#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}"

if [[ "${STRIP_BINARIES:-1}" == "1" ]] && command -v strip >/dev/null 2>&1; then
	while IFS= read -r file_path; do
		strip --strip-unneeded "${file_path}" >/dev/null 2>&1 || true
	done < <(find "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" -type f 2>/dev/null)
fi

find "${TARGET_DIR}" \
	-type d \
	\( -name doc -o -name docs -o -name examples \) \
	-prune \
	-exec rm -rf {} +

find "${TARGET_DIR}" \
	-path "${TARGET_DIR}/lib/std" \
	-prune \
	-o \
	-type d \
	\( -name test -o -name tests \) \
	-prune \
	-exec rm -rf {} +

du -sh "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" "${TARGET_DIR}/include" 2>/dev/null | sed 's#'"${TARGET_DIR}"'/##' >"${STATE_DIR}/size-report.txt"
