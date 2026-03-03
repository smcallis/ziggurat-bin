#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"

zig_bin="${TARGET_DIR}/bin/zig"
zig_lib_dir="${TARGET_DIR}/lib"
cache_dir="${STATE_DIR}/zig-cache"
wrapper_out="${STATE_DIR}/zig-wrapper-smoke"
cpp_src="${STATE_DIR}/hello.cc"
cpp_out="${STATE_DIR}/hello"

[[ -x "${zig_bin}" ]] || die "Missing zig binary in payload: ${zig_bin}"
[[ -d "${zig_lib_dir}" ]] || die "Missing zig lib dir in payload: ${zig_lib_dir}"

mkdir -p "${STATE_DIR}" "${cache_dir}"

cat >"${cpp_src}" <<'EOF'
#include <vector>

int main() {
	std::vector<int> values{1, 2, 3};
	return values[0] - 1;
}
EOF

env \
	ZIG_LIB_DIR="${zig_lib_dir}" \
	ZIG_LOCAL_CACHE_DIR="${cache_dir}" \
	ZIG_GLOBAL_CACHE_DIR="${cache_dir}" \
	"${zig_bin}" build-exe \
	-fstrip \
	-OReleaseSafe \
	-femit-bin="${wrapper_out}" \
	"${PROJECT_ROOT}/toolchain/lib/zig-wrapper.zig"

[[ -x "${wrapper_out}" ]] || die "zig-wrapper compile validation did not produce ${wrapper_out}"

env \
	ZIG_LIB_DIR="${zig_lib_dir}" \
	ZIG_LOCAL_CACHE_DIR="${cache_dir}" \
	ZIG_GLOBAL_CACHE_DIR="${cache_dir}" \
	"${zig_bin}" c++ \
	-std=c++20 \
	"${cpp_src}" \
	-o "${cpp_out}"

[[ -f "${cpp_out}" ]] || die "C++ compile validation did not produce ${cpp_out}"
