#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if grep -Fq 'payload_bazel.sh' "${ROOT_DIR}/scripts/stages/90_collect_dist_sysroot.sh"; then
	echo "stage 90 should not source payload_bazel.sh"
	exit 1
fi

cp_a_count="$(grep -Ec 'cp -a( |$)' "${ROOT_DIR}/scripts/stages/90_collect_dist_sysroot.sh" || true)"
if [[ "${cp_a_count}" != "1" ]]; then
	echo "stage 90 should use a single cp -a helper implementation"
	exit 1
fi

if ! grep -Fq 'cp -a --no-preserve=ownership "$@"' "${ROOT_DIR}/scripts/stages/90_collect_dist_sysroot.sh"; then
	echo "stage 90 copy helper should disable ownership preservation"
	exit 1
fi

for required_tool in ar objcopy ranlib cc objdump; do
	if ! command -v "${required_tool}" >/dev/null 2>&1; then
		echo "missing required test tool: ${required_tool}"
		exit 1
	fi
done

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
FINAL_DIR="${BUILD_DIR}/final-toolchain"

mkdir -p \
	"${FINAL_DIR}/zig/bin" \
	"${FINAL_DIR}/llvm/bin" \
	"${FINAL_DIR}/llvm/lib/clang/20/lib/aarch64-unknown-linux-gnu" \
	"${FINAL_DIR}/llvm/lib/clang/20/lib/x86_64-unknown-linux-gnu" \
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

ln -sf "$(command -v ar)" "${FINAL_DIR}/llvm/bin/llvm-ar"
ln -sf "$(command -v ranlib)" "${FINAL_DIR}/llvm/bin/llvm-ranlib"
ln -sf "$(command -v objcopy)" "${FINAL_DIR}/llvm/bin/llvm-objcopy"

printf 'fake-lib\n' >"${FINAL_DIR}/llvm/lib/libc++.a"
printf 'fake-asan\n' >"${FINAL_DIR}/llvm/lib/libclang_rt.asan-x86_64.a"
printf 'fake-current-asan\n' >"${FINAL_DIR}/llvm/lib/clang/20/lib/x86_64-unknown-linux-gnu/libclang_rt.asan.a"
printf 'vector header\n' >"${FINAL_DIR}/llvm/include/c++/v1/vector"

cat >"${TMP_DIR}/fuzzer_runtime.c" <<'EOF'
int ziggurat_fuzzer_runtime(void) { return 0; }
EOF
cc -c "${TMP_DIR}/fuzzer_runtime.c" -o "${TMP_DIR}/fuzzer_runtime.o"
: >"${TMP_DIR}/empty.section"
objcopy \
	--add-section .deplibs="${TMP_DIR}/empty.section" \
	--add-section .linker-options="${TMP_DIR}/empty.section" \
	"${TMP_DIR}/fuzzer_runtime.o"
ar qc \
	"${FINAL_DIR}/llvm/lib/clang/20/lib/x86_64-unknown-linux-gnu/libclang_rt.fuzzer.a" \
	"${TMP_DIR}/fuzzer_runtime.o"
ranlib "${FINAL_DIR}/llvm/lib/clang/20/lib/x86_64-unknown-linux-gnu/libclang_rt.fuzzer.a"

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
	"${TARGET_DIR}/BUILD.bazel" \
	"${TARGET_DIR}/lib/libc++.a" \
	"${TARGET_DIR}/lib/libclang_rt.asan-x86_64.a" \
	"${TARGET_DIR}/include/c++/v1/vector"; do
	if [[ ! -f "${expected_path}" ]]; then
		echo "expected assembled file missing: ${expected_path}"
		exit 1
	fi
done

if [[ ! -L "${TARGET_DIR}/lib/clang/current" ]]; then
	echo "expected lib/clang/current symlink in dist payload"
	exit 1
fi

if [[ "$(readlink "${TARGET_DIR}/lib/clang/current")" != "20" ]]; then
	echo "expected lib/clang/current symlink target to be 20"
	ls -l "${TARGET_DIR}/lib/clang"
	exit 1
fi

mkdir -p "${TMP_DIR}/patched-fuzzer"
cp "${TARGET_DIR}/lib/clang/current/lib/x86_64-unknown-linux-gnu/libclang_rt.fuzzer.a" \
	"${TMP_DIR}/patched-fuzzer/"
(
	cd "${TMP_DIR}/patched-fuzzer"
	if [[ "$(
		ar t libclang_rt.fuzzer.a | wc -l | tr -d '[:space:]'
	)" != "1" ]]; then
		echo "expected patched fuzzer archive to contain one object"
		ar t libclang_rt.fuzzer.a
		exit 1
	fi
	ar x libclang_rt.fuzzer.a
	if objdump -h fuzzer_runtime.o | grep -Eq '\.(deplibs|linker-options)'; then
		echo "expected patched fuzzer archive to remove dependent-library sections"
		objdump -h fuzzer_runtime.o
		exit 1
	fi
)

if ! cmp -s "${ROOT_DIR}/payload/BUILD.bazel" "${TARGET_DIR}/BUILD.bazel"; then
	echo "payload BUILD.bazel does not match checked-in source"
	exit 1
fi

for removed_target in llvm_cov llvm_profdata llvm_symbolizer; do
	if grep -Fq "name = \"${removed_target}\"" "${TARGET_DIR}/BUILD.bazel"; then
		echo "payload BUILD.bazel should not define top-level binary label ${removed_target}"
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

if [[ -e "${TARGET_DIR}/TOOLCHAIN_METADATA.json" ]]; then
	echo "did not expect TOOLCHAIN_METADATA.json in dist payload"
	exit 1
fi
