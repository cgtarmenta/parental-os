#!/usr/bin/env bats
# Invariants of the unattended Calamares config tree.
#
# This tree exists so a target install can run with no human input inside QEMU.
# Calamares has no unattended mode; the mechanism is the per-instance autoProceed
# flag (src/libcalamares/Settings.cpp:100, consumed in CalamaresWindow.cpp:108-121),
# which clicks Next when it becomes enabled and cascades through the show: sequence.

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  U="$TEST_ROOT/distros/cachyos/calamares/unattended"
}

@test "unattended settings.conf exists and disables the install prompt" {
  [ -f "$U/settings.conf" ]
  grep -qE '^prompt-install:[[:space:]]*false' "$U/settings.conf"
}

@test "unattended settings.conf quits at end so QEMU sees termination" {
  grep -qE '^quit-at-end:[[:space:]]*true' "$U/settings.conf"
}

@test "every show step has an autoProceed instance" {
  # Extract the show: sequence, then require an instances entry per module.
  shown="$(awk '/^- show:/{f=1;next} /^- exec:/{f=0} f && /^ *- /{gsub(/[ -]/,"");print}' \
    "$U/settings.conf")"
  [ -n "$shown" ]
  for step in $shown; do
    mod="${step%%@*}"
    grep -q "module:[[:space:]]*$mod" "$U/settings.conf"
  done
  # autoProceed must appear at least as many times as there are show steps.
  n_show="$(printf '%s\n' $shown | wc -l)"
  n_auto="$(grep -c 'autoProceed:[[:space:]]*true' "$U/settings.conf")"
  [ "$n_auto" -ge "$n_show" ]
}

@test "show: sequence is NOT emptied" {
  # Emptying show: is a trap: ViewModule::loadSelf registers a view step
  # unconditionally (ViewModule.cpp:64) regardless of which phase listed it, so an
  # empty show: yields MORE interactive pages, not fewer, and quit-at-end never
  # fires because isAtVeryEnd() is false for an out-of-range index.
  run awk '/^- show:/{f=1;next} /^- exec:/{f=0} f && /^ *- /{c++} END{print c+0}' \
    "$U/settings.conf"
  [ "$output" -gt 0 ]
}

@test "partition.conf erases at top level AND in every bootloaderOverrides entry" {
  # Config::fillGSSecondaryConfiguration re-runs setConfigurationMap with the
  # override map when packagechooser_bootloader changes, and setConfigurationMap
  # re-reads initialPartitioningChoice from whatever map it is handed
  # (partition/Config.cpp:429-431). Setting it only at top level is silently reset.
  [ -f "$U/modules/partition.conf" ]
  n_erase="$(grep -c 'initialPartitioningChoice:[[:space:]]*erase' "$U/modules/partition.conf")"
  n_over="$(grep -c 'initialPartitioningChoice:' "$U/modules/partition.conf")"
  [ "$n_erase" -eq "$n_over" ]
  [ "$n_erase" -ge 2 ]
}

@test "finished.conf powers off, giving the test its success oracle" {
  [ -f "$U/modules/finished.conf" ]
  grep -qE '^restartNowMode:[[:space:]]*always' "$U/modules/finished.conf"
  grep -q 'poweroff' "$U/modules/finished.conf"
}

@test "users.conf presets a login name so the users page can self-advance" {
  [ -f "$U/modules/users.conf" ]
  grep -q 'presets:' "$U/modules/users.conf"
  grep -q 'loginName:' "$U/modules/users.conf"
}

@test "the tree is never wired into a shipping settings file" {
  # It must be reachable only via calamares -c, never from the installed config.
  ! grep -rq 'unattended' "$TEST_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
}


@test "seed builder accepts a profile and defaults to smoke" {
  s="$TEST_ROOT/scripts/make-cloud-init-seed.sh"
  grep -q -- '--profile' "$s"
  grep -q 'user-data-install' "$s"
  grep -qE 'PROFILE="\$\{PROFILE:-smoke\}"|PROFILE=smoke' "$s"
}

@test "install seed launches calamares against the shipped unattended tree" {
  d="$TEST_ROOT/tests/qemu/user-data-install"
  [ -f "$d" ]
  grep -q '/usr/share/parental-os/unattended' "$d"
  grep -q 'calamares' "$d"
  # The Qt platform must be pinned; a GUI-only launch has no display in this path.
  grep -q 'QT_QPA_PLATFORM' "$d"
}


@test "test-install.sh exists, is executable and pins the docker context" {
  s="$TEST_ROOT/scripts/test-install.sh"
  [ -f "$s" ]
  [ -x "$s" ]
  bash -n "$s"
  grep -q 'DOCKER_CONTEXT' "$s"
}

