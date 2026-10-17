#!/usr/bin/env bash

postgres_require_upgrade_space() {
  local database_size docker_root available required directory
  database_size="$(compose_cmd exec -T postgres psql -XAt -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c 'SELECT pg_database_size(current_database())')" || return 1
  [[ "${database_size}" =~ ^[0-9]+$ ]] || return 1
  # Protect the dump, its test restore, and the new database. Do not estimate
  # from the compressed dump size or assume state and Docker share a disk.
  required=$((database_size * 3 + 268435456))
  docker_root="$(docker info --format '{{.DockerRootDir}}')" || return 1
  for directory in "${STATE_DIR}" "${docker_root}"; do
    [[ -d "${directory}" ]] || return 1
    available="$(df -PB1 "${directory}" | awk 'NR==2 {print $4}')"
    [[ "${available}" =~ ^[0-9]+$ && "${available}" -ge "${required}" ]] || {
      log_error "Недостаточно места для защищённого переноса PostgreSQL."
      return 1
    }
  done
}

prepare_postgres_update_storage() {
  local directory="$1" image="$2" target_major target_volume suffix
  postgres_storage_defaults || return 1
  local previous_major="${POSTGRES_MAJOR}" previous_volume="${POSTGRES_VOLUME_NAME}"
  target_major="$(postgres_image_major "${image}")" || return 1
  target_volume="${previous_volume}"
  if [[ "${target_major}" != "${previous_major}" ]]; then
    [[ "${previous_major}" == 15 && "${target_major}" == 18 ]] || {
      log_error "Разрешён только перенос PostgreSQL 15 -> 18; downgrade образа запрещён."
      return 1
    }
    postgres_assert_runtime "${previous_major}" "${previous_volume}" "${POSTGRES_IMAGE}" || return 1
    postgres_require_upgrade_space || return 1
    suffix="$(basename "${directory}" | sed 's/^\.protected-update\.//' | tr '[:upper:]' '[:lower:]')"
    [[ "${suffix}" =~ ^[a-z0-9]+$ ]] || return 1
    target_volume="${COMPOSE_PROJECT_NAME}_postgres18_data-${suffix}"
    if docker volume inspect "${target_volume}" >/dev/null 2>&1; then
      log_error "Новый PostgreSQL volume уже существует; повторное использование запрещено."
      return 1
    fi
  fi
  write_protected_update_context_value "${directory}" previous-postgres-major "${previous_major}" || return 1
  write_protected_update_context_value "${directory}" previous-postgres-volume "${previous_volume}" || return 1
  write_protected_update_context_value "${directory}" target-postgres-major "${target_major}" || return 1
  write_protected_update_context_value "${directory}" target-postgres-volume "${target_volume}"
}

postgres_upgrade_requested() {
  # Old interrupted updates have no engine transition metadata.
  [[ -f "${context_dir}/target-postgres-major" ]] || return 1
  [[ "$(context_value target-postgres-major)" != "$(context_value previous-postgres-major)" ]]
}

protect_postgres_upgrade() {
  postgres_upgrade_requested || return 0
  postgres_assert_runtime "$(context_value previous-postgres-major)" \
    "$(context_value previous-postgres-volume)" "${POSTGRES_IMAGE}" || return 1
  postgres_database_manifest > "${context_dir}/postgres-before.json.tmp" || return 1
  [[ -s "${context_dir}/postgres-before.json.tmp" ]] || return 1
  mv -f "${context_dir}/postgres-before.json.tmp" "${context_dir}/postgres-before.json" || return 1
  secure_private_file "${context_dir}/postgres-before.json" || return 1
  sync -f "${context_dir}/postgres-before.json"
  write_context_value postgres-before-sha256 "$(file_sha256 "${context_dir}/postgres-before.json")"
}

verify_postgres_upgrade_manifest() {
  local label="$1" before="${context_dir}/postgres-before.json"
  [[ -f "${before}" && ! -L "${before}" ]] || return 1
  [[ "$(file_sha256 "${before}")" == "$(context_value postgres-before-sha256)" ]] || return 1
  postgres_database_manifest > "${context_dir}/postgres-${label}.json" || return 1
  secure_private_file "${context_dir}/postgres-${label}.json" || return 1
  cmp "${before}" "${context_dir}/postgres-${label}.json" >/dev/null
}

apply_postgres_upgrade() {
  postgres_upgrade_requested || return 0
  local target_volume="$(context_value target-postgres-volume)" dump="$(context_value dump-reference)"
  [[ "$(context_value previous-postgres-major)" == 15 && "$(context_value target-postgres-major)" == 18 ]] || return 1
  [[ "${target_volume}" != "$(context_value previous-postgres-volume)" ]] || return 1
  if docker volume inspect "${target_volume}" >/dev/null 2>&1; then
    log_error "Target PG18 volume уже существует. Нужен rollback прерванной операции."
    return 1
  fi
  [[ -f "${dump}" && ! -L "${dump}" ]] || return 1
  [[ "$(file_sha256 "${dump}")" == "$(context_value dump-sha256)" ]] || return 1
  # Starting only postgres is essential: Bot must not create/migrate a blank DB.
  write_context_value postgres-upgrade-phase creating-target
  compose_cmd up -d --no-deps --wait --wait-timeout 180 postgres || return 1
  postgres_assert_runtime 18 "${target_volume}" "$(context_value target-postgres-image)" || return 1
  restore_verified_update_dump "${dump}" "$(context_value before-revision)" || return 1
  verify_postgres_upgrade_manifest restored || {
    log_error "Сверка таблиц/счётчиков PostgreSQL не прошла; запуск Bot запрещён."
    return 1
  }
  write_context_value postgres-upgrade-phase data-verified
}

record_postgres_upgrade_receipt() {
  postgres_upgrade_requested || return 0
  local outcome="$1" dump="$(context_value dump-reference)" receipt
  path_is_under "$(backup_dir_root)/database" "${dump}" || return 1
  receipt="${dump%.dump}.postgres-upgrade.txt"
  (
    umask 077
    {
      printf 'outcome=%s\n' "${outcome}"
      printf 'previous_image=%s\n' "$(context_value previous-postgres-image)"
      printf 'previous_volume=%s\n' "$(context_value previous-postgres-volume)"
      printf 'target_image=%s\n' "$(context_value target-postgres-image)"
      printf 'target_volume=%s\n' "$(context_value target-postgres-volume)"
      printf 'dump_sha256=%s\n' "$(context_value dump-sha256)"
      printf 'source_manifest_sha256=%s\n' "$(context_value postgres-before-sha256)"
      printf 'old_volume_retained=true\n'
      printf 'late_rollback_requires_current_data_recovery=true\n'
    } > "${receipt}.tmp"
  ) || return 1
  for label in before restored rollback; do
    if [[ -f "${context_dir}/postgres-${label}.json" ]]; then
      cp "${context_dir}/postgres-${label}.json" "${dump%.dump}.postgres-${label}.json" || return 1
      secure_private_file "${dump%.dump}.postgres-${label}.json" || return 1
    fi
  done
  mv -f "${receipt}.tmp" "${receipt}" || return 1
  secure_private_file "${receipt}" || return 1
  sync -f "${receipt}"
  sync -f "$(dirname "${receipt}")"
}
