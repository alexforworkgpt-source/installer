#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${RUN_INSTALLER_INTEGRATION:-}" != "1" ]]; then
  echo "SKIP: set RUN_INSTALLER_INTEGRATION=1 on a disposable Ubuntu 24.04 VPS"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"
# shellcheck source=lib/doctor.sh
source "${SCRIPT_DIR}/lib/doctor.sh"

required_test_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Integration variable ${name} is required."
}

for name in \
  TEST_HOOK_DOMAIN \
  TEST_APP_DOMAIN \
  TEST_BOT_TOKEN \
  TEST_BOT_USERNAME \
  TEST_ADMIN_IDS \
  TEST_REMNAWAVE_API_URL \
  TEST_REMNAWAVE_API_KEY \
  TEST_REMNAWAVE_SECRET_KEY \
  TEST_REMNAWAVE_WEBHOOK_SECRET; do
  required_test_value "${name}"
done

ensure_root
assert_supported_os

PROJECT_ROOT="${TEST_PROJECT_ROOT:-/opt/bot-stack-integration}"
is_safe_project_root "${PROJECT_ROOT}" || die "Unsafe TEST_PROJECT_ROOT: ${PROJECT_ROOT}"
[[ "${PROJECT_ROOT}" == *integration* ]] || die "TEST_PROJECT_ROOT must contain 'integration'."
[[ ! -e "${PROJECT_ROOT}" ]] || die "TEST_PROJECT_ROOT already exists: ${PROJECT_ROOT}"
[[ ! -e /etc/caddy/conf.d/bot-stack.caddy ]] || die "Default Bot Stack Caddy snippet already exists."

cleanup_integration_stack() {
  local exit_code=$?
  set +e
  if [[ -f "${STATE_FILE:-}" ]]; then
    compose_cmd down -v --remove-orphans >/dev/null 2>&1
  fi
  if [[ -n "${TEST_BOT_TOKEN:-}" ]]; then
    curl_with_timeouts -fsS -X POST \
      "https://api.telegram.org/bot${TEST_BOT_TOKEN}/deleteWebhook" \
      --data "drop_pending_updates=false" >/dev/null 2>&1
  fi
  rm -f /etc/caddy/conf.d/bot-stack.caddy
  systemctl reload caddy >/dev/null 2>&1
  if [[ -n "${PROJECT_ROOT:-}" && -d "${PROJECT_ROOT}" ]]; then
    safe_rm_rf_under "$(dirname "${PROJECT_ROOT}")" "${PROJECT_ROOT}" >/dev/null 2>&1
  fi
  exit "${exit_code}"
}
trap cleanup_integration_stack EXIT

set_default_runtime_values
HOOK_DOMAIN="$(normalize_domain "${TEST_HOOK_DOMAIN}")"
APP_DOMAIN="$(normalize_domain "${TEST_APP_DOMAIN}")"
WEBHOOK_URL="https://${HOOK_DOMAIN}"
CABINET_URL="https://${APP_DOMAIN}"
BOT_TOKEN="${TEST_BOT_TOKEN}"
BOT_USERNAME="${TEST_BOT_USERNAME#@}"
ADMIN_IDS="${TEST_ADMIN_IDS}"
REMNAWAVE_API_URL="$(normalize_url "${TEST_REMNAWAVE_API_URL}")"
REMNAWAVE_API_KEY="${TEST_REMNAWAVE_API_KEY}"
REMNAWAVE_SECRET_KEY="${TEST_REMNAWAVE_SECRET_KEY}"
REMNAWAVE_WEBHOOK_SECRET="${TEST_REMNAWAVE_WEBHOOK_SECRET}"
WEBHOOK_SECRET_TOKEN="$(generate_hex_secret 64)"
WEB_API_DEFAULT_TOKEN="$(generate_hex_secret 64)"
CABINET_JWT_SECRET="$(generate_hex_secret 64)"
POSTGRES_PASSWORD="$(generate_hex_secret 64)"
set_runtime_paths

install_base_packages
install_docker_engine
ensure_docker_compose_plugin
ensure_directories
save_state
configure_host_firewall
enable_services
render_all_configs

[[ "$(stat -c '%a' "${BOT_ENV_FILE}")" == "600" ]] || die "bot.env permissions are not 600."
[[ "$(stat -c '%a' "${BOT_OVERRIDE_ENV_FILE}")" == "600" ]] || die "bot.override.env permissions are not 600."
[[ "$(stat -c '%a' "${CABINET_ENV_FILE}")" == "600" ]] || die "cabinet.env permissions are not 600."
[[ ! -s "${BOT_OVERRIDE_ENV_FILE}" ]] || die "Fresh-install bot.override.env must be empty."
if grep -Eq '^(HELEKET_|TELEGRAM_STARS_)' "${BOT_ENV_FILE}"; then
  die "Optional payment settings leaked into minimal bot.env."
fi

server_preflight_checks
preflight_install_checks
clone_required_repos
deploy_stack
compose_cmd config -q
doctor_stack

recovery_proof_file="${BOT_UPLOADS_DIR}/recovery-proof.txt"
printf '%s\n' "verified-before-backup" > "${recovery_proof_file}"
recovery_archive="$(run_python "${RECOVERY_HELPER}" create "${PROJECT_ROOT}" integration)"
run_python "${RECOVERY_HELPER}" validate "${recovery_archive}" "${PROJECT_ROOT}" >/dev/null
printf '%s\n' "changed-after-backup" > "${recovery_proof_file}"
recovery_result_file="$(mktemp "${STATE_DIR}/.integration-recovery-result.XXXXXX")"
run_python \
  "${RECOVERY_HELPER}" recover "${recovery_archive}" "${PROJECT_ROOT}" \
  "${RECOVERY_RUNTIME_ADAPTER}" "${recovery_result_file}"
[[ "$(run_python "${RECOVERY_HELPER}" result-field "${recovery_result_file}" outcome)" == "committed" ]] \
  || die "File Recovery integration did not commit."
[[ "$(<"${recovery_proof_file}")" == "verified-before-backup" ]] \
  || die "File Recovery did not restore the proof file."
rm -f "${recovery_result_file}"
verify_runtime_health

log_info "Minimal Bot Stack integration smoke passed."
