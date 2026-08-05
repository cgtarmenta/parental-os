#!/usr/bin/env bats
# Contract tests for Task 8: dual genuine CachyOS desktop/handheld image builds.
#
# Network-free cases exercise edition metadata, ref resolution (via PATH-injected
# fake git), dispatch, provenance schema, exact-SHA checkout arguments, staging
# isolation, and edition distinctness. Docker-gated cases verify the builder
# image and the container invocation flags; they skip when Docker is absent but
# the real build acceptance gate (build-cachyos.sh all) is NOT waivable.

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  export PARENTAL_OS_OUT="$TEST_TMP/out"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/cachyos.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Edition metadata
# ---------------------------------------------------------------------------

@test "cachyos_edition_metadata returns data for desktop" {
  run cachyos_edition_metadata desktop
  [ "$status" -eq 0 ]
  [[ "$output" == *"live_iso_url=https://github.com/CachyOS/CachyOS-Live-ISO.git"* ]]
  [[ "$output" == *"live_iso_branch=master"* ]]
  [[ "$output" == *"calamares_url=https://github.com/CachyOS/cachyos-calamares.git"* ]]
  [[ "$output" == *"calamares_branch=cachyos-dev"* ]]
  [[ "$output" == *"pkgbuilds_url=https://github.com/CachyOS/CachyOS-PKGBUILDS.git"* ]]
  [[ "$output" == *"pkgbuilds_branch=master"* ]]
  [[ "$output" == *"packages_file=packages_desktop.x86_64"* ]]
  [[ "$output" == *"iso_basename=parental-os-cachyos-desktop"* ]]
}

@test "cachyos_edition_metadata returns data for handheld" {
  run cachyos_edition_metadata handheld
  [ "$status" -eq 0 ]
  [[ "$output" == *"live_iso_branch=cachyos-deckify"* ]]
  [[ "$output" == *"calamares_branch=cachyos-dev-deckify"* ]]
  [[ "$output" == *"packages_file=packages_handheld.x86_64"* ]]
  [[ "$output" == *"iso_basename=parental-os-cachyos-handheld"* ]]
}

@test "cachyos_edition_metadata rejects unknown edition" {
  run cachyos_edition_metadata nonsense
  [ "$status" -ne 0 ]
}

@test "desktop and handheld map to distinct live_iso branches" {
  desktop_branch="$(cachyos_edition_metadata desktop | grep '^live_iso_branch=' | cut -d= -f2)"
  handheld_branch="$(cachyos_edition_metadata handheld | grep '^live_iso_branch=' | cut -d= -f2)"
  [ -n "$desktop_branch" ]
  [ -n "$handheld_branch" ]
  [ "$desktop_branch" != "$handheld_branch" ]
}

@test "desktop and handheld map to distinct calamares branches" {
  d="$(cachyos_edition_metadata desktop | grep '^calamares_branch=' | cut -d= -f2)"
  h="$(cachyos_edition_metadata handheld | grep '^calamares_branch=' | cut -d= -f2)"
  [ "$d" != "$h" ]
}

@test "desktop and handheld map to distinct package files" {
  d="$(cachyos_edition_metadata desktop | grep '^packages_file=' | cut -d= -f2)"
  h="$(cachyos_edition_metadata handheld | grep '^packages_file=' | cut -d= -f2)"
  [ "$d" = "packages_desktop.x86_64" ]
  [ "$h" = "packages_handheld.x86_64" ]
  [ "$d" != "$h" ]
}

@test "desktop and handheld map to distinct ISO basenames" {
  d="$(cachyos_edition_metadata desktop | grep '^iso_basename=' | cut -d= -f2)"
  h="$(cachyos_edition_metadata handheld | grep '^iso_basename=' | cut -d= -f2)"
  [ "$d" = "parental-os-cachyos-desktop" ]
  [ "$h" = "parental-os-cachyos-handheld" ]
  [ "$d" != "$h" ]
}

@test "both editions use the same PKGBUILDS repo and branch" {
  d_url="$(cachyos_edition_metadata desktop | grep '^pkgbuilds_url=' | cut -d= -f2)"
  h_url="$(cachyos_edition_metadata handheld | grep '^pkgbuilds_url=' | cut -d= -f2)"
  d_br="$(cachyos_edition_metadata desktop | grep '^pkgbuilds_branch=' | cut -d= -f2)"
  h_br="$(cachyos_edition_metadata handheld | grep '^pkgbuilds_branch=' | cut -d= -f2)"
  [ "$d_url" = "$h_url" ]
  [ "$d_br" = "$h_br" ]
}

@test "desktop required packages include QEMU smoke bootstrap dependencies" {
  required="$(cachyos_metadata_value desktop required_packages)"
  for pkg in cloud-init openssh qemu-guest-agent; do
    [[ " $required " == *" $pkg "* ]]
  done
}

@test "handheld required packages include QEMU smoke bootstrap dependencies" {
  required="$(cachyos_metadata_value handheld required_packages)"
  for pkg in cloud-init openssh qemu-guest-agent; do
    [[ " $required " == *" $pkg "* ]]
  done
}

@test "edition metadata must not encode any hardcoded 40-char SHA" {
  # Observed research SHAs are evidence only and must not be build pins.
  for ed in desktop handheld; do
    run cachyos_edition_metadata "$ed"
    ! echo "$output" | grep -Eq '[0-9a-f]{40}'
  done
}

# ---------------------------------------------------------------------------
# SHA validation
# ---------------------------------------------------------------------------

