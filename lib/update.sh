#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=lib/release_bundle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_bundle.sh"

list_remote_tags() {
  local repo_url="$1"
  git ls-remote --tags --refs "${repo_url}" 2>/dev/null | awk -F/ '{print $3}' | sort -Vr
}

list_local_tags() {
  local repo_dir="$1"
  [[ -d "${repo_dir}/.git" ]] || return 0
  git -C "${repo_dir}" tag --sort=-v:refname
}

resolve_component_repo_dir() {
  local component="$1"

  case "${component}" in
    bot) printf '%s' "${BOT_REPO_DIR}" ;;
    cabinet) printf '%s' "${CABINET_REPO_DIR}" ;;
    *) die "Неподдерживаемый компонент: ${component}" ;;
  esac
}

list_component_tags() {
  local component="$1"
  local repo_url="$2"
  local repo_dir="$3"
  local tags=""

  tags="$(list_remote_tags "${repo_url}" || true)"
  if [[ -n "${tags}" ]]; then
    printf '%s\n' "${tags}"
    return 0
  fi

  clone_or_update_repo "${repo_url}" "${repo_dir}" "main" >/dev/null 2>&1 || true
  list_local_tags "${repo_dir}" || true
}

resolve_component_repo_url() {
  local component="$1"

  case "${component}" in
    bot) printf '%s' "${BOT_REPO_URL}" ;;
    cabinet) printf '%s' "${CABINET_REPO_URL}" ;;
    *) die "Неподдерживаемый компонент: ${component}" ;;
  esac
}

resolve_component_latest_ref() {
  local component="$1"
  local repo_url
  repo_url="$(resolve_component_repo_url "${component}")"

  latest_remote_tag "${repo_url}"
}

