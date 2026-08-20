#!/usr/bin/env bash
# build-edition.sh — Container entrypoint for the parental-os CachyOS builder.
#
# Runs inside the ephemeral privileged Arch container. The host build script
# (scripts/build-cachyos.sh) has already:
#   - Resolved the exact upstream SHAs via git ls-remote.
#   - Written per-edition provenance.json files under out/cachyos/<edition>/.
#   - Fetched and checked out those exact SHAs into out/cachyos/staging/<edition>/.
#   - Built the Docker builder image.
#
# This entrypoint:
#   1. Builds parental-guard once (for `all`) into a local pacman repository.
#   2. Creates the [parental-os] repository with repo-add.
#   3. For each edition (desktop then handheld for `all`):
#      a. Verifies the checked-out SHAs match the recorded provenance.
#      b. Copies the resolved official archiso/ profile into a mutable staging
#         directory.
#      c. Adds parental-guard, the embedded /srv/parental-os-repo, and the
#         [parental-os] repository entries to the staged profile.
#      d. Applies the Calamares parental overlay transformer.
#      e. Runs the upstream CachyOS buildiso.sh to produce the ISO.
#      f. Normalizes outputs: ISO, pkglist, SHA256, provenance, build log.
#
# Usage: build-edition.sh <target> [builder_image_tag]
#   target: desktop | handheld | all
set -euo pipefail

TARGET="${1:-all}"
# Builder image tag is passed for reference but not used inside the container.
# shellcheck disable=SC2034
BUILDER_IMAGE="${2:-parental-os-cachyos-builder:latest}"

REPO_DIR="${REPO_DIR:-${PARENTAL_OS_ROOT:-/repo}}"
OUT_DIR="${OUT_DIR:-${PARENTAL_OS_OUT:-/out}}"
CACHYOS_STAGING="$OUT_DIR/cachyos/staging"
PACKAGES_OUT="$OUT_DIR/packages"
LOGS_OUT="$OUT_DIR/logs"

log() { printf '%s\n' "$*" >&2; }
die() { log "build-edition: error: $*"; exit 1; }

