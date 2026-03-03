#!/usr/bin/env bash
set -euo pipefail

## Split a semicolon-delimited list into non-empty lines.
semicolon_list_to_lines() {
	local input="$1"
	tr ';' '\n' <<<"${input}" | sed '/^[[:space:]]*$/d'
}

## Return required tool names from TOOLS config.
required_tools_lines() {
	local tools_value="$1"
	semicolon_list_to_lines "${tools_value}"
}

## Return required sanitizer names from SANITIZERS config.
required_sanitizers_lines() {
	local sanitizers_value="$1"
	semicolon_list_to_lines "${sanitizers_value}"
}
