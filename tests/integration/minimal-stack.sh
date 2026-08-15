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
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"
# shellcheck source=lib/config_editor.sh
source "${SCRIPT_DIR}/lib/config_editor.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"

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
set_runtime_paths
[[ ! -e "${PROJECT_ROOT}" ]] || die "TEST_PROJECT_ROOT already exists: ${PROJECT_ROOT}"
[[ ! -e "${CADDY_SNIPPET_FILE}" ]] || die "Bot Stack Caddy snippet already exists: ${CADDY_SNIPPET_FILE}"

cleanup_integration_stack() {
  local exit_code=$?
  set +e
  if [[ "${exit_code}" -ne 0 && -f "${STATE_FILE:-}" ]]; then
    printf '%s\n' 'Safe failure diagnostics:' >&2
    compose_cmd ps -a >&2 || true
    bot_container_id="$(compose_cmd ps -aq bot 2>/dev/null | head -n 1)"
    if [[ -n "${bot_container_id}" ]]; then
      docker container inspect "${bot_container_id}" \
        --format 'bot status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' >&2 || true
    fi
    printf 'local=%s app=%s hook-default=%s\n' \
      "$(http_status_code "http://127.0.0.1:${BOT_HTTP_PORT}/cabinet/branding")" \
      "$(http_status_code "https://${APP_DOMAIN}/")" \
      "$(http_status_code "https://${HOOK_DOMAIN}/")" >&2
  fi
  if [[ -f "${STATE_FILE:-}" ]]; then
    compose_cmd down -v --remove-orphans >/dev/null 2>&1
  fi
  if [[ -n "${TEST_BOT_TOKEN:-}" ]]; then
    curl_with_timeouts -fsS -X POST \
      "https://api.telegram.org/bot${TEST_BOT_TOKEN}/deleteWebhook" \
      --data "drop_pending_updates=false" >/dev/null 2>&1
  fi
  rm -f "${CADDY_SNIPPET_FILE:-}"
  systemctl reload caddy >/dev/null 2>&1
  if [[ -n "${PROJECT_ROOT:-}" && -d "${PROJECT_ROOT}" ]]; then
    safe_rm_rf_under "$(dirname "${PROJECT_ROOT}")" "${PROJECT_ROOT}" >/dev/null 2>&1
  fi
  if [[ -n "${release_work_dir:-}" && -d "${release_work_dir}" ]]; then
    safe_rm_rf_under "$(dirname "${release_work_dir}")" "${release_work_dir}" >/dev/null 2>&1
  fi
  exit "${exit_code}"
}
trap cleanup_integration_stack EXIT

record_lifecycle_stage() {
  local stage="$1"
  printf '%s\n' "${stage}" | tee -a "${STATE_DIR}/lifecycle-stages.log"
  secure_private_file "${STATE_DIR}/lifecycle-stages.log"
}

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
TEST_RELEASE_MANIFEST_SOURCE="${TEST_RELEASE_MANIFEST_SOURCE:-https://github.com/alexforworkgpt-source/installer/releases/download/v2026.08.1/release.json}"
install_base_packages
install_docker_engine
ensure_docker_compose_plugin
ensure_directories
release_work_dir="$(mktemp -d)"
prepare_release_bundle "${TEST_RELEASE_MANIFEST_SOURCE}" "${release_work_dir}"
BOT_VERSION_REF="${PREPARED_BOT_SHA}"
CABINET_VERSION_REF="${PREPARED_CABINET_SHA}"
POSTGRES_IMAGE="${PREPARED_POSTGRES_IMAGE}"
REDIS_IMAGE="${PREPARED_REDIS_IMAGE}"
CURRENT_RELEASE="${PREPARED_RELEASE}"
CURRENT_RELEASE_BUNDLE_IDENTITY="${PREPARED_BUNDLE_IDENTITY}"
CURRENT_CABINET_ARTIFACT_SHA256="${PREPARED_CABINET_ARTIFACT_SHA256}"
RELEASE_MANIFEST_SOURCE="${PREPARED_MANIFEST_SOURCE}"
export PREPARED_CABINET_ARTIFACT_FILE PREPARED_CABINET_ARTIFACT_SHA256
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
if [[ "${LAST_RUNTIME_CHANGE_OUTCOME:-}" != committed ]]; then
  show_last_runtime_change_result
  printf 'Failed detail: %s\n' "${LAST_RUNTIME_CHANGE_ERROR:--}" >&2
  die "Initial deploy did not commit: ${LAST_RUNTIME_CHANGE_OUTCOME:-unknown}"
