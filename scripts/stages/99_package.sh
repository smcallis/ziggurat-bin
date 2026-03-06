#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"

out_dir="${OUT_DIR:-${PROJECT_ROOT}/out}"
mkdir -p "${STATE_DIR}" "${out_dir}"

source_config_with_env_overrides "${PROJECT_ROOT}/config.env" ZIG_VERSION
version="dev"
version="${ZIG_VERSION:-dev}"
if [[ "${version}" == "dev" && -f "${STATE_DIR}/zig-source-lock.json" ]]; then
	lock_version="$(read_lock_field "${STATE_DIR}/zig-source-lock.json" "version")"
	if [[ -n "${lock_version}" ]]; then
		version="${lock_version}"
	fi
fi

tar_name="ziggurat-${version}.tar"
tar_path="${out_dir}/${tar_name}"
xz_path="${tar_path}.xz"
sha_path="${xz_path}.sha256"
archive_root="ziggurat-v${version}"

tar_common_args=(
	--sort=name
	--mtime='UTC 1970-01-01'
	--owner=0
	--group=0
	--numeric-owner
	-C "${TARGET_DIR}"
)

tar_payload_paths=(
	bin
	lib
	include
	BUILD.bazel
	MANIFEST.txt
	VERSION.txt
)

if command -v pixz >/dev/null 2>&1; then
	tar "${tar_common_args[@]}" \
		--transform="flags=r;s,^,${archive_root}/," \
		-cf - "${tar_payload_paths[@]}" | pixz -9 >"${xz_path}"
else
	tar "${tar_common_args[@]}" \
		--transform="flags=r;s,^,${archive_root}/," \
		-cf "${tar_path}" "${tar_payload_paths[@]}"
	xz -f -T0 -9e "${tar_path}"
fi

(
	cd "${out_dir}"
	sha256sum "$(basename "${xz_path}")" >"$(basename "${sha_path}")"
)

echo "${xz_path}" >"${STATE_DIR}/package-path.txt"
