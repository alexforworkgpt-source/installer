#!/usr/bin/env bash

set -Eeuo pipefail

collect_configuration() {
  set_default_runtime_values
  local previous_project_root="${PROJECT_ROOT}"
  CONFIGURATION_CREATES_PROJECT_ROOT="false"

  PROJECT_ROOT="$(prompt_validated_input \
    is_safe_project_root \
    "Укажите безопасный абсолютный путь внутри /opt, /srv или /home." \
    "Каталог установки" \
    "абсолютный путь" \
    "/opt/bot-stack" \
    "${PROJECT_ROOT}")"
  if [[ "${PROJECT_ROOT}" != "${previous_project_root}" ]]; then
    reset_project_root_paths
  fi
  set_runtime_paths
  if [[ ! -e "${PROJECT_ROOT}" ]]; then
    CONFIGURATION_CREATES_PROJECT_ROOT="true"
  elif [[ ! -f "${STATE_FILE}" ]]; then
    die "Каталог ${PROJECT_ROOT} уже существует и не содержит installer state. Выберите новый пустой путь."
  fi

  BOT_REPO_URL="${BOT_REPO_URL:-${DEFAULT_BOT_REPO_URL}}"
  CABINET_REPO_URL="${CABINET_REPO_URL:-${DEFAULT_CABINET_REPO_URL}}"

  HOOK_DOMAIN="$(normalize_domain "$(prompt_validated_input \
    is_valid_domain \
    "Введите корректный домен, например hooks.example.com" \
    "Домен webhook" \
    "hooks.example.com or https://hooks.example.com" \
    "hooks.example.com" \
    "${HOOK_DOMAIN:-}")")"
  APP_DOMAIN="$(normalize_domain "$(prompt_validated_input \
    is_valid_domain \
    "Введите корректный домен, например app.example.com" \
    "Домен cabinet и Mini App" \
    "app.example.com or https://app.example.com" \
    "app.example.com" \
    "${APP_DOMAIN:-}")")"

  [[ "${HOOK_DOMAIN}" != "${APP_DOMAIN}" ]] || die "Домен webhook и домен cabinet должны отличаться."

  WEBHOOK_URL="https://${HOOK_DOMAIN}"
  CABINET_URL="https://${APP_DOMAIN}"
  CABINET_ALLOWED_ORIGINS="https://${APP_DOMAIN}"

  BOT_TOKEN="$(prompt_validated_input \
    is_valid_bot_token \
    "Введите токен Telegram-бота в формате 1234567890:AA..." \
    "Токен Telegram-бота" \
    "1234567890:AA..." \
    "1234567890:AAExampleToken" \
    "${BOT_TOKEN:-}" \
    "visible-secret")"
  BOT_USERNAME="$(prompt_validated_input \
    is_valid_bot_username \
    "Введите username Telegram без @, 5-32 символа, буквы/цифры/подчеркивание." \
    "Username Telegram-бота" \
    "without @" \
    "my_vpn_bot" \
    "${BOT_USERNAME:-}")"
  BOT_USERNAME="${BOT_USERNAME#@}"
  ADMIN_IDS="$(prompt_validated_input \
    is_valid_admin_ids \
    "Введите один или несколько числовых Telegram ID через запятую." \
    "Telegram ID администраторов" \
    "single ID or comma-separated IDs" \
    "123456789 or 123456789,987654321" \
    "${ADMIN_IDS:-}")"

  REMNAWAVE_API_URL="$(normalize_url "$(prompt_validated_input \
    is_valid_url \
    "Введите корректный URL, например https://panel.example.com" \
    "Remnawave API URL" \
    "https://panel.example.com" \
    "https://panel.example.com" \
    "${REMNAWAVE_API_URL:-}")")"
  REMNAWAVE_API_KEY="$(prompt_validated_input \
    is_nonempty_string \
    "API key Remnawave не может быть пустым." \
    "Remnawave API Key" \
    "raw API key string without Bearer" \
    "your_api_key_here" \
    "${REMNAWAVE_API_KEY:-}" \
    "visible-secret")"
  REMNAWAVE_SECRET_KEY="$(prompt_validated_input \
    is_nonempty_string \
    "Secret key Remnawave не может быть пустым." \
    "Remnawave Secret Key" \
    "secret_name:secret_value" \
    "secret_name:secret_value" \
    "${REMNAWAVE_SECRET_KEY:-}" \
    "visible-secret")"
  REMNAWAVE_WEBHOOK_SECRET="$(prompt_validated_input \
    is_nonempty_string \
    "Webhook secret Remnawave не может быть пустым. Возьмите значение из панели Remnawave." \
    "Remnawave Webhook Secret" \
    "из панели Remnawave" \
    "paste_webhook_secret_here" \
    "${REMNAWAVE_WEBHOOK_SECRET:-}" \
    "visible-secret")"
  REMNAWAVE_AUTH_TYPE="api_key"
  TIMEZONE="${TIMEZONE:-${DEFAULT_TIMEZONE}}"
  DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-ru}"
  APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
  APP_LOGO="${APP_LOGO:-${DEFAULT_APP_LOGO}}"

  BOT_HTTP_PORT="8080"

  WEBHOOK_SECRET_TOKEN="${WEBHOOK_SECRET_TOKEN:-$(generate_hex_secret 64)}"
  WEB_API_DEFAULT_TOKEN="${WEB_API_DEFAULT_TOKEN:-$(generate_hex_secret 64)}"
  CABINET_JWT_SECRET="${CABINET_JWT_SECRET:-$(generate_hex_secret 64)}"
  REMNAWAVE_WEBHOOK_SECRET="${REMNAWAVE_WEBHOOK_SECRET}"

}

