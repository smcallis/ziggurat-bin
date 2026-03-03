#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${SYSROOT:-${ROOT_DIR}/dist}"

if [[ -z "${TOOLS:-}" && -f "${ROOT_DIR}/config.env" ]]; then
	# shellcheck source=/dev/null
	source "${ROOT_DIR}/config.env"
fi
tools="${TOOLS:-clangd;llvm-ar};include-what-you-use;mold;zig"

while IFS= read -r tool; do
	[[ -n "${tool}" ]] || continue
	if [[ ! -x "${SYSROOT}/bin/${tool}" ]]; then
		echo "missing required tool: ${SYSROOT}/bin/${tool}" >&2
		exit 1
	fi
done < <(tr ';' '\n' <<<"${tools}" | sed '/^[[:space:]]*$/d')
