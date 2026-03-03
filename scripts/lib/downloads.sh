#!/usr/bin/env bash
set -euo pipefail

# Download or copy a file into the local cache path.
download_file() {
	local url="$1"
	local output_path="$2"

	mkdir -p "$(dirname "${output_path}")"

	if [[ -f "${output_path}" ]]; then
		log_info "Using cached download: ${output_path}" >&2
		return 0
	fi

	if [[ "${url}" == file://* ]]; then
		cp "${url#file://}" "${output_path}"
		return 0
	fi

	if [[ -f "${url}" ]]; then
		cp "${url}" "${output_path}"
		return 0
	fi

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "${url}" -o "${output_path}"
		return 0
	fi

	if command -v wget >/dev/null 2>&1; then
		wget -qO "${output_path}" "${url}"
		return 0
	fi

	die "Unable to download ${url}; neither curl nor wget is available."
}

# Read the first checksum token from a checksum file.
checksum_from_file() {
	local checksum_file="$1"
	[[ -f "${checksum_file}" ]] || die "Missing checksum file: ${checksum_file}"

	local first_token
	first_token="$(awk 'NF {print $1; exit}' "${checksum_file}")"
	[[ -n "${first_token}" ]] || die "Checksum file is empty: ${checksum_file}"
	echo "${first_token}"
}

# Verify a file matches an expected SHA-256 value.
verify_sha256() {
	local file_path="$1"
	local expected_sha="$2"

	[[ -f "${file_path}" ]] || die "Missing file for checksum validation: ${file_path}"
	[[ -n "${expected_sha}" ]] || die "Expected sha256 is empty"

	local actual_sha
	actual_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
	if [[ "${actual_sha}" != "${expected_sha}" ]]; then
		die "Checksum mismatch for ${file_path}: expected ${expected_sha}, got ${actual_sha}"
	fi
}

# Extract an archive into an output directory.
extract_archive() {
	local archive_path="$1"
	local output_dir="$2"

	[[ -f "${archive_path}" ]] || die "Missing archive: ${archive_path}"
	mkdir -p "${output_dir}"
	tar -xf "${archive_path}" -C "${output_dir}"
}
