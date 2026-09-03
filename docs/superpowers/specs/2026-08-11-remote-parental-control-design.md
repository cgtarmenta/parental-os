# parental-os — Re-plan: enforceable blocking and remote parental control

**Status:** design under review. Not approved, not scheduled.
**Verified against:** `dev` @ 52b2c80, 2026-08-11.
**Method:** measured in containers and on the live CachyOS host where marked, read from
the staged Calamares tree where marked, and flagged explicitly where neither.

---

## 0. The requirements this re-plans around

Four product requirements, all fixed by the owner:

**R1.** The child keeps `sudo` for everyday tasks. Not negotiable. Do not design around
removing it.

**R2.** A parent can block login until a set hour, or until they lift it manually. This
must hold in practice.

**R3.** A Tauri 2 + Vue parent app on the same network pairs with the child machine using
a code the app generates, during installation or first boot.

**R4.** Multiple parents, multiple children, multiple devices per child.

### Why R1 and R2 do not conflict

`sudo` lives *inside* a session. The block lives *at the door*. A blocked child has no
session, therefore no `sudo`, therefore nothing running with which to attack the block.
A user permitted to run `sudo` is not a superuser; PAM refuses them before any process of
theirs exists.

That leaves exactly two residual paths, and naming them is what makes the product claim
honest:

1. **Pre-emptive sabotage** — while unblocked the child has `sudo` and therefore root, and
   can attack the enforcement in anticipation. The answer is not prevention but
   *direction*: every sabotage must make the next login **deny**.
2. **Pre-login access to the disk** — boot media, kernel command line editing, and (see
   §2.3) bootable snapshots. This is the ceiling.

**R2 is a requirement, not a status.** There is no PAM asset, no block state and no
enforcement code anywhere in `overlays/` today.

---

## 1. The honest claim

What a parent may truthfully be told:

> When you block this machine, the block is enforced at the door. Your child's account is
> refused at the login screen, at a text console, over SSH and through `su`, before any
> program of theirs is running. Your child may use `sudo` for everyday tasks, but `sudo`
> only exists inside a session, and while blocked there is no session. If they tamper with
> the controls in advance, the machine is designed to refuse the next login rather than
> allow it — tampering locks them out further, and tells you it happened. What this does
> not stop is someone starting the machine from a USB stick, editing the boot menu, or
> booting an older snapshot. Closing that needs full-disk encryption with Secure Boot,
> which this version does not have.

**The sentence the product must never say:** *"Your child cannot disable this."* Nor
"tamper-proof", "unbypassable", or any paraphrase.

---

## 2. Three findings that reorder the plan

These are not design questions. They are defects in the shipping configuration, each a
complete bypass, each cheap to fix.

### 2.1 The child is a polkit administrator

Read from the staged tree: `users.conf:18` puts `wheel` in `defaultGroups`; `users.conf:38`
sets `sudoersGroup: wheel`; `/usr/share/polkit-1/rules.d/50-default.rules` returns
`["unix-group:wheel"]` as the admin identity unconditionally; `pkaction --verbose
--action-id org.freedesktop.policykit.exec` reports `auth_admin` at all three implicit
levels. So `pkexec <anything>` prompts for the child's **own** password and returns root.

`overlays/etc/polkit-1/rules.d/50-parental-os.rules` is **dead code** for admin purposes.
polkit processes rule files in lexical order by basename and stops at the first function
that returns a value, so `50-parental-os` runs *after* `50-default`, which has already
answered. The fix is a rename to something sorting earlier (`00-parental-os.rules`) plus an
explicit admin-identity override and a `polkit.Result.NO` for
`org.freedesktop.policykit.exec`. *Documented from `polkit(8)`; not yet observed on a
booted guest.*

### 2.2 The installer offers to give root the child's password

`users.conf:40-47` sets `setRootPassword: true`, `doReusePassword: true`, `minLength: 4`.
Calamares therefore offers a one-click option making root's password identical to the
child's account password, with a four-character minimum. Since any workable design exempts
uid 0 to preserve a recovery path, that click is a total bypass needing no sabotage and no
prior session. *Setting read; whether the UI pre-ticks the box is unverified — it changes
the severity, not the fix.*

### 2.3 Bootable read-write snapshots are enabled by default, and they are pre-login

`cachyos-calamares/src/scripts/bootloader-post-setup`, listed in `pacstrap.conf`'s
`postInstallFiles`, installs `cachyos-snapper-support`, enables
`limine-snapper-sync.service`, swaps in `limine-mkinitcpio-hook`, and appends
`HOOKS+=(sd-btrfs-overlayfs)` — the hook whose purpose is making snapshots bootable
read-write. `bootloader/main.py:835` writes `BOOT_ORDER="*, *lts, *fallback, Snapshots"`.

So on a default install, reaching a pre-block `/etc/shadow`, `/etc/pam.d`, `/etc/sudoers.d`
and the pinned key is **a keypress at the boot menu**. No session, no `sudo`, nothing for a
sudo policy or a materialiser to intercept. This is not the physical-boot ceiling; it is a
default-enabled bypass shipped by the installer we drive.

Either the snapshot entries go, or this sits in the README beside the USB stick. Note also
`bootloader/main.py:1076` writes refind a *"Boot to single-user mode"* entry.

---

## 3. Architecture: enforce by materialisation, not by evaluation

The device holds **no authority**. It holds a pinned household public key set and a
short-lived signed lease. **Its default state is DENY.** A PERMIT exists only because a
parent signed one. Governing rule for every new file in the system: *nothing that PERMITs
may be device-authored.* Anything the device writes for itself — sequence floor, time
high-water mark, inventory digest, tamper flag — may only ever **restrict**.

That inversion is what makes inaction safe. Killing the daemon, unplugging the network,
deleting the lease, rebooting, or powering off across a deadline all deny by decay, with no
cooperation from the device.

### 3.1 No parental-os code runs inside a login attempt

A root materialiser writes enforcement state *ahead of time*; the login path reads only
ordinary, pre-existing PAM primitives.

The primary deny bit rides on `account required pam_unix.so` via account expiry
(`chage -E`). That module is on every entry path by construction, so it covers doors nobody
enumerated, with `/etc/pam.d` left pristine. This eliminates a class of failure at once:
there is no hook whose exit status can be forced, so the `/etc/ld.so.preload` hijack —
measured to flip both candidate verifier designs from DENY to PERMIT under real PAM — has
nothing to hijack; there is no hook to ship at mode 0644, this repo's most expensive
recurring failure; and nothing can hang the greeter.

**Constraint discovered late:** shadow's expiry field is whole **days**, so "until 21:00"
becomes a boolean that only a working timer clears. Every materialiser failure is therefore
a lockout only root can lift. That makes root recovery (§6, decision 3) a *prerequisite* of
the materialiser, not a later question. And `/etc/shadow` must join the protected-path set,
while `chage`/`usermod`/`passwd` must stay usable by the materialiser and by nobody else.

### 3.2 PAM measurements that decide the secondary layer

All measured on `archlinux:latest` (pam 1.7.2-2) and `ubuntu:jammy` (libpam0g
1.4.0-11ubuntu2.7) using a ctypes harness calling `pam_start` + `pam_acct_mgmt` directly.

Fail-closed against **destruction**, on both distros:

| sabotage | result |
|---|---|
| `pam_exec` hook exits 1 | DENY, rc=4 |
| hook path does not exist | DENY, rc=4 (not skipped) |
| hook exists but mode 0644 — *exactly what archiso does* | DENY, rc=4 |
| module `.so` missing | DENY, rc=28; leading `-account` does **not** suppress it |
| service file deleted, truncated, or lacking account lines | falls back to `other` → DENY |
| whole `/etc/pam.d` removed | DENY on both, by different mechanisms |

Not fail-closed against **substitution**. Prepending one line — `account sufficient
pam_permit.so` — above the gate yields PERMIT on both distros, on every service, **even
against a `[default=die]` gate**, because the short-circuit fires before the gate module is
invoked. `chage -E -1 child` likewise restores PERMIT in one command. Integrity of
`/etc/pam.d` cannot come from PAM.

Only `required` and `requisite` are gates; `sufficient` and `optional` return PERMIT on a
failing module.

Placement, measured:

- **CachyOS: `/etc/pam.d/system-login`, never `system-auth` alone.** A gate in `system-auth`
  dies to `truncate -s0` (PERMIT), because `system-login` still holds passing account
  modules so the service never falls back to `other`. A gate in `system-login` survives
  truncation of `system-auth`, truncation of `system-login`, and deletion of `system-login`.
- **`su` and `su-l` must be patched individually** — neither consults `system-login` for the
  account stack. `su -` resolves to service **`su-l`**, so a test probing only `su` measures
  nothing. This trap produced false PERMITs on the first measurement run.
- **`/usr/lib/pam.d/systemd-run0`** must be patched *in place*; deleting an `/etc` override
  falls back to the ungated vendor twin.
- **`runuser` never calls `pam_acct_mgmt` at all** on either distro. It is unclosable via
  PAM; restrict the binary or accept it.
- **Ubuntu: `/etc/pam.d/common-account`** is the single sufficient site.
- **`sudo -u child` evaluates the invoker's account stack, not the target's** — so any other
  sudo-capable account resurrects a blocked one.

A block must also **terminate the live session**: `loginctl terminate-user`, stop
`user@<uid>.service`, stop `user-<uid>.slice`, and remove `/var/lib/systemd/linger/<user>`.
`loginctl terminate-session` returns success and kills nothing when the session leader has
already exited.

### 3.3 The AppArmor correction — this is the important one

AppArmor genuinely delivers what sudoers structurally cannot. Measured: a process running
as uid 0 with all capabilities was denied writes to `/etc/sudoers.d` and `/etc/pam.d`, and
**confinement is inherited across `execve`**, so copying a shell to `/tmp` and re-running it
— the trick that defeats the current denylist — stayed denied. Symlink indirection stayed
denied.

**But AppArmor rules are subject-scoped, not object-scoped.** All 154 profiles in
`/etc/apparmor.d` bind to a writing executable: `bin.ping:15` is
`profile ping /{usr/,}bin/{,iputils-}ping {…}`. There is no object-scoped rule form. So
"a profile denies writes to `/etc/pam.d` even for root" holds **only for a process already
confined**. The child's shell, `sudo cp`, and any binary they compile are unconfined and
write freely.

Making the premise true means confining the **whole child session** — `pam_apparmor.so`
ships (`/usr/lib/security/pam_apparmor.so`, `apparmor 4.1.7-1.1`), or `AppArmorProfile=` on
`user@.service` — and writing an allow-list profile that a full Plasma session survives with
no `ux` transition anywhere. That is a substantially larger sub-project than "a profile of
directory globs", and it must be settled before any build order is committed.

Also measured or read:

- On this CachyOS host AppArmor is **compiled in and switched off**:
  `/sys/module/apparmor/parameters/enabled` is `N`;
  `/sys/kernel/security/lsm` is `capability,landlock,lockdown,yama,bpf`.
- An **unconfined** root process removes any profile with
  `echo name > /sys/kernel/security/apparmor/.remove`. A shell redirect is not a command, so
  no sudo policy can deny it. The "mutual reinforcement" between sudoers and AppArmor is
  therefore weaker than it first appears: it converts a two-second text edit into a reboot
  with an edited kernel command line. Real gain — slow, visible, loggable — but not a
  boundary.
- Any parental-os profile must carry `deny capability mac_admin`, `deny capability
  mac_override`, `deny mount`, `deny umount`, `deny /etc/apparmor.d/** w`,
  `deny /sys/kernel/security/** w`, and use **`audit deny`** rather than bare `deny` —
  plain deny is silent and produced zero audit records.
- Profiles must be written as **directory globs with create denied**; an enumerated file list
  is bypassed by creating a new vendor-shadow file.
- **Two independent kernel-command-line keys, and the default bootloader is limine, not
  GRUB.** `bootloader.conf: kernelParams` (`bootloader/main.py:144`) feeds systemd-boot,
  limine (`:833`) and refind (`:1074`); GRUB's line comes from `grubcfg`'s own
  `kernel_params` (`grubcfg/main.py:216`, emitted at `:285`). Shipping default is
  `efiBootLoader: "limine"`, user-selectable via `packagechooser_bootloader`. Miss either key
  and a GRUB/BIOS install silently boots with AppArmor off. The live ISO is the same problem
  across seven files per edition, none of which the build touches today.
