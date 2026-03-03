#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
ZIG_SRC="${TMP_DIR}/zig-src"
OUTPUT_FILE="${TMP_DIR}/output.log"

mkdir -p "${ZIG_SRC}"
git -C "${ZIG_SRC}" init -q
printf 'llvmorg-20.1.2\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig 0.13.0"
git -C "${ZIG_SRC}" tag -a -m "v0.13.0" v0.13.0

if BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_VERSION="0.13.0" \
	ZIG_GIT_REF="main" \
	LLVM_GIT_REF="llvmorg-20.0.0" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}" >"${OUTPUT_FILE}" 2>&1; then
	echo "expected stage 10 to fail on conflicting ZIG_VERSION and ZIG_GIT_REF"
	cat "${OUTPUT_FILE}"
	exit 1
fi

if ! grep -Fq "ZIG_VERSION and ZIG_GIT_REF conflict" "${OUTPUT_FILE}"; then
	echo "missing conflict error"
	cat "${OUTPUT_FILE}"
	exit 1
fi
