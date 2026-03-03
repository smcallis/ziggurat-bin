#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUILD_DIR="${TMP_DIR}/build"
STATE_DIR="${TMP_DIR}/state"
TARGET_DIR="${TMP_DIR}/dist"
ZIG_SRC="${TMP_DIR}/zig-src"
LLVM_SRC="${TMP_DIR}/llvm-src"
ZIG_RELEASE_ROOT="${TMP_DIR}/zig-release"
ZIG_RELEASE_DIR="${ZIG_RELEASE_ROOT}/zig-linux-x86_64-0.13.0"
ZIG_RELEASE_TARBALL="${TMP_DIR}/zig-linux-x86_64-0.13.0.tar.xz"
ZIG_INDEX_JSON="${TMP_DIR}/index.json"

mkdir -p "${ZIG_SRC}"
git -C "${ZIG_SRC}" init -q
printf 'zig\n' >"${ZIG_SRC}/README.md"
git -C "${ZIG_SRC}" add README.md
git -C "${ZIG_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "zig source"
git -C "${ZIG_SRC}" tag -a -m "v0.13.0" v0.13.0

mkdir -p "${LLVM_SRC}"
git -C "${LLVM_SRC}" init -q
printf 'llvm\n' >"${LLVM_SRC}/README.md"
git -C "${LLVM_SRC}" add README.md
git -C "${LLVM_SRC}" -c user.name=test -c user.email=test@example.com commit -q -m "llvm seed"
git -C "${LLVM_SRC}" tag -a -m "llvmorg-20.1.2" llvmorg-20.1.2
git -C "${LLVM_SRC}" tag -a -m "llvmorg-20.1.8" llvmorg-20.1.8
git -C "${LLVM_SRC}" tag -a -m "llvmorg-20.2.1" llvmorg-20.2.1

mkdir -p "${ZIG_RELEASE_DIR}"
cat >"${ZIG_RELEASE_DIR}/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "cc" && "$2" == "--version" ]]; then
	echo "clang version 20.1.4"
	exit 0
fi
exit 1
EOF
chmod +x "${ZIG_RELEASE_DIR}/zig"
tar -C "${ZIG_RELEASE_ROOT}" -cJf "${ZIG_RELEASE_TARBALL}" "zig-linux-x86_64-0.13.0"
cat >"${ZIG_INDEX_JSON}" <<EOF
{"0.13.0":{"x86_64-linux":{"tarball":"file://${ZIG_RELEASE_TARBALL}"}}}
EOF

BUILD_ROOT="${BUILD_DIR}" \
	ZIG_GIT_URL="${ZIG_SRC}" \
	ZIG_GIT_REF="v0.13.0" \
	ZIG_DOWNLOAD_INDEX_URL="file://${ZIG_INDEX_JSON}" \
	LLVM_GIT_URL="file://${LLVM_SRC}" \
	bash "${ROOT_DIR}/scripts/build.sh" \
	--from-stage 10_fetch_zig \
	--to-stage 10_fetch_zig \
	--state-dir "${STATE_DIR}" \
	--target-dir "${TARGET_DIR}"

if ! grep -Fq '"llvm_ref":"llvmorg-20.1.8"' "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected llvm ref to use latest patch release in derived major.minor series"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi

if ! grep -Fq '"llvm_version":"20.1.8"' "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected llvm version to match selected llvm patch ref"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi

if ! grep -Fq '"iwyu_ref":"clang_20"' "${STATE_DIR}/zig-source-lock.json"; then
	echo "expected iwyu ref derived from inferred llvm major"
	cat "${STATE_DIR}/zig-source-lock.json"
	exit 1
fi
