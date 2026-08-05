#!/usr/bin/env bats

setup() {
  PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_ROOT
  PARENTAL_OS_OUT="$(mktemp -d)"
  export PARENTAL_OS_OUT
  source "$PARENTAL_OS_ROOT/scripts/lib/common.sh"
  source "$PARENTAL_OS_ROOT/scripts/lib/qemu.sh"
}

teardown() {
  rm -rf "$PARENTAL_OS_OUT"
}

@test "qemu_targets_for expands all targets in deterministic order" {
  run qemu_targets_for all
  [ "$status" -eq 0 ]
  [ "$output" = $'ubuntu\ncachyos-desktop\ncachyos-handheld' ]
}

@test "qemu_targets_for expands cachyos to both editions" {
  run qemu_targets_for cachyos
  [ "$status" -eq 0 ]
  [ "$output" = $'cachyos-desktop\ncachyos-handheld' ]
}

@test "qemu_targets_for returns ubuntu as a single target" {
  run qemu_targets_for ubuntu
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu" ]
}

@test "qemu_targets_for returns cachyos-desktop as a single target" {
  run qemu_targets_for cachyos-desktop
  [ "$status" -eq 0 ]
  [ "$output" = "cachyos-desktop" ]
}

@test "qemu_targets_for returns cachyos-handheld as a single target" {
  run qemu_targets_for cachyos-handheld
  [ "$status" -eq 0 ]
  [ "$output" = "cachyos-handheld" ]
}

@test "qemu_targets_for rejects unknown targets" {
  run qemu_targets_for windows
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown QEMU target"* ]]
}

@test "qemu_iso_for_target returns newest ISO for target" {
  mkdir -p "$PARENTAL_OS_OUT/ubuntu"
  old="$PARENTAL_OS_OUT/ubuntu/old.iso"
  new="$PARENTAL_OS_OUT/ubuntu/new.iso"
  : >"$old"
  : >"$new"
  touch -d '2026-08-04 00:00:00 UTC' "$old"
  touch -d '2026-08-05 00:00:00 UTC' "$new"

  run qemu_iso_for_target ubuntu
  [ "$status" -eq 0 ]
  [ "$output" = "$new" ]
}

@test "qemu_iso_for_target returns newest ISO for cachyos-desktop" {
  mkdir -p "$PARENTAL_OS_OUT/cachyos/desktop"
  old="$PARENTAL_OS_OUT/cachyos/desktop/old.iso"
  new="$PARENTAL_OS_OUT/cachyos/desktop/new.iso"
  : >"$old"
  : >"$new"
  touch -d '2026-08-04 00:00:00 UTC' "$old"
  touch -d '2026-08-05 00:00:00 UTC' "$new"

  run qemu_iso_for_target cachyos-desktop
  [ "$status" -eq 0 ]
  [ "$output" = "$new" ]
}

@test "qemu_iso_for_target returns newest ISO for cachyos-handheld" {
  mkdir -p "$PARENTAL_OS_OUT/cachyos/handheld"
  old="$PARENTAL_OS_OUT/cachyos/handheld/old.iso"
  new="$PARENTAL_OS_OUT/cachyos/handheld/new.iso"
  : >"$old"
  : >"$new"
  touch -d '2026-08-04 00:00:00 UTC' "$old"
  touch -d '2026-08-05 00:00:00 UTC' "$new"

  run qemu_iso_for_target cachyos-handheld
  [ "$status" -eq 0 ]
  [ "$output" = "$new" ]
}

@test "qemu_iso_for_target fails when requested ISO is missing" {
  mkdir -p "$PARENTAL_OS_OUT/cachyos/desktop"

  run qemu_iso_for_target cachyos-desktop
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ISO found for cachyos-desktop"* ]]
}

