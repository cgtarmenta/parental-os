#!/usr/bin/env bash
# Reconcile parental-users membership for every interactive account.
#
# parental-os has no admin-user concept: root is the only administrator, and every
# other account on the machine must be a member of parental-users so the sudoers
# policy (%parental-users ALL=(ALL) NOPASSWD: ALL, !PARENTAL_GUARDED) actually
# applies to it.
#
# This runs as root from parental-guard-enroll.service at boot and again from
# parental-guard-enroll.path whenever the account database changes, which is what
# delivers the automatic policy inheritance for new users that the design calls for.
#
# It deliberately replaces a login-shell hook as the primary mechanism. A hook in
# /etc/profile.d is sourced only by POSIX login shells -- notably not by fish -- and
# runs without the privileges usermod needs, so it could never enroll anyone
# reliably.
#
# Modes:
#   --list    print every interactive user, one per line
#   --check   exit non-zero if any interactive user is not a member
#   (none)    enroll every interactive user; requires root
set -euo pipefail

ROOT_FS="${PARENTAL_OS_ROOT_FS:-}"
CFG="${ROOT_FS}/etc/parental-os/config.env"
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"
elif [[ -z "$ROOT_FS" && -f /etc/parental-os/config.env ]]; then
  # shellcheck disable=SC1091
  source /etc/parental-os/config.env
fi

GROUP_NAME="${PARENTAL_OS_GROUP:-parental-users}"
PASSWD_FILE="${ROOT_FS}/etc/passwd"
GROUP_FILE="${ROOT_FS}/etc/group"
LOGIN_DEFS="${ROOT_FS}/etc/login.defs"

die() { printf 'enroll-users: error: %s\n' "$*" >&2; exit 1; }

[[ -n "$GROUP_NAME" ]] || die "group name is empty; check PARENTAL_OS_GROUP"

# A staged root filesystem carries policy files but no account database. That is
# not a fault: there is simply nothing to reconcile yet, so --list and --check treat
# it as inapplicable. Only actual enrollment requires the database.
has_account_db() { [[ -r "$PASSWD_FILE" ]]; }

login_def() {
  local key="$1" default="$2" value=""
  if [[ -r "$LOGIN_DEFS" ]]; then
    value="$(awk -v k="$key" '$1==k {print $2; exit}' "$LOGIN_DEFS")"
  fi
  printf '%s\n' "${value:-$default}"
}

UID_MIN="$(login_def UID_MIN 1000)"
UID_MAX="$(login_def UID_MAX 60000)"

# An account is interactive when its UID falls in the human range and its shell is
# a real one. Shell *identity* is never used to decide this -- fish, zsh and bash
# are equally real -- only the explicit refusal shells are excluded.
interactive_users() {
  awk -F: -v min="$UID_MIN" -v max="$UID_MAX" '
    $1 == "root" { next }
    $3 < min || $3 > max { next }
    {
      shell = $7
      sub(/.*\//, "", shell)
      if (shell == "nologin" || shell == "false" || shell == "sync" ||
          shell == "shutdown" || shell == "halt" || shell == "")
        next
      print $1
    }
  ' "$PASSWD_FILE"
}

# Members of the group, from both the group line and users whose primary group it
# is. Reading the files directly (rather than getent) keeps --list/--check usable
# against a staged root filesystem in tests and during image builds.
group_members() {
  [[ -r "$GROUP_FILE" ]] || return 0
  awk -F: -v g="$GROUP_NAME" '$1==g {gsub(/,/, "\n", $4); print $4}' "$GROUP_FILE" \
    | sed '/^$/d'
}

unenrolled_users() {
  local members user
  members="$(group_members)"
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    grep -qxF "$user" <<<"$members" || printf '%s\n' "$user"
  done < <(interactive_users)
}

case "${1:-}" in
  --list)
    has_account_db || exit 0
    interactive_users
    exit 0
    ;;
  --check)
    if ! has_account_db; then
      printf 'enroll-users: no account database at %s; nothing to reconcile\n' \
        "$PASSWD_FILE"
      exit 0
    fi
    missing="$(unenrolled_users)"
    if [[ -n "$missing" ]]; then
      printf 'enroll-users: unenrolled interactive users:\n' >&2
      printf '  %s\n' $missing >&2
      exit 1
    fi
    printf 'enroll-users: all interactive users are members of %s\n' "$GROUP_NAME"
    exit 0
    ;;
  "") ;;
  *) die "unknown option: $1 (use --list|--check)" ;;
esac

# Enrollment proper. Every failure is fatal: a partially applied policy that
# reports success is how an empty group went unnoticed on a real install.
[[ -z "$ROOT_FS" ]] || die "enrollment cannot run against a staged root filesystem"
[[ "$(id -u)" -eq 0 ]] || die "must run as root to modify group membership"
has_account_db || die "cannot read $PASSWD_FILE"

if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
  groupadd --system "$GROUP_NAME" || groupadd "$GROUP_NAME" \
    || die "could not create group $GROUP_NAME"
fi

enrolled=0
while IFS= read -r user; do
  [[ -n "$user" ]] || continue
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxF "$GROUP_NAME"; then
    continue
  fi
  usermod -aG "$GROUP_NAME" "$user" \
    || die "could not add $user to $GROUP_NAME"
  printf 'enroll-users: added %s to %s\n' "$user" "$GROUP_NAME"
  enrolled=$((enrolled + 1))
done < <(interactive_users)

printf 'enroll-users: %s newly enrolled; group %s reconciled\n' \
  "$enrolled" "$GROUP_NAME"
