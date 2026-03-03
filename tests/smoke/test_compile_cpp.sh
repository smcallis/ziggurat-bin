#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${SYSROOT:-${ROOT_DIR}/dist}"

zig_bin="${SYSROOT}/bin/zig"
[[ -x "${zig_bin}" ]] || {
	echo "missing zig binary: ${zig_bin}" >&2
	exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat >"${tmp_dir}/main.cpp" <<'EOF'
#include <iostream>
int main() {
  std::cout << "smoke-ok\n";
  return 0;
}
EOF

"${zig_bin}" c++ "${tmp_dir}/main.cpp" -o "${tmp_dir}/smoke-bin"
output="$("${tmp_dir}/smoke-bin")"
[[ "${output}" == "smoke-ok" ]] || {
	echo "unexpected program output: ${output}" >&2
	exit 1
}
