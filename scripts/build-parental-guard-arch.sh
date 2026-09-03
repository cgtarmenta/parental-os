#!/usr/bin/env bash
# Build the parental-guard Arch package in a checkout-safe staging directory.
#
# All generated sources and build work stay under out/cachyos/staging/ so the
# repository checkout remains read-only. Only the resulting .pkg.tar.* is
# published to out/packages/. Accepts an optional destination override for the
# staging src tree (used by the CachyOS container build-edition.sh entrypoint).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd makepkg

OUT="$(out_root)"
SRC_DEST="${1:-$OUT/cachyos/staging/parental-guard/src}"
mkdir -p "$(dirname "$SRC_DEST")"
PKG_STAGE="$(cd "$(dirname "$SRC_DEST")" && pwd)"

# Sync overlays into the staging src tree.
"$ROOT/scripts/sync-package-from-overlays.sh" "$SRC_DEST"

# Copy the PKGBUILD and install script into the staging package directory.
mkdir -p "$PKG_STAGE"
cp -a "$ROOT/packages/parental-guard/arch/PKGBUILD" "$PKG_STAGE/"
cp -a "$ROOT/packages/parental-guard/arch/parental-guard.install" "$PKG_STAGE/"

cd "$PKG_STAGE"
makepkg -f --nodeps 2>&1 | tee "$OUT/logs/parental-guard-arch-makepkg.log"

shopt -s nullglob
for f in parental-guard-*.pkg.tar.*; do
  cp -f "$f" "$OUT/packages/"
done
log "arch package(s) in $OUT/packages"
