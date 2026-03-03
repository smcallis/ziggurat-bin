#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SYSROOT="${TMP_DIR}/sysroot"
mkdir -p "${SYSROOT}/bin" "${SYSROOT}/lib" "${SYSROOT}/include"

cat >"${SYSROOT}/bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "version" ]]; then
  echo "0.99.0-test"
  exit 0
fi
if [[ "$1" == "c++" ]]; then
  out=""
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
      out="$2"
      shift 2
      continue
    fi
    shift
  done
  printf '%s\n' '#!/usr/bin/env bash' 'echo smoke-ok' >"${out}"
  chmod +x "${out}"
  exit 0
fi
exit 1
EOF
chmod +x "${SYSROOT}/bin/zig"

for tool in include-what-you-use mold clangd llvm-ar; do
	printf '%s\n' '#!/usr/bin/env bash' "echo ${tool}" >"${SYSROOT}/bin/${tool}"
	chmod +x "${SYSROOT}/bin/${tool}"
done

for san in asan tsan msan ubsan lsan rtsan; do
	printf 'fake-%s\n' "${san}" >"${SYSROOT}/lib/libclang_rt.${san}-x86_64.a"
done

SYSROOT="${SYSROOT}" \
	TOOLS="zig;include-what-you-use;mold;clangd;llvm-ar" \
	SANITIZERS="asan;tsan;msan;ubsan;lsan;rtsan" \
	bash "${ROOT_DIR}/tests/run-smoke.sh"
