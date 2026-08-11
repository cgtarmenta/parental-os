# SP-A: Unattended install + booted-target test harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it possible to install a CachyOS target unattended in QEMU, boot the installed system, and assert against it — so that every security property in the re-plan becomes measurable instead of hypothetical.

**Architecture:** Calamares has no unattended mode, but this fork carries an undocumented per-instance `autoProceed` flag that clicks Next when it becomes enabled and cascades through the whole `show:` sequence. We ship a throwaway Calamares config tree into the live ISO, launch `calamares -c <that tree>` from the cloud-init seed, let `finished`'s `restartNowCommand` power the machine off as the success oracle, then boot the resulting disk and run assertions over SSH.

**Tech stack:** bash, bats, QEMU via the existing `distros/qemu-browser` container, cloud-init NoCloud seed, Calamares YAML module configs.

**Spec:** `docs/superpowers/specs/2026-08-11-remote-parental-control-design.md` §4, §5 (SP-A).

---

## Why this is SP-A and not a later task

Nothing in the repo can install a target today. `scripts/lib/qemu.sh:169-190` boots `-cdrom <iso>` against a blank qcow2 and `tests/qemu/assert_guest.sh` asserts against cloud-init's users on the **live** image. So `users.conf` outcomes, the installed target's kernel command line, its PAM stack, snapshot rollback and reboot persistence are all unmeasurable — including the AppArmor activation the whole design rests on.

Bypassing Calamares and scripting `pacstrap_calamares` directly would give us the kernel command line and PAM stack, but would **not** exercise `users.conf` at all: the group list, `sudoersGroup`, `nopasswd_group` and `home_permissions` are interpreted by C++ jobs inside the users module (`src/modules/users/Config.cpp:1088-1100`, `MiscJobs.cpp`, `CreateUserJob.cpp`, `SetupSudoJob`). Since group enrollment into `parental-users` is exactly what has been broken twice, that is the one code path we must not bypass.

## File structure

| Path | Responsibility |
|---|---|
| `distros/cachyos/calamares/unattended/settings.conf` | Throwaway Calamares settings: same sequence as `settings_online.conf`, plus `autoProceed` per show-step, `prompt-install: false`, `quit-at-end: true` |
| `distros/cachyos/calamares/unattended/modules/partition.conf` | `initialPartitioningChoice: erase` at top level **and** in the active `bootloaderOverrides` entry |
| `distros/cachyos/calamares/unattended/modules/users.conf` | Presets for `fullName`/`loginName`, weak-password allowances |
| `distros/cachyos/calamares/unattended/modules/finished.conf` | `restartNowMode: always`, `restartNowCommand: systemctl -i poweroff` |
| `distros/cachyos/calamares/unattended/README.md` | Why this tree exists and that it must never ship enabled |
| `tests/qemu/user-data-install` | cloud-init seed variant whose `runcmd` launches the unattended install |
| `scripts/make-cloud-init-seed.sh` | Modified: `--profile install\|smoke` selects the user-data template |
| `scripts/test-install.sh` | Host driver: boot ISO → wait for poweroff → boot installed disk → run target assertions |
| `tests/qemu/assert_target.sh` | Assertions that run inside the **installed** system |
| `tests/host/test_unattended_install.bats` | Host-level assertions over the config tree and the driver script |
| `Justfile` | `test-install` recipe |

**Naming discipline:** the tree is `unattended`, the driver is `test-install.sh`, the target assertions are `assert_target.sh`. Do not reuse `assert_guest.sh` — that one asserts against the live image and stays as it is.

---

## Task 1: Spike — confirm the autoProceed cascade and headless Qt

Two things in the research are read-from-source but **not executed**: that the cascade completes end-to-end under real Qt event-loop timing, and that Calamares runs without a display. Everything below depends on both. Establish them before writing config.

**Files:** none. This task produces a written finding, not code.

- [ ] **Step 1: Build a desktop ISO and boot it**

```bash
cd /home/dat30/github/parental-os
DOCKER_CONTEXT=default just build-cachyos desktop
DOCKER_CONTEXT=default just qemu-browser cachyos-desktop
```

Wait for SSH (cloud-init now works, so `child` exists):

```bash
ssh -p 2222 -i out/qemu/id_ed25519 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null child@127.0.0.1 'echo CONNECTED'
```

