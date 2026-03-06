#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT_DIR}/tests/lib/runner_env.sh"
setup_test_runner_env "${TMP_DIR}/bin"

if apt-get update >"${TMP_DIR}/apt.log" 2>&1; then
	echo "expected apt-get to be blocked by test runner env"
	exit 1
fi

if ! grep -Fq "blocked during tests" "${TMP_DIR}/apt.log"; then
	echo "expected blocking message from apt-get shim"
	cat "${TMP_DIR}/apt.log"
	exit 1
fi
