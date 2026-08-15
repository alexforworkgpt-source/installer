#!/usr/bin/env bash

set -Eeuo pipefail

if (($# < 3)); then
  printf '%s\n' 'usage: runtime_change_adapter.sh <operation> <state-dir> [context] <stage> [recovery-point]' >&2
  exit 2
fi

operation="$1"
requested_state_dir="$2"
context_file=""
case "${operation}" in
  settings)
    stage="$3"
    recovery_point="${4:-}"
    ;;
  deploy)
    stage="$3"
    recovery_point="${4:-}"
    ;;
  first-install)
    (($# >= 4)) || exit 2
    context_file="$3"
    stage="$4"
    recovery_point="${5:-}"
    ;;
  postgres-rotation)
    (($# >= 4)) || exit 2
    context_file="$3"
    stage="$4"
    recovery_point="${5:-}"
    ;;
  *)
    printf 'unsupported Runtime Change operation: %s\n' "${operation}" >&2
    exit 2
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"
# shellcheck source=lib/doctor.sh
source "${SCRIPT_DIR}/lib/doctor.sh"
# shellcheck source=lib/config_editor.sh
source "${SCRIPT_DIR}/lib/config_editor.sh"

STATE_DIR="${requested_state_dir}"
PROJECT_ROOT="$(dirname "${STATE_DIR}")"
STATE_FILE="${STATE_DIR}/install.state"
set_runtime_paths
RUNTIME_CHANGE_MARKER="${STATE_DIR}/runtime-change.in-progress"
RUNTIME_CHANGE_PENDING_STATE="${STATE_DIR}/install.state.pending-runtime-change"

write_runtime_change_marker() {
  local protected_snapshot="$1"
  local marker_temp="${RUNTIME_CHANGE_MARKER}.tmp"
  (
    umask 077
    {
      printf 'operation=%s\n' "${operation}"
      printf 'recovery_point=%s\n' "${protected_snapshot}"
      printf 'context_file=%s\n' "${context_file}"
    } > "${marker_temp}"
  )
  mv -f "${marker_temp}" "${RUNTIME_CHANGE_MARKER}"
  secure_private_file "${RUNTIME_CHANGE_MARKER}"
}

clear_runtime_change_marker() {
  rm -f "${RUNTIME_CHANGE_MARKER}"
}

safe_stop_bot_and_verify() {
  local running_services
  compose_cmd stop bot >/dev/null
  running_services="$(compose_cmd ps --status running --services)"
  ! grep -Fxq bot <<<"${running_services}"
}

run_settings_stage() {
  case "${stage}" in
    plan)
      require_state_file
      [[ -d "${STATE_DIR}/draft" ]]
      [[ -n "$(run_python "${INSTALLER_DIR}/lib/installation_config.py" plan-draft "${STATE_DIR}")" ]]
      ;;
    protect)
      require_state_file
      [[ ! -f "${RUNTIME_CHANGE_MARKER}" ]]
      local previous_bot_running="false"
      if compose_cmd ps --status running --services 2>/dev/null | grep -Fxq bot; then
        previous_bot_running="true"
      fi
      create_update_snapshot "before-draft-promotion" >&2
      printf '%s\n' "${previous_bot_running}" \
        > "${LAST_CREATED_SNAPSHOT_DIR}/previous-bot-running"
      write_runtime_change_marker "${LAST_CREATED_SNAPSHOT_DIR}"
      printf '%s\n' "${LAST_CREATED_SNAPSHOT_DIR}"
      ;;
    apply)
      require_state_file
      run_python "${INSTALLER_DIR}/lib/installation_config.py" promote-draft "${STATE_DIR}"
      RUNTIME_CHANGE_PENDING_STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE}"
      export RUNTIME_CHANGE_PENDING_STATE_FILE
      apply_config_changes_once
      ;;
    verify)
      [[ -f "${RUNTIME_CHANGE_PENDING_STATE}" ]]
      RUNTIME_CHANGE_PENDING_STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE}"
      export RUNTIME_CHANGE_PENDING_STATE_FILE
      require_state_file
      wait_for_runtime_ready 60 3
      verify_runtime_health
      ;;
    commit)
      require_state_file
      [[ -f "${RUNTIME_CHANGE_PENDING_STATE}" ]]
      mv -f "${RUNTIME_CHANGE_PENDING_STATE}" "${STATE_FILE}"
      secure_private_file "${STATE_FILE}"
      load_state
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    rollback)
      [[ -n "${recovery_point}" ]]
      rm -f "${RUNTIME_CHANGE_PENDING_STATE}"
      restore_snapshot_files_from_path "${recovery_point}"
      if [[ "$(<"${recovery_point}/previous-bot-running")" == "true" ]]; then
        activate_current_runtime_once
      else
        install_caddy_candidate
        reload_caddy
        apply_telegram_runtime_mode
        safe_stop_bot_and_verify
      fi
      ;;
    verify-rollback)
      require_state_file
      if [[ "$(<"${recovery_point}/previous-bot-running")" == "true" ]]; then
        wait_for_runtime_ready 60 3
        verify_runtime_health
      else
        safe_stop_bot_and_verify
      fi
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    safe-stop)
      require_state_file
      safe_stop_bot_and_verify
      ;;
    *)
      printf 'unsupported settings Runtime Change stage: %s\n' "${stage}" >&2
      return 2
      ;;
  esac
}