- **`apparmor` reaches the installed target through no path the project controls.** Zero
  occurrences in the staged Calamares tree; absent from `pacstrap.conf: basePackages`. Adding
  it to `required_packages` affects only the live ISO. The cheap guaranteed lever:
  `depends=('apparmor')` in `packages/parental-guard/arch/PKGBUILD`, since `parental-guard`
  is `basePackages[0]`.
- **Ubuntu needs no kernel parameter** — jammy's `CONFIG_LSM` already includes AppArmor.

### 3.4 sudo scope

The denylist over a blanket grant is structurally unfixable. Measured escapes, each one
command to `uid=0`: `sudo python -c 'os.execl(...)'`; `sudo cp /usr/bin/bash /tmp/x` then
`sudo /tmp/x`; a lexically-later drop-in in `/etc/sudoers.d`. Deleting the policy falls back
to `%wheel` on CachyOS or to `/etc/sudoers.d/live` on Ubuntu. Line 4,
`Defaults:%parental-users !env_reset`, leaks `LD_PRELOAD`, `PYTHONPATH` and `BASH_ENV` into
root and must go.

**`NOEXEC` works and closes the interpreter escape.** Measured with `!env_reset` deliberately
left in place: with `NOEXEC:` on the python entry, the exec-family call raised
`PermissionError` errno 13, the shell helper was blocked, `posix_spawn` raised errno -1, and a
direct `execve` through ctypes returned without exec'ing. Removing only the tag made the same
line yield `uid=0`. An earlier conclusion that interpreters were irreducible was **wrong**.

State the limit: NOEXEC works by `LD_PRELOAD`ing `sudo_noexec.so`, so a statically linked
binary or a runtime issuing raw syscalls should walk through it. *Reasoned, not measured —
test with a static Go or Rust binary before relying on it.*

Group membership is the wrong primitive for the governed set. `gpasswd -d child
parental-users` flips a group-derived gate to PERMIT; `gr_mem` omits users whose *primary*
gid is the group, so `useradd -g parental-users kid2` is invisible. Worse, group-derived
**denials fail open**: `50-parental-os.rules` gates every `polkit.Result.NO` on
`isInGroup("parental-users")`, so leaving the group strips the denials while `wheel` keeps
the admin identity. The governed set must come from a signed subject list, or denials must
invert to "deny unless present in the materialised permit list".

### 3.5 Deadline integrity

- **fs-verity has real teeth**: a uid-0 write to a sealed file was refused with `EPERM` on
  this host while DAC permitted it. But it freezes **content only** — `chmod`, mtime rewind,
  rename and delete were all allowed. So the watermark's value must live in file **content**,
  never in mtime. systemd makes exactly that mistake:
  `/var/lib/systemd/timesync/clock` is 0 bytes and carries its value in mtime, and under the
  shipped sudoers both `sudo touch -d 2020-01-01` and `sudo rm -f` on it returned rc=0.
- fs-verity cannot be updated in place, so the watermark must be an append-only sequence of
  sealed generation files, or a sealed file plus a TPM NV counter.
- Represent the deadline as a **remaining-duration budget** drained with `CLOCK_BOOTTIME`,
  not an absolute instant.
- Create `/usr/lib/clock-epoch` at image build time on both distros — absent and
  package-unowned on both. PID 1 raises the clock to its mtime before any unit runs, which
  kills "boot with the clock at 1970".
- jammy has **no NTP client and no `/var/lib/systemd/timesync`** at all; add
  `systemd-timesyncd` to the Ubuntu package list.
- Stop denying the clock by command name: `hwclock`, python's `clock_settime`, and a copied
  `date` all pass the current denylist. The durable control is removing root's `CAP_SYS_TIME`.
- `PARENTAL_OS_STATE_DIR=/var/lib/parental-os` (`config.env:6`) is inside `@` and therefore
  snapshot-reversible. The monotonic floor cannot live there.

### 3.6 End-to-end: "block until 21:00" from another room

