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

ensure_out_dirs() {
  local root
  root="$(repo_root)"
  mkdir -p "$root/out/ubuntu" "$root/out/cachyos" "$root/out/packages" "$root/out/logs" "$root/out/qemu"
}
