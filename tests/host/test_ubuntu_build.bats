#!/usr/bin/env bats
# Contract tests for Ubuntu Desktop LiveCD port: metadata, ref resolution,
# provenance, and validation helpers (Task 1).

setup() {
  TEST_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export PARENTAL_OS_ROOT="$TEST_ROOT"
  export PARENTAL_OS_OUT="$TEST_TMP/out"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/scripts/lib/ubuntu.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helpers
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
  git -C "$work" config user.name "Ubuntu port test"
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

_copy_ubuntu_calamares_fixture() {
  local destination="$1"
  mkdir -p "$destination"
  cp -a "$TEST_ROOT/tests/fixtures/ubuntu/calamares/." "$destination/"
}

_run_ubuntu_transformer_source() {
  local source_root="$1"
  local live_root="$2"
  local package="${3:-}"
  if [[ -n "$package" ]]; then
    run python3 "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py" \
      stage "$source_root" "$live_root" \
      "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py" "$package"
  else
    run python3 "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py" \
      stage "$source_root" "$live_root" \
      "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py"
  fi
}

_run_ubuntu_transformer_runtime() {
  local source_root="$1"
  local live_root="$2"
  run python3 "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py" \
    runtime "$source_root" "$live_root"
}

# ---------------------------------------------------------------------------
# Edition metadata
# ---------------------------------------------------------------------------

@test "ubuntu_edition_metadata returns data for desktop" {
  run ubuntu_edition_metadata desktop
  [ "$status" -eq 0 ]
  [[ "$output" == *"live_iso_url="* ]]
  [[ "$output" == *"live_iso_branch="* ]]
  [[ "$output" == *"calamares_url="* ]]
  [[ "$output" == *"calamares_branch="* ]]
  [[ "$output" == *"iso_basename=parental-os-ubuntu-desktop"* ]]
  [[ "$output" == *"architecture=x86_64"* ]]
}

@test "ubuntu_edition_metadata points to calamares-settings-ubuntu upstream" {
  run ubuntu_edition_metadata desktop
  [ "$status" -eq 0 ]
  [[ "$output" == *"calamares-settings-ubuntu"* ]]
}

@test "ubuntu_edition_metadata rejects unknown edition" {
  run ubuntu_edition_metadata nonsense
  [ "$status" -ne 0 ]
}

@test "ubuntu_edition_metadata does not encode any hardcoded 40-char SHA" {
  run ubuntu_edition_metadata desktop
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -E '^(live_iso|calamares)_sha=' | grep -Eq '[0-9a-f]{40}'
}

@test "ubuntu_metadata_value extracts keys correctly" {
  run ubuntu_metadata_value desktop iso_basename
  [ "$status" -eq 0 ]
  [ "$output" = "parental-os-ubuntu-desktop" ]

  run ubuntu_metadata_value desktop architecture
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64" ]
}

@test "ubuntu_metadata_value fails closed on unknown keys" {
  run ubuntu_metadata_value desktop nonexistent_key
  [ "$status" -ne 0 ]
}

@test "ubuntu_known_editions returns desktop" {
  run ubuntu_known_editions
  [ "$status" -eq 0 ]
  [ "$output" = "desktop" ]
}

@test "ubuntu_is_valid_edition validates desktop and rejects invalid" {
  run ubuntu_is_valid_edition desktop
  [ "$status" -eq 0 ]

  run ubuntu_is_valid_edition server
  [ "$status" -ne 0 ]

  run ubuntu_is_valid_edition ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

@test "ubuntu_dispatch_editions returns desktop for desktop" {
  run ubuntu_dispatch_editions desktop
  [ "$status" -eq 0 ]
  [ "$output" = "desktop" ]
}

@test "ubuntu_dispatch_editions returns desktop for all" {
  run ubuntu_dispatch_editions all
  [ "$status" -eq 0 ]
  [ "$output" = "desktop" ]
}

@test "ubuntu_dispatch_editions rejects unknown target" {
  run ubuntu_dispatch_editions nonsense
  [ "$status" -ne 0 ]
}

@test "ubuntu_dispatch_editions rejects empty target" {
  run ubuntu_dispatch_editions ""
  [ "$status" -ne 0 ]
}

@test "ubuntu_for_each_edition invokes callback for desktop" {
  trace="$TEST_TMP/trace"
  edition_callback() {
    local edition="$1"
    printf 'ran:%s\n' "$edition" >>"$trace"
  }

  run ubuntu_for_each_edition desktop edition_callback
  [ "$status" -eq 0 ]
  [ "$(cat "$trace")" = "ran:desktop" ]
}

# ---------------------------------------------------------------------------
# SHA validation
# ---------------------------------------------------------------------------

@test "ubuntu_validate_sha accepts a valid 40-char lowercase hex SHA" {
  run ubuntu_validate_sha "abcdef0123456789abcdef0123456789abcdef01"
  [ "$status" -eq 0 ]
}

@test "ubuntu_validate_sha rejects short, uppercase, and non-hex strings" {
  run ubuntu_validate_sha "abc"
  [ "$status" -ne 0 ]
  run ubuntu_validate_sha "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
  [ "$status" -ne 0 ]
  run ubuntu_validate_sha "zbcdef0123456789abcdef0123456789abcdef01"
  [ "$status" -ne 0 ]
  run ubuntu_validate_sha ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Ref resolution
# ---------------------------------------------------------------------------

@test "ubuntu_resolve_ref returns the SHA from git ls-remote" {
  fake_bin="$(mktemp -d)"
  export FAKE_GIT_LOG="$fake_bin/git.log"
  _make_fake_git "$fake_bin" "abcdef0123456789abcdef0123456789abcdef01"
  PATH="$fake_bin:$PATH" run ubuntu_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -eq 0 ]
  [ "$output" = "abcdef0123456789abcdef0123456789abcdef01" ]
  grep -Fq 'ls-remote --exit-code https://example.invalid/repo.git refs/heads/master' "$FAKE_GIT_LOG"
  rm -rf "$fake_bin"
}

@test "ubuntu_resolve_ref rejects a non-40-char response" {
  fake_bin="$(mktemp -d)"
  _make_fake_git "$fake_bin" "tooshort"
  PATH="$fake_bin:$PATH" run ubuntu_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -ne 0 ]
  rm -rf "$fake_bin"
}

@test "ubuntu_resolve_ref fails when git returns nothing" {
  fake_bin="$(mktemp -d)"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/git"
  PATH="$fake_bin:$PATH" run ubuntu_resolve_ref "https://example.invalid/repo.git" "master"
  [ "$status" -ne 0 ]
  rm -rf "$fake_bin"
}

# ---------------------------------------------------------------------------
# Exact checkout
# ---------------------------------------------------------------------------

@test "ubuntu_checkout_exact fetches and detaches only the requested SHA" {
  remote="$TEST_TMP/remote.git"
  source_work="$TEST_TMP/source"
  checkout="$TEST_TMP/checkout"
  _make_source_repo "$remote" "$source_work"

  run ubuntu_checkout_exact "$remote" "$FIRST_SHA" "$checkout"
  [ "$status" -eq 0 ]
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$FIRST_SHA" ]
  [ "$(git -C "$checkout" symbolic-ref -q HEAD || true)" = "" ]
  [ "$(cat "$checkout/payload")" = "first" ]
}

@test "ubuntu_checkout_exact fails closed when the requested SHA cannot be fetched" {
  remote="$TEST_TMP/remote.git"
  source_work="$TEST_TMP/source"
  checkout="$TEST_TMP/checkout"
  _make_source_repo "$remote" "$source_work"

  run ubuntu_checkout_exact "$remote" \
    0000000000000000000000000000000000000000 "$checkout"
  [ "$status" -ne 0 ]
  if [[ -d "$checkout/.git" ]]; then
    [ "$(git -C "$checkout" rev-parse -q --verify HEAD 2>/dev/null || true)" != \
      "0000000000000000000000000000000000000000" ]
  fi
}

# ---------------------------------------------------------------------------
# Provenance schema & validation
# ---------------------------------------------------------------------------

@test "ubuntu_provenance_write creates a JSON file with required fields" {
  prov="$TEST_TMP/provenance.json"
  ubuntu_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    live_iso_sha=abcdef0123456789abcdef0123456789abcdef01 \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"
  [ -f "$prov" ]
  run ubuntu_provenance_validate "$prov"
  [ "$status" -eq 0 ]
}

@test "ubuntu_provenance_validate rejects missing required field" {
  prov="$TEST_TMP/provenance.json"
  # Missing live_iso_sha
  ubuntu_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"
  run ubuntu_provenance_validate "$prov"
  [ "$status" -ne 0 ]
}

@test "ubuntu_provenance_validate rejects invalid SHA format" {
  prov="$TEST_TMP/provenance.json"
  ubuntu_provenance_write "$prov" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    live_iso_sha=notasha \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha=bbbbbbb0123456789abcdef0123456789abcdef0 \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"
  run ubuntu_provenance_validate "$prov"
  [ "$status" -ne 0 ]
}

@test "ubuntu_provenance_validate rejects missing file" {
  run ubuntu_provenance_validate "/nonexistent/path/provenance.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Parental-os git helpers
# ---------------------------------------------------------------------------

@test "ubuntu_parental_os_revision returns revision string" {
  run ubuntu_parental_os_revision
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "ubuntu_parental_os_dirty returns boolean string" {
  run ubuntu_parental_os_dirty
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(true|false)$ ]]
}

# ---------------------------------------------------------------------------
# Directory output helpers
# ---------------------------------------------------------------------------

@test "ubuntu_edition_out_dir returns expected path" {
  run ubuntu_edition_out_dir desktop
  [ "$status" -eq 0 ]
  [ "$output" = "$PARENTAL_OS_OUT/ubuntu/desktop" ]
}

@test "ubuntu_staging_dir returns expected path" {
  run ubuntu_staging_dir desktop
  [ "$status" -eq 0 ]
  [ "$output" = "$PARENTAL_OS_OUT/ubuntu/staging/desktop" ]
}

# ---------------------------------------------------------------------------
# Builder container contract & Dockerfile checks (Task 2)
# ---------------------------------------------------------------------------

skip_if_no_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker_cli info >/dev/null 2>&1 \
    || skip "docker context $DOCKER_CONTEXT is unavailable"
}

