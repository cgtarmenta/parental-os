#!/usr/bin/env bats
# Static regression tests for the parental-guard Debian packaging metadata.
#
# These tests guard the canonical committed debian/ tree and the build script
# against the four blocking findings from review 4835532761:
#   1. install manifest `etc usr` installs /etc under /usr (wrong layout/modes).
#   2. source/format 3.0 (native) + changelog 0.1.0-1 breaks dpkg-source -b.
#   3. build script rewrites committed metadata after staging.
#   4. postinst gates enablement on /run/systemd/system and swallows errors.
#
# They run on the host without Docker so `just test-host` stays fast. The
# built-artifact assertions live in test_deb_package_build.bats (Docker-gated).

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DEB_DIR="$PARENTAL_OS_ROOT/packages/parental-guard/debian"
}

@test "install manifest maps etc to root and systemd units to lib/systemd/system" {
  f="$DEB_DIR/parental-guard.install"
  [[ -f "$f" ]]
  # etc must map to the filesystem root -> /etc, never under /usr.
  grep -Eq '^etc[[:space:]]+/$' "$f"
  ! grep -Eq '^etc[[:space:]]+usr([[:space:]]|$)' "$f"
  # usr/bin must land at /usr/bin (dest parent is usr/).
  grep -Eq '^usr/bin[[:space:]]+usr/' "$f"
  # parental-os library must land at /usr/lib/parental-os.
  grep -Eq '^usr/lib/parental-os[[:space:]]+usr/lib/' "$f"
  # systemd units must map to lib/systemd so dh_installsystemd detects them.
  grep -Eq '^usr/lib/systemd/system[[:space:]]+lib/systemd/' "$f"
}

@test "source format is 3.0 (quilt) to match the 0.1.0-1 Debian revision" {
  f="$DEB_DIR/source/format"
  [[ -f "$f" ]]
  run cat "$f"
  [[ "$output" == *"3.0 (quilt)"* ]]
  [[ "$output" != *"3.0 (native)"* ]]
}

@test "rules chmod sudoers 0440 inside override_dh_fixperms after dh_fixperms" {
  f="$DEB_DIR/rules"
  [[ -f "$f" ]]
  # override_dh_fixperms must exist and call dh_fixperms before the chmod,
  # otherwise dh_fixperms resets the sudoers file to 0644 after us.
  grep -q 'override_dh_fixperms' "$f"
  grep -q 'dh_fixperms' "$f"
  grep -Eq 'chmod[[:space:]]+0440.*sudoers\.d/parental-os' "$f"
  # The chmod must NOT live in override_dh_auto_install (runs before dh_fixperms).
  ! grep -q 'override_dh_auto_install' "$f" || \
    ! sed -n '/override_dh_auto_install/,/^[^[:space:]\t]/p' "$f" | grep -Eq 'chmod.*04?40.*sudoers'
}

@test "postinst uses the #DEBHELPER# token for deb-systemd-helper integration" {
  f="$DEB_DIR/postinst"
  [[ -f "$f" ]]
  # dh_installsystemd inserts deb-systemd-helper enable calls at this token,
  # which creates the WantedBy symlinks without a running systemd (chroot-safe).
  grep -q '#DEBHELPER#' "$f"
}

@test "postinst does not gate service enablement on /run/systemd/system" {
  f="$DEB_DIR/postinst"
  [[ -f "$f" ]]
  # The old guard skipped enablement entirely in image/chroot builds where
  # systemd is not running. deb-systemd-helper works without a running systemd.
  ! grep -q '/run/systemd/system' "$f"
  ! grep -Eq 'systemctl[[:space:]]+(daemon-reload|enable)' "$f"
}

@test "postinst creates the parental-users group idempotently" {
  f="$DEB_DIR/postinst"
  [[ -f "$f" ]]
  grep -q 'parental-users' "$f"
  # Idempotent: check existence with getent before creating.
  grep -Eq 'getent[[:space:]]+group[[:space:]]+parental-users' "$f"
  grep -Eq 'groupadd[[:space:]]+--system[[:space:]]+parental-users' "$f"
}

