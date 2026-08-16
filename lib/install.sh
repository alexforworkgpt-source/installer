#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=lib/release_bundle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_bundle.sh"

assert_supported_os() {
  [[ -f /etc/os-release ]] || die "Не удалось определить операционную систему."
  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "Установщик поддерживает только Ubuntu."
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "Установщик протестирован для Ubuntu 24.04."
}

wait_for_package_manager() {
  local timeout_seconds="${1:-600}"
  local poll_seconds="${PACKAGE_MANAGER_POLL_SECONDS:-5}"
  local started_at
  local lock_file
  local locked
  local warned="false"
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  command_exists fuser \
    || die "Команда fuser нужна для безопасного ожидания package manager lock."
  started_at="$(date +%s)"
  while true; do
    locked="false"
    for lock_file in "${lock_files[@]}"; do
      if [[ -e "${lock_file}" ]] && fuser "${lock_file}" >/dev/null 2>&1; then
        locked="true"
        break
      fi
    done
    [[ "${locked}" == "true" ]] || return 0

    if [[ "${warned}" == "false" ]]; then
      log_warn "Другой apt/dpkg процесс ещё работает. Жду освобождения package manager lock."
      warned="true"
    fi
    if (( $(date +%s) - started_at >= timeout_seconds )); then
      die "Package manager lock не освободился за ${timeout_seconds} секунд."
    fi
    sleep "${poll_seconds}"
  done
}

install_base_packages() {
  log_info "Установка базовых пакетов."
  wait_for_package_manager
  apt-get update
  wait_for_package_manager
  apt-get -o DPkg::Lock::Timeout=600 install -y ca-certificates curl git jq gnupg lsb-release caddy openssl python3 ufw util-linux
}

install_docker_engine() {
  if command_exists docker; then
    log_info "Docker уже установлен."
    return 0
  fi

  log_info "Установка Docker Engine."
  wait_for_package_manager
  curl -fsSL https://get.docker.com | sh
}

ensure_docker_compose_plugin() {
  if require_docker_compose; then
    log_info "Плагин Docker Compose уже установлен."
    return 0
  fi

  log_info "Установка плагина Docker Compose."
  wait_for_package_manager
  apt-get -o DPkg::Lock::Timeout=600 install -y docker-compose-plugin >/dev/null 2>&1 \
    || apt-get -o DPkg::Lock::Timeout=600 install -y docker-compose-v2 >/dev/null 2>&1 \
    || curl -fsSL https://get.docker.com | sh

  require_docker_compose || die "Плагин Docker Compose недоступен после установки."
}

enable_services() {
  log_info "Включаю и запускаю Docker и Caddy."
  systemctl enable --now docker
  systemctl enable --now caddy
}

preflight_install_checks() {
  require_state_file

  log_info "Запуск предварительных проверок."
  [[ "${HOOK_DOMAIN}" != "${APP_DOMAIN}" ]] || die "Webhook-домен и домен cabinet должны отличаться."
  is_valid_domain "${HOOK_DOMAIN}" || die "Некорректный webhook-домен: ${HOOK_DOMAIN}"
  is_valid_domain "${APP_DOMAIN}" || die "Некорректный домен cabinet: ${APP_DOMAIN}"
  is_valid_port "${BOT_HTTP_PORT}" || die "Некорректный HTTP-порт бота: ${BOT_HTTP_PORT}"
  check_ports_available_or_caddy_only || die "Порты 80/443 заняты процессом, отличным от Caddy."
}