choose_ref_interactive() {
  local component="$1"
  local repo_url="$2"
  local repo_dir="$3"
  local tags=()
  local latest_tag=""
  local choice=""
  local selected_index

  mapfile -t tags < <(list_component_tags "${component}" "${repo_url}" "${repo_dir}" | head -n 30)
  if ((${#tags[@]} > 0)); then
    latest_tag="${tags[0]}"
  else
    latest_tag="$(latest_remote_tag "${repo_url}" || true)"
  fi

  while true; do
    {
      clear
      print_menu_header "Выбор версии: ${component}"
      print_menu_section "Источник версии"
      print_menu_item "1" "Последний релиз" "${latest_tag:-теги не найдены}"
      print_menu_item "2" "main" "Использовать основную ветку репозитория."
      print_menu_item "3" "Выбрать тег из списка" "Показать доступные теги и выбрать вручную."
      echo
    } >&2

    read_menu_choice "Выберите пункт [1-3]: " choice
    echo >&2

    case "${choice}" in
      1)
        [[ -n "${latest_tag}" ]] || die "Для ${component} не найдено тегов."
        printf '%s' "${latest_tag}"
        return 0
        ;;
      2)
        printf '%s' "main"
        return 0
        ;;
      3)
        ((${#tags[@]} > 0)) || die "Для ${component} не найдено тегов."
        {
          clear
          print_menu_header "Теги: ${component}"
          print_menu_section "Доступные теги"
          for i in "${!tags[@]}"; do
            print_menu_item "$((i + 1))" "${tags[$i]}"
          done
          echo
        } >&2
        read_menu_choice "Выберите номер тега [1-${#tags[@]}]: " selected_index
        [[ "${selected_index}" =~ ^[0-9]+$ ]] || die "Некорректный выбор тега."
        ((selected_index >= 1 && selected_index <= ${#tags[@]})) || die "Номер тега вне диапазона."
        printf '%s' "${tags[$((selected_index - 1))]}"
        return 0
        ;;
      *)
        log_warn "Неизвестный пункт: ${choice}"
        pause >&2
        ;;
    esac
  done
}

checkout_repo_ref() {
  local repo_dir="$1"
  local repo_url="$2"
  local ref="$3"

  clone_or_update_repo "${repo_url}" "${repo_dir}"
  if [[ "${ref}" == "main" ]]; then
    git -C "${repo_dir}" checkout main
    git -C "${repo_dir}" pull --ff-only origin main
  else
    git -C "${repo_dir}" fetch --tags origin
    git -C "${repo_dir}" checkout "${ref}"
  fi
}

restore_bot_checkout() {
  local ref="$1"
  [[ -n "${ref}" ]] || return 0
  log_warn "Восстановление репозитория бота до ${ref}"
  checkout_repo_ref "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "${ref}" || true
}

restore_bot_checkout_and_restart() {
  local ref="$1"
  [[ -n "${ref}" ]] || return 0

  restore_bot_checkout "${ref}"
  compose_cmd config -q >/dev/null 2>&1 || return 0
  compose_cmd up -d --build --wait --wait-timeout 180 postgres redis bot >/dev/null 2>&1 || true
}

restore_cabinet_checkout_and_assets() {
  local ref="$1"
  [[ -n "${ref}" ]] || return 0

  log_warn "Восстановление репозитория cabinet до ${ref}"
  checkout_repo_ref "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "${ref}" || true
  build_cabinet_assets || true
  regenerate_caddy_config || true
}

repo_head_revision() {
  local repo_dir="$1"
  local fallback_ref="${2:-}"

  if [[ -d "${repo_dir}/.git" ]]; then
    git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || printf '%s' "${fallback_ref}"
  else
    printf '%s' "${fallback_ref}"
  fi
}

pin_bot_ref() {
  local ref="$1"
  local previous_ref="${BOT_VERSION_REF}"

  create_update_snapshot "update-bot-${ref}"
  checkout_repo_ref "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "${ref}"
  if ! compose_cmd config -q || ! compose_cmd up -d --build --wait --wait-timeout 180 postgres redis bot; then
    restore_bot_checkout_and_restart "${previous_ref}"
    die "Обновление бота завершилось ошибкой. Репозиторий возвращен на ${previous_ref}."
  fi
  if ! wait_for_runtime_ready 60 3; then
    restore_bot_checkout_and_restart "${previous_ref}"
    die "Обновление бота не дождалось готовности сервисов. Репозиторий возвращен на ${previous_ref}."
  fi
  if ! verify_runtime_health; then
    restore_bot_checkout_and_restart "${previous_ref}"
    die "Обновление бота завершилось ошибкой на пост-проверке. Репозиторий возвращен на ${previous_ref}."
  fi
  LAST_BOT_VERSION_REF="${previous_ref}"
  BOT_VERSION_REF="${ref}"
  save_state
  mark_runtime_apply_state
}

pin_cabinet_ref() {
  local ref="$1"
  local previous_ref="${CABINET_VERSION_REF}"

  create_update_snapshot "update-cabinet-${ref}"
  checkout_repo_ref "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "${ref}"
  if ! build_cabinet_assets; then
    restore_cabinet_checkout_and_assets "${previous_ref}"
    die "Обновление cabinet завершилось ошибкой при сборке. Предыдущая версия восстановлена."
  fi
  if ! regenerate_caddy_config; then
    restore_cabinet_checkout_and_assets "${previous_ref}"
    die "Обновление cabinet завершилось ошибкой при перезагрузке Caddy. Предыдущая версия восстановлена."
  fi
  if ! wait_for_runtime_ready 60 3; then
    restore_cabinet_checkout_and_assets "${previous_ref}"
    die "Обновление cabinet не дождалось готовности сервисов. Предыдущая версия восстановлена."
  fi
  if ! verify_runtime_health; then
    restore_cabinet_checkout_and_assets "${previous_ref}"
    die "Обновление cabinet завершилось ошибкой на пост-проверке. Предыдущая версия восстановлена."
  fi
  LAST_CABINET_VERSION_REF="${previous_ref}"
  CABINET_VERSION_REF="${ref}"
  save_state
  mark_runtime_apply_state
}

choose_component_ref_only() {
  ensure_root
  require_state_file

  local component="$1"
  local repo_url
  local repo_dir

  repo_url="$(resolve_component_repo_url "${component}")"
  repo_dir="$(resolve_component_repo_dir "${component}")"
  choose_ref_interactive "${component}" "${repo_url}" "${repo_dir}"
}

rollback_grouped_update() {
  local previous_bot_ref="$1"
  local previous_cabinet_ref="$2"
  local previous_last_bot_ref="$3"
  local previous_last_cabinet_ref="$4"
  local previous_bot_checkout_ref="$5"
  local previous_cabinet_checkout_ref="$6"
  local rollback_failed="false"

  log_warn "Откат группового обновления: bot=${previous_bot_ref}, cabinet=${previous_cabinet_ref}"
  if [[ -n "${previous_bot_checkout_ref}" ]]; then
    log_warn "Восстановление репозитория бота до ${previous_bot_checkout_ref}"
    checkout_repo_ref "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "${previous_bot_checkout_ref}" || rollback_failed="true"
  fi
  if [[ -n "${previous_cabinet_checkout_ref}" ]]; then
    log_warn "Восстановление репозитория cabinet до ${previous_cabinet_checkout_ref}"
    checkout_repo_ref "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "${previous_cabinet_checkout_ref}" || rollback_failed="true"
  fi
  build_cabinet_assets || rollback_failed="true"
  if ! compose_cmd config -q >/dev/null 2>&1 || ! compose_cmd up -d --build --wait --wait-timeout 180 postgres redis bot >/dev/null 2>&1; then
    rollback_failed="true"
  fi
  regenerate_caddy_config || rollback_failed="true"
  apply_telegram_runtime_mode || rollback_failed="true"

  BOT_VERSION_REF="${previous_bot_ref}"
  CABINET_VERSION_REF="${previous_cabinet_ref}"
  LAST_BOT_VERSION_REF="${previous_last_bot_ref}"
  LAST_CABINET_VERSION_REF="${previous_last_cabinet_ref}"
  save_state

  if [[ "${rollback_failed}" == "true" ]]; then
    return 1
  fi
  wait_for_runtime_ready 60 3 && verify_runtime_health && mark_runtime_apply_state
}

apply_grouped_update_refs() {
  ensure_root
  require_state_file

  local target_bot_ref="$1"
  local target_cabinet_ref="$2"
  local previous_bot_ref="${BOT_VERSION_REF}"
  local previous_cabinet_ref="${CABINET_VERSION_REF}"
  local previous_last_bot_ref="${LAST_BOT_VERSION_REF:-}"
  local previous_last_cabinet_ref="${LAST_CABINET_VERSION_REF:-}"
  local previous_bot_checkout_ref
  local previous_cabinet_checkout_ref
  local failure_reason=""

  [[ -n "${target_bot_ref}" ]] || die "Целевая версия bot не задана."
  [[ -n "${target_cabinet_ref}" ]] || die "Целевая версия cabinet не задана."

  previous_bot_checkout_ref="$(repo_head_revision "${BOT_REPO_DIR}" "${previous_bot_ref}")"
  previous_cabinet_checkout_ref="$(repo_head_revision "${CABINET_REPO_DIR}" "${previous_cabinet_ref}")"

  create_update_snapshot "update-both-${target_bot_ref}-${target_cabinet_ref}"
  log_info "Групповое обновление: bot ${previous_bot_ref} -> ${target_bot_ref}, cabinet ${previous_cabinet_ref} -> ${target_cabinet_ref}"

  if ! checkout_repo_ref "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "${target_bot_ref}"; then
    failure_reason="checkout bot ${target_bot_ref}"
  elif ! checkout_repo_ref "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "${target_cabinet_ref}"; then
    failure_reason="checkout cabinet ${target_cabinet_ref}"
  elif ! build_cabinet_assets; then
    failure_reason="build cabinet assets"
  elif ! compose_cmd config -q; then
    failure_reason="docker compose config"
  elif ! compose_cmd up -d --build --wait --wait-timeout 180 postgres redis bot; then
    failure_reason="docker compose up"
  elif ! regenerate_caddy_config; then
    failure_reason="regenerate caddy config"
  elif ! apply_telegram_runtime_mode; then
    failure_reason="telegram runtime mode"
  elif ! wait_for_runtime_ready 60 3; then
    failure_reason="runtime readiness"
  elif ! verify_runtime_health; then
    failure_reason="runtime health"
  fi

  if [[ -n "${failure_reason}" ]]; then
    if rollback_grouped_update "${previous_bot_ref}" "${previous_cabinet_ref}" "${previous_last_bot_ref}" "${previous_last_cabinet_ref}" "${previous_bot_checkout_ref}" "${previous_cabinet_checkout_ref}"; then
      die "Групповое обновление завершилось ошибкой (${failure_reason}). Bot и cabinet возвращены на предыдущие версии."
    fi
    die "Групповое обновление завершилось ошибкой (${failure_reason}). Попытка отката выполнена, но итоговая проверка отката не прошла."
  fi

  LAST_BOT_VERSION_REF="${previous_bot_ref}"
  LAST_CABINET_VERSION_REF="${previous_cabinet_ref}"
  BOT_VERSION_REF="${target_bot_ref}"
  CABINET_VERSION_REF="${target_cabinet_ref}"
  save_state
  mark_runtime_apply_state
  log_info "Групповое обновление завершено: bot=${target_bot_ref}, cabinet=${target_cabinet_ref}."
}

choose_component_version() {
  ensure_root
  require_state_file

  local component="$1"
  local repo_url
  local repo_dir
  local ref

  repo_url="$(resolve_component_repo_url "${component}")"
  repo_dir="$(resolve_component_repo_dir "${component}")"

  case "${component}" in
    bot)
      ref="$(choose_ref_interactive "bot" "${repo_url}" "${repo_dir}")"
      pin_bot_ref "${ref}"
      ;;
    cabinet)
      ref="$(choose_ref_interactive "cabinet" "${repo_url}" "${repo_dir}")"
      pin_cabinet_ref "${ref}"
      ;;
    *)
      die "Неподдерживаемый компонент: ${component}"
      ;;
  esac

  log_info "Для ${component} зафиксирована версия ${ref}."
}

update_component_interactive() {
  choose_component_version "$1"
}

update_component_to_ref() {
  ensure_root
  require_state_file

  local component="$1"
  local ref="$2"

  case "${component}" in
    bot)
      pin_bot_ref "${ref}"
      ;;
    cabinet)
      pin_cabinet_ref "${ref}"
      ;;
    *)
      die "Неподдерживаемый компонент: ${component}"
      ;;
  esac

  log_info "${component} обновлен до ${ref}."
}

