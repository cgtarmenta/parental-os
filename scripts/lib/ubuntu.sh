#!/usr/bin/env bash
# Ubuntu Desktop edition metadata, ref resolution, provenance, and validation helpers
# for the Ubuntu Desktop LiveCD port.
#
# Observed research SHAs are evidence only and must never be encoded here. Only
# repository URLs and branch names are immutable metadata; SHAs are resolved at
# build time via git ls-remote and recorded in per-edition provenance.
set -euo pipefail

# ---------------------------------------------------------------------------
# Edition metadata
# ---------------------------------------------------------------------------

# Print key=value metadata for a given edition. Returns non-zero for unknown
# editions. No 40-char SHAs are ever emitted by this function.
ubuntu_edition_metadata() {
  local edition="$1"
  case "$edition" in
    desktop)
      printf 'live_iso_url=https://github.com/lubuntu-team/calamares-settings-ubuntu.git\n'
      printf 'live_iso_branch=master\n'
      printf 'calamares_url=https://github.com/lubuntu-team/calamares-settings-ubuntu.git\n'
      printf 'calamares_branch=master\n'
      printf 'profile_name=desktop\n'
      printf 'architecture=x86_64\n'
      printf 'iso_basename=parental-os-ubuntu-desktop\n'
      printf 'required_packages=parental-guard cloud-init openssh-server qemu-guest-agent\n'
      printf 'forbidden_packages=\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Convenience: fetch a single metadata value for an edition.
ubuntu_metadata_value() {
  local edition="$1" key="$2"
  ubuntu_edition_metadata "$edition" | awk -F= -v k="$key" '$1 == k { print $2; found=1 } END { if (!found) exit 1 }'
}

ubuntu_known_editions() {
  printf 'desktop\n'
}

ubuntu_is_valid_edition() {
  case "$1" in
    desktop) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch: map a target to an ordered list of editions.
# ---------------------------------------------------------------------------

ubuntu_dispatch_editions() {
  local target="$1"
  [[ -n "$target" ]] || return 1
  case "$target" in
    desktop | all) printf 'desktop\n' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# SHA validation
# ---------------------------------------------------------------------------

ubuntu_validate_sha() {
  local sha="$1"
  [[ -n "$sha" ]] || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

# ---------------------------------------------------------------------------
# Ref resolution: resolve a branch head to an exact 40-char SHA via git
# ls-remote. The SHA is validated before returning. Fails closed on any error.
# ---------------------------------------------------------------------------

ubuntu_resolve_ref() {
  local url="$1" branch="$2"
  local sha
  sha="$(git ls-remote --exit-code "$url" "refs/heads/$branch" 2>/dev/null | awk '{ print $1 }')"
  ubuntu_validate_sha "$sha" || return 1
  printf '%s\n' "$sha"
}

ubuntu_checkout_exact() {
  local url="$1" sha="$2" checkout_dir="$3"
  ubuntu_validate_sha "$sha" || return 1

  if [[ ! -d "$checkout_dir/.git" ]]; then
    rm -rf "$checkout_dir"
    git clone --no-checkout "$url" "$checkout_dir" >/dev/null 2>&1 || return 1
  fi

  git -C "$checkout_dir" fetch --depth=1 origin "$sha" >/dev/null 2>&1 || return 1
  git -C "$checkout_dir" checkout --detach "$sha" >/dev/null 2>&1 || return 1
  [[ "$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null)" = "$sha" ]]
}

ubuntu_for_each_edition() {
  local target="$1" callback="$2"
  local editions ed
  editions="$(ubuntu_dispatch_editions "$target")" || return 1
  for ed in $editions; do
    "$callback" "$ed" || return 1
  done
}

# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

# Required fields in every provenance document.
UBUNTU_PROVENANCE_REQUIRED_FIELDS=(
  edition
  live_iso_url
  live_iso_branch
  live_iso_sha
  calamares_url
  calamares_branch
  calamares_sha
  resolved_at
  parental_os_revision
  parental_os_dirty
  builder_image
)

# Fields whose values must be valid 40-char lowercase hex SHAs.
UBUNTU_PROVENANCE_SHA_FIELDS=(
  live_iso_sha
  calamares_sha
)

# Write a provenance JSON document. Accepts key=value pairs after the file path.
# Uses jq if available; otherwise falls back to a minimal JSON writer.
ubuntu_provenance_write() {
  local out_file="$1"
  shift
  local out_dir
  out_dir="$(dirname "$out_file")"
  mkdir -p "$out_dir"

  if command -v jq >/dev/null 2>&1; then
    {
      printf '{\n'
      local first=1
      for kv in "$@"; do
        local key val
        key="${kv%%=*}"
        val="${kv#*=}"
        # Escape backslashes and double quotes for JSON string safety.
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '  "%s": "%s"' "$key" "$val"
        first=0
      done
      printf '\n}\n'
    } | jq '.' >"$out_file"
  else
    {
      printf '{\n'
      local first=1
      for kv in "$@"; do
        local key val
        key="${kv%%=*}"
        val="${kv#*=}"
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        if [[ "$first" -eq 0 ]]; then
          printf ',\n'
        fi
        printf '  "%s": "%s"' "$key" "$val"
        first=0
      done
      printf '\n}\n'
    } >"$out_file"
  fi
}

# Validate a provenance JSON document: file exists, is valid JSON, contains all
# required fields, and SHA fields have the correct format.
ubuntu_provenance_validate() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  local jq_available=0
  command -v jq >/dev/null 2>&1 && jq_available=1

  if [[ "$jq_available" -eq 1 ]]; then
    # Verify the file is valid JSON.
    jq empty "$file" 2>/dev/null || return 1

    local field
    for field in "${UBUNTU_PROVENANCE_REQUIRED_FIELDS[@]}"; do
      local val
      val="$(jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)"
      [[ -n "$val" ]] || return 1
    done

    for field in "${UBUNTU_PROVENANCE_SHA_FIELDS[@]}"; do
      local val
      val="$(jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)"
      ubuntu_validate_sha "$val" || return 1
    done
  else
    # Fallback: grep-based validation when jq is not installed.
    local field
    for field in "${UBUNTU_PROVENANCE_REQUIRED_FIELDS[@]}"; do
      grep -Eq "\"${field}\"[[:space:]]*:" "$file" || return 1
    done
    for field in "${UBUNTU_PROVENANCE_SHA_FIELDS[@]}"; do
      local val
      val="$(grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
        | sed -E "s/.*:\"([^\"]*)\"/\1/")"
      ubuntu_validate_sha "$val" || return 1
    done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Parental-os git state (revision + dirty flag) for provenance recording.
