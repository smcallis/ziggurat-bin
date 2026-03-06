#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_FILE="${ROOT_DIR}/.github/workflows/build-toolchain.yml"

[[ -f "${WORKFLOW_FILE}" ]] || {
	echo "missing workflow file: ${WORKFLOW_FILE}"
	exit 1
}

required_patterns=(
	"schedule:"
	"cron: \"0 6 * * *\""
	"concurrency:"
	"group: build-ziggurat-release-\${{ github.ref }}"
	"cancel-in-progress: false"
	"permissions:"
	"contents: write"
	"Install Build Dependencies"
	"sudo apt-get install -y"
	"clang"
	"lld"
	"llvm"
	"cmake"
	"ninja-build"
	"jq"
	"pixz"
	"Resolve Release Metadata"
	"release_tag=v"
	"asset_name=ziggurat-"
	"asset_sha_name=ziggurat-"
	"Check Existing Release Artifact"
	"skip_build=true"
	"skip_build=false"
	"if: steps.release_check.outputs.skip_build != 'true'"
	"Build and Package Archive"
	"--to-stage 99_package"
	"out/\${{ steps.release_meta.outputs.asset_name }}"
	"Ensure Release Exists"
	"gh release create"
	"Upload Release Asset"
	"gh release upload"
	"out/\${{ steps.release_meta.outputs.asset_sha_name }}"
	"if-no-files-found: error"
)

for pattern in "${required_patterns[@]}"; do
	if ! grep -Fq -- "${pattern}" "${WORKFLOW_FILE}"; then
		echo "workflow missing expected pattern: ${pattern}"
		exit 1
	fi
done

for forbidden_pattern in \
	"Validate Dist Metadata Schema" \
	"dist/TOOLCHAIN_METADATA.json"; do
	if grep -Fq -- "${forbidden_pattern}" "${WORKFLOW_FILE}"; then
		echo "workflow should not reference removed metadata: ${forbidden_pattern}"
		exit 1
	fi
done
