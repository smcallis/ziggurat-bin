#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PROJECT_ROOT

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/stages.sh"

TARGET_DIR="${PROJECT_ROOT}/dist"
STATE_DIR="${PROJECT_ROOT}/state"
FROM_STAGE=""
TO_STAGE=""
declare -a SKIP_STAGES=()
GLOBAL_FINGERPRINT=""
FROM_STAGE_IDX=0
TO_STAGE_IDX=0

# Print CLI usage.
usage() {
	cat <<'EOF'
Usage: scripts/build.sh [options]

Options:
  --from-stage <name>   Start execution at this stage (inclusive).
  --to-stage <name>     Stop execution at this stage (inclusive).
  --skip-stage <name>   Skip this stage (repeatable).
  --target-dir <path>   Output sysroot directory (default: dist).
  --state-dir <path>    Build state/stamp directory (default: state).
  --help                Show this message.
EOF
}

# Parse CLI options.
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--from-stage)
			[[ $# -ge 2 ]] || die "Missing value for --from-stage"
			FROM_STAGE="$2"
			shift 2
			;;
		--to-stage)
			[[ $# -ge 2 ]] || die "Missing value for --to-stage"
			TO_STAGE="$2"
			shift 2
			;;
		--skip-stage)
			[[ $# -ge 2 ]] || die "Missing value for --skip-stage"
			SKIP_STAGES+=("$2")
			shift 2
			;;
		--target-dir)
			[[ $# -ge 2 ]] || die "Missing value for --target-dir"
			TARGET_DIR="$2"
			shift 2
			;;
		--state-dir)
			[[ $# -ge 2 ]] || die "Missing value for --state-dir"
			STATE_DIR="$2"
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
		esac
	done
}

# Set default stage range.
set_default_stage_range() {
	if [[ -z "${FROM_STAGE}" ]]; then
		FROM_STAGE="${STAGE_ORDER[0]}"
	fi
	if [[ -z "${TO_STAGE}" ]]; then
		TO_STAGE="${STAGE_ORDER[$((${#STAGE_ORDER[@]} - 1))]}"
	fi
}

# Validate stage names and range arguments.
validate_stage_range() {
	if ! stage_exists "${FROM_STAGE}"; then
		die "Unknown stage: ${FROM_STAGE}"
	fi
	if ! stage_exists "${TO_STAGE}"; then
		die "Unknown stage: ${TO_STAGE}"
	fi

	local skip_stage
	for skip_stage in "${SKIP_STAGES[@]}"; do
		if ! stage_exists "${skip_stage}"; then
			die "Unknown stage: ${skip_stage}"
		fi
	done

	FROM_STAGE_IDX="$(stage_index "${FROM_STAGE}")"
	TO_STAGE_IDX="$(stage_index "${TO_STAGE}")"
	if ((FROM_STAGE_IDX > TO_STAGE_IDX)); then
		die "--from-stage must come before --to-stage"
	fi
}

# Return success when a stage should run in the requested range.
stage_in_selected_range() {
	local stage="$1"
	local stage_idx
	stage_idx="$(stage_index "${stage}")"
	((stage_idx >= FROM_STAGE_IDX && stage_idx <= TO_STAGE_IDX))
}

# Return success when the stage is explicitly skipped.
stage_is_skipped() {
	local stage="$1"
	string_in_array "${stage}" "${SKIP_STAGES[@]}"
}

# Return success when the stage stamp metadata is current.
stage_is_up_to_date() {
	local stage="$1"
	local stage_script="$2"
	local stage_stamp="${STATE_DIR}/${stage}.done"
	local stage_meta="${STATE_DIR}/${stage}.meta"
	local expected_meta
	local current_meta

	expected_meta="$(stage_build_fingerprint "${stage}" "${stage_script}" "${GLOBAL_FINGERPRINT}")"
	[[ -f "${stage_stamp}" && -f "${stage_meta}" ]] || return 1
	current_meta="$(cat "${stage_meta}")"
	[[ "${current_meta}" == "${expected_meta}" ]]
}

# Run one stage script and refresh its stamp files.
run_stage() {
	local stage="$1"
	local stage_script
	local stage_stamp
	local stage_meta
	local expected_meta

	stage_script="$(stage_script_path "${stage}")"
	[[ -f "${stage_script}" ]] || die "Missing stage script: ${stage_script}"

	stage_stamp="${STATE_DIR}/${stage}.done"
	stage_meta="${STATE_DIR}/${stage}.meta"
	expected_meta="$(stage_build_fingerprint "${stage}" "${stage_script}" "${GLOBAL_FINGERPRINT}")"

	log_info "Running stage ${stage}"
	bash "${stage_script}" "${TARGET_DIR}" "${STATE_DIR}"
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"${stage_stamp}"
	echo "${expected_meta}" >"${stage_meta}"
}

# Execute the selected stage range.
run_stage_range() {
	local stage
	local stage_script
	for stage in "${STAGE_ORDER[@]}"; do
		if ! stage_in_selected_range "${stage}"; then
			continue
		fi

		if stage_is_skipped "${stage}"; then
			log_info "Skipping stage ${stage} (requested by --skip-stage)."
			continue
		fi

		stage_script="$(stage_script_path "${stage}")"
		[[ -f "${stage_script}" ]] || die "Missing stage script: ${stage_script}"
		if stage_is_up_to_date "${stage}" "${stage_script}"; then
			log_info "Skipping stage ${stage} (stamp up-to-date)."
			continue
		fi

		run_stage "${stage}"
	done
}

parse_args "$@"
set_default_stage_range
validate_stage_range
mkdir -p "${TARGET_DIR}" "${STATE_DIR}"
GLOBAL_FINGERPRINT="$(global_build_fingerprint "${PROJECT_ROOT}")"
run_stage_range