Expected: `CONNECTED` within ~4 minutes of boot.

- [ ] **Step 2: Confirm `autoProceed` is actually parsed by the shipped binary**

```bash
ssh -p 2222 -i out/qemu/id_ed25519 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null child@127.0.0.1 \
  'strings /usr/bin/calamares | grep -x autoProceed'
```

Expected: `autoProceed`.

If it is absent, the installed `cachyos-calamares-next` package predates the flag. Stop and report: the plan's mechanism does not exist in the shipped binary and Task 1 has failed. Do not proceed to Task 2.

- [ ] **Step 3: Confirm Calamares starts headless**

```bash
ssh -p 2222 -i out/qemu/id_ed25519 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null child@127.0.0.1 \
  'sudo QT_QPA_PLATFORM=offscreen timeout 30 calamares -D6 2>&1 | tail -25'
```

Expected: Calamares logs its startup and module loading rather than a `qt.qpa.plugin` fatal. Record the exact last 25 lines in the finding.

If `offscreen` fails, try in order and record which works: `QT_QPA_PLATFORM=vnc`, then running under the live Plasma session's Wayland socket by exporting `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR=/run/user/1000` from the autologin session. One of these must work before Task 2.

- [ ] **Step 4: Write the finding**

Create `docs/superpowers/notes/2026-08-11-autoproceed-spike.md` containing: whether `autoProceed` is in the binary, which `QT_QPA_PLATFORM` works, and the observed log tail. State plainly whether Task 2 may proceed.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-08-11-autoproceed-spike.md
git commit -m "docs: spike findings for unattended Calamares automation

Records whether the shipped cachyos-calamares binary carries the autoProceed
flag and which Qt platform plugin lets Calamares run without a display. Both
were read from source but never executed, and every later task in the SP-A
plan depends on them."
```

---

## Task 2: The unattended Calamares config tree

**Files:**
- Create: `distros/cachyos/calamares/unattended/settings.conf`
- Create: `distros/cachyos/calamares/unattended/modules/partition.conf`
- Create: `distros/cachyos/calamares/unattended/modules/users.conf`
- Create: `distros/cachyos/calamares/unattended/modules/finished.conf`
- Create: `distros/cachyos/calamares/unattended/README.md`
- Test: `tests/host/test_unattended_install.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/host/test_unattended_install.bats`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats
```

Expected: every case fails — `$U/settings.conf` does not exist.

- [ ] **Step 3: Create the config tree**

First copy the upstream settings as the base, so the sequence stays identical to what really ships:

```bash
cd /home/dat30/github/parental-os
mkdir -p distros/cachyos/calamares/unattended/modules
cp out/cachyos/staging/desktop/cachyos-calamares/settings_online.conf \
   distros/cachyos/calamares/unattended/settings.conf
```

Then edit `distros/cachyos/calamares/unattended/settings.conf`:

- Set `prompt-install: false` (it is `true` upstream). Required: the modal lives in `ViewManager::next()` (`ViewManager.cpp:339-365`) and would stop the cascade.
- Set `quit-at-end: true` (it is `false` upstream), so `ViewManager` calls `quit()` at the very end (`ViewManager.cpp:440-443`).
- Leave the `sequence:` exactly as it is. Do not empty `show:`.
- Add `autoProceed: true` to the instance entry for every module named in `show:`. The upstream `instances:` block already has entries for `welcome@online`, `packagechooser@bootloader` and `packagechooser@desktop`; add `autoProceed: true` to those, and add new entries for the modules that have no instance entry yet. A non-custom entry needs no `id:` — `InstanceKey(module, "")` sets `id = module` and `reconcileInstancesAndSequence` matches rather than duplicating (`Settings.cpp:296-315`), and the config file name still defaults to `<module>.conf` (`Settings.cpp:77`).

The `show:` sequence upstream is `welcome@online, locale, keyboard, packagechooser@bootloader, partition, packagechooser@desktop, netinstall, users, summary`. So the instances block must carry `autoProceed: true` for: `welcome@online`, `locale`, `keyboard`, `packagechooser@bootloader`, `partition`, `packagechooser@desktop`, `netinstall`, `users`, `summary`.

Add, for each module that lacks one:

