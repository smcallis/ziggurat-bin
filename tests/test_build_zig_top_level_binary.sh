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

mkdir -p "${BOOTSTRAP_BIN}" "${ZIG_SRC}" "${BIN_DIR}"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

printf '%s\n' '#!/usr/bin/env bash' 'echo zig 0.99.0-test' >"${ZIG_SRC}/zig"
chmod +x "${ZIG_SRC}/zig"
mkdir -p "${ZIG_SRC}/lib"
printf '%s\n' 'placeholder' >"${ZIG_SRC}/lib/placeholder.txt"
mkdir -p "${ZIG_SRC}/lib/std/crypto/pcurves/tests"
printf '%s\n' 'p256 source' >"${ZIG_SRC}/lib/std/crypto/pcurves/tests/p256.zig"
printf '%s\n' 'p384 source' >"${ZIG_SRC}/lib/std/crypto/pcurves/tests/p384.zig"
printf '%s\n' 'secp256k1 source' >"${ZIG_SRC}/lib/std/crypto/pcurves/tests/secp256k1.zig"

cat >"${BIN_DIR}/fake-zig-build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${ZIG_INSTALL_DIR}"
mkdir -p "${ZIG_INSTALL_DIR}/bin" "${ZIG_INSTALL_DIR}/lib"
cp -a "${ZIG_SOURCE_DIR}/zig" "${ZIG_INSTALL_DIR}/bin/zig"
cp -a "${ZIG_SOURCE_DIR}/lib/placeholder.txt" "${ZIG_INSTALL_DIR}/lib/placeholder.txt"
EOF
chmod +x "${BIN_DIR}/fake-zig-build"

BUILD_ROOT="${BUILD_DIR}" \
	INITIAL_TOOLCHAIN_BIN="${BOOTSTRAP_BIN}" \
	ZIG_BUILD_BIN="${BIN_DIR}/fake-zig-build" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 40_build_zig_with_bootstrap \
	--to-stage 40_build_zig_with_bootstrap \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -x "${BUILD_DIR}/final-toolchain/zig/bin/zig" ]]; then
	echo "expected final zig binary at bin/zig"
	exit 1
fi

if [[ ! -f "${BUILD_DIR}/final-toolchain/zig/lib/placeholder.txt" ]]; then
	echo "expected Zig runtime files to be copied"
	exit 1
fi

for required_path in \
	"${BUILD_DIR}/final-toolchain/zig/lib/std/crypto/pcurves/tests/p256.zig" \
	"${BUILD_DIR}/final-toolchain/zig/lib/std/crypto/pcurves/tests/p384.zig" \
	"${BUILD_DIR}/final-toolchain/zig/lib/std/crypto/pcurves/tests/secp256k1.zig"; do
	if [[ ! -f "${required_path}" ]]; then
		echo "expected Zig source file to be preserved in installed lib tree: ${required_path}"
		exit 1
	fi
done

if [[ ! -f "${STATE_DIR}/zig-build.json" ]]; then
	echo "expected zig stage metadata file"
	exit 1
fi

if ! grep -Fq '"mode":"custom-builder"' "${STATE_DIR}/zig-build.json"; then
	echo "unexpected zig build mode"
	cat "${STATE_DIR}/zig-build.json"
	exit 1
fi
