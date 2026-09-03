#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/qemu.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd ssh

TARGET="${1:-all}"
OUT="$(out_root)"
RAM="${PARENTAL_OS_QEMU_RAM:-2048}"
CPUS="${PARENTAL_OS_QEMU_CPUS:-2}"
SSH_PORT_BASE="${PARENTAL_OS_QEMU_SSH_PORT_BASE:-2220}"
ATTEMPTS="${PARENTAL_OS_QEMU_ATTEMPTS:-120}"
SLEEP_SECONDS="${PARENTAL_OS_QEMU_SLEEP_SECONDS:-5}"
SEED_ISO="$OUT/qemu/seed.iso"
KEY="$OUT/qemu/id_ed25519"
ASSERT_GUEST="$ROOT/tests/qemu/assert_guest.sh"

QEMU_PIDFILES=()

qemu_pid_matches_expected_process() {
  local pid="$1"
  local comm

  if [[ -r "/proc/$pid/comm" ]]; then
    comm="$(<"/proc/$pid/comm")"
    [[ "$comm" == qemu-system-x86_64 || "$comm" == qemu-system-x86* ]]
    return $?
  fi

  return 0
}

qemu_pid_start_time() {
  local pid="$1"
  local stat rest

  if [[ ! -r "/proc/$pid/stat" ]]; then
    return 0
  fi

  stat="$(<"/proc/$pid/stat")"
  rest="${stat##*) }"
  set -- $rest
  printf '%s\n' "${20:-}"
}

qemu_pid_is_same_process() {
  local pid="$1"
  local start_time="$2"
  local current_start_time

  kill -0 "$pid" 2>/dev/null || return 1
  qemu_pid_matches_expected_process "$pid" || return 1

  if [[ -n "$start_time" ]]; then
    current_start_time="$(qemu_pid_start_time "$pid")"
    [[ "$current_start_time" == "$start_time" ]] || return 1
  fi
}

kill_qemu_pidfile() {
  local pidfile="$1"
  local pid start_time

  if [[ ! -f "$pidfile" ]]; then
    return 0
  fi

  read -r pid start_time _ <"$pidfile" || true
  start_time="${start_time:-}"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if [[ -z "$start_time" ]]; then
      log "warning: $pidfile lacks a stored process start time; removing stale pidfile without killing"
      rm -f "$pidfile"
      return 0
    fi

    if ! qemu_pid_is_same_process "$pid" "$start_time"; then
      log "warning: $pidfile points to non-QEMU process $pid; removing stale pidfile without killing"
      rm -f "$pidfile"
      return 0
    fi

    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.25
    done
    if qemu_pid_is_same_process "$pid" "$start_time"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$pidfile"
}

cleanup_qemu() {
  local pidfile
  for pidfile in "${QEMU_PIDFILES[@]}"; do
    kill_qemu_pidfile "$pidfile"
  done
}

trap cleanup_qemu EXIT
trap 'cleanup_qemu; exit 130' INT
trap 'cleanup_qemu; exit 143' TERM

qemu_acceleration_args() {
  if [[ -r /dev/kvm ]]; then
    printf '%s\n' -enable-kvm -cpu host
  else
    log "warning: /dev/kvm is not readable; using software emulation"
  fi
}

wait_for_guest() {
  local target="$1"
  local port="$2"
  local pid="$3"
  local start_time="$4"
  local log_file="$5"
  local attempt output status

  for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    if ! qemu_pid_is_same_process "$pid" "$start_time"; then
      die "$target: QEMU exited or its PID was reused before guest assertions completed; see serial log: $log_file"
    fi

    set +e
    output="$($ASSERT_GUEST 127.0.0.1 "$port" "$KEY" 2>&1)"
    status="$?"
    set -e

    if [[ "$status" -eq 0 ]]; then
      log "$target: guest assertions passed"
      return 0
    fi

    if [[ -n "$output" ]]; then
      log "$target: guest assertions not ready on attempt $attempt/$ATTEMPTS"
      log "$output"
    else
      log "$target: waiting for guest bootstrap marker on attempt $attempt/$ATTEMPTS"
    fi

    sleep "$SLEEP_SECONDS"
  done

  die "$target: guest assertions failed after $ATTEMPTS attempts; see serial log: $log_file"
}

run_target() {
  local target="$1"
  local index="$2"
  local iso disk pidfile log_file port pid start_time
  local accel_args=()

  iso="$(qemu_iso_for_target "$target")"
  disk="$OUT/qemu/${target}.qcow2"
  pidfile="$OUT/qemu/${target}.pid"
  log_file="$OUT/logs/qemu-${target}.serial.log"
  port="$((SSH_PORT_BASE + index))"

  kill_qemu_pidfile "$pidfile"
  rm -f "$disk"
  : >"$log_file"
  qemu-img create -f qcow2 "$disk" 20G >/dev/null

  mapfile -t accel_args < <(qemu_acceleration_args)

  log "$target: booting $iso with SSH forwarded on 127.0.0.1:$port"
  qemu-system-x86_64 \
    "${accel_args[@]}" \
    -m "$RAM" \
    -smp "$CPUS" \
    -boot d \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -cdrom "$iso" \
    -drive "file=$SEED_ISO,if=none,id=seed,format=raw,media=cdrom,readonly=on" \
    -device virtio-scsi-pci \
    -device scsi-cd,drive=seed \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$log_file" \
    -pidfile "$pidfile" \
    -daemonize

  [[ -f "$pidfile" ]] || die "$target: QEMU may have failed to start; pidfile was not created: $pidfile; see serial log: $log_file"
  pid="$(<"$pidfile")"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "$target: QEMU wrote an invalid pidfile: $pidfile; see serial log: $log_file"
  start_time="$(qemu_pid_start_time "$pid")"
  [[ -n "$start_time" ]] || die "$target: could not read QEMU process start time: $pidfile; see serial log: $log_file"
  printf '%s %s\n' "$pid" "$start_time" >"$pidfile"
  qemu_pid_is_same_process "$pid" "$start_time" \
    || die "$target: pidfile does not point to qemu-system-x86_64: $pidfile; see serial log: $log_file"
  QEMU_PIDFILES+=("$pidfile")

  if wait_for_guest "$target" "$port" "$pid" "$start_time" "$log_file"; then
    kill_qemu_pidfile "$pidfile"
    return 0
  fi
}

targets_text="$(qemu_targets_for "$TARGET")"
mapfile -t TARGETS <<<"$targets_text"

"$ROOT/scripts/make-cloud-init-seed.sh"
[[ -s "$SEED_ISO" ]] || die "seed ISO was not created: $SEED_ISO"
[[ -f "$KEY" ]] || die "SSH key was not created: $KEY"

for i in "${!TARGETS[@]}"; do
  run_target "${TARGETS[$i]}" "$i"
done

log "QEMU harness completed for target=$TARGET"
