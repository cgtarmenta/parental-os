set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

default:
  @just --list

test-host:
  cd "{{root}}" && bats tests/host

build target="all":
  "{{root}}/scripts/build-all.sh" "{{target}}"

build-ubuntu target="all":
  "{{root}}/scripts/build-ubuntu.sh" "{{target}}"

build-cachyos edition="all":
  "{{root}}/scripts/build-cachyos.sh" "{{edition}}"

package-arch:
  "{{root}}/scripts/build-parental-guard-arch.sh"

package-deb:
  "{{root}}/scripts/build-parental-guard-deb.sh"

test-qemu target="all":
  "{{root}}/scripts/test-qemu.sh" "{{target}}"

qemu-browser target="ubuntu":
  "{{root}}/scripts/qemu-browser.sh" "{{target}}"

qemu-browser-down:
  "{{root}}/scripts/qemu-browser.sh" down

clean:
  sudo rm -rf "{{root}}/out"/* 2>/dev/null || rm -rf "{{root}}/out"/* 2>/dev/null || docker --context default run --rm -v "{{root}}/out":/out alpine rm -rf /out/* 2>/dev/null || true
  mkdir -p "{{root}}/out/ubuntu" "{{root}}/out/cachyos" "{{root}}/out/packages" "{{root}}/out/logs" "{{root}}/out/qemu"


test-install target="cachyos-desktop":
  "{{root}}/scripts/test-install.sh" "{{target}}"
