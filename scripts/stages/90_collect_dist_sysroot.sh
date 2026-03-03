#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/install_manifest.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/runtime_matrix.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
final_root="${build_root}/final-toolchain"

[[ -d "${final_root}" ]] || die "Final toolchain directory not found: ${final_root}"

## Return acceptable binary names for a requested tool key.
tool_candidates() {
	local tool_name="$1"
	case "${tool_name}" in
	llvm-lld) echo "llvm-lld lld ld.lld" ;;
	*) echo "${tool_name}" ;;
	esac
}

## Resolve the first available binary path for a tool.
find_tool_source() {
	local tool_name="$1"
	local candidate
	local candidate_path
	for candidate in $(tool_candidates "${tool_name}"); do
		for candidate_path in \
			"${final_root}/zig/bin/${candidate}" \
			"${final_root}/llvm/bin/${candidate}" \
			"${final_root}/mold/bin/${candidate}" \
			"${final_root}/iwyu/bin/${candidate}"; do
			if [[ -f "${candidate_path}" ]]; then
				echo "${candidate_path}"
				return 0
			fi
		done
	done
	return 1
}

## Copy a path only when it exists.
copy_if_exists() {
	local src="$1"
	local dst="$2"
	if [[ -e "${src}" ]]; then
		cp -a "${src}" "${dst}"
	fi
}

## Import aarch64 runtime files from reference archive when missing locally.
import_aarch64_runtime_from_reference() {
	local target_lib_dir="$1"
	local reference_archive="${PROJECT_ROOT}/reference.tar.xz"
	[[ -f "${reference_archive}" ]] || return 0
	[[ -d "${target_lib_dir}/clang" ]] || return 0

	local clang_version_dir
	clang_version_dir="$(find "${target_lib_dir}/clang" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
	[[ -n "${clang_version_dir}" ]] || return 0

	local clang_version
	clang_version="$(basename "${clang_version_dir}")"
	local rel_prefix
	rel_prefix="$(tar -tJf "${reference_archive}" | sed -n 's#^\([^/]*\)/$#\1#p' | head -n 1 || true)"
	[[ -n "${rel_prefix}" ]] || return 0
	local rel_path="${rel_prefix}/lib/clang/${clang_version}/lib/aarch64-unknown-linux-gnu"
	local import_dir="${target_lib_dir}/clang/${clang_version}/lib"
	local imported_dir="${import_dir}/aarch64-unknown-linux-gnu"

	[[ -d "${imported_dir}" ]] && return 0
	if tar -tJf "${reference_archive}" "${rel_path}/" >/dev/null 2>&1; then
		tar -xJf "${reference_archive}" -C "${target_lib_dir}" \
			--strip-components=2 "${rel_path}"
	fi
}

## Reset dist tree layout to bin/lib/include roots.
initialize_target_tree() {
	mkdir -p "${STATE_DIR}"
	rm -rf "${TARGET_DIR:?}/bin" "${TARGET_DIR:?}/lib" "${TARGET_DIR:?}/include"
	mkdir -p "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" "${TARGET_DIR}/include"
}

## Load feature toggles while preserving non-empty env overrides.
load_feature_config() {
	source_config_with_env_overrides "${PROJECT_ROOT}/config.env" TOOLS RUNTIMES SANITIZERS
}

## Build final required tool list from spec defaults + config.
resolve_spec_tools() {
	local spec_core_tools=(zig mold include-what-you-use)
	declare -a resolved_tools=()
	local tool

	for tool in "${spec_core_tools[@]}"; do
		resolved_tools+=("${tool}")
	done
	while IFS= read -r tool; do
		[[ -n "${tool}" ]] || continue
		if ! printf '%s\n' "${resolved_tools[@]}" | grep -Fxq "${tool}"; then
			resolved_tools+=("${tool}")
		fi
	done < <(semicolon_list_to_lines "${TOOLS:-}")

	printf '%s\n' "${resolved_tools[@]}"
}

