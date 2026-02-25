#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

LLVM_PREFIX=""
ZIG_PREFIX=""
OUT_DIR=""
PKG_KEY=""
LLVM_VERSION=""
ZIG_VERSION=""
TOOLCHAIN_NAME=""
PKG_ROOT=""

usage() {
  echo "usage: $0 <llvm-prefix> <zig-prefix> <out-dir> <pkg-key> <llvm-version> <zig-version> [toolchain-name]" >&2
  exit 1
}

parse_args() {
  LLVM_PREFIX="${1:-}"
  ZIG_PREFIX="${2:-}"
  OUT_DIR="${3:-}"
  PKG_KEY="${4:-}"
  LLVM_VERSION="${5:-}"
  ZIG_VERSION="${6:-}"
  TOOLCHAIN_NAME="${7:-zig-llvm-toolchain}"

  [[ -n "$LLVM_PREFIX" && -n "$ZIG_PREFIX" && -n "$OUT_DIR" && -n "$PKG_KEY" ]] || usage
}

copy_if_exists() {
  local src_root="$1"
  local rel="$2"
  local dest_root="$3"

  if [[ -e "$src_root/$rel" ]]; then
    mkdir -p "$(dirname "$dest_root/$rel")"
    cp -a "$src_root/$rel" "$dest_root/$rel"
  fi
}

copy_glob_matches() {
  local src_root="$1"
  local pattern="$2"
  local dest_root="$3"

  while IFS= read -r match; do
    local rel="${match#"$src_root"/}"
    mkdir -p "$(dirname "$dest_root/$rel")"
    cp -a "$match" "$dest_root/$rel"
  done < <(compgen -G "$src_root/$pattern" || true)
}

copy_minimal_llvm_payload() {
  local llvm_binaries="${LLVM_BINARIES:-clang clang++ ld.lld llvm-ar llvm-ranlib llvm-objcopy llvm-objdump llvm-symbolizer llvm-profdata llvm-cov}"
  local llvm_dirs="${LLVM_DIRS:-lib/clang}"
  local llvm_lib_globs="${LLVM_LIB_GLOBS:-lib/libclang*.a lib/liblld*.a lib/libz*.a lib/libLLVM*.a lib/libc++*.a lib/libc++*.so* lib/libunwind*.a lib/libunwind*.so*}"

  mkdir -p "$PKG_ROOT/llvm/bin" "$PKG_ROOT/llvm/lib"

  local bin
  for bin in $llvm_binaries; do
    copy_if_exists "$LLVM_PREFIX" "bin/$bin" "$PKG_ROOT/llvm"
  done

  local rel
  for rel in $llvm_dirs; do
    copy_if_exists "$LLVM_PREFIX" "$rel" "$PKG_ROOT/llvm"
  done

  local lib_glob
  for lib_glob in $llvm_lib_globs; do
    copy_glob_matches "$LLVM_PREFIX" "$lib_glob" "$PKG_ROOT/llvm"
  done
}

write_manifest() {
  local manifest="$PKG_ROOT/manifest.json"

  cat > "$manifest" <<JSON
{
  "toolchain_name": "${TOOLCHAIN_NAME}",
  "package_key": "${PKG_KEY}",
  "llvm_version": "${LLVM_VERSION}",
  "zig_version": "${ZIG_VERSION}",
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

  log "wrote manifest: $manifest"
}

create_archive() {
  local archive="$OUT_DIR/${TOOLCHAIN_NAME}-${PKG_KEY}.tar.xz"
  tar -C "$OUT_DIR" -cf - "${TOOLCHAIN_NAME}-${PKG_KEY}" | xz -T0 -9e -c > "$archive"
  log "wrote package: $archive"
}

main() {
  parse_args "$@"
  mkdir -p "$OUT_DIR"

  PKG_ROOT="$OUT_DIR/${TOOLCHAIN_NAME}-${PKG_KEY}"
  rm -rf "$PKG_ROOT"
  mkdir -p "$PKG_ROOT"

  if [[ "${LLVM_PACKAGE_MODE:-minimal}" == "full" ]]; then
    cp -a "$LLVM_PREFIX" "$PKG_ROOT/llvm"
  else
    copy_minimal_llvm_payload
  fi

  cp -a "$ZIG_PREFIX" "$PKG_ROOT/zig"

  write_manifest
  create_archive
}

main "$@"
