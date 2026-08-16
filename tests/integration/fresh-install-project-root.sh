#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
TARGET_ROOT="${TEMP_ROOT}/project"
PREVIOUS_ROOT="${TEMP_ROOT}/preconfiguration-project"
RESULT_FILE="${TEMP_ROOT}/configure-result"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"

INSTALLER_DIR="${TEMP_ROOT}/installer-source"
GLOBAL_INSTALLER_STATE_DIR="${TEMP_ROOT}/global-state"
GLOBAL_LAST_PROJECT_ROOT_FILE="${GLOBAL_INSTALLER_STATE_DIR}/last_project_root"
DEFAULT_PROJECT_ROOT="${TARGET_ROOT}"
PROJECT_ROOT="${TARGET_ROOT}"
mkdir -p "${INSTALLER_DIR}"
reset_project_root_paths

ensure_root() { :; }
assert_supported_os() { :; }
install_base_packages() { log_info "bootstrap packages prepared"; }
install_docker_engine() { log_info "Docker prepared"; }
ensure_docker_compose_plugin() { log_info "Compose plugin prepared"; }
prepare_fresh_install_release() {
  log_info "Release Bundle prepared"
  PREPARED_RELEASE="fresh-root-test"
  PREPARED_BUNDLE_IDENTITY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  PREPARED_BOT_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  PREPARED_CABINET_REPO_URL="https://example.test/custom-cabinet.git"
  PREPARED_CABINET_SHA="cccccccccccccccccccccccccccccccccccccccc"
  PREPARED_CABINET_ARTIFACT_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  PREPARED_CABINET_ARTIFACT_FILE="${TEMP_ROOT}/cabinet-dist.tar.gz"
  PREPARED_POSTGRES_IMAGE="postgres@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  PREPARED_REDIS_IMAGE="redis@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  PREPARED_MANIFEST_SOURCE="https://example.test/release.json"
  printf '%s\n' artifact > "${PREPARED_CABINET_ARTIFACT_FILE}"
}
configure_stack() {
  if [[ -e "${TARGET_ROOT}" ]]; then
    printf '%s\n' polluted > "${RESULT_FILE}"
  else
    printf '%s\n' clean > "${RESULT_FILE}"
  fi
  return 1
}

full_install_once && exit 1

[[ -f "${RESULT_FILE}" ]]
[[ "$(<"${RESULT_FILE}")" == clean ]]
[[ ! -e "${TARGET_ROOT}" ]]

unset STATE_DIR REPOS_DIR RUNTIME_DIR RELEASES_DIR STATE_FILE
unset BOT_REPO_DIR CABINET_REPO_DIR BOT_RUNTIME_DIR BOT_DATA_DIR BOT_LOGS_DIR
unset BOT_UPLOADS_DIR CABINET_DIST_DIR BOT_ENV_FILE BOT_OVERRIDE_ENV_FILE
unset CABINET_ENV_FILE COMPOSE_FILE CADDY_CANDIDATE_FILE CADDY_SNIPPET_FILE
PROJECT_ROOT="${PREVIOUS_ROOT}"
unset COMPOSE_PROJECT_NAME
set_runtime_paths
preconfiguration_compose_project="${COMPOSE_PROJECT_NAME}"
CONFIGURATION_CREATES_PROJECT_ROOT="false"
is_safe_project_root() { [[ "$1" == "${TARGET_ROOT}" ]]; }
prompt_input() {
  local label="$1"
  case "${label}" in
    "Каталог установки")
      if [[ ! -f "${TEMP_ROOT}/invalid-root-emitted" ]]; then
        : > "${TEMP_ROOT}/invalid-root-emitted"
        printf '%s' relative-project
      else
        printf '%s' "${TARGET_ROOT}"
      fi
      ;;
    "Домен webhook") printf '%s' "hooks.example.test" ;;
    "Домен cabinet и Mini App") printf '%s' "app.example.test" ;;
    "Токен Telegram-бота") printf '%s' "1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ;;
    "Username Telegram-бота") printf '%s' "test_bot" ;;
    "Telegram ID администраторов") printf '%s' "123456789" ;;
    "Remnawave API URL") printf '%s' "https://panel.example.test" ;;
    "Remnawave API Key") printf '%s' "test-api-key" ;;
    "Remnawave Secret Key") printf '%s' "test-secret-key" ;;
    "Remnawave Webhook Secret") printf '%s' "test-webhook-secret" ;;
    *) return 1 ;;
  esac
}

collect_configuration
set_runtime_paths
expected_compose_project="$(compose_project_name_for_root "${TARGET_ROOT}")"

[[ "${CONFIGURATION_CREATES_PROJECT_ROOT}" == true ]]
[[ -f "${TEMP_ROOT}/invalid-root-emitted" ]]
[[ ! -e "${PREVIOUS_ROOT}" ]]
[[ ! -e "${TARGET_ROOT}" ]]
[[ "${COMPOSE_PROJECT_NAME}" != "${preconfiguration_compose_project}" ]]
[[ "${COMPOSE_PROJECT_NAME}" == "${expected_compose_project}" ]]

RACE_ROOT="${TEMP_ROOT}/race-project"
PROJECT_ROOT="${RACE_ROOT}"
CONFIGURATION_CREATES_PROJECT_ROOT="true"
reset_project_root_paths
is_safe_first_install_parent() { :; }
mkdir() {
  if [[ "$#" == 1 && "$1" == "${RACE_ROOT}" ]]; then
    command mkdir "$1"
    return 1
  fi
  command mkdir "$@"
}
if (prepare_first_install_project); then
  printf '%s\n' 'Raced project-root creation unexpectedly succeeded.' >&2
  exit 1
fi
[[ -d "${RACE_ROOT}" ]]
[[ ! -e "${RACE_ROOT}/state" ]]
unset -f mkdir

mkdir "${TARGET_ROOT}"
PROJECT_ROOT="${TEMP_ROOT}/preexisting-root-selection"
unset COMPOSE_PROJECT_NAME
reset_project_root_paths
set_runtime_paths
if (collect_configuration); then
  printf '%s\n' 'Existing project root without installer state was accepted.' >&2
  exit 1
fi
[[ -z "$(find "${TARGET_ROOT}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

printf '%s\n' "Fresh-install project-root integration test passed."
