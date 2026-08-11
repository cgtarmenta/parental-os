# parental-os session handoff — 2026-08-11

## Read this first

**Never run mutating system experiments on the host machine.** PAM, sudoers, systemd
units, the clock, LSM state, fs-verity, users, groups: all of it belongs in the QEMU VM
or in a `docker --context default run --rm` container. On the host, reads only.

The reason is decisive on its own: **this machine is not where parental-os gets
installed, so there is nothing about it to investigate.** Any property worth measuring
is a property of the target image. Measuring it here answers the wrong question even
when it does no harm — the image ships its own `pam`, its own greeter and its own
package set.

What went wrong today: several analysis subagents were told to measure "on the live
CachyOS host". One reported running `sudo touch -d 2020-01-01` and `sudo rm -f` against
`/var/lib/systemd/timesync/clock`, and sealing files with fs-verity, on the host.
Verified afterwards that nothing persistent broke, but it should never have been
possible. When writing any prompt that touches system state, say it explicitly:
*read-only on the host; every mutation in the VM or a `--rm` container.* Do not write
"measure on this host" even for something that looks like a read — an agent asked to
measure clock or fs-verity behaviour will reach for a write to do it.

Also: **all containers run on the docker `default` context**, never Docker Desktop, and
never `sudo` for docker. When looking for containers, filter `docker ps` on the **image**
column — names are random Docker words like `wizardly_dirac`, and grepping the name for
"cachyos" finds nothing and will make you wrongly conclude nothing is running.

## Where the work stands

**`dev` is pushed and clean** at `53760cb`. Three PRs merged today:

| PR | What |
|---|---|
| #19 | Task 8: made CachyOS target integration actually apply during install |
| #20 | Enrollment into `parental-users` + the cloud-init single-process driver |
| #21 | Closed — folded into #20, because the enrollment fix could not be validated without cloud-init working |

Suite was **213 pass / 0 fail** on `dev` at the point of the last full run.

**Current branch: `feature/sp-a-target-install-harness`**, 3 commits ahead of `dev`,
**not pushed**:

```
a5e4a7a fix: correct Task 1 Step 2, which would have falsely killed the plan
a1aec82 docs: spike findings for unattended Calamares automation
```

(`53760cb` and `b321670` are the docs already on `dev`.)

## What was achieved today

Task 8 finally works end-to-end. `parental-guard` installs onto the target, its
services are enabled, and — verified on a real install — the enrollment mechanism ran:
`enroll-users: added liveuser to parental-users`. **SSH into the live VM works for the
first time in this project**, which is what makes the Calamares install log readable at
all. Four root causes were found and fixed, all sharing one shape: apparent success
through an ignored return code.

Then the product was re-planned around four new fixed requirements, and the re-plan
found three complete bypasses that exist in the shipping configuration today.

## The two documents that matter

**`docs/superpowers/specs/2026-08-11-remote-parental-control-design.md`** — the re-plan.
Status: under review, not approved beyond a verbal go-ahead on the proposed solution.
Read §2 first: three defects, each a total bypass, each cheap to fix.

**`docs/superpowers/plans/2026-08-11-sp-a-target-install-harness.md`** — the SP-A
implementation plan, 7 tasks. **Task 1 is complete**; Tasks 2-7 are written and ready.

## The settled threat model — do not re-litigate it

`sudo` lives inside a session. The block lives at the door. A blocked child has no
session, therefore no `sudo`, therefore nothing running with which to attack the block.
A user permitted to run `sudo` is not a superuser.

- **R1: the child keeps `sudo`.** Fixed. Never propose removing it.
- **R2: a parent can block login via PAM** until an hour or a manual release. Fixed.
- **R3:** a Tauri 2 + Vue parent app pairs via a code at install time.
- **R4:** multiple parents, multiple children, multiple devices per child.

There is no admin-user concept: root is the only administrator, and every created
account is restricted. The sudo denylist's job is to stop the child *stopping the
parental controls* from inside a session — that is the pre-emptive-sabotage defence, and
it is where the measured escapes matter.

## Measured facts worth not re-measuring

**Three sudo escapes, each one command to `uid=0`**, reproduced in a container against
the real policy file: `sudo python -c 'os.execl(...)'`; `sudo cp /usr/bin/bash /tmp/x`
then `sudo /tmp/x`; a lexically-later drop-in in `/etc/sudoers.d`. Deleting the policy
falls back to `%wheel` on CachyOS or `/etc/sudoers.d/live` on Ubuntu.

**`NOEXEC` closes the interpreter escape.** Measured with `!env_reset` deliberately left
in place: the exec-family call, the shell helper, `posix_spawn` and a direct `execve`
through ctypes were all blocked; removing only the tag made the same line yield `uid=0`.
An earlier conclusion that interpreters were irreducible was wrong. Limit to state: it
works via an `LD_PRELOAD` of `sudo_noexec.so`, so a static binary or a runtime issuing
raw syscalls should evade it — **untested**.

**PAM is fail-closed against destruction, not substitution.** Hook failing, hook missing,
hook at mode 0644, module `.so` missing, service file deleted or truncated, whole
`/etc/pam.d` gone: all DENY on both distros. But one prepended line —
`account sufficient pam_permit.so` — beats the gate on both, even a `[default=die]` gate.
Integrity of `/etc/pam.d` cannot come from PAM.

