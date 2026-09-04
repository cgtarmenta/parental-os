# CachyOS Calamares C++/Qt6 Guardian View Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and compile a native C++/Qt6 Calamares ViewModule plugin (`calamares_viewmodule_guardian.so`) integrated into the Calamares installer wizard (`show:` sequence) in CachyOS, prompting for the Guardian Password and provisioning the domain-separated hash to the target system.

**Architecture:** C++/Qt6 plugin implementing `Calamares::ViewStep`, `QWidget` page with live validation, and `Calamares::Job` persistence. Built against `cachyos-calamares-next` headers and staged into `/usr/lib/calamares/modules/guardian/` with `apply-parental-overlay.py` wiring it into `settings.conf` after the `users` step.

**Tech Stack:** C++17, Qt6 (Core, Gui, Widgets), Calamares Plugin API (ViewStep, Job, GlobalStorage), CMake, Python transformer.

**Spec:** `docs/superpowers/specs/2026-09-03-cachyos-calamares-guardian-view-module-design.md`

## Global Constraints

- Domain separation prefix: `"parental-guard:lan-v1:"`
- Target path: `/etc/parental-os/guardian.hash` with mode `0600`, owner `root:root` (`0:0`)
- Live environment path: `/run/parental-os/guardian.hash` with mode `0600`
- Calamares module type: `viewmodule`, interface: `qtplugin`
- Next button disabled until password is at least 4 characters and confirmation matches

---

### Task 1: C++/Qt6 Guardian View Module Source Code & CMake Project

**Files:**
- Create: `distros/cachyos/calamares/viewmodule/CMakeLists.txt`
- Create: `distros/cachyos/calamares/viewmodule/module.desc`
- Create: `distros/cachyos/calamares/viewmodule/guardian.conf`
- Create: `distros/cachyos/calamares/viewmodule/GuardianPage.h`
- Create: `distros/cachyos/calamares/viewmodule/GuardianPage.cpp`
- Create: `distros/cachyos/calamares/viewmodule/GuardianJob.h`
- Create: `distros/cachyos/calamares/viewmodule/GuardianJob.cpp`
- Create: `distros/cachyos/calamares/viewmodule/GuardianViewStep.h`
- Create: `distros/cachyos/calamares/viewmodule/GuardianViewStep.cpp`
- Test: `tests/host/test_cachyos_build.bats`

**Interfaces:**
- Consumes: Calamares headers (`ViewStep.h`, `Job.h`, `GlobalStorage.h`, `PluginFactory.h`)
- Produces: `libcalamares_viewmodule_guardian.so` Qt6 plugin binary

- [ ] **Step 1: Write the failing test for view module source files**

In `tests/host/test_cachyos_build.bats`:
```bash
@test "cachyos calamares viewmodule source files exist" {
  [ -f "distros/cachyos/calamares/viewmodule/CMakeLists.txt" ]
  [ -f "distros/cachyos/calamares/viewmodule/module.desc" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianPage.h" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianPage.cpp" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianJob.h" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianJob.cpp" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianViewStep.h" ]
  [ -f "distros/cachyos/calamares/viewmodule/GuardianViewStep.cpp" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_cachyos_build.bats -f "viewmodule source files"`
Expected: FAIL

- [ ] **Step 3: Implement C++/Qt6 view module files**

1. `distros/cachyos/calamares/viewmodule/module.desc`:
   Descriptor specifying `type: "viewmodule"`, `interface: "qtplugin"`, and `load: "libcalamares_viewmodule_guardian.so"`.

2. `distros/cachyos/calamares/viewmodule/guardian.conf`:
   Configuration with `required: true`, `minLength: 4`.

3. `distros/cachyos/calamares/viewmodule/GuardianPage.h` & `GuardianPage.cpp`:
   QWidget page with title, explanation, password & confirm fields with password echo mode, status/error label, and `checkValidity()` signal.

