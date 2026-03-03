#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
BOOTSTRAP_BIN="${BUILD_DIR}/bootstrap-toolchain/bin"
ZIG_SRC="${BUILD_DIR}/src/zig/zig-linux-x86_64-test"
LOG_FILE="${TMP_DIR}/build.log"

mkdir -p "${BOOTSTRAP_BIN}" "${ZIG_SRC}/bin"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

printf '%s\n' '#!/usr/bin/env bash' 'echo zig 0.99.0-test' >"${ZIG_SRC}/bin/zig"
chmod +x "${ZIG_SRC}/bin/zig"

set +e
BUILD_ROOT="${BUILD_DIR}" \
	INITIAL_TOOLCHAIN_BIN="${BOOTSTRAP_BIN}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 40_build_zig_with_bootstrap \
	--to-stage 40_build_zig_with_bootstrap \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}" >"${LOG_FILE}" 2>&1
status=$?
set -e

if [[ "${status}" -eq 0 ]]; then
	echo "expected stage 40 fixture to fail without a valid source build setup"
	cat "${LOG_FILE}"
	exit 1
fi

if ! grep -Eq "CMake Error|No such file|not found|error:" "${LOG_FILE}"; then
	echo "expected source-build failure diagnostics"
	cat "${LOG_FILE}"
	exit 1
fi
