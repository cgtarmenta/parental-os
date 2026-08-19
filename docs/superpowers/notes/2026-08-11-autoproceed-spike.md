# Spike: `autoProceed` and headless Qt in the shipped Calamares

**Date:** 2026-08-11
**Plan:** `docs/superpowers/plans/2026-08-11-sp-a-target-install-harness.md`, Task 1
**Environment:** running `qemu-browser` VM, CachyOS desktop ISO built from `dev` @ `52b2c80`, reached over SSH as `child@127.0.0.1:2222`

## Verdict

**Task 2 may proceed.** Both gating assumptions hold:

1. `autoProceed` is present in the shipped `cachyos-calamares-next` package.
2. `QT_QPA_PLATFORM=offscreen` runs Calamares to a fully initialised window with no display, on the first attempt. No fallback to `vnc` or the live Wayland session was needed.

## Question 1: is `autoProceed` in the shipped package?

Yes — **but not in `/usr/bin/calamares`.** The plan's Step 2 command checks the wrong file and returns a false negative:

```console
$ strings /usr/bin/calamares | grep -x autoProceed
$ echo $?
1
```

That is the expected result, not a failure. The flag is parsed in `src/libcalamares/Settings.cpp`, which compiles into `libcalamares.so`, not the executable. Checking the library:

```console
$ strings /usr/lib/libcalamares.so.3.4.1 | grep -x autoProceed
autoProceed
$ strings /usr/lib/libcalamaresui.so.3.4.1 | grep -x autoProceed
(no exact match)
```

**Anyone re-running Task 1's Step 2 verbatim will wrongly conclude the mechanism is absent and stop.** Grep `/usr/lib/libcalamares.so.3.4.1` instead.

A sweep of every file in the package found the flag in the library, its symlinks, and — decisively — in the installed public header:

```console
$ grep -n -B3 -A2 -i autoproceed /usr/include/libcalamares/Settings.h
63-    bool isCustom() const { return m_instanceKey.isCustom(); }
64-    int weight() const { return m_weight < 0 ? 1 : m_weight; }
65-    bool explicitWeight() const { return m_weight > 0; }
66:    bool autoProceed() const { return m_autoProceed; }
67-
68-private:
--
70-    QString m_configFileName;
71-    int m_weight = 0;
72-    /// @brief Whether to automatically proceed to the next ViewStep page
73:    bool m_autoProceed = false;
74-};
```

This is stronger evidence than the string match. The accessor sits alongside `isCustom()` and `weight()` on the per-instance descriptor, which confirms the research's reading that `autoProceed` is a **per-instance** key belonging on `instances:` entries, not a global setting. The doc comment states its behaviour outright: "Whether to automatically proceed to the next ViewStep page."

The main binary exposes no `autoProceed` dynamic symbol, defined or undefined, which is expected — the getter is defined inline in the header, so the `CalamaresWindow` call site is inlined rather than linked.

### Version

```console
$ pacman -Qo /usr/bin/calamares
/usr/bin/calamares is owned by cachyos-calamares-next 3.4.2-11
```

The package is `3.4.2-11`; the binary self-reports `Calamares version: 3.4.1` and links `libcalamares.so.3.4.1`. Harmless inconsistency in the CachyOS packaging, noted so a future reader is not thrown by it.

## Question 2: does Calamares start headless?

Yes, with `QT_QPA_PLATFORM=offscreen`. No `qt.qpa.plugin` fatal.

```bash
sudo QT_QPA_PLATFORM=offscreen timeout 30 calamares -D6 2>&1 | tail -25
```

`sudo` is required (Calamares wants root) and is permitted: `child` holds `NOPASSWD: ALL` with a denylist that does not cover `calamares`. The sudoers policy also sets `!env_reset`, so `QT_QPA_PLATFORM` reaches the child process.

### Observed log tail (exact last 25 lines)