@test "Ubuntu builder Dockerfile exists and uses ubuntu:noble base image" {
  f="$TEST_ROOT/distros/ubuntu/container/Dockerfile"
  [ -f "$f" ]
  grep -Eq '^FROM[[:space:]]+ubuntu:noble' "$f"
}

@test "Ubuntu builder Dockerfile configures non-interactive debian frontend" {
  f="$TEST_ROOT/distros/ubuntu/container/Dockerfile"
  [ -f "$f" ]
  grep -Eq 'DEBIAN_FRONTEND=noninteractive' "$f"
}

@test "Ubuntu builder Dockerfile installs required packaging and live ISO tools" {
  f="$TEST_ROOT/distros/ubuntu/container/Dockerfile"
  [ -f "$f" ]
  for pkg in debootstrap squashfs-tools xorriso mtools dosfstools dpkg-dev debhelper rsync git jq; do
    grep -q "$pkg" "$f"
  done
}

@test "Ubuntu builder Dockerfile sets working directory to /build" {
  f="$TEST_ROOT/distros/ubuntu/container/Dockerfile"
  [ -f "$f" ]
  grep -Eq '^WORKDIR[[:space:]]+/build' "$f"
}

@test "docker build succeeds for the Ubuntu builder image" {
  skip_if_no_docker
  f="$TEST_ROOT/distros/ubuntu/container/Dockerfile"
  [ -f "$f" ]
  run docker_cli build \
    -t parental-os-ubuntu-builder:latest "$TEST_ROOT/distros/ubuntu/container"
  [ "$status" -eq 0 ]
}

