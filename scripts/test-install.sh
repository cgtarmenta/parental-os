#!/usr/bin/env bash
# Drive an unattended Calamares install in QEMU, then boot the installed target
# and assert against it.
#
# Success oracle: finished.conf sets restartNowCommand to `systemctl -i poweroff`,
# and Calamares downgrades restartNowMode to Never when a job fails
# (finished/Config.cpp:100-106). So a container that exits on its own means the
# install completed; a container still running when INSTALL_TIMEOUT expires means
# it did not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"

TARGET="${1:-cachyos-desktop}"
INSTALL_TIMEOUT="${PARENTAL_OS_INSTALL_TIMEOUT:-2700}"
OUT="$(out_root)"
STATE="$OUT/qemu/install/$TARGET"
DISK="$STATE/target.qcow2"
LOG="$OUT/logs/test-install-$TARGET.log"

require_cmd docker
mkdir -p "$STATE" "$OUT/logs"

# A fresh disk every run: the whole point is to observe what the installer writes.
rm -f "$DISK"

log "=== phase 1: unattended install ==="
"$ROOT/scripts/make-cloud-init-seed.sh" --profile install

PARENTAL_OS_QEMU_STATE_DIR="$STATE" PARENTAL_OS_BROWSER_TARGET="install-$TARGET"   "$ROOT/scripts/qemu-browser.sh" "$TARGET" >>"$LOG" 2>&1

container="$(docker --context "$DOCKER_CONTEXT" ps   --format '{{.Names}}	{{.Image}}' | awk '/qemu-browser/{print $1; exit}')"
[[ -n "$container" ]] || die "install VM container not found"
log "install VM: $container (timeout ${INSTALL_TIMEOUT}s)"

# `docker wait` blocks until the container exits, which happens when the guest
# powers itself off. Racing it against a sleep gives us the timeout.
( docker --context "$DOCKER_CONTEXT" wait "$container" >"$STATE/wait.rc" ) &
waiter=$!
( sleep "$INSTALL_TIMEOUT"; kill -TERM "$waiter" 2>/dev/null ) &
timer=$!
if wait "$waiter" 2>/dev/null; then
  kill -TERM "$timer" 2>/dev/null || true
  log "guest powered off — install reported success"
else
  log "install did not complete within ${INSTALL_TIMEOUT}s"
  docker --context "$DOCKER_CONTEXT" logs --tail 60 "$container" >>"$LOG" 2>&1 || true
  "$ROOT/scripts/qemu-browser.sh" down >>"$LOG" 2>&1 || true
  die "unattended install timed out; see $LOG"
fi

"$ROOT/scripts/qemu-browser.sh" down >>"$LOG" 2>&1 || true
[[ -f "$DISK" ]] || die "installer produced no disk at $DISK"
log "installed disk: $(stat -c %s "$DISK") bytes"

log "=== phase 2: boot the installed target ==="
# Boot from disk, not CD: PARENTAL_OS_ISO_PATH points at /dev/null so the
# entrypoint has no bootable CD and falls through to the virtio disk.
PARENTAL_OS_QEMU_STATE_DIR="$STATE" PARENTAL_OS_BROWSER_TARGET="install-$TARGET" PARENTAL_OS_ISO_PATH=/dev/null   "$ROOT/scripts/qemu-browser.sh" "$TARGET" >>"$LOG" 2>&1

log "installed target booting; noVNC http://127.0.0.1:8011/vnc.html"
log "run assertions with: tests/qemu/assert_target.sh"
