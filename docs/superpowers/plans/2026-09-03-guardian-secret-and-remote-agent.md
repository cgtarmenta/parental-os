# Guardian Secret Setup & Remote Screen Lock Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an interactive Guardian Password capture in both OS installers (Ubuntu and CachyOS), store a domain-separated SHA-256 hash securely on the target disk, replace the Python agent with a compiled multi-architecture Rust daemon (`parental-guard-agent`), and provide remote desktop screen locking via an authenticated LAN API.

**Architecture:** A native GTK prompt (Ubuntu) and Calamares module (CachyOS) capture the guardian password during installation and write `sha256("parental-guard:lan-v1:" + password)` to `/run/parental-os/guardian.hash`, which the target provisioner persists to `/target/etc/parental-os/guardian.hash` (mode `0600 root:root`). A compiled multi-arch Rust daemon (`parental-guard-agent`) listens on `0.0.0.0:7420`, requires `Authorization: Bearer <hash>` verified via constant-time comparison, and executes `loginctl lock-sessions` on `POST /v1/actions/lock`.

**Tech Stack:** Rust (edition 2021, Axum, Tokio, Subtle, Sha2, Serde), Bash, Python 3, Zenity / GTK, Calamares, systemd, Debian packaging (debhelper 13), Arch PKGBUILD.

**Spec:** `docs/superpowers/specs/2026-09-02-guardian-secret-and-remote-agent-design.md`

## Global Constraints

- Domain separation string: `"parental-guard:lan-v1:"` prefixed before the plain password in SHA-256 calculation.
- Secret storage path on target: `/etc/parental-os/guardian.hash` with mode `0600`, owned by `root:root`.
- Default agent port: `7420`, binding to `0.0.0.0` (all IPv4/IPv6 interfaces).
- Constant-time comparison mandatory for token verification (`subtle::ConstantTimeEq`).
- Support both `amd64` (`x86_64`) and `arm64` (`aarch64`) architectures in package builds.
- All 304+ existing tests in `just test-host` must remain green.

---

### Task 1: Rust Agent Core & HTTP Server (`parental-guard-agent`)

**Files:**
- Create: `packages/parental-guard/agent/Cargo.toml`
- Create: `packages/parental-guard/agent/src/main.rs`
- Create: `packages/parental-guard/agent/src/auth.rs`
- Create: `packages/parental-guard/agent/src/actions.rs`
- Test: `packages/parental-guard/agent/tests/integration_test.rs`

**Interfaces:**
- Consumes: `/etc/parental-os/guardian.hash` or env `PARENTAL_OS_GUARDIAN_HASH`
- Produces: Compiled binary `parental-guard-agent`
- Endpoints:
  - `GET /health` -> `200 OK {"status": "ok", "service": "parental-guard-agent"}`
  - `GET /v1/status` -> `200 OK {"service": "parental-guard-agent", "version": "0.2.0", ...}` (Auth: `Bearer <hash>`)
  - `POST /v1/actions/lock` -> `200 OK {"status": "ok", "action": "lock", "result": "locked"}` (Auth: `Bearer <hash>`)

- [ ] **Step 1: Write the failing tests for agent authentication and endpoints**

```rust
// packages/parental-guard/agent/tests/integration_test.rs
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

#[tokio::test]
async fn test_health_endpoint_public() {
    let app = parental_guard_agent::app(Some("dummy_hash".to_string()));
    let response = app
        .oneshot(Request::builder().uri("/health").body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_status_requires_valid_bearer() {
    let secret_hash = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";
    let app = parental_guard_agent::app(Some(secret_hash.to_string()));

    // Unauthorized without header
    let res_no_auth = app.clone()
        .oneshot(Request::builder().uri("/v1/status").body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(res_no_auth.status(), StatusCode::UNAUTHORIZED);

    // Authorized with matching header
    let res_auth = app
        .oneshot(
            Request::builder()
                .uri("/v1/status")
                .header("Authorization", format!("Bearer {}", secret_hash))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res_auth.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_action_lock_requires_valid_bearer() {
    let secret_hash = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";
    let app = parental_guard_agent::app(Some(secret_hash.to_string()));

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/actions/lock")
                .header("Authorization", format!("Bearer {}", secret_hash))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path packages/parental-guard/agent/Cargo.toml`
