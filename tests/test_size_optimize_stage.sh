#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"

mkdir -p \
	"${TARGET_DIR}/bin" \
	"${TARGET_DIR}/lib" \
	"${TARGET_DIR}/include" \
	"${TARGET_DIR}/share/doc" \
	"${TARGET_DIR}/share/examples" \
	"${TARGET_DIR}/lib/tests" \
	"${TARGET_DIR}/lib/std/crypto/pcurves/tests"

printf '%s\n' '#!/usr/bin/env bash' 'echo tool' >"${TARGET_DIR}/bin/tool"
chmod +x "${TARGET_DIR}/bin/tool"
printf 'lib\n' >"${TARGET_DIR}/lib/libfoo.a"
printf 'hdr\n' >"${TARGET_DIR}/include/foo.h"
printf 'doc\n' >"${TARGET_DIR}/share/doc/readme.txt"
printf 'example\n' >"${TARGET_DIR}/share/examples/example.txt"
printf 'test\n' >"${TARGET_DIR}/lib/tests/test.txt"
printf 'zig source\n' >"${TARGET_DIR}/lib/std/crypto/pcurves/tests/p256.zig"

bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 95_size_optimize \
	--to-stage 95_size_optimize \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

for removed_path in \
	"${TARGET_DIR}/share/doc" \
	"${TARGET_DIR}/share/examples" \
	"${TARGET_DIR}/lib/tests"; do
	if [[ -e "${removed_path}" ]]; then
		echo "expected path to be removed by size optimization: ${removed_path}"
		exit 1
	fi
done

if [[ ! -f "${TARGET_DIR}/lib/std/crypto/pcurves/tests/p256.zig" ]]; then
	echo "expected zig std source test file to be preserved"
	exit 1
fi

for required_path in \
	"${TARGET_DIR}/bin/tool" \
	"${TARGET_DIR}/lib/libfoo.a" \
	"${TARGET_DIR}/include/foo.h"; do
	if [[ ! -e "${required_path}" ]]; then
		echo "required payload path missing after optimization: ${required_path}"
		exit 1
	fi
done

if [[ ! -f "${STATE_DIR}/size-report.txt" ]]; then
	echo "expected size report"
	exit 1
fi
