#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="$(mktemp)"
trap 'rm -f "${OUTPUT_FILE}"' EXIT

if ! bash "${ROOT_DIR}/scripts/build.sh" --help >"${OUTPUT_FILE}" 2>&1; then
	echo "expected --help to succeed"
	cat "${OUTPUT_FILE}"
	exit 1
fi

required_lines=(
	"Usage: scripts/build.sh [options]"
	"--from-stage <name>"
	"--to-stage <name>"
	"--skip-stage <name>"
	"--target-dir <path>"
	"--state-dir <path>"
)

for line in "${required_lines[@]}"; do
	if ! grep -Fq -- "${line}" "${OUTPUT_FILE}"; then
		echo "missing expected help text: ${line}"
		cat "${OUTPUT_FILE}"
		exit 1
	fi
done
