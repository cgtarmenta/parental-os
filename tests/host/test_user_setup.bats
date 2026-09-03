#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FAKE="$(mktemp -d)"
  export FAKE
  mkdir -p "$FAKE/etc/parental-os" "$FAKE/usr/sbin" "$FAKE/etc" "$FAKE/home"
  cp "$PARENTAL_OS_ROOT/overlays/etc/parental-os/config.env" "$FAKE/etc/parental-os/config.env"
  printf 'root:x:0:\nparental-users:x:910:\n' >"$FAKE/etc/group"
  cat >"$FAKE/usr/sbin/groupadd" <<'EOS'
#!/bin/bash
name="$1"
grep -q "^${name}:" "$PARENTAL_FAKE_ROOT/etc/group" && exit 0
echo "${name}:x:910:" >>"$PARENTAL_FAKE_ROOT/etc/group"
EOS
  cat >"$FAKE/usr/sbin/usermod" <<'EOS'
#!/bin/bash
group=""
user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -aG) group="$2"; shift 2 ;;
    *) user="$1"; shift ;;
  esac
done
tmp="$(mktemp)"
while IFS= read -r line; do
  if [[ "$line" == "${group}:"* ]]; then
    if [[ "$line" != *"${user}"* ]]; then
      if [[ "$line" == *: ]]; then
        line="${line}${user}"
      else
        line="${line},${user}"
      fi
    fi
  fi
  printf '%s\n' "$line"
done <"$PARENTAL_FAKE_ROOT/etc/group" >"$tmp"
mv "$tmp" "$PARENTAL_FAKE_ROOT/etc/group"
EOS
  chmod +x "$FAKE/usr/sbin/groupadd" "$FAKE/usr/sbin/usermod"
  export PATH="$FAKE/usr/sbin:$PATH"
  export PARENTAL_FAKE_ROOT="$FAKE"
}

teardown() {
  rm -rf "$FAKE"
}

@test "user-setup adds user to parental-users" {
  run env PARENTAL_OS_ROOT_FS="$FAKE" bash "$PARENTAL_OS_ROOT/overlays/usr/lib/parental-os/user-setup.sh" child1
  [ "$status" -eq 0 ]
  grep -q 'parental-users:.*child1' "$FAKE/etc/group"
}
