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
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"

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
grep -Fq '@cabinet_assets path /assets/*' "${CADDY_CANDIDATE_FILE}"
grep -Fq 'Cache-Control "public, max-age=31536000, immutable"' "${CADDY_CANDIDATE_FILE}"
grep -Fq 'header Cache-Control "no-store, no-cache, must-revalidate, max-age=0"' "${CADDY_CANDIDATE_FILE}"
if grep -Fq '@static path' "${CADDY_CANDIDATE_FILE}"; then
  printf '%s\n' 'Cabinet static matcher can cache an HTML fallback as immutable.' >&2
  exit 1
fi
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
if [[ "${PUBLIC_CURL_TRANSIENT_FAILURE:-false}" == true ]]; then
  attempts_file="${PUBLIC_CURL_LOG}.attempts"
  attempts="$(( $(cat "${attempts_file}" 2>/dev/null || printf '0') + 1 ))"
  printf '%s\n' "${attempts}" > "${attempts_file}"
  [[ "${attempts}" != "1" ]] || exit 28
fi
printf '200'
EOF
chmod +x "${TEMP_ROOT}/bin/curl"
export PATH="${TEMP_ROOT}/bin:${PATH}"
export PUBLIC_CURL_LOG="${TEMP_ROOT}/public-curl.log"
export CURL_RETRY_DELAY=0

[[ "$(public_https_status 'https://app.example.test/')" == 200 ]]
if grep -Eq '(^|[[:space:]])-[^[:space:]]*k' "${PUBLIC_CURL_LOG}"; then
  printf '%s\n' 'Public HTTPS probe disabled certificate verification.' >&2
  exit 1
fi
export PUBLIC_CURL_TRANSIENT_FAILURE=true
[[ "$(public_https_status 'https://app.example.test/')" == 200 ]]
[[ "$(<"${PUBLIC_CURL_LOG}.attempts")" == 2 ]]
unset PUBLIC_CURL_TRANSIENT_FAILURE
export PUBLIC_CURL_CERT_FAILURE=true
if public_https_status 'https://app.example.test/' >/dev/null; then
  printf '%s\n' 'Public HTTPS probe accepted a certificate failure.' >&2
  exit 1
fi
unset PUBLIC_CURL_CERT_FAILURE

# Runtime verification retries only short external transport failures after a
# Caddy reload. Security failures remain fail-fast.
HEALTH_ATTEMPTS_FILE="${TEMP_ROOT}/health-attempts"
HEALTH_SLEEP_LOG="${TEMP_ROOT}/health-sleeps"
printf '%s\n' 0 > "${HEALTH_ATTEMPTS_FILE}"
: > "${HEALTH_SLEEP_LOG}"
sleep() { printf '%s\n' "$1" >> "${HEALTH_SLEEP_LOG}"; }
http_status_code() {
  case "$1" in
    http://127.0.0.1:18080/cabinet/branding) printf '%s' 200 ;;
    https://app.example.test/api/cabinet/branding)
      attempts="$(( $(<"${HEALTH_ATTEMPTS_FILE}") + 1 ))"
      printf '%s\n' "${attempts}" > "${HEALTH_ATTEMPTS_FILE}"
      if ((attempts < 3)); then
        printf '%s' 000
      else
        printf '%s' 200
      fi
      ;;
    https://app.example.test/) printf '%s' 200 ;;
    https://hooks.example.test/) printf '%s' 404 ;;
    *) return 1 ;;
  esac
}
verify_private_runtime_ports() { :; }
BOT_RUN_MODE=polling
RUNTIME_HEALTH_RETRY_DELAY=3
verify_runtime_health
[[ "$(<"${HEALTH_ATTEMPTS_FILE}")" == 3 ]]
[[ "$(paste -sd, "${HEALTH_SLEEP_LOG}")" == 3,3 ]]

