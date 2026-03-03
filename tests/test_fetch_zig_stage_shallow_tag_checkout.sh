#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
ZIG_SRC="${TMP_DIR}/zig-src"

mkdir -p "${ZIG_SRC}"
git -C "${ZIG_SRC}" init -q
printf 'llvmorg-20.0.0\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig release"
git -C "${ZIG_SRC}" tag -a -m "v0.13.0" v0.13.0

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="file://${ZIG_SRC}" \
	ZIG_GIT_REF="v0.13.0" \
	LLVM_GIT_REF="llvmorg-20.0.0" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -f "${BUILD_DIR}/src/zig/.git/shallow" ]]; then
	echo "expected shallow git checkout for tag-based zig fetch"
	exit 1
fi
