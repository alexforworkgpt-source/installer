#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
ORDER_LOG="${TEMP_ROOT}/order.log"
TARGET_BOT_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TARGET_CABINET_SHA="cccccccccccccccccccccccccccccccccccccccc"
TARGET_CABINET_REPOSITORY="https://example.test/custom-cabinet.git"
TARGET_BUNDLE_IDENTITY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TARGET_ARTIFACT_SHA256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"

INSTALLER_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
mkdir -p "${STATE_DIR}"

ensure_root() { :; }
assert_supported_os() { :; }
log_info() { :; }
set_default_runtime_values() {
  BOT_VERSION_REF="main"
  CABINET_VERSION_REF="main"
  POSTGRES_IMAGE="postgres:15-alpine"
  REDIS_IMAGE="redis:7-alpine"
}
install_base_packages() { printf '%s\n' packages >> "${ORDER_LOG}"; }
install_docker_engine() { printf '%s\n' docker >> "${ORDER_LOG}"; }
ensure_docker_compose_plugin() { printf '%s\n' compose-plugin >> "${ORDER_LOG}"; }
prepare_fresh_install_release() {
  printf '%s\n' release-preflight >> "${ORDER_LOG}"
  PREPARED_RELEASE="fresh-test"
  PREPARED_BUNDLE_IDENTITY="${TARGET_BUNDLE_IDENTITY}"
  PREPARED_BOT_SHA="${TARGET_BOT_SHA}"
  PREPARED_CABINET_REPO_URL="${TARGET_CABINET_REPOSITORY}"
  PREPARED_CABINET_SHA="${TARGET_CABINET_SHA}"
  PREPARED_CABINET_ARTIFACT_SHA256="${TARGET_ARTIFACT_SHA256}"
  PREPARED_CABINET_ARTIFACT_FILE="${TEMP_ROOT}/cabinet-dist.tar.gz"
  PREPARED_POSTGRES_IMAGE="postgres@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  PREPARED_REDIS_IMAGE="redis@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  PREPARED_MANIFEST_SOURCE="https://example.test/release.json"
  printf '%s\n' artifact > "${PREPARED_CABINET_ARTIFACT_FILE}"
}
configure_stack() {
  printf '%s\n' configure >> "${ORDER_LOG}"
  [[ "${BOT_VERSION_REF}" == "${TARGET_BOT_SHA}" ]]
  [[ "${CABINET_VERSION_REF}" == "${TARGET_CABINET_SHA}" ]]
  [[ "${CABINET_REPO_URL}" == "${TARGET_CABINET_REPOSITORY}" ]]
  [[ "${POSTGRES_IMAGE}" == *@sha256:* ]]
  [[ "${REDIS_IMAGE}" == *@sha256:* ]]
  [[ -z "${CURRENT_RELEASE:-}" ]]
}
server_preflight_checks() { :; }
preflight_install_checks() { :; }
configure_host_firewall() { :; }
enable_services() { :; }
clone_required_repos() {
  printf '%s\n' checkout >> "${ORDER_LOG}"
  [[ "${BOT_VERSION_REF}" == "${TARGET_BOT_SHA}" ]]
  [[ "${CABINET_VERSION_REF}" == "${TARGET_CABINET_SHA}" ]]
}
deploy_stack_apply() {
  printf '%s\n' deploy >> "${ORDER_LOG}"
  [[ -f "${PREPARED_CABINET_ARTIFACT_FILE}" ]]
}
wait_for_runtime_ready() { :; }
verify_runtime_health() { :; }
save_state() {
  printf '%s\n' commit-release >> "${ORDER_LOG}"
  [[ "${CURRENT_RELEASE}" == "fresh-test" ]]
  [[ "${CURRENT_RELEASE_BUNDLE_IDENTITY}" == "${TARGET_BUNDLE_IDENTITY}" ]]
  [[ "${CURRENT_CABINET_ARTIFACT_SHA256}" == "${TARGET_ARTIFACT_SHA256}" ]]
}
mark_runtime_apply_state() { :; }
commit_first_install_state() { :; }
run_first_install_transaction() {
  local context_dir="$1"
  clone_required_repos
  PREPARED_CABINET_ARTIFACT_FILE="$(first_install_context_value \
    "${context_dir}" artifact-file)"
  deploy_stack_apply
  CURRENT_RELEASE="$(first_install_context_value "${context_dir}" release)"
  CURRENT_RELEASE_BUNDLE_IDENTITY="$(first_install_context_value \
    "${context_dir}" bundle-identity)"
  CURRENT_CABINET_ARTIFACT_SHA256="$(first_install_context_value \
    "${context_dir}" artifact-sha256)"
  save_state
  commit_first_install_state
}

full_install_once

expected_order='packages,docker,compose-plugin,release-preflight,configure,checkout,deploy,commit-release'
[[ "$(paste -sd, "${ORDER_LOG}")" == "${expected_order}" ]]

# Restore production deploy helpers after the isolated first-install stub.
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"
BOT_REPO_DIR="${TEMP_ROOT}/bot-repository"
CABINET_REPO_DIR="${TEMP_ROOT}/cabinet-repository"
CABINET_DIST_DIR="${TEMP_ROOT}/cabinet-dist"
mkdir -p "${BOT_REPO_DIR}" "${CABINET_REPO_DIR}" "${CABINET_DIST_DIR}"
: > "${ORDER_LOG}"
require_state_file() { :; }
ensure_directories() { :; }
ensure_runtime_permissions() { :; }
preflight_deploy_checks() { :; }
render_all_configs() { :; }
build_cabinet_assets() {
  printf '%s\n' forbidden-vps-build >> "${ORDER_LOG}"
  return 1
}
run_python() {
  [[ "${2:-}" == "activate-cabinet" ]]
  printf '%s\n' activate-release-artifact >> "${ORDER_LOG}"
}
deploy_compose_stack() { :; }
regenerate_caddy_config() { :; }
apply_telegram_runtime_mode() { :; }
finalize_runtime_change() { :; }
status_stack() { :; }
print_post_deploy_summary() { :; }

deploy_stack_once
[[ "$(<"${ORDER_LOG}")" == 'activate-release-artifact' ]]

printf '%s\n' 'Fresh install Release Bundle harness passed.'