@test "qemu_iso_for_target preserves enabled nullglob" {
  mkdir -p "$PARENTAL_OS_OUT/ubuntu"
  iso="$PARENTAL_OS_OUT/ubuntu/test.iso"
  : >"$iso"

  qemu_iso_and_print_nullglob() {
    qemu_iso_for_target ubuntu >/dev/null
    if shopt -q nullglob; then
      printf 'nullglob enabled\n'
    else
      printf 'nullglob disabled\n'
    fi
  }

  shopt -s nullglob
  run qemu_iso_and_print_nullglob
  [ "$status" -eq 0 ]
  [ "$output" = "nullglob enabled" ]
}

@test "qemu_require_single_target defaults to ubuntu" {
  run qemu_require_single_target
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu" ]
}

@test "qemu_require_single_target accepts ubuntu" {
  run qemu_require_single_target ubuntu
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu" ]
}

@test "qemu_require_single_target accepts cachyos-desktop" {
  run qemu_require_single_target cachyos-desktop
  [ "$status" -eq 0 ]
  [ "$output" = "cachyos-desktop" ]
}

@test "qemu_require_single_target accepts cachyos-handheld" {
  run qemu_require_single_target cachyos-handheld
  [ "$status" -eq 0 ]
  [ "$output" = "cachyos-handheld" ]
}

@test "qemu_require_single_target rejects aggregate browser targets" {
  run qemu_require_single_target all
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a single ISO target"* ]]
}

@test "qemu_require_single_target rejects cachyos aggregate browser target" {
  run qemu_require_single_target cachyos
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a single ISO target"* ]]
}

@test "make-cloud-init-seed creates key, rendered user-data, and seed ISO" {
  if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1; then
    skip "missing xorriso, genisoimage, or mkisofs"
  fi

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  [[ -f "$PARENTAL_OS_OUT/qemu/id_ed25519" ]]
  [[ -f "$PARENTAL_OS_OUT/qemu/id_ed25519.pub" ]]
  [ "$(stat -c %a "$PARENTAL_OS_OUT/qemu/id_ed25519")" = "600" ]
  derived_pub="$(ssh-keygen -y -f "$PARENTAL_OS_OUT/qemu/id_ed25519")"
  [ "$(<"$PARENTAL_OS_OUT/qemu/id_ed25519.pub")" = "$derived_pub" ]
  [[ -s "$PARENTAL_OS_OUT/qemu/seed.iso" ]]
  [[ -f "$PARENTAL_OS_OUT/qemu/seed/user-data" ]]
  rendered="$(<"$PARENTAL_OS_OUT/qemu/seed/user-data")"
  [[ "$rendered" != *"SSH_PUBKEY_PLACEHOLDER"* ]]
  [[ "$rendered" == *"$derived_pub"* ]]
  rendered_without_pub="${rendered//$derived_pub/}"
  [ "$(((${#rendered} - ${#rendered_without_pub}) / ${#derived_pub}))" -eq 1 ]
}

@test "make-cloud-init-seed regenerates missing public key from existing private key" {
  if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1; then
    skip "missing xorriso, genisoimage, or mkisofs"
  fi

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  rm "$PARENTAL_OS_OUT/qemu/id_ed25519.pub"

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  [[ -f "$PARENTAL_OS_OUT/qemu/id_ed25519.pub" ]]
  [ "$(<"$PARENTAL_OS_OUT/qemu/id_ed25519.pub")" = "$(ssh-keygen -y -f "$PARENTAL_OS_OUT/qemu/id_ed25519")" ]
  [[ -s "$PARENTAL_OS_OUT/qemu/seed.iso" ]]
}