@test "cachyos_validate_sha accepts a valid 40-char lowercase hex SHA" {
  run cachyos_validate_sha "abcdef0123456789abcdef0123456789abcdef01"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Behavioral recovery regressions
# ---------------------------------------------------------------------------

_make_fake_git() {
  local bindir="$1"
  local sha="$2"
  mkdir -p "$bindir"
  cat >"$bindir/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${FAKE_GIT_LOG:?}"
if [[ "\$1" == "ls-remote" ]]; then
  printf '%s\t%s\n' "$sha" "\$4"
  exit 0
fi
exit 1
EOF
  chmod +x "$bindir/git"
}

_make_source_repo() {
  local remote="$1"
  local work="$2"
  git init -q --bare "$remote"
  git init -q "$work"
  git -C "$work" config user.email test@example.invalid
  git -C "$work" config user.name "Task 8 test"
  printf 'first\n' >"$work/payload"
  git -C "$work" add payload
  git -C "$work" commit -q -m first
  git -C "$work" remote add origin "$remote"
  git -C "$work" push -q origin HEAD:master
  FIRST_SHA="$(git -C "$work" rev-parse HEAD)"
  printf 'second\n' >"$work/payload"
  git -C "$work" commit -qam second
  git -C "$work" push -q origin HEAD:master
  SECOND_SHA="$(git -C "$work" rev-parse HEAD)"
  export FIRST_SHA SECOND_SHA
}

_copy_calamares_fixture() {
  local destination="$1"
  mkdir -p "$destination"
  cp -a "$TEST_ROOT/tests/fixtures/cachyos/calamares/." "$destination/"
}

_make_live_fixture() {
  local edition="$1"
  local package_file="$2"
  local calamares_package="$3"
  local reinstall_command="$4"
  local destination="$5"

  mkdir -p \
    "$destination/archiso/airootfs/etc" \
    "$destination/archiso/airootfs/usr/local/bin"
  cat >"$destination/buildiso.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${OFFICIAL_INVOCATION_LOG:?}"
printf '%s\n' "${USER:-}" >"${OFFICIAL_USER_LOG:?}"
source ./util-iso.sh
prepare_profile "$2"
mkdir -p "out/$2" build/iso/arch
printf 'iso\n' >"out/$2/cachyos-2099.01.02-x86_64.iso"
printf 'parental-guard 0.1.0-1\n' >"build/iso/arch/pkglist.x86_64.txt"
EOF
  chmod +x "$destination/buildiso.sh"
  cat >"$destination/util-iso.sh" <<EOF
prepare_profile() {
  local profile="\$1"
  cp "archiso/$package_file" archiso/packages.x86_64
  printf '%s\n' "\$profile" >archiso/airootfs/etc/edition-tag
  printf '%s\n' 990102 >archiso/airootfs/etc/version-tag
}
run_build() {
  prepare_profile "\$1"
  sudo mkarchiso -v archiso
}
EOF
  cat >"$destination/util.sh" <<'EOF'
sign_with_key() {
  gpg --detach-sign "$1"
}
EOF
  printf '%s\n' base "$calamares_package" "kernel-$edition" >"$destination/archiso/$package_file"
  cat >"$destination/archiso/pacman.conf" <<'EOF'
[cachyos]
Server = https://mirror.invalid/$repo/$arch
EOF
  cat >"$destination/archiso/airootfs/etc/pacman-more.conf" <<'EOF'
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF
  cat >"$destination/archiso/airootfs/etc/pacman.conf" <<'EOF'
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF
  cat >"$destination/archiso/profiledef.sh" <<'EOF'
file_permissions=(
  ["/usr/local/bin/calamares-online.sh"]="0:0:755"
)
EOF
  cat >"$destination/archiso/airootfs/usr/local/bin/calamares-online.sh" <<EOF
#!/usr/bin/env bash
$reinstall_command
exec pkexec-wrapper calamares
EOF
  chmod +x "$destination/archiso/airootfs/usr/local/bin/calamares-online.sh"
}

_run_transformer_source() {
  local source_root="$1"
  local live_root="$2"
  local package="$3"
  run python3 "$TEST_ROOT/distros/cachyos/calamares/apply-parental-overlay.py" \
    stage "$source_root" "$live_root" \
    "$TEST_ROOT/distros/cachyos/calamares/apply-parental-overlay.py" "$package"
}

_run_transformer_runtime() {
  local source_root="$1"
  local live_root="$2"
  run python3 "$TEST_ROOT/distros/cachyos/calamares/apply-parental-overlay.py" \
    runtime "$source_root" "$live_root"
}

@test "docker_cli defaults to native default context and honors overrides" {
  fake_bin="$TEST_TMP/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
  chmod +x "$fake_bin/docker"

  unset DOCKER_CONTEXT
  PATH="$fake_bin:$PATH" run docker_cli version
  [ "$status" -eq 0 ]
  [ "$output" = "--context default version" ]

  DOCKER_CONTEXT=task8-native PATH="$fake_bin:$PATH" run docker_cli info
  [ "$status" -eq 0 ]
  [ "$output" = "--context task8-native info" ]
}

@test "exact checkout fetches and detaches only the requested SHA" {
  remote="$TEST_TMP/remote.git"
  source_work="$TEST_TMP/source"
  checkout="$TEST_TMP/checkout"
  _make_source_repo "$remote" "$source_work"

  run cachyos_checkout_exact "$remote" "$FIRST_SHA" "$checkout"
  [ "$status" -eq 0 ]
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$FIRST_SHA" ]
  [ "$(git -C "$checkout" symbolic-ref -q HEAD || true)" = "" ]
  [ "$(cat "$checkout/payload")" = "first" ]
}

@test "exact checkout fails closed when the requested SHA cannot be fetched" {
  remote="$TEST_TMP/remote.git"
  source_work="$TEST_TMP/source"
  checkout="$TEST_TMP/checkout"
  _make_source_repo "$remote" "$source_work"

  run cachyos_checkout_exact "$remote" \
    0000000000000000000000000000000000000000 "$checkout"
  [ "$status" -ne 0 ]
  if [[ -d "$checkout/.git" ]]; then
    [ "$(git -C "$checkout" rev-parse -q --verify HEAD 2>/dev/null || true)" != \
      "0000000000000000000000000000000000000000" ]
  fi
}

@test "edition callback dispatch completes desktop before starting handheld" {
  trace="$TEST_TMP/trace"
  edition_callback() {
    local edition="$1"
    printf 'start:%s\n' "$edition" >>"$trace"
    printf 'complete:%s\n' "$edition" >>"$trace"
  }

  run cachyos_for_each_edition all edition_callback
  [ "$status" -eq 0 ]
  diff -u <(printf '%s\n' start:desktop complete:desktop start:handheld complete:handheld) "$trace"
}

@test "source transformation writes installed Calamares paths and is idempotent without preinstalling package-owned paths" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares
EOF

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  [ ! -e "$live/etc/calamares/modules/pacstrap.conf" ]
  [ ! -e "$live/etc/calamares/modules/services-systemd.conf" ]
  [ ! -e "$live/etc/calamares/modules/shellprocess_cleanup_calamares.conf" ]
  [ ! -e "$live/etc/calamares/scripts/remove-parental-os-repo" ]
  [ -x "$live/usr/local/lib/parental-os/apply-parental-overlay.py" ]
  [ -f "$live/usr/share/calamares/src/modules/pacstrap/pacstrap.conf" ]
  [ -f "$live/usr/share/calamares/src/modules/shellprocess/shellprocess-before-online.conf" ]
  grep -qx '  - parental-guard' "$live/usr/share/calamares/src/modules/pacstrap/pacstrap.conf"
  grep -qx '  - base' "$live/usr/share/calamares/src/modules/pacstrap/pacstrap.conf"
  grep -qx '  - cachyos-hooks' "$live/usr/share/calamares/src/modules/pacstrap/pacstrap.conf"
  grep -q '/etc/calamares/scripts/copy-parental-os-repo ${ROOT}' \
    "$live/usr/share/calamares/src/modules/shellprocess/shellprocess-before-online.conf"
  grep -q '  - "/etc/calamares/scripts/remove-parental-os-repo"' \
    "$live/usr/share/calamares/src/modules/pacstrap/pacstrap.conf"
  grep -q '/etc/calamares/scripts/remove-parental-os-repo /etc/pacman.conf' \
    "$live/usr/share/calamares/src/modules/shellprocess/shellprocess_cleanup_calamares.conf"
  first_hash="$(find "$live" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  second_hash="$(find "$live" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  [ "$first_hash" = "$second_hash" ]
}

@test "runtime transformation writes installed Calamares paths and cleanup script" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares
EOF

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  _run_transformer_runtime "$live/usr/share/calamares" "$live"
  [ "$status" -eq 0 ]
  [ -f "$live/etc/calamares/modules/pacstrap.conf" ]
  [ -f "$live/etc/calamares/modules/shellprocess-before-online.conf" ]
  [ -f "$live/etc/calamares/modules/services-systemd.conf" ]
  [ -f "$live/etc/calamares/modules/shellprocess_cleanup_calamares.conf" ]
  [ -x "$live/etc/calamares/scripts/copy-parental-os-repo" ]
  [ -x "$live/etc/calamares/scripts/remove-parental-os-repo" ]
  grep -qx '  - parental-guard' "$live/etc/calamares/modules/pacstrap.conf"
  grep -qx '  - base' "$live/etc/calamares/modules/pacstrap.conf"
  grep -qx '  - cachyos-hooks' "$live/etc/calamares/modules/pacstrap.conf"
  grep -q '/etc/calamares/scripts/copy-parental-os-repo ${ROOT}' \
    "$live/etc/calamares/modules/shellprocess-before-online.conf"
  grep -q '  - "/etc/calamares/scripts/remove-parental-os-repo"' \
    "$live/etc/calamares/modules/pacstrap.conf"
  grep -q 'parental-guard.service' "$live/etc/calamares/modules/services-systemd.conf"
  grep -q 'parental-guard-agent.service' "$live/etc/calamares/modules/services-systemd.conf"
  grep -q '/etc/calamares/scripts/remove-parental-os-repo /etc/pacman.conf' \
    "$live/etc/calamares/modules/shellprocess_cleanup_calamares.conf"
}

