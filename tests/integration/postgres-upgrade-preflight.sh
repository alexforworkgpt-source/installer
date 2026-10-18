#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/update.sh"
PROJECT_ROOT="${TEMP_ROOT}/project"
COMPOSE_PROJECT_NAME=preflight-test
set_runtime_paths
mkdir -p "${STATE_DIR}/.protected-update.fixture"
POSTGRES_IMAGE=postgres:15-alpine
POSTGRES_USER=fixture
POSTGRES_DB=fixture
MOCK_ENGINE=18
MOCK_VOLUME=preflight-test_postgres_data
AVAILABLE=1
docker() {
  case "$*" in
    'image inspect --format '* ) printf 'PG_MAJOR=%s\n' "${MOCK_ENGINE}" ;;
    'inspect --format {{.Config.Image}} pg-container') printf '%s\n' postgres:15-alpine ;;
    'inspect --format {{range .Mounts}}'*) printf '/var/lib/postgresql/data=%s\n' "${MOCK_VOLUME}" ;;
    'info --format {{.DockerRootDir}}') printf '%s\n' "${TEMP_ROOT}" ;;
    'volume inspect '*) return 1 ;;
    *) printf 'Unexpected mutation: %s\n' "$*" >&2; exit 99 ;;
  esac
}
compose_cmd() {
  case "$*" in
    'ps -q postgres') printf '%s\n' pg-container ;;
    *server_version_num*) printf '%s\n' 15 ;;
    *pg_database_size*) printf '%s\n' 10000000 ;;
    *) printf 'Unexpected mutation: %s\n' "$*" >&2; exit 99 ;;
  esac
}
df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfixture 999999999 0 %s 0%% /\n' "${AVAILABLE}"; }
context="${STATE_DIR}/.protected-update.fixture"
if prepare_postgres_update_storage "${context}" postgres:18-alpine; then
  echo 'Insufficient space was accepted.' >&2; exit 1
fi
[[ ! -e "${context}/target-postgres-volume" ]]
AVAILABLE=999999999
MOCK_VOLUME=foreign_postgres_data
if prepare_postgres_update_storage "${context}" postgres:18-alpine; then
  echo 'Foreign database volume was accepted.' >&2; exit 1
fi
[[ ! -e "${context}/target-postgres-volume" ]]
POSTGRES_MAJOR=18
POSTGRES_VOLUME_NAME=preflight-test_postgres18_data
MOCK_ENGINE=15
if prepare_postgres_update_storage "${context}" postgres:15-alpine; then
  echo 'PG18 -> PG15 image downgrade was accepted.' >&2; exit 1
fi
printf '%s\n' 'PostgreSQL preflight guards passed without runtime mutation.'
