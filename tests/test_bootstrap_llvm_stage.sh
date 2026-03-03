#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
BIN_DIR="${TMP_DIR}/bin"

mkdir -p "${BUILD_DIR}/src/llvm-project/llvm" "${BIN_DIR}"

cat >"${BIN_DIR}/fake-cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/cmake.log"
EOF
chmod +x "${BIN_DIR}/fake-cmake"

cat >"${BIN_DIR}/fake-ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/ninja.log"
mkdir -p "${BOOTSTRAP_INSTALL_DIR}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo clang' >"${BOOTSTRAP_INSTALL_DIR}/bin/clang"
printf '%s\n' '#!/usr/bin/env bash' 'echo ld.lld' >"${BOOTSTRAP_INSTALL_DIR}/bin/ld.lld"
chmod +x "${BOOTSTRAP_INSTALL_DIR}/bin/clang" "${BOOTSTRAP_INSTALL_DIR}/bin/ld.lld"
EOF
chmod +x "${BIN_DIR}/fake-ninja"

BUILD_ROOT="${BUILD_DIR}" \
	TMP_DIR="${TMP_DIR}" \
	CMAKE_BIN="${BIN_DIR}/fake-cmake" \
	NINJA_BIN="${BIN_DIR}/fake-ninja" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 30_build_bootstrap_llvm \
	--to-stage 30_build_bootstrap_llvm \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -x "${BUILD_DIR}/bootstrap-toolchain/bin/clang" ]]; then
	echo "expected bootstrap clang binary placeholder"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/bootstrap-llvm.json" ]]; then
	echo "expected bootstrap metadata file"
	exit 1
fi

if ! grep -Fq '"projects":"clang;clang-tools-extra;lld"' "${STATE_DIR}/bootstrap-llvm.json"; then
	echo "missing projects configuration in bootstrap metadata"
	cat "${STATE_DIR}/bootstrap-llvm.json"
	exit 1
fi

if ! grep -Fq -- '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld' "${TMP_DIR}/cmake.log"; then
	echo "cmake invocation missing expected projects setting"
	cat "${TMP_DIR}/cmake.log"
	exit 1
fi

if ! grep -Fq -- '-DCMAKE_C_COMPILER=/usr/bin/clang' "${TMP_DIR}/cmake.log"; then
	echo "cmake invocation missing initial clang compiler"
	cat "${TMP_DIR}/cmake.log"
	exit 1
fi

if ! grep -Fq -- '-DCMAKE_CXX_COMPILER=/usr/bin/clang++' "${TMP_DIR}/cmake.log"; then
	echo "cmake invocation missing initial clang++ compiler"
	cat "${TMP_DIR}/cmake.log"
	exit 1
fi

if ! grep -Fq -- '-DLLVM_ENABLE_ZSTD=OFF' "${TMP_DIR}/cmake.log"; then
	echo "cmake invocation missing zstd disable flag"
	cat "${TMP_DIR}/cmake.log"
	exit 1
fi

if grep -Fq -- '-DLLVM_TARGETS_TO_BUILD=' "${TMP_DIR}/cmake.log"; then
	echo "cmake invocation should not force restricted llvm targets by default"
	cat "${TMP_DIR}/cmake.log"
	exit 1
fi
