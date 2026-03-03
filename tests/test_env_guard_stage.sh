#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
BOOTSTRAP_BIN="${BUILD_DIR}/bootstrap-toolchain/bin"

mkdir -p "${BOOTSTRAP_BIN}"
printf '%s\n' '#!/usr/bin/env bash' 'echo clang' >"${BOOTSTRAP_BIN}/clang"
printf '%s\n' '#!/usr/bin/env bash' 'echo clang++' >"${BOOTSTRAP_BIN}/clang++"
chmod +x "${BOOTSTRAP_BIN}/clang" "${BOOTSTRAP_BIN}/clang++"

BUILD_ROOT="${BUILD_DIR}" \
	PATH="${BOOTSTRAP_BIN}:${PATH}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 50_disable_host_compilers \
	--to-stage 50_disable_host_compilers \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

env_file="${STATE_DIR}/bootstrap-env.sh"
guard_script="${BUILD_DIR}/guards/check-no-host-compiler.sh"

if [[ ! -f "${env_file}" ]]; then
	echo "expected bootstrap env file"
	exit 1
fi

if [[ ! -x "${guard_script}" ]]; then
	echo "expected executable guard script"
	exit 1
fi

if ! grep -Fq "export CC=${BOOTSTRAP_BIN}/clang" "${env_file}"; then
	echo "expected CC export in env file"
	cat "${env_file}"
	exit 1
fi

if PATH="/usr/bin:${BOOTSTRAP_BIN}" bash "${guard_script}" >/dev/null 2>&1; then
	echo "guard script should fail when host compilers come first"
	exit 1
fi

PATH="${BOOTSTRAP_BIN}:/usr/bin" bash "${guard_script}"
