# parental-os — Design Spec

**Date:** 2026-08-01  
**Status:** Approved  
**Repo (local):** `/home/dat30/github/parental-os`  
**Repo (remote):** `git@github.com:cgtarmenta/parental-os.git`  
**Owner intent:** Build installable Ubuntu and CachyOS images with desktop-agnostic parental controls, limited passwordless sudo for everyday use, automatic policy inheritance for new users, and a path to LAN remote administration (Android / parent PC). Real local root is retained for guardian recovery and remote policy control.

---

## 1. Purpose and scope

### 1.1 Problem

Open-source parental control stacks (starting from [timekpr-next](https://mjasnik.gitlab.io/timekpr-next/) and possibly others) are limited and easy to bypass on a normal desktop Linux install. We need gold images where:

- Children get a full desktop experience (any DE they choose later).
- Everyday `sudo` works for normal tasks without a password prompt spam.
- Users cannot remove or disable screen-time / parental tooling via sudo, polkit, or casual package operations.
- Any newly created interactive user automatically inherits the same guardrails.
- A parent can later manage restrictions from the local network (Android app or another computer), using real root/recovery when needed — not a trapped local “admin child” account model.

### 1.2 Product

**parental-os** is a monorepo that builds **installable ISOs** for multiple distributions from one orchestration entrypoint, applying shared overlays and a guarded meta-package.

### 1.3 v1 in scope

- Repository layout under `/home/dat30/github/parental-os` with remote `git@github.com:cgtarmenta/parental-os.git`.
- Shared `overlays/` + package **`parental-guard`** (placeholder; not a timekpr fork yet).
- Distro builders:
  - **Ubuntu** via live-build (or equivalent Debian live pipeline).
  - **CachyOS** via archiso-style / Cachy ISO profile.
- Single orchestration command (e.g. `just build` / `scripts/build-all.sh`) for one or both distros.
- Preloaded config files and install rules via overlays/hooks.
- Security model: passwordless sudo for normal use, deny list + polkit + protected units/paths + user-creation hooks.
- Automatic inheritance of guardrails for newly created users (no per-user sudoers lines as the primary mechanism).
- QEMU smoke tests validating guard service, sudo denials, and group/policy inheritance as far as automation allows.
- Optional Docker only as a **build-tooling** aid, not as a substitute for booting the ISO.
- Documented stub for a future LAN guardian agent (no full Android app in v1).
- Design/implementation docs under `docs/superpowers/`.

### 1.4 v1 out of scope

- Real fork of timekpr-next (phase 2).
- Fixed desktop environment or DE installer UX (control plane must stay DE-agnostic).
- Full Android / parent desktop app.
- Hard guarantee against a determined operator with root, live media, or physical access (root retention is intentional).
- Public Internet exposure of the control agent.
- Perfect CI of full ISO builds on free runners (may be local-first initially).

### 1.5 Success criteria (v1 done)

1. Clone `git@github.com:cgtarmenta/parental-os.git` and follow README to understand build/test.
2. `just build all` (or documented equivalent) produces reproducible build attempts and artifacts under `out/` for Ubuntu and CachyOS (stubs only acceptable if tooling gaps are explicit and one path is real; target is both constructible).
3. `just test-qemu` fails closed when guard service is down, guarded commands succeed under sudo, or new users skip the parental group/policy path.
4. This design spec is present and matches implemented structure.

---

## 2. Goals and non-goals

### 2.1 Goals

- **One repo, many distros:** shared policy logic; distro folders only know how to install it.
- **ISO-first:** installable images primary; QEMU for validation; Docker secondary.
- **Desktop-agnostic parental plane:** no dependency on GNOME/KDE/Hyprland APIs for enforcement core.
- **UX for kids:** full system experience; friction is on bypassing controls, not on normal apps.
- **UX for parents:** keep real root/recovery; evolve toward LAN remote configuration.
- **Extensibility:** stable paths, units, and package name so timekpr-next fork and other tools plug into the same guard.

### 2.2 Non-goals

- Replacing enterprise MDM / full fleet management.
- Hiding root from the household operator.
- Shipping a polished consumer app store image in v1.
- Supporting every Arch derivative on day one (CachyOS + Ubuntu only).

---

## 3. Roles and trust model

| Role | Location | Powers |
|------|----------|--------|
| **Child / local interactive user** | Installed system | Full desktop experience; passwordless sudo for everyday tasks; **cannot** disable parental stack, alter guarded time policy tools, or use trivial sudo escape hatches defined in v1 |
| **Guardian (parent)** | Android app or parent PC on **LAN** (future); root/SSH/recovery as needed | Read/adjust time policies and exceptions; full repair via root |
| **Recovery operator** | Live ISO / root console | Unrestricted |

**Important product decision:** real root remains available. The threat model for v1 is the **local desktop user with limited sudo**, not “unbreakable against root.”

Remote guardian control is a **phase 3** product surface; v1 only reserves the on-image agent contract (stub unit, bind policy, auth placeholder).

---

## 4. Architecture

### 4.1 Approach

**Overlays + native builders (Approach A):**

- Shared policy and files live in `overlays/` and `packages/parental-guard`.
- Each distro uses its native ISO toolchain.
- Orchestration invokes both builders and common apply/test scripts.

Rejected for v1 primary path:

- **Packer-only:** weaker fit for installable live ISOs.
- **Single abstract rootfs:** too costly across deb vs pacman ecosystems.

### 4.2 Repository layout

```text
parental-os/
├── README.md
├── Justfile                      # build, test-qemu, clean
├── docs/
│   └── superpowers/
│       ├── specs/                # this design and future specs
│       └── plans/                # implementation plans
├── overlays/                     # shared filesystem tree (source of truth)
│   ├── etc/
│   │   ├── sudoers.d/
│   │   ├── polkit-1/
│   │   ├── systemd/
│   │   └── parental-os/
│   ├── usr/
│   │   ├── lib/parental-os/
│   │   └── share/parental-os/
│   └── skel/                     # optional user defaults
├── packages/
│   └── parental-guard/           # placeholder package (deb + arch)
│       ├── debian/
│       ├── arch/
│       └── src/
├── distros/
│   ├── ubuntu/                   # live-build config + hooks
│   └── cachyos/                  # archiso/Cachy profile + hooks
├── scripts/
│   ├── build-all.sh
│   ├── build-ubuntu.sh
│   ├── build-cachyos.sh
│   ├── apply-overlays.sh
│   └── test-qemu.sh
├── tests/
│   └── qemu/
├── out/                          # ISOs + logs (gitignored)
└── .gitignore
```

**Principles:**

- No duplicated business logic inside `distros/*/`.
- `apply-overlays.sh` is the single merge path from shared tree → chroot/ISO root.
- `out/` and build caches are never committed.

### 4.3 Component: `parental-guard` (placeholder package)

Ships:

- systemd units / drop-ins for the guard (and future timekpr units hooks).
- sudoers drop-in and polkit rules.
- user-creation / first-login inheritance hooks.
- protected path and protected package lists.
- CLI: `parental-guard status|doctor` for humans and QEMU tests.
- **LAN agent stub** (script or minimal service): local/LAN bind only, token placeholder, documented intended API shape in `docs/` (OpenAPI optional stub allowed; full app not required).

Phase 2 replaces/extends placeholder with real timekpr-next fork packages without renaming the guard integration surface if possible.

### 4.4 Component: shared overlays

Filesystem snippets that must be identical in spirit on both distros (paths may adapt via package install scripts when FHS differs slightly). Includes example parental configs under `/etc/parental-os/`.

### 4.5 Component: distro builders

| Distro | v1 toolchain | Integration |
|--------|--------------|-------------|
| Ubuntu | live-build | Hooks install `parental-guard` `.deb`, run `apply-overlays.sh`, seed test user if desired |
| CachyOS | archiso-style / Cachy ISO profile | Hooks install `parental-guard` package from local PKGBUILD/repo, same overlays |

Both expose the same high-level stages: bootstrap → install base → install guard → apply overlays → cleanup → ISO.

### 4.6 Component: orchestration

- `just build ubuntu|cachyos|all`
- `just test-qemu ubuntu|cachyos|all`
- `just clean`
- Default `all` builds **serially** (optional parallel later).

### 4.7 Component: QEMU test harness

Boots artifact with KVM when available and asserts at least:

1. `parental-guard` service (or equivalent unit) is active.
2. Test user is in the parental group / covered by sudoers group rule.
3. Innocuous `sudo` command allowed (e.g. `sudo true` or a harmless allowlisted action).
4. Guarded operations denied (representative sample: stop/disable guard unit, invoke guarded admin binary path, `visudo`, etc.).
5. Exit non-zero on failure; logs under `out/`.

Exact automation (cloud-init, expect, ssh into guest) is an implementation detail left to the plan; behavior above is normative.

### 4.8 Docker

Optional container with host build dependencies. Not a runtime stand-in for full desktop ISO boot.

---

## 5. Security design (guardrails)

### 5.1 Identity

- System group: **`parental-users`** (final name may match this exactly).
- Primary sudo/polkit subject: **`%parental-users`**, not one-off usernames (avoids missing new accounts).
- All interactive human users created on the system must be added to this group automatically.

### 5.2 Defense in depth

1. **sudoers**  
   - Passwordless broad access for `%parental-users`.  
   - `Cmnd_Alias GUARDED` (name illustrative) denies parental admin tools, `visudo`, shell escalation patterns as feasible, `su`, dangerous passwd targets, package-manager remove/purge of protected packages, `systemctl` stop/disable/mask of protected units, and time-altering tools where they break enforcement (`timedatectl`, `date` set operations as applicable).  
   - **Note:** `ALL, !GUARDED` alone is insufficient; layers below are mandatory.

2. **polkit**  
   - Deny pkexec / administrative actions that bypass sudo for package removal, unit management of protected services, and related admin panels where rules can express it.

3. **Filesystem / packages**  
   - Guard configs and binaries `root:root`, minimal permissions.  
   - Protected package list enforced by hook/wrapper where practical so `apt`/`pacman` removal of guard stack fails for guarded users.

4. **systemd**  
   - Guard units enabled by default.  
   - Drop-ins reduce casual disable/mask from user session.  
   - Future timekpr units join the same protected set.

5. **User provisioning hooks**  
   - `/usr/lib/parental-os/user-setup.sh` (path illustrative) invoked from distro-appropriate useradd/adduser hooks and a first-login safety net.  
   - Ensures group membership and any skel/policy seeds without editing sudoers per user.

### 5.3 Explicit non-claims

- Root, live USB, and physical access can undo controls — required for guardian operations.
- v1 reduces casual bypass by children with desktop sudo, not nation-state or expert local root attackers.
- DE-specific “parental plugins” are non-authoritative; kernel/session time enforcement comes from the parental engine (phase 2+).

### 5.4 Example policy shape (illustrative, not final file)

The user’s initial idea maps to a **group-based** rule rather than a single username:

```sudoers
Cmnd_Alias GUARDED = /usr/bin/timekpr-admin, /usr/sbin/ctparental, \
  /usr/bin/timedatectl, /usr/bin/date, /usr/bin/visudo, \
  /bin/su, /bin/bash, /bin/sh, /usr/bin/passwd, \
  /usr/bin/systemctl stop parental-guard.service, \
  /usr/bin/systemctl disable parental-guard.service
# plus package-manager guarded operations as implemented

%parental-users ALL=(ALL) NOPASSWD: ALL, !GUARDED
```

Implementation must expand and harden this list and pair it with polkit/hooks; the spec requires the **intent**, not this exact alias body.

---

## 6. Remote administration contract (stub in v1)

### 6.1 Direction

- Parent manages restrictions from **local network** (Android / parent computer).
- On-image **agent stub** present so phase 3 does not reshape the ISO layout.

### 6.2 v1 requirements for the stub

- systemd unit installed and enabled (may expose only health/status).
- Default listen policy: **localhost and/or LAN interface**, not open Internet by default.
- Authentication placeholder: shared token / pair secret generated or seeded at first boot (document format; full pairing UX later).
- Document intended operations: get status, get/set time allowances, list users, health — even if handlers return `501 Not Implemented` except health/status.

### 6.3 Out of scope for stub

- Production-grade mTLS, app store client, multi-tenant cloud relay.

---

## 7. Build and host requirements

- Primary build host: CachyOS/Arch-like system (developer machine is acceptable).
- Needs: sufficient disk for two ISO pipelines, KVM for QEMU tests, root/sudo for ISO build steps as required by toolchains.
- README must list packages/tools (`just`, live-build deps, archiso/Cachy tooling, qemu-system, etc.).
- Network may be required during bootstrap to fetch packages unless fully offline mirrors are configured later.

---

## 8. Testing strategy

| Layer | What |
|-------|------|
| **Static** | Shellcheck/lint scripts where applicable; `visudo -c` / sudoers validation in package build |
| **Package** | deb and pkgbuild install in clean chroot if feasible |
| **QEMU smoke** | Normative v1 gate (section 4.7) |
| **Manual** | Boot ISO, create new user from DE/CLI, confirm inheritance |

No claim of full security audit in v1.

---

## 9. Roadmap

| Phase | Deliverable |
|-------|-------------|
| **v1** | Monorepo, overlays, `parental-guard` placeholder, Ubuntu + CachyOS ISO pipeline, QEMU smoke, GitHub remote, docs |
| **v2** | timekpr-next fork packaged and integrated; real screen-time enforcement |
| **v3** | Stable LAN agent + Android / parent desktop client |
| **v4+** | Additional parental tools, richer profiles, ISO signing, harder bypass mitigations |

---

## 10. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| sudo deny-list bypass | polkit + hooks + protected packages/units; expand tests |
| Ubuntu vs Cachy drift | shared overlays/package only; thin distro hooks |
| Cachy ISO tooling churn | pin profile docs; isolate distro adapter |
| Heavy builds | local-first; cache; serial builds default |
| LAN agent abuse on open Wi-Fi | no default public bind; token required before real APIs |
| Scope creep into app/DE | hard phase gates in this spec |

---

## 11. Documentation deliverables

- `README.md` — quick start, build, test, threat model summary.
- This file — design source of truth for v1.
- Implementation plan under `docs/superpowers/plans/` after plan authoring.
- Short `docs/agent-api.md` (or equivalent) describing stub endpoints/status.

---

## 12. Open implementation choices (deferred to plan, not product ambiguity)

These do not reopen product scope; implementers pick concrete tools consistent with this design:

- Exact live-build vs ubuntu-image flavor for Ubuntu.
- Exact CachyOS ISO profile source (upstream Cachy vs archiso derivative).
- QEMU guest automation mechanism (ssh + cloud-init vs serial expect).
- Language for agent stub (shell+socat vs small Go/Rust binary).
- Whether `just` is mandatory vs Makefile fallback (prefer Justfile as designed).

---

## 13. Approval

- **Design approach:** Overlays + native builders (A) — approved.  
- **v1 success bar:** both distros + guard + QEMU checks — approved.  
- **DE policy:** none fixed; parental plane DE-agnostic — approved.  
- **Accounts:** all new users inherit guardrails; root kept for guardian — approved.  
- **Remote:** LAN parent control later; stub in image — approved.  
- **Repo name/remote:** `parental-os` / `git@github.com:cgtarmenta/parental-os.git` — approved.  
- **Phase 1 engine:** placeholder only; timekpr fork later — approved.

**Approved by:** Don Tadeo (product owner) — 2026-08-01  
**Next step:** implementation plan via writing-plans skill; then scaffold and build pipeline.
