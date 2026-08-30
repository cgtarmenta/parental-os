#!/usr/bin/env bash
# build-ubuntu.sh — Host-facing Ubuntu Desktop LTS live image build driver.
#
# Builds genuine Ubuntu Desktop x86_64 LiveCD ISO image from official upstream
# branch heads (calamares-settings-ubuntu@master). The edition resolves its
# branch head with git ls-remote, validates the 40-character SHA, writes that
# resolution to provenance, and checks out the detached commit.
#
# The actual ISO build runs inside an ephemeral privileged Ubuntu container
# (--rm --privileged) with the parental checkout mounted read-only at /repo and
# only out/ mounted read-write at /out with private mount propagation (rprivate).
#
# Usage: build-ubuntu.sh desktop|all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ubuntu.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd git
require_cmd docker
require_cmd jq

TARGET="${1:-all}"
BUILDER_IMAGE_TAG="parental-os-ubuntu-builder:latest"
CONTAINER_DIR="$ROOT/distros/ubuntu/container"

# Validate the target before doing any work.
editions="$(ubuntu_dispatch_editions "$TARGET")" \
  || die "unknown target: $TARGET (use desktop|all)"

log "=== Ubuntu build: target=$TARGET ==="

# ---------------------------------------------------------------------------
# Step 1: Resolve upstream refs and write provenance for each edition.
# ---------------------------------------------------------------------------
resolve_and_record() {
  local edition="$1"
  local out_dir
  out_dir="$(ubuntu_edition_out_dir "$edition")"
  mkdir -p "$out_dir"

  local live_iso_url live_iso_branch calamares_url calamares_branch
  live_iso_url="$(ubuntu_metadata_value "$edition" live_iso_url)"
  live_iso_branch="$(ubuntu_metadata_value "$edition" live_iso_branch)"
  calamares_url="$(ubuntu_metadata_value "$edition" calamares_url)"
  calamares_branch="$(ubuntu_metadata_value "$edition" calamares_branch)"

  log "Resolving upstream refs for $edition..."
  local live_iso_sha calamares_sha
  live_iso_sha="$(ubuntu_resolve_ref "$live_iso_url" "$live_iso_branch")" \
    || die "failed to resolve $live_iso_url @ $live_iso_branch"
  calamares_sha="$(ubuntu_resolve_ref "$calamares_url" "$calamares_branch")" \
    || die "failed to resolve $calamares_url @ $calamares_branch"

  log "  Live ISO:   $live_iso_sha"
  log "  Calamares:  $calamares_sha"

  local resolved_at parental_os_rev parental_os_dirty
  resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  parental_os_rev="$(ubuntu_parental_os_revision)"
  parental_os_dirty="$(ubuntu_parental_os_dirty)"

  ubuntu_provenance_write "$out_dir/provenance.json" \
    edition="$edition" \
    live_iso_url="$live_iso_url" \
    live_iso_branch="$live_iso_branch" \
    live_iso_sha="$live_iso_sha" \
    calamares_url="$calamares_url" \
    calamares_branch="$calamares_branch" \
    calamares_sha="$calamares_sha" \
    resolved_at="$resolved_at" \
    parental_os_revision="$parental_os_rev" \
    parental_os_dirty="$parental_os_dirty" \
    builder_image="$BUILDER_IMAGE_TAG"

  ubuntu_provenance_validate "$out_dir/provenance.json" \
    || die "provenance validation failed for $edition"
  log "  Provenance written to $out_dir/provenance.json"
}

