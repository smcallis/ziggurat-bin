#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stage_dump="$(
	set +u
	# shellcheck source=/dev/null
	source "${ROOT_DIR}/scripts/lib/stages.sh"
	set -u
	for stage in "${STAGE_ORDER[@]}"; do
		echo "${stage}"
	done
)"

missing_stage_scripts="$(
	set +u
	# shellcheck source=/dev/null
	source "${ROOT_DIR}/scripts/lib/stages.sh"
	set -u
	for stage in "${STAGE_ORDER[@]}"; do
		script_path="$(stage_script_path "${stage}")"
		if [[ ! -f "${script_path}" ]]; then
			echo "${stage}:${script_path}"
		fi
	done
)"

expected_stages=(
	"00_prepare_dirs"
	"10_fetch_zig"
	"20_fetch_llvm_iwyu"
	"30_build_bootstrap_llvm"
	"40_build_zig_with_bootstrap"
	"50_disable_host_compilers"
	"60_fetch_mold"
	"70_build_mold"
	"80_build_iwyu"
	"90_collect_dist_sysroot"
	"95_size_optimize"
	"98_validate_payload"
	"99_package"
)

for stage in "${expected_stages[@]}"; do
	if ! grep -Fxq -- "${stage}" <<<"${stage_dump}"; then
		echo "missing stage in STAGE_ORDER: ${stage}"
		echo "${stage_dump}"
		exit 1
	fi
done

first_stage="$(head -n 1 <<<"${stage_dump}")"
last_stage="$(tail -n 1 <<<"${stage_dump}")"

if [[ "${first_stage}" != "00_prepare_dirs" ]]; then
	echo "expected first stage to be 00_prepare_dirs, got: ${first_stage}"
	exit 1
fi

if [[ "${last_stage}" != "99_package" ]]; then
	echo "expected last stage to be 99_package, got: ${last_stage}"
	exit 1
fi

line_stage_40="$(nl -ba <<<"${stage_dump}" | awk '$2=="40_build_zig_with_bootstrap"{print $1}')"
line_stage_50="$(nl -ba <<<"${stage_dump}" | awk '$2=="50_disable_host_compilers"{print $1}')"
if [[ -z "${line_stage_40}" || -z "${line_stage_50}" ]]; then
	echo "unable to determine stage ordering for 50/40"
	echo "${stage_dump}"
	exit 1
fi
if ((line_stage_40 >= line_stage_50)); then
	echo "expected stage 40_build_zig_with_bootstrap to run before 50_disable_host_compilers"
	echo "${stage_dump}"
	exit 1
fi

line_stage_65="$(nl -ba <<<"${stage_dump}" | awk '$2=="60_fetch_mold"{print $1}')"
line_stage_70="$(nl -ba <<<"${stage_dump}" | awk '$2=="70_build_mold"{print $1}')"
if [[ -z "${line_stage_65}" || -z "${line_stage_70}" ]]; then
	echo "unable to determine stage ordering for 65/70"
	echo "${stage_dump}"
	exit 1
fi
if ((line_stage_65 >= line_stage_70)); then
	echo "expected stage 60_fetch_mold to run before 70_build_mold"
	echo "${stage_dump}"
	exit 1
fi

if [[ -n "${missing_stage_scripts}" ]]; then
	echo "missing stage scripts:"
	echo "${missing_stage_scripts}"
	exit 1
fi
