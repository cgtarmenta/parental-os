# Design Specification: Guardian Secret Setup & Remote Screen Lock Agent

- **Date**: 2026-09-02
- **Author**: Antigravity & Carlos G. T. Armenta Andrade
- **Status**: Draft (Approved in Brainstorming)
- **Target Distributions**: Ubuntu 26.04 Desktop, CachyOS (Desktop & Handheld)
- **Target Architectures**: `amd64` (`x86_64`), `arm64` (`aarch64`)

---

## 1. Executive Summary

This specification establishes the architecture and implementation design for the next evolution of `parental-guard`:
1. **Interactive Guardian Password Setup during Installation**:
   - Ubuntu: A native, clean GTK modal dialog presented in the live installer session prior to Subiquity.
   - CachyOS: A dedicated interactive module integrated directly into Calamares.
2. **Cryptographic Storage & Verification**:
   - Deterministic domain-separated SHA-256 hash (`sha256("parental-guard:lan-v1:" + password)`).
   - Secure persistence to `/target/etc/parental-os/guardian.hash` with `0600 root:root` permissions during target provisioning.
3. **Compiled Multi-Architecture Rust Agent (`parental-guard-agent`)**:
   - Replaces the Python `server.py` stub with a high-performance, memory-safe, compiled Rust daemon.
   - Cross-compiled for both `amd64` and `arm64`.
   - Exposes authenticated HTTP endpoints (`GET /health`, `GET /v1/status`, `POST /v1/actions/lock`).
   - Constant-time Bearer token comparison (`Authorization: Bearer <hash>`).
   - Executes immediate desktop screen locking via `loginctl lock-sessions` with fallback to display manager/screensaver D-Bus interfaces.
4. **Remote Testing Client**:
   - A companion CLI script (`scripts/parental-remote.py`) that computes the exact same hash from `--password` and interacts with the agent over the LAN.

---

## 2. Problem Statement & Motivation

Previously, `parental-guard` focused on local group enrollment (`parental-users`), `sudoers` command restrictions, and polkit policies. However:
- There was no mechanism during installation for the parent/guardian to set an administrative master secret distinct from the child's user password.
- The LAN agent was a basic Python prototype stub listening only on `127.0.0.1` without real remote enforcement capabilities or multi-architecture binary distribution.
- To enable remote parenting via a mobile application or LAN controller, the system requires a secure, lightweight, and tamper-resistant network daemon capable of locking down the workstation on demand.

---

## 3. Architecture & Data Flow

```
+-------------------------------------------------------------+
|                     INSTALLATION PHASE                      |
|                                                             |
|  [ Ubuntu Live Session ]         [ CachyOS Live Session ]   |
|   GTK Dialog / Hook               Calamares Setup Module    |
|            \                               /                |
|             \                             /                 |
|       Guardian Inputs Password ("MiClave123")               |
|                           |                                 |
|       Calculate: sha256("parental-guard:lan-v1:" + pwd)     |
|                           |                                 |
|     Save to Live RAM: /run/parental-os/guardian.hash        |
|                           |                                 |
|        Provisioner Transfer to Target Partition             |
|         /target/etc/parental-os/guardian.hash               |
|                    (mode 0600 root:root)                    |
+-------------------------------------------------------------+
                            |
                            v Target Reboots
+-------------------------------------------------------------+
|                      RUNTIME EXECUTION                      |
|                                                             |
|  [ parental-guard-agent (Rust Binary) ]                     |
|  - Systemd Unit: parental-guard-agent.service               |
|  - Listens on: 0.0.0.0:7420 (LAN)                           |
|  - Reads: /etc/parental-os/guardian.hash                    |
|                                                             |
|  [ Remote Client / Mobile App / parental-remote.py ]        |
|  - Sends: POST /v1/actions/lock                             |
|  - Header: Authorization: Bearer <hash>                     |
|                           |                                 |
|  [ Constant-Time Comparison ]                               |
|   - Matched: Execute loginctl lock-sessions + fallback     |
|   - Mismatched: Return 401 Unauthorized                     |
+-------------------------------------------------------------+
```

---

## 4. Component Details

### 4.1 Installer Secret Capture

#### A. Ubuntu Desktop (Live Environment)
- **Script**: `/usr/lib/parental-os/guardian-setup-prompt.sh`
- **Mechanism**:
  - Launched via an autostart hook or live desktop wrapper before Subiquity initiates.
  - Invokes a GTK/Zenity dialog:
    - Field 1: Contraseña de Guardián / Guardian Password.
    - Field 2: Confirmar Contraseña / Confirm Password.
  - Validates matching non-empty input.
  - Computes:
    ```python
    import hashlib
    hash_val = hashlib.sha256(("parental-guard:lan-v1:" + password).encode("utf-8")).hexdigest()
    ```
  - Writes `hash_val` to `/run/parental-os/guardian.hash` with `chmod 0600`.
  - **Headless / Unattended Mode**:
    - If `PARENTAL_OS_GUARDIAN_PASSWORD` is set in the environment or `/run/parental-os/guardian.hash` already exists, the GUI prompt is bypassed.

#### B. CachyOS (Calamares)
- **Module**: `parental-guardian` Calamares view/execution module.
- Prompts within the Calamares installer sequence for the Guardian Password.
- Computes identical domain-separated SHA-256 hash.
- Writes to `/run/parental-os/guardian.hash` (and directly into `/target/etc/parental-os/guardian.hash` in the Calamares `chroot` phase).

