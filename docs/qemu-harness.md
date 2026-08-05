# QEMU Harness

The QEMU harness supports two local validation modes:

- Headless smoke tests that boot installer images, wait for SSH, and run guest assertions.
- A browser VM that exposes a noVNC console for interactive testing.

On this host, run Docker-backed commands with `DOCKER_CONTEXT=default`.

## Headless Smoke Tests

Run the headless QEMU smoke tests with a specific target or with all supported targets:

```sh
DOCKER_CONTEXT=default just test-qemu ubuntu
DOCKER_CONTEXT=default just test-qemu cachyos-desktop
DOCKER_CONTEXT=default just test-qemu cachyos-handheld
DOCKER_CONTEXT=default just test-qemu all
```

Generated QEMU artifacts are written under `out/qemu`, including generated SSH keys, cloud-init seed media, qcow2 disks, and pidfiles. Serial logs are written under `out/logs`.

The headless runner supports these environment variables:

| Variable | Purpose |
|----------|---------|
| `PARENTAL_OS_QEMU_RAM` | RAM allocated to each VM. |
| `PARENTAL_OS_QEMU_CPUS` | vCPU count allocated to each VM. |
| `PARENTAL_OS_QEMU_SSH_PORT_BASE` | Base localhost SSH port used for forwarded guest SSH. |
| `PARENTAL_OS_QEMU_ATTEMPTS` | Number of guest assertion attempts before failing. |
| `PARENTAL_OS_QEMU_SLEEP_SECONDS` | Delay between guest assertion attempts. |

## Browser VM

Start an interactive browser VM for a target:

```sh
DOCKER_CONTEXT=default just qemu-browser ubuntu
```

By default, the noVNC console is available at:

```text
http://127.0.0.1:8011/vnc.html
```

Stop the browser VM with:

```sh
DOCKER_CONTEXT=default just qemu-browser-down
```

Target-specific browser VM state is stored under `out/qemu/browser/<target>`.

The browser VM supports these environment variables:

| Variable | Purpose |
|----------|---------|
| `PARENTAL_OS_BIND_IP` | IP address for the noVNC and browser SSH bind. |
| `PARENTAL_OS_WEB_PORT` | noVNC web port. |
| `PARENTAL_OS_BROWSER_SSH_PORT` | Host port forwarded to guest SSH. |
| `PARENTAL_OS_QEMU_RAM` | RAM allocated to the VM. |
| `PARENTAL_OS_QEMU_CPUS` | vCPU count allocated to the VM. |
| `PARENTAL_OS_QEMU_DISK_SIZE` | Browser VM qcow2 disk size. |

## Security

noVNC binds to `127.0.0.1` by default. Only set `PARENTAL_OS_BIND_IP` to a remote or overlay network address intentionally, because that can expose the VM console and forwarded SSH port beyond the local host.