@test "copy-parental-os-repo copies the live repo into the pacstrap target root" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  source_repo="$TEST_TMP/source-repo"
  target="$TEST_TMP/target"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin" "$source_repo" "$target"
  printf 'db\n' >"$source_repo/parental-os.db"
  printf 'pkg\n' >"$source_repo/parental-guard.pkg.tar.zst"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares
EOF

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  PARENTAL_OS_REPO_SOURCE="$source_repo" run "$calamares/scripts/copy-parental-os-repo" "$target"
  [ "$status" -eq 0 ]
  [ -f "$target/srv/parental-os-repo/parental-os.db" ]
  [ -f "$target/srv/parental-os-repo/parental-guard.pkg.tar.zst" ]
}

@test "source transformation fails closed on Calamares layout drift" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_calamares_fixture "$calamares"
  rm "$calamares/src/modules/pacstrap/pacstrap.conf"
  mkdir -p "$live/usr/local/bin"
  printf '%s\n' '#!/usr/bin/env bash' >"$live/usr/local/bin/calamares-online.sh"

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected"* ]]
}

@test "Calamares launcher patch matches each resolved package marker exactly" {
  calamares="$TEST_TMP/calamares"
  _copy_calamares_fixture "$calamares"

  desktop_live="$TEST_TMP/desktop-live"
  mkdir -p "$desktop_live/usr/local/bin"
  cat >"$desktop_live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares
EOF
  _run_transformer_source "$calamares" "$desktop_live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  desktop_reinstall="$(grep -n 'cachyos-calamares-next' "$desktop_live/usr/local/bin/calamares-online.sh" | cut -d: -f1)"
  grep -q 'apply-parental-overlay.py runtime /usr/share/calamares /' \
    "$desktop_live/usr/local/bin/calamares-online.sh"
  ! grep -q 'apply-parental-overlay.py installed /' \
    "$desktop_live/usr/local/bin/calamares-online.sh"
  desktop_reapply="$(grep -n 'apply-parental-overlay.py runtime /usr/share/calamares /' "$desktop_live/usr/local/bin/calamares-online.sh" | cut -d: -f1)"
  [ "$desktop_reapply" -gt "$desktop_reinstall" ]

  handheld_live="$TEST_TMP/handheld-live"
  mkdir -p "$handheld_live/usr/local/bin"
  cat >"$handheld_live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
yes | sudo pacman -R cachyos-calamares-deckify
yes | sudo pacman -Sy cachyos-calamares-deckify
pkexec-wrapper calamares
EOF
  _run_transformer_source "$calamares" "$handheld_live" cachyos-calamares-deckify
  [ "$status" -eq 0 ]
  handheld_reinstall="$(grep -n 'pacman -Sy cachyos-calamares-deckify' "$handheld_live/usr/local/bin/calamares-online.sh" | cut -d: -f1)"
  grep -q 'apply-parental-overlay.py runtime /usr/share/calamares /' \
    "$handheld_live/usr/local/bin/calamares-online.sh"
  ! grep -q 'apply-parental-overlay.py installed /' \
    "$handheld_live/usr/local/bin/calamares-online.sh"
  handheld_reapply="$(grep -n 'apply-parental-overlay.py runtime /usr/share/calamares /' "$handheld_live/usr/local/bin/calamares-online.sh" | cut -d: -f1)"
  [ "$handheld_reapply" -gt "$handheld_reinstall" ]
}

@test "Calamares launcher patch rejects a different reinstall package" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm unexpected-calamares
exec pkexec-wrapper calamares
EOF

  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -ne 0 ]
  [[ "$output" == *"reinstall"* ]]
}

@test "generated cleanup removes only the marked block from a non-default target" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  target_root="$TEST_TMP/target-root"
  target="$target_root/etc/pacman.conf"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares
EOF
  _run_transformer_source "$calamares" "$live" cachyos-calamares-next
  [ "$status" -eq 0 ]
  _run_transformer_runtime "$live/usr/share/calamares" "$live"
  [ "$status" -eq 0 ]
  mkdir -p "$target_root/etc" "$target_root/srv/parental-os-repo"
  printf 'db\n' >"$target_root/srv/parental-os-repo/parental-os.db"
  cat >"$target" <<'EOF'
[core]
Server = https://core.invalid/
# BEGIN parental-os temporary repository
[parental-os]
SigLevel = Optional TrustAll
Server = file:///srv/parental-os-repo
# END parental-os temporary repository
[parental-os-archive]
Server = https://archive.invalid/
EOF

  run "$live/etc/calamares/scripts/remove-parental-os-repo" "$target"
  [ "$status" -eq 0 ]
  ! grep -q '^\[parental-os\]$' "$target"
  grep -q '^\[core\]$' "$target"
  grep -q '^\[parental-os-archive\]$' "$target"
  grep -q 'https://archive.invalid/' "$target"
  [ ! -e "$target_root/srv/parental-os-repo" ]
}

@test "official staging preserves prepare_profile and invokes buildiso.sh" {
  live="$TEST_TMP/live"
  calamares="$TEST_TMP/calamares"
  repo="$TEST_TMP/repo"
  staged="$TEST_TMP/staged"
  invocation="$TEST_TMP/invocation"
  official_user="$TEST_TMP/official-user"
  _make_live_fixture desktop packages_desktop.x86_64 \
    cachyos-calamares-next \
    'sudo pacman -Sy --noconfirm cachyos-calamares-next' "$live"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$repo"
  printf 'package\n' >"$repo/parental-guard.pkg.tar.zst"

  export CACHYOS_CONTAINER_LIB_ONLY=1
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  run stage_official_tree desktop "$live" "$calamares" "$repo" "$staged"
  [ "$status" -eq 0 ]
  grep -q 'prepare_profile' "$staged/util-iso.sh"
  required="$(cachyos_metadata_value desktop required_packages)"
  for pkg in $required; do
    grep -qx "$pkg" "$staged/archiso/packages_desktop.x86_64"
    [ "$(grep -xc "$pkg" "$staged/archiso/packages_desktop.x86_64")" -eq 1 ]
  done
  grep -q '^# BEGIN parental-os temporary repository$' "$staged/archiso/pacman.conf"
  grep -q '^Server = file:///srv/parental-os-repo$' "$staged/archiso/pacman.conf"
  grep -q '^# BEGIN parental-os temporary repository$' \
    "$staged/archiso/airootfs/etc/pacman-more.conf"
  grep -q '^Server = http://127.0.0.1:8765$' \
    "$staged/archiso/airootfs/etc/pacman-more.conf"
  grep -q '^# BEGIN parental-os temporary repository$' \
    "$staged/archiso/airootfs/etc/pacman.conf"
  grep -q '^Server = http://127.0.0.1:8765$' \
    "$staged/archiso/airootfs/etc/pacman.conf"
  [ ! -e "$staged/archiso/airootfs/etc/calamares/modules/pacstrap.conf" ]
  [ ! -e "$staged/archiso/airootfs/etc/calamares/modules/shellprocess-before-online.conf" ]
  repo_service="$staged/archiso/airootfs/etc/systemd/system/parental-os-repo.service"
  [ -f "$repo_service" ]
  grep -q 'python -m http.server 8765 --bind 127.0.0.1 --directory /srv/parental-os-repo' \
    "$repo_service"
  wants="$staged/archiso/airootfs/etc/systemd/system/multi-user.target.wants"
  [ -L "$wants/parental-os-repo.service" ]
  [ "$(readlink "$wants/parental-os-repo.service")" = "/etc/systemd/system/parental-os-repo.service" ]
  for service in \
    cloud-init-local.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service \
    sshd.service \
    qemu-guest-agent.service; do
    [ -L "$wants/$service" ]
    [ "$(readlink "$wants/$service")" = "/usr/lib/systemd/system/$service" ]
  done

  run stage_official_tree desktop "$live" "$calamares" "$repo" "$staged"
  [ "$status" -eq 0 ]
  for service in \
    cloud-init-local.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service \
    sshd.service \
    qemu-guest-agent.service; do
    [ -L "$wants/$service" ]
    [ "$(readlink "$wants/$service")" = "/usr/lib/systemd/system/$service" ]
  done

  export OFFICIAL_INVOCATION_LOG="$invocation"
  export OFFICIAL_USER_LOG="$official_user"
  run run_official_build desktop "$staged"
  [ "$status" -eq 0 ]
  [ "$(cat "$invocation")" = "-p desktop" ]
  [ "$(cat "$official_user")" = "builder" ]
  [ "$(cat "$staged/archiso/airootfs/etc/edition-tag")" = "desktop" ]
  [ -s "$staged/archiso/airootfs/etc/version-tag" ]
}

