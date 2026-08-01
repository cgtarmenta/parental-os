#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd makepkg
"$ROOT/scripts/sync-package-from-overlays.sh"
mkdir -p "$ROOT/packages/parental-guard/src"
cd "$ROOT/packages/parental-guard/arch"
makepkg -f --nodeps 2>&1 | tee "$ROOT/out/logs/parental-guard-arch-makepkg.log"
shopt -s nullglob
for f in parental-guard-*.pkg.tar.*; do
  mv -f "$f" "$ROOT/out/packages/"
done
log "arch package(s) in out/packages"