@test "builder image has required tools installed and functional" {
  skip_if_no_docker
  run docker_cli run --rm \
    --entrypoint bash \
    parental-os-ubuntu-builder:latest \
    -c 'command -v debootstrap && command -v mksquashfs && command -v xorriso && command -v dpkg-buildpackage && command -v git && command -v jq && command -v python3'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Calamares parental overlay transformer for Ubuntu (Task 3)
# ---------------------------------------------------------------------------

@test "Ubuntu apply-parental-overlay.py exists and is executable" {
  f="$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py"
  [ -f "$f" ]
  [ -x "$f" ]
}

@test "Ubuntu apply-parental-overlay.py has valid Python 3 syntax" {
  f="$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py"
  run python3 -m py_compile "$f"
  [ "$status" -eq 0 ]
}

@test "Ubuntu apply-parental-overlay.py adds all four services to services-systemd.conf" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  conf="$calamares/src/modules/services-systemd/services-systemd.conf"
  [ -f "$conf" ]
  for svc in parental-guard.service parental-guard-agent.service parental-guard-enroll.service parental-guard-enroll.path; do
    grep -q "$svc" "$conf"
  done
  grep -A 2 'parental-guard.service' "$conf" | grep -q 'action: "enable"'
  grep -A 2 'parental-guard.service' "$conf" | grep -q 'mandatory: true'
}

