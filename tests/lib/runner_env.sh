#!/usr/bin/env bash
set -euo pipefail

## Create PATH shims that block package manager mutations during tests.
setup_test_runner_env() {
	local shims_dir="$1"

	mkdir -p "${shims_dir}"

	cat >"${shims_dir}/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "apt-get is blocked during tests" >&2
exit 99
EOF
	chmod +x "${shims_dir}/apt-get"

	cat >"${shims_dir}/apt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "apt is blocked during tests" >&2
exit 99
EOF
	chmod +x "${shims_dir}/apt"

	cat >"${shims_dir}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
	chmod +x "${shims_dir}/sudo"

	export PATH="${shims_dir}:${PATH}"
}
