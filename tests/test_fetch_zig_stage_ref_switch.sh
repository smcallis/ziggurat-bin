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
printf 'zig-v1\n' >"${ZIG_SRC}/README.md"
git -C "${ZIG_SRC}" add README.md
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig v1"
zig_ref_v1="$(git -C "${ZIG_SRC}" rev-parse HEAD)"

printf 'zig-v2\n' >"${ZIG_SRC}/README.md"
git -C "${ZIG_SRC}" add README.md
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig v2"
zig_ref_v2="$(git -C "${ZIG_SRC}" rev-parse HEAD)"

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_GIT_REF="${zig_ref_v1}" \
	LLVM_GIT_REF="llvmorg-1.2.3" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

rm -f "${STATE_DIR}/10_fetch_zig.done" "${STATE_DIR}/10_fetch_zig.meta"

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_GIT_REF="${zig_ref_v2}" \
	LLVM_GIT_REF="llvmorg-1.2.3" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

zig_head="$(git -C "${BUILD_DIR}/src/zig" rev-parse HEAD)"
if [[ "${zig_head}" != "${zig_ref_v2}" ]]; then
	echo "expected zig checkout to move to requested ref"
	echo "head=${zig_head}"
	echo "expected=${zig_ref_v2}"
	exit 1
fi