@test "Ubuntu apply-parental-overlay.py wires shellprocess repo copy and cleanup" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  before_conf="$calamares/src/modules/shellprocess/shellprocess-before-online.conf"
  cleanup_conf="$calamares/src/modules/shellprocess/shellprocess_cleanup_calamares.conf"
  grep -q '/etc/calamares/scripts/copy-parental-os-repo ${ROOT}' "$before_conf"
  grep -q '/etc/calamares/scripts/remove-parental-os-repo' "$cleanup_conf"
}

@test "Ubuntu apply-parental-overlay.py creates copy-parental-os-repo, install-parental-guard, and remove-parental-os-repo scripts" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  [ -x "$calamares/scripts/copy-parental-os-repo" ]
  [ -x "$calamares/scripts/install-parental-guard" ]
  [ -x "$calamares/scripts/remove-parental-os-repo" ]
}

@test "Ubuntu apply-parental-overlay.py is idempotent" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]
  first_hash="$(find "$calamares" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]
  second_hash="$(find "$calamares" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  [ "$first_hash" = "$second_hash" ]
}

@test "Ubuntu apply-parental-overlay.py is fail-closed on missing inputs" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  rm -f "$calamares/src/modules/services-systemd/services-systemd.conf"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -ne 0 ]
}

@test "Ubuntu copy-parental-os-repo copies local repo and sets up apt list" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  source_repo="$TEST_TMP/source-repo"
  target="$TEST_TMP/target"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin" "$source_repo" "$target"
  printf 'Package: parental-guard\n' >"$source_repo/Packages"
  printf 'fake deb\n' >"$source_repo/parental-guard_0.1.0-1_all.deb"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  PARENTAL_OS_REPO_SOURCE="$source_repo" run "$calamares/scripts/copy-parental-os-repo" "$target"
  [ "$status" -eq 0 ]
  [ -f "$target/srv/parental-os-repo/Packages" ]
  [ -f "$target/srv/parental-os-repo/parental-guard_0.1.0-1_all.deb" ]
  [ -f "$target/etc/apt/sources.list.d/parental-os.list" ]
  grep -q 'file:///srv/parental-os-repo' "$target/etc/apt/sources.list.d/parental-os.list"
}

@test "Ubuntu install-parental-guard configures PAM account gate in common-account" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  target="$TEST_TMP/target"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin" "$target/srv/parental-os-repo" "$target/etc/pam.d" "$target/usr/bin"
  printf 'fake deb\n' >"$target/srv/parental-os-repo/parental-guard_0.1.0-1_all.deb"
  cat >"$target/etc/pam.d/common-account" <<'EOF'
