#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/git_checkout.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
mold_src_dir="${build_root}/src/mold"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${mold_src_dir}"

source_config_with_env_overrides \
	"${PROJECT_ROOT}/config.env" \
	MOLD_VERSION MOLD_GIT_REF MOLD_GIT_URL

mold_git_url="${MOLD_GIT_URL:-https://github.com/rui314/mold.git}"
mold_git_ref="${MOLD_GIT_REF:-}"
mold_version="${MOLD_VERSION:-}"

if [[ -z "${mold_git_ref}" ]]; then
	[[ -n "${mold_version}" ]] || die "Either MOLD_VERSION or MOLD_GIT_REF is required"
	mold_git_ref="v${mold_version#v}"
fi

checkout_git_ref "${mold_git_url}" "${mold_src_dir}" "${mold_git_ref}"
mold_sha="$(resolve_head_sha "${mold_src_dir}")"

printf '{"mold":"%s","ref":"%s","version":"%s","url":"%s"}\n' \
	"${mold_sha}" "${mold_git_ref}" "${mold_version:-${mold_git_ref#v}}" "${mold_git_url}" >"${STATE_DIR}/mold-source-lock.json"
