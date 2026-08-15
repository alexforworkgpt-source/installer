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
full_install
[[ "$(paste -sd, "${ORDER_LOG}")" == 'apply' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'safely_stopped' ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == 'rollback' ]]

printf '%s\n' 'Full install Runtime Change harness passed.'
