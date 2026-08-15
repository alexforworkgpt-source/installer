#!/usr/bin/env bash

set -Eeuo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_STATE_FILE="${INSTALLER_DIR}/state/install.state"
LAST_PROJECT_ROOT_FILE="${INSTALLER_DIR}/state/last_project_root"
GLOBAL_INSTALLER_STATE_DIR="${INSTALLER_GLOBAL_STATE_DIR:-/var/lib/bedolaga-installer}"
GLOBAL_LAST_PROJECT_ROOT_FILE="${GLOBAL_INSTALLER_STATE_DIR}/last_project_root"
STATE_FILE="/opt/bot-stack/state/install.state"
ENV_HELPER="${INSTALLER_DIR}/lib/env_helper.py"
RECOVERY_HELPER="${INSTALLER_DIR}/lib/recovery.py"
RECOVERY_RUNTIME_ADAPTER="${INSTALLER_DIR}/lib/recovery_runtime.sh"

DEFAULT_PROJECT_ROOT="/opt/bot-stack"
DEFAULT_BOT_REPO_URL="https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git"
DEFAULT_CABINET_REPO_URL="https://github.com/BEDOLAGA-DEV/bedolaga-cabinet.git"
DEFAULT_TIMEZONE="Europe/Moscow"
DEFAULT_LANGUAGE="ru"
DEFAULT_POSTGRES_DB="remnawave_bot"
DEFAULT_POSTGRES_USER="remnawave_user"
DEFAULT_POSTGRES_PASSWORD=""
DEFAULT_POSTGRES_IMAGE="postgres:15-alpine"
DEFAULT_REDIS_URL="redis://redis:6379/0"
DEFAULT_REDIS_IMAGE="redis:7-alpine"
DEFAULT_BOT_HTTP_PORT="8080"
DEFAULT_APP_NAME="Bot Service"
DEFAULT_APP_LOGO="B"
DEFAULT_CURL_CONNECT_TIMEOUT="5"
DEFAULT_CURL_MAX_TIME="20"
DEFAULT_MENU_LAUNCHER_PATH="/usr/local/bin/vpn"
DEFAULT_INSTALLER_HOME="/opt/bedolaga-installer"

UI_RESET=""
UI_BOLD=""
UI_DIM=""
UI_BLUE=""
UI_CYAN=""
UI_GREEN=""
UI_YELLOW=""
UI_RED=""
UI_WHITE=""
UI_GRAY=""

