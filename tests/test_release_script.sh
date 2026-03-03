#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/ziggurat-test.tar.xz"
printf 'fake-archive\n' >"${ARCHIVE_PATH}"

RELEASE_SKIP_GIT_CHECK=1 \
	bash "${ROOT_DIR}/scripts/release.sh" \
	--archive "${ARCHIVE_PATH}" \
	--skip-build \
	--skip-tests

checksum_path="${ARCHIVE_PATH}.sha256"
if [[ ! -f "${checksum_path}" ]]; then
	echo "expected checksum file at ${checksum_path}"
	exit 1
fi

if ! grep -Fq "ziggurat-test.tar.xz" "${checksum_path}"; then
	echo "checksum file missing archive filename"
	cat "${checksum_path}"
	exit 1
fi