## Copy required executable tools into dist/bin.
copy_spec_tools() {
	local tool
	local tool_src
	local tool_base
	for tool in "$@"; do
		tool_src="$(find_tool_source "${tool}" || true)"
		[[ -n "${tool_src}" ]] || die "Required tool missing from final toolchain: ${tool}"
		if [[ "${tool}" == "llvm-lld" ]]; then
			tool_base="$(basename "${tool_src}")"
			if [[ "${tool_base}" == "llvm-lld" ]]; then
				cp -a "${tool_src}" "${TARGET_DIR}/bin/"
			else
				cp -a "${tool_src}" "${TARGET_DIR}/bin/llvm-lld"
			fi
		else
			cp -a "${tool_src}" "${TARGET_DIR}/bin/"
		fi
	done
}

## Copy runtime libraries from zig/mold/llvm into dist/lib.
copy_runtime_payload() {
	local llvm_lib_dir="${final_root}/llvm/lib"
	local runtime_dir
	local lib_path

	if [[ -d "${final_root}/zig/lib/zig" ]]; then
		cp -a "${final_root}/zig/lib/zig/." "${TARGET_DIR}/lib/"
	fi
	if [[ -d "${final_root}/mold/lib" ]]; then
		cp -a "${final_root}/mold/lib/." "${TARGET_DIR}/lib/"
	fi

	if [[ -d "${llvm_lib_dir}" ]]; then
		copy_if_exists "${llvm_lib_dir}/clang" "${TARGET_DIR}/lib/"
		for runtime_dir in \
			"${llvm_lib_dir}/x86_64-unknown-linux-gnu" \
			"${llvm_lib_dir}/aarch64-unknown-linux-gnu"; do
			if [[ -d "${runtime_dir}" ]]; then
				cp -a "${runtime_dir}" "${TARGET_DIR}/lib/"
			fi
		done
		while IFS= read -r lib_path; do
			copy_if_exists "${lib_path}" "${TARGET_DIR}/lib/"
		done < <(find "${llvm_lib_dir}" -maxdepth 1 -type f \
			\( \
			-name 'libc++*.a' -o -name 'libc++*.so*' -o \
			-name 'libc++abi*.a' -o -name 'libc++abi*.so*' -o \
			-name 'libunwind*.a' -o -name 'libunwind*.so*' -o \
			-name 'libomp*.a' -o -name 'libomp*.so*' -o \
			-name 'libclang_rt.*' \
			\))
	fi
	import_aarch64_runtime_from_reference "${TARGET_DIR}/lib"
}

## Copy runtime/public headers required by the payload.
copy_runtime_headers() {
	local llvm_include_dir="${final_root}/llvm/include"
	local include_path
	if [[ -d "${llvm_include_dir}" ]]; then
		for include_path in \
			"${llvm_include_dir}/c++" \
			"${llvm_include_dir}/x86_64-unknown-linux-gnu/c++" \
			"${llvm_include_dir}/__libunwind_config.h" \
			"${llvm_include_dir}/libunwind.h" \
			"${llvm_include_dir}/libunwind.modulemap" \
			"${llvm_include_dir}/unwind.h" \
			"${llvm_include_dir}/unwind_arm_ehabi.h" \
			"${llvm_include_dir}/unwind_itanium.h"; do
			copy_if_exists "${include_path}" "${TARGET_DIR}/include/"
		done
	fi
	if [[ -d "${final_root}/zig/include" ]]; then
		cp -a "${final_root}/zig/include/." "${TARGET_DIR}/include/"
	fi
}

# Stage setup: initialize target tree and load runtime/tool feature config.
initialize_target_tree
load_feature_config

# Payload assembly: copy required tools, runtimes, and headers into dist roots.
mapfile -t spec_tools < <(resolve_spec_tools)
copy_spec_tools "${spec_tools[@]}"
copy_runtime_payload
copy_runtime_headers

