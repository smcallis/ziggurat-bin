#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/git_checkout.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/version_match.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/downloads.sh"

## Query remote tags and return the latest stable Zig release tag.
latest_release_tag() {
	local repo_url="$1"

	local selected_tag
	selected_tag="$(
		git ls-remote --tags --refs "${repo_url}" 2>/dev/null |
			awk '
				{
					tag=$2
					sub(/^refs\/tags\//,"",tag)
					normalized=tag
					sub(/^v/,"",normalized)
					if (normalized ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
						printf "%s %s\n", normalized, tag
					}
				}
			' |
			LC_ALL=C sort -k1,1V |
			tail -n 1 |
			awk '{print $2}'
	)"

	[[ -n "${selected_tag}" ]] || die "Unable to resolve latest stable release tag from ${repo_url}"
	echo "${selected_tag}"
}

## Resolve a canonical Zig git ref from configured version.
resolve_zig_ref_from_version() {
	local repo_url="$1"
	local version="$2"
	local candidates=("${version}")

	if [[ "${version}" == v* ]]; then
		candidates+=("${version#v}")
	else
		candidates+=("v${version}")
	fi

	local candidate
	for candidate in "${candidates[@]}"; do
		if remote_tag_exists "${repo_url}" "${candidate}"; then
			echo "${candidate}"
			return 0
		fi
	done

	die "Unable to resolve zig release tag for ZIG_VERSION=${version} from ${repo_url}"
}

## Normalize optional "v" prefix in a version-like ref.
normalize_version_ref() {
	local value="$1"
	if [[ "${value}" == v* ]]; then
		echo "${value#v}"
	else
		echo "${value}"
	fi
}

## Return Zig download index platform key for this host.
host_platform_key() {
	local os
	os="$(uname -s)"
	local arch
	arch="$(uname -m)"

	local os_key
	case "${os}" in
	Linux) os_key="linux" ;;
	Darwin) os_key="macos" ;;
	*) die "Unsupported host OS for zig release detection: ${os}" ;;
	esac

	local arch_key
	case "${arch}" in
	x86_64 | amd64) arch_key="x86_64" ;;
	aarch64 | arm64) arch_key="aarch64" ;;
	*) die "Unsupported host architecture for zig release detection: ${arch}" ;;
	esac

	echo "${arch_key}-${os_key}"
}

## Read LLVM version by running "zig cc --version" from release binary.
llvm_version_from_zig_release_binary() {
	local zig_version="$1"
	local downloads_root="$2"

	local version_key="${zig_version#v}"
	local platform_key
	platform_key="$(host_platform_key)"
	local index_url="${ZIG_DOWNLOAD_INDEX_URL:-https://ziglang.org/download/index.json}"
	local curl_bin="${CURL_BIN:-curl}"
	local jq_bin="${JQ_BIN:-jq}"

	local tarball_url
	tarball_url="$(
		# shellcheck disable=SC2016
		"${curl_bin}" -fsSL "${index_url}" |
			"${jq_bin}" -r --arg version "${version_key}" --arg platform "${platform_key}" '.[$version][$platform].tarball // empty'
	)"
	[[ -n "${tarball_url}" ]] || die "Unable to resolve zig release tarball for ${version_key} (${platform_key}) from ${index_url}"

	local tarball_path="${downloads_root}/zig-${version_key}-${platform_key}.tar.xz"
	local extract_dir="${downloads_root}/zig-release-${version_key}-${platform_key}"
	download_file "${tarball_url}" "${tarball_path}"
	rm -rf "${extract_dir}"
	mkdir -p "${extract_dir}"
	tar -xf "${tarball_path}" -C "${extract_dir}"

	local zig_bin
	zig_bin="$(find "${extract_dir}" -type f -name zig -perm -u+x | head -n 1)"
	[[ -n "${zig_bin}" ]] || die "Unable to locate zig binary in extracted release archive ${tarball_path}"

	local llvm_version
	llvm_version="$("${zig_bin}" cc --version 2>/dev/null | sed -n 's/.*clang version \([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -n 1)"
	[[ -n "${llvm_version}" ]] || die "Unable to derive LLVM version from zig cc --version for ${zig_version}"
	echo "${llvm_version}"
}