@test "make-cloud-init-seed replaces stale public key with derived public key" {
  if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1; then
    skip "missing xorriso, genisoimage, or mkisofs"
  fi

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' 'ssh-ed25519 stale-key stale-comment' >"$PARENTAL_OS_OUT/qemu/id_ed25519.pub"

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  derived_pub="$(ssh-keygen -y -f "$PARENTAL_OS_OUT/qemu/id_ed25519")"
  [ "$(<"$PARENTAL_OS_OUT/qemu/id_ed25519.pub")" = "$derived_pub" ]
  rendered="$(<"$PARENTAL_OS_OUT/qemu/seed/user-data")"
  [[ "$rendered" == *"$derived_pub"* ]]
  [[ "$rendered" != *"stale-key"* ]]
}

@test "make-cloud-init-seed creates xorriso-readable CIDATA ISO with root cloud-init files" {
  if ! command -v xorriso >/dev/null 2>&1; then
    skip "missing xorriso"
  fi

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]

  run xorriso -indev "$PARENTAL_OS_OUT/qemu/seed.iso" -pvd_info
  [ "$status" -eq 0 ]
  [[ "$output" == *"Volume id    : 'CIDATA'"* ]]

  run xorriso -indev "$PARENTAL_OS_OUT/qemu/seed.iso" -find / -maxdepth 1 -type f
  [ "$status" -eq 0 ]
  [[ "$output" == *$'/user-data'* ]]
  [[ "$output" == *$'/meta-data'* ]]
}

@test "assert_guest has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -eq 0 ]
}

@test "assert_guest suppresses routine SSH log noise" {
  run grep -q -- 'LogLevel=ERROR' "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -eq 0 ]
}

@test "assert_guest forces the configured SSH identity" {
  run grep -q -- 'IdentitiesOnly=yes' "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -eq 0 ]
}

@test "assert_guest does not depend on curl" {
  run grep -q -- 'curl' "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -ne 0 ]
}

@test "assert_guest uses Python stdlib for health checks" {
  run grep -q -- 'urllib.request' "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -eq 0 ]
}

@test "assert_guest validates sudo denial output" {
  script="$(<"$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh")"
  [[ "$script" == *"not allowed"* ]]
  [[ "$script" == *"may not"* ]]
  [[ "$script" == *"denied"* ]]
}

@test "test-qemu has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/scripts/test-qemu.sh"
  [ "$status" -eq 0 ]
}

@test "test-qemu sources qemu helpers and seed generator" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *"scripts/lib/qemu.sh"* ]]
  [[ "$script" == *"make-cloud-init-seed.sh"* ]]
}

@test "test-qemu uses localhost SSH forwarding and serial logs" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *"hostfwd=tcp:127.0.0.1"* ]]
  [[ "$script" == *"-serial"* ]]
  [[ "$script" == *"out/logs/qemu-"* || "$script" == *"/logs/qemu-"* ]]
}

@test "test-qemu cleans existing pidfile before target artifact removal" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  run_body="${script#*'port="$((SSH_PORT_BASE + index))"'}"
  before_disk_removal="${run_body%%'rm -f "$disk"'*}"
  [[ "$before_disk_removal" == *'kill_qemu_pidfile "$pidfile"'* ]]
}

@test "test-qemu validates process identity before killing pidfile pid" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" != *"QEMU_PIDS"* ]]
  [[ "$script" == *'/proc/$pid/comm'* ]]
  [[ "$script" == *"qemu-system-x86_64"* ]]
}

@test "test-qemu wait loop fails fast when qemu exits" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  wait_body="${script#*'wait_for_guest()'}"
  wait_body="${wait_body%%'run_target()'*}"
  [[ "$wait_body" == *'qemu_pid_is_same_process "$pid" "$start_time"'* ]]
  [[ "$wait_body" == *"serial log"* ]]
}

@test "test-qemu missing pidfile diagnostic points at startup failure and serial log" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *"QEMU may have failed to start"* ]]
  [[ "$script" == *"serial log"* ]]
}

@test "test-qemu revalidates process identity before sigkill escalation" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *$'if qemu_pid_is_same_process "$pid" "$start_time"; then\n      kill -KILL "$pid"'* ]]
}