print_configuration_summary() {
  cat <<EOF
Сводка конфигурации
-------------------
Корень проекта:     ${PROJECT_ROOT}
Git backend repo:  ${BOT_REPO_URL}
Git cabinet repo:  ${CABINET_REPO_URL}
Домен webhook:      ${HOOK_DOMAIN}
Домен cabinet:      ${APP_DOMAIN}
URL webhook:        ${WEBHOOK_URL}
URL cabinet:        ${CABINET_URL}
Username бота:      ${BOT_USERNAME}
ID администраторов: ${ADMIN_IDS}
Remnawave API URL:  ${REMNAWAVE_API_URL}
Remnawave API Key:  $(mask_secret "${REMNAWAVE_API_KEY}")
Remnawave Secret:   $(mask_secret "${REMNAWAVE_SECRET_KEY}")
Язык:               ${DEFAULT_LANGUAGE}
Название app:       ${APP_NAME}
Логотип app:        ${APP_LOGO}
База PostgreSQL:    ${POSTGRES_DB}
Пользователь PG:    ${POSTGRES_USER}
Пароль PG:          $(mask_secret "${POSTGRES_PASSWORD}")
HTTP-порт бота:     ${BOT_HTTP_PORT}
Версия бота:        ${BOT_VERSION_REF}
Версия cabinet:     ${CABINET_VERSION_REF}
EOF
}

render_bot_env() {
  require_state_file

  # Гарантируем наличие базовых токенов для runtime.
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_hex_secret 64)}"
  WEBHOOK_SECRET_TOKEN="${WEBHOOK_SECRET_TOKEN:-$(generate_hex_secret 64)}"
  WEB_API_DEFAULT_TOKEN="${WEB_API_DEFAULT_TOKEN:-$(generate_hex_secret 64)}"
  CABINET_JWT_SECRET="${CABINET_JWT_SECRET:-$(generate_hex_secret 64)}"
  [[ -n "${REMNAWAVE_WEBHOOK_SECRET:-}" ]] || die "REMNAWAVE_WEBHOOK_SECRET не задан. Укажите его из панели Remnawave в конфигурации."
  if [[ -n "${APP_DOMAIN:-}" ]]; then
    CABINET_URL="https://${APP_DOMAIN}"
    CABINET_ALLOWED_ORIGINS="https://${APP_DOMAIN}"
    WEB_API_ALLOWED_ORIGINS="https://${APP_DOMAIN}"
    MINIAPP_CUSTOM_URL="https://${APP_DOMAIN}"
  fi
  if [[ -n "${HOOK_DOMAIN:-}" ]]; then
    WEBHOOK_URL="https://${HOOK_DOMAIN}"
  fi

  if [[ -f "${BOT_ENV_FILE}" && ! -f "${BOT_OVERRIDE_ENV_FILE}" ]]; then
    [[ -f "${CABINET_ENV_FILE}" ]] || die "Найден legacy bot.env без cabinet.env. Автоматическая миграция остановлена, applied-файлы не изменены."
    local migration_backup
    if [[ -f "${BOT_REPO_DIR}/.env.example" ]]; then
      migration_backup="$(run_python "${INSTALLER_DIR}/lib/installation_config.py" migrate "${STATE_DIR}" "${BOT_REPO_DIR}/.env.example")"
    else
      migration_backup="$(run_python "${INSTALLER_DIR}/lib/installation_config.py" migrate "${STATE_DIR}")"
    fi
    log_info "Legacy environment перенесён. Safety backup: ${migration_backup}"
  fi

  run_python "${INSTALLER_DIR}/lib/installation_config.py" render \
    "${BOT_ENV_FILE}" \
    "${CABINET_ENV_FILE}" \
    "HOOK_DOMAIN=${HOOK_DOMAIN}" \
    "APP_DOMAIN=${APP_DOMAIN}" \
    "BOT_TOKEN=${BOT_TOKEN}" \
    "BOT_USERNAME=${BOT_USERNAME}" \
    "ADMIN_IDS=${ADMIN_IDS}" \
    "DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE}" \
    "TIMEZONE=${TIMEZONE}" \
    "POSTGRES_DB=${POSTGRES_DB}" \
    "POSTGRES_USER=${POSTGRES_USER}" \
    "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
    "REMNAWAVE_API_URL=${REMNAWAVE_API_URL}" \
    "REMNAWAVE_API_KEY=${REMNAWAVE_API_KEY}" \
    "REMNAWAVE_SECRET_KEY=${REMNAWAVE_SECRET_KEY}" \
    "REMNAWAVE_WEBHOOK_SECRET=${REMNAWAVE_WEBHOOK_SECRET}" \
    "WEBHOOK_SECRET_TOKEN=${WEBHOOK_SECRET_TOKEN}" \
    "WEB_API_DEFAULT_TOKEN=${WEB_API_DEFAULT_TOKEN}" \
    "BOT_HTTP_PORT=${BOT_HTTP_PORT}" \
    "CABINET_JWT_SECRET=${CABINET_JWT_SECRET}" \
    "APP_NAME=${APP_NAME}" \
    "APP_LOGO=${APP_LOGO}"
  secure_private_file "${BOT_ENV_FILE}"
  secure_private_file "${CABINET_ENV_FILE}"
  if [[ ! -f "${BOT_OVERRIDE_ENV_FILE}" ]]; then
    (
      umask 077
      : > "${BOT_OVERRIDE_ENV_FILE}"
    )
  fi
  secure_private_file "${BOT_OVERRIDE_ENV_FILE}"
}