ui_init() {
  local use_color="false"

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    case "${TERM:-}" in
      ""|dumb) use_color="false" ;;
      *) use_color="true" ;;
    esac
  fi

  if [[ "${use_color}" == "true" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_BLUE=$'\033[38;5;75m'
    UI_CYAN=$'\033[38;5;117m'
    UI_GREEN=$'\033[38;5;114m'
    UI_YELLOW=$'\033[38;5;180m'
    UI_RED=$'\033[38;5;174m'
    UI_WHITE=$'\033[38;5;252m'
    UI_GRAY=$'\033[38;5;244m'
  else
    UI_RESET=""
    UI_BOLD=""
    UI_DIM=""
    UI_BLUE=""
    UI_CYAN=""
    UI_GREEN=""
    UI_YELLOW=""
    UI_RED=""
    UI_WHITE=""
    UI_GRAY=""
  fi
}

ui_term_width() {
  local width="${COLUMNS:-}"
  if [[ -z "${width}" || ! "${width}" =~ ^[0-9]+$ ]]; then
    width="$(tput cols 2>/dev/null || true)"
  fi
  if [[ -z "${width}" || ! "${width}" =~ ^[0-9]+$ ]]; then
    width=80
  fi
  if ((width < 60)); then
    width=60
  elif ((width > 100)); then
    width=100
  fi
  printf '%s' "${width}"
}

ui_repeat() {
  local char="$1"
  local count="$2"
  local result=""
  while ((${#result} < count)); do
    result+="${char}"
  done
  printf '%s' "${result:0:count}"
}

ui_strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

ui_visible_length() {
  local value="$1"
  printf '%s' "${value}" | ui_strip_ansi | wc -m | tr -d '[:space:]'
}

ui_pad_right() {
  local value="$1"
  local target_width="$2"
  local visible_length
  local padding=0

  visible_length="$(ui_visible_length "${value}")"
  if ((visible_length < target_width)); then
    padding=$((target_width - visible_length))
  fi

  printf '%s%s' "${value}" "$(printf '%*s' "${padding}" '')"
}

ui_status_color() {
  local value="${1:-}"
  case "${value}" in
    OK|active|активен|200|healthy|нет) printf '%s' "${UI_GREEN}" ;;
    FAIL|inactive|неактивен|000|n/a) printf '%s' "${UI_RED}" ;;
    *) printf '%s' "${UI_YELLOW}" ;;
  esac
}

ui_box_top() {
  local width="$1"
  printf '%b┌%s┐%b\n' "${UI_BLUE}" "$(ui_repeat '─' "${width}")" "${UI_RESET}"
}

ui_box_separator() {
  local width="$1"
  printf '%b├%s┤%b\n' "${UI_BLUE}" "$(ui_repeat '─' "${width}")" "${UI_RESET}"
}

ui_box_bottom() {
  local width="$1"
  printf '%b└%s┘%b\n' "${UI_BLUE}" "$(ui_repeat '─' "${width}")" "${UI_RESET}"
}

ui_box_line() {
  local width="$1"
  local content="${2:-}"
  local visible_length
  local padding=0

  visible_length="$(ui_visible_length "${content}")"
  if ((visible_length + 2 < width)); then
    padding=$((width - visible_length - 2))
  fi

  printf '%b│%b %s%*s %b│%b\n' \
    "${UI_BLUE}" \
    "${UI_RESET}" \
    "${content}" \
    "${padding}" \
    "" \
    "${UI_BLUE}" \
    "${UI_RESET}"
}

ui_render_kv_box() {
  local title="$1"
  shift
  local width
  local content_width
  local line
  local entry
  local label
  local value

  width="$(ui_term_width)"
  content_width=$((width - 2))

  ui_box_top "${content_width}"
  line="${UI_BOLD}${UI_CYAN}${title}${UI_RESET}"
  ui_box_line "${content_width}" "${line}"
  ui_box_separator "${content_width}"

  for entry in "$@"; do
    label="${entry%%=*}"
    value="${entry#*=}"
    line="$(printf '%b%-18s%b %b%s%b' "${UI_GRAY}" "${label}" "${UI_RESET}" "${UI_WHITE}" "${value}" "${UI_RESET}")"
    ui_box_line "${content_width}" "${line}"
  done

  ui_box_bottom "${content_width}"
}

ui_render_status_row() {
  local title="$1"
  local value="$2"
  local color

  color="$(ui_status_color "${value}")"
  printf '%b%-42s%b %b%s%b\n' \
    "${UI_GRAY}" "${title}" "${UI_RESET}" \
    "${color}" "${value}" "${UI_RESET}"
}

ui_init

installer_log_file() {
  local base_dir
  if [[ -n "${STATE_DIR:-}" ]]; then
    base_dir="${STATE_DIR}"
  else
    base_dir="${INSTALLER_DIR}/state"
  fi
  printf '%s' "${base_dir}/installer.log"
}

record_runtime_change_result() {
  local name="$1"
  local outcome="$2"
  local failed_stage="${3:--}"
  local error="${4:--}"
  local rollback_verified="${5:-false}"
  local safe_next_action="$6"
  local log_reference="${7:--}"

  local result_json
  result_json="$(run_python \
    "${INSTALLER_DIR}/lib/runtime_change.py" result \
    "${name}" \
    "${outcome}" \
    "${failed_stage:-}" \
    "${error:-}" \
    "${rollback_verified}" \
    "${safe_next_action}" \
    "${log_reference:-}")" || return 1
  persist_runtime_change_result_json "${result_json}"
}

persist_runtime_change_result_json() {
  local result_json="$1"
  local assignments

  assignments="$(printf '%s' "${result_json}" \
    | run_python "${INSTALLER_DIR}/lib/runtime_change.py" shell-assignments)" \
    || return 1
  eval "${assignments}"

  local result_state_dir="${STATE_DIR:-${INSTALLER_DIR}/state}"
  if mkdir -p "${result_state_dir}"; then
    local result_file="${result_state_dir}/last-runtime-change.json"
    local result_temp="${result_file}.tmp"
    (
      umask 077
      printf '%s\n' "${LAST_RUNTIME_CHANGE_RESULT}" > "${result_temp}"
    )
    mv -f "${result_temp}" "${result_file}"
    secure_private_file "${result_file}"
  fi
}

show_last_runtime_change_result() {
  local result_file="${STATE_DIR:-${INSTALLER_DIR}/state}/last-runtime-change.json"

  [[ -f "${result_file}" ]] || return 0
  echo
  echo "Результат Runtime Change"
  echo "------------------------"
  run_python "${INSTALLER_DIR}/lib/runtime_change.py" show "${result_file}"
}

recover_interrupted_runtime_change() {
  local marker_file
  local operation
  local recovery_point
  local context_file
  local adapter="${RUNTIME_CHANGE_ADAPTER:-${INSTALLER_DIR}/lib/runtime_change_adapter.sh}"
  local protected_update_adapter="${PROTECTED_UPDATE_ADAPTER:-${INSTALLER_DIR}/lib/protected_update_adapter.sh}"
  local adapter_command=()

  resolve_state_file
  if [[ ! -f "${STATE_FILE}" ]]; then
    marker_file="$(dirname "${STATE_FILE}")/runtime-change.in-progress"
    if [[ -f "${marker_file}" ]]; then
      operation="$(awk -F= '$1 == "operation" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
      if [[ "${operation}" == first-install ]] \
        && declare -F cleanup_failed_first_install >/dev/null; then
        PROJECT_ROOT="$(dirname "$(dirname "${STATE_FILE}")")"
        reset_project_root_paths
        set_runtime_paths
        recovery_point="$(awk -F= '$1 == "recovery_point" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
        if [[ "${recovery_point}" == committing ]] \
          && declare -F recover_first_install_commit >/dev/null \
          && recover_first_install_commit; then
          record_runtime_change_result \
            "recover interrupted first install" "committed" "commit" \
            "Первая установка была проверена и committed после прерывания." "false" \
            "Дополнительные действия не требуются." "$(installer_log_file)"
          sync -f "${STATE_DIR}/last-runtime-change.json"
          sync -f "${STATE_DIR}"
          finalize_first_install_commit
          return 0
        fi
        if cleanup_failed_first_install; then
          record_runtime_change_result \
            "recover interrupted first install" "rolled_back" "apply" \
            "Прерванная первая установка удалена до commit applied state." "true" \
            "Повторите установку с Release Bundle." "$(installer_log_file)"
          return 0
        fi
      fi
      log_error "Найден Runtime Change marker без install.state: ${marker_file}."
      return 1
    fi
    return 0
  fi
  load_state
  marker_file="${STATE_DIR}/runtime-change.in-progress"
  [[ -f "${marker_file}" ]] || return 0

  operation="$(awk -F= '$1 == "operation" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  recovery_point="$(awk -F= '$1 == "recovery_point" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  context_file="$(awk -F= '$1 == "context_file" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  [[ -n "${operation}" && -n "${recovery_point}" ]] || return 1

  if [[ "${operation}" == first-install ]]; then
    if [[ "${recovery_point}" == committing ]] \
      && declare -F recover_first_install_commit >/dev/null \
      && recover_first_install_commit; then
      record_runtime_change_result \
        "recover interrupted first install" "committed" "commit" \
        "Первая установка была проверена и committed после прерывания." "false" \
        "Дополнительные действия не требуются." "$(installer_log_file)"
      sync -f "${STATE_DIR}/last-runtime-change.json"
      sync -f "${STATE_DIR}"
      finalize_first_install_commit
      return 0
    fi
    if declare -F cleanup_failed_first_install >/dev/null \
      && cleanup_failed_first_install; then
      record_runtime_change_result \
        "recover interrupted first install" "rolled_back" "apply" \
        "Прерванная первая установка удалена до commit applied state." "true" \
        "Повторите установку с Release Bundle." "$(installer_log_file)"
      return 0
    fi
    return 1
  fi

  if [[ "${operation}" == protected-update ]]; then
    local migration_policy
    local previous_release
    local before_revision
    local protected_command
    [[ -d "${context_file}" ]] || return 1
    path_is_under "${STATE_DIR}" "${context_file}" || return 1
    [[ "$(dirname "${context_file}")" == "${STATE_DIR}" ]]
    [[ "$(basename "${context_file}")" == .protected-update.* ]]
    migration_policy="$(<"${context_file}/migration-policy" tr -d '\n')" || return 1
    previous_release="$(<"${context_file}/previous-release-key" tr -d '\n')" || return 1
    protected_command=(
      "${BASH:-bash}" "${protected_update_adapter}" "${STATE_DIR}" "${context_file}"
    )

    if [[ "${recovery_point}" == committed ]]; then
      if "${protected_command[@]}" verify-commit; then
        record_runtime_change_result \
          "recover interrupted protected update" "committed" "commit" \
          "Runtime был committed до прерывания; receipt проверен." "false" \
          "Дополнительные действия не требуются." "$(installer_log_file)"
        sync -f "${STATE_DIR}/last-runtime-change.json"
        sync -f "${STATE_DIR}"
        "${protected_command[@]}" finalize-commit || return 1
        safe_rm_rf_under "${STATE_DIR}" "${context_file}"
        return 0
      fi
    fi
    if [[ "${recovery_point}" == protection-aborted ]]; then
      if "${protected_command[@]}" verify-aborted; then
        record_runtime_change_result \
          "recover interrupted protected update" "rolled_back" "protect" \
          "Protection не завершилась; предыдущий runtime восстановлен и проверен." "true" \
          "Проверьте статус и повторите update." "$(installer_log_file)"
        sync -f "${STATE_DIR}/last-runtime-change.json"
        sync -f "${STATE_DIR}"
        "${protected_command[@]}" finalize-terminal protection-aborted || return 1
        safe_rm_rf_under "${STATE_DIR}" "${context_file}"
        return 0
      fi
    fi
    if [[ "${recovery_point}" == rolled-back ]]; then
      before_revision="$(<"${context_file}/before-revision" tr -d '\n')" || return 1
      local completed_dump
      completed_dump="$(<"${context_file}/dump-reference" tr -d '\n')" || return 1
      if "${protected_command[@]}" verify-rollback \
        "${previous_release}" "${before_revision}" "${completed_dump}"; then
        record_runtime_change_result \
          "recover interrupted protected update" "rolled_back" "verify_rollback" \
          "Rollback был завершён до прерывания; terminal receipt сохранён." "true" \
          "Проверьте статус перед повтором update." "$(installer_log_file)"
        sync -f "${STATE_DIR}/last-runtime-change.json"
        sync -f "${STATE_DIR}"
        "${protected_command[@]}" finalize-terminal rolled-back || return 1
        safe_rm_rf_under "${STATE_DIR}" "${context_file}"
        return 0
      fi
    fi
    if [[ "${recovery_point}" == pending-dump ]]; then
      if "${protected_command[@]}" abort-protection; then
        record_runtime_change_result \
          "recover interrupted protected update" "rolled_back" "protect" \
          "Protection была прервана до создания PostgreSQL dump; предыдущий runtime восстановлен." "true" \
          "Проверьте статус и повторите update." "$(installer_log_file)"
        sync -f "${STATE_DIR}/last-runtime-change.json"
        sync -f "${STATE_DIR}"
        "${protected_command[@]}" finalize-terminal protection-aborted || return 1
        safe_rm_rf_under "${STATE_DIR}" "${context_file}"
        return 0
      fi
      "${protected_command[@]}" safe-stop >/dev/null 2>&1 || return 1
      return 1
    fi

    if [[ "${migration_policy}" == forward-only ]]; then
      "${protected_command[@]}" safe-stop >/dev/null 2>&1 || return 1
      record_runtime_change_result \
        "recover interrupted protected update" "safely_stopped" "apply" \
        "Forward-only update был прерван; автоматический rollback запрещён." "false" \
        "Завершите совместимую forward migration либо вручную восстановите dump и предыдущий release." \
        "$(installer_log_file)"
      return 1
    fi
    [[ "${migration_policy}" == rollback-compatible ]] || return 1
    before_revision="$(<"${context_file}/before-revision" tr -d '\n')" || return 1

    log_warn "Обнаружен прерванный Protected Update. Выполняю проверяемый rollback."
    if "${protected_command[@]}" rollback-release "${previous_release}" "${recovery_point}" \
      && "${protected_command[@]}" restore-dump "${recovery_point}" "${before_revision}" \
      && "${protected_command[@]}" verify-rollback \
        "${previous_release}" "${before_revision}" "${recovery_point}"; then
      record_runtime_change_result \
        "recover interrupted protected update" "rolled_back" "apply" \
        "Прерванный update автоматически восстановлен из verified PostgreSQL dump." "true" \
        "Проверьте статус перед повтором update." "$(installer_log_file)"
      sync -f "${STATE_DIR}/last-runtime-change.json"
      sync -f "${STATE_DIR}"
      "${protected_command[@]}" finalize-terminal rolled-back || return 1
      safe_rm_rf_under "${STATE_DIR}" "${context_file}"
      return 0
    fi

    "${protected_command[@]}" safe-stop >/dev/null 2>&1 || return 1
    record_runtime_change_result \
      "recover interrupted protected update" "safely_stopped" "verify_rollback" \
      "Автоматический rollback Protected Update не прошёл проверку." "false" \
      "Оставьте Bot остановленным; восстановите ${recovery_point}, release ${previous_release} и revision ${before_revision}." \
      "$(installer_log_file)"
    return 1
  fi

  case "${operation}" in
    settings)
      adapter_command=("${BASH:-bash}" "${adapter}" settings "${STATE_DIR}")
      ;;
    deploy)
      adapter_command=("${BASH:-bash}" "${adapter}" deploy "${STATE_DIR}")
      ;;
    postgres-rotation)
      adapter_command=("${BASH:-bash}" "${adapter}" postgres-rotation "${STATE_DIR}" "${context_file}")
      ;;
    *) return 1 ;;
  esac

  log_warn "Обнаружен прерванный Runtime Change (${operation}). Выполняю rollback."
  if "${adapter_command[@]}" rollback "${recovery_point}" \
    && "${adapter_command[@]}" verify-rollback "${recovery_point}"; then
    rm -f "${context_file}"
    record_runtime_change_result \
      "recover interrupted ${operation}" "rolled_back" "apply" \
      "Runtime Change был прерван и автоматически восстановлен." "true" \
      "Проверьте статус и диагностику перед повтором операции." "$(installer_log_file)"
    return 0
  fi

  "${adapter_command[@]}" safe-stop >/dev/null 2>&1 || return 1
  record_runtime_change_result \
    "recover interrupted ${operation}" "safely_stopped" "verify_rollback" \
    "Автоматический rollback прерванного Runtime Change не прошёл проверку." "false" \
    "Восстановите snapshot ${recovery_point} вручную перед запуском Bot." \
    "$(installer_log_file)"
}

append_installer_log() {
  local level="$1"
  shift
  local log_file
  local timestamp

  log_file="$(installer_log_file)"
  mkdir -p "$(dirname "${log_file}")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || true)"
  printf '[%s] [%s] %s\n' "${timestamp:-unknown-time}" "${level}" "$*" >> "${log_file}" 2>/dev/null || true
  secure_private_file "${log_file}"
}

log_info() {
  append_installer_log "INFO" "$*"
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  append_installer_log "WARN" "$*"
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  append_installer_log "ERROR" "$*"
  printf '[ERROR] %s\n' "$*" >&2
}

mask_secret() {
  local value="${1:-}"
  local length="${#value}"

  if ((length == 0)); then
    printf '%s' "-"
  elif ((length <= 8)); then
    printf '%s' "********"
  else
    printf '%s***%s' "${value:0:4}" "${value: -4}"
  fi
}

die() {
  log_error "$*"
  exit 1
}

acquire_installer_lock() {
  local lock_file="${INSTALLER_DIR}/state/installer.lock"

  if ! command_exists flock; then
    log_warn "flock не найден. Защита от параллельного запуска installer отключена."
    return 0
  fi

  mkdir -p "$(dirname "${lock_file}")"
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    die "Другой экземпляр installer уже запущен. Повторите позже."
  fi
}

pause() {
  echo
  read -r -p "Нажмите Enter для продолжения..." _
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Запустите скрипт от root или через sudo."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

firewall_status() {
  local status_output=""

  if ! command_exists ufw; then
    printf '%s' "not-installed"
    return 0
  fi

  status_output="$(LC_ALL=C ufw status 2>/dev/null || true)"
  if grep -Fq "Status: active" <<<"${status_output}"; then
    printf '%s' "active"
  elif grep -Fq "Status: inactive" <<<"${status_output}"; then
    printf '%s' "inactive"
  else
    printf '%s' "n/a"
  fi
}

list_firewall_ports() {
  local status_output=""
  local ports=""

  if ! command_exists ufw; then
    printf '%s' "n/a"
    return 0
  fi

  status_output="$(LC_ALL=C ufw status 2>/dev/null || true)"
  [[ -n "${status_output}" ]] || {
    printf '%s' "n/a"
    return 0
  }

  if grep -Fq "Status: inactive" <<<"${status_output}"; then
    printf '%s' "нет"
    return 0
  fi

  ports="$(
    awk '
      BEGIN { in_rules = 0 }
      /^To[[:space:]]+Action[[:space:]]+From$/ { in_rules = 1; next }
      /^--/ && in_rules == 1 { next }
      in_rules == 1 {
        if ($1 == "") next
        if ($1 ~ /\(v6\)$/) next
        if ($1 == "OpenSSH") print "22"
        else if ($1 ~ /^[0-9]+\/tcp$/) {
          split($1, parts, "/")
          print parts[1]
        } else if ($1 ~ /^[0-9]+$/) print $1
      }
    ' <<<"${status_output}" | awk '!seen[$0]++' | sort -n | paste -sd ', ' -
  )"

  printf '%s' "${ports:-нет правил}"
}

