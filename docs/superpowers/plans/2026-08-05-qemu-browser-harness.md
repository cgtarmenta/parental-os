# QEMU Browser Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automated QEMU smoke tests and a browser-viewable noVNC VM runner for generated parental-os Linux ISOs.

**Architecture:** Shared Bash helpers resolve ISO targets and output paths. Headless validation uses native QEMU, NoCloud cloud-init, SSH, and guest assertions. Interactive validation uses a project-owned Docker Compose QEMU/noVNC container that boots the same ISOs and exposes a local browser URL.

**Tech Stack:** Bash, Just, Bats, QEMU, cloud-init NoCloud, OpenSSH, Docker Compose, noVNC, websockify.

---

## Preflight Context

Implement against `origin/dev`, not the current main checkout if it is behind or dirty. The main checkout currently has an unrelated local edit in `docs/superpowers/handoff-2026-08-01-session.md`; do not modify or revert it.

Create an isolated worktree before changing code:

```bash
git fetch origin
git worktree add .worktrees/feature-qemu-browser-harness -b feature/qemu-browser-harness origin/dev
```

Use the worktree as the implementation directory:

```bash
cd .worktrees/feature-qemu-browser-harness
```

## File Structure

Create these files:

```text
scripts/lib/qemu.sh                         # Shared target resolution and ISO discovery helpers
scripts/make-cloud-init-seed.sh             # Builds out/qemu/seed.iso and ephemeral SSH key
scripts/test-qemu.sh                        # Native headless QEMU smoke runner
scripts/qemu-browser.sh                     # Docker Compose/noVNC interactive runner
tests/qemu/user-data                        # Cloud-init user-data template
tests/qemu/meta-data                        # Cloud-init NoCloud metadata
tests/qemu/assert_guest.sh                  # SSH assertions executed against booted guests
tests/host/test_qemu_harness.bats           # Host tests for target helpers and syntax checks
distros/qemu-browser/Dockerfile             # Project-owned QEMU/noVNC image
distros/qemu-browser/entrypoint.sh          # Starts QEMU and websockify inside the container
compose.qemu.yml                            # Browser VM Compose service
docs/qemu-harness.md                        # Operator usage for headless and browser workflows
```

Modify these files:

```text
Justfile                                    # Add qemu-browser and qemu-browser-down targets
```

Do not edit these unrelated files:

```text
docs/superpowers/handoff-2026-08-01-session.md
```

---

### Task 1: Shared QEMU Target Helpers

**Files:**
- Create: `scripts/lib/qemu.sh`
- Test: `tests/host/test_qemu_harness.bats`

- [ ] **Step 1: Write failing host tests for target expansion and ISO discovery**

Create `tests/host/test_qemu_harness.bats` with this initial content:

```bash
#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_OUT="$(mktemp -d)"
  source "$PARENTAL_OS_ROOT/scripts/lib/common.sh"
  source "$PARENTAL_OS_ROOT/scripts/lib/qemu.sh"
}

teardown() {
  rm -rf "$PARENTAL_OS_OUT"
}

@test "qemu_targets_for expands all targets in deterministic order" {
  run qemu_targets_for all
  [ "$status" -eq 0 ]
  [ "$output" = $'ubuntu\ncachyos-desktop\ncachyos-handheld' ]
}

@test "qemu_targets_for expands cachyos to both editions" {
  run qemu_targets_for cachyos
  [ "$status" -eq 0 ]
  [ "$output" = $'cachyos-desktop\ncachyos-handheld' ]
}

@test "qemu_targets_for rejects unknown targets" {
  run qemu_targets_for windows
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown QEMU target"* ]]
}

@test "qemu_iso_for_target returns newest ISO for target" {
  mkdir -p "$PARENTAL_OS_OUT/ubuntu"
  old="$PARENTAL_OS_OUT/ubuntu/old.iso"
  new="$PARENTAL_OS_OUT/ubuntu/new.iso"
  : >"$old"
  : >"$new"
  touch -d '2026-08-04 00:00:00 UTC' "$old"
  touch -d '2026-08-05 00:00:00 UTC' "$new"

  run qemu_iso_for_target ubuntu
  [ "$status" -eq 0 ]
  [ "$output" = "$new" ]
}

@test "qemu_iso_for_target fails when requested ISO is missing" {
  mkdir -p "$PARENTAL_OS_OUT/cachyos/desktop"

  run qemu_iso_for_target cachyos-desktop
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ISO found for cachyos-desktop"* ]]
}

@test "qemu_require_single_target rejects aggregate browser targets" {
  run qemu_require_single_target all
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a single ISO target"* ]]
}
```

- [ ] **Step 2: Run the new tests and verify they fail because the helper does not exist**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: FAIL with an error mentioning `scripts/lib/qemu.sh` is missing.

- [ ] **Step 3: Implement the shared helper**

Create `scripts/lib/qemu.sh`:

```bash
#!/usr/bin/env bash
# Shared QEMU helper functions for parental-os scripts.
set -euo pipefail

qemu_targets_for() {
  local target="${1:-all}"
  case "$target" in
    ubuntu)
      printf '%s\n' ubuntu
      ;;
    cachyos-desktop)
      printf '%s\n' cachyos-desktop
      ;;
    cachyos-handheld)
      printf '%s\n' cachyos-handheld
      ;;
    cachyos)
      printf '%s\n' cachyos-desktop cachyos-handheld
      ;;
    all)
      printf '%s\n' ubuntu cachyos-desktop cachyos-handheld
      ;;
    *)
      printf 'unknown QEMU target: %s (use ubuntu|cachyos-desktop|cachyos-handheld|cachyos|all)\n' "$target" >&2
      return 2
      ;;
  esac
}

qemu_target_iso_dir() {
  local target="$1"
  local out
  out="$(out_root)"
  case "$target" in
    ubuntu) printf '%s\n' "$out/ubuntu" ;;
    cachyos-desktop) printf '%s\n' "$out/cachyos/desktop" ;;
    cachyos-handheld) printf '%s\n' "$out/cachyos/handheld" ;;
    *)
      printf 'unknown single QEMU target: %s\n' "$target" >&2
      return 2
      ;;
  esac
}

qemu_iso_for_target() {
  local target="$1"
  local dir
  dir="$(qemu_target_iso_dir "$target")" || return $?
  shopt -s nullglob
  local files=("$dir"/*.iso)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'no ISO found for %s in %s\n' "$target" "$dir" >&2
    return 1
  fi

  local newest="${files[0]}"
  local candidate
  for candidate in "${files[@]}"; do
    if [[ "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done
  printf '%s\n' "$newest"
}

qemu_require_single_target() {
  local target="${1:-ubuntu}"
  case "$target" in
    ubuntu|cachyos-desktop|cachyos-handheld)
      printf '%s\n' "$target"
      ;;
    cachyos|all)
      printf 'browser mode requires a single ISO target: use ubuntu|cachyos-desktop|cachyos-handheld\n' >&2
      return 2
      ;;
    *)
      printf 'unknown QEMU target: %s (use ubuntu|cachyos-desktop|cachyos-handheld)\n' "$target" >&2
      return 2
      ;;
  esac
}
```

- [ ] **Step 4: Run the helper tests and verify they pass**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: PASS with 6 tests.

- [ ] **Step 5: Run the full host suite**

Run:

```bash
DOCKER_CONTEXT=default just test-host
```

Expected: PASS for all host tests.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add scripts/lib/qemu.sh tests/host/test_qemu_harness.bats
git commit -m "feat: add QEMU target resolution helpers"
```

---

### Task 2: Cloud-Init Seed Generation

**Files:**
- Create: `scripts/make-cloud-init-seed.sh`
- Create: `tests/qemu/user-data`
- Create: `tests/qemu/meta-data`
- Modify: `tests/host/test_qemu_harness.bats`

- [ ] **Step 1: Add failing host test for seed generation**

Append this test to `tests/host/test_qemu_harness.bats`:

```bash
@test "make-cloud-init-seed creates key, rendered user-data, and seed ISO" {
  if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1; then
    skip "missing xorriso, genisoimage, or mkisofs"
  fi

  run "$PARENTAL_OS_ROOT/scripts/make-cloud-init-seed.sh"
  [ "$status" -eq 0 ]
  [[ -f "$PARENTAL_OS_OUT/qemu/id_ed25519" ]]
  [[ -f "$PARENTAL_OS_OUT/qemu/id_ed25519.pub" ]]
  [[ -s "$PARENTAL_OS_OUT/qemu/seed.iso" ]]
  [[ -f "$PARENTAL_OS_OUT/qemu/seed/user-data" ]]
  rendered="$(<"$PARENTAL_OS_OUT/qemu/seed/user-data")"
  [[ "$rendered" != *"SSH_PUBKEY_PLACEHOLDER"* ]]
  [[ "$rendered" == *"$(<"$PARENTAL_OS_OUT/qemu/id_ed25519.pub")"* ]]
}
```

- [ ] **Step 2: Run the seed test and verify it fails because the script is missing**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: FAIL in the seed generation test with `No such file or directory` for `scripts/make-cloud-init-seed.sh`.

- [ ] **Step 3: Create cloud-init templates**

Create `tests/qemu/meta-data`:

```yaml
instance-id: parental-os-qemu-001
local-hostname: parental-os-test
```

Create `tests/qemu/user-data`:

```yaml
#cloud-config
package_update: false
ssh_pwauth: false
disable_root: true
write_files:
  - path: /usr/local/sbin/parental-os-qemu-bootstrap
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      install -d -m 0755 /run/parental-os-qemu
      groupadd -f parental-users
      for user in child qa; do
        if ! id -u "$user" >/dev/null 2>&1; then
          useradd -m -s /bin/bash "$user"
        fi
        usermod -aG parental-users "$user"
        install -d -m 0700 -o "$user" -g "$user" "/home/$user/.ssh"
        printf '%s\n' 'SSH_PUBKEY_PLACEHOLDER' >"/home/$user/.ssh/authorized_keys"
        chown "$user:$user" "/home/$user/.ssh/authorized_keys"
        chmod 0600 "/home/$user/.ssh/authorized_keys"
        passwd -l "$user" >/dev/null 2>&1 || true
      done
      if [ -x /usr/lib/parental-os/user-setup.sh ]; then
        /usr/lib/parental-os/user-setup.sh child || true
        /usr/lib/parental-os/user-setup.sh qa || true
      fi
      systemctl enable --now ssh.service >/dev/null 2>&1 || systemctl enable --now sshd.service >/dev/null 2>&1 || true
      systemctl enable --now parental-guard-agent.service >/dev/null 2>&1 || true
      systemctl enable --now parental-guard.service >/dev/null 2>&1 || true
      touch /run/parental-os-qemu/bootstrap-complete
runcmd:
  - [ /usr/local/sbin/parental-os-qemu-bootstrap ]
```

- [ ] **Step 4: Implement seed generation script**

Create `scripts/make-cloud-init-seed.sh`:

```bash
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

mkdir -p "$OUT/qemu"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "parental-os-qemu" >/dev/null
fi
chmod 0600 "$KEY"

PUB="$(<"$KEY.pub")"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
sed "s|SSH_PUBKEY_PLACEHOLDER|${PUB}|g" "$ROOT/tests/qemu/user-data" >"$SEED_DIR/user-data"
cp "$ROOT/tests/qemu/meta-data" "$SEED_DIR/meta-data"

tool="$(choose_seed_tool)"
case "$tool" in
  xorriso)
    xorriso -as mkisofs -output "$SEED_ISO" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
  genisoimage)
    genisoimage -output "$SEED_ISO" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
  mkisofs)
    mkisofs -output "$SEED_ISO" -volid CIDATA -joliet -rock \
      "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
    ;;
esac

log "seed iso: $SEED_ISO"
```

- [ ] **Step 5: Mark script executable and rerun tests**

Run:

```bash
chmod +x scripts/make-cloud-init-seed.sh
bats tests/host/test_qemu_harness.bats
```

Expected: PASS for all QEMU harness host tests.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add scripts/make-cloud-init-seed.sh tests/qemu/user-data tests/qemu/meta-data tests/host/test_qemu_harness.bats
git commit -m "feat: add QEMU cloud-init seed generation"
```

---

### Task 3: Guest Assertion Script

**Files:**
- Create: `tests/qemu/assert_guest.sh`
- Modify: `tests/host/test_qemu_harness.bats`

- [ ] **Step 1: Add host test for assertion script syntax**

Append this test to `tests/host/test_qemu_harness.bats`:

```bash
@test "assert_guest has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/tests/qemu/assert_guest.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test and verify it fails because the script is missing**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: FAIL in the assertion syntax test because `tests/qemu/assert_guest.sh` does not exist.

- [ ] **Step 3: Create the guest assertion script**

Create `tests/qemu/assert_guest.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HOST="${1:?host}"
PORT="${2:?port}"
KEY="${3:?key}"

SSH=(
  ssh
  -i "$KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -p "$PORT"
  "qa@${HOST}"
)

remote() {
  "${SSH[@]}" "$1"
}

remote 'test -f /run/parental-os-qemu/bootstrap-complete'
remote 'id -nG child | tr " " "\n" | grep -qx parental-users'
remote 'id -nG qa | tr " " "\n" | grep -qx parental-users'
remote 'parental-guard status'
remote 'systemctl is-active --quiet parental-guard.service'
remote 'systemctl is-active --quiet parental-guard-agent.service'
remote 'curl -fsS http://127.0.0.1:7420/health'
remote 'sudo -n true'

if remote 'sudo -n visudo -c' >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: sudo visudo should be denied for parental-users' >&2
  exit 1
fi

if remote 'sudo -n systemctl stop parental-guard-agent.service' >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: stopping parental-guard-agent.service should be denied for parental-users' >&2
  exit 1
fi

printf '%s\n' 'assert_guest: OK'
```

- [ ] **Step 4: Mark script executable and run host tests**

Run:

```bash
chmod +x tests/qemu/assert_guest.sh
bats tests/host/test_qemu_harness.bats
```

Expected: PASS for all QEMU harness host tests.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add tests/qemu/assert_guest.sh tests/host/test_qemu_harness.bats
git commit -m "feat: add QEMU guest assertions"
```

---

### Task 4: Headless Native QEMU Smoke Runner

**Files:**
- Create: `scripts/test-qemu.sh`
- Modify: `tests/host/test_qemu_harness.bats`

- [ ] **Step 1: Add host syntax test for the runner**

Append this test to `tests/host/test_qemu_harness.bats`:

```bash
@test "test-qemu has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/scripts/test-qemu.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests and verify the syntax test fails because the runner is missing**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: FAIL in the `test-qemu` syntax test.

- [ ] **Step 3: Implement the headless runner**

Create `scripts/test-qemu.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/qemu.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd ssh

OUT="$(out_root)"
TARGET="${1:-all}"
RAM="${PARENTAL_OS_QEMU_RAM:-2048}"
CPUS="${PARENTAL_OS_QEMU_CPUS:-2}"
SSH_BASE_PORT="${PARENTAL_OS_QEMU_SSH_PORT_BASE:-2220}"
ATTEMPTS="${PARENTAL_OS_QEMU_ATTEMPTS:-120}"
SLEEP_SECONDS="${PARENTAL_OS_QEMU_SLEEP_SECONDS:-5}"
PIDS=()

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT INT TERM

qemu_accel_args() {
  if [[ -r /dev/kvm ]]; then
    printf '%s\n' -enable-kvm -cpu host
  else
    log "warning: /dev/kvm is not readable; using software emulation"
  fi
}

run_one() {
  local target="$1"
  local index="$2"
  local iso disk logf pidfile ssh_port
  iso="$(qemu_iso_for_target "$target")" || die "cannot resolve ISO for $target"
  disk="$OUT/qemu/${target}.qcow2"
  logf="$OUT/logs/qemu-${target}.log"
  pidfile="$OUT/qemu/${target}.pid"
  ssh_port="$((SSH_BASE_PORT + index))"

  rm -f "$disk" "$pidfile" "$logf"
  qemu-img create -f qcow2 "$disk" 20G >/dev/null

  local accel=()
  while IFS= read -r arg; do
    accel+=("$arg")
  done < <(qemu_accel_args)

  log "QEMU boot: target=$target iso=$iso ssh_port=$ssh_port log=$logf"
  qemu-system-x86_64 "${accel[@]}" \
    -m "$RAM" \
    -smp "$CPUS" \
    -boot d \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -cdrom "$iso" \
    -drive "file=$OUT/qemu/seed.iso,media=cdrom,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$logf" \
    -daemonize \
    -pidfile "$pidfile"

  local pid
  [[ -f "$pidfile" ]] || die "QEMU did not create pidfile for $target; inspect $logf"
  pid="$(<"$pidfile")"
  PIDS+=("$pid")

  local ok=0
  local attempt
  for attempt in $(seq 1 "$ATTEMPTS"); do
    if "$ROOT/tests/qemu/assert_guest.sh" 127.0.0.1 "$ssh_port" "$OUT/qemu/id_ed25519"; then
      ok=1
      break
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      log "QEMU exited before assertions passed for $target"
      break
    fi
    log "waiting for $target guest assertions ($attempt/$ATTEMPTS)"
    sleep "$SLEEP_SECONDS"
  done

  kill "$pid" >/dev/null 2>&1 || true
  rm -f "$pidfile"

  if [[ "$ok" -ne 1 ]]; then
    die "QEMU assertions failed for $target; inspect $logf"
  fi
  log "QEMU OK: $target"
}

main() {
  "$ROOT/scripts/make-cloud-init-seed.sh"
  local index=0
  local target
  while IFS= read -r target; do
    run_one "$target" "$index"
    index="$((index + 1))"
  done < <(qemu_targets_for "$TARGET")
}

main "$@"
```

- [ ] **Step 4: Mark runner executable and run host tests**

Run:

```bash
chmod +x scripts/test-qemu.sh
bats tests/host/test_qemu_harness.bats
```

Expected: PASS for all QEMU harness host tests.

- [ ] **Step 5: Run full host tests**

Run:

```bash
DOCKER_CONTEXT=default just test-host
```

Expected: PASS for all host tests.

- [ ] **Step 6: Run one end-to-end QEMU smoke test against an available ISO**

Use the first available built ISO target on the machine. If Ubuntu exists under `out/ubuntu`, run:

```bash
DOCKER_CONTEXT=default just test-qemu ubuntu
```

Expected: the command eventually prints `assert_guest: OK` and `QEMU OK: ubuntu`.

If the only local artifact is a CachyOS desktop ISO under `out/cachyos/desktop`, run:

```bash
DOCKER_CONTEXT=default just test-qemu cachyos-desktop
```

Expected: the command eventually prints `assert_guest: OK` and `QEMU OK: cachyos-desktop`.

- [ ] **Step 7: Commit Task 4**

Run:

```bash
git add scripts/test-qemu.sh tests/host/test_qemu_harness.bats
git commit -m "feat: add headless QEMU smoke runner"
```

---

### Task 5: Browser-Viewable QEMU Runner

**Files:**
- Create: `distros/qemu-browser/Dockerfile`
- Create: `distros/qemu-browser/entrypoint.sh`
- Create: `compose.qemu.yml`
- Create: `scripts/qemu-browser.sh`
- Modify: `Justfile`
- Modify: `tests/host/test_qemu_harness.bats`

- [ ] **Step 1: Add syntax tests for browser runner files**

Append these tests to `tests/host/test_qemu_harness.bats`:

```bash
@test "qemu-browser script has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/scripts/qemu-browser.sh"
  [ "$status" -eq 0 ]
}

