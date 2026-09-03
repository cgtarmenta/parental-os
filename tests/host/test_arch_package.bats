#!/usr/bin/env bats
# Tests for parental-guard Arch packaging integration with Rust agent.

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  ARCH_DIR="$PARENTAL_OS_ROOT/packages/parental-guard/arch"
  # shellcheck source=/dev/null
  source "$PARENTAL_OS_ROOT/scripts/lib/common.sh"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
}

skip_if_no_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker_cli info >/dev/null 2>&1 \
    || skip "docker context $DOCKER_CONTEXT is unavailable"
}

assert_success() {
  [ "$status" -eq 0 ]
}

assert_output() {
  if [ "$1" = "--partial" ]; then
    [[ "$output" == *"$2"* ]]
  else
    [ "$output" = "$1" ]
  fi
}

@test "PKGBUILD declares arch x86_64 and aarch64" {
  f="$ARCH_DIR/PKGBUILD"
  [[ -f "$f" ]]
  grep -Eq "arch=\(['\"]?x86_64['\"]?[[:space:]]+['\"]?aarch64['\"]?\)" "$f"
}

@test "PKGBUILD makedepends on cargo and rust" {
  f="$ARCH_DIR/PKGBUILD"
  [[ -f "$f" ]]
  grep -Eq "makedepends=\(.*\bcargo\b" "$f"
  grep -Eq "makedepends=\(.*\brust\b" "$f"
}

@test "PKGBUILD build function compiles Rust agent with cargo build --release --locked" {
  f="$ARCH_DIR/PKGBUILD"
  [[ -f "$f" ]]
  grep -q 'build()' "$f"
  grep -q 'cargo build --release --locked' "$f"
}

@test "PKGBUILD package function installs compiled parental-guard-agent to usr/lib/parental-os/" {
  f="$ARCH_DIR/PKGBUILD"
  [[ -f "$f" ]]
  grep -q 'package()' "$f"
  grep -Eq 'install.*parental-guard-agent.*usr/lib/parental-os/' "$f"
}

@test "build-parental-guard-arch stages agent source directory" {
  f="$PARENTAL_OS_ROOT/scripts/build-parental-guard-arch.sh"
  [[ -f "$f" ]]
  grep -q 'packages/parental-guard/agent' "$f"
}

@test "arch package ships compiled parental-guard-agent binary in usr/lib/parental-os/" {
  skip_if_no_docker
  cd "$PARENTAL_OS_ROOT"
  shopt -s nullglob
  local pkgs=(out/packages/parental-guard-*-*.pkg.tar.zst)
  shopt -u nullglob
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    run tar -tvf out/packages/parental-guard-0.1.0-1-x86_64.pkg.tar.zst
  else
    run tar -tvf "${pkgs[0]}"
  fi
  assert_success
  assert_output --partial "usr/lib/parental-os/parental-guard-agent"
}
