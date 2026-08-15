#!/usr/bin/env bash

set -Eeuo pipefail

sync_bot_username_from_cabinet_env() {
  require_state_file
  [[ -f "${CABINET_ENV_FILE}" ]] || return 0
  [[ -f "${BOT_ENV_FILE}" ]] || return 0
  run_env_helper sync-bot-username "${CABINET_ENV_FILE}" "${BOT_ENV_FILE}"
}

sync_state_from_env_files() {
  require_state_file
  [[ -f "${BOT_ENV_FILE}" ]] || return 0

  local cabinet_env_file="${CABINET_ENV_FILE}"
  local applied_postgres_db="${POSTGRES_DB}"
  local applied_postgres_user="${POSTGRES_USER}"
  local applied_postgres_password="${POSTGRES_PASSWORD}"
  [[ -f "${cabinet_env_file}" ]] || cabinet_env_file=""

  sync_bot_username_from_cabinet_env

  # Обновляем install.state по фактическим значениям в env-файлах.
  eval "$(run_env_helper state-updates "${BOT_ENV_FILE}" "${cabinet_env_file}")"

  if [[ "${POSTGRES_DB}" != "${applied_postgres_db}" \
    || "${POSTGRES_USER}" != "${applied_postgres_user}" \
    || "${POSTGRES_PASSWORD}" != "${applied_postgres_password}" ]]; then
    POSTGRES_DB="${applied_postgres_db}"
    POSTGRES_USER="${applied_postgres_user}"
    POSTGRES_PASSWORD="${applied_postgres_password}"
    die "Параметры существующей PostgreSQL нельзя менять через редактор env. Используйте отдельную операцию ротации credentials."
  fi

  if [[ -n "${RUNTIME_CHANGE_PENDING_STATE_FILE:-}" ]]; then
    local applied_state_file="${STATE_FILE}"
    STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE_FILE}"
    save_state
    STATE_FILE="${applied_state_file}"
  else
    save_state
  fi
}

show_current_configuration() {
  require_state_file
  print_configuration_summary
}

prepare_settings_draft() {
  require_state_file
  run_python "${INSTALLER_DIR}/lib/installation_config.py" create-draft "${STATE_DIR}" >/dev/null
}

show_settings_draft_plan() {
  require_state_file
  if [[ ! -d "${STATE_DIR}/draft" ]]; then
    log_info "Черновик настроек ещё не создан."
    return 0
  fi

  local plan
  plan="$(run_python "${INSTALLER_DIR}/lib/installation_config.py" plan-draft "${STATE_DIR}")"
  if [[ -z "${plan}" ]]; then
    log_info "Черновик не содержит изменений."
    return 0
  fi

  echo "План изменений"
  echo "---------------"
  printf '%s\n' "${plan}"
}

discard_settings_draft() {
  require_state_file
  local draft_dir="${STATE_DIR}/draft"
  if [[ ! -d "${draft_dir}" ]]; then
    log_info "Черновик настроек не найден."
    return 0
  fi
  safe_rm_rf_under "${STATE_DIR}" "${draft_dir}"
  log_info "Черновик настроек удалён."
}

apply_settings_draft() {
  ensure_root
  require_state_file
  if [[ ! -d "${STATE_DIR}/draft" ]]; then
    log_info "Черновик не найден. Проверяю изменения applied-файлов для обратной совместимости."
    apply_config_changes || return 1
    return 0
  fi

  local plan
  plan="$(run_python "${INSTALLER_DIR}/lib/installation_config.py" plan-draft "${STATE_DIR}")"
  if [[ -z "${plan}" ]]; then
    log_info "Черновик не содержит изменений."
    discard_settings_draft
    return 0
  fi

  echo "План изменений"
  echo "---------------"
  printf '%s\n' "${plan}"
  echo
  if ! prompt_yes_no "Применить этот черновик?" "n"; then
    log_info "Применение черновика отменено. Applied-конфигурация не изменена."
    return 0
  fi

  local result_json
  local runtime_change_adapter="${RUNTIME_CHANGE_ADAPTER:-${INSTALLER_DIR}/lib/runtime_change_adapter.sh}"
  result_json="$(run_python \
    "${INSTALLER_DIR}/lib/runtime_change.py" run-command \
    "apply settings draft" \
    "$(installer_log_file)" \
    -- \
    "${BASH:-bash}" "${runtime_change_adapter}" settings "${STATE_DIR}")" \
    || return 1
  persist_runtime_change_result_json "${result_json}" || return 1

  case "${LAST_RUNTIME_CHANGE_OUTCOME}" in
    committed)
      log_info "Runtime Change committed: настройки применены и проверены."
      ;;
    rolled_back)
      log_warn "Runtime Change rolled back: предыдущая конфигурация восстановлена и проверена."
      ;;
    safely_stopped)
      log_error "Runtime Change safely stopped: ${LAST_RUNTIME_CHANGE_SAFE_NEXT_ACTION}"
      ;;
  esac
}