# ---------------------------------------------------------------------------

ubuntu_parental_os_revision() {
  local root="${PARENTAL_OS_ROOT:-$(repo_root)}"
  git -C "$root" rev-parse --short HEAD 2>/dev/null || printf 'unknown\n'
}

ubuntu_parental_os_dirty() {
  local root="${PARENTAL_OS_ROOT:-$(repo_root)}"
  if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# ---------------------------------------------------------------------------
# Artifact normalization helpers
# ---------------------------------------------------------------------------

ubuntu_edition_out_dir() {
  local out
  out="$(out_root)"
  local edition="$1"
  printf '%s/ubuntu/%s\n' "$out" "$edition"
}

ubuntu_staging_dir() {
  local out
  out="$(out_root)"
  local edition="$1"
  printf '%s/ubuntu/staging/%s\n' "$out" "$edition"
}

ubuntu_validate_artifact_set() {
  local edition="$1" edition_dir="$2"
  ubuntu_is_valid_edition "$edition" || return 1
  [[ -d "$edition_dir" ]] || return 1

  local iso_basename
  iso_basename="$(ubuntu_metadata_value "$edition" iso_basename)" || return 1

  shopt -s nullglob
  local isos=("$edition_dir"/"$iso_basename"*.iso)
  shopt -u nullglob
  [[ "${#isos[@]}" -eq 1 ]] || return 1

  local iso="${isos[0]}"
  [[ -s "$iso" ]] || return 1
  [[ -f "$iso.sha256" ]] || return 1
  (cd "$edition_dir" && sha256sum -c "$(basename "$iso").sha256" >/dev/null 2>&1) || return 1

  local provenance="$edition_dir/provenance.json"
  [[ -s "$edition_dir/build.log" ]] || return 1
  [[ -s "$provenance" ]] || return 1
  ubuntu_provenance_validate "$provenance" || return 1
  if command -v jq >/dev/null 2>&1; then
    [[ "$(jq -r '.edition // empty' "$provenance" 2>/dev/null)" = "$edition" ]] || return 1
  else
    grep -Eq "\"edition\"[[:space:]]*:[[:space:]]*\"${edition}\"" "$provenance" || return 1
  fi
}