update_component_to_latest() {
  ensure_root
  require_state_file

  local component="$1"
  local ref
  ref="$(resolve_component_latest_ref "${component}")"
  [[ -n "${ref}" ]] || die "Для ${component} не найдено релизных тегов."
  update_component_to_ref "${component}" "${ref}"
}

update_component_to_main() {
  update_component_to_ref "$1" "main"
}

confirm_multi_component_update() {
  log_info "Bot и cabinet будут обновлены как одна группа. При ошибке оба компонента будут откатаны."
  prompt_yes_no "Продолжить обновление обоих компонентов?" "n"
}

current_alembic_revision() {
  compose_cmd exec -T postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At \
    -c 'SELECT version_num FROM alembic_version ORDER BY version_num' 2>/dev/null \
    | paste -sd, -
}

create_verified_update_dump() {
  local release="$1"
  local safe_release
  local backup_dir
  local dump_path
  local temp_path
  local verification_database="installer_verify_${RANDOM}_$$"
  local verification_failed="false"
  safe_release="$(printf '%s' "${release}" | sed 's/[^A-Za-z0-9._-]/-/g')"
  backup_dir="$(backup_dir_root)/database"
  dump_path="${backup_dir}/before-release-${safe_release}-$(date '+%Y%m%d-%H%M%S').dump"
  temp_path="${dump_path}.tmp"
  mkdir -p "${backup_dir}"
  if ! (
    umask 077
    compose_cmd exec -T postgres \
      pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc > "${temp_path}"
  ); then
    rm -f "${temp_path}"
    return 1
  fi
  [[ -s "${temp_path}" ]] || {
    rm -f "${temp_path}"
    return 1
  }
  if ! compose_cmd exec -T postgres pg_restore --list < "${temp_path}" >/dev/null; then
    rm -f "${temp_path}"
    return 1
  fi
  compose_cmd exec -T postgres createdb \
    -U "${POSTGRES_USER}" \
    --owner "${POSTGRES_USER}" \
    "${verification_database}" || {
      rm -f "${temp_path}"
      return 1
    }
  compose_cmd exec -T postgres pg_restore \
    -U "${POSTGRES_USER}" \
    -d "${verification_database}" \
    --no-owner \
    --no-privileges \
    --exit-on-error < "${temp_path}" >/dev/null \
    || verification_failed="true"
  compose_cmd exec -T postgres psql \
    -U "${POSTGRES_USER}" \
    -d "${verification_database}" \
    -At -c 'SELECT version_num FROM alembic_version ORDER BY version_num' \
    | paste -sd, - | grep -q . \
    || verification_failed="true"
  compose_cmd exec -T postgres dropdb \
    -U "${POSTGRES_USER}" --if-exists --force "${verification_database}" \
    || verification_failed="true"
  if [[ "${verification_failed}" == true ]]; then
    rm -f "${temp_path}"
    return 1
  fi
  mv -f "${temp_path}" "${dump_path}" || return 1
  [[ -s "${dump_path}" ]] || return 1
  secure_private_file "${dump_path}" || return 1
  printf '%s' "${dump_path}"
}

