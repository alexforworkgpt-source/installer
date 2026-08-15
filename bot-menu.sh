#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# shellcheck source=lib/migrate.sh
source "${SCRIPT_DIR}/lib/migrate.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"
# shellcheck source=lib/doctor.sh
source "${SCRIPT_DIR}/lib/doctor.sh"
# shellcheck source=lib/config_editor.sh
source "${SCRIPT_DIR}/lib/config_editor.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"

acquire_installer_lock
recover_interrupted_file_recovery \
  || die "Прерванный File Recovery требует ручной проверки Docker/Caddy перед продолжением."
recover_interrupted_runtime_change \
  || die "Прерванный Runtime Change требует ручного восстановления перед продолжением."
recover_pending_migration_bot || die "Сначала остановите контейнер botstack_bot вручную и повторите запуск installer."
recover_completed_migration_restart || true
install_menu_launcher || true
clear_console_screen

MENU_STATE_FILE=""
MENU_PROJECT_ROOT=""
MENU_HOOK_DOMAIN=""
MENU_APP_DOMAIN=""
MENU_BOT_REF=""
MENU_CABINET_REF=""
MENU_LOCAL_API="n/a"
MENU_DOCKER_STATUS="n/a"
MENU_CADDY_STATUS="n/a"
MENU_FIREWALL_STATUS="n/a"
MENU_PENDING_APPLY="n/a"
MENU_FIREWALL_PORTS="n/a"

compact_pending_summary() {
  local value="${1:-}"
  local trimmed
  local count

  case "${value}" in
    ""|n/a) printf '%s' "n/a" ; return 0 ;;
    нет) printf '%s' "нет" ; return 0 ;;
  esac

  trimmed="${value//, /,}"
  count="$(printf '%s' "${trimmed}" | awk -F',' '{print NF}')"
  if [[ "${count}" =~ ^[0-9]+$ ]] && ((count > 0)); then
    printf '%s изменений' "${count}"
  else
    printf '%s' "${value}"
  fi
}

collect_menu_runtime_summary() {
  resolve_state_file

  MENU_DOCKER_STATUS="n/a"
  MENU_CADDY_STATUS="n/a"
  MENU_FIREWALL_STATUS="$(firewall_status)"
  if command_exists systemctl; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      MENU_DOCKER_STATUS="active"
    else
      MENU_DOCKER_STATUS="inactive"
    fi
    if systemctl is-active --quiet caddy 2>/dev/null; then
      MENU_CADDY_STATUS="active"
    else
      MENU_CADDY_STATUS="inactive"
    fi
  fi

  if [[ ! -f "${STATE_FILE}" ]]; then
    MENU_STATE_FILE="не настроен"
    MENU_PROJECT_ROOT="не задан"
    MENU_HOOK_DOMAIN="не задан"
    MENU_APP_DOMAIN="не задан"
    MENU_BOT_REF="не задан"
    MENU_CABINET_REF="не задан"
    MENU_LOCAL_API="n/a"
    MENU_PENDING_APPLY="n/a"
    MENU_FIREWALL_PORTS="$(list_firewall_ports)"
    return 0
  fi

  load_state

  local local_health="n/a"
  if command_exists curl && [[ -n "${BOT_HTTP_PORT:-}" ]]; then
    local_health="$(http_status_code "http://127.0.0.1:${BOT_HTTP_PORT}/cabinet/branding")"
    local_health="${local_health:-n/a}"
  fi

  MENU_STATE_FILE="${STATE_FILE}"
  MENU_PROJECT_ROOT="${PROJECT_ROOT:-не задан}"
  MENU_HOOK_DOMAIN="${HOOK_DOMAIN:-не задан}"
  MENU_APP_DOMAIN="${APP_DOMAIN:-не задан}"
  MENU_BOT_REF="${BOT_VERSION_REF:-не задан}"
  MENU_CABINET_REF="${CABINET_VERSION_REF:-не задан}"
  MENU_LOCAL_API="${local_health}"
  MENU_PENDING_APPLY="$(compact_pending_summary "$(pending_runtime_changes_summary 2>/dev/null || printf '%s' 'n/a')")"
  MENU_FIREWALL_PORTS="$(list_firewall_ports)"
}

