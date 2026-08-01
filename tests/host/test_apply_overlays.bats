#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DEST="$(mktemp -d)"
  export DEST
}

teardown() {
  rm -rf "$DEST"
}

@test "apply-overlays copies sudoers and parental-guard binary" {
  run "$PARENTAL_OS_ROOT/scripts/apply-overlays.sh" "$DEST"
  [ "$status" -eq 0 ]
  [[ -f "$DEST/etc/sudoers.d/parental-os" ]]
  [[ -x "$DEST/usr/bin/parental-guard" ]]
  [[ -f "$DEST/usr/lib/systemd/system/parental-guard-agent.service" ]]
}
