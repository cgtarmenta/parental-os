#!/usr/bin/env bash
# Assertions against the INSTALLED target, run over SSH after scripts/test-install.sh
# phase 2 (the unattended Calamares install completes, QEMU reboots off the virtio
# disk, and the installed system comes up). Distinct from assert_guest.sh, which
# asserts against the live ISO image.
#
# Cases marked EXPECTED-TODAY record defects the re-plan documents but SP-B has not
# fixed yet. They assert the CURRENT behaviour on purpose, so SP-B's fix is what
# flips them. Do not "fix" them here -- an assertion that already encoded the fix
# would go green before any fix existed, which is exactly the failure mode this
# project has hit repeatedly.
#
# Usage:
#   tests/qemu/assert_target.sh [HOST [PORT]]
#
# Connection (matching scripts/qemu-browser.sh):
#   HOST  defaults to $PARENTAL_OS_BIND_IP or 127.0.0.1
#   PORT  defaults to $PARENTAL_OS_BROWSER_SSH_PORT or 2222 (the qemu-browser default)
#   KEY   defaults to $PARENTAL_OS_SSH_KEY or <out_root>/qemu/id_ed25519
#         (out_root honours PARENTAL_OS_OUT, then $PARENTAL_OS_ROOT/out, then a
#          repo-root walk -- the same path make-cloud-init-seed.sh writes)
#   USER  defaults to $PARENTAL_OS_TARGET_USER or testchild (users.conf preset)
set -uo pipefail

