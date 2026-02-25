#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

LLVM_PREFIX=""
ZIG_PREFIX=""
AR_BIN=""
OBJDUMP_BIN=""

usage() {
  echo "usage: $0 <llvm-prefix> <zig-prefix>" >&2
  exit 1
}

parse_args() {
  LLVM_PREFIX="${1:-}"
  ZIG_PREFIX="${2:-}"
  [[ -n "$LLVM_PREFIX" && -n "$ZIG_PREFIX" ]] || usage
}

assert_inputs() {
  [[ -x "$LLVM_PREFIX/bin/llvm-config" ]] || die "expected llvm-config at $LLVM_PREFIX/bin/llvm-config"
  [[ -x "$ZIG_PREFIX/bin/zig" ]] || die "expected zig binary at $ZIG_PREFIX/bin/zig"
}

resolve_archive_tools() {
  OBJDUMP_BIN="${OBJDUMP_BIN:-$LLVM_PREFIX/bin/llvm-objdump}"
  AR_BIN="${AR_BIN:-$LLVM_PREFIX/bin/llvm-ar}"

  if [[ ! -x "$OBJDUMP_BIN" ]]; then
    OBJDUMP_BIN="$(command -v llvm-objdump || command -v objdump || true)"
  fi
  if [[ ! -x "$AR_BIN" ]]; then
    AR_BIN="$(command -v llvm-ar || command -v ar || true)"
  fi

  [[ -n "$OBJDUMP_BIN" && -x "$OBJDUMP_BIN" ]] || die "requires llvm-objdump/objdump"
  [[ -n "$AR_BIN" && -x "$AR_BIN" ]] || die "requires llvm-ar/ar"
}

verify_llvm_zig_version_match() {
  local llvm_version=""
  local zig_version=""
  local zig_cc_version_line=""
  local zig_cc_llvm=""

  llvm_version="$("$LLVM_PREFIX/bin/llvm-config" --version | tr -d '[:space:]')"
  zig_version="$("$ZIG_PREFIX/bin/zig" version | tr -d '[:space:]')"
  zig_cc_version_line="$("$ZIG_PREFIX/bin/zig" cc --version | head -n1)"
  zig_cc_llvm="$(printf '%s\n' "$zig_cc_version_line" | sed -nE 's/^clang version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')"

  [[ -n "$zig_cc_llvm" ]] || die "unable to parse zig cc clang version from: $zig_cc_version_line"

  if [[ "$(major_minor "$llvm_version")" != "$(major_minor "$zig_cc_llvm")" ]]; then
    die "LLVM/Zig mismatch: llvm-config=$llvm_version zig-cc-clang=$zig_cc_llvm"
  fi

  log "verified matching LLVM major.minor: $(major_minor "$llvm_version") (zig=$zig_version)"
}

archive_has_forbidden_sections() {
  local archive="$1"

  local tmpdir=""
  tmpdir="$(mktemp -d)"

  if ! (
    cd "$tmpdir"
    cp "$archive" ./archive.a
    "$AR_BIN" x archive.a >/dev/null 2>&1 || true

    shopt -s nullglob
    local obj
    for obj in *; do
      [[ -f "$obj" ]] || continue
      if "$OBJDUMP_BIN" -h "$obj" 2>/dev/null | grep -Eq '\.deplibs|\.linker-options'; then
        echo "forbidden section in $archive member $obj" >&2
        exit 1
      fi
    done
  ); then
    rm -rf "$tmpdir"
    return 0
  fi

  rm -rf "$tmpdir"
  return 1
}

verify_archive_sections() {
  local -a archives=()
  mapfile -t archives < <(find "$LLVM_PREFIX/lib" -type f -name '*.a' | sort)
  [[ "${#archives[@]}" -gt 0 ]] || die "no static archives found under $LLVM_PREFIX/lib"

  local archive
  for archive in "${archives[@]}"; do
    if archive_has_forbidden_sections "$archive"; then
      return 1
    fi
  done

  return 0
}

main() {
  parse_args "$@"
  assert_inputs
  resolve_archive_tools
  verify_llvm_zig_version_match

  verify_archive_sections || die "static archive verification failed"
  log "verified static archives are free of .deplibs/.linker-options"
}

main "$@"
