#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="${TEMP_ROOT}/bot-stack"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"
FAKE_BIN="${TEMP_ROOT}/bin"
DOCKER_LOG="${TEMP_ROOT}/docker.log"
LEGACY_PROJECT="bedolaga-232719bb124c"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STATE_DIR}" "${FAKE_BIN}"
cat > "${STATE_FILE}" <<EOF
PROJECT_ROOT='${PROJECT_ROOT}'
BOT_VERSION_REF='v4.1.0'
CABINET_VERSION_REF='v1.66.0'
EOF
printf '%s\n' 'imported_at=2026-08-05T20:16:06Z' \
  > "${STATE_DIR}/migration.completed"
cat > "${PROJECT_ROOT}/.migration-resources-created" <<EOF
compose_project=${LEGACY_PROJECT}
volume=${LEGACY_PROJECT}_postgres_data
volume=${LEGACY_PROJECT}_redis_data
EOF
cat > "${STATE_DIR}/migration-image.override.yml" <<EOF
name: "${LEGACY_PROJECT}"
services:
  postgres:
    image: "bedolaga-migration/postgres:20260805-220129"
  redis:
    image: "bedolaga-migration/redis:20260805-220129"
  bot:
    image: "bedolaga-local/bot:v4.1.0"
    restart: unless-stopped
EOF

cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG}"

if [[ "${1:-}" == ps && "$*" == *'service=bot'* ]]; then
  printf '%s\n' bot-id
  exit 0
fi
if [[ "${1:-}" == ps && "$*" == *'service=postgres'* ]]; then
  printf '%s\n' postgres-id
  exit 0
fi
if [[ "${1:-}" == ps && "$*" == *'service=redis'* ]]; then
  printf '%s\n' redis-id
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'.Mounts'* && "$*" == *'bot-id'* ]]; then
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'.Mounts'* && "$*" == *'postgres-id'* ]]; then
  if [[ "${BAD_MIGRATION_MOUNT:-}" == true ]]; then
    printf '%s\n' '/var/lib/postgresql/data=wrong_postgres_data'
  else
    printf '%s\n' '/var/lib/postgresql/data=bedolaga-232719bb124c_postgres_data'
  fi
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'.Mounts'* && "$*" == *'redis-id'* ]]; then
  printf '%s\n' '/data=bedolaga-232719bb124c_redis_data'
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'bot-id'* ]]; then
  printf '%s\n' 'bedolaga-local/bot:v4.1.0'
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'postgres-id'* ]]; then
  printf '%s\n' 'bedolaga-migration/postgres:20260805-220129'
  exit 0
fi
if [[ "${1:-}" == inspect && "$*" == *'redis-id'* ]]; then
  printf '%s\n' 'bedolaga-migration/redis:20260805-220129'
  exit 0
fi
if [[ "${1:-}" == volume && "${2:-}" == inspect ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "${FAKE_BIN}/docker"
export PATH="${FAKE_BIN}:${PATH}"
export DOCKER_LOG

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"
PROJECT_ROOT="${TEMP_ROOT}/bot-stack"
STATE_DIR="${PROJECT_ROOT}/state"
STATE_FILE="${STATE_DIR}/install.state"

export BAD_MIGRATION_MOUNT=true
if (adopt_completed_migration_runtime_identity); then
  printf '%s\n' 'unsafe migration volume was accepted' >&2
  exit 1
fi
unset BAD_MIGRATION_MOUNT

adopt_completed_migration_runtime_identity

[[ "${COMPOSE_PROJECT_NAME}" == "${LEGACY_PROJECT}" ]]
[[ "${POSTGRES_IMAGE}" == 'bedolaga-migration/postgres:20260805-220129' ]]
[[ "${REDIS_IMAGE}" == 'bedolaga-migration/redis:20260805-220129' ]]
grep -Fq "COMPOSE_PROJECT_NAME='${LEGACY_PROJECT}'" "${STATE_FILE}"
grep -Fq "POSTGRES_IMAGE='bedolaga-migration/postgres:20260805-220129'" "${STATE_FILE}"
grep -Fq "REDIS_IMAGE='bedolaga-migration/redis:20260805-220129'" "${STATE_FILE}"
[[ -f "${STATE_DIR}/migration-image.override.yml" ]]
[[ -n "$(find "${STATE_DIR}/migration-backups" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]

PROTECTED_CONTEXT="${STATE_DIR}/.protected-update.test"
mkdir -p "${PROTECTED_CONTEXT}"
protect_completed_migration_image_override "${PROTECTED_CONTEXT}"
cmp "${STATE_DIR}/migration-image.override.yml" \
  "${PROTECTED_CONTEXT}/previous-migration-image.override.yml"

rm -f "${STATE_DIR}/migration-image.override.yml"
adopt_completed_migration_runtime_identity
[[ "${MIGRATION_IMAGE_OVERRIDE_PRESENT}" == false ]]

! grep -Eq '(^| )(up|stop|down|rm|restart)( |$)' "${DOCKER_LOG}"

printf '%s\n' 'Completed migration runtime identity integration harness passed.'
