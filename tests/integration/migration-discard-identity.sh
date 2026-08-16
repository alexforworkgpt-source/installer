#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
FAKE_BIN="${TEMP_ROOT}/bin"
DOCKER_LOG="${TEMP_ROOT}/docker.log"
IMPORTED_PROJECT_ROOT="${TEMP_ROOT}/imported-project"
PROJECT_ROOT="${IMPORTED_PROJECT_ROOT}"
CUSTOM_COMPOSE_PROJECT="custom-migrated-project"
INSTALLER_GLOBAL_STATE_DIR="${TEMP_ROOT}/global-state"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${PROJECT_ROOT}/state"
cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >> "${DOCKER_LOG}"
if [[ "${1:-}" == compose && "$*" == *"--project-name ${CUSTOM_COMPOSE_PROJECT}"* && "$*" == *' down -v' ]]; then
  exit 0
fi
if [[ "${1:-}" == ps ]]; then
  exit 0
fi
if [[ "${1:-}" == volume && "${2:-}" == inspect ]]; then
  exit 1
fi
exit 1
EOF
chmod +x "${FAKE_BIN}/docker"
export PATH="${FAKE_BIN}:${PATH}"
export CUSTOM_COMPOSE_PROJECT DOCKER_LOG

printf '%s\n' compose > "${PROJECT_ROOT}/state/docker-compose.yml"
printf '%s\n' override > "${PROJECT_ROOT}/state/migration-image.override.yml"
printf '%s\n' state > "${PROJECT_ROOT}/state/install.state"
printf '%s\n' pending > "${PROJECT_ROOT}/state/migration.pending"
cat > "${PROJECT_ROOT}/.migration-resources-created" <<EOF
compose_project=${CUSTOM_COMPOSE_PROJECT}
volume=${CUSTOM_COMPOSE_PROJECT}_postgres_data
volume=${CUSTOM_COMPOSE_PROJECT}_redis_data
EOF

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/migrate.sh
source "${SCRIPT_DIR}/lib/migrate.sh"

LAST_PROJECT_ROOT_FILE="${TEMP_ROOT}/last_project_root"
reset_project_root_paths
set_runtime_paths

is_safe_project_root() { :; }
ensure_root() { :; }
require_state_file() { :; }
prompt_typed_confirmation() { :; }
migration_remove_recorded_caddy() { :; }
command_exists() { return 1; }
log_info() { :; }
log_warn() { :; }

mkdir -p "${GLOBAL_INSTALLER_STATE_DIR}"
printf '%s\n' "${PROJECT_ROOT}" > "${LAST_PROJECT_ROOT_FILE}"
printf '%s\n' "${PROJECT_ROOT}" > "${GLOBAL_LAST_PROJECT_ROOT_FILE}"
if ((EUID != 0)); then
  clear_last_project_root() {
    rm -f "${LAST_PROJECT_ROOT_FILE}" "${GLOBAL_LAST_PROJECT_ROOT_FILE}"
  }
fi

discard_pending_migration

grep -Fq -- "compose --project-name ${CUSTOM_COMPOSE_PROJECT}" "${DOCKER_LOG}"
[[ ! -e "${IMPORTED_PROJECT_ROOT}" ]]
[[ ! -e "${LAST_PROJECT_ROOT_FILE}" ]]
[[ ! -e "${GLOBAL_LAST_PROJECT_ROOT_FILE}" ]]

printf '%s\n' 'Migration discard identity integration harness passed.'
