# SP: Ubuntu Desktop LTS LiveCD Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconstruct a genuine **Ubuntu Desktop LiveCD ISO (latest LTS: Noble 24.04 / 26.04)** from official upstream sources, with `parental-guard` integrated into both the live desktop session and the hard disk installer, mirroring the exact architecture and testing harness established for CachyOS.

**Architecture:** Upstream source resolution (`scripts/lib/ubuntu.sh`), deterministic provenance tracking (`provenance.json`), isolated containerized image construction (`distros/ubuntu/container/`), declarative Calamares/live installer overlay transformation (`distros/ubuntu/calamares/apply-parental-overlay.py`), and automated QEMU verification (`test-qemu.sh`, `test-install.sh`).

**Spec:** `docs/superpowers/specs/2026-08-30-multi-distro-reconstruction-framework.md`

---

## File Structure & Responsibilities

| Path | Responsibility |
| :--- | :--- |
| `scripts/lib/ubuntu.sh` | Edition metadata, upstream ref resolution via `git ls-remote`, provenance generation & validation. |
| `scripts/build-ubuntu.sh` | Host-facing driver: resolves refs, checks out staging, builds container, executes containerized build, normalizes artifacts under `out/ubuntu/`. |
| `distros/ubuntu/container/Dockerfile` | Ephemeral builder container based on Ubuntu LTS (`ubuntu:noble`), containing native packaging and ISO generation tools. |
| `distros/ubuntu/container/build-edition.sh` | Container entrypoint: compiles `parental-guard` deb, initializes local apt repo, transforms live profile, runs image build. |
| `distros/ubuntu/calamares/apply-parental-overlay.py` | Idempotent, fail-closed transformer for the installer config on Ubuntu (target package injection, service enablement, sudoers/polkit/PAM drop-ins, and repo cleanup). |
| `distros/ubuntu/calamares/unattended/` | Throwaway unattended install config tree (`settings.conf`, `partition.conf`, `finished.conf`) for automated QEMU installation tests. |
| `tests/host/test_ubuntu_build.bats` | Host-level BATS unit & contract tests validating Ubuntu metadata, provenance, builder container, and overlay transformer. |

---

## Task 1: Ubuntu Upstream Metadata, Provenance & Validation Library

**Files:**
- Create: `scripts/lib/ubuntu.sh`
- Test: `tests/host/test_ubuntu_build.bats`

- [x] **Step 1: Write failing host tests for `scripts/lib/ubuntu.sh`**
  Assert:
  - `ubuntu_edition_metadata desktop` emits expected keys: `live_iso_url`, `live_iso_branch`, `calamares_url`, `calamares_branch`, `iso_basename`, `architecture`.
  - `ubuntu_metadata_value` extracts keys correctly and fails closed on unknown keys.
  - `ubuntu_validate_sha` enforces 40-character hexadecimal regex.
  - `ubuntu_provenance_write` produces valid JSON conforming to the framework schema.
  - `ubuntu_provenance_validate` verifies presence of all required fields.

- [x] **Step 2: Implement `scripts/lib/ubuntu.sh`**
  Implement the metadata definitions pointing to the official Ubuntu Desktop live/Calamares upstream repositories (e.g. `https://github.com/lubuntu-team/calamares-settings-ubuntu.git`), SHA resolution via `git ls-remote`, and provenance helpers.

- [x] **Step 3: Run BATS tests**
  ```bash
  bats tests/host/test_ubuntu_build.bats
  ```
  Ensure all tests pass.

- [x] **Step 4: Commit**
  ```bash
  git add scripts/lib/ubuntu.sh tests/host/test_ubuntu_build.bats
  git commit -m "feat(ubuntu): add upstream metadata, provenance, and validation library"
  ```

---

## Task 2: Ubuntu Builder Container Environment

**Files:**
- Create: `distros/ubuntu/container/Dockerfile`
- Test: `tests/host/test_ubuntu_build.bats`

- [x] **Step 1: Write tests asserting container contract**
  Assert:
  - `distros/ubuntu/container/Dockerfile` exists.
  - Base image is `ubuntu:noble` (or latest LTS).
  - Installs required packaging and image tools: `debootstrap`, `squashfs-tools`, `xorriso`, `mtools`, `dosfstools`, `dpkg-dev`, `debhelper`.

- [x] **Step 2: Implement Dockerfile**
  Create `distros/ubuntu/container/Dockerfile` with minimal, reproducible dependencies.

- [x] **Step 3: Validate Docker build**
  ```bash
  docker --context default build -t parental-os-ubuntu-builder:latest distros/ubuntu/container
  ```

- [x] **Step 4: Commit**
  ```bash
  git add distros/ubuntu/container/Dockerfile tests/host/test_ubuntu_build.bats
  git commit -m "feat(ubuntu): create ephemeral builder container Dockerfile"
  ```

---

## Task 3: Calamares Parental Overlay Transformer for Ubuntu

**Files:**
- Create: `distros/ubuntu/calamares/apply-parental-overlay.py`
- Test: `tests/host/test_ubuntu_build.bats`

- [x] **Step 1: Write failing tests for the Ubuntu Calamares transformer**
  Assert:
  - `apply-parental-overlay.py` is executable and valid Python 3.
  - Injects `parental-guard` deb package installation into the target chroot post-install scripts.
  - Enables `parental-guard.service`, `parental-guard-agent.service`, `parental-guard-enroll.service`, `parental-guard-enroll.path` in `services-systemd.conf`.
  - Configures PAM account gate in `/etc/pam.d/common-account`.
  - Installs cleanup hook to remove temporary local apt repositories from the target system.

- [x] **Step 2: Implement `apply-parental-overlay.py`**
  Implement the fail-closed transformer adapted for Ubuntu's Calamares module layout and debian packaging paths.

- [x] **Step 3: Run BATS tests**
  ```bash
  bats tests/host/test_ubuntu_build.bats
  ```

- [x] **Step 4: Commit**
  ```bash
  git add distros/ubuntu/calamares/apply-parental-overlay.py tests/host/test_ubuntu_build.bats
  git commit -m "feat(ubuntu): implement Calamares parental overlay transformer"
  ```

---

## Task 4: Ubuntu Build Driver & Container Entrypoint

**Files:**
- Create: `distros/ubuntu/container/build-edition.sh`
- Create: `scripts/build-ubuntu.sh`
- Test: `tests/host/test_ubuntu_build.bats`

- [x] **Step 1: Write failing tests for build driver**
  Assert:
  - `scripts/build-ubuntu.sh` resolves upstream refs, writes provenance to `out/ubuntu/desktop/provenance.json`, checks out staging repos, and launches the builder container with private mount propagation.
  - `distros/ubuntu/container/build-edition.sh` builds `parental-guard_0.1.0-1_all.deb`, sets up local repo, applies transformer, and runs image generation.

- [x] **Step 2: Implement `distros/ubuntu/container/build-edition.sh` and `scripts/build-ubuntu.sh`**
  Implement complete build orchestration matching the CachyOS pattern.

- [x] **Step 3: Test host script syntax and contracts**
  ```bash
  bats tests/host/test_ubuntu_build.bats
  ```

- [x] **Step 4: Commit**
  ```bash
  git add distros/ubuntu/container/build-edition.sh scripts/build-ubuntu.sh tests/host/test_ubuntu_build.bats
  git commit -m "feat(ubuntu): implement host build driver and containerized build entrypoint"
  ```

---

## Task 5: Unattended Installer Configuration & QEMU Integration

**Files:**
- Create: `distros/ubuntu/calamares/unattended/settings.conf`
- Create: `distros/ubuntu/calamares/unattended/modules/partition.conf`
- Create: `distros/ubuntu/calamares/unattended/modules/finished.conf`
- Modify: `scripts/test-install.sh`
- Modify: `tests/qemu/assert_target.sh`
- Test: `tests/host/test_unattended_install.bats`

- [x] **Step 1: Write tests for unattended install tree**
  Assert:
  - `distros/ubuntu/calamares/unattended/settings.conf` enables `autoProceed` per show step and sets `quit-at-end: true`.
  - `partition.conf` selects erase partitioning.
  - `finished.conf` executes poweroff as success oracle.

- [x] **Step 2: Implement unattended configuration files**
  Create the test-only configuration files.

- [x] **Step 3: Update `scripts/test-install.sh` and target assertions**
  Ensure `just test-install ubuntu` drives the unattended installation and executes `assert_target.sh` over SSH on the installed system.

- [x] **Step 4: Run full host test suite**
  ```bash
  just test-host
  ```
  Ensure all tests pass.

- [x] **Step 5: Commit**
  ```bash
  git add distros/ubuntu/calamares/unattended/ scripts/test-install.sh tests/qemu/assert_target.sh tests/host/
  git commit -m "feat(ubuntu): add unattended install config and target assertion harness"
  ```
