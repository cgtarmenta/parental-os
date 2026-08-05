#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd docker

OUT="$(out_root)"
BUILDER_IMAGE_TAG="parental-os-ubuntu-live-builder:latest"
DOCKER_CONTEXT_DIR="$ROOT/distros/ubuntu/docker"
# Generated live-build tree lives under out/ubuntu/lb.
LB_DIR="$OUT/ubuntu/lb"
# Build output is streamed to out/logs/build-ubuntu.log.
LOG="$OUT/logs/build-ubuntu.log"

clean_lb_dir() {
  if ! rm -rf "$LB_DIR" 2>/dev/null; then
    log "host rm failed (root-owned live-build files); cleaning via Docker container..."
    docker_cli run --rm -v "$OUT:/cleanout" alpine:latest \
      sh -c "rm -rf /cleanout/ubuntu/lb" >/dev/null 2>&1 || true
    rm -rf "$LB_DIR" 2>/dev/null || true
  fi
}

stage_live_build_tree() {
  shopt -s nullglob
  local debs=("$OUT"/packages/parental-guard_*.deb)
  shopt -u nullglob
  [[ "${#debs[@]}" -gt 0 ]] || die "no parental-guard_*.deb found in $OUT/packages"

  clean_lb_dir
  mkdir -p "$LB_DIR/config/includes.chroot/root/parental-os-debs"
  cp -a "$ROOT/distros/ubuntu/auto" "$LB_DIR/"
  cp -a "$ROOT/distros/ubuntu/config/." "$LB_DIR/config/"
  cp -a "${debs[@]}" "$LB_DIR/config/includes.chroot/root/parental-os-debs/"
}

run_live_build() {
  docker_cli run --rm \
    --privileged \
    --mount type=bind,source="$LB_DIR",destination=/build,bind-propagation=rprivate \
    "$BUILDER_IMAGE_TAG" \
    bash -lc '
      set -euo pipefail
      cd /build
      lb clean --purge || true
      lb config
      lb build
    '
}

copy_iso_artifacts() {
  shopt -s nullglob
  local iso_files=("$LB_DIR"/*.iso)
  [[ "${#iso_files[@]}" -gt 0 ]] || die "no ISO produced under $LB_DIR"
  cp -a "$LB_DIR"/*.iso "$OUT/ubuntu/"
  for iso in "${iso_files[@]}"; do
    (cd "$OUT/ubuntu" && sha256sum "$(basename "$iso")") \
      >"$OUT/ubuntu/$(basename "$iso").sha256"
  done
  shopt -u nullglob
}

{
  log "=== Ubuntu-family live-build ==="
  log "Step 1: Building parental-guard deb"
  "$ROOT/scripts/build-parental-guard-deb.sh"

  log "Step 2: Staging live-build tree"
  stage_live_build_tree

  log "Step 3: Building live-build Docker image"
  docker_cli build -t "$BUILDER_IMAGE_TAG" "$DOCKER_CONTEXT_DIR"

  log "Step 4: Running live-build container"
  run_live_build

  log "Step 5: Copying ISO artifacts"
  copy_iso_artifacts

  log "Ubuntu-family artifacts in $OUT/ubuntu"
} 2>&1 | tee "$LOG"