```yaml
- id:       ""
  module:   locale
  config:   locale.conf
  autoProceed: true
```

…and the same shape for `keyboard`, `partition`, `netinstall`, `users`, `summary`. For the three that already exist, add the single line `autoProceed: true`.

- [ ] **Step 4: Create `modules/partition.conf`**

```bash
cd /home/dat30/github/parental-os
cp out/cachyos/staging/desktop/cachyos-calamares/src/modules/partition/partition.conf \
   distros/cachyos/calamares/unattended/modules/partition.conf
```

Then change **every** occurrence of `initialPartitioningChoice: none` to `initialPartitioningChoice: erase`, and every `initialSwapChoice: none` to `initialSwapChoice: small`. There are three sites: top level (`partition.conf:52,54`) and one inside each `bootloaderOverrides` entry (grub and limine). Verify:

```bash
grep -n 'initialPartitioningChoice\|initialSwapChoice' \
  distros/cachyos/calamares/unattended/modules/partition.conf
```

Expected: no line still says `none`.

Also add `requiredStorage: 8` near the top. `doAutopartition` reads `requiredStorageGiB` (`ChoicePage.cpp:513`), which the welcome module's requirements checker normally writes (`GeneralRequirements.cpp:389`); setting `requiredStorage` here makes the tree independent of that ordering.

- [ ] **Step 5: Create `modules/users.conf`**

```bash
cd /home/dat30/github/parental-os
cp out/cachyos/staging/desktop/cachyos-calamares/src/modules/users/users.conf \
   distros/cachyos/calamares/unattended/modules/users.conf
```

Append the preset block. `ApplyPresets` in this fork applies only `fullName` and `loginName` (`users/Config.cpp:1064-1065`), keyed off `platform.<edition>` where edition is the content of `/etc/edition-tag` — written as `desktop` by `util-iso.sh:113`:

```yaml
presets:
  platform:
    desktop:
      fullName:
        value: "Test Child"
      loginName:
        value: "testchild"
```

Then allow the empty password so the users page reports ready. `m_requireStrongPasswords` is `!allowWeakPasswords || !allowWeakPasswordsDefault` (`users/Config.cpp:1041-1042`), and `isReady()` rejects only `Invalid`, not `Weak`:

```yaml
allowWeakPasswords: true
allowWeakPasswordsDefault: true
```

**Do not** change `setRootPassword`, `doReusePassword` or `minLength` here. Those are the §2.2 defect and belong to SP-B; this tree must reproduce the shipping behaviour so SP-B's fix is measurable against it.

- [ ] **Step 6: Create `modules/finished.conf`**

```yaml
---
restartNowMode: always
restartNowCommand: "systemctl -i poweroff"
notifyOnFinished: false
```

`FinishedViewStep::onActivate` connects `aboutToQuit` to `doRestart()` (`finished/FinishedViewStep.cpp:86-90`), and `always` makes `restartNowWanted()` true (`finished/Config.cpp:215`). A failure downgrades the mode to `Never` (`Config.cpp:100-106`), so **poweroff means the install succeeded and a still-running VM means it did not** — that is the driver's oracle in Task 5.

- [ ] **Step 7: Create the README**

`distros/cachyos/calamares/unattended/README.md`:

```markdown
# Unattended Calamares config — TEST ONLY

This tree drives a complete Calamares install with no human input, so the installed
target can be asserted against in CI. It is consumed only via `calamares -c`, from
the cloud-init seed built by `scripts/make-cloud-init-seed.sh --profile install`.

**It must never be wired into a shipping settings file.** It disables the install
confirmation prompt, erases the disk without asking, and accepts an empty user
password. `tests/host/test_unattended_install.bats` asserts that
`apply-parental-overlay.py` does not reference it.

The mechanism is the per-instance `autoProceed` flag, undocumented in upstream
configs: it clicks Next once a step's Next button becomes enabled
(`src/libcalamares/Settings.cpp:100`, `src/calamares/CalamaresWindow.cpp:108-121`)
and cascades, because `ViewManager::next()` re-emits `nextEnabledChanged` for the
newly current step (`ViewManager.cpp:395`).

Do not try to shorten this by emptying `show:`. `ViewModule::loadSelf()` registers a
view step unconditionally (`ViewModule.cpp:64`) regardless of which phase listed the
module, so an empty `show:` produces more interactive pages rather than fewer, and
`quit-at-end` never fires because `isAtVeryEnd()` is false for an out-of-range index
(`ViewManager.cpp:285-288`).
```

