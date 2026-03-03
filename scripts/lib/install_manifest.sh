#!/usr/bin/env bash
set -euo pipefail

## Write a stable file manifest for a directory tree.
generate_manifest() {
	local target_dir="$1"
	local output_file="$2"

	(
		cd "${target_dir}"
		find bin lib include -type f | LC_ALL=C sort | while IFS= read -r rel_path; do
			local sha
			sha="$(sha256sum "${rel_path}" | awk '{print $1}')"
			printf '%s  %s\n' "${sha}" "${rel_path}"
		done
	) >"${output_file}"
}

## Convert newline-delimited text into a compact JSON string array.
json_array_from_lines() {
	local input="$1"
	local out="["
	local first=1
	local line

	while IFS= read -r line; do
		[[ -n "${line}" ]] || continue
		line="${line//\\/\\\\}"
		line="${line//\"/\\\"}"
		if ((first)); then
			first=0
		else
			out+=","
		fi
		out+="\"${line}\""
	done <<<"${input}"

	out+="]"
	echo "${out}"
}
