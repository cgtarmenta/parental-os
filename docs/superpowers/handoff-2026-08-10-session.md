# parental-os session handoff — 2026-08-10

## Summary

Task 8 had been stuck in an error1→fix1→error2→fix2 loop for **11 fix commits**: the
CachyOS ISO built fine and the Calamares install completed cleanly, but the
installed target had no `parental-guard`, no sudoers policy and no polkit rules.

Three independent root causes were found and fixed in commit `1075ea9`. All three
were diagnosed by inspecting the **already-built airootfs** rather than by
rebuilding, which is why they surfaced in one session after eleven had missed
them.

## Root causes

### 1. The runtime transformer shipped mode 644 — explains the observed symptom

`apply-parental-overlay.py` landed in the live image non-executable, so
`calamares-online.sh` could not run it.

archiso's `_make_custom_airootfs` copies the profile's `airootfs/` with
`cp -af --no-preserve=ownership,mode`, then restores **only** the modes declared
in the `file_permissions` array of `profiledef.sh`. Anything absent from that
array becomes 644, so the `chmod 755` applied during staging was silently
discarded.

Proof, a perfect control — two files from the same staging directory, both
chmod 755:

| file | staged | built |
|---|---|---|
| `usr/local/lib/parental-os/apply-parental-overlay.py` | 755 | **644** |
| `usr/local/bin/calamares-online.sh` | 755 | 755 |

`calamares-online.sh` is listed in `file_permissions`; ours was not
(`profiledef.sh` contained zero occurrences of "parental").

The resulting failure chain:

```
calamares-online.sh:35  sudo pacman -Sy --noconfirm cachyos-calamares-next
                        └─> restores pristine upstream /etc/calamares/,
                            undoing everything the mkarchiso post-pacstrap hook did

calamares-online.sh:49  sudo .../apply-parental-overlay.py runtime ...
                        └─> Permission denied (mode 644)   <-- FAILS SILENTLY
                            main() has no `set -e`; the status is never checked

calamares-online.sh:51  exec pkexec-wrapper calamares
                        └─> starts with pacstrap.conf lacking parental-guard,
                            no services, no repo copy, no cleanup

Result: the install completes and looks entirely successful.
```

This also resolves the paradox that stalled the previous session: the mkarchiso
post-pacstrap hook (commits `dbd3ecb`, `ed0fb07`, `299f981`) **did work** — the
files were verified present in the squashfs — but the runtime `pacman -Sy` undoes
it, and the only thing that would restore it was the transformer that could not
execute.

**Fix:** register the transformer in `file_permissions`; invoke it through
`python3` so a lost exec bit cannot repeat this; make the call fail-closed so it
aborts loudly instead of starting an install that omits parental-guard.

### 2. Ordering bug in `shellprocess-before-online.conf`

`add_repo_copy_to_before_online()` inserted our command at the head of the
`script:` list via `content.replace("script:\n", ...)`. Upstream's very next
command is `cp /etc/pacman-more.conf ${ROOT}/etc/pacman.conf`, which overwrites
the file wholesale and discards the `file:///srv/parental-os-repo` rewrite our
script had just made. Reproduced in about one second against the built airootfs:
`t1 file:// → t2 http://127.0.0.1:8765`.

