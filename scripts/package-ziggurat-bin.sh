#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ZIG_PREFIX=""
LLVM_PREFIX=""
MOLD_PREFIX=""
OUT_DIR=""
PKG_KEY=""
PAYLOAD_NAME=""
PACKAGE_BASENAME=""
PKG_ROOT=""

# Print CLI usage and exit.
usage() {
  cat >&2 <<USAGE
usage: $0 <zig-prefix> <llvm-prefix> <mold-prefix|-> <out-dir> <pkg-key> [payload-name] [package-basename]
USAGE
  exit 1
}

# Parse and validate command-line arguments.
parse_args() {
  ZIG_PREFIX="${1:-}"
  LLVM_PREFIX="${2:-}"
  MOLD_PREFIX="${3:-}"
  OUT_DIR="${4:-}"
  PKG_KEY="${5:-}"
  PAYLOAD_NAME="${6:-ziggurat-bin}"
  PACKAGE_BASENAME="${7:-}"

  [[ -n "$ZIG_PREFIX" && -n "$LLVM_PREFIX" && -n "$MOLD_PREFIX" && -n "$OUT_DIR" && -n "$PKG_KEY" ]] || usage
}

# Ensure tooling required to package/compress artifacts is available.
require_packaging_dependencies() {
  require_cmds tar xz find
}

# Verify expected build outputs exist before packaging starts.
assert_inputs() {
  [[ -x "$ZIG_PREFIX/bin/zig" ]] || die "missing zig binary at $ZIG_PREFIX/bin/zig"
  [[ -d "$ZIG_PREFIX/lib" ]] || die "missing zig lib directory at $ZIG_PREFIX/lib"
  [[ -d "$LLVM_PREFIX/bin" ]] || die "missing llvm bin directory at $LLVM_PREFIX/bin"
  [[ -d "$LLVM_PREFIX/lib" ]] || die "missing llvm lib directory at $LLVM_PREFIX/lib"
}

# Resolve the output directory name used inside dist/.
package_base_name() {
  if [[ -n "$PACKAGE_BASENAME" ]]; then
    printf '%s\n' "$PACKAGE_BASENAME"
    return 0
  fi
  printf '%s\n' "${PAYLOAD_NAME}-${PKG_KEY}"
}

# Copy one required file into the package root.
copy_required_file() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] || die "missing required file: $src"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

# Copy one required binary and dereference symlinks to real files.
copy_required_binary() {
  local requested_name="$1"
  local dest_name="${2:-$requested_name}"
  local primary_path="$LLVM_PREFIX/bin/$requested_name"

  if [[ -e "$primary_path" ]]; then
    mkdir -p "$PKG_ROOT/bin"
    cp -L "$primary_path" "$PKG_ROOT/bin/$dest_name"
    return 0
  fi

  case "$requested_name" in
    llvm-lld)
      local fallback_path="$LLVM_PREFIX/bin/lld"
      [[ -e "$fallback_path" ]] || die "missing required file: $primary_path (and fallback $fallback_path)"
      mkdir -p "$PKG_ROOT/bin"
      cp -L "$fallback_path" "$PKG_ROOT/bin/$dest_name"
      return 0
      ;;
  esac

  die "missing required file: $primary_path"
}

# Copy one required directory recursively.
copy_required_dir() {
  local src="$1"
  local dst="$2"
  [[ -d "$src" ]] || die "missing required directory: $src"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
}

# Copy Zig binary plus Zig standard library/runtime files.
copy_zig_payload() {
  copy_required_file "$ZIG_PREFIX/bin/zig" "$PKG_ROOT/zig"

  if [[ -d "$ZIG_PREFIX/lib/zig" ]]; then
    copy_required_dir "$ZIG_PREFIX/lib/zig" "$PKG_ROOT/lib"
  else
    copy_required_dir "$ZIG_PREFIX/lib" "$PKG_ROOT/lib"
  fi
}

# Copy required LLVM/Clang executables listed by PAYLOAD_LLVM_BINARIES.
copy_llvm_binaries() {
  local llvm_bins="${PAYLOAD_LLVM_BINARIES:-ld.lld llvm-ar llvm-ranlib llvm-objcopy llvm-objdump llvm-symbolizer llvm-profdata llvm-cov llvm-cxxfilt llvm-lld llvm-mca llvm-nm llvm-xray clangd clang-format clang-tidy}"

  local bin
  for bin in $llvm_bins; do
    copy_required_binary "$bin"
  done
}

