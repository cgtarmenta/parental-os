# parental-os v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a monorepo that builds Ubuntu and CachyOS/Arch-style installable ISOs with a shared `parental-guard` placeholder (sudo/polkit/user hooks, LAN agent stub) and QEMU smoke tests.

**Architecture:** Shared policy lives in `overlays/` and `packages/parental-guard`. Thin distro adapters call `scripts/apply-overlays.sh` and install the package. Orchestration is a Justfile wrapping shell scripts. Ubuntu ISO builds run via **Docker + live-build** (host is Arch/CachyOS). Cachy/Arch ISO builds use **archiso** on the host. QEMU tests boot artifacts with a **NoCloud cloud-init** seed and SSH assertions.

**Tech Stack:** bash, Just (`just`), systemd units, sudoers, polkit, archiso, Docker + `debian:bookworm` live-build image, qemu-system-x86_64 + cloud-init seed ISO, shellcheck, bats (host unit tests).

**Spec:** `docs/superpowers/specs/2026-08-01-parental-os-design.md`

**Locked implementation choices (from spec §12):**
- Ubuntu toolchain: **live-build inside Docker** (not bare-metal live-build on Arch).
- CachyOS path v1: **archiso `releng` profile** with Cachy/Arch repos documented; full upstream Cachy ISO branding can harden later without changing overlays.
- QEMU automation: **cloud-init NoCloud + SSH**.
- Agent stub: **Python 3 stdlib `http.server`** subclass (no extra deps).
- Orchestration: **Justfile required**; scripts remain callable without Just.

---

## File map (create unless noted)

| Path | Responsibility |
|------|----------------|
| `README.md` | Quick start, threat model summary, host deps |
| `Justfile` | `build`, `test-qemu`, `test-host`, `clean`, `package-*` |
| `.gitignore` | Modify: caches, debs, pkg tarballs |
| `docs/agent-api.md` | LAN agent stub HTTP contract |
| `overlays/etc/sudoers.d/parental-os` | Group-based limited NOPASSWD sudo |
| `overlays/etc/polkit-1/rules.d/50-parental-os.rules` | Deny casual admin bypass |
| `overlays/etc/parental-os/config.env` | Shared config (bind addr, paths) |
| `overlays/etc/parental-os/protected-packages.list` | Packages children must not remove |
| `overlays/etc/parental-os/protected-units.list` | systemd units children must not stop |
| `overlays/usr/lib/parental-os/user-setup.sh` | Add user to `parental-users` |
| `overlays/usr/lib/parental-os/first-login.sh` | Safety-net on first login |
| `overlays/usr/lib/parental-os/agent/server.py` | LAN HTTP stub |
| `overlays/usr/bin/parental-guard` | CLI status/doctor |
| `overlays/usr/lib/systemd/system/parental-guard.service` | Oneshot/assert guard present |
| `overlays/usr/lib/systemd/system/parental-guard-agent.service` | Agent process |
| `overlays/usr/lib/systemd/system/parental-guard-agent.socket` | Optional; prefer service bind |
| `overlays/etc/systemd/system/user@.service.d/parental-os.conf` | First-login hook wiring if used |
| `overlays/etc/profile.d/parental-os-first-login.sh` | Invoke first-login once |
| `packages/parental-guard/src/**` | Canonical copy of package payload (synced from/to overlays in build) |
| `packages/parental-guard/arch/PKGBUILD` | Arch package |
| `packages/parental-guard/debian/control` | deb metadata |
| `packages/parental-guard/debian/rules` | deb build |
| `packages/parental-guard/debian/parental-guard.install` | install mapping |
| `packages/parental-guard/debian/postinst` | enable units, ensure group |
| `packages/parental-guard/debian/changelog` | deb changelog |
| `packages/parental-guard/debian/compat` | debhelper compat |
| `scripts/lib/common.sh` | ROOT, logging, die |
| `scripts/sync-package-from-overlays.sh` | Copy overlays → package src |
| `scripts/apply-overlays.sh` | rsync overlays into a rootfs |
| `scripts/build-parental-guard-arch.sh` | makepkg |
| `scripts/build-parental-guard-deb.sh` | dpkg-buildpackage in Docker |
| `scripts/build-ubuntu.sh` | Docker live-build driver |
| `scripts/build-cachyos.sh` | archiso driver |
| `scripts/build-all.sh` | serial both |
| `scripts/test-qemu.sh` | boot + SSH checks |
| `scripts/make-cloud-init-seed.sh` | NoCloud seed ISO |
| `distros/ubuntu/docker/Dockerfile` | live-build environment |
| `distros/ubuntu/auto/config` | lb config script |
| `distros/ubuntu/config/hooks/live/0100-parental-os.hook.chroot` | install guard in chroot |
| `distros/ubuntu/config/package-lists/parental-os.list.chroot` | extra packages |
| `distros/ubuntu/config/includes.chroot_after_packages/` | optional static includes |
| `distros/cachyos/profile/packages.x86_64` | package list |
| `distros/cachyos/profile/pacman.conf` | pacman conf for build |
| `distros/cachyos/profile/profiledef.sh` | archiso profiledef |
| `distros/cachyos/profile/airootfs/` | minimal airootfs stubs + bootstrap hook |
| `distros/cachyos/profile/bootstrap_packages.x86_64` | bootstrap pkgs if needed |
| `tests/host/test_user_setup.bats` | user-setup unit tests |
| `tests/host/test_parental_guard_cli.bats` | CLI unit tests |
| `tests/host/fixtures/` | fake rootfs trees |
| `tests/qemu/assert_guest.sh` | remote assertions over SSH |
| `tests/qemu/user-data` | cloud-init user-data |
| `tests/qemu/meta-data` | cloud-init meta-data |

---

### Task 1: Repo skeleton, common lib, gitignore, Justfile stubs

**Files:**
- Create: `scripts/lib/common.sh`
- Create: `Justfile`
- Create: `scripts/build-all.sh`
- Modify: `.gitignore`
- Create: `out/.gitkeep` is **not** used (out is ignored); create `README.md` placeholder only in Task 12 — here only skeleton dirs via script

- [ ] **Step 1: Write failing host test for `repo_root` helper**

Create `tests/host/test_common.bats`:

```bash
#!/usr/bin/env bats

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/common.sh"
}

@test "repo_root points at directory containing Justfile or docs/superpowers" {
  root="$(repo_root)"
  [[ -d "$root/docs/superpowers/specs" ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/dat30/github/parental-os
mkdir -p tests/host
# install bats if missing: sudo pacman -S --needed bats
bats tests/host/test_common.bats
```

Expected: FAIL (`common.sh` missing or `repo_root` undefined).

- [ ] **Step 3: Implement common.sh, dirs, Justfile, gitignore, build-all stub**

`scripts/lib/common.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for parental-os scripts.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

repo_root() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/Justfile" || -d "$d/docs/superpowers/specs" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  # Fallback: parent of scripts/
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_out_dirs() {
  local root
  root="$(repo_root)"
  mkdir -p "$root/out/ubuntu" "$root/out/cachyos" "$root/out/packages" "$root/out/logs" "$root/out/qemu"
}
```

Note: when sourced from bats, `BASH_SOURCE[1]` may be the bats file; prefer walking from `PWD` if needed. Use this more reliable `repo_root`:

```bash
repo_root() {
  if [[ -n "${PARENTAL_OS_ROOT:-}" ]]; then
    printf '%s\n' "$PARENTAL_OS_ROOT"
    return 0
  fi
  local start d
  start="$(pwd)"
  d="$start"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/Justfile" || -d "$d/docs/superpowers/specs" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  die "could not locate parental-os repo root from $start"
}
```

`Justfile`:

```just
set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

default:
  @just --list

test-host:
  cd "{{root}}" && bats tests/host

build target="all":
  "{{root}}/scripts/build-all.sh" "{{target}}"

build-ubuntu:
  "{{root}}/scripts/build-ubuntu.sh"

build-cachyos:
  "{{root}}/scripts/build-cachyos.sh"

package-arch:
  "{{root}}/scripts/build-parental-guard-arch.sh"

package-deb:
  "{{root}}/scripts/build-parental-guard-deb.sh"

test-qemu target="all":
  "{{root}}/scripts/test-qemu.sh" "{{target}}"

clean:
  rm -rf "{{root}}/out"/*
  mkdir -p "{{root}}/out/ubuntu" "{{root}}/out/cachyos" "{{root}}/out/packages" "{{root}}/out/logs" "{{root}}/out/qemu"
```

`scripts/build-all.sh`:

```bash
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
```

Temporarily create stub builders so `build-all` can be syntax-checked later:

```bash
# scripts/build-ubuntu.sh and build-cachyos.sh stubs — replaced in later tasks
#!/usr/bin/env bash
set -euo pipefail
echo "stub: implement in later task" >&2
exit 1
```

Append to `.gitignore`:

```gitignore
out/
*.iso
*.img
.cache/
work/
build/
*.log
.DS_Store
*.deb
*.ddeb
*.tar.zst
*.pkg.tar.*
srcpkgs/
pkg/
packages/parental-guard/arch/pkg/
packages/parental-guard/arch/src/
packages/parental-guard/debian/*.debhelper*
packages/parental-guard/debian/.debhelper/
packages/parental-guard/debian/files
packages/parental-guard/debian/parental-guard/
distros/ubuntu/cache/
distros/ubuntu/chroot/
distros/ubuntu/binary/
distros/ubuntu/.build/
distros/cachyos/work/
```

```bash
chmod +x scripts/lib/common.sh scripts/build-all.sh
mkdir -p scripts overlays packages/parental-guard/{src,arch,debian} distros/{ubuntu,cachyos} tests/{host,qemu} out
```

- [ ] **Step 4: Run host test**

```bash
cd /home/dat30/github/parental-os
sudo pacman -S --needed bats just
bats tests/host/test_common.bats
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/dat30/github/parental-os
git add .gitignore Justfile scripts tests/host
git commit -m "chore: scaffold repo scripts, Justfile, and host test harness"
```

---

### Task 2: Overlay policy files (sudoers, polkit, config lists)

**Files:**
- Create: `overlays/etc/sudoers.d/parental-os`
- Create: `overlays/etc/polkit-1/rules.d/50-parental-os.rules`
- Create: `overlays/etc/parental-os/config.env`
- Create: `overlays/etc/parental-os/protected-packages.list`
- Create: `overlays/etc/parental-os/protected-units.list`
- Create: `tests/host/test_sudoers_syntax.bats`

- [ ] **Step 1: Write failing test for sudoers file presence and visudo**

`tests/host/test_sudoers_syntax.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "sudoers drop-in exists" {
  [[ -f "$PARENTAL_OS_ROOT/overlays/etc/sudoers.d/parental-os" ]]
}

@test "sudoers drop-in validates with visudo -cf when visudo exists" {
  if ! command -v visudo >/dev/null; then
    skip "visudo not installed on host"
  fi
  run visudo -cf "$PARENTAL_OS_ROOT/overlays/etc/sudoers.d/parental-os"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test — expect FAIL (missing file)**

```bash
bats tests/host/test_sudoers_syntax.bats
```

- [ ] **Step 3: Write overlay policy files**

`overlays/etc/sudoers.d/parental-os` (mode 0440 when installed):

```sudoers
# parental-os — group-based limited passwordless sudo
# Validate: visudo -cf /etc/sudoers.d/parental-os

Defaults:%parental-users !env_reset
Defaults:%parental-users secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

Cmnd_Alias PARENTAL_GUARDED = \
  /usr/bin/timekpr*, \
  /usr/sbin/timekpr*, \
  /usr/sbin/ctparental, \
  /usr/bin/parental-guard, \
  /usr/bin/visudo, \
  /usr/sbin/visudo, \
  /bin/su, /usr/bin/su, \
  /bin/bash, /usr/bin/bash, \
  /bin/sh, /usr/bin/sh, /usr/bin/dash, \
  /usr/bin/zsh, /bin/zsh, /usr/bin/fish, \
  /usr/bin/passwd, \
  /usr/bin/timedatectl, \
  /usr/bin/date, \
  /usr/bin/systemctl stop parental-guard*, \
  /usr/bin/systemctl disable parental-guard*, \
  /usr/bin/systemctl mask parental-guard*, \
  /usr/bin/systemctl stop timekpr*, \
  /usr/bin/systemctl disable timekpr*, \
  /usr/bin/systemctl mask timekpr*, \
  /usr/bin/apt remove parental-guard, \
  /usr/bin/apt purge parental-guard, \
  /usr/bin/apt-get remove parental-guard, \
  /usr/bin/apt-get purge parental-guard, \
  /usr/bin/dpkg -r parental-guard, \
  /usr/bin/dpkg --purge parental-guard, \
  /usr/bin/pacman -R parental-guard, \
  /usr/bin/pacman -Rns parental-guard

# Allow everyday admin via sudo, except guarded commands.
%parental-users ALL=(ALL) NOPASSWD: ALL, !PARENTAL_GUARDED
```

`overlays/etc/polkit-1/rules.d/50-parental-os.rules`:

```javascript
// parental-os: block casual package/unit admin via polkit for parental-users
polkit.addRule(function (action, subject) {
  if (!subject.isInGroup("parental-users")) {
    return polkit.Result.NOT_HANDLED;
  }

  var deny = [
    "org.freedesktop.systemd1.manage-units",
    "org.freedesktop.systemd1.manage-unit-files",
    "org.freedesktop.packagekit.package-remove",
    "org.freedesktop.packagekit.package-install",
    "org.freedesktop.timedate1.set-time",
    "org.freedesktop.timedate1.set-timezone",
    "org.freedesktop.timedate1.set-ntp"
  ];

  if (deny.indexOf(action.id) !== -1) {
    return polkit.Result.NO;
  }

  return polkit.Result.NOT_HANDLED;
});
```

`overlays/etc/parental-os/config.env`:

```bash
# parental-os shared configuration (sourced by agent and CLI)
PARENTAL_OS_GROUP=parental-users
PARENTAL_OS_AGENT_BIND=127.0.0.1
PARENTAL_OS_AGENT_PORT=7420
PARENTAL_OS_TOKEN_FILE=/etc/parental-os/agent.token
PARENTAL_OS_STATE_DIR=/var/lib/parental-os
```

`overlays/etc/parental-os/protected-packages.list`:

```text
parental-guard
timekpr
timekpr-next
ctparental
```

`overlays/etc/parental-os/protected-units.list`:

```text
parental-guard.service
parental-guard-agent.service
timekpr.service
```

- [ ] **Step 4: Run tests**

```bash
sudo pacman -S --needed sudo
bats tests/host/test_sudoers_syntax.bats
```

Expected: PASS (visudo accepts file).

- [ ] **Step 5: Commit**

```bash
git add overlays tests/host/test_sudoers_syntax.bats
git commit -m "feat: add shared sudoers, polkit, and parental-os config overlays"
```

---

### Task 3: user-setup + first-login scripts (TDD)

**Files:**
- Create: `overlays/usr/lib/parental-os/user-setup.sh`
- Create: `overlays/usr/lib/parental-os/first-login.sh`
- Create: `overlays/etc/profile.d/parental-os-first-login.sh`
- Create: `tests/host/test_user_setup.bats`
- Create: `tests/host/fixtures/fake-root/etc/parental-os/config.env`

- [ ] **Step 1: Write failing bats tests**

`tests/host/test_user_setup.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FAKE="$(mktemp -d)"
  export FAKE
  mkdir -p "$FAKE/etc/parental-os" "$FAKE/usr/sbin" "$FAKE/etc/group" "$FAKE/home"
  cp "$PARENTAL_OS_ROOT/overlays/etc/parental-os/config.env" "$FAKE/etc/parental-os/config.env"
  # minimal group file
  printf 'root:x:0:\nparental-users:x:910:\n' >"$FAKE/etc/group"
  # stub groupadd/usermod that edit $FAKE/etc/group
  cat >"$FAKE/usr/sbin/groupadd" <<'EOS'
#!/bin/bash
# groupadd NAME
name="$1"
grep -q "^${name}:" "$PARENTAL_FAKE_ROOT/etc/group" && exit 0
echo "${name}:x:910:" >>"$PARENTAL_FAKE_ROOT/etc/group"
EOS
  cat >"$FAKE/usr/sbin/usermod" <<'EOS'
#!/bin/bash
# usermod -aG GROUP USER
group=""; user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -aG) group="$2"; shift 2 ;;
    *) user="$1"; shift ;;
  esac
done
# append user to group line
tmp="$(mktemp)"
while IFS= read -r line; do
  if [[ "$line" == "${group}:"* ]]; then
    if [[ "$line" == *":" ]] || [[ "$line" == *","* ]] || [[ "$line" == *"${user}"* ]]; then
      if [[ "$line" != *"${user}"* ]]; then
        if [[ "$line" == *: ]]; then
          line="${line}${user}"
        else
          line="${line},${user}"
        fi
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
```

- [ ] **Step 2: Run — expect FAIL**

```bash
bats tests/host/test_user_setup.bats
```

- [ ] **Step 3: Implement scripts**

`overlays/usr/lib/parental-os/user-setup.sh`:

```bash
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
```

`overlays/usr/lib/parental-os/first-login.sh`:

```bash
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
```

`overlays/etc/profile.d/parental-os-first-login.sh`:

```bash
# shellcheck shell=sh
if [ -n "${USER:-}" ] && [ "$USER" != "root" ] && [ -x /usr/lib/parental-os/first-login.sh ]; then
  /usr/lib/parental-os/first-login.sh || true
fi
```

```bash
chmod +x overlays/usr/lib/parental-os/user-setup.sh overlays/usr/lib/parental-os/first-login.sh
```

- [ ] **Step 4: Run bats — expect PASS**

```bash
bats tests/host/test_user_setup.bats
```

- [ ] **Step 5: Commit**

```bash
git add overlays/usr/lib/parental-os overlays/etc/profile.d tests/host/test_user_setup.bats
git commit -m "feat: add user-setup and first-login inheritance hooks"
```

---

### Task 4: parental-guard CLI + systemd units + agent stub

**Files:**
- Create: `overlays/usr/bin/parental-guard`
- Create: `overlays/usr/lib/parental-os/agent/server.py`
- Create: `overlays/usr/lib/systemd/system/parental-guard.service`
- Create: `overlays/usr/lib/systemd/system/parental-guard-agent.service`
- Create: `tests/host/test_parental_guard_cli.bats`
- Create: `tests/host/test_agent_health.bats`
- Create: `docs/agent-api.md`

- [ ] **Step 1: Write failing CLI and agent tests**

`tests/host/test_parental_guard_cli.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  chmod +x "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" 2>/dev/null || true
}

@test "parental-guard status exits 0 on overlay tree with config" {
  run env PARENTAL_OS_ROOT_FS="$PARENTAL_OS_ROOT/overlays" \
    "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"parental-os"* ]] || [[ "$output" == *"OK"* ]] || [[ "$output" == *"status"* ]]
}

@test "parental-guard doctor mentions group" {
  run env PARENTAL_OS_ROOT_FS="$PARENTAL_OS_ROOT/overlays" \
    "$PARENTAL_OS_ROOT/overlays/usr/bin/parental-guard" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"parental-users"* ]]
}
```

`tests/host/test_agent_health.bats`:

```bash
#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PORT=17420
  TOKEN_DIR="$(mktemp -d)"
  echo "test-token-123" >"$TOKEN_DIR/agent.token"
  STATE="$(mktemp -d)"
  python3 "$PARENTAL_OS_ROOT/overlays/usr/lib/parental-os/agent/server.py" \
    --bind 127.0.0.1 --port "$PORT" \
    --token-file "$TOKEN_DIR/agent.token" \
    --state-dir "$STATE" &
  export AGENT_PID=$!
  export PORT TOKEN_DIR STATE
  sleep 0.5
}

teardown() {
  kill "$AGENT_PID" 2>/dev/null || true
  rm -rf "$TOKEN_DIR" "$STATE"
}

@test "GET /health returns ok without token" {
  run curl -sf "http://127.0.0.1:${PORT}/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok"'* ]] || [[ "$output" == *'ok'* ]]
}

@test "GET /v1/status without token is 401" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/v1/status"
  [ "$output" = "401" ]
}

@test "GET /v1/status with token works" {
  run curl -sf -H "Authorization: Bearer test-token-123" "http://127.0.0.1:${PORT}/v1/status"
  [ "$status" -eq 0 ]
}

@test "POST /v1/allowances returns 501" {
  code="$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer test-token-123" \
    "http://127.0.0.1:${PORT}/v1/allowances")"
  [ "$code" = "501" ]
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
bats tests/host/test_parental_guard_cli.bats tests/host/test_agent_health.bats
```

- [ ] **Step 3: Implement CLI, agent, units, docs**

`overlays/usr/bin/parental-guard`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_FS="${PARENTAL_OS_ROOT_FS:-}"
CFG="${ROOT_FS}/etc/parental-os/config.env"
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG"
elif [[ -f /etc/parental-os/config.env ]]; then
  # shellcheck disable=SC1091
  source /etc/parental-os/config.env
fi

GROUP_NAME="${PARENTAL_OS_GROUP:-parental-users}"
cmd="${1:-status}"

status_cmd() {
  echo "parental-os status"
  echo "group: ${GROUP_NAME}"
  if [[ -n "$ROOT_FS" ]]; then
    echo "rootfs: $ROOT_FS (overlay/dev mode)"
    echo "result: OK"
    return 0
  fi
  if getent group "$GROUP_NAME" >/dev/null 2>&1; then
    echo "group_exists: yes"
  else
    echo "group_exists: no"
  fi
  if systemctl is-active --quiet parental-guard-agent.service 2>/dev/null; then
    echo "agent: active"
  else
    echo "agent: inactive_or_unavailable"
  fi
  echo "result: OK"
}

doctor_cmd() {
  echo "parental-os doctor"
  echo "expected_group: parental-users (config: ${GROUP_NAME})"
  local issues=0
  if [[ -z "$ROOT_FS" ]]; then
    getent group "$GROUP_NAME" >/dev/null || { echo "MISSING group $GROUP_NAME"; issues=1; }
    [[ -f /etc/sudoers.d/parental-os ]] || { echo "MISSING sudoers drop-in"; issues=1; }
    [[ -x /usr/lib/parental-os/user-setup.sh ]] || { echo "MISSING user-setup.sh"; issues=1; }
    [[ -f /usr/lib/parental-os/agent/server.py ]] || { echo "MISSING agent"; issues=1; }
  else
    [[ -f "$ROOT_FS/etc/sudoers.d/parental-os" ]] || { echo "MISSING sudoers in rootfs"; issues=1; }
    echo "dev_mode_checks: basic file presence only"
  fi
  if [[ "$issues" -eq 0 ]]; then
    echo "doctor: OK"
    return 0
  fi
  echo "doctor: ISSUES"
  return 1
}

case "$cmd" in
  status) status_cmd ;;
  doctor) doctor_cmd ;;
  *) echo "usage: parental-guard status|doctor" >&2; exit 2 ;;
esac
```

