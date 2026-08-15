#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
INSTALLER_GLOBAL_STATE_DIR="${TEMP_ROOT}/global-state"
export INSTALLER_GLOBAL_STATE_DIR
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state.pending-first-install"
CONTEXT_DIR="${STATE_DIR}/.first-install-context"
ORDER_LOG="${TEMP_ROOT}/order.log"
RUNTIME_CHANGE_ADAPTER="${TEMP_ROOT}/runtime-change-adapter.sh"
APPLY_RESULT="success"
FAIL_STAGE=""
export ORDER_LOG APPLY_RESULT FAIL_STAGE

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${CONTEXT_DIR}"
printf '%s\n' pending > "${STATE_FILE}"
printf '%s\n' "${STATE_DIR}/install.state" > "${CONTEXT_DIR}/applied-state"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state.pending-first-install"
CONTEXT_DIR="${STATE_DIR}/.first-install-context"
GLOBAL_INSTALLER_STATE_DIR="${TEMP_ROOT}/global-state"

cat > "${RUNTIME_CHANGE_ADAPTER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

stage="$4"
printf '%s\n' "${stage}" >> "${ORDER_LOG}"
if [[ "${FAIL_STAGE}" == "${stage}" ]]; then
  exit 1
fi
case "${stage}" in
  protect) printf '%s\n' empty-project ;;
  apply) [[ "${APPLY_RESULT}" == success ]] ;;
esac
EOF
chmod +x "${RUNTIME_CHANGE_ADAPTER}"

installer_log_file() { printf '%s' "${TEMP_ROOT}/installer.log"; }
secure_private_file() { chmod 600 "$1"; }
finalize_first_install_commit() { printf '%s\n' finalize >> "${ORDER_LOG}"; }
safe_rm_rf_under() { rm -rf "$2"; }

run_first_install_transaction "${CONTEXT_DIR}"
[[ "$(paste -sd, "${ORDER_LOG}")" == 'plan,protect,apply,verify,commit,finalize' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == committed ]]

: > "${ORDER_LOG}"
mkdir -p "${CONTEXT_DIR}"
printf '%s\n' "${STATE_DIR}/install.state" > "${CONTEXT_DIR}/applied-state"
for failed_stage in plan protect; do
  : > "${ORDER_LOG}"
  FAIL_STAGE="${failed_stage}"
  if run_first_install_transaction "${CONTEXT_DIR}"; then
    printf 'Failed first-install %s returned success.\n' "${failed_stage}" >&2
    exit 1
  fi
  expected="plan"
  [[ "${failed_stage}" == protect ]] && expected+=",protect"
  [[ "$(paste -sd, "${ORDER_LOG}")" == "${expected}" ]]
  [[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]
  [[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == "${failed_stage}" ]]
done

for failed_stage in apply verify commit; do
  : > "${ORDER_LOG}"
  FAIL_STAGE="${failed_stage}"
  if run_first_install_transaction "${CONTEXT_DIR}"; then
    printf 'Failed first-install %s returned success.\n' "${failed_stage}" >&2
    exit 1
  fi
  expected="plan,protect,apply"
  [[ "${failed_stage}" == verify || "${failed_stage}" == commit ]] \
    && expected+=",verify"
  [[ "${failed_stage}" == commit ]] && expected+=",commit"
  expected+=",rollback,verify-rollback"
  [[ "$(paste -sd, "${ORDER_LOG}")" == "${expected}" ]]
  [[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == rolled_back ]]
  [[ "${LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED}" == true ]]
done
[[ -f "${GLOBAL_INSTALLER_STATE_DIR}/last-runtime-change.json" ]]

: > "${ORDER_LOG}"
APPLY_RESULT="failure"
FAIL_STAGE="rollback"
if run_first_install_transaction "${CONTEXT_DIR}"; then
  printf '%s\n' 'Failed first-install rollback returned success.' >&2
  exit 1
fi
[[ "$(paste -sd, "${ORDER_LOG}")" == 'plan,protect,apply,rollback,safe-stop' ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]
[[ "${LAST_RUNTIME_CHANGE_FAILED_STAGE}" == rollback ]]

printf '%s\n' 'First install Runtime Change harness passed.'
