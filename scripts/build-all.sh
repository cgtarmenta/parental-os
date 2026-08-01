#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
target="${1:-all}"
case "$target" in
  all)
    "$ROOT/scripts/build-ubuntu.sh"
    "$ROOT/scripts/build-cachyos.sh"
    ;;
  ubuntu) "$ROOT/scripts/build-ubuntu.sh" ;;
  cachyos) "$ROOT/scripts/build-cachyos.sh" ;;
  *) die "unknown target: $target (use all|ubuntu|cachyos)" ;;
esac