alter_postgres_role_password() {
  local password="$1"
  local escaped_password="${password//\\/\\\\}"
  escaped_password="${escaped_password//\'/\'\'}"
  {
    printf '\\set role_name %s\n' "${POSTGRES_USER}"
    printf "\\set role_password '%s'\n" "${escaped_password}"
    printf 'ALTER ROLE :"role_name" WITH PASSWORD :\x27role_password\x27;\n'
  } | compose_cmd exec -T postgres \
    psql -v ON_ERROR_STOP=1 \
      -U "${POSTGRES_USER}" \
      -d "${POSTGRES_DB}" >/dev/null
}

verify_postgres_role_password() {
  local password="$1"
  printf '%s\n' "${password}" \
    | compose_cmd exec -T postgres sh -c '
        IFS= read -r PGPASSWORD
        export PGPASSWORD
        exec psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d "$2" -c "SELECT 1;"
      ' sh "${POSTGRES_USER}" "${POSTGRES_DB}" >/dev/null
}

rotate_postgres_credentials_runtime() {
  ensure_root
  require_state_file
  prompt_yes_no "Сгенерировать и применить новый пароль PostgreSQL?" "n" || {
    log_info "Ротация PostgreSQL credentials отменена."
    return 0
  }

  local new_password
  local context_file
  local result_json
  local runtime_change_adapter="${RUNTIME_CHANGE_ADAPTER:-${INSTALLER_DIR}/lib/runtime_change_adapter.sh}"
  new_password="$(generate_hex_secret 64)"
  context_file="$(mktemp "${STATE_DIR}/.postgres-rotation.XXXXXX")" || return 1
  cleanup_postgres_rotation_context() {
    rm -f "${context_file:-}"
  }
  trap cleanup_postgres_rotation_context RETURN
  (
    umask 077
    printf '%s\n' "${new_password}" > "${context_file}"
  ) || {
    rm -f "${context_file}"
    return 1
  }
  secure_private_file "${context_file}" || {
    rm -f "${context_file}"
    return 1
  }

  local result_status=0
  if result_json="$(run_python \
    "${INSTALLER_DIR}/lib/runtime_change.py" run-command \
    "rotate PostgreSQL credentials" \
    "$(installer_log_file)" \
    -- \
    "${BASH:-bash}" "${runtime_change_adapter}" \
    postgres-rotation "${STATE_DIR}" "${context_file}")"; then
    :
  else
    result_status=$?
  fi
  ((result_status == 0)) || return "${result_status}"
  persist_runtime_change_result_json "${result_json}" || return 1

  case "${LAST_RUNTIME_CHANGE_OUTCOME}" in
    committed) log_info "Runtime Change committed: PostgreSQL credentials обновлены." ;;
    rolled_back) log_warn "Runtime Change rolled back: прежние PostgreSQL credentials восстановлены." ;;
    safely_stopped) log_error "Runtime Change safely stopped: ${LAST_RUNTIME_CHANGE_SAFE_NEXT_ACTION}" ;;
  esac
  trap - RETURN
  cleanup_postgres_rotation_context
}

env_editor_menu() {
  require_state_file
  prepare_settings_draft

  while true; do
    clear
    print_menu_header "Настройки"
    print_menu_section "Редактирование env"
    print_menu_item "1" "Открыть черновик bot.env" "Applied-файл не изменится до явного применения."
    print_menu_item "2" "Открыть черновик cabinet.env" "Applied-файл не изменится до явного применения."
    print_menu_item "3" "Открыть advanced override" "Опциональные настройки Bot с повышенным приоритетом."
    echo
    print_menu_section "Навигация"
    print_menu_item "4" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-4]: " choice
    echo

    case "${choice}" in
      1)
        open_file_in_editor "${STATE_DIR}/draft/bot.env"
        ;;
      2)
        open_file_in_editor "${STATE_DIR}/draft/cabinet.env"
        ;;
      3)
        open_file_in_editor "${STATE_DIR}/draft/bot.override.env"
        ;;
      4) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

configuration_menu() {
  ensure_root
  require_state_file

  while true; do
    clear
    print_menu_header "Настройки"
    print_menu_section "Просмотр и изменение"
    print_menu_item "1" "Текущие параметры" "Показывает сводку активной конфигурации."
    print_menu_item "2" "Редактор env" "Открывает bot.env и cabinet.env."
    print_menu_item "3" "Показать план изменений" "Секреты в плане скрыты."
    print_menu_item "4" "Применить черновик" "Показывает план и запрашивает подтверждение."
    print_menu_item "5" "Удалить черновик" "Applied-конфигурация останется без изменений."
    print_menu_item "6" "Сменить пароль PostgreSQL" "Отдельная проверяемая ротация credentials."
    echo
    print_menu_section "Навигация"
    print_menu_item "7" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-7]: " choice
    echo

    case "${choice}" in
      1)
        show_current_configuration
        pause
        ;;
      2) env_editor_menu ;;
      3) show_settings_draft_plan ; pause ;;
      4) apply_settings_draft || true ; show_last_runtime_change_result ;;
      5) discard_settings_draft ; pause ;;
      6) rotate_postgres_credentials_runtime || true ; show_last_runtime_change_result ; pause ;;
      7) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ; pause ;;
    esac
  done
}
