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

mkdir -p "${BUILD_DIR}/src/mold" "${BOOTSTRAP_BIN}" "${BIN_DIR}"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${BOOTSTRAP_BIN}/${tool}"
	chmod +x "${BOOTSTRAP_BIN}/${tool}"
done

cat >"${BIN_DIR}/fake-cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/cmake-mold.log"
EOF
chmod +x "${BIN_DIR}/fake-cmake"

cat >"${BIN_DIR}/fake-ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${TMP_DIR}/ninja-mold.log"
mkdir -p "${MOLD_INSTALL_DIR}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo mold' >"${MOLD_INSTALL_DIR}/bin/mold"
chmod +x "${MOLD_INSTALL_DIR}/bin/mold"
EOF
chmod +x "${BIN_DIR}/fake-ninja"

BUILD_ROOT="${BUILD_DIR}" \
	TMP_DIR="${TMP_DIR}" \
	CMAKE_BIN="${BIN_DIR}/fake-cmake" \
	NINJA_BIN="${BIN_DIR}/fake-ninja" \
	MOLD_VERSION="2.50.0-test" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 70_build_mold \
	--to-stage 70_build_mold \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -x "${BUILD_DIR}/final-toolchain/mold/bin/mold" ]]; then
	echo "expected mold binary"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/mold-build.json" ]]; then
	echo "expected mold metadata file"
	exit 1
fi

if ! grep -Fq '"mold_version":"2.50.0-test"' "${STATE_DIR}/mold-build.json"; then
	echo "unexpected mold version in metadata"
	cat "${STATE_DIR}/mold-build.json"
	exit 1
fi
