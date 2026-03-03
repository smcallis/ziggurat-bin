#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
bootstrap_bin="${build_root}/bootstrap-toolchain/bin"
mold_source="${build_root}/src/mold"
mold_build_dir="${build_root}/mold-build"
mold_install_dir="${build_root}/final-toolchain/mold"

[[ -d "${mold_source}" ]] || die "mold source directory not found: ${mold_source}"
for required_tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	[[ -x "${bootstrap_bin}/${required_tool}" ]] || die "Missing bootstrap tool: ${bootstrap_bin}/${required_tool}"
done

source_config_with_env_overrides "${PROJECT_ROOT}/config.env" MOLD_VERSION
mold_version="${MOLD_VERSION:-unknown}"

cmake_bin="${CMAKE_BIN:-cmake}"
ninja_bin="${NINJA_BIN:-ninja}"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${mold_build_dir}" "${mold_install_dir}"

"${cmake_bin}" \
	-G Ninja \
	-S "${mold_source}" \
	-B "${mold_build_dir}" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="${mold_install_dir}" \
	-DCMAKE_C_COMPILER="${bootstrap_bin}/clang" \
	-DCMAKE_CXX_COMPILER="${bootstrap_bin}/clang++" \
	-DCMAKE_LINKER="${bootstrap_bin}/ld.lld"

export MOLD_INSTALL_DIR="${mold_install_dir}"
"${ninja_bin}" -C "${mold_build_dir}" install

[[ -x "${mold_install_dir}/bin/mold" ]] || die "Missing mold binary after stage: ${mold_install_dir}/bin/mold"

printf '{"source":"%s","install_dir":"%s","mold_version":"%s"}\n' \
	"${mold_source}" "${mold_install_dir}" "${mold_version}" >"${STATE_DIR}/mold-build.json"
