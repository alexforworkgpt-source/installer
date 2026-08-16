#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "${1:-}" == export-child ]]; then
  TEMP_ROOT="${MIGRATION_TEST_ROOT}"
  PROJECT_ROOT="${TEMP_ROOT}/project"
  STATE_DIR="${PROJECT_ROOT}/state"
  STATE_FILE="${STATE_DIR}/install.state"
  COMPOSE_FILE="${STATE_DIR}/docker-compose.yml"
  BOT_ENV_FILE="${STATE_DIR}/bot.env"
  BOT_REPO_DIR="${PROJECT_ROOT}/repos/bot-backend"
  CABINET_REPO_DIR="${PROJECT_ROOT}/repos/bot-cabinet"
  CADDY_SNIPPET_DIR="${TEMP_ROOT}/caddy"
  COMPOSE_PROJECT_NAME="${CUSTOM_COMPOSE_PROJECT}"
  POSTGRES_DB=bot
  POSTGRES_USER=bot

  # shellcheck source=lib/common.sh
  source "${SCRIPT_DIR}/lib/common.sh"
  # shellcheck source=lib/migrate.sh
  source "${SCRIPT_DIR}/lib/migrate.sh"
  set_runtime_paths

  ensure_root() { :; }
  require_state_file() { :; }
  require_docker_compose() { :; }
  secure_private_file() { :; }
  log_info() { :; }
  log_warn() { :; }
  prompt_input() { printf '%s' "${TEMP_ROOT}/export"; }
  prompt_yes_no() { return 1; }
  migration_service_is_running() { :; }
  migration_service_container() { printf '%s' "$1-container"; }
  migration_repo_commit() { printf 'a%.0s' {1..40}; }
  migration_repo_is_dirty() { return 1; }
  migration_volume_for_destination() { printf '%s' redis-volume; }

  create_migration_export
  exit 0
fi

TEMP_ROOT="$(mktemp -d)"
FAKE_BIN="${TEMP_ROOT}/bin"
DOCKER_LOG="${TEMP_ROOT}/docker.log"
CUSTOM_COMPOSE_PROJECT="custom-export-project"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${TEMP_ROOT}/project/state" \
  "${TEMP_ROOT}/project/repos/bot-backend" "${TEMP_ROOT}/project/repos/bot-cabinet"
touch "${TEMP_ROOT}/project/state/install.state" \
  "${TEMP_ROOT}/project/state/docker-compose.yml" \
  "${TEMP_ROOT}/project/state/bot.env"
cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >> "${DOCKER_LOG}"
if [[ "${1:-}" == compose \
  && -n "${FAIL_MIGRATION_START_SERVICE:-}" \
  && "$*" == *" start ${FAIL_MIGRATION_START_SERVICE}"* ]]; then
  exit 1
fi
case "${1:-} ${2:-}" in
  'inspect bot-container') printf '%s\n' bot-image-id ;;
  'inspect postgres-container') printf '%s\n' postgres-image-id ;;
  'inspect redis-container') printf '%s\n' redis-image-id ;;
  'run --rm')
    for argument in "$@"; do
      if [[ "${argument}" == *:/backup ]]; then
        touch "${argument%:/backup}/redis-data.tar.gz"
      fi
    done
    ;;
  'image save')
    while (($#)); do
      if [[ "$1" == --output ]]; then
        printf '%s\n' images > "$2"
        break
      fi
      shift
    done
    ;;
esac
exit 0
EOF
chmod +x "${FAKE_BIN}/docker"

export PATH="${FAKE_BIN}:${PATH}"
export CUSTOM_COMPOSE_PROJECT DOCKER_LOG
export MIGRATION_TEST_ROOT="${TEMP_ROOT}"

if ! bash "${BASH_SOURCE[0]}" export-child; then
  printf '%s\n' 'Trial migration export fixture failed.' >&2
  exit 1
fi

if ! grep -Fq -- "--project-name ${CUSTOM_COMPOSE_PROJECT}"' --env-file '"${TEMP_ROOT}/project/state/bot.env"' -f '"${TEMP_ROOT}/project/state/docker-compose.yml"' start redis' "${DOCKER_LOG}"; then
  printf '%s\n' 'Trial export cleanup did not restart Redis with the persisted Compose project identity.' >&2
  exit 1
fi
if ! grep -Fq -- "--project-name ${CUSTOM_COMPOSE_PROJECT}"' --env-file '"${TEMP_ROOT}/project/state/bot.env"' -f '"${TEMP_ROOT}/project/state/docker-compose.yml"' start bot' "${DOCKER_LOG}"; then
  printf '%s\n' 'Trial export cleanup did not restart Bot with the persisted Compose project identity.' >&2
  exit 1
fi

export FAIL_MIGRATION_START_SERVICE=bot
if bash "${BASH_SOURCE[0]}" export-child; then
  printf '%s\n' 'Trial export reported success after Bot restart failed.' >&2
  exit 1
fi
[[ -f "${TEMP_ROOT}/project/state/migration-export.in-progress" ]]

printf '%s\n' 'Migration export cleanup integration harness passed.'