@test "test-install.sh treats a clean poweroff as success and a timeout as failure" {
  s="$TEST_ROOT/scripts/test-install.sh"
  grep -qE "poweroff|exited" "$s"
  grep -qE 'INSTALL_TIMEOUT|timeout' "$s"
}

@test "test-install.sh boots the installed disk after the install" {
  s="$TEST_ROOT/scripts/test-install.sh"
  grep -qE "boot_installed|BOOT_ORDER|installed" "$s"
}

@test "Justfile exposes test-install" {
  grep -qE '^test-install' "$TEST_ROOT/Justfile"
}


# ---------------------------------------------------------------------------
# Task 6: the installed-target verifier exists and records what it must.
# ---------------------------------------------------------------------------

@test "assert_target.sh exists, is executable and valid bash" {
  s="$TEST_ROOT/tests/qemu/assert_target.sh"
  [ -f "$s" ]
  [ -x "$s" ]
  bash -n "$s"
}

@test "assert_target.sh records the three known bypasses as expected-today" {
  s="$TEST_ROOT/tests/qemu/assert_target.sh"
  grep -q 'wheel' "$s"          # users.conf defaultGroups
  grep -q 'pkexec' "$s"         # polkit admin identity
  grep -q -i 'snapshot' "$s"    # bootable snapshot entries
}

@test "assert_target.sh checks the enrollment path on the installed target" {
  s="$TEST_ROOT/tests/qemu/assert_target.sh"
  grep -q 'parental-users' "$s"
  grep -q 'parental-guard' "$s"
}

# ---------------------------------------------------------------------------
# Ubuntu unattended Calamares tree invariants
# ---------------------------------------------------------------------------

@test "ubuntu unattended settings.conf exists and disables the install prompt" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  [ -f "$u/settings.conf" ]
  grep -qE '^prompt-install:[[:space:]]*false' "$u/settings.conf"
}

@test "ubuntu unattended settings.conf quits at end so QEMU sees termination" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  grep -qE '^quit-at-end:[[:space:]]*true' "$u/settings.conf"
}

@test "ubuntu every show step has an autoProceed instance" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  shown="$(awk '/^- show:/{f=1;next} /^- exec:/{f=0} f && /^ *- /{gsub(/[ -]/,"");print}' \
    "$u/settings.conf")"
  [ -n "$shown" ]
  for step in $shown; do
    mod="${step%%@*}"
    grep -q "module:[[:space:]]*$mod" "$u/settings.conf"
  done
  n_show="$(printf '%s\n' $shown | wc -l)"
  n_auto="$(grep -c 'autoProceed:[[:space:]]*true' "$u/settings.conf")"
  [ "$n_auto" -ge "$n_show" ]
}

@test "ubuntu unattended show: sequence is NOT emptied" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  run awk '/^- show:/{f=1;next} /^- exec:/{f=0} f && /^ *- /{c++} END{print c+0}' \
    "$u/settings.conf"
  [ "$output" -gt 0 ]
}

@test "ubuntu partition.conf erases at top level AND in every bootloaderOverrides entry" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  [ -f "$u/modules/partition.conf" ]
  n_erase="$(grep -c 'initialPartitioningChoice:[[:space:]]*erase' "$u/modules/partition.conf")"
  n_over="$(grep -c 'initialPartitioningChoice:' "$u/modules/partition.conf")"
  [ "$n_erase" -eq "$n_over" ]
  [ "$n_erase" -ge 2 ]
}

@test "ubuntu finished.conf powers off, giving the test its success oracle" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  [ -f "$u/modules/finished.conf" ]
  grep -qE '^restartNowMode:[[:space:]]*always' "$u/modules/finished.conf"
  grep -q 'poweroff' "$u/modules/finished.conf"
}

@test "ubuntu users.conf presets a login name so the users page can self-advance" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  [ -f "$u/modules/users.conf" ]
  grep -q 'presets:' "$u/modules/users.conf"
  grep -q 'loginName:' "$u/modules/users.conf"
}

@test "ubuntu unattended tree is never wired into a shipping settings file" {
  ! grep -rq 'unattended' "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py"
}

@test "ubuntu unattended README documents test-only purpose" {
  local u="$TEST_ROOT/distros/ubuntu/calamares/unattended"
  [ -f "$u/README.md" ]
  grep -qi 'test only' "$u/README.md"
  grep -qi 'autoProceed' "$u/README.md"
}

@test "test-install.sh supports ubuntu as single target" {
  s="$TEST_ROOT/scripts/test-install.sh"
  grep -q 'qemu_require_single_target' "$s" || grep -q 'TARGET' "$s"
}

@test "assert_target.sh supports checking deb and arch package status" {
  s="$TEST_ROOT/tests/qemu/assert_target.sh"
  grep -q 'dpkg' "$s"
  grep -q 'pacman' "$s"
}

