#!/usr/bin/env bash
set -euo pipefail

## Write a wrapper that blocks accidental host compiler use.
write_compiler_guard_script() {
	local output_path="$1"
	local bootstrap_bin="$2"

	mkdir -p "$(dirname "${output_path}")"
	cat >"${output_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

bootstrap_bin="${bootstrap_bin}"

## Validate a command exists in PATH.
check_tool() {
  local tool="\$1"
  local resolved
  resolved="\$(command -v "\${tool}" || true)"
  if [[ -n "\${resolved}" && "\${resolved}" == /usr/bin/* ]]; then
    echo "host compiler is first in PATH for \${tool}: \${resolved}" >&2
    exit 1
  fi
}

check_tool clang
check_tool clang++

clang_resolved="\$(command -v clang || true)"
if [[ -n "\${clang_resolved}" && "\${clang_resolved}" != "\${bootstrap_bin}/clang" ]]; then
  echo "clang does not resolve to bootstrap toolchain: \${clang_resolved}" >&2
  exit 1
fi
EOF
	chmod +x "${output_path}"
}

## Write env exports for bootstrap toolchain binaries.
write_bootstrap_env_file() {
	local output_path="$1"
	local bootstrap_bin="$2"

	mkdir -p "$(dirname "${output_path}")"
	cat >"${output_path}" <<EOF
#!/usr/bin/env bash
export PATH=${bootstrap_bin}:\${PATH}
export CC=${bootstrap_bin}/clang
export CXX=${bootstrap_bin}/clang++
export AR=${bootstrap_bin}/llvm-ar
export RANLIB=${bootstrap_bin}/llvm-ranlib
export LD=${bootstrap_bin}/ld.lld
EOF
	chmod +x "${output_path}"
}