# ---------------------------------------------------------------------------
# Step 2: Fetch and check out exact SHAs into edition-specific staging.
# ---------------------------------------------------------------------------
fetch_and_checkout() {
  local edition="$1"
  local stage_dir
  stage_dir="$(ubuntu_staging_dir "$edition")"
  local out_dir
  out_dir="$(ubuntu_edition_out_dir "$edition")"
  local prov="$out_dir/provenance.json"

  local live_iso_url live_iso_sha calamares_url calamares_sha
  live_iso_url="$(jq -r '.live_iso_url' "$prov")"
  live_iso_sha="$(jq -r '.live_iso_sha' "$prov")"
  calamares_url="$(jq -r '.calamares_url' "$prov")"
  calamares_sha="$(jq -r '.calamares_sha' "$prov")"

  log "Fetching and checking out exact SHAs for $edition into $stage_dir..."
  mkdir -p "$stage_dir"

  # Live ISO / Calamares settings
  if [[ ! -d "$stage_dir/ubuntu-live-iso/.git" ]]; then
    git clone "$live_iso_url" "$stage_dir/ubuntu-live-iso" 2>/dev/null
  fi
  git -C "$stage_dir/ubuntu-live-iso" fetch origin 2>/dev/null || true
  git -C "$stage_dir/ubuntu-live-iso" reset --hard 2>/dev/null || true
  git -C "$stage_dir/ubuntu-live-iso" clean -fdx 2>/dev/null || true
  git -C "$stage_dir/ubuntu-live-iso" checkout --detach "$live_iso_sha" 2>/dev/null \
    || die "failed to checkout Live ISO SHA $live_iso_sha"
  local checked
  checked="$(git -C "$stage_dir/ubuntu-live-iso" rev-parse HEAD)"
  [[ "$checked" = "$live_iso_sha" ]] \
    || die "Live ISO checkout SHA mismatch: expected=$live_iso_sha got=$checked"

  # Calamares tree
  if [[ ! -d "$stage_dir/ubuntu-calamares/.git" ]]; then
    git clone "$calamares_url" "$stage_dir/ubuntu-calamares" 2>/dev/null
  fi
  git -C "$stage_dir/ubuntu-calamares" fetch origin 2>/dev/null || true
  git -C "$stage_dir/ubuntu-calamares" reset --hard 2>/dev/null || true
  git -C "$stage_dir/ubuntu-calamares" clean -fdx 2>/dev/null || true
  git -C "$stage_dir/ubuntu-calamares" checkout --detach "$calamares_sha" 2>/dev/null \
    || die "failed to checkout Calamares SHA $calamares_sha"
  checked="$(git -C "$stage_dir/ubuntu-calamares" rev-parse HEAD)"
  [[ "$checked" = "$calamares_sha" ]] \
    || die "Calamares checkout SHA mismatch: expected=$calamares_sha got=$checked"

  log "  All SHAs checked out and verified for $edition"
}

# ---------------------------------------------------------------------------
# Step 3: Build the Docker builder image.
# ---------------------------------------------------------------------------
build_builder_image() {
  log "=== Building Ubuntu builder Docker image ==="
  docker_cli build -t "$BUILDER_IMAGE_TAG" "$CONTAINER_DIR" \
    2>&1 | tee "$ROOT/out/logs/ubuntu-builder-image.log"
  log "Builder image built: $BUILDER_IMAGE_TAG"
}

# ---------------------------------------------------------------------------
# Step 4: Run the container to build editions.
# ---------------------------------------------------------------------------
run_container_build() {
  log "=== Running containerized build for target=$TARGET ==="
  docker_cli run --rm \
    --privileged \
    --mount type=bind,source="$ROOT/out",destination=/out,bind-propagation=rprivate \
    --mount type=bind,source="$ROOT",destination=/repo,readonly,bind-propagation=rprivate \
    "$BUILDER_IMAGE_TAG" \
    "$TARGET" "$BUILDER_IMAGE_TAG" \
    2>&1 | tee "$ROOT/out/logs/build-ubuntu-all.log"
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

log "Step 4: Running the containerized build"
run_container_build

log ""
log "=== Ubuntu build complete ==="
log "Artifacts:"
for ed in $editions; do
  out_dir="$(ubuntu_edition_out_dir "$ed")"
  log "  $ed: $out_dir"
  ls -la "$out_dir" >&2 || true
done