# Locate the repo so we can resolve the generated SSH key the same way the rest
# of the harness does. common.sh sets -euo pipefail on its own; that is fine.
ROOT_FROM_SELF=""
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/../../Justfile" ]]; then
  ROOT_FROM_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if [[ -n "${PARENTAL_OS_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  source "$PARENTAL_OS_ROOT/scripts/lib/common.sh"
elif [[ -n "$ROOT_FROM_SELF" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT_FROM_SELF/scripts/lib/common.sh"
  export PARENTAL_OS_ROOT="$ROOT_FROM_SELF"
fi

HOST="${1:-${PARENTAL_OS_BIND_IP:-127.0.0.1}}"
SSH_PORT="${2:-${PARENTAL_OS_BROWSER_SSH_PORT:-2222}}"
USER_NAME="${PARENTAL_OS_TARGET_USER:-testchild}"

if [[ -n "${PARENTAL_OS_SSH_KEY:-}" ]]; then
  KEY="$PARENTAL_OS_SSH_KEY"
elif command -v out_root >/dev/null 2>&1; then
  KEY="$(out_root)/qemu/id_ed25519"
else
  KEY="${PARENTAL_OS_ROOT:-$ROOT_FROM_SELF}/out/qemu/id_ed25519"
fi

# The agent binds to 127.0.0.1:7420 on the target (overlays/etc/parental-os/config.env).
# assert_guest.sh probes the same endpoint; the port is read from the environment only
# so a future off-default deploy can override it without editing this file.
AGENT_PORT="${PARENTAL_OS_AGENT_PORT:-7420}"

# How many times to wait for the target to become reachable before giving up.
RETRIES="${PARENTAL_OS_ASSERT_RETRIES:-30}"
RETRY_SLEEP="${PARENTAL_OS_ASSERT_RETRY_SLEEP:-5}"

fails=0

# Single SSH invocation helper. BatchMode=yes so a missing/authorised-key problem
# fails fast instead of hanging on a password prompt. IdentitiesOnly so a loaded
# ssh-agent key cannot masquerade as the generated one.
r() {
  ssh -p "$SSH_PORT" -i "$KEY" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes \
    -o LogLevel=ERROR -o IdentitiesOnly=yes \
    "$USER_NAME@$HOST" "$@" 2>/dev/null
}

# A normal assertion: PASS when the remote command exits 0.
check() { # name, command
  printf '  %-58s ' "$1"
  if r "$2" >/dev/null; then
    echo "PASS"
  else
    echo "FAIL"
    fails=$((fails + 1))
  fi
}

# EXPECTED-TODAY: the command currently SUCCEEDS because the defect is present.
# When SP-B fixes the defect the command starts failing, and this branch tells the
# reader exactly which file/section to update instead of silently going green.
expect_today() { # name, command, note
  printf '  %-58s ' "$1"
  if r "$2" >/dev/null; then
    echo "as-expected-today ($3)"
  else
    echo "CHANGED -- update this file and the re-plan ($3)"
    fails=$((fails + 1))
  fi
}

# Wait for the target to accept an SSH connection before running the suite. The
# installed system takes a while to come up after QEMU reboots off the disk; without
# this the first few checks would report FAIL purely because sshd was not up yet.
wait_for_target() {
  local attempt
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    if r 'true' >/dev/null 2>&1; then
      printf 'target reachable on attempt %s/%s\n' "$attempt" "$RETRIES"
      return 0
    fi
    sleep "$RETRY_SLEEP"
  done
  printf 'target not reachable after %s attempts (%s:%s as %s)\n' \
    "$RETRIES" "$HOST" "$SSH_PORT" "$USER_NAME" >&2
  return 1
}

if ! wait_for_target; then
  exit 1
fi

# ---------------------------------------------------------------------------
# The system booted off the installed disk, not the live ISO.
# ---------------------------------------------------------------------------
# archiso sets archisobasedir= on the kernel command line and mounts the live
# medium at /run/archiso (see archiso's airootfs init). Neither exists on a
# disk-installed boot. Asserting this first means the rest of the checks cannot
# pass against the live image by accident.
echo "=== booted from disk, not the live ISO ==="
check "no archisobasedir= on kernel cmdline" \
      "! grep -q 'archisobasedir=' /proc/cmdline"
check "no /run/archiso live medium" \
      "! test -d /run/archiso"

# ---------------------------------------------------------------------------
# parental-guard present and the installed account enrolled
# ---------------------------------------------------------------------------
echo "=== installed target: parental-guard present and enrolled ==="
check "parental-guard installed"          "pacman -Qi parental-guard"
check "parental-guard.service enabled"    "systemctl is-enabled parental-guard.service"
check "parental-guard-enroll.service enabled" \
                                          "systemctl is-enabled parental-guard-enroll.service"
check "parental-users group exists"       "getent group parental-users"
check "installed user exists"             "id $USER_NAME"
check "installed user is enrolled"        "id -nG | tr ' ' '\n' | grep -qx parental-users"
check "sudoers drop-in present"           "test -f /etc/sudoers.d/parental-os"
check "sudoers is valid"                  "sudo -n visudo -c >/dev/null || visudo -c >/dev/null"

# ---------------------------------------------------------------------------
# agent enabled AND healthy (not just installed)
# ---------------------------------------------------------------------------
# `is-enabled` proves the install wired the unit up; `is-active` proves it is
# running on the booted target; the /health probe proves the HTTP agent actually
# answers, mirroring assert_guest.sh and tests/host/test_agent_health.bats.
echo "=== agent enabled and healthy ==="
check "parental-guard-agent.service enabled" \
                                          "systemctl is-enabled parental-guard-agent.service"
check "parental-guard-agent.service active" \
                                          "systemctl is-active --quiet parental-guard-agent.service"
check "agent /health endpoint responds" \
      "curl -sf -o /dev/null http://127.0.0.1:$AGENT_PORT/health"

# ---------------------------------------------------------------------------
# temporary build scaffolding must NOT survive onto a user's machine
# ---------------------------------------------------------------------------
echo "=== temporary build scaffolding must NOT survive ==="
check "no [parental-os] stanza in pacman.conf" \
      "! grep -q '^\[parental-os\]' /etc/pacman.conf"
check "no [parental-os] stanza in pacman-more.conf" \
      "! grep -q '^\[parental-os\]' /etc/pacman-more.conf"
check "no /srv/parental-os-repo"          "! test -d /srv/parental-os-repo"

# ---------------------------------------------------------------------------
# defects the re-plan documents; SP-B flips these
# ---------------------------------------------------------------------------
echo "=== defects the re-plan documents; SP-B flips these ==="
expect_today "installed user is in wheel" \
      "id -nG | tr ' ' '\n' | grep -qx wheel" \
      "users.conf:18 defaultGroups"
expect_today "pkexec grants root to the child" \
      "pkexec --version" \
      "50-default.rules admin identity"
expect_today "bootable snapshot entries exist" \
      "test -d /.snapshots -o -f /etc/default/limine" \
      "bootloader-post-setup"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "assert_target: OK"
  exit 0
fi
echo "assert_target: $fails FAILED"
exit 1
