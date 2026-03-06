#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
BOOTSTRAP_BIN="${BUILD_DIR}/bootstrap-toolchain/bin"
BIN_DIR="${TMP_DIR}/bin"
APT_LOG="${TMP_DIR}/apt.log"

mkdir -p "${BOOTSTRAP_BIN}" "${BIN_DIR}"
printf '%s\n' '#!/usr/bin/env bash' 'echo clang' >"${BOOTSTRAP_BIN}/clang"
printf '%s\n' '#!/usr/bin/env bash' 'echo clang++' >"${BOOTSTRAP_BIN}/clang++"
chmod +x "${BOOTSTRAP_BIN}/clang" "${BOOTSTRAP_BIN}/clang++"

cat >"${BIN_DIR}/apt-get" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"${APT_LOG}"
exit 1
EOF
chmod +x "${BIN_DIR}/apt-get"

cat >"${BIN_DIR}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
chmod +x "${BIN_DIR}/sudo"

BUILD_ROOT="${BUILD_DIR}" \
	PATH="${BIN_DIR}:${BOOTSTRAP_BIN}:${PATH}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 50_disable_host_compilers \
	--to-stage 50_disable_host_compilers \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

env_file="${STATE_DIR}/bootstrap-env.sh"
guard_script="${BUILD_DIR}/guards/check-no-host-compiler.sh"

if [[ ! -f "${env_file}" ]]; then
	echo "expected bootstrap env file"
	exit 1
fi

if [[ ! -x "${guard_script}" ]]; then
	echo "expected executable guard script"
	exit 1
fi

if grep -Fq 'check_tool gcc' "${guard_script}"; then
	echo "did not expect guard script to check gcc"
	exit 1
fi

if grep -Fq 'check_tool g++' "${guard_script}"; then
	echo "did not expect guard script to check g++"
	exit 1
fi

if ! grep -Fq "export CC=${BOOTSTRAP_BIN}/clang" "${env_file}"; then
	echo "expected CC export in env file"
	cat "${env_file}"
	exit 1
fi

for shim in cc gcc c++ g++; do
	if [[ -e "${BOOTSTRAP_BIN}/${shim}" ]]; then
		echo "did not expect bootstrap shim ${shim}"
		exit 1
	fi
done

if [[ ! -f "${APT_LOG}" ]]; then
	echo "expected fake apt-get log"
	exit 1
fi

if ! grep -Fq "remove gcc g++ clang" "${APT_LOG}"; then
	echo "expected host compiler uninstall attempt"
	cat "${APT_LOG}"
	exit 1
fi

# Guard script should still identify host compiler precedence when invoked.
if [[ -x /usr/bin/clang ]]; then
	if PATH="/usr/bin:${BOOTSTRAP_BIN}" bash "${guard_script}" >/dev/null 2>&1; then
		echo "guard script should fail when host compilers come first"
		exit 1
	fi
else
	if ! PATH="/usr/bin:${BOOTSTRAP_BIN}" bash "${guard_script}" >/dev/null 2>&1; then
		echo "guard script should succeed when host clang is absent"
		exit 1
	fi
fi