run_deploy_stage() {
  case "${stage}" in
    plan)
      require_state_file
      ;;
    protect)
      require_state_file
      [[ ! -f "${RUNTIME_CHANGE_MARKER}" ]]
      local previous_bot_running="false"
      if compose_cmd ps --status running --services 2>/dev/null | grep -Fxq bot; then
        previous_bot_running="true"
      fi
      create_update_snapshot "before-deploy-transaction" >&2
      printf '%s\n' "${previous_bot_running}" \
        > "${LAST_CREATED_SNAPSHOT_DIR}/previous-bot-running"
      write_runtime_change_marker "${LAST_CREATED_SNAPSHOT_DIR}"
      printf '%s\n' "${LAST_CREATED_SNAPSHOT_DIR}"
      ;;
    apply)
      deploy_stack_apply
      ;;
    verify)
      require_state_file
      wait_for_runtime_ready 60 3
      verify_runtime_health
      ;;
    commit)
      require_state_file
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    rollback)
      [[ -n "${recovery_point}" ]]
      restore_snapshot_files_from_path "${recovery_point}"
      if [[ "$(<"${recovery_point}/previous-bot-running")" == true ]]; then
        activate_current_runtime_once
      else
        install_caddy_candidate
        reload_caddy
        apply_telegram_runtime_mode
        safe_stop_bot_and_verify
      fi
      ;;
    verify-rollback)
      require_state_file
      if [[ "$(<"${recovery_point}/previous-bot-running")" == true ]]; then
        wait_for_runtime_ready 60 3
        verify_runtime_health
      else
        safe_stop_bot_and_verify
      fi
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    safe-stop)
      require_state_file
      safe_stop_bot_and_verify
      ;;
    *)
      printf 'unsupported deploy Runtime Change stage: %s\n' "${stage}" >&2
      return 2
      ;;
  esac
}

run_postgres_rotation_stage() {
  local password
  case "${stage}" in
    plan)
      require_state_file
      [[ -f "${context_file}" ]]
      password="$(<"${context_file}")"
      [[ ${#password} -ge 32 ]]
      ;;
    protect)
      require_state_file
      [[ ! -f "${RUNTIME_CHANGE_MARKER}" ]]
      local previous_bot_running="false"
      if compose_cmd ps --status running --services 2>/dev/null | grep -Fxq bot; then
        previous_bot_running="true"
      fi
      verify_postgres_role_password "${POSTGRES_PASSWORD}"
      create_update_snapshot "before-postgres-credential-rotation" >&2
      printf '%s\n' "${previous_bot_running}" \
        > "${LAST_CREATED_SNAPSHOT_DIR}/previous-bot-running"
      write_runtime_change_marker "${LAST_CREATED_SNAPSHOT_DIR}"
      printf '%s\n' "${LAST_CREATED_SNAPSHOT_DIR}"
      ;;
    apply)
      require_state_file
      password="$(<"${context_file}")"
      [[ ${#password} -ge 32 ]]
      alter_postgres_role_password "${password}"
      run_python "${INSTALLER_DIR}/lib/installation_config.py" \
        replace-postgres-password "${BOT_ENV_FILE}" "${password}"
      compose_cmd up -d --force-recreate --wait --wait-timeout 180 bot
      ;;
    verify)
      require_state_file
      password="$(<"${context_file}")"
      verify_postgres_role_password "${password}"
      wait_for_runtime_ready 60 3
      verify_runtime_health
      ;;
    commit)
      require_state_file
      password="$(<"${context_file}")"
      POSTGRES_PASSWORD="${password}"
      save_state
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    rollback)
      [[ -n "${recovery_point}" ]]
      restore_snapshot_files_from_path "${recovery_point}"
      alter_postgres_role_password "${POSTGRES_PASSWORD}"
      run_python "${INSTALLER_DIR}/lib/installation_config.py" \
        replace-postgres-password "${BOT_ENV_FILE}" "${POSTGRES_PASSWORD}"
      if [[ "$(<"${recovery_point}/previous-bot-running")" == "true" ]]; then
        compose_cmd up -d --force-recreate --wait --wait-timeout 180 bot
      else
        safe_stop_bot_and_verify
      fi
      ;;
    verify-rollback)
      require_state_file
      verify_postgres_role_password "${POSTGRES_PASSWORD}"
      if [[ "$(<"${recovery_point}/previous-bot-running")" == "true" ]]; then
        wait_for_runtime_ready 60 3
        verify_runtime_health
      else
        safe_stop_bot_and_verify
      fi
      mark_runtime_apply_state
      clear_runtime_change_marker
      ;;
    safe-stop)
      require_state_file
      safe_stop_bot_and_verify
      ;;
    *)
      printf 'unsupported PostgreSQL rotation stage: %s\n' "${stage}" >&2
      return 2
      ;;
  esac
}

