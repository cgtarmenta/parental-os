#!/usr/bin/env python3
"""
apply-parental-overlay.py — Idempotent, fail-closed Calamares transformer for Ubuntu.

This script is invoked during Ubuntu live ISO assembly and at live runtime to
integrate parental-guard into the Calamares installer configuration. It:

1. Adds all four systemd services/units to the services-systemd.conf enable list:
   - parental-guard.service
   - parental-guard-agent.service
   - parental-guard-enroll.service
   - parental-guard-enroll.path
2. Adds parental-guard to packages.conf if present.
3. Injects target repository copying into pre-install shellprocess so the
   local /srv/parental-os-repo (or parental-guard deb) is staged in the target root.
4. Generates target scripts:
   - copy-parental-os-repo: copies local deb/repo and configures temporary apt source.
   - install-parental-guard: installs parental-guard in target chroot, configures PAM
     common-account, sudoers, and enables systemd units.
   - remove-parental-os-repo: cleans up temporary apt repo source and /srv/parental-os-repo.
5. Injects cleanup into shellprocess cleanup to remove temporary repository
   artifacts from the target upon completion.

The transformer is idempotent: running it multiple times produces identical output.
It is fail-closed: if expected configuration files or markers are absent, it aborts
with a non-zero exit code.

Usage:
    apply-parental-overlay.py stage <calamares_src_dir> <live_airootfs_dir> [transformer_src] [expected_package]
    apply-parental-overlay.py runtime <calamares_src_dir> <live_airootfs_dir>
    apply-parental-overlay.py <calamares_src_dir>
"""

import re
import shutil
import sys
from pathlib import Path

PARENTAL_GUARD_PKG = "parental-guard"
SERVICES = [
    "parental-guard.service",
    "parental-guard-agent.service",
    "parental-guard-enroll.service",
    "parental-guard-enroll.path",
]
COPY_REPO_SCRIPT_PATH = "/etc/calamares/scripts/copy-parental-os-repo"
INSTALL_SCRIPT_PATH = "/etc/calamares/scripts/install-parental-guard"
CLEANUP_SCRIPT_PATH = "/etc/calamares/scripts/remove-parental-os-repo"
TRANSFORMER_LIVE_PATH = "/usr/local/lib/parental-os/apply-parental-overlay.py"

SERVICES_CANDIDATES = [
    "src/modules/services-systemd/services-systemd.conf",
    "src/modules/services-systemd.conf",
    "modules/services-systemd/services-systemd.conf",
    "modules/services-systemd.conf",
    "etc/calamares/modules/services-systemd.conf",
]

BEFORE_SHELLPROCESS_CANDIDATES = [
    "src/modules/shellprocess/shellprocess-before-online.conf",
    "src/modules/shellprocess/shellprocess-before.conf",
    "src/modules/shellprocess/shellprocess.conf",
    "modules/shellprocess-before-online.conf",
    "modules/shellprocess-before.conf",
    "modules/shellprocess.conf",
]

CLEANUP_SHELLPROCESS_CANDIDATES = [
    "src/modules/shellprocess/shellprocess_cleanup_calamares.conf",
    "src/modules/shellprocess/shellprocess_cleanup.conf",
    "src/modules/shellprocess/shellprocess-final.conf",
    "modules/shellprocess_cleanup_calamares.conf",
    "modules/shellprocess_cleanup.conf",
    "modules/shellprocess-final.conf",
]

PACKAGES_CANDIDATES = [
    "src/modules/packages/packages.conf",
    "modules/packages/packages.conf",
    "modules/packages.conf",
]