render_compose_file() {
  require_state_file

  render_template \
    "${INSTALLER_DIR}/templates/docker-compose.yml.tpl" \
    "${COMPOSE_FILE}" \
    "BOT_REPO_DIR=${BOT_REPO_DIR}" \
    "BOT_ENV_FILE=${BOT_ENV_FILE}" \
    "BOT_OVERRIDE_ENV_FILE=${BOT_OVERRIDE_ENV_FILE}" \
    "BOT_DATA_DIR=${BOT_DATA_DIR}" \
    "BOT_LOGS_DIR=${BOT_LOGS_DIR}" \
    "BOT_UPLOADS_DIR=${BOT_UPLOADS_DIR}" \
    "POSTGRES_DB=${POSTGRES_DB}" \
    "POSTGRES_USER=${POSTGRES_USER}" \
    "POSTGRES_IMAGE=${POSTGRES_IMAGE}" \
    "REDIS_IMAGE=${REDIS_IMAGE}" \
    "BOT_HTTP_PORT=${BOT_HTTP_PORT}"
}

render_caddy_file() {
  require_state_file

  render_template \
    "${INSTALLER_DIR}/templates/bot-stack.caddy.tpl" \
    "${CADDY_CANDIDATE_FILE}" \
    "HOOK_DOMAIN=${HOOK_DOMAIN}" \
    "APP_DOMAIN=${APP_DOMAIN}" \
    "BOT_HTTP_PORT=${BOT_HTTP_PORT}" \
    "BOT_UPLOADS_DIR=${BOT_UPLOADS_DIR}" \
    "CABINET_DIST_DIR=${CABINET_DIST_DIR}"
}

render_all_configs() {
  render_bot_env
  render_compose_file
  render_caddy_file
}

configure_stack() {
  local state_mode="${1:-applied}"
  ensure_root
  collect_configuration
  echo
  print_configuration_summary
  echo
  if ! prompt_yes_no "Сохранить эту конфигурацию?" "y"; then
    die "Конфигурация отменена пользователем."
  fi
  if [[ "${state_mode}" == pending-first-install ]]; then
    prepare_first_install_project
    STATE_FILE="${STATE_DIR}/install.state.pending-first-install"
    RUNTIME_CHANGE_PENDING_STATE_FILE="${STATE_FILE}"
    export RUNTIME_CHANGE_PENDING_STATE_FILE
    write_first_install_marker "${STATE_FILE}"
  elif [[ "${state_mode}" != applied ]]; then
    die "Неизвестный режим сохранения конфигурации: ${state_mode}"
  else
    ensure_directories
    if [[ "${CONFIGURATION_CREATES_PROJECT_ROOT}" == true ]]; then
      printf '%s\n' "created-by-bedolaga-installer" \
        > "${STATE_DIR}/project-root-created-by-installer"
      secure_private_file "${STATE_DIR}/project-root-created-by-installer"
    fi
  fi
  save_state
  if [[ "${state_mode}" == pending-first-install ]]; then
    log_info "Pending configuration сохранена; generated files появятся на apply stage."
  else
    render_all_configs
    log_info "Конфигурация успешно сгенерирована."
    log_info "Сгенерирован кандидат конфига Caddy: ${CADDY_CANDIDATE_FILE}"
  fi
}
