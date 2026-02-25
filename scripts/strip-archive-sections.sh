#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

PREFIX=""
AR_BIN=""
OBJCOPY_BIN=""
RANLIB_BIN=""

# Print CLI usage and exit.
usage() {
  echo "usage: $0 <llvm-prefix>" >&2
  exit 1
}

# Parse and validate command-line arguments.
parse_args() {
  PREFIX="${1:-}"
  [[ -n "$PREFIX" && -d "$PREFIX" ]] || usage
}

# Resolve archive tooling, preferring tools from the provided prefix.
resolve_tools() {
  AR_BIN="${AR_BIN:-$PREFIX/bin/llvm-ar}"
  OBJCOPY_BIN="${OBJCOPY_BIN:-$PREFIX/bin/llvm-objcopy}"
  RANLIB_BIN="${RANLIB_BIN:-$PREFIX/bin/llvm-ranlib}"

  if [[ ! -x "$AR_BIN" ]]; then
    AR_BIN="$(command -v llvm-ar || command -v ar || true)"
  fi
  if [[ ! -x "$OBJCOPY_BIN" ]]; then
    OBJCOPY_BIN="$(command -v llvm-objcopy || command -v objcopy || true)"
  fi
  if [[ ! -x "$RANLIB_BIN" ]]; then
    RANLIB_BIN="$(command -v llvm-ranlib || command -v ranlib || true)"
  fi

  [[ -n "$AR_BIN" && -x "$AR_BIN" ]] || die "requires llvm-ar/ar"
  [[ -n "$OBJCOPY_BIN" && -x "$OBJCOPY_BIN" ]] || die "requires llvm-objcopy/objcopy"
  [[ -n "$RANLIB_BIN" && -x "$RANLIB_BIN" ]] || die "requires llvm-ranlib/ranlib"
}

# Rebuild a static archive with .deplibs/.linker-options removed from members.
sanitize_archive() {
  local archive="$1"

  local tmpdir=""
  tmpdir="$(mktemp -d)"

  if (
    cd "$tmpdir"
    cp "$archive" ./archive.a
    "$AR_BIN" x archive.a >/dev/null 2>&1 || true

    shopt -s nullglob
    local -a members=()
    local member
    for member in *; do
      [[ -f "$member" ]] || continue
      [[ "$member" == "archive.a" ]] && continue
      members+=("$member")
    done

    if [[ "${#members[@]}" -eq 0 ]]; then
      exit 0
    fi

    local obj
    for obj in "${members[@]}"; do
      "$OBJCOPY_BIN" \
        --remove-section=.deplibs \
        --remove-section=.linker-options \
        "$obj" >/dev/null 2>&1 || true
    done

    rm -f archive.a
    "$AR_BIN" qc archive.a "${members[@]}"
    "$RANLIB_BIN" archive.a
  ); then
    mv "$tmpdir/archive.a" "$archive"
  fi

  rm -rf "$tmpdir"
}

# Strip unsupported metadata sections from all static archives under prefix/lib.
main() {
  parse_args "$@"
  resolve_tools

  log "stripping .deplibs/.linker-options from static archives under $PREFIX"

  local -a archives=()
  mapfile -t archives < <(find "$PREFIX/lib" -type f -name '*.a' | sort)
  [[ "${#archives[@]}" -gt 0 ]] || die "no static archives found under $PREFIX/lib"

  local archive
  for archive in "${archives[@]}"; do
    sanitize_archive "$archive"
  done

  log "archive section stripping complete"
}

main "$@"
