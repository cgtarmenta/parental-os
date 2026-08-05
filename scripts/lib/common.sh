#!/usr/bin/env bash
# Shared helpers for parental-os scripts.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

repo_root() {
  if [[ -n "${PARENTAL_OS_ROOT:-}" ]]; then
    printf '%s\n' "$PARENTAL_OS_ROOT"
    return 0
  fi
  local start d
  start="$(pwd)"
  d="$start"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/Justfile" || -d "$d/docs/superpowers/specs" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  die "could not locate parental-os repo root from $start"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

docker_context_name() {
  printf '%s\n' "${DOCKER_CONTEXT:-default}"
}

docker_cli() {
  docker --context "$(docker_context_name)" "$@"
}

# Return the output directory root. Inside the privileged CachyOS builder
# container, PARENTAL_OS_OUT is set to /out (the writable bind mount). On the
# host, it defaults to <repo_root>/out.
out_root() {
  if [[ -n "${PARENTAL_OS_OUT:-}" ]]; then
    printf '%s\n' "$PARENTAL_OS_OUT"
    return 0
  fi
  local root
  root="$(repo_root)"
  printf '%s/out\n' "$root"
}

ensure_out_dirs() {
  local out
  out="$(out_root)"
  mkdir -p "$out/ubuntu" "$out/cachyos" "$out/packages" "$out/logs" "$out/qemu"
}