clear_console_screen() {
  [[ -t 1 ]] || return 0

  if command_exists clear; then
    clear 2>/dev/null || printf '\033c'
  else
    printf '\033c'
  fi
}

installer_source_identity() {
  local identity=""

  if [[ -d "${INSTALLER_DIR}/.git" ]]; then
    identity="$(git -C "${INSTALLER_DIR}" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ -z "${identity}" && -f "${INSTALLER_DIR}/bot-menu.sh" ]]; then
    identity="$({
      cd "${INSTALLER_DIR}"
      find . \
        \( -path './.git' -o -path './.scratch' -o -path './state' \
           -o -path './.playwright-mcp' -o -name '__pycache__' \) -prune \
        -o -type f \
           ! -path './server.env' \
           ! -path './env.txt' \
           ! -name '*.pyc' \
           -print0 \
        | sort -z \
        | while IFS= read -r -d '' source_file; do
            printf '%s\0' "${source_file}"
            sha256sum "${source_file}" | cut -d ' ' -f1
          done
    } | sha256sum | cut -d ' ' -f1)"
  fi
  [[ "${identity}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  printf '%s' "${identity}"
}

install_management_copy() {
  local installer_home="${1:-${DEFAULT_INSTALLER_HOME}}"
  local identity
  local releases_dir
  local release_dir
  local staged_release
  local staged_current
  local previous_current

  [[ -f "${INSTALLER_DIR}/bot-menu.sh" ]] || return 1
  [[ "${installer_home}" == /opt/* || "${installer_home}" == /usr/local/* || "${installer_home}" == /tmp/* ]] || return 1
  identity="$(installer_source_identity)" || return 1
  releases_dir="${installer_home}/releases"
  release_dir="${releases_dir}/${identity}"
  mkdir -p "${releases_dir}"

  if [[ ! -d "${release_dir}" ]]; then
    staged_release="$(mktemp -d "${installer_home}/.release.XXXXXX")" || return 1
    if ! (
      cd "${INSTALLER_DIR}"
      tar -cf - \
        --exclude='./.git' \
        --exclude='./.scratch' \
        --exclude='./state' \
        --exclude='./server.env' \
        --exclude='./env.txt' \
        --exclude='./.playwright-mcp' \
        --exclude='*/__pycache__' \
        --exclude='*.pyc' \
        .
    ) | tar -xf - -C "${staged_release}"; then
      safe_rm_rf_under "${installer_home}" "${staged_release}"
      return 1
    fi
    mkdir -p "${staged_release}/state"
    chmod 700 "${staged_release}/state"
    chmod 755 "${staged_release}/bot-menu.sh"
    mv "${staged_release}" "${release_dir}"
  fi

  staged_current="$(mktemp -d "${installer_home}/.current.XXXXXX")" || return 1
  cp -a "${release_dir}/." "${staged_current}/"
  previous_current="${installer_home}/.previous-current"
  if [[ -e "${previous_current}" ]]; then
    safe_rm_rf_under "${installer_home}" "${previous_current}"
  fi
  if [[ -e "${installer_home}/current" ]]; then
    mv "${installer_home}/current" "${previous_current}"
  fi
  mv "${staged_current}" "${installer_home}/current"
  if [[ -e "${previous_current}" ]]; then
    safe_rm_rf_under "${installer_home}" "${previous_current}"
  fi
  printf '%s' "${installer_home}/current/bot-menu.sh"
}

write_menu_launcher() {
  local launcher_path="$1"
  local script_path="$2"
  local launcher_dir
  local temp_file

  launcher_dir="$(dirname "${launcher_path}")"
  [[ -d "${launcher_dir}" ]] || mkdir -p "${launcher_dir}"
  [[ -f "${script_path}" ]] || return 1

  temp_file="$(mktemp "${launcher_dir}/.vpn-launcher.XXXXXX")" || return 1
  cat > "${temp_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "\${EUID:-\$(id -u)}" -ne 0 ]]; then
  exec sudo bash "${script_path}" "\$@"
fi

exec bash "${script_path}" "\$@"
EOF

  chmod 755 "${temp_file}"
  mv -f "${temp_file}" "${launcher_path}"
}

install_menu_launcher() {
  local launcher_path="${1:-${DEFAULT_MENU_LAUNCHER_PATH}}"
  local installed_script

  [[ "${EUID}" -eq 0 ]] || return 0
  installed_script="$(install_management_copy)" || return 1
  write_menu_launcher "${launcher_path}" "${installed_script}"
}

python_cmd() {
  if command_exists python3 && python3 -c "import sys" >/dev/null 2>&1; then
    printf '%s' "python3"
    return 0
  fi

  if command_exists py && py -3 -c "import sys" >/dev/null 2>&1; then
    printf '%s' "py -3"
    return 0
  fi

  return 1
}

run_python() {
  local cmd
  cmd="$(python_cmd)" || die "Не найден рабочий Python 3 interpreter."
  # shellcheck disable=SC2086
  ${cmd} "$@"
}

run_env_helper() {
  run_python "${ENV_HELPER}" "$@"
}

prompt_input() {
  local label="$1"
  local format_hint="$2"
  local example="$3"
  local default_value="${4:-}"
  local mode="${5:-plain}"
  local value
  local prompt

  prompt="${label}"
  if [[ -n "${format_hint}" ]]; then
    prompt+=" | Формат: ${format_hint}"
  fi
  if [[ -n "${example}" ]]; then
    prompt+=" | Пример: ${example}"
  fi
  if [[ -n "${default_value}" && "${mode}" == "plain" ]]; then
    prompt+=" | По умолчанию: ${default_value}"
  fi
  if [[ "${mode}" == "visible-secret" ]]; then
    prompt+=" | Ввод видимый"
  fi

  while true; do
    if [[ "${mode}" == "secret" ]]; then
      read -r -s -p "${prompt}: " value
      echo
    else
      read -r -p "${prompt}: " value
    fi
    value="${value:-${default_value}}"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
    log_warn "Значение не может быть пустым."
  done
}

prompt_optional_input() {
  local label="$1"
  local format_hint="$2"
  local example="$3"
  local default_value="${4:-}"
  local value
  local prompt

  prompt="${label}"
  if [[ -n "${format_hint}" ]]; then
    prompt+=" | Формат: ${format_hint}"
  fi
  if [[ -n "${example}" ]]; then
    prompt+=" | Пример: ${example}"
  fi
  if [[ -n "${default_value}" ]]; then
    prompt+=" | По умолчанию: ${default_value}"
  fi
  prompt+=" | Оставьте пустым, чтобы пропустить"

  read -r -p "${prompt}: " value
  value="${value:-${default_value}}"
  printf '%s' "${value}"
}

prompt_validated_input() {
  local validator_name="$1"
  local error_message="$2"
  shift 2

  local value
  while true; do
    value="$(prompt_input "$@")"
    if "${validator_name}" "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    log_warn "${error_message}"
  done
}

prompt_optional_validated_input() {
  local validator_name="$1"
  local error_message="$2"
  shift 2

  local value
  while true; do
    value="$(prompt_optional_input "$@")"
    if [[ -z "${value}" ]] || "${validator_name}" "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    log_warn "${error_message}"
  done
}

prompt_yes_no() {
  local label="$1"
  local default_choice="${2:-y}"
  local example
  local answer

  if [[ "${default_choice}" == "y" ]]; then
    example="Y/n"
  else
    example="y/N"
  fi

  while true; do
    read -r -p "${label} [${example}]: " answer
    answer="${answer:-${default_choice}}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) log_warn "Введите y или n." ;;
    esac
  done
}

prompt_typed_confirmation() {
  local expected="$1"
  local label="$2"
  local answer

  read -r -p "${label} Введите '${expected}': " answer
  [[ "${answer}" == "${expected}" ]]
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

shell_quote() {
  local value="${1:-}"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "${value}"
}

curl_with_timeouts() {
  curl \
    --connect-timeout "${CURL_CONNECT_TIMEOUT:-${DEFAULT_CURL_CONNECT_TIMEOUT}}" \
    --max-time "${CURL_MAX_TIME:-${DEFAULT_CURL_MAX_TIME}}" \
    "$@"
}

public_https_status() {
  local url="$1"
  local status

  [[ "${url}" == https://* ]] || return 1
  status="$(curl_with_timeouts -sS -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)" \
    || return 1
  [[ "${status}" =~ ^[1-5][0-9][0-9]$ ]] || return 1
  printf '%s' "${status}"
}

secure_private_file() {
  local file_path="$1"
  [[ -e "${file_path}" ]] || return 0
  chmod 600 "${file_path}"
}

is_safe_project_root() {
  local value
  local resolved_value
  value="$(trim "$1")"

  [[ "${value}" == /* ]] || return 1
  resolved_value="$(realpath -m "${value}")" || return 1
  [[ "${resolved_value}" == "${value}" ]] || return 1

  case "${value}" in
    /|/root|/etc|/usr|/var|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/run|/tmp)
      return 1
      ;;
  esac

  [[ "${value}" == /opt/* || "${value}" == /srv/* || "${value}" == /home/* ]]
}

restore_snapshot_repository_heads() {
  local snapshot_path="$1"
  local metadata_file="${snapshot_path}/metadata.txt"
  local bot_head_sha=""
  local cabinet_head_sha=""

  [[ -f "${metadata_file}" ]] || return 0
  bot_head_sha="$(awk -F= '$1 == "bot_head_sha" {print $2; exit}' "${metadata_file}")"
  cabinet_head_sha="$(awk -F= '$1 == "cabinet_head_sha" {print $2; exit}' "${metadata_file}")"

  if [[ "${bot_head_sha}" =~ ^[0-9a-f]{40}$ && -d "${BOT_REPO_DIR}/.git" ]]; then
    git -C "${BOT_REPO_DIR}" checkout --detach "${bot_head_sha}" >/dev/null || return 1
    [[ "$(git -C "${BOT_REPO_DIR}" rev-parse HEAD)" == "${bot_head_sha}" ]] || return 1
  fi
  if [[ "${cabinet_head_sha}" =~ ^[0-9a-f]{40}$ && -d "${CABINET_REPO_DIR}/.git" ]]; then
    git -C "${CABINET_REPO_DIR}" checkout --detach "${cabinet_head_sha}" >/dev/null || return 1
    [[ "$(git -C "${CABINET_REPO_DIR}" rev-parse HEAD)" == "${cabinet_head_sha}" ]] || return 1
  fi
}

restore_snapshot_cabinet_dist() {
  local snapshot_path="$1"
  local snapshot_dist="${snapshot_path}/cabinet-dist"

  [[ -d "${snapshot_dist}" ]] || return 0
  safe_rm_rf_under "${PROJECT_ROOT}" "${CABINET_DIST_DIR}"
  cp -a "${snapshot_dist}" "${CABINET_DIST_DIR}"
}

path_is_under() {
  local base_path="$1"
  local target_path="$2"
  local resolved_base
  local resolved_target

  resolved_base="$(realpath -m "${base_path}")" || return 1
  resolved_target="$(realpath -m "${target_path}")" || return 1

  [[ "${resolved_target}" == "${resolved_base}" || "${resolved_target}" == "${resolved_base}/"* ]]
}

safe_rm_rf_under() {
  local base_path="$1"
  local target_path="$2"

  [[ -n "${base_path}" && -n "${target_path}" ]] || die "Пустой путь для безопасного удаления."
  [[ "${target_path}" != "/" ]] || die "Отказ удаления корня файловой системы."
  path_is_under "${base_path}" "${target_path}" || die "Отказ удаления вне разрешенной директории: ${target_path}"

  rm -rf "${target_path}"
}

preferred_editor() {
  if [[ -n "${EDITOR:-}" ]]; then
    printf '%s' "${EDITOR}"
  elif command_exists nano; then
    printf '%s' "nano"
  elif command_exists vi; then
    printf '%s' "vi"
  else
    printf '%s' ""
  fi
}

open_file_in_editor() {
  local file_path="$1"
  local editor_cmd

  editor_cmd="$(preferred_editor)"
  [[ -n "${editor_cmd}" ]] || die "Не найден текстовый редактор. Установите nano, vi или задайте переменную EDITOR."
  "${editor_cmd}" "${file_path}"
}

normalize_domain() {
  local value
  value="$(trim "$1")"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s' "${value,,}"
}

normalize_url() {
  local value
  value="$(trim "$1")"
  if [[ "${value}" != http://* && "${value}" != https://* ]]; then
    value="https://${value}"
  fi
  value="${value%/}"
  printf '%s' "${value}"
}

is_valid_domain() {
  local value
  value="$(normalize_domain "$1")"
  [[ "${value}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

is_valid_url() {
  local value
  value="$(normalize_url "$1")"
  [[ "${value}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

is_valid_git_remote() {
  local value="$1"
  [[ "${value}" =~ ^https?://.+\.git$ || "${value}" =~ ^git@[^:]+:.+\.git$ || "${value}" =~ ^ssh://.+\.git$ ]]
}

is_valid_bot_token() {
  [[ "$1" =~ ^[0-9]+:.+$ ]]
}

is_valid_bot_username() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]{4,31}$ ]]
}

is_valid_admin_ids() {
  [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

is_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  ((value >= 1 && value <= 65535))
}

is_valid_pg_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

is_valid_language_code() {
  [[ "$1" =~ ^[a-z]{2}([_-][A-Za-z]{2})?$ ]]
}

is_valid_timezone_value() {
  [[ "$1" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]]
}

is_valid_decimal() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_valid_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonempty_string() {
  [[ -n "$1" ]]
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

render_template() {
  local template_file="$1"
  local output_file="$2"
  shift 2

  [[ -f "${template_file}" ]] || die "Шаблон не найден: ${template_file}"
  mkdir -p "$(dirname "${output_file}")"

  local replacements_file
  replacements_file="$(mktemp)"

  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair}" >> "${replacements_file}"
  done

  run_python - "${template_file}" "${output_file}" "${replacements_file}" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
replacements_path = Path(sys.argv[3])

content = template_path.read_text(encoding="utf-8")
for line in replacements_path.read_text(encoding="utf-8").splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    content = content.replace(f"__{key}__", value)

output_path.write_text(content + "\n", encoding="utf-8")
PY

  rm -f "${replacements_file}"
}

render_env_file() {
  local base_env_file="$1"
  local output_file="$2"
  shift 2

  [[ -f "${base_env_file}" ]] || die "Базовый env-файл не найден: ${base_env_file}"
  mkdir -p "$(dirname "${output_file}")"

  local replacements_file
  replacements_file="$(mktemp)"

  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair}" >> "${replacements_file}"
  done

  run_python - "${base_env_file}" "${output_file}" "${replacements_file}" <<'PY'
from pathlib import Path
import re
import sys

base_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
replacements_path = Path(sys.argv[3])

replacements = {}
for raw in replacements_path.read_text(encoding="utf-8").splitlines():
    if "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    key = key.strip()
    if key:
        replacements[key] = value

line_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=')
seen = set()
out_lines = []

for line in base_path.read_text(encoding="utf-8").splitlines():
    m = line_re.match(line)
    if not m:
        out_lines.append(line)
        continue
    key = m.group(1)
    if key in replacements:
        out_lines.append(f"{key}={replacements[key]}")
        seen.add(key)
    else:
        out_lines.append(line)

for key, value in replacements.items():
    if key not in seen:
        out_lines.append(f"{key}={value}")

out_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
PY

  rm -f "${replacements_file}"
}

generate_hex_secret() {
  local length="${1:-64}"
  if command_exists openssl; then
    openssl rand -hex "$((length / 2))"
  else
    head -c "$((length / 2))" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

read_last_project_root() {
  local locator_file="${LAST_PROJECT_ROOT_FILE}"
  if [[ -f "${GLOBAL_LAST_PROJECT_ROOT_FILE}" ]]; then
    locator_file="${GLOBAL_LAST_PROJECT_ROOT_FILE}"
  elif [[ ! -f "${locator_file}" ]]; then
    return 1
  fi
  local value
  value="$(head -n 1 "${locator_file}" 2>/dev/null || true)"
  value="$(trim "${value}")"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}"
}

save_last_project_root() {
  local locator_file
  local temporary
  local locator_files=("${LAST_PROJECT_ROOT_FILE}")
  if [[ "${EUID}" -eq 0 ]]; then
    locator_files+=("${GLOBAL_LAST_PROJECT_ROOT_FILE}")
  fi
  for locator_file in "${locator_files[@]}"; do
    mkdir -p "$(dirname "${locator_file}")"
    temporary="${locator_file}.tmp.$$"
    (
      umask 077
      printf '%s\n' "${PROJECT_ROOT}" > "${temporary}"
    )
    mv -f "${temporary}" "${locator_file}"
    secure_private_file "${locator_file}"
    sync -f "${locator_file}"
    sync -f "$(dirname "${locator_file}")"
  done
}

clear_last_project_root() {
  rm -f "${LAST_PROJECT_ROOT_FILE}"
  sync -f "$(dirname "${LAST_PROJECT_ROOT_FILE}")" 2>/dev/null || true
  if [[ "${EUID}" -eq 0 ]]; then
    rm -f "${GLOBAL_LAST_PROJECT_ROOT_FILE}"
    sync -f "${GLOBAL_INSTALLER_STATE_DIR}" 2>/dev/null || true
  fi
}

resolve_state_file() {
  local remembered_project_root
  local runtime_state_file
  local default_state_file

  if [[ -n "${RUNTIME_CHANGE_PENDING_STATE_FILE:-}" \
    && -f "${RUNTIME_CHANGE_PENDING_STATE_FILE}" ]]; then
    STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE_FILE}"
    return 0
  fi

  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    runtime_state_file="${PROJECT_ROOT}/state/install.state"
    if [[ -f "${runtime_state_file}" ]]; then
      STATE_FILE="${runtime_state_file}"
      return 0
    fi
  fi

  remembered_project_root="$(read_last_project_root || true)"
  if [[ -n "${remembered_project_root}" ]]; then
    runtime_state_file="${remembered_project_root}/state/install.state"
    if [[ -f "${runtime_state_file}" ]]; then
      PROJECT_ROOT="${remembered_project_root}"
      STATE_FILE="${runtime_state_file}"
      return 0
    fi
  fi

  default_state_file="${DEFAULT_PROJECT_ROOT}/state/install.state"
  if [[ -f "${default_state_file}" ]]; then
    PROJECT_ROOT="${DEFAULT_PROJECT_ROOT}"
    STATE_FILE="${default_state_file}"
    return 0
  fi

  if [[ -f "${LEGACY_STATE_FILE}" ]]; then
    STATE_FILE="${LEGACY_STATE_FILE}"
    return 0
  fi

  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    STATE_FILE="${PROJECT_ROOT}/state/install.state"
  elif [[ -n "${remembered_project_root}" ]]; then
    PROJECT_ROOT="${remembered_project_root}"
    STATE_FILE="${PROJECT_ROOT}/state/install.state"
  else
    STATE_FILE="${default_state_file}"
  fi
}

load_state() {
  resolve_state_file
  if [[ -f "${STATE_FILE}" ]]; then
    reset_loaded_state_vars
    eval "$(run_env_helper read-state "${STATE_FILE}")"
    set_runtime_paths
    migrate_legacy_state_if_needed
  fi
}

reset_loaded_state_vars() {
  unset PROJECT_ROOT REPOS_DIR RUNTIME_DIR STATE_DIR RELEASES_DIR
  unset BOT_REPO_URL CABINET_REPO_URL BOT_REPO_DIR CABINET_REPO_DIR
  unset BOT_RUNTIME_DIR BOT_DATA_DIR BOT_LOGS_DIR BOT_UPLOADS_DIR CABINET_DIST_DIR
  unset BOT_ENV_FILE BOT_OVERRIDE_ENV_FILE CABINET_ENV_FILE COMPOSE_FILE CADDY_CANDIDATE_FILE
  unset CADDY_SNIPPET_DIR CADDY_SNIPPET_FILE
  unset HOOK_DOMAIN APP_DOMAIN WEBHOOK_URL CABINET_URL
  unset BOT_TOKEN BOT_USERNAME ADMIN_IDS
  unset REMNAWAVE_API_URL REMNAWAVE_API_KEY REMNAWAVE_SECRET_KEY
  unset REMNAWAVE_WEBHOOK_SECRET REMNAWAVE_AUTH_TYPE
  unset TIMEZONE DEFAULT_LANGUAGE APP_NAME APP_LOGO
  unset WEBHOOK_SECRET_TOKEN WEB_API_DEFAULT_TOKEN CABINET_JWT_SECRET
  unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_IMAGE REDIS_URL REDIS_IMAGE
  unset BOT_HTTP_PORT BOT_RUN_MODE WEB_API_ENABLED CABINET_ENABLED COMPOSE_PROJECT_NAME
  unset CABINET_EMAIL_AUTH_ENABLED CABINET_EMAIL_VERIFICATION_ENABLED
  unset BOT_VERSION_REF CABINET_VERSION_REF LAST_BOT_VERSION_REF LAST_CABINET_VERSION_REF
  unset RELEASE_MANIFEST_SOURCE CURRENT_RELEASE
  unset CURRENT_RELEASE_BUNDLE_IDENTITY CURRENT_CABINET_ARTIFACT_SHA256
  unset LAST_RELEASE_BUNDLE_IDENTITY LAST_CABINET_ARTIFACT_SHA256
}

reset_project_root_paths() {
  unset REPOS_DIR RUNTIME_DIR STATE_DIR RELEASES_DIR
  unset BOT_REPO_DIR CABINET_REPO_DIR
  unset BOT_RUNTIME_DIR BOT_DATA_DIR BOT_LOGS_DIR BOT_UPLOADS_DIR CABINET_DIST_DIR
  unset BOT_ENV_FILE BOT_OVERRIDE_ENV_FILE CABINET_ENV_FILE COMPOSE_FILE CADDY_CANDIDATE_FILE
  unset CADDY_SNIPPET_FILE
}

set_runtime_paths() {
  PROJECT_ROOT="${PROJECT_ROOT:-${DEFAULT_PROJECT_ROOT}}"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(compose_project_name_for_root "${PROJECT_ROOT}")}"
  REPOS_DIR="${PROJECT_ROOT}/repos"
  RUNTIME_DIR="${PROJECT_ROOT}/runtime"
  STATE_DIR="${PROJECT_ROOT}/state"
  RELEASES_DIR="${PROJECT_ROOT}/releases"

  BOT_REPO_DIR="${BOT_REPO_DIR:-${REPOS_DIR}/bot-backend}"
  CABINET_REPO_DIR="${CABINET_REPO_DIR:-${REPOS_DIR}/bot-cabinet}"

  BOT_RUNTIME_DIR="${BOT_RUNTIME_DIR:-${RUNTIME_DIR}/bot}"
  BOT_DATA_DIR="${BOT_DATA_DIR:-${BOT_RUNTIME_DIR}/data}"
  BOT_LOGS_DIR="${BOT_LOGS_DIR:-${BOT_RUNTIME_DIR}/logs}"
  BOT_UPLOADS_DIR="${BOT_UPLOADS_DIR:-${BOT_RUNTIME_DIR}/uploads}"
  CABINET_DIST_DIR="${CABINET_DIST_DIR:-${RUNTIME_DIR}/cabinet-dist}"

  BOT_ENV_FILE="${BOT_ENV_FILE:-${STATE_DIR}/bot.env}"
  BOT_OVERRIDE_ENV_FILE="${BOT_OVERRIDE_ENV_FILE:-${STATE_DIR}/bot.override.env}"
  CABINET_ENV_FILE="${CABINET_ENV_FILE:-${STATE_DIR}/cabinet.env}"
  COMPOSE_FILE="${COMPOSE_FILE:-${STATE_DIR}/docker-compose.yml}"
  CADDY_CANDIDATE_FILE="${CADDY_CANDIDATE_FILE:-${STATE_DIR}/bot-stack.caddy}"

  CADDY_SNIPPET_DIR="${CADDY_SNIPPET_DIR:-/etc/caddy/conf.d}"
  CADDY_SNIPPET_FILE="${CADDY_SNIPPET_FILE:-${CADDY_SNIPPET_DIR}/${COMPOSE_PROJECT_NAME}.caddy}"
  STATE_FILE="${STATE_DIR}/install.state"
}

compose_project_name_for_root() {
  local project_root="$1"
  local slug
  local digest

  slug="$(basename "${project_root}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/[-_]+$//')"
  slug="${slug:-stack}"
  digest="$(printf '%s' "${project_root}" | sha256sum | cut -c1-8)"
  printf 'bedolaga-%s-%s' "${slug:0:32}" "${digest}"
}

file_sha256() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || return 1
  sha256sum "${file_path}" | awk '{print $1}'
}

tracked_hash_file() {
  local label="$1"
  printf '%s' "${STATE_DIR}/applied-${label}.sha256"
}

snapshot_dir_root() {
  printf '%s' "${STATE_DIR}/snapshots"
}

backup_dir_root() {
  printf '%s' "${STATE_DIR}/backups"
}

prune_old_paths() {
  local keep_count="$1"
  shift
  local entries=("$@")
  local index

  ((${#entries[@]} > keep_count)) || return 0

  for ((index = keep_count; index < ${#entries[@]}; index++)); do
    safe_rm_rf_under "${STATE_DIR}" "${entries[$index]}"
    log_info "Удален старый артефакт: ${entries[$index]}"
  done
}

create_backup_archive() {
  require_state_file
  local backup_label="${1:-manual}"
  local backup_path

  log_info "Создание file backup без PostgreSQL и Redis."
  backup_path="$(run_python "${RECOVERY_HELPER}" create "${PROJECT_ROOT}" "${backup_label}")" \
    || die "Не удалось создать и проверить file backup."
  printf '%s' "${backup_path}"
}

create_manual_backup() {
  require_state_file
  local backup_label
  local backup_path

  backup_label="$(prompt_optional_input \
    "Метка backup" \
    "короткая строка без пробелов или с дефисами" \
    "before-manual-change" \
    "manual")"
  backup_label="${backup_label:-manual}"
  backup_path="$(create_backup_archive "${backup_label}" | tail -n 1)"
  log_info "Backup создан: ${backup_path}"
}

list_backups() {
  require_state_file
  local root_dir
  local limit="${1:-20}"

  root_dir="$(backup_dir_root)"
  [[ -d "${root_dir}" ]] || return 0

  find "${root_dir}" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' | sort -r | head -n "${limit}"
}

print_recent_backups() {
  require_state_file
  local backup_path
  local count=0
  local size_bytes=""
  local size_human=""
  local meta_path=""

  echo "Последние backups"
  echo "-----------------"

  while IFS= read -r backup_path; do
    ((count += 1))
    meta_path="${backup_path%.tar.gz}.metadata.txt"
    size_bytes="$(wc -c < "${backup_path}" 2>/dev/null | tr -d '[:space:]' || true)"
    size_human="${size_bytes:-0} B"
    if command_exists numfmt && [[ -n "${size_bytes}" ]]; then
      size_human="$(numfmt --to=iec-i --suffix=B "${size_bytes}" 2>/dev/null || printf '%s B' "${size_bytes}")"
    fi

    printf '%2d. %s [%s]\n' "${count}" "${backup_path}" "${size_human}"
    if run_python "${RECOVERY_HELPER}" validate "${backup_path}" "${PROJECT_ROOT}" >/dev/null 2>&1; then
      echo "    type=file-backup; PostgreSQL=нет; Redis=нет; checksums=проверены"
    elif [[ -f "${meta_path}" ]]; then
      sed 's/^/    /' "${meta_path}"
      echo "    status=legacy/unverified; автоматическое восстановление запрещено"
    else
      echo "    status=непроверяемый artifact; автоматическое восстановление запрещено"
    fi
    echo
  done < <(list_backups 10)

  if ((count == 0)); then
    echo "Backups пока не найдены."
  fi
}

restore_backup_archive() {
  require_state_file
  local backups=()
  local selected_index
  local backup_path
  local meta_path
  local result_file
  local outcome
  local failed_stage
  local safety_backup
  local recovery_plan

  mapfile -t backups < <(list_backups 20)
  if ((${#backups[@]} == 0)); then
    log_info "Backups для восстановления не найдены."
    return 0
  fi

  echo "Доступные backups"
  echo "-----------------"
  for selected_index in "${!backups[@]}"; do
    backup_path="${backups[$selected_index]}"
    meta_path="${backup_path%.tar.gz}.metadata.txt"
    printf '%2d. %s\n' "$((selected_index + 1))" "${backup_path}"
    if [[ -f "${meta_path}" ]]; then
      sed 's/^/    /' "${meta_path}"
    fi
    echo
  done

  read_menu_choice "Выберите backup [1-${#backups[@]}]: " selected_index
  [[ "${selected_index}" =~ ^[0-9]+$ ]] || die "Некорректный номер backup."
  ((selected_index >= 1 && selected_index <= ${#backups[@]})) || die "Номер backup вне диапазона."

  backup_path="${backups[$((selected_index - 1))]}"
  run_python "${RECOVERY_HELPER}" validate "${backup_path}" "${PROJECT_ROOT}" >/dev/null \
    || die "File backup повреждён, небезопасен, относится к другому проекту или не имеет checksums. Runtime не изменён."

  log_warn "Будет восстановлен file backup: ${backup_path}"
  log_warn "Состав: state, Bot data/logs/uploads и Cabinet dist. PostgreSQL и Redis не входят."
  log_warn "До остановки сервисов Recovery создаст и проверит safety file backup."
  prompt_typed_confirmation "RESTORE_BACKUP" "Подтверждение." || die "Восстановление backup отменено."

  result_file="$(mktemp "${STATE_DIR}/.recovery-result.XXXXXX")"
  cleanup_restore_backup_temp() {
    local exit_code=$?
    trap - RETURN
    rm -f "${result_file}" >/dev/null 2>&1 || true
    return "${exit_code}"
  }
  trap cleanup_restore_backup_temp RETURN

  run_python \
    "${RECOVERY_HELPER}" recover "${backup_path}" "${PROJECT_ROOT}" \
    "${RECOVERY_RUNTIME_ADAPTER}" "${result_file}" \
    || die "Recovery не смог запустить lifecycle. Runtime мог быть безопасно остановлен; проверьте installer log."

  outcome="$(run_python "${RECOVERY_HELPER}" result-field "${result_file}" outcome)"
  failed_stage="$(run_python "${RECOVERY_HELPER}" result-field "${result_file}" failed_stage)"
  safety_backup="$(run_python "${RECOVERY_HELPER}" result-field "${result_file}" safety_backup)"
  recovery_plan="$(run_python "${RECOVERY_HELPER}" result-field "${result_file}" recovery_plan)"
  case "${outcome}" in
    committed)
      log_info "Recovery committed: файлы восстановлены, Docker/Caddy/Telegram активированы и проверены."
      log_info "Safety file backup сохранён: ${safety_backup}"
      ;;
    rolled_back)
      log_warn "Recovery rolled back на стадии ${failed_stage}: прежнее состояние восстановлено и проверено."
      log_warn "Safety file backup: ${safety_backup}"
      ;;
    safely_stopped)
      log_error "Recovery safely stopped на стадии ${failed_stage}."
      log_error "Safety file backup: ${safety_backup}"
      log_error "Recovery plan: ${recovery_plan}"
      ;;
    *)
      die "Recovery вернул неизвестный outcome. Runtime состояние необходимо проверить вручную."
      ;;
  esac

  trap - RETURN
  cleanup_restore_backup_temp
}

recover_interrupted_file_recovery() {
  local marker_file
  local recovery_project_root
  local safety_backup

  resolve_state_file
  recovery_project_root="${PROJECT_ROOT:-$(read_last_project_root || true)}"
  recovery_project_root="${recovery_project_root:-${DEFAULT_PROJECT_ROOT}}"
  marker_file="${recovery_project_root}/.file-recovery-in-progress.json"
  [[ -f "${marker_file}" ]] || return 0

  log_error "Обнаружен прерванный File Recovery. Bot и Caddy будут удерживаться остановленными."
  if ! bash "${RECOVERY_RUNTIME_ADAPTER}" safe-stop "${recovery_project_root}"; then
    log_error "Безопасная остановка после прерывания НЕ подтверждена. Не запускайте runtime вручную."
    return 1
  fi
  safety_backup="$(run_python "${RECOVERY_HELPER}" result-field "${marker_file}" safety_backup)"
  if [[ ! -f "${safety_backup}" ]]; then
    local preserved_dir
    for preserved_dir in "${recovery_project_root}"/.recovery-backups-*; do
      [[ -d "${preserved_dir}" ]] || continue
      if [[ -f "${preserved_dir}/$(basename "${safety_backup}")" ]]; then
        safety_backup="${preserved_dir}/$(basename "${safety_backup}")"
        break
      fi
    done
  fi
  log_warn "Runtime безопасно остановлен. Для возврата выберите safety file backup: ${safety_backup}"
}

cleanup_old_backups() {
  require_state_file
  local keep_count
  local backups=()

  keep_count="$(prompt_validated_input \
    is_valid_positive_integer \
    "Введите положительное целое число." \
    "Сколько последних backups оставить" \
    "например 10" \
    "10")"

  mapfile -t backups < <(list_backups 1000)
  if ((${#backups[@]} == 0)); then
    log_info "Backups для очистки не найдены."
    return 0
  fi

  if ! prompt_yes_no "Удалить старые backups и оставить только последние ${keep_count}?" "n"; then
    log_info "Очистка backups отменена."
    return 0
  fi

  prune_old_paths "${keep_count}" "${backups[@]}"
  log_info "Очистка backups завершена. Оставлено последних: ${keep_count}."
}

list_snapshots() {
  require_state_file
  local root_dir
  local limit="${1:-20}"

  root_dir="$(snapshot_dir_root)"
  [[ -d "${root_dir}" ]] || return 0

  find "${root_dir}" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n "${limit}"
}

print_recent_snapshots() {
  require_state_file
  local snapshot_path
  local count=0

  echo "Последние snapshots"
  echo "-------------------"

  while IFS= read -r snapshot_path; do
    ((count += 1))
    printf '%2d. %s\n' "${count}" "${snapshot_path}"
    if [[ -f "${snapshot_path}/metadata.txt" ]]; then
      sed 's/^/    /' "${snapshot_path}/metadata.txt"
    fi
    echo
  done < <(list_snapshots 10)

  if ((count == 0)); then
    echo "Snapshots пока не найдены."
  fi
}

restore_snapshot_configs() {
  require_state_file
  local snapshots=()
  local selected_index
  local snapshot_path
  local restored=0

  mapfile -t snapshots < <(list_snapshots 20)
  if ((${#snapshots[@]} == 0)); then
    log_info "Snapshots для восстановления не найдены."
    return 0
  fi

  echo "Доступные snapshots"
  echo "-------------------"
  for selected_index in "${!snapshots[@]}"; do
    printf '%2d. %s\n' "$((selected_index + 1))" "${snapshots[$selected_index]}"
    if [[ -f "${snapshots[$selected_index]}/metadata.txt" ]]; then
      sed 's/^/    /' "${snapshots[$selected_index]}/metadata.txt"
    fi
    echo
  done

  read_menu_choice "Выберите snapshot [1-${#snapshots[@]}]: " selected_index
  [[ "${selected_index}" =~ ^[0-9]+$ ]] || die "Некорректный номер snapshot."
  ((selected_index >= 1 && selected_index <= ${#snapshots[@]})) || die "Номер snapshot вне диапазона."

  snapshot_path="${snapshots[$((selected_index - 1))]}"
  log_warn "Будут восстановлены служебные файлы из snapshot: ${snapshot_path}"
  prompt_typed_confirmation "RESTORE_SNAPSHOT" "Подтверждение." || die "Восстановление snapshot отменено."

  create_update_snapshot "before-restore-snapshot"

  if [[ -f "${snapshot_path}/install.state" ]]; then
    cp "${snapshot_path}/install.state" "${STATE_FILE}"
    secure_private_file "${STATE_FILE}"
    ((restored += 1))
  fi
  if [[ -f "${snapshot_path}/bot.env" ]]; then
    cp "${snapshot_path}/bot.env" "${BOT_ENV_FILE}"
    secure_private_file "${BOT_ENV_FILE}"
    ((restored += 1))
  fi
  if [[ -f "${snapshot_path}/bot.override.env" ]]; then
    cp "${snapshot_path}/bot.override.env" "${BOT_OVERRIDE_ENV_FILE}"
    secure_private_file "${BOT_OVERRIDE_ENV_FILE}"
    ((restored += 1))
  fi
  if [[ -f "${snapshot_path}/cabinet.env" ]]; then
    cp "${snapshot_path}/cabinet.env" "${CABINET_ENV_FILE}"
    secure_private_file "${CABINET_ENV_FILE}"
    ((restored += 1))
  fi
  if [[ -f "${snapshot_path}/docker-compose.yml" ]]; then
    cp "${snapshot_path}/docker-compose.yml" "${COMPOSE_FILE}"
    ((restored += 1))
  fi
  if [[ -f "${snapshot_path}/bot-stack.caddy.candidate" ]]; then
    cp "${snapshot_path}/bot-stack.caddy.candidate" "${CADDY_CANDIDATE_FILE}"
    ((restored += 1))
  fi
  if [[ -d "${snapshot_path}/settings-draft" ]]; then
    safe_rm_rf_under "${STATE_DIR}" "${STATE_DIR}/draft"
    cp -a "${snapshot_path}/settings-draft" "${STATE_DIR}/draft"
    ((restored += 1))
  fi

  load_state
  restore_snapshot_repository_heads "${snapshot_path}"
  restore_snapshot_cabinet_dist "${snapshot_path}"
  log_info "Восстановление snapshot завершено. Файлов восстановлено: ${restored}."
  log_info "Для применения восстановленной конфигурации выполните: Обслуживание -> Применить новые настройки."
}

restore_snapshot_files_from_path() {
  local snapshot_path="$1"
  [[ -d "${snapshot_path}" ]] || return 1

  [[ -f "${snapshot_path}/install.state" ]] && cp "${snapshot_path}/install.state" "${STATE_FILE}"
  [[ -f "${snapshot_path}/bot.env" ]] && cp "${snapshot_path}/bot.env" "${BOT_ENV_FILE}"
  [[ -f "${snapshot_path}/bot.override.env" ]] && cp "${snapshot_path}/bot.override.env" "${BOT_OVERRIDE_ENV_FILE}"
  [[ -f "${snapshot_path}/cabinet.env" ]] && cp "${snapshot_path}/cabinet.env" "${CABINET_ENV_FILE}"
  [[ -f "${snapshot_path}/docker-compose.yml" ]] && cp "${snapshot_path}/docker-compose.yml" "${COMPOSE_FILE}"
  [[ -f "${snapshot_path}/bot-stack.caddy.candidate" ]] && cp "${snapshot_path}/bot-stack.caddy.candidate" "${CADDY_CANDIDATE_FILE}"
  if [[ -d "${snapshot_path}/settings-draft" ]]; then
    safe_rm_rf_under "${STATE_DIR}" "${STATE_DIR}/draft"
    cp -a "${snapshot_path}/settings-draft" "${STATE_DIR}/draft"
  fi
  secure_private_file "${STATE_FILE}"
  secure_private_file "${BOT_ENV_FILE}"
  secure_private_file "${BOT_OVERRIDE_ENV_FILE}"
  secure_private_file "${CABINET_ENV_FILE}"
  load_state
  restore_snapshot_repository_heads "${snapshot_path}"
  restore_snapshot_cabinet_dist "${snapshot_path}"
}

cleanup_old_snapshots() {
  require_state_file
  local keep_count
  local snapshots=()

  keep_count="$(prompt_validated_input \
    is_valid_positive_integer \
    "Введите положительное целое число." \
    "Сколько последних snapshots оставить" \
    "например 20" \
    "20")"

  mapfile -t snapshots < <(list_snapshots 1000)
  if ((${#snapshots[@]} == 0)); then
    log_info "Snapshots для очистки не найдены."
    return 0
  fi

  if ! prompt_yes_no "Удалить старые snapshots и оставить только последние ${keep_count}?" "n"; then
    log_info "Очистка snapshots отменена."
    return 0
  fi

  prune_old_paths "${keep_count}" "${snapshots[@]}"
  log_info "Очистка snapshots завершена. Оставлено последних: ${keep_count}."
}

create_manual_snapshot() {
  require_state_file
  local snapshot_label

  snapshot_label="$(prompt_optional_input \
    "Метка snapshot" \
    "короткая строка без пробелов или с дефисами" \
    "before-manual-change" \
    "manual")"
  snapshot_label="${snapshot_label:-manual}"
  create_update_snapshot "${snapshot_label}"
}

show_recent_installer_actions() {
  local lines="${1:-50}"
  local log_file

  log_file="$(installer_log_file)"
  if [[ ! -f "${log_file}" ]]; then
    echo "Installer log пока не найден: ${log_file}"
    return 0
  fi

  echo "Последние действия installer"
  echo "----------------------------"
  tail -n "${lines}" "${log_file}"
}

read_tracked_file_hash() {
  local label="$1"
  local hash_file
  hash_file="$(tracked_hash_file "${label}")"
  [[ -f "${hash_file}" ]] || return 1
  head -n 1 "${hash_file}" 2>/dev/null
}

write_tracked_file_hash() {
  local label="$1"
  local file_path="$2"
  local hash_file
  local hash_value

  hash_file="$(tracked_hash_file "${label}")"
  hash_value="$(file_sha256 "${file_path}")" || return 1
  mkdir -p "${STATE_DIR}"
  (
    umask 077
    printf '%s\n' "${hash_value}" > "${hash_file}"
  )
  secure_private_file "${hash_file}"
}

file_changed_since_last_apply() {
  local label="$1"
  local file_path="$2"
  local current_hash
  local tracked_hash

  current_hash="$(file_sha256 "${file_path}")" || return 0
  tracked_hash="$(read_tracked_file_hash "${label}" || true)"
  [[ -n "${tracked_hash}" && "${tracked_hash}" == "${current_hash}" ]] || return 0
  return 1
}

render_template_to_temp() {
  local template_file="$1"
  shift
  local temp_file
  temp_file="$(mktemp)"
  render_template "${template_file}" "${temp_file}" "$@"
  printf '%s' "${temp_file}"
}

create_update_snapshot() {
  require_state_file || return 1
  local snapshot_label="${1:-manual}"
  local timestamp
  local snapshot_dir
  local safe_label

  safe_label="$(printf '%s' "${snapshot_label}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$(snapshot_dir_root)" || return 1
  snapshot_dir="$(mktemp -d "$(snapshot_dir_root)/${timestamp}-${safe_label}-XXXXXX")" \
    || return 1
  LAST_CREATED_SNAPSHOT_DIR="${snapshot_dir}"

  [[ -f "${STATE_FILE}" ]] || return 1
  cp "${STATE_FILE}" "${snapshot_dir}/install.state" || return 1
  [[ ! -f "${BOT_ENV_FILE}" ]] || cp "${BOT_ENV_FILE}" "${snapshot_dir}/bot.env" || return 1
  [[ ! -f "${BOT_OVERRIDE_ENV_FILE}" ]] || cp "${BOT_OVERRIDE_ENV_FILE}" "${snapshot_dir}/bot.override.env" || return 1
  [[ ! -f "${CABINET_ENV_FILE}" ]] || cp "${CABINET_ENV_FILE}" "${snapshot_dir}/cabinet.env" || return 1
  [[ ! -f "${COMPOSE_FILE}" ]] || cp "${COMPOSE_FILE}" "${snapshot_dir}/docker-compose.yml" || return 1
  [[ ! -f "${CADDY_CANDIDATE_FILE}" ]] || cp "${CADDY_CANDIDATE_FILE}" "${snapshot_dir}/bot-stack.caddy.candidate" || return 1
  [[ ! -f "${CADDY_SNIPPET_FILE}" ]] || cp "${CADDY_SNIPPET_FILE}" "${snapshot_dir}/bot-stack.caddy.live" || return 1
  [[ ! -d "${CABINET_DIST_DIR}" ]] || cp -a "${CABINET_DIST_DIR}" "${snapshot_dir}/cabinet-dist" || return 1
  [[ ! -d "${STATE_DIR}/draft" ]] || cp -a "${STATE_DIR}/draft" "${snapshot_dir}/settings-draft" || return 1

  {
    printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'label=%s\n' "${snapshot_label}"
    printf 'bot_target_ref=%s\n' "${BOT_VERSION_REF:-}"
    printf 'cabinet_target_ref=%s\n' "${CABINET_VERSION_REF:-}"
    printf 'bot_current_ref=%s\n' "$(current_repo_revision "${BOT_REPO_DIR}")"
    printf 'cabinet_current_ref=%s\n' "$(current_repo_revision "${CABINET_REPO_DIR}")"
    printf 'bot_head_sha=%s\n' "$(git -C "${BOT_REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
    printf 'cabinet_head_sha=%s\n' "$(git -C "${CABINET_REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
  } > "${snapshot_dir}/metadata.txt" || return 1

  secure_private_file "${snapshot_dir}/install.state" || return 1
  secure_private_file "${snapshot_dir}/bot.env" || return 1
  secure_private_file "${snapshot_dir}/bot.override.env" || return 1
  secure_private_file "${snapshot_dir}/cabinet.env" || return 1
  secure_private_file "${snapshot_dir}/metadata.txt" || return 1

  log_info "Создан snapshot перед изменением: ${snapshot_dir}"
}

migrate_legacy_state_if_needed() {
  local runtime_state_file

  [[ "${STATE_FILE}" == "${LEGACY_STATE_FILE}" ]] || return 0

  runtime_state_file="${STATE_DIR}/install.state"
  if [[ ! -f "${runtime_state_file}" ]]; then
    mkdir -p "${STATE_DIR}"
    cp "${LEGACY_STATE_FILE}" "${runtime_state_file}"
    log_info "Файл состояния перенесен в ${runtime_state_file}."
  fi

  STATE_FILE="${runtime_state_file}"
}

save_state() {
  local pending_state_file="${RUNTIME_CHANGE_PENDING_STATE_FILE:-}"
  set_runtime_paths
  if [[ -n "${pending_state_file}" ]]; then
    STATE_FILE="${pending_state_file}"
  fi
  save_last_project_root
  mkdir -p "$(dirname "${STATE_FILE}")"
  local state_temp_file
  state_temp_file="$(mktemp "$(dirname "${STATE_FILE}")/.install.state.XXXXXX")"
  if ! (
    umask 077
    cat > "${state_temp_file}" <<EOF
PROJECT_ROOT=$(shell_quote "${PROJECT_ROOT}")
REPOS_DIR=$(shell_quote "${REPOS_DIR}")
RUNTIME_DIR=$(shell_quote "${RUNTIME_DIR}")
STATE_DIR=$(shell_quote "${STATE_DIR}")
RELEASES_DIR=$(shell_quote "${RELEASES_DIR}")
BOT_REPO_URL=$(shell_quote "${BOT_REPO_URL}")
CABINET_REPO_URL=$(shell_quote "${CABINET_REPO_URL}")
BOT_REPO_DIR=$(shell_quote "${BOT_REPO_DIR}")
CABINET_REPO_DIR=$(shell_quote "${CABINET_REPO_DIR}")
BOT_RUNTIME_DIR=$(shell_quote "${BOT_RUNTIME_DIR}")
BOT_DATA_DIR=$(shell_quote "${BOT_DATA_DIR}")
BOT_LOGS_DIR=$(shell_quote "${BOT_LOGS_DIR}")
BOT_UPLOADS_DIR=$(shell_quote "${BOT_UPLOADS_DIR}")
CABINET_DIST_DIR=$(shell_quote "${CABINET_DIST_DIR}")
BOT_ENV_FILE=$(shell_quote "${BOT_ENV_FILE}")
BOT_OVERRIDE_ENV_FILE=$(shell_quote "${BOT_OVERRIDE_ENV_FILE}")
CABINET_ENV_FILE=$(shell_quote "${CABINET_ENV_FILE}")
COMPOSE_FILE=$(shell_quote "${COMPOSE_FILE}")
CADDY_CANDIDATE_FILE=$(shell_quote "${CADDY_CANDIDATE_FILE}")
CADDY_SNIPPET_DIR=$(shell_quote "${CADDY_SNIPPET_DIR}")
CADDY_SNIPPET_FILE=$(shell_quote "${CADDY_SNIPPET_FILE}")
HOOK_DOMAIN=$(shell_quote "${HOOK_DOMAIN}")
APP_DOMAIN=$(shell_quote "${APP_DOMAIN}")
WEBHOOK_URL=$(shell_quote "${WEBHOOK_URL}")
CABINET_URL=$(shell_quote "${CABINET_URL}")
BOT_TOKEN=$(shell_quote "${BOT_TOKEN}")
BOT_USERNAME=$(shell_quote "${BOT_USERNAME}")
ADMIN_IDS=$(shell_quote "${ADMIN_IDS}")
REMNAWAVE_API_URL=$(shell_quote "${REMNAWAVE_API_URL}")
REMNAWAVE_API_KEY=$(shell_quote "${REMNAWAVE_API_KEY}")
REMNAWAVE_SECRET_KEY=$(shell_quote "${REMNAWAVE_SECRET_KEY}")
REMNAWAVE_WEBHOOK_SECRET=$(shell_quote "${REMNAWAVE_WEBHOOK_SECRET}")
REMNAWAVE_AUTH_TYPE=$(shell_quote "${REMNAWAVE_AUTH_TYPE}")
TIMEZONE=$(shell_quote "${TIMEZONE}")
DEFAULT_LANGUAGE=$(shell_quote "${DEFAULT_LANGUAGE}")
APP_NAME=$(shell_quote "${APP_NAME}")
APP_LOGO=$(shell_quote "${APP_LOGO}")
WEBHOOK_SECRET_TOKEN=$(shell_quote "${WEBHOOK_SECRET_TOKEN}")
WEB_API_DEFAULT_TOKEN=$(shell_quote "${WEB_API_DEFAULT_TOKEN}")
CABINET_JWT_SECRET=$(shell_quote "${CABINET_JWT_SECRET}")
POSTGRES_DB=$(shell_quote "${POSTGRES_DB}")
POSTGRES_USER=$(shell_quote "${POSTGRES_USER}")
POSTGRES_PASSWORD=$(shell_quote "${POSTGRES_PASSWORD}")
POSTGRES_IMAGE=$(shell_quote "${POSTGRES_IMAGE}")
REDIS_URL=$(shell_quote "${REDIS_URL}")
REDIS_IMAGE=$(shell_quote "${REDIS_IMAGE}")
BOT_HTTP_PORT=$(shell_quote "${BOT_HTTP_PORT}")
COMPOSE_PROJECT_NAME=$(shell_quote "${COMPOSE_PROJECT_NAME}")
BOT_RUN_MODE=$(shell_quote "${BOT_RUN_MODE}")
WEB_API_ENABLED=$(shell_quote "${WEB_API_ENABLED}")
CABINET_ENABLED=$(shell_quote "${CABINET_ENABLED}")
CABINET_EMAIL_AUTH_ENABLED=$(shell_quote "${CABINET_EMAIL_AUTH_ENABLED}")
CABINET_EMAIL_VERIFICATION_ENABLED=$(shell_quote "${CABINET_EMAIL_VERIFICATION_ENABLED}")
BOT_VERSION_REF=$(shell_quote "${BOT_VERSION_REF}")
CABINET_VERSION_REF=$(shell_quote "${CABINET_VERSION_REF}")
LAST_BOT_VERSION_REF=$(shell_quote "${LAST_BOT_VERSION_REF:-}")
LAST_CABINET_VERSION_REF=$(shell_quote "${LAST_CABINET_VERSION_REF:-}")
RELEASE_MANIFEST_SOURCE=$(shell_quote "${RELEASE_MANIFEST_SOURCE:-}")
CURRENT_RELEASE=$(shell_quote "${CURRENT_RELEASE:-}")
CURRENT_RELEASE_BUNDLE_IDENTITY=$(shell_quote "${CURRENT_RELEASE_BUNDLE_IDENTITY:-}")
CURRENT_CABINET_ARTIFACT_SHA256=$(shell_quote "${CURRENT_CABINET_ARTIFACT_SHA256:-}")
LAST_RELEASE_BUNDLE_IDENTITY=$(shell_quote "${LAST_RELEASE_BUNDLE_IDENTITY:-}")
LAST_CABINET_ARTIFACT_SHA256=$(shell_quote "${LAST_CABINET_ARTIFACT_SHA256:-}")
EOF
  ); then
    rm -f "${state_temp_file}"
    return 1
  fi
  mv -f "${state_temp_file}" "${STATE_FILE}"
  secure_private_file "${STATE_FILE}"
}

require_state_file() {
  resolve_state_file
  [[ -f "${STATE_FILE}" ]] || die "Файл состояния не найден. Сначала выполните установку или восстановите state из текущей установки."
  load_state
  set_runtime_paths
}

ensure_directories() {
  mkdir -p \
    "${REPOS_DIR}" \
    "${RUNTIME_DIR}" \
    "${STATE_DIR}" \
    "${RELEASES_DIR}" \
    "${BOT_DATA_DIR}" \
    "${BOT_DATA_DIR}/backups" \
    "${BOT_LOGS_DIR}" \
    "${BOT_UPLOADS_DIR}" \
    "${CABINET_DIST_DIR}"
}

ensure_runtime_permissions() {
  mkdir -p "${BOT_DATA_DIR}" "${BOT_DATA_DIR}/backups" "${BOT_LOGS_DIR}" "${BOT_UPLOADS_DIR}"
  chown -R 1000:1000 "${BOT_DATA_DIR}" "${BOT_LOGS_DIR}" "${BOT_UPLOADS_DIR}"
}

clone_or_update_repo() {
  local repo_url="$1"
  local target_dir="$2"
  local default_ref="${3:-main}"

  if [[ -d "${target_dir}/.git" ]]; then
    log_info "Обновление репозитория: ${target_dir}"
    git -C "${target_dir}" fetch --tags origin
  else
    log_info "Клонирование репозитория: ${repo_url}"
    git clone "${repo_url}" "${target_dir}"
  fi

  if [[ -n "${default_ref}" ]]; then
    git -C "${target_dir}" checkout "${default_ref}" >/dev/null 2>&1
  fi
}

latest_remote_tag() {
  local repo_url="$1"
  git ls-remote --tags --refs "${repo_url}" | awk -F/ '{print $3}' | sort -Vr | head -n 1
}

compose_cmd() {
  require_state_file
  local compose_args=(--project-name "${COMPOSE_PROJECT_NAME}" --env-file "${BOT_ENV_FILE}" -f "${COMPOSE_FILE}")
  local migration_override="${STATE_DIR}/migration-image.override.yml"
  if [[ -f "${migration_override}" ]]; then
    compose_args+=(-f "${migration_override}")
  fi
  docker compose "${compose_args[@]}" "$@"
}

require_docker_compose() {
  command_exists docker && docker compose version >/dev/null 2>&1
}

ensure_caddy_import() {
  local caddy_main="/etc/caddy/Caddyfile"
  local import_line="import /etc/caddy/conf.d/*.caddy"

  mkdir -p "${CADDY_SNIPPET_DIR}"
  [[ -f "${caddy_main}" ]] || touch "${caddy_main}"

  if ! grep -Fq "${import_line}" "${caddy_main}"; then
    printf '\n%s\n' "${import_line}" >> "${caddy_main}"
  fi
}

validate_caddy() {
  caddy validate --config /etc/caddy/Caddyfile >/dev/null
}

verify_caddy_public_postcheck() {
  local attempt
  local app_status
  local hook_status

  [[ -n "${APP_DOMAIN:-}" && -n "${HOOK_DOMAIN:-}" ]] || return 0
  for attempt in {1..12}; do
    app_status="$(public_https_status "https://${APP_DOMAIN}/" || true)"
    hook_status="$(public_https_status "https://${HOOK_DOMAIN}/" || true)"
    if [[ "${app_status}" == "200" && "${hook_status}" == "404" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

restore_caddy_candidate_backup() {
  local backup_file="${CADDY_SNIPPET_FILE}.rollback"
  local absent_marker="${CADDY_SNIPPET_FILE}.rollback-absent"

  if [[ -f "${backup_file}" ]]; then
    mv -f "${backup_file}" "${CADDY_SNIPPET_FILE}"
  elif [[ -f "${absent_marker}" ]]; then
    rm -f "${CADDY_SNIPPET_FILE}"
  else
    return 1
  fi
  rm -f "${absent_marker}"
}

commit_caddy_candidate() {
  rm -f "${CADDY_SNIPPET_FILE}.rollback" "${CADDY_SNIPPET_FILE}.rollback-absent"
}

reload_caddy() {
  local postcheck_mode="${1:-verify-public}"
  if ! validate_caddy \
    || ! systemctl reload caddy \
    || { [[ "${postcheck_mode}" != skip-public-postcheck ]] && ! verify_caddy_public_postcheck; }; then
    if restore_caddy_candidate_backup; then
      validate_caddy >/dev/null 2>&1 || true
      systemctl reload caddy >/dev/null 2>&1 || true
    fi
    return 1
  fi
  commit_caddy_candidate
}

install_caddy_candidate() {
  require_state_file
  [[ -f "${CADDY_CANDIDATE_FILE}" ]] || die "Сгенерированный кандидат конфига Caddy не найден: ${CADDY_CANDIDATE_FILE}"

  ensure_caddy_import
  mkdir -p "${CADDY_SNIPPET_DIR}"

  local backup_file="${CADDY_SNIPPET_FILE}.rollback"
  local absent_marker="${CADDY_SNIPPET_FILE}.rollback-absent"
  local staged_file
  rm -f "${backup_file}" "${absent_marker}"
  if [[ -f "${CADDY_SNIPPET_FILE}" ]]; then
    cp "${CADDY_SNIPPET_FILE}" "${backup_file}"
  else
    : > "${absent_marker}"
  fi

  staged_file="$(mktemp "${CADDY_SNIPPET_DIR}/.caddy-candidate.XXXXXX")" || return 1
  cp "${CADDY_CANDIDATE_FILE}" "${staged_file}"
  chmod 644 "${staged_file}"
  mv -f "${staged_file}" "${CADDY_SNIPPET_FILE}"
  if ! validate_caddy; then
    restore_caddy_candidate_backup || true
    die "Сгенерированный конфиг Caddy невалиден. Предыдущий конфиг восстановлен."
  fi
}

set_default_runtime_values() {
  load_state

  BOT_REPO_URL="${BOT_REPO_URL:-${DEFAULT_BOT_REPO_URL}}"
  CABINET_REPO_URL="${CABINET_REPO_URL:-${DEFAULT_CABINET_REPO_URL}}"
  PROJECT_ROOT="${PROJECT_ROOT:-${DEFAULT_PROJECT_ROOT}}"

  TIMEZONE="${TIMEZONE:-${DEFAULT_TIMEZONE}}"
  DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-ru}"
  APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
  APP_LOGO="${APP_LOGO:-${DEFAULT_APP_LOGO}}"

  POSTGRES_DB="${POSTGRES_DB:-${DEFAULT_POSTGRES_DB}}"
  POSTGRES_USER="${POSTGRES_USER:-${DEFAULT_POSTGRES_USER}}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${DEFAULT_POSTGRES_PASSWORD}}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_hex_secret 64)}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-${DEFAULT_POSTGRES_IMAGE}}"
  REDIS_URL="${REDIS_URL:-${DEFAULT_REDIS_URL}}"
  REDIS_IMAGE="${REDIS_IMAGE:-${DEFAULT_REDIS_IMAGE}}"
  BOT_HTTP_PORT="${BOT_HTTP_PORT:-${DEFAULT_BOT_HTTP_PORT}}"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(compose_project_name_for_root "${PROJECT_ROOT}")}"
  BOT_RUN_MODE="${BOT_RUN_MODE:-webhook}"
  WEB_API_ENABLED="${WEB_API_ENABLED:-true}"
  CABINET_ENABLED="${CABINET_ENABLED:-true}"
  CABINET_EMAIL_AUTH_ENABLED="${CABINET_EMAIL_AUTH_ENABLED:-false}"
  CABINET_EMAIL_VERIFICATION_ENABLED="${CABINET_EMAIL_VERIFICATION_ENABLED:-false}"
  REMNAWAVE_AUTH_TYPE="${REMNAWAVE_AUTH_TYPE:-api_key}"
  REMNAWAVE_SECRET_KEY="${REMNAWAVE_SECRET_KEY:-}"
  REMNAWAVE_WEBHOOK_SECRET="${REMNAWAVE_WEBHOOK_SECRET:-}"

  BOT_VERSION_REF="${BOT_VERSION_REF:-main}"
  CABINET_VERSION_REF="${CABINET_VERSION_REF:-main}"
  LAST_BOT_VERSION_REF="${LAST_BOT_VERSION_REF:-}"
  LAST_CABINET_VERSION_REF="${LAST_CABINET_VERSION_REF:-}"
  RELEASE_MANIFEST_SOURCE="${RELEASE_MANIFEST_SOURCE:-}"
  CURRENT_RELEASE="${CURRENT_RELEASE:-}"
  CURRENT_RELEASE_BUNDLE_IDENTITY="${CURRENT_RELEASE_BUNDLE_IDENTITY:-}"
  CURRENT_CABINET_ARTIFACT_SHA256="${CURRENT_CABINET_ARTIFACT_SHA256:-}"
  LAST_RELEASE_BUNDLE_IDENTITY="${LAST_RELEASE_BUNDLE_IDENTITY:-}"
  LAST_CABINET_ARTIFACT_SHA256="${LAST_CABINET_ARTIFACT_SHA256:-}"

  set_runtime_paths
}

current_repo_revision() {
  local repo_dir="$1"

  [[ -d "${repo_dir}/.git" ]] || return 0

  (
    cd "${repo_dir}"
    local tag
    tag="$(git describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "${tag}" ]]; then
      printf '%s' "${tag}"
    else
      git rev-parse --abbrev-ref HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
    fi
  )
}

check_port_listening() {
  local port="$1"
  ss -ltn "( sport = :${port} )" | grep -q ":${port}"
}

check_ports_available() {
  ! ss -ltn '( sport = :80 or sport = :443 )' | grep -Eq ':(80|443)\b'
}

check_ports_available_or_caddy_only() {
  local listeners
  listeners="$(ss -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | tail -n +2 || true)"

  [[ -z "${listeners}" ]] && return 0
  ! printf '%s\n' "${listeners}" | grep -Ev '"caddy"' >/dev/null
}

domain_resolves() {
  getent hosts "$1" >/dev/null 2>&1
}

get_local_ipv4_list() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
}

domain_points_to_local_machine() {
  local domain="$1"
  local local_ips resolved_ips

  local_ips="$(get_local_ipv4_list)"
  resolved_ips="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u)"

  [[ -n "${local_ips}" && -n "${resolved_ips}" ]] || return 1

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    grep -Fxq "${ip}" <<<"${resolved_ips}" && return 0
  done <<<"${local_ips}"

  return 1
}
