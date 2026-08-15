#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
ORDER_LOG="${TEMP_ROOT}/order.log"
BOT_STATE_FILE="${TEMP_ROOT}/bot-state"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config_editor.sh
source "${SCRIPT_DIR}/lib/config_editor.sh"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
mkdir -p "${STATE_DIR}/draft"
printf '%s\n' state > "${STATE_FILE}"
printf '%s\n' running > "${BOT_STATE_FILE}"

ensure_root() { :; }
require_state_file() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
prompt_yes_no() { return 0; }
installer_log_file() { printf '%s' "${TEMP_ROOT}/installer.log"; }
secure_private_file() { chmod 600 "$1"; }

APPLY_RESULT="success"
ROLLBACK_RESULT="success"
PROTECT_RESULT="success"
RUNTIME_CHANGE_ADAPTER="${TEMP_ROOT}/runtime-change-adapter.sh"
export APPLY_RESULT ROLLBACK_RESULT PROTECT_RESULT ORDER_LOG BOT_STATE_FILE
cat > "${RUNTIME_CHANGE_ADAPTER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

operation="$1"
if [[ "${operation}" == settings ]]; then
  stage="$3"
else
  stage="$4"
fi
case "${stage}" in
  protect)
    printf '%s\n' protect >> "${ORDER_LOG}"
    [[ "${PROTECT_RESULT}" == success ]]
    printf '%s\n' snapshot-before-settings
    ;;
  apply)
    printf '%s\n' apply >> "${ORDER_LOG}"
    [[ "${APPLY_RESULT}" == success ]]
    ;;
  verify)
    printf '%s\n' verify >> "${ORDER_LOG}"
    ;;
  commit)
    printf '%s\n' commit >> "${ORDER_LOG}"
    ;;
  rollback)
    printf '%s\n' rollback >> "${ORDER_LOG}"
    [[ "${ROLLBACK_RESULT}" == success ]]
    ;;
  verify-rollback)
    printf '%s\n' verify-rollback >> "${ORDER_LOG}"
    rm -f "$2/runtime-change.in-progress"
    ;;
  safe-stop)
    printf '%s\n' stopped > "${BOT_STATE_FILE}"
    ;;
esac
EOF
chmod +x "${RUNTIME_CHANGE_ADAPTER}"
run_python() {
  local script="$1"
  local command_name="${2:-}"
  local cmd

  if [[ "${script}" == */installation_config.py ]]; then
    case "${command_name}" in
      plan-draft) printf '%s\n' 'APP_NAME: old -> new' ;;
      promote-draft) printf '%s\n' promote >> "${ORDER_LOG}" ;;
      replace-postgres-password)
        printf 'write-password:%s\n' "$4" >> "${ORDER_LOG}"
        if [[ "${WRITE_NEW_PASSWORD_RESULT:-success}" == "failure" && "$4" == "${NEW_PASSWORD:-}" ]]; then
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
    return 0
  fi

  cmd="$(python_cmd)" || return 1
  # shellcheck disable=SC2086
  ${cmd} "$@"
}

apply_settings_draft
[[ "$(paste -sd, "${ORDER_LOG}")" == 'protect,apply,verify,commit' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'committed' ]]

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
ROLLBACK_RESULT="success"
apply_settings_draft
[[ "$(paste -sd, "${ORDER_LOG}")" == 'protect,apply,rollback,verify-rollback' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'rolled_back' ]]
[[ "${LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED}" == 'true' ]]

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
ROLLBACK_RESULT="failure"
printf '%s\n' running > "${BOT_STATE_FILE}"
apply_settings_draft
[[ "$(<"${BOT_STATE_FILE}")" == 'stopped' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'safely_stopped' ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == 'rollback' ]]
[[ -f "${STATE_DIR}/last-runtime-change.json" ]]

POSTGRES_PASSWORD="old-password"
POSTGRES_USER="test-user"
POSTGRES_DB="test-db"
BOT_ENV_FILE="${STATE_DIR}/bot.env"
NEW_PASSWORD="nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"
generate_hex_secret() { printf '%s' "${NEW_PASSWORD}"; }

: > "${ORDER_LOG}"
APPLY_RESULT="success"
ROLLBACK_RESULT="success"
PROTECT_RESULT="success"
rotate_postgres_credentials_runtime
[[ "$(paste -sd, "${ORDER_LOG}")" == 'protect,apply,verify,commit' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'committed' ]]
if compgen -G "${STATE_DIR}/.postgres-rotation.*" >/dev/null; then
  exit 1
fi

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
ROLLBACK_RESULT="success"
rotate_postgres_credentials_runtime
[[ "$(paste -sd, "${ORDER_LOG}")" == 'protect,apply,rollback,verify-rollback' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'rolled_back' ]]

: > "${ORDER_LOG}"
APPLY_RESULT="success"
PROTECT_RESULT="failure"
printf '%s\n' running > "${BOT_STATE_FILE}"
rotate_postgres_credentials_runtime
[[ "$(<"${BOT_STATE_FILE}")" == 'running' ]]
if grep -Fxq apply "${ORDER_LOG}"; then
  printf '%s\n' 'Credential rotation mutated PostgreSQL after failed protection.' >&2
  exit 1
fi
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'safely_stopped' ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == 'protect' ]]

resolve_state_file() { :; }
load_state() { :; }
cat > "${STATE_DIR}/runtime-change.in-progress" <<EOF
operation=settings
recovery_point=${STATE_DIR}/snapshots/interrupted-settings
context_file=
EOF
: > "${ORDER_LOG}"
APPLY_RESULT="success"
ROLLBACK_RESULT="success"
PROTECT_RESULT="success"
recover_interrupted_runtime_change
[[ "$(paste -sd, "${ORDER_LOG}")" == 'rollback,verify-rollback' ]]
[[ ! -f "${STATE_DIR}/runtime-change.in-progress" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == 'rolled_back' ]]

printf '%s\n' 'Settings Runtime Change harness passed.'
