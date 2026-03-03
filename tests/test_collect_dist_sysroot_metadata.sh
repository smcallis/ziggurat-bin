#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
FINAL_DIR="${BUILD_DIR}/final-toolchain"

if ! command -v jq >/dev/null 2>&1; then
	echo "jq not installed; skipping metadata schema test"
	exit 0
fi

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

BUILD_ROOT="${BUILD_DIR}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 90_collect_dist_sysroot \
	--to-stage 90_collect_dist_sysroot \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

jq -e '
	type == "object" and
	(.target_triples | type == "array") and
	(.tool_binaries | type == "array") and
	(.include_roots | type == "array") and
	(.library_roots | type == "array") and
	(.runtime_libraries | type == "array") and
	(.sanitizer_libraries | type == "array")
' "${TARGET_DIR}/TOOLCHAIN_METADATA.json" >/dev/null
