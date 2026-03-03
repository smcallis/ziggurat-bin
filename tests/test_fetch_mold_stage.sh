#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
MOLD_SRC="${TMP_DIR}/mold-src"

mkdir -p "${MOLD_SRC}"

git -C "${MOLD_SRC}" init -q
printf '%s\n' "cmake_minimum_required(VERSION 3.16)" >"${MOLD_SRC}/CMakeLists.txt"
git -C "${MOLD_SRC}" add CMakeLists.txt
git -C "${MOLD_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "init mold"
git -C "${MOLD_SRC}" tag -a -m "v2.40.1" v2.40.1
mold_ref="$(git -C "${MOLD_SRC}" rev-parse 'v2.40.1^{commit}')"

BUILD_ROOT="${BUILD_DIR}" \
	MOLD_GIT_URL="${MOLD_SRC}" \
	MOLD_VERSION="2.40.1" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 65_fetch_mold \
	--to-stage 65_fetch_mold \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

fetched_head="$(git -C "${BUILD_DIR}/src/mold" rev-parse HEAD)"
if [[ "${fetched_head}" != "${mold_ref}" ]]; then
	echo "mold checkout mismatch"
	exit 1
fi

lock_file="${STATE_DIR}/mold-source-lock.json"
if [[ ! -f "${lock_file}" ]]; then
	echo "expected mold lock file"
	exit 1
fi

if ! grep -Fq "\"mold\":\"${mold_ref}\"" "${lock_file}"; then
	echo "mold lock missing mold ref"
	cat "${lock_file}"
	exit 1
fi