printf '%s\n' 0 > "${HEALTH_ATTEMPTS_FILE}"
: > "${HEALTH_SLEEP_LOG}"
http_status_code() {
  case "$1" in
    http://127.0.0.1:18080/cabinet/branding) printf '%s' 200 ;;
    https://app.example.test/api/cabinet/branding)
      attempts="$(( $(<"${HEALTH_ATTEMPTS_FILE}") + 1 ))"
      printf '%s\n' "${attempts}" > "${HEALTH_ATTEMPTS_FILE}"
      printf '%s' 000
      ;;
    https://app.example.test/) printf '%s' 200 ;;
    https://hooks.example.test/) printf '%s' 404 ;;
    *) return 1 ;;
  esac
}
if verify_runtime_health; then
  printf '%s\n' 'Runtime health accepted a persistent external API failure.' >&2
  exit 1
fi
[[ "$(<"${HEALTH_ATTEMPTS_FILE}")" == 3 ]]
[[ "$(paste -sd, "${HEALTH_SLEEP_LOG}")" == 3,3 ]]

: > "${HEALTH_SLEEP_LOG}"
HARD_CHECK_ATTEMPTS_FILE="${TEMP_ROOT}/hard-check-attempts"
printf '%s\n' 0 > "${HARD_CHECK_ATTEMPTS_FILE}"
http_status_code() {
  case "$1" in
    http://127.0.0.1:18080/cabinet/branding) printf '%s' 200 ;;
    https://app.example.test/api/cabinet/branding)
      attempts="$(( $(<"${HARD_CHECK_ATTEMPTS_FILE}") + 1 ))"
      printf '%s\n' "${attempts}" > "${HARD_CHECK_ATTEMPTS_FILE}"
      printf '%s' 200
      ;;
    https://app.example.test/) printf '%s' 200 ;;
    https://hooks.example.test/) printf '%s' 200 ;;
    *) return 1 ;;
  esac
}
if verify_runtime_health; then
  printf '%s\n' 'Runtime health retried an unsafe Hook response.' >&2
  exit 1
fi
[[ ! -s "${HEALTH_SLEEP_LOG}" ]]
[[ "$(<"${HARD_CHECK_ATTEMPTS_FILE}")" == 1 ]]

PORT_CHECK_ATTEMPTS_FILE="${TEMP_ROOT}/port-check-attempts"
printf '%s\n' 0 > "${PORT_CHECK_ATTEMPTS_FILE}"
http_status_code() {
  case "$1" in
    http://127.0.0.1:18080/cabinet/branding) printf '%s' 200 ;;
    https://app.example.test/api/cabinet/branding) printf '%s' 200 ;;
    https://app.example.test/) printf '%s' 200 ;;
    https://hooks.example.test/) printf '%s' 404 ;;
    *) return 1 ;;
  esac
}
verify_private_runtime_ports() {
  attempts="$(( $(<"${PORT_CHECK_ATTEMPTS_FILE}") + 1 ))"
  printf '%s\n' "${attempts}" > "${PORT_CHECK_ATTEMPTS_FILE}"
  return 1
}
if verify_runtime_health; then
  printf '%s\n' 'Runtime health retried unsafe runtime port bindings.' >&2
  exit 1
fi
[[ ! -s "${HEALTH_SLEEP_LOG}" ]]
[[ "$(<"${PORT_CHECK_ATTEMPTS_FILE}")" == 1 ]]

WEBHOOK_CHECK_ATTEMPTS_FILE="${TEMP_ROOT}/webhook-check-attempts"
printf '%s\n' 0 > "${WEBHOOK_CHECK_ATTEMPTS_FILE}"
verify_private_runtime_ports() { :; }
check_telegram_webhook_matches() {
  attempts="$(( $(<"${WEBHOOK_CHECK_ATTEMPTS_FILE}") + 1 ))"
  printf '%s\n' "${attempts}" > "${WEBHOOK_CHECK_ATTEMPTS_FILE}"
  return 1
}
BOT_RUN_MODE=webhook
if verify_runtime_health; then
  printf '%s\n' 'Runtime health retried a mismatched Telegram webhook.' >&2
  exit 1
fi
[[ ! -s "${HEALTH_SLEEP_LOG}" ]]
[[ "$(<"${WEBHOOK_CHECK_ATTEMPTS_FILE}")" == 1 ]]

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