```
    No partitioning choice has been made yet
20:00:12 [6]: Calamares::RequirementsList GeneralRequirements::checkRequirements()
    GeneralRequirements output:
     storage :   8589934592
     enoughStorage :   true
     RAM :   2684354560
     enoughRam :   true
     hasPower :   true
     hasInternet :   true
     isRoot :   true
20:00:12 [6]: void Calamares::RequirementsChecker::addCheckedRequirements(Calamares::Module*)
    Got 6 requirement results from "welcome"
20:00:12 [6]: void Calamares::RequirementsChecker::finished()
    All requirements have been checked.
20:00:12 [6]: void Calamares::RequirementsModel::describe() const
    Requirements model has 7 items
    .. requirement 0 "partitions" satisfied? true mandatory? true
    .. requirement 1 "storage" satisfied? true mandatory? false
    .. requirement 2 "ram" satisfied? true mandatory? true
    .. requirement 3 "power" satisfied? true mandatory? false
    .. requirement 4 "internet" satisfied? true mandatory? true
    .. requirement 5 "root" satisfied? true mandatory? false
    .. requirement 6 "screen" satisfied? true mandatory? false
20:00:16 [2]: WARNING (Qt): QIODevice::read (QSslSocket): device not open
20:00:17 [2]: WARNING (Qt): QIODevice::read (QSslSocket): device not open
```

Every one of the 7 requirements is satisfied, including the two mandatory ones (`ram`, `internet`) and `screen` under `offscreen`. That matters beyond "it started": the welcome step's Next button is gated on mandatory requirements, so under `offscreen` it does become enabled — which is precisely the edge `autoProceed` waits on. The `QSslSocket` warnings come from the `welcome@online` internet check and are benign.

### Startup markers (second run, captured in full to `/tmp/cal-spike.log`)

```
    Using Calamares settings file at "/usr/share/calamares/settings.conf"
    Calamares version: 3.4.1
    .. Using Qt version: 6.11.1
    .. Build type: Release
    Found 38 modules
    STARTUP: initModuleManager: all modules init done
    STARTUP: initJobQueue done
20:01:06 [6]: CalamaresWindow::CalamaresWindow(QWidget*)
    STARTUP: CalamaresWindow created; loadModules started
    STARTUP: loadModules for all modules done
    STARTUP: Window now visible and ProgressTreeView populated
```

Initialisation completes all the way to "Window now visible and ProgressTreeView populated", and `CalamaresWindow` is constructed — the object that consumes `autoProceed`. So the consumer is reached under `offscreen`, not merely the parser.

Both runs exited 124 (killed by `timeout`), i.e. Calamares stayed alive and idle rather than crashing. A scan of the full log for `Starting job`, `mkfs`, `sgdisk`, `wipefs`, `Committing`, `pacstrap` and `installation` returned nothing: **no install was performed.** The shipped `/usr/share/calamares/settings.conf` contains no `autoProceed`, so the run parked on the welcome page as intended.

## What this spike did *not* establish

The cascade itself was **not executed**. This spike proves the flag is parsed by the shipped library, that it is a per-instance key, and that the window which consumes it initialises headless. It does not prove that `button->click()` chains through all nine `show:` steps under real event-loop timing, because doing so requires a config with `autoProceed` set, and that would perform a genuine install on the VM's disk — out of scope here. Task 5 is the first point where the cascade runs end to end; that is where it gets confirmed or falsified.

## Incidental findings that de-risk Task 2

- `calamares -c` takes a **configuration directory**, not a file: `-c, --config <config>  Configuration directory to use, for testing purposes.` The plan's `calamares -c "$tree"` usage is correct.
- Every global key Task 2 writes is present in `libcalamares.so.3.4.1`: `prompt-install`, `quit-at-end`, `disable-cancel`, `oem-setup`.
- The base to copy is `/usr/share/calamares/settings_online.conf` (also `settings.conf`, byte-identical at 2253 bytes, and `settings_offline.conf`). `/etc/calamares/` holds only `images/`, `modules/` and `scripts/` — **no `settings.conf`** — so the default resolves out of `/usr/share/calamares/`.
- The live session's autologin user is `liveuser`, uid **1000**; `child` is uid 1002. The plan's `XDG_RUNTIME_DIR=/run/user/1000` fallback guess was right about the uid, but is moot since `offscreen` works.
- The shipped `show:` sequence has 9 steps: `welcome@online`, `locale`, `keyboard`, `packagechooser@bootloader`, `partition`, `packagechooser@desktop`, `netinstall`, `users`, `summary`. Each needs its own `autoProceed: true` instance entry.