- [ ] **Step 8: Run the test to verify it passes**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats
```

Expected: all cases pass.

- [ ] **Step 9: Run the full suite for regressions**

```bash
cd /home/dat30/github/parental-os && DOCKER_CONTEXT=default bats tests/host
```

Expected: 213 previously passing cases still pass, plus the new ones.

- [ ] **Step 10: Commit**

```bash
git add distros/cachyos/calamares/unattended tests/host/test_unattended_install.bats
git commit -m "test: add unattended Calamares config tree for target install testing

Calamares has no unattended mode, but this fork carries a per-instance autoProceed
flag that clicks Next when it becomes enabled and cascades through the show:
sequence. This tree uses it to drive a full install with no input, so the installed
target becomes assertable.

Two non-obvious constraints are encoded as tests. The show: sequence must NOT be
emptied: ViewModule::loadSelf registers a view step regardless of which phase
listed it, so emptying show: yields more interactive pages, not fewer.
initialPartitioningChoice: erase must be set at top level AND in every
bootloaderOverrides entry, because fillGSSecondaryConfiguration re-runs
setConfigurationMap with the override map and silently resets it otherwise.

finished.conf powers the machine off, which gives the driver in a later task its
success oracle: a clean poweroff means the install completed, a still-running VM
means it did not."
```

---

## Task 3: Ship the tree into the live ISO

The tree must exist inside the live image so `calamares -c` can reach it. It rides in the airootfs, which means it also needs a `file_permissions` entry — archiso restores only declared modes and everything else lands 0644.

**Files:**
- Modify: `distros/cachyos/container/build-edition.sh` (in `stage_official_tree`, after the existing repo staging)
- Modify: `tests/host/test_cachyos_build.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/host/test_cachyos_build.bats`:

```bash
@test "official staging ships the unattended Calamares tree into the airootfs" {
  f="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  grep -q 'unattended' "$f"
  grep -q 'usr/share/parental-os/unattended' "$f"
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_cachyos_build.bats -f 'unattended'
```

Expected: FAIL, `grep -q 'unattended'` returns non-zero.

- [ ] **Step 3: Implement the staging**

In `distros/cachyos/container/build-edition.sh`, inside `stage_official_tree`, immediately after the block that copies the Calamares src to the airootfs (`cp -a "$calamares_dir/src" ...`), add:

```bash
  # Ship the unattended Calamares config tree for automated target-install tests.
  # Consumed only via `calamares -c`; never wired into a shipping settings file.
  local unattended_src="$REPO_DIR/distros/cachyos/calamares/unattended"
  if [[ -d "$unattended_src" ]]; then
    mkdir -p "$staged_dir/archiso/airootfs/usr/share/parental-os/unattended"
    cp -a "$unattended_src/." \
      "$staged_dir/archiso/airootfs/usr/share/parental-os/unattended/"
    log "stage_official_tree: shipped unattended Calamares tree"
  else
    die "unattended Calamares tree not found at $unattended_src"
  fi
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_cachyos_build.bats -f 'unattended'
```

Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
cd /home/dat30/github/parental-os && DOCKER_CONTEXT=default bats tests/host
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add distros/cachyos/container/build-edition.sh tests/host/test_cachyos_build.bats
git commit -m "test: ship the unattended Calamares tree into the live airootfs

Places the tree at /usr/share/parental-os/unattended so a first-boot unit can run
calamares -c against it. Fails the build closed if the tree is missing, rather than
producing an ISO whose install test silently cannot run."
```

---

## Task 4: cloud-init seed profile that launches the install

**Files:**
- Create: `tests/qemu/user-data-install`
- Modify: `scripts/make-cloud-init-seed.sh`
- Modify: `tests/host/test_unattended_install.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/host/test_unattended_install.bats`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'seed'
```

Expected: FAIL.

- [ ] **Step 3: Create `tests/qemu/user-data-install`**

Use the platform value Task 1 established. The template below assumes `offscreen`; if the spike found otherwise, substitute it and say so in the commit message.

```yaml
#cloud-config
package_update: false
ssh_pwauth: false
disable_root: true
write_files:
  - path: /usr/local/sbin/parental-os-run-install
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      # Drive an unattended Calamares install, then let finished.conf power off.
      # A clean poweroff is the success signal; a machine still running when the
      # driver's timeout expires is the failure signal.
      set -uo pipefail
      exec >>/var/log/parental-os-install.log 2>&1
      echo "=== parental-os unattended install starting: $(date -u) ==="
      tree=/usr/share/parental-os/unattended
      if [[ ! -f "$tree/settings.conf" ]]; then
        echo "FATAL: unattended tree missing at $tree"
        exit 1
      fi
      export QT_QPA_PLATFORM=offscreen
      calamares -c "$tree" -D6
      rc=$?
      echo "=== calamares exited rc=$rc: $(date -u) ==="
      exit "$rc"
runcmd:
  - [ systemd-run, --unit=parental-os-install, --description=unattended install,
      /usr/local/sbin/parental-os-run-install ]
```

`systemd-run` detaches it, so cloud-init's `runcmd` does not block for the whole install and `cloud-init status` still reaches `done` — which the driver uses as its "installer has been launched" signal.

- [ ] **Step 4: Add the profile switch to `scripts/make-cloud-init-seed.sh`**

Replace the line that reads the user-data template. It currently is:

```bash
USER_DATA="$(<"$ROOT/tests/qemu/user-data")"
```

with:

```bash
PROFILE="${PARENTAL_OS_SEED_PROFILE:-smoke}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$PROFILE" in
  smoke)   template="$ROOT/tests/qemu/user-data" ;;
  install) template="$ROOT/tests/qemu/user-data-install" ;;
  *) die "unknown seed profile: $PROFILE (use smoke|install)" ;;
