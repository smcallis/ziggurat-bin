#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
ZIG_SMOKE_SRC="${STATE_DIR}/zig-smoke.zig"

mkdir -p "${TARGET_DIR}/bin" "${TARGET_DIR}/lib/std/crypto/pcurves/tests"

cat >"${TARGET_DIR}/bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${STATE_DIR:?missing STATE_DIR}/zig-invocations.log"
printf '%s\n' "$*" >>"${log_file}"

if [[ "$1" == "build-exe" ]]; then
	[[ -f "${ZIG_LIB_DIR}/std/crypto/pcurves/tests/p256.zig" ]] || {
		echo "missing required zig std source" >&2
		exit 1
	}
	emit_bin=""
	for arg in "$@"; do
		case "${arg}" in
		-femit-bin=*)
			emit_bin="${arg#-femit-bin=}"
			;;
		esac
	done
	[[ -n "${emit_bin}" ]] || {
		echo "missing emit bin path" >&2
		exit 1
	}
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${emit_bin}"
	chmod +x "${emit_bin}"
	exit 0
fi

if [[ "$1" == "c++" ]]; then
	out=""
	prev=""
	for arg in "$@"; do
		if [[ "${prev}" == "-o" ]]; then
			out="${arg}"
			break
		fi
		prev="${arg}"
	done
	[[ -n "${out}" ]] || {
		echo "missing output path" >&2
		exit 1
	}
	printf 'fake-binary\n' >"${out}"
	exit 0
fi

echo "unexpected zig invocation: $*" >&2
exit 1
EOF
chmod +x "${TARGET_DIR}/bin/zig"

printf 'test source\n' >"${TARGET_DIR}/lib/std/crypto/pcurves/tests/p256.zig"

env \
	STATE_DIR="${STATE_DIR}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 98_validate_payload \
	--to-stage 98_validate_payload \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if [[ ! -f "${ZIG_SMOKE_SRC}" ]]; then
	echo "expected standalone zig smoke source"
	exit 1
fi

if ! grep -Fq "${ZIG_SMOKE_SRC}" "${STATE_DIR}/zig-invocations.log"; then
	echo "expected wrapper compile validation to use standalone zig smoke source"
	cat "${STATE_DIR}/zig-invocations.log"
	exit 1
fi

if grep -Fq "toolchain/lib/zig-wrapper.zig" "${STATE_DIR}/zig-invocations.log"; then
	echo "stage should not depend on toolchain repo files"
	cat "${STATE_DIR}/zig-invocations.log"
	exit 1
fi

if ! grep -Fq "build-exe" "${STATE_DIR}/zig-invocations.log"; then
	echo "expected wrapper compile validation to invoke zig build-exe"
	cat "${STATE_DIR}/zig-invocations.log"
	exit 1
fi

if ! grep -Fq "c++" "${STATE_DIR}/zig-invocations.log"; then
	echo "expected C++ compile validation to invoke zig c++"
	cat "${STATE_DIR}/zig-invocations.log"
	exit 1
fi
