#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
OUT1="${TMP_DIR}/run1.log"
OUT2="${TMP_DIR}/run2.log"

bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 00_prepare_dirs \
	--to-stage 00_prepare_dirs \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}" >"${OUT1}" 2>&1

if [[ ! -f "${STATE_DIR}/00_prepare_dirs.done" ]]; then
	echo "expected stamp file to be created"
	cat "${OUT1}"
	exit 1
fi

bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 00_prepare_dirs \
	--to-stage 00_prepare_dirs \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}" >"${OUT2}" 2>&1

if ! grep -Fq "Skipping stage 00_prepare_dirs (stamp up-to-date)." "${OUT2}"; then
	echo "expected second run to skip stage by stamp"
	cat "${OUT2}"
	exit 1
fi
