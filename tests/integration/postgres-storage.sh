#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT
export INSTALLER_GLOBAL_STATE_DIR="${TEMP_ROOT}/global"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/configure.sh"
PROJECT_ROOT="${TEMP_ROOT}/project"
set_runtime_paths
mkdir -p "${STATE_DIR}"
printf '%s\n' 'POSTGRES_PASSWORD=fixture' > "${BOT_ENV_FILE}"
: > "${BOT_OVERRIDE_ENV_FILE}"
cat > "${STATE_FILE}" <<EOF
PROJECT_ROOT='${PROJECT_ROOT}'
COMPOSE_PROJECT_NAME='storage-test'
POSTGRES_DB='test'
POSTGRES_USER='test'
POSTGRES_IMAGE='postgres:18-alpine'
POSTGRES_MAJOR='18'
POSTGRES_VOLUME_NAME='storage-test_postgres18_data'
REDIS_IMAGE='redis:7-alpine'
BOT_HTTP_PORT='18080'
EOF
render_compose_file
grep -Fq ':/var/lib/postgresql' "${COMPOSE_FILE}"
! grep -Fq ':/var/lib/postgresql/data' "${COMPOSE_FILE}"
volume_name() {
  docker compose --project-name "$1" --env-file "${BOT_ENV_FILE}" -f "${COMPOSE_FILE}" config --format json \
    | python3 -c 'import json,sys; c=json.load(sys.stdin); key=c["services"]["postgres"]["volumes"][0]["source"]; print(c["volumes"][key]["name"])'
}
[[ "$(volume_name storage-test)" == storage-test_postgres18_data ]]
# Standard Compose --project-name isolation must not share the live DB volume.
[[ "$(volume_name storage-clone)" == storage-clone_postgres18_data ]]
# A later settings render reloads the applied state and keeps the same storage.
POSTGRES_MAJOR=15
POSTGRES_VOLUME_NAME=wrong
render_compose_file
[[ "$(volume_name storage-test)" == storage-test_postgres18_data ]]
# Reject a PG18 configuration that would attach the legacy PG15 data volume.
sed -i "s/storage-test_postgres18_data/storage-test_postgres_data/" "${STATE_FILE}"
before="$(sha256sum "${COMPOSE_FILE}")"
if render_compose_file; then
  printf '%s\n' 'PG18 accepted the legacy data volume.' >&2
  exit 1
fi
[[ "$(sha256sum "${COMPOSE_FILE}")" == "${before}" ]]
# Old installations without the new keys retain their original volume/layout.
sed -i '/POSTGRES_MAJOR=/d; /POSTGRES_VOLUME_NAME=/d; s/postgres:18-alpine/postgres:15-alpine/' "${STATE_FILE}"
render_compose_file
grep -Fq 'postgres_data:/var/lib/postgresql/data' "${COMPOSE_FILE}"
[[ "$(volume_name storage-test)" == storage-test_postgres_data ]]
mkdir -p "${TEMP_ROOT}/old-snapshot"
cp "${STATE_FILE}" "${TEMP_ROOT}/old-snapshot/install.state"
cat >> "${STATE_FILE}" <<'EOF'
POSTGRES_MAJOR='18'
POSTGRES_VOLUME_NAME='storage-test_postgres18_data-upgrade1'
EOF
before_state="$(sha256sum "${STATE_FILE}")"
if (restore_snapshot_files_from_path "${TEMP_ROOT}/old-snapshot"); then
  printf '%s\n' 'Settings snapshot switched to stale PG15 storage.' >&2
  exit 1
fi
[[ "$(sha256sum "${STATE_FILE}")" == "${before_state}" ]]
printf '%s\n' 'PostgreSQL storage integration harness passed.'
