#!/usr/bin/env bash
set -euo pipefail

# Return success when a ref looks like a commit SHA.
is_commit_ref() {
	local ref="$1"
	[[ "${ref}" =~ ^[0-9a-fA-F]{7,40}$ ]]
}

# Return success if a tag exists in a remote repository.
remote_tag_exists() {
	local repo_url="$1"
	local tag_name="$2"
	git ls-remote --tags --exit-code "${repo_url}" "refs/tags/${tag_name}" >/dev/null 2>&1
}

# Clone a repo (if needed) and force checkout to the requested ref.
checkout_git_ref() {
	local repo_url="$1"
	local repo_dir="$2"
	local git_ref="$3"
	local shallow_ok=1
	is_commit_ref "${git_ref}" && shallow_ok=0

	if [[ -d "${repo_dir}" && ! -d "${repo_dir}/.git" ]]; then
		rm -rf "${repo_dir:?}"
	fi

	if [[ ! -d "${repo_dir}/.git" ]]; then
		mkdir -p "$(dirname "${repo_dir}")"
		if [[ "${shallow_ok}" -eq 1 ]]; then
			if ! git clone -q --depth 1 --branch "${git_ref}" "${repo_url}" "${repo_dir}"; then
				git clone -q "${repo_url}" "${repo_dir}"
			fi
		else
			git clone -q "${repo_url}" "${repo_dir}"
		fi
	else
		git -C "${repo_dir}" remote set-url origin "${repo_url}"
	fi

	if [[ "${shallow_ok}" -eq 1 ]]; then
		if ! git -C "${repo_dir}" fetch -q --depth 1 --prune origin "${git_ref}"; then
			git -C "${repo_dir}" fetch -q --tags --prune origin
		fi
	else
		git -C "${repo_dir}" fetch -q --tags --prune origin
	fi
	git -C "${repo_dir}" checkout -q --force "${git_ref}"
	git -C "${repo_dir}" reset -q --hard "${git_ref}"
}

# Print the currently checked-out commit SHA for a repo.
resolve_head_sha() {
	local repo_dir="$1"
	git -C "${repo_dir}" rev-parse HEAD
}
