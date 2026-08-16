#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
ORDER_LOG="${TEMP_ROOT}/order.log"
INSTALLER_DIR="${SCRIPT_DIR}"
STATE_DIR="${TEMP_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
LAST_CREATED_SNAPSHOT_DIR="${STATE_DIR}/snapshots/before-install"
BOT_STATE_FILE="${TEMP_ROOT}/bot-state"
SELECTED_PROJECT_ROOT="${TEMP_ROOT}/selected-project"
FULL_INSTALL_FIXTURE="generic-failure"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STATE_DIR}"
printf '%s\n' state > "${STATE_FILE}"
printf '%s\n' running > "${BOT_STATE_FILE}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"

STATE_DIR="${TEMP_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
LAST_CREATED_SNAPSHOT_DIR="${STATE_DIR}/snapshots/before-install"
GLOBAL_INSTALLER_STATE_DIR="${TEMP_ROOT}/global-state"
GLOBAL_LAST_PROJECT_ROOT_FILE="${GLOBAL_INSTALLER_STATE_DIR}/last_project_root"
LAST_PROJECT_ROOT_FILE="${TEMP_ROOT}/last_project_root"

ensure_root() { :; }
assert_supported_os() { :; }
resolve_state_file() { :; }
require_state_file() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
installer_log_file() { printf '%s' "${TEMP_ROOT}/installer.log"; }
create_update_snapshot() {
  printf '%s\n' protect >> "${ORDER_LOG}"
  LAST_CREATED_SNAPSHOT_DIR="${STATE_DIR}/snapshots/before-install"
}
update_from_release_bundle() {
  printf '%s\n' protected-update >> "${ORDER_LOG}"
  LAST_RUNTIME_CHANGE_OUTCOME="rolled_back"
  LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED="true"
  return 1
}
full_install_once() {
  printf '%s\n' apply >> "${ORDER_LOG}"
  if [[ "${FULL_INSTALL_FIXTURE}" == preflight-rejection ]]; then
    PROJECT_ROOT="${SELECTED_PROJECT_ROOT}"
    reset_project_root_paths
    set_runtime_paths
    mkdir -p "${STATE_DIR}"
    printf '%s\n' operation=first-install > "${STATE_DIR}/runtime-change.in-progress"
    save_last_project_root
    record_runtime_change_result \
      "first install" "safely_stopped" "plan" \
      "preflight rejected fixture" "false" \
      "Fix the preflight rejection before retrying." "$(installer_log_file)"
  fi
  return 1
}
restore_snapshot_files_from_path() {
  [[ "$1" == "${LAST_CREATED_SNAPSHOT_DIR}" ]]
  printf '%s\n' rollback >> "${ORDER_LOG}"
}
activate_current_runtime() {
  printf '%s\n' verify-rollback >> "${ORDER_LOG}"
}
compose_cmd() {
  case "${1:-}" in
    ps)
      [[ "$(<"${BOT_STATE_FILE}")" == "running" ]] && printf '%s\n' bot
      return 0
      ;;
    stop)
      printf '%s\n' stopped > "${BOT_STATE_FILE}"
      ;;
  esac
}

full_install || true
[[ "$(<"${ORDER_LOG}")" == protected-update ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'rolled_back' ]]
[[ "${LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED}" == 'true' ]]

: > "${ORDER_LOG}"
rm -f "${STATE_FILE}"
printf '%s\n' running > "${BOT_STATE_FILE}"
unset LAST_RUNTIME_CHANGE_OUTCOME LAST_RUNTIME_CHANGE_FAILED_STAGE
if full_install; then
  printf '%s\n' 'Failure before first-install transaction was reported as successful cleanup.' >&2
  exit 1
fi
[[ "$(paste -sd, "${ORDER_LOG}")" == 'apply' ]]
[[ -z "${LAST_RUNTIME_CHANGE_OUTCOME:-}" ]]

: > "${ORDER_LOG}"
stale_project_root="${TEMP_ROOT}/stale-project"
PROJECT_ROOT="${stale_project_root}"
reset_project_root_paths
set_runtime_paths
mkdir -p "${STATE_DIR}"
record_runtime_change_result \
  "stale first install" "safely_stopped" "safe_stop" \
  "stale result fixture" "false" \
  "Ignore this stale result." "$(installer_log_file)"
save_last_project_root
LAST_RUNTIME_CHANGE_ERROR="current attempt sentinel"
if full_install; then
  printf '%s\n' 'Early failure with a stale result was reported as successful cleanup.' >&2
  exit 1
fi
[[ "${LAST_RUNTIME_CHANGE_ERROR}" == 'current attempt sentinel' ]]

: > "${ORDER_LOG}"
clear_last_project_root
PROJECT_ROOT="${TEMP_ROOT}/stale-project-without-locator"
reset_project_root_paths
set_runtime_paths
mkdir -p "${STATE_DIR}"
record_runtime_change_result \
  "unlocated stale first install" "safely_stopped" "safe_stop" \
  "unlocated stale result fixture" "false" \
  "Ignore this unlocated stale result." "$(installer_log_file)"
LAST_RUNTIME_CHANGE_ERROR="unlocated current attempt sentinel"
if full_install; then
  printf '%s\n' 'Early failure with an unlocated stale result was reported as successful cleanup.' >&2
  exit 1
fi
[[ "${LAST_RUNTIME_CHANGE_ERROR}" == 'unlocated current attempt sentinel' ]]

: > "${ORDER_LOG}"
FULL_INSTALL_FIXTURE="preflight-rejection"
PROJECT_ROOT="${TEMP_ROOT}/parent-default"
reset_project_root_paths
set_runtime_paths
if full_install; then
  printf '%s\n' 'Rejected first-install preflight reported a secondary cleanup success.' >&2
  exit 1
fi
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == plan ]]
[[ "${LAST_RUNTIME_CHANGE_ERROR}" == 'preflight rejected fixture' ]]

printf '%s\n' 'Full install Runtime Change harness passed.'
