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
ZLIB_SRC_DIR=""
ZLIB_BUILD_DIR=""
ZLIB_PREFIX=""

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

# Config-sourced variables (declared for lint clarity; populated by load_config).
LLVM_REPO=""
LLVM_REF=""
ZIG_REPO=""
ZIG_REF=""
ZLIB_REPO=""
ZLIB_REF=""

# Convert tool names to CMake option key format (e.g. llvm-ar -> LLVM_AR).
canonical_tool_name() {
  local name="$1"
  name="${name//-/_}"
  printf '%s' "${name^^}"
}

# Enable only selected tool subdirectories and disable all others in a source root.
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

# Resolve workspace, install, and output paths used across the build.
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
  ZLIB_SRC_DIR="$WORK_DIR/zlib"
  ZLIB_BUILD_DIR="$WORK_DIR/build-zlib"
  ZLIB_PREFIX="$WORK_DIR/install-zlib"

  ZIG_SRC_DIR="$WORK_DIR/zig"
  ZIG_BUILD_DIR="$WORK_DIR/build-zig"
  ZIG_PREFIX="$WORK_DIR/install-zig"

  MOLD_SRC_DIR="$WORK_DIR/mold"
  MOLD_BUILD_DIR="$WORK_DIR/build-mold"
  MOLD_PREFIX="$WORK_DIR/install-mold"

  mkdir -p "$WORK_DIR" "$DIST_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$XDG_CACHE_HOME"
}

# Load config, apply optional overrides, and enforce release-only Zig refs.
load_and_validate_config() {
  load_config "${TOOLCHAIN_CONFIG:-$ROOT_DIR/toolchain.env}"
  apply_optional_override LLVM_REF "${LLVM_REF_OVERRIDE:-}"
  apply_optional_override ZIG_REF "${ZIG_REF_OVERRIDE:-}"
  validate_release_ref "$ZIG_REF"
}

# Check required host build tools before running any work.
require_build_dependencies() {
  require_cmds git cmake ninja python3 tar xz clang clang++ find
}

# Fetch or refresh all source repositories at their configured refs.
sync_sources() {
  sync_repo_shallow "$LLVM_REPO" "$LLVM_REF" "$LLVM_SRC_DIR"
  sync_repo_shallow "$ZIG_REPO" "$ZIG_REF" "$ZIG_SRC_DIR"
  : "${ZLIB_REPO:=https://github.com/madler/zlib.git}"
  : "${ZLIB_REF:=v1.3.1}"
  sync_repo_shallow "$ZLIB_REPO" "$ZLIB_REF" "$ZLIB_SRC_DIR"

  if [[ "${BUILD_MOLD:-1}" == "1" ]]; then
    : "${MOLD_REPO:=https://github.com/rui314/mold.git}"
    : "${MOLD_REF:=v2.4.0}"
    sync_repo_shallow "$MOLD_REPO" "$MOLD_REF" "$MOLD_SRC_DIR"
  else
    MOLD_PREFIX="-"
  fi
}

# Remove prior build and install directories for a clean run.
clean_previous_outputs() {
  rm -rf \
    "$LLVM_RT_BUILD_DIR" \
    "$LLVM_RT_PREFIX" \
    "$LLVM_BUILD_DIR" \
    "$LLVM_PREFIX" \
    "$ZLIB_BUILD_DIR" \
    "$ZLIB_PREFIX" \
    "$ZIG_BUILD_DIR" \
    "$ZIG_PREFIX" \
    "$MOLD_BUILD_DIR"

  if [[ "$MOLD_PREFIX" != "-" ]]; then
    rm -rf "$MOLD_PREFIX"
  fi
}

# Select host bootstrap C/C++ compilers used for LLVM and mold.
configure_bootstrap_compilers() {
  BOOTSTRAP_CC="${BOOTSTRAP_CC:-$(command -v clang)}"
  BOOTSTRAP_CXX="${BOOTSTRAP_CXX:-$(command -v clang++)}"
  [[ -n "$BOOTSTRAP_CC" && -n "$BOOTSTRAP_CXX" ]] || die "unable to resolve bootstrap clang/clang++"

  log "using bootstrap compilers: CC=$BOOTSTRAP_CC CXX=$BOOTSTRAP_CXX"
}

# Build libc++, libc++abi, and libunwind first for a hermetic LLVM toolchain.
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