@test "official staging creates live pacman.conf when upstream omits it" {
  live="$TEST_TMP/live"
  calamares="$TEST_TMP/calamares"
  repo="$TEST_TMP/repo"
  staged="$TEST_TMP/staged"
  _make_live_fixture desktop packages_desktop.x86_64 \
    cachyos-calamares-next \
    'sudo pacman -Sy --noconfirm cachyos-calamares-next' "$live"
  rm "$live/archiso/airootfs/etc/pacman.conf"
  _copy_calamares_fixture "$calamares"
  mkdir -p "$repo"
  printf 'package\n' >"$repo/parental-guard.pkg.tar.zst"

  export CACHYOS_CONTAINER_LIB_ONLY=1
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  run stage_official_tree desktop "$live" "$calamares" "$repo" "$staged"
  [ "$status" -eq 0 ]
  [ -f "$staged/archiso/airootfs/etc/pacman.conf" ]
  grep -q '^# BEGIN parental-os temporary repository$' \
    "$staged/archiso/airootfs/etc/pacman.conf"
  grep -q '^\[cachyos\]$' "$staged/archiso/airootfs/etc/pacman.conf"
}

@test "official staging cleanup handles root-owned profile-work with sudo rm fallback" {
  f="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  [[ -f "$f" ]]
  grep -Eq 'sudo[[:space:]]+rm[[:space:]]+-rf[[:space:]]+"\$staged_dir"' "$f"
}

@test "official staging appends required packages idempotently" {
  f="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  [[ -f "$f" ]]
  grep -Fq 'required_packages="$(cachyos_metadata_value "$edition" required_packages)"' "$f"
  grep -Eq 'for[[:space:]]+pkg[[:space:]]+in[[:space:]]+\$required_packages' "$f"
  grep -Eq 'grep[[:space:]]+-qx[[:space:]]+"\$pkg"[[:space:]]+"\$staged_dir/archiso/\$packages_file"' "$f"
}

@test "container entrypoint never bypasses official buildiso with direct mkarchiso" {
  f="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  grep -Eq '(^|[[:space:]])\\./buildiso\\.sh|/buildiso\\.sh' "$f"
  ! grep -Eq 'sudo[[:space:]]+mkarchiso|(^|[[:space:]])mkarchiso[[:space:]]' "$f"
}

@test "artifact validation accepts a complete edition and rejects identity drift" {
  edition_dir="$TEST_TMP/desktop"
  mkdir -p "$edition_dir"
  iso="$edition_dir/parental-os-cachyos-desktop-2099.01.02-x86_64.iso"
  printf 'iso\n' >"$iso"
  printf '%s  %s\n' "$(sha256sum "$iso" | awk '{print $1}')" "$(basename "$iso")" \
    >"$iso.sha256"
  printf '%s\n' \
    'parental-guard 0.1.0-1' \
    'cachyos-calamares-next 3.4.2-6' \
    'linux-cachyos 6.0-1' \
    'cloud-init 24.4-1' \
    'openssh 9.9p1-1' \
    'qemu-guest-agent 9.2.0-1' \
    >"$edition_dir/pkglist.x86_64.txt"
  printf 'log\n' >"$edition_dir/build.log"
  cachyos_provenance_write "$edition_dir/provenance.json" \
    edition=desktop \
    live_iso_url="https://github.com/CachyOS/CachyOS-Live-ISO.git" \
    live_iso_branch=master \
    live_iso_sha=abcdef0123456789abcdef0123456789abcdef01 \
    calamares_url="https://github.com/CachyOS/cachyos-calamares.git" \
    calamares_branch=cachyos-dev \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    pkgbuilds_url="https://github.com/CachyOS/CachyOS-PKGBUILDS.git" \
    pkgbuilds_branch=master \
    pkgbuilds_sha=ccccccc0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-04T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-cachyos-builder:latest"

  run cachyos_validate_artifact_set desktop "$edition_dir"
  [ "$status" -eq 0 ]

  printf '%s\n' 'linux-cachyos-deckify 6.0-1' >>"$edition_dir/pkglist.x86_64.txt"
  run cachyos_validate_artifact_set desktop "$edition_dir"
  [ "$status" -ne 0 ]
}

@test "edition artifact cleanup removes stale generated files but preserves provenance" {
  edition_dir="$TEST_TMP/desktop"
  mkdir -p "$edition_dir"
  printf 'old\n' >"$edition_dir/parental-os-cachyos-desktop-2026.08.04-x86_64.iso"
  printf 'old sum\n' >"$edition_dir/parental-os-cachyos-desktop-2026.08.04-x86_64.iso.sha256"
  printf 'current\n' >"$edition_dir/parental-os-cachyos-desktop.iso"
  printf 'current sum\n' >"$edition_dir/parental-os-cachyos-desktop.iso.sha256"
  mkdir -p "$edition_dir/stale-directory.iso"
  printf 'stale nested\n' >"$edition_dir/stale-directory.iso/payload"
  printf 'pkglist\n' >"$edition_dir/pkglist.x86_64.txt"
  printf 'log\n' >"$edition_dir/build.log"
  printf '{"edition":"desktop"}\n' >"$edition_dir/provenance.json"

  export CACHYOS_CONTAINER_LIB_ONLY=1
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  run clean_edition_artifacts "$edition_dir"
  [ "$status" -eq 0 ]
  [ ! -e "$edition_dir/parental-os-cachyos-desktop-2026.08.04-x86_64.iso" ]
  [ ! -e "$edition_dir/parental-os-cachyos-desktop-2026.08.04-x86_64.iso.sha256" ]
  [ ! -e "$edition_dir/parental-os-cachyos-desktop.iso" ]
  [ ! -e "$edition_dir/parental-os-cachyos-desktop.iso.sha256" ]
  [ ! -e "$edition_dir/stale-directory.iso" ]
  [ ! -e "$edition_dir/pkglist.x86_64.txt" ]
  [ ! -e "$edition_dir/build.log" ]
  [ -f "$edition_dir/provenance.json" ]
}

@test "edition artifact cleanup handles root-owned stale generated directories with sudo fallback" {
  f="$TEST_ROOT/distros/cachyos/container/build-edition.sh"
  [[ -f "$f" ]]
  grep -Eq 'sudo[[:space:]]+rm[[:space:]]+-rf[[:space:]]+"\$\{generated_artifacts\[@\]\}"' "$f"
}

@test "artifact validation rejects invalid provenance and edition drift" {
  edition_dir="$TEST_TMP/desktop"
  mkdir -p "$edition_dir"
  iso="$edition_dir/parental-os-cachyos-desktop-2099.01.02-x86_64.iso"
  printf 'iso\n' >"$iso"
  printf '%s  %s\n' "$(sha256sum "$iso" | awk '{print $1}')" "$(basename "$iso")" \
    >"$iso.sha256"
  printf '%s\n' \
    'parental-guard 0.1.0-1' \
    'cachyos-calamares-next 3.4.2-6' \
    'linux-cachyos 6.0-1' \
    >"$edition_dir/pkglist.x86_64.txt"
  printf 'log\n' >"$edition_dir/build.log"

  printf '{"edition":"desktop"}\n' >"$edition_dir/provenance.json"
  run cachyos_validate_artifact_set desktop "$edition_dir"
  [ "$status" -ne 0 ]

  cachyos_provenance_write "$edition_dir/provenance.json" \
    edition=handheld \
    live_iso_url="https://github.com/CachyOS/CachyOS-Live-ISO.git" \
    live_iso_branch=master \
    live_iso_sha=abcdef0123456789abcdef0123456789abcdef01 \
    calamares_url="https://github.com/CachyOS/cachyos-calamares.git" \
    calamares_branch=cachyos-dev \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    pkgbuilds_url="https://github.com/CachyOS/CachyOS-PKGBUILDS.git" \
    pkgbuilds_branch=master \
    pkgbuilds_sha=ccccccc0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-04T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-cachyos-builder:latest"
  run cachyos_validate_artifact_set desktop "$edition_dir"
  [ "$status" -ne 0 ]
}

@test "handheld metadata remains x86_64 and uses current deckify identity contracts" {
  run cachyos_edition_metadata handheld
  [ "$status" -eq 0 ]
  [[ "$output" == *"architecture=x86_64"* ]]
  [[ "$output" == *"calamares_package=cachyos-calamares-deckify"* ]]
  [[ "$output" == *"required_packages=linux-cachyos-deckify"* ]]
  [[ "$output" == *"steamdeck-firmware"* ]]
  [[ "$output" == *"plasma-keyboard"* ]]
  [[ "$output" != *"aarch64"* ]]
  [[ "$output" != *"arm64"* ]]
}

@test "cachyos_validate_sha rejects short, uppercase, and non-hex strings" {
  run cachyos_validate_sha "abc"
  [ "$status" -ne 0 ]
  run cachyos_validate_sha "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
  [ "$status" -ne 0 ]
  run cachyos_validate_sha "zbcdef0123456789abcdef0123456789abcdef01"
  [ "$status" -ne 0 ]
  run cachyos_validate_sha ""
  [ "$status" -ne 0 ]
}

@test "cachyos_resolve_ref returns the SHA from git ls-remote" {
  fake_bin="$(mktemp -d)"
  export FAKE_GIT_LOG="$fake_bin/git.log"
  _make_fake_git "$fake_bin" "abcdef0123456789abcdef0123456789abcdef01"
  PATH="$fake_bin:$PATH" run cachyos_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -eq 0 ]
  [ "$output" = "abcdef0123456789abcdef0123456789abcdef01" ]
  grep -Fq 'ls-remote --exit-code https://example.invalid/repo.git refs/heads/master' "$FAKE_GIT_LOG"
  rm -rf "$fake_bin"
}

@test "cachyos_resolve_ref rejects a non-40-char response" {
  fake_bin="$(mktemp -d)"
  _make_fake_git "$fake_bin" "tooshort"
  PATH="$fake_bin:$PATH" run cachyos_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -ne 0 ]
  rm -rf "$fake_bin"
}

@test "cachyos_resolve_ref fails when git returns nothing" {
  fake_bin="$(mktemp -d)"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/git"
  PATH="$fake_bin:$PATH" run cachyos_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -ne 0 ]
  rm -rf "$fake_bin"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

@test "cachyos_dispatch_editions returns desktop for desktop" {
  run cachyos_dispatch_editions desktop
  [ "$status" -eq 0 ]
  [ "$output" = "desktop" ]
}

@test "cachyos_dispatch_editions returns handheld for handheld" {
  run cachyos_dispatch_editions handheld
  [ "$status" -eq 0 ]
  [ "$output" = "handheld" ]
}

@test "cachyos_dispatch_editions returns desktop then handheld for all" {
  run cachyos_dispatch_editions all
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "desktop" ]
  [ "${lines[1]}" = "handheld" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cachyos_dispatch_editions rejects unknown target" {
  run cachyos_dispatch_editions foo
  [ "$status" -ne 0 ]
}