if [[ -f "$REPO_DIR/scripts/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/scripts/lib/common.sh"
elif [[ "${CACHYOS_CONTAINER_LIB_ONLY:-0}" != "1" ]]; then
  die "common library not found under $REPO_DIR"
fi

if [[ -f "$REPO_DIR/scripts/lib/cachyos.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/scripts/lib/cachyos.sh"
elif [[ "${CACHYOS_CONTAINER_LIB_ONLY:-0}" != "1" ]]; then
  die "CachyOS library not found under $REPO_DIR"
fi

export PARENTAL_OS_ROOT="$REPO_DIR"
export PARENTAL_OS_OUT="$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Build parental-guard once into out/packages/
# ---------------------------------------------------------------------------
build_parental_guard() {
  log "=== Building parental-guard package (once for all editions) ==="
  mkdir -p "$PACKAGES_OUT" "$LOGS_OUT" "$CACHYOS_STAGING/parental-guard"
  "$REPO_DIR/scripts/build-parental-guard-arch.sh" \
    "$CACHYOS_STAGING/parental-guard/src" \
    2>&1 | tee "$LOGS_OUT/parental-guard-arch-makepkg.log"

  # Verify the package was produced.
  local found=0
  shopt -s nullglob
  for f in "$PACKAGES_OUT"/parental-guard-*.pkg.tar.*; do
    found=1
    break
  done
  [[ "$found" -eq 1 ]] || die "parental-guard package not found in $PACKAGES_OUT"
  log "parental-guard package built successfully"
}

# ---------------------------------------------------------------------------
# 2. Create the [parental-os] local pacman repository
# ---------------------------------------------------------------------------
create_local_repo() {
  local repo_dir="$CACHYOS_STAGING/parental-os-repo"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"
  shopt -s nullglob
  for f in "$PACKAGES_OUT"/parental-guard-*.pkg.tar.*; do
    cp -f "$f" "$repo_dir/"
  done
  (cd "$repo_dir" && repo-add parental-os.db.tar.gz parental-guard-*.pkg.tar.*)
  log "=== Created [parental-os] repository at $repo_dir ==="
  # Also embed the repo at /srv/parental-os-repo for the live image.
  local embedded="$CACHYOS_STAGING/parental-os-repo-srv"
  rm -rf "$embedded"
  cp -a "$repo_dir" "$embedded"
  log "Embedded repo copy at $embedded (for /srv/parental-os-repo in live image)"
}

append_parental_repo_stanza() {
  local file="$1"
  local server="${2:-file:///srv/parental-os-repo}"
  [[ -f "$file" ]] || die "pacman config not found: $file"
  if grep -q '^# BEGIN parental-os temporary repository$' "$file"; then
    sed -i \
      "/^# BEGIN parental-os temporary repository$/,/^# END parental-os temporary repository$/ s|^Server = .*|Server = $server|" \
      "$file"
    return 0
  fi
  cat >>"$file" <<'EOF'

# BEGIN parental-os temporary repository
[parental-os]
SigLevel = Optional TrustAll
Server = PLACEHOLDER_PARENTAL_OS_REPO_SERVER
# END parental-os temporary repository
EOF
  sed -i "s|PLACEHOLDER_PARENTAL_OS_REPO_SERVER|$server|" "$file"
}

# archiso copies airootfs/ with --no-preserve=mode and then restores only the
# modes declared in profiledef.sh's file_permissions array; anything absent from
# that array lands as 644. A chmod applied while staging the profile is therefore
# discarded, so every executable we add to the live image must be registered here
# or it silently ships non-executable.
register_parental_file_permissions() {
  local profiledef="$1"
  [[ -f "$profiledef" ]] || die "profiledef.sh not found: $profiledef"
  grep -q '^file_permissions=(' "$profiledef" \
    || die "file_permissions array not found in $profiledef; upstream layout may have changed"
  if grep -q '/usr/local/lib/parental-os/apply-parental-overlay.py' "$profiledef"; then
    return 0
  fi
  sed -i \
    '/^file_permissions=(/a\  ["/usr/local/lib/parental-os/apply-parental-overlay.py"]="0:0:755"' \
    "$profiledef"
  grep -q '/usr/local/lib/parental-os/apply-parental-overlay.py' "$profiledef" \
    || die "failed to register parental-os file permissions in $profiledef"
  log "registered parental-os file permissions in $profiledef"
}

install_live_repo_service() {
  local live_root="$1"
  local service_dir="$live_root/etc/systemd/system"
  local wants_dir="$service_dir/multi-user.target.wants"
  mkdir -p "$service_dir" "$wants_dir"
  cat >"$service_dir/parental-os-repo.service" <<'EOF'
[Unit]
Description=Temporary parental-os package repository
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python -m http.server 8765 --bind 127.0.0.1 --directory /srv/parental-os-repo
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  ln -sfn "/etc/systemd/system/parental-os-repo.service" \
    "$wants_dir/parental-os-repo.service"
}

stage_official_tree() {
  local edition="$1" live_iso_dir="$2" calamares_dir="$3" repo_dir="$4" staged_dir="$5"
  local packages_file calamares_package required_packages pkg unit wants_dir
  packages_file="$(cachyos_metadata_value "$edition" packages_file)" || return 1
  calamares_package="$(cachyos_metadata_value "$edition" calamares_package)" || return 1
  required_packages="$(cachyos_metadata_value "$edition" required_packages)" || return 1

  [[ -d "$live_iso_dir" ]] || die "Live ISO source not found: $live_iso_dir"
  [[ -d "$calamares_dir" ]] || die "Calamares source not found: $calamares_dir"
  [[ -d "$repo_dir" ]] || die "parental-os repository not found: $repo_dir"

  if ! rm -rf "$staged_dir" 2>/dev/null; then
    sudo rm -rf "$staged_dir"
  fi
  mkdir -p "$staged_dir"
  cp -a "$live_iso_dir/." "$staged_dir/"

  [[ -f "$staged_dir/buildiso.sh" ]] || die "official buildiso.sh not found in $staged_dir"
  [[ -f "$staged_dir/archiso/$packages_file" ]] || die "packages file not found: $packages_file"

  register_parental_file_permissions "$staged_dir/archiso/profiledef.sh"

  for pkg in $required_packages; do
    if ! grep -qx "$pkg" "$staged_dir/archiso/$packages_file"; then
      printf '%s\n' "$pkg" >>"$staged_dir/archiso/$packages_file"
    fi
  done

  wants_dir="$staged_dir/archiso/airootfs/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$wants_dir"
  # Arch packages never auto-enable units, and cloud-init ships no pre-created
  # cloud-init.target.wants/ symlinks, so each stage unit has to be wanted by
  # multi-user.target explicitly. Enabling cloud-init.target alone accomplishes
  # nothing: its .wants directory is empty and it is ordered
  # After=multi-user.target, so it cannot pull the stages that must run before
  # login.
  #
  # cloud-init >= 24.3 renamed cloud-init.service to cloud-init-network.service.
  # Naming the obsolete unit leaves a dangling symlink, cloud-init never completes,
  # and there is then no SSH into the live VM -- which is exactly what kept the
  # Calamares install logs unreachable while target integration was being debugged.
  # patch_mkarchiso_post_pacstrap asserts every one of these resolves once the
  # packages are actually installed, so a future rename fails the build instead of
  # silently costing us VM access again.
  # cloud-init-main.service is not optional. From 24.3 cloud-init runs as a single
  # process: the four stage units are only `nc -U` shims that poke sockets under
  # /run/cloud-init/share/, and main (ExecStart=/usr/bin/cloud-init --all-stages) is
  # the sole creator of those sockets. With main disabled every shim connects to
  # nothing, its `| sh` receives nothing, and each oneshot reports success while
  # cloud-init configures nothing at all -- no users, no SSH, no install log.
  for unit in \
    cloud-init-main.service \
    cloud-init-local.service \
    cloud-init-network.service \
    cloud-config.service \
    cloud-final.service \
    cloud-init.target \
    sshd.service \
    qemu-guest-agent.service; do
    ln -sfn "/usr/lib/systemd/system/$unit" "$wants_dir/$unit"
  done

  # Every pacman config that can reach the target must resolve [parental-os] over
  # file:///srv/parental-os-repo. In particular pacman-more.conf: upstream's
  # shellprocess@before-online copies it verbatim over ${ROOT}/etc/pacman.conf
  # immediately before pacstrap, so whatever URL it carries is the URL pacstrap
  # uses. Pointing it at file:// makes the install self-contained and removes any
  # dependency on the ordering of our command relative to upstream's.
  append_parental_repo_stanza "$staged_dir/archiso/pacman.conf"
  append_parental_repo_stanza \
    "$staged_dir/archiso/airootfs/etc/pacman-more.conf"
  local live_pacman_conf="$staged_dir/archiso/airootfs/etc/pacman.conf"
  if [[ ! -f "$live_pacman_conf" ]]; then
    mkdir -p "${live_pacman_conf%/*}"
    cp "$staged_dir/archiso/pacman.conf" "$live_pacman_conf"
  fi
  append_parental_repo_stanza "$live_pacman_conf"

  mkdir -p "$staged_dir/archiso/airootfs/srv/parental-os-repo"
  cp -a "$repo_dir/." "$staged_dir/archiso/airootfs/srv/parental-os-repo/"
  install_live_repo_service "$staged_dir/archiso/airootfs"

  python3 "$REPO_DIR/distros/cachyos/calamares/apply-parental-overlay.py" \
    stage \
    "$calamares_dir" \
    "$staged_dir/archiso/airootfs" \
    "$REPO_DIR/distros/cachyos/calamares/apply-parental-overlay.py" \
    "$calamares_package" >/dev/null

  # Stash Calamares scripts inside the repo so the post-pacstrap hook can
  # copy them to /etc/calamares/scripts/ in the airootfs.  Must be after
  # apply-parental-overlay.py because that transformer creates the scripts.
  if [[ -d "$calamares_dir/scripts" ]]; then
    mkdir -p "$staged_dir/archiso/airootfs/srv/parental-os-repo/scripts"
    cp -a "$calamares_dir/scripts/." "$staged_dir/archiso/airootfs/srv/parental-os-repo/scripts/"
    log "stage_official_tree: stashed Calamares scripts in repo"
  fi

  mkdir -p "$staged_dir/archiso/airootfs/usr/share/calamares"
  cp -a "$calamares_dir/src" "$staged_dir/archiso/airootfs/usr/share/calamares/src"

  # Ship the unattended Calamares config tree for automated target-install tests.
  # Consumed only via `calamares -c`; never wired into a shipping settings file.
  # These are config files, not executables, so archiso's default 0644 restore is
  # the desired mode and no file_permissions entry is needed.
  local unattended_src="$REPO_DIR/distros/cachyos/calamares/unattended"
  if [[ -d "$unattended_src" ]]; then
    mkdir -p "$staged_dir/archiso/airootfs/usr/share/parental-os/unattended"
    cp -a "$unattended_src/." "$staged_dir/archiso/airootfs/usr/share/parental-os/unattended/"
    log "stage_official_tree: shipped unattended Calamares tree"
  else
    die "unattended Calamares tree not found at $unattended_src"
  fi

}

# Patch mkarchiso to run post-pacstrap tasks: copy Calamares module .conf files,
# copy Calamares scripts, copy srv/parental-os-repo, and re-apply the
# [parental-os] stanza.
#
# This is required because archiso copies the profile's airootfs/ into the image
# BEFORE running pacstrap (verifiable in any build log: "Copying custom airootfs
# files..." precedes "Installing packages to ..."). Every path that collides with
# a file owned by cachyos-calamares-next is therefore overwritten by the package,
# so our Calamares configuration has to be re-applied after pacstrap completes.
#
# Kept separate from stage_official_tree because this mutates the *builder
# environment* rather than the staged profile, and only makes sense inside the
# privileged builder container.
patch_mkarchiso_post_pacstrap() {
  local _mkarchiso="${1:-/usr/bin/mkarchiso}"
  [[ -f "$_mkarchiso" ]] || die "mkarchiso not found at $_mkarchiso"
  sudo python3 - "$_mkarchiso" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
HOOK_MARKER = '# parental-os: post-pacstrap tasks'
if HOOK_MARKER in content:
    print(f"{path} already patched; skipping")
    sys.exit(0)
marker = '        env -u TMPDIR pacstrap "${_pacstrap_options[@]}"'
insert = (
    '\n        # parental-os: post-pacstrap tasks\n'
    '        # Copy Calamares module .conf files into airootfs\n'
    '        cp -r "${pacstrap_dir}/usr/share/calamares/src/modules/pacstrap/pacstrap.conf" "${pacstrap_dir}/etc/calamares/modules/pacstrap.conf" 2>/dev/null || true\n'
    '        cp -r "${pacstrap_dir}/usr/share/calamares/src/modules/shellprocess/shellprocess-before-online.conf" "${pacstrap_dir}/etc/calamares/modules/shellprocess-before-online.conf" 2>/dev/null || true\n'
    '        cp -r "${pacstrap_dir}/usr/share/calamares/src/modules/services-systemd/services-systemd.conf" "${pacstrap_dir}/etc/calamares/modules/services-systemd.conf" 2>/dev/null || true\n'
    '        cp -r "${pacstrap_dir}/usr/share/calamares/src/modules/shellprocess/shellprocess_cleanup_calamares.conf" "${pacstrap_dir}/etc/calamares/modules/shellprocess_cleanup_calamares.conf" 2>/dev/null || true\n'
    '        # Copy Calamares scripts and repo dir into airootfs\n'
    '        _parental_repo_src="${pacstrap_dir}/srv/parental-os-repo"\n'
    '        if [[ ! -d "$_parental_repo_src" ]]; then\n'
    '          _parental_repo_src="${work_dir}/archiso/airootfs/srv/parental-os-repo"\n'
    '        fi\n'
    '        if [[ -d "$_parental_repo_src" ]]; then\n'
    '          mkdir -p "${pacstrap_dir}/srv"\n'
    '          cp -a "$_parental_repo_src" "${pacstrap_dir}/srv/parental-os-repo" 2>/dev/null || true\n'
    '          mkdir -p "${pacstrap_dir}/etc/calamares/scripts"\n'
    '          cp -r "${pacstrap_dir}/srv/parental-os-repo/scripts/." "${pacstrap_dir}/etc/calamares/scripts/" 2>/dev/null || true\n'
    '        fi\n'
    '        # Re-apply [parental-os] stanza to pacman.conf\n'
    '        printf "\\n# BEGIN parental-os temporary repository\\n[parental-os]\\nSigLevel = Optional TrustAll\\nServer = file:///srv/parental-os-repo\\n# END parental-os temporary repository\\n" >> "${pacstrap_dir}/etc/pacman.conf"\n'
    '        printf "\\n# BEGIN parental-os temporary repository\\n[parental-os]\\nSigLevel = Optional TrustAll\\nServer = file:///srv/parental-os-repo\\n# END parental-os temporary repository\\n" >> "${pacstrap_dir}/etc/pacman-more.conf"\n'
    '        # parental-os: the enablement symlinks were created while staging the\n'
    '        # profile, before any package existed to point at. Now that pacstrap has\n'
    '        # installed them, assert every target actually resolves. A stale unit name\n'
    '        # (cloud-init renamed cloud-init.service to cloud-init-network.service in\n'
    '        # 24.3) otherwise leaves a dangling symlink that costs SSH access to the\n'
    '        # live VM, and with it any ability to read the Calamares install log.\n'
    '        for _parental_unit in \\\n'
    '          cloud-init-main.service cloud-init-local.service \\\n'
    '          cloud-init-network.service cloud-config.service \\\n'
    '          cloud-final.service cloud-init.target \\\n'
    '          sshd.service qemu-guest-agent.service; do\n'
    '          if [[ ! -e "${pacstrap_dir}/usr/lib/systemd/system/${_parental_unit}" ]]; then\n'
    '            printf "parental-os: FATAL: unit %s is not present in the image; its multi-user.target.wants symlink would dangle\\n" "$_parental_unit" >&2\n'
    '            exit 1\n'
    '          fi\n'
    '        done\n'
    '        # parental-os: a unit existing is not the same as cloud-init working.\n'
    '        # The stage units are socket shims; whichever unit runs cloud-init with\n'
    '        # --all-stages is what creates the sockets they poke. If those shims are\n'
    '        # enabled without their provider, every one of them reports success while\n'
    '        # configuring nothing. Derive the relationship from the image so this\n'
    '        # keeps holding if upstream changes the model again.\n'
    '        _parental_units_dir="${pacstrap_dir}/usr/lib/systemd/system"\n'
    '        _parental_wants="${pacstrap_dir}/etc/systemd/system/multi-user.target.wants"\n'
    '        _parental_shims=""\n'
    '        for _parental_link in "$_parental_wants"/cloud-init*.service \\\n'
    '                              "$_parental_wants"/cloud-config.service \\\n'
    '                              "$_parental_wants"/cloud-final.service; do\n'
    '          [[ -L "$_parental_link" ]] || continue\n'
    '          _parental_u="$(basename "$_parental_link")"\n'
    '          if grep -qE "/run/cloud-init/.*[.]sock" "$_parental_units_dir/$_parental_u" 2>/dev/null; then\n'
    '            _parental_shims="$_parental_shims $_parental_u"\n'
    '          fi\n'
    '        done\n'
    '        if [[ -n "$_parental_shims" ]]; then\n'
    '          _parental_provider="$(grep -lE "ExecStart=.*cloud-init .*--all-stages" "$_parental_units_dir"/cloud-init*.service 2>/dev/null | head -1)"\n'
    '          if [[ -z "$_parental_provider" ]]; then\n'
    '            printf "parental-os: FATAL: cloud-init stage shims present but no --all-stages driver found; upstream model changed\\n" >&2\n'
    '            exit 1\n'
    '          fi\n'
    '          _parental_provider="$(basename "$_parental_provider")"\n'
    '          if [[ ! -L "$_parental_wants/$_parental_provider" ]]; then\n'
    '            printf "parental-os: FATAL: cloud-init shims%s are enabled but their socket provider %s is not; cloud-init would silently configure nothing\\n" "$_parental_shims" "$_parental_provider" >&2\n'
    '            exit 1\n'
    '          fi\n'
    '        fi\n'
)
last_idx = content.rfind(marker)
if last_idx == -1:
    # Fail closed. Continuing here would produce an ISO whose Calamares
    # configuration was silently reverted by the package install, i.e. an image
    # that installs a target with no parental-guard while the build reports
    # success.
    print(
        f"ERROR: pacstrap invocation not found in {path}; "
        "upstream mkarchiso layout may have changed",
        file=sys.stderr,
    )
    sys.exit(1)
new_content = content[:last_idx + len(marker)] + insert + content[last_idx + len(marker):]
with open(path, 'w') as f:
    f.write(new_content)
print(f"Patched {path} with parental-os post-pacstrap tasks")
PYEOF
}

run_official_build() {
  local edition="$1" staged_dir="$2"
  local profile_name
  profile_name="$(cachyos_metadata_value "$edition" profile_name)" || return 1
  [[ -x "$staged_dir/buildiso.sh" ]] || die "official buildiso.sh is not executable: $staged_dir/buildiso.sh"
  (cd "$staged_dir" && USER=builder \./buildiso\.sh -p "$profile_name")
}

clean_edition_artifacts() {
  local edition_out="$1"
  local generated_artifacts
  mkdir -p "$edition_out"
  generated_artifacts=(
    "$edition_out"/*.iso \
    "$edition_out"/*.iso.sha256 \
    "$edition_out"/pkglist.x86_64.txt \
    "$edition_out"/build.log
  )
  if ! rm -rf "${generated_artifacts[@]}" 2>/dev/null; then
    sudo rm -rf "${generated_artifacts[@]}"
  fi
}

# ---------------------------------------------------------------------------
# 3. Verify checked-out SHAs match provenance for an edition
# ---------------------------------------------------------------------------
verify_provenance() {
  local edition="$1"
  local stage="$CACHYOS_STAGING/$edition"
  local prov="$OUT_DIR/cachyos/$edition/provenance.json"

  [[ -f "$prov" ]] || die "provenance not found for $edition: $prov"
  cachyos_provenance_validate "$prov" || die "provenance validation failed for $edition"

  local live_iso_sha calamares_sha pkgbuilds_sha
  live_iso_sha="$(jq -r '.live_iso_sha' "$prov")"
  calamares_sha="$(jq -r '.calamares_sha' "$prov")"
  pkgbuilds_sha="$(jq -r '.pkgbuilds_sha' "$prov")"

  # Verify the checked-out Live ISO SHA matches provenance.
  local checked
  checked="$(git -C "$stage/cachyos-live-iso" rev-parse HEAD 2>/dev/null || true)"
  [[ "$checked" = "$live_iso_sha" ]] \
    || die "Live ISO SHA mismatch for $edition: provenance=$live_iso_sha checked=$checked"

  checked="$(git -C "$stage/cachyos-calamares" rev-parse HEAD 2>/dev/null || true)"
  [[ "$checked" = "$calamares_sha" ]] \
    || die "Calamares SHA mismatch for $edition: provenance=$calamares_sha checked=$checked"

  checked="$(git -C "$stage/cachyos-pkgbuilds" rev-parse HEAD 2>/dev/null || true)"
  [[ "$checked" = "$pkgbuilds_sha" ]] \
    || die "PKGBUILDS SHA mismatch for $edition: provenance=$pkgbuilds_sha checked=$checked"

  log "=== Provenance verified for $edition (SHAs match checked-out sources) ==="
}

# ---------------------------------------------------------------------------
# 4. Stage the official profile and add parental integration
# ---------------------------------------------------------------------------
stage_profile() {
  local edition="$1"
  local stage="$CACHYOS_STAGING/$edition"
  local live_iso_dir="$stage/cachyos-live-iso"
  local calamares_dir="$stage/cachyos-calamares"
  local profile_stage="$stage/profile-work"

  log "=== Staging profile for $edition ==="
  stage_official_tree "$edition" "$live_iso_dir" "$calamares_dir" \
    "$CACHYOS_STAGING/parental-os-repo-srv" "$profile_stage"

  patch_mkarchiso_post_pacstrap

  # Place the local repo at the container path consumed by the staged profile.
  cp -a "$CACHYOS_STAGING/parental-os-repo-srv/"* /srv/parental-os-repo/
  chmod -R 755 /srv/parental-os-repo

  log "Profile staged at $profile_stage for $edition"
}

# ---------------------------------------------------------------------------
# 5. Run the upstream CachyOS build to produce the ISO
# ---------------------------------------------------------------------------
build_iso() {
  local edition="$1"
  local stage="$CACHYOS_STAGING/$edition"
  local profile_stage="$stage/profile-work"
  local edition_out="$OUT_DIR/cachyos/$edition"
  local iso_basename profile_name
  iso_basename="$(cachyos_metadata_value "$edition" iso_basename)"
  profile_name="$(cachyos_metadata_value "$edition" profile_name)"

  log "=== Building ISO for $edition ==="
  mkdir -p "$edition_out"
  clean_edition_artifacts "$edition_out"

  run_official_build "$edition" "$profile_stage" \
    2>&1 | tee "$edition_out/build.log" "$LOGS_OUT/build-cachyos-$edition.log"

  # Normalize the ISO name to our parental-os basename.
  shopt -s nullglob
  local built_isos=("$profile_stage/out/$profile_name"/*.iso)
  local f dest
  for f in "${built_isos[@]}"; do
    dest="$edition_out/$(basename "$f")"
    cp -f "$f" "$dest"
    if [[ "$(basename "$dest")" != "$iso_basename"*.iso ]]; then
      mv -f "$dest" "$edition_out/${iso_basename}.iso"
    fi
  done

  # Copy the package list.
  if [[ -f "$profile_stage/build/iso/arch/pkglist.x86_64.txt" ]]; then
    cp -f "$profile_stage/build/iso/arch/pkglist.x86_64.txt" \
      "$edition_out/pkglist.x86_64.txt"
  fi

  # Generate SHA256 for the ISO.
  shopt -s nullglob
  for f in "$edition_out"/*.iso; do
    (cd "$edition_out" && sha256sum "$(basename "$f")" > "$(basename "$f")".sha256)
  done

  cachyos_validate_artifact_set "$edition" "$edition_out" \
    || die "artifact validation failed for $edition"

  log "=== ISO build complete for $edition ==="
  log "Artifacts in $edition_out:"
  ls -la "$edition_out" >&2 || true
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
  [[ -d "$REPO_DIR" ]] || die "repo not mounted at $REPO_DIR"
  [[ -d "$OUT_DIR" ]] || die "out not mounted at $OUT_DIR"

  command -v jq >/dev/null 2>&1 || die "jq not available in container"

  # Build parental-guard once, then create the local repo.
  build_parental_guard
  create_local_repo

  # Dispatch editions.
  local editions
  editions="$(cachyos_dispatch_editions "$TARGET")" \
    || die "unknown target: $TARGET (use desktop|handheld|all)"

  local ed
  for ed in $editions; do
    log ""
    log "############################################"
    log "# Building edition: $ed"
    log "############################################"
    verify_provenance "$ed"
    stage_profile "$ed"
    build_iso "$ed"
  done

  log ""
  log "=== All editions built successfully ==="
  log "Target was: $TARGET"
}

if [[ "${CACHYOS_CONTAINER_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
