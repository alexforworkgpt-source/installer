#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="${TEMP_ROOT}/project"
INSTALLER_DIR="${SCRIPT_DIR}"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
CONTEXT_DIR="${STATE_DIR}/.protected-update.test"
BOT_STATE_FILE="${TEMP_ROOT}/bot-state"
ORDER_LOG="${TEMP_ROOT}/order.log"
marker_file="${STATE_DIR}/runtime-change.in-progress"
context_dir="${CONTEXT_DIR}"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

grep -Fq 'source "${SCRIPT_DIR}/lib/firewall.sh"' \
  "${SCRIPT_DIR}/lib/protected_update_adapter.sh"

mkdir -p "${CONTEXT_DIR}/previous-cabinet" "${PROJECT_ROOT}/runtime/cabinet-dist"
printf '%s\n' state > "${STATE_FILE}"
printf '%s\n' running > "${BOT_STATE_FILE}"
printf '%s\n' old > "${CONTEXT_DIR}/previous-cabinet/index.html"
printf '%s\n' new > "${CONTEXT_DIR}/cabinet-dist.tar.gz"
printf '%s\n' current > "${PROJECT_ROOT}/runtime/cabinet-dist/index.html"

write_value() {
  printf '%s\n' "$2" > "${CONTEXT_DIR}/$1"
}

write_value target-release release-new
write_value target-bundle-identity bundle-new
write_value target-bot-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
write_value target-cabinet-sha cccccccccccccccccccccccccccccccccccccccc
write_value target-artifact-file "${CONTEXT_DIR}/cabinet-dist.tar.gz"
write_value target-artifact-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_value target-postgres-image postgres@sha256:new
write_value target-redis-image redis@sha256:new
write_value target-manifest-source https://example.test/release.json
write_value migration-policy rollback-compatible
write_value previous-bot-sha 1111111111111111111111111111111111111111
write_value previous-cabinet-sha 2222222222222222222222222222222222222222
write_value previous-postgres-image postgres@sha256:old
write_value previous-redis-image redis@sha256:old
write_value previous-release release-old
write_value previous-release-key release-old
write_value previous-manifest-source https://example.test/previous.json
write_value previous-bundle-identity bundle-old
write_value previous-artifact-identity artifact-old
write_value previous-last-bundle-identity bundle-older
write_value previous-last-artifact-identity artifact-older
write_value previous-last-bot-ref bot-older
write_value previous-last-cabinet-ref cabinet-older

PROTECTED_UPDATE_ADAPTER_SOURCE_ONLY=true
# shellcheck source=lib/protected_update_adapter.sh
source "${SCRIPT_DIR}/lib/protected_update_adapter.sh"

BOT_REPO_DIR="${PROJECT_ROOT}/repos/bot"
CABINET_REPO_DIR="${PROJECT_ROOT}/repos/cabinet"
BOT_REPO_URL="https://example.test/bot.git"
CABINET_REPO_URL="https://example.test/cabinet.git"
CABINET_DIST_DIR="${PROJECT_ROOT}/runtime/cabinet-dist"
REVISION="rev-old"
INJECTED_STAGE=""

secure_private_file() { chmod 600 "$1"; }
file_sha256() { sha256sum "$1" | awk '{print $1}'; }
compose_cmd() {
  case "$*" in
    'ps --status running --services')
      [[ "$(<"${BOT_STATE_FILE}")" == running ]] && printf '%s\n' bot
      return 0
      ;;
    'stop bot')
      printf '%s\n' stopped > "${BOT_STATE_FILE}"
      printf '%s\n' stop-bot >> "${ORDER_LOG}"
      ;;
    *'up '*' bot'*)
      [[ "${INJECTED_STAGE}" != compose ]] || return 1
      printf '%s\n' running > "${BOT_STATE_FILE}"
      printf '%s\n' start-bot >> "${ORDER_LOG}"
      ;;
    *'up '*) printf '%s\n' start-data >> "${ORDER_LOG}" ;;
    'config -q') printf '%s\n' compose-config >> "${ORDER_LOG}" ;;
  esac
}
create_verified_update_dump() {
  local dump="${CONTEXT_DIR}/verified.dump"
  printf '%s\n' dump > "${dump}"
  printf '%s' "${dump}"
}
create_update_snapshot() {
  LAST_CREATED_SNAPSHOT_DIR="${CONTEXT_DIR}/snapshot"
  mkdir -p "${LAST_CREATED_SNAPSHOT_DIR}"
}
activate_current_runtime_once() { printf '%s\n' running > "${BOT_STATE_FILE}"; }
checkout_repo_ref() {
  [[ "${INJECTED_STAGE}" != checkout ]] || return 1
  printf 'checkout:%s\n' "$3" >> "${ORDER_LOG}"
}
verify_release_checkout() { printf 'verify-head:%s\n' "$2" >> "${ORDER_LOG}"; }
run_python() {
  [[ "${INJECTED_STAGE}" != cabinet ]] || return 1
  printf '%s\n' activate-cabinet >> "${ORDER_LOG}"
}
render_compose_file() { printf '%s\n' render-compose >> "${ORDER_LOG}"; }
reload_caddy() {
  [[ "${INJECTED_STAGE}" != caddy ]] || return 1
  printf '%s\n' caddy >> "${ORDER_LOG}"
}
apply_telegram_runtime_mode() {
  [[ "${INJECTED_STAGE}" != telegram ]] || return 1
  printf '%s\n' telegram >> "${ORDER_LOG}"
}
wait_for_runtime_ready() { :; }
verify_runtime_health() {
  [[ "${INJECTED_STAGE}" != health ]] || return 1
  printf '%s\n' health >> "${ORDER_LOG}"
}
current_alembic_revision() {
  [[ "${INJECTED_STAGE}" != migration ]] || return 0
  printf '%s' "${REVISION}"
}
mark_runtime_apply_state() { printf '%s\n' mark-applied >> "${ORDER_LOG}"; }
save_state() { printf '%s\n' "${CURRENT_RELEASE}" > "${TEMP_ROOT}/saved-release"; }
rollback_release_sources() { printf '%s\n' rollback-sources >> "${ORDER_LOG}"; }
safe_rm_rf_under() { rm -rf "$2"; }
restore_verified_update_dump() {
  [[ "$1" == "${CONTEXT_DIR}/verified.dump" ]]
  [[ "$2" == rev-old ]]
  REVISION="rev-old"
  printf '%s\n' restore-dump >> "${ORDER_LOG}"
}

run_current_revision_stage >/dev/null
dump_reference="$(run_create_dump_stage)"
[[ "${dump_reference}" == "${CONTEXT_DIR}/verified.dump" ]]
[[ "$(<"${BOT_STATE_FILE}")" == stopped ]]
[[ "$(context_value previous-bot-running)" == true ]]
[[ "$(context_value dump-reference)" == "${dump_reference}" ]]
grep -Fq "recovery_point=${dump_reference}" "${marker_file}"

run_apply_release_stage
REVISION="rev-new"
run_verify_release_stage
[[ "$(run_current_revision_stage)" == rev-new ]]
[[ "$(<"${BOT_STATE_FILE}")" == running ]]
run_commit_release_stage "${dump_reference}" rev-old rev-new
grep -Fq 'recovery_point=committed' "${marker_file}"
run_verify_commit_stage
run_finalize_commit_stage
[[ ! -f "${marker_file}" ]]
[[ "$(<"${TEMP_ROOT}/saved-release")" == release-new ]]
grep -Fq 'after_revision=rev-new' "${CONTEXT_DIR}/verified.metadata.txt"

: > "${ORDER_LOG}"
write_update_marker "${dump_reference}"
printf '%s\n' running > "${BOT_STATE_FILE}"
run_rollback_release_stage
run_restore_dump_stage "${dump_reference}" rev-old
run_verify_rollback_stage release-old rev-old "${dump_reference}"
grep -Fq 'recovery_point=rolled-back' "${marker_file}"
run_finalize_terminal_stage rolled-back
[[ ! -f "${marker_file}" ]]
[[ "$(<"${BOT_STATE_FILE}")" == running ]]
[[ "$(<"${TEMP_ROOT}/saved-release")" == release-old ]]
[[ "$(<"${CABINET_DIST_DIR}/index.html")" == old ]]
grep -Fxq rollback-sources "${ORDER_LOG}"
grep -Fxq restore-dump "${ORDER_LOG}"
grep -Fxq health "${ORDER_LOG}"

write_context_value previous-bot-running false
write_update_marker "${dump_reference}"
printf '%s\n' stopped > "${BOT_STATE_FILE}"
run_rollback_release_stage
run_restore_dump_stage "${dump_reference}" rev-old
run_verify_rollback_stage release-old rev-old "${dump_reference}"
[[ "$(<"${BOT_STATE_FILE}")" == stopped ]]
run_finalize_terminal_stage rolled-back
write_context_value previous-bot-running true

assert_stage_failure() {
  local label="$1"
  local function_name="$2"
  local status
  set +e
  (set -e; "${function_name}")
  status=$?
  set -e
  if ((status == 0)); then
    printf 'Injected %s failure was accepted by production adapter.\n' "${label}" >&2
    exit 1
  fi
}

for injected_stage in checkout cabinet compose caddy telegram; do
  INJECTED_STAGE="${injected_stage}"
  assert_stage_failure "${injected_stage}" run_apply_release_stage
done
for injected_stage in migration health; do
  INJECTED_STAGE="${injected_stage}"
  assert_stage_failure "${injected_stage}" run_verify_release_stage
done
INJECTED_STAGE=""

printf '%s\n' 'Protected Update adapter harness passed.'
