#!/usr/bin/env bash

set -Eeuo pipefail

MIGRATION_FORMAT_VERSION="1"
MIGRATION_HELPER="${INSTALLER_DIR}/lib/migration_helper.py"

migration_manifest_value() {
  local manifest_file="$1"
  local key="$2"
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${manifest_file}"
}

migration_service_is_running() {
  local service_name="$1"
  compose_cmd ps --status running --services 2>/dev/null | grep -Fxq "${service_name}"
}

migration_service_container() {
  local service_name="$1"
  compose_cmd ps --all -q "${service_name}" 2>/dev/null | head -n 1
}

migration_volume_for_destination() {
  local container_id="$1"
  local destination="$2"
  docker inspect "${container_id}" \
    --format "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Name}}{{end}}{{end}}"
}

migration_copy_tree() {
  local source_dir="$1"
  local target_dir="$2"

  [[ -d "${source_dir}" ]] || return 0
  mkdir -p "${target_dir}"
  tar -C "${source_dir}" -cf - . | tar -C "${target_dir}" -xf -
}

migration_repo_commit() {
  local repo_dir="$1"
  [[ -d "${repo_dir}/.git" ]] || die "Git-репозиторий не найден: ${repo_dir}"
  git -C "${repo_dir}" rev-parse HEAD
}

migration_repo_is_dirty() {
  local repo_dir="$1"
  [[ -n "$(git -C "${repo_dir}" status --porcelain 2>/dev/null)" ]]
}

migration_remove_project_stack() {
  local project_root="$1"
  local compose_file="${project_root}/state/docker-compose.yml"
  local override_file="${project_root}/state/migration-image.override.yml"
  local resource_marker="${project_root}/.migration-resources-created"
  local compose_project=""
  local compose_args=()
  local resource_name

  is_safe_project_root "${project_root}" || die "Небезопасный путь очистки: ${project_root}"
  if [[ -f "${resource_marker}" ]]; then
    [[ -f "${compose_file}" && -f "${override_file}" ]] \
      || { log_error "Не хватает compose-файлов для безопасной очистки ${project_root}."; return 1; }
    compose_project="$(migration_manifest_value "${resource_marker}" compose_project)"
    [[ "${compose_project}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
      || { log_error "Некорректный Compose project в marker очистки ${project_root}."; return 1; }
    compose_args=(-f "${compose_file}")
    compose_args+=(-f "${override_file}")
    docker compose --project-name "${compose_project}" "${compose_args[@]}" down -v \
      || { log_error "Docker не подтвердил удаление ресурсов миграции."; return 1; }

    if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${compose_project}")" ]]; then
      log_error "Контейнеры Compose project ${compose_project} не удалены."
      return 1
    fi
    while IFS= read -r resource_name; do
      [[ -n "${resource_name}" ]] || continue
      if docker volume inspect "${resource_name}" >/dev/null 2>&1; then
        log_error "Volume миграции не удален: ${resource_name}"
        return 1
      fi
    done < <(awk -F= '$1 == "volume" {sub(/^[^=]*=/, ""); print}' "${resource_marker}")
  fi
  safe_rm_rf_under "$(dirname "${project_root}")" "${project_root}"
}

migration_remove_recorded_caddy() {
  local marker_file="$1"
  local snippet_dir="/etc/caddy/conf.d"
  local caddy_path

  [[ -f "${marker_file}" ]] || return 0
  while IFS= read -r caddy_path; do
    [[ "${caddy_path}" == "${snippet_dir}/bedolaga-"*.caddy || "${caddy_path}" == "${snippet_dir}/landing-"*.caddy ]] \
      || continue
    rm -f "${caddy_path}"
  done < <(awk -F= '$1 == "caddy_file" {sub(/^[^=]*=/, ""); print}' "${marker_file}")
}

migration_domain_points_here() {
  local domain="$1"
  local public_ipv4=""
  local resolved_ipv4=""

  domain_points_to_local_machine "${domain}" && return 0
  public_ipv4="$(curl_with_timeouts -4fsS https://api.ipify.org 2>/dev/null || true)"
  resolved_ipv4="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u)"
  [[ -n "${public_ipv4}" ]] && grep -Fxq "${public_ipv4}" <<<"${resolved_ipv4}"
}

