#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/version_match.sh"

env_iwyu_git_ref="${IWYU_GIT_REF:-}"
if [[ -f "${PROJECT_ROOT}/config.env" ]]; then
	# shellcheck source=/dev/null
	source "${PROJECT_ROOT}/config.env"
fi
assert_iwyu_ref_not_configurable "${env_iwyu_git_ref}"
assert_iwyu_ref_not_configurable "${IWYU_GIT_REF:-}"

mkdir -p "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" "${TARGET_DIR}/include"
mkdir -p "${STATE_DIR}"
mkdir -p "${PROJECT_ROOT}/build" "${PROJECT_ROOT}/out"