@test "qemu-browser container entrypoint has valid bash syntax" {
  run bash -n "$PARENTAL_OS_ROOT/distros/qemu-browser/entrypoint.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests and verify they fail because browser files are missing**

Run:

```bash
bats tests/host/test_qemu_harness.bats
```

Expected: FAIL in the two browser syntax tests.

- [ ] **Step 3: Create the browser container Dockerfile**

Create `distros/qemu-browser/Dockerfile`:

```dockerfile
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    novnc \
    qemu-system-x86 \
    qemu-utils \
    websockify \
  && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/qemu-browser-entrypoint
RUN chmod 755 /usr/local/bin/qemu-browser-entrypoint

EXPOSE 8006 2222
ENTRYPOINT ["/usr/local/bin/qemu-browser-entrypoint"]
```

- [ ] **Step 4: Create the browser container entrypoint**

Create `distros/qemu-browser/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${PARENTAL_OS_ISO:?PARENTAL_OS_ISO must point to the mounted ISO inside the container}"

RAM="${PARENTAL_OS_QEMU_RAM:-4096}"
CPUS="${PARENTAL_OS_QEMU_CPUS:-2}"
DISK_SIZE="${PARENTAL_OS_QEMU_DISK_SIZE:-20G}"
STATE_DIR="${PARENTAL_OS_QEMU_STATE_DIR:-/state}"
SEED_ISO="${PARENTAL_OS_QEMU_SEED_ISO:-/out/qemu/seed.iso}"
SSH_PORT="${PARENTAL_OS_CONTAINER_SSH_PORT:-2222}"

mkdir -p "$STATE_DIR"
DISK="$STATE_DIR/browser.qcow2"
if [[ ! -f "$DISK" ]]; then
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

ACCEL="tcg"
CPU="max"
if [[ -r /dev/kvm ]]; then
  ACCEL="kvm"
  CPU="host"
fi

websockify --web=/usr/share/novnc 0.0.0.0:8006 127.0.0.1:5900 &
WEBSOCKIFY_PID="$!"

cleanup() {
  kill "$WEBSOCKIFY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

QEMU_ARGS=(
  -machine "q35,accel=$ACCEL"
  -cpu "$CPU"
  -m "$RAM"
  -smp "$CPUS"
  -boot d
  -drive "file=$DISK,if=virtio,format=qcow2"
  -cdrom "$PARENTAL_OS_ISO"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
  -device virtio-net-pci,netdev=net0
  -vga virtio
  -display none
  -vnc 0.0.0.0:0
  -serial mon:stdio
)

if [[ -f "$SEED_ISO" ]]; then
  QEMU_ARGS+=( -drive "file=$SEED_ISO,media=cdrom,readonly=on" )
fi

printf 'Starting QEMU browser VM: iso=%s accel=%s ram=%s cpus=%s\n' \
  "$PARENTAL_OS_ISO" "$ACCEL" "$RAM" "$CPUS" >&2
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
```

- [ ] **Step 5: Create Compose service**

Create `compose.qemu.yml`:

```yaml
services:
  qemu-browser:
    build:
      context: distros/qemu-browser
      dockerfile: Dockerfile
    image: parental-os-qemu-browser:latest
    container_name: parental-os-qemu-browser
    environment:
      PARENTAL_OS_ISO: /iso/boot.iso
      PARENTAL_OS_QEMU_RAM: "${PARENTAL_OS_QEMU_RAM:-4096}"
      PARENTAL_OS_QEMU_CPUS: "${PARENTAL_OS_QEMU_CPUS:-2}"
      PARENTAL_OS_QEMU_DISK_SIZE: "${PARENTAL_OS_QEMU_DISK_SIZE:-20G}"
      PARENTAL_OS_QEMU_STATE_DIR: /state
      PARENTAL_OS_QEMU_SEED_ISO: /out/qemu/seed.iso
      PARENTAL_OS_CONTAINER_SSH_PORT: "2222"
    volumes:
      - "${PARENTAL_OS_ISO_PATH:?PARENTAL_OS_ISO_PATH is required}:/iso/boot.iso:ro"
      - ./out:/out
      - ./out/qemu/browser:/state
    ports:
      - "${PARENTAL_OS_BIND_IP:-127.0.0.1}:${PARENTAL_OS_WEB_PORT:-8011}:8006"
      - "${PARENTAL_OS_BIND_IP:-127.0.0.1}:${PARENTAL_OS_BROWSER_SSH_PORT:-2222}:2222"
    restart: unless-stopped
    stop_grace_period: 30s
```

- [ ] **Step 6: Implement browser runner script**

Create `scripts/qemu-browser.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/qemu.sh"
export PARENTAL_OS_ROOT="$ROOT"
ensure_out_dirs

PROJECT_NAME="parental-os-qemu-browser"
COMPOSE_FILE="$ROOT/compose.qemu.yml"
OVERRIDE_FILE="$(out_root)/qemu/browser/compose.kvm.yml"

compose_base() {
  docker_cli compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

compose_with_optional_kvm() {
  mkdir -p "$(dirname "$OVERRIDE_FILE")"
  local args=(-p "$PROJECT_NAME" -f "$COMPOSE_FILE")
  if [[ -e /dev/kvm ]]; then
    cat >"$OVERRIDE_FILE" <<'YAML'
services:
  qemu-browser:
    devices:
      - /dev/kvm:/dev/kvm
YAML
    args+=(-f "$OVERRIDE_FILE")
  fi
  docker_cli compose "${args[@]}" "$@"
}

down() {
  compose_base down --remove-orphans
}

up() {
  local requested="${1:-ubuntu}"
  local target iso bind_ip web_port ssh_port
  target="$(qemu_require_single_target "$requested")" || exit $?
  iso="$(qemu_iso_for_target "$target")" || die "cannot resolve ISO for $target"
  "$ROOT/scripts/make-cloud-init-seed.sh"

  bind_ip="${PARENTAL_OS_BIND_IP:-127.0.0.1}"
  web_port="${PARENTAL_OS_WEB_PORT:-8011}"
  ssh_port="${PARENTAL_OS_BROWSER_SSH_PORT:-2222}"

  export PARENTAL_OS_ISO_PATH="$iso"
  export PARENTAL_OS_BIND_IP="$bind_ip"
  export PARENTAL_OS_WEB_PORT="$web_port"
  export PARENTAL_OS_BROWSER_SSH_PORT="$ssh_port"
  export PARENTAL_OS_QEMU_RAM="${PARENTAL_OS_QEMU_RAM:-4096}"
  export PARENTAL_OS_QEMU_CPUS="${PARENTAL_OS_QEMU_CPUS:-2}"
  export PARENTAL_OS_QEMU_DISK_SIZE="${PARENTAL_OS_QEMU_DISK_SIZE:-20G}"

  log "Starting browser VM: target=$target iso=$iso"
  compose_with_optional_kvm up -d --build
  log "noVNC URL: http://${bind_ip}:${web_port}/vnc.html"
  log "SSH forward: ssh -i $(out_root)/qemu/id_ed25519 -p ${ssh_port} qa@${bind_ip}"
}

case "${1:-ubuntu}" in
  down) down ;;
  *) up "${1:-ubuntu}" ;;
esac
```

- [ ] **Step 7: Modify Justfile**

Update `Justfile` so the QEMU section contains these targets:

```make
test-qemu target="all":
  "{{root}}/scripts/test-qemu.sh" "{{target}}"

qemu-browser target="ubuntu":
  "{{root}}/scripts/qemu-browser.sh" "{{target}}"

qemu-browser-down:
  "{{root}}/scripts/qemu-browser.sh" down
```

- [ ] **Step 8: Mark scripts executable and run host tests**

Run:

```bash
chmod +x scripts/qemu-browser.sh distros/qemu-browser/entrypoint.sh
DOCKER_CONTEXT=default just test-host
```

Expected: PASS for all host tests.

- [ ] **Step 9: Verify the browser container builds**

Run:

```bash
DOCKER_CONTEXT=default docker build -t parental-os-qemu-browser:latest -f distros/qemu-browser/Dockerfile distros/qemu-browser
```

Expected: Docker build completes successfully and tags `parental-os-qemu-browser:latest`.

- [ ] **Step 10: Verify browser mode starts against an available ISO**

Use the first available local artifact. For Ubuntu:

```bash
DOCKER_CONTEXT=default just qemu-browser ubuntu
```

Expected: command prints `noVNC URL: http://127.0.0.1:8011/vnc.html`.

Then verify the endpoint responds:

```bash
curl -fsS http://127.0.0.1:8011/vnc.html >/dev/null
```

Expected: exit code 0.

Stop the browser VM:

```bash
DOCKER_CONTEXT=default just qemu-browser-down
```

Expected: Compose stops and removes the `parental-os-qemu-browser` container.

- [ ] **Step 11: Commit Task 5**

Run:

```bash
git add distros/qemu-browser/Dockerfile distros/qemu-browser/entrypoint.sh compose.qemu.yml scripts/qemu-browser.sh Justfile tests/host/test_qemu_harness.bats
git commit -m "feat: add browser-viewable QEMU runner"
```

---

### Task 6: Usage Documentation And Final Verification

**Files:**
- Create: `docs/qemu-harness.md`

- [ ] **Step 1: Write usage documentation**

Create `docs/qemu-harness.md`:

```markdown
# QEMU Harness

The QEMU harness validates generated parental-os live ISOs in two modes.

## Headless Smoke Tests

Run automated SSH assertions against a generated ISO:

```bash
DOCKER_CONTEXT=default just test-qemu ubuntu
DOCKER_CONTEXT=default just test-qemu cachyos-desktop
DOCKER_CONTEXT=default just test-qemu cachyos-handheld
DOCKER_CONTEXT=default just test-qemu all
```

Generated test material is stored under `out/qemu` and `out/logs`:

```text
out/qemu/id_ed25519
out/qemu/id_ed25519.pub
out/qemu/seed.iso
out/logs/qemu-<target>.log
```

Useful environment variables:

```bash
PARENTAL_OS_QEMU_RAM=4096
PARENTAL_OS_QEMU_CPUS=4
PARENTAL_OS_QEMU_SSH_PORT_BASE=2220
PARENTAL_OS_QEMU_ATTEMPTS=120
PARENTAL_OS_QEMU_SLEEP_SECONDS=5
```

## Browser VM

Start a browser-viewable VM for one ISO target:

```bash
DOCKER_CONTEXT=default just qemu-browser ubuntu
```

Open the printed URL, usually:

```text
http://127.0.0.1:8011/vnc.html
```

Stop the browser VM:

```bash
DOCKER_CONTEXT=default just qemu-browser-down
```

Useful environment variables:

```bash
PARENTAL_OS_BIND_IP=127.0.0.1
PARENTAL_OS_WEB_PORT=8011
PARENTAL_OS_BROWSER_SSH_PORT=2222
PARENTAL_OS_QEMU_RAM=4096
PARENTAL_OS_QEMU_CPUS=2
PARENTAL_OS_QEMU_DISK_SIZE=20G
```

The browser service binds to `127.0.0.1` by default. Set `PARENTAL_OS_BIND_IP` to an overlay-network address only when remote browser access is intentional.
```

- [ ] **Step 2: Run final host verification**

Run:

```bash
DOCKER_CONTEXT=default just test-host
```

Expected: PASS for all host tests.

- [ ] **Step 3: Run final headless QEMU verification**

Run against at least one ISO that exists locally:

```bash
DOCKER_CONTEXT=default just test-qemu ubuntu
```

Expected: PASS with `assert_guest: OK` and `QEMU OK: ubuntu`.

If Ubuntu artifacts are absent and CachyOS desktop artifacts exist, run:

```bash
DOCKER_CONTEXT=default just test-qemu cachyos-desktop
```

Expected: PASS with `assert_guest: OK` and `QEMU OK: cachyos-desktop`.

- [ ] **Step 4: Run final browser verification**

Run:

```bash
DOCKER_CONTEXT=default just qemu-browser ubuntu
curl -fsS http://127.0.0.1:8011/vnc.html >/dev/null
DOCKER_CONTEXT=default just qemu-browser-down
```

Expected: browser VM starts, `curl` exits 0, and browser VM stops cleanly.

- [ ] **Step 5: Inspect worktree diff**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: only intended files are changed, and `git diff --check` exits 0.

- [ ] **Step 6: Commit Task 6**

Run:

```bash
git add docs/qemu-harness.md
git commit -m "docs: document QEMU harness workflows"
```

---

## Final Review Checklist

- `DOCKER_CONTEXT=default just test-host` passes.
- At least one `DOCKER_CONTEXT=default just test-qemu <target>` run passes against an available ISO.
- `DOCKER_CONTEXT=default just qemu-browser <target>` starts and exposes `/vnc.html` on the configured local port.
- `DOCKER_CONTEXT=default just qemu-browser-down` stops the browser VM.
- Generated key material remains only under `out/qemu`.
- noVNC defaults to `127.0.0.1`.
- No unrelated changes are included.

## Expected Pull Request

Open a PR from `feature/qemu-browser-harness` to `dev` with this summary:

```text
Add QEMU ISO smoke tests and browser-viewable VM runner
```

The PR body should include:

```markdown
## Summary
- add shared QEMU ISO target resolution helpers
- add cloud-init seed generation and SSH guest assertions
- add native QEMU smoke runner for generated ISOs
- add Docker Compose noVNC browser runner for manual VM inspection
- document QEMU harness usage

## Verification
- DOCKER_CONTEXT=default just test-host
- DOCKER_CONTEXT=default just test-qemu <target>
- DOCKER_CONTEXT=default just qemu-browser <target>
- curl -fsS http://127.0.0.1:8011/vnc.html >/dev/null
- DOCKER_CONTEXT=default just qemu-browser-down
```
