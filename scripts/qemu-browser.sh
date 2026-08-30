#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/qemu.sh"
export PARENTAL_OS_ROOT="$ROOT"

COMPOSE_FILE="$ROOT/compose.qemu.yml"

safe_compose_suffix() {
  local raw="${1,,}"
  local safe=""
  local char
  local i

  for ((i = 0; i < ${#raw}; i++)); do
    char="${raw:i:1}"
    if [[ "$char" =~ [a-z0-9_-] ]]; then
      safe+="$char"
    else
      safe+="-"
    fi
  done

  while [[ "$safe" == [-_]* ]]; do
    safe="${safe:1}"
  done
  while [[ "$safe" == *[-_] ]]; do
    safe="${safe:0:${#safe}-1}"
  done
  printf '%s\n' "${safe:-worktree}"
}

DEFAULT_PROJECT_SUFFIX="$(safe_compose_suffix "$(basename "$ROOT")")"
PROJECT="${PARENTAL_OS_QEMU_PROJECT:-parental-os-qemu-browser-$DEFAULT_PROJECT_SUFFIX}"

compose_down() {
  docker_cli compose -p "$PROJECT" -f "$COMPOSE_FILE" down --remove-orphans
}

if [[ "${1:-}" == "down" ]]; then
  export PARENTAL_OS_ISO_PATH="${PARENTAL_OS_ISO_PATH:-/dev/null}"
  export PARENTAL_OS_BROWSER_TARGET="${PARENTAL_OS_BROWSER_TARGET:-down}"
  export PARENTAL_OS_BIND_IP="${PARENTAL_OS_BIND_IP:-127.0.0.1}"
  export PARENTAL_OS_WEB_PORT="${PARENTAL_OS_WEB_PORT:-8011}"
  export PARENTAL_OS_BROWSER_SSH_PORT="${PARENTAL_OS_BROWSER_SSH_PORT:-2222}"
  compose_down
  exit 0
fi

if [[ "$#" -gt 1 ]]; then
  die "qemu-browser requires a single ISO target: use ubuntu|cachyos-desktop|cachyos-handheld"
fi

require_cmd docker
ensure_out_dirs

TARGET="$(qemu_require_single_target "${1:-ubuntu}")"
ISO="$(qemu_iso_for_target "$TARGET")"
OUT="$(out_root)"
# Interactive browser mode: do not attach cloud-init seed so installer runs in GUI wizard mode
if [[ "${PARENTAL_OS_ATTACH_SEED:-0}" == "1" ]]; then
  "$ROOT/scripts/make-cloud-init-seed.sh"
fi

export PARENTAL_OS_ISO_PATH="$ISO"
export PARENTAL_OS_BROWSER_TARGET="$TARGET"
export PARENTAL_OS_BIND_IP="${PARENTAL_OS_BIND_IP:-127.0.0.1}"
export PARENTAL_OS_WEB_PORT="${PARENTAL_OS_WEB_PORT:-8011}"
export PARENTAL_OS_BROWSER_SSH_PORT="${PARENTAL_OS_BROWSER_SSH_PORT:-2222}"
export PARENTAL_OS_QEMU_RAM="${PARENTAL_OS_QEMU_RAM:-6144}"
export PARENTAL_OS_QEMU_CPUS="${PARENTAL_OS_QEMU_CPUS:-4}"
export PARENTAL_OS_QEMU_DISK_SIZE="${PARENTAL_OS_QEMU_DISK_SIZE:-20G}"

mkdir -p "$OUT/qemu/browser/$TARGET"
COMPOSE_ARGS=(compose -p "$PROJECT" -f "$COMPOSE_FILE")
KVM_OVERRIDE="$OUT/qemu/browser/$TARGET/compose.kvm.yml"
if [[ -e /dev/kvm ]]; then
  cat >"$KVM_OVERRIDE" <<'YAML'
services:
  qemu-browser:
    devices:
      - /dev/kvm:/dev/kvm
YAML
  COMPOSE_ARGS+=(-f "$KVM_OVERRIDE")
else
  rm -f "$KVM_OVERRIDE"
fi

docker_cli "${COMPOSE_ARGS[@]}" up -d --build

printf 'noVNC URL: http://%s:%s/vnc.html\n' "$PARENTAL_OS_BIND_IP" "$PARENTAL_OS_WEB_PORT"
printf 'SSH command: ssh -p %s -i %s/qemu/id_ed25519 child@%s\n' \
  "$PARENTAL_OS_BROWSER_SSH_PORT" "$OUT" "$PARENTAL_OS_BIND_IP"
