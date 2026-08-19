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
