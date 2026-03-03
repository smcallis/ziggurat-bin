#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

archive_path=""
skip_build=0
skip_tests=0

# Run the build command without eval-style shell re-parsing.
run_release_build() {
	if [[ -z "${RELEASE_BUILD_CMD:-}" ]]; then
		bash scripts/build.sh
		return 0
	fi

	local cmd_wrapper
	cmd_wrapper="$(mktemp)"
	trap 'rm -f "${cmd_wrapper}"' RETURN
	cat >"${cmd_wrapper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${RELEASE_BUILD_CMD}
EOF
	bash "${cmd_wrapper}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--archive)
		[[ $# -ge 2 ]] || {
			echo "missing value for --archive" >&2
			exit 1
		}
		archive_path="$2"
		shift 2
		;;
	--skip-build)
		skip_build=1
		shift
		;;
	--skip-tests)
		skip_tests=1
		shift
		;;
	--help | -h)
		cat <<'EOF'
Usage: scripts/release.sh [options]

Options:
  --archive <path>   Use existing archive path.
  --skip-build       Skip build/package step.
  --skip-tests       Skip smoke tests.
EOF
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 1
		;;
	esac
done

cd "${PROJECT_ROOT}"

if [[ "${RELEASE_SKIP_GIT_CHECK:-0}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
	echo "release requires a clean git worktree (set RELEASE_SKIP_GIT_CHECK=1 to bypass)." >&2
	exit 1
fi

if ((skip_build == 0)) && [[ -z "${archive_path}" ]]; then
	run_release_build
fi

if [[ -z "${archive_path}" ]]; then
	archive_path="$(find out -maxdepth 1 -type f -name 'ziggurat-*.tar.xz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
fi
[[ -n "${archive_path}" ]] || {
	echo "could not locate release archive" >&2
	exit 1
}
[[ -f "${archive_path}" ]] || {
	echo "archive not found: ${archive_path}" >&2
	exit 1
}

if ((skip_tests == 0)); then
	smoke_root="$(mktemp -d)"
	trap 'rm -rf "${smoke_root}"' EXIT
	tar -xJf "${archive_path}" -C "${smoke_root}"
	SYSROOT="${smoke_root}" bash tests/run-smoke.sh
fi

sha256sum "${archive_path}" >"${archive_path}.sha256"
echo "release checksum written: ${archive_path}.sha256"
