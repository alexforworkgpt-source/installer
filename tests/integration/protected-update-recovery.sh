#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
ORDER_LOG="${TEMP_ROOT}/order.log"
PROTECTED_UPDATE_ADAPTER="${TEMP_ROOT}/protected-update-adapter.sh"
export ORDER_LOG

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STATE_DIR}"
printf '%s\n' state > "${STATE_FILE}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
resolve_state_file() { :; }
load_state() { :; }
log_warn() { :; }
installer_log_file() { printf '%s' "${TEMP_ROOT}/installer.log"; }

cat > "${PROTECTED_UPDATE_ADAPTER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="$1"
stage="$3"
printf '%s\n' "${stage}" >> "${ORDER_LOG}"
case "${stage}" in
  abort-protection)
    sed -i 's|^recovery_point=.*|recovery_point=protection-aborted|' \
      "${state_dir}/runtime-change.in-progress"
    ;;
  verify-rollback)
    sed -i 's|^recovery_point=.*|recovery_point=rolled-back|' \
      "${state_dir}/runtime-change.in-progress"
    ;;
  finalize-commit|finalize-terminal) rm -f "${state_dir}/runtime-change.in-progress" ;;
esac
EOF
chmod +x "${PROTECTED_UPDATE_ADAPTER}"

create_context() {
  local name="$1"
  local policy="$2"
  local context="${STATE_DIR}/${name}"
  mkdir -p "${context}"
  printf '%s\n' "${policy}" > "${context}/migration-policy"
  printf '%s\n' release-old > "${context}/previous-release-key"
  printf '%s\n' rev-old > "${context}/before-revision"
  printf '%s' "${context}"
}

write_marker() {
  local context="$1"
  local recovery_point="$2"
  cat > "${STATE_DIR}/runtime-change.in-progress" <<EOF
operation=protected-update
recovery_point=${recovery_point}
context_file=${context}
EOF
}

context="$(create_context .protected-update.rollback rollback-compatible)"
dump_reference="${STATE_DIR}/verified.dump"
printf '%s\n' dump > "${dump_reference}"
write_marker "${context}" "${dump_reference}"
recover_interrupted_runtime_change
[[ "$(paste -sd, "${ORDER_LOG}")" == 'rollback-release,restore-dump,verify-rollback,finalize-terminal' ]]
[[ ! -d "${context}" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == rolled_back ]]

: > "${ORDER_LOG}"
context="$(create_context .protected-update.pending rollback-compatible)"
write_marker "${context}" pending-dump
recover_interrupted_runtime_change
[[ "$(paste -sd, "${ORDER_LOG}")" == 'abort-protection,finalize-terminal' ]]
[[ ! -d "${context}" ]]

: > "${ORDER_LOG}"
context="$(create_context .protected-update.forward-pending forward-only)"
write_marker "${context}" pending-dump
recover_interrupted_runtime_change
[[ "$(paste -sd, "${ORDER_LOG}")" == 'abort-protection,finalize-terminal' ]]
[[ ! -d "${context}" ]]

: > "${ORDER_LOG}"
context="$(create_context .protected-update.forward forward-only)"
write_marker "${context}" "${dump_reference}"
if recover_interrupted_runtime_change; then
  printf '%s\n' 'Forward-only interrupted update was automatically rolled back.' >&2
  exit 1
fi
[[ "$(<"${ORDER_LOG}")" == safe-stop ]]
[[ -d "${context}" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == safely_stopped ]]

: > "${ORDER_LOG}"
rm -rf "${context}"
context="$(create_context .protected-update.committed rollback-compatible)"
write_marker "${context}" committed
recover_interrupted_runtime_change
[[ "$(paste -sd, "${ORDER_LOG}")" == 'verify-commit,finalize-commit' ]]
[[ ! -d "${context}" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == committed ]]

rm -f "${STATE_FILE}"
cat > "${STATE_DIR}/runtime-change.in-progress" <<EOF
operation=protected-update
recovery_point=pending-dump
context_file=${STATE_DIR}/.protected-update.missing-state
EOF
if recover_interrupted_runtime_change; then
  printf '%s\n' 'Runtime Change marker without install.state was ignored.' >&2
  exit 1
fi

printf '%s\n' 'Protected Update recovery harness passed.'
