#!/usr/bin/env bash
# Build parental-guard .deb inside debian:bookworm via Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd docker
require_cmd rsync

"$ROOT/scripts/sync-package-from-overlays.sh"

PKGVER="0.1.0"
STAGE_PARENT="$ROOT/out/deb-src"
STAGE="$STAGE_PARENT/parental-guard-${PKGVER}"
rm -rf "$STAGE_PARENT"
mkdir -p "$STAGE"

# Upstream filesystem payload at package root for dh / .install mapping
rsync -a "$ROOT/packages/parental-guard/src/" "$STAGE/"
rsync -a "$ROOT/packages/parental-guard/debian/" "$STAGE/debian/"

# Staged install file: map etc/ and usr/ into the binary package
cat >"$STAGE/debian/parental-guard.install" <<'INST'
etc usr
INST

# Simple rules for staged native package layout (payload beside debian/)
cat >"$STAGE/debian/rules" <<'RULES'
#!/usr/bin/make -f
export DH_VERBOSE = 1

%:
	dh $@

override_dh_fixperms:
	dh_fixperms
	if [ -f debian/parental-guard/etc/sudoers.d/parental-os ]; then \
		chmod 440 debian/parental-guard/etc/sudoers.d/parental-os; \
	fi
RULES
chmod +x "$STAGE/debian/rules"

mkdir -p "$STAGE/debian/source"
echo "3.0 (native)" >"$STAGE/debian/source/format"

if [[ ! -f "$STAGE/debian/postinst" ]]; then
  cat >"$STAGE/debian/postinst" <<'POSTINST'
#!/bin/sh
set -e
groupadd --system parental-users 2>/dev/null || groupadd parental-users 2>/dev/null || true
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
  systemctl enable parental-guard.service parental-guard-agent.service || true
fi
exit 0
POSTINST
fi
chmod 755 "$STAGE/debian/postinst"

# Ensure var/lib exists in payload for runtime state
mkdir -p "$STAGE/var/lib/parental-os"

log "building deb in docker (debian:bookworm) from $STAGE"
docker run --rm \
  -v "$STAGE_PARENT:/build" \
  -w "/build/parental-guard-${PKGVER}" \
  debian:bookworm \
  bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential debhelper dpkg-dev devscripts fakeroot
    dpkg-buildpackage -us -uc -b
    ls -la /build
  ' 2>&1 | tee "$ROOT/out/logs/parental-guard-deb-build.log"

shopt -s nullglob
copied=0
for f in "$STAGE_PARENT"/parental-guard_*.deb; do
  cp -a "$f" "$ROOT/out/packages/"
  copied=1
done
if [[ "$copied" -eq 0 ]]; then
  die "no parental-guard_*.deb produced under $STAGE_PARENT"
fi
log "deb package(s) in out/packages:"
ls -la "$ROOT/out/packages"/parental-guard_*.deb >&2 || true