preflight_deploy_checks() {
  require_state_file

  log_info "Проверка перед деплоем."
  [[ -n "${BOT_TOKEN:-}" ]] || die "BOT_TOKEN не настроен."
  [[ -n "${REMNAWAVE_API_URL:-}" ]] || die "REMNAWAVE_API_URL не настроен."
  [[ -n "${REMNAWAVE_API_KEY:-}" ]] || die "REMNAWAVE_API_KEY не настроен."
  [[ -n "${REMNAWAVE_SECRET_KEY:-}" ]] || die "REMNAWAVE_SECRET_KEY не настроен."
  require_docker_compose || die "Плагин Docker Compose недоступен."
  is_valid_domain "${HOOK_DOMAIN}" || die "Некорректный webhook-домен: ${HOOK_DOMAIN}"
  is_valid_domain "${APP_DOMAIN}" || die "Некорректный домен cabinet: ${APP_DOMAIN}"
  domain_resolves "${HOOK_DOMAIN}" || die "Webhook-домен пока не резолвится: ${HOOK_DOMAIN}"
  domain_resolves "${APP_DOMAIN}" || die "Домен cabinet пока не резолвится: ${APP_DOMAIN}"
  [[ "${HOOK_DOMAIN}" != "${APP_DOMAIN}" ]] || die "Webhook-домен и домен cabinet должны отличаться."
  is_valid_port "${BOT_HTTP_PORT}" || die "Некорректный HTTP-порт бота: ${BOT_HTTP_PORT}"
}

clone_required_repos() {
  require_state_file
  clone_or_update_repo "${BOT_REPO_URL}" "${BOT_REPO_DIR}" "${BOT_VERSION_REF}"
  verify_release_checkout "${BOT_REPO_DIR}" "${BOT_VERSION_REF}"
  clone_or_update_repo "${CABINET_REPO_URL}" "${CABINET_REPO_DIR}" "${CABINET_VERSION_REF}"
  verify_release_checkout "${CABINET_REPO_DIR}" "${CABINET_VERSION_REF}"
}

prepare_fresh_install_release() {
  local manifest_source

  manifest_source="$(prompt_optional_input \
    "Release Bundle manifest" \
    "HTTPS URL или локальный путь к release.json" \
    "https://github.com/OWNER/installer/releases/download/v1/release.json" \
    "${RELEASE_MANIFEST_SOURCE:-}")"
  [[ -n "${manifest_source}" ]] || {
    log_error "Fresh install требует Release Bundle manifest."
    return 1
  }

  FRESH_RELEASE_WORK_DIR="$(mktemp -d)" || return 1
  prepare_release_bundle "${manifest_source}" "${FRESH_RELEASE_WORK_DIR}" || return 1
}

cleanup_fresh_install_release() {
  if [[ -n "${FRESH_RELEASE_WORK_DIR:-}" && -d "${FRESH_RELEASE_WORK_DIR}" ]]; then
    rm -rf "${FRESH_RELEASE_WORK_DIR}"
  fi
  unset FRESH_RELEASE_WORK_DIR
}

