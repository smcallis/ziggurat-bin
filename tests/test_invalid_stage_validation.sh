#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

OUTPUT_FILE="${TMP_DIR}/output.log"

if bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage not_a_stage \
	--to-stage 00_prepare_dirs \
	--state-dir "${TMP_DIR}/state" \
	--target-dir "${TMP_DIR}/dist" >"${OUTPUT_FILE}" 2>&1; then
	echo "expected invalid stage arguments to fail"
	cat "${OUTPUT_FILE}"
	exit 1
fi

if ! grep -Fq "Unknown stage: not_a_stage" "${OUTPUT_FILE}"; then
	echo "missing invalid-stage error message"
	cat "${OUTPUT_FILE}"
	exit 1
fi
