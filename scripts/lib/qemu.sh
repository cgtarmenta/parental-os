#!/usr/bin/env bash
# Shared QEMU helper functions for parental-os scripts.
set -euo pipefail

qemu_targets_for() {
  local target="${1:-all}"
  case "$target" in
    ubuntu)
      printf '%s\n' ubuntu
      ;;
    cachyos-desktop)
      printf '%s\n' cachyos-desktop
      ;;
    cachyos-handheld)
      printf '%s\n' cachyos-handheld
      ;;
    cachyos)
      printf '%s\n' cachyos-desktop cachyos-handheld
      ;;
    all)
      printf '%s\n' ubuntu cachyos-desktop cachyos-handheld
      ;;
    *)
      printf 'unknown QEMU target: %s (use ubuntu|cachyos-desktop|cachyos-handheld|cachyos|all)\n' "$target" >&2
      return 2
      ;;
  esac
}

qemu_target_iso_dir() {
  local target="$1"
  local out
  out="$(out_root)"
  case "$target" in
    ubuntu) printf '%s\n' "$out/ubuntu" ;;
    cachyos-desktop) printf '%s\n' "$out/cachyos/desktop" ;;
    cachyos-handheld) printf '%s\n' "$out/cachyos/handheld" ;;
    *)
      printf 'unknown single QEMU target: %s\n' "$target" >&2
      return 2
      ;;
  esac
}

qemu_iso_for_target() {
  local target="$1"
  local dir
  dir="$(qemu_target_iso_dir "$target")" || return $?
  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  local files=("$dir"/*.iso)
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'no ISO found for %s in %s\n' "$target" "$dir" >&2
    return 1
  fi

  local newest="${files[0]}"
  local candidate
  for candidate in "${files[@]}"; do
    if [[ "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done
  printf '%s\n' "$newest"
}

qemu_require_single_target() {
  local target="${1:-ubuntu}"
  case "$target" in
    ubuntu|cachyos-desktop|cachyos-handheld)
      printf '%s\n' "$target"
      ;;
    cachyos|all)
      printf 'browser mode requires a single ISO target: use ubuntu|cachyos-desktop|cachyos-handheld\n' >&2
      return 2
      ;;
    *)
      printf 'unknown QEMU target: %s (use ubuntu|cachyos-desktop|cachyos-handheld)\n' "$target" >&2
      return 2
      ;;
  esac
}