restore_verified_update_dump() {
  local dump_path="$1"
  local expected_revision="$2"
  local restored_revision
  local backup_dir

  backup_dir="$(backup_dir_root)/database"
  [[ -f "${dump_path}" && ! -L "${dump_path}" && -s "${dump_path}" ]] || return 1
  path_is_under "${backup_dir}" "${dump_path}" || return 1
  compose_cmd exec -T postgres pg_restore --list < "${dump_path}" >/dev/null \
    || return 1
  compose_cmd exec -T postgres dropdb \
    -U "${POSTGRES_USER}" \
    --if-exists \
    --force \
    "${POSTGRES_DB}" || return 1
  compose_cmd exec -T postgres createdb \
    -U "${POSTGRES_USER}" \
    --owner "${POSTGRES_USER}" \
    "${POSTGRES_DB}" || return 1
  compose_cmd exec -T postgres pg_restore \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    --no-owner \
    --no-privileges \
    --exit-on-error < "${dump_path}" || return 1

  restored_revision="$(compose_cmd exec -T postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At \
    -c 'SELECT version_num FROM alembic_version ORDER BY version_num' \
    | paste -sd, -)"
  [[ -n "${restored_revision}" && "${restored_revision}" == "${expected_revision}" ]]
}

rollback_release_sources() {
  local previous_bot_sha="$1"
  local previous_cabinet_sha="$2"
  local rollback_failed="false"

  checkout_repo_ref "${BOT_REPO_DIR}" "${BOT_REPO_URL}" "${previous_bot_sha}" \
    || rollback_failed="true"
  verify_release_checkout "${BOT_REPO_DIR}" "${previous_bot_sha}" \
    || rollback_failed="true"
  checkout_repo_ref "${CABINET_REPO_DIR}" "${CABINET_REPO_URL}" "${previous_cabinet_sha}" \
    || rollback_failed="true"
  verify_release_checkout "${CABINET_REPO_DIR}" "${previous_cabinet_sha}" \
    || rollback_failed="true"

  [[ "${rollback_failed}" == "false" ]]
}

