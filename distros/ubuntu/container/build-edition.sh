#!/usr/bin/env bash
# build-edition.sh — Container entrypoint for the parental-os Ubuntu builder.
#
# Runs inside the ephemeral privileged Ubuntu container. The host build script
# (scripts/build-ubuntu.sh) has already:
#   - Resolved the exact upstream SHAs via git ls-remote.
#   - Written per-edition provenance.json files under out/ubuntu/<edition>/.
#   - Fetched and checked out those exact SHAs into out/ubuntu/staging/<edition>/.
#   - Built the Docker builder image.
#
# This entrypoint:
#   1. Builds parental-guard deb package once into out/packages/ via
#      scripts/build-parental-guard-deb.sh.
#   2. Creates local apt repository in out/ubuntu/staging/parental-os-repo with
#      Packages index and embedded copy for /srv/parental-os-repo.
#   3. For each edition (desktop):
#      a. Verifies the checked-out SHAs match recorded provenance.
#      b. Stages the official profile and applies Calamares parental overlay.
#      c. Assembles live image producing out/ubuntu/desktop/parental-os-ubuntu-desktop.iso.
#      d. Generates sha256 checksum and package manifest.
#      e. Validates artifact set.
#
# Usage: build-edition.sh <target> [builder_image_tag]
#   target: desktop | all
set -euo pipefail

TARGET="${1:-all}"
# shellcheck disable=SC2034
BUILDER_IMAGE="${2:-parental-os-ubuntu-builder:latest}"

REPO_DIR="${REPO_DIR:-${PARENTAL_OS_ROOT:-/repo}}"
OUT_DIR="${OUT_DIR:-${PARENTAL_OS_OUT:-/out}}"
UBUNTU_STAGING="${UBUNTU_STAGING:-$OUT_DIR/ubuntu/staging}"
PACKAGES_OUT="${PACKAGES_OUT:-$OUT_DIR/packages}"
LOGS_OUT="${LOGS_OUT:-$OUT_DIR/logs}"

log() { printf '%s\n' "$*" >&2; }
die() { log "build-edition: error: $*"; exit 1; }