`overlays/usr/lib/parental-os/agent/server.py`:

```python
#!/usr/bin/env python3
"""parental-os LAN agent stub (v1). Stdlib only."""

from __future__ import annotations

import argparse
import json
import os
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse


def load_or_create_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(32)
    path.write_text(token + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return token


class AgentHandler(BaseHTTPRequestHandler):
    server_version = "parental-os-agent/0.1"

    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth_ok(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        got = auth[len("Bearer ") :].strip()
        return secrets.compare_digest(got, self.server.token)  # type: ignore[attr-defined]

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"status": "ok", "service": "parental-guard-agent"})
            return
        if path == "/v1/status":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(
                200,
                {
                    "service": "parental-guard-agent",
                    "version": "0.1.0-stub",
                    "enforcement": "placeholder",
                    "group": "parental-users",
                },
            )
            return
        if path == "/v1/users":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(501, {"error": "not_implemented", "op": "list_users"})
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/v1/allowances":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(501, {"error": "not_implemented", "op": "set_allowances"})
            return
        self._json(404, {"error": "not_found"})

    def log_message(self, fmt: str, *args) -> None:
        # quieter default logs
        return


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="parental-os agent stub")
    p.add_argument("--bind", default=os.environ.get("PARENTAL_OS_AGENT_BIND", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PARENTAL_OS_AGENT_PORT", "7420")))
    p.add_argument(
        "--token-file",
        default=os.environ.get("PARENTAL_OS_TOKEN_FILE", "/etc/parental-os/agent.token"),
    )
    p.add_argument(
        "--state-dir",
        default=os.environ.get("PARENTAL_OS_STATE_DIR", "/var/lib/parental-os"),
    )
    args = p.parse_args(argv)

    token = load_or_create_token(Path(args.token_file))
    Path(args.state_dir).mkdir(parents=True, exist_ok=True)

    httpd = ThreadingHTTPServer((args.bind, args.port), AgentHandler)
    httpd.token = token  # type: ignore[attr-defined]
    print(f"parental-guard-agent listening on {args.bind}:{args.port}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

`overlays/usr/lib/systemd/system/parental-guard.service`:

```ini
[Unit]
Description=parental-os guard presence check
After=multi-user.target
Wants=parental-guard-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/parental-guard status
# Discourage casual stop from non-root contexts; root can still override.
RefuseManualStop=false

[Install]
WantedBy=multi-user.target
```

`overlays/usr/lib/systemd/system/parental-guard-agent.service`:

```ini
[Unit]
Description=parental-os LAN agent stub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/parental-os/config.env
ExecStart=/usr/bin/python3 /usr/lib/parental-os/agent/server.py
Restart=on-failure
RestartSec=2
# Default bind comes from config.env (127.0.0.1)

[Install]
WantedBy=multi-user.target
```

`docs/agent-api.md`:

```markdown
# parental-os agent API (v1 stub)

Default bind: `127.0.0.1:7420` (see `/etc/parental-os/config.env`).

Auth: `Authorization: Bearer <token>` where token is in `PARENTAL_OS_TOKEN_FILE` (default `/etc/parental-os/agent.token`). Created on first start if missing (mode 0600).

## Endpoints

| Method | Path | Auth | v1 behavior |
|--------|------|------|-------------|
| GET | `/health` | no | `{"status":"ok",...}` |
| GET | `/v1/status` | yes | stub status JSON |
| GET | `/v1/users` | yes | `501 not_implemented` |
| POST | `/v1/allowances` | yes | `501 not_implemented` |

Phase 3 will implement real allowance and user listing against timekpr.
```

```bash
chmod +x overlays/usr/bin/parental-guard overlays/usr/lib/parental-os/agent/server.py
```

- [ ] **Step 4: Run tests**

```bash
sudo pacman -S --needed python curl
bats tests/host/test_parental_guard_cli.bats tests/host/test_agent_health.bats
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add overlays/usr/bin/parental-guard overlays/usr/lib/parental-os/agent \
  overlays/usr/lib/systemd docs/agent-api.md \
  tests/host/test_parental_guard_cli.bats tests/host/test_agent_health.bats
git commit -m "feat: add parental-guard CLI, agent stub, and systemd units"
```

---

### Task 5: apply-overlays.sh + sync package payload

**Files:**
- Create: `scripts/apply-overlays.sh`
- Create: `scripts/sync-package-from-overlays.sh`
- Create: `tests/host/test_apply_overlays.bats`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bats
# tests/host/test_apply_overlays.bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DEST="$(mktemp -d)"
  export DEST
}

teardown() {
  rm -rf "$DEST"
}

@test "apply-overlays copies sudoers and parental-guard binary" {
  run "$PARENTAL_OS_ROOT/scripts/apply-overlays.sh" "$DEST"
  [ "$status" -eq 0 ]
  [[ -f "$DEST/etc/sudoers.d/parental-os" ]]
  [[ -x "$DEST/usr/bin/parental-guard" ]]
  [[ -f "$DEST/usr/lib/systemd/system/parental-guard-agent.service" ]]
}
```

- [ ] **Step 2: Run — FAIL**

```bash
bats tests/host/test_apply_overlays.bats
```

- [ ] **Step 3: Implement scripts**

`scripts/apply-overlays.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"

dest="${1:-}"
[[ -n "$dest" ]] || die "usage: apply-overlays.sh <destination-rootfs>"
[[ -d "$dest" ]] || mkdir -p "$dest"

require_cmd rsync
rsync -a --delete "${ROOT}/overlays/" "${dest}/"

# Enforce sensitive modes
if [[ -f "${dest}/etc/sudoers.d/parental-os" ]]; then
  chmod 440 "${dest}/etc/sudoers.d/parental-os"
  chown root:root "${dest}/etc/sudoers.d/parental-os" 2>/dev/null || true
fi
find "${dest}/usr/lib/parental-os" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null || true
chmod 755 "${dest}/usr/bin/parental-guard" 2>/dev/null || true
chmod 755 "${dest}/usr/lib/parental-os/agent/server.py" 2>/dev/null || true

log "applied overlays to ${dest}"
```

