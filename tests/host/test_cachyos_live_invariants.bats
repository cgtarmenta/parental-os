#!/usr/bin/env bats
# Boundary invariants for the CachyOS live image -> Calamares -> install target
# chain (Task 8).
#
# Each case isolates ONE boundary that must hold for parental-guard to reach the
# installed target. They exist because the end-to-end signal (build a 3 GB ISO,
# run a Calamares install in a VM, check whether parental-guard is present) takes
# about an hour and collapses ~8 coupled layers into a single boolean, which made
# every regression look like a brand new bug.
#
# Source-level cases always run. Built-artifact cases run against the airootfs
# produced by the last build and skip when it is absent.

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
  BUILD_EDITION="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  TRANSFORMER="$TEST_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  BUILT_AIROOTFS="$TEST_ROOT/out/cachyos/staging/desktop/profile-work/build/x86_64/airootfs"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Build a minimal live airootfs plus a Calamares source tree from the fixtures,
# then run the transformer in stage mode against them.
run_transformer_stage() {
  local cal="$TEST_TMP/calamares" air="$TEST_TMP/airootfs"
  cp -a "$TEST_ROOT/tests/fixtures/cachyos/calamares" "$cal"
  mkdir -p "$air/usr/local/bin"
  cat >"$air/usr/local/bin/calamares-online.sh" <<'EOF'
#!/bin/bash
main() {
    sudo pacman -Sy --noconfirm cachyos-calamares-next
    local mode="online"
    sudo cp "/usr/share/calamares/settings_${mode}.conf" /etc/calamares/settings.conf
    exec pkexec-wrapper calamares -D6
}
main "$@"
EOF
  python3 "$TRANSFORMER" stage "$cal" "$air" "$TRANSFORMER" \
    cachyos-calamares-next >/dev/null
  printf '%s\n' "$air"
}

# ---------------------------------------------------------------------------
# Boundary 1: the live image must be able to EXECUTE the runtime transformer.
#
# archiso copies airootfs/ with --no-preserve=mode and then restores only the
# modes declared in profiledef.sh's file_permissions array, so a chmod applied
# while staging is discarded. Without a file_permissions entry the transformer
# ships mode 644 and the runtime reapply silently fails.
# ---------------------------------------------------------------------------

@test "build-edition registers the transformer in profiledef file_permissions" {
  grep -q 'file_permissions' "$BUILD_EDITION"
  grep -q '/usr/local/lib/parental-os/apply-parental-overlay.py' "$BUILD_EDITION"
}

@test "profiledef file_permissions registration is idempotent and fail-closed" {
  # A staged profiledef.sh without the array must abort the build rather than
  # silently produce an image whose transformer cannot execute.
  grep -qE 'die|fail' <(sed -n '/register_parental_file_permissions/,/^}/p' "$BUILD_EDITION")
}

# ---------------------------------------------------------------------------
# Boundary 2: the reapply invocation must not depend on the exec bit, and must
# be fail-closed.
#
# calamares-online.sh runs `pacman -Sy cachyos-calamares-next`, which restores
# pristine upstream Calamares configs. The reapply that follows is the only
# thing that puts our configs back. If it fails and the failure is ignored,
# Calamares launches with upstream configs and the install completes cleanly
# with no parental-guard.
# ---------------------------------------------------------------------------

@test "reapply is invoked through python3 so a lost exec bit cannot break it" {
  air="$(run_transformer_stage)"
  run grep -c 'python3 /usr/local/lib/parental-os/apply-parental-overlay.py' \
    "$air/usr/local/bin/calamares-online.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "reapply failure aborts instead of launching Calamares with upstream config" {
  air="$(run_transformer_stage)"
  online="$air/usr/local/bin/calamares-online.sh"
  # The reapply must be guarded; a bare command whose status is discarded is the
  # exact silent failure this boundary exists to prevent.
  run grep -qE 'if ! .*apply-parental-overlay\.py|apply-parental-overlay\.py.*\|\|' "$online"
  [ "$status" -eq 0 ]
}

