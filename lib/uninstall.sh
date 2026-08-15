#!/usr/bin/env bash

set -Eeuo pipefail

project_root_looks_safe() {
  [[ -n "${PROJECT_ROOT:-}" ]] || return 1
  [[ "${PROJECT_ROOT}" != "/" ]] || return 1
  [[ "${PROJECT_ROOT}" != "/root" ]] || return 1
  [[ "${PROJECT_ROOT}" != "/etc" ]] || return 1
  [[ "${PROJECT_ROOT}" != "/usr" ]] || return 1
  [[ "${PROJECT_ROOT}" != "/var" ]] || return 1
  [[ "${PROJECT_ROOT}" == /opt/* || "${PROJECT_ROOT}" == /srv/* || "${PROJECT_ROOT}" == /home/* ]]
}

stop_compose_stack() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose_cmd down --remove-orphans "$@"
  else
    log_warn "Compose-файл не найден, пропускаю остановку контейнеров."
  fi
}

remove_caddy_installation() {
  if [[ -f "${CADDY_SNIPPET_FILE}" ]]; then
    rm -f "${CADDY_SNIPPET_FILE}"
    reload_caddy || true
  fi
}

delete_telegram_webhook_if_requested() {
  require_state_file
  [[ -n "${BOT_TOKEN:-}" ]] || return 0

  if prompt_yes_no "Удалить Telegram webhook перед удалением?" "y"; then
    curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" \
      --data "drop_pending_updates=true" >/dev/null || true
    log_info "Telegram webhook удалён."
  fi
}

uninstall_stack_only() {
  ensure_root
  require_state_file

  log_warn "Будут остановлены и удалены контейнеры проекта, но данные и конфиги останутся."
  prompt_typed_confirmation "DELETE_STACK" "Подтверждение." || die "Удаление отменено."

  delete_telegram_webhook_if_requested
  stop_compose_stack
  log_info "Стек удалён. Данные и конфиги сохранены."
}

uninstall_stack_and_runtime() {
  ensure_root
  require_state_file

  log_warn "Будут удалены контейнеры, volumes, runtime-данные и сгенерированные env/compose/caddy-файлы."
  prompt_typed_confirmation "DELETE_DATA" "Подтверждение." || die "Удаление отменено."

  delete_telegram_webhook_if_requested
  stop_compose_stack -v
  remove_caddy_installation
  safe_rm_rf_under "${PROJECT_ROOT}" "${RUNTIME_DIR}"
  safe_rm_rf_under "${PROJECT_ROOT}" "${STATE_DIR}"
  safe_rm_rf_under "${PROJECT_ROOT}" "${RELEASES_DIR}"
  rm -f "${LEGACY_STATE_FILE}"
  log_info "Стек и runtime-данные удалены. Installer сохранён."
}

full_uninstall_keep_installer() {
  ensure_root
  require_state_file

  project_root_looks_safe || die "PROJECT_ROOT выглядит небезопасно для полного удаления: ${PROJECT_ROOT}"

  log_warn "Будут удалены все файлы развёрнутого проекта, кроме директории installer."
  prompt_typed_confirmation "WIPE_PROJECT" "Подтверждение." || die "Удаление отменено."

  delete_telegram_webhook_if_requested
  stop_compose_stack -v
  remove_caddy_installation
  rm -rf "${PROJECT_ROOT}"
  rm -f "${STATE_FILE}" "${LEGACY_STATE_FILE}"
  log_info "Полное удаление выполнено. Installer сохранён."
}

uninstall_menu() {
  ensure_root
  require_state_file

  while true; do
    clear
    print_menu_header "Удаление"
    print_menu_section "Опасные действия"
    print_menu_item "1" "Удалить только стек" "Остановит и удалит контейнеры, но оставит данные и конфиги."
    print_menu_item "2" "Удалить стек и runtime-данные" "Удалит контейнеры, volumes, runtime и сгенерированные файлы."
    print_menu_item "3" "Полное удаление установки" "Удалит весь развёрнутый проект, кроме каталога installer."
    echo
    print_menu_section "Навигация"
    print_menu_item "4" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-4]: " choice
    echo

    case "${choice}" in
      1) uninstall_stack_only ;;
      2) uninstall_stack_and_runtime ;;
      3) full_uninstall_keep_installer ;;
      4) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}
