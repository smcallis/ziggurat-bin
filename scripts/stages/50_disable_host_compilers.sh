#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
STATE_DIR="${2:?missing state dir}"
PROJECT_ROOT="${PROJECT_ROOT:?missing PROJECT_ROOT}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/lib/env_guard.sh"

build_root="$(build_root_dir "${PROJECT_ROOT}")"
bootstrap_bin="${build_root}/bootstrap-toolchain/bin"
guards_dir="${build_root}/guards"
guard_script="${guards_dir}/check-no-host-compiler.sh"
env_file="${STATE_DIR}/bootstrap-env.sh"

mkdir -p "${TARGET_DIR}" "${STATE_DIR}" "${guards_dir}" "${bootstrap_bin}"

## Best-effort apt-based host compiler uninstall.
attempt_uninstall_host_compilers() {
	if ! command -v apt-get >/dev/null 2>&1; then
		log_warn "apt-get not available; skipping host compiler uninstall."
		return 1
	fi

	local -a prefix=()
	if [[ "${EUID}" -ne 0 ]]; then
		if command -v sudo >/dev/null 2>&1; then
			prefix=(sudo)
		else
			log_warn "host compiler uninstall skipped (requires root or sudo)."
			return 1
		fi
	fi

	if ! "${prefix[@]}" apt-get -y remove gcc g++ clang >/dev/null 2>&1; then
		log_warn "apt uninstall step failed; continuing with bootstrap env guard only."
		return 1
	fi
	"${prefix[@]}" apt-get -y autoremove >/dev/null 2>&1 || true
	return 0
}

uninstall_succeeded=false
if attempt_uninstall_host_compilers; then
	uninstall_succeeded=true
fi

# Ensure no compiler redirection shims are left in bootstrap bin.
rm -f "${bootstrap_bin}/cc" "${bootstrap_bin}/gcc" "${bootstrap_bin}/c++" "${bootstrap_bin}/g++"

write_compiler_guard_script "${guard_script}" "${bootstrap_bin}"
write_bootstrap_env_file "${env_file}" "${bootstrap_bin}"

cat >"${guards_dir}/compiler-policy.txt" <<'POLICY'
host-compiler-policy=bootstrap-only
POLICY

if [[ "${uninstall_succeeded}" == "true" && -x "${bootstrap_bin}/clang" ]]; then
	PATH="${bootstrap_bin}:${PATH}" bash "${guard_script}"
else
	log_warn "host compiler uninstall not enforced; generated guard/env files without strict PATH validation."
fi