The parent picks the block at 19:40. The app composes a directive — subject
`child@device-id`, state blocked, until 21:00 local, a per-parent-device sequence number,
issued-at — and signs it with that device's Ed25519 key. A courier moves ~400 signed bytes by
whatever path exists; transport is not authority, so any courier will do.

The device's client drops the envelope in a pending directory. The materialiser, running as
root, triggered by a path unit plus a timer, verifies the signature against the pinned key set
**in-process with a pure-stdlib Ed25519 implementation** — no subprocess in the decision path,
because overwriting `/usr/bin/openssl` with `exit 0` is measured to turn a garbage signature
into PERMIT — checks the sequence against the stored floor, folds outstanding directives, and
computes DENY-until-21:00.

It then *materialises*: sets account expiry, removes the child from the permit list, bumps the
sequence floor, writes `/run/parental-os/boot-verdict` stamped with the current `boot_id`, and
ends the live session after the parent's configured warning interval. At 21:00 a timer fires
and materialises PERMIT. Early release is the same path with a higher sequence number: the
release *is* the parent signature.

**The worst open hole:** full-chain substitution. Root generates its own keypair, overwrites
the pinned public key, and re-signs everything self-consistently. Measured to yield a session.
Only kernel-enforced unwritability of the pinned key closes it; a boot-seal inventory plus
parent-side divergence detection turns it from silent into loud.

---

## 4. What cannot currently be tested, and why it is a sub-project

Nothing in the repo can install a target. `scripts/lib/qemu.sh:169-190` boots `-cdrom <iso>`
against a blank qcow2 plus a cloud-init seed; `tests/qemu/assert_guest.sh` asserts against
cloud-init's `qa`/`child` on the **live** image. Calamares has no unattended mode.

So `users.conf` outcomes, the installed target's kernel command line, `plasmalogin`'s PAM
stack, snapper rollback, reboot persistence and the boot-verdict token are all **unmeasurable
today** — including the AppArmor activation this design rests on. "Install unattended, then
boot the installed target" is a sub-project in its own right and must appear in the build
order.

Related delivery gap: the transformer edits three files
(`apply-parental-overlay.py:456-459`) and re-copies four at runtime (`:322-334`), and the
mkarchiso post-pacstrap hook copies the same four. `users.conf`, `bootloader.conf` and
`grubcfg.conf` appear in **none** of those lists, and `calamares-online.sh` reinstalls
`cachyos-calamares-next`, restoring upstream configs. Every Calamares override in this plan
therefore needs a new transform function, a new runtime-copy entry, a new post-pacstrap copy
and a fail-closed marker check — or it is silently reverted, which is precisely the task-8
failure that cost eleven commits.

---

## 5. Sub-projects and build order

**SP-A — Target-install test harness.** Unattended Calamares install in QEMU, then boot the
installed target and assert against it. Without this, nothing below is verifiable.
*Depends on: nothing. Goes first.*

**SP-B — Close the root-to-root doors.** The polkit rename plus admin-identity override plus
`pkexec` denial; `wheel` out of `defaultGroups` and `sudoersGroup` moved; the
`setRootPassword`/`doReusePassword`/`minLength` overrides; snapshot boot entries removed; the
sudoers denylist inverted to an allowlist with `NOEXEC` and `!env_reset` deleted. Each item
needs the delivery plumbing from §4. *Depends on: SP-A to prove it.*

**SP-C — Trust root and record format.** Key pinning, the signed envelope, pure-stdlib
in-process Ed25519 verify, the hash-chain offline release, and the identity model:
subjects are **user-at-device** from a signed subject list, never `/etc/group`; every parent
device carries its own counter. *Depends on: nothing; parallel with SP-A/SP-B.*

**SP-D — Session confinement (AppArmor).** Package delivery via PKGBUILD `depends`, the kernel
command line in **both** Calamares keys and the live-ISO boot configs, `pam_apparmor` or
`AppArmorProfile=` confining the whole child session, an allow-list profile a Plasma session
survives, and a booted-target assertion that the LSM is active and the profile enforcing.
*Depends on: SP-A. Scope is uncertain — see §7.*

