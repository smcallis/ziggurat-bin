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

printf 'llvmorg-17.0.6\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig 0.12.0"
git -C "${ZIG_SRC}" tag -a -m "v0.12.0" v0.12.0

printf 'llvmorg-18.1.8\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig 0.13.0"
git -C "${ZIG_SRC}" tag -a -m "0.13.0" 0.13.0

printf 'llvmorg-19.1.7\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig prerelease"
git -C "${ZIG_SRC}" tag -a -m "v0.14.0-rc1" v0.14.0-rc1

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	LLVM_GIT_REF="llvmorg-20.0.0" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if ! grep -Fq '"ref":"0.13.0"' "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected latest stable tag 0.13.0 to be selected"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi

if ! grep -Fq '"version":"0.13.0"' "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected zig version to derive from latest selected tag"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi
