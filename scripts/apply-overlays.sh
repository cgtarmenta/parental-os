#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"

dest="${1:-}"
[[ -n "$dest" ]] || die "usage: apply-overlays.sh <destination-rootfs>"
[[ -d "$dest" ]] || mkdir -p "$dest"

require_cmd rsync
rsync -a "${ROOT}/overlays/" "${dest}/"

# Enforce sensitive modes
if [[ -f "${dest}/etc/sudoers.d/parental-os" ]]; then
  chmod 440 "${dest}/etc/sudoers.d/parental-os"
  chown root:root "${dest}/etc/sudoers.d/parental-os" 2>/dev/null || true
fi
find "${dest}/usr/lib/parental-os" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null || true
chmod 755 "${dest}/usr/bin/parental-guard" 2>/dev/null || true
chmod 755 "${dest}/usr/lib/parental-os/agent/server.py" 2>/dev/null || true

log "applied overlays to ${dest}"