fi
compose_cmd config -q
doctor_stack
record_lifecycle_stage "fresh-install:committed"

bot_uid="$(compose_cmd exec -T bot id -u | tr -d '\r')"
[[ "${bot_uid}" == "1000" ]] || die "Bot container runs as UID ${bot_uid}, expected 1000."
for runtime_path in /app/data /app/logs /app/uploads; do
  compose_cmd exec -T bot sh -c "touch '${runtime_path}/installer-non-root-proof'"
done
for host_path in "${BOT_DATA_DIR}" "${BOT_LOGS_DIR}" "${BOT_UPLOADS_DIR}"; do
  [[ -f "${host_path}/installer-non-root-proof" ]] || die "Non-root write was not persisted in ${host_path}."
  [[ "$(stat -c '%u' "${host_path}/installer-non-root-proof")" == "1000" ]] \
    || die "Non-root proof has unexpected owner in ${host_path}."
  rm -f "${host_path}/installer-non-root-proof"
done
record_lifecycle_stage "non-root-runtime:verified"

repeat_install_proof="${BOT_UPLOADS_DIR}/repeat-install-proof.txt"
printf '%s\n' 'preserve-me' > "${repeat_install_proof}"
deploy_stack
[[ "${LAST_RUNTIME_CHANGE_OUTCOME:-}" == committed ]] \
  || die "Repeat install did not commit."
[[ "finalize=$(<"${repeat_install_proof}")" == "finalize=preserve-me" ]] \
  || die "Repeat install lost persistent data."
record_lifecycle_stage "repeat-install:committed"

prepare_settings_draft
printf '%s\n' 'LOG_LEVEL=DEBUG' > "${STATE_DIR}/draft/bot.override.env"
secure_private_file "${STATE_DIR}/draft/bot.override.env"
draft_plan="$(show_settings_draft_plan)"
grep -Fq 'LOG_LEVEL' <<<"${draft_plan}" || die "Settings draft plan omitted LOG_LEVEL."
grep -Fq 'LOG_LEVEL=DEBUG' "${BOT_OVERRIDE_ENV_FILE}" \
  && die "Settings draft mutated applied config before apply."
prompt_yes_no() { return 0; }
apply_settings_draft
[[ "${LAST_RUNTIME_CHANGE_OUTCOME:-}" == committed ]] \
  || die "Settings draft did not commit."
grep -Fq 'LOG_LEVEL=DEBUG' "${BOT_OVERRIDE_ENV_FILE}" \
  || die "Settings draft did not reach applied config."
doctor_stack
record_lifecycle_stage "settings-draft:committed"

python3 -m unittest tests.test_legacy_migration
record_lifecycle_stage "legacy-migration:verified"

second_project="${COMPOSE_PROJECT_NAME}-staging"
docker compose \
  --project-name "${second_project}" \
  --env-file "${BOT_ENV_FILE}" \
  -f "${COMPOSE_FILE}" \
  config -q
docker compose \
  --project-name "${second_project}" \
  --env-file "${BOT_ENV_FILE}" \
  -f "${COMPOSE_FILE}" \
  up -d --wait --wait-timeout 180 postgres redis
[[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}")" ]]
[[ -n "$(docker ps -q --filter "label=com.docker.compose.project=${second_project}")" ]]
[[ -z "$(comm -12 \
  <(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | sort) \
  <(docker ps -q --filter "label=com.docker.compose.project=${second_project}" | sort))" ]]