write_protected_update_context_value() {
  local context_dir="$1"
  local key="$2"
  local value="$3"
  local target="${context_dir}/${key}"
  local temporary="${target}.tmp"

  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  (
    umask 077
    printf '%s\n' "${value}" > "${temporary}"
  )
  mv -f "${temporary}" "${target}"
  secure_private_file "${target}"
}

update_from_release_bundle_once() {
  ensure_root
  require_state_file
  command_exists jq || die "Для Release Bundle требуется jq."

  local manifest_source
  manifest_source="$(prompt_optional_input \
    "Release Bundle manifest" \
    "HTTPS URL или путь к release.json" \
    "https://example.com/releases/2026.08.0/release.json" \
    "${RELEASE_MANIFEST_SOURCE:-}")"
  [[ -n "${manifest_source}" ]] || die "Release Bundle manifest не задан."

  local work_dir
  local manifest_file
  local bundle_json
  local release
  local bundle_identity
  local manifest_bot_repo
  local bot_sha
  local cabinet_sha
  local cabinet_artifact_url
  local cabinet_artifact_sha256
  local postgres_image
  local redis_image
  local migration_policy
  local archive_file
  local previous_bot_sha
  local previous_cabinet_sha
  local previous_postgres_image="${POSTGRES_IMAGE}"
  local previous_redis_image="${REDIS_IMAGE}"
  local previous_release="${CURRENT_RELEASE:-}"
  local previous_manifest_source="${RELEASE_MANIFEST_SOURCE:-}"
  local previous_bundle_identity="${CURRENT_RELEASE_BUNDLE_IDENTITY:-}"
  local previous_artifact_identity="${CURRENT_CABINET_ARTIFACT_SHA256:-}"
  local previous_last_bundle_identity="${LAST_RELEASE_BUNDLE_IDENTITY:-}"
  local previous_last_artifact_identity="${LAST_CABINET_ARTIFACT_SHA256:-}"
  local previous_last_bot_ref="${LAST_BOT_VERSION_REF:-}"
  local previous_last_cabinet_ref="${LAST_CABINET_VERSION_REF:-}"
  local previous_cabinet_dir
  local protected_result_json=""
  local protected_result_status=0
  local protected_outcome
  local protected_failed_stage
  local protected_error
  local protected_rollback_verified
  local protected_recovery_plan
  local terminal_marker=""
  local protected_update_adapter="${PROTECTED_UPDATE_ADAPTER:-${INSTALLER_DIR}/lib/protected_update_adapter.sh}"

  work_dir="$(mktemp -d "${STATE_DIR}/.protected-update.XXXXXX")"
  cleanup_release_bundle_workdir() {
    local exit_code=$?
    local marker_context=""
    trap - RETURN
    if [[ -f "${STATE_DIR}/runtime-change.in-progress" ]]; then
      marker_context="$(awk -F= '$1 == "context_file" {print substr($0, index($0, "=") + 1); exit}' \
        "${STATE_DIR}/runtime-change.in-progress")"
    fi
    if [[ "${marker_context}" != "${work_dir}" ]]; then
      safe_rm_rf_under "${STATE_DIR}" "${work_dir}" >/dev/null 2>&1 || true
    fi
    return "${exit_code}"
  }
  trap cleanup_release_bundle_workdir RETURN

  manifest_file="${work_dir}/release.json"
  copy_or_download_release_file "${manifest_source}" "${manifest_file}" \
    || die "Не удалось получить Release Bundle manifest: ${manifest_source}"
  bundle_json="$(run_python "${INSTALLER_DIR}/lib/release_bundle.py" validate "${manifest_file}" 1)" \
    || die "Release Bundle manifest не прошёл проверку."

  release="$(jq -r '.release' <<<"${bundle_json}")"
  bundle_identity="$(jq -r '.identity' <<<"${bundle_json}")"
  manifest_bot_repo="$(jq -r '.bot.repository' <<<"${bundle_json}")"
  bot_sha="$(jq -r '.bot.sha' <<<"${bundle_json}")"
  cabinet_sha="$(jq -r '.cabinet.source_sha' <<<"${bundle_json}")"
  cabinet_artifact_url="$(jq -r '.cabinet.artifact_url' <<<"${bundle_json}")"
  cabinet_artifact_sha256="$(jq -r '.cabinet.artifact_sha256' <<<"${bundle_json}")"
  postgres_image="$(jq -r '.images.postgres' <<<"${bundle_json}")"
  redis_image="$(jq -r '.images.redis' <<<"${bundle_json}")"
  migration_policy="$(jq -r '.migration_policy' <<<"${bundle_json}")"
  [[ "${manifest_bot_repo}" == "${BOT_REPO_URL}" ]] \
    || die "Bot repository в manifest не совпадает с настроенным repository."
  [[ "${migration_policy}" == "rollback-compatible" || "${migration_policy}" == "forward-only" ]] \
    || die "Release Bundle содержит неизвестную migration policy: ${migration_policy}."

  bot_sha="$(resolve_release_source_sha "${manifest_bot_repo}" "${bot_sha}")" \
    || die "Bot SHA из Release Bundle не найден в repository. Runtime не изменён."
  cabinet_sha="$(resolve_release_source_sha "${CABINET_REPO_URL}" "${cabinet_sha}")" \
    || die "Cabinet SHA из Release Bundle не найден в repository. Runtime не изменён."

  archive_file="${work_dir}/cabinet-dist.tar.gz"
  copy_or_download_release_file "${cabinet_artifact_url}" "${archive_file}" \
    || die "Не удалось скачать Cabinet artifact."
  verify_release_cabinet_artifact "${archive_file}" "${cabinet_artifact_sha256}" \
    || die "Cabinet artifact не прошёл checksum/structure проверку. Runtime не изменён."

  previous_bot_sha="$(repo_head_revision "${BOT_REPO_DIR}" "${BOT_VERSION_REF}")"
  previous_cabinet_sha="$(repo_head_revision "${CABINET_REPO_DIR}" "${CABINET_VERSION_REF}")"
  [[ "${previous_bot_sha}" =~ ^[0-9a-f]{40}$ ]] \
    || die "Точный текущий Bot HEAD не определён. Runtime не изменён."
  [[ "${previous_cabinet_sha}" =~ ^[0-9a-f]{40}$ ]] \
    || die "Точный текущий Cabinet HEAD не определён. Runtime не изменён."
  previous_cabinet_dir="${work_dir}/previous-cabinet"
  if [[ -d "${CABINET_DIST_DIR}" ]]; then
    cp -a "${CABINET_DIST_DIR}" "${previous_cabinet_dir}"
  fi

  echo "Release Bundle: ${release}"
  echo "Bot SHA:        ${bot_sha}"
  echo "Cabinet SHA:    ${cabinet_sha}"
  echo "PostgreSQL:     ${postgres_image}"
  echo "Redis:          ${redis_image}"
  prompt_yes_no "Применить этот Release Bundle?" "n" || {
    log_info "Обновление Release Bundle отменено."
    return 0
  }

  write_protected_update_context_value "${work_dir}" target-release "${release}"
  write_protected_update_context_value "${work_dir}" target-bundle-identity "${bundle_identity}"
  write_protected_update_context_value "${work_dir}" target-bot-sha "${bot_sha}"
  write_protected_update_context_value "${work_dir}" target-cabinet-sha "${cabinet_sha}"
  write_protected_update_context_value "${work_dir}" target-artifact-file "${archive_file}"
  write_protected_update_context_value "${work_dir}" target-artifact-sha256 "${cabinet_artifact_sha256}"
  write_protected_update_context_value "${work_dir}" target-postgres-image "${postgres_image}"
  write_protected_update_context_value "${work_dir}" target-redis-image "${redis_image}"
  write_protected_update_context_value "${work_dir}" target-manifest-source "${manifest_source}"
  write_protected_update_context_value "${work_dir}" migration-policy "${migration_policy}"
  write_protected_update_context_value "${work_dir}" previous-bot-sha "${previous_bot_sha}"
  write_protected_update_context_value "${work_dir}" previous-cabinet-sha "${previous_cabinet_sha}"
  write_protected_update_context_value "${work_dir}" previous-postgres-image "${previous_postgres_image}"
  write_protected_update_context_value "${work_dir}" previous-redis-image "${previous_redis_image}"
  write_protected_update_context_value "${work_dir}" previous-release "${previous_release}"
  write_protected_update_context_value \
    "${work_dir}" previous-release-key "${previous_release:-${previous_bot_sha}}"
  write_protected_update_context_value "${work_dir}" previous-manifest-source "${previous_manifest_source}"
  write_protected_update_context_value "${work_dir}" previous-bundle-identity "${previous_bundle_identity}"
  write_protected_update_context_value "${work_dir}" previous-artifact-identity "${previous_artifact_identity}"
  write_protected_update_context_value \
    "${work_dir}" previous-last-bundle-identity "${previous_last_bundle_identity}"
  write_protected_update_context_value \
    "${work_dir}" previous-last-artifact-identity "${previous_last_artifact_identity}"
  write_protected_update_context_value "${work_dir}" previous-last-bot-ref "${previous_last_bot_ref}"
  write_protected_update_context_value \
    "${work_dir}" previous-last-cabinet-ref "${previous_last_cabinet_ref}"

  if protected_result_json="$(run_python \
    "${INSTALLER_DIR}/lib/protected_update.py" run-command \
    "${migration_policy}" \
    -- \
    "${BASH:-bash}" "${protected_update_adapter}" "${STATE_DIR}" "${work_dir}")"; then
    protected_result_status=0
  else
    protected_result_status=$?
  fi
  [[ -n "${protected_result_json}" ]] \
    || die "Protected Update не вернул structured result. Проверьте installer log."
  if ((protected_result_status >= 128)); then
    log_warn "Protected Update был прерван сигналом; rollback result сохранён."
  fi

  protected_outcome="$(jq -r '.outcome' <<<"${protected_result_json}")"
  protected_failed_stage="$(jq -r '.failed_stage' <<<"${protected_result_json}")"
  protected_error="$(jq -r '.error' <<<"${protected_result_json}")"
  protected_rollback_verified="$(jq -r '.rollback_verified' <<<"${protected_result_json}")"
  protected_recovery_plan="$(jq -r '.recovery_plan' <<<"${protected_result_json}")"
  [[ "${protected_failed_stage}" != null ]] || protected_failed_stage="-"
  [[ "${protected_error}" != null ]] || protected_error="-"
  [[ "${protected_recovery_plan}" != null ]] || protected_recovery_plan="-"
  (
    umask 077
    printf '%s\n' "${protected_result_json}" > "${STATE_DIR}/last-protected-update.json"
  )
  secure_private_file "${STATE_DIR}/last-protected-update.json"
  sync -f "${STATE_DIR}/last-protected-update.json"
  record_runtime_change_result \
    "protected update" \
    "${protected_outcome}" \
    "${protected_failed_stage}" \
    "${protected_error}" \
    "${protected_rollback_verified}" \
    "$([[ "${protected_recovery_plan}" == "-" ]] \
      && printf '%s' 'Исправьте указанную ошибку и повторите update.' \
      || printf '%s' "${protected_recovery_plan}")" \
    "$(installer_log_file)"
  sync -f "${STATE_DIR}/last-runtime-change.json"
  sync -f "${STATE_DIR}"

  if [[ -f "${STATE_DIR}/runtime-change.in-progress" ]]; then
    terminal_marker="$(awk -F= '$1 == "recovery_point" {print substr($0, index($0, "=") + 1); exit}' \
      "${STATE_DIR}/runtime-change.in-progress")"
  fi
  case "${terminal_marker}" in
    committed)
      "${BASH:-bash}" "${protected_update_adapter}" \
        "${STATE_DIR}" "${work_dir}" finalize-commit || return 1
      ;;
    rolled-back|protection-aborted)
      "${BASH:-bash}" "${protected_update_adapter}" \
        "${STATE_DIR}" "${work_dir}" finalize-terminal "${terminal_marker}" || return 1
      ;;
  esac

  case "${protected_outcome}" in
    committed)
      log_info "Release Bundle ${release} успешно применён и проверен."
      status_stack || true
      return 0
      ;;
    rolled_back)
      log_error "Release Bundle ${release} не применён; предыдущий runtime и PostgreSQL восстановлены и проверены."
      return 1
      ;;
    safely_stopped)
      log_error "Protected Update safely stopped: ${protected_recovery_plan}"
      return 1
      ;;
    *)
      log_error "Protected Update вернул неизвестный outcome: ${protected_outcome}."
      return 1
      ;;
  esac
}

