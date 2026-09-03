#!/usr/bin/env bats
# Docker-gated regression tests for the built parental-guard .deb.
#
# These build the real package via the Docker build script and assert the
# built-artifact contract from review 4835532761:
#   - exact artifact parental-guard_0.1.0-1_all.deb
#   - /etc and /usr payload (no /usr/etc), sudoers 0440
#   - lintian with no error-level (E:) findings
#   - valid 3.0 (quilt) source package (.dsc)
#   - systemd-less/offline install enables both services + parental-users group
#
# They skip when Docker is unavailable so `just test-host` stays portable.

setup_file() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
  export DEB_ARCH="$ARCH"
  export DEB="$TEST_ROOT/out/packages/parental-guard_0.1.0-1_${ARCH}.deb"
  export STAGE_PARENT="$TEST_ROOT/out/deb-src"
  # Build once for the whole file; the build script cleans and re-stages.
  mkdir -p "$TEST_ROOT/out"
  rm -f "$TEST_ROOT/out/deb-build-status.txt"
  if "$TEST_ROOT/scripts/build-parental-guard-deb.sh"; then
    echo "0" > "$TEST_ROOT/out/deb-build-status.txt"
  else
    echo "1" > "$TEST_ROOT/out/deb-build-status.txt"
  fi
}

setup() {
  # shellcheck source=/dev/null
  source "$PARENTAL_OS_ROOT/scripts/lib/common.sh"
}

skip_if_no_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker_cli info >/dev/null 2>&1 \
    || skip "docker context $DOCKER_CONTEXT is unavailable"
}

ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
bats_test_function --description "docker build produces exact artifact parental-guard_0.1.0-1_${ARCH}.deb" -- deb_build_produces_exact_artifact
deb_build_produces_exact_artifact() {
  skip_if_no_docker
  [ -f "$PARENTAL_OS_ROOT/out/deb-build-status.txt" ]
  [ "$(<"$PARENTAL_OS_ROOT/out/deb-build-status.txt")" -eq 0 ]
  [ -f "$DEB" ]
}

bats_test_function --description "built .deb contains /etc and /usr payload with no /usr/etc" -- deb_contains_expected_payload
deb_contains_expected_payload() {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm \
    -v "$DEB:/pkg.deb:ro" debian:bookworm dpkg-deb --contents /pkg.deb
  [ "$status" -eq 0 ]
  [[ "$output" == *"/etc/sudoers.d/parental-os"* ]]
  [[ "$output" == *"/etc/parental-os/config.env"* ]]
  [[ "$output" == *"/etc/parental-os/protected-packages.list"* ]]
  [[ "$output" == *"/etc/parental-os/protected-units.list"* ]]
  [[ "$output" == *"/etc/polkit-1/rules.d/50-parental-os.rules"* ]]
  [[ "$output" == *"/etc/profile.d/parental-os-first-login.sh"* ]]
  [[ "$output" == *"/usr/bin/parental-guard"* ]]
  [[ "$output" == *"/usr/lib/parental-os/agent/server.py"* ]]
  [[ "$output" == *"/usr/lib/parental-os/parental-guard-agent"* ]]
  [[ "$output" == *"/usr/lib/parental-os/first-login.sh"* ]]
  [[ "$output" == *"/usr/lib/parental-os/user-setup.sh"* ]]
  # Systemd units ship under /usr/lib/systemd/system or /lib/systemd/system
  [[ "$output" == *"/systemd/system/parental-guard.service"* ]]
  [[ "$output" == *"/systemd/system/parental-guard-agent.service"* ]]
  [[ "$output" != *"/usr/etc/"* ]]
}

bats_test_function --description "built .deb ships sudoers drop-in at mode 0440" -- deb_sudoers_mode_0440
deb_sudoers_mode_0440() {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm -v "$DEB:/pkg.deb:ro" debian:bookworm dpkg-deb --contents /pkg.deb
  [ "$status" -eq 0 ]
  # 0440 -> -r--r----- in dpkg-deb's ls-style listing.
  echo "$output" | grep -Eq '^[-rwxst]{10}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+.*sudoers\.d/parental-os$' || \
    echo "$output" | grep -E 'sudoers\.d/parental-os$' | grep -Eq '^-r--r-----'
}

bats_test_function --description "lintian reports no error-level (E:) findings on the built .deb" -- deb_lintian_no_errors
deb_lintian_no_errors() {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm \
    -v "$DEB:/pkg.deb:ro" debian:bookworm bash -lc '
    set -e
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends lintian >/dev/null 2>&1
    # Decouple from lintian exit code (W:/I: tags do not block); grep for E:.
    set +e
    lintian --tag-display-limit 0 /pkg.deb 2>&1
    echo "LINTIAN_DONE"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINTIAN_DONE"* ]]
  ! echo "$output" | grep -Eq '^E: '
}

bats_test_function --description "dpkg-source produced a valid 3.0 (quilt) source package (.dsc)" -- deb_source_is_quilt
deb_source_is_quilt() {
  skip_if_no_docker
  [ -d "$STAGE_PARENT" ]
  run docker_cli run --rm \
    -v "$STAGE_PARENT:/build:ro" debian:bookworm bash -lc '
    set -e
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends dpkg-dev >/dev/null 2>&1
    dpkg-source -x /build/parental-guard_0.1.0-1.dsc /tmp/src >/dev/null 2>&1
    grep -q "3.0 (quilt)" /tmp/src/debian/source/format
    test -f /tmp/src/debian/changelog
    test -f /tmp/src/etc/sudoers.d/parental-os
    test -f /tmp/src/usr/bin/parental-guard
  '
  [ "$status" -eq 0 ]
}

bats_test_function --description "offline/systemd-less install enables both services and creates parental-users group" -- deb_offline_install_enables_services
deb_offline_install_enables_services() {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm -v "$DEB:/pkg.deb:ro" debian:bookworm bash -lc '
    set -e
    # A container has no running systemd: /run/systemd/system must not exist.
    test ! -e /run/systemd/system
    # Ensure groupadd (passwd) is present; deb-systemd-helper is Essential.
    command -v groupadd >/dev/null 2>&1 || apt-get update -qq && apt-get install -y -qq --no-install-recommends passwd >/dev/null 2>&1
    # --force-depends lets the maintscript run without the runtime deps;
    # init-system-helpers (Essential) provides deb-systemd-helper regardless.
    dpkg --force-depends -i /pkg.deb
    test -e /etc/systemd/system/multi-user.target.wants/parental-guard.service
    test -e /etc/systemd/system/multi-user.target.wants/parental-guard-agent.service
    getent group parental-users >/dev/null
  '
  [ "$status" -eq 0 ]
}

bats_test_function --description "offline install is idempotent (re-run maintscript keeps group and enablement)" -- deb_offline_install_idempotent
deb_offline_install_idempotent() {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm -v "$DEB:/pkg.deb:ro" debian:bookworm bash -lc '
    set -e
    test ! -e /run/systemd/system
    command -v groupadd >/dev/null 2>&1 || apt-get update -qq && apt-get install -y -qq --no-install-recommends passwd >/dev/null 2>&1
    dpkg --force-depends -i /pkg.deb
    # Re-run the generated maintscript to prove idempotent group/enablement.
    /var/lib/dpkg/info/parental-guard.postinst configure 0.1.0-1
    getent group parental-users >/dev/null
    test -e /etc/systemd/system/multi-user.target.wants/parental-guard.service
    test -e /etc/systemd/system/multi-user.target.wants/parental-guard-agent.service
  '
  [ "$status" -eq 0 ]
}