`scripts/sync-package-from-overlays.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
require_cmd rsync
dest="$ROOT/packages/parental-guard/src"
rm -rf "$dest"
mkdir -p "$dest"
rsync -a "$ROOT/overlays/" "$dest/"
log "synced overlays -> packages/parental-guard/src"
```

```bash
chmod +x scripts/apply-overlays.sh scripts/sync-package-from-overlays.sh
```

- [ ] **Step 4: PASS bats**

```bash
bats tests/host/test_apply_overlays.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/apply-overlays.sh scripts/sync-package-from-overlays.sh tests/host/test_apply_overlays.bats
git commit -m "feat: add apply-overlays and package sync scripts"
```

---

### Task 6: Arch package (PKGBUILD) for parental-guard

**Files:**
- Create: `packages/parental-guard/arch/PKGBUILD`
- Create: `scripts/build-parental-guard-arch.sh`
- Create: `packages/parental-guard/arch/parental-guard.install`

- [ ] **Step 1: Sync src and write PKGBUILD**

```bash
./scripts/sync-package-from-overlays.sh
```

`packages/parental-guard/arch/PKGBUILD`:

```bash
# Maintainer: parental-os
pkgname=parental-guard
pkgver=0.1.0
pkgrel=1
pkgdesc="parental-os guard placeholder (sudo/polkit/agent stub)"
arch=('any')
url="https://github.com/cgtarmenta/parental-os"
license=('MIT')
depends=('bash' 'python' 'sudo' 'polkit' 'systemd')
source=()
install=parental-guard.install

package() {
  local root="$startdir/../src"
  # Prefer repo overlays path when building from monorepo scripts
  if [[ ! -d "$root/etc" ]]; then
    root="$startdir/../../overlays"
  fi
  cp -a "$root"/* "$pkgdir"/
  chmod 440 "$pkgdir/etc/sudoers.d/parental-os"
  mkdir -p "$pkgdir/var/lib/parental-os"
}
```

`packages/parental-guard/arch/parental-guard.install`:

```bash
post_install() {
  groupadd --system parental-users 2>/dev/null || groupadd parental-users 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable parental-guard.service parental-guard-agent.service >/dev/null 2>&1 || true
}

post_upgrade() {
  post_install
}
```

`scripts/build-parental-guard-arch.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd makepkg
"$ROOT/scripts/sync-package-from-overlays.sh"
# Ensure src layout for PKGBUILD
mkdir -p "$ROOT/packages/parental-guard/src"
cd "$ROOT/packages/parental-guard/arch"
# makepkg needs writable dir; use --holdver
makepkg -f --nodeps 2>&1 | tee "$ROOT/out/logs/parental-guard-arch-makepkg.log"
shopt -s nullglob
for f in parental-guard-*.pkg.tar.*; do
  mv -f "$f" "$ROOT/out/packages/"
done
log "arch package(s) in out/packages"
```

```bash
chmod +x scripts/build-parental-guard-arch.sh
```

- [ ] **Step 2: Build package on host**

```bash
sudo pacman -S --needed base-devel
./scripts/build-parental-guard-arch.sh
ls out/packages/
```

Expected: `parental-guard-0.1.0-1-any.pkg.tar.zst` (or similar) exists.

- [ ] **Step 3: Optional install smoke (root)**

```bash
sudo pacman -U out/packages/parental-guard-*.pkg.tar.zst
parental-guard doctor || true
sudo pacman -Rns parental-guard || true
```

- [ ] **Step 4: Commit**

```bash
git add packages/parental-guard scripts/build-parental-guard-arch.sh
git commit -m "feat: add Arch PKGBUILD and package build script for parental-guard"
```

---

### Task 7: Debian package build via Docker

**Files:**
- Create: `packages/parental-guard/debian/control`
- Create: `packages/parental-guard/debian/rules`
- Create: `packages/parental-guard/debian/compat`
- Create: `packages/parental-guard/debian/changelog`
- Create: `packages/parental-guard/debian/parental-guard.install`
- Create: `packages/parental-guard/debian/postinst`
- Create: `packages/parental-guard/debian/source/format`
- Create: `scripts/build-parental-guard-deb.sh`

- [ ] **Step 1: Write debian packaging metadata**

`packages/parental-guard/debian/control`:

```control
Source: parental-guard
Section: admin
Priority: optional
Maintainer: parental-os <cgtarmenta@users.noreply.github.com>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.6.2
Homepage: https://github.com/cgtarmenta/parental-os

Package: parental-guard
Architecture: all
Depends: ${misc:Depends}, bash, python3, sudo, polkitd | policykit-1, systemd
Description: parental-os guard placeholder
 Sudo/polkit policies, user inheritance hooks, and LAN agent stub
 for parental-os images.
```

`packages/parental-guard/debian/compat`:

```text
13
```

`packages/parental-guard/debian/changelog`:

```changelog
parental-guard (0.1.0-1) unstable; urgency=medium

  * Initial placeholder package.

 -- parental-os <cgtarmenta@users.noreply.github.com>  Sat, 01 Aug 2026 12:00:00 +0000
```

`packages/parental-guard/debian/rules`:

```makefile
#!/usr/bin/make -f
export DH_VERBOSE = 1

%:
	dh $@

override_dh_auto_build:
	@echo "no build step"

override_dh_auto_install:
	mkdir -p debian/parental-guard
	cp -a src/. debian/parental-guard/ || cp -a ../src/. debian/parental-guard/
	chmod 440 debian/parental-guard/etc/sudoers.d/parental-os
```

Actually monorepo layout: build script will stage a proper debian package tree. Prefer:

`scripts/build-parental-guard-deb.sh` stages `/tmp` or `out/deb-src/parental-guard-0.1.0/` with `src` content as upstream and debian/.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd docker

"$ROOT/scripts/sync-package-from-overlays.sh"

STAGE="$ROOT/out/deb-src/parental-guard-0.1.0"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# upstream contents at package root for dh install via debian/parental-guard.install
rsync -a "$ROOT/packages/parental-guard/src/" "$STAGE/"
rsync -a "$ROOT/packages/parental-guard/debian/" "$STAGE/debian/"

# install file: map tree into package
cat >"$STAGE/debian/parental-guard.install" <<'EOF'
etc usr
EOF

# Fix rules for staged layout
cat >"$STAGE/debian/rules" <<'EOF'
#!/usr/bin/make -f
%:
	dh $@
EOF
chmod +x "$STAGE/debian/rules"

mkdir -p "$STAGE/debian/source"
echo "3.0 (native)" >"$STAGE/debian/source/format"

cat >"$STAGE/debian/postinst" <<'EOF'
#!/bin/sh
set -e
groupadd --system parental-users 2>/dev/null || groupadd parental-users 2>/dev/null || true
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
  systemctl enable parental-guard.service parental-guard-agent.service || true
fi
exit 0
EOF
chmod 755 "$STAGE/debian/postinst"

docker run --rm -v "$STAGE:/src" -w /src debian:bookworm bash -lc '
  set -e
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y debhelper dpkg-dev
  dpkg-buildpackage -us -uc -b
  ls -la /src/..
'

mkdir -p "$ROOT/out/packages"
cp -a "$ROOT/out/deb-src"/parental-guard_*.deb "$ROOT/out/packages/" 2>/dev/null \
  || cp -a "$STAGE"/../parental-guard_*.deb "$ROOT/out/packages/"
