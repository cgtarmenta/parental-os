#!/usr/bin/env bash
# Idempotent first-login safety net for group membership.
set -euo pipefail

MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/parental-os/first-login-done"
mkdir -p "$(dirname "$MARKER")"
if [[ -f "$MARKER" ]]; then
  exit 0
fi

USER_NAME="$(id -un)"
if [[ "$USER_NAME" == "root" ]]; then
  exit 0
fi

SETUP="/usr/lib/parental-os/user-setup.sh"
if [[ -x "$SETUP" ]]; then
  # May fail without privileges; ignore — package hooks should have run.
  sudo -n "$SETUP" "$USER_NAME" 2>/dev/null || "$SETUP" "$USER_NAME" 2>/dev/null || true
fi

touch "$MARKER"