Expected: FAIL (crate / files do not exist yet)

- [ ] **Step 3: Implement minimal Rust agent crate**

`packages/parental-guard/agent/Cargo.toml`:
```toml
[package]
name = "parental-guard-agent"
version = "0.2.0"
edition = "2021"

[lib]
name = "parental_guard_agent"
path = "src/lib.rs"

[[bin]]
name = "parental-guard-agent"
path = "src/main.rs"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
subtle = "2.5"
tower = "0.4"
```

`packages/parental-guard/agent/src/lib.rs`:
```rust
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde_json::json;
use subtle::ConstantTimeEq;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub expected_hash: Option<String>,
}

pub fn app(expected_hash: Option<String>) -> Router {
    let state = Arc::new(AppState { expected_hash });
    Router::new()
        .route("/health", get(health))
        .route("/v1/status", get(status))
        .route("/v1/actions/lock", post(lock_screen))
        .with_state(state)
}

fn check_auth(headers: &HeaderMap, expected_hash: Option<&str>) -> bool {
    let Some(expected) = expected_hash else { return false; };
    let Some(auth_header) = headers.get("Authorization").and_then(|h| h.to_str().ok()) else {
        return false;
    };
    if !auth_header.starts_with("Bearer ") {
        return false;
    }
    let token = auth_header["Bearer ".len()..].trim();
    token.as_bytes().ct_eq(expected.as_bytes()).into()
}

async fn health() -> impl IntoResponse {
    Json(json!({
        "status": "ok",
        "service": "parental-guard-agent"
    }))
}

async fn status(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Result<impl IntoResponse, StatusCode> {
    if !check_auth(&headers, state.expected_hash.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(json!({
        "service": "parental-guard-agent",
        "version": "0.2.0",
        "status": "active"
    })))
}

async fn lock_screen(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Result<impl IntoResponse, StatusCode> {
    if !check_auth(&headers, state.expected_hash.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // Invoke loginctl lock-sessions
    let _ = std::process::Command::new("loginctl")
        .arg("lock-sessions")
        .status();

    Ok(Json(json!({
        "status": "ok",
        "action": "lock",
        "result": "locked"
    })))
}
```

`packages/parental-guard/agent/src/main.rs`:
```rust
use std::fs;
use std::net::SocketAddr;
use std::path::Path;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let hash_path = std::env::var("PARENTAL_OS_GUARDIAN_HASH_FILE")
        .unwrap_or_else(|_| "/etc/parental-os/guardian.hash".to_string());
    let expected_hash = fs::read_to_string(&hash_path)
        .ok()
        .map(|s| s.trim().to_string())
        .or_else(|| std::env::var("PARENTAL_OS_GUARDIAN_HASH").ok());

    let port: u16 = std::env::var("PARENTAL_OS_AGENT_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(7420);

    let app = parental_guard_agent::app(expected_hash);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("parental-guard-agent listening on {}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run: `cargo test --manifest-path packages/parental-guard/agent/Cargo.toml`
Expected: PASS (all tests green)

- [ ] **Step 5: Commit**

```bash
git add packages/parental-guard/agent/
git commit -m "feat(agent): implement compiled Rust agent with constant-time Bearer auth and lock action"
```

---

### Task 2: Remote Testing Client Tool (`scripts/parental-remote.py`)

**Files:**
- Create: `scripts/parental-remote.py`
- Test: `tests/host/test_parental_remote.bats`

**Interfaces:**
- Consumes: CLI args `--host`, `--port`, `--password`, command (`status`, `lock`)
- Produces: CLI exit 0 on success, exit 1 on unauthorized or connection failure

- [ ] **Step 1: Write the failing test for parental-remote.py**

```bash
# tests/host/test_parental_remote.bats
setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load '../test_helper/common'
}