#### C. Target Provisioning Persistence
- `target-provisioner.sh` (run via `parental-target-shutdown.service` in Ubuntu or shellprocess in Calamares):
  - Copies `/run/parental-os/guardian.hash` to `/target/etc/parental-os/guardian.hash`.
  - Enforces `chmod 0600 /target/etc/parental-os/guardian.hash` and `chown 0:0`.

---

### 4.2 Rust Agent Architecture (`parental-guard-agent`)

- **Location**: `packages/parental-guard/agent/`
- **Language**: Rust (edition 2021)
- **Binary Name**: `parental-guard-agent`
- **Installed Path**: `/usr/lib/parental-os/parental-guard-agent`
- **Service Unit**: `parental-guard-agent.service`

#### Dependencies
- Minimal, audited, and lightweight:
  - `tokio` (features = `["rt-multi-thread", "macros", "process"]`)
  - `axum` (lightweight web framework)
  - `serde`, `serde_json`
  - `sha2`
  - `subtle` (for constant-time slice comparison `ConstantTimeEq`)

#### Security & Authentication
- **Token File**: Reads `/etc/parental-os/guardian.hash`.
- **Timing Attack Prevention**: Uses `subtle::ConstantTimeEq` to compare the incoming Bearer token string against the stored hash.
- **Fail-Closed**: If `/etc/parental-os/guardian.hash` does not exist or is empty, all authenticated endpoints return `401 Unauthorized` and log a security warning.

#### API Endpoints
1. `GET /health`:
   - **Auth**: None (Public for LAN discovery).
   - **Status**: `200 OK`.
   - **Response**: `{"status": "ok", "service": "parental-guard-agent"}`.
2. `GET /v1/status`:
   - **Auth**: `Authorization: Bearer <hash>`.
   - **Status**: `200 OK` or `401 Unauthorized`.
   - **Response**:
     ```json
     {
       "service": "parental-guard-agent",
       "version": "0.2.0",
       "hostname": "MBALI",
       "screen_locked": false,
       "parental_users": ["cmva"]
     }
     ```
3. `POST /v1/actions/lock`:
   - **Auth**: `Authorization: Bearer <hash>`.
   - **Action Logic**:
     1. Executes `loginctl lock-sessions`.
     2. Fallback: Checks for active user display sessions and invokes `gdbus call --session ... org.gnome.ScreenSaver.Lock` or switches VT if unlocked.
   - **Response**:
     ```json
     {
       "status": "ok",
       "action": "lock",
       "result": "locked"
     }
     ```

---

### 4.3 Multi-Architecture Packaging (`amd64` / `arm64`)

The build pipeline must compile native ELF binaries for both target architectures:
- `x86_64-unknown-linux-gnu` (Ubuntu Desktop amd64, CachyOS Desktop x86_64)
- `aarch64-unknown-linux-gnu` (CachyOS Handheld arm64, Ubuntu Desktop arm64)

#### Arch Linux (`packages/parental-guard/arch/PKGBUILD`)
- Update `arch=('x86_64' 'aarch64')`.
- In `build()`:
  ```bash
  cd "$srcdir/agent"
  cargo build --release --locked
  ```
- In `package()`:
  ```bash
  install -Dm755 "$srcdir/agent/target/release/parental-guard-agent" \
    "$pkgdir/usr/lib/parental-os/parental-guard-agent"
  ```

#### Debian / Ubuntu (`packages/parental-guard/debian/`)
- Update `debian/control`:
  - `Architecture: any`
  - `Build-Depends: debhelper-compat (= 13), cargo, rustc`
- Update `debian/rules`:
  - Under `override_dh_auto_build`:
    ```makefile
    override_dh_auto_build:
    	cd agent && cargo build --release --locked
    	dh_auto_build
    ```
- Update `debian/parental-guard.install`:
  - Map `agent/target/release/parental-guard-agent usr/lib/parental-os/`

---

### 4.4 Remote Testing Utility (`scripts/parental-remote.py`)

- A standalone Python script runnable on the host or external network client:
  ```bash
  python3 scripts/parental-remote.py \
    --host <IP> \
    --port 7420 \
    --password "<guardian_password>" \
    lock
  ```
- Computes:
  `token = hashlib.sha256(("parental-guard:lan-v1:" + args.password).encode()).hexdigest()`
- Issues HTTP POST with `Authorization: Bearer <token>`.
- Displays response status and execution latency.

---

## 5. Verification & Testing Strategy

1. **Unit Tests (Cargo)**:
   - `cargo test` verifying hash computation, constant-time verification, and Axum routing handlers.
2. **Package Build Tests (BATS / Docker)**:
   - Verify `just package-deb` produces an `amd64` `.deb` containing `/usr/lib/parental-os/parental-guard-agent`.
   - Verify `just package-arch` produces an `x86_64` `.pkg.tar.zst` containing the binary.
   - Verify permissions on installed `/etc/parental-os/guardian.hash` are `0600`.
3. **End-to-End QEMU Verification**:
   - Install Ubuntu in QEMU with guardian password configured.
   - Boot installed system.
   - Run `scripts/parental-remote.py --host 127.0.0.1 --port 7420 --password "secret" lock`.
   - Verify screen locks immediately via QEMU monitor `screendump`.
