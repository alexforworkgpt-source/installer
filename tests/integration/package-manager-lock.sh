#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
FAKE_BIN="${TEMP_ROOT}/bin"
export PACKAGE_LOCK_ATTEMPTS="${TEMP_ROOT}/attempts"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}"
printf '%s\n' '0' > "${PACKAGE_LOCK_ATTEMPTS}"
cat > "${FAKE_BIN}/fuser" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == "/var/lib/dpkg/lock-frontend" ]] || exit 1
attempts="$(<"${PACKAGE_LOCK_ATTEMPTS}")"
attempts=$((attempts + 1))
printf '%s\n' "${attempts}" > "${PACKAGE_LOCK_ATTEMPTS}"
((attempts < 3))
EOF
cat > "${FAKE_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:${PATH}"
export PACKAGE_MANAGER_POLL_SECONDS=0

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"

wait_for_package_manager 30
[[ "$(<"${PACKAGE_LOCK_ATTEMPTS}")" == "3" ]]
printf '%s\n' 'Package manager lock harness passed.'