menu_info_row() {
  local label="$1"
  local value="$2"
  local color="${3:-${UI_WHITE}}"

  printf '%b%-13s%b %b%s%b' \
    "${UI_GRAY}" "${label}" "${UI_RESET}" \
    "${color}" "${value}" "${UI_RESET}"
}

menu_status_chip() {
  local label="$1"
  local value="$2"
  local color

  color="$(ui_status_color "${value}")"
  printf '%b%s%b %b%s%b' \
    "${UI_GRAY}" "${label}" "${UI_RESET}" \
    "${color}" "${value}" "${UI_RESET}"
}

print_menu_title_box() {
  local title="$1"
  local width
  local content_width
  local line
  local status_color

  width="$(ui_term_width)"
  content_width=$((width - 2))

  collect_menu_runtime_summary

  ui_box_top "${content_width}"
  line="${UI_BOLD}${UI_CYAN}${title}${UI_RESET}"
  ui_box_line "${content_width}" "${line}"
  ui_box_separator "${content_width}"

  line="$(menu_info_row "PROJECT_ROOT:" "${MENU_PROJECT_ROOT}" "${UI_WHITE}")"
  ui_box_line "${content_width}" "${line}"
  line="$(menu_info_row "Hook/App:" "${MENU_HOOK_DOMAIN} ${UI_GRAY}|${UI_RESET} ${MENU_APP_DOMAIN}" "${UI_CYAN}")"
  ui_box_line "${content_width}" "${line}"
  line="$(menu_info_row "Target refs:" "bot=${MENU_BOT_REF} ${UI_GRAY}|${UI_RESET} cabinet=${MENU_CABINET_REF}" "${UI_WHITE}")"
  ui_box_line "${content_width}" "${line}"
  status_color="$(ui_status_color "${MENU_LOCAL_API}")"
  line="$(menu_info_row "Local API:" "${MENU_LOCAL_API}" "${status_color}")"
  ui_box_line "${content_width}" "${line}"
  ui_box_bottom "${content_width}"
}

print_menu_status_box() {
  local width
  local content_width
  local line

  width="$(ui_term_width)"
  content_width=$((width - 2))

  ui_box_top "${content_width}"
  line="${UI_BOLD}${UI_BLUE}Оперативная сводка${UI_RESET}"
  ui_box_line "${content_width}" "${line}"
  ui_box_separator "${content_width}"

  line="$(menu_status_chip "Docker:" "${MENU_DOCKER_STATUS}")   ${UI_GRAY}|${UI_RESET}   $(menu_status_chip "Caddy:" "${MENU_CADDY_STATUS}")   ${UI_GRAY}|${UI_RESET}   $(menu_status_chip "UFW:" "${MENU_FIREWALL_STATUS}")"
  ui_box_line "${content_width}" "${line}"
  line="$(printf '%b%s%b %b%s%b' "${UI_GRAY}" "State:" "${UI_RESET}" "${UI_WHITE}" "${MENU_STATE_FILE}" "${UI_RESET}")"
  ui_box_line "${content_width}" "${line}"
  line="$(printf '%b%s%b %b%s%b' "${UI_GRAY}" "Firewall:" "${UI_RESET}" "${UI_WHITE}" "${MENU_FIREWALL_PORTS}" "${UI_RESET}")"
  ui_box_line "${content_width}" "${line}"
  ui_box_bottom "${content_width}"
  echo
}

print_main_menu_header() {
  print_menu_title_box "$1"
  print_menu_status_box
}

print_submenu_header() {
  print_menu_title_box "$1"
  echo
}

print_menu_header() {
  print_submenu_header "$1"
}

print_menu_section() {
  local title="$1"
  printf '%b[%s]%b\n' "${UI_CYAN}${UI_BOLD}" "${title}" "${UI_RESET}"
}

