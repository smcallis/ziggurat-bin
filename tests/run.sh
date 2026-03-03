#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
TEST_SHIMS_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_SHIMS_DIR}"' EXIT

# Ensure git-based fixture tests can commit on clean CI runners.
export GIT_AUTHOR_NAME="test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test"
export GIT_COMMITTER_EMAIL="test@example.com"

# shellcheck source=/dev/null
source "${ROOT_DIR}/tests/lib/runner_env.sh"
setup_test_runner_env "${TEST_SHIMS_DIR}"

for test_file in "${ROOT_DIR}"/tests/test_*.sh; do
	if [[ ! -f "${test_file}" ]]; then
		continue
	fi

	echo "==> Running $(basename "${test_file}")"
	if ! bash "${test_file}"; then
		FAILED=1
	fi
done

if [[ "${FAILED}" -ne 0 ]]; then
	echo "One or more tests failed."
	exit 1
fi

echo "All tests passed."
