#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

DOWNLOAD_INDEX_URL="${DOWNLOAD_INDEX_URL:-https://ziglang.org/download/index.json}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
TMPDIR_CLEANUP=""

# Ensure all tools required by release automation are installed.
require_release_dependencies() {
  require_cmds curl python3 tar sha256sum
}

# Remove the temporary working directory created by this script.
cleanup_tmpdir() {
  local dir="${TMPDIR_CLEANUP:-}"
  if [[ -n "$dir" && -d "$dir" ]]; then
    rm -rf "$dir"
  fi
}

# Resolve the latest stable Zig release from the public download index.
latest_stable_zig() {
  python3 - "$DOWNLOAD_INDEX_URL" <<'PY'
import json
import re
import sys
import urllib.request

url = sys.argv[1]
with urllib.request.urlopen(url) as resp:
    data = json.load(resp)

versions = [k for k in data.keys() if re.fullmatch(r"\d+\.\d+\.\d+", k)]
if not versions:
    raise SystemExit("no stable zig versions found in download index")

versions.sort(key=lambda s: tuple(int(x) for x in s.split(".")))
print(versions[-1])
PY
}

# Resolve tarball URL and checksum for a Zig release/host pair.
resolve_zig_tarball_info() {
  local zig_version="$1"
  local host_key="$2"

  python3 - "$DOWNLOAD_INDEX_URL" "$zig_version" "$host_key" <<'PY'
import json
import sys
import urllib.request

url = sys.argv[1]
zig_version = sys.argv[2]
host_key = sys.argv[3]

with urllib.request.urlopen(url) as resp:
    data = json.load(resp)

entry = data.get(zig_version, {})
host = entry.get(host_key)
if not isinstance(host, dict):
    raise SystemExit(f"no {host_key} package for zig {zig_version}")

tarball = host.get("tarball")
shasum = host.get("shasum")
if not tarball or not shasum:
    raise SystemExit(f"missing tarball/shasum for zig {zig_version} {host_key}")

print(tarball)
print(shasum)
PY
}

# Download Zig release tarball and verify SHA-256.
download_and_verify_zig_archive() {
  local tarball_url="$1"
  local expected_sha="$2"
  local output_path="$3"

  curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --retry "${CURL_MAX_RETRIES:-5}" \
    --retry-all-errors \
    --retry-delay "${CURL_RETRY_DELAY_SEC:-2}" \
    --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC:-30}" \
    --max-time "${CURL_MAX_TIME_SEC:-1800}" \
    "$tarball_url" \
    -o "$output_path"

  local actual_sha=""
  actual_sha="$(sha256sum "$output_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || die "zig release checksum mismatch: expected $expected_sha got $actual_sha"
}

