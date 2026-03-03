#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
zig_src_root="${build_root}/src/zig"
zig_build_dir="${build_root}/zig"
zig_install_dir="${build_root}/final-toolchain/zig"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${zig_build_dir}" "${zig_install_dir}"

if [[ -z "${ZIG_BUILD_BIN:-}" ]]; then
	ZIG_BUILD_BIN="${PROJECT_ROOT}/scripts/zig_source_build.sh"
fi
[[ -x "${ZIG_BUILD_BIN}" ]] || die "ZIG_BUILD_BIN is not executable: ${ZIG_BUILD_BIN}"

initial_toolchain_bin="${INITIAL_TOOLCHAIN_BIN:-/usr/bin}"
initial_cc="${INITIAL_CC:-${initial_toolchain_bin}/clang}"
initial_cxx="${INITIAL_CXX:-${initial_toolchain_bin}/clang++}"
initial_ar="${INITIAL_AR:-${initial_toolchain_bin}/llvm-ar}"
initial_ranlib="${INITIAL_RANLIB:-${initial_toolchain_bin}/llvm-ranlib}"
initial_ld="${INITIAL_LD:-${initial_toolchain_bin}/ld.lld}"

for required_tool in \
	"${initial_cc}" \
	"${initial_cxx}" \
	"${initial_ar}" \
	"${initial_ranlib}" \
	"${initial_ld}"; do
	[[ -x "${required_tool}" ]] || die "Missing initial toolchain binary: ${required_tool}"
done

zig_source="${zig_src_root}"
if [[ ! -f "${zig_source}/build.zig" ]]; then
	first_child_dir="$(find "${zig_src_root}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -n 1 || true)"
	if [[ -n "${first_child_dir}" ]]; then
		zig_source="${first_child_dir}"
	fi
fi
[[ -d "${zig_source}" ]] || die "Zig source directory not found: ${zig_source}"

export ZIG_SOURCE_DIR="${zig_source}"
export ZIG_BUILD_DIR="${zig_build_dir}"
export ZIG_INSTALL_DIR="${zig_install_dir}"
export CC="${initial_cc}"
export CXX="${initial_cxx}"
export AR="${initial_ar}"
export RANLIB="${initial_ranlib}"
export LD="${initial_ld}"
"${ZIG_BUILD_BIN}"
zig_mode="custom-builder"

[[ -x "${zig_install_dir}/bin/zig" ]] || die "Missing zig binary after stage: ${zig_install_dir}/bin/zig"

printf '{"source":"%s","install_dir":"%s","mode":"%s"}\n' \
	"${zig_source}" "${zig_install_dir}" "${zig_mode}" >"${STATE_DIR}/zig-build.json"
