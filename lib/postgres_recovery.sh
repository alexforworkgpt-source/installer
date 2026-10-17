#!/usr/bin/env bash

# Reconstruct storage only from the existing Compose and its running container.
# This path must work without install.state and must never start containers.
recover_postgres_runtime_identity() {
  local root="$1" project recorded_project marker configuration container mounts volume_key destination
  project="$(compose_project_name_for_root "${root}")"
  if [[ -f "${root}/state/install.state" ]]; then
    recorded_project="$(run_env_helper get "${root}/state/install.state" COMPOSE_PROJECT_NAME)" || return 1
    [[ -z "${recorded_project}" ]] || project="${recorded_project}"
  fi
  marker="${root}/.migration-resources-created"
  if [[ -f "${marker}" && ! -L "${marker}" ]]; then
    project="$(awk -F= '$1 == "compose_project" {print $2; exit}' "${marker}")"
  fi
  [[ "${project}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  local compose_args=(--project-name "${project}" --env-file "${root}/state/bot.env" -f "${root}/state/docker-compose.yml")
  if [[ -f "${root}/state/migration-image.override.yml" ]]; then
    compose_args+=(-f "${root}/state/migration-image.override.yml")
  fi
  configuration="$(docker compose "${compose_args[@]}" config --format json)" || return 1
  RECOVERED_POSTGRES_IMAGE="$(jq -er '.services.postgres.image' <<<"${configuration}")" || return 1
  RECOVERED_REDIS_IMAGE="$(jq -er '.services.redis.image' <<<"${configuration}")" || return 1
  RECOVERED_POSTGRES_MAJOR="$(postgres_image_major "${RECOVERED_POSTGRES_IMAGE}")" || return 1
  case "${RECOVERED_POSTGRES_MAJOR}" in
    15) destination=/var/lib/postgresql/data ;;
    18) destination=/var/lib/postgresql ;;
    *) return 1 ;;
  esac
  volume_key="$(jq -er --arg destination "${destination}" \
    '.services.postgres.volumes | map(select(.type == "volume" and .target == $destination)) | if length == 1 then .[0].source else error("ambiguous PostgreSQL mount") end' \
    <<<"${configuration}")" || return 1
  RECOVERED_POSTGRES_VOLUME="$(jq -er --arg key "${volume_key}" '.volumes[$key].name' <<<"${configuration}")" || return 1
  container="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" --filter label=com.docker.compose.service=postgres)" || return 1
  [[ -n "${container}" && "${container}" != *$'\n'* ]] || return 1
  [[ "$(docker inspect --format '{{.State.Running}}' "${container}")" == true ]] || return 1
  [[ "$(docker inspect --format '{{.Config.Image}}' "${container}")" == "${RECOVERED_POSTGRES_IMAGE}" ]] || return 1
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s=%s\n" .Destination .Name}}{{end}}' "${container}")" || return 1
  grep -Fxq "${destination}=${RECOVERED_POSTGRES_VOLUME}" <<<"${mounts}" || return 1
  RECOVERED_COMPOSE_PROJECT="${project}"
}