migration_local_caddy_status() {
  local domain="$1"
  local path="$2"
  curl_with_timeouts -sS \
    --resolve "${domain}:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' \
    "https://${domain}${path}" 2>/dev/null || true
}

recover_pending_migration_bot() {
  resolve_state_file
  [[ -f "${STATE_FILE}" ]] || return 0
  load_state
  [[ -f "${STATE_DIR}/migration.pending" ]] || return 0
  [[ -f "${STATE_DIR}/migration-image.override.yml" ]] || return 0
  command_exists docker || return 0

  docker compose \
    --project-name "${COMPOSE_PROJECT_NAME}" \
    -f "${COMPOSE_FILE}" \
    -f "${STATE_DIR}/migration-image.override.yml" \
    stop bot >/dev/null 2>&1 || true
  if migration_service_is_running bot; then
    log_error "Не удалось остановить бота незавершенной миграции."
    return 1
  fi
  log_warn "Незавершенная миграция: бот удерживается остановленным до повторной активации."
}

recover_completed_migration_restart() {
  resolve_state_file
  [[ -f "${STATE_FILE}" ]] || return 0
  load_state
  [[ -f "${STATE_DIR}/migration.completed" ]] || return 0
  [[ -f "${STATE_DIR}/migration-image.override.yml" ]] || return 0

  if grep -Fq 'restart: "no"' "${STATE_DIR}/migration-image.override.yml"; then
    sed -i 's/restart: "no"/restart: unless-stopped/' "${STATE_DIR}/migration-image.override.yml"
  fi
  local bot_container
  bot_container="$(migration_service_container bot)"
  if command_exists docker && [[ -n "${bot_container}" ]]; then
    docker update --restart unless-stopped "${bot_container}" >/dev/null \
      || log_warn "Не удалось включить автозапуск Bot container."
  fi
}

