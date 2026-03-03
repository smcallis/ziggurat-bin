#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${SYSROOT:-${ROOT_DIR}/dist}"

if [[ -z "${SANITIZERS:-}" && -f "${ROOT_DIR}/config.env" ]]; then
	# shellcheck source=/dev/null
	source "${ROOT_DIR}/config.env"
fi
sanitizers="${SANITIZERS:-asan;tsan;msan;ubsan;lsan;rtsan}"

while IFS= read -r sanitizer; do
	[[ -n "${sanitizer}" ]] || continue
	if ! find "${SYSROOT}/lib" -type f -name "*${sanitizer}*" | grep -q .; then
		echo "missing sanitizer runtime for ${sanitizer} in ${SYSROOT}/lib" >&2
		exit 1
	fi
done < <(tr ';' '\n' <<<"${sanitizers}" | sed '/^[[:space:]]*$/d')
