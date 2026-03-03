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

printf 'llvmorg-20.1.2\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "release commit"
release_ref="$(git -C "${ZIG_SRC}" rev-parse HEAD)"
git -C "${ZIG_SRC}" tag -a -m "v0.13.0" v0.13.0

printf 'llvmorg-99.9.9\n' >"${ZIG_SRC}/build.zig.zon"
git -C "${ZIG_SRC}" add build.zig.zon
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "branch commit"
branch_ref="$(git -C "${ZIG_SRC}" rev-parse HEAD)"
git -C "${ZIG_SRC}" branch -f 0.13.0 "${branch_ref}"

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_VERSION="0.13.0" \
	LLVM_GIT_REF="llvmorg-20.0.0" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if ! grep -Fq "\"zig\":\"${release_ref}\"" "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected ZIG_VERSION to resolve release tag commit, not same-named branch"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi

if grep -Fq "\"zig\":\"${branch_ref}\"" "${STATE_DIR}/zig-source-lock.json"; then
	echo "unexpected branch commit selected for ZIG_VERSION release lookup"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi
