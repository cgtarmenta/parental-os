#!/usr/bin/env bash
set -euo pipefail

HOST="${1:?host}"
PORT="${2:?port}"
KEY="${3:?key}"

SSH=(
  ssh
  -i "$KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o LogLevel=ERROR
  -o IdentitiesOnly=yes
  -p "$PORT"
  "qa@${HOST}"
)

remote_quiet() {
  "${SSH[@]}" "$1" >/dev/null 2>&1
}

remote_capture() {
  "${SSH[@]}" "$1" 2>&1
}

fail_assertion() {
  local label="$1"
  local status="$2"
  local output="$3"

  printf 'ERROR: %s failed (exit %s)\n' "$label" "$status" >&2
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
  exit 1
}

remote_assert() {
  local label="$1"
  local command="$2"
  local output
  local status

  set +e
  output="$(remote_capture "$command")"
  status="$?"
  set -e

  if [ "$status" -ne 0 ]; then
    fail_assertion "$label" "$status" "$output"
  fi
}

remote_expect_sudo_denied() {
  local label="$1"
  local command="$2"
  local output
  local status

  set +e
  output="$(remote_capture "$command")"
  status="$?"
  set -e

  if [ "$status" -eq 0 ]; then
    printf 'ERROR: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi

  if ! printf '%s\n' "$output" | grep -Eiq 'not allowed|may not|denied'; then
    printf 'ERROR: %s failed without sudo policy denial output (exit %s)\n' "$label" "$status" >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" >&2
    fi
    exit 1
  fi
}

remote_quiet 'test -f /run/parental-os-qemu/bootstrap-complete' || exit 1

health_check=$'python3 - <<\'PY\'\nimport urllib.request\n\nwith urllib.request.urlopen("http://127.0.0.1:7420/health", timeout=5) as response:\n    if response.status != 200:\n        raise SystemExit(f"unexpected status: {response.status}")\nPY'

remote_assert 'child belongs to parental-users' 'groups="$(id -nG child)"; printf "%s\n" "$groups"; printf "%s\n" "$groups" | tr " " "\n" | grep -qx parental-users'
remote_assert 'qa belongs to parental-users' 'groups="$(id -nG qa)"; printf "%s\n" "$groups"; printf "%s\n" "$groups" | tr " " "\n" | grep -qx parental-users'
remote_assert 'parental-guard status works' 'parental-guard status'
remote_assert 'parental-guard.service is active' 'systemctl is-active parental-guard.service'
remote_assert 'parental-guard-agent.service is active' 'systemctl is-active parental-guard-agent.service'
remote_assert 'health endpoint responds' "$health_check"
remote_assert 'qa has baseline sudo access' 'sudo -n true'

remote_expect_sudo_denied 'sudo visudo is denied for parental-users' 'sudo -n visudo -c'
remote_expect_sudo_denied 'stopping parental-guard-agent.service is denied for parental-users' 'sudo -n systemctl stop parental-guard-agent.service'

printf '%s\n' 'assert_guest: OK'