**PAM placement traps.** On CachyOS the gate goes in `/etc/pam.d/system-login`, never
`system-auth` alone — a gate in `system-auth` dies to `truncate -s0`. `su` and `su-l`
must be patched individually. **`su -` resolves to service `su-l`, not `su`** — a test
probing only `su` measures nothing, and this produced false PERMITs on the first run.
`runuser` never calls `pam_acct_mgmt` and is unclosable via PAM. On Ubuntu,
`common-account` is the single sufficient site.

**AppArmor is subject-scoped, not object-scoped.** All 154 profiles bind to a writing
executable. So "a profile denies root a write to `/etc/pam.d`" holds only for an
*already-confined* process; the child's shell and any binary they compile are unconfined.
Making it true means confining the whole child session via `pam_apparmor` and writing a
profile a Plasma session survives — a far larger sub-project than directory globs. It is
also **compiled in but switched off** on CachyOS (`/sys/module/apparmor/parameters/enabled`
= `N`), and nothing in the ISO, Calamares `kernelParams` or the target's grub enables it.

**`autoProceed` exists** — the mechanism the whole SP-A plan rests on. Present in
`libcalamares.so` and in `/usr/include/libcalamares/Settings.h:66`, package
`cachyos-calamares-next 3.4.2-11`. `QT_QPA_PLATFORM=offscreen` runs Calamares headless
on the first attempt, and all 7 requirement checks pass under it — including `screen`,
which is what enables the Next button that `autoProceed` hooks. See
`docs/superpowers/notes/2026-08-11-autoproceed-spike.md`. **The cascade itself is still
unexecuted**; Task 5 is its first honest test.

## Next step

Resume subagent-driven execution of the SP-A plan at **Task 2** (the unattended
Calamares config tree, 8 bats cases). Tasks 2-7 have complete steps with literal file
content and exact commands. Task 6 deliberately asserts the *current defective*
behaviour for the three known bypasses, so SP-B's fixes are what flip them — do not
"correct" those assertions.

A VM may still be running with the ISO built at 12:53 (matching `dev` @ 52b2c80). Check
before rebuilding: `docker --context default ps --format '{{.Names}}\t{{.Image}}'`.

## Decisions still open for the owner

Ranked by what they block. The first two block the most.

1. **Session confinement (AppArmor): in scope, or documented gap?** Blocks the whole
   build order for the enforcement work.
2. **Root recovery.** A prerequisite, not a later question: shadow's expiry field is
   day-granular, so every materialiser failure is a lockout only root can lift.
3. **Snapshot boot entries: remove, or document?** Bootable read-write snapshots are
   enabled by default, so reaching a pre-block `/etc/shadow` is a keypress at the boot
   menu, needing no session and no `sudo`.
4. Lease TTL and dead-man threshold. 5. Deadline semantics. 6. Agent reachability.
7. Pairing in v1 vs a build-time key. 8. Ubuntu: real R2 or labelled demo.

## Two lessons from how today went

**Scale was substituted for precision.** Two workflows of 51 and 44 agents, 3.4M and
4.1M subagent tokens, 16 concurrent each. Every good finding of the day — the three sudo
escapes, `NOEXEC`, `autoProceed`, the PAM placement traps — came from small directed
commands, not from the swarms. One agent died on `529 Overloaded`, which is direct
evidence of hitting capacity while the user had four sessions open. Prefer a handful of
targeted agents over a fleet.

**An empty result is not a negative result.** This bit repeatedly: `dpkg-deb` absent made
a package inspection silently return nothing; a `grep -A1` missed a line two rows down; a
`docker ps` filtered on the name column found nothing because the name is a random word;
and `strings` on the wrong binary nearly killed the SP-A plan. Before concluding "not
there", confirm the tool ran and looked in the right place.

## Unresolved: two user-session losses

The user lost their whole user session twice this afternoon, losing all running jobs,
and the timing coincides with the PAM investigation. Investigated and **no mechanism
found**:

- `/etc/pam.d` on the host: 0 altered files vs the package manifests, no orphans.
- All 15 `pamcheck.py` coredumps carry `Control Group: /system.slice/docker-….scope` —
  they ran in containers, and appear in the host's `coredumpctl` only because the kernel
  is shared.
- No OOM in either boot; 74 GiB available.
- No logind session termination and no `user@1000.service` stop; it ran until 21:10.
- No compositor or display-manager crash in a boot spanning 4-11 August.
- One non-container coredump today: `gnb` SIGSEGV at 21:35, from the 5G container, in
  the current boot.
- A parallel root session on `pts/5` from `25.25.12.23` ran `shelly`, `snapper -c root
  list` and repeated btrfs snapshot searches in the same window. Not ours.

The correlation is real and is not dismissed; the causal path was not found. If it
recurs, catch it live with `journalctl -f` and `dmesg -w` in a separate terminal — a
session loss that leaves no journal trace points at the client or the transport rather
than the system, and that is visible live but not forensically.

## Useful paths

- Re-plan spec: `docs/superpowers/specs/2026-08-11-remote-parental-control-design.md`
- SP-A plan: `docs/superpowers/plans/2026-08-11-sp-a-target-install-harness.md`
- Spike note: `docs/superpowers/notes/2026-08-11-autoproceed-spike.md`
- Yesterday's handoff (task 8 root causes): `docs/superpowers/handoff-2026-08-10-session.md`
- Boundary invariants: `tests/host/test_cachyos_live_invariants.bats`
- Enrollment tests: `tests/host/test_group_enrollment.bats`
- noVNC when a VM is up: http://127.0.0.1:8011/vnc.html
- SSH into the live VM: `ssh -p 2222 -i out/qemu/id_ed25519 child@127.0.0.1`
