#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ROOT:?missing PROJECT_ROOT}"
: "${ZIG_SOURCE_DIR:?missing ZIG_SOURCE_DIR}"
: "${ZIG_BUILD_DIR:?missing ZIG_BUILD_DIR}"
: "${ZIG_INSTALL_DIR:?missing ZIG_INSTALL_DIR}"
: "${CC:?missing CC}"
: "${CXX:?missing CXX}"
: "${AR:?missing AR}"
: "${RANLIB:?missing RANLIB}"
: "${LD:?missing LD}"

build_root="${BUILD_ROOT:-${PROJECT_ROOT}/build}"
bootstrap_toolchain="${build_root}/bootstrap-toolchain"
cmake_bin="${CMAKE_BIN:-cmake}"
ninja_bin="${NINJA_BIN:-ninja}"
zig_local_cache_dir="${build_root}/zig-cache/local"
zig_global_cache_dir="${build_root}/zig-cache/global"

mkdir -p "${zig_local_cache_dir}" "${zig_global_cache_dir}"
export ZIG_LOCAL_CACHE_DIR="${zig_local_cache_dir}"
export ZIG_GLOBAL_CACHE_DIR="${zig_global_cache_dir}"

"${cmake_bin}" \
	-G Ninja \
	-S "${ZIG_SOURCE_DIR}" \
	-B "${ZIG_BUILD_DIR}" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="${ZIG_INSTALL_DIR}" \
	-DCMAKE_C_COMPILER="${CC}" \
	-DCMAKE_CXX_COMPILER="${CXX}" \
	-DCMAKE_AR="${AR}" \
	-DCMAKE_RANLIB="${RANLIB}" \
	-DCMAKE_LINKER="${LD}" \
	-DCMAKE_PREFIX_PATH="${bootstrap_toolchain}" \
	-DLLVM_DIR="${bootstrap_toolchain}/lib/cmake/llvm" \
	-DZIG_STATIC_ZLIB=ON \
	-DZIG_USE_LLVM_CONFIG=OFF

"${ninja_bin}" -C "${ZIG_BUILD_DIR}" install
