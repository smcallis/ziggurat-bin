#!/usr/bin/env bash
set -euo pipefail

# Log a standard informational message.
log_info() {
	echo "[INFO] $*"
}

# Log a warning message to stderr.
log_warn() {
	echo "[WARN] $*" >&2
}

# Log an error message to stderr.
log_error() {
	echo "[ERROR] $*" >&2
}

# Log an error and exit immediately.
die() {
	log_error "$*"
	exit 1
}

# Return the SHA-256 hash for a string payload.
sha256_string() {
	printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# Return the SHA-256 hash for a file, or empty for missing files.
sha256_file() {
	local file_path="$1"
	if [[ ! -f "${file_path}" ]]; then
		printf ''
		return 0
	fi
	sha256sum "${file_path}" | awk '{print $1}'
}

# Build a global cache fingerprint from config inputs.
global_build_fingerprint() {
	local project_root="$1"
	local env_file="${project_root}/config.env"
	local payload=""

	if [[ -f "${env_file}" ]]; then
		payload+=$(<"${env_file}")
	fi

	sha256_string "${payload}"
}

# Build a stage fingerprint from stage script and global fingerprint.
stage_build_fingerprint() {
	local stage_name="$1"
	local stage_script="$2"
	local global_fingerprint="$3"
	local stage_script_sha
	stage_script_sha="$(sha256_file "${stage_script}")"
	sha256_string "${stage_name}:${stage_script_sha}:${global_fingerprint}"
}

# Return success if a string equals any remaining arguments.
string_in_array() {
	local needle="$1"
	shift
	local item
	for item in "$@"; do
		if [[ "${item}" == "${needle}" ]]; then
			return 0
		fi
	done
	return 1
}

# Return the active build root directory.
build_root_dir() {
	local project_root="$1"
	if [[ -n "${BUILD_ROOT:-}" ]]; then
		echo "${BUILD_ROOT}"
		return 0
	fi
	echo "${project_root}/build"
}

# Source a config file while preserving non-empty env overrides.
source_config_with_env_overrides() {
	local config_file="$1"
	shift
	local -A env_overrides=()
	local var_name
	for var_name in "$@"; do
		env_overrides["${var_name}"]="${!var_name-}"
	done

	if [[ -f "${config_file}" ]]; then
		# shellcheck source=/dev/null
		source "${config_file}"
	fi

	for var_name in "$@"; do
		if [[ -n "${env_overrides[${var_name}]}" ]]; then
			printf -v "${var_name}" '%s' "${env_overrides[${var_name}]}"
		fi
	done
}

# Read a string field from a JSON lock file, returning empty when missing.
read_lock_field() {
	local lock_file="$1"
	local key="$2"
	[[ -f "${lock_file}" ]] || return 0

	if command -v jq >/dev/null 2>&1; then
		jq -r --arg key "${key}" '.[$key] // empty' "${lock_file}"
		return 0
	fi

	sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" "${lock_file}" | head -n 1
}