esac
[[ -f "$template" ]] || die "seed template not found: $template"
USER_DATA="$(<"$template")"
log "seed profile: $PROFILE"
```

The `install` template has no `SSH_PUBKEY_PLACEHOLDER`, and the existing substitution is a no-op when the placeholder is absent, so no further change is needed there.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'seed'
```

Expected: PASS.

- [ ] **Step 6: Verify both profiles still build a seed**

```bash
cd /home/dat30/github/parental-os
./scripts/make-cloud-init-seed.sh && ls -la out/qemu/seed.iso
./scripts/make-cloud-init-seed.sh --profile install && ls -la out/qemu/seed.iso
./scripts/make-cloud-init-seed.sh --profile nonsense; echo "exit=$?"
```

Expected: the first two print `seed iso:` and leave a file; the third exits non-zero with `unknown seed profile`.

- [ ] **Step 7: Commit**

```bash
git add tests/qemu/user-data-install scripts/make-cloud-init-seed.sh \
        tests/host/test_unattended_install.bats
git commit -m "test: add an install seed profile that launches Calamares unattended

make-cloud-init-seed.sh gains --profile smoke|install, defaulting to smoke so the
existing harness is unchanged. The install profile detaches the installer with
systemd-run so cloud-init still reaches done, which the driver uses as its
installer-launched signal, and logs to /var/log/parental-os-install.log."
```

---

## Task 5: The host driver

**Files:**
- Create: `scripts/test-install.sh`
- Modify: `Justfile`
- Modify: `tests/host/test_unattended_install.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/host/test_unattended_install.bats`:

```bash
@test "test-install.sh exists, is executable and pins the docker context" {
  s="$TEST_ROOT/scripts/test-install.sh"
  [ -f "$s" ]
  [ -x "$s" ]
  bash -n "$s"
  grep -q 'DOCKER_CONTEXT' "$s"
}

@test "test-install.sh treats a clean poweroff as success and a timeout as failure" {
  s="$TEST_ROOT/scripts/test-install.sh"
  grep -q 'poweroff\|exited' "$s"
  grep -qE 'INSTALL_TIMEOUT|timeout' "$s"
}

@test "test-install.sh boots the installed disk after the install" {
  s="$TEST_ROOT/scripts/test-install.sh"
  grep -q 'boot_installed\|BOOT_ORDER\|installed' "$s"
}

@test "Justfile exposes test-install" {
  grep -qE '^test-install' "$TEST_ROOT/Justfile"
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'test-install'
```

Expected: FAIL.