# Build static zlib and install it for LLVM and Zig link steps.
build_bootstrap_zlib() {
  log "bootstrapping zlib (${ZLIB_REF})"

  local -a zlib_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$BOOTSTRAP_CC"
    -DCMAKE_CXX_COMPILER="$BOOTSTRAP_CXX"
    -DCMAKE_INSTALL_PREFIX="$ZLIB_PREFIX"
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  )

  cmake -S "$ZLIB_SRC_DIR" -B "$ZLIB_BUILD_DIR" "${zlib_args[@]}"
  cmake_build "$ZLIB_BUILD_DIR" --target install

  [[ -f "$ZLIB_PREFIX/lib/libz.a" ]] || die "missing static zlib archive at $ZLIB_PREFIX/lib/libz.a"
}

# Configure and install LLVM/Clang/LLD with minimal required tools enabled.
build_llvm() {
  log "configuring llvm ($LLVM_REF)"

  local llvm_libcxx_cxx_flags="-stdlib=libc++ -isystem $LLVM_RT_PREFIX/include/c++/v1"
  local llvm_libcxx_link_flags="-stdlib=libc++ -L$LLVM_RT_PREFIX/lib -L$ZLIB_PREFIX/lib"

  local -a llvm_args=(
    -G "${CMAKE_GENERATOR:-Ninja}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$BOOTSTRAP_CC"
    -DCMAKE_CXX_COMPILER="$BOOTSTRAP_CXX"
    -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX"
    -DCMAKE_PREFIX_PATH="$LLVM_RT_PREFIX;$ZLIB_PREFIX"
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
    -DLLVM_ENABLE_ZLIB=FORCE_ON
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
    -DZLIB_USE_STATIC_LIBS=ON
    -DZLIB_ROOT="$ZLIB_PREFIX"
    -DZLIB_INCLUDE_DIR="$ZLIB_PREFIX/include"
    -DZLIB_LIBRARY="$ZLIB_PREFIX/lib/libz.a"
    -DZLIB_LIBRARY_RELEASE="$ZLIB_PREFIX/lib/libz.a"
    -DZLIB_LIBRARY_DEBUG="$ZLIB_PREFIX/lib/libz.a"
  )

  # Build compiler-rt runtimes needed by Zig tooling and payload packaging.
  if [[ ";${LLVM_ENABLE_RUNTIMES:-compiler-rt};" == *";compiler-rt;"* ]]; then
    local runtime_targets="${COMPILER_RT_RUNTIME_TARGETS:-x86_64-unknown-linux-gnu;aarch64-unknown-linux-gnu}"
    local builtin_targets="${COMPILER_RT_BUILTIN_TARGETS:-$runtime_targets}"

    llvm_args+=(
      -DCOMPILER_RT_BUILD_BUILTINS="${COMPILER_RT_BUILD_BUILTINS:-ON}"
      -DCOMPILER_RT_BUILD_SANITIZERS="${COMPILER_RT_BUILD_SANITIZERS:-ON}"
      -DCOMPILER_RT_BUILD_LIBFUZZER="${COMPILER_RT_BUILD_LIBFUZZER:-ON}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY="${COMPILER_RT_DEFAULT_TARGET_ONLY:-OFF}"
      -DCOMPILER_RT_BUILD_PROFILE="${COMPILER_RT_BUILD_PROFILE:-ON}"
      -DCOMPILER_RT_USE_BUILTINS_LIBRARY="${COMPILER_RT_USE_BUILTINS_LIBRARY:-ON}"
      -DCOMPILER_RT_BUILD_XRAY="${COMPILER_RT_BUILD_XRAY:-OFF}"
      -DCOMPILER_RT_BUILD_MEMPROF="${COMPILER_RT_BUILD_MEMPROF:-OFF}"
      -DCOMPILER_RT_BUILD_ORC="${COMPILER_RT_BUILD_ORC:-OFF}"
      -DCOMPILER_RT_BUILD_GWP_ASAN="${COMPILER_RT_BUILD_GWP_ASAN:-OFF}"
      -DCOMPILER_RT_BUILD_CTX_PROFILE="${COMPILER_RT_BUILD_CTX_PROFILE:-OFF}"
      -DLLVM_RUNTIME_TARGETS="$runtime_targets"
      -DLLVM_BUILTIN_TARGETS="$builtin_targets"
    )

    # Build compiler-rt runtimes explicitly for the Linux targets consumed by
    # downstream Bazel sanitizer/fuzzer configs.
    local -a runtime_target_array=()
    local -a builtin_target_array=()
    IFS=';' read -r -a runtime_target_array <<< "$runtime_targets"
    IFS=';' read -r -a builtin_target_array <<< "$builtin_targets"

    local target=""
    for target in "${runtime_target_array[@]}"; do
      [[ -n "$target" ]] || continue
      llvm_args+=(
        "-DRUNTIMES_${target}_LLVM_ENABLE_RUNTIMES=compiler-rt"
        "-DRUNTIMES_${target}_CMAKE_C_COMPILER_TARGET=$target"
        "-DRUNTIMES_${target}_CMAKE_CXX_COMPILER_TARGET=$target"
        "-DRUNTIMES_${target}_CMAKE_ASM_COMPILER_TARGET=$target"
        "-DRUNTIMES_${target}_CMAKE_CXX_FLAGS=$llvm_libcxx_cxx_flags"
        "-DRUNTIMES_${target}_COMPILER_RT_USE_BUILTINS_LIBRARY=${COMPILER_RT_USE_BUILTINS_LIBRARY:-ON}"
        "-DRUNTIMES_${target}_COMPILER_RT_BUILD_SANITIZERS=${COMPILER_RT_BUILD_SANITIZERS:-ON}"
        "-DRUNTIMES_${target}_COMPILER_RT_BUILD_LIBFUZZER=${COMPILER_RT_BUILD_LIBFUZZER:-ON}"
        "-DRUNTIMES_${target}_COMPILER_RT_BUILD_PROFILE=${COMPILER_RT_BUILD_PROFILE:-ON}"
      )
    done

    for target in "${builtin_target_array[@]}"; do
      [[ -n "$target" ]] || continue
      llvm_args+=(
        "-DBUILTINS_${target}_CMAKE_C_COMPILER_TARGET=$target"
        "-DBUILTINS_${target}_CMAKE_ASM_COMPILER_TARGET=$target"
      )
    done
  fi

  if [[ -n "${LLVM_TARGETS_TO_BUILD:-}" ]]; then
    llvm_args+=("-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS_TO_BUILD}")
  fi

  # Restrict LLVM tools to a curated set required by downstream Bazel usage.
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

# Install compiler-rt runtimes and merge them into the LLVM install prefix.
install_compiler_rt_runtimes() {
  if [[ ";${LLVM_ENABLE_RUNTIMES:-compiler-rt};" != *";compiler-rt;"* ]]; then
    return
  fi

  log "installing compiler-rt runtime artifacts"
  cmake_build "$LLVM_BUILD_DIR" --target install-runtimes

  local build_rt_clang_dir="$LLVM_BUILD_DIR/runtimes/runtimes-bins/lib/clang"
  local install_rt_clang_dir="$LLVM_PREFIX/lib/clang"

  # Some configurations install runtimes directly into LLVM_PREFIX and do not
  # leave a populated runtimes-bins/lib/clang tree.
  if [[ -d "$build_rt_clang_dir" ]]; then
    mkdir -p "$install_rt_clang_dir"
    cp -a "$build_rt_clang_dir/." "$install_rt_clang_dir/"
  fi

  [[ -d "$install_rt_clang_dir" ]] || die "missing compiler-rt install tree at $install_rt_clang_dir"

  local runtime_targets="${COMPILER_RT_RUNTIME_TARGETS:-x86_64-unknown-linux-gnu;aarch64-unknown-linux-gnu}"
  local -a runtime_target_array=()
  IFS=';' read -r -a runtime_target_array <<< "$runtime_targets"

  local -a required_archives=(
    libclang_rt.fuzzer.a
    libclang_rt.asan-preinit.a
    libclang_rt.asan.a
    libclang_rt.asan_cxx.a
    libclang_rt.tsan.a
    libclang_rt.tsan_cxx.a
    libclang_rt.msan.a
    libclang_rt.msan_cxx.a
    libclang_rt.ubsan_standalone.a
    libclang_rt.ubsan_standalone_cxx.a
    libclang_rt.lsan.a
    libclang_rt.rtsan.a
    libclang_rt.profile.a
  )

  local -a missing=()
  local target=""
  local archive=""
  for target in "${runtime_target_array[@]}"; do
    [[ -n "$target" ]] || continue
    for archive in "${required_archives[@]}"; do
      if ! find "$install_rt_clang_dir" -type f -path "*/lib/$target/$archive" -print -quit | grep -q .; then
        missing+=("$target/$archive")
      fi
    done
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "compiler-rt install is missing required runtimes under $install_rt_clang_dir: ${missing[*]}"
  fi
}

# Merge bootstrap libc++ runtime artifacts into the final LLVM prefix.
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

# Merge static zlib into LLVM prefix so downstream -L<llvm>/lib -lz resolves to libz.a.
merge_bootstrap_zlib_into_llvm_prefix() {
  log "merging static zlib into llvm prefix"

  mkdir -p "$LLVM_PREFIX/include" "$LLVM_PREFIX/lib"
  cp -a "$ZLIB_PREFIX/lib/libz.a" "$LLVM_PREFIX/lib/libz.a"
  cp -a "$ZLIB_PREFIX/include/zlib.h" "$LLVM_PREFIX/include/zlib.h"
  cp -a "$ZLIB_PREFIX/include/zconf.h" "$LLVM_PREFIX/include/zconf.h"
}

# Rebuild one static archive after removing unsupported metadata sections.
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

# Strip .deplibs/.linker-options from all LLVM static archives.
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

# Export runtime env so LLVM and Zig binaries use hermetic libraries.
configure_llvm_runtime_env() {
  local llvm_lib_path
  llvm_lib_path="$(llvm_runtime_lib_path)"

  export PATH="$LLVM_PREFIX/bin:$PATH"
  export LIBRARY_PATH="$llvm_lib_path${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LD_LIBRARY_PATH="$llvm_lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export ZIG_GLOBAL_CACHE_DIR
  export XDG_CACHE_HOME
}

# Build library search path for LLVM executables that depend on libc++ runtimes.
llvm_runtime_lib_path() {
  local path="$LLVM_PREFIX/lib"
  if [[ -d "$LLVM_RT_PREFIX/lib" ]]; then
    path="$path:$LLVM_RT_PREFIX/lib"
  fi
  printf '%s' "$path"
}

# Create versioned llvm-config aliases expected by Zig's Findllvm.cmake.
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

# Configure and install Zig against the freshly built hermetic LLVM prefix.
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
    -DZIG_STATIC_ZLIB=ON
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

# Build mold and install it into the toolchain payload prefix.
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
    -DMOLD_MOSTLY_STATIC=ON
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

# Ensure key toolchain binaries are not dynamically linked against libz.so.
verify_static_zlib_linkage() {
  local host_os=""
  host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$host_os" != "linux" ]]; then
    log "skipping static zlib linkage verification on non-linux host: $host_os"
    return 0
  fi

  require_cmd ldd

  local -a bins=(
    "$LLVM_PREFIX/bin/clang"
    "$LLVM_PREFIX/bin/ld.lld"
    "$LLVM_PREFIX/bin/llvm-config"
    "$ZIG_PREFIX/bin/zig"
  )

  if [[ "$MOLD_PREFIX" != "-" ]]; then
    bins+=("$MOLD_PREFIX/bin/mold")
  fi

  local bin=""
  local ldd_output=""
  for bin in "${bins[@]}"; do
    [[ -x "$bin" ]] || die "missing binary for zlib linkage verification: $bin"

    ldd_output="$(ldd "$bin" 2>/dev/null || true)"
    if printf '%s\n' "$ldd_output" | grep -Eq 'libz\.so(\.|$)'; then
      die "binary is dynamically linked against libz (expected static link): $bin"
    fi
  done

  log "verified key binaries are not dynamically linked against libz.so"
}

# Produce output archives and payloads in dist/.
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

# Emit a small metadata file describing the generated artifacts.
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

# Run the full build, verification, and packaging pipeline.
main() {
  # Prepare workspace and inputs.
  require_build_dependencies
  load_and_validate_config
  configure_runtime_paths

  # Sync repositories and clean previous outputs.
  sync_sources
  clean_previous_outputs

  # Build mold, runtimes, LLVM, and Zig.
  configure_bootstrap_compilers
  build_mold
  build_bootstrap_runtimes
  build_bootstrap_zlib
  build_llvm
  merge_bootstrap_runtimes_into_llvm_prefix
  merge_bootstrap_zlib_into_llvm_prefix
  sanitize_llvm_archives

  configure_llvm_runtime_env
  build_zig
  verify_static_zlib_linkage

  # Verify outputs and produce release artifacts.
  LLVM_VERSION="$(LD_LIBRARY_PATH="$(llvm_runtime_lib_path)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$LLVM_PREFIX/bin/llvm-config" --version)"
  ZIG_VERSION="$("$ZIG_PREFIX/bin/zig" version)"

  "$SCRIPT_DIR/verify-toolchain.sh" "$LLVM_PREFIX" "$ZIG_PREFIX"

  package_outputs
  write_build_info

  log "toolchain build complete"
}

main "$@"
