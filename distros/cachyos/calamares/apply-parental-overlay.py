#!/usr/bin/env python3
"""
apply-parental-overlay.py — Idempotent, fail-closed staged Calamares transformer.

This script is invoked during ISO assembly to integrate parental-guard into the
Calamares installer configuration that ships inside the live image. It:

1. Adds ``parental-guard`` to the pacstrap basePackages list so the target
   system receives the guard package during installation.
2. Copies the live image's temporary ``/srv/parental-os-repo`` into the target
   root before pacstrap, because pacstrap resolves file:// repos below the new
   root while synchronizing databases.
3. Adds ``parental-guard.service`` and ``parental-guard-agent.service`` to the
   services-systemd enable list so both services are enabled on the target.
4. Installs a final target cleanup that removes only the marked temporary
   ``[parental-os]`` repository stanza from the installed target's pacman.conf
   after installation completes.

The transformer is idempotent: running it multiple times produces the same
result. It is fail-closed: if expected markers (the upstream basePackages list,
the upstream units list, or the Calamares module files) are absent, it aborts
with a non-zero exit rather than silently producing an image without target
integration.

Usage:
    apply-parental-overlay.py <calamares_src_dir>

Where <calamares_src_dir> is the staged Calamares source tree containing
``src/modules/pacstrap/pacstrap.conf`` and
``src/modules/services-systemd/services-systemd.conf``.
"""

import re
import shutil
import sys
from pathlib import Path

PARENTAL_GUARD_PKG = "parental-guard"
PARENTAL_GUARD_SERVICE = "parental-guard.service"
PARENTAL_GUARD_AGENT_SERVICE = "parental-guard-agent.service"
CLEANUP_SCRIPT_PATH = "/etc/calamares/scripts/remove-parental-os-repo"
COPY_REPO_SCRIPT_PATH = "/etc/calamares/scripts/copy-parental-os-repo"

# The temporary repository stanza added to the live image pacman.conf. The
# target cleanup must remove exactly this stanza and nothing else.
TEMP_REPO_STANZA_MARKER = "[parental-os]"
TRANSFORMER_LIVE_PATH = "/usr/local/lib/parental-os/apply-parental-overlay.py"