print_menu_item() {
  local key="$1"
  local label="$2"
  local note="${3:-}"

  printf ' %b[%s]%b %b%s%b\n' "${UI_BLUE}${UI_BOLD}" "${key}" "${UI_RESET}" "${UI_WHITE}" "${label}" "${UI_RESET}"
  if [[ -n "${note}" ]]; then
    printf '     %b%s%b\n' "${UI_GRAY}" "${note}" "${UI_RESET}"
  fi
}

read_menu_choice() {
  local prompt="$1"
  local __resultvar="$2"
  local value
  IFS= read -r -p "$(printf '%b%s%b' "${UI_GREEN}" "${prompt}" "${UI_RESET}")" value
  printf -v "${__resultvar}" '%s' "${value}"
}

installation_menu() {
  while true; do
    clear
    print_submenu_header "Установка"
    print_menu_section "Подготовка"
    print_menu_item "1" "Полная установка" "Подготовка сервера и первый запуск."
    print_menu_item "2" "Проверка сервера" "Docker, Caddy и базовые зависимости."
    print_menu_item "3" "Восстановить служебные файлы" "Подхватывает state из текущей установки."
    print_menu_section "Навигация"
    print_menu_item "4" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-4]: " choice
    echo

    case "${choice}" in
      1) full_install || true ; show_last_runtime_change_result ;;
      2)
        ensure_root
        server_preflight_checks
        ;;
      3) restore_state_from_runtime ;;
      4) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

recovery_menu() {
  while true; do
    clear
    print_submenu_header "Восстановление"
    print_menu_section "Точечный ремонт"
    print_menu_item "1" "Пересоздать служебные конфиги" "Заново создаёт compose и Caddy."
    print_menu_item "2" "Починить Caddy" "Переустановит конфиг веб-прокси."
    print_menu_item "3" "Починить Telegram webhook" "Повторно зарегистрирует webhook."
    print_menu_item "4" "Пересобрать кабинет" "Собирает веб-кабинет заново."
    print_menu_item "5" "Пересобрать только бота" "Трогает только сервис бота."
    print_menu_section "Навигация"
    print_menu_item "6" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-6]: " choice
    echo

    case "${choice}" in
      1) repair_generated_configs ;;
      2) regenerate_caddy_config ;;
      3) repair_telegram_integration ;;
      4) repair_cabinet_assets ;;
      5) repair_bot_service ;;
      6) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

reserve_menu() {
  while true; do
    clear
    print_submenu_header "Резервирование"
    print_menu_section "Создание"
    print_menu_item "1" "Создать быструю точку" "Сохраняет настройки перед изменениями."
    print_menu_item "2" "Создать file backup" "Файлы текущей VPS без PostgreSQL и Redis."
    print_menu_section "Просмотр"
    print_menu_item "3" "Показать быстрые точки"
    print_menu_item "4" "Показать file backups"
    print_menu_section "Восстановление"
    print_menu_item "5" "Восстановить быструю точку" "Возвращает state/env/compose/Caddy candidate из snapshot."
    print_menu_item "6" "Восстановить file backup" "Проверяемый Recovery без PostgreSQL и Redis."
    print_menu_section "Очистка"
    print_menu_item "7" "Очистить быстрые точки"
    print_menu_item "8" "Очистить file backups"
    print_menu_section "Навигация"
    print_menu_item "9" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-9]: " choice
    echo

    case "${choice}" in
      1) create_manual_snapshot ;;
      2) create_manual_backup ;;
      3) print_recent_snapshots ;;
      4) print_recent_backups ;;
      5) restore_snapshot_configs ;;
      6) restore_backup_archive ;;
      7) cleanup_old_snapshots ;;
      8) cleanup_old_backups ;;
      9) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

