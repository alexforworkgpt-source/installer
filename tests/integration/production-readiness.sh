#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=lib/doctor.sh
source "${SCRIPT_DIR}/lib/doctor.sh"

assert_supported_os() { :; }
check_bootstrap_resources() { :; }
check_ports_available_or_caddy_only() { :; }
check_required_external_connectivity() { :; }
command_exists() { return 1; }
log_info() { :; }
die() { printf '%s\n' "$*" >&2; return 1; }

# Bootstrap readiness must work before Docker, Compose, Caddy, jq and git exist.
server_preflight_checks

require_state_file() { :; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
HOOK_DOMAIN=hooks.example.test
APP_DOMAIN=app.example.test
BOT_HTTP_PORT=18080
BOT_UPLOADS_DIR="${TEMP_ROOT}/uploads"
CABINET_DIST_DIR="${TEMP_ROOT}/cabinet"
CADDY_CANDIDATE_FILE="${TEMP_ROOT}/bot-stack.caddy"
render_caddy_file

grep -Fq '@telegram path /webhook' "${CADDY_CANDIDATE_FILE}"
grep -Fq '@remnawave path /remnawave-webhook' "${CADDY_CANDIDATE_FILE}"
grep -Fq '@health path /health/unified' "${CADDY_CANDIDATE_FILE}"
grep -Fq 'respond 404' "${CADDY_CANDIDATE_FILE}"
if grep -Eq '^    reverse_proxy ' "${CADDY_CANDIDATE_FILE}"; then
  printf '%s\n' 'Webhook host still proxies the complete backend.' >&2
  exit 1
fi

mkdir -p "${TEMP_ROOT}/bin"
cat > "${TEMP_ROOT}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${PUBLIC_CURL_LOG}"
[[ "${PUBLIC_CURL_CERT_FAILURE:-false}" != true ]] || exit 60
printf '200'
EOF
chmod +x "${TEMP_ROOT}/bin/curl"
export PATH="${TEMP_ROOT}/bin:${PATH}"
export PUBLIC_CURL_LOG="${TEMP_ROOT}/public-curl.log"

[[ "$(public_https_status 'https://app.example.test/')" == 200 ]]
if grep -Eq '(^|[[:space:]])-[^[:space:]]*k' "${PUBLIC_CURL_LOG}"; then
  printf '%s\n' 'Public HTTPS probe disabled certificate verification.' >&2
  exit 1
fi
export PUBLIC_CURL_CERT_FAILURE=true
if public_https_status 'https://app.example.test/' >/dev/null; then
  printf '%s\n' 'Public HTTPS probe accepted a certificate failure.' >&2
  exit 1
fi

# Caddy activation must restore the previous snippet when the public post-check fails.
CADDY_SNIPPET_DIR="${TEMP_ROOT}/caddy"
CADDY_SNIPPET_FILE="${CADDY_SNIPPET_DIR}/bedolaga-test.caddy"
CADDY_CANDIDATE_FILE="${TEMP_ROOT}/candidate.caddy"
mkdir -p "${CADDY_SNIPPET_DIR}"
printf '%s\n' old-config > "${CADDY_SNIPPET_FILE}"
printf '%s\n' new-config > "${CADDY_CANDIDATE_FILE}"
ensure_caddy_import() { :; }
validate_caddy() { grep -Fq config "${CADDY_SNIPPET_FILE}"; }
systemctl() { [[ "${1:-}" == reload && "${CADDY_RELOAD_FAIL:-false}" != true ]]; }
verify_caddy_public_postcheck() { [[ "${CADDY_POSTCHECK_FAIL:-false}" != true ]]; }
CADDY_POSTCHECK_FAIL=true
install_caddy_candidate
if reload_caddy; then
  printf '%s\n' 'Caddy activation accepted a failed public post-check.' >&2
  exit 1
fi
[[ "$(<"${CADDY_SNIPPET_FILE}")" == old-config ]]
[[ ! -e "${CADDY_SNIPPET_FILE}.rollback" ]]
[[ ! -e "${CADDY_SNIPPET_FILE}.rollback-absent" ]]

printf '%s\n' 'Production readiness integration harness passed.'
