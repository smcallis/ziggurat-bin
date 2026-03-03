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

build_root="$(build_root_dir "${PROJECT_ROOT}")"
src_root="${build_root}/src"
llvm_dir="${src_root}/llvm-project"
iwyu_dir="${src_root}/include-what-you-use"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${src_root}"

source_config_with_env_overrides \
	"${PROJECT_ROOT}/config.env" \
	LLVM_GIT_REF LLVM_VERSION IWYU_GIT_REF

assert_iwyu_ref_not_configurable "${IWYU_GIT_REF:-}"

zig_lock_file="${STATE_DIR}/zig-source-lock.json"
if [[ -f "${zig_lock_file}" ]]; then
	if [[ -z "${LLVM_GIT_REF:-}" ]]; then
		LLVM_GIT_REF="$(read_lock_field "${zig_lock_file}" "llvm_ref")"
	fi
	if [[ -z "${LLVM_VERSION:-}" ]]; then
		LLVM_VERSION="$(read_lock_field "${zig_lock_file}" "llvm_version")"
	fi
fi

llvm_url="${LLVM_GIT_URL:-https://github.com/llvm/llvm-project.git}"
iwyu_url="${IWYU_GIT_URL:-https://github.com/include-what-you-use/include-what-you-use.git}"
llvm_ref="${LLVM_GIT_REF:?LLVM_GIT_REF is required}"
llvm_version="${LLVM_VERSION:-}"
if [[ -z "${llvm_version}" && "${llvm_ref}" =~ ^llvmorg-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
	llvm_version="${BASH_REMATCH[1]}"
fi
[[ -n "${llvm_version}" ]] || die "LLVM_VERSION is required to validate IWYU compatibility in stage 20"
iwyu_ref="clang_$(llvm_major_from_version "${llvm_version}")"
assert_iwyu_llvm_compat "${llvm_version}" "${iwyu_ref}"

checkout_git_ref "${llvm_url}" "${llvm_dir}" "${llvm_ref}"
checkout_git_ref "${iwyu_url}" "${iwyu_dir}" "${iwyu_ref}"

llvm_sha="$(resolve_head_sha "${llvm_dir}")"
iwyu_sha="$(resolve_head_sha "${iwyu_dir}")"

printf '{"llvm":"%s","iwyu":"%s"}\n' "${llvm_sha}" "${iwyu_sha}" >"${STATE_DIR}/source-lock.json"
