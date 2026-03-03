#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for smoke_test in \
	"${ROOT_DIR}/tests/smoke/test_compile_cpp.sh" \
	"${ROOT_DIR}/tests/smoke/test_sanitizers.sh" \
	"${ROOT_DIR}/tests/smoke/test_tools_present.sh" \
	"${ROOT_DIR}/tests/smoke/test_iwyu.sh" \
	"${ROOT_DIR}/tests/smoke/test_mold_link.sh"; do
	echo "==> Running $(basename "${smoke_test}")"
	bash "${smoke_test}"
done

echo "Smoke tests passed."
