# shellcheck shell=sh
if [ -n "${USER:-}" ] && [ "$USER" != "root" ] && [ -x /usr/lib/parental-os/first-login.sh ]; then
  /usr/lib/parental-os/first-login.sh || true
fi