updates_advanced_menu() {
  while true; do
    clear
    print_submenu_header "Выбор версии"
    print_menu_section "Ручной выбор"
    print_menu_item "1" "Выбрать версию бота"
    print_menu_item "2" "Выбрать версию кабинета"
    print_menu_section "Готовые сценарии"
    print_menu_item "3" "Обновить бота до последнего релиза"
    print_menu_item "4" "Обновить кабинет до последнего релиза"
    print_menu_item "5" "Обновить бота до main"
    print_menu_item "6" "Обновить кабинет до main"
    print_menu_item "7" "Обновить оба до последнего релиза"
    print_menu_item "8" "Обновить оба до main"
    print_menu_section "Навигация"
    print_menu_item "9" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-9]: " choice
    echo

    case "${choice}" in
      1) choose_component_version "bot" ;;
      2) choose_component_version "cabinet" ;;
      3) update_component_to_latest "bot" ;;
      4) update_component_to_latest "cabinet" ;;
      5) update_component_to_main "bot" ;;
      6) update_component_to_main "cabinet" ;;
      7) update_everything_to_latest ;;
      8) update_everything_to_main ;;
      9) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

confirm_expert_update_mode() {
  log_warn "Expert mode не проверяет совместимость независимых Bot/Cabinet версий."
  log_warn "Для production используйте только Release Bundle."
  prompt_typed_confirmation \
    "EXPERT" \
    "Для входа в небезопасный ручной режим"
}

updates_menu() {
  while true; do
    clear
    print_submenu_header "Обновления"
    print_menu_section "Быстрые действия"
    print_menu_item "1" "Обновить всё из Release Bundle" "Совместимые Bot, Cabinet и immutable images."
    print_menu_section "Экспертный режим"
    print_menu_item "2" "Ручной выбор версии" "Без compatibility guarantee; требует подтверждения EXPERT."
    print_menu_section "Навигация"
    print_menu_item "3" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-3]: " choice
    echo

    case "${choice}" in
      1)
        update_from_release_bundle || true
        show_last_runtime_change_result
        if [[ -f "${STATE_DIR}/runtime-change.in-progress" ]]; then
          log_error "Protected Update требует recovery; остальные действия заблокированы."
          return 1
        fi
        ;;
      2)
        if confirm_expert_update_mode; then
          updates_advanced_menu
        else
          log_warn "Expert mode отменён."
        fi
        ;;
      3) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

services_menu() {
  while true; do
    clear
    print_submenu_header "Сервисы"
    print_menu_section "Управление"
    print_menu_item "1" "Развернуть текущую конфигурацию" "Применяет текущие конфиги и поднимает стек."
    print_menu_item "2" "Пересобрать сервисы" "Пересобирает контейнеры."
    print_menu_item "3" "Перезапустить сервисы" "Быстрый перезапуск."
    print_menu_section "Навигация"
    print_menu_item "4" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-4]: " choice
    echo

    case "${choice}" in
      1) deploy_stack || true ; show_last_runtime_change_result ;;
      2) rebuild_stack ;;
      3) restart_stack ;;
      4) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

caddy_menu() {
  while true; do
    clear
    print_submenu_header "Домены и Caddy"
    print_menu_section "Проверка и обслуживание"
    print_menu_item "1" "Проверить домены и SSL" "Проверка доменов и сертификатов."
    print_menu_item "2" "Пересоздать конфиг Caddy"
    print_menu_item "3" "Перезагрузить Caddy"
    print_menu_item "4" "Добавить лендинг" "Создаёт отдельный Caddy snippet."
    print_menu_section "Навигация"
    print_menu_item "5" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-5]: " choice
    echo

    case "${choice}" in
      1) ssl_check ;;
      2) regenerate_caddy_config ;;
      3) reload_caddy ;;
      4) add_landing_site_to_caddy ;;
      5) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

firewall_menu() {
  while true; do
    clear
    print_submenu_header "Firewall"
    print_menu_section "Проверка и обслуживание"
    print_menu_item "1" "Показать статус" "Текущая политика и разрешённые порты UFW."
    print_menu_item "2" "Применить базовые правила" "SSH, HTTP, HTTPS и HTTP/3 без сброса других правил."
    print_menu_item "3" "Проверить защиту" "Проверяет UFW и приватность Bot, PostgreSQL и Redis."
    print_menu_section "Навигация"
    print_menu_item "4" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-4]: " choice
    echo

    case "${choice}" in
      1) print_host_firewall_status ;;
      2) configure_host_firewall ;;
      3)
        verify_host_firewall || die "Базовые правила UFW не прошли проверку."
        verify_private_runtime_ports || die "Найден неожиданный публичный runtime-порт."
        log_info "Firewall и приватные runtime-порты настроены безопасно."
        ;;
      4) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

