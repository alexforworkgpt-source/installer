#!/usr/bin/env bash

postgres_image_major() {
  local image="$1" metadata major
  if ! metadata="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null)"; then
    docker pull "${image}" >&2 || return 1
    metadata="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}")" || return 1
  fi
  major="$(sed -n 's/^PG_MAJOR=//p' <<<"${metadata}")"
  [[ "${major}" == 15 || "${major}" == 18 ]] || {
    log_error "Образ PostgreSQL не содержит поддерживаемый PG_MAJOR (15 или 18)."
    return 1
  }
  printf '%s' "${major}"
}

# Legacy state without storage metadata belongs to PostgreSQL 15. Never infer
# an existing database layout from a new image tag.
postgres_storage_defaults() {
  POSTGRES_MAJOR="${POSTGRES_MAJOR:-15}"
  case "${POSTGRES_MAJOR}" in
    15) POSTGRES_MOUNT_PATH=/var/lib/postgresql/data ;;
    18) POSTGRES_MOUNT_PATH=/var/lib/postgresql ;;
    *) log_error "Неподдерживаемый PostgreSQL major: ${POSTGRES_MAJOR}"; return 1 ;;
  esac
  [[ "${COMPOSE_PROJECT_NAME}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  if [[ "${POSTGRES_MAJOR}" == 15 ]]; then
    POSTGRES_VOLUME_NAME="${POSTGRES_VOLUME_NAME:-${COMPOSE_PROJECT_NAME}_postgres_data}"
    [[ "${POSTGRES_VOLUME_NAME}" == "${COMPOSE_PROJECT_NAME}_postgres_data" ]] || return 1
  else
    POSTGRES_VOLUME_NAME="${POSTGRES_VOLUME_NAME:-${COMPOSE_PROJECT_NAME}_postgres18_data}"
    local suffix="${POSTGRES_VOLUME_NAME#"${COMPOSE_PROJECT_NAME}_postgres18_data"}"
    [[ "${POSTGRES_VOLUME_NAME}" == "${COMPOSE_PROJECT_NAME}_postgres18_data${suffix}" ]] || return 1
    [[ -z "${suffix}" || "${suffix}" =~ ^-[a-z0-9]+$ ]] || return 1
  fi
  POSTGRES_VOLUME_KEY="${POSTGRES_VOLUME_NAME#"${COMPOSE_PROJECT_NAME}_"}"
}

postgres_assert_runtime() {
  local major="$1" volume="$2" image="$3" destination container actual
  case "${major}" in
    15) destination=/var/lib/postgresql/data ;;
    18) destination=/var/lib/postgresql ;;
    *) return 1 ;;
  esac
  container="$(compose_cmd ps -q postgres)" || return 1
  [[ -n "${container}" && "${container}" != *$'\n'* ]] || return 1
  [[ "$(docker inspect --format '{{.Config.Image}}' "${container}")" == "${image}" ]] || return 1
  actual="$(docker inspect --format '{{range .Mounts}}{{printf "%s=%s\n" .Destination .Name}}{{end}}' "${container}")" || return 1
  grep -Fxq "${destination}=${volume}" <<<"${actual}" || return 1
  actual="$(compose_cmd exec -T postgres psql -XAt -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "SELECT current_setting('server_version_num')::int / 10000")" || return 1
  [[ "${actual}" == "${major}" ]]
}

postgres_database_manifest() {
  compose_cmd exec -T postgres psql -XqAt -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    < "${INSTALLER_DIR}/lib/postgres_manifest.sql"
}

postgres_storage_identity_from_file() (
  unset POSTGRES_MAJOR POSTGRES_VOLUME_NAME COMPOSE_PROJECT_NAME
  eval "$(run_env_helper read-state "$1")"
  set_runtime_paths
  postgres_storage_defaults || return 1
  printf '%s:%s' "${POSTGRES_MAJOR}" "${POSTGRES_VOLUME_NAME}"
)

postgres_require_same_snapshot_storage() {
  local restored_state="$1" current restored
  [[ -f "${STATE_FILE}" && -f "${restored_state}" ]] || return 0
  current="$(postgres_storage_identity_from_file "${STATE_FILE}")" || return 1
  restored="$(postgres_storage_identity_from_file "${restored_state}")" || return 1
  [[ "${current}" == "${restored}" ]] || {
    log_error "Snapshot настроек не может менять PostgreSQL storage. Нужен отдельный перенос/возврат базы."
    return 1
  }
}
