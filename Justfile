set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

default:
  @just --list

test-host:
  cd "{{root}}" && bats tests/host

build target="all":
  "{{root}}/scripts/build-all.sh" "{{target}}"

build-ubuntu:
  "{{root}}/scripts/build-ubuntu.sh"

build-cachyos edition="all":
  "{{root}}/scripts/build-cachyos.sh" "{{edition}}"

package-arch:
  "{{root}}/scripts/build-parental-guard-arch.sh"

package-deb:
  "{{root}}/scripts/build-parental-guard-deb.sh"

test-qemu target="all":
  "{{root}}/scripts/test-qemu.sh" "{{target}}"

clean:
  rm -rf "{{root}}/out"/*
  mkdir -p "{{root}}/out/ubuntu" "{{root}}/out/cachyos" "{{root}}/out/packages" "{{root}}/out/logs" "{{root}}/out/qemu"
