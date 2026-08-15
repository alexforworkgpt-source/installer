#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/firewall.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/deploy.sh"
# shellcheck source=lib/doctor.sh
source "${SCRIPT_DIR}/doctor.sh"

action="${1:-}"
requested_project_root="${2:-}"

[[ -n "${action}" && -n "${requested_project_root}" ]] \
  || die "Recovery runtime adapter требует action и PROJECT_ROOT."
is_safe_project_root "${requested_project_root}" \
  || die "Recovery получил небезопасный PROJECT_ROOT."

if [[ "${action}" == "safe-stop" ]]; then
  command_exists docker && docker info >/dev/null 2>&1 \
    || die "Docker daemon недоступен; безопасная остановка Bot не подтверждена."
  if docker container inspect botstack_bot >/dev/null 2>&1; then
    docker stop botstack_bot >/dev/null 2>&1 || true
    [[ "$(docker container inspect botstack_bot --format '{{.State.Running}}' 2>/dev/null)" == "false" ]] \
      || die "Не удалось доказать безопасную остановку Bot после Recovery failure."
  fi
  systemctl stop caddy >/dev/null 2>&1 || true
  [[ "$(systemctl show caddy --property=ActiveState --value 2>/dev/null)" =~ ^(inactive|failed)$ ]] \
    || die "Не удалось доказать безопасную остановку Caddy после Recovery failure."
  exit 0
fi

PROJECT_ROOT="${requested_project_root}"
STATE_FILE="${PROJECT_ROOT}/state/install.state"
load_state
[[ "${PROJECT_ROOT}" == "${requested_project_root}" ]] \
  || die "PROJECT_ROOT в восстановленном state не совпадает с Recovery target."

# Paths from a restored artifact are never trusted by the root runtime adapter.
PROJECT_ROOT="${requested_project_root}"
reset_project_root_paths
unset CADDY_SNIPPET_DIR CADDY_SNIPPET_FILE
set_runtime_paths
CADDY_SNIPPET_DIR="/etc/caddy/conf.d"
CADDY_SNIPPET_FILE="${CADDY_SNIPPET_DIR}/bot-stack.caddy"
STATE_FILE="${STATE_DIR}/install.state"

recovery_bot_state() {
  local running
  if ! command_exists docker || ! docker info >/dev/null 2>&1; then
    printf '%s' "unknown"
    return 0
  fi
  if ! docker container inspect botstack_bot >/dev/null 2>&1; then
    printf '%s' "stopped"
    return 0
  fi
  running="$(docker container inspect botstack_bot --format '{{.State.Running}}' 2>/dev/null)" \
    || { printf '%s' "unknown"; return 0; }
  if [[ "${running}" == "true" ]]; then
    printf '%s' "running"
  elif [[ "${running}" == "false" ]]; then
    printf '%s' "stopped"
  else
    printf '%s' "unknown"
  fi
}

recovery_caddy_state() {
  local state
  state="$(systemctl show caddy --property=ActiveState --value 2>/dev/null)" \
    || { printf '%s' "unknown"; return 0; }
  case "${state}" in
    inactive|failed) printf '%s' "stopped" ;;
    active) printf '%s' "running" ;;
    *) printf '%s' "unknown" ;;
  esac
}

recovery_quiesce_runtime() {
  compose_cmd stop bot >/dev/null 2>&1 || docker stop botstack_bot >/dev/null
  systemctl stop caddy
  [[ "$(recovery_bot_state)" == "stopped" ]] \
    || die "Остановка Bot после quiesce не подтверждена."
  [[ "$(recovery_caddy_state)" == "stopped" ]] \
    || die "Остановка Caddy после quiesce не подтверждена."
}

recovery_activate_runtime() {
  ensure_runtime_permissions
  compose_cmd config -q
  compose_cmd up -d --build --force-recreate --wait --wait-timeout 180
  install_caddy_candidate
  systemctl start caddy
  apply_telegram_runtime_mode
}

recovery_verify_runtime() {
  local running_services
  local required_service
  running_services="$(compose_cmd ps --status running --services)"
  for required_service in postgres redis bot; do
    grep -Fxq "${required_service}" <<<"${running_services}" \
      || die "Recovery не подтвердил Docker service: ${required_service}."
  done
  compose_cmd exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null \
    || die "Recovery не подтвердил готовность PostgreSQL."
  [[ "$(compose_cmd exec -T redis redis-cli ping 2>/dev/null | tr -d '\r')" == "PONG" ]] \
    || die "Recovery не подтвердил готовность Redis."
  systemctl is-active --quiet caddy \
    || die "Recovery не подтвердил активный Caddy."
  curl_with_timeouts -fsS -o /dev/null "https://${APP_DOMAIN}/" \
    || die "Recovery не подтвердил публичный TLS Cabinet."
  curl_with_timeouts -fsS -o /dev/null "https://${HOOK_DOMAIN}/cabinet/branding" \
    || die "Recovery не подтвердил публичный TLS webhook host."
  wait_for_runtime_ready 60 3 \
    || die "Recovery runtime не вышел в готовое состояние."
  verify_runtime_health \
    || die "Recovery не прошёл итоговую Docker/Caddy/Telegram проверку."
}

case "${action}" in
  quiesce) recovery_quiesce_runtime ;;
  activate) recovery_activate_runtime ;;
  verify) recovery_verify_runtime ;;
  *) die "Неизвестный Recovery runtime action: ${action}" ;;
esac
