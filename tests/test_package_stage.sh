#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
OUT_DIR="${TMP_DIR}/out"
UNPACK_DIR="${TMP_DIR}/unpack"

mkdir -p "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" "${TARGET_DIR}/include"
printf '%s\n' '#!/usr/bin/env bash' 'echo zig' >"${TARGET_DIR}/bin/zig"
chmod +x "${TARGET_DIR}/bin/zig"
printf 'fake-lib\n' >"${TARGET_DIR}/lib/libc++.a"
printf 'header\n' >"${TARGET_DIR}/include/vector"
printf 'manifest\n' >"${TARGET_DIR}/MANIFEST.txt"
printf 'version\n' >"${TARGET_DIR}/VERSION.txt"
printf '{"meta":true}\n' >"${TARGET_DIR}/TOOLCHAIN_METADATA.json"

ZIG_VERSION="testpkg" \
	OUT_DIR="${OUT_DIR}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 99_package \
	--to-stage 99_package \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

archive_path="${OUT_DIR}/ziggurat-testpkg.tar.xz"
if [[ ! -f "${archive_path}" ]]; then
	echo "expected package archive at ${archive_path}"
	exit 1
fi

if [[ "$(cat "${STATE_DIR}/package-path.txt")" != "${archive_path}" ]]; then
	echo "package state file has unexpected path"
	cat "${STATE_DIR}/package-path.txt"
	exit 1
fi

mkdir -p "${UNPACK_DIR}"
tar -xJf "${archive_path}" -C "${UNPACK_DIR}"

for required in \
	"${UNPACK_DIR}/bin/zig" \
	"${UNPACK_DIR}/lib/libc++.a" \
	"${UNPACK_DIR}/include/vector" \
	"${UNPACK_DIR}/MANIFEST.txt" \
	"${UNPACK_DIR}/VERSION.txt" \
	"${UNPACK_DIR}/TOOLCHAIN_METADATA.json"; do
	if [[ ! -f "${required}" ]]; then
		echo "missing unpacked payload file: ${required}"
		exit 1
	fi
done