create_migration_export() {
  ensure_root
  require_state_file
  require_docker_compose || die "Docker Compose недоступен."

  local output_dir
  local final_cutover="false"
  local timestamp
  local staging_dir
  local archive_path
  local archive_temp
  local checksum_path
  local bot_container
  local postgres_container
  local redis_container
  local redis_volume
  local bot_commit
  local cabinet_commit
  local bot_dirty="false"
  local cabinet_dirty="false"
  local bot_image_id
  local postgres_image_id
  local redis_image_id
  local bot_image_tag
  local postgres_image_tag
  local redis_image_tag
  local bot_was_running="false"
  local redis_was_running="false"
  local export_completed="false"
  local service_name
  local old_umask
  local operation_marker="${STATE_DIR}/migration-export.in-progress"

  if [[ -f "${operation_marker}" ]]; then
    log_warn "Найден прерванный экспорт. Возвращаю сервисы в рабочее состояние."
    compose_cmd start postgres redis bot >/dev/null 2>&1 \
      || die "Не удалось восстановить сервисы после прерванного экспорта; marker сохранён."
    rm -f "${operation_marker}"
  fi

  output_dir="$(prompt_input \
    "Каталог для пакета переноса" \
    "абсолютный путь вне PROJECT_ROOT" \
    "/root" \
    "/root")"
  [[ "${output_dir}" == /* ]] || die "Нужен абсолютный путь к каталогу."
  if path_is_under "${PROJECT_ROOT}" "${output_dir}"; then
    die "Пакет переноса нельзя создавать внутри ${PROJECT_ROOT}."
  fi

  if prompt_yes_no "Это финальный экспорт? После него оставить старого бота остановленным?" "n"; then
    final_cutover="true"
  fi

  for service_name in postgres redis bot; do
    migration_service_is_running "${service_name}" \
      || die "Сервис ${service_name} должен быть запущен и healthy перед экспортом."
  done

  bot_was_running="true"
  redis_was_running="true"
  bot_container="$(migration_service_container bot)"
  postgres_container="$(migration_service_container postgres)"
  redis_container="$(migration_service_container redis)"
  [[ -n "${bot_container}" && -n "${postgres_container}" && -n "${redis_container}" ]] \
    || die "Не удалось определить контейнеры стека."

  bot_commit="$(migration_repo_commit "${BOT_REPO_DIR}")"
  cabinet_commit="$(migration_repo_commit "${CABINET_REPO_DIR}")"
  migration_repo_is_dirty "${BOT_REPO_DIR}" && bot_dirty="true"
  migration_repo_is_dirty "${CABINET_REPO_DIR}" && cabinet_dirty="true"

  bot_image_id="$(docker inspect "${bot_container}" --format '{{.Image}}')"
  postgres_image_id="$(docker inspect "${postgres_container}" --format '{{.Image}}')"
  redis_image_id="$(docker inspect "${redis_container}" --format '{{.Image}}')"
  redis_volume="$(migration_volume_for_destination "${redis_container}" "/data")"
  [[ -n "${redis_volume}" ]] || die "Не удалось определить Docker volume Redis."

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  bot_image_tag="bedolaga-migration/bot:${timestamp}"
  postgres_image_tag="bedolaga-migration/postgres:${timestamp}"
  redis_image_tag="bedolaga-migration/redis:${timestamp}"
  staging_dir="$(mktemp -d)"
  old_umask="$(umask)"
  umask 077
  mkdir -p "${output_dir}"
  archive_path="${output_dir}/bedolaga-migration-${timestamp}.tar.gz"
  archive_temp="${staging_dir}/migration.tar.gz"
  checksum_path="${archive_path}.sha256"

  migration_export_cleanup() {
    local exit_code=$?
    local restart_failed="false"
    trap - EXIT
    if [[ "${redis_was_running}" == "true" ]]; then
      if ! compose_cmd start redis >/dev/null 2>&1; then
        log_error "Не удалось запустить Redis после экспорта."
        restart_failed="true"
      fi
    fi
    if [[ "${bot_was_running}" == "true" && ("${export_completed}" != "true" || "${final_cutover}" != "true") ]]; then
      if ! compose_cmd start bot >/dev/null 2>&1; then
        log_error "Не удалось запустить Bot после экспорта."
        restart_failed="true"
      fi
    fi
    [[ -n "${bot_image_tag}" ]] && docker image rm "${bot_image_tag}" >/dev/null 2>&1 || true
    [[ -n "${postgres_image_tag}" ]] && docker image rm "${postgres_image_tag}" >/dev/null 2>&1 || true
    [[ -n "${redis_image_tag}" ]] && docker image rm "${redis_image_tag}" >/dev/null 2>&1 || true
    if [[ "${export_completed}" != "true" ]]; then
      rm -f "${archive_path}" "${checksum_path}" >/dev/null 2>&1 || true
    fi
    if [[ "${restart_failed}" == "false" ]]; then
      rm -f "${operation_marker}" >/dev/null 2>&1 || true
    else
      log_error "Migration export marker сохранён для повторного восстановления сервисов."
      [[ "${exit_code}" -ne 0 ]] || exit_code=1
    fi
    rm -rf "${staging_dir}" >/dev/null 2>&1 || true
    umask "${old_umask}"
    return "${exit_code}"
  }
  trap migration_export_cleanup EXIT

  log_warn "Бот будет остановлен на время создания согласованного пакета."
  printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${operation_marker}"
  secure_private_file "${operation_marker}"
  compose_cmd stop -t 30 bot

  mkdir -p \
    "${staging_dir}/database" \
    "${staging_dir}/images" \
    "${staging_dir}/project/state" \
    "${staging_dir}/project/runtime" \
    "${staging_dir}/project/caddy"

  log_info "Создание логического дампа PostgreSQL."
  compose_cmd exec -T postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    --format=custom --no-owner --no-acl \
    > "${staging_dir}/database/postgres.dump"
  compose_cmd exec -T postgres pg_restore --list \
    < "${staging_dir}/database/postgres.dump" >/dev/null

  log_info "Фиксация Redis и runtime-файлов."
  compose_cmd exec -T redis redis-cli SAVE >/dev/null
  compose_cmd stop -t 30 redis
  docker run --rm \
    --volume "${redis_volume}:/source:ro" \
    --volume "${staging_dir}/database:/backup" \
    "${redis_image_id}" \
    tar -czf /backup/redis-data.tar.gz -C /source .

  tar \
    --exclude='./backups' \
    --exclude='./backups/*' \
    --exclude='./snapshots' \
    --exclude='./snapshots/*' \
    --exclude='./migration-export.in-progress' \
    --exclude='./migration-image.override.yml' \
    --exclude='./migration.pending' \
    --exclude='./migration.completed' \
    -C "${STATE_DIR}" -cf - . \
    | tar -C "${staging_dir}/project/state" -xf -
  migration_copy_tree "${REPOS_DIR}" "${staging_dir}/project/repos"
  migration_copy_tree "${BOT_DATA_DIR}" "${staging_dir}/project/runtime/bot/data"
  migration_copy_tree "${BOT_UPLOADS_DIR}" "${staging_dir}/project/runtime/bot/uploads"
  migration_copy_tree "${CABINET_DIST_DIR}" "${staging_dir}/project/runtime/cabinet-dist"
  migration_copy_tree "${RUNTIME_DIR}/landing-dist" "${staging_dir}/project/runtime/landing-dist"

  if [[ -d "${CADDY_SNIPPET_DIR}" ]]; then
    while IFS= read -r -d '' snippet_file; do
      cp -a "${snippet_file}" "${staging_dir}/project/caddy/"
    done < <(find "${CADDY_SNIPPET_DIR}" -maxdepth 1 -type f -name 'landing-*.caddy' -print0)
  fi

  log_info "Сохранение точных Docker-образов запущенного стека."
  docker image tag "${bot_image_id}" "${bot_image_tag}"
  docker image tag "${postgres_image_id}" "${postgres_image_tag}"
  docker image tag "${redis_image_id}" "${redis_image_tag}"
  docker image save \
    --output "${staging_dir}/images/runtime-images.tar" \
    "${bot_image_tag}" "${postgres_image_tag}" "${redis_image_tag}"

  cat > "${staging_dir}/manifest.env" <<EOF
FORMAT_VERSION=${MIGRATION_FORMAT_VERSION}
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PROJECT_ROOT=${PROJECT_ROOT}
ARCHITECTURE=$(uname -m)
BOT_COMMIT=${bot_commit}
CABINET_COMMIT=${cabinet_commit}
BOT_DIRTY=${bot_dirty}
CABINET_DIRTY=${cabinet_dirty}
BOT_IMAGE_TAG=${bot_image_tag}
POSTGRES_IMAGE_TAG=${postgres_image_tag}
REDIS_IMAGE_TAG=${redis_image_tag}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
FINAL_CUTOVER=${final_cutover}
EOF

  (
    cd "${staging_dir}"
    find manifest.env database images project -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum > checksums.sha256
  )
  (cd "${staging_dir}" && sha256sum -c checksums.sha256 >/dev/null)

  log_info "Упаковка миграционного архива."
  tar -C "${staging_dir}" -czf "${archive_temp}" \
    manifest.env checksums.sha256 database images project
  tar -tzf "${archive_temp}" >/dev/null
  mv -f "${archive_temp}" "${archive_path}"
  (
    cd "${output_dir}"
    sha256sum "$(basename "${archive_path}")" > "$(basename "${checksum_path}")"
  )
  secure_private_file "${archive_path}"
  secure_private_file "${checksum_path}"

  export_completed="true"
  trap - EXIT
  migration_export_cleanup

  log_info "Пакет переноса создан: ${archive_path}"
  log_info "Контрольная сумма: ${checksum_path}"
  log_warn "Архив содержит токены, пароли и ключи. Передавайте его только по SSH/SCP и удалите после проверки."
  if [[ "${final_cutover}" == "true" ]]; then
    log_warn "Старый бот оставлен остановленным. Не запускайте его после импорта на новую VPS."
  else
    log_info "Старый бот снова запущен. Для реального переключения сделайте финальный экспорт."
  fi
}

import_migration_archive() {
  ensure_root

  local archive_path
  local checksum_path
  local extract_dir
  local manifest_file
  local format_version
  local target_root=""
  local source_architecture
  local bot_commit
  local cabinet_commit
  local bot_image_tag
  local postgres_image_tag
  local redis_image_tag
  local restored_bot_commit
  local restored_cabinet_commit
  local redis_container
  local redis_volume
  local override_file
  local image_tag
  local project_restored="false"
  local import_completed="false"
  local caddy_file
  local caddy_target
  local copied_caddy_paths=()
  local compose_project
  local expected_volume
  local in_progress_marker
  local resource_marker
  local pending_temp

  archive_path="$(prompt_input \
    "Путь к пакету переноса" \
    "полный путь к bedolaga-migration-*.tar.gz" \
    "/root/bedolaga-migration-20260101-120000.tar.gz" \
    "")"
  [[ -f "${archive_path}" ]] || die "Архив не найден: ${archive_path}"
  checksum_path="${archive_path}.sha256"
  if [[ -f "${checksum_path}" ]]; then
    (cd "$(dirname "${archive_path}")" && sha256sum -c "$(basename "${checksum_path}")") \
      || die "Контрольная сумма архива не совпала."
  else
    log_warn "Sidecar-файл ${checksum_path} не найден. Будет проверено только содержимое пакета."
  fi

  assert_supported_os
  install_base_packages
  install_docker_engine
  ensure_docker_compose_plugin
  enable_services

  extract_dir="$(mktemp -d)"
  migration_import_cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ "${import_completed}" != "true" && "${project_restored}" == "true" && -n "${target_root}" ]]; then
      migration_remove_project_stack "${target_root}" >/dev/null 2>&1 || true
      for caddy_target in "${copied_caddy_paths[@]}"; do
        rm -f "${caddy_target}" >/dev/null 2>&1 || true
      done
    fi
    rm -rf "${extract_dir}" >/dev/null 2>&1 || true
    return "${exit_code}"
  }
  trap migration_import_cleanup EXIT

  run_python "${MIGRATION_HELPER}" extract "${archive_path}" "${extract_dir}"
  manifest_file="${extract_dir}/manifest.env"
  [[ -f "${manifest_file}" && -f "${extract_dir}/checksums.sha256" ]] \
    || die "В пакете отсутствует manifest или список контрольных сумм."
  (cd "${extract_dir}" && sha256sum -c checksums.sha256) \
    || die "Один или несколько файлов пакета повреждены."

  format_version="$(migration_manifest_value "${manifest_file}" FORMAT_VERSION)"
  [[ "${format_version}" == "${MIGRATION_FORMAT_VERSION}" ]] \
    || die "Неподдерживаемая версия пакета: ${format_version:-не задана}."

  target_root="$(migration_manifest_value "${manifest_file}" PROJECT_ROOT)"
  source_architecture="$(migration_manifest_value "${manifest_file}" ARCHITECTURE)"
  bot_commit="$(migration_manifest_value "${manifest_file}" BOT_COMMIT)"
  cabinet_commit="$(migration_manifest_value "${manifest_file}" CABINET_COMMIT)"
  bot_image_tag="$(migration_manifest_value "${manifest_file}" BOT_IMAGE_TAG)"
  postgres_image_tag="$(migration_manifest_value "${manifest_file}" POSTGRES_IMAGE_TAG)"
  redis_image_tag="$(migration_manifest_value "${manifest_file}" REDIS_IMAGE_TAG)"

  is_safe_project_root "${target_root}" || die "Небезопасный PROJECT_ROOT в пакете: ${target_root}"
  [[ "${source_architecture}" == "$(uname -m)" ]] \
    || die "Архитектура VPS отличается: пакет=${source_architecture}, сервер=$(uname -m)."
  [[ "${bot_commit}" =~ ^[0-9a-f]{40}$ && "${cabinet_commit}" =~ ^[0-9a-f]{40}$ ]] \
    || die "В manifest отсутствуют корректные Git SHA."

  in_progress_marker="${target_root}/.migration-import-in-progress"
  resource_marker="${target_root}/.migration-resources-created"
  if [[ -f "${in_progress_marker}" ]]; then
    log_warn "Найден незавершенный импорт в ${target_root}."
    prompt_typed_confirmation "RETRY_IMPORT" "Удалить только ресурсы прерванного импорта и повторить?" \
      || die "Повторный импорт отменен."
    migration_remove_recorded_caddy "${in_progress_marker}"
    migration_remove_project_stack "${target_root}"
    if command_exists caddy && [[ -f /etc/caddy/Caddyfile ]]; then
      caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
    fi
  fi

  if [[ -d "${target_root}" && -n "$(find "${target_root}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "Каталог ${target_root} уже содержит данные. Импорт разрешен только на чистую VPS."
  fi

  log_info "Восстановление файлов проекта в ${target_root}."
  mkdir -p "${target_root}"
  project_restored="true"
  printf 'source_archive=%s\n' "${archive_path}" > "${in_progress_marker}"
  secure_private_file "${in_progress_marker}"
  [[ -d "${extract_dir}/project/state" ]] \
    && cp -a "${extract_dir}/project/state" "${target_root}/state"
  [[ -d "${extract_dir}/project/repos" ]] \
    && cp -a "${extract_dir}/project/repos" "${target_root}/repos"
  [[ -d "${extract_dir}/project/runtime" ]] \
    && cp -a "${extract_dir}/project/runtime" "${target_root}/runtime"

  PROJECT_ROOT="${target_root}"
  reset_project_root_paths
  set_runtime_paths
  STATE_FILE="${STATE_DIR}/install.state"
  [[ -f "${STATE_FILE}" ]] || die "В пакете отсутствует ${STATE_FILE}."
  save_last_project_root
  load_state
  [[ "${PROJECT_ROOT}" == "${target_root}" ]] \
    || die "PROJECT_ROOT в восстановленном state не совпадает с manifest."

  PROJECT_ROOT="${target_root}"
  reset_project_root_paths
  set_runtime_paths
  CADDY_SNIPPET_DIR="/etc/caddy/conf.d"
  CADDY_SNIPPET_FILE="${CADDY_SNIPPET_DIR}/${COMPOSE_PROJECT_NAME}.caddy"
  STATE_FILE="${STATE_DIR}/install.state"

  restored_bot_commit="$(migration_repo_commit "${BOT_REPO_DIR}")"
  restored_cabinet_commit="$(migration_repo_commit "${CABINET_REPO_DIR}")"
  [[ "${restored_bot_commit}" == "${bot_commit}" ]] \
    || die "SHA репозитория бота не совпал после восстановления."
  [[ "${restored_cabinet_commit}" == "${cabinet_commit}" ]] \
    || die "SHA репозитория кабинета не совпал после восстановления."

  BOT_VERSION_REF="${bot_commit}"
  CABINET_VERSION_REF="${cabinet_commit}"
  save_state
  ensure_directories
  ensure_runtime_permissions

  [[ ! -e "${CADDY_SNIPPET_FILE}" ]] \
    || die "Caddy snippet уже существует на новой VPS: ${CADDY_SNIPPET_FILE}"
  if [[ -d "${extract_dir}/project/caddy" ]]; then
    while IFS= read -r -d '' caddy_file; do
      caddy_target="${CADDY_SNIPPET_DIR}/$(basename "${caddy_file}")"
      [[ ! -e "${caddy_target}" ]] \
        || die "Caddy snippet уже существует на новой VPS: ${caddy_target}"
    done < <(find "${extract_dir}/project/caddy" -maxdepth 1 -type f -name 'landing-*.caddy' -print0)
  fi

  compose_project="${COMPOSE_PROJECT_NAME}"
  if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${compose_project}")" ]]; then
    die "Compose project ${compose_project} уже существует. Импорт разрешен только на чистый target project."
  fi
  for expected_volume in "${compose_project}_postgres_data" "${compose_project}_redis_data"; do
    if docker volume inspect "${expected_volume}" >/dev/null 2>&1; then
      die "Docker volume ${expected_volume} уже существует. Удалите остатки предыдущей попытки через меню переноса."
    fi
  done

  log_info "Загрузка точных Docker-образов со старой VPS."
  docker image load --input "${extract_dir}/images/runtime-images.tar"
  for image_tag in "${bot_image_tag}" "${postgres_image_tag}" "${redis_image_tag}"; do
    docker image inspect "${image_tag}" >/dev/null \
      || die "Docker-образ не восстановлен: ${image_tag}"
  done

  override_file="${STATE_DIR}/migration-image.override.yml"
  cat > "${override_file}" <<EOF
services:
  postgres:
    image: "${postgres_image_tag}"
  redis:
    image: "${redis_image_tag}"
  bot:
    image: "${bot_image_tag}"
    restart: "no"
EOF
  secure_private_file "${override_file}"
  compose_cmd config -q

  cat > "${resource_marker}" <<EOF
compose_project=${compose_project}
volume=${compose_project}_postgres_data
volume=${compose_project}_redis_data
EOF
  secure_private_file "${resource_marker}"

  log_info "Запуск PostgreSQL и восстановление актуальной базы."
  compose_cmd up -d --wait --wait-timeout 180 postgres
  compose_cmd exec -T postgres \
    dropdb -U "${POSTGRES_USER}" --if-exists --force "${POSTGRES_DB}"
  compose_cmd exec -T postgres \
    createdb -U "${POSTGRES_USER}" -O "${POSTGRES_USER}" "${POSTGRES_DB}"
  compose_cmd exec -T postgres \
    pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    --no-owner --no-acl --exit-on-error \
    < "${extract_dir}/database/postgres.dump"

  log_info "Восстановление Redis."
  compose_cmd create redis >/dev/null
  redis_container="$(migration_service_container redis)"
  [[ -n "${redis_container}" ]] || die "Не удалось создать контейнер Redis."
  redis_volume="$(migration_volume_for_destination "${redis_container}" "/data")"
  [[ -n "${redis_volume}" ]] || die "Не удалось определить новый Redis volume."
  docker run --rm \
    --volume "${redis_volume}:/target" \
    --volume "${extract_dir}/database:/backup:ro" \
    "${redis_image_tag}" \
    tar -xzf /backup/redis-data.tar.gz -C /target

  if [[ -d "${extract_dir}/project/caddy" ]]; then
    mkdir -p "${CADDY_SNIPPET_DIR}"
    while IFS= read -r -d '' caddy_file; do
      caddy_target="${CADDY_SNIPPET_DIR}/$(basename "${caddy_file}")"
      [[ ! -e "${caddy_target}" ]] \
        || die "Caddy snippet уже существует на новой VPS: ${caddy_target}"
      printf 'caddy_file=%s\n' "${caddy_target}" >> "${in_progress_marker}"
      cp -a "${caddy_file}" "${caddy_target}"
      copied_caddy_paths+=("${caddy_target}")
    done < <(find "${extract_dir}/project/caddy" -maxdepth 1 -type f -name 'landing-*.caddy' -print0)
  fi
  printf 'caddy_file=%s\n' "${CADDY_SNIPPET_FILE}" >> "${in_progress_marker}"
  install_caddy_candidate
  copied_caddy_paths+=("${CADDY_SNIPPET_FILE}")
  reload_caddy

  compose_cmd stop postgres >/dev/null
  pending_temp="$(mktemp "${STATE_DIR}/.migration.pending.XXXXXX")"
  cat > "${pending_temp}" <<EOF
imported_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
source_archive=${archive_path}
bot_commit=${bot_commit}
cabinet_commit=${cabinet_commit}
bot_image_tag=${bot_image_tag}
postgres_image_tag=${postgres_image_tag}
redis_image_tag=${redis_image_tag}
EOF
  for caddy_target in "${copied_caddy_paths[@]}"; do
    printf 'caddy_file=%s\n' "${caddy_target}" >> "${pending_temp}"
  done
  secure_private_file "${pending_temp}"
  mv -f "${pending_temp}" "${STATE_DIR}/migration.pending"
  rm -f "${in_progress_marker}"

  import_completed="true"
  trap - EXIT
  migration_import_cleanup
  log_info "Импорт завершен. Бот, PostgreSQL и Redis оставлены остановленными."
  log_warn "Теперь переключите DNS на новую VPS, остановите старого бота и выберите 'Активировать перенесенный проект'."
}

activate_migrated_stack() {
  ensure_root
  require_state_file

  local override_file="${STATE_DIR}/migration-image.override.yml"
  local activation_completed="false"
  local app_local_status
  local hook_local_status
  [[ -f "${STATE_DIR}/migration.pending" ]] \
    || die "Не найден незавершенный импорт: ${STATE_DIR}/migration.pending"
  [[ -f "${override_file}" ]] || die "Не найден override точных Docker-образов: ${override_file}"

  log_warn "Перед активацией старый бот должен быть остановлен, а DNS A/AAAA направлены на эту VPS."
  if ! migration_domain_points_here "${APP_DOMAIN}" || ! migration_domain_points_here "${HOOK_DOMAIN}"; then
    log_warn "Не удалось подтвердить, что оба домена уже направлены на эту VPS."
    prompt_typed_confirmation "DNS_OVERRIDE" "Продолжить, только если используется DNS proxy и старая VPS остановлена." \
      || die "Активация отменена до корректного переключения DNS."
  fi
  prompt_typed_confirmation "ACTIVATE" "Подтверждение финального переключения." \
    || die "Активация отменена."

  migration_activation_cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ "${activation_completed}" != "true" && ! -f "${STATE_DIR}/migration.completed" ]]; then
      compose_cmd stop bot >/dev/null 2>&1 || true
      log_warn "Активация не завершена: новый бот остановлен для защиты от двойной обработки."
    fi
    return "${exit_code}"
  }
  trap migration_activation_cleanup EXIT

  install_caddy_candidate
  reload_caddy
  compose_cmd up -d --no-build --wait --wait-timeout 180
  app_local_status="$(migration_local_caddy_status "${APP_DOMAIN}" "/")"
  hook_local_status="$(migration_local_caddy_status "${HOOK_DOMAIN}" "/")"
  [[ "${app_local_status}" == "200" && "${hook_local_status}" == "404" ]] \
    || die "Новая VPS не прошла локальную проверку Caddy: app=${app_local_status:-n/a}, hook=${hook_local_status:-n/a}."
  apply_telegram_runtime_mode
  finalize_runtime_change "Перенесенный проект активирован."
  mv -f "${STATE_DIR}/migration.pending" "${STATE_DIR}/migration.completed"
  secure_private_file "${STATE_DIR}/migration.completed"
  activation_completed="true"
  trap - EXIT
  recover_completed_migration_restart
  status_stack
}

discard_pending_migration() {
  ensure_root
  require_state_file

  local pending_file="${STATE_DIR}/migration.pending"
  local caddy_path
  local image_tag
  local image_key
  local image_tags=()
  [[ -f "${pending_file}" ]] || die "Незавершенный импорт не найден."

  log_warn "Будут удалены импортированный PROJECT_ROOT, его контейнеры, volumes и перенесенные Caddy snippets."
  prompt_typed_confirmation "DISCARD_IMPORT" "Подтверждение очистки тестового импорта." \
    || die "Очистка отменена."

  migration_remove_recorded_caddy "${pending_file}"

  for image_key in bot_image_tag postgres_image_tag redis_image_tag; do
    image_tag="$(migration_manifest_value "${pending_file}" "${image_key}")"
    [[ -n "${image_tag}" ]] && image_tags+=("${image_tag}")
  done

  if command_exists caddy && [[ -f /etc/caddy/Caddyfile ]]; then
    caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  fi
  local removed_project_root="${PROJECT_ROOT}"
  migration_remove_project_stack "${removed_project_root}"
  for image_tag in "${image_tags[@]}"; do
    docker image rm "${image_tag}" >/dev/null 2>&1 || true
  done
  clear_last_project_root
  unset PROJECT_ROOT STATE_DIR STATE_FILE
  log_info "Тестовый импорт удален. Можно импортировать финальный пакет."
}