def fail(msg: str) -> None:
    """Print an error to stderr and exit non-zero (fail-closed)."""
    print(f"apply-parental-overlay: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_yaml(path: Path) -> str:
    """Load a file, failing closed if it does not exist."""
    if not path.is_file():
        fail(f"expected file not found: {path}")
    return path.read_text(encoding="utf-8")


def find_conf_file(base_dir: Path, candidates: list[str], required: bool = True) -> Path | None:
    """Find the first matching candidate file in base_dir."""
    for rel in candidates:
        p = base_dir / rel
        if p.is_file():
            return p
    if required:
        fail(
            f"none of expected files found in {base_dir}: {', '.join(candidates)}; "
            "upstream layout may have changed"
        )
    return None


def add_services_to_systemd(conf_path: Path) -> None:
    """Add all parental-guard services to services-systemd.conf units list."""
    content = load_yaml(conf_path)
    if "units:" not in content:
        fail(
            f"could not find units list in {conf_path}; "
            "upstream layout may have changed"
        )

    modified = False
    for svc in SERVICES:
        if f'"{svc}"' in content or f"'{svc}'" in content or f" {svc}\n" in content:
            continue
        unit_entry = (
            f"\n   - name: \"{svc}\"\n"
            f"     action: \"enable\"\n"
            f"     mandatory: true\n"
        )
        content += unit_entry
        modified = True
        print(f"apply-parental-overlay: added {svc} to {conf_path}")

    if modified:
        conf_path.write_text(content, encoding="utf-8")


def add_package_to_packages(conf_path: Path) -> None:
    """Add parental-guard to packages.conf install list if present."""
    content = load_yaml(conf_path)
    if PARENTAL_GUARD_PKG in content:
        return

    pattern = r"(install:\s*\n(?:\s*#\s*[^\n]*\n)*\s*)(  - )"
    match = re.search(pattern, content)
    if match:
        insertion = f"{match.group(1)}{match.group(2)}{PARENTAL_GUARD_PKG}\n"
        new_content = content[: match.start()] + insertion + content[match.start(2) :]
        conf_path.write_text(new_content, encoding="utf-8")
        print(f"apply-parental-overlay: added {PARENTAL_GUARD_PKG} to {conf_path}")


def add_repo_copy_to_before_shellprocess(conf_path: Path) -> None:
    """Wire copying of temporary local repository into target before installation."""
    content = load_yaml(conf_path)
    if COPY_REPO_SCRIPT_PATH in content:
        return

    command = f'    - command: "{COPY_REPO_SCRIPT_PATH} ${{ROOT}}"'
    marker = "script:\n"
    if marker not in content:
        fail(
            f"could not find script list in {conf_path}; "
            "upstream layout may have changed"
        )

    content = content.replace(marker, marker + command + "\n", 1)
    conf_path.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: wired target repo copy in {conf_path}")


def wire_shellprocess_cleanup(conf_path: Path) -> None:
    """Add temporary repository cleanup command to Calamares cleanup shellprocess."""
    content = load_yaml(conf_path)
    if CLEANUP_SCRIPT_PATH in content:
        return

    command = f"    - {CLEANUP_SCRIPT_PATH} /etc/apt/sources.list"
    marker = "script:\n"
    if marker not in content:
        fail(
            f"could not find script list in {conf_path}; "
            "upstream layout may have changed"
        )

    content = content.replace(marker, marker + command + "\n", 1)
    conf_path.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: wired target cleanup in {conf_path}")


def install_target_repo_copy(calamares_src_dir: Path) -> None:
    """Install pre-install script that stages local repo and apt source in target."""
    scripts_dir = calamares_src_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    copy_script = scripts_dir / "copy-parental-os-repo"
    copy_script.write_text(
        "#!/bin/bash\n"
        "# Copy the live image's temporary repository into the mounted target.\n"
        "set -euo pipefail\n"
        'source_repo="${PARENTAL_OS_REPO_SOURCE:-/srv/parental-os-repo}"\n'
        'target_root="${1:-${ROOT:-}}"\n'
        'if [[ -z "$target_root" ]]; then\n'
        '  echo "copy-parental-os-repo: target root argument is required" >&2\n'
        "  exit 1\n"
        "fi\n"
        'if [[ ! -d "$target_root" ]]; then\n'
        '  echo "copy-parental-os-repo: target root not found: $target_root" >&2\n'
        "  exit 1\n"
        "fi\n"
        'if [[ ! -d "$source_repo" ]]; then\n'
        '  echo "copy-parental-os-repo: source repo not found: $source_repo" >&2\n'
        "  exit 1\n"
        "fi\n"
        'install -d "$target_root/srv"\n'
        'rm -rf -- "$target_root/srv/parental-os-repo"\n'
        'cp -a "$source_repo" "$target_root/srv/parental-os-repo"\n'
        'install -d "$target_root/etc/apt/sources.list.d"\n'
        'cat >"$target_root/etc/apt/sources.list.d/parental-os.list" <<\'EOF\'\n'
        'deb [trusted=yes] file:///srv/parental-os-repo ./\n'
        "EOF\n",
        encoding="utf-8",
    )
    copy_script.chmod(0o755)
    print(f"apply-parental-overlay: installed target repo copy at {copy_script}")


def install_target_pkg_installer(calamares_src_dir: Path) -> None:
    """Install script to install parental-guard deb and configure system in target."""
    scripts_dir = calamares_src_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    install_script = scripts_dir / "install-parental-guard"
    install_script.write_text(
        "#!/bin/bash\n"
        "# Install parental-guard deb in target system and configure PAM/services.\n"
        "set -euo pipefail\n"
        'target_root="${1:-${ROOT:-/}}"\n'
        'prefix=""\n'
        'if [[ "$target_root" != "/" ]]; then\n'
        '  prefix="$target_root"\n'
        "fi\n"
        "run_chroot() {\n"
        '  if [[ -n "$prefix" ]]; then\n'
        '    chroot "$prefix" "$@"\n'
        "  else\n"
        '    "$@"\n'
        "  fi\n"
        "}\n"
        'deb_file=""\n'
        'shopt -s nullglob\n'
        'debs=("${prefix}/srv/parental-os-repo"/parental-guard*.deb)\n'
        'shopt -u nullglob\n'
        'if [[ "${#debs[@]}" -gt 0 ]]; then\n'
        '  deb_file="${debs[0]}"\n'
        "fi\n"
        'if [[ -n "$deb_file" ]]; then\n'
        '  deb_rel="${deb_file#$prefix}"\n'
        '  run_chroot dpkg -i "$deb_rel" || run_chroot apt-get install -f -y --no-install-recommends\n'
        "fi\n"
        'pam_account="${prefix}/etc/pam.d/common-account"\n'
        'if [[ -f "$pam_account" ]]; then\n'
        '  if ! grep -q "pam_unix.so" "$pam_account"; then\n'
        '    echo "account required pam_unix.so" >> "$pam_account"\n'
        "  fi\n"
        "fi\n"
        'if [[ -f "${prefix}/etc/sudoers.d/parental-os" ]]; then\n'
        '  chmod 0440 "${prefix}/etc/sudoers.d/parental-os"\n'
        "fi\n"
        "for svc in parental-guard.service parental-guard-agent.service parental-guard-enroll.service parental-guard-enroll.path; do\n"
        '  run_chroot systemctl enable "$svc" 2>/dev/null || true\n'
        "done\n",
        encoding="utf-8",
    )
    install_script.chmod(0o755)
    print(f"apply-parental-overlay: installed target package installer at {install_script}")


def install_target_cleanup(calamares_src_dir: Path) -> None:
    """Install cleanup hook to remove temporary local apt repository and debs."""
    scripts_dir = calamares_src_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    cleanup_script = scripts_dir / "remove-parental-os-repo"
    cleanup_script.write_text(
        "#!/bin/bash\n"
        "# Remove temporary parental-os repository and staged debs from the target.\n"
        "set -euo pipefail\n"
        'target_input="${1:-${ROOT:-/etc/apt/sources.list}}"\n'
        'target_root=""\n'
        'case "$target_input" in\n'
        "  /etc/apt/sources.list | /etc/apt/sources.list.d/*)\n"
        '    target_root="/" ;;\n'
        "  */etc/apt/sources.list)\n"
        '    target_root="${target_input%/etc/apt/sources.list}" ;;\n'
        "  */etc/apt/sources.list.d/*)\n"
        '    target_root="${target_input%/etc/apt/sources.list.d/*}" ;;\n'
        "  *)\n"
        '    if [[ -d "$target_input" ]]; then\n'
        '      target_root="$target_input"\n'
        "    else\n"
        '      target_root="/"\n'
        "    fi ;;\n"
        "esac\n"
        'prefix=""\n'
        'if [[ -n "$target_root" && "$target_root" != "/" ]]; then\n'
        '  prefix="$target_root"\n'
        "fi\n"
        'rm -f -- "${prefix}/etc/apt/sources.list.d/parental-os.list"\n'
        'if [[ -f "${prefix}/etc/apt/sources.list" ]]; then\n'
        '  python3 - "${prefix}/etc/apt/sources.list" <<\'PYEOF\'\n'
        "import re, sys\n"
        "for path in sys.argv[1:]:\n"
        "    try:\n"
        '        with open(path, "r", encoding="utf-8") as f:\n'
        "            content = f.read()\n"
        "    except FileNotFoundError:\n"
        "        continue\n"
        "    new = re.sub(r'^deb\\s+.*parental-os-repo.*\\n?', '', content, flags=re.MULTILINE)\n"
        "    new = re.sub(r'^# BEGIN parental-os temporary repository\\n.*?\\n# END parental-os temporary repository\\n?', '', new, flags=re.MULTILINE | re.DOTALL)\n"
        '    with open(path, "w", encoding="utf-8") as f:\n'
        "        f.write(new)\n"
        "PYEOF\n"
        "fi\n"
        'rm -rf -- "${prefix}/srv/parental-os-repo"\n',
        encoding="utf-8",
    )
    cleanup_script.chmod(0o755)
    print(f"apply-parental-overlay: installed target cleanup at {cleanup_script}")


def copy_runtime_source_to_live(calamares_src_dir: Path, live_airootfs_dir: Path) -> None:
    """Copy patched source where calamares launcher can reapply it at runtime."""
    share_dir = live_airootfs_dir / "usr/share/calamares"
    share_dir.mkdir(parents=True, exist_ok=True)
    if (calamares_src_dir / "src").is_dir():
        shutil.copytree(calamares_src_dir / "src", share_dir / "src", dirs_exist_ok=True)
    if (calamares_src_dir / "modules").is_dir():
        shutil.copytree(calamares_src_dir / "modules", share_dir / "modules", dirs_exist_ok=True)
    if (calamares_src_dir / "scripts").is_dir():
        shutil.copytree(calamares_src_dir / "scripts", share_dir / "scripts", dirs_exist_ok=True)
    print(f"apply-parental-overlay: copied runtime source to {share_dir}")


def copy_transformer_to_live(live_airootfs_dir: Path, transformer_src: Path) -> None:
    """Copy this transformer into the live filesystem."""
    dest = live_airootfs_dir / TRANSFORMER_LIVE_PATH.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(transformer_src.read_text(encoding="utf-8"), encoding="utf-8")
    dest.chmod(0o755)
    print(f"apply-parental-overlay: copied transformer to {dest}")


def patch_calamares_launcher(
    calamares_src_dir: Path, live_airootfs_dir: Path, expected_package: str | None
) -> None:
    """Patch calamares launcher script to reapply transformer if present."""
    online_sh = live_airootfs_dir / "usr/local/bin/calamares-online.sh"
    if not online_sh.is_file():
        return

    content = online_sh.read_text(encoding="utf-8")

    if expected_package and expected_package not in content:
        fail(
            f"calamares launcher at {online_sh} does not contain "
            f"expected package {expected_package}"
        )

    if "apply-parental-overlay.py" in content:
        return

    reapply_block = (
        "# parental-os: reapply the Calamares parental overlay\n"
        f"    if ! sudo python3 {TRANSFORMER_LIVE_PATH} runtime /usr/share/calamares /; then\n"
        '        echo "parental-os: FATAL: could not reapply the Calamares parental overlay" >&2\n'
        '        echo "parental-os: refusing to start an install that would omit parental-guard" >&2\n'
        "        exit 1\n"
        "    fi\n"
        "    "
    )

    if "sudo cp" in content and "settings" in content:
        content = content.replace(
            'sudo cp "/usr/share/calamares/settings_',
            reapply_block + 'sudo cp "/usr/share/calamares/settings_',
            1,
        )
    elif "pkexec-wrapper calamares" in content:
        content = content.replace(
            "pkexec-wrapper calamares",
            reapply_block + "pkexec-wrapper calamares",
            1,
        )
    elif "exec calamares" in content:
        content = content.replace(
            "exec calamares",
            reapply_block + "exec calamares",
            1,
        )
    else:
        # Prepend before final non-empty line
        lines = content.rstrip().split("\n")
        lines.insert(len(lines) - 1, reapply_block)
        content = "\n".join(lines) + "\n"

    online_sh.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: patched {online_sh} for reapplication")


def install_live_calamares_files(calamares_src_dir: Path, live_airootfs_dir: Path) -> None:
    """Install the patched Calamares module files into the live filesystem."""
    live_etc = live_airootfs_dir / "etc/calamares"
    modules_dir = live_etc / "modules"
    scripts_dir = live_etc / "scripts"
    modules_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir.mkdir(parents=True, exist_ok=True)

    services_conf = find_conf_file(calamares_src_dir, SERVICES_CANDIDATES)
    (modules_dir / "services-systemd.conf").write_text(
        services_conf.read_text(encoding="utf-8"), encoding="utf-8"
    )

    before_conf = find_conf_file(calamares_src_dir, BEFORE_SHELLPROCESS_CANDIDATES)
    (modules_dir / before_conf.name).write_text(
        before_conf.read_text(encoding="utf-8"), encoding="utf-8"
    )

    cleanup_conf = find_conf_file(calamares_src_dir, CLEANUP_SHELLPROCESS_CANDIDATES)
    (modules_dir / cleanup_conf.name).write_text(
        cleanup_conf.read_text(encoding="utf-8"), encoding="utf-8"
    )

    pkg_conf = find_conf_file(calamares_src_dir, PACKAGES_CANDIDATES, required=False)
    if pkg_conf:
        (modules_dir / "packages.conf").write_text(
            pkg_conf.read_text(encoding="utf-8"), encoding="utf-8"
        )

    for script_name in ("copy-parental-os-repo", "install-parental-guard", "remove-parental-os-repo"):
        script_src = calamares_src_dir / "scripts" / script_name
        if script_src.is_file():
            script_dest = scripts_dir / script_name
            script_dest.write_text(script_src.read_text(encoding="utf-8"), encoding="utf-8")
            script_dest.chmod(0o755)

    print(f"apply-parental-overlay: installed live Calamares files under {live_etc}")


def transform_source(calamares_src_dir: Path) -> None:
    """Transform the source configuration tree."""
    services_conf = find_conf_file(calamares_src_dir, SERVICES_CANDIDATES)
    before_conf = find_conf_file(calamares_src_dir, BEFORE_SHELLPROCESS_CANDIDATES)
    cleanup_conf = find_conf_file(calamares_src_dir, CLEANUP_SHELLPROCESS_CANDIDATES)
    pkg_conf = find_conf_file(calamares_src_dir, PACKAGES_CANDIDATES, required=False)

    add_services_to_systemd(services_conf)
    if pkg_conf:
        add_package_to_packages(pkg_conf)
    add_repo_copy_to_before_shellprocess(before_conf)
    install_target_repo_copy(calamares_src_dir)
    install_target_pkg_installer(calamares_src_dir)
    install_target_cleanup(calamares_src_dir)
    wire_shellprocess_cleanup(cleanup_conf)


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: apply-parental-overlay.py stage <calamares_src_dir> "
            "<live_airootfs_dir> [transformer_src] [expected_package]\n"
            "       apply-parental-overlay.py runtime <calamares_src_dir> "
            "<live_airootfs_dir>\n"
            "       apply-parental-overlay.py <calamares_src_dir>",
            file=sys.stderr,
        )
        return 2

    first_arg = sys.argv[1]
    if first_arg in ("stage", "runtime"):
        mode = first_arg
        if len(sys.argv) < 3:
            fail("calamares source dir argument is required")
        calamares_src_dir = Path(sys.argv[2])
        if not calamares_src_dir.is_dir():
            fail(f"calamares source dir not found: {calamares_src_dir}")

        if len(sys.argv) < 4:
            fail("live airootfs dir argument is required")
        live_airootfs_dir = Path(sys.argv[3])
        if not live_airootfs_dir.is_dir():
            fail(f"live airootfs dir not found: {live_airootfs_dir}")

        transform_source(calamares_src_dir)

        if mode == "stage":
            transformer_src = Path(sys.argv[4]) if len(sys.argv) >= 5 else Path(__file__)
            expected_package = sys.argv[5] if len(sys.argv) >= 6 else None
            copy_transformer_to_live(live_airootfs_dir, transformer_src)
            copy_runtime_source_to_live(calamares_src_dir, live_airootfs_dir)
            patch_calamares_launcher(calamares_src_dir, live_airootfs_dir, expected_package)
        elif mode == "runtime":
            install_live_calamares_files(calamares_src_dir, live_airootfs_dir)
    else:
        calamares_src_dir = Path(first_arg)
        if not calamares_src_dir.is_dir():
            fail(f"calamares source dir not found: {calamares_src_dir}")
        transform_source(calamares_src_dir)

    print("apply-parental-overlay: transformation complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