@test "test-qemu tracks process start time from proc stat" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *'/proc/$pid/stat'* ]]
  [[ "$script" == *'qemu_pid_start_time'* ]]
}

@test "test-qemu stores pid start time before cleanup can kill qemu" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  [[ "$script" == *'printf '\''%s %s\n'\'' "$pid" "$start_time" >"$pidfile"'* ]]
  [[ "$script" == *'if [[ -z "$start_time" ]]; then'* ]]
  [[ "$script" == *'removing stale pidfile without killing'* ]]
}

@test "test-qemu wait loop validates qemu identity beyond kill zero" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/test-qemu.sh")"
  wait_body="${script#*'wait_for_guest()'}"
  wait_body="${wait_body%%'run_target()'*}"
  [[ "$wait_body" == *'qemu_pid_is_same_process "$pid" "$start_time"'* ]]
  [[ "$wait_body" != *'if ! kill -0 "$pid"'* ]]
}

@test "qemu-browser script has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/scripts/qemu-browser.sh"
  [ "$status" -eq 0 ]
}

@test "qemu-browser container entrypoint has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/distros/qemu-browser/entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "qemu-browser defaults noVNC bind to localhost" {
  compose="$(<"$PARENTAL_OS_ROOT/compose.qemu.yml")"
  [[ "$compose" == *'${PARENTAL_OS_BIND_IP:-127.0.0.1}:${PARENTAL_OS_WEB_PORT:-8011}:8006'* ]]
}

@test "Justfile exposes qemu browser targets" {
  justfile="$(<"$PARENTAL_OS_ROOT/Justfile")"
  [[ "$justfile" == *"qemu-browser target="* ]]
  [[ "$justfile" == *"qemu-browser-down"* ]]
}

@test "qemu-browser down mode supplies compose interpolation defaults" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/qemu-browser.sh")"
  down_body="${script#*'if [[ "${1:-}" == "down" ]]; then'}"
  down_body="${down_body%%'fi'*}"
  [[ "$down_body" == *'PARENTAL_OS_ISO_PATH="${PARENTAL_OS_ISO_PATH:-'* ]]
  [[ "$down_body" == *'PARENTAL_OS_BROWSER_TARGET="${PARENTAL_OS_BROWSER_TARGET:-'* ]]
}

@test "qemu-browser compose project identity is worktree-specific by default" {
  script="$(<"$PARENTAL_OS_ROOT/scripts/qemu-browser.sh")"
  [[ "$script" == *'PARENTAL_OS_QEMU_PROJECT:-'* ]]
  [[ "$script" == *'basename "$ROOT"'* ]]
  [[ "$script" != *'PROJECT="parental-os-qemu-browser"'* ]]
}

@test "qemu-browser compose does not hardcode a fixed container name" {
  compose="$(<"$PARENTAL_OS_ROOT/compose.qemu.yml")"
  [[ "$compose" != *'container_name: parental-os-qemu-browser'* ]]
}

@test "qemu-browser state volume is target-specific" {
  compose="$(<"$PARENTAL_OS_ROOT/compose.qemu.yml")"
  [[ "$compose" == *'./out/qemu/browser/${PARENTAL_OS_BROWSER_TARGET'*':/state'* ]]
}

@test "qemu-browser entrypoint binds qemu vnc to container localhost" {
  entrypoint="$(<"$PARENTAL_OS_ROOT/distros/qemu-browser/entrypoint.sh")"
  [[ "$entrypoint" == *'-vnc 127.0.0.1:0'* ]]
}

@test "qemu-browser entrypoint supervises qemu and websockify" {
  entrypoint="$(<"$PARENTAL_OS_ROOT/distros/qemu-browser/entrypoint.sh")"
  [[ "$entrypoint" != *'exec qemu-system-x86_64'* ]]
  [[ "$entrypoint" == *'wait -n'* || "$entrypoint" == *'wait_for_first_exit'* ]]
}
