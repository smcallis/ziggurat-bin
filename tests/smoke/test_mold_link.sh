#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${SYSROOT:-${ROOT_DIR}/dist}"

mold_bin="${SYSROOT}/bin/mold"
[[ -x "${mold_bin}" ]] || {
	echo "missing mold binary: ${mold_bin}" >&2
	exit 1
}
"${mold_bin}" --version >/dev/null