- [ ] **Step 3: Create `scripts/test-install.sh`**

```bash
#!/usr/bin/env bash
# Drive an unattended Calamares install in QEMU, then boot the installed target
# and assert against it.
#
# Success oracle: finished.conf sets restartNowCommand to `systemctl -i poweroff`,
# and Calamares downgrades restartNowMode to Never when a job fails
# (finished/Config.cpp:100-106). So a container that exits on its own means the
# install completed; a container still running when INSTALL_TIMEOUT expires means
# it did not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
export PARENTAL_OS_ROOT="$ROOT"
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"

TARGET="${1:-cachyos-desktop}"
INSTALL_TIMEOUT="${PARENTAL_OS_INSTALL_TIMEOUT:-2700}"
OUT="$(out_root)"
STATE="$OUT/qemu/install/$TARGET"
DISK="$STATE/target.qcow2"
LOG="$OUT/logs/test-install-$TARGET.log"

require_cmd docker
mkdir -p "$STATE" "$OUT/logs"

# A fresh disk every run: the whole point is to observe what the installer writes.
rm -f "$DISK"

log "=== phase 1: unattended install ==="
"$ROOT/scripts/make-cloud-init-seed.sh" --profile install

PARENTAL_OS_QEMU_STATE_DIR="$STATE" \
PARENTAL_OS_BROWSER_TARGET="install-$TARGET" \
  "$ROOT/scripts/qemu-browser.sh" "$TARGET" >>"$LOG" 2>&1

container="$(docker --context "$DOCKER_CONTEXT" ps \
  --format '{{.Names}}\t{{.Image}}' | awk '/qemu-browser/{print $1; exit}')"
[[ -n "$container" ]] || die "install VM container not found"
log "install VM: $container (timeout ${INSTALL_TIMEOUT}s)"

# `docker wait` blocks until the container exits, which happens when the guest
# powers itself off. Racing it against a sleep gives us the timeout.
( docker --context "$DOCKER_CONTEXT" wait "$container" >"$STATE/wait.rc" ) &
waiter=$!
( sleep "$INSTALL_TIMEOUT"; kill -TERM "$waiter" 2>/dev/null ) &
timer=$!
if wait "$waiter" 2>/dev/null; then
  kill -TERM "$timer" 2>/dev/null || true
  log "guest powered off — install reported success"
else
  log "install did not complete within ${INSTALL_TIMEOUT}s"
  docker --context "$DOCKER_CONTEXT" logs --tail 60 "$container" >>"$LOG" 2>&1 || true
  "$ROOT/scripts/qemu-browser.sh" down >>"$LOG" 2>&1 || true
  die "unattended install timed out; see $LOG"
fi

"$ROOT/scripts/qemu-browser.sh" down >>"$LOG" 2>&1 || true
[[ -f "$DISK" ]] || die "installer produced no disk at $DISK"
log "installed disk: $(stat -c %s "$DISK") bytes"

log "=== phase 2: boot the installed target ==="
# Boot from disk, not CD: PARENTAL_OS_ISO_PATH points at /dev/null so the
# entrypoint has no bootable CD and falls through to the virtio disk.
PARENTAL_OS_QEMU_STATE_DIR="$STATE" \
PARENTAL_OS_BROWSER_TARGET="install-$TARGET" \
PARENTAL_OS_ISO_PATH=/dev/null \
  "$ROOT/scripts/qemu-browser.sh" "$TARGET" >>"$LOG" 2>&1

log "installed target booting; noVNC http://127.0.0.1:8011/vnc.html"
log "run assertions with: tests/qemu/assert_target.sh"
```

```bash
chmod +x scripts/test-install.sh
```

- [ ] **Step 4: Add the Justfile recipe**

Append to `Justfile`:

```
test-install target="cachyos-desktop":
  "{{root}}/scripts/test-install.sh" "{{target}}"
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'test-install|Justfile'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-install.sh Justfile tests/host/test_unattended_install.bats
git commit -m "test: add the unattended install driver

Boots the ISO with the install seed profile, waits for the guest to power itself
off — which Calamares only does when every job succeeded — then reboots the same
disk without a CD so the installed target can be asserted against.

A still-running VM at timeout is the failure signal, and the container logs plus
/var/log/parental-os-install.log in the guest are the diagnostics."
```