update_from_release_bundle() {
  local result_file="${STATE_DIR:-}/last-runtime-change.json"

  if [[ -n "${STATE_DIR:-}" ]]; then
    rm -f "${result_file}"
  fi
  if (update_from_release_bundle_once); then
    return 0
  fi

  if [[ -z "${STATE_DIR:-}" || ! -f "${result_file}" ]]; then
    record_runtime_change_result \
      "protected update" "safely_stopped" "protect" \
      "Release Bundle update завершился до commit." "false" \
      "Исправьте указанную ошибку и повторите update; runtime не запускайте, если его состояние неизвестно." \
      "$(installer_log_file)"
  fi
  return 1
}

update_everything() {
  ensure_root
  require_state_file
  local bot_ref
  local cabinet_ref

  confirm_multi_component_update || {
    log_info "Обновление обоих компонентов отменено."
    return 0
  }
  bot_ref="$(choose_component_ref_only "bot")"
  cabinet_ref="$(choose_component_ref_only "cabinet")"
  apply_grouped_update_refs "${bot_ref}" "${cabinet_ref}"
  status_stack
}

update_everything_to_latest() {
  ensure_root
  require_state_file
  local bot_ref
  local cabinet_ref

  confirm_multi_component_update || {
    log_info "Обновление обоих компонентов отменено."
    return 0
  }
  bot_ref="$(resolve_component_latest_ref "bot")"
  cabinet_ref="$(resolve_component_latest_ref "cabinet")"
  [[ -n "${bot_ref}" ]] || die "Для bot не найдено релизных тегов."
  [[ -n "${cabinet_ref}" ]] || die "Для cabinet не найдено релизных тегов."
  apply_grouped_update_refs "${bot_ref}" "${cabinet_ref}"
  status_stack
}

update_everything_to_main() {
  ensure_root
  require_state_file

  confirm_multi_component_update || {
    log_info "Обновление обоих компонентов отменено."
    return 0
  }
  apply_grouped_update_refs "main" "main"
  status_stack
}
