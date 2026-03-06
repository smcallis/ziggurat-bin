#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT_DIR}/Dockerfile"
DOCKERIGNORE="${ROOT_DIR}/.dockerignore"

[[ -f "${DOCKERFILE}" ]] || {
	echo "missing Dockerfile"
	exit 1
}

[[ -f "${DOCKERIGNORE}" ]] || {
	echo "missing .dockerignore"
	exit 1
}

required_dockerfile_patterns=(
	"FROM ubuntu:24.04"
	"apt-get install -y"
	"clang"
	"lld"
	"llvm"
	"cmake"
	"ninja-build"
	"curl"
	"jq"
	"pixz"
	"zlib1g-dev"
	"gh"
	"git"
	"COPY . /workspace"
	"chmod +x /workspace/ci-local.sh"
	"CMD [\"/workspace/ci-local.sh\"]"
)

for pattern in "${required_dockerfile_patterns[@]}"; do
	if ! grep -Fq -- "${pattern}" "${DOCKERFILE}"; then
		echo "Dockerfile missing expected pattern: ${pattern}"
		exit 1
	fi
done

for pattern in \
	".git" \
	"build" \
	"out" \
	"state"; do
	if ! grep -Fxq -- "${pattern}" "${DOCKERIGNORE}"; then
		echo ".dockerignore missing expected entry: ${pattern}"
		exit 1
	fi
done
