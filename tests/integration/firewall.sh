#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
FAKE_BIN="${TEMP_ROOT}/bin"
export FIREWALL_FAKE_STATE="${TEMP_ROOT}/fake-state"
export STATE_DIR="${TEMP_ROOT}/project/state"
export UFW_CONFIG_DIR="${TEMP_ROOT}/etc/ufw"
export UFW_DEFAULT_FILE="${TEMP_ROOT}/etc/default/ufw"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p \
  "${FAKE_BIN}" \
  "${FIREWALL_FAKE_STATE}" \
  "${STATE_DIR}" \
  "${UFW_CONFIG_DIR}" \
  "$(dirname "${UFW_DEFAULT_FILE}")"
printf '%s\n' 'IPV6=no' > "${UFW_DEFAULT_FILE}"
printf '%s\n' inactive > "${FIREWALL_FAKE_STATE}/status"
printf '%s\n' '8443/tcp ALLOW IN Anywhere' > "${FIREWALL_FAKE_STATE}/rules"
printf '%s\n' '8080/tcp -> 127.0.0.1:8080' > "${FIREWALL_FAKE_STATE}/bot-ports"
: > "${FIREWALL_FAKE_STATE}/commands"

cat > "${FAKE_BIN}/sshd" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == "-T" ]] || exit 1
[[ "${FIREWALL_TEST_SSH_PORT:-2222}" != "none" ]] || exit 0
printf 'port %s\n' "${FIREWALL_TEST_SSH_PORT:-2222}"
printf '%s\n' 'passwordauthentication yes'
EOF

cat > "${FAKE_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "show" && "${FIREWALL_TEST_SOCKET_PORT:-2022}" != "none" ]]; then
  printf '[::]:%s (Stream)\n' "${FIREWALL_TEST_SOCKET_PORT:-2022}"
fi
EOF

cat > "${FAKE_BIN}/ufw" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${FIREWALL_FAKE_STATE}/commands"

if [[ "${1:-}" == "status" ]]; then
  if [[ "$(<"${FIREWALL_FAKE_STATE}/status")" == "active" ]]; then
    printf '%s\n' \
      'Status: active' \
      'Logging: on (low)' \
      'Default: deny (incoming), allow (outgoing), deny (routed)' \
      '' \
      'To                         Action      From' \
      '--                         ------      ----'
    while read -r target action direction source; do
      [[ -n "${target}" ]] || continue
      printf '%-26s %s %s    %s\n' "${target}" "${action}" "${direction}" "${source}"
      printf '%-26s %s %s    %s (v6)\n' "${target} (v6)" "${action}" "${direction}" "${source}"
    done < "${FIREWALL_FAKE_STATE}/rules"
  else
    printf '%s\n' 'Status: inactive'
  fi
  exit 0
fi

if [[ "${1:-}" == "show" && "${2:-}" == "added" ]]; then
  while read -r target action _ source; do
    if [[ "${source}" == "Anywhere" ]]; then
      printf 'ufw %s %s\n' "${action,,}" "${target}"
    else
      port="${target%/*}"
      protocol="${target#*/}"
      printf 'ufw %s from %s to any port %s proto %s\n' \
        "${action,,}" "${source}" "${port}" "${protocol}"
    fi
  done < "${FIREWALL_FAKE_STATE}/rules"
  exit 0
fi

if [[ "${1:-}" == "allow" ]]; then
  rule="${2} ALLOW IN Anywhere"
  if ! grep -Fxq "${rule}" "${FIREWALL_FAKE_STATE}/rules"; then
    printf '%s\n' "${rule}" >> "${FIREWALL_FAKE_STATE}/rules"
  fi
  exit 0
fi

if [[ "${1:-}" == "--force" && "${2:-}" == "enable" ]]; then
  printf '%s\n' active > "${FIREWALL_FAKE_STATE}/status"
  exit 0
fi

case "${1:-}" in
  default|logging|reload) exit 0 ;;
esac

exit 1
EOF


cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" != "info" ]] || exit 0
if [[ "${1:-}" == "port" ]]; then
  case "${2:-}" in
    bot-container-id) cat "${FIREWALL_FAKE_STATE}/bot-ports" ;;
    postgres-container-id|redis-container-id) : ;;
  esac
  exit 0
fi
exit 1
EOF

cat > "${FAKE_BIN}/ss" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${FIREWALL_TEST_SS_FAIL:-false}" != "true" ]] || exit 1
if [[ "$*" == *':8080'* ]]; then
  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*'
fi
EOF

chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:${PATH}"
export SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 2200'

ensure_root() { :; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
log_info() { :; }
log_warn() { :; }
die() { printf '%s\n' "$*" >&2; return 1; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
secure_private_file() { chmod 600 "$1"; }
compose_cmd() {
  [[ "${1:-}" == ps && "${2:-}" == -q ]] || return 1
  case "${3:-}" in
    bot) printf '%s\n' bot-container-id ;;
    postgres) printf '%s\n' postgres-container-id ;;
    redis) printf '%s\n' redis-container-id ;;
    *) return 1 ;;
  esac
}

# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"

configure_host_firewall
verify_host_firewall
verify_private_runtime_ports

expected_rules=$'80/tcp\n443/tcp\n443/udp\n2022/tcp\n2200/tcp\n2222/tcp\n8443/tcp'
actual_rules="$(awk '$2 == "ALLOW" {print $1}' "${FIREWALL_FAKE_STATE}/rules" | sort -V)"
[[ "${actual_rules}" == "${expected_rules}" ]]
grep -Fqx 'IPV6=yes' "${UFW_DEFAULT_FILE}"
[[ "$(find "${STATE_DIR}/firewall-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "1" ]]

commands_after_first_run="$(wc -l < "${FIREWALL_FAKE_STATE}/commands")"
configure_host_firewall
[[ "$(wc -l < "${FIREWALL_FAKE_STATE}/commands")" == "$((commands_after_first_run + 1))" ]]
[[ "$(find "${STATE_DIR}/firewall-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "1" ]]

grep -Fq '2200/tcp ALLOW' "${FIREWALL_FAKE_STATE}/rules"
grep -Fq '8443/tcp ALLOW' "${FIREWALL_FAKE_STATE}/rules"
if grep -Fq 'ufw reset' "${FIREWALL_FAKE_STATE}/commands"; then
  printf '%s\n' 'Firewall used the destructive ufw reset command.' >&2
  exit 1
fi

printf '%s\n' '8080/tcp -> 0.0.0.0:8080' > "${FIREWALL_FAKE_STATE}/bot-ports"
if verify_private_runtime_ports; then
  printf '%s\n' 'Firewall accepted a public Docker binding.' >&2
  exit 1
fi
printf '%s\n' '8080/tcp -> 127.0.0.1:8080' > "${FIREWALL_FAKE_STATE}/bot-ports"
export FIREWALL_TEST_SS_FAIL=true
if verify_private_runtime_ports; then
  printf '%s\n' 'Firewall accepted a failed socket inspection.' >&2
  exit 1
fi
unset FIREWALL_TEST_SS_FAIL

export FIREWALL_TEST_SSH_PORT=none
export FIREWALL_TEST_SOCKET_PORT=none
unset SSH_CONNECTION
commands_before_rejected_run="$(wc -l < "${FIREWALL_FAKE_STATE}/commands")"
if configure_host_firewall 2>/dev/null; then
  printf '%s\n' 'Firewall unexpectedly accepted an unknown SSH port.' >&2
  exit 1
fi
[[ "$(wc -l < "${FIREWALL_FAKE_STATE}/commands")" == "${commands_before_rejected_run}" ]]

export FIREWALL_TEST_SSH_PORT=2222
export FIREWALL_TEST_SOCKET_PORT=2022
export SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 2200'
printf '%s\n' inactive > "${FIREWALL_FAKE_STATE}/status"
printf '%s\n' '2222/tcp DENY IN 192.0.2.10' > "${FIREWALL_FAKE_STATE}/rules"
if configure_host_firewall 2>/dev/null; then
  printf '%s\n' 'Firewall enabled despite a conflicting SSH deny rule.' >&2
  exit 1
fi
[[ "$(<"${FIREWALL_FAKE_STATE}/status")" == "inactive" ]]

printf '%s\n' 'Firewall integration harness passed.'
