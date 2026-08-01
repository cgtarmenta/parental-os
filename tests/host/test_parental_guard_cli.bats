#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  chmod +x "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" 2>/dev/null || true
}

@test "parental-guard status exits 0 on overlay tree with config" {
  run env PARENTAL_OS_ROOT_FS="$PARENTAL_OS_ROOT/overlays" \
    "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"parental-os"* ]] || [[ "$output" == *"OK"* ]] || [[ "$output" == *"status"* ]]
}

@test "parental-guard doctor mentions group" {
  run env PARENTAL_OS_ROOT_FS="$PARENTAL_OS_ROOT/overlays" \
    "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"parental-users"* ]]
}
