#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${SYSROOT:-${ROOT_DIR}/dist}"

iwyu_bin="${SYSROOT}/bin/include-what-you-use"
[[ -x "${iwyu_bin}" ]] || {
	echo "missing include-what-you-use binary: ${iwyu_bin}" >&2
	exit 1
}
"${iwyu_bin}" --version >/dev/null