cleanup_failed_first_install() {
  local failed_project_root=""
  local verified_project_root=""
  local running_services=""
  local marker_file
  local transaction_id
  local expected_root_identity
  local current_root_identity
  local ownership_value

  resolve_state_file
  PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$(dirname "${STATE_FILE}")")}"
  reset_project_root_paths
  set_runtime_paths
  [[ -e "${PROJECT_ROOT}" ]] || return 0
  marker_file="${STATE_DIR}/runtime-change.in-progress"
  [[ -f "${marker_file}" ]] || return 1
  grep -Fxq operation=first-install "${marker_file}" || return 1
  transaction_id="$(awk -F= '$1 == "transaction_id" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  expected_root_identity="$(awk -F= '$1 == "root_identity" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  [[ "${transaction_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "${expected_root_identity}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  current_root_identity="$(stat -c '%d:%i' "${PROJECT_ROOT}")" || return 1
  [[ "${current_root_identity}" == "${expected_root_identity}" ]] || return 1
  is_safe_first_install_parent "$(dirname "${PROJECT_ROOT}")" || return 1
  command_exists mountpoint || return 1
  mountpoint -q "${PROJECT_ROOT}" && return 1
  verified_project_root="${PROJECT_ROOT}"
  [[ -f "${STATE_DIR}/project-root-created-by-installer" ]] || return 1
  ownership_value="$(<"${STATE_DIR}/project-root-created-by-installer")"
  [[ "${ownership_value}" == \
    "created-by-bedolaga-installer:${transaction_id}:${expected_root_identity}" ]] || return 1
  if [[ ! -f "${STATE_FILE}" \
    && -f "${STATE_DIR}/install.state.pending-first-install" ]]; then
    RUNTIME_CHANGE_PENDING_STATE_FILE="${STATE_DIR}/install.state.pending-first-install"
    export RUNTIME_CHANGE_PENDING_STATE_FILE
    STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE_FILE}"
  fi
  if [[ ! -f "${STATE_FILE}" ]]; then
    is_safe_project_root "${PROJECT_ROOT}" || return 1
    [[ "$(stat -c '%d:%i' "${PROJECT_ROOT}")" == "${expected_root_identity}" ]] \
      || return 1
    is_safe_first_install_parent "$(dirname "${PROJECT_ROOT}")" || return 1
    mountpoint -q "${PROJECT_ROOT}" && return 1
    safe_rm_rf_under "$(dirname "${PROJECT_ROOT}")" "${PROJECT_ROOT}" || return 1
    clear_last_project_root
    unset STATE_DIR STATE_FILE PROJECT_ROOT RUNTIME_CHANGE_PENDING_STATE_FILE
    return 0
  fi
  load_state || return 1
  [[ "${PROJECT_ROOT}" == "${verified_project_root}" ]] || return 1
  failed_project_root="${verified_project_root}"

  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose_cmd stop bot >/dev/null 2>&1 || return 1
    running_services="$(compose_cmd ps --status running --services 2>/dev/null)" \
      || return 1
    ! grep -Fxq bot <<<"${running_services}" || return 1
    compose_cmd down -v --remove-orphans >/dev/null 2>&1 || return 1
  fi
  if [[ -f "${STATE_DIR}/telegram-webhook-managed" ]]; then
    delete_telegram_webhook_for_polling || return 1
  fi
  if [[ -f "${CADDY_SNIPPET_FILE}" ]]; then
    rm -f "${CADDY_SNIPPET_FILE}" || return 1
    reload_caddy >/dev/null 2>&1 || return 1
  fi
  is_safe_project_root "${failed_project_root}" || return 1
  [[ "$(stat -c '%d:%i' "${failed_project_root}")" == "${expected_root_identity}" ]] \
    || return 1
  is_safe_first_install_parent "$(dirname "${failed_project_root}")" || return 1
  mountpoint -q "${failed_project_root}" && return 1
  safe_rm_rf_under "$(dirname "${failed_project_root}")" "${failed_project_root}"
  clear_last_project_root
  unset STATE_DIR STATE_FILE PROJECT_ROOT RUNTIME_CHANGE_PENDING_STATE_FILE
}

