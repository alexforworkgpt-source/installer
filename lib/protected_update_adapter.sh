#!/usr/bin/env bash

set -Eeuo pipefail

source_only="${PROTECTED_UPDATE_ADAPTER_SOURCE_ONLY:-false}"
if [[ "${source_only}" == false ]]; then
  if (($# < 3)); then
    printf '%s\n' 'usage: protected_update_adapter.sh <state-dir> <context-dir> <stage> [args...]' >&2
    exit 2
  fi

  requested_state_dir="$1"
  context_dir="$2"
  stage="$3"
  shift 3

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # shellcheck source=lib/common.sh
  source "${SCRIPT_DIR}/lib/common.sh"
  # shellcheck source=lib/configure.sh
  source "${SCRIPT_DIR}/lib/configure.sh"
  # shellcheck source=lib/install.sh
  source "${SCRIPT_DIR}/lib/install.sh"
  # shellcheck source=lib/firewall.sh
  source "${SCRIPT_DIR}/lib/firewall.sh"
  # shellcheck source=lib/deploy.sh
  source "${SCRIPT_DIR}/lib/deploy.sh"
  # shellcheck source=lib/doctor.sh
  source "${SCRIPT_DIR}/lib/doctor.sh"
  # shellcheck source=lib/update.sh
  source "${SCRIPT_DIR}/lib/update.sh"

  STATE_DIR="${requested_state_dir}"
  PROJECT_ROOT="$(dirname "${STATE_DIR}")"
  STATE_FILE="${STATE_DIR}/install.state"
  set_runtime_paths
  require_state_file

  marker_file="${STATE_DIR}/runtime-change.in-progress"
fi

context_value() {
  local key="$1"
  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  [[ -f "${context_dir}/${key}" ]] || return 1
  < "${context_dir}/${key}" tr -d '\n'
}

write_context_value() {
  local key="$1"
  local value="$2"
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

write_update_marker() {
  local recovery_point="$1"
  local temporary="${marker_file}.tmp"
  (
    umask 077
    {
      printf 'operation=protected-update\n'
      printf 'recovery_point=%s\n' "${recovery_point}"
      printf 'context_file=%s\n' "${context_dir}"
    } > "${temporary}"
  )
  mv -f "${temporary}" "${marker_file}"
  secure_private_file "${marker_file}"
  sync -f "${marker_file}"
  sync -f "${STATE_DIR}"
}

clear_update_marker() {
  rm -f "${marker_file}"
  sync -f "${STATE_DIR}"
}

safe_stop_bot_and_verify() {
  local running_services
  compose_cmd stop bot >/dev/null
  running_services="$(compose_cmd ps --status running --services)"
  ! grep -Fxq bot <<<"${running_services}"
}

restore_previous_release_variables() {
  CABINET_REPO_URL="$(context_value previous-cabinet-repository)"
  POSTGRES_IMAGE="$(context_value previous-postgres-image)"
  REDIS_IMAGE="$(context_value previous-redis-image)"
  CURRENT_RELEASE="$(context_value previous-release)"
  RELEASE_MANIFEST_SOURCE="$(context_value previous-manifest-source)"
  CURRENT_RELEASE_BUNDLE_IDENTITY="$(context_value previous-bundle-identity)"
  CURRENT_CABINET_ARTIFACT_SHA256="$(context_value previous-artifact-identity)"
  LAST_RELEASE_BUNDLE_IDENTITY="$(context_value previous-last-bundle-identity)"
  LAST_CABINET_ARTIFACT_SHA256="$(context_value previous-last-artifact-identity)"
  LAST_BOT_VERSION_REF="$(context_value previous-last-bot-ref)"
  LAST_CABINET_VERSION_REF="$(context_value previous-last-cabinet-ref)"
  BOT_VERSION_REF="$(context_value previous-bot-sha)"
  CABINET_VERSION_REF="$(context_value previous-cabinet-sha)"
}

run_create_dump_stage() {
  local dump_reference
  local snapshot_reference

  if ! dump_reference="$(create_verified_update_dump "$(context_value target-release)")"; then
    run_abort_protection_stage || true
    return 1
  fi
  write_context_value dump-reference "${dump_reference}"
  write_context_value dump-sha256 "$(file_sha256 "${dump_reference}")"
  sync -f "${dump_reference}"
  create_update_snapshot "release-bundle-$(context_value target-release)" >&2 || return 1
  snapshot_reference="${LAST_CREATED_SNAPSHOT_DIR}"
  write_context_value snapshot-reference "${snapshot_reference}"
  write_update_marker "${dump_reference}"
  printf '%s\n' "${dump_reference}"
}

run_current_revision_stage() {
  local previous_bot_running="false"
  local revision

  if [[ -f "${context_dir}/before-revision" ]]; then
    revision="$(current_alembic_revision)"
    [[ -n "${revision}" ]]
    printf '%s\n' "${revision}"
    return 0
  fi

  [[ ! -f "${marker_file}" ]]
  if compose_cmd ps --status running --services 2>/dev/null | grep -Fxq bot; then
    previous_bot_running="true"
  fi
  write_context_value previous-bot-running "${previous_bot_running}"
  write_update_marker pending-dump
  safe_stop_bot_and_verify || return 1
  if ! revision="$(current_alembic_revision)"; then
    run_abort_protection_stage || true
    return 1
  fi
  [[ -n "${revision}" ]]
  write_context_value before-revision "${revision}"
  printf '%s\n' "${revision}"
}

run_abort_protection_stage() {
  if [[ "$(context_value previous-bot-running)" == true ]]; then
    if ! activate_current_runtime_once \
      || ! wait_for_runtime_ready 60 3 \
      || ! verify_runtime_health; then
      safe_stop_bot_and_verify || return 1
      return 1
    fi
  else
    safe_stop_bot_and_verify
  fi
  write_update_marker protection-aborted
}

run_apply_release_stage() {
  CABINET_REPO_URL="$(context_value target-cabinet-repository)"
  checkout_repo_ref \
    "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "$(context_value target-bot-sha)"
  verify_release_checkout "${BOT_REPO_DIR}" "$(context_value target-bot-sha)"
  checkout_repo_ref \
    "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "$(context_value target-cabinet-sha)"
  verify_release_checkout "${CABINET_REPO_DIR}" "$(context_value target-cabinet-sha)"
  run_python "${INSTALLER_DIR}/lib/release_bundle.py" activate-cabinet \
    "$(context_value target-artifact-file)" \
    "$(context_value target-artifact-sha256)" \
    "${CABINET_DIST_DIR}"

  POSTGRES_IMAGE="$(context_value target-postgres-image)"
  REDIS_IMAGE="$(context_value target-redis-image)"
  BOT_VERSION_REF="$(context_value target-bot-sha)"
  CABINET_VERSION_REF="$(context_value target-cabinet-sha)"
  render_compose_file
  compose_cmd config -q
  compose_cmd up -d --build --wait --wait-timeout 180 postgres redis bot
  reload_caddy
  apply_telegram_runtime_mode
}

run_verify_release_stage() {
  local revision
  revision="$(current_alembic_revision)"
  [[ -n "${revision}" ]]
  wait_for_runtime_ready 60 3
  verify_runtime_health
}

run_commit_release_stage() {
  local dump_reference="$1"
  local before_revision="$2"
  local after_revision="$3"
  local metadata_file="${dump_reference%.dump}.metadata.txt"

  LAST_BOT_VERSION_REF="$(context_value previous-bot-sha)"
  LAST_CABINET_VERSION_REF="$(context_value previous-cabinet-sha)"
  LAST_RELEASE_BUNDLE_IDENTITY="$(context_value previous-bundle-identity)"
  LAST_CABINET_ARTIFACT_SHA256="$(context_value previous-artifact-identity)"
  CABINET_REPO_URL="$(context_value target-cabinet-repository)"
  CURRENT_RELEASE="$(context_value target-release)"
  CURRENT_RELEASE_BUNDLE_IDENTITY="$(context_value target-bundle-identity)"
  CURRENT_CABINET_ARTIFACT_SHA256="$(context_value target-artifact-sha256)"
  RELEASE_MANIFEST_SOURCE="$(context_value target-manifest-source)"
  POSTGRES_IMAGE="$(context_value target-postgres-image)"
  REDIS_IMAGE="$(context_value target-redis-image)"
  BOT_VERSION_REF="$(context_value target-bot-sha)"
  CABINET_VERSION_REF="$(context_value target-cabinet-sha)"

  (
    umask 077
    {
      printf 'release=%s\n' "${CURRENT_RELEASE}"
      printf 'database_dump=%s\n' "${dump_reference}"
      printf 'before_revision=%s\n' "${before_revision}"
      printf 'after_revision=%s\n' "${after_revision}"
      printf 'migration_policy=%s\n' "$(context_value migration-policy)"
    } > "${metadata_file}"
  )
  secure_private_file "${metadata_file}"
  write_context_value after-revision "${after_revision}"
  save_state
  mark_runtime_apply_state
  sync -f "${STATE_FILE}"
  sync -f "${STATE_DIR}"
  write_update_marker committed
}

run_rollback_release_stage() {
  local previous_cabinet_dir="${context_dir}/previous-cabinet"

  safe_stop_bot_and_verify
  restore_previous_release_variables
  rollback_release_sources \
    "$(context_value previous-bot-sha)" \
    "$(context_value previous-cabinet-sha)"
  safe_rm_rf_under "${PROJECT_ROOT}" "${CABINET_DIST_DIR}"
  if [[ -d "${previous_cabinet_dir}" ]]; then
    cp -a "${previous_cabinet_dir}" "${CABINET_DIST_DIR}"
  else
    mkdir -p "${CABINET_DIST_DIR}"
  fi
  save_state
  sync -f "${STATE_FILE}"
  sync -f "${STATE_DIR}"
  render_compose_file
  compose_cmd config -q
  compose_cmd up -d --wait --wait-timeout 180 postgres redis
}

run_restore_dump_stage() {
  local dump_reference="$1"
  local before_revision="$2"
  local expected_dump
  local expected_checksum

  expected_dump="$(context_value dump-reference)"
  expected_checksum="$(context_value dump-sha256)"
  [[ "${dump_reference}" == "${expected_dump}" ]]
  [[ -f "${dump_reference}" && ! -L "${dump_reference}" ]]
  [[ "$(file_sha256 "${dump_reference}")" == "${expected_checksum}" ]]
  restore_verified_update_dump "${dump_reference}" "${before_revision}"
}

run_verify_rollback_stage() {
  local previous_release="$1"
  local before_revision="$2"
  local dump_reference="$3"

  [[ "${previous_release}" == "$(context_value previous-release-key)" ]]
  [[ "${dump_reference}" == "$(context_value dump-reference)" ]]
  restore_previous_release_variables
  reload_caddy
  apply_telegram_runtime_mode
  if [[ "$(context_value previous-bot-running)" == true ]]; then
    compose_cmd up -d --build --wait --wait-timeout 180 bot
    wait_for_runtime_ready 60 3
    verify_runtime_health
  else
    safe_stop_bot_and_verify
  fi
  [[ "$(current_alembic_revision)" == "${before_revision}" ]]
  save_state
  mark_runtime_apply_state
  sync -f "${STATE_FILE}"
  sync -f "${STATE_DIR}"
  write_update_marker rolled-back
}

run_verify_commit_stage() {
  CABINET_REPO_URL="$(context_value target-cabinet-repository)"
  POSTGRES_IMAGE="$(context_value target-postgres-image)"
  REDIS_IMAGE="$(context_value target-redis-image)"
  BOT_VERSION_REF="$(context_value target-bot-sha)"
  CABINET_VERSION_REF="$(context_value target-cabinet-sha)"
  verify_release_checkout "${BOT_REPO_DIR}" "${BOT_VERSION_REF}"
  verify_release_checkout "${CABINET_REPO_DIR}" "${CABINET_VERSION_REF}"
  [[ "$(current_alembic_revision)" == "$(context_value after-revision)" ]]
  wait_for_runtime_ready 60 3
  verify_runtime_health
}

run_finalize_commit_stage() {
  [[ "$(awk -F= '$1 == "recovery_point" {print substr($0, index($0, "=") + 1); exit}' \
    "${marker_file}")" == committed ]]
  clear_update_marker
}

run_verify_aborted_stage() {
  if [[ "$(context_value previous-bot-running)" == true ]]; then
    wait_for_runtime_ready 60 3
    verify_runtime_health
  else
    safe_stop_bot_and_verify
  fi
}

run_finalize_terminal_stage() {
  local expected="$1"
  [[ "$(awk -F= '$1 == "recovery_point" {print substr($0, index($0, "=") + 1); exit}' \
    "${marker_file}")" == "${expected}" ]]
  clear_update_marker
}

if [[ "${source_only}" == false ]]; then
  case "${stage}" in
    create-dump) run_create_dump_stage ;;
    current-revision) run_current_revision_stage ;;
    current-release) context_value previous-release-key ;;
    apply-release) run_apply_release_stage ;;
    verify-release) run_verify_release_stage ;;
    commit-release) run_commit_release_stage "$@" ;;
    rollback-release) run_rollback_release_stage ;;
    restore-dump) run_restore_dump_stage "$1" "$2" ;;
    verify-rollback) run_verify_rollback_stage "$@" ;;
    abort-protection) run_abort_protection_stage ;;
    verify-commit) run_verify_commit_stage ;;
    finalize-commit) run_finalize_commit_stage ;;
    verify-aborted) run_verify_aborted_stage ;;
    finalize-terminal) run_finalize_terminal_stage "$1" ;;
    safe-stop) safe_stop_bot_and_verify ;;
    *)
      printf 'unsupported protected update stage: %s\n' "${stage}" >&2
      exit 2
      ;;
  esac
fi
