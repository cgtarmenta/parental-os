#!/usr/bin/env bats

# Validate tests/qemu/assert_target.sh without a live QEMU target.
# SSH is mocked by putting a fake ssh first in PATH.

setup() {
  PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_ROOT
  ASSERT="$PARENTAL_OS_ROOT/tests/qemu/assert_target.sh"
  export ASSERT
  export PARENTAL_OS_OUT="$(mktemp -d)"
  export PARENTAL_OS_BIND_IP=127.0.0.1
  export PARENTAL_OS_BROWSER_SSH_PORT=2222
  export PARENTAL_OS_TARGET_USER=testchild
  export PARENTAL_OS_ASSERT_RETRIES=2
  export PARENTAL_OS_ASSERT_RETRY_SLEEP=0
  mkdir -p "$PARENTAL_OS_OUT/qemu"
  : >"$PARENTAL_OS_OUT/qemu/id_ed25519"
  MOCK_BIN="$(mktemp -d)"
  export MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$PARENTAL_OS_OUT" "$MOCK_BIN"
}

# Fake ssh: exit 0 for the wait_for_target probe ("true"), exit 1 for all
# other commands. This simulates a target where every assertion command fails.
mock_ssh_fail_checks() {
  cat >"$MOCK_BIN/ssh" <<SH
#!/usr/bin/env bash
for last in "\$@"; do :; done
if [ "\$last" = "true" ]; then exit 0; fi
exit 1
SH
  chmod +x "$MOCK_BIN/ssh"
}

# Fake ssh: exit 0 for everything (all checks pass).
mock_ssh_pass_all() {
  cat >"$MOCK_BIN/ssh" <<SH
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$MOCK_BIN/ssh"
}

# Fake ssh: record all args to a log file (for connection-arg checks).
mock_ssh_record() {
  cat >"$MOCK_BIN/ssh" <<SH
#!/usr/bin/env bash
for last in "\$@"; do :; done
if [ "\$last" = "true" ]; then exit 0; fi
printf '%s ' "\$@" >> "$MOCK_BIN/ssh_calls.log"
echo >> "$MOCK_BIN/ssh_calls.log"
exit 0
SH
  chmod +x "$MOCK_BIN/ssh"
}

@test "assert_target.sh parses (bash -n)" {
  run bash -n "$ASSERT"
  [ "$status" -eq 0 ]
}

@test "assert_target.sh is executable" {
  [ -x "$ASSERT" ]
}

@test "script uses BatchMode and IdentitiesOnly" {
  grep -q BatchMode=yes "$ASSERT"
  grep -q IdentitiesOnly=yes "$ASSERT"
  grep -q StrictHostKeyChecking=no "$ASSERT"
}

@test "script has check / expect_today / wait_for_target helpers" {
  grep -q '^check()' "$ASSERT"
  grep -q '^expect_today()' "$ASSERT"
  grep -q '^wait_for_target()' "$ASSERT"
}

@test "script asserts booted-from-disk, agent health, no build scaffolding" {
  grep -q archisobasedir= "$ASSERT"
  grep -q parental-guard-agent.service "$ASSERT"
  grep -q 7420 "$ASSERT"
  grep -q srv/parental-os-repo "$ASSERT"
}

@test "script exits 1 when target is unreachable" {
  cat >"$MOCK_BIN/ssh" <<SH
#!/usr/bin/env bash
exit 255
SH
  chmod +x "$MOCK_BIN/ssh"
  run "$ASSERT"
  [ "$status" -eq 1 ]
}

@test "script exits 0 when all checks pass (mocked ssh succeeds)" {
  mock_ssh_pass_all
  run "$ASSERT"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "script exits 1 and counts failures when checks fail" {
  mock_ssh_fail_checks
  run "$ASSERT"
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
}

@test "expect_today reports as-expected-today when all ssh succeeds" {
  mock_ssh_pass_all
  run "$ASSERT"
  [[ "$output" == *as-expected-today* ]]
}

@test "connection args honour target user and SSH port" {
  mock_ssh_record
  run "$ASSERT"
  [ "$status" -eq 0 ]
  grep -q -- '-p 2222' "$MOCK_BIN/ssh_calls.log"
  grep -q -- 'testchild@127.0.0.1' "$MOCK_BIN/ssh_calls.log"
}
