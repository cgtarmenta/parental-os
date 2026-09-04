#!/usr/bin/env bash
set -euo pipefail

: "${PARENTAL_OS_ISO:?PARENTAL_OS_ISO must point to the mounted ISO inside the container}"

RAM="${PARENTAL_OS_QEMU_RAM:-4096}"
CPUS="${PARENTAL_OS_QEMU_CPUS:-2}"
DISK_SIZE="${PARENTAL_OS_QEMU_DISK_SIZE:-20G}"
STATE_DIR="${PARENTAL_OS_QEMU_STATE_DIR:-/state}"
SEED_ISO="${PARENTAL_OS_QEMU_SEED_ISO:-/out/qemu/seed.iso}"
SSH_PORT="${PARENTAL_OS_CONTAINER_SSH_PORT:-2222}"

mkdir -p "$STATE_DIR"
DISK="$STATE_DIR/browser.qcow2"
if [[ ! -f "$DISK" ]]; then
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

ACCEL="tcg"
CPU="max"
if [[ -r /dev/kvm ]]; then
  ACCEL="kvm"
  CPU="host"
fi

QEMU_PID=""
WEBSOCKIFY_PID=""

cleanup() {
  local pid
  for pid in "${QEMU_PID:-}" "${WEBSOCKIFY_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  for pid in "${QEMU_PID:-}" "${WEBSOCKIFY_PID:-}"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

BOOT_ORDER="order=dc,menu=on"
if [[ "${PARENTAL_OS_BOOT_FROM:-}" == "disk" ]]; then
  BOOT_ORDER="order=c,menu=on"
fi

QEMU_ARGS=(
  -machine "q35,accel=$ACCEL"
  -cpu "$CPU"
  -m "$RAM"
  -smp "$CPUS"
  -boot "$BOOT_ORDER"
  -drive "file=$DISK,if=virtio,format=qcow2"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${AGENT_PORT:-7420}-:7420"
  -device virtio-net-pci,netdev=net0
  -vga virtio
  -display none
  -vnc 127.0.0.1:0
  -serial mon:stdio
  -monitor "unix:$STATE_DIR/monitor.sock,server,nowait"
)

if [[ -f "$PARENTAL_OS_ISO" && "$PARENTAL_OS_ISO" != "/dev/null" && "${PARENTAL_OS_BOOT_FROM:-}" != "disk" ]]; then
  QEMU_ARGS+=( -cdrom "$PARENTAL_OS_ISO" )
fi

if [[ "${PARENTAL_OS_ATTACH_SEED:-0}" == "1" && -f "$SEED_ISO" ]]; then
  QEMU_ARGS+=( -drive "file=$SEED_ISO,media=cdrom,readonly=on" )
fi

printf 'Starting QEMU browser VM: iso=%s accel=%s ram=%s cpus=%s\n' \
  "$PARENTAL_OS_ISO" "$ACCEL" "$RAM" "$CPUS" >&2

websockify --web=/usr/share/novnc 0.0.0.0:8006 127.0.0.1:5900 &
WEBSOCKIFY_PID="$!"

qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID="$!"

set +e
wait -n "$QEMU_PID" "$WEBSOCKIFY_PID"
STATUS="$?"
set -e

cleanup
trap - EXIT
exit "$STATUS"
