#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
BOOTSTRAP_BIN="${BUILD_DIR}/bootstrap-toolchain/bin"
BIN_DIR="${TMP_DIR}/bin"

mkdir -p \
	"${BUILD_DIR}/src/include-what-you-use" \
	"${BUILD_DIR}/src/llvm-project/llvm" \
	"${BUILD_DIR}/final-toolchain/llvm/lib/cmake/llvm" \
	"${BUILD_DIR}/final-toolchain/llvm/lib/cmake/clang" \
	"${BOOTSTRAP_BIN}" \
	"${BIN_DIR}"

for tool in clang clang++; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

cat >"${BIN_DIR}/fake-cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/cmake-iwyu.log"
EOF
chmod +x "${BIN_DIR}/fake-cmake"

cat >"${BIN_DIR}/fake-ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/ninja-iwyu.log"
mkdir -p "${IWYU_INSTALL_DIR}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo include-what-you-use' >"${IWYU_INSTALL_DIR}/bin/include-what-you-use"
chmod +x "${IWYU_INSTALL_DIR}/bin/include-what-you-use"
EOF
chmod +x "${BIN_DIR}/fake-ninja"

BUILD_ROOT="${BUILD_DIR}" \
	TMP_DIR="${TMP_DIR}" \
	CMAKE_BIN="${BIN_DIR}/fake-cmake" \
	NINJA_BIN="${BIN_DIR}/fake-ninja" \
	LLVM_VERSION="19.1.7" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 80_build_iwyu \
	--to-stage 80_build_iwyu \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -x "${BUILD_DIR}/final-toolchain/iwyu/bin/include-what-you-use" ]]; then
	echo "expected iwyu binary"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/iwyu-build.json" ]]; then
	echo "expected iwyu metadata file"
	exit 1
fi

if ! grep -Fq -- "-DClang_DIR=${BUILD_DIR}/final-toolchain/llvm/lib/cmake/clang" "${TMP_DIR}/cmake-iwyu.log"; then
	echo "expected Clang_DIR to be set to final LLVM clang config path"
	cat "${TMP_DIR}/cmake-iwyu.log"
	exit 1
fi
