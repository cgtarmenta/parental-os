#!/usr/bin/env bats

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/common.sh"
}

@test "repo_root points at directory containing Justfile or docs/superpowers" {
  root="$(repo_root)"
  [[ -d "$root/docs/superpowers/specs" ]]
}

@test "ensure_out_dirs creates expected out subdirectories" {
  ensure_out_dirs
  root="$(repo_root)"
  [[ -d "$root/out/ubuntu" ]]
  [[ -d "$root/out/cachyos" ]]
  [[ -d "$root/out/packages" ]]
  [[ -d "$root/out/logs" ]]
  [[ -d "$root/out/qemu" ]]
}