# Inspect the Zig release binary to determine its LLVM tag.
extract_llvm_ref_from_zig_release() {
  local zig_archive="$1"
  local tmpdir="$2"

  tar -xJf "$zig_archive" -C "$tmpdir"

  local zig_bin=""
  zig_bin="$(find "$tmpdir" -type f -name zig | head -n1 || true)"
  [[ -n "$zig_bin" && -x "$zig_bin" ]] || die "failed to locate zig binary in downloaded release tarball"

  local zig_cc_version_line=""
  zig_cc_version_line="$("$zig_bin" cc --version | head -n1)"

  local clang_version=""
  clang_version="$(printf '%s\n' "$zig_cc_version_line" | sed -nE 's/^clang version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')"
  [[ -n "$clang_version" ]] || die "unable to parse clang version from zig cc: $zig_cc_version_line"

  if [[ "$clang_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    clang_version="$clang_version.0"
  fi

  printf 'llvmorg-%s\n' "$clang_version"
}

# Detect whether release upload prerequisites are present.
in_github_ci_context() {
  [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]
}

# Issue an authenticated GitHub API request and return HTTP status code.
github_request() {
  local method="$1"
  local url="$2"
  local output_path="$3"
  shift 3

  local -a cmd=(
    curl -sS
    -o "$output_path"
    -w "%{http_code}"
    -X "$method"
    -H "Accept: application/vnd.github+json"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    "$url"
  )

  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi

  "${cmd[@]}"
}

# Return 1/0 depending on whether a release JSON payload has a named asset.
release_has_asset_from_json() {
  local release_json="$1"
  local asset_name="$2"

  python3 - "$release_json" "$asset_name" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    release = json.load(f)

asset_name = sys.argv[2]
for asset in release.get("assets", []):
    if str(asset.get("name", "")) == asset_name:
        print("1")
        raise SystemExit(0)

print("0")
PY
}

# Extract upload URL prefix from a GitHub release payload.
release_json_upload_url() {
  local release_json="$1"

  python3 - "$release_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    release = json.load(f)

upload_url = str(release.get("upload_url", ""))
if not upload_url:
    raise SystemExit("missing upload_url in release payload")

print(upload_url.split("{", 1)[0])
PY
}

# URL-encode a string for safe use in API paths/queries.
encode_url_component() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

# Fetch release metadata by tag and write response JSON to a file.
fetch_release_by_tag() {
  local tag="$1"
  local output_json="$2"
  local encoded_tag=""
  encoded_tag="$(encode_url_component "$tag")"

  github_request \
    GET \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/tags/$encoded_tag" \
    "$output_json"
}

# Ensure a GitHub release exists for the given tag (create if missing).
ensure_release_exists() {
  local tag="$1"
  local release_name="$2"
  local release_json="$3"

  local status=""
  status="$(fetch_release_by_tag "$tag" "$release_json")"

  case "$status" in
    200)
      return 0
      ;;
    404)
      ;;
    *)
      cat "$release_json" >&2 || true
      die "failed to query github release for tag $tag (HTTP $status)"
      ;;
  esac

  local target_commitish="${GITHUB_SHA:-}"
  if [[ -z "$target_commitish" ]]; then
    target_commitish="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$target_commitish" ]]; then
    target_commitish="main"
  fi

  local payload_json
  payload_json="$(mktemp)"
  cat > "$payload_json" <<JSON
{
  "tag_name": "$tag",
  "name": "$release_name",
  "target_commitish": "$target_commitish",
  "generate_release_notes": true
}
JSON

  local create_resp
  create_resp="$(mktemp)"
  status="$(github_request \
    POST \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases" \
    "$create_resp" \
    -H "Content-Type: application/json" \
    --data-binary "@$payload_json")"

  rm -f "$payload_json"

  if [[ "$status" != "201" ]]; then
    cat "$create_resp" >&2 || true
    rm -f "$create_resp"
    die "failed to create github release for tag $tag (HTTP $status)"
  fi

  rm -f "$create_resp"

  status="$(fetch_release_by_tag "$tag" "$release_json")"
  [[ "$status" == "200" ]] || die "created release tag $tag but failed to fetch it (HTTP $status)"
}

# Upload one asset if it is not already attached to the release.
upload_release_asset_if_missing() {
  local release_json="$1"
  local asset_path="$2"
  local content_type="$3"

  local asset_name
  asset_name="$(basename "$asset_path")"

  local exists=""
  exists="$(release_has_asset_from_json "$release_json" "$asset_name")"
  if [[ "$exists" == "1" ]]; then
    log "release already has asset: $asset_name"
    return 0
  fi

  local upload_url=""
  upload_url="$(release_json_upload_url "$release_json")"
  local encoded_asset_name=""
  encoded_asset_name="$(encode_url_component "$asset_name")"

  local response_json
  response_json="$(mktemp)"
  local status=""
  status="$(github_request \
    POST \
    "$upload_url?name=$encoded_asset_name" \
    "$response_json" \
    -H "Content-Type: $content_type" \
    --data-binary "@$asset_path")"

  if [[ "$status" != "201" ]]; then
    cat "$response_json" >&2 || true
    rm -f "$response_json"
    die "failed to upload asset $asset_name (HTTP $status)"
  fi

  rm -f "$response_json"
  log "uploaded release asset: $asset_name"
}

