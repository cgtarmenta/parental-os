#!/usr/bin/env bash
# build-cachyos.sh — Host-facing dual genuine CachyOS image build driver.
#
# Builds two genuine CachyOS x86_64 images from current official upstream
# branch heads: desktop (CachyOS-Live-ISO@master) and handheld
# (CachyOS-Live-ISO@cachyos-deckify). Each edition resolves its branch head
# exactly once with git ls-remote, validates the 40-character SHA, writes that
# resolution to provenance, and checks out the detached commit.
#
# The actual ISO build runs inside an ephemeral privileged Arch container
# (--rm --privileged) with the parental checkout mounted read-only and only
# out/ mounted read-write with private mount propagation. No host
# /usr/bin/mkarchiso mutation occurs.
#
# Usage: build-cachyos.sh desktop|handheld|all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/cachyos.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd git
require_cmd docker
require_cmd jq

TARGET="${1:-all}"
BUILDER_IMAGE_TAG="parental-os-cachyos-builder:latest"
CONTAINER_DIR="$ROOT/distros/cachyos/container"

# Validate the target before doing any work.
editions="$(cachyos_dispatch_editions "$TARGET")" \
  || die "unknown target: $TARGET (use desktop|handheld|all)"

log "=== CachyOS dual build: target=$TARGET ==="

# ---------------------------------------------------------------------------
# Step 1: Resolve upstream refs and write provenance for each edition.
# ---------------------------------------------------------------------------
resolve_and_record() {
  local edition="$1"
  local out_dir
  out_dir="$(cachyos_edition_out_dir "$edition")"
  mkdir -p "$out_dir"

  local live_iso_url live_iso_branch calamares_url calamares_branch \
    pkgbuilds_url pkgbuilds_branch
  live_iso_url="$(cachyos_metadata_value "$edition" live_iso_url)"
  live_iso_branch="$(cachyos_metadata_value "$edition" live_iso_branch)"
  calamares_url="$(cachyos_metadata_value "$edition" calamares_url)"
  calamares_branch="$(cachyos_metadata_value "$edition" calamares_branch)"
  pkgbuilds_url="$(cachyos_metadata_value "$edition" pkgbuilds_url)"
  pkgbuilds_branch="$(cachyos_metadata_value "$edition" pkgbuilds_branch)"

  log "Resolving upstream refs for $edition..."
  local live_iso_sha calamares_sha pkgbuilds_sha
  live_iso_sha="$(cachyos_resolve_ref "$live_iso_url" "$live_iso_branch")" \
    || die "failed to resolve $live_iso_url @ $live_iso_branch"
  calamares_sha="$(cachyos_resolve_ref "$calamares_url" "$calamares_branch")" \
    || die "failed to resolve $calamares_url @ $calamares_branch"
  pkgbuilds_sha="$(cachyos_resolve_ref "$pkgbuilds_url" "$pkgbuilds_branch")" \
    || die "failed to resolve $pkgbuilds_url @ $pkgbuilds_branch"

  log "  Live ISO:   $live_iso_sha"
  log "  Calamares:  $calamares_sha"
  log "  PKGBUILDS:  $pkgbuilds_sha"

  local resolved_at parental_os_rev parental_os_dirty
  resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  parental_os_rev="$(cachyos_parental_os_revision)"
  parental_os_dirty="$(cachyos_parental_os_dirty)"

  cachyos_provenance_write "$out_dir/provenance.json" \
    edition="$edition" \
    live_iso_url="$live_iso_url" \
    live_iso_branch="$live_iso_branch" \
    live_iso_sha="$live_iso_sha" \
    calamares_url="$calamares_url" \
    calamares_branch="$calamares_branch" \
    calamares_sha="$calamares_sha" \
    pkgbuilds_url="$pkgbuilds_url" \
    pkgbuilds_branch="$pkgbuilds_branch" \
    pkgbuilds_sha="$pkgbuilds_sha" \
    resolved_at="$resolved_at" \
    parental_os_revision="$parental_os_rev" \
    parental_os_dirty="$parental_os_dirty" \
    builder_image="$BUILDER_IMAGE_TAG"

  cachyos_provenance_validate "$out_dir/provenance.json" \
    || die "provenance validation failed for $edition"
  log "  Provenance written to $out_dir/provenance.json"
}

