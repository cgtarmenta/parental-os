#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
require_cmd rsync
dest="$ROOT/packages/parental-guard/src"
rm -rf "$dest"
mkdir -p "$dest"
rsync -a "$ROOT/overlays/" "$dest/"
log "synced overlays -> packages/parental-guard/src"
