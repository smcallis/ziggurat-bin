#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK_DIR=""
DIST_DIR=""
PKG_KEY=""
PAYLOAD_NAME=""
EMIT_TOOLCHAIN_ARCHIVE=""
RELEASE_ARCHIVE_NAME=""

LLVM_SRC_DIR=""
LLVM_RT_BUILD_DIR=""
LLVM_RT_PREFIX=""
LLVM_BUILD_DIR=""
LLVM_PREFIX=""

ZIG_SRC_DIR=""
ZIG_BUILD_DIR=""
ZIG_PREFIX=""

MOLD_SRC_DIR=""
MOLD_BUILD_DIR=""
MOLD_PREFIX="-"

ZIG_GLOBAL_CACHE_DIR=""
XDG_CACHE_HOME=""

BOOTSTRAP_CC=""
BOOTSTRAP_CXX=""

LLVM_VERSION=""
ZIG_VERSION=""

canonical_tool_name() {
  local name="$1"
  name="${name//-/_}"
  printf '%s' "${name^^}"
}

add_tool_build_flags() {
  local -n cmake_args_ref="$1"
  local option_prefix="$2"
  local source_root="$3"
  shift 3

  local -a allowed_tools=("$@")
  local -A allow_map=()
  local tool=""
  local key=""

  for tool in "${allowed_tools[@]}"; do
    key="$(canonical_tool_name "$tool")"
    allow_map["$key"]=1
    cmake_args_ref+=("-D${option_prefix}_${key}_BUILD=ON")
  done

  local dir=""
  local dir_name=""
  local dir_key=""
  shopt -s nullglob
  for dir in "$source_root"/*; do
    [[ -d "$dir" && -f "$dir/CMakeLists.txt" ]] || continue
    dir_name="$(basename "$dir")"
    dir_key="$(canonical_tool_name "$dir_name")"
    if [[ -z "${allow_map[$dir_key]+x}" ]]; then
      cmake_args_ref+=("-D${option_prefix}_${dir_key}_BUILD=OFF")
    fi
  done
  shopt -u nullglob
}

configure_runtime_paths() {
  WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work}"
  DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
  PKG_KEY="${TARGET_TRIPLE}-${TARGET_CPU}"
  PAYLOAD_NAME="${PAYLOAD_NAME:-ziggurat-bin}"
  EMIT_TOOLCHAIN_ARCHIVE="${EMIT_TOOLCHAIN_ARCHIVE:-0}"
  RELEASE_ARCHIVE_NAME="${RELEASE_ARCHIVE_NAME:-}"

  ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$WORK_DIR/zig-global-cache}"
  XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORK_DIR/xdg-cache}"

  LLVM_SRC_DIR="$WORK_DIR/llvm-project"
  LLVM_RT_BUILD_DIR="$WORK_DIR/build-llvm-runtimes"
  LLVM_RT_PREFIX="$WORK_DIR/install-llvm-runtimes"
  LLVM_BUILD_DIR="$WORK_DIR/build-llvm"
  LLVM_PREFIX="$WORK_DIR/install-llvm"

  ZIG_SRC_DIR="$WORK_DIR/zig"
  ZIG_BUILD_DIR="$WORK_DIR/build-zig"
  ZIG_PREFIX="$WORK_DIR/install-zig"

  MOLD_SRC_DIR="$WORK_DIR/mold"
  MOLD_BUILD_DIR="$WORK_DIR/build-mold"
  MOLD_PREFIX="$WORK_DIR/install-mold"

  mkdir -p "$WORK_DIR" "$DIST_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$XDG_CACHE_HOME"
}

load_and_validate_config() {
  load_config "${TOOLCHAIN_CONFIG:-$ROOT_DIR/toolchain.env}"
  apply_optional_override LLVM_REF "${LLVM_REF_OVERRIDE:-}"
  apply_optional_override ZIG_REF "${ZIG_REF_OVERRIDE:-}"
  validate_release_ref "$ZIG_REF"
}

require_build_dependencies() {
  require_cmds git cmake ninja python3 tar xz clang clang++ find
}

sync_sources() {
  sync_repo_shallow "$LLVM_REPO" "$LLVM_REF" "$LLVM_SRC_DIR"
  sync_repo_shallow "$ZIG_REPO" "$ZIG_REF" "$ZIG_SRC_DIR"

  if [[ "${BUILD_MOLD:-1}" == "1" ]]; then
    : "${MOLD_REPO:=https://github.com/rui314/mold.git}"
    : "${MOLD_REF:=v2.4.0}"
    sync_repo_shallow "$MOLD_REPO" "$MOLD_REF" "$MOLD_SRC_DIR"
  else
    MOLD_PREFIX="-"
  fi
}

clean_previous_outputs() {
  rm -rf \
    "$LLVM_RT_BUILD_DIR" \
    "$LLVM_RT_PREFIX" \
    "$LLVM_BUILD_DIR" \
    "$LLVM_PREFIX" \
    "$ZIG_BUILD_DIR" \
    "$ZIG_PREFIX" \
    "$MOLD_BUILD_DIR"

  if [[ "$MOLD_PREFIX" != "-" ]]; then
    rm -rf "$MOLD_PREFIX"
  fi
}

configure_bootstrap_compilers() {
  BOOTSTRAP_CC="${BOOTSTRAP_CC:-$(command -v clang)}"
  BOOTSTRAP_CXX="${BOOTSTRAP_CXX:-$(command -v clang++)}"
  [[ -n "$BOOTSTRAP_CC" && -n "$BOOTSTRAP_CXX" ]] || die "unable to resolve bootstrap clang/clang++"

  log "using bootstrap compilers: CC=$BOOTSTRAP_CC CXX=$BOOTSTRAP_CXX"
}

build_bootstrap_runtimes() {
  log "bootstrapping libc++ runtimes for llvm build"

  local -a runtimes_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$BOOTSTRAP_CC"
    -DCMAKE_CXX_COMPILER="$BOOTSTRAP_CXX"
    -DCMAKE_INSTALL_PREFIX="$LLVM_RT_PREFIX"
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF
    -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBUNWIND_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF
    -DLIBCXX_INCLUDE_DOCS=OFF
  )

  cmake -S "$LLVM_SRC_DIR/runtimes" -B "$LLVM_RT_BUILD_DIR" "${runtimes_args[@]}"
  cmake_build "$LLVM_RT_BUILD_DIR"
  cmake --install "$LLVM_RT_BUILD_DIR"

  [[ -d "$LLVM_RT_PREFIX/include/c++/v1" ]] || die "missing libc++ headers at $LLVM_RT_PREFIX/include/c++/v1"
}

build_llvm() {
  log "configuring llvm ($LLVM_REF)"

  local llvm_libcxx_cxx_flags="-stdlib=libc++ -isystem $LLVM_RT_PREFIX/include/c++/v1"
  local llvm_libcxx_link_flags="-stdlib=libc++ -L$LLVM_RT_PREFIX/lib"

  local -a llvm_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$BOOTSTRAP_CC"
    -DCMAKE_CXX_COMPILER="$BOOTSTRAP_CXX"
    -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX"
    -DCMAKE_PREFIX_PATH="$LLVM_RT_PREFIX"
    -DCMAKE_CXX_FLAGS="$llvm_libcxx_cxx_flags"
    -DCMAKE_EXE_LINKER_FLAGS="$llvm_libcxx_link_flags"
    -DCMAKE_SHARED_LINKER_FLAGS="$llvm_libcxx_link_flags"
    -DCMAKE_MODULE_LINKER_FLAGS="$llvm_libcxx_link_flags"
    -DCMAKE_BUILD_RPATH="$LLVM_RT_PREFIX/lib"
    -DCMAKE_INSTALL_RPATH=\$ORIGIN/../lib
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"
    -DLLVM_ENABLE_LIBCXX=ON
    -DLLVM_ENABLE_RUNTIMES="${LLVM_ENABLE_RUNTIMES:-compiler-rt}"
    -DLLVM_ENABLE_BINDINGS=OFF
    -DLLVM_ENABLE_LIBEDIT=OFF
    -DLLVM_ENABLE_LIBXML2=OFF
    -DLLVM_ENABLE_Z3_SOLVER=OFF
    -DLLVM_ENABLE_ZSTD=OFF
    -DLLVM_INCLUDE_UTILS=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DCLANG_DEFAULT_CXX_STDLIB=libc++
    -DCLANG_BUILD_TOOLS=ON
    -DCLANG_ENABLE_ARCMT=OFF
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF
    -DCLANG_INCLUDE_DOCS=OFF
    -DCLANG_INCLUDE_TESTS=OFF
    -DLLD_BUILD_TOOLS=ON
  )

  if [[ ";${LLVM_ENABLE_RUNTIMES:-compiler-rt};" == *";compiler-rt;"* ]]; then
    llvm_args+=(
      -DCOMPILER_RT_BUILD_BUILTINS="${COMPILER_RT_BUILD_BUILTINS:-ON}"
      -DCOMPILER_RT_BUILD_SANITIZERS="${COMPILER_RT_BUILD_SANITIZERS:-ON}"
      -DCOMPILER_RT_BUILD_LIBFUZZER="${COMPILER_RT_BUILD_LIBFUZZER:-ON}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY="${COMPILER_RT_DEFAULT_TARGET_ONLY:-OFF}"
      -DCOMPILER_RT_BUILD_PROFILE="${COMPILER_RT_BUILD_PROFILE:-OFF}"
      -DCOMPILER_RT_BUILD_XRAY="${COMPILER_RT_BUILD_XRAY:-OFF}"
      -DCOMPILER_RT_BUILD_MEMPROF="${COMPILER_RT_BUILD_MEMPROF:-OFF}"
      -DCOMPILER_RT_BUILD_ORC="${COMPILER_RT_BUILD_ORC:-OFF}"
      -DCOMPILER_RT_BUILD_GWP_ASAN="${COMPILER_RT_BUILD_GWP_ASAN:-OFF}"
      -DCOMPILER_RT_BUILD_CTX_PROFILE="${COMPILER_RT_BUILD_CTX_PROFILE:-OFF}"
    )
  fi

  if [[ -n "${LLVM_TARGETS_TO_BUILD:-}" ]]; then
    llvm_args+=("-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS_TO_BUILD}")
  fi

  local llvm_required_tools="${LLVM_REQUIRED_TOOLS:-llvm-ar llvm-config llvm-cov llvm-cxxfilt llvm-mca llvm-nm llvm-objcopy llvm-objdump llvm-profdata llvm-ranlib llvm-symbolizer llvm-xray}"
  local -a llvm_required_tools_array=()
  # shellcheck disable=SC2206
  llvm_required_tools_array=($llvm_required_tools)

  add_tool_build_flags llvm_args "LLVM_TOOL" "$LLVM_SRC_DIR/llvm/tools" "${llvm_required_tools_array[@]}"
  llvm_args+=(
    -DLLVM_TOOL_CLANG_BUILD=ON
    -DLLVM_TOOL_LLD_BUILD=ON
  )

  # Keep clang tools minimal and explicitly enable only required front-end tools.
  local -a clang_required_root_tools=(
    driver
    clang-format
  )
  add_tool_build_flags llvm_args "CLANG_TOOL" "$LLVM_SRC_DIR/clang/tools" "${clang_required_root_tools[@]}"

  local -a clang_extra_required_tools=(
    clangd
    clang-tidy
  )
  add_tool_build_flags llvm_args "CLANG_TOOL" "$LLVM_SRC_DIR/clang-tools-extra" "${clang_extra_required_tools[@]}"

  cmake -S "$LLVM_SRC_DIR/llvm" -B "$LLVM_BUILD_DIR" "${llvm_args[@]}"
  cmake_build "$LLVM_BUILD_DIR" --target install
  install_compiler_rt_runtimes
  ensure_llvm_config_aliases
}

install_compiler_rt_runtimes() {
  if [[ ";${LLVM_ENABLE_RUNTIMES:-compiler-rt};" != *";compiler-rt;"* ]]; then
    return
  fi

  log "installing compiler-rt runtime artifacts"
  cmake_build "$LLVM_BUILD_DIR" --target install-runtimes

  local rt_prefix="$LLVM_BUILD_DIR/runtimes/runtimes-bins"
  local rt_clang_dir="$rt_prefix/lib/clang"
  [[ -d "$rt_clang_dir" ]] || die "missing compiler-rt runtime tree: $rt_clang_dir"

  mkdir -p "$LLVM_PREFIX/lib/clang"
  cp -a "$rt_clang_dir/." "$LLVM_PREFIX/lib/clang/"
}

merge_bootstrap_runtimes_into_llvm_prefix() {
  log "merging bootstrap libc++ runtimes into llvm prefix"

  mkdir -p "$LLVM_PREFIX/include" "$LLVM_PREFIX/lib"
  cp -a "$LLVM_RT_PREFIX/include/." "$LLVM_PREFIX/include/"

  shopt -s nullglob
  local lib
  for lib in \
    "$LLVM_RT_PREFIX"/lib/libc++* \
    "$LLVM_RT_PREFIX"/lib/libc++abi* \
    "$LLVM_RT_PREFIX"/lib/libunwind*; do
    cp -a "$lib" "$LLVM_PREFIX/lib/"
  done
  shopt -u nullglob
}

sanitize_single_archive() {
  local archive="$1"
  local ar_bin="$2"
  local objcopy_bin="$3"
  local ranlib_bin="$4"

  local tmpdir=""
  tmpdir="$(mktemp -d)"

  if (
    cd "$tmpdir"
    cp "$archive" ./archive.a
    "$ar_bin" x archive.a >/dev/null 2>&1 || true

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
      "$objcopy_bin" \
        --remove-section=.deplibs \
        --remove-section=.linker-options \
        "$obj" >/dev/null 2>&1 || true
    done

    rm -f archive.a
    "$ar_bin" qc archive.a "${members[@]}"
    "$ranlib_bin" archive.a
  ); then
    mv "$tmpdir/archive.a" "$archive"
  fi

  rm -rf "$tmpdir"
}

sanitize_llvm_archives() {
  log "stripping .deplibs/.linker-options from llvm static archives"

  local ar_bin="${AR_BIN:-$LLVM_PREFIX/bin/llvm-ar}"
  local objcopy_bin="${OBJCOPY_BIN:-$LLVM_PREFIX/bin/llvm-objcopy}"
  local ranlib_bin="${RANLIB_BIN:-$LLVM_PREFIX/bin/llvm-ranlib}"

  [[ -x "$ar_bin" ]] || die "missing archive tool: $ar_bin"
  [[ -x "$objcopy_bin" ]] || die "missing objcopy tool: $objcopy_bin"
  [[ -x "$ranlib_bin" ]] || die "missing ranlib tool: $ranlib_bin"

  local -a archives=()
  mapfile -t archives < <(find "$LLVM_PREFIX/lib" -type f -name '*.a' | sort)
  [[ "${#archives[@]}" -gt 0 ]] || die "no static archives found under $LLVM_PREFIX/lib"

  local archive
  for archive in "${archives[@]}"; do
    sanitize_single_archive "$archive" "$ar_bin" "$objcopy_bin" "$ranlib_bin"
  done
}

configure_llvm_runtime_env() {
  local llvm_lib_path
  llvm_lib_path="$(llvm_runtime_lib_path)"

  export PATH="$LLVM_PREFIX/bin:$PATH"
  export LIBRARY_PATH="$llvm_lib_path${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LD_LIBRARY_PATH="$llvm_lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export ZIG_GLOBAL_CACHE_DIR
  export XDG_CACHE_HOME
}

llvm_runtime_lib_path() {
  local path="$LLVM_PREFIX/lib"
  if [[ -d "$LLVM_RT_PREFIX/lib" ]]; then
    path="$path:$LLVM_RT_PREFIX/lib"
  fi
  printf '%s' "$path"
}

ensure_llvm_config_aliases() {
  local llvm_config="$LLVM_PREFIX/bin/llvm-config"
  [[ -x "$llvm_config" ]] || die "missing llvm-config: $llvm_config"

  local llvm_version major llvm_lib_path
  llvm_lib_path="$(llvm_runtime_lib_path)"
  if ! llvm_version="$(LD_LIBRARY_PATH="$llvm_lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$llvm_config" --version)"; then
    die "failed to run llvm-config with runtime library path: $llvm_lib_path"
  fi
  major="${llvm_version%%.*}"
  [[ -n "$major" ]] || die "failed to parse llvm-config version: $llvm_version"

  ln -sf llvm-config "$LLVM_PREFIX/bin/llvm-config-${major}"
  ln -sf llvm-config "$LLVM_PREFIX/bin/llvm-config-${major}.0"
  ln -sf llvm-config "$LLVM_PREFIX/bin/llvm-config${major}0"
  ln -sf llvm-config "$LLVM_PREFIX/bin/llvm-config${major}"
}

build_zig() {
  log "configuring zig ($ZIG_REF)"

  local -a zig_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$ZIG_PREFIX"
    -DCMAKE_PREFIX_PATH="$LLVM_PREFIX"
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang"
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++"
    -DZIG_STATIC_LLVM=ON
    -DZIG_EXTRA_BUILD_ARGS=-Duse-zig-libcxx
    -DZIG_VERSION="$ZIG_REF"
  )

  if [[ "$MOLD_PREFIX" != "-" && -x "$MOLD_PREFIX/bin/mold" ]]; then
    local zig_linker_flags="-fuse-ld=$MOLD_PREFIX/bin/mold"
    log "using mold for zig link steps: $MOLD_PREFIX/bin/mold"
    zig_args+=(
      -DCMAKE_EXE_LINKER_FLAGS="$zig_linker_flags"
      -DCMAKE_SHARED_LINKER_FLAGS="$zig_linker_flags"
      -DCMAKE_MODULE_LINKER_FLAGS="$zig_linker_flags"
    )
  fi

  if [[ -n "${TARGET_TRIPLE:-}" ]]; then
    zig_args+=("-DZIG_TARGET_TRIPLE=${TARGET_TRIPLE}")
  fi
  if [[ -n "${TARGET_CPU:-}" ]]; then
    zig_args+=("-DZIG_TARGET_MCPU=${TARGET_CPU}")
  fi

  cmake -S "$ZIG_SRC_DIR" -B "$ZIG_BUILD_DIR" "${zig_args[@]}"
  cmake_build "$ZIG_BUILD_DIR" --target install
}

build_mold() {
  if [[ "${BUILD_MOLD:-1}" != "1" ]]; then
    log "skipping mold build (BUILD_MOLD=${BUILD_MOLD:-0})"
    MOLD_PREFIX="-"
    return 0
  fi

  log "building mold (${MOLD_REF})"

  local -a mold_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$BOOTSTRAP_CC"
    -DCMAKE_CXX_COMPILER="$BOOTSTRAP_CXX"
    -DBUILD_TESTING=OFF
    -DCMAKE_INSTALL_PREFIX="$MOLD_PREFIX"
  )

  cmake -S "$MOLD_SRC_DIR" -B "$MOLD_BUILD_DIR" "${mold_args[@]}"
  cmake_build "$MOLD_BUILD_DIR" --target mold

  mkdir -p "$MOLD_PREFIX/bin"

  local mold_bin_candidate="$MOLD_BUILD_DIR/mold"
  if [[ ! -x "$mold_bin_candidate" ]]; then
    mold_bin_candidate="$(find "$MOLD_BUILD_DIR" -type f -name mold -perm -111 | head -n1 || true)"
  fi
  [[ -n "$mold_bin_candidate" && -x "$mold_bin_candidate" ]] || die "failed to locate built mold binary"

  cp -a "$mold_bin_candidate" "$MOLD_PREFIX/bin/mold"
}

package_outputs() {
  if [[ "$EMIT_TOOLCHAIN_ARCHIVE" == "1" ]]; then
    "$SCRIPT_DIR/package-toolchain.sh" \
      "$LLVM_PREFIX" \
      "$ZIG_PREFIX" \
      "$DIST_DIR" \
      "$PKG_KEY" \
      "$LLVM_VERSION" \
      "$ZIG_VERSION" \
      "$TOOLCHAIN_NAME"
  fi

  if [[ -z "$RELEASE_ARCHIVE_NAME" ]]; then
    RELEASE_ARCHIVE_NAME="ziggurat-$ZIG_VERSION"
  fi

  "$SCRIPT_DIR/package-ziggurat-bin.sh" \
    "$ZIG_PREFIX" \
    "$LLVM_PREFIX" \
    "$MOLD_PREFIX" \
    "$DIST_DIR" \
    "$PKG_KEY" \
    "$PAYLOAD_NAME" \
    "$RELEASE_ARCHIVE_NAME"
}

write_build_info() {
  cat > "$DIST_DIR/build-info.txt" <<EOF_INFO
toolchain_name=$TOOLCHAIN_NAME
llvm_ref=$LLVM_REF
zig_ref=$ZIG_REF
target_triple=$TARGET_TRIPLE
target_cpu=$TARGET_CPU
llvm_version=$LLVM_VERSION
zig_version=$ZIG_VERSION
mold_ref=${MOLD_REF:-disabled}
release_archive=$RELEASE_ARCHIVE_NAME.tar.xz
built_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_INFO
}

main() {
  require_build_dependencies
  load_and_validate_config
  configure_runtime_paths

  sync_sources
  clean_previous_outputs

  configure_bootstrap_compilers
  build_mold
  build_bootstrap_runtimes
  build_llvm
  merge_bootstrap_runtimes_into_llvm_prefix
  sanitize_llvm_archives

  configure_llvm_runtime_env
  build_zig

  LLVM_VERSION="$(LD_LIBRARY_PATH="$(llvm_runtime_lib_path)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$LLVM_PREFIX/bin/llvm-config" --version)"
  ZIG_VERSION="$("$ZIG_PREFIX/bin/zig" version)"

  "$SCRIPT_DIR/verify-toolchain.sh" "$LLVM_PREFIX" "$ZIG_PREFIX"

  package_outputs
  write_build_info

  log "toolchain build complete"
}

main "$@"
