#!/usr/bin/env bash
set -euo pipefail

STAGES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${STAGES_LIB_DIR}/../.." && pwd)}"

STAGE_ORDER=(
	"00_prepare_dirs"
	"10_fetch_zig"
	"20_fetch_llvm"
	"30_build_bootstrap_llvm"
	"40_build_zig_with_bootstrap"
	"50_disable_host_compilers"
	"65_fetch_mold"
	"70_build_mold"
	"80_build_iwyu"
	"90_collect_dist_sysroot"
	"95_size_optimize"
	"99_package"
)

# Return success when a stage name is registered.
stage_exists() {
	stage_index "$1" >/dev/null 2>&1
}

# Print the zero-based index for a stage name.
stage_index() {
	local target="$1"
	local idx=0
	local stage

	for stage in "${STAGE_ORDER[@]}"; do
		if [[ "${stage}" == "${target}" ]]; then
			echo "${idx}"
			return 0
		fi
		idx=$((idx + 1))
	done

	return 1
}

# Return the script path for a stage name.
stage_script_path() {
	local stage_name="$1"
	echo "${PROJECT_ROOT}/scripts/stages/${stage_name}.sh"
}