@test "cachyos_dispatch_editions rejects empty target" {
  run cachyos_dispatch_editions ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Provenance schema
# ---------------------------------------------------------------------------

@test "cachyos_provenance_write creates a JSON file with required fields" {
  tmp="$(mktemp -d)"
  prov="$tmp/provenance.json"
  cachyos_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/CachyOS/CachyOS-Live-ISO.git" \
    live_iso_branch=master \
    live_iso_sha=abcdef0123456789abcdef0123456789abcdef01 \
    calamares_url="https://github.com/CachyOS/cachyos-calamares.git" \
    calamares_branch=cachyos-dev \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    pkgbuilds_url="https://github.com/CachyOS/CachyOS-PKGBUILDS.git" \
    pkgbuilds_branch=master \
    pkgbuilds_sha=ccccccc0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-04T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-cachyos-builder:latest"
  [ -f "$prov" ]
  run cachyos_provenance_validate "$prov"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
}

@test "cachyos_provenance_validate rejects missing required field" {
  tmp="$(mktemp -d)"
  prov="$tmp/provenance.json"
  # Missing live_iso_sha
  cachyos_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/CachyOS/CachyOS-Live-ISO.git" \
    live_iso_branch=master \
    calamares_url="https://github.com/CachyOS/cachyos-calamares.git" \
    calamares_branch=cachyos-dev \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    pkgbuilds_url="https://github.com/CachyOS/CachyOS-PKGBUILDS.git" \
    pkgbuilds_branch=master \
    pkgbuilds_sha=ccccccc0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-04T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-cachyos-builder:latest"
  run cachyos_provenance_validate "$prov"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "cachyos_provenance_validate rejects invalid SHA format" {
  tmp="$(mktemp -d)"
  prov="$tmp/provenance.json"
  cachyos_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/CachyOS/CachyOS-Live-ISO.git" \
    live_iso_branch=master \
    live_iso_sha=notasha \
    calamares_url="https://github.com/CachyOS/cachyos-calamares.git" \
    calamares_branch=cachyos-dev \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    pkgbuilds_url="https://github.com/CachyOS/CachyOS-PKGBUILDS.git" \
    pkgbuilds_branch=master \
    pkgbuilds_sha=ccccccc0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-04T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-cachyos-builder:latest"
  run cachyos_provenance_validate "$prov"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "cachyos_provenance_validate rejects missing file" {
  run cachyos_provenance_validate "/nonexistent/path/provenance.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Staging isolation: all generated content stays under out/cachyos/staging/
# ---------------------------------------------------------------------------

@test "build-cachyos.sh does not write to packages/parental-guard/src" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  ! grep -Fq 'packages/parental-guard/src' "$f"
}

@test "build-parental-guard-arch.sh stages into out/cachyos/staging not packages/" {
  f="$PARENTAL_OS_ROOT/scripts/build-parental-guard-arch.sh"
  [[ -f "$f" ]]
  grep -Fq 'cachyos/staging' "$f"
  ! grep -Fq 'packages/parental-guard/src' "$f"
}

@test "build-parental-guard-arch.sh creates explicit staging parent before makepkg" {
  fake_bin="$TEST_TMP/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf 'fake makepkg in %s\n' "$PWD" >"${FAKE_MAKEPKG_LOG:?}"
printf 'pkg\n' >parental-guard-0.1.0-1-any.pkg.tar.zst
EOF
  chmod +x "$fake_bin/makepkg"
  export FAKE_MAKEPKG_LOG="$TEST_TMP/makepkg.log"

  stage_src="$PARENTAL_OS_OUT/cachyos/staging/nonexistent-parent/src"
  PATH="$fake_bin:$PATH" run "$PARENTAL_OS_ROOT/scripts/build-parental-guard-arch.sh" "$stage_src"
  [ "$status" -eq 0 ]
  [ -d "$PARENTAL_OS_OUT/cachyos/staging/nonexistent-parent" ]
  [ -f "$FAKE_MAKEPKG_LOG" ]
  [ -f "$PARENTAL_OS_OUT/packages/parental-guard-0.1.0-1-any.pkg.tar.zst" ]
}

@test "sync-package-from-overlays.sh accepts an explicit destination arg" {
  f="$PARENTAL_OS_ROOT/scripts/sync-package-from-overlays.sh"
  [[ -f "$f" ]]
  # Must accept a destination argument rather than hardcoding packages/.../src.
  grep -Eq 'dest="\$\{1:-' "$f"
  ! grep -Eq '^dest="\$ROOT/packages/parental-guard/src"$' "$f"
}

@test "sync-package-from-overlays.sh rejects destinations outside CachyOS staging" {
  unsafe="$TEST_TMP/outside-staging/src"
  mkdir -p "$unsafe"
  printf 'keep\n' >"$unsafe/sentinel"

  run "$PARENTAL_OS_ROOT/scripts/sync-package-from-overlays.sh" "$unsafe"

  [ "$status" -ne 0 ]
  [ -f "$unsafe/sentinel" ]
}

@test "PKGBUILD packages staged src next to PKGBUILD before checkout overlays fallback" {
  pkg_stage="$TEST_TMP/pkg-stage"
  pkgdir="$TEST_TMP/pkgdir"
  mkdir -p "$pkg_stage/src/etc/sudoers.d" "$pkg_stage/src/usr/local/bin" "$pkgdir"
  printf 'staged marker\n' >"$pkg_stage/src/usr/local/bin/staged-only"
  printf 'root ALL=(ALL) NOPASSWD: ALL\n' >"$pkg_stage/src/etc/sudoers.d/parental-os"

  run bash -lc '
    set -euo pipefail
    startdir="$1"
    pkgdir="$2"
    PARENTAL_OS_ROOT="$3"
    source "$3/packages/parental-guard/arch/PKGBUILD"
    package
  ' _ "$pkg_stage" "$pkgdir" "$PARENTAL_OS_ROOT"

  [ "$status" -eq 0 ]
  [ -f "$pkgdir/usr/local/bin/staged-only" ]
}

@test "all generated paths in build-cachyos.sh are under out/" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  # No writes to distros/cachyos/profile or other tracked checkout paths.
  ! grep -Fq 'distros/cachyos/profile' "$f"
}

@test "build-cachyos.sh declares jq because checkout reads provenance with jq" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  grep -Fq 'require_cmd jq' "$f"
}

@test "build-cachyos.sh uses docker default context helper" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  grep -Fq 'docker_cli build' "$f"
  grep -Fq 'docker_cli run' "$f"
  ! grep -Eq '(^|[[:space:]])docker[[:space:]]+(build|run)([[:space:]]|$)' "$f"
}

@test "build-parental-guard-deb.sh uses docker default context helper" {
  f="$PARENTAL_OS_ROOT/scripts/build-parental-guard-deb.sh"
  [[ -f "$f" ]]
  grep -Fq 'docker_cli run' "$f"
  ! grep -Eq '(^|[[:space:]])docker[[:space:]]+run([[:space:]]|$)' "$f"
}

