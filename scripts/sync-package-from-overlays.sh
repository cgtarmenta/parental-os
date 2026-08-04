#!/usr/bin/env bash
# Sync the shared overlays/ tree into an explicit destination directory.
#
# Usage: sync-package-from-overlays.sh [destination]
#
# When a destination is provided, overlays are synced there. When no
# destination is given, the default is out/cachyos/staging/parental-guard/src
# so that generated package sources stay under the gitignored out/ tree and
# the checkout remains read-only during builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
require_cmd rsync
OUT="$(out_root)"
dest="${1:-$OUT/cachyos/staging/parental-guard/src}"
rm -rf "$dest"
mkdir -p "$dest"
rsync -a "$ROOT/overlays/" "$dest/"
log "synced overlays -> $dest"
