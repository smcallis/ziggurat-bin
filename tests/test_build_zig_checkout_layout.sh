#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
INITIAL_BIN="${TMP_DIR}/initial-bin"
ZIG_SRC_ROOT="${BUILD_DIR}/src/zig"

mkdir -p "${INITIAL_BIN}" "${ZIG_SRC_ROOT}/.git"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${INITIAL_BIN}/${tool}"
	chmod +x "${INITIAL_BIN}/${tool}"
done
printf '%s\n' 'source-marker' >"${ZIG_SRC_ROOT}/README.md"

cat >"${TMP_DIR}/fake-zig-build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "${ZIG_SOURCE_DIR}" >"${TEST_STATE_DIR}/zig-source-dir.txt"
mkdir -p "${ZIG_INSTALL_DIR}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo zig' >"${ZIG_INSTALL_DIR}/bin/zig"
chmod +x "${ZIG_INSTALL_DIR}/bin/zig"
EOF
chmod +x "${TMP_DIR}/fake-zig-build"

export TEST_STATE_DIR="${STATE_DIR}"
BUILD_ROOT="${BUILD_DIR}" \
	INITIAL_TOOLCHAIN_BIN="${INITIAL_BIN}" \
	ZIG_BUILD_BIN="${TMP_DIR}/fake-zig-build" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 40_build_zig_with_bootstrap \
	--to-stage 40_build_zig_with_bootstrap \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ "$(cat "${STATE_DIR}/zig-source-dir.txt")" != "${ZIG_SRC_ROOT}" ]]; then
	echo "expected zig source dir to use checkout root, not .git child"
	cat "${STATE_DIR}/zig-source-dir.txt"
	exit 1
fi
