#!/usr/bin/env bats
# Enrollment of interactive users into the parental-users group.
#
# parental-os has no admin-user concept: root is the only administrator, and every
# account created on the machine must be in parental-users so that
# `%parental-users ALL=(ALL) NOPASSWD: ALL, !PARENTAL_GUARDED` actually applies.
#
# A real install on 2026-08-10 had parental-guard present, the group created, the
# agent active, `parental-guard status` reporting OK -- and the installed user still
# able to run `sudo su`, because nothing had ever put anyone in the group. These
# cases exist so that cannot recur silently.

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  # overlays/ is the source of truth. scripts/build-parental-guard-arch.sh runs
  # sync-package-from-overlays.sh, which rsyncs overlays/ into the staging src tree,
  # and packages/parental-guard/src/ is gitignored generated output. Asserting
  # against the generated tree would pass while shipping nothing.
  SRC="$TEST_ROOT/overlays"
  ENROLL="$SRC/usr/lib/parental-os/enroll-users.sh"
  GUARD="$SRC/usr/bin/parental-guard"
  FIRST_LOGIN="$SRC/usr/lib/parental-os/first-login.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# A fake root filesystem with a realistic passwd: root, system accounts, service
# accounts with nologin shells, and two real interactive users.
make_fake_root() {
  local fake="$TEST_TMP/fakeroot"
  mkdir -p "$fake/etc"
  cat >"$fake/etc/passwd" <<'EOF'
root:x:0:0::/root:/usr/bin/bash
bin:x:1:1::/:/usr/bin/nologin
daemon:x:2:2::/:/usr/bin/nologin
http:x:33:33::/srv/http:/usr/bin/nologin
nobody:x:65534:65534:Nobody:/:/usr/bin/nologin
cmva:x:1000:1000::/home/cmva:/usr/bin/fish
child:x:1001:1001::/home/child:/bin/bash
svc:x:999:999::/var/lib/svc:/usr/bin/nologin
locked:x:1002:1002::/home/locked:/usr/bin/false
EOF
  cat >"$fake/etc/group" <<'EOF'
root:x:0:
wheel:x:998:cmva
parental-users:x:997:
EOF
  cat >"$fake/etc/login.defs" <<'EOF'
UID_MIN 1000
UID_MAX 60000
EOF
  printf '%s\n' "$fake"
}

# ---------------------------------------------------------------------------
# The enrollment script itself
# ---------------------------------------------------------------------------

@test "enroll-users.sh exists and is executable" {
  [ -f "$ENROLL" ]
  [ -x "$ENROLL" ]
}

@test "enrollment files live in overlays, the tree the package is built from" {
  # packages/parental-guard/src/ is gitignored generated output: the Arch build
  # rsyncs overlays/ over it. Editing only that tree produces changes git cannot
  # see and the next build discards.
  run git -C "$TEST_ROOT" check-ignore -q packages/parental-guard/src
  [ "$status" -eq 0 ]
  for rel in \
    usr/lib/parental-os/enroll-users.sh \
    usr/lib/systemd/system/parental-guard-enroll.service \
    usr/lib/systemd/system/parental-guard-enroll.path; do
    [ -f "$TEST_ROOT/overlays/$rel" ]
    run git -C "$TEST_ROOT" ls-files --error-unmatch "overlays/$rel"
    [ "$status" -eq 0 ]
  done
}

@test "enroll-users.sh lists every interactive user and no system account" {
  fake="$(make_fake_root)"
  run env PARENTAL_OS_ROOT_FS="$fake" bash "$ENROLL" --list
  [ "$status" -eq 0 ]
  # Interactive users, regardless of login shell -- fish must not be treated as
  # less of a user than bash, which is exactly the assumption that broke the
  # profile.d hook.
  [[ "$output" == *"cmva"* ]]
  [[ "$output" == *"child"* ]]
  # root is never enrolled: it is the administrator.
  [[ "$output" != *"root"* ]]
  # System and service accounts are below UID_MIN or have no login shell.
  [[ "$output" != *"http"* ]]
  [[ "$output" != *"daemon"* ]]
  [[ "$output" != *"nobody"* ]]
  [[ "$output" != *"svc"* ]]
  [[ "$output" != *"locked"* ]]
}

@test "enroll-users.sh honours UID_MIN from login.defs" {
  fake="$(make_fake_root)"
  # Raise UID_MIN above cmva so it stops being an interactive candidate.
  printf 'UID_MIN 1001\nUID_MAX 60000\n' >"$fake/etc/login.defs"
  run env PARENTAL_OS_ROOT_FS="$fake" bash "$ENROLL" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmva"* ]]
  [[ "$output" == *"child"* ]]
}

@test "enroll-users.sh does not swallow a usermod failure" {
  # The original first-login.sh masked every error with `|| true` and then marked
  # itself complete, which is why an empty group went unnoticed for so long.
  run grep -nE 'usermod[^|]*\|\|[[:space:]]*true' "$ENROLL"
  [ "$status" -ne 0 ]
}

@test "enroll-users.sh --check fails while an interactive user is unenrolled" {
  fake="$(make_fake_root)"
  # parental-users is empty in the fixture, so the policy applies to nobody. That
  # is the exact state a real install was left in, and it must be reported as a
  # failure rather than passing quietly.
  run env PARENTAL_OS_ROOT_FS="$fake" bash "$ENROLL" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"cmva"* ]]
}

@test "enroll-users.sh --check passes once every interactive user is a member" {
  fake="$(make_fake_root)"
  printf 'parental-users:x:997:cmva,child\n' >>"$fake/etc/group"
  sed -i '/^parental-users:x:997:$/d' "$fake/etc/group"
  run env PARENTAL_OS_ROOT_FS="$fake" bash "$ENROLL" --check
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# It has to be driven by root, at boot, and again when accounts appear
# ---------------------------------------------------------------------------

@test "a systemd unit performs enrollment at boot" {
  unit="$SRC/usr/lib/systemd/system/parental-guard-enroll.service"
  [ -f "$unit" ]
  grep -q 'enroll-users.sh' "$unit"
  grep -qE '^WantedBy=multi-user.target' "$unit"
}

@test "enrollment re-runs when accounts are created later" {
  # The spec calls for automatic policy inheritance for new users. A login hook
  # cannot deliver that: it is shell-dependent and unprivileged. Watch the account
  # database instead.
  path_unit="$SRC/usr/lib/systemd/system/parental-guard-enroll.path"
  [ -f "$path_unit" ]
  grep -q '/etc/passwd' "$path_unit"
  grep -qE '^WantedBy=multi-user.target' "$path_unit"
}

@test "first-login.sh does not mark itself done when enrollment failed" {
  # It may remain as a best-effort secondary path, but it must never record
  # success it did not achieve.
  [ -f "$FIRST_LOGIN" ]
  run grep -nE '(sudo -n|user-setup\.sh).*\|\|[[:space:]]*true' "$FIRST_LOGIN"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# status must stop reporting OK while the policy applies to nobody
# ---------------------------------------------------------------------------

@test "parental-guard status reports enrolled users" {
  grep -q 'enrolled' "$GUARD"
}

@test "parental-guard status does not claim OK when an interactive user is unenrolled" {
  fake="$(make_fake_root)"
  # cmva and child exist as interactive users; parental-users is empty.
  run env PARENTAL_OS_ROOT_FS="$fake" bash "$GUARD" status
  [[ "$output" == *"unenrolled"* ]]
  [[ "$output" != *"result: OK"* ]]
}
