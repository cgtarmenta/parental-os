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
  local packages_file calamares_package required_packages pkg service wants_dir
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
  for pkg in $required_packages; do
    if ! grep -qx "$pkg" "$staged_dir/archiso/$packages_file"; then
      printf '%s\n' "$pkg" >>"$staged_dir/archiso/$packages_file"
    fi
  done

  wants_dir="$staged_dir/archiso/airootfs/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$wants_dir"
  for service in \
    cloud-init-local.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service \
    sshd.service \
    qemu-guest-agent.service; do
    ln -sfn "/usr/lib/systemd/system/$service" "$wants_dir/$service"
  done

  append_parental_repo_stanza "$staged_dir/archiso/pacman.conf"
  append_parental_repo_stanza \
    "$staged_dir/archiso/airootfs/etc/pacman-more.conf" \
    "http://127.0.0.1:8765"
  local live_pacman_conf="$staged_dir/archiso/airootfs/etc/pacman.conf"
  if [[ ! -f "$live_pacman_conf" ]]; then
    mkdir -p "${live_pacman_conf%/*}"
    cp "$staged_dir/archiso/pacman.conf" "$live_pacman_conf"
  fi
  append_parental_repo_stanza "$live_pacman_conf" "http://127.0.0.1:8765"

  mkdir -p "$staged_dir/archiso/airootfs/srv/parental-os-repo"
  cp -a "$repo_dir/." "$staged_dir/archiso/airootfs/srv/parental-os-repo/"
  install_live_repo_service "$staged_dir/archiso/airootfs"

  python3 "$REPO_DIR/distros/cachyos/calamares/apply-parental-overlay.py" \
    stage \
    "$calamares_dir" \
    "$staged_dir/archiso/airootfs" \
    "$REPO_DIR/distros/cachyos/calamares/apply-parental-overlay.py" \
    "$calamares_package" >/dev/null

  mkdir -p "$staged_dir/archiso/airootfs/usr/share/calamares"
  cp -a "$calamares_dir/src" "$staged_dir/archiso/airootfs/usr/share/calamares/src"

  # Patch util-iso.sh to inject the parental-os Calamares module files into
  # the airootfs after mkarchiso finishes its pacstrap phase. mkarchiso
  # copies profile/archiso/airootfs/ to the pacstrap dir both before and
  # after pacstrap; the post-pacstrap copy would overwrite our patched
  # files — but pacstrap itself fails with "exists in filesystem" if the
  # files are present pre-pacstrap.  So we hook into mkarchiso after
  # _make_customize_airootfs to copy the patched module files from
  # /usr/share/calamares/src/modules/ (which survived pacstrap because it
  # is not shipped by cachyos-calamares-next) into /etc/calamares/modules/.
  local util_iso="$staged_dir/util-iso.sh"
  if [[ -f "$util_iso" ]]; then
    if ! grep -q 'parental-os: copy Calamares module files' "$util_iso" 2>/dev/null; then
      python3 - "$util_iso" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Find the line in modify_mkarchiso that removes the keyring timer.
# We insert our copy commands right after it.
pattern = (
    r'(rm -f "\$\{pacstrap_dir\}/usr/lib/systemd/system/timers\.target\.wants'
    r'/archlinux-keyring-wkd-sync\.timer")'
)
replacement = (
    r'\1\n'
    r'\t# parental-os: copy Calamares module files into airootfs after pacstrap\n'
    r'\tcp -r "${pacstrap_dir}/usr/share/calamares/src/modules/pacstrap/pacstrap.conf"'
    r' "${pacstrap_dir}/etc/calamares/modules/pacstrap.conf" 2>/dev/null || true\n'
    r'\tcp -r "${pacstrap_dir}/usr/share/calamares/src/modules/shellprocess/shellprocess-before-online.conf"'
    r' "${pacstrap_dir}/etc/calamares/modules/shellprocess-before-online.conf" 2>/dev/null || true\n'
    r'\tcp -r "${pacstrap_dir}/usr/share/calamares/src/modules/services-systemd/services-systemd.conf"'
    r' "${pacstrap_dir}/etc/calamares/modules/services-systemd.conf" 2>/dev/null || true\n'
    r'\tcp -r "${pacstrap_dir}/usr/share/calamares/src/modules/shellprocess/shellprocess_cleanup_calamares.conf"'
    r' "${pacstrap_dir}/etc/calamares/modules/shellprocess_cleanup_calamares.conf" 2>/dev/null || true'
)
new_content = re.sub(pattern, replacement, content, count=1)
if new_content == content:
    print(f"WARNING: pattern not found in {path}; mkarchiso may have changed layout")
else:
    with open(path, 'w') as f:
        f.write(new_content)
    print(f"Patched {path} with parental-os Calamares module copy hook")
PYEOF
    else
      log "$util_iso already patched with parental-os Calamares module copy hook"
    fi
  else
    log "warning: $util_iso not found; cannot patch mkarchiso for Calamares module files"
  fi
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