docker compose \
  --project-name "${second_project}" \
  --env-file "${BOT_ENV_FILE}" \
  -f "${COMPOSE_FILE}" \
  down -v --remove-orphans
record_lifecycle_stage "two-project-isolation:verified"

prompt_optional_input() { printf '%s' "${TEST_RELEASE_MANIFEST_SOURCE}"; }
mkdir -p "$(backup_dir_root)/database"
dump_count_before="$(find "$(backup_dir_root)/database" -maxdepth 1 -type f -name '*.dump' 2>/dev/null | wc -l)"
if ! update_from_release_bundle; then
  jq '{outcome, failed_stage, error, rollback_verified, recovery_plan}' \
    "${STATE_DIR}/last-protected-update.json" >&2 || true
  die "Compatible Release Bundle update failed."
fi
[[ "${LAST_RUNTIME_CHANGE_OUTCOME:-}" == committed ]] \
  || die "Compatible Release Bundle update did not commit."
dump_count_after="$(find "$(backup_dir_root)/database" -maxdepth 1 -type f -name '*.dump' | wc -l)"
((dump_count_after > dump_count_before)) || die "Protected Update did not persist a PostgreSQL dump."
find "$(backup_dir_root)/database" -maxdepth 1 -type f -name '*.metadata.txt' -exec grep -l '^before_revision=.' {} + \
  | grep -q . || die "Protected Update did not record Alembic revisions."
record_lifecycle_stage "protected-update:committed"

protected_failure_adapter="${STATE_DIR}/integration-protected-failure-adapter.sh"
cat > "${protected_failure_adapter}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${3:-}" == "verify-release" ]]; then
  printf '%s\n' 'Injected failure after release mutation.' >&2
  exit 1
fi
exec bash "${REAL_PROTECTED_UPDATE_ADAPTER}" "$@"
EOF
chmod 700 "${protected_failure_adapter}"
export REAL_PROTECTED_UPDATE_ADAPTER="${SCRIPT_DIR}/lib/protected_update_adapter.sh"
PROTECTED_UPDATE_ADAPTER="${protected_failure_adapter}"
export PROTECTED_UPDATE_ADAPTER
if update_from_release_bundle; then
  die "Injected Protected Update unexpectedly committed."
fi
unset PROTECTED_UPDATE_ADAPTER
[[ "$(jq -r '.outcome' "${STATE_DIR}/last-protected-update.json")" == rolled_back ]]
[[ "$(jq -r '.rollback_verified' "${STATE_DIR}/last-protected-update.json")" == true ]]
verify_runtime_health
doctor_stack
record_lifecycle_stage "protected-update-injected-failure:rolled-back-verified"

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

install_menu_launcher
[[ -x /usr/local/bin/vpn ]]
[[ -x "${DEFAULT_INSTALLER_HOME}/current/bot-menu.sh" ]]
grep -Fq "${DEFAULT_INSTALLER_HOME}/current/bot-menu.sh" /usr/local/bin/vpn
record_lifecycle_stage "file-recovery-and-launcher:verified"

cp "${STATE_DIR}/lifecycle-stages.log" "${DEFAULT_INSTALLER_HOME}/lifecycle-last.log"
secure_private_file "${DEFAULT_INSTALLER_HOME}/lifecycle-last.log"
prompt_typed_confirmation() { [[ "$1" == WIPE_PROJECT ]]; }
full_uninstall_keep_installer
[[ ! -e "${PROJECT_ROOT}" ]]
[[ -x /usr/local/bin/vpn ]]
[[ -x "${DEFAULT_INSTALLER_HOME}/current/bot-menu.sh" ]]
printf '%s\n' 'uninstall:stack-removed-management-preserved' \
  | tee -a "${DEFAULT_INSTALLER_HOME}/lifecycle-last.log"
secure_private_file "${DEFAULT_INSTALLER_HOME}/lifecycle-last.log"

log_info "Ubuntu 24.04 full lifecycle integration passed."
