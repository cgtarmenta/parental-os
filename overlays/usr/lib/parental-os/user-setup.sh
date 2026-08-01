#!/usr/bin/env bash
# Add an interactive user to the parental-users group.
# Usage: user-setup.sh <username>
set -euo pipefail

USER_NAME="${1:-}"
[[ -n "$USER_NAME" ]] || { echo "usage: $0 <username>" >&2; exit 2; }

ROOT_FS="${PARENTAL_OS_ROOT_FS:-}"
CFG="${ROOT_FS}/etc/parental-os/config.env"
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"
fi
GROUP_NAME="${PARENTAL_OS_GROUP:-parental-users}"

if [[ -n "$ROOT_FS" ]]; then
  export PARENTAL_FAKE_ROOT="$ROOT_FS"
  groupadd "$GROUP_NAME" 2>/dev/null || true
  usermod -aG "$GROUP_NAME" "$USER_NAME"
else
  if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
    groupadd --system "$GROUP_NAME" || groupadd "$GROUP_NAME"
  fi
  usermod -aG "$GROUP_NAME" "$USER_NAME"
fi

echo "parental-os: ensured ${USER_NAME} in group ${GROUP_NAME}"