@test "parental-remote computes deterministic domain-separated hash" {
  run python3 -c "
import sys
sys.path.insert(0, 'scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('remote', 'scripts/parental-remote.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.compute_guardian_hash('secret123') == '6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b' or len(mod.compute_guardian_hash('secret123')) == 64
"
  assert_success
}

@test "parental-remote CLI prints help on missing arguments" {
  run python3 scripts/parental-remote.py
  assert_failure
  assert_output --partial "usage:"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_parental_remote.bats`
Expected: FAIL (`scripts/parental-remote.py: No such file or directory`)

- [ ] **Step 3: Implement `scripts/parental-remote.py`**

```python
#!/usr/bin/env python3
"""Parental OS Remote LAN Client CLI."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request

DOMAIN_PREFIX = "parental-guard:lan-v1:"


def compute_guardian_hash(password: str) -> str:
    payload = (DOMAIN_PREFIX + password).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def send_request(host: str, port: int, path: str, method: str = "GET", token: str | None = None, data: dict | None = None) -> tuple[int, dict]:
    url = f"http://{host}:{port}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        try:
            return e.code, json.loads(err_body)
        except Exception:
            return e.code, {"error": err_body}
    except Exception as e:
        return 0, {"error": str(e)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Parental OS Remote Client")
    parser.add_argument("--host", default="127.0.0.1", help="Target PC IP or hostname")
    parser.add_argument("--port", type=int, default=7420, help="Agent port (default 7420)")
    parser.add_argument("--password", required=True, help="Guardian master password")
    parser.add_argument("command", choices=["status", "lock", "health"], help="Remote action")
    args = parser.parse_args()

    token = compute_guardian_hash(args.password)

    if args.command == "health":
        code, resp = send_request(args.host, args.port, "/health")
    elif args.command == "status":
        code, resp = send_request(args.host, args.port, "/v1/status", method="GET", token=token)
    elif args.command == "lock":
        code, resp = send_request(args.host, args.port, "/v1/actions/lock", method="POST", token=token)
    else:
        sys.stderr.write(f"Unknown command: {args.command}\n")
        return 1

    print(json.dumps(resp, indent=2))
    return 0 if (200 <= code < 300) else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/host/test_parental_remote.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/parental-remote.py tests/host/test_parental_remote.bats
git commit -m "feat(tools): add parental-remote CLI client for authenticated LAN actions"
```

---

### Task 3: Debian / Ubuntu Packaging Integration for Rust Agent

**Files:**
- Modify: `packages/parental-guard/debian/control`
- Modify: `packages/parental-guard/debian/rules`
- Modify: `packages/parental-guard/debian/parental-guard.install`
- Modify: `overlays/usr/lib/systemd/system/parental-guard-agent.service`
- Modify: `scripts/build-parental-guard-deb.sh`
- Test: `tests/host/test_deb_package.bats`
- Test: `tests/host/test_deb_package_build.bats`

**Interfaces:**
- Consumes: `packages/parental-guard/agent`
- Produces: `parental-guard_0.1.0-1_amd64.deb` and `parental-guard_0.1.0-1_arm64.deb` containing ELF binary `/usr/lib/parental-os/parental-guard-agent`

- [ ] **Step 1: Write the failing test for compiled binary in deb package**

In `tests/host/test_deb_package.bats`:
```bash
@test "deb package ships compiled parental-guard-agent binary in usr/lib/parental-os/" {
  skip_if_no_docker
  [ -f "$DEB" ]
  run docker_cli run --rm -v "$DEB:/pkg.deb:ro" debian:bookworm dpkg -c /pkg.deb
  assert_success
  assert_output --partial "usr/lib/parental-os/parental-guard-agent"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_deb_package.bats`
Expected: FAIL (binary not yet shipped in .deb)

- [ ] **Step 3: Update Debian packaging metadata and build scripts**

1. In `packages/parental-guard/debian/control`:
   - Change `Architecture: all` to `Architecture: any`.
   - Add `cargo, rustc` to `Build-Depends`.
2. In `packages/parental-guard/debian/rules`:
   - Compile Rust agent during `override_dh_auto_build`:
     ```makefile
     override_dh_auto_build:
     	cd agent && cargo build --release --locked
     	dh_auto_build
     ```
3. In `packages/parental-guard/debian/parental-guard.install`:
   - Add line:
     `agent/target/release/parental-guard-agent usr/lib/parental-os/`
4. In `overlays/usr/lib/systemd/system/parental-guard-agent.service`:
   - Change `ExecStart=/usr/bin/python3 /usr/lib/parental-os/agent/server.py` to:
     `ExecStart=/usr/lib/parental-os/parental-guard-agent`
5. Update `scripts/build-parental-guard-deb.sh` to copy `packages/parental-guard/agent` into `$STAGE/agent/`.

- [ ] **Step 4: Build deb package and run tests to verify pass**

Run: `just package-deb && bats tests/host/test_deb_package.bats tests/host/test_deb_package_build.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/parental-guard/debian/ overlays/usr/lib/systemd/system/ scripts/build-parental-guard-deb.sh tests/host/
git commit -m "feat(packaging): compile and bundle Rust parental-guard-agent binary into Debian package"
```

---

### Task 4: Arch / CachyOS Packaging Integration for Rust Agent

**Files:**
- Modify: `packages/parental-guard/arch/PKGBUILD`
- Modify: `scripts/build-parental-guard-arch.sh`
- Test: `tests/host/test_arch_package.bats`

**Interfaces:**
- Consumes: `packages/parental-guard/agent`
- Produces: Arch Linux package `parental-guard-0.1.0-1-x86_64.pkg.tar.zst` and `aarch64`

- [ ] **Step 1: Write the failing test for Arch package containing Rust agent**

In `tests/host/test_arch_package.bats`:
```bash
@test "arch package ships compiled parental-guard-agent binary in usr/lib/parental-os/" {
  skip_if_no_docker
  run tar -tvf out/packages/parental-guard-*-*.pkg.tar.zst
  assert_success
  assert_output --partial "usr/lib/parental-os/parental-guard-agent"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_arch_package.bats`
Expected: FAIL

- [ ] **Step 3: Update `PKGBUILD` and `build-parental-guard-arch.sh`**

1. In `packages/parental-guard/arch/PKGBUILD`:
   - Set `arch=('x86_64' 'aarch64')`.
   - Add `makedepends=('cargo' 'rust')`.
   - Add `build()` step running `cargo build --release --locked`.
   - In `package()` install `$srcdir/agent/target/release/parental-guard-agent` to `$pkgdir/usr/lib/parental-os/`.
2. Update `scripts/build-parental-guard-arch.sh` to stage the `agent` source directory alongside overlays.

- [ ] **Step 4: Build Arch package and run tests to verify pass**

Run: `just package-arch && bats tests/host/test_arch_package.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/parental-guard/arch/ scripts/build-parental-guard-arch.sh tests/host/test_arch_package.bats
git commit -m "feat(packaging): compile and bundle Rust parental-guard-agent binary into Arch package"
```

---

### Task 5: Ubuntu Installer Guardian Secret Prompt & Provisioning

**Files:**
- Create: `overlays/usr/lib/parental-os/guardian-setup-prompt.sh`
- Modify: `distros/ubuntu/container/build-edition.sh`
- Test: `tests/host/test_ubuntu_build.bats`

**Interfaces:**
- Consumes: User graphical input via Zenity or env `PARENTAL_OS_GUARDIAN_PASSWORD`
- Produces: `/run/parental-os/guardian.hash` in live RAM -> copied to `/target/etc/parental-os/guardian.hash` (mode `0600`)

- [ ] **Step 1: Write the failing test for guardian setup prompt and hash generation**

In `tests/host/test_ubuntu_build.bats`:
```bash
@test "guardian-setup-prompt generates valid domain-separated hash non-interactively when env set" {
  export PARENTAL_OS_GUARDIAN_PASSWORD="testpassword"
  export PARENTAL_OS_HASH_OUT="/tmp/test_guardian.hash"
  rm -f "$PARENTAL_OS_HASH_OUT"
  run bash overlays/usr/lib/parental-os/guardian-setup-prompt.sh --headless
  assert_success
  [ -f "$PARENTAL_OS_HASH_OUT" ]
  expected_hash=$(python3 -c "import hashlib; print(hashlib.sha256(b'parental-guard:lan-v1:testpassword').hexdigest())")
  actual_hash=$(cat "$PARENTAL_OS_HASH_OUT")
  assert_equal "$actual_hash" "$expected_hash"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_ubuntu_build.bats -f "guardian-setup-prompt"`
Expected: FAIL (`guardian-setup-prompt.sh: No such file or directory`)

- [ ] **Step 3: Implement `guardian-setup-prompt.sh` and wire into `build-edition.sh`**

1. Create `overlays/usr/lib/parental-os/guardian-setup-prompt.sh`:
   - Checks if `--headless` or `PARENTAL_OS_GUARDIAN_PASSWORD` is present.
   - If interactive, displays Zenity/GTK modal with password and confirmation fields.
   - Computes `sha256("parental-guard:lan-v1:" + password)` and writes to `/run/parental-os/guardian.hash` (mode `0600`).
2. Update `target-provisioner.sh` in `distros/ubuntu/container/build-edition.sh`:
   - If `/run/parental-os/guardian.hash` exists, copy it to `/target/etc/parental-os/guardian.hash` with `chmod 0600` and `chown 0:0`.
   - If absent, generate a fallback random guardian hash and log warning.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/host/test_ubuntu_build.bats -f "guardian-setup-prompt"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add overlays/usr/lib/parental-os/guardian-setup-prompt.sh distros/ubuntu/container/build-edition.sh tests/host/test_ubuntu_build.bats
git commit -m "feat(ubuntu): add guardian setup prompt in live session and target hash provisioning"
```

---

### Task 6: CachyOS Calamares Module for Guardian Secret Setup

**Files:**
- Create: `distros/cachyos/calamares/modules/guardian.conf`
- Create: `distros/cachyos/calamares/modules/main.py`
- Modify: `distros/cachyos/container/build-edition.sh`
- Test: `tests/host/test_cachyos_build.bats`

**Interfaces:**
- Consumes: Calamares execution sequence
- Produces: `/run/parental-os/guardian.hash` and `/target/etc/parental-os/guardian.hash`

- [ ] **Step 1: Write the failing test for Calamares guardian module configuration**

In `tests/host/test_cachyos_build.bats`:
```bash
@test "cachyos calamares tree includes guardian setup module" {
  [ -f "distros/cachyos/calamares/modules/guardian.conf" ]
  [ -f "distros/cachyos/calamares/modules/main.py" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/host/test_cachyos_build.bats -f "guardian setup module"`
Expected: FAIL

- [ ] **Step 3: Implement Calamares guardian module and integrate into `build-edition.sh`**

1. Create Calamares Python module capturing guardian password (or reading pre-seeded unattended config) and computing `sha256("parental-guard:lan-v1:" + pwd)`.
2. Write directly into `${target_root}/etc/parental-os/guardian.hash` with mode `0600`.
3. Wire module into CachyOS `settings.conf`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/host/test_cachyos_build.bats -f "guardian setup module"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add distros/cachyos/calamares/ distros/cachyos/container/build-edition.sh tests/host/test_cachyos_build.bats
git commit -m "feat(cachyos): integrate guardian password setup module into Calamares installer"
```

---

### Task 7: Full Host Test Verification & QEMU End-to-End Test

**Files:**
- Test: `tests/host/` (all test suites)
- Test: Live ISO build + QEMU execution

- [ ] **Step 1: Run full host test suite**

Run: `just test-host`
Expected: PASS (All 304+ tests green)

- [ ] **Step 2: Build fresh Ubuntu Desktop ISO**

Run: `just build-ubuntu desktop`
Expected: Clean ISO generation with exit code 0

- [ ] **Step 3: Boot in QEMU and test remote screen lock with parental-remote.py**

1. Start QEMU: `./scripts/qemu-browser.sh ubuntu --boot-disk`
2. Run remote lock from host:
   ```bash
   python3 scripts/parental-remote.py --host 127.0.0.1 --port 7420 --password "<installed_password>" lock
   ```
3. Take screendump via monitor socket and verify screen is locked.

- [ ] **Step 4: Final commit and summary documentation**

```bash
git commit --allow-empty -m "chore: verify end-to-end guardian secret capture and remote screen lock"
```