# ---------------------------------------------------------------------------
# Step 2: Fetch and check out exact SHAs into edition-specific staging.
# ---------------------------------------------------------------------------
fetch_and_checkout() {
  local edition="$1"
  local stage_dir
  stage_dir="$(cachyos_staging_dir "$edition")"
  local out_dir
  out_dir="$(cachyos_edition_out_dir "$edition")"
  local prov="$out_dir/provenance.json"

  local live_iso_url live_iso_sha calamares_url calamares_sha \
    pkgbuilds_url pkgbuilds_sha
  live_iso_url="$(jq -r '.live_iso_url' "$prov")"
  live_iso_sha="$(jq -r '.live_iso_sha' "$prov")"
  calamares_url="$(jq -r '.calamares_url' "$prov")"
  calamares_sha="$(jq -r '.calamares_sha' "$prov")"
  pkgbuilds_url="$(jq -r '.pkgbuilds_url' "$prov")"
  pkgbuilds_sha="$(jq -r '.pkgbuilds_sha' "$prov")"

  log "Fetching and checking out exact SHAs for $edition into $stage_dir..."
  mkdir -p "$stage_dir"

  # Live ISO
  if [[ ! -d "$stage_dir/cachyos-live-iso/.git" ]]; then
    git clone --bare "$live_iso_url" "$stage_dir/cachyos-live-iso-bare" 2>/dev/null
    git clone "$live_iso_url" "$stage_dir/cachyos-live-iso" 2>/dev/null
  fi
  git -C "$stage_dir/cachyos-live-iso" fetch origin 2>/dev/null || true
  git -C "$stage_dir/cachyos-live-iso" checkout --detach "$live_iso_sha" 2>/dev/null \
    || die "failed to checkout Live ISO SHA $live_iso_sha"
  local checked
  checked="$(git -C "$stage_dir/cachyos-live-iso" rev-parse HEAD)"
  [[ "$checked" = "$live_iso_sha" ]] \
    || die "Live ISO checkout SHA mismatch: expected=$live_iso_sha got=$checked"

  # Calamares - force clean to remove any stale apply-parental-overlay modifications
  if [[ ! -d "$stage_dir/cachyos-calamares/.git" ]]; then
    git clone "$calamares_url" "$stage_dir/cachyos-calamares" 2>/dev/null
  fi
  git -C "$stage_dir/cachyos-calamares" fetch origin 2>/dev/null || true
  git -C "$stage_dir/cachyos-calamares" checkout --detach "$calamares_sha" 2>/dev/null \
    || die "failed to checkout Calamares SHA $calamares_sha"
  git -C "$stage_dir/cachyos-calamares" clean -fdx 2>/dev/null || true
  git -C "$stage_dir/cachyos-calamares" checkout -- . 2>/dev/null || true
  checked="$(git -C "$stage_dir/cachyos-calamares" rev-parse HEAD)"
  [[ "$checked" = "$calamares_sha" ]] \
    || die "Calamares checkout SHA mismatch: expected=$calamares_sha got=$checked"

  # PKGBUILDS (shared, but checked out per-edition for isolation)
  if [[ ! -d "$stage_dir/cachyos-pkgbuilds/.git" ]]; then
    git clone "$pkgbuilds_url" "$stage_dir/cachyos-pkgbuilds" 2>/dev/null
  fi
  git -C "$stage_dir/cachyos-pkgbuilds" fetch origin 2>/dev/null || true
  git -C "$stage_dir/cachyos-pkgbuilds" checkout --detach "$pkgbuilds_sha" 2>/dev/null \
    || die "failed to checkout PKGBUILDS SHA $pkgbuilds_sha"
  checked="$(git -C "$stage_dir/cachyos-pkgbuilds" rev-parse HEAD)"
  [[ "$checked" = "$pkgbuilds_sha" ]] \
    || die "PKGBUILDS checkout SHA mismatch: expected=$pkgbuilds_sha got=$checked"

  log "  All SHAs checked out and verified for $edition"
}

# ---------------------------------------------------------------------------
# Step 3: Build the Docker builder image.
# ---------------------------------------------------------------------------
build_builder_image() {
  log "=== Building CachyOS builder Docker image ==="
  docker_cli build -t "$BUILDER_IMAGE_TAG" "$CONTAINER_DIR" \
    2>&1 | tee "$ROOT/out/logs/cachyos-builder-image.log"
  log "Builder image built: $BUILDER_IMAGE_TAG"
}

# ---------------------------------------------------------------------------
# Step 4: Run the container to build all editions.
# The container receives the repo read-only at /repo and out/ read-write at /out
# with private mount propagation. --rm ensures automatic cleanup.
#
# Note: This requires the Docker default context (native dockerd), not Docker
# Desktop, because Docker Desktop on Linux cannot share git worktree paths.
# ---------------------------------------------------------------------------
run_container_build() {
  log "=== Running containerized build for target=$TARGET ==="
  # Mount /out before /repo so the /out bind is not shadowed by the /repo
  # bind when private propagation is used. Both mounts use rprivate propagation
  # so container mount events do not leak to the host.
  docker_cli run --rm \
    --privileged \
    --mount type=bind,source="$ROOT/out",destination=/out,bind-propagation=rprivate \
    --mount type=bind,source="$ROOT",destination=/repo,readonly,bind-propagation=rprivate \
    "$BUILDER_IMAGE_TAG" \
    "$TARGET" "$BUILDER_IMAGE_TAG" \
    2>&1 | tee "$ROOT/out/logs/build-cachyos-all.log"
  log "=== Container build complete ==="
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
log "Step 1: Resolving upstream refs and writing provenance"
for ed in $editions; do
  resolve_and_record "$ed"
done

log "Step 2: Fetching and checking out exact SHAs"
for ed in $editions; do
  fetch_and_checkout "$ed"
done

log "Step 3: Building the Docker builder image"
build_builder_image

log "Step 4: Running the containerized dual build"
run_container_build

log ""
log "=== CachyOS dual build complete ==="
log "Artifacts:"
for ed in $editions; do
  out_dir="$(cachyos_edition_out_dir "$ed")"
  log "  $ed: $out_dir"
  ls -la "$out_dir" >&2 || true
done