# Skip an expensive build when the release already has the archive asset.
maybe_skip_if_release_asset_exists() {
  local tag="$1"
  local archive_name="$2"

  in_github_ci_context || return 1

  local release_json
  release_json="$(mktemp)"

  local status=""
  status="$(fetch_release_by_tag "$tag" "$release_json")"

  case "$status" in
    200)
      local exists=""
      exists="$(release_has_asset_from_json "$release_json" "$archive_name")"
      rm -f "$release_json"
      if [[ "$exists" == "1" ]]; then
        log "release $tag already has $archive_name; skipping build"
        return 0
      fi
      return 1
      ;;
    404)
      rm -f "$release_json"
      return 1
      ;;
    *)
      cat "$release_json" >&2 || true
      rm -f "$release_json"
      die "failed to query github release for tag $tag (HTTP $status)"
      ;;
  esac
}

# Resolve latest Zig/LLVM pair, build payload, and optionally upload release assets.
main() {
  # Resolve release versions and short-circuit if the release already has the artifact.
  require_release_dependencies

  local latest_zig=""
  latest_zig="$(latest_stable_zig)"

  local archive_name="ziggurat-${latest_zig}.tar.xz"
  local release_tag="$latest_zig"

  if maybe_skip_if_release_asset_exists "$release_tag" "$archive_name"; then
    exit 0
  fi

  # Download official Zig release archive and infer matching LLVM tag.
  local host_key=""
  host_key="$(host_package_key)"

  local -a zig_pkg=()
  mapfile -t zig_pkg < <(resolve_zig_tarball_info "$latest_zig" "$host_key")
  [[ "${#zig_pkg[@]}" -eq 2 ]] || die "failed to resolve zig package metadata"

  local zig_tarball_url="${zig_pkg[0]}"
  local zig_tarball_sha="${zig_pkg[1]}"

  TMPDIR_CLEANUP="$(mktemp -d)"
  trap cleanup_tmpdir EXIT

  local zig_archive="$TMPDIR_CLEANUP/zig-release.tar.xz"
  download_and_verify_zig_archive "$zig_tarball_url" "$zig_tarball_sha" "$zig_archive"

  local llvm_ref=""
  llvm_ref="$(extract_llvm_ref_from_zig_release "$zig_archive" "$TMPDIR_CLEANUP")"

  log "latest zig release: $latest_zig"
  log "resolved llvm ref: $llvm_ref"

  # Build and package ziggurat payload for this Zig release.
  ZIG_REF_OVERRIDE="$latest_zig" \
  LLVM_REF_OVERRIDE="$llvm_ref" \
  EMIT_TOOLCHAIN_ARCHIVE=0 \
  RELEASE_ARCHIVE_NAME="ziggurat-$latest_zig" \
  "$SCRIPT_DIR/build-toolchain.sh"

  local archive_path="$ROOT_DIR/dist/$archive_name"
  [[ -f "$archive_path" ]] || die "expected archive missing: $archive_path"

  local sha_path="$archive_path.sha256"
  sha256sum "$archive_path" > "$sha_path"
  log "wrote checksum: $sha_path"

  # Upload archive and checksum when running in GitHub CI with credentials.
  if ! in_github_ci_context; then
    log "not in github ci context; skipping release upload"
    exit 0
  fi

  local release_json
  release_json="$(mktemp)"
  ensure_release_exists "$release_tag" "Zig $latest_zig" "$release_json"

  upload_release_asset_if_missing "$release_json" "$archive_path" "application/x-xz"

  local refreshed_release_json
  refreshed_release_json="$(mktemp)"
  local refresh_status=""
  refresh_status="$(fetch_release_by_tag "$release_tag" "$refreshed_release_json")"
  [[ "$refresh_status" == "200" ]] || die "failed to refresh release payload after upload (HTTP $refresh_status)"
  upload_release_asset_if_missing "$refreshed_release_json" "$sha_path" "text/plain"

  rm -f "$release_json" "$refreshed_release_json"
}

main "$@"
