#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/version_match.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
bootstrap_bin="${build_root}/bootstrap-toolchain/bin"
iwyu_source="${build_root}/src/include-what-you-use"
llvm_checkout="${build_root}/src/llvm-project"
llvm_source="${llvm_checkout}"
if [[ -d "${llvm_checkout}/llvm" ]]; then
	llvm_source="${llvm_checkout}/llvm"
fi

[[ -d "${iwyu_source}" ]] || die "IWYU source directory not found: ${iwyu_source}"
[[ -d "${llvm_source}" ]] || die "LLVM source directory not found: ${llvm_source}"
for required_tool in clang clang++; do
	[[ -x "${bootstrap_bin}/${required_tool}" ]] || die "Missing bootstrap tool: ${bootstrap_bin}/${required_tool}"
done

source_config_with_env_overrides "${PROJECT_ROOT}/config.env" LLVM_VERSION IWYU_GIT_REF

assert_iwyu_ref_not_configurable "${IWYU_GIT_REF:-}"

zig_lock_file="${STATE_DIR}/zig-source-lock.json"
if [[ -f "${zig_lock_file}" ]]; then
	if [[ -z "${LLVM_VERSION:-}" ]]; then
		LLVM_VERSION="$(read_lock_field "${zig_lock_file}" "llvm_version")"
	fi
fi

llvm_version="${LLVM_VERSION:?LLVM_VERSION is required}"
iwyu_ref="clang_$(llvm_major_from_version "${llvm_version}")"
assert_iwyu_llvm_compat "${llvm_version}" "${iwyu_ref}"

iwyu_build_dir="${build_root}/iwyu-build"
iwyu_install_dir="${build_root}/final-toolchain/iwyu"
llvm_cmake_dir="${build_root}/final-toolchain/llvm/lib/cmake/llvm"
clang_cmake_dir="${build_root}/final-toolchain/llvm/lib/cmake/clang"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${iwyu_build_dir}" "${iwyu_install_dir}"

"${CMAKE_BIN:-cmake}" \
	-G Ninja \
	-S "${iwyu_source}" \
	-B "${iwyu_build_dir}" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="${iwyu_install_dir}" \
	-DCMAKE_C_COMPILER="${bootstrap_bin}/clang" \
	-DCMAKE_CXX_COMPILER="${bootstrap_bin}/clang++" \
	-DLLVM_DIR="${llvm_cmake_dir}" \
	-DClang_DIR="${clang_cmake_dir}" \
	-DLLVM_EXTERNAL_SRC="${llvm_source}"

export IWYU_INSTALL_DIR="${iwyu_install_dir}"
"${NINJA_BIN:-ninja}" -C "${iwyu_build_dir}" install

[[ -x "${iwyu_install_dir}/bin/include-what-you-use" ]] || die "Missing IWYU binary after stage: ${iwyu_install_dir}/bin/include-what-you-use"

printf '{"source":"%s","install_dir":"%s","llvm_version":"%s","iwyu_ref":"%s"}\n' \
	"${iwyu_source}" "${iwyu_install_dir}" "${llvm_version}" "${iwyu_ref}" >"${STATE_DIR}/iwyu-build.json"