## Resolve latest llvmorg patch tag in a major.minor series.
latest_llvm_patch_ref_for_series() {
	local llvm_repo_url="$1"
	local major_minor="$2"
	local selected_ref
	selected_ref="$(
		git ls-remote --tags --refs "${llvm_repo_url}" 2>/dev/null |
			awk -v series="${major_minor}" '
				{
					tag=$2
					sub(/^refs\/tags\//,"",tag)
					if (tag ~ /^llvmorg-[0-9]+\.[0-9]+\.[0-9]+$/) {
						version=tag
						sub(/^llvmorg-/,"",version)
						split(version, parts, ".")
						candidate_series=parts[1] "." parts[2]
						if (candidate_series == series) {
							printf "%s %s\n", version, tag
						}
					}
				}
			' |
			LC_ALL=C sort -k1,1V |
			tail -n 1 |
			awk '{print $2}'
	)"
	[[ -n "${selected_ref}" ]] || die "Unable to resolve LLVM patch tag for series ${major_minor} from ${llvm_repo_url}"
	echo "${selected_ref}"
}

# Prepare stage directories used by source checkout and release probing.
build_root="$(build_root_dir "${PROJECT_ROOT}")"
zig_src_dir="${build_root}/src/zig"
downloads_dir="${build_root}/downloads"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${zig_src_dir}" "${downloads_dir}"

# Load user configuration and enforce fixed IWYU derivation policy.
source_config_with_env_overrides \
	"${PROJECT_ROOT}/config.env" \
	ZIG_VERSION ZIG_GIT_REF ZIG_GIT_URL LLVM_GIT_REF LLVM_VERSION IWYU_GIT_REF

assert_iwyu_ref_not_configurable "${IWYU_GIT_REF:-}"

# Resolve Zig source ref/version (explicit version, explicit ref, or latest release).
zig_git_url="${ZIG_GIT_URL:-https://codeberg.org/ziglang/zig}"

zig_git_ref="${ZIG_GIT_REF:-}"
zig_version="${ZIG_VERSION:-}"
if [[ -n "${zig_git_ref}" && -n "${zig_version}" ]]; then
	if [[ "$(normalize_version_ref "${zig_git_ref}")" != "$(normalize_version_ref "${zig_version}")" ]]; then
		die "ZIG_VERSION and ZIG_GIT_REF conflict: ${zig_version} vs ${zig_git_ref}"
	fi
fi
if [[ -z "${zig_git_ref}" ]]; then
	if [[ -n "${zig_version}" ]]; then
		zig_git_ref="$(resolve_zig_ref_from_version "${zig_git_url}" "${zig_version}")"
	else
		zig_git_ref="$(latest_release_tag "${zig_git_url}")"
	fi
fi
if [[ -z "${zig_version}" ]]; then
	zig_version="${zig_git_ref#v}"
fi

# Checkout Zig source and capture immutable source SHA.
checkout_git_ref "${zig_git_url}" "${zig_src_dir}" "${zig_git_ref}"
zig_sha="$(resolve_head_sha "${zig_src_dir}")"

# Resolve LLVM ref/version aligned to the selected Zig release.
llvm_ref="${LLVM_GIT_REF:-}"
llvm_version="${LLVM_VERSION:-}"
if [[ -z "${llvm_ref}" ]]; then
	if [[ -z "${llvm_version}" ]]; then
		llvm_version="$(llvm_version_from_zig_release_binary "${zig_version}" "${downloads_dir}")"
	fi
	llvm_series="$(cut -d. -f1,2 <<<"${llvm_version}")"
	llvm_repo_url="${LLVM_GIT_URL:-https://github.com/llvm/llvm-project.git}"
	llvm_ref="$(latest_llvm_patch_ref_for_series "${llvm_repo_url}" "${llvm_series}")"
	llvm_version="${llvm_ref#llvmorg-}"
fi
if [[ -z "${llvm_version}" ]]; then
	llvm_version="${llvm_ref#llvmorg-}"
fi

# Derive IWYU ref from LLVM major and persist lock metadata.
llvm_major="${llvm_version%%.*}"
[[ -n "${llvm_major}" ]] || die "Unable to derive LLVM major version from ${llvm_version}"
iwyu_ref="clang_${llvm_major}"

printf '{"zig":"%s","ref":"%s","version":"%s","url":"%s","llvm_ref":"%s","llvm_version":"%s","iwyu_ref":"%s"}\n' \
	"${zig_sha}" "${zig_git_ref}" "${zig_version}" "${zig_git_url}" "${llvm_ref}" "${llvm_version}" "${iwyu_ref}" >"${STATE_DIR}/zig-source-lock.json"
