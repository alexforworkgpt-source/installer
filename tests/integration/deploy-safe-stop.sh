#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
ORDER_LOG="${TEMP_ROOT}/order.log"
BOT_STATE_FILE="${TEMP_ROOT}/bot-state"
RUNTIME_CHANGE_ADAPTER="${TEMP_ROOT}/runtime-change-adapter.sh"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"

INSTALLER_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
mkdir -p "${STATE_DIR}"
printf '%s\n' state > "${STATE_FILE}"
printf '%s\n' running > "${BOT_STATE_FILE}"

APPLY_RESULT="success"
ROLLBACK_RESULT="success"
SAFE_STOP_RESULT="success"
export APPLY_RESULT ROLLBACK_RESULT SAFE_STOP_RESULT ORDER_LOG BOT_STATE_FILE

cat > "${RUNTIME_CHANGE_ADAPTER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

stage="$3"
case "${stage}" in
  plan) printf '%s\n' plan >> "${ORDER_LOG}" ;;
  protect)
    printf '%s\n' protect >> "${ORDER_LOG}"
    printf '%s\n' snapshot-before-deploy
    ;;
  apply)
    printf '%s\n' apply >> "${ORDER_LOG}"
    [[ "${APPLY_RESULT}" == success ]]
    ;;
  verify) printf '%s\n' verify >> "${ORDER_LOG}" ;;
  commit) printf '%s\n' commit >> "${ORDER_LOG}" ;;
  rollback)
    printf '%s\n' rollback >> "${ORDER_LOG}"
    [[ "${ROLLBACK_RESULT}" == success ]]
    ;;
  verify-rollback) printf '%s\n' verify-rollback >> "${ORDER_LOG}" ;;
  safe-stop)
    printf '%s\n' safe-stop >> "${ORDER_LOG}"
    [[ "${SAFE_STOP_RESULT}" == success ]]
    printf '%s\n' stopped > "${BOT_STATE_FILE}"
    ;;
esac
EOF
chmod +x "${RUNTIME_CHANGE_ADAPTER}"

ensure_root() { :; }
require_state_file() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
installer_log_file() { printf '%s' "${TEMP_ROOT}/installer.log"; }
secure_private_file() { chmod 600 "$1"; }

deploy_stack
[[ "$(paste -sd, "${ORDER_LOG}")" == 'plan,protect,apply,verify,commit' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == committed ]]

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
ROLLBACK_RESULT="success"
deploy_stack
[[ "$(paste -sd, "${ORDER_LOG}")" == 'plan,protect,apply,rollback,verify-rollback' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == rolled_back ]]
[[ "${LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED}" == true ]]

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
ROLLBACK_RESULT="failure"
SAFE_STOP_RESULT="success"
deploy_stack
[[ "$(paste -sd, "${ORDER_LOG}")" == 'plan,protect,apply,rollback,safe-stop' ]]
[[ "$(<"${BOT_STATE_FILE}")" == stopped ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == rollback ]]

: > "${ORDER_LOG}"
SAFE_STOP_RESULT="failure"
deploy_stack
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == safe_stop ]]

printf '%s\n' 'Deploy Runtime Change harness passed.'
