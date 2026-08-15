#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
INSTALLER_GLOBAL_STATE_DIR="${TEMP_ROOT}/global-installer-state"
export INSTALLER_GLOBAL_STATE_DIR
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
LAST_PROJECT_ROOT_FILE="${TEMP_ROOT}/last-project-root"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
LAST_PROJECT_ROOT_FILE="${TEMP_ROOT}/last-project-root"
CADDY_SNIPPET_FILE="${TEMP_ROOT}/no-live-caddy"
CADDY_CANDIDATE_FILE="${STATE_DIR}/bot-stack.caddy"

ensure_root() { :; }
collect_configuration() {
  CONFIGURATION_CREATES_PROJECT_ROOT="true"
}
print_configuration_summary() { :; }
prompt_yes_no() { return 0; }
render_all_configs() {
  [[ "${STATE_FILE}" == "${STATE_DIR}/install.state.pending-first-install" ]]
  [[ -f "${STATE_FILE}" ]]
  [[ ! -f "${STATE_DIR}/install.state" ]]
}
log_info() { :; }
log_error() { :; }
log_warn() { :; }
is_safe_project_root() { return 0; }
is_safe_first_install_parent() { return 0; }
safe_rm_rf_under() { rm -rf "$2"; }
mountpoint() { return 1; }

set_default_runtime_values
HOOK_DOMAIN="hooks.example.test"
APP_DOMAIN="app.example.test"
WEBHOOK_URL="https://${HOOK_DOMAIN}"
CABINET_URL="https://${APP_DOMAIN}"
BOT_TOKEN="1234567890:test-token"
BOT_USERNAME="test_bot"
ADMIN_IDS="123456789"
REMNAWAVE_API_URL="https://panel.example.test"
REMNAWAVE_API_KEY="api-key"
REMNAWAVE_SECRET_KEY="secret-key"
REMNAWAVE_WEBHOOK_SECRET="webhook-secret"
WEBHOOK_SECRET_TOKEN="webhook-token"
WEB_API_DEFAULT_TOKEN="api-token"
CABINET_JWT_SECRET="cabinet-token"

configure_stack pending-first-install
pending_state="${STATE_DIR}/install.state.pending-first-install"
marker_file="${STATE_DIR}/runtime-change.in-progress"
[[ -f "${pending_state}" ]]
[[ ! -f "${STATE_DIR}/install.state" ]]
grep -Fxq operation=first-install "${marker_file}"
grep -Fxq recovery_point=empty-project "${marker_file}"

commit_first_install_state
[[ -f "${STATE_DIR}/install.state" ]]
[[ ! -f "${pending_state}" ]]
grep -Fxq recovery_point=committing "${marker_file}"
finalize_first_install_commit
[[ ! -f "${marker_file}" ]]

rm -rf "${PROJECT_ROOT}"
mkdir -p "${PROJECT_ROOT}"
STATE_FILE="${PROJECT_ROOT}/state/install.state"
if cleanup_failed_first_install; then
  printf '%s\n' 'Unknown project root without transaction marker was accepted for cleanup.' >&2
  exit 1
fi
rm -rf "${PROJECT_ROOT}"
mkdir -p "${PROJECT_ROOT}"
CONFIGURATION_CREATES_PROJECT_ROOT="true"
if (prepare_first_install_project); then
  printf '%s\n' 'First install adopted a project root created during confirmation.' >&2
  exit 1
fi
rm -rf "${PROJECT_ROOT}"

CONFIGURATION_CREATES_PROJECT_ROOT="true"
prepare_first_install_project
mv "${PROJECT_ROOT}" "${TEMP_ROOT}/original-project"
mkdir -p "${STATE_DIR}"
cp "${TEMP_ROOT}/original-project/state/runtime-change.in-progress" \
  "${STATE_DIR}/runtime-change.in-progress"
cp "${TEMP_ROOT}/original-project/state/project-root-created-by-installer" \
  "${STATE_DIR}/project-root-created-by-installer"
STATE_FILE="${STATE_DIR}/install.state"
if cleanup_failed_first_install; then
  printf '%s\n' 'Replaced project root passed transaction ownership verification.' >&2
  exit 1
fi
rm -rf "${PROJECT_ROOT}" "${TEMP_ROOT}/original-project"

CONFIGURATION_CREATES_PROJECT_ROOT="true"
prepare_first_install_project
verified_project_root="${PROJECT_ROOT}"
printf 'PROJECT_ROOT=%q\n' "${TEMP_ROOT}/foreign-project" \
  > "${STATE_DIR}/install.state.pending-first-install"
load_state() {
  PROJECT_ROOT="${TEMP_ROOT}/foreign-project"
  reset_project_root_paths
  set_runtime_paths
}
if cleanup_failed_first_install; then
  printf '%s\n' 'Pending state redirected first-install cleanup to a foreign root.' >&2
  exit 1
fi
rm -rf "${verified_project_root}"
PROJECT_ROOT="${verified_project_root}"
reset_project_root_paths
set_runtime_paths

CONFIGURATION_CREATES_PROJECT_ROOT="true"
prepare_first_install_project
printf 'PROJECT_ROOT=%q\n' "${PROJECT_ROOT}" > "${pending_state}"
unset RUNTIME_CHANGE_PENDING_STATE_FILE
STATE_FILE="${STATE_DIR}/install.state"
load_state() { set_runtime_paths; }
expected_project_root="${PROJECT_ROOT}"
recover_interrupted_runtime_change
[[ ! -e "${expected_project_root}" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == rolled_back ]]

PROJECT_ROOT="${expected_project_root}"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
CONFIGURATION_CREATES_PROJECT_ROOT="true"
prepare_first_install_project
pending_state="${STATE_DIR}/install.state.pending-first-install"
printf 'PROJECT_ROOT=%q\n' "${PROJECT_ROOT}" > "${pending_state}"
RUNTIME_CHANGE_PENDING_STATE_FILE="${pending_state}"
export RUNTIME_CHANGE_PENDING_STATE_FILE
commit_first_install_state
wait_for_runtime_ready() { :; }
verify_runtime_health() { :; }
recover_interrupted_runtime_change
[[ ! -f "${STATE_DIR}/runtime-change.in-progress" ]]
[[ "${LAST_RUNTIME_CHANGE_OUTCOME}" == committed ]]

printf '%s\n' 'First install pending-state harness passed.'
