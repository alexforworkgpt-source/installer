#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
SUCCESS_MARKER="${TEMP_ROOT}/success-log"
CALL_LOG="${TEMP_ROOT}/call-log"
FAIL_STAGE=""

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/lib/deploy.sh"

ensure_root() { :; }
require_state_file() { :; }
render_caddy_file() {
  printf '%s\n' render >> "${CALL_LOG}"
  [[ "${FAIL_STAGE}" != render ]]
}
install_caddy_candidate() {
  printf '%s\n' install >> "${CALL_LOG}"
  [[ "${FAIL_STAGE}" != install ]]
}
reload_caddy() {
  printf '%s\n' reload >> "${CALL_LOG}"
  [[ "${FAIL_STAGE}" != reload ]]
}
log_info() { : > "${SUCCESS_MARKER}"; }

for FAIL_STAGE in render install reload; do
  : > "${CALL_LOG}"
  rm -f "${SUCCESS_MARKER}"
  if regenerate_caddy_config; then
    printf 'Caddy regeneration ignored %s failure.\n' "${FAIL_STAGE}" >&2
    exit 1
  fi

  case "${FAIL_STAGE}" in
    render) expected_calls=render ;;
    install) expected_calls=render,install ;;
    reload) expected_calls=render,install,reload ;;
  esac
  [[ "$(paste -sd, "${CALL_LOG}")" == "${expected_calls}" ]]
  [[ ! -e "${SUCCESS_MARKER}" ]]
done

printf '%s\n' "Caddy regeneration failure propagation test passed."