# Copy required LLVM runtime directories (usually lib/clang tree).
copy_llvm_directories() {
  local llvm_dirs="${PAYLOAD_LLVM_DIRS:-lib/clang}"

  local rel
  for rel in $llvm_dirs; do
    copy_required_dir "$LLVM_PREFIX/$rel" "$PKG_ROOT/$rel"
  done
}

# Copy selected static C++ runtime libraries used by downstream builds.
copy_static_runtime_libraries() {
  local static_libs="${PAYLOAD_LLVM_STATIC_LIBS:-lib/libc++.a lib/libc++abi.a lib/libunwind.a}"

  local rel
  for rel in $static_libs; do
    copy_required_file "$LLVM_PREFIX/$rel" "$PKG_ROOT/$rel"
  done
}

# Copy libclang_rt.fuzzer.a as a canonical lib/libFuzzer.a alias.
copy_libfuzzer_alias() {
  local preferred=""
  local fallback=""

  preferred="$(find "$LLVM_PREFIX/lib/clang" -type f -path '*/x86_64-unknown-linux-gnu/libclang_rt.fuzzer.a' | head -n1 || true)"
  fallback="$(find "$LLVM_PREFIX/lib/clang" -type f -name 'libclang_rt.fuzzer.a' | head -n1 || true)"

  local selected="${preferred:-$fallback}"
  [[ -n "$selected" ]] || die "unable to locate libclang_rt.fuzzer.a under $LLVM_PREFIX/lib/clang"

  copy_required_file "$selected" "$PKG_ROOT/lib/libFuzzer.a"
}

# Copy mold into payload when enabled/required.
copy_mold_binary() {
  local require_mold="${PAYLOAD_REQUIRE_MOLD:-1}"

  if [[ "$MOLD_PREFIX" == "-" ]]; then
    if [[ "$require_mold" == "1" ]]; then
      die "mold is required but build disabled (MOLD_PREFIX='-')"
    fi
    log "skipping mold in payload"
    return 0
  fi

  copy_required_file "$MOLD_PREFIX/bin/mold" "$PKG_ROOT/bin/mold"
}

# Validate that the assembled payload has required binaries and libraries.
verify_payload() {
  [[ -x "$PKG_ROOT/zig" ]] || die "payload verification failed: missing executable zig"
  [[ -d "$PKG_ROOT/lib" ]] || die "payload verification failed: missing lib directory"

  local llvm_bins="${PAYLOAD_LLVM_BINARIES:-ld.lld llvm-ar llvm-ranlib llvm-objcopy llvm-objdump llvm-symbolizer llvm-profdata llvm-cov llvm-cxxfilt llvm-lld llvm-mca llvm-nm llvm-xray clangd clang-format clang-tidy}"
  local bin
  for bin in $llvm_bins; do
    [[ -f "$PKG_ROOT/bin/$bin" ]] || die "payload verification failed: missing bin/$bin"
  done

  [[ -f "$PKG_ROOT/lib/libc++.a" ]] || die "payload verification failed: missing lib/libc++.a"
  [[ -f "$PKG_ROOT/lib/libc++abi.a" ]] || die "payload verification failed: missing lib/libc++abi.a"
  [[ -f "$PKG_ROOT/lib/libunwind.a" ]] || die "payload verification failed: missing lib/libunwind.a"
  [[ -f "$PKG_ROOT/lib/libFuzzer.a" ]] || die "payload verification failed: missing lib/libFuzzer.a"
}

# Create compressed release archive for the payload directory.
create_archive() {
  local archive_basename="$1"
  local archive="$OUT_DIR/$archive_basename.tar.xz"

  tar -C "$OUT_DIR" -cf - "$archive_basename" | xz -T0 -9e -c > "$archive"
  log "wrote ziggurat payload: $archive"
}

# Build payload directory, verify it, and emit the final .tar.xz archive.
main() {
  parse_args "$@"
  require_packaging_dependencies
  assert_inputs

  # Prepare a clean payload directory.
  mkdir -p "$OUT_DIR"

  local pkg_base=""
  pkg_base="$(package_base_name)"

  PKG_ROOT="$OUT_DIR/$pkg_base"
  rm -rf "$PKG_ROOT"
  mkdir -p "$PKG_ROOT"

  # Populate payload from Zig, LLVM, and optional mold outputs.
  copy_zig_payload
  copy_llvm_binaries
  copy_llvm_directories
  copy_static_runtime_libraries
  copy_libfuzzer_alias
  copy_mold_binary

  # Validate payload layout before archiving.
  verify_payload
  create_archive "$pkg_base"
}

main "$@"
