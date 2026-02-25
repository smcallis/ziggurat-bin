#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly UTC_TS_FORMAT='+%Y-%m-%dT%H:%M:%SZ'

log() {
  printf '[%s] %s\n' "$(date -u "$UTC_TS_FORMAT")" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    require_cmd "$cmd"
  done
}

major_minor() {
  local version="$1"
  local major=""
  local minor=""
  IFS=. read -r major minor _ <<<"$version"
  [[ -n "$major" && -n "$minor" ]] || die "cannot parse major.minor from version: $version"
  printf '%s.%s\n' "$major" "$minor"
}

is_release_ref() {
  local ref="$1"
  [[ "$ref" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_release_ref() {
  local ref="$1"
  local allow_dev_refs="${ALLOW_DEV_REFS:-0}"

  if [[ "$allow_dev_refs" == "1" ]]; then
    return 0
  fi

  is_release_ref "$ref" || die "ZIG_REF must be an official release tag like 0.15.2 (got: $ref)"
}

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

apply_optional_override() {
  local var_name="$1"
  local override_value="$2"
  if [[ -n "$override_value" ]]; then
    printf -v "$var_name" '%s' "$override_value"
  fi
}

sync_repo_shallow() {
  local repo="$1"
  local ref="$2"
  local dir="$3"

  if [[ ! -d "$dir/.git" ]]; then
    log "cloning $repo@$ref"
    git clone --depth 1 --branch "$ref" "$repo" "$dir"
    return 0
  fi

  log "refreshing $dir to $ref"

  if git -C "$dir" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref" >/dev/null 2>&1; then
    git -C "$dir" checkout -f "tags/$ref" >/dev/null 2>&1
    return 0
  fi

  if git -C "$dir" fetch --depth 1 origin "$ref" >/dev/null 2>&1; then
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

cmake_build() {
  local build_dir="$1"
  shift

  local -a cmd=(cmake --build "$build_dir" "$@")
  if [[ -n "${BUILD_PARALLELISM:-}" ]]; then
    cmd+=(--parallel "$BUILD_PARALLELISM")
  fi

  "${cmd[@]}"
}

normalize_host_os() {
  local uname_s
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$uname_s" in
    linux) printf 'linux\n' ;;
    darwin) printf 'macos\n' ;;
    *) die "unsupported host OS: $uname_s" ;;
  esac
}

normalize_host_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "unsupported host arch: $uname_m" ;;
  esac
}

host_package_key() {
  local arch
  local os
  arch="$(normalize_host_arch)"
  os="$(normalize_host_os)"
  printf '%s-%s\n' "$arch" "$os"
}
