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
printf 'zig\n' >"${ZIG_SRC}/README.md"
git -C "${ZIG_SRC}" add README.md
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init zig"
zig_ref="$(git -C "${ZIG_SRC}" rev-parse HEAD)"

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_GIT_REF="${zig_ref}" \
	LLVM_GIT_REF="llvmorg-1.2.3" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

zig_head="$(git -C "${BUILD_DIR}/src/zig" rev-parse HEAD)"
if [[ "${zig_head}" != "${zig_ref}" ]]; then
	echo "zig checkout mismatch"
	exit 1
fi

if [[ ! -f "${STATE_DIR}/zig-source-lock.json" ]]; then
	echo "expected zig source lock file"
	exit 1
fi

if ! grep -Fq "\"zig\":\"${zig_ref}\"" "${STATE_DIR}/zig-source-lock.json"; then
	echo "zig source lock missing ref"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi
