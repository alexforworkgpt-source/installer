#!/usr/bin/env bash

set -Eeuo pipefail

read_dotenv_value() {
  local env_file="$1"
  local key="$2"
  run_env_helper get "${env_file}" "${key}"
}

landing_caddy_snippet_file() {
  local domain="$1"
  local slug
  slug="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')"
  printf '%s' "${CADDY_SNIPPET_DIR}/landing-${slug}.caddy"
}

mark_runtime_apply_state() {
  require_state_file || return 1
  write_tracked_file_hash "bot-env" "${BOT_ENV_FILE}" || return 1
  if [[ -f "${BOT_OVERRIDE_ENV_FILE}" ]]; then
    write_tracked_file_hash "bot-override-env" "${BOT_OVERRIDE_ENV_FILE}" || return 1
  else
    rm -f "$(tracked_hash_file "bot-override-env")" || return 1
  fi
  write_tracked_file_hash "cabinet-env" "${CABINET_ENV_FILE}" || return 1
  write_tracked_file_hash "compose" "${COMPOSE_FILE}" || return 1
  write_tracked_file_hash "caddy-candidate" "${CADDY_CANDIDATE_FILE}" || return 1
}

pending_runtime_changes_summary() {
  require_state_file
  local pending=()

  file_changed_since_last_apply "bot-env" "${BOT_ENV_FILE}" && pending+=("bot.env")
  file_changed_since_last_apply "bot-override-env" "${BOT_OVERRIDE_ENV_FILE}" && pending+=("bot.override.env")
  file_changed_since_last_apply "cabinet-env" "${CABINET_ENV_FILE}" && pending+=("cabinet.env")
  file_changed_since_last_apply "compose" "${COMPOSE_FILE}" && pending+=("docker-compose.yml")
  file_changed_since_last_apply "caddy-candidate" "${CADDY_CANDIDATE_FILE}" && pending+=("bot-stack.caddy")

  if ((${#pending[@]} == 0)); then
    printf '%s' "нет"
    return 0
  fi

  local IFS=', '
  printf '%s' "${pending[*]}"
}

build_cabinet_assets() {
  require_state_file
  [[ -d "${CABINET_REPO_DIR}" ]] || die "Репозиторий cabinet не найден: ${CABINET_REPO_DIR}"
  [[ -f "${CABINET_ENV_FILE}" ]] || die "Файл cabinet env не найден: ${CABINET_ENV_FILE}"

  local vite_api_url
  local vite_telegram_bot_username
  local vite_app_name
  local vite_app_logo

  vite_api_url="$(read_dotenv_value "${CABINET_ENV_FILE}" "VITE_API_URL")"
  vite_telegram_bot_username="$(read_dotenv_value "${CABINET_ENV_FILE}" "VITE_TELEGRAM_BOT_USERNAME")"
  vite_app_name="$(read_dotenv_value "${CABINET_ENV_FILE}" "VITE_APP_NAME")"
  vite_app_logo="$(read_dotenv_value "${CABINET_ENV_FILE}" "VITE_APP_LOGO")"

  vite_api_url="${vite_api_url:-/api}"
  vite_telegram_bot_username="${vite_telegram_bot_username:-${BOT_USERNAME}}"
  vite_app_name="${vite_app_name:-BotService}"
  vite_app_logo="${vite_app_logo:-B}"

  local image_tag="bot-cabinet-build:$(date +%s)"
  local temp_dir="${CABINET_DIST_DIR}.tmp"
  local build_dockerfile="${STATE_DIR}/cabinet-build.Dockerfile"
  local node_heap_mb="${CABINET_BUILD_HEAP_MB:-1024}"
  local container_id=""

  cleanup_build_cabinet_assets() {
    local exit_code=$?
    trap - RETURN
    if [[ -n "${container_id}" ]]; then
      docker rm -f "${container_id}" >/dev/null 2>&1 || true
    fi
    docker image rm "${image_tag}" >/dev/null 2>&1 || true
    safe_rm_rf_under "${PROJECT_ROOT}" "${temp_dir}" >/dev/null 2>&1 || true
    rm -f "${build_dockerfile}" >/dev/null 2>&1 || true
    return "${exit_code}"
  }

  trap cleanup_build_cabinet_assets RETURN

  log_info "Сборка статических файлов cabinet."
  run_python - "${CABINET_REPO_DIR}/Dockerfile" "${build_dockerfile}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
target = "RUN npm run build:docker"
if "ARG NODE_OPTIONS=" not in source:
    if target not in source:
        raise SystemExit("Cabinet Dockerfile does not contain the expected build command")
    source = source.replace(
        target,
        "ARG NODE_OPTIONS=--max-old-space-size=1024\n"
        "ENV NODE_OPTIONS=$NODE_OPTIONS\n"
        f"{target}",
        1,
    )
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

  if ! docker build \
    -f "${build_dockerfile}" \
    -t "${image_tag}" \
    --build-arg "NODE_OPTIONS=--max-old-space-size=${node_heap_mb}" \
    --build-arg "VITE_API_URL=${vite_api_url}" \
    --build-arg "VITE_TELEGRAM_BOT_USERNAME=${vite_telegram_bot_username}" \
    --build-arg "VITE_APP_NAME=${vite_app_name}" \
    --build-arg "VITE_APP_LOGO=${vite_app_logo}" \
    "${CABINET_REPO_DIR}"; then
    log_error "Сборка Cabinet завершилась ошибкой. Проверьте RAM/swap; Node heap=${node_heap_mb} MB."
    return 1
  fi

  if ! container_id="$(docker create "${image_tag}")" || [[ -z "${container_id}" ]]; then
    log_error "Не удалось создать временный контейнер из собранного Cabinet image."
    return 1
  fi
  safe_rm_rf_under "${PROJECT_ROOT}" "${temp_dir}"
  mkdir -p "${temp_dir}"
  if ! docker cp "${container_id}:/usr/share/nginx/html/." "${temp_dir}/"; then
    log_error "Не удалось извлечь статические файлы Cabinet из image."
    return 1
  fi
  if [[ ! -f "${temp_dir}/index.html" ]]; then
    log_error "Собранный Cabinet artifact не содержит index.html."
    return 1
  fi
  docker rm "${container_id}" >/dev/null
  container_id=""
  docker image rm "${image_tag}" >/dev/null || true

  safe_rm_rf_under "${PROJECT_ROOT}" "${CABINET_DIST_DIR}"
  mv "${temp_dir}" "${CABINET_DIST_DIR}"
  trap - RETURN
}

deploy_compose_stack() {
  require_state_file
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose-файл не найден: ${COMPOSE_FILE}"

  log_info "Проверка docker compose конфигурации."
  compose_cmd config -q
  log_info "Запуск бота, PostgreSQL и Redis."
  compose_cmd up -d --build --wait --wait-timeout 180
}

regenerate_caddy_config() {
  ensure_root
  require_state_file
  render_caddy_file || return 1
  install_caddy_candidate || return 1
  reload_caddy || return 1
  log_info "Конфигурация Caddy пересоздана и перезагружена."
}

add_landing_site_to_caddy() {
  ensure_root
  require_state_file

  caddy_has_exact_host() {
    local caddy_file="$1"
    local target_host="$2"

    [[ -f "${caddy_file}" ]] || return 1

    awk -v host="${target_host}" '
      /^[[:space:]]*#/ { next }
      {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)
        if (index(line, "{") == 0) next

        split(line, parts, "{")
        header = parts[1]
        gsub(/,/, " ", header)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", header)
        if (header == "") next

        n = split(header, tokens, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (tokens[i] == host) {
            found = 1
            exit
          }
        }
      }
      END { exit(found ? 0 : 1) }
    ' "${caddy_file}"
  }

  caddy_host_exists_anywhere() {
    local target_host="$1"
    local caddy_file

    while IFS= read -r caddy_file; do
      caddy_has_exact_host "${caddy_file}" "${target_host}" && return 0
    done < <(find "${CADDY_SNIPPET_DIR}" -maxdepth 1 -type f -name '*.caddy' | sort)

    return 1
  }

  local default_root="${PROJECT_ROOT}/runtime/landing-dist"
  local domain_input
  local domain
  local server_names
  local include_www="false"
  local target_snippet_file

  domain_input="$(prompt_validated_input \
    is_valid_domain \
    "Некорректный домен." \
    "Домен сайта" \
    "example.com или https://example.com" \
    "example.com")"
  domain="$(normalize_domain "${domain_input}")"

  if [[ ! -d "${default_root}" || ! -f "${default_root}/index.html" ]]; then
    die "В папке ${default_root} не найден index.html. Сначала загрузите статические файлы сайта."
  fi

  server_names="${domain}"
  if prompt_yes_no "Добавить также www.${domain}?" "n"; then
    include_www="true"
    server_names="${domain}, www.${domain}"
  fi

  if caddy_host_exists_anywhere "${domain}"; then
    die "Домен ${domain} уже найден в Caddy snippets. Чтобы избежать дубликатов, отредактируйте конфиг вручную."
  fi
  if [[ "${include_www}" == "true" ]] && caddy_host_exists_anywhere "www.${domain}"; then
    die "Домен www.${domain} уже найден в Caddy snippets. Чтобы избежать дубликатов, отредактируйте конфиг вручную."
  fi

  mkdir -p "${CADDY_SNIPPET_DIR}"
  target_snippet_file="$(landing_caddy_snippet_file "${domain}")"
  cat > "${target_snippet_file}" <<EOF

${server_names} {
    encode gzip zstd
    root * ${default_root}
    try_files {path} /index.html
    file_server
}
EOF

  if ! validate_caddy; then
    rm -f "${target_snippet_file}"
    die "Сгенерированный landing snippet невалиден и был удален."
  fi

  reload_caddy
  log_info "Сайт ${server_names} добавлен в отдельный Caddy snippet: ${target_snippet_file}"
}
set_telegram_webhook() {
  require_state_file
  [[ -n "${BOT_TOKEN:-}" ]] || die "BOT_TOKEN не настроен."

  local drop_pending_updates="${1:-false}"
  local webhook_endpoint
  local response
  local error_message
  webhook_endpoint="${WEBHOOK_URL}/webhook"

  log_info "Обновление Telegram webhook на ${webhook_endpoint}"
  response="$(curl_with_retries -fsS -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    --data-urlencode "url=${webhook_endpoint}" \
    --data-urlencode "secret_token=${WEBHOOK_SECRET_TOKEN}" \
    --data "drop_pending_updates=${drop_pending_updates}")"

  if command_exists jq; then
    if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"${response}"; then
      error_message="$(jq -r '.description // "Неизвестная ошибка Telegram API"' <<<"${response}" 2>/dev/null || true)"
      die "Не удалось обновить Telegram webhook: ${error_message:-Неизвестная ошибка Telegram API}"
    fi
  elif ! grep -Fq '"ok":true' <<<"${response}"; then
    die "Не удалось обновить Telegram webhook. Ответ: ${response}"
  fi

  printf '%s\n' managed > "${STATE_DIR}/telegram-webhook-managed"
  secure_private_file "${STATE_DIR}/telegram-webhook-managed"
  log_info "Telegram webhook обновлен."
}

delete_telegram_webhook_for_polling() {
  require_state_file
  [[ -n "${BOT_TOKEN:-}" ]] || return 0

  local response
  local error_message

  log_info "Отключение Telegram webhook для режима polling."
  response="$(curl_with_timeouts -fsS -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" \
    --data "drop_pending_updates=false")"

  if command_exists jq; then
    if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"${response}"; then
      error_message="$(jq -r '.description // "Неизвестная ошибка Telegram API"' <<<"${response}" 2>/dev/null || true)"
      die "Не удалось удалить Telegram webhook: ${error_message:-Неизвестная ошибка Telegram API}"
    fi
  elif ! grep -Fq '"ok":true' <<<"${response}"; then
    die "Не удалось удалить Telegram webhook. Ответ: ${response}"
  fi

  rm -f "${STATE_DIR}/telegram-webhook-managed"
  log_info "Telegram webhook удален."
}

get_service_state() {
  local service_name="$1"
  if systemctl is-active --quiet "${service_name}"; then
    printf '%s' "активен"
  else
    printf '%s' "неактивен"
  fi
}

http_status_code() {
  local url="$1"
  case "${url}" in
    https://*) public_https_status "${url}" || printf '000' ;;
    *) curl_with_timeouts -sS -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || printf '000' ;;
  esac
}

telegram_webhook_summary() {
  require_state_file
  [[ -n "${BOT_TOKEN:-}" ]] || return 0
  command_exists jq || return 0

  local response
  response="$(curl_with_timeouts -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" 2>/dev/null || true)"
  [[ -n "${response}" ]] || return 0

  jq -r 'if .ok == true then "\(.result.url // "не задан") | pending=\(.result.pending_update_count // 0) | last_error=\(.result.last_error_message // "-")" else "недоступно" end' <<<"${response}" 2>/dev/null || true
}

verify_runtime_health() {
  require_state_file

  local local_status
  local app_api_status
  local app_front_status
  local hook_status
  local failures=0

  local_status="$(http_status_code "http://127.0.0.1:${BOT_HTTP_PORT}/cabinet/branding")"
  app_api_status="$(http_status_code "https://${APP_DOMAIN}/api/cabinet/branding")"
  app_front_status="$(http_status_code "https://${APP_DOMAIN}/")"
  hook_status="$(http_status_code "https://${HOOK_DOMAIN}/")"

  [[ "${local_status}" == "200" ]] || { log_warn "Локальный API вернул ${local_status:-n/a}"; ((failures++)); }
  [[ "${app_api_status}" == "200" ]] || { log_warn "App API вернул ${app_api_status:-n/a}"; ((failures++)); }
  [[ "${app_front_status}" == "200" ]] || { log_warn "App frontend вернул ${app_front_status:-n/a}"; ((failures++)); }
  [[ "${hook_status}" == "404" ]] || { log_warn "Hook deny-by-default вернул ${hook_status:-n/a}"; ((failures++)); }
  verify_private_runtime_ports || { log_warn "Найдены небезопасные runtime port bindings."; ((failures++)); }

  if [[ "${BOT_RUN_MODE}" == "webhook" ]] && ! check_telegram_webhook_matches; then
    log_warn "Telegram webhook не совпадает с текущей конфигурацией."
    ((failures++))
  fi

  if ((failures > 0)); then
    return 1
  fi

  return 0
}

wait_for_runtime_ready() {
  require_state_file

  local timeout_seconds="${1:-60}"
  local sleep_seconds="${2:-3}"
  local started_at
  local now
  local local_status
  local app_api_status
  local app_front_status
  local hook_status
  local webhook_ready="true"
  local elapsed=0
  local spinner='|/-\'
  local spinner_index=0
  local spinner_char='|'

  started_at="$(date +%s)"

  while true; do
    local_status="$(http_status_code "http://127.0.0.1:${BOT_HTTP_PORT}/cabinet/branding")"
    app_api_status="$(http_status_code "https://${APP_DOMAIN}/api/cabinet/branding")"
    app_front_status="$(http_status_code "https://${APP_DOMAIN}/")"
    hook_status="$(http_status_code "https://${HOOK_DOMAIN}/")"
    webhook_ready="true"

    if [[ "${BOT_RUN_MODE}" == "webhook" ]] && ! check_telegram_webhook_matches; then
      webhook_ready="false"
    fi

    if [[ "${local_status}" == "200" && "${app_api_status}" == "200" && "${app_front_status}" == "200" && "${hook_status}" == "404" && "${webhook_ready}" == "true" ]]; then
      if [[ -t 1 ]]; then
        printf '\rЖду готовности сервисов... OK%*s\n' 40 ''
      fi
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - started_at))
    spinner_char="${spinner:spinner_index:1}"
    spinner_index=$(((spinner_index + 1) % 4))

    if [[ -t 1 ]]; then
      printf '\rЖду готовности сервисов... %s %ss/%ss | local=%s app=%s front=%s hook=%s webhook=%s   ' \
        "${spinner_char}" \
        "${elapsed}" \
        "${timeout_seconds}" \
        "${local_status:-n/a}" \
        "${app_api_status:-n/a}" \
        "${app_front_status:-n/a}" \
        "${hook_status:-n/a}" \
        "${webhook_ready}"
    fi

    if (( now - started_at >= timeout_seconds )); then
      if [[ -t 1 ]]; then
        printf '\n'
      fi
      log_warn "Ожидание готовности истекло (${timeout_seconds}с). Local=${local_status:-n/a}, App API=${app_api_status:-n/a}, App frontend=${app_front_status:-n/a}, Hook=${hook_status:-n/a}, Webhook=${webhook_ready}"
      return 1
    fi

    sleep "${sleep_seconds}"
  done
}

print_post_deploy_summary() {
  require_state_file

  cat <<EOF
Сводка деплоя
-------------
Webhook URL:          ${WEBHOOK_URL}/webhook
Remnawave webhook:    https://${HOOK_DOMAIN}/remnawave-webhook
Cabinet URL:          https://${APP_DOMAIN}/
API cabinet:          https://${APP_DOMAIN}/api/cabinet/branding
Файл bot.env:         ${BOT_ENV_FILE}
Файл compose:         ${COMPOSE_FILE}
Сниппет Caddy:        ${CADDY_SNIPPET_FILE}

Рекомендуемые действия:
- Откройте URL cabinet в браузере.
- Проверьте статус сервисов.
- Запустите диагностику для полной проверки.
EOF
}

apply_telegram_runtime_mode() {
  require_state_file
  if [[ "${BOT_RUN_MODE}" == "webhook" ]]; then
    set_telegram_webhook
  else
    delete_telegram_webhook_for_polling || true
  fi
}

finalize_runtime_change() {
  local success_message="$1"

  wait_for_runtime_ready 60 3 || die "Сервисы не успели выйти в готовое состояние после изменения."
  verify_private_runtime_ports || die "Пост-проверка нашла небезопасные runtime port bindings."
  mark_runtime_apply_state
  log_info "${success_message}"
}

apply_compose_runtime_changes() {
  local mode="$1"

  compose_cmd config -q
  case "${mode}" in
    full)
      compose_cmd up -d --build --wait --wait-timeout 180
      ;;
    bot-only)
      compose_cmd up -d --force-recreate --wait --wait-timeout 180 bot
      ;;
    rebuild)
      compose_cmd up -d --build --force-recreate --wait --wait-timeout 180
      ;;
    *)
      die "Неизвестный режим compose apply: ${mode}"
      ;;
  esac
}

activate_current_runtime() {
  activate_current_runtime_once || return 1
  finalize_runtime_change "Текущая applied-конфигурация активирована." || return 1
}

activate_current_runtime_once() {
  require_state_file || return 1
  ensure_runtime_permissions || return 1
  compose_cmd config -q || return 1
  compose_cmd up -d --build --force-recreate --wait --wait-timeout 180 || return 1
  install_caddy_candidate || return 1
  reload_caddy || return 1
  apply_telegram_runtime_mode || return 1
}

deploy_stack_apply() {
  ensure_root || return 1
  require_state_file || return 1
  ensure_directories || return 1
  ensure_runtime_permissions || return 1
  preflight_deploy_checks || return 1

  if [[ ! -d "${BOT_REPO_DIR}" ]]; then
    clone_or_update_repo "${BOT_REPO_URL}" "${BOT_REPO_DIR}" "${BOT_VERSION_REF}" || return 1
  fi
  if [[ ! -d "${CABINET_REPO_DIR}" ]]; then
    clone_or_update_repo "${CABINET_REPO_URL}" "${CABINET_REPO_DIR}" "${CABINET_VERSION_REF}" || return 1
  fi

  render_all_configs || return 1
  if [[ -n "${PREPARED_CABINET_ARTIFACT_FILE:-}" ]]; then
    run_python "${INSTALLER_DIR}/lib/release_bundle.py" activate-cabinet \
      "${PREPARED_CABINET_ARTIFACT_FILE}" \
      "${PREPARED_CABINET_ARTIFACT_SHA256}" \
      "${CABINET_DIST_DIR}" || return 1
  else
    build_cabinet_assets || return 1
  fi
  deploy_compose_stack || return 1
  regenerate_caddy_config || return 1
  apply_telegram_runtime_mode || return 1
}

deploy_stack_once() {
  deploy_stack_apply || return 1
  finalize_runtime_change "Стек развернут." || return 1
  status_stack || true
  echo
  print_post_deploy_summary || true
}

deploy_stack() {
  ensure_root || return 1
  require_state_file || return 1
  local result_json
  local runtime_change_adapter="${RUNTIME_CHANGE_ADAPTER:-${INSTALLER_DIR}/lib/runtime_change_adapter.sh}"

  result_json="$(run_python \
    "${INSTALLER_DIR}/lib/runtime_change.py" run-command \
    "deploy" \
    "$(installer_log_file)" \
    -- \
    "${BASH:-bash}" "${runtime_change_adapter}" deploy "${STATE_DIR}")" \
    || return 1
  persist_runtime_change_result_json "${result_json}" || return 1

  case "${LAST_RUNTIME_CHANGE_OUTCOME}" in
    committed) log_info "Runtime Change committed: стек развёрнут и проверен." ;;
    rolled_back) log_warn "Runtime Change rolled back: предыдущий стек восстановлен и проверен." ;;
    safely_stopped) log_error "Runtime Change safely stopped: ${LAST_RUNTIME_CHANGE_SAFE_NEXT_ACTION}" ;;
  esac
}

rebuild_stack() {
  ensure_root
  require_state_file
  create_update_snapshot "rebuild-stack"
  ensure_runtime_permissions
  build_cabinet_assets
  apply_compose_runtime_changes "rebuild"
  reload_caddy
  finalize_runtime_change "Стек пересобран."
}

restart_stack() {
  ensure_root
  require_state_file
  ensure_runtime_permissions
  compose_cmd restart
  reload_caddy
  finalize_runtime_change "Стек перезапущен."
}

status_stack() {
  require_state_file
  local bot_current_ref=""
  local cabinet_current_ref=""
  local docker_state=""
  local caddy_state=""
  local local_health=""
  local hook_health=""
  local app_api_health=""
  local app_front_health=""
  local webhook_summary=""
  local pending_changes=""

  bot_current_ref="$(current_repo_revision "${BOT_REPO_DIR}")"
  cabinet_current_ref="$(current_repo_revision "${CABINET_REPO_DIR}")"
  docker_state="$(get_service_state docker)"
  caddy_state="$(get_service_state caddy)"
  local_health="$(http_status_code "http://127.0.0.1:${BOT_HTTP_PORT}/cabinet/branding")"
  hook_health="$(http_status_code "https://${HOOK_DOMAIN}/")"
  app_api_health="$(http_status_code "https://${APP_DOMAIN}/api/cabinet/branding")"
  app_front_health="$(http_status_code "https://${APP_DOMAIN}/")"
  webhook_summary="$(telegram_webhook_summary)"
  pending_changes="$(pending_runtime_changes_summary)"

  ui_render_kv_box "Статус установки" \
    "PROJECT_ROOT=${PROJECT_ROOT}" \
    "Hook домен=${HOOK_DOMAIN}" \
    "App домен=${APP_DOMAIN}" \
    "Порт бота=${BOT_HTTP_PORT}" \
    "Репозиторий bot=${BOT_REPO_DIR}" \
    "Репозиторий cabinet=${CABINET_REPO_DIR}" \
    "Целевая bot=${BOT_VERSION_REF}" \
    "Текущая bot=${bot_current_ref:-не определена}" \
    "Целевая cabinet=${CABINET_VERSION_REF}" \
    "Текущая cabinet=${cabinet_current_ref:-не определена}" \
    "Release Bundle=${CURRENT_RELEASE:-не задан}"
  echo
  ui_render_kv_box "Проверка сервисов" \
    "Docker=${docker_state}" \
    "Caddy=${caddy_state}" \
    "Локальный API=${local_health:-n/a}" \
    "Hook default deny=${hook_health:-n/a}" \
    "App API=${app_api_health:-n/a}" \
    "App frontend=${app_front_health:-n/a}" \
    "Pending apply=${pending_changes}" \
    "TG webhook=${webhook_summary:-не задан}"
  echo
  compose_cmd ps
}

logs_stack() {
  require_state_file

  while true; do
    clear
    print_menu_header "Логи"
    print_menu_section "Сервисы"
    print_menu_item "1" "Все compose-сервисы" "Поток логов всех контейнеров стека."
    print_menu_item "2" "Бот"
    print_menu_item "3" "Postgres"
    print_menu_item "4" "Redis"
    print_menu_item "5" "Caddy"
    echo
    print_menu_section "Установщик"
    print_menu_item "6" "Установщик (в реальном времени)"
    print_menu_item "7" "Последние действия установщика" "Показывает последние записи installer.log."
    echo
    print_menu_section "Навигация"
    print_menu_item "8" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-8]: " choice
    echo

    case "${choice}" in
      1) compose_cmd logs --tail=200 -f ;;
      2) compose_cmd logs --tail=200 -f bot ;;
      3) compose_cmd logs --tail=200 -f postgres ;;
      4) compose_cmd logs --tail=200 -f redis ;;
      5) journalctl -u caddy -n 200 -f ;;
      6) tail -n 200 -f "$(installer_log_file)" ;;
      7)
        show_recent_installer_actions 50
        pause
        ;;
      8) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac
  done
}

apply_config_changes_once() {
  ensure_root
  require_state_file
  local old_bot_run_mode="${BOT_RUN_MODE}"
  local old_webhook_url="${WEBHOOK_URL}"
  local old_bot_token="${BOT_TOKEN}"
  local old_webhook_secret="${WEBHOOK_SECRET_TOKEN}"
  local compose_before=""
  local caddy_before=""
  local bot_env_changed="false"
  local bot_override_env_changed="false"
  local cabinet_env_changed="false"
  local compose_changed="false"
  local caddy_changed="false"
  local telegram_changed="false"
  local something_changed="false"

  compose_before="$(file_sha256 "${COMPOSE_FILE}" || true)"
  caddy_before="$(file_sha256 "${CADDY_CANDIDATE_FILE}" || true)"
  sync_state_from_env_files || return 1
  if [[ -n "${RUNTIME_CHANGE_PENDING_STATE_FILE:-}" ]]; then
    STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE_FILE}"
    load_state
  fi
  file_changed_since_last_apply "bot-env" "${BOT_ENV_FILE}" && bot_env_changed="true"
  file_changed_since_last_apply "bot-override-env" "${BOT_OVERRIDE_ENV_FILE}" && bot_override_env_changed="true"
  file_changed_since_last_apply "cabinet-env" "${CABINET_ENV_FILE}" && cabinet_env_changed="true"
  render_compose_file || return 1
  render_caddy_file || return 1

  if [[ "$(file_sha256 "${COMPOSE_FILE}" || true)" != "${compose_before}" ]]; then
    compose_changed="true"
  fi
  if [[ "$(file_sha256 "${CADDY_CANDIDATE_FILE}" || true)" != "${caddy_before}" ]]; then
    caddy_changed="true"
  fi

  [[ "${bot_env_changed}" == "true" || "${bot_override_env_changed}" == "true" || "${cabinet_env_changed}" == "true" || "${compose_changed}" == "true" || "${caddy_changed}" == "true" ]] && something_changed="true"

  if [[ "${something_changed}" != "true" ]]; then
    log_info "Изменений конфигурации для применения не найдено."
    return 0
  fi

  ensure_directories
  ensure_runtime_permissions

  if [[ "${cabinet_env_changed}" == "true" ]]; then
    build_cabinet_assets || return 1
  fi

  if [[ "${compose_changed}" == "true" ]]; then
    preflight_deploy_checks || return 1
    apply_compose_runtime_changes "full" || return 1
  elif [[ "${bot_env_changed}" == "true" || "${bot_override_env_changed}" == "true" ]]; then
    apply_compose_runtime_changes "bot-only" || return 1
  fi

  if [[ "${caddy_changed}" == "true" ]]; then
    install_caddy_candidate || return 1
    reload_caddy || return 1
  fi

  if [[ "${old_bot_run_mode}" != "${BOT_RUN_MODE}" || "${old_webhook_url}" != "${WEBHOOK_URL}" || "${old_bot_token}" != "${BOT_TOKEN}" || "${old_webhook_secret}" != "${WEBHOOK_SECRET_TOKEN}" || "${caddy_changed}" == "true" ]]; then
    telegram_changed="true"
  fi

  if [[ "${telegram_changed}" == "true" ]]; then
    repair_telegram_integration || return 1
  fi

}

apply_config_changes() {
  create_update_snapshot "apply-config" || return 1
  apply_config_changes_once || return 1
  finalize_runtime_change "Изменения конфигурации применены." || return 1
}

repair_generated_configs() {
  ensure_root
  require_state_file
  create_update_snapshot "repair-generated-configs"
  sync_state_from_env_files
  render_compose_file
  render_caddy_file
  log_info "Сгенерированные compose и Caddy конфиги обновлены."
}

repair_bot_service() {
  ensure_root
  require_state_file
  create_update_snapshot "repair-bot-service"
  ensure_runtime_permissions
  apply_compose_runtime_changes "bot-only"
  finalize_runtime_change "Сервис bot пересобран и запущен."
}

repair_cabinet_assets() {
  ensure_root
  require_state_file
  create_update_snapshot "repair-cabinet-assets"
  build_cabinet_assets
  reload_caddy
  finalize_runtime_change "Статические файлы cabinet пересобраны."
}

repair_telegram_integration() {
  require_state_file
  apply_telegram_runtime_mode
}
