#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
LLVM_SRC="${BUILD_DIR}/src/llvm-project/llvm"
BIN_DIR="${TMP_DIR}/bin"

mkdir -p "${LLVM_SRC}" "${BIN_DIR}"

cat >"${BIN_DIR}/fake-cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/cmake-runtime.log"
EOF
chmod +x "${BIN_DIR}/fake-cmake"

cat >"${BIN_DIR}/fake-ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/ninja-runtime.log"
mkdir -p "${BOOTSTRAP_INSTALL_DIR}/bin" "${BOOTSTRAP_INSTALL_DIR}/lib"
for tool in clangd llvm-ar; do
  printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_INSTALL_DIR}/bin/${tool}"
  chmod +x "${BOOTSTRAP_INSTALL_DIR}/bin/${tool}"
done
for san in asan lsan rtsan; do
  printf 'fake-%s\n' "${san}" >"${BOOTSTRAP_INSTALL_DIR}/lib/libclang_rt.${san}-x86_64.a"
done
mkdir -p "${BOOTSTRAP_INSTALL_DIR}/include"
printf '%s\n' 'bootstrap-header' >"${BOOTSTRAP_INSTALL_DIR}/include/bootstrap-only.h"
EOF
chmod +x "${BIN_DIR}/fake-ninja"

BUILD_ROOT="${BUILD_DIR}" \
	TMP_DIR="${TMP_DIR}" \
	CMAKE_BIN="${BIN_DIR}/fake-cmake" \
	NINJA_BIN="${BIN_DIR}/fake-ninja" \
	INITIAL_CC="${BIN_DIR}/fake-cmake" \
	INITIAL_CXX="${BIN_DIR}/fake-cmake" \
	INITIAL_AR="${BIN_DIR}/fake-cmake" \
	INITIAL_RANLIB="${BIN_DIR}/fake-cmake" \
	INITIAL_LD="${BIN_DIR}/fake-cmake" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 30_build_bootstrap_llvm \
	--to-stage 30_build_bootstrap_llvm \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

for required in \
	"${BUILD_DIR}/final-toolchain/llvm/bin/clangd" \
	"${BUILD_DIR}/final-toolchain/llvm/bin/llvm-ar" \
	"${BUILD_DIR}/final-toolchain/llvm/include/bootstrap-only.h" \
	"${BUILD_DIR}/bootstrap-toolchain/include/bootstrap-only.h" \
	"${BUILD_DIR}/final-toolchain/llvm/lib/libclang_rt.asan-x86_64.a" \
	"${BUILD_DIR}/final-toolchain/llvm/lib/libclang_rt.lsan-x86_64.a" \
	"${BUILD_DIR}/final-toolchain/llvm/lib/libclang_rt.rtsan-x86_64.a"; do
	if [[ ! -f "${required}" ]]; then
		echo "missing runtime-stage output: ${required}"
		exit 1
	fi
done

if [[ ! -L "${BUILD_DIR}/final-toolchain/llvm" ]]; then
	echo "expected final llvm path to be a symlink"
	ls -ld "${BUILD_DIR}/final-toolchain/llvm" || true
	exit 1
fi

if ! grep -Fq -- '-DLLVM_ENABLE_RUNTIMES=compiler-rt;libcxx;libcxxabi;libunwind;openmp' "${TMP_DIR}/cmake-runtime.log"; then
	echo "missing LLVM runtimes configuration in cmake invocation"
	cat "${TMP_DIR}/cmake-runtime.log"
	exit 1
fi

if ! grep -Fq -- '-C' "${TMP_DIR}/ninja-runtime.log" || ! grep -Fq -- 'install' "${TMP_DIR}/ninja-runtime.log"; then
	echo "expected install target"
	cat "${TMP_DIR}/ninja-runtime.log"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/bootstrap-llvm.json" ]]; then
	echo "expected bootstrap llvm metadata file"
	exit 1
fi
