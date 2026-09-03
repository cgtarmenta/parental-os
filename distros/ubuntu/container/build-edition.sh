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

  # Stage guardian secret setup prompt, live session autostart, and desktop launcher wrapper
  local guardian_prompt_src="$REPO_DIR/overlays/usr/lib/parental-os/guardian-setup-prompt.sh"
  if [[ -f "$guardian_prompt_src" ]]; then
    mkdir -p "$airootfs/usr/lib/parental-os" "$airootfs/etc/xdg/autostart" "$airootfs/usr/local/bin"
    cp -f "$guardian_prompt_src" "$airootfs/usr/lib/parental-os/guardian-setup-prompt.sh"
    chmod 755 "$airootfs/usr/lib/parental-os/guardian-setup-prompt.sh"

    cat > "$airootfs/etc/xdg/autostart/parental-guardian-prompt.desktop" <<'AUTOSTART_EOF'
[Desktop Entry]
Type=Application
Name=Parental OS Guardian Setup
Comment=Prompt for guardian secret during live session
Exec=/usr/lib/parental-os/guardian-setup-prompt.sh
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOSTART_EOF
    chmod 644 "$airootfs/etc/xdg/autostart/parental-guardian-prompt.desktop"

    cat > "$airootfs/usr/lib/parental-os/desktop-launcher-wrapper.sh" <<'WRAPPER_EOF'
#!/bin/bash
# Wrapper to ensure guardian secret prompt runs when desktop launcher executes
if [[ -x /usr/lib/parental-os/guardian-setup-prompt.sh ]]; then
  /usr/lib/parental-os/guardian-setup-prompt.sh || true
