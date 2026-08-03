#!/usr/bin/env bash
# Build parental-guard .deb inside debian:bookworm via Docker.
#
# The committed packages/parental-guard/debian/ tree is the canonical build
# input: it is copied into the stage unchanged and an equality assertion guards
# against silent divergence. The build produces both a 3.0 (quilt) source
# package and the binary parental-guard_0.1.0-1_all.deb under out/packages/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd docker
require_cmd rsync

# Refresh the upstream payload from overlays so src/ matches the overlay tree.
"$ROOT/scripts/sync-package-from-overlays.sh"

PKGVER="0.1.0"
SRCNAME="parental-guard"
STAGE_PARENT="$ROOT/out/deb-src"
STAGE="$STAGE_PARENT/${SRCNAME}-${PKGVER}"
DEB_OUT="$ROOT/out/packages"
rm -rf "$STAGE_PARENT"
mkdir -p "$STAGE" "$DEB_OUT"

# Upstream filesystem payload at package root for dh_install/.install mapping.
rsync -a "$ROOT/packages/parental-guard/src/" "$STAGE/"
# Canonical debian/ metadata copied unchanged (Finding 3: no rewrites).
rsync -a "$ROOT/packages/parental-guard/debian/" "$STAGE/debian/"

# Equality/non-rewrite assertion: staged debian/ must equal committed templates.
if ! diff -r "$ROOT/packages/parental-guard/debian" "$STAGE/debian" >/tmp/parental-guard-deb-diff 2>&1; then
  cat /tmp/parental-guard-deb-diff >&2
  die "staged debian/ diverges from committed packages/parental-guard/debian"
fi
rm -f /tmp/parental-guard-deb-diff

# 3.0 (quilt) requires an upstream orig tarball named <src>_<ver>.orig.tar.gz
# containing everything except the debian/ directory.
ORIG_TGZ="$STAGE_PARENT/${SRCNAME}_${PKGVER}.orig.tar.gz"
tar -czf "$ORIG_TGZ" -C "$STAGE_PARENT" \
  --exclude="${SRCNAME}-${PKGVER}/debian" \
  "${SRCNAME}-${PKGVER}"

log "building deb in docker (debian:bookworm) from $STAGE"
docker run --rm \
  -v "$STAGE_PARENT:/build" \
  -w "/build/${SRCNAME}-${PKGVER}" \
  debian:bookworm \
  bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends build-essential debhelper dpkg-dev fakeroot
    # Build the 3.0 (quilt) source package, then the binary package.
    dpkg-source -b .
    dpkg-buildpackage -us -uc -b
    ls -la /build
  ' 2>&1 | tee "$ROOT/out/logs/parental-guard-deb-build.log"

# Copy the binary .deb and the source .dsc into out/packages.
shopt -s nullglob
copied=0
for f in "$STAGE_PARENT"/parental-guard_*.deb; do
  cp -a "$f" "$DEB_OUT/"
  copied=1
done
if [[ "$copied" -eq 0 ]]; then
  die "no parental-guard_*.deb produced under $STAGE_PARENT"
fi
for f in "$STAGE_PARENT"/parental-guard_*.dsc; do
  cp -a "$f" "$DEB_OUT/"
done
log "deb package(s) in out/packages:"
ls -la "$DEB_OUT"/parental-guard_* >&2 || true
