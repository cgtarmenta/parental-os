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

# Secondary path only. parental-guard-enroll.service is the mechanism that
# actually enrolls users: it runs as root at boot and again whenever the account
# database changes, and unlike this hook it is not restricted to POSIX login shells
# (fish never sources /etc/profile.d) nor dependent on the caller's privileges.
#
# The marker is written only on real success. Recording completion after a failed
# attempt is what previously hid an empty parental-users group: the hook could not
# usermod without privileges, swallowed the error, and then never retried.
SETUP="/usr/lib/parental-os/user-setup.sh"
if [[ ! -x "$SETUP" ]]; then
  exit 0
fi

if sudo -n "$SETUP" "$USER_NAME" 2>/dev/null || "$SETUP" "$USER_NAME" 2>/dev/null; then
  touch "$MARKER"
  exit 0
fi

# Already a member by some other route (the enroll service, most likely): nothing
# to do, and no reason to retry on every login.
if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' \
    | grep -qxF "${PARENTAL_OS_GROUP:-parental-users}"; then
  touch "$MARKER"
fi

exit 0