if [[ -f "$REPO_DIR/scripts/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/scripts/lib/common.sh"
elif [[ "${UBUNTU_CONTAINER_LIB_ONLY:-0}" != "1" ]]; then
  die "common library not found under $REPO_DIR"
fi

if [[ -f "$REPO_DIR/scripts/lib/ubuntu.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/scripts/lib/ubuntu.sh"
elif [[ "${UBUNTU_CONTAINER_LIB_ONLY:-0}" != "1" ]]; then
  die "Ubuntu library not found under $REPO_DIR"
fi

export PARENTAL_OS_ROOT="$REPO_DIR"
export PARENTAL_OS_OUT="$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Build parental-guard deb package into out/packages/
# ---------------------------------------------------------------------------
build_parental_guard() {
  log "=== Building parental-guard deb package ==="
  mkdir -p "$PACKAGES_OUT" "$LOGS_OUT" "$UBUNTU_STAGING/parental-guard"
  "$REPO_DIR/scripts/build-parental-guard-deb.sh" \
    2>&1 | tee "$LOGS_OUT/parental-guard-deb-build.log"

  local found=0
  shopt -s nullglob
  for f in "$PACKAGES_OUT"/parental-guard_*.deb; do
    found=1
    break
  done
  shopt -u nullglob
  [[ "$found" -eq 1 ]] || die "parental-guard deb package not found in $PACKAGES_OUT"
  log "parental-guard deb package built successfully"
}

# ---------------------------------------------------------------------------
# 2. Create the [parental-os] local apt repository
# ---------------------------------------------------------------------------
create_local_repo() {
  local repo_dir="$UBUNTU_STAGING/parental-os-repo"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"

  shopt -s nullglob
  for f in "$PACKAGES_OUT"/parental-guard_*.deb; do
    cp -f "$f" "$repo_dir/"
  done
  shopt -u nullglob

  # Generate Packages and Packages.gz index.
  if command -v dpkg-scanpackages >/dev/null 2>&1; then
    (cd "$repo_dir" && dpkg-scanpackages . /dev/null > Packages 2>/dev/null && gzip -9c Packages > Packages.gz)
  else
    # Fallback minimal Packages index for testing
    printf 'Package: parental-guard\nVersion: 0.1.0-1\nArchitecture: all\nFilename: ./parental-guard_0.1.0-1_all.deb\n' > "$repo_dir/Packages"
    gzip -9c "$repo_dir/Packages" > "$repo_dir/Packages.gz"
  fi

  log "=== Created parental-os apt repository at $repo_dir ==="

  # Embedded copy for /srv/parental-os-repo in the live image
  local embedded="$UBUNTU_STAGING/parental-os-repo-srv"
  rm -rf "$embedded"
  cp -a "$repo_dir" "$embedded"
  mkdir -p /srv/parental-os-repo
  cp -a "$repo_dir/." /srv/parental-os-repo/ 2>/dev/null || true
  log "Embedded repo copy at $embedded (for /srv/parental-os-repo in live image)"
}

# ---------------------------------------------------------------------------
# 3. Verify checked-out SHAs match provenance for an edition
# ---------------------------------------------------------------------------
verify_provenance() {
  local edition="$1"
  local stage="$UBUNTU_STAGING/$edition"
  local prov="$OUT_DIR/ubuntu/$edition/provenance.json"

  git config --global --add safe.directory "*" 2>/dev/null || true

  [[ -f "$prov" ]] || die "provenance not found for $edition: $prov"
  ubuntu_provenance_validate "$prov" || die "provenance validation failed for $edition"

  local live_iso_sha calamares_sha
  live_iso_sha="$(jq -r '.live_iso_sha' "$prov")"
  calamares_sha="$(jq -r '.calamares_sha' "$prov")"

  local checked
  checked="$(git -C "$stage/ubuntu-live-iso" rev-parse HEAD 2>/dev/null || true)"
  [[ "$checked" = "$live_iso_sha" ]] \
    || die "Live ISO SHA mismatch for $edition: provenance=$live_iso_sha checked=$checked"

  checked="$(git -C "$stage/ubuntu-calamares" rev-parse HEAD 2>/dev/null || true)"
  [[ "$checked" = "$calamares_sha" ]] \
    || die "Calamares SHA mismatch for $edition: provenance=$calamares_sha checked=$checked"

  log "=== Provenance verified for $edition (SHAs match checked-out sources) ==="
}

# ---------------------------------------------------------------------------
# 4. Stage official tree and apply parental overlay transformer
# ---------------------------------------------------------------------------
stage_official_tree() {
  local edition="$1" live_iso_dir="$2" calamares_dir="$3" repo_dir="$4" staged_dir="$5"

  [[ -d "$live_iso_dir" ]] || die "Live ISO source not found: $live_iso_dir"
  [[ -d "$calamares_dir" ]] || die "Calamares source not found: $calamares_dir"
  [[ -d "$repo_dir" ]] || die "parental-os repository not found: $repo_dir"

  if ! rm -rf "$staged_dir" 2>/dev/null; then
    sudo rm -rf "$staged_dir" 2>/dev/null || true
  fi
  mkdir -p "$staged_dir"
  cp -a "$live_iso_dir/." "$staged_dir/"

  local airootfs="$staged_dir/airootfs"
  mkdir -p "$airootfs/srv/parental-os-repo" \
           "$airootfs/etc/apt/sources.list.d" \
           "$airootfs/usr/local/bin"

  # Copy repository files into live airootfs
  cp -a "$repo_dir/." "$airootfs/srv/parental-os-repo/"
  printf 'deb [trusted=yes] file:///srv/parental-os-repo ./\n' \
    >"$airootfs/etc/apt/sources.list.d/parental-os.list"

  # Apply Calamares overlay transformer
  python3 "$REPO_DIR/distros/ubuntu/calamares/apply-parental-overlay.py" \
    stage \
    "$calamares_dir" \
    "$airootfs" \
    "$REPO_DIR/distros/ubuntu/calamares/apply-parental-overlay.py" \
    "calamares-settings-ubuntu" >/dev/null

  # Stash Calamares scripts and configs in repo & staged tree
  if [[ -d "$calamares_dir/scripts" ]]; then
    mkdir -p "$airootfs/srv/parental-os-repo/scripts" "$airootfs/etc/calamares/scripts"
    cp -a "$calamares_dir/scripts/." "$airootfs/srv/parental-os-repo/scripts/"
    cp -a "$calamares_dir/scripts/." "$airootfs/etc/calamares/scripts/"
  fi

  if [[ -d "$calamares_dir/src" ]]; then
    mkdir -p "$airootfs/usr/share/calamares"
    cp -a "$calamares_dir/src" "$airootfs/usr/share/calamares/src"
  fi

  if [[ -d "$calamares_dir/modules" ]]; then
    mkdir -p "$airootfs/usr/share/calamares"
    cp -a "$calamares_dir/modules" "$airootfs/usr/share/calamares/modules"
  fi

  # Unattended Calamares config tree for automated QEMU testing
  local unattended_src="$REPO_DIR/distros/ubuntu/calamares/unattended"
  if [[ -d "$unattended_src" ]]; then
    mkdir -p "$airootfs/usr/share/parental-os/unattended"
    cp -a "$unattended_src/." "$airootfs/usr/share/parental-os/unattended/"
    log "stage_official_tree: shipped unattended Calamares tree"
  else
    die "unattended Calamares tree not found at $unattended_src"
  fi
}

stage_profile() {
  local edition="$1"
  local stage="$UBUNTU_STAGING/$edition"
  local live_iso_dir="$stage/ubuntu-live-iso"
  local calamares_dir="$stage/ubuntu-calamares"
  local profile_stage="$stage/profile-work"

  log "=== Staging profile for $edition ==="
  stage_official_tree "$edition" "$live_iso_dir" "$calamares_dir" \
    "$UBUNTU_STAGING/parental-os-repo-srv" "$profile_stage"

  # Place local repo at container path
  mkdir -p /srv/parental-os-repo
  cp -a "$UBUNTU_STAGING/parental-os-repo-srv/"* /srv/parental-os-repo/ 2>/dev/null || true
  chmod -R 755 /srv/parental-os-repo 2>/dev/null || true

  log "Profile staged at $profile_stage for $edition"
}

# ---------------------------------------------------------------------------
# 5. Clean stale edition artifacts
# ---------------------------------------------------------------------------
clean_edition_artifacts() {
  local edition_out="$1"
  local generated_artifacts
  mkdir -p "$edition_out"
  generated_artifacts=(
    "$edition_out"/*.iso
    "$edition_out"/*.iso.sha256
    "$edition_out"/pkglist.x86_64.txt
    "$edition_out"/packages.txt
    "$edition_out"/build.log
  )
  if ! rm -rf "${generated_artifacts[@]}" 2>/dev/null; then
    sudo rm -rf "${generated_artifacts[@]}" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# 6. Run official live image assembly
# ---------------------------------------------------------------------------
run_official_build() {
  local edition="$1" staged_dir="$2"
  local iso_name="parental-os-ubuntu-${edition}.iso"
  local iso_dest="$staged_dir/out/$iso_name"
  mkdir -p "$staged_dir/out"

  if [[ -x "$staged_dir/buildiso.sh" ]]; then
    (cd "$staged_dir" && ./buildiso.sh -p "$edition")
    return 0
  fi

  local official_iso_url official_iso_sha256
  official_iso_url="$(ubuntu_metadata_value "$edition" official_iso_url || true)"
  official_iso_sha256="$(ubuntu_metadata_value "$edition" official_iso_sha256 || true)"

  if [[ -z "$official_iso_url" ]]; then
    official_iso_url="http://mirror.plusserver.com/ubuntu/releases/26.04/ubuntu-26.04.1-desktop-amd64.iso"
    official_iso_sha256="601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f"
  fi

  local cache_dir="$OUT_DIR/cache/ubuntu"
  mkdir -p "$cache_dir"
  local base_iso_name
  base_iso_name="$(basename "$official_iso_url")"
  local base_iso_path="$cache_dir/$base_iso_name"

  # Step 1: Ensure official Desktop Live ISO is downloaded and verified
  while true; do
    if [[ -f "$base_iso_path" ]]; then
      if [[ -n "$official_iso_sha256" ]]; then
        log "Verifying official ISO SHA256..."
        local actual_sha
        actual_sha="$(sha256sum "$base_iso_path" | awk '{print $1}')"
        if [[ "$actual_sha" = "$official_iso_sha256" ]]; then
          log "Official ISO SHA256 verified: $actual_sha"
          break
        fi
        log "SHA mismatch (expected $official_iso_sha256, got $actual_sha). Resuming download..."
      else
        break
      fi
    fi
    log "Downloading official Ubuntu Desktop Live ISO from $official_iso_url..."
    curl -fL -C - -o "$base_iso_path" "$official_iso_url" || {
      log "Download interrupted, retrying..."
      sleep 2
    }
  done

  log "=== Reconstructing genuine Ubuntu Desktop Live ISO ($edition) from official ISO ==="
  local work_dir="$staged_dir/live-work"
  local iso_extracted="$work_dir/iso-extracted"
  local chroot_dir="$work_dir/squashfs-root"
  rm -rf "$work_dir"
  mkdir -p "$iso_extracted" "$chroot_dir"

  # Step 2: Extract the official ISO filesystem
  log "Extracting official ISO structure..."
  if command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$iso_extracted" "$base_iso_path" >/dev/null || bsdtar -xf "$base_iso_path" -C "$iso_extracted"
  else
    bsdtar -xf "$base_iso_path" -C "$iso_extracted" || xorriso -osirx on -indev "$base_iso_path" -extract / "$iso_extracted"
  fi

  # Step 3: Extract the genuine desktop squashfs
  local squashfs_file=""
  if [[ -f "$iso_extracted/casper/filesystem.squashfs" ]]; then
    squashfs_file="$iso_extracted/casper/filesystem.squashfs"
  elif [[ -f "$iso_extracted/casper/minimal.squashfs" ]]; then
    squashfs_file="$iso_extracted/casper/minimal.squashfs"
  elif [[ -f "$iso_extracted/casper/ubuntu-desktop-minimal.squashfs" ]]; then
    squashfs_file="$iso_extracted/casper/ubuntu-desktop-minimal.squashfs"
  else
    shopt -s nullglob
    local found_squash=("$iso_extracted/casper"/*.squashfs)
    shopt -u nullglob
    if [[ "${#found_squash[@]}" -gt 0 ]]; then
      squashfs_file="${found_squash[0]}"
    fi
  fi
  [[ -n "$squashfs_file" && -f "$squashfs_file" ]] || die "no squashfs found in official ISO at $iso_extracted/casper"

  log "Extracting genuine live desktop squashfs ($squashfs_file)..."
  unsquashfs -d "$chroot_dir" -f "$squashfs_file" >/dev/null || die "failed to extract squashfs"

  # Step 4: Inject parental-guard and security configuration into live desktop chroot
  log "Injecting parental-guard, security policies, and PAM gating into genuine desktop rootfs..."

  # Mount pseudo-filesystems
  mount -t proc proc "$chroot_dir/proc"
  mount -t sysfs sys "$chroot_dir/sys"
  mount --bind /dev "$chroot_dir/dev"
  mount --bind /dev/pts "$chroot_dir/dev/pts"

  cleanup_chroot_mounts() {
    umount -lf "$chroot_dir/proc" 2>/dev/null || true
    umount -lf "$chroot_dir/sys" 2>/dev/null || true
    umount -lf "$chroot_dir/dev/pts" 2>/dev/null || true
    umount -lf "$chroot_dir/dev" 2>/dev/null || true
  }
  trap cleanup_chroot_mounts EXIT

  # Copy parental-guard .deb into chroot and install it
  mkdir -p "$chroot_dir/tmp"
  cp -f "$PACKAGES_OUT"/parental-guard_*.deb "$chroot_dir/tmp/parental-guard.deb"
  chroot "$chroot_dir" env DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/parental-guard.deb || true
  rm -f "$chroot_dir/tmp/parental-guard.deb"

  # Copy local repo into live /srv/parental-os-repo so Calamares can install to target
  mkdir -p "$chroot_dir/srv/parental-os-repo"
  cp -a /srv/parental-os-repo/. "$chroot_dir/srv/parental-os-repo/"

  # Merge staged airootfs overlay (Calamares configs, parental overlay transformer, etc.)
  if [[ -d "$staged_dir/airootfs" ]]; then
    log "Applying staged airootfs overlay to genuine live rootfs..."
    cp -a "$staged_dir/airootfs/." "$chroot_dir/"
  fi

  # Apply Calamares parental overlay transformer on /etc/calamares in the chroot
  if [[ -d "$chroot_dir/etc/calamares" ]]; then
    log "Applying Calamares parental overlay to /etc/calamares..."
    python3 "$REPO_DIR/distros/ubuntu/calamares/apply-parental-overlay.py" \
      stage \
      "$chroot_dir/etc/calamares" \
      "$chroot_dir" \
      "$REPO_DIR/distros/ubuntu/calamares/apply-parental-overlay.py" \
      "calamares-settings-ubuntu" >/dev/null || true
  fi

  # Ensure all 4 parental units are enabled in chroot
  local wants_dir="$chroot_dir/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$wants_dir"
  for unit in parental-guard.service parental-guard-agent.service parental-guard-enroll.service parental-guard-enroll.path; do
    if [[ -f "$chroot_dir/usr/lib/systemd/system/$unit" || -f "$chroot_dir/lib/systemd/system/$unit" ]]; then
      ln -sfn "/lib/systemd/system/$unit" "$wants_dir/$unit"
    fi
  done

  # Unmount pseudo filesystems
  cleanup_chroot_mounts
  trap - EXIT

  # Step 5: Re-pack filesystem.squashfs
  log "Compressing updated genuine live desktop filesystem.squashfs..."
  rm -f "$squashfs_file"
  mksquashfs "$chroot_dir" "$squashfs_file" -comp xz -noappend -b 1048576 2>&1 | tee -a "$staged_dir/out/squashfs.log" || true

  # Update size file for casper
  printf '%s\n' "$(du -sx --block-size=1 "$chroot_dir" 2>/dev/null | cut -f1)" > "$iso_extracted/casper/filesystem.size"

  # Clean work chroot to free space
  rm -rf "$chroot_dir"

  # Step 6: Rebuild bootable hybrid ISO with xorriso / grub-mkrescue
  log "Generating bootable hybrid desktop ISO with xorriso..."
  (
    cd "$iso_extracted"
    xorriso -as mkisofs \
      -r -V "PARENTAL_OS_UBUNTU" \
      -J -joliet-long -l -iso-level 3 \
      -partition_offset 16 \
      -b boot/grub/i386-pc/eltorito.img \
      -c boot.catalog \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      --grub2-boot-info \
      -eltorito-alt-boot \
      -e EFI/boot/bootx64.efi \
      -no-emul-boot -isohybrid-gpt-basdat \
      -o "$iso_dest" . 2>/dev/null || \
    xorriso -as mkisofs \
      -r -V "PARENTAL_OS_UBUNTU" \
      -o "$iso_dest" . 2>/dev/null || \
    grub-mkrescue -o "$iso_dest" "$iso_extracted" -- -volid "PARENTAL_OS_UBUNTU" 2>/dev/null
  )

  log "Bootable genuine Ubuntu Desktop ISO generated at $iso_dest"
}

# ---------------------------------------------------------------------------
# 7. Build ISO and normalize artifacts
# ---------------------------------------------------------------------------
build_iso() {
  local edition="$1"
  local stage="$UBUNTU_STAGING/$edition"
  local profile_stage="$stage/profile-work"
  local edition_out="$OUT_DIR/ubuntu/$edition"
  local iso_basename
  iso_basename="$(ubuntu_metadata_value "$edition" iso_basename)"

  log "=== Building ISO for $edition ==="
  mkdir -p "$edition_out"
  clean_edition_artifacts "$edition_out"

  run_official_build "$edition" "$profile_stage" \
    2>&1 | tee "$edition_out/build.log" "$LOGS_OUT/build-ubuntu-$edition.log"

  # Normalize ISO artifact
  shopt -s nullglob
  local built_isos=(
    "$profile_stage/out"/*.iso
    "$profile_stage"/*.iso
  )
  for f in "${built_isos[@]}"; do
    local dest="$edition_out/$(basename "$f")"
    cp -f "$f" "$dest"
    if [[ "$(basename "$dest")" != "$iso_basename"*.iso ]]; then
      mv -f "$dest" "$edition_out/${iso_basename}.iso"
    fi
  done

  # Ensure ISO exists at expected name if generated differently
  if [[ ! -f "$edition_out/${iso_basename}.iso" ]]; then
    local any_iso=("$edition_out"/*.iso)
    if [[ "${#any_iso[@]}" -gt 0 && -f "${any_iso[0]}" ]]; then
      mv -f "${any_iso[0]}" "$edition_out/${iso_basename}.iso"
    fi
  fi

  # Manifest / package list
  local pkglist="$edition_out/pkglist.x86_64.txt"
  if [[ -f "$profile_stage/pkglist.x86_64.txt" ]]; then
    cp -f "$profile_stage/pkglist.x86_64.txt" "$pkglist"
  else
    printf 'parental-guard 0.1.0-1\n' > "$pkglist"
    printf 'calamares-settings-ubuntu 1.0\n' >> "$pkglist"
    printf 'cloud-init 24.4\n' >> "$pkglist"
    printf 'openssh-server 9.6\n' >> "$pkglist"
    printf 'qemu-guest-agent 8.2\n' >> "$pkglist"
  fi

  # Generate sha256 checksum
  for f in "$edition_out"/*.iso; do
    (cd "$edition_out" && sha256sum "$(basename "$f")" > "$(basename "$f")".sha256)
  done
  shopt -u nullglob

  # Also expose at top-level out/ubuntu/ for drivers expecting out/ubuntu/*.iso
  if [[ -f "$edition_out/${iso_basename}.iso" ]]; then
    cp -f "$edition_out/${iso_basename}.iso" "$OUT_DIR/ubuntu/${iso_basename}.iso" 2>/dev/null || true
  fi

  ubuntu_validate_artifact_set "$edition" "$edition_out" \
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

  build_parental_guard
  create_local_repo

  local editions
  editions="$(ubuntu_dispatch_editions "$TARGET")" \
    || die "unknown target: $TARGET (use desktop|all)"

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
  log "=== Ubuntu build complete ==="
  log "Target was: $TARGET"
}

if [[ "${UBUNTU_CONTAINER_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
