#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"

LLVM_SRC="${TMP_DIR}/llvm-src"
IWYU_SRC="${TMP_DIR}/iwyu-src"

mkdir -p "${LLVM_SRC}" "${IWYU_SRC}"

git -C "${LLVM_SRC}" init -q
printf 'llvm\n' >"${LLVM_SRC}/README.md"
git -C "${LLVM_SRC}" add README.md
git -C "${LLVM_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init llvm"
llvm_ref="$(git -C "${LLVM_SRC}" rev-parse HEAD)"

git -C "${IWYU_SRC}" init -q
printf 'iwyu\n' >"${IWYU_SRC}/README.md"
git -C "${IWYU_SRC}" add README.md
git -C "${IWYU_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init iwyu"
iwyu_sha="$(git -C "${IWYU_SRC}" rev-parse HEAD)"
git -C "${IWYU_SRC}" branch -f clang_20 HEAD
default_branch="$(git -C "${IWYU_SRC}" symbolic-ref --short HEAD)"
printf 'head\n' >"${IWYU_SRC}/HEAD_BRANCH.md"
git -C "${IWYU_SRC}" add HEAD_BRANCH.md
git -C "${IWYU_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "advance ${default_branch}"

BUILD_ROOT="${BUILD_DIR}" \
	LLVM_GIT_URL="${LLVM_SRC}" \
	LLVM_GIT_REF="${llvm_ref}" \
	LLVM_VERSION="20.0.0" \
	IWYU_GIT_URL="${IWYU_SRC}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 20_fetch_llvm_iwyu \
	--to-stage 20_fetch_llvm_iwyu \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

llvm_head="$(git -C "${BUILD_DIR}/src/llvm-project" rev-parse HEAD)"
iwyu_head="$(git -C "${BUILD_DIR}/src/include-what-you-use" rev-parse HEAD)"

if [[ "${llvm_head}" != "${llvm_ref}" ]]; then
	echo "llvm checkout mismatch"
	exit 1
fi

if [[ "${iwyu_head}" != "${iwyu_sha}" ]]; then
	echo "iwyu checkout mismatch"
	exit 1
fi

lock_file="${STATE_DIR}/source-lock.json"
if [[ ! -f "${lock_file}" ]]; then
	echo "expected source lock file"
	exit 1
fi

if ! grep -Fq "\"llvm\":\"${llvm_ref}\"" "${lock_file}"; then
	echo "source lock missing llvm ref"
	cat "${lock_file}"
	exit 1
fi

if ! grep -Fq "\"iwyu\":\"${iwyu_sha}\"" "${lock_file}"; then
	echo "source lock missing iwyu ref"
	cat "${lock_file}"
	exit 1
fi
