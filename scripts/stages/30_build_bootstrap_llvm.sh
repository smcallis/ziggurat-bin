#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/cmake_presets.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
llvm_checkout="${build_root}/src/llvm-project"
llvm_source="${llvm_checkout}"
if [[ -d "${llvm_checkout}/llvm" ]]; then
	llvm_source="${llvm_checkout}/llvm"
fi

[[ -d "${llvm_source}" ]] || die "LLVM source checkout not found: ${llvm_source}"

if [[ -f "${PROJECT_ROOT}/config.env" ]]; then
	# shellcheck source=/dev/null
	source "${PROJECT_ROOT}/config.env"
fi

projects="${LLVM_ENABLE_PROJECTS:-$(default_llvm_projects)}"
runtimes="${LLVM_ENABLE_RUNTIMES:-${RUNTIMES:-$(default_llvm_runtimes)}}"
targets="${LLVM_TARGETS_TO_BUILD:-}"

initial_toolchain_bin="${INITIAL_TOOLCHAIN_BIN:-/usr/bin}"
initial_cc="${INITIAL_CC:-${initial_toolchain_bin}/clang}"
initial_cxx="${INITIAL_CXX:-${initial_toolchain_bin}/clang++}"
initial_ar="${INITIAL_AR:-${initial_toolchain_bin}/llvm-ar}"
initial_ranlib="${INITIAL_RANLIB:-${initial_toolchain_bin}/llvm-ranlib}"
initial_ld="${INITIAL_LD:-${initial_toolchain_bin}/ld.lld}"

cmake_bin="${CMAKE_BIN:-cmake}"
ninja_bin="${NINJA_BIN:-ninja}"
bootstrap_build_dir="${build_root}/bootstrap-llvm"
bootstrap_install_dir="${build_root}/bootstrap-toolchain"
llvm_alias_dir="${build_root}/final-toolchain/llvm"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${bootstrap_build_dir}" "${bootstrap_install_dir}/bin"

cmake_args=(
	-G
	Ninja
	-S
	"${llvm_source}"
	-B
	"${bootstrap_build_dir}"
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_INSTALL_PREFIX="${bootstrap_install_dir}"
	-DCMAKE_C_COMPILER="${initial_cc}"
	-DCMAKE_CXX_COMPILER="${initial_cxx}"
	-DCMAKE_AR="${initial_ar}"
	-DCMAKE_RANLIB="${initial_ranlib}"
	-DCMAKE_LINKER="${initial_ld}"
	-DLLVM_ENABLE_PROJECTS="${projects}"
	-DLLVM_ENABLE_RUNTIMES="${runtimes}"
	-DLLVM_ENABLE_ASSERTIONS=OFF
	-DLLVM_ENABLE_ZSTD=OFF
	-DLLVM_ENABLE_LIBXML2=OFF
	-DLLVM_BUILD_LLVM_DYLIB=ON
	-DLLVM_LINK_LLVM_DYLIB=ON
	-DCLANG_LINK_CLANG_DYLIB=ON
)
if [[ -n "${targets}" ]]; then
	cmake_args+=(-DLLVM_TARGETS_TO_BUILD="${targets}")
fi
"${cmake_bin}" "${cmake_args[@]}"

export BOOTSTRAP_INSTALL_DIR="${bootstrap_install_dir}"
"${ninja_bin}" -C "${bootstrap_build_dir}" install

mkdir -p "$(dirname "${llvm_alias_dir}")"
rm -rf "${llvm_alias_dir:?}"
ln -s "${bootstrap_install_dir}" "${llvm_alias_dir}"

printf '{"source":"%s","install_dir":"%s","projects":"%s","runtimes":"%s","targets":"%s"}\n' \
	"${llvm_source}" "${bootstrap_install_dir}" "${projects}" "${runtimes}" "${targets}" >"${STATE_DIR}/bootstrap-llvm.json"