def fail(msg: str) -> None:
    """Print an error to stderr and exit non-zero (fail-closed)."""
    print(f"apply-parental-overlay: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_yaml(path: Path) -> str:
    """Load a file, failing closed if it does not exist."""
    if not path.is_file():
        fail(f"expected file not found: {path}")
    return path.read_text(encoding="utf-8")


def add_package_to_pacstrap(conf_path: Path) -> None:
    """Add parental-guard to the pacstrap basePackages list if absent.

    The upstream pacstrap.conf is a YAML file with a ``basePackages`` list.
    We insert parental-guard as the first entry after the list header to
    ensure it is installed early in the pacstrap flow.
    """
    content = load_yaml(conf_path)
    if PARENTAL_GUARD_PKG in content:
        # Already present; idempotent no-op.
        return

    # Find the basePackages list and insert parental-guard as the first item.
    pattern = r"(basePackages:\s*\n(?:\s*#\s*[^\n]*\n)*\s*)(  - )"
    match = re.search(pattern, content)
    if not match:
        fail(
            f"could not find basePackages list in {conf_path}; "
            "upstream layout may have changed"
        )

    insertion = f"{match.group(1)}{match.group(2)}{PARENTAL_GUARD_PKG}\n"
    new_content = content[: match.start()] + insertion + content[match.start(2) :]
    conf_path.write_text(new_content, encoding="utf-8")
    print(f"apply-parental-overlay: added {PARENTAL_GUARD_PKG} to {conf_path}")


def add_cleanup_to_postinstall_files(conf_path: Path) -> None:
    """Copy the cleanup hook into the target before chrooted shellprocess runs."""
    content = load_yaml(conf_path)
    cleanup_entry = f'  - "{CLEANUP_SCRIPT_PATH}"'
    if cleanup_entry in content:
        return

    pattern = r"(postInstallFiles:\s*\n(?:\s*#\s*[^\n]*\n)*\s*)(  - )"
    match = re.search(pattern, content)
    if not match:
        fail(
            f"could not find postInstallFiles list in {conf_path}; "
            "upstream layout may have changed"
        )

    insertion = f"{match.group(1)}{cleanup_entry}\n"
    new_content = content[: match.start()] + insertion + content[match.start(2) :]
    conf_path.write_text(new_content, encoding="utf-8")
    print(f"apply-parental-overlay: added {CLEANUP_SCRIPT_PATH} to {conf_path}")


def add_repo_copy_to_before_online(conf_path: Path) -> None:
    """Copy the temporary local repository into the target before pacstrap."""
    content = load_yaml(conf_path)
    if "dontChroot: true" not in content:
        fail(
            f"expected dontChroot: true in {conf_path}; "
            "repo copy must run from the live environment before pacstrap"
        )

    command = f'    - command: "{COPY_REPO_SCRIPT_PATH} ${{ROOT}}"'
    if COPY_REPO_SCRIPT_PATH in content:
        return

    marker = "script:\n"
    if marker not in content:
        fail(
            f"could not find script list in {conf_path}; "
            "upstream layout may have changed"
        )

    content = content.replace(marker, marker + command + "\n", 1)
    conf_path.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: wired target repo copy in {conf_path}")


def add_services_to_systemd(conf_path: Path) -> None:
    """Add both parental-guard services to the services-systemd units list.

    The upstream services-systemd.conf is a YAML file with a ``units`` list.
    Each unit is a mapping with ``name``, ``action``, and ``mandatory`` keys.
    We append both services as enable entries.
    """
    content = load_yaml(conf_path)
    modified = False

    for svc in (PARENTAL_GUARD_SERVICE, PARENTAL_GUARD_AGENT_SERVICE):
        if svc in content:
            continue
        # Append a new unit entry before the end of the file. The YAML list
        # uses 3-space indent for unit mappings in the upstream file.
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


def install_target_cleanup(calamares_src_dir: Path) -> None:
    """Install a cleanup script that removes the temporary [parental-os] stanza.

    After CachyOS reinstalls its Calamares package on the target, the temporary
    [parental-os] repository stanza must be removed from the installed system's
    pacman.conf. This script creates a small cleanup hook that removes only
    that stanza.
    """
    scripts_dir = calamares_src_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    cleanup_script = scripts_dir / "remove-parental-os-repo"
    cleanup_script.write_text(
        "#!/bin/bash\n"
        "# Remove the temporary [parental-os] repository stanza from the\n"
        "# installed target's pacman.conf. This stanza is only needed during\n"
        "# the live build and initial pacstrap; it must not persist on the\n"
        "# installed system.\n"
        f"set -euo pipefail\n"
        f'target_pacman_conf="${{1:-/etc/pacman.conf}}"\n'
        f'if [[ ! -f "$target_pacman_conf" ]]; then\n'
        f'  echo "remove-parental-os-repo: $target_pacman_conf not found" >&2\n'
        f"  exit 1\n"
        f"fi\n"
        f'target_root=""\n'
        f'case "$target_pacman_conf" in\n'
        f'  /etc/pacman.conf) target_root="/" ;;\n'
        f'  */etc/pacman.conf) target_root="${{target_pacman_conf%/etc/pacman.conf}}" ;;\n'
        f'esac\n'
        f'cleanup_targets=("$target_pacman_conf")\n'
        f'if [[ -n "$target_root" ]]; then\n'
        f'  if [[ "$target_root" == "/" ]]; then\n'
        f'    cleanup_targets+=("/etc/pacman-more.conf")\n'
        f'  else\n'
        f'    cleanup_targets+=("$target_root/etc/pacman-more.conf")\n'
        f'  fi\n'
        f'fi\n'
        f"# Remove the exact temporary [parental-os] repo section from any\n"
        f"# installed pacman config that may have inherited the live config.\n"
        f'python3 - "${{cleanup_targets[@]}}" <<\'PYEOF\'\n'
        f'import re, sys\n'
        f"marked = r'^# BEGIN parental-os temporary repository\\n\\[parental-os\\]\\n.*?^# END parental-os temporary repository\\n?'\n"
        f"unmarked_temp = r'^\\[parental-os\\]\\n(?:(?!^\\[[^]\\n]+\\]\\n)[\\s\\S])*(?:Server = http://127\\.0\\.0\\.1:8765|Server = file:///srv/parental-os-repo)(?:(?!^\\[[^]\\n]+\\]\\n)[\\s\\S])*'\n"
        f"for path in sys.argv[1:]:\n"
        f"    try:\n"
        f"        with open(path) as f:\n"
        f"            content = f.read()\n"
        f"    except FileNotFoundError:\n"
        f"        continue\n"
        f"    new = re.sub(marked, '', content, flags=re.MULTILINE | re.DOTALL)\n"
        f"    new = re.sub(unmarked_temp, '', new, flags=re.MULTILINE | re.DOTALL)\n"
        f"    with open(path, 'w') as f:\n"
        f"        f.write(new)\n"
        f"PYEOF\n"
        f'if [[ -n "$target_root" ]]; then\n'
        f'  if [[ "$target_root" == "/" ]]; then\n'
        f'    repo_path="/srv/parental-os-repo"\n'
        f'  else\n'
        f'    repo_path="$target_root/srv/parental-os-repo"\n'
        f'  fi\n'
        f'  rm -rf -- "$repo_path"\n'
        f'fi\n',
        encoding="utf-8",
    )
    cleanup_script.chmod(0o755)
    print(f"apply-parental-overlay: installed target cleanup at {cleanup_script}")


def install_target_repo_copy(calamares_src_dir: Path) -> None:
    """Install a pre-pacstrap script that stages the local repo in the target."""
    scripts_dir = calamares_src_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    copy_script = scripts_dir / "copy-parental-os-repo"
    copy_script.write_text(
        "#!/bin/bash\n"
        "# Copy the live image's temporary repository into the mounted target.\n"
        "# pacstrap resolves file:// repository URLs relative to the target root.\n"
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
        'if [[ ! -e "$source_repo/parental-os.db" ]]; then\n'
        '  echo "copy-parental-os-repo: source repo database missing" >&2\n'
        "  exit 1\n"
        "fi\n"
        'install -d "$target_root/srv"\n'
        'rm -rf -- "$target_root/srv/parental-os-repo"\n'
        'cp -a "$source_repo" "$target_root/srv/parental-os-repo"\n',
        encoding="utf-8",
    )
    copy_script.chmod(0o755)
    print(f"apply-parental-overlay: installed target repo copy at {copy_script}")


def wire_shellprocess_cleanup(calamares_src_dir: Path) -> None:
    """Add the temporary repository cleanup command to Calamares shellprocess."""
    shellprocess_conf = (
        calamares_src_dir
        / "src/modules/shellprocess/shellprocess_cleanup_calamares.conf"
    )
    content = load_yaml(shellprocess_conf)
    command = f"    - {CLEANUP_SCRIPT_PATH} /etc/pacman.conf"
    if f"{CLEANUP_SCRIPT_PATH} /etc/pacman.conf" in content:
        return
    marker = "script:\n"
    if marker not in content:
        fail(
            f"could not find script list in {shellprocess_conf}; "
            "upstream layout may have changed"
        )
    content = content.replace(marker, marker + command + "\n", 1)
    shellprocess_conf.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: wired target cleanup in {shellprocess_conf}")


def copy_runtime_source_to_live(calamares_src_dir: Path, live_airootfs_dir: Path) -> None:
    """Copy patched source where calamares-online.sh can reapply it at runtime."""
    share_dir = live_airootfs_dir / "usr/share/calamares"
    share_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(calamares_src_dir / "src", share_dir / "src", dirs_exist_ok=True)
    print(f"apply-parental-overlay: copied runtime source to {share_dir}")


def install_live_calamares_files(calamares_src_dir: Path, live_airootfs_dir: Path) -> None:
    """Install the patched Calamares module files into the live filesystem."""
    live_etc = live_airootfs_dir / "etc/calamares"
    modules_dir = live_etc / "modules"
    scripts_dir = live_etc / "scripts"
    modules_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir.mkdir(parents=True, exist_ok=True)

    files = {
        calamares_src_dir / "src/modules/pacstrap/pacstrap.conf": modules_dir
        / "pacstrap.conf",
        calamares_src_dir
        / "src/modules/shellprocess/shellprocess-before-online.conf": modules_dir
        / "shellprocess-before-online.conf",
        calamares_src_dir
        / "src/modules/services-systemd/services-systemd.conf": modules_dir
        / "services-systemd.conf",
        calamares_src_dir
        / "src/modules/shellprocess/shellprocess_cleanup_calamares.conf": modules_dir
        / "shellprocess_cleanup_calamares.conf",
    }
    for src, dest in files.items():
        if not src.is_file():
            fail(f"expected file not found: {src}")
        dest.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    for script_name in ("copy-parental-os-repo", "remove-parental-os-repo"):
        script_src = calamares_src_dir / "scripts" / script_name
        script_dest = scripts_dir / script_name
        script_dest.write_text(script_src.read_text(encoding="utf-8"), encoding="utf-8")
        script_dest.chmod(0o755)

    print(f"apply-parental-overlay: installed live Calamares files under {live_etc}")


def patch_calamares_online(
    calamares_src_dir: Path, live_airootfs_dir: Path, expected_package: str | None
) -> None:
    """Patch calamares-online.sh to reapply the transformer after CachyOS
    reinstalls its Calamares package.

    The upstream calamares-online.sh runs ``pacman -Sy cachyos-calamares-next``
    (or deckify) which overwrites the patched Calamares config. We patch the
    script to reapply apply-parental-overlay.py after the reinstall.
    """
    online_sh = live_airootfs_dir / "usr/local/bin/calamares-online.sh"
    if not online_sh.is_file():
        fail(
            f"expected calamares-online.sh not found at {online_sh}; "
            "cannot patch target integration reapplication"
        )

    content = online_sh.read_text(encoding="utf-8")

    # Check for the reinstall marker: the upstream script reinstalls calamares
    # via pacman -Sy. If this marker is absent, the upstream layout has changed
    # and we must abort rather than produce an image without target integration.
    if "pacman -Sy" not in content and "pacman -Sy --noconfirm" not in content:
        fail(
            f"calamares-online.sh at {online_sh} does not contain the expected "
            "pacman -Sy calamares reinstall marker; upstream layout may have changed"
        )

    if expected_package and expected_package not in content:
        fail(
            f"calamares-online.sh at {online_sh} does not reinstall "
            f"expected package {expected_package}"
        )

    # Idempotent: only patch once.
    if "apply-parental-overlay.py" in content:
        return

    # Insert a reapplication call just before the final calamares exec.
    # We place the transformer in /usr/local/bin/ on the live filesystem.
    reapply_line = (
        "# parental-os: reapply the Calamares parental overlay after the\n"
        "# CachyOS Calamares package reinstall overwrites our patches.\n"
        f"sudo {TRANSFORMER_LIVE_PATH} runtime /usr/share/calamares /\n"
    )

    # Insert before the line that copies settings.conf or before the exec.
    if "sudo cp" in content and "settings" in content:
        content = content.replace(
            'sudo cp "/usr/share/calamares/settings_',
            reapply_line + 'sudo cp "/usr/share/calamares/settings_',
            1,
        )
    elif "pkexec-wrapper calamares" in content:
        content = content.replace(
            "pkexec-wrapper calamares",
            reapply_line + "pkexec-wrapper calamares",
            1,
        )
    else:
        fail(
            f"could not find insertion point in {online_sh}; "
            "upstream layout may have changed"
        )

    online_sh.write_text(content, encoding="utf-8")
    print(f"apply-parental-overlay: patched {online_sh} for reapplication")


def copy_transformer_to_live(live_airootfs_dir: Path, transformer_src: Path) -> None:
    """Copy this transformer into the live filesystem's /usr/local/bin/."""
    dest = live_airootfs_dir / TRANSFORMER_LIVE_PATH.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(transformer_src.read_text(encoding="utf-8"), encoding="utf-8")
    dest.chmod(0o755)
    print(f"apply-parental-overlay: copied transformer to {dest}")


def transform_source(calamares_src_dir: Path) -> None:
    pacstrap_conf = calamares_src_dir / "src/modules/pacstrap/pacstrap.conf"
    before_online_conf = (
        calamares_src_dir
        / "src/modules/shellprocess/shellprocess-before-online.conf"
    )
    services_conf = (
        calamares_src_dir / "src/modules/services-systemd/services-systemd.conf"
    )
    add_package_to_pacstrap(pacstrap_conf)
    add_repo_copy_to_before_online(before_online_conf)
    add_cleanup_to_postinstall_files(pacstrap_conf)
    add_services_to_systemd(services_conf)
    install_target_repo_copy(calamares_src_dir)
    install_target_cleanup(calamares_src_dir)
    wire_shellprocess_cleanup(calamares_src_dir)


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: apply-parental-overlay.py stage <calamares_src_dir> "
            "<live_airootfs_dir> [transformer_src] [expected_package]\n"
            "       apply-parental-overlay.py runtime <calamares_src_dir> "
            "<live_airootfs_dir>",
            file=sys.stderr,
        )
        return 2

    mode = sys.argv[1]
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
        patch_calamares_online(calamares_src_dir, live_airootfs_dir, expected_package)
        # Also install the patched files directly into /etc/calamares/modules/
        # so they are available even before calamares-online.sh re-runs the
        # transformer in runtime mode. This covers the offline install path
        # and the gap between calamares-online.sh reinstalling the package
        # and re-running the transformer.
        install_live_calamares_files(calamares_src_dir, live_airootfs_dir)
    elif mode == "runtime":
        install_live_calamares_files(calamares_src_dir, live_airootfs_dir)
    else:
        fail(f"unknown mode: {mode} (use stage|runtime)")

    print("apply-parental-overlay: transformation complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