log "deb package(s) in out/packages"
```

Also place static debian templates under `packages/parental-guard/debian/` matching control/changelog/compat/postinst for version control (rules may be overwritten in stage).

- [ ] **Step 2: Build deb**

```bash
# docker required
./scripts/build-parental-guard-deb.sh
ls out/packages/*.deb
```

Expected: `parental-guard_0.1.0-1_all.deb` present.

- [ ] **Step 3: Commit**

```bash
git add packages/parental-guard/debian scripts/build-parental-guard-deb.sh
git commit -m "feat: add Debian packaging and Docker-based deb build"
```

---

### Task 8: CachyOS/Arch ISO profile (archiso)

**Files:**
- Create: `distros/cachyos/profile/profiledef.sh`
- Create: `distros/cachyos/profile/packages.x86_64`
- Create: `distros/cachyos/profile/bootstrap_packages.x86_64`
- Create: `distros/cachyos/profile/pacman.conf`
- Create: `distros/cachyos/profile/airootfs/etc/passwd` (via archiso defaults — copy from releng)
- Create: `scripts/build-cachyos.sh`

- [ ] **Step 1: Install archiso and seed profile from releng**

```bash
sudo pacman -S --needed archiso
rm -rf distros/cachyos/profile
cp -a /usr/share/archiso/configs/releng distros/cachyos/profile
```

- [ ] **Step 2: Customize packages and profiledef**

Edit `distros/cachyos/profile/packages.x86_64` — keep releng baseline, append:

```text
python
sudo
polkit
qemu-guest-agent
openssh
cloud-init
```

Edit `profiledef.sh` — set:

```bash
iso_name="parental-os-cachy"
iso_label="PARENTAL_OS_CACHY"
iso_publisher="parental-os <https://github.com/cgtarmenta/parental-os>"
iso_application="parental-os Cachy/Arch image"
```

Add build hook script `distros/cachyos/profile/airootfs/root/customize_airootfs.sh` is legacy; modern archiso uses `profiledef` + packages. Instead, extend `scripts/build-cachyos.sh` to:

1. Build arch package into a local repo dir.
2. Add that repo to profile `pacman.conf`.
3. Add `parental-guard` to `packages.x86_64`.
4. Run `mkarchiso`.

`scripts/build-cachyos.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd mkarchiso

"$ROOT/scripts/build-parental-guard-arch.sh"

LOCAL_REPO="$ROOT/out/archrepo"
rm -rf "$LOCAL_REPO"
mkdir -p "$LOCAL_REPO"
cp -a "$ROOT/out/packages"/parental-guard-*.pkg.tar.* "$LOCAL_REPO/"
( cd "$LOCAL_REPO" && repo-add parental-os.db.tar.gz parental-guard-*.pkg.tar.* )

PROFILE="$ROOT/distros/cachyos/profile"
# Inject local repo into pacman.conf if not present
if ! grep -q '\[parental-os\]' "$PROFILE/pacman.conf"; then
  cat >>"$PROFILE/pacman.conf" <<EOF

[parental-os]
SigLevel = Optional TrustAll
Server = file://${LOCAL_REPO}
EOF
fi

if ! grep -qx 'parental-guard' "$PROFILE/packages.x86_64"; then
  echo 'parental-guard' >>"$PROFILE/packages.x86_64"
fi

WORK="$ROOT/out/cachyos/work"
rm -rf "$WORK"
mkdir -p "$WORK" "$ROOT/out/cachyos"

sudo mkarchiso -v -w "$WORK" -o "$ROOT/out/cachyos" "$PROFILE" \
  2>&1 | tee "$ROOT/out/logs/build-cachyos.log"

log "Cachy/Arch ISO artifacts in out/cachyos"
```

Document in README: v1 uses Arch releng + local `parental-guard`; switching pacman mirrors to CachyOS optimized repos is a follow-up one-liner in `pacman.conf`.

- [ ] **Step 3: Build ISO (long, needs root, network, disk)**

```bash
./scripts/build-cachyos.sh
ls -lh out/cachyos/*.iso
```

Expected: ISO file created.

- [ ] **Step 4: Commit profile customizations (not work dirs)**

```bash
git add distros/cachyos/profile scripts/build-cachyos.sh
git commit -m "feat: add archiso-based parental-os Cachy/Arch ISO builder"
```

---

### Task 9: Ubuntu live-build via Docker

**Files:**
- Create: `distros/ubuntu/docker/Dockerfile`
- Create: `distros/ubuntu/auto/config`
- Create: `distros/ubuntu/config/hooks/normal/9000-parental-os.hook.chroot`
- Create: `distros/ubuntu/config/package-lists/parental-os.list.chroot`
- Create: `scripts/build-ubuntu.sh`

- [ ] **Step 1: Dockerfile for live-build**

`distros/ubuntu/docker/Dockerfile`:

```dockerfile
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build live-boot live-config live-tools \
    ca-certificates curl gnupg squashfs-tools xorriso \
    debootstrap syslinux-common isolinux \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
```

- [ ] **Step 2: auto/config and hooks**

`distros/ubuntu/auto/config`:

```bash
#!/bin/sh
set -e
lb config noauto \
  --architectures amd64 \
  --distribution bookworm \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootappend-live "boot=live components username=child hostname=parental-os" \
  --mirror-bootstrap "https://deb.debian.org/debian/" \
  --mirror-binary "https://deb.debian.org/debian/" \
  --debian-installer none \
  --updates true \
  --security true \
  "${@}"
```

Note: Spec says Ubuntu; bookworm live-build is the practical path on Debian tooling. Brand as `parental-os-ubuntu` compatible image; switch `--distribution jammy` + Ubuntu mirrors in a later iteration if Ubuntu-specific packages are required. Document this honestly in README as **Debian live baseline for Ubuntu-family target** OR use:

```bash
--distribution jammy \
--mirror-bootstrap http://archive.ubuntu.com/ubuntu/ \
--mirror-binary http://archive.ubuntu.com/ubuntu/ \
--parent-mirror-bootstrap http://archive.ubuntu.com/ubuntu/ \
```

**Prefer Ubuntu jammy mirrors in final implementation** to match the product name. If jammy live-build from Debian container fails, fall back to bookworm and document gap.

`distros/ubuntu/config/package-lists/parental-os.list.chroot`:

```text
sudo
python3
polkitd
openssh-server
cloud-init
qemu-guest-agent
```

`distros/ubuntu/config/hooks/normal/9000-parental-os.hook.chroot`:

```bash
#!/bin/bash
set -e
# Install local deb if present
if ls /tmp/parental-os-debs/parental-guard_*.deb >/dev/null 2>&1; then
  apt-get install -y /tmp/parental-os-debs/parental-guard_*.deb || dpkg -i /tmp/parental-os-debs/parental-guard_*.deb
  apt-get install -f -y
fi
groupadd --system parental-users 2>/dev/null || true
systemctl enable parental-guard.service parental-guard-agent.service || true
# Seed demo child user for QEMU (password disabled login via cloud-init later)
if ! id child >/dev/null 2>&1; then
  useradd -m -s /bin/bash child || true
  /usr/lib/parental-os/user-setup.sh child || true
fi
```

- [ ] **Step 3: build-ubuntu.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd docker

"$ROOT/scripts/build-parental-guard-deb.sh"

IMG="parental-os-live-build:bookworm"
docker build -t "$IMG" "$ROOT/distros/ubuntu/docker"

BUILD_DIR="$ROOT/out/ubuntu/lb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
# seed live-build tree
cp -a "$ROOT/distros/ubuntu/auto" "$BUILD_DIR/"
mkdir -p "$BUILD_DIR/config"
cp -a "$ROOT/distros/ubuntu/config/." "$BUILD_DIR/config/" 2>/dev/null || true
mkdir -p "$BUILD_DIR/config/packages.chroot"
cp -a "$ROOT/out/packages"/parental-guard_*.deb "$BUILD_DIR/config/packages.chroot/" 2>/dev/null || \
  cp -a "$ROOT/out/packages"/parental-guard_*.deb "$BUILD_DIR/" 

# Also place debs where hook expects
mkdir -p "$BUILD_DIR/config/includes.chroot/tmp/parental-os-debs"
cp -a "$ROOT/out/packages"/parental-guard_*.deb "$BUILD_DIR/config/includes.chroot/tmp/parental-os-debs/"

docker run --rm --privileged \
  -v "$BUILD_DIR:/build" \
  -v "$ROOT/out/packages:/packages:ro" \
  -w /build "$IMG" bash -lc '
    set -e
    chmod +x auto/config
    lb config
    lb build
  ' 2>&1 | tee "$ROOT/out/logs/build-ubuntu.log"

find "$BUILD_DIR" -name '*.iso' -exec cp -a {} "$ROOT/out/ubuntu/" \;
log "Ubuntu-family ISO artifacts in out/ubuntu"
```

- [ ] **Step 4: Build (long)**

```bash
./scripts/build-ubuntu.sh
ls -lh out/ubuntu/*.iso
```

Expected: ISO created (or documented failure with actionable log).

- [ ] **Step 5: Commit**

```bash
git add distros/ubuntu scripts/build-ubuntu.sh
git commit -m "feat: add Docker live-build pipeline for Ubuntu-family ISO"
```

---

### Task 10: QEMU smoke tests (cloud-init + SSH)

**Files:**
- Create: `scripts/make-cloud-init-seed.sh`
- Create: `scripts/test-qemu.sh`
- Create: `tests/qemu/user-data`
- Create: `tests/qemu/meta-data`
- Create: `tests/qemu/assert_guest.sh`

- [ ] **Step 1: Cloud-init seed materials**

Generate a dedicated CI SSH key in `out/qemu/id_ed25519` (gitignored) during test, not committed.

`tests/qemu/user-data`:

```yaml
#cloud-config
users:
  - name: child
    groups: [sudo, parental-users]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - SSH_PUBKEY_PLACEHOLDER
  - name: qa
    groups: [sudo, parental-users]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - SSH_PUBKEY_PLACEHOLDER
package_update: false
runcmd:
  - [ /usr/lib/parental-os/user-setup.sh, child ]
  - [ /usr/lib/parental-os/user-setup.sh, qa ]
  - [ systemctl, enable, --now, parental-guard.service ]
  - [ systemctl, enable, --now, parental-guard-agent.service ]
  - [ systemctl, enable, --now, ssh ]
ssh_pwauth: false
```

`tests/qemu/meta-data`:

```yaml
instance-id: parental-os-qemu-001
local-hostname: parental-os-test
```

`scripts/make-cloud-init-seed.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
ensure_out_dirs
require_cmd genisoimage || require_cmd mkisofs || require_cmd xorriso

KEY="$ROOT/out/qemu/id_ed25519"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "parental-os-qemu"
fi
PUB="$(cat "${KEY}.pub")"
SEED_DIR="$ROOT/out/qemu/seed"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
sed "s|SSH_PUBKEY_PLACEHOLDER|${PUB}|g" "$ROOT/tests/qemu/user-data" >"$SEED_DIR/user-data"
cp "$ROOT/tests/qemu/meta-data" "$SEED_DIR/meta-data"

OUT="$ROOT/out/qemu/seed.iso"
if command -v xorriso >/dev/null; then
  xorriso -as mkisofs -output "$OUT" -volid CIDATA -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
elif command -v genisoimage >/dev/null; then
  genisoimage -output "$OUT" -volid cidata -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
else
  mkisofs -output "$OUT" -volid cidata -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
fi
log "seed iso: $OUT"
```

`tests/qemu/assert_guest.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HOST="${1:?host}"
PORT="${2:?port}"
KEY="${3:?key}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$PORT" "qa@${HOST}")

"${SSH[@]}" 'systemctl is-active parental-guard.service || systemctl is-active parental-guard-agent.service'
"${SSH[@]}" 'getent group parental-users | grep -E "child|qa"'
"${SSH[@]}" 'sudo -n true'
# Guarded command must fail
if "${SSH[@]}" 'sudo -n visudo -c' 2>/dev/null; then
  echo "ERROR: sudo visudo should be denied" >&2
  exit 1
fi
if "${SSH[@]}" 'sudo -n systemctl stop parental-guard-agent.service' 2>/dev/null; then
  # If stop unexpectedly succeeds, fail test
  echo "ERROR: stop agent via sudo should be denied" >&2
  exit 1
fi
"${SSH[@]}" 'parental-guard status'
"${SSH[@]}" 'curl -sf http://127.0.0.1:7420/health'
echo "assert_guest: OK"
```

`scripts/test-qemu.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs
require_cmd qemu-system-x86_64
"$ROOT/scripts/make-cloud-init-seed.sh"

target="${1:-all}"
run_one() {
  local name="$1"
  local iso
  iso="$(ls -1t "$ROOT/out/$name"/*.iso 2>/dev/null | head -1 || true)"
  [[ -n "$iso" ]] || die "no ISO for $name in out/$name"
  local ssh_port
  ssh_port=$((2200 + RANDOM % 200))
  local disk="$ROOT/out/qemu/${name}.qcow2"
  qemu-img create -f qcow2 "$disk" 20G >/dev/null
  local logf="$ROOT/out/logs/qemu-${name}.log"
  local kvm=()
  [[ -r /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

  qemu-system-x86_64 "${kvm[@]}" -m 2048 -smp 2 \
    -drive file="$disk",if=virtio \
    -cdrom "$iso" \
    -drive file="$ROOT/out/qemu/seed.iso",media=cdrom \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -display none -serial file:"$logf" \
    -daemonize -pidfile "$ROOT/out/qemu/${name}.pid"

  # Wait for SSH up to 10 minutes (first boot + cloud-init)
  local ok=0
  for _ in $(seq 1 120); do
    if bash "$ROOT/tests/qemu/assert_guest.sh" 127.0.0.1 "$ssh_port" "$ROOT/out/qemu/id_ed25519"; then
      ok=1
      break
    fi
    sleep 5
  done
  if [[ -f "$ROOT/out/qemu/${name}.pid" ]]; then
    kill "$(cat "$ROOT/out/qemu/${name}.pid")" 2>/dev/null || true
  fi
  [[ "$ok" -eq 1 ]] || die "QEMU assertions failed for $name (see $logf)"
  log "QEMU OK: $name"
}

case "$target" in
  all) run_one ubuntu; run_one cachyos ;;
  ubuntu) run_one ubuntu ;;
  cachyos) run_one cachyos ;;
  *) die "unknown target $target" ;;
esac
```

```bash
chmod +x scripts/make-cloud-init-seed.sh scripts/test-qemu.sh tests/qemu/assert_guest.sh
```

- [ ] **Step 2: Run QEMU test against available ISO**

```bash
just test-qemu cachyos
# or
./scripts/test-qemu.sh ubuntu
```

Expected: `assert_guest: OK` and script exit 0. If live ISO does not auto-install to disk, **adjust**: use `qemu` with the ISO as the root filesystem via `boot=live` and cloud-init on live session, or use `archiso` with `copytoram` + precreated airootfs user.  

**Fallback if install-from-ISO is too heavy for v1:** change `test-qemu.sh` to boot **live** session with cloud-init (Debian live supports cloud-init packages) and run asserts in live user space without qcow install. Implement that fallback in the same task if first approach does not get SSH within timeout:

```bash
# Live-boot mode: no qcow install
qemu-system-x86_64 ... -cdrom "$iso" -boot d ...
```

Update assert to use live username `child` from bootappend.

- [ ] **Step 3: Commit**

```bash
git add scripts/test-qemu.sh scripts/make-cloud-init-seed.sh tests/qemu
git commit -m "feat: add QEMU cloud-init smoke tests for guardrails"
```

---

### Task 11: User creation hooks for package installs (distro glue)

**Files:**
- Create: `overlays/usr/share/parental-os/adduser.local` (Debian adduser hook)
- Create: `overlays/etc/adduser.conf.d/parental-os.conf` if supported — on Debian, `/usr/local/sbin/adduser.local` or `/etc/adduser.conf` EXTRA_GROUPS
- Modify: `packages/parental-guard/arch/parental-guard.install` and debian `postinst` to install hooks
- Create: `overlays/usr/lib/parental-os/install-user-hooks.sh`

Debian: document and install `ADD_EXTRA_GROUPS=1` and `EXTRA_GROUPS=parental-users` via `/etc/adduser.conf` drop-in is not always supported — use `/usr/local/sbin/adduser.local`:

```bash
#!/bin/sh
# adduser.local USER UID GID HOME
/usr/lib/parental-os/user-setup.sh "$1" || true
```

Arch: install a pacman hook is wrong for useradd; install `/usr/share/libalpm/scripts` no — use `/etc/useradd` defaults:

`/etc/default/useradd` does not append groups. Prefer wrapping via systemd `sysusers` only for system users.

**Practical v1 approach (implement):**
1. Debian `adduser.local`
2. `/etc/profile.d` first-login (already)
3. cloud-init / ISO hook creates baseline users
4. Optional: `/etc/pam.d` is out of scope

`overlays/usr/local/sbin/adduser.local`:

```bash
#!/bin/sh
/usr/lib/parental-os/user-setup.sh "$1" || true
```

Also `overlays/etc/cloud/cloud.cfg.d/99-parental-os.cfg`:

```yaml
system_info:
  default_user:
    groups: [parental-users, sudo]
```

- [ ] **Step 1: Add files, sync package, rebuild packages**

```bash
mkdir -p overlays/usr/local/sbin overlays/etc/cloud/cloud.cfg.d
# write adduser.local + cloud cfg
chmod 755 overlays/usr/local/sbin/adduser.local
./scripts/sync-package-from-overlays.sh
./scripts/build-parental-guard-arch.sh
./scripts/build-parental-guard-deb.sh
```

- [ ] **Step 2: Host test that adduser.local calls user-setup** (optional bats)

- [ ] **Step 3: Commit**

```bash
git add overlays packages
git commit -m "feat: auto-enroll new users via adduser.local and cloud-init defaults"
```

---

### Task 12: README + Justfile polish + shellcheck

**Files:**
- Create: `README.md`
- Modify: `Justfile` (ensure package recipes work)
- Create: `scripts/check-shell.sh`

- [ ] **Step 1: README.md**

```markdown
# parental-os

Multi-distro installable images (Ubuntu-family + Cachy/Arch) with desktop-agnostic parental guardrails.

## Spec

See [docs/superpowers/specs/2026-08-01-parental-os-design.md](docs/superpowers/specs/2026-08-01-parental-os-design.md).

## Threat model (summary)

Local interactive users get passwordless sudo for daily work but are blocked from removing/stopping parental controls via sudoers + polkit + hooks. Real root remains for parents/recovery. LAN agent binds to localhost by default.

## Host dependencies

```bash
sudo pacman -S --needed bats just base-devel archiso qemu-full docker cloud-image-utils xorriso rsync openssh python curl sudo
sudo systemctl enable --now docker
```

## Quick start

```bash
git clone git@github.com:cgtarmenta/parental-os.git
cd parental-os
just test-host
just package-arch
just package-deb
just build cachyos    # long
just build ubuntu     # long, Docker
just test-qemu cachyos
```

Artifacts land in `out/`.

## Layout

- `overlays/` shared filesystem policy
- `packages/parental-guard` deb + arch packaging
- `distros/ubuntu` live-build (Docker)
- `distros/cachyos` archiso profile
- `scripts/` orchestration

## Agent API

See [docs/agent-api.md](docs/agent-api.md).
```

- [ ] **Step 2: shellcheck**

```bash
#!/usr/bin/env bash
# scripts/check-shell.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v shellcheck >/dev/null || { echo "install shellcheck"; exit 0; }
shellcheck -x "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh \
  "$ROOT"/overlays/usr/bin/parental-guard \
  "$ROOT"/overlays/usr/lib/parental-os/*.sh
```

```bash
sudo pacman -S --needed shellcheck
./scripts/check-shell.sh
just test-host
```

- [ ] **Step 3: Commit**

```bash
git add README.md Justfile scripts/check-shell.sh
git commit -m "docs: add README and shellcheck helper for parental-os v1"
```

---

### Task 13: End-to-end verification checklist

- [ ] **Step 1: Host tests green**

```bash
cd /home/dat30/github/parental-os
just test-host
```

Expected: all bats PASS.

- [ ] **Step 2: Both packages build**

```bash
just package-arch
just package-deb
ls out/packages
```

- [ ] **Step 3: At least one ISO builds**

```bash
just build cachyos
# and/or
just build ubuntu
```

- [ ] **Step 4: QEMU smoke on built ISO**

```bash
just test-qemu cachyos
```

Expected: exit 0.

- [ ] **Step 5: Final commit if fixes needed + tag optional**

```bash
git status
# commit any fixes
git tag -a v0.1.0 -m "parental-os v1 pipeline"
```

Do **not** push unless Don Tadeo requests push.

---

## Self-review (plan vs spec)

| Spec requirement | Task(s) |
|------------------|---------|
| Monorepo layout overlays/packages/distros/scripts | 1, 5–9 |
| parental-guard placeholder package deb+arch | 6, 7 |
| sudo/polkit/group inheritance | 2, 3, 11 |
| LAN agent stub + docs | 4, docs/agent-api.md |
| just build all / per distro | 1, 8, 9 |
| apply-overlays single path | 5 |
| QEMU assertions | 10, 13 |
| README + threat model | 12 |
| Root retained / DE-agnostic | documented; no DE packages forced beyond live baseline |
| Docker secondary for build | 7, 9 |
| timekpr fork excluded | no task ships timekpr |

**Placeholder scan:** none intentional; Ubuntu jammy vs bookworm has an explicit prefer-jammy with bookworm fallback note in Task 9.  
**Type/name consistency:** group `parental-users`, units `parental-guard.service` / `parental-guard-agent.service`, CLI `parental-guard`, bind `127.0.0.1:7420`.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-01-parental-os-v1.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session, batch with checkpoints  

Which approach, Don Tadeo?
