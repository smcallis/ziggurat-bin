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
printf 'fake-asan\n' >"${FINAL_DIR}/llvm/lib/libclang_rt.asan-x86_64.a"
printf 'vector header\n' >"${FINAL_DIR}/llvm/include/c++/v1/vector"

BUILD_ROOT="${BUILD_DIR}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 90_collect_dist_sysroot \
	--to-stage 90_collect_dist_sysroot \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

for expected_path in \
	"${TARGET_DIR}/bin/zig" \
	"${TARGET_DIR}/bin/clangd" \
	"${TARGET_DIR}/bin/mold" \
	"${TARGET_DIR}/bin/include-what-you-use" \
	"${TARGET_DIR}/lib/libc++.a" \
	"${TARGET_DIR}/lib/libclang_rt.asan-x86_64.a" \
	"${TARGET_DIR}/include/c++/v1/vector"; do
	if [[ ! -f "${expected_path}" ]]; then
		echo "expected assembled file missing: ${expected_path}"
		exit 1
	fi
done

if ! grep -Fq "bin/zig" "${TARGET_DIR}/MANIFEST.txt"; then
	echo "manifest missing bin/zig entry"
	cat "${TARGET_DIR}/MANIFEST.txt"
	exit 1
fi

if ! grep -Fq "zig_version=" "${TARGET_DIR}/VERSION.txt"; then
	echo "version file missing zig_version"
	cat "${TARGET_DIR}/VERSION.txt"
	exit 1
fi

for tool in zig mold include-what-you-use clangd llvm-ar llvm-lld; do
	if ! grep -Fq "\"${tool}\"" "${TARGET_DIR}/TOOLCHAIN_METADATA.json"; then
		echo "metadata file missing expected tool: ${tool}"
		cat "${TARGET_DIR}/TOOLCHAIN_METADATA.json"
		exit 1
	fi
done