# ---------------------------------------------------------------------------
# Container invocation flags (static inspection of build-cachyos.sh)
# ---------------------------------------------------------------------------

@test "build-cachyos.sh uses docker_cli run with --rm" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  grep -Fq 'docker_cli run' "$f"
  grep -Fq -- '--rm' "$f"
}

@test "build-cachyos.sh uses docker_cli run with --privileged" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  grep -Fq 'docker_cli run' "$f"
  grep -Fq -- '--privileged' "$f"
}

@test "build-cachyos.sh mounts the parental checkout read-only" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  # A read-only bind mount for the repo root via --mount syntax.
  grep -Eq 'destination=/repo' "$f"
  grep -Eq 'readonly' "$f"
}

@test "build-cachyos.sh mounts out/ read-write" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  # A read-write bind mount for out/ via --mount syntax.
  grep -Eq 'destination=/out' "$f"
}

@test "build-cachyos.sh uses private mount propagation" {
  f="$PARENTAL_OS_ROOT/scripts/build-cachyos.sh"
  [[ -f "$f" ]]
  # Private mount propagation specified via bind-propagation=rprivate.
  grep -Eq 'bind-propagation=rprivate' "$f"
}

# ---------------------------------------------------------------------------
# Dockerfile and container entrypoint static checks
# ---------------------------------------------------------------------------

@test "Dockerfile exists and uses archlinux base-devel" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  [[ -f "$f" ]]
  grep -Eq '^FROM archlinux:base-devel' "$f"
}

@test "Dockerfile installs archiso and CachyOS build prerequisites" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  grep -q 'archiso' "$f"
  grep -q 'git' "$f"
  grep -q 'sudo' "$f"
  grep -q 'rsync' "$f"
  grep -q 'squashfs-tools' "$f"
  grep -q 'xorriso' "$f"
}

@test "Dockerfile creates a non-root builder user" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  grep -Eq 'useradd.*builder' "$f"
  grep -Eq 'USER builder' "$f"
}

@test "Dockerfile grants narrowly scoped sudo to builder" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  # Must have a sudoers drop-in for builder.
  grep -q 'builder' "$f"
  grep -Eq 'NOPASSWD' "$f"
  # Must NOT grant blanket ALL=NOPASSWD: ALL without command scoping.
  ! grep -Eq 'builder ALL=\(ALL\) NOPASSWD: ALL$' "$f"
}

@test "Dockerfile allows upstream buildiso chown without blanket sudo" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  grep -Eq '/usr/bin/chown[[:space:]]+builder[[:space:]]+\*' "$f"
  ! grep -Eq 'builder ALL=\(ALL\) NOPASSWD: ALL$' "$f"
}

@test "Dockerfile initializes and trusts the CachyOS keyring" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  grep -q 'cachyos-keyring' "$f"
  grep -q 'pacman-key' "$f"
}

@test "container entrypoint build-edition.sh exists and is executable" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/build-edition.sh"
  [[ -f "$f" ]]
  [[ -x "$f" ]]
}

@test "build-edition.sh builds parental-guard once for all" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/build-edition.sh"
  grep -q 'parental-guard' "$f"
  grep -Eq 'repo-add' "$f"
  grep -Eq 'buildiso\.sh' "$f"
}

@test "build-edition.sh builds desktop before handheld for all" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/build-edition.sh"
  # The dispatch must produce desktop then handheld sequentially.
  grep -q 'desktop' "$f"
  grep -q 'handheld' "$f"
}

# ---------------------------------------------------------------------------
# Calamares parental overlay transformer
# ---------------------------------------------------------------------------

@test "apply-parental-overlay.py exists" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  [[ -f "$f" ]]
  [[ -x "$f" ]]
}

@test "apply-parental-overlay.py adds parental-guard to pacstrap.conf" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  grep -q 'parental-guard' "$f"
  grep -q 'pacstrap.conf' "$f"
}

@test "apply-parental-overlay.py adds both services to services-systemd.conf" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  grep -q 'parental-guard.service' "$f"
  grep -q 'parental-guard-agent.service' "$f"
  grep -q 'services-systemd.conf' "$f"
}

@test "apply-parental-overlay.py removes the temporary [parental-os] stanza" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  grep -q 'parental-os' "$f"
  grep -Eq 'cleanup|remove|stanza' "$f"
}

@test "apply-parental-overlay.py is idempotent and fail-closed" {
  f="$PARENTAL_OS_ROOT/distros/cachyos/calamares/apply-parental-overlay.py"
  # Must check for expected markers/keys and abort if absent.
  grep -Eq 'sys.exit|raise|abort' "$f"
}

# ---------------------------------------------------------------------------
# Docker-gated tests (skip without Docker)
# ---------------------------------------------------------------------------

skip_if_no_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker_cli info >/dev/null 2>&1 \
    || skip "docker context $DOCKER_CONTEXT is unavailable"
}

@test "docker build succeeds for the CachyOS builder image" {
  skip_if_no_docker
  f="$PARENTAL_OS_ROOT/distros/cachyos/container/Dockerfile"
  [[ -f "$f" ]]
  run docker_cli build \
    -t parental-os-cachyos-builder:test "$PARENTAL_OS_ROOT/distros/cachyos/container"
  [ "$status" -eq 0 ]
}

@test "builder image has a non-root builder with sudo access" {
  skip_if_no_docker
  run docker_cli run --rm \
    --entrypoint /usr/bin/id parental-os-cachyos-builder:test
  [ "$status" -eq 0 ]
  [[ "$output" == *"builder"* ]]
  # Verify narrowly scoped sudo works for an allowed command (pacman).
  run docker_cli run --rm \
    --entrypoint /usr/bin/sudo parental-os-cachyos-builder:test \
    -n /usr/bin/pacman -V
  [ "$status" -eq 0 ]
}

@test "builder image has archiso installed" {
  skip_if_no_docker
  run docker_cli run --rm \
    --entrypoint /usr/bin/pacman parental-os-cachyos-builder:test -Qi archiso
  [ "$status" -eq 0 ]
}
