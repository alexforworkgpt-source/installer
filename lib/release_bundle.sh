#!/usr/bin/env bash

set -Eeuo pipefail

copy_or_download_release_file() {
  local source="$1"
  local destination="$2"
  case "${source}" in
    https://*)
      curl -fL --connect-timeout 10 --max-time 300 "${source}" -o "${destination}"
      ;;
    /*)
      [[ -f "${source}" ]] || return 1
      cp "${source}" "${destination}"
      ;;
    *)
      [[ -f "${source}" ]] || return 1
      cp "${source}" "${destination}"
      ;;
  esac
}

resolve_release_source_sha() {
  local repository="$1"
  local requested_ref="$2"

  run_python "${INSTALLER_DIR}/lib/release_bundle.py" resolve-ref \
    "${repository}" "${requested_ref}"
}

verify_release_checkout() {
  local repository_dir="$1"
  local expected_sha="$2"

  run_python "${INSTALLER_DIR}/lib/release_bundle.py" verify-head \
    "${repository_dir}" "${expected_sha}"
}

verify_release_cabinet_artifact() {
  local archive_file="$1"
  local expected_sha256="$2"

  run_python "${INSTALLER_DIR}/lib/release_bundle.py" verify-cabinet \
    "${archive_file}" "${expected_sha256}"
}

prepare_release_bundle() {
  local manifest_source="$1"
  local work_dir="$2"
  local manifest_file="${work_dir}/release.json"
  local bundle_json
  local manifest_bot_repo
  local migration_policy

  command_exists jq || {
    log_error "Для Release Bundle требуется jq."
    return 1
  }
  copy_or_download_release_file "${manifest_source}" "${manifest_file}" || {
    log_error "Не удалось получить Release Bundle manifest: ${manifest_source}"
    return 1
  }
  bundle_json="$(run_python "${INSTALLER_DIR}/lib/release_bundle.py" validate "${manifest_file}" 1)" || {
    log_error "Release Bundle manifest не прошёл проверку."
    return 1
  }

  PREPARED_RELEASE="$(jq -r '.release' <<<"${bundle_json}")"
  PREPARED_BUNDLE_IDENTITY="$(jq -r '.identity' <<<"${bundle_json}")"
  manifest_bot_repo="$(jq -r '.bot.repository' <<<"${bundle_json}")"
  PREPARED_BOT_SHA="$(jq -r '.bot.sha' <<<"${bundle_json}")"
  PREPARED_CABINET_SHA="$(jq -r '.cabinet.source_sha' <<<"${bundle_json}")"
  PREPARED_CABINET_ARTIFACT_URL="$(jq -r '.cabinet.artifact_url' <<<"${bundle_json}")"
  PREPARED_CABINET_ARTIFACT_SHA256="$(jq -r '.cabinet.artifact_sha256' <<<"${bundle_json}")"
  PREPARED_POSTGRES_IMAGE="$(jq -r '.images.postgres' <<<"${bundle_json}")"
  PREPARED_REDIS_IMAGE="$(jq -r '.images.redis' <<<"${bundle_json}")"
  migration_policy="$(jq -r '.migration_policy' <<<"${bundle_json}")"

  [[ "${manifest_bot_repo}" == "${BOT_REPO_URL}" ]] || {
    log_error "Bot repository в manifest не совпадает с настроенным repository."
    return 1
  }
  [[ "${migration_policy}" == "rollback-compatible" ]] || {
    log_error "Forward-only Release Bundle заблокирован до появления проверенного recovery flow."
    return 1
  }

  PREPARED_BOT_SHA="$(resolve_release_source_sha "${manifest_bot_repo}" "${PREPARED_BOT_SHA}")" || {
    log_error "Bot SHA из Release Bundle не найден в repository."
    return 1
  }
  PREPARED_CABINET_SHA="$(resolve_release_source_sha "${CABINET_REPO_URL}" "${PREPARED_CABINET_SHA}")" || {
    log_error "Cabinet SHA из Release Bundle не найден в repository."
    return 1
  }

  PREPARED_CABINET_ARTIFACT_FILE="${work_dir}/cabinet-dist.tar.gz"
  copy_or_download_release_file \
    "${PREPARED_CABINET_ARTIFACT_URL}" \
    "${PREPARED_CABINET_ARTIFACT_FILE}" || {
    log_error "Не удалось скачать Cabinet artifact."
    return 1
  }
  verify_release_cabinet_artifact \
    "${PREPARED_CABINET_ARTIFACT_FILE}" \
    "${PREPARED_CABINET_ARTIFACT_SHA256}" || {
    log_error "Cabinet artifact не прошёл checksum/structure проверку."
    return 1
  }

  PREPARED_MANIFEST_SOURCE="${manifest_source}"
  PREPARED_MANIFEST_FILE="${manifest_file}"
}
