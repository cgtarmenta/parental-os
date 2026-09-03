#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd ssh-keygen

choose_seed_tool() {
  if command -v xorriso >/dev/null 2>&1; then
    printf '%s\n' xorriso
    return 0
  fi
  if command -v genisoimage >/dev/null 2>&1; then
    printf '%s\n' genisoimage
    return 0
  fi
  if command -v mkisofs >/dev/null 2>&1; then
    printf '%s\n' mkisofs
    return 0
  fi
  die "missing required command: xorriso, genisoimage, or mkisofs"
}

OUT="$(out_root)"
KEY="$OUT/qemu/id_ed25519"
SEED_DIR="$OUT/qemu/seed"
SEED_ISO="$OUT/qemu/seed.iso"
PUB_TMP=""
ISO_TMP=""

cleanup_tmp() {
  if [[ -n "$PUB_TMP" ]]; then
    rm -f "$PUB_TMP"
  fi
  if [[ -n "$ISO_TMP" ]]; then
    rm -f "$ISO_TMP"
  fi
}
trap cleanup_tmp EXIT

mkdir -p "$OUT/qemu"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "parental-os-qemu" >/dev/null
fi
chmod 0600 "$KEY"
PUB_TMP="$(mktemp "$OUT/qemu/id_ed25519.pub.XXXXXX")"
ssh-keygen -y -f "$KEY" >"$PUB_TMP"
mv "$PUB_TMP" "$KEY.pub"
PUB_TMP=""

PUB="$(<"$KEY.pub")"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
PROFILE="${PROFILE:-smoke}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$PROFILE" in
  smoke)   template="$ROOT/tests/qemu/user-data" ;;
  install) template="$ROOT/tests/qemu/user-data-install" ;;
  *) die "unknown seed profile: $PROFILE (use smoke|install)" ;;
esac
[[ -f "$template" ]] || die "seed template not found: $template"
USER_DATA="$(<"$template")"
log "seed profile: $PROFILE"
printf '%s\n' "${USER_DATA//SSH_PUBKEY_PLACEHOLDER/$PUB}" >"$SEED_DIR/user-data"
cp "$ROOT/tests/qemu/meta-data" "$SEED_DIR/meta-data"

tool="$(choose_seed_tool)"
ISO_TMP="$(mktemp "$OUT/qemu/seed.iso.XXXXXX")"
case "$tool" in
  xorriso)
    xorriso -as mkisofs -output "$ISO_TMP" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
  genisoimage)
    genisoimage -output "$ISO_TMP" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
  mkisofs)
    mkisofs -output "$ISO_TMP" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
esac
mv "$ISO_TMP" "$SEED_ISO"
ISO_TMP=""

log "seed iso: $SEED_ISO"
