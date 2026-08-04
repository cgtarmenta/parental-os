#!/usr/bin/env bats
# Contract tests for Task 9: Ubuntu-family live-build image pipeline.

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  export PARENTAL_OS_OUT="$(mktemp -d)/out"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/common.sh"
}

teardown() {
  rm -rf "$(dirname "$PARENTAL_OS_OUT")"
}

function ubuntu_live_build_dockerfile_exists_and_installs_required_tools { # @test
  f="$TEST_ROOT/distros/ubuntu/docker/Dockerfile"
  [[ -f "$f" ]]
  grep -q 'live-build' "$f"
  grep -q 'live-boot' "$f"
  grep -q 'live-config' "$f"
  grep -q 'live-tools' "$f"
  grep -q 'debootstrap' "$f"
  grep -q 'squashfs-tools' "$f"
  grep -q 'xorriso' "$f"
  grep -q 'curl' "$f"
  grep -q 'gnupg' "$f"
  grep -q 'fdisk' "$f"
}

function ubuntu_auto_config_is_executable_and_configures_amd64_iso_hybrid_image { # @test
  f="$TEST_ROOT/distros/ubuntu/auto/config"
  [[ -f "$f" ]]
  [[ -x "$f" ]]
  grep -q 'lb config noauto' "$f"
  grep -Eq -- '--architectures[[:space:]]+amd64' "$f"
  grep -Eq -- '--binary-images[[:space:]]+iso-hybrid' "$f"
  grep -q 'bootappend-live' "$f"
  grep -q 'username=child' "$f"
  grep -q 'hostname=parental-os' "$f"
}

function ubuntu_package_list_includes_desktop_baseline_and_vm_remote_support { # @test
  f="$TEST_ROOT/distros/ubuntu/config/package-lists/parental-os.list.chroot"
  [[ -f "$f" ]]
  grep -qx 'sudo' "$f"
  grep -qx 'python3' "$f"
  grep -qx 'policykit-1' "$f"
  grep -qx 'openssh-server' "$f"
  grep -qx 'cloud-init' "$f"
  grep -qx 'qemu-guest-agent' "$f"
}

function ubuntu_chroot_hook_installs_local_deb_and_seeds_parental_controls { # @test
  f="$TEST_ROOT/distros/ubuntu/config/hooks/normal/9000-parental-os.hook.chroot"
  [[ -f "$f" ]]
  [[ -x "$f" ]]
  grep -Eq 'dpkg[[:space:]]+-i' "$f"
  grep -Eq 'parental-guard_.*\.deb' "$f"
  grep -Eq 'groupadd.*parental-users|addgroup.*parental-users' "$f"
  grep -q 'parental-guard.service' "$f"
  grep -q 'parental-guard-agent.service' "$f"
  grep -Eq 'systemctl[[:space:]]+enable' "$f"
  grep -q 'user-setup' "$f"
  grep -q 'child' "$f"
}

function build_ubuntu_sh_builds_deb_first_and_uses_common_out_helpers { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  [[ -f "$f" ]]
  grep -q 'scripts/lib/common.sh' "$f"
  grep -q 'ensure_out_dirs' "$f"
  grep -q 'out_root' "$f"
  grep -q 'build-parental-guard-deb.sh' "$f"
}

function build_ubuntu_sh_uses_docker_cli_build_run_without_raw_docker_build_run { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Fq 'docker_cli build' "$f"
  grep -Fq 'docker_cli run' "$f"
  ! grep -Eq '(^|[[:space:]])docker[[:space:]]+(build|run)([[:space:]]|$)' "$f"
}

function build_ubuntu_sh_builds_docker_context_from_distros_ubuntu_docker { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -q 'distros/ubuntu/docker' "$f"
  ! grep -Eq 'docker_cli build.*"\$ROOT"' "$f"
}

function build_ubuntu_sh_stages_live_build_tree_under_out_ubuntu_lb { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -q 'out/ubuntu/lb' "$f"
  grep -q 'LB_DIR=' "$f"
}

function build_ubuntu_sh_stages_deb_into_live_build_config { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -q 'config/includes.chroot' "$f"
  grep -Eq 'parental-guard_\*\.deb|parental-guard_.*\.deb' "$f"
}

function build_ubuntu_sh_runs_live_build_privileged_and_writes_build_log { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -q -- '--privileged' "$f"
  grep -q 'out/logs/build-ubuntu.log' "$f"
  grep -q 'tee' "$f"
}

function build_ubuntu_sh_runs_lb_config_before_lb_build { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -q 'lb config' "$f"
  config_line="$(grep -n 'lb config' "$f" | cut -d: -f1 | head -n1)"
  build_line="$(grep -n 'lb build' "$f" | cut -d: -f1 | head -n1)"
  [[ -n "$config_line" ]]
  [[ -n "$build_line" ]]
  [ "$config_line" -lt "$build_line" ]
}

function build_ubuntu_sh_copies_generated_iso_artifacts_to_out_ubuntu { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Eq 'cp .*\.iso' "$f"
  grep -q 'out/ubuntu' "$f"
}

function build_ubuntu_sh_generates_portable_basename_checksums { # @test
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Eq '\(cd "\$OUT/ubuntu" && sha256sum "\$\(basename "\$iso"\)"\)' "$f"
  ! grep -Eq 'sha256sum "\$OUT/ubuntu/' "$f"
}

skip_if_no_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker_cli info >/dev/null 2>&1 \
    || skip "docker context $DOCKER_CONTEXT is unavailable"
}

function docker_build_succeeds_for_the_ubuntu_live_build_image { # @test
  skip_if_no_docker
  f="$TEST_ROOT/distros/ubuntu/docker/Dockerfile"
  [[ -f "$f" ]]
  run docker_cli build \
    -t parental-os-ubuntu-live-builder:test "$TEST_ROOT/distros/ubuntu/docker"
  [ "$status" -eq 0 ]
}

function docker_lb_config_smoke_has_no_missing_fdisk_warning { # @test
  skip_if_no_docker
  run docker_cli build \
    -t parental-os-ubuntu-live-builder:test "$TEST_ROOT/distros/ubuntu/docker"
  [ "$status" -eq 0 ]

  run docker_cli run --rm \
    --mount type=bind,source="$TEST_ROOT/distros/ubuntu/auto",destination=/tmp/parental-auto,readonly \
    parental-os-ubuntu-live-builder:test \
    bash -lc 'set -euo pipefail; mkdir -p /tmp/lb/auto; cp -a /tmp/parental-auto/. /tmp/lb/auto/; cd /tmp/lb; output="$(auto/config 2>&1)"; printf "%s\n" "$output"; ! printf "%s\n" "$output" | grep -q "Can'"'"'t process file /sbin/fdisk"; test -d config'
  [ "$status" -eq 0 ]
}
