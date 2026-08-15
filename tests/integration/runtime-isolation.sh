#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
FAKE_BIN="${TEMP_ROOT}/bin"
DOCKER_LOG="${TEMP_ROOT}/docker.log"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG}"
if [[ "${1:-}" == info ]]; then
  exit 0
fi
if [[ "${1:-}" == compose && "$*" == *' config' ]]; then
  exit 0
fi
if [[ "${1:-}" == compose && "$*" == *' ps -q bot' ]]; then
  printf '%s\n' bot-container-id
  exit 0
fi
if [[ "${1:-}" == compose && "$*" == *' ps -q postgres' ]]; then
  printf '%s\n' postgres-container-id
  exit 0
fi
if [[ "${1:-}" == compose && "$*" == *' ps -q redis' ]]; then
  printf '%s\n' redis-container-id
  exit 0
fi
if [[ "${1:-}" == port ]]; then
  case "${2:-}" in
    bot-container-id) printf '%s\n' "${RUNTIME_TEST_BOT_BINDING:-8080/tcp -> 127.0.0.1:18080}" ;;
    postgres-container-id|redis-container-id) : ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "${FAKE_BIN}/docker"
export PATH="${FAKE_BIN}:${PATH}"
export DOCKER_LOG

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/configure.sh
source "${SCRIPT_DIR}/lib/configure.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"

require_state_file() { :; }

render_project() {
  local project_root="$1"
  local output_file="$2"

  PROJECT_ROOT="${project_root}"
  reset_project_root_paths
  set_runtime_paths
  COMPOSE_PROJECT_NAME="$(compose_project_name_for_root "${PROJECT_ROOT}")"
  BOT_REPO_DIR="${PROJECT_ROOT}/repos/bot-backend"
  BOT_ENV_FILE="${PROJECT_ROOT}/state/bot.env"
  BOT_OVERRIDE_ENV_FILE="${PROJECT_ROOT}/state/bot.override.env"
  BOT_DATA_DIR="${PROJECT_ROOT}/runtime/bot/data"
  BOT_LOGS_DIR="${PROJECT_ROOT}/runtime/bot/logs"
  BOT_UPLOADS_DIR="${PROJECT_ROOT}/runtime/bot/uploads"
  POSTGRES_DB=remnawave_bot
  POSTGRES_USER=remnawave_user
  POSTGRES_IMAGE='postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  REDIS_IMAGE='redis@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  BOT_HTTP_PORT="$3"
  COMPOSE_FILE="${output_file}"
  render_compose_file
}

render_project "${TEMP_ROOT}/project-one" "${TEMP_ROOT}/one.yml" 18080
project_one_name="${COMPOSE_PROJECT_NAME}"
render_project "${TEMP_ROOT}/project-two" "${TEMP_ROOT}/two.yml" 28080
project_two_name="${COMPOSE_PROJECT_NAME}"

[[ "${project_one_name}" != "${project_two_name}" ]]
[[ "${project_one_name}" =~ ^[a-z0-9][a-z0-9_-]+$ ]]
[[ "${project_two_name}" =~ ^[a-z0-9][a-z0-9_-]+$ ]]

for compose_file in "${TEMP_ROOT}/one.yml" "${TEMP_ROOT}/two.yml"; do
  ! grep -Fq 'container_name:' "${compose_file}"
  grep -Fq 'user: "1000:1000"' "${compose_file}"
done
grep -Fq '127.0.0.1:18080:8080' "${TEMP_ROOT}/one.yml"
grep -Fq '127.0.0.1:28080:8080' "${TEMP_ROOT}/two.yml"

PROJECT_ROOT="${TEMP_ROOT}/project-one"
reset_project_root_paths
set_runtime_paths
COMPOSE_PROJECT_NAME="${project_one_name}"
BOT_HTTP_PORT=18080
BOT_ENV_FILE="${TEMP_ROOT}/bot.env"
COMPOSE_FILE="${TEMP_ROOT}/one.yml"
: > "${BOT_ENV_FILE}"
compose_cmd config
grep -Fq -- "compose --project-name ${project_one_name}" "${DOCKER_LOG}"

host_port_has_no_public_listener() { return 0; }
export RUNTIME_TEST_BOT_BINDING='8080/tcp -> 0.0.0.0:18080'
if verify_private_runtime_ports; then
  printf '%s\n' 'Project-scoped public Bot binding was accepted.' >&2
  exit 1
fi
export RUNTIME_TEST_BOT_BINDING='8080/tcp -> 127.0.0.1:18080'
verify_private_runtime_ports

printf '%s\n' 'Runtime isolation integration harness passed.'