is_safe_first_install_parent() {
  local parent_dir="$1"
  local canonical_parent
  local current_dir
  local owner_uid
  local mode

  [[ -d "${parent_dir}" && ! -L "${parent_dir}" ]] || return 1
  canonical_parent="$(realpath -e "${parent_dir}")" || return 1
  [[ "${canonical_parent}" == "${parent_dir}" ]] || return 1
  current_dir="${canonical_parent}"
  while true; do
    [[ -d "${current_dir}" && ! -L "${current_dir}" ]] || return 1
    owner_uid="$(stat -c '%u' "${current_dir}")" || return 1
    mode="$(stat -c '%a' "${current_dir}")" || return 1
    [[ "${owner_uid}" == 0 ]] || return 1
    (( (8#${mode} & 8#022) == 0 )) || return 1
    [[ "${current_dir}" == / ]] && return 0
    current_dir="$(dirname "${current_dir}")"
  done
}

prepare_first_install_project() {
  local transaction_id
  local root_identity
  local ownership_file
  local parent_dir

  [[ "${CONFIGURATION_CREATES_PROJECT_ROOT:-false}" == true ]] \
    || die "Первая установка требует новый project root."
  parent_dir="$(dirname "${PROJECT_ROOT}")"
  is_safe_first_install_parent "${parent_dir}" \
    || die "Parent каталога установки должен существовать, принадлежать root и не быть доступен для записи другим пользователям: ${parent_dir}"
  mkdir "${PROJECT_ROOT}" \
    || die "Не удалось эксклюзивно создать новый project root: ${PROJECT_ROOT}"
  set_runtime_paths
  mkdir "${STATE_DIR}"
  transaction_id="$(generate_hex_secret 32)"
  [[ "${transaction_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  root_identity="$(stat -c '%d:%i' "${PROJECT_ROOT}")" || return 1
  ownership_file="${STATE_DIR}/project-root-created-by-installer"
  (
    umask 077
    printf 'created-by-bedolaga-installer:%s:%s\n' \
      "${transaction_id}" "${root_identity}" > "${ownership_file}"
  )
  secure_private_file "${ownership_file}"
  FIRST_INSTALL_TRANSACTION_ID="${transaction_id}"
  FIRST_INSTALL_ROOT_IDENTITY="${root_identity}"
  write_first_install_marker "${STATE_DIR}/install.state.pending-first-install" empty-project
  ensure_directories
}

write_first_install_marker() {
  local pending_state="$1"
  local recovery_point="${2:-empty-project}"
  local expected_state_sha256="${3:-}"
  local marker_file="${STATE_DIR}/runtime-change.in-progress"
  local marker_temp="${marker_file}.tmp"
  local transaction_id="${FIRST_INSTALL_TRANSACTION_ID:-}"
  local root_identity="${FIRST_INSTALL_ROOT_IDENTITY:-}"

  if [[ -f "${marker_file}" ]]; then
    transaction_id="$(awk -F= '$1 == "transaction_id" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
    root_identity="$(awk -F= '$1 == "root_identity" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  fi
  [[ "${transaction_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "${root_identity}" =~ ^[0-9]+:[0-9]+$ ]] || return 1

  save_last_project_root
  (
    umask 077
    {
      printf 'operation=first-install\n'
      printf 'recovery_point=%s\n' "${recovery_point}"
      printf 'context_file=%s\n' "${pending_state}"
      printf 'transaction_id=%s\n' "${transaction_id}"
      printf 'root_identity=%s\n' "${root_identity}"
      printf 'expected_state_sha256=%s\n' "${expected_state_sha256}"
    } > "${marker_temp}"
  )
  mv -f "${marker_temp}" "${marker_file}"
  secure_private_file "${marker_file}"
  sync -f "${marker_file}"
  sync -f "${STATE_DIR}"
}

commit_first_install_state() {
  local pending_state="${STATE_DIR}/install.state.pending-first-install"
  local applied_state="${STATE_DIR}/install.state"
  local expected_state_sha256

  [[ -f "${pending_state}" ]]
  expected_state_sha256="$(file_sha256 "${pending_state}")" || return 1
  sync -f "${pending_state}"
  write_first_install_marker \
    "${pending_state}" committing "${expected_state_sha256}" || return 1
  mv -f "${pending_state}" "${applied_state}"
  secure_private_file "${applied_state}"
  unset RUNTIME_CHANGE_PENDING_STATE_FILE
  STATE_FILE="${applied_state}"
  sync -f "${applied_state}"
  sync -f "${STATE_DIR}"
}

finalize_first_install_commit() {
  local marker_file="${STATE_DIR}/runtime-change.in-progress"
  local expected_state_sha256
  [[ -f "${marker_file}" ]]
  grep -Fxq recovery_point=committing "${marker_file}"
  expected_state_sha256="$(awk -F= '$1 == "expected_state_sha256" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  [[ "${expected_state_sha256}" =~ ^[0-9a-f]{64}$ ]]
  [[ "$(file_sha256 "${STATE_DIR}/install.state")" == "${expected_state_sha256}" ]]
  rm -f "${marker_file}"
  sync -f "${STATE_DIR}"
}

recover_first_install_commit() {
  local marker_file="${STATE_DIR}/runtime-change.in-progress"
  local pending_state="${STATE_DIR}/install.state.pending-first-install"
  local applied_state="${STATE_DIR}/install.state"
  local expected_state_sha256

  [[ -f "${marker_file}" ]]
  grep -Fxq recovery_point=committing "${marker_file}"
  expected_state_sha256="$(awk -F= '$1 == "expected_state_sha256" {print substr($0, index($0, "=") + 1); exit}' "${marker_file}")"
  [[ "${expected_state_sha256}" =~ ^[0-9a-f]{64}$ ]]

  if [[ -f "${applied_state}" ]]; then
    [[ "$(file_sha256 "${applied_state}")" == "${expected_state_sha256}" ]] || return 1
    unset RUNTIME_CHANGE_PENDING_STATE_FILE
    STATE_FILE="${applied_state}"
    load_state
  elif [[ -f "${pending_state}" ]]; then
    [[ "$(file_sha256 "${pending_state}")" == "${expected_state_sha256}" ]] || return 1
    RUNTIME_CHANGE_PENDING_STATE_FILE="${pending_state}"
    export RUNTIME_CHANGE_PENDING_STATE_FILE
    STATE_FILE="${pending_state}"
    load_state
    wait_for_runtime_ready 60 3
    verify_runtime_health
    mv -f "${pending_state}" "${applied_state}"
    unset RUNTIME_CHANGE_PENDING_STATE_FILE
    STATE_FILE="${applied_state}"
    sync -f "${applied_state}"
    sync -f "${STATE_DIR}"
  else
    return 1
  fi
  wait_for_runtime_ready 60 3
  verify_runtime_health
}

restore_state_from_runtime() {
  ensure_root

  local project_root="${PROJECT_ROOT:-${DEFAULT_PROJECT_ROOT}}"
  local runtime_state_file="${project_root}/state/install.state"
  local bot_env="${project_root}/state/bot.env"
  local cabinet_env="${project_root}/state/cabinet.env"

  [[ -f "${bot_env}" ]] || die "Файл не найден: ${bot_env}. Восстановление state невозможно."
  [[ -f "${cabinet_env}" ]] || die "Файл не найден: ${cabinet_env}. Восстановление state невозможно."
  mkdir -p "$(dirname "${runtime_state_file}")"

  local guessed_bot_repo_dir="${project_root}/repos/bot-backend"
  local guessed_cabinet_repo_dir="${project_root}/repos/bot-cabinet"

  local guessed_bot_repo_url="${DEFAULT_BOT_REPO_URL}"
  local guessed_cabinet_repo_url="${DEFAULT_CABINET_REPO_URL}"
  if [[ -d "${guessed_bot_repo_dir}/.git" ]]; then
    guessed_bot_repo_url="$(git -C "${guessed_bot_repo_dir}" remote get-url origin 2>/dev/null || printf '%s' "${DEFAULT_BOT_REPO_URL}")"
  fi
  if [[ -d "${guessed_cabinet_repo_dir}/.git" ]]; then
    guessed_cabinet_repo_url="$(git -C "${guessed_cabinet_repo_dir}" remote get-url origin 2>/dev/null || printf '%s' "${DEFAULT_CABINET_REPO_URL}")"
  fi

  run_env_helper restore-state \
    "${project_root}" \
    "${runtime_state_file}" \
    "${bot_env}" \
    "${cabinet_env}" \
    "${guessed_bot_repo_url}" \
    "${guessed_cabinet_repo_url}" \
    "${guessed_bot_repo_dir}" \
    "${guessed_cabinet_repo_dir}"
  secure_private_file "${runtime_state_file}"

  PROJECT_ROOT="${project_root}"
  reset_project_root_paths
  set_runtime_paths
  save_last_project_root
  log_info "State восстановлен: ${STATE_FILE}."
}

write_first_install_context_value() {
  local context_dir="$1"
  local key="$2"
  local value="$3"
  local target="${context_dir}/${key}"
  local temporary="${target}.tmp"

  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  (
    umask 077
    printf '%s\n' "${value}" > "${temporary}"
  )
  mv -f "${temporary}" "${target}"
  secure_private_file "${target}"
  sync -f "${target}"
  sync -f "${context_dir}"
}

first_install_context_value() {
  local context_dir="$1"
  local key="$2"
  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  [[ -f "${context_dir}/${key}" ]] || return 1
  < "${context_dir}/${key}" tr -d '\n'
}

run_first_install_transaction() {
  local context_dir="$1"
  local result_json
  local outcome
  local runtime_change_adapter="${RUNTIME_CHANGE_ADAPTER:-${INSTALLER_DIR}/lib/runtime_change_adapter.sh}"
  local result_state_dir="${STATE_DIR}"

  if result_json="$(run_python \
    "${INSTALLER_DIR}/lib/runtime_change.py" run-command \
    "first install" \
    "$(installer_log_file)" \
    -- \
    "${BASH:-bash}" "${runtime_change_adapter}" \
    first-install "${STATE_DIR}" "${context_dir}")"; then
    :
  else
    [[ -n "${result_json}" ]] || return 1
  fi
  outcome="$(run_python -c 'import json,sys; print(json.load(sys.stdin)["outcome"])' \
    <<<"${result_json}")" || return 1
  if [[ "${outcome}" == rolled_back || ! -d "${PROJECT_ROOT}" ]]; then
    result_state_dir="${GLOBAL_INSTALLER_STATE_DIR}"
  fi
  STATE_DIR="${result_state_dir}"
  persist_runtime_change_result_json "${result_json}" || return 1
  sync -f "${STATE_DIR}/last-runtime-change.json"
  sync -f "${STATE_DIR}"

  if [[ "${outcome}" == committed ]]; then
    STATE_DIR="$(dirname "$(first_install_context_value "${context_dir}" applied-state)")"
    PROJECT_ROOT="$(dirname "${STATE_DIR}")"
    STATE_FILE="${STATE_DIR}/install.state"
    finalize_first_install_commit || return 1
    safe_rm_rf_under "${STATE_DIR}" "${context_dir}"
    return 0
  fi
  return 1
}

full_install_once() {
  local context_dir
  trap cleanup_fresh_install_release RETURN
  ensure_root || return 1
  assert_supported_os || return 1
  set_default_runtime_values || return 1
  # Do not create an unaccepted project root while logging host/release preparation.
  reset_project_root_paths
  install_base_packages || return 1
  install_docker_engine || return 1
  ensure_docker_compose_plugin || return 1
  prepare_fresh_install_release || return 1
  BOT_VERSION_REF="${PREPARED_BOT_SHA}"
  CABINET_REPO_URL="${PREPARED_CABINET_REPO_URL}"
  CABINET_VERSION_REF="${PREPARED_CABINET_SHA}"
  POSTGRES_IMAGE="${PREPARED_POSTGRES_IMAGE}"
  REDIS_IMAGE="${PREPARED_REDIS_IMAGE}"
  configure_stack pending-first-install || return 1
  set_runtime_paths
  context_dir="${STATE_DIR}/.first-install-context"
  mkdir -p "${context_dir}"
  write_first_install_context_value \
    "${context_dir}" pending-state "${STATE_DIR}/install.state.pending-first-install"
  write_first_install_context_value \
    "${context_dir}" applied-state "${STATE_DIR}/install.state"
  write_first_install_context_value \
    "${context_dir}" release "${PREPARED_RELEASE}"
  write_first_install_context_value \
    "${context_dir}" bundle-identity "${PREPARED_BUNDLE_IDENTITY}"
  write_first_install_context_value \
    "${context_dir}" artifact-file "${PREPARED_CABINET_ARTIFACT_FILE}"
  write_first_install_context_value \
    "${context_dir}" artifact-sha256 "${PREPARED_CABINET_ARTIFACT_SHA256}"
  write_first_install_context_value \
    "${context_dir}" manifest-source "${PREPARED_MANIFEST_SOURCE}"
  run_first_install_transaction "${context_dir}"
}

full_install() {
  ensure_root
  assert_supported_os

  local fallback_result_file="${GLOBAL_INSTALLER_STATE_DIR}/last-runtime-change.json"
  local failed_project_root=""
  local remembered_project_root=""
  local initial_result_file=""
  local initial_result_identity=""
  local previous_result_file=""
  local previous_result_identity=""
  local current_result_file=""
  local current_result_identity=""

  resolve_state_file
  if [[ -f "${STATE_FILE}" ]]; then
    require_state_file
    declare -F update_from_release_bundle >/dev/null \
      || die "Protected Update flow недоступен. Перезапустите installer из полного комплекта файлов."
    log_info "Найдена существующая установка. Повторная установка выполняется как Protected Update."
    update_from_release_bundle
    return $?
  fi

  initial_result_file="$(dirname "${STATE_FILE}")/last-runtime-change.json"
  if [[ -f "${initial_result_file}" ]]; then
    initial_result_identity="$(stat -c '%d:%i' "${initial_result_file}")" || return 1
  fi
  remembered_project_root="$(read_last_project_root || true)"
  if [[ -n "${remembered_project_root}" \
    && -f "${remembered_project_root}/state/last-runtime-change.json" ]]; then
    previous_result_file="${remembered_project_root}/state/last-runtime-change.json"
    previous_result_identity="$(stat -c '%d:%i' "${previous_result_file}")" || return 1
  fi
  rm -f "${fallback_result_file}"

  if (full_install_once); then
    resolve_state_file
    require_state_file
    log_info "Runtime Change committed: установка завершена и проверена."
    return 0
  fi

  failed_project_root="$(read_last_project_root || true)"
  if [[ -n "${failed_project_root}" \
    && ( -f "${failed_project_root}/state/last-runtime-change.json" \
      || -f "${failed_project_root}/state/runtime-change.in-progress" ) ]]; then
    PROJECT_ROOT="${failed_project_root}"
    reset_project_root_paths
    set_runtime_paths
  fi
  resolve_state_file
  PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$(dirname "${STATE_FILE}")")}"
  reset_project_root_paths
  set_runtime_paths
  if [[ -f "${fallback_result_file}" ]]; then
    STATE_DIR="${GLOBAL_INSTALLER_STATE_DIR}"
    persist_runtime_change_result_json "$(<"${fallback_result_file}")"
    return 1
  fi
  current_result_file="${STATE_DIR}/last-runtime-change.json"
  if [[ -f "${current_result_file}" ]]; then
    current_result_identity="$(stat -c '%d:%i' "${current_result_file}")" || return 1
    if [[ !( "${current_result_file}" == "${initial_result_file}" \
        && "${current_result_identity}" == "${initial_result_identity}" ) \
      && !( "${current_result_file}" == "${previous_result_file}" \
        && "${current_result_identity}" == "${previous_result_identity}" ) ]]; then
      persist_runtime_change_result_json "$(<"${current_result_file}")"
      return 1
    fi
  fi
  if [[ -f "${STATE_DIR}/runtime-change.in-progress" ]]; then
    log_error "First-install transaction прервана; recovery выполнится при следующем запуске."
    return 1
  fi

  log_error "Первая установка завершилась до начала Runtime Change; runtime не изменён."
  return 1
}
