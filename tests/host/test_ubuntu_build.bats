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
  ! echo "$output" | grep -Eq '[0-9a-f]{40}'
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
    parental-os-ubuntu-builder:latest \
    bash -c 'command -v debootstrap && command -v mksquashfs && command -v xorriso && command -v dpkg-buildpackage && command -v git && command -v jq && command -v python3'
  [ "$status" -eq 0 ]
}

