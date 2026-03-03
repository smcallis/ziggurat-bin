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
BIN_DIR="${TMP_DIR}/bin"

mkdir -p "${BOOTSTRAP_BIN}" "${ZIG_SRC}/bin" "${BIN_DIR}"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	printf '%s\n' '#!/usr/bin/env bash' "echo bootstrap-${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

printf '%s\n' '#!/usr/bin/env bash' 'echo zig 0.99.0-test' >"${ZIG_SRC}/bin/zig"
chmod +x "${ZIG_SRC}/bin/zig"

cat >"${BIN_DIR}/fake-zig-build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "${CC}" >"${TEST_STATE_DIR}/zig-build-cc.txt"
echo "${CXX}" >"${TEST_STATE_DIR}/zig-build-cxx.txt"
mkdir -p "${ZIG_INSTALL_DIR}"
cp -a "${ZIG_SOURCE_DIR}/." "${ZIG_INSTALL_DIR}/"
EOF
chmod +x "${BIN_DIR}/fake-zig-build"

export TEST_STATE_DIR="${STATE_DIR}"
BUILD_ROOT="${BUILD_DIR}" \
	INITIAL_TOOLCHAIN_BIN="${BOOTSTRAP_BIN}" \
	ZIG_BUILD_BIN="${BIN_DIR}/fake-zig-build" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 40_build_zig_with_bootstrap \
	--to-stage 40_build_zig_with_bootstrap \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -x "${BUILD_DIR}/final-toolchain/zig/bin/zig" ]]; then
	echo "expected final zig binary"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/zig-build.json" ]]; then
	echo "expected zig stage metadata file"
	exit 1
fi

if ! grep -Fq '"mode":"custom-builder"' "${STATE_DIR}/zig-build.json"; then
	echo "unexpected zig build mode"
	cat "${STATE_DIR}/zig-build.json"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/zig-build-cc.txt" ]]; then
	echo "expected custom zig builder to run"
	exit 1
fi

if [[ "$(cat "${STATE_DIR}/zig-build-cc.txt")" != "${BOOTSTRAP_BIN}/clang" ]]; then
	echo "expected CC to resolve from initial toolchain bin"
	cat "${STATE_DIR}/zig-build-cc.txt"
	exit 1
fi