**SP-E — Materialiser and boot seal.** `parental-materialise.service` ordered before
`systemd-user-sessions.service` and the greeter's **real** unit id (`display-manager.service`
is an alias that may not exist), writing the expiry bit, permit list, sequence floor and
boot-verdict token, plus a signed inventory over the protected set. *Depends on: SP-C, and on
the root-recovery decision.*

**SP-F — PAM secondary layer.** Gate lines at the measured sites, `systemd-run0` patched in
place, `profiledef.sh` `file_permissions` for every parental-os executable with a bats test
over the built ISO, plus the Plasma unlock stack, `vlock` and `system-remote-login`.
*Depends on: SP-E.*

**SP-G — Session termination and deadline integrity.** *Depends on: SP-E.*

**SP-H — Transport, pairing and the parent app.** *Depends on: SP-C. Ships last: it is
decoration without enforcement.*

**Smallest honest shippable slice: SP-A + SP-B + SP-C + SP-E**, with a build-time pinned key
and a CLI-driven block. A machine where a parent holding the private key can block and
release, where tampering locks the child out rather than freeing them, and where `pkexec` and
`sudo` no longer hand out root. Truthfully describable and fully testable. Everything about
"from another room" is SP-H.

---

## 6. Decisions only the owner can make

1. **Session confinement: in scope or documented gap?** Blocks the whole build order. Without
   it, R2 is fail-closed against blunt destruction only, and full-chain key substitution
   yields a session. But §3.3 shows it means profiling a Plasma session, not writing globs.
2. **Root recovery.** Now a *prerequisite* of SP-E, not a later question, because shadow
   expiry is day-granular and every materialiser failure is a lockout. Options: an
   install-time root password the parent sets independently with a real minimum
   (recommended); or root locked, making every fail-closed state install-media recovery.
3. **Snapshot boot entries: remove, or document?** §2.3. Removing them costs a Calamares
   override with delivery plumbing; keeping them puts a keypress bypass in the product.
4. **Lease TTL and dead-man threshold.** One number that is both the longest a block takes to
   bite and the longest the machine works with the app absent. Decide it by answering: if the
   parent's phone is dead for a weekend, should the child's machine keep working?
5. **Deadline semantics.** Wall-clock 21:00, or that much screen time from now? Does a block
   keep burning down while the machine is off? Crediting off-time from the RTC is what lets a
   BIOS clock change end a block early.
6. **Agent reachability.** Loopback plus tunnel, LAN bind with a pinned certificate, or
   outbound polling. Blocks SP-H; outbound polling recommended — no inbound port, works off-LAN,
   NAT-friendly.
7. **Pairing in v1, or a build-time key with a rotation path?**
8. **Ubuntu: real R2 or labelled demo?** It is live-only, so no block survives a reboot.
9. **What the child sees when denied.** Account expiry produces "User account has expired" —
   accurate, confusing.

---

## 7. Honest uncertainty

- **AppArmor activation on the CachyOS kernel is not measured.** Not that
  `apparmor=1 security=apparmor` activates it, not that a confined root process is denied a
  write on *that* kernel, not how it interacts with the active `landlock,lockdown,yama,bpf`
  stack. Measure it on a booted guest **before** committing the build order; if it fails, the
  sequence changes shape.
- **Session-wide confinement is unscoped.** Whether a Plasma session survives an allow-list
  profile is the single largest unknown in this document.
- **The polkit fix is documented, not observed.**
- **`doReusePassword` behaviour is read, not run.**
- **The primary deny bit is measured in a container**, not through `plasmalogin` on a booted
  target, nor against Plasma's unlock stack.
- **`NOEXEC` against non-libc code paths is reasoned, not measured.**
- **The snapshot/ESP claims rest on reading configuration**, not on a real rollback.
- **Nothing about clock manipulation is measured on real hardware.**
- **Everything Ubuntu-side was measured in jammy containers**, never on the built image.
- **Design coverage was uneven.** Seven of forty-four analysis agents failed on output
  validation, so `identity` was judged against a single proposal and `policy-integrity`,
  `pairing`, `transport` and `sudo-scope` against two rather than three. Their
  recommendations are assessments, not the output of a full comparison.