@test "postinst does not swallow group-creation errors" {
  f="$DEB_DIR/postinst"
  [[ -f "$f" ]]
  grep -q 'set -e' "$f"
  # No blind `groupadd ... || true` that hides real failures.
  ! grep -Eq 'groupadd.*\|\|[[:space:]]*true' "$f"
}

@test "build script does not rewrite staged debian metadata" {
  f="$PARENTAL_OS_ROOT/scripts/build-parental-guard-deb.sh"
  [[ -f "$f" ]]
  # The committed debian/ directory is canonical; the build must copy it
  # unchanged into the stage instead of overwriting templates after staging.
  ! grep -Fq 'cat >"$STAGE/debian/parental-guard.install"' "$f"
  ! grep -Fq 'cat >"$STAGE/debian/rules"' "$f"
  ! grep -Fq 'cat >"$STAGE/debian/postinst"' "$f"
  ! grep -Fq '"$STAGE/debian/source/format"' "$f"
}

@test "build script asserts staged debian/ equals committed templates" {
  f="$PARENTAL_OS_ROOT/scripts/build-parental-guard-deb.sh"
  [[ -f "$f" ]]
  # Equality/non-rewrite guard: diff the staged debian/ against the committed
  # tree and fail the build on divergence.
  grep -Eq 'diff[[:space:]]+-r' "$f"
  grep -Eq 'packages/parental-guard/debian' "$f"
  grep -Eq '\$STAGE/debian' "$f"
}

@test "debian dirs file declares var/lib/parental-os runtime state dir" {
  f="$DEB_DIR/parental-guard.dirs"
  [[ -f "$f" ]]
  grep -Eq '^var/lib/parental-os/?$' "$f"
}

@test "debian changelog retains the required 0.1.0-1 version" {
  f="$DEB_DIR/changelog"
  [[ -f "$f" ]]
  head -1 "$f" | grep -Eq '^parental-guard \(0\.1\.0-1\) '
}

@test "control declares parental-guard Architecture: all with runtime deps" {
  f="$PARENTAL_OS_ROOT/packages/parental-guard/debian/control"
  [[ -f "$f" ]]
  grep -Eq '^Package: parental-guard$' "$f"
  grep -Eq '^Architecture: all$' "$f"
  grep -Eq '^Depends:.*\$\{misc:Depends\}' "$f"
  grep -q 'python3' "$f"
  grep -q 'sudo' "$f"
  # Must not depend on essential bash without a version (lintian E:).
  ! grep -Eq '^Depends:.*\bbash\b([^(]|$)' "$f"
}

@test "control build-depends on debhelper-compat 13" {
  f="$PARENTAL_OS_ROOT/packages/parental-guard/debian/control"
  grep -Eq 'debhelper-compat \(= 13\)' "$f"
}

@test "overlays payload includes CLI, agent, both systemd units, and /etc policies/hooks" {
  o="$PARENTAL_OS_ROOT/overlays"
  [[ -x "$o/usr/bin/parental-guard" ]]
  [[ -f "$o/usr/lib/parental-os/agent/server.py" ]]
  [[ -f "$o/usr/lib/parental-os/first-login.sh" ]]
  [[ -f "$o/usr/lib/parental-os/user-setup.sh" ]]
  [[ -f "$o/usr/lib/systemd/system/parental-guard.service" ]]
  [[ -f "$o/usr/lib/systemd/system/parental-guard-agent.service" ]]
  [[ -f "$o/etc/parental-os/config.env" ]]
  [[ -f "$o/etc/parental-os/protected-packages.list" ]]
  [[ -f "$o/etc/parental-os/protected-units.list" ]]
  [[ -f "$o/etc/polkit-1/rules.d/50-parental-os.rules" ]]
  [[ -f "$o/etc/profile.d/parental-os-first-login.sh" ]]
  [[ -f "$o/etc/sudoers.d/parental-os" ]]
}

@test "both systemd units declare WantedBy=multi-user.target for enablement" {
  o="$PARENTAL_OS_ROOT/overlays"
  grep -q 'WantedBy=multi-user.target' "$o/usr/lib/systemd/system/parental-guard.service"
  grep -q 'WantedBy=multi-user.target' "$o/usr/lib/systemd/system/parental-guard-agent.service"
}