maintenance_menu() {
  while true; do
    clear
    print_submenu_header "Обслуживание"
    print_menu_section "Контроль"
    print_menu_item "1" "Статус" "Сервисы, домены, webhook и версии."
    print_menu_item "2" "Диагностика" "Расширенная проверка системы."
    print_menu_item "3" "Логи" "Бот, база, Redis, Caddy и установщик."
    print_menu_section "Настройки"
    print_menu_item "4" "Настройки" "Просмотр и редактирование env-файлов."
    print_menu_item "5" "Применить новые настройки" "Применяет только реально изменившееся."
    print_menu_section "Обслуживание"
    print_menu_item "6" "Обновления" "Обновление бота и кабинета."
    print_menu_item "7" "Сервисы" "Развёртывание, пересборка и перезапуск."
    print_menu_item "8" "Восстановление" "Точечный ремонт компонентов."
    print_menu_item "9" "Домены и Caddy" "SSL, Caddy и лендинги."
    print_menu_item "10" "Резервирование" "Быстрые точки и file backups."
    print_menu_item "11" "Firewall" "UFW, публичные и приватные порты."
    print_menu_section "Навигация"
    print_menu_item "12" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-12]: " choice
    echo

    case "${choice}" in
      1) status_stack ;;
      2) doctor_stack ;;
      3) logs_stack ;;
      4) configuration_menu ;;
      5) apply_settings_draft || true ; show_last_runtime_change_result ;;
      6) updates_menu ;;
      7) services_menu ;;
      8) recovery_menu ;;
      9) caddy_menu ;;
      10) reserve_menu ;;
      11) firewall_menu ;;
      12) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

migration_menu() {
  while true; do
    clear
    print_submenu_header "Перенос на другой VPS"
    print_menu_section "Старая VPS"
    print_menu_item "1" "Создать пакет переноса" "Актуальная PostgreSQL, Redis, файлы и точные версии."
    print_menu_section "Новая VPS"
    print_menu_item "2" "Импортировать пакет" "Подготовит чистую VPS, но не запустит бота."
    print_menu_item "3" "Активировать перенесенный проект" "Запуск после переключения DNS и остановки старой VPS."
    print_menu_item "4" "Удалить тестовый импорт" "Очистит только незавершенный перенос и его volumes."
    print_menu_section "Навигация"
    print_menu_item "5" "Назад"
    echo

    read_menu_choice "Выберите пункт [1-5]: " choice
    echo

    case "${choice}" in
      1) create_migration_export ;;
      2) import_migration_archive ;;
      3) activate_migrated_stack ;;
      4) discard_pending_migration ;;
      5) return 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac

    pause
  done
}

main_menu() {
  while true; do
    if [[ -n "${STATE_DIR:-}" && -f "${STATE_DIR}/runtime-change.in-progress" ]]; then
      die "Runtime Change требует recovery. Перезапустите installer для автоматического восстановления."
    fi
    clear
    print_main_menu_header "Установщик Bot Stack"
    print_menu_section "Основные разделы"
    print_menu_item "1" "Установка" "Установка, проверка сервера и восстановление."
    print_menu_item "2" "Обслуживание" "Статус, настройки, обновления и резервирование."
    print_menu_item "3" "Перенос на другой VPS" "Актуальная БД и точная установленная версия."
    print_menu_item "4" "Удаление" "Удаление текущей установки с подтверждением."
    print_menu_item "5" "Выход"
    echo

    read_menu_choice "Выберите раздел [1-5]: " choice
    echo

    case "${choice}" in
      1) installation_menu ;;
      2) maintenance_menu ;;
      3) migration_menu ;;
      4) uninstall_menu ;;
      5) exit 0 ;;
      *) log_warn "Неизвестный пункт: ${choice}" ;;
    esac
  done
}

main_menu
