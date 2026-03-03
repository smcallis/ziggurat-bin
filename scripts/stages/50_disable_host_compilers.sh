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

if [[ -x "${bootstrap_bin}/clang" ]]; then
	[[ -e "${bootstrap_bin}/cc" ]] || ln -s clang "${bootstrap_bin}/cc"
	[[ -e "${bootstrap_bin}/gcc" ]] || ln -s clang "${bootstrap_bin}/gcc"
fi
if [[ -x "${bootstrap_bin}/clang++" ]]; then
	[[ -e "${bootstrap_bin}/c++" ]] || ln -s clang++ "${bootstrap_bin}/c++"
	[[ -e "${bootstrap_bin}/g++" ]] || ln -s clang++ "${bootstrap_bin}/g++"
fi

write_compiler_guard_script "${guard_script}" "${bootstrap_bin}"
write_bootstrap_env_file "${env_file}" "${bootstrap_bin}"

cat >"${guards_dir}/compiler-policy.txt" <<'EOF'
host-compiler-policy=bootstrap-only
EOF

if [[ -x "${bootstrap_bin}/clang" ]]; then
	PATH="${bootstrap_bin}:${PATH}" bash "${guard_script}"
else
	log_warn "bootstrap clang not found at ${bootstrap_bin}/clang; guard script generated but not enforced yet."
fi