# /etc/pam.d/common-account - authorization settings common to all services
account [success=1 new_authtok_reqd=done default=ignore] pam_unix.so
account requisite pam_deny.so
account required pam_permit.so
EOF

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  fake_bin="$TEST_TMP/fakebin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/dpkg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$fake_bin/chroot" <<'EOF'
#!/usr/bin/env bash
shift
"$@"
EOF
  chmod +x "$fake_bin"/*

  PATH="$fake_bin:$PATH" run "$calamares/scripts/install-parental-guard" "$target"
  [ "$status" -eq 0 ]
  grep -q 'pam_unix.so' "$target/etc/pam.d/common-account"
}

@test "Ubuntu remove-parental-os-repo cleans up target apt repo and removes /srv/parental-os-repo" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  target="$TEST_TMP/target"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin" "$target/srv/parental-os-repo" "$target/etc/apt/sources.list.d"
  printf 'fake deb\n' >"$target/srv/parental-os-repo/parental-guard_0.1.0-1_all.deb"
  printf 'deb [trusted=yes] file:///srv/parental-os-repo ./\n' >"$target/etc/apt/sources.list.d/parental-os.list"
  printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$target/etc/apt/sources.list.d/ubuntu.list"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  run "$calamares/scripts/remove-parental-os-repo" "$target"
  [ "$status" -eq 0 ]
  [ ! -e "$target/srv/parental-os-repo" ]
  [ ! -e "$target/etc/apt/sources.list.d/parental-os.list" ]
  [ -f "$target/etc/apt/sources.list.d/ubuntu.list" ]
}

@test "Ubuntu runtime mode installs module files and scripts to live etc/calamares" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]
  _run_ubuntu_transformer_runtime "$live/usr/share/calamares" "$live"
  [ "$status" -eq 0 ]

  [ -f "$live/etc/calamares/modules/services-systemd.conf" ]
  [ -f "$live/etc/calamares/modules/shellprocess-before-online.conf" ]
  [ -f "$live/etc/calamares/modules/shellprocess_cleanup_calamares.conf" ]
  [ -x "$live/etc/calamares/scripts/copy-parental-os-repo" ]
  [ -x "$live/etc/calamares/scripts/install-parental-guard" ]
  [ -x "$live/etc/calamares/scripts/remove-parental-os-repo" ]
  grep -q 'parental-guard.service' "$live/etc/calamares/modules/services-systemd.conf"
  grep -q 'parental-guard-enroll.service' "$live/etc/calamares/modules/services-systemd.conf"
}

@test "Ubuntu stage mode patches calamares launcher when present" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
apt-get update && apt-get install -y calamares-settings-ubuntu
exec calamares
EOF

  _run_ubuntu_transformer_source "$calamares" "$live" "calamares-settings-ubuntu"
  [ "$status" -eq 0 ]

  grep -q 'apply-parental-overlay.py runtime /usr/share/calamares /' "$live/usr/local/bin/calamares-online.sh"
}

@test "Ubuntu stage mode fails when launcher has unexpected package" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin"
  cat >"$live/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
apt-get install -y unexpected-calamares
exec calamares
EOF

  _run_ubuntu_transformer_source "$calamares" "$live" "calamares-settings-ubuntu"
  [ "$status" -ne 0 ]
}

@test "Ubuntu remove-parental-os-repo cleans up inline deb lines from sources.list" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  target="$TEST_TMP/target"
  _copy_ubuntu_calamares_fixture "$calamares"
  mkdir -p "$live/usr/local/bin" "$target/srv/parental-os-repo" "$target/etc/apt"
  cat >"$target/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main universe
deb [trusted=yes] file:///srv/parental-os-repo ./
deb http://security.ubuntu.com/ubuntu noble-security main
EOF

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -eq 0 ]

  run "$calamares/scripts/remove-parental-os-repo" "$target/etc/apt/sources.list"
  [ "$status" -eq 0 ]
  ! grep -q 'parental-os-repo' "$target/etc/apt/sources.list"
  grep -q 'archive.ubuntu.com' "$target/etc/apt/sources.list"
  grep -q 'security.ubuntu.com' "$target/etc/apt/sources.list"
  [ ! -e "$target/srv/parental-os-repo" ]
}

@test "Ubuntu apply-parental-overlay.py fails closed when units key is missing" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  printf 'invalid: true\n' >"$calamares/src/modules/services-systemd/services-systemd.conf"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -ne 0 ]
}

@test "Ubuntu apply-parental-overlay.py fails closed when script key is missing in shellprocess" {
  calamares="$TEST_TMP/calamares"
  live="$TEST_TMP/live"
  _copy_ubuntu_calamares_fixture "$calamares"
  printf 'dontChroot: true\n' >"$calamares/src/modules/shellprocess/shellprocess-before-online.conf"
  mkdir -p "$live/usr/local/bin"

  _run_ubuntu_transformer_source "$calamares" "$live"
  [ "$status" -ne 0 ]
}

@test "Ubuntu apply-parental-overlay.py fails closed when calamares source dir is missing" {
  live="$TEST_TMP/live"
  mkdir -p "$live"
  run python3 "$TEST_ROOT/distros/ubuntu/calamares/apply-parental-overlay.py" \
    stage "$TEST_TMP/nonexistent" "$live"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Host build driver & container entrypoint tests (Task 4)
# ---------------------------------------------------------------------------

@test "scripts/build-ubuntu.sh exists and is executable" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  [ -f "$f" ]
  [ -x "$f" ]
}

@test "scripts/build-ubuntu.sh has valid bash syntax" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  run bash -n "$f"
  [ "$status" -eq 0 ]
}

@test "scripts/build-ubuntu.sh sources common.sh and ubuntu.sh" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Eq 'source.*scripts/lib/common\.sh' "$f"
  grep -Eq 'source.*scripts/lib/ubuntu\.sh' "$f"
}

@test "scripts/build-ubuntu.sh requires git, docker, and jq" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Fq 'require_cmd git' "$f"
  grep -Fq 'require_cmd docker' "$f"
  grep -Fq 'require_cmd jq' "$f"
}

@test "scripts/build-ubuntu.sh validates target (desktop | all) and rejects invalid" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Eq 'ubuntu_dispatch_editions' "$f"
  grep -Eq 'unknown target' "$f"
}

@test "scripts/build-ubuntu.sh uses docker default context helper" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Fq 'docker_cli build' "$f"
  grep -Fq 'docker_cli run' "$f"
  ! grep -Eq '(^|[[:space:]])docker[[:space:]]+(build|run)([[:space:]]|$)' "$f"
}

@test "scripts/build-ubuntu.sh uses docker_cli run with --rm and --privileged" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Fq 'docker_cli run' "$f"
  grep -Fq -- '--rm' "$f"
  grep -Fq -- '--privileged' "$f"
}

@test "scripts/build-ubuntu.sh mounts repo read-only and out read-write with rprivate propagation" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  grep -Eq 'destination=/repo' "$f"
  grep -Eq 'readonly' "$f"
  grep -Eq 'destination=/out' "$f"
  grep -Eq 'bind-propagation=rprivate' "$f"
}

@test "all generated paths in build-ubuntu.sh are under out/" {
  f="$TEST_ROOT/scripts/build-ubuntu.sh"
  ! grep -Fq 'distros/ubuntu/profile' "$f"
  ! grep -Fq 'distros/ubuntu/lb' "$f"
}

@test "distros/ubuntu/container/build-edition.sh exists and is executable" {
  f="$TEST_ROOT/distros/ubuntu/container/build-edition.sh"
  [ -f "$f" ]
  [ -x "$f" ]
}

@test "distros/ubuntu/container/build-edition.sh has valid bash syntax" {
  f="$TEST_ROOT/distros/ubuntu/container/build-edition.sh"
  run bash -n "$f"
  [ "$status" -eq 0 ]
}

@test "Ubuntu build-edition.sh creates local apt repo with Packages index" {
  pkg_dir="$TEST_TMP/packages"
  staging_dir="$TEST_TMP/out/ubuntu/staging"
  mkdir -p "$pkg_dir" "$staging_dir"
  printf 'fake deb\n' >"$pkg_dir/parental-guard_0.1.0-1_all.deb"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  export PACKAGES_OUT="$pkg_dir"
  export UBUNTU_STAGING="$staging_dir"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run create_local_repo
  [ "$status" -eq 0 ]
  [ -f "$staging_dir/parental-os-repo/parental-guard_0.1.0-1_all.deb" ]
  [ -f "$staging_dir/parental-os-repo/Packages" ]
  [ -f "$staging_dir/parental-os-repo/Packages.gz" ]
  [ -d "$staging_dir/parental-os-repo-srv" ]
}

@test "Ubuntu build-edition.sh verify_provenance validates checked-out SHAs against provenance.json" {
  stage="$TEST_TMP/out/ubuntu/staging/desktop"
  out="$TEST_TMP/out/ubuntu/desktop"
  mkdir -p "$stage/ubuntu-live-iso" "$stage/ubuntu-calamares" "$out"

  _make_source_repo "$TEST_TMP/live.git" "$TEST_TMP/live_work"
  cp -a "$TEST_TMP/live_work/." "$stage/ubuntu-live-iso/"
  _make_source_repo "$TEST_TMP/cal.git" "$TEST_TMP/cal_work"
  cp -a "$TEST_TMP/cal_work/." "$stage/ubuntu-calamares/"

  live_sha="$(git -C "$stage/ubuntu-live-iso" rev-parse HEAD)"
  cal_sha="$(git -C "$stage/ubuntu-calamares" rev-parse HEAD)"

  ubuntu_provenance_write "$out/provenance.json" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    live_iso_sha="$live_sha" \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha="$cal_sha" \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  export UBUNTU_STAGING="$TEST_TMP/out/ubuntu/staging"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run verify_provenance desktop
  [ "$status" -eq 0 ]
}

@test "Ubuntu build-edition.sh verify_provenance fails closed on SHA mismatch" {
  stage="$TEST_TMP/out/ubuntu/staging/desktop"
  out="$TEST_TMP/out/ubuntu/desktop"
  mkdir -p "$stage/ubuntu-live-iso" "$stage/ubuntu-calamares" "$out"

  _make_source_repo "$TEST_TMP/live.git" "$TEST_TMP/live_work"
  cp -a "$TEST_TMP/live_work/." "$stage/ubuntu-live-iso/"
  _make_source_repo "$TEST_TMP/cal.git" "$TEST_TMP/cal_work"
  cp -a "$TEST_TMP/cal_work/." "$stage/ubuntu-calamares/"

  ubuntu_provenance_write "$out/provenance.json" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    live_iso_sha="0000000000000000000000000000000000000000" \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha="1111111111111111111111111111111111111111" \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  export UBUNTU_STAGING="$TEST_TMP/out/ubuntu/staging"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run verify_provenance desktop
  [ "$status" -ne 0 ]
}

@test "Ubuntu build-edition.sh stage_official_tree stages Calamares tree, repo, and applies transformer" {
  live="$TEST_TMP/live"
  calamares="$TEST_TMP/calamares"
  repo="$TEST_TMP/repo"
  staged="$TEST_TMP/staged"
  mkdir -p "$live" "$repo"
  _copy_ubuntu_calamares_fixture "$calamares"
  printf 'fake deb\n' >"$repo/parental-guard_0.1.0-1_all.deb"
  printf 'Package: parental-guard\n' >"$repo/Packages"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run stage_official_tree desktop "$live" "$calamares" "$repo" "$staged"
  [ "$status" -eq 0 ]
  [ -f "$staged/airootfs/srv/parental-os-repo/parental-guard_0.1.0-1_all.deb" ]
  [ -f "$staged/airootfs/etc/apt/sources.list.d/parental-os.list" ]
  [ -x "$staged/airootfs/usr/local/lib/parental-os/apply-parental-overlay.py" ]
  [ -d "$staged/airootfs/usr/share/calamares" ]
  [ -d "$staged/airootfs/usr/share/parental-os/unattended" ]
  [ -f "$staged/airootfs/usr/share/parental-os/unattended/settings.conf" ]
}

@test "Ubuntu build-edition.sh clean_edition_artifacts removes stale ISOs and logs while preserving provenance" {
  edition_dir="$TEST_TMP/desktop"
  mkdir -p "$edition_dir"
  printf 'old iso\n' >"$edition_dir/parental-os-ubuntu-desktop.iso"
  printf 'old sha\n' >"$edition_dir/parental-os-ubuntu-desktop.iso.sha256"
  printf 'pkglist\n' >"$edition_dir/pkglist.x86_64.txt"
  printf 'log\n' >"$edition_dir/build.log"
  printf '{"edition":"desktop"}\n' >"$edition_dir/provenance.json"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run clean_edition_artifacts "$edition_dir"
  [ "$status" -eq 0 ]
  [ ! -e "$edition_dir/parental-os-ubuntu-desktop.iso" ]
  [ ! -e "$edition_dir/parental-os-ubuntu-desktop.iso.sha256" ]
  [ ! -e "$edition_dir/pkglist.x86_64.txt" ]
  [ ! -e "$edition_dir/build.log" ]
  [ -f "$edition_dir/provenance.json" ]
}

@test "Ubuntu build-edition.sh clean_edition_artifacts handles root-owned files with sudo fallback" {
  f="$TEST_ROOT/distros/ubuntu/container/build-edition.sh"
  [ -f "$f" ]
  grep -Eq 'sudo[[:space:]]+rm[[:space:]]+-rf[[:space:]]+"\$\{generated_artifacts\[@\]\}"' "$f"
}

@test "Ubuntu build-edition.sh produces normalized ISO, sha256, and logs adhering to ubuntu_validate_artifact_set" {
  stage="$TEST_TMP/out/ubuntu/staging/desktop"
  out="$TEST_TMP/out/ubuntu/desktop"
  mkdir -p "$stage/profile-work/airootfs" "$stage/profile-work/out" "$out"
  printf 'fake iso\n' >"$stage/profile-work/out/parental-os-ubuntu-desktop.iso"

  ubuntu_provenance_write "$out/provenance.json" \
    edition=desktop \
    live_iso_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    live_iso_branch=master \
    live_iso_sha="abcdef0123456789abcdef0123456789abcdef01" \
    calamares_url="https://github.com/lubuntu-team/calamares-settings-ubuntu.git" \
    calamares_branch=master \
    calamares_sha="bbbbbbb0123456789abcdef0123456789abcdef0" \
    resolved_at="2026-08-30T00:00:00Z" \
    parental_os_revision=abcdef0 \
    parental_os_dirty=false \
    builder_image="parental-os-ubuntu-builder:latest"

  export UBUNTU_CONTAINER_LIB_ONLY=1
  export REPO_DIR="$TEST_ROOT"
  export OUT_DIR="$TEST_TMP/out"
  export UBUNTU_STAGING="$TEST_TMP/out/ubuntu/staging"
  export LOGS_OUT="$TEST_TMP/out/logs"
  mkdir -p "$LOGS_OUT"
  # shellcheck source=/dev/null
  source "$TEST_ROOT/distros/ubuntu/container/build-edition.sh"

  run build_iso desktop
  [ "$status" -eq 0 ]
  [ -f "$out/parental-os-ubuntu-desktop.iso" ]
  [ -f "$out/parental-os-ubuntu-desktop.iso.sha256" ]
  [ -f "$out/build.log" ]
  run ubuntu_validate_artifact_set desktop "$out"
  [ "$status" -eq 0 ]
}

@test "Ubuntu build-edition.sh builds custom live layer and wires target provisioner" {
  f="$TEST_ROOT/distros/ubuntu/container/build-edition.sh"
  [ -f "$f" ]
  grep -Eq 'minimal\.standard\.live\.custom\.squashfs' "$f"
  grep -Eq 'layerfs-path=minimal\.standard\.live\.custom\.squashfs' "$f"
  grep -Eq 'target-provisioner\.sh' "$f"
}