---

## Task 6: Target assertions

**Files:**
- Create: `tests/qemu/assert_target.sh`
- Modify: `tests/host/test_unattended_install.bats`

These assert the *current* shipping behaviour, including the three known defects. That is deliberate: SP-B's fixes must flip specific assertions, and an assertion that already encodes the fix would go green before the fix exists.

- [ ] **Step 1: Write the failing test**

Append to `tests/host/test_unattended_install.bats`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'assert_target'
```

Expected: FAIL.

- [ ] **Step 3: Create `tests/qemu/assert_target.sh`**

```bash
#!/usr/bin/env bash
# Assertions against the INSTALLED target, run over SSH after scripts/test-install.sh
# phase 2. Distinct from assert_guest.sh, which asserts against the live image.
#
# Cases marked EXPECTED-TODAY record defects the re-plan documents but SP-B has not
# fixed yet. They assert the CURRENT behaviour on purpose, so SP-B's fix is what
# flips them. Do not "fix" them here.
set -uo pipefail

SSH_PORT="${PARENTAL_OS_BROWSER_SSH_PORT:-2222}"
KEY="${PARENTAL_OS_SSH_KEY:-out/qemu/id_ed25519}"
USER_NAME="${PARENTAL_OS_TARGET_USER:-testchild}"
fails=0

r() {
  ssh -p "$SSH_PORT" -i "$KEY" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes \
    "$USER_NAME@127.0.0.1" "$@" 2>/dev/null
}

check() { # name, command
  printf '  %-58s ' "$1"
  if r "$2" >/dev/null; then echo "ok"; else echo "FAIL"; fails=$((fails + 1)); fi
}

expect_today() { # name, command, note
  printf '  %-58s ' "$1"
  if r "$2" >/dev/null; then echo "as-expected-today ($3)"; else
    echo "CHANGED — update this file and the re-plan"; fails=$((fails + 1))
  fi
}

echo "=== installed target: parental-guard present and enrolled ==="
check "parental-guard installed"          "pacman -Qi parental-guard"
check "parental-guard.service enabled"    "systemctl is-enabled parental-guard.service"
check "parental-guard-enroll.service enabled" \
                                          "systemctl is-enabled parental-guard-enroll.service"
check "parental-users group exists"       "getent group parental-users"
check "installed user is enrolled"        "id -nG | tr ' ' '\\n' | grep -qx parental-users"
check "sudoers drop-in present"           "test -f /etc/sudoers.d/parental-os"
check "sudoers is valid"                  "sudo -n visudo -c >/dev/null || visudo -c >/dev/null"

echo "=== temporary build scaffolding must NOT survive ==="
check "no [parental-os] stanza in pacman.conf" \
      "! grep -q '^\\[parental-os\\]' /etc/pacman.conf"
check "no [parental-os] stanza in pacman-more.conf" \
      "! grep -q '^\\[parental-os\\]' /etc/pacman-more.conf"
check "no /srv/parental-os-repo"          "! test -d /srv/parental-os-repo"

echo "=== defects the re-plan documents; SP-B flips these ==="
expect_today "installed user is in wheel" \
      "id -nG | tr ' ' '\\n' | grep -qx wheel" \
      "users.conf:18 defaultGroups"
expect_today "pkexec grants root to the child" \
      "pkexec --version" \
      "50-default.rules admin identity"
expect_today "bootable snapshot entries exist" \
      "test -d /.snapshots -o -f /etc/default/limine" \
      "bootloader-post-setup"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "assert_target: OK"
  exit 0
fi
echo "assert_target: $fails FAILED"
exit 1
```

```bash
chmod +x tests/qemu/assert_target.sh
```

Note on the `pkexec` case: `pkexec --version` succeeding only proves the binary exists. Replacing it with a real authorization probe requires a password on stdin, which the unattended install does not set. SP-B must strengthen this into a genuine `pkexec id` denial check once it sets a target password.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/dat30/github/parental-os && bats tests/host/test_unattended_install.bats -f 'assert_target'
```

Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
cd /home/dat30/github/parental-os && DOCKER_CONTEXT=default bats tests/host
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add tests/qemu/assert_target.sh tests/host/test_unattended_install.bats
git commit -m "test: assert against the installed target, not just the live image