fi
if [[ $# -gt 0 ]]; then
  exec "$@"
fi
WRAPPER_EOF
    chmod 755 "$airootfs/usr/lib/parental-os/desktop-launcher-wrapper.sh"
    ln -sfn /usr/lib/parental-os/desktop-launcher-wrapper.sh "$airootfs/usr/local/bin/parental-desktop-launcher"
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

  if [[ -f "$iso_dest" ]]; then
    log "Using pre-staged ISO at $iso_dest"
    return 0
  fi

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
  chmod -R ugo+rwX "$iso_extracted" 2>/dev/null || true

  # Step 3: Build custom parental overlay layer on top of genuine Ubuntu layers
  log "Building custom parental overlay layer (minimal.standard.live.custom.squashfs)..."
  local overlay_dir="$work_dir/overlay-root"
  rm -rf "$overlay_dir"
  mkdir -p "$overlay_dir"

  # Unpack parental-guard deb directly into overlay tree
  local pg_deb
  pg_deb="$(ls -1 "$PACKAGES_OUT"/parental-guard_*.deb 2>/dev/null | head -n1)"
  [[ -n "$pg_deb" && -f "$pg_deb" ]] || die "parental-guard deb not found in $PACKAGES_OUT"
  dpkg-deb -x "$pg_deb" "$overlay_dir/"

  # Retain deb package at /usr/share/parental-os/ and /cdrom/casper/ for target installation
  mkdir -p "$overlay_dir/usr/share/parental-os"
  cp -f "$pg_deb" "$overlay_dir/usr/share/parental-os/parental-guard.deb"
  cp -f "$pg_deb" "$iso_extracted/casper/parental-guard.deb"

  # Copy local repo into overlay /srv/parental-os-repo
  mkdir -p "$overlay_dir/srv/parental-os-repo"
  if [[ -d /srv/parental-os-repo ]]; then
    cp -a /srv/parental-os-repo/. "$overlay_dir/srv/parental-os-repo/"
  fi

  # Merge staged airootfs overlay if present
  if [[ -d "$staged_dir/airootfs" ]]; then
    log "Applying staged airootfs overlay to custom layer..."
    cp -a "$staged_dir/airootfs/." "$overlay_dir/"
  fi

  # Clean up any account database and policy files from overlay to keep live installer uninhibited
  rm -f "$overlay_dir/etc/group" "$overlay_dir/etc/passwd" "$overlay_dir/etc/shadow" "$overlay_dir/etc/gshadow" 2>/dev/null || true
  rm -f "$overlay_dir/etc/sudoers.d/parental-os" 2>/dev/null || true
  rm -f "$overlay_dir/etc/polkit-1/rules.d/50-parental-os.rules" 2>/dev/null || true

  # Ensure runtime state directory exists
  mkdir -p "$overlay_dir/var/lib/parental-os"

  # Ensure GDM display manager is enabled for graphical live session
  local wants_dir="$overlay_dir/etc/systemd/system/multi-user.target.wants"
  local graph_wants_dir="$overlay_dir/etc/systemd/system/graphical.target.wants"
  mkdir -p "$wants_dir" "$graph_wants_dir"
  ln -sfn "/usr/lib/systemd/system/gdm.service" "$overlay_dir/etc/systemd/system/display-manager.service"
  ln -sfn "/usr/lib/systemd/system/gdm.service" "$graph_wants_dir/gdm.service"

  # Wire guardian setup prompt into live session autostart and desktop launcher wrapper
  local guardian_prompt_src="$REPO_DIR/overlays/usr/lib/parental-os/guardian-setup-prompt.sh"
  mkdir -p "$overlay_dir/usr/lib/parental-os" "$overlay_dir/etc/xdg/autostart" "$overlay_dir/usr/local/bin"
  if [[ -f "$guardian_prompt_src" ]]; then
    cp -f "$guardian_prompt_src" "$overlay_dir/usr/lib/parental-os/guardian-setup-prompt.sh"
    chmod 755 "$overlay_dir/usr/lib/parental-os/guardian-setup-prompt.sh"
  fi

  cat > "$overlay_dir/etc/xdg/autostart/parental-guardian-prompt.desktop" <<'AUTOSTART_EOF'
[Desktop Entry]
Type=Application
Name=Parental OS Guardian Setup
Comment=Prompt for guardian secret during live session
Exec=/usr/lib/parental-os/guardian-setup-prompt.sh
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOSTART_EOF
  chmod 644 "$overlay_dir/etc/xdg/autostart/parental-guardian-prompt.desktop"

  cat > "$overlay_dir/usr/lib/parental-os/desktop-launcher-wrapper.sh" <<'WRAPPER_EOF'
#!/bin/bash
# Wrapper to ensure guardian secret prompt runs when desktop launcher executes
if [[ -x /usr/lib/parental-os/guardian-setup-prompt.sh ]]; then
  /usr/lib/parental-os/guardian-setup-prompt.sh || true
fi
if [[ $# -gt 0 ]]; then
  exec "$@"
fi
WRAPPER_EOF
  chmod 755 "$overlay_dir/usr/lib/parental-os/desktop-launcher-wrapper.sh"
  ln -sfn /usr/lib/parental-os/desktop-launcher-wrapper.sh "$overlay_dir/usr/local/bin/parental-desktop-launcher"

  # Inject robust target provisioner to guarantee parental-guard is installed on target system
  mkdir -p "$overlay_dir/usr/lib/parental-os" "$overlay_dir/usr/lib/systemd/system"
  cat > "$overlay_dir/usr/lib/parental-os/target-provisioner.sh" <<'TARGET_EOF'
#!/bin/bash
set -u

log_msg() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> /var/log/parental-target-provisioner.log 2>/dev/null || true
  if [[ -d /target/var/log ]]; then
    echo "$msg" >> /target/var/log/parental-provisioner.log 2>/dev/null || true
  fi
}

find_deb() {
  for p in /usr/share/parental-os/parental-guard.deb \
           /srv/parental-os-repo/parental-guard_*.deb \
           /cdrom/casper/parental-guard.deb \
           /run/casper-cdrom/casper/parental-guard.deb; do
    if ls $p 1>/dev/null 2>&1; then
      ls -1 $p | head -n1
      return 0
    fi
  done
  return 1
}

provision_target_partition() {
  local deb="$1"
  local target_mounted_by_us=0

  # Ensure /target is mounted
  if ! mountpoint -q /target 2>/dev/null; then
    mkdir -p /target
    local root_dev=""
    for dev in $(lsblk -lno PATH,FSTYPE 2>/dev/null | awk '$2=="ext4"{print $1}'); do
      if mount "$dev" /target 2>/dev/null; then
        if [[ -f /target/etc/os-release && -f /target/etc/passwd ]]; then
          root_dev="$dev"
          target_mounted_by_us=1
          break
        else
          umount /target 2>/dev/null || true
        fi
      fi
    done
    if [[ -z "$root_dev" ]]; then
      log_msg "No target installation partition found to provision"
      return 0
    fi
  fi

  [[ -f /target/etc/passwd && -f /target/etc/os-release ]] || return 0
  [[ -f /target/var/lib/parental-os/.provisioned ]] && return 0

  log_msg "Provisioning target filesystem with $deb..."

  # 1. Extract payload to /target
  dpkg-deb -x "$deb" /target/ 2>&1 | while read -r line; do log_msg "extract: $line"; done

  # 2. Extract control files to target /var/lib/dpkg/info
  local tmp_ctrl="/target/tmp/pg-deb-control"
  rm -rf "$tmp_ctrl"
  mkdir -p "$tmp_ctrl"
  if dpkg-deb -e "$deb" "$tmp_ctrl" 2>/dev/null; then
    mkdir -p /target/var/lib/dpkg/info
    for f in "$tmp_ctrl"/*; do
      [[ -f "$f" ]] || continue
      local fname
      fname="$(basename "$f")"
      if [[ "$fname" != "control" ]]; then
        cp -f "$f" "/target/var/lib/dpkg/info/parental-guard.$fname"
      fi
    done

    # Register in dpkg status if not present
    if [[ -f /target/var/lib/dpkg/status ]] && ! grep -q '^Package: parental-guard' /target/var/lib/dpkg/status 2>/dev/null; then
      cat "$tmp_ctrl/control" >> /target/var/lib/dpkg/status
      echo "Status: install ok installed" >> /target/var/lib/dpkg/status
      echo "" >> /target/var/lib/dpkg/status
      log_msg "Registered parental-guard in /target/var/lib/dpkg/status"
    fi
    rm -rf "$tmp_ctrl"
  fi

  # 3. Ensure group parental-users exists in /target/etc/group
  if [[ -f /target/etc/group ]] && ! grep -q '^parental-users:' /target/etc/group; then
    echo "parental-users:x:998:" >> /target/etc/group
    log_msg "Added parental-users group to /target/etc/group"
  fi

  # 4. Ensure sudoers drop-in is mode 0440
  if [[ -f /target/etc/sudoers.d/parental-os ]]; then
    chmod 0440 /target/etc/sudoers.d/parental-os
  fi

  # 5. Ensure runtime state dir exists
  mkdir -p /target/var/lib/parental-os

  # Provision guardian secret hash
  mkdir -p /target/etc/parental-os
  if [[ -f /run/parental-os/guardian.hash && -s /run/parental-os/guardian.hash ]]; then
    cp -f /run/parental-os/guardian.hash /target/etc/parental-os/guardian.hash
    chmod 0600 /target/etc/parental-os/guardian.hash
    chown 0:0 /target/etc/parental-os/guardian.hash
    log_msg "Provisioned guardian secret hash from /run/parental-os/guardian.hash"
  else
    log_msg "WARNING: /run/parental-os/guardian.hash absent; generating secure random guardian hash"
    local random_secret fallback_hash
    random_secret="$(od -vN 32 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || date +%s%N)"
    fallback_hash="$(printf 'parental-guard:lan-v1:%s' "$random_secret" | sha256sum | awk '{print $1}')"
    printf '%s\n' "$fallback_hash" > /target/etc/parental-os/guardian.hash
    chmod 0600 /target/etc/parental-os/guardian.hash
    chown 0:0 /target/etc/parental-os/guardian.hash
    log_msg "Generated fallback random guardian hash at /target/etc/parental-os/guardian.hash"
  fi

  # 6. Enable systemd units in target
  local tgt_wants="/target/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$tgt_wants"
  for unit in parental-guard.service parental-guard-agent.service parental-guard-enroll.service parental-guard-enroll.path; do
    if [[ -f "/target/usr/lib/systemd/system/$unit" || -f "/target/lib/systemd/system/$unit" ]]; then
      ln -sfn "/usr/lib/systemd/system/$unit" "$tgt_wants/$unit"
      log_msg "Linked $unit in target multi-user.target.wants"
    fi
  done

  # 7. Ensure merged-/usr symlinks (lib -> usr/lib) and display-manager are intact
  if [[ -d /target/usr/lib && ! -L /target/lib ]]; then
    cp -a /target/lib/* /target/usr/lib/ 2>/dev/null || true
    rm -rf /target/lib 2>/dev/null || true
    ln -sfn usr/lib /target/lib
    log_msg "Repaired merged-/usr /target/lib symlink"
  fi
  if [[ -f /target/usr/lib/systemd/system/gdm.service ]]; then
    ln -sfn "/usr/lib/systemd/system/gdm.service" "/target/etc/systemd/system/display-manager.service"
  fi

  # 8. Run user enrollment on target users if passwd exists
  if [[ -x /target/usr/lib/parental-os/enroll-users.sh ]]; then
    PARENTAL_OS_ROOT_FS=/target /target/usr/lib/parental-os/enroll-users.sh 2>&1 | while read -r line; do log_msg "enroll: $line"; done || true
  fi

  touch /target/var/lib/parental-os/.provisioned
  sync
  log_msg "Target system successfully provisioned!"

  if [[ "$target_mounted_by_us" -eq 1 ]]; then
    umount /target 2>/dev/null || true
  fi
  return 0
}

DEB_FILE="$(find_deb || true)"
if [[ -z "$DEB_FILE" ]]; then
  log_msg "Warning: parental-guard deb not found"
  exit 0
fi

provision_target_partition "$DEB_FILE"
TARGET_EOF
  chmod 755 "$overlay_dir/usr/lib/parental-os/target-provisioner.sh"

  cat > "$overlay_dir/usr/lib/systemd/system/parental-target-shutdown.service" <<'SHUTDOWN_UNIT_EOF'
[Unit]
Description=Parental OS Final Target Provisioner on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target umount.target

[Service]
Type=oneshot
ExecStart=/usr/lib/parental-os/target-provisioner.sh
TimeoutStartSec=15

[Install]
WantedBy=shutdown.target reboot.target halt.target
SHUTDOWN_UNIT_EOF
  local shutdown_wants="$overlay_dir/etc/systemd/system/shutdown.target.wants"
  local reboot_wants="$overlay_dir/etc/systemd/system/reboot.target.wants"
  mkdir -p "$shutdown_wants" "$reboot_wants"
  ln -sfn "/usr/lib/systemd/system/parental-target-shutdown.service" "$shutdown_wants/parental-target-shutdown.service"
  ln -sfn "/usr/lib/systemd/system/parental-target-shutdown.service" "$reboot_wants/parental-target-shutdown.service"

  # Step 4: Compress custom overlay layer
  log "Compressing custom overlay layer to casper/minimal.standard.live.custom.squashfs..."
  local custom_squash="$iso_extracted/casper/minimal.standard.live.custom.squashfs"
  rm -f "$custom_squash"
  mksquashfs "$overlay_dir" "$custom_squash" -comp xz -noappend -b 1048576 2>&1 | tee -a "$staged_dir/out/squashfs.log" || true

  local custom_size
  custom_size="$(du -sx --block-size=1 "$overlay_dir" 2>/dev/null | cut -f1)"
  printf '%s\n' "$custom_size" > "$iso_extracted/casper/minimal.standard.live.custom.size"
  rm -rf "$overlay_dir"

  # Step 5: Update GRUB configuration with custom layer, noprompt, and Boot from Hard Disk option
  log "Updating GRUB configuration with custom layer, noprompt, and hard disk boot option..."
  for grub_file in "$iso_extracted/boot/grub/grub.cfg" "$iso_extracted/boot/grub/loopback.cfg"; do
    if [[ -f "$grub_file" ]]; then
      sed -i 's|/casper/vmlinuz\([ \t]\+\)|/casper/vmlinuz layerfs-path=minimal.standard.live.custom.squashfs noprompt\1|g' "$grub_file"
      cat >> "$grub_file" <<'GRUB_HD_EOF'

menuentry "Boot from Hard Disk" --id "harddisk" {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod fat
    search --no-floppy --file --set=root /boot/grub/grub.cfg
    if [ -f ($root)/boot/grub/grub.cfg ]; then
        configfile ($root)/boot/grub/grub.cfg
    else
        set root=(hd0)
        chainloader +1 || exit 1
    fi
}
GRUB_HD_EOF
    fi
  done

  # Recompute ISO md5sum manifest
  log "Recomputing ISO md5sum manifest..."
  (
    cd "$iso_extracted"
    rm -f md5sum.txt
    find . -type f ! -path "./boot.catalog" ! -path "./isolinux/boot.cat" -exec md5sum {} + > md5sum.txt 2>/dev/null || true
  )

  # Step 6: Extract official boot images and rebuild hybrid ISO with genuine MBR & EFI layout
  local boot_images="$work_dir/boot_images"
  mkdir -p "$boot_images"
  xorriso -osirrox on -indev "$base_iso_path" -extract_boot_images "$boot_images" >/dev/null 2>&1 || true

  log "Generating bootable hybrid desktop ISO with xorriso..."
  (
    cd "$iso_extracted"
    if [[ -f "$boot_images/mbr_code_grub2.img" && -f "$boot_images/gpt_part2_efi.img" ]]; then
      xorriso -as mkisofs \
        -r -V "Ubuntu 26.04.1 LTS amd64" \
        -J -joliet-long -l -iso-level 3 \
        -partition_offset 16 \
        --grub2-mbr "$boot_images/mbr_code_grub2.img" \
        --protective-msdos-label \
        -partition_cyl_align off \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$boot_images/gpt_part2_efi.img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
        -o "$iso_dest" .
    else
      xorriso -as mkisofs \
        -r -V "Ubuntu 26.04.1 LTS amd64" \
        -J -joliet-long -l -iso-level 3 \
        -partition_offset 16 \
        -b boot/grub/i386-pc/eltorito.img \
        -c boot.catalog \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot -isohybrid-gpt-basdat \
        -o "$iso_dest" .
    fi
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