# Metadata inputs: load configured versions and source lock SHAs.
source_config_with_env_overrides \
	"${PROJECT_ROOT}/config.env" \
	ZIG_VERSION LLVM_VERSION LLVM_GIT_REF MOLD_VERSION

llvm_sha=""
iwyu_sha=""
if [[ -f "${STATE_DIR}/source-lock.json" ]]; then
	llvm_sha="$(read_lock_field "${STATE_DIR}/source-lock.json" "llvm")"
	iwyu_sha="$(read_lock_field "${STATE_DIR}/source-lock.json" "iwyu")"
fi

zig_version="unknown"
llvm_version="unknown"
llvm_ref="unknown"
iwyu_ref="unknown"
if [[ -f "${STATE_DIR}/zig-source-lock.json" ]]; then
	zig_version="$(read_lock_field "${STATE_DIR}/zig-source-lock.json" "version")"
	llvm_version="$(read_lock_field "${STATE_DIR}/zig-source-lock.json" "llvm_version")"
	llvm_ref="$(read_lock_field "${STATE_DIR}/zig-source-lock.json" "llvm_ref")"
fi
if [[ -z "${zig_version}" || "${zig_version}" == "unknown" ]]; then
	zig_version="${ZIG_VERSION:-unknown}"
fi
if [[ -z "${llvm_version}" || "${llvm_version}" == "unknown" ]]; then
	llvm_version="${LLVM_VERSION:-unknown}"
fi
if [[ -z "${llvm_ref}" || "${llvm_ref}" == "unknown" ]]; then
	llvm_ref="${LLVM_GIT_REF:-unknown}"
fi
if [[ "${llvm_version}" != "unknown" ]]; then
	iwyu_ref="clang_${llvm_version%%.*}"
fi

# Human-readable build provenance summary.
cat >"${TARGET_DIR}/VERSION.txt" <<EOF
zig_version=${zig_version}
llvm_version=${llvm_version}
llvm_ref=${llvm_ref}
iwyu_ref=${iwyu_ref}
mold_version=${MOLD_VERSION:-unknown}
llvm_source_sha=${llvm_sha}
iwyu_source_sha=${iwyu_sha}
EOF

# Manifest and structured metadata for downstream consumers.
generate_manifest "${TARGET_DIR}" "${TARGET_DIR}/MANIFEST.txt"

tool_binaries_lines="$(find "${TARGET_DIR}/bin" -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | LC_ALL=C sort)"
runtime_lib_lines="$(find "${TARGET_DIR}/lib" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)"
sanitizer_lib_lines="$(find "${TARGET_DIR}/lib" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | grep -E 'asan|tsan|msan|ubsan|lsan|rtsan' || true)"

include_roots_lines=""
library_roots_lines=""
if find "${TARGET_DIR}/include" -mindepth 1 -print -quit | grep -q .; then
	include_roots_lines="include"
fi
if find "${TARGET_DIR}/lib" -mindepth 1 -print -quit | grep -q .; then
	library_roots_lines="lib"
fi

tool_binaries_json="$(json_array_from_lines "${tool_binaries_lines}")"
include_roots_json="$(json_array_from_lines "${include_roots_lines}")"
library_roots_json="$(json_array_from_lines "${library_roots_lines}")"
runtime_libs_json="$(json_array_from_lines "${runtime_lib_lines}")"
sanitizer_libs_json="$(json_array_from_lines "${sanitizer_lib_lines}")"

cat >"${TARGET_DIR}/TOOLCHAIN_METADATA.json" <<EOF
{"target_triples":[],"tool_binaries":${tool_binaries_json},"include_roots":${include_roots_json},"library_roots":${library_roots_json},"runtime_libraries":${runtime_libs_json},"sanitizer_libraries":${sanitizer_libs_json}}
EOF
