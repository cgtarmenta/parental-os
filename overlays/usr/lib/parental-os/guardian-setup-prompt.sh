#!/usr/bin/env bash
# guardian-setup-prompt.sh — Prompt for guardian password and save domain-separated hash.
#
# Can run interactively via Zenity / GTK dialog or non-interactively via
# --headless flag or PARENTAL_OS_GUARDIAN_PASSWORD environment variable.
#
# Output:
#   Writes sha256("parental-guard:lan-v1:" + password) to PARENTAL_OS_HASH_OUT
#   (defaults to /run/parental-os/guardian.hash) with file mode 0600.
set -euo pipefail

HASH_OUT="${PARENTAL_OS_HASH_OUT:-/run/parental-os/guardian.hash}"
PASSWORD="${PARENTAL_OS_GUARDIAN_PASSWORD:-}"
HEADLESS=0

usage() {
  cat <<'USAGE_EOF'
Usage: guardian-setup-prompt.sh [options]

Options:
  --headless              Run in non-interactive/headless mode
  -p, --password <pass>   Provide guardian password directly
  -o, --out <file>        Output file path (default: /run/parental-os/guardian.hash)
  -h, --help              Show this help message
USAGE_EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)
      HEADLESS=1
      shift
      ;;
    -p|--password)
      PASSWORD="$2"
      shift 2
      ;;
    -o|--out)
      HASH_OUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "guardian-setup-prompt: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# If already provisioned and no new password supplied, bypass prompt
if [[ -s "$HASH_OUT" && -z "$PASSWORD" ]]; then
  echo "guardian-setup-prompt: secret hash already exists at $HASH_OUT; bypassing prompt"
  exit 0
fi

compute_hash() {
  local secret="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import hashlib, sys; sys.stdout.write(hashlib.sha256(('parental-guard:lan-v1:' + sys.argv[1]).encode('utf-8')).hexdigest() + '\n')" "$secret"
  else
    printf 'parental-guard:lan-v1:%s' "$secret" | sha256sum | awk '{print $1}'
  fi
}

write_hash_file() {
  local hash_value="$1"
  local target_path="$2"
  local out_dir
  out_dir="$(dirname "$target_path")"

  if ! mkdir -p "$out_dir" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      sudo mkdir -p "$out_dir"
      sudo chmod 755 "$out_dir"
    fi
  fi

  local tmp_file="${target_path}.tmp.$$"
  if ( umask 077 && printf '%s\n' "$hash_value" > "$tmp_file" ) 2>/dev/null; then
    chmod 0600 "$tmp_file"
    mv -f "$tmp_file" "$target_path"
    chmod 0600 "$target_path"
  else
    if command -v sudo >/dev/null 2>&1; then
      printf '%s\n' "$hash_value" | sudo tee "$target_path" >/dev/null
      sudo chmod 0600 "$target_path"
      sudo chown 0:0 "$target_path" 2>/dev/null || true
    else
      echo "guardian-setup-prompt: error: failed to write $target_path" >&2
      return 1
    fi
  fi
}

find_display() {
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    if [[ -e /tmp/.X11-unix/X0 ]]; then
      export DISPLAY=":0"
    fi
    for sock in /run/user/*/wayland-*; do
      if [[ -S "$sock" ]]; then
        export WAYLAND_DISPLAY="$(basename "$sock")"
        export XDG_RUNTIME_DIR="$(dirname "$sock")"
        break
      fi
    done
  fi
}

prompt_zenity() {
  command -v zenity >/dev/null 2>&1 || return 1
  find_display
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1

  while true; do
    local result
    result="$(zenity --forms \
      --title="Parental OS - Configuración de Guardián" \
      --text="Establezca la contraseña de guardián para gestión y control remoto." \
      --add-password="Contraseña de Guardián" \
      --add-password="Confirmar Contraseña" \
      --separator="@@@" 2>/dev/null)" || return 1

    local p1 p2
    p1="$(printf '%s' "$result" | awk -F'@@@' '{print $1}')"
    p2="$(printf '%s' "$result" | awk -F'@@@' '{print $2}')"

    if [[ -z "$p1" ]]; then
      zenity --error \
        --title="Error" \
        --text="La contraseña de guardián no puede estar vacía." 2>/dev/null || true
      continue
    fi

    if [[ "$p1" != "$p2" ]]; then
      zenity --error \
        --title="Error" \
        --text="Las contraseñas no coinciden. Inténtelo de nuevo." 2>/dev/null || true
      continue
    fi

    PASSWORD="$p1"
    return 0
  done
}

prompt_terminal() {
  [[ -t 0 ]] || return 1
  while true; do
    read -r -s -p "Contraseña de Guardián: " p1
    echo
    read -r -s -p "Confirmar Contraseña: " p2
    echo
    if [[ -z "$p1" ]]; then
      echo "Error: La contraseña de guardián no puede estar vacía." >&2
      continue
    fi
    if [[ "$p1" != "$p2" ]]; then
      echo "Error: Las contraseñas no coinciden." >&2
      continue
    fi
    PASSWORD="$p1"
    return 0
  done
}

# Resolve password if not provided
if [[ -z "$PASSWORD" ]]; then
  if [[ "$HEADLESS" -eq 1 ]]; then
    # In headless mode without explicit password, generate secure random secret
    echo "guardian-setup-prompt: headless mode with no password set; generating random secret" >&2
    PASSWORD="$(od -vN 24 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || date +%s%N)"
  else
    # In interactive graphical environment, wait up to 30s for display to be ready
    for _ in $(seq 1 30); do
      find_display
      if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        break
      fi
      sleep 1
    done

    if prompt_zenity; then
      :
    elif prompt_terminal; then
      :
    else
      echo "guardian-setup-prompt: no interactive display or terminal available; generating random fallback secret" >&2
      PASSWORD="$(od -vN 24 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || date +%s%N)"
    fi
  fi
fi

[[ -n "$PASSWORD" ]] || {
  echo "guardian-setup-prompt: error: password resolution failed" >&2
  exit 1
}

HASH="$(compute_hash "$PASSWORD")"
write_hash_file "$HASH" "$HASH_OUT"
echo "guardian-setup-prompt: secret hash written to $HASH_OUT"
systemctl try-restart parental-guard-agent.service 2>/dev/null || true
