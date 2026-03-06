#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="${ROOT_DIR}/ci-local.sh"

[[ -f "${SCRIPT_FILE}" ]] || {
	echo "missing local CI script: ${SCRIPT_FILE}"
	exit 1
}

required_patterns=(
	"resolve_release_metadata()"
	"check_existing_release_artifact()"
	"verify_archive_exists()"
	"ensure_release_exists()"
	"upload_release_assets()"
	"ENABLE_GITHUB_RELEASES"
	"bash tests/run.sh"
	"bash scripts/build.sh --from-stage 00_prepare_dirs --to-stage 99_package"
	"Archive: out/\${RELEASE_ASSET_NAME}"
	"Checksum: out/\${RELEASE_ASSET_SHA_NAME}"
)

for pattern in "${required_patterns[@]}"; do
	if ! grep -Fq -- "${pattern}" "${SCRIPT_FILE}"; then
		echo "ci-local.sh missing expected pattern: ${pattern}"
		exit 1
	fi
done