Covers what has never been verifiable: that parental-guard reaches the installed
system, that its units are enabled, that the installed account is actually enrolled
in parental-users, and that the temporary [parental-os] repo does not survive onto
a user's machine.

Three cases deliberately assert the CURRENT defective behaviour — the account
landing in wheel, pkexec being reachable, and bootable snapshot entries existing —
so that SP-B's fixes are what flip them. An assertion that already encoded the fix
would be green before any fix existed, which is the failure mode this project has
hit repeatedly."
```

---

## Task 7: End-to-end run and the honest result

**Files:** none; this produces a finding.

- [ ] **Step 1: Run the whole thing**

```bash
cd /home/dat30/github/parental-os
DOCKER_CONTEXT=default just build-cachyos desktop
DOCKER_CONTEXT=default just test-install cachyos-desktop
```

Expected: phase 1 ends with `guest powered off — install reported success`; phase 2 leaves the installed target booting.

- [ ] **Step 2: Run the target assertions**

```bash
cd /home/dat30/github/parental-os && ./tests/qemu/assert_target.sh
```

Record the full output verbatim.

- [ ] **Step 3: Write the finding**

Create `docs/superpowers/notes/2026-08-11-first-target-install.md` with: whether the unattended install completed, the assertion output, and — most importantly — **whether `parental-guard` is present and the installed user is enrolled on a real installed target.** That is the first end-to-end verification of the work merged in PRs #19 and #20; until now only the ISO contents were verified, never the installed result.

If the install did not complete, record the last 60 lines of the container log and `/var/log/parental-os-install.log` from the guest, and state which step failed. Do not iterate blindly: the harness exists so the failure is diagnosable.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/2026-08-11-first-target-install.md
git commit -m "docs: first end-to-end verification of an installed target

Records the result of the first unattended install plus target assertions. This is
the first time the project has verified the installed system rather than the ISO
contents."
```

---

## Self-review

**Spec coverage.** SP-A in the spec asks for "unattended Calamares install in QEMU, then boot the installed target and assert against it". Tasks 2-4 build the install, Task 5 the boot, Task 6 the assertions, Task 7 the first real run. The spec's §4 note that `users.conf` outcomes must not be bypassed is honoured by driving the real installer rather than scripting `pacstrap`. The spec's §4 delivery-plumbing warning applies to SP-B, not here — this tree is delivered by the airootfs copy in Task 3, not by the Calamares transformer, so it cannot be reverted by the runtime package reinstall.

**Placeholders.** None. Every step has the literal file content or command. Task 1 is a spike, but with exact commands, exact expected output and an explicit stop condition rather than "investigate".

**Type/name consistency.** `distros/cachyos/calamares/unattended` is the tree path throughout; it lands at `/usr/share/parental-os/unattended` in the image (Task 3) and is read from there by the seed (Task 4) — consistent. `--profile install` in Task 4 is what Task 5's driver passes. `assert_target.sh` is created in Task 6 and referenced by Task 5's closing log line and Task 7's run — consistent. `PARENTAL_OS_QEMU_STATE_DIR` is the variable the existing `compose.qemu.yml` already consumes.

**Known weak points, stated rather than hidden.**

1. Task 1 gates everything. If `autoProceed` is absent from the shipped binary, or no Qt platform runs headless, Tasks 2-7 do not apply and the plan needs rewriting around a rebuilt Calamares package. The spike exists precisely to find that out for the cost of one boot.
2. Task 5 phase 2 assumes the qemu-browser entrypoint falls through to the virtio disk when handed `/dev/null` as the ISO. `distros/qemu-browser/entrypoint.sh:51` passes `-boot d`, so this needs confirming during Task 5; if it does not fall through, the entrypoint needs a `PARENTAL_OS_BOOT_ORDER` variable, which is a small addition to that file and its own commit.
3. The installed target's SSH access is unproven. The unattended install creates `testchild` with an empty password and no key, so `assert_target.sh` may not be able to connect. If it cannot, Task 6 needs a preceding step that injects an authorized key — most cleanly by adding a `shellprocess` entry to the unattended tree that drops `out/qemu/id_ed25519.pub` into the new user's `~/.ssh/authorized_keys`. Discover this in Task 5, fix it in its own commit rather than by weakening the assertions.
