# QEMU Browser Harness Design

## Summary

Add two complementary VM workflows for parental-os ISO validation:

1. A headless automated smoke test that boots generated ISOs with QEMU, injects a NoCloud cloud-init seed, waits for SSH, and runs guardrail assertions inside the live guest.
2. A browser-viewable interactive VM runner that exposes the guest display through noVNC for manual inspection on headless hosts.

The automated path is the primary CI-style validation path. The browser path is for debugging, visual boot verification, and manual exploration when SSH assertions fail or when a live desktop must be inspected.

## Goals

- Make `just test-qemu ubuntu|cachyos|all` functional and fail closed when guest assertions fail.
- Provide a browser-accessible VM workflow similar in spirit to `/home/dat30/winvm-samfw/docker-compose.yml`, but tailored to Linux live ISOs rather than persistent Windows installs.
- Keep generated keys, seed ISOs, VM disks, PID files, and logs under `out/qemu` or `out/logs`.
- Support Ubuntu, CachyOS desktop, and CachyOS handheld artifacts without hardcoding one exact ISO filename.
- Prefer local native QEMU for automated tests and Docker Compose/noVNC for interactive browser access.

## Non-Goals

- Do not implement full OS installation tests in this step. The smoke test validates the live environment produced by the ISO build.
- Do not require USB passthrough. The external Windows VM recipe uses USB passthrough, but parental-os ISO testing does not need it.
- Do not introduce a long-running VM manager or persistent VM lifecycle service.
- Do not replace the existing Docker-based ISO builders.

## Interfaces

### Just Targets

- `just test-qemu target="all"`
  - Calls `scripts/test-qemu.sh`.
  - Valid targets: `ubuntu`, `cachyos-desktop`, `cachyos-handheld`, `cachyos`, `all`.
  - `cachyos` expands to both CachyOS editions.

- `just qemu-browser target="ubuntu"`
  - Calls `scripts/qemu-browser.sh`.
  - Resolves the selected ISO target and starts the browser-viewable VM through Docker Compose.
  - Uses environment variables for VM resources and host bind address/port.

- `just qemu-browser-down`
  - Stops and removes the interactive VM container.

### Scripts

- `scripts/make-cloud-init-seed.sh`
  - Generates `out/qemu/id_ed25519` and `out/qemu/id_ed25519.pub` if missing.
  - Renders `tests/qemu/user-data` with the generated public key.
  - Produces `out/qemu/seed.iso` with volume ID `CIDATA`.
  - Uses `xorriso`, `genisoimage`, or `mkisofs`, in that order.

- `scripts/test-qemu.sh <target>`
  - Resolves the newest ISO for each requested target.
  - Creates an ephemeral qcow2 disk under `out/qemu` for QEMU compatibility.
  - Boots the ISO and cloud-init seed with user-mode networking and a randomized localhost SSH forward.
  - Waits up to a bounded timeout for guest assertions to pass.
  - Always attempts to terminate the QEMU process before exiting.
  - Writes serial output to `out/logs/qemu-<target>.log`.

- `scripts/qemu-browser.sh <target>`
  - Resolves a single ISO target for interactive boot.
  - Generates the cloud-init seed if missing.
  - Exports the resolved ISO path and VM settings for Docker Compose.
  - Prints the noVNC URL after the Compose service starts.

- `tests/qemu/assert_guest.sh <host> <port> <key>`
  - Connects as the QA user over SSH.
  - Verifies parental guard services are active where applicable.
  - Verifies expected users/groups exist.
  - Verifies the QA path can run allowed sudo checks.
  - Verifies guarded commands are denied.
  - Verifies `parental-guard status` and the local agent health endpoint when available.

## ISO Target Resolution

Target resolution is filesystem-based and deterministic:

- `ubuntu`: newest `out/ubuntu/*.iso`.
- `cachyos-desktop`: newest `out/cachyos/desktop/*.iso`.
- `cachyos-handheld`: newest `out/cachyos/handheld/*.iso`.
- `cachyos`: `cachyos-desktop` followed by `cachyos-handheld`.
- `all`: `ubuntu`, `cachyos-desktop`, then `cachyos-handheld`.

If a requested target has no ISO, the script exits with a clear error and does not silently skip it.

## Guest Bootstrap

The smoke test uses NoCloud cloud-init to avoid embedding test credentials in committed files. The seed creates or configures test users, injects the generated SSH key, starts SSH, and starts parental-os services. The checked-in `tests/qemu/user-data` contains a placeholder for the public key only.

The guest bootstrap must handle live-session differences between Ubuntu and CachyOS:

- Ubuntu live images already include `cloud-init`, `openssh-server`, and `qemu-guest-agent`.
- CachyOS images include `cloud-init`, `openssh`, and `qemu-guest-agent` in the built package set.
- Service names may differ by distro. Assertions should prefer distro-neutral checks where possible and include narrow distro branches only where necessary.

## Interactive Browser VM

The browser workflow uses `compose.qemu.yml` plus a small project-owned image built from `distros/qemu-browser/Dockerfile`. The image installs QEMU, noVNC, and websockify from distro packages and runs one Linux live ISO per container. This avoids relying on an unverified third-party VM image while preserving the browser-viewable mechanism used by the external Windows VM recipe.

It mirrors the important parts of the external Windows VM recipe:

- `/dev/kvm` is passed through when available.
- VM resources are controlled by environment variables such as `PARENTAL_OS_QEMU_RAM`, `PARENTAL_OS_QEMU_CPUS`, and `PARENTAL_OS_WEB_PORT`.
- noVNC binds to `${PARENTAL_OS_BIND_IP:-127.0.0.1}:${PARENTAL_OS_WEB_PORT:-8011}` by default to avoid exposing the viewer on every interface.
- The selected ISO is mounted read-only from the host.
- VM state stays under `out/qemu/browser` and is safe to remove.

The default browser mode should be local-only and explicit about the URL it exposes. Operators can override the bind IP for overlay-network access on headless hosts.

## Error Handling

- Missing host commands fail before booting a VM.
- Missing ISOs fail with the target-specific expected output directory.
- If `/dev/kvm` is not readable, automated QEMU falls back to software acceleration with a warning rather than failing immediately.
- SSH timeouts report the serial log path and leave enough diagnostic output to inspect the failed boot.
- Cleanup attempts run on success, failure, and interruption.
- Browser mode does not hide Docker Compose failures; it prints the exact follow-up command for logs.

## Testing Strategy

- Host-level Bats tests cover target parsing, ISO discovery, seed rendering, and command construction where practical without booting a full VM.
- The end-to-end verification is `DOCKER_CONTEXT=default just test-qemu <target>` against available built artifacts.
- Browser mode is verified by starting the Compose service and confirming that the noVNC HTTP endpoint responds on the configured bind/port.

## Security And Safety

- Generated SSH private keys are never committed and remain under `out/qemu`.
- Browser noVNC defaults to `127.0.0.1`, not `0.0.0.0`.
- The interactive VM container receives only the minimum devices needed for virtualization; USB passthrough is intentionally excluded.
- QEMU networking uses host-local forwarded SSH for tests.

## Open Implementation Notes

- Prefer small Bash helpers inside `scripts/test-qemu.sh` until reuse justifies a separate library.
- The first implementation should favor live-boot smoke validation. Installation-to-disk tests can be added later as a separate spec if needed.
- Keep Docker context usage explicit in docs and commands: `DOCKER_CONTEXT=default` remains the expected local invocation when Docker is involved.
