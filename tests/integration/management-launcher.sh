#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"

source_clone="${TEMP_ROOT}/source-clone"
installer_home="${TEMP_ROOT}/installed"
launcher="${TEMP_ROOT}/bin/vpn"
mkdir -p "${source_clone}/lib" "${source_clone}/state" "${TEMP_ROOT}/bin"
cat > "${TEMP_ROOT}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "${TEMP_ROOT}/bin/sudo"
export PATH="${TEMP_ROOT}/bin:${PATH}"
printf '%s\n' '#!/usr/bin/env bash' 'printf installed-launcher-ok' > "${source_clone}/bot-menu.sh"
printf '%s\n' 'helper-content' > "${source_clone}/lib/helper.sh"
printf '%s\n' 'private-state' > "${source_clone}/state/private.txt"
printf '%s\n' 'must-not-copy' > "${source_clone}/server.env"

INSTALLER_DIR="${source_clone}"
installed_script="$(install_management_copy "${installer_home}")"
write_menu_launcher "${launcher}" "${installed_script}"

[[ -x "${launcher}" ]]
[[ "${installed_script}" == "${installer_home}/current/bot-menu.sh" ]]
[[ -f "${installer_home}/current/lib/helper.sh" ]]
[[ ! -e "${installer_home}/current/state/private.txt" ]]
[[ ! -e "${installer_home}/current/server.env" ]]

printf '%s\n' 'updated-helper-content' > "${source_clone}/lib/helper.sh"
install_management_copy "${installer_home}" >/dev/null
[[ "$(<"${installer_home}/current/lib/helper.sh")" == updated-helper-content ]]
[[ "$(find "${installer_home}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 2 ]]

rm -rf "${source_clone}"
[[ "$(bash "${launcher}")" == installed-launcher-ok ]]

ensure_root() { :; }
require_state_file() { :; }
log_warn() { :; }
stack_root="${TEMP_ROOT}/stack"
PROJECT_ROOT="${stack_root}"
STATE_DIR="${stack_root}/state"
STATE_FILE="${STATE_DIR}/install.state"
COMPOSE_FILE="${STATE_DIR}/missing-compose.yml"
CADDY_SNIPPET_FILE="${TEMP_ROOT}/missing.caddy"
LEGACY_STATE_FILE="${TEMP_ROOT}/legacy.state"
mkdir -p "${STATE_DIR}"
printf '%s\n' test > "${STATE_FILE}"
project_root_looks_safe() { :; }
prompt_yes_no() { return 1; }
prompt_typed_confirmation() { [[ "$1" == WIPE_PROJECT ]]; }
full_uninstall_keep_installer
[[ ! -e "${stack_root}" ]]

log_info() { :; }
DEFAULT_INSTALLER_HOME="${installer_home}"
DEFAULT_MENU_LAUNCHER_PATH="${launcher}"
prompt_typed_confirmation() { return 1; }
if remove_installer_tooling; then
  printf '%s\n' 'Installer removal succeeded without confirmation.' >&2
  exit 1
fi
[[ -d "${installer_home}" && -f "${launcher}" ]]

prompt_typed_confirmation() { [[ "$1" == REMOVE_INSTALLER ]]; }
remove_installer_tooling
[[ ! -e "${installer_home}" && ! -e "${launcher}" ]]

printf '%s\n' 'Management launcher integration harness passed.'