4. `distros/cachyos/calamares/viewmodule/GuardianJob.h` & `GuardianJob.cpp`:
   Calamares Job that writes `${rootMountPoint}/etc/parental-os/guardian.hash` with mode `0600` and `chown 0:0`.

5. `distros/cachyos/calamares/viewmodule/GuardianViewStep.h` & `GuardianViewStep.cpp`:
   Calamares ViewStep with `CALAMARES_PLUGIN_FACTORY_DECLARATION`, wiring `isNextEnabled()` to page validity, computing domain-separated SHA-256 hash in `onLeave()`, storing in GlobalStorage and `/run/parental-os/guardian.hash`, and returning `GuardianJob`.

6. `distros/cachyos/calamares/viewmodule/CMakeLists.txt`:
   CMake configuration creating MODULE `calamares_viewmodule_guardian` linked against `Qt6::Widgets`, `Calamares::calamares`, `Calamares::calamaresui`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/host/test_cachyos_build.bats -f "viewmodule source files"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add distros/cachyos/calamares/viewmodule/ tests/host/test_cachyos_build.bats
git commit -m "feat(cachyos): implement C++/Qt6 Calamares view module for guardian password setup"
```

---

### Task 2: Build Pipeline & Staging Integration

**Files:**
- Modify: `distros/cachyos/calamares/apply-parental-overlay.py`
- Modify: `distros/cachyos/container/build-edition.sh`
- Test: `tests/host/test_cachyos_build.bats`

**Interfaces:**
- Consumes: `distros/cachyos/calamares/viewmodule/`
- Produces: Compiled `libcalamares_viewmodule_guardian.so` in live ISO `/usr/lib/calamares/modules/guardian/` and updated `settings.conf` with `guardian` in `show:` sequence

- [ ] **Step 1: Write the failing test for settings wiring**

In `tests/host/test_cachyos_build.bats`:
Add test verifying that `apply-parental-overlay.py` wires `guardian` into `sequence: - show:` directly after `users`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_cachyos_build.bats -f "wires guardian into show sequence"`
Expected: FAIL

- [ ] **Step 3: Update `apply-parental-overlay.py` and `build-edition.sh`**

1. In `distros/cachyos/calamares/apply-parental-overlay.py`:
   - Update `wire_guardian_to_settings`: insert `- guardian` in `sequence: - show:` directly after `- users`.
2. In `distros/cachyos/container/build-edition.sh`:
   - Add compilation of `distros/cachyos/calamares/viewmodule/` using `cmake` inside the container against `cachyos-calamares-next`.
   - Install the resulting `libcalamares_viewmodule_guardian.so`, `module.desc`, and `guardian.conf` to `${staged_dir}/archiso/airootfs/usr/lib/calamares/modules/guardian/`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/host/test_cachyos_build.bats -f "wires guardian into show sequence"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add distros/cachyos/calamares/apply-parental-overlay.py distros/cachyos/container/build-edition.sh tests/host/test_cachyos_build.bats
git commit -m "feat(cachyos): compile and stage C++/Qt6 guardian view module in Calamares installer"
```

---

### Task 3: Full Verification & ISO Build

**Files:**
- Test: All host tests (`just test-host`)
- Build: `just build-cachyos desktop`
- Verify: QEMU live test in noVNC

- [ ] **Step 1: Run all host tests**

Run: `just test-host`
Expected: 330+ tests passing (0 failures).

- [ ] **Step 2: Build fresh CachyOS Desktop ISO**

Run: `just build-cachyos desktop`
Expected: `out/cachyos/desktop/parental-os-cachyos-desktop.iso` generated cleanly.

- [ ] **Step 3: Launch in QEMU and perform interactive test**

Run: `PARENTAL_OS_ATTACH_SEED=1 ./scripts/qemu-browser.sh cachyos-desktop`
Expected:
- Calamares launches.
- Shows "Parental Guard" page after "Users".
- "Next" button disabled until passwords match.
- Installation completes with correct secret.
