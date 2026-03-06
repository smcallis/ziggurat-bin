#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/common.sh"

resolve_release_metadata() {
	local zig_version=""
	local zig_git_url="https://codeberg.org/ziglang/zig"

	if [[ -f "${ROOT_DIR}/config.env" ]]; then
		# shellcheck source=/dev/null
		source "${ROOT_DIR}/config.env"
	fi

	if [[ -n "${ZIG_GIT_URL:-}" ]]; then
		zig_git_url="${ZIG_GIT_URL}"
	fi

	if [[ -n "${ZIG_VERSION:-}" ]]; then
		zig_version="${ZIG_VERSION#v}"
	elif [[ -n "${ZIG_GIT_REF:-}" && "${ZIG_GIT_REF}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		zig_version="${ZIG_GIT_REF#v}"
	else
		zig_version="$(
			git ls-remote --tags --refs "${zig_git_url}" |
				awk '
					{
						tag=$2
						sub(/^refs\/tags\//, "", tag)
						normalized=tag
						sub(/^v/, "", normalized)
						if (normalized ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
							print normalized
						}
					}
				' |
				LC_ALL=C sort -V |
				tail -n 1
		)"
	fi

	[[ -n "${zig_version}" ]] || die "failed to resolve zig_version"

	RELEASE_ZIG_VERSION="${zig_version}"
	RELEASE_TAG="v${zig_version}"
	RELEASE_ASSET_NAME="ziggurat-${zig_version}.tar.xz"
	RELEASE_ASSET_SHA_NAME="ziggurat-${zig_version}.tar.xz.sha256"
}

check_existing_release_artifact() {
	SKIP_BUILD=false
	if [[ "${ENABLE_GITHUB_RELEASES:-0}" != "1" ]]; then
		return 0
	fi

	command -v gh >/dev/null 2>&1 || die "gh is required when ENABLE_GITHUB_RELEASES=1"
	[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required when ENABLE_GITHUB_RELEASES=1"

	local release_assets
	if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
		release_assets="$(gh release view "${RELEASE_TAG}" --json assets --jq '.assets[].name')"
		if grep -Fxq "${RELEASE_ASSET_NAME}" <<<"${release_assets}" &&
			grep -Fxq "${RELEASE_ASSET_SHA_NAME}" <<<"${release_assets}"; then
			SKIP_BUILD=true
		fi
	fi
}

verify_archive_exists() {
	local archive_path="${ROOT_DIR}/out/${RELEASE_ASSET_NAME}"
	local checksum_path="${ROOT_DIR}/out/${RELEASE_ASSET_SHA_NAME}"

	[[ -f "${archive_path}" ]] || die "expected ${archive_path}"
	[[ -f "${checksum_path}" ]] || die "expected ${checksum_path}"
}

ensure_release_exists() {
	[[ "${ENABLE_GITHUB_RELEASES:-0}" == "1" ]] || return 0

	if ! gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
		gh release create "${RELEASE_TAG}" \
			--target "${GITHUB_SHA:-HEAD}" \
			--title "${RELEASE_TAG}" \
			--notes "Release for Zig ${RELEASE_ZIG_VERSION}."
	fi
}

upload_release_assets() {
	[[ "${ENABLE_GITHUB_RELEASES:-0}" == "1" ]] || return 0

	gh release upload \
		"${RELEASE_TAG}" \
		"${ROOT_DIR}/out/${RELEASE_ASSET_NAME}" \
		"${ROOT_DIR}/out/${RELEASE_ASSET_SHA_NAME}" \
		--clobber
}

main() {
	cd "${ROOT_DIR}"

	resolve_release_metadata
	check_existing_release_artifact

	if [[ "${SKIP_BUILD}" == "true" ]]; then
		log_info "Release asset already exists for ${RELEASE_TAG}; skipping build."
		log_info "${RELEASE_ASSET_NAME}"
		log_info "${RELEASE_ASSET_SHA_NAME}"
		exit 0
	fi

	bash tests/run.sh
	bash scripts/build.sh --from-stage 00_prepare_dirs --to-stage 99_package
	verify_archive_exists
	ensure_release_exists
	upload_release_assets

	log_info "Local CI run completed."
	log_info "Archive: out/${RELEASE_ASSET_NAME}"
	log_info "Checksum: out/${RELEASE_ASSET_SHA_NAME}"
}

main "$@"