use_first_install_pending_state() {
  RUNTIME_CHANGE_PENDING_STATE_FILE="$(first_install_context_value \
    "${context_file}" pending-state)"
  export RUNTIME_CHANGE_PENDING_STATE_FILE
  STATE_FILE="${RUNTIME_CHANGE_PENDING_STATE_FILE}"
}

run_first_install_stage() {
  case "${stage}" in
    plan)
      use_first_install_pending_state
      require_state_file
      [[ -d "${context_file}" ]]
      [[ -f "$(first_install_context_value "${context_file}" artifact-file)" ]]
      server_preflight_checks
      preflight_install_checks
      preflight_deploy_checks
      ;;
    protect)
      use_first_install_pending_state
      require_state_file
      grep -Fxq operation=first-install "${RUNTIME_CHANGE_MARKER}"
      grep -Fxq recovery_point=empty-project "${RUNTIME_CHANGE_MARKER}"
      printf '%s\n' empty-project
      ;;
    apply)
      use_first_install_pending_state
      require_state_file
      render_all_configs
      configure_host_firewall
      enable_services
      clone_required_repos
      PREPARED_CABINET_ARTIFACT_FILE="$(first_install_context_value \
        "${context_file}" artifact-file)"
      PREPARED_CABINET_ARTIFACT_SHA256="$(first_install_context_value \
        "${context_file}" artifact-sha256)"
      export PREPARED_CABINET_ARTIFACT_FILE PREPARED_CABINET_ARTIFACT_SHA256
      deploy_stack_apply
      ;;
    verify)
      use_first_install_pending_state
      require_state_file
      wait_for_runtime_ready 60 3
      verify_runtime_health
      ;;
    commit)
      use_first_install_pending_state
      require_state_file
      CURRENT_RELEASE="$(first_install_context_value "${context_file}" release)"
      CURRENT_RELEASE_BUNDLE_IDENTITY="$(first_install_context_value \
        "${context_file}" bundle-identity)"
      CURRENT_CABINET_ARTIFACT_SHA256="$(first_install_context_value \
        "${context_file}" artifact-sha256)"
      RELEASE_MANIFEST_SOURCE="$(first_install_context_value \
        "${context_file}" manifest-source)"
      save_state
      mark_runtime_apply_state
      commit_first_install_state
      ;;
    rollback)
      [[ "${recovery_point}" == empty-project ]]
      cleanup_failed_first_install
      ;;
    verify-rollback)
      [[ "${recovery_point}" == empty-project ]]
      [[ ! -e "${PROJECT_ROOT}" ]]
      ;;
    safe-stop)
      if [[ -f "$(first_install_context_value "${context_file}" pending-state 2>/dev/null || true)" ]]; then
        use_first_install_pending_state
        require_state_file
      fi
      if [[ -f "${COMPOSE_FILE}" ]]; then
        safe_stop_bot_and_verify
      fi
      ;;
    *)
      printf 'unsupported first install Runtime Change stage: %s\n' "${stage}" >&2
      return 2
      ;;
  esac
}

case "${operation}" in
  settings) run_settings_stage ;;
  deploy) run_deploy_stage ;;
  first-install) run_first_install_stage ;;
  postgres-rotation) run_postgres_rotation_stage ;;
esac