The design therefore fell back to the fragile HTTP path it was meant to avoid —
the same oscillation visible in the history between `c1b26c2` ("stage CachyOS
repo before pacstrap", file://) and `389c9ea` ("serve CachyOS local repo during
install", http://).

Note the HTTP fallback was verified *functional* in isolation (python present,
`parental-os.db` symlink served correctly, package served correctly), so this bug
alone does not explain the symptom. Cause 1 does.

**Fix:** carry `Server = file:///srv/parental-os-repo` in the live
`pacman-more.conf` itself. Upstream then propagates the correct URL to the target
for us, so the outcome no longer depends on command ordering or on a running
service. Work *with* upstream's flow rather than racing it.

### 3. cloud-init never ran — the reason the loop persisted

`build-edition.sh` symlinked `cloud-init.service`, which does not exist in
cloud-init **26.1** (renamed to `cloud-init-network.service` in >= 24.3). More
fundamentally, every cloud-init stage unit is `WantedBy=cloud-init.target`, so
symlinking individual services into `multi-user.target.wants` is the wrong
enablement mechanism regardless of naming.

Consequence: no `child`/`qa` user, no SSH into the live VM, therefore
**`/var/log/calamares/session.log` was never read across eleven fix attempts**.
The previous handoff listed four competing hypotheses about why
`copy-parental-os-repo` might fail; that log answers the question directly.

**Fix:** enable `cloud-init.target`.

## The architectural cause of the loop

Eleven failed fixes is not eleven bugs — it is the wrong feedback architecture:

1. **A ~1 hour loop returning one bit.** 3 GB ISO (~40 min) plus a VM install
   (~20 min), yielding a single boolean. With ~8 coupled layers, a failure cannot
   be attributed to a layer.
2. **Zero observability**, per cause 3 above.
3. **Position-blind regex patching of upstream YAML.** `content.replace("script:\n", ...)`,
   `re.search(r"(basePackages:\s*\n...)")`, `content += unit_entry`. None can
   express the actual requirement ("insert *after* upstream's pacman-more.conf
   copy"), so cause 2 was the inevitable failure mode of the technique, not an
   oversight.

`tests/host/test_cachyos_live_invariants.bats` addresses this directly: 12
boundary assertions that isolate each layer and run in about a second.

## Corrections to earlier notes

The previous version of this handoff contained two claims that are wrong; they
are recorded here so nobody re-chases them:

- **"The build from `feature/task8` was never tested in a VM."** The running VM
  *was* booted from that ISO: the ISO was finalized at 09:57:12 and the container
  started at 09:58:33, 81 seconds later.
- **"The root cause of not advancing was working on `dev` instead of the feature
  branch."** It was not. The ISO on disk was correct; all three causes were
  runtime.

Git topology was also verified clean — `dev` is a direct ancestor of
`feature/task8-dual-cachyos`, so the merge is a fast-forward with zero conflicts,
and the other three feature branches have no commits outside `dev`.

## State at handoff

- **Branch:** `feature/task8-dual-cachyos`
- **Fix commit:** `1075ea9` — "fix(#15) make Calamares target integration
  fail-closed and executable"
- Ahead of `origin/feature/task8-dual-cachyos`; **not pushed**.
- **Tests: 196 pass, 0 fail** (`bats tests/host`), up from 193 pass / 3 fail. The
  three built-artifact invariants were the acceptance gate and are now green:
  - `built airootfs: transformer is executable`
  - `built airootfs: no dangling parental-os systemd symlinks`
  - `built airootfs: target pacman.conf template resolves the repo over file://`

  All 12 cases in `test_cachyos_live_invariants.bats` pass with **0 skipped**,
  which matters: a bats `skip` also reports `ok`, so "12 ok" alone would be
  consistent with the built-artifact cases silently skipping on a missing
  airootfs. They genuinely executed against the new image.
- Stale QEMU VM torn down; ports 8011 and 2222 free.
- `desktop` rebuilt successfully. ISO at
  `out/cachyos/desktop/parental-os-cachyos-desktop.iso`, 3,188,850,688 bytes,
  `sha256sum -c` verified, builder exit code 0. Neither fail-closed guard tripped.

### Ground truth in the rebuilt image

| check | before | after |
|---|---|---|
| `usr/local/lib/parental-os/apply-parental-overlay.py` mode | 644 | **755** |
| `[parental-os]` Server in `etc/pacman-more.conf` | `http://127.0.0.1:8765` | **`file:///srv/parental-os-repo`** |
| `cloud-init` enablement | `cloud-init.service` → dangling | **`cloud-init.target` → resolves** |
| reapply invocation | direct exec, status ignored | **`sudo python3 …`, `exit 1` on failure** |

### A note on build cost

The rebuild took **5m 04s**, not the ~40 min assumed throughout the previous
session. That earlier figure came from a cold build; with a warm pacman cache and
warm Docker layers the real cost is an order of magnitude lower. This is worth
internalising, because the belief that each iteration cost an hour was itself part
of what sustained the loop. The genuinely expensive parts were the manual VM
install and the absence of logs — which is the layer that got optimised.

Verify a fast build was not a cache no-op before trusting it: the log should show a
real pacstrap (`installing parental-guard...`, hundreds of MiB downloaded),
initramfs generation, `Creating SquashFS image`, and `Creating ISO image...`.

### Expected log noise (do not chase these)

Four alarming lines appear in a healthy build. All four are byte-identical in the
previous known-good run, which is the cheapest way to classify them — it turns
"does this error matter?" into a diff:

- `error: command failed to execute correctly` — a `cachyos-rate-mirrors`
  scriptlet trying to enable a timer the live profile intentionally masks.
- `error: cachyos: key "882DCF…5A47" is unknown` and `error: keyring is not
  writable` — emitted while mkarchiso generates the installed-package list.
- `==> ERROR: An unknown error has occurred. Exiting...` — from upstream
  `buildiso.sh` cleanup, *after* `ISO image produced`, the checksums, and
  `Time run_build`. The ISO is already complete at that point.

## Two pre-existing problems found on the way

- **Tests 31 and 32 had been failing since commit `299f981`** and nobody noticed.
  The mkarchiso patching lived inside `stage_official_tree`, which the tests
  exercise in an environment with no `/usr/bin/mkarchiso`. Extracting
  `patch_mkarchiso_post_pacstrap()` restores them. Run `just test-host` before
  each commit on this branch.
- **Test 35's regex matched comments**, not invocations
  (`# Patch mkarchiso to ...`). It is now anchored to command position with
  comment lines excluded.

## Environment constraints

- **All containers run on the docker `default` context**, never Docker Desktop.
  The interactive shell's active context may be `desktop-linux`, which is wrong
  for this project and makes running containers invisible to `docker ps`. That
  mismatch already caused real confusion: the stale VM holding ports 8011/2222
  was invisible for exactly this reason. `scripts/lib/common.sh`'s `docker_cli()`
  already defaults correctly via `${DOCKER_CONTEXT:-default}`; it is ad-hoc
  commands that need `--context default`.
- `docker --context default` works without sudo.

## Scope of what is and is not proven

The tests prove the ISO **contains** the right things and that the reapply is
fail-closed. They do **not** prove Calamares actually **uses** them during an
install. That end-to-end check is the remaining work — but it is now diagnosable
rather than guessable, because cloud-init is enabled and the install log is
reachable.

## Next steps

Booting and installing need no manual disk handling. `just qemu-browser
cachyos-desktop` regenerates the cloud-init seed and starts everything;
`distros/qemu-browser/entrypoint.sh` passes `-boot d`, so the VM always boots the
live ISO from CD-ROM and never the installed system, and Calamares reformats the
target during the partition step anyway. The `browser.qcow2` file does persist
between runs (the entrypoint only creates it when absent), but its contents do not
affect either step below.

1. Boot the rebuilt ISO and verify SSH into the live environment works. That is
   the end-to-end proof of cause 3, and the prerequisite for everything else.
2. Run a Calamares install and confirm the target has `parental-guard`, the
   sudoers policy, and the polkit rules. If anything fails, read
   `/var/log/calamares/session.log` rather than hypothesising — that log going
   unread across eleven fix attempts is the single biggest reason this took as
   long as it did.
3. Build `handheld` to confirm. It shares all three code paths with `desktop`, so
   it is a confirmation build, not a diagnostic one.
4. Push and open the PR into `dev`. The merge is a fast-forward.

## Useful files

- Design spec: `docs/superpowers/specs/2026-08-01-parental-os-design.md`
- v1 plan: `docs/superpowers/plans/2026-08-01-parental-os-v1.md`
- QEMU spec: `docs/superpowers/specs/2026-08-05-qemu-browser-harness-design.md`
- QEMU plan: `docs/superpowers/plans/2026-08-05-qemu-browser-harness.md`
- Boundary invariants: `tests/host/test_cachyos_live_invariants.bats`
- Build log: `out/logs/build-cachyos-desktop.log`
