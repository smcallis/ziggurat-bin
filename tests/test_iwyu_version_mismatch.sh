#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
OUTPUT_FILE="${TMP_DIR}/output.log"
BOOTSTRAP_BIN="${BUILD_DIR}/bootstrap-toolchain/bin"

mkdir -p "${BUILD_DIR}/src/include-what-you-use" "${BUILD_DIR}/src/llvm-project/llvm" "${BOOTSTRAP_BIN}"
for tool in clang clang++; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

if BUILD_ROOT="${BUILD_DIR}" \
	LLVM_VERSION="20.0.0" \
	IWYU_GIT_REF="clang_19" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 80_build_iwyu \
	--to-stage 80_build_iwyu \
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
