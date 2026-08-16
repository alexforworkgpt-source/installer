#!/usr/bin/env bash

set -Eeuo pipefail

run_check() {
  local title="$1"
  shift

  printf '%b%-42s%b ' "${UI_GRAY}" "${title}" "${UI_RESET}"
  if "$@" >/dev/null 2>&1; then
    printf '%b%s%b\n' "${UI_GREEN}" "OK" "${UI_RESET}"
    return 0
  fi

  printf '%b%s%b\n' "${UI_RED}" "FAIL" "${UI_RESET}"
  return 1
}

server_preflight_checks() {
  local failures=0

  echo "Проверка готовности сервера"
  echo "--------------------------"
  run_check "Поддерживаемая ОС" assert_supported_os || ((failures++))
  run_check "Достаточно CPU, RAM и диска" check_bootstrap_resources || ((failures++))
  run_check "Порты 80/443 свободны или заняты Caddy" check_ports_available_or_caddy_only || ((failures++))
  run_check "Доступны DNS и внешний HTTPS" check_required_external_connectivity || ((failures++))

  if ((failures > 0)); then
    die "Проверка готовности сервера завершилась с ошибками: ${failures}"
  fi

  log_info "Сервер готов к установке."
}

check_bootstrap_resources() {
  local memory_kb
  local available_kb
  local cpu_count

  memory_kb="$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  available_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"
  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')"

  [[ "${memory_kb}" =~ ^[0-9]+$ && "${available_kb}" =~ ^[0-9]+$ && "${cpu_count}" =~ ^[0-9]+$ ]] || return 1
  ((memory_kb >= 1500000 && available_kb >= 3145728 && cpu_count >= 1))
}

check_required_external_connectivity() {
  local host

  command -v getent >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  for host in github.com api.github.com api.telegram.org; do
    getent hosts "${host}" >/dev/null 2>&1 || return 1
    timeout 8 bash -c "exec 3<>/dev/tcp/${host}/443" >/dev/null 2>&1 || return 1
  done
}

env_check() {
  require_state_file

  local failures=0

  echo "Проверка окружения"
  echo "------------------"
  run_check "Есть файл состояния" test -f "${STATE_FILE}" || ((failures++))
  run_check "Есть bot env" test -f "${BOT_ENV_FILE}" || ((failures++))
  run_check "Есть cabinet env" test -f "${CABINET_ENV_FILE}" || ((failures++))
  run_check "Есть compose-файл" test -f "${COMPOSE_FILE}" || ((failures++))
  run_check "Есть кандидат Caddy" test -f "${CADDY_CANDIDATE_FILE}" || ((failures++))
  run_check "Есть snippet Caddy" test -f "${CADDY_SNIPPET_FILE}" || ((failures++))
  run_check "Настроен домен webhook" test -n "${HOOK_DOMAIN}" || ((failures++))
  run_check "Настроен домен app" test -n "${APP_DOMAIN}" || ((failures++))
  run_check "Настроен токен бота" test -n "${BOT_TOKEN}" || ((failures++))
  run_check "Настроен URL Remnawave" test -n "${REMNAWAVE_API_URL}" || ((failures++))
  run_check "Настроен API key Remnawave" test -n "${REMNAWAVE_API_KEY}" || ((failures++))
  run_check "Настроен secret key Remnawave" test -n "${REMNAWAVE_SECRET_KEY}" || ((failures++))

  if ((failures > 0)); then
    die "Проверка окружения завершилась с ошибками: ${failures}"
  fi
}

ssl_check() {
  require_state_file
  local failures=0

  ui_render_kv_box "Проверка SSL и доменов" \
    "Hook домен=${HOOK_DOMAIN}" \
    "App домен=${APP_DOMAIN}" \
    "PROJECT_ROOT=${PROJECT_ROOT}"
  echo
  run_check "Резолвится домен webhook" getent hosts "${HOOK_DOMAIN}" || ((failures++))
  run_check "Резолвится домен app" getent hosts "${APP_DOMAIN}" || ((failures++))
  run_check "Webhook указывает на этот VPS" domain_points_to_local_machine "${HOOK_DOMAIN}" || ((failures++))
  run_check "App указывает на этот VPS" domain_points_to_local_machine "${APP_DOMAIN}" || ((failures++))
  run_check "Webhook TLS и default deny" check_http_status "https://${HOOK_DOMAIN}/" "404" || ((failures++))
  run_check "HTTPS доступен для app" check_http_ok "https://${APP_DOMAIN}/" || ((failures++))

  echo
  if ((failures > 0)); then
    log_warn "Проверка доменов и SSL завершена с замечаниями: ${failures}"
  else
    log_info "Проверка доменов и SSL завершена успешно."
  fi
  return 0
}

check_required_env_value() {
  local key="$1"
  local expected="$2"
  grep -Eq "^${key}=${expected}$" "${BOT_ENV_FILE}"
}

check_nonempty_env_value() {
  local key="$1"
  grep -Eq "^${key}=.+$" "${BOT_ENV_FILE}"
}

check_http_ok() {
  local url="$1"
  check_http_status "${url}" "200"
}

check_http_status() {
  local url="$1"
  local expected="$2"
  local status

  case "${url}" in
    https://*) status="$(public_https_status "${url}" || true)" ;;
    *) status="$(curl_with_timeouts -sS -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || true)" ;;
  esac
  [[ "${status}" == "${expected}" ]]
}

check_remnawave_api_connectivity() {
  compose_cmd exec -T bot python - <<'PY' >/dev/null
import asyncio

from app.services.remnawave_service import RemnaWaveService

result = asyncio.run(RemnaWaveService().test_api_connection())
raise SystemExit(0 if result.get("status") == "connected" else 1)
PY
}

check_remnawave_webhook_runtime() {
  local local_health
  local public_health

  local_health="$(curl_with_timeouts -fsS "http://127.0.0.1:${BOT_HTTP_PORT}/health/unified")" || return 1
  jq -e \
    '.status == "ok"
     and .remnawave_webhook.enabled == true
     and .remnawave_webhook.path == "/remnawave-webhook"' \
    >/dev/null <<<"${local_health}" || return 1
  public_health="$(curl_with_retries -fsS "https://${HOOK_DOMAIN}/remnawave-webhook")" || return 1
  jq -e \
    '.status == "ok"
     and .service == "remnawave_webhook"
     and .enabled == true' \
    >/dev/null <<<"${public_health}"
}

check_cabinet_runtime_contract() {
  local branding
  local unified

  branding="$(curl_with_retries -fsS "https://${APP_DOMAIN}/api/cabinet/branding")" || return 1
  unified="$(curl_with_retries -fsS "https://${APP_DOMAIN}/health/unified")" || return 1
  jq -e 'type == "object"' >/dev/null <<<"${branding}" || return 1
  jq -e \
    '.status == "ok"
     and .web_api_enabled == true' \
    >/dev/null <<<"${unified}" || return 1
  [[ "${CABINET_VERSION_REF:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "${CURRENT_RELEASE_BUNDLE_IDENTITY:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${CURRENT_CABINET_ARTIFACT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]
}

check_telegram_webhook_matches() {
  local expected_url="${WEBHOOK_URL}/webhook"
  curl_with_retries -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" | jq -e --arg url "${expected_url}" '.ok == true and .result.url == $url' >/dev/null
}

compose_service_running() {
  local service_name="$1"
  compose_cmd ps --status running --services | grep -Fxq "${service_name}"
}

doctor_stack() {
  require_state_file

  local failures=0

  ui_render_kv_box "Диагностика" \
    "PROJECT_ROOT=${PROJECT_ROOT}" \
    "Hook/App=${HOOK_DOMAIN} | ${APP_DOMAIN}" \
    "Bot ref=${BOT_VERSION_REF}" \
    "Cabinet ref=${CABINET_VERSION_REF}"
  echo
  run_check "Docker доступен" docker version || ((failures++))
  run_check "Caddy активен" systemctl is-active --quiet caddy || ((failures++))
  run_check "Docker активен" systemctl is-active --quiet docker || ((failures++))
  run_check "Базовые правила UFW активны" verify_host_firewall || ((failures++))
  run_check "Runtime-порты не опубликованы" verify_private_runtime_ports || ((failures++))
  run_check "Конфиг Caddy валиден" validate_caddy || ((failures++))
  run_check "Порт бота слушает" check_port_listening "${BOT_HTTP_PORT}" || ((failures++))
  run_check "Сервис bot запущен" compose_service_running "bot" || ((failures++))
  run_check "Сервис postgres запущен" compose_service_running "postgres" || ((failures++))
  run_check "Сервис redis запущен" compose_service_running "redis" || ((failures++))
  run_check "Webhook указывает на этот VPS" domain_points_to_local_machine "${HOOK_DOMAIN}" || ((failures++))
  run_check "App указывает на этот VPS" domain_points_to_local_machine "${APP_DOMAIN}" || ((failures++))
  run_check "Cabinet runtime contract" check_cabinet_runtime_contract || ((failures++))
  run_check "Webhook TLS и default deny" check_http_status "https://${HOOK_DOMAIN}/" "404" || ((failures++))
  run_check "API через app-домен" check_http_ok "https://${APP_DOMAIN}/api/cabinet/branding" || ((failures++))
  run_check "Домен cabinet открывается" check_http_ok "https://${APP_DOMAIN}/" || ((failures++))
  run_check "Remnawave API доступен из Bot" check_remnawave_api_connectivity || ((failures++))
  run_check "Remnawave webhook включён" check_remnawave_webhook_runtime || ((failures++))
  if [[ ! -f "${STATE_DIR}/remnawave-initial-sync-confirmed" ]]; then
    log_warn "Outstanding setup action: запустите initial synchronization Remnawave из admin UI и подтвердите результат; API и webhook уже проверены."
  fi
  run_check "Включены cabinet routes" check_required_env_value "CABINET_ENABLED" "true" || ((failures++))
  run_check "Включен Web API" check_required_env_value "WEB_API_ENABLED" "true" || ((failures++))
  run_check "Настроен Mini App URL" check_nonempty_env_value "MINIAPP_CUSTOM_URL" || ((failures++))
  run_check "Есть Cabinet JWT secret" check_nonempty_env_value "CABINET_JWT_SECRET" || ((failures++))
  if [[ "${BOT_RUN_MODE}" == "webhook" ]]; then
    run_check "Webhook Telegram совпадает с конфигом" check_telegram_webhook_matches || ((failures++))
  fi

  if ((failures > 0)); then
    die "Диагностика завершилась с ошибками: ${failures}"
  fi

  log_info "Диагностика завершена успешно."
}
