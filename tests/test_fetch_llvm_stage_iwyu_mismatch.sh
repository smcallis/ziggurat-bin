#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
OUTPUT_FILE="${TMP_DIR}/output.log"

LLVM_SRC="${TMP_DIR}/llvm-src"
IWYU_SRC="${TMP_DIR}/iwyu-src"

mkdir -p "${LLVM_SRC}" "${IWYU_SRC}"

git -C "${LLVM_SRC}" init -q
printf 'llvm\n' >"${LLVM_SRC}/README.md"
git -C "${LLVM_SRC}" add README.md
git -C "${LLVM_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init llvm"
llvm_ref="$(git -C "${LLVM_SRC}" rev-parse HEAD)"

git -C "${IWYU_SRC}" init -q
printf 'iwyu\n' >"${IWYU_SRC}/README.md"
git -C "${IWYU_SRC}" add README.md
git -C "${IWYU_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init iwyu"
git -C "${IWYU_SRC}" branch -f clang_19 HEAD

if BUILD_ROOT="${BUILD_DIR}" \
	LLVM_GIT_URL="${LLVM_SRC}" \
	LLVM_GIT_REF="${llvm_ref}" \
	LLVM_VERSION="20.0.0" \
	IWYU_GIT_URL="${IWYU_SRC}" \
	IWYU_GIT_REF="clang_19" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 20_fetch_llvm_iwyu \
	--to-stage 20_fetch_llvm_iwyu \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}" >"${OUTPUT_FILE}" 2>&1; then
	echo "expected stage to fail when IWYU_GIT_REF is explicitly set"
	cat "${OUTPUT_FILE}"
	exit 1
fi

if ! grep -Fq "IWYU_GIT_REF is not configurable; it is derived from LLVM_VERSION" "${OUTPUT_FILE}"; then
	echo "missing non-configurable IWYU error"
	cat "${OUTPUT_FILE}"
	exit 1
fi
