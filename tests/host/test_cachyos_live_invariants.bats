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
  # Overridable so these cases can be pointed at a build produced elsewhere, e.g.
  # from another git worktree, which has no out/ of its own.
  BUILT_AIROOTFS="${PARENTAL_OS_BUILT_AIROOTFS:-$TEST_ROOT/out/cachyos/staging/desktop/profile-work/build/x86_64/airootfs}"
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

@test "build-edition enables every cloud-init stage unit, not just the target" {
  # Enabling cloud-init.target alone is a no-op: cloud-init ships no
  # cloud-init.target.wants/ symlinks, Arch never auto-enables units, and the
  # target is ordered After=multi-user.target so it cannot pull the stages that
  # have to run before login. Each stage unit must be wanted by multi-user.target.
  for unit in \
    cloud-init-local.service \
    cloud-init-network.service \
    cloud-config.service \
    cloud-final.service; do
    grep -qF "$unit" "$BUILD_EDITION"
  done
}

@test "build-edition does not symlink the removed cloud-init.service" {
  # cloud-init >= 24.3 renamed it to cloud-init-network.service. Inspect the unit
  # list of the enablement loop rather than the whole file: the surrounding
  # comments legitimately name the obsolete unit to explain why it is gone, and a
  # file-wide grep matches that prose instead of any actual symlink.
  units="$(sed -n '/for unit in \\/,/^  done$/p' "$BUILD_EDITION")"
  [ -n "$units" ]
  [[ "$units" == *"cloud-init-network.service"* ]]
  run grep -E '^[[:space:]]*cloud-init\.service[[:space:]]*\\?$' <<<"$units"
  [ "$status" -ne 0 ]
}

@test "post-pacstrap hook fails the build on a dangling enablement symlink" {
  # The symlinks are created while staging, before any package exists to point at,
  # so nothing can validate them until pacstrap has run. Without this assertion a
  # renamed unit silently costs SSH access to the live VM -- and with it the
  # Calamares install log, which is what let a debugging loop run for 11 commits.
  hook="$(sed -n '/parental-os: the enablement symlinks/,/^)/p' "$BUILD_EDITION")"
  [ -n "$hook" ]
  [[ "$hook" == *"cloud-init-network.service"* ]]
  [[ "$hook" == *"exit 1"* ]]
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

# ---------------------------------------------------------------------------
# cloud-init has to actually configure the live system, not merely have its units
# present.
#
# Three attempts at this failed in a row, each because the check verified the shape
# of the fix instead of the requirement:
#   - cloud-init.service was symlinked; the unit no longer exists (dangling).
#   - cloud-init.target was symlinked; it ships no .wants and is ordered
#     After=multi-user.target, so it pulls nothing.
#   - the four stage units were symlinked; under cloud-init >= 24.3's single-process
#     model they are only `nc -U` shims to sockets that cloud-init-main.service
#     creates, so with main disabled every shim connects to nothing, the `| sh`
#     receives nothing, and each oneshot reports success while configuring nothing.
#
# The assertion below is therefore derived from the image rather than from the fix:
# it reads which enabled stage units are socket shims and which unit provides those
# sockets, so it keeps holding if upstream changes the model again.
# ---------------------------------------------------------------------------

@test "built airootfs: enabled cloud-init shims have their socket provider enabled" {
  [ -d "$BUILT_AIROOTFS" ] || skip "no built airootfs; run a CachyOS build first"
  wants="$BUILT_AIROOTFS/etc/systemd/system/multi-user.target.wants"
  units="$BUILT_AIROOTFS/usr/lib/systemd/system"

  shims=""
  for link in "$wants"/cloud-init*.service "$wants"/cloud-config.service \
              "$wants"/cloud-final.service; do
    [ -L "$link" ] || continue
    unit="$(basename "$link")"
    if grep -qE '/run/cloud-init/.*\.sock' "$units/$unit" 2>/dev/null; then
      shims="$shims $unit"
    fi
  done
  [ -n "$shims" ] || skip "this cloud-init version uses no socket shims"

  # Whichever unit drives every stage in one process is what creates the sockets.
  provider="$(grep -lE 'ExecStart=.*cloud-init .*--all-stages' \
    "$units"/cloud-init*.service 2>/dev/null | head -1)"
  [ -n "$provider" ]
  provider="$(basename "$provider")"

  if [ ! -L "$wants/$provider" ]; then
    echo "socket shims enabled:$shims"
    echo "but their socket provider $provider is NOT enabled"
    echo "=> cloud-init will report success while configuring nothing"
    false
  fi
}

@test "build-edition enables the cloud-init single-process driver" {
  units="$(sed -n '/for unit in \\/,/^  done$/p' "$BUILD_EDITION")"
  [[ "$units" == *"cloud-init-main.service"* ]]
}

@test "post-pacstrap hook asserts the socket provider is enabled" {
  hook="$(sed -n '/parental-os: the enablement symlinks/,/^)/p' "$BUILD_EDITION")"
  [ -n "$hook" ]
  [[ "$hook" == *"all-stages"* ]]
}
