#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly UTC_TS_FORMAT='+%Y-%m-%dT%H:%M:%SZ'

# Print a timestamped log line in UTC.
log() {
  printf '[%s] %s\n' "$(date -u "$UTC_TS_FORMAT")" "$*"
}

# Print an error and exit non-zero.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Ensure a single command is available on PATH.
require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

# Ensure all listed commands are available on PATH.
require_cmds() {
  local cmd
  for cmd in "$@"; do
    require_cmd "$cmd"
  done
}

# Retry a command a fixed number of times with a constant delay.
retry_cmd() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  [[ "$attempts" =~ ^[0-9]+$ && "$attempts" -gt 0 ]] || die "retry attempts must be a positive integer (got: $attempts)"
  [[ "$delay_seconds" =~ ^[0-9]+$ ]] || die "retry delay must be a non-negative integer (got: $delay_seconds)"
  [[ "$#" -gt 0 ]] || die "retry_cmd requires a command"

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if (( attempt >= attempts )); then
      return 1
    fi

    log "command failed (attempt $attempt/$attempts), retrying in ${delay_seconds}s"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

# Extract "major.minor" from a semantic version string.
major_minor() {
  local version="$1"
  local major=""
  local minor=""
  IFS=. read -r major minor _ <<<"$version"
  [[ -n "$major" && -n "$minor" ]] || die "cannot parse major.minor from version: $version"
  printf '%s.%s\n' "$major" "$minor"
}

# Return success when a ref matches an official Zig release tag (X.Y.Z).
is_release_ref() {
  local ref="$1"
  [[ "$ref" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Enforce release-only Zig refs unless ALLOW_DEV_REFS=1 is set.
validate_release_ref() {
  local ref="$1"
  local allow_dev_refs="${ALLOW_DEV_REFS:-0}"

  if [[ "$allow_dev_refs" == "1" ]]; then
    return 0
  fi

  is_release_ref "$ref" || die "ZIG_REF must be an official release tag like 0.15.2 (got: $ref)"
}

# Load toolchain configuration and validate required keys.
load_config() {
  local cfg="${1:-$ROOT_DIR/toolchain.env}"
  [[ -f "$cfg" ]] || die "missing config file: $cfg"

  # shellcheck disable=SC1090
  source "$cfg"

  : "${LLVM_REPO:?must be set in toolchain.env}"
  : "${LLVM_REF:?must be set in toolchain.env}"
  : "${ZIG_REPO:?must be set in toolchain.env}"
  : "${ZIG_REF:?must be set in toolchain.env}"
  : "${TARGET_TRIPLE:?must be set in toolchain.env}"
  : "${TARGET_CPU:?must be set in toolchain.env}"
  : "${TOOLCHAIN_NAME:?must be set in toolchain.env}"
}

# Override a shell variable when an override value is provided.
apply_optional_override() {
  local var_name="$1"
  local override_value="$2"
  if [[ -n "$override_value" ]]; then
    printf -v "$var_name" '%s' "$override_value"
  fi
}

# Clone or refresh a repository at a specific ref with depth=1.
sync_repo_shallow() {
  local repo="$1"
  local ref="$2"
  local dir="$3"
  local sync_attempts="${SYNC_REPO_MAX_ATTEMPTS:-3}"
  local sync_retry_delay="${SYNC_REPO_RETRY_DELAY_SEC:-3}"

  if [[ ! -d "$dir/.git" ]]; then
    log "cloning $repo@$ref"
    retry_cmd "$sync_attempts" "$sync_retry_delay" \
      git clone --depth 1 --branch "$ref" "$repo" "$dir" \
      || die "failed to clone $repo@$ref after $sync_attempts attempts"
    return 0
  fi

  log "refreshing $dir to $ref"

  if retry_cmd "$sync_attempts" "$sync_retry_delay" \
    git -C "$dir" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref" >/dev/null 2>&1; then
    git -C "$dir" checkout -f "tags/$ref" >/dev/null 2>&1
    return 0
  fi

  if retry_cmd "$sync_attempts" "$sync_retry_delay" \
    git -C "$dir" fetch --depth 1 origin "$ref" >/dev/null 2>&1; then
    git -C "$dir" checkout -f FETCH_HEAD >/dev/null 2>&1
    return 0
  fi

  if git -C "$dir" checkout -f "tags/$ref" >/dev/null 2>&1; then
    log "offline fallback for $dir: using local tag $ref"
    return 0
  fi

  if git -C "$dir" checkout -f "$ref" >/dev/null 2>&1; then
    log "offline fallback for $dir: using local ref $ref"
    return 0
  fi

  die "unable to refresh $dir to $ref: network fetch failed and ref is unavailable locally"
}

# Run a CMake build with optional BUILD_PARALLELISM override.
cmake_build() {
  local build_dir="$1"
  shift

  local -a cmd=(cmake --build "$build_dir" "$@")
  if [[ -n "${BUILD_PARALLELISM:-}" ]]; then
    cmd+=(--parallel "$BUILD_PARALLELISM")
  fi

  "${cmd[@]}"
}

# Normalize uname OS values to packaging OS names.
normalize_host_os() {
  local uname_s
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$uname_s" in
    linux) printf 'linux\n' ;;
    darwin) printf 'macos\n' ;;
    *) die "unsupported host OS: $uname_s" ;;
  esac
}

# Normalize uname arch values to packaging architecture names.
normalize_host_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "unsupported host arch: $uname_m" ;;
  esac
}

# Build the host package key used in release metadata.
host_package_key() {
  local arch
  local os
  arch="$(normalize_host_arch)"
  os="$(normalize_host_os)"
  printf '%s-%s\n' "$arch" "$os"
}
