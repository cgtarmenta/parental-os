#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "sudoers drop-in exists" {
  [[ -f "$PARENTAL_OS_ROOT/overlays/etc/sudoers.d/parental-os" ]]
}

@test "sudoers drop-in validates with visudo -cf when visudo exists" {
  if ! command -v visudo >/dev/null; then
    skip "visudo not installed on host"
  fi
  run visudo -cf "$PARENTAL_OS_ROOT/overlays/etc/sudoers.d/parental-os"
  [ "$status" -eq 0 ]
}

@test "polkit rule file exists" {
  [[ -f "$PARENTAL_OS_ROOT/overlays/etc/polkit-1/rules.d/50-parental-os.rules" ]]
}

@test "config.env defines parental-users group" {
  run grep -q 'PARENTAL_OS_GROUP=parental-users' "$PARENTAL_OS_ROOT/overlays/etc/parental-os/config.env"
  [ "$status" -eq 0 ]
}