@test "reapply is ordered after the Calamares package reinstall" {
  air="$(run_transformer_stage)"
  online="$air/usr/local/bin/calamares-online.sh"
  reinstall_line="$(grep -n 'pacman -Sy' "$online" | head -1 | cut -d: -f1)"
  reapply_line="$(grep -n 'apply-parental-overlay.py' "$online" | head -1 | cut -d: -f1)"
  [ -n "$reinstall_line" ]
  [ -n "$reapply_line" ]
  [ "$reapply_line" -gt "$reinstall_line" ]
}

# ---------------------------------------------------------------------------
# Boundary 3: the repo URL the target resolves must survive upstream's own
# commands.
#
# shellprocess@before-online runs, in order:
#   1. our repo copy
#   2. cp /etc/pacman-more.conf ${ROOT}/etc/pacman.conf   <- upstream
#   3. detect-architecture ${ROOT}/etc/pacman.conf         <- upstream
# Step 2 overwrites the target pacman.conf wholesale, so the URL must come from
# pacman-more.conf itself rather than from a rewrite applied in step 1.
# ---------------------------------------------------------------------------

@test "pacman-more.conf carries the file:// repo URL, not the http fallback" {
  run grep -n 'pacman-more.conf' "$BUILD_EDITION"
  [ "$status" -eq 0 ]
  # The stanza written into pacman-more.conf is the one that propagates to the
  # target, so it must already be file:// and must not rely on 127.0.0.1:8765.
  block="$(sed -n '/pacman-more\.conf/,+2p' "$BUILD_EDITION")"
  [[ "$block" != *"127.0.0.1:8765"* ]]
}

# ---------------------------------------------------------------------------
# Boundary 4: cloud-init must actually run in the live image, otherwise there is
# no SSH into the VM and no way to read /var/log/calamares/session.log.
#
# cloud-init >= 24.3 renamed cloud-init.service to cloud-init-network.service,
# and every stage unit is WantedBy=cloud-init.target. Symlinking individual
# services into multi-user.target.wants is the wrong enablement mechanism and
# leaves a dangling link.
# ---------------------------------------------------------------------------

@test "build-edition enables cloud-init.target" {
  grep -q 'cloud-init.target' "$BUILD_EDITION"
}

@test "build-edition does not symlink the removed cloud-init.service" {
  run grep -E '^\s*cloud-init\.service\s*\\?$' "$BUILD_EDITION"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Built-artifact invariants: assert against the airootfs the last build made.
# ---------------------------------------------------------------------------

@test "built airootfs: transformer is executable" {
  [ -d "$BUILT_AIROOTFS" ] || skip "no built airootfs; run a CachyOS build first"
  mode="$(stat -c %a "$BUILT_AIROOTFS/usr/local/lib/parental-os/apply-parental-overlay.py")"
  # Owner execute bit must be set.
  [ $(( 0$mode & 0100 )) -ne 0 ]
}

@test "built airootfs: no dangling parental-os systemd symlinks" {
  [ -d "$BUILT_AIROOTFS" ] || skip "no built airootfs; run a CachyOS build first"
  wants="$BUILT_AIROOTFS/etc/systemd/system/multi-user.target.wants"
  dangling=""
  for link in "$wants"/cloud-init* "$wants"/sshd.service \
              "$wants"/qemu-guest-agent.service "$wants"/parental-os-repo.service; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    [ -e "$BUILT_AIROOTFS${target}" ] || dangling="$dangling $(basename "$link")"
  done
  [ -z "$dangling" ] || {
    echo "dangling units:$dangling"
    false
  }
}

@test "built airootfs: pacstrap.conf installs parental-guard on the target" {
  [ -d "$BUILT_AIROOTFS" ] || skip "no built airootfs; run a CachyOS build first"
  grep -qE '^\s+- parental-guard\s*$' \
    "$BUILT_AIROOTFS/etc/calamares/modules/pacstrap.conf"
}

@test "built airootfs: target pacman.conf template resolves the repo over file://" {
  [ -d "$BUILT_AIROOTFS" ] || skip "no built airootfs; run a CachyOS build first"
  server="$(awk '/^\[parental-os\]/{i=1;next} i&&/^\[/{i=0} i&&/^Server/{print;exit}' \
    "$BUILT_AIROOTFS/etc/pacman-more.conf")"
  [[ "$server" == *"file:///srv/parental-os-repo"* ]]
}
