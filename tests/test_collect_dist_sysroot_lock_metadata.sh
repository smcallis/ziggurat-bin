#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
FINAL_DIR="${BUILD_DIR}/final-toolchain"

mkdir -p \
	"${FINAL_DIR}/zig/bin" \
	"${FINAL_DIR}/llvm/bin" \
	"${FINAL_DIR}/llvm/lib" \
	"${FINAL_DIR}/llvm/include/c++/v1" \
	"${FINAL_DIR}/mold/bin" \
	"${FINAL_DIR}/iwyu/bin"

printf '%s\n' '#!/usr/bin/env bash' 'echo zig' >"${FINAL_DIR}/zig/bin/zig"
printf '%s\n' '#!/usr/bin/env bash' 'echo mold' >"${FINAL_DIR}/mold/bin/mold"
printf '%s\n' '#!/usr/bin/env bash' 'echo iwyu' >"${FINAL_DIR}/iwyu/bin/include-what-you-use"
chmod +x "${FINAL_DIR}/zig/bin/zig" "${FINAL_DIR}/mold/bin/mold" "${FINAL_DIR}/iwyu/bin/include-what-you-use"

TOOLS=""
# shellcheck source=/dev/null
source "${ROOT_DIR}/config.env"
while IFS= read -r tool; do
	[[ -n "${tool}" ]] || continue
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${FINAL_DIR}/llvm/bin/${tool}"
	chmod +x "${FINAL_DIR}/llvm/bin/${tool}"
done < <(tr ';' '\n' <<<"${TOOLS}")

printf 'fake-lib\n' >"${FINAL_DIR}/llvm/lib/libc++.a"
printf 'vector header\n' >"${FINAL_DIR}/llvm/include/c++/v1/vector"

mkdir -p "${STATE_DIR}"
cat >"${STATE_DIR}/zig-source-lock.json" <<'EOF'
{"zig":"deadbeef","ref":"0.13.0","version":"0.13.0","url":"test","llvm_ref":"llvmorg-20.1.2","llvm_version":"20.1.2","iwyu_ref":"clang_20"}
EOF

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_VERSION="9.9.9" \
	LLVM_VERSION="99.9.9" \
	LLVM_GIT_REF="llvmorg-99.9.9" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 90_collect_dist_sysroot \
	--to-stage 90_collect_dist_sysroot \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if ! grep -Fq 'zig_version=0.13.0' "${TARGET_DIR}/VERSION.txt"; then
	echo "expected zig_version from zig-source-lock.json"
	cat "${TARGET_DIR}/VERSION.txt"
	exit 1
fi

if ! grep -Fq 'llvm_version=20.1.2' "${TARGET_DIR}/VERSION.txt"; then
	echo "expected llvm_version from zig-source-lock.json"
	cat "${TARGET_DIR}/VERSION.txt"
	exit 1
fi

if ! grep -Fq 'llvm_ref=llvmorg-20.1.2' "${TARGET_DIR}/VERSION.txt"; then
	echo "expected llvm_ref from zig-source-lock.json"
	cat "${TARGET_DIR}/VERSION.txt"
	exit 1
fi

if ! grep -Fq 'iwyu_ref=clang_20' "${TARGET_DIR}/VERSION.txt"; then
	echo "expected iwyu_ref derived from lock llvm version"
	cat "${TARGET_DIR}/VERSION.txt"
	exit 1
fi
