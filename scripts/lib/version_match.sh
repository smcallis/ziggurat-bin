#!/usr/bin/env bash
set -euo pipefail

# Extract LLVM major version from a semantic version string.
llvm_major_from_version() {
	local llvm_version="$1"
	local major="${llvm_version%%.*}"
	echo "${major}"
}

# Fail if callers try to override IWYU ref directly.
assert_iwyu_ref_not_configurable() {
	local iwyu_ref="$1"
	if [[ -n "${iwyu_ref}" ]]; then
		die "IWYU_GIT_REF is not configurable; it is derived from LLVM_VERSION"
	fi
}

# Fail when IWYU ref is incompatible with the LLVM major version.
assert_iwyu_llvm_compat() {
	local llvm_version="$1"
	local iwyu_ref="$2"
	local llvm_major
	llvm_major="$(llvm_major_from_version "${llvm_version}")"

	if [[ "${iwyu_ref}" == "master" ]]; then
		return 0
	fi

	local expected_ref="clang_${llvm_major}"
	if [[ "${iwyu_ref}" != "${expected_ref}" ]]; then
		die "IWYU ref ${iwyu_ref} is incompatible with LLVM major ${llvm_major} (expected ${expected_ref} or master)"
	fi
}
