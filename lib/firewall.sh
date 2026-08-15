#!/usr/bin/env bash

set -Eeuo pipefail

UFW_CONFIG_DIR="${UFW_CONFIG_DIR:-/etc/ufw}"
UFW_DEFAULT_FILE="${UFW_DEFAULT_FILE:-/etc/default/ufw}"

ensure_ufw_installed() {
  if command_exists ufw; then
    return 0
  fi

  log_info "Установка UFW."
  wait_for_package_manager
  apt-get update
  wait_for_package_manager
  apt-get -o DPkg::Lock::Timeout=600 install -y ufw
  command_exists ufw || die "UFW недоступен после установки."
}

ufw_cmd() {
  LC_ALL=C ufw "$@"
}

detect_ssh_socket_ports() {
  command_exists systemctl || return 0

  local listen_config
  local endpoint
  listen_config="$(systemctl show ssh.socket --property=Listen --value 2>/dev/null || true)"

  while IFS= read -r endpoint; do
    endpoint="${endpoint#"${endpoint%%[![:space:]]*}"}"
    endpoint="${endpoint%"${endpoint##*[![:space:]]}"}"
    if [[ "${endpoint}" =~ :([0-9]+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "${endpoint}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${endpoint}"
    fi
  done < <(sed -E 's/[[:space:]]*\(Stream\)/\n/g' <<<"${listen_config}")
}

detect_ssh_ports() {
  local ports=""
  local port=""
  local sshd_config=""
  local socket_ports=""

  if command_exists sshd; then
    sshd_config="$(sshd -T 2>/dev/null || true)"
    ports="$(awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' <<<"${sshd_config}")"
  fi

  socket_ports="$(detect_ssh_socket_ports)"
  ports="$(printf '%s\n%s\n' "${ports}" "${socket_ports}" | awk 'NF' | sort -un)"

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    port="$(awk '{print $4}' <<<"${SSH_CONNECTION}")"
    if is_valid_port "${port}"; then
      ports="$(printf '%s\n%s\n' "${ports}" "${port}" | awk 'NF' | sort -un)"
    fi
  fi

  if [[ -z "${ports}" ]]; then
    die "Не удалось определить SSH-порт. Firewall не изменён."
    return 1
  fi

  while IFS= read -r port; do
    [[ -n "${port}" ]] || continue
    if ! is_valid_port "${port}"; then
      die "Обнаружен некорректный SSH-порт: ${port}. Firewall не изменён."
      return 1
    fi
    printf '%s\n' "${port}"
  done <<<"${ports}"
}

firewall_ipv6_enabled() {
  [[ -f "${UFW_DEFAULT_FILE}" ]] \
    && grep -Eq '^IPV6=(yes|YES|true|TRUE)$' "${UFW_DEFAULT_FILE}"
}

enable_firewall_ipv6() {
  if firewall_ipv6_enabled; then
    return 0
  fi

  if grep -Eq '^IPV6=' "${UFW_DEFAULT_FILE}" 2>/dev/null; then
    sed -i -E 's/^IPV6=.*/IPV6=yes/' "${UFW_DEFAULT_FILE}"
  else
    printf '%s\n' 'IPV6=yes' >> "${UFW_DEFAULT_FILE}"
  fi

  firewall_ipv6_enabled || die "Не удалось включить IPv6-фильтрацию UFW."
}

firewall_public_rule_allows() {
  local status_output="$1"
  local port="$2"
  local protocol="$3"
  local target="${port}/${protocol}"

  awk -v target="${target}" '
    ($1 == target || $1 == "Anywhere") && ($2 == "DENY" || $2 == "REJECT") && $3 == "IN" && $4 == "Anywhere" { decision = -1; exit }
    $1 == target && $2 == "ALLOW" && $3 == "IN" && $4 == "Anywhere" { decision = 1; exit }
    END { exit(decision == 1 ? 0 : 1) }
  ' <<<"${status_output}"
}

firewall_public_ipv6_rule_allows() {
  local status_output="$1"
  local port="$2"
  local protocol="$3"
  local target="${port}/${protocol}"

  awk -v target="${target}" '
    ($1 == target || $1 == "Anywhere") && $2 == "(v6)" && ($3 == "DENY" || $3 == "REJECT") && $4 == "IN" && $5 == "Anywhere" { decision = -1; exit }
    $1 == target && $2 == "(v6)" && $3 == "ALLOW" && $4 == "IN" && $5 == "Anywhere" { decision = 1; exit }
    END { exit(decision == 1 ? 0 : 1) }
  ' <<<"${status_output}"
}

firewall_rule_conflicts() {
  local port="$1"
  local protocol="$2"
  local include_source_specific="${3:-false}"
  local rule
  local token
  local previous=""
  local rule_port=""
  local rule_protocol=""

  while IFS= read -r rule; do
    [[ "${rule}" == 'ufw deny '* || "${rule}" == 'ufw reject '* ]] || continue
    [[ "${rule}" != *' out '* ]] || continue
    if [[ "${include_source_specific}" != "true" \
      && "${rule}" == *' from '* && "${rule}" != *' from any'* ]]; then
      continue
    fi

    rule_port=""
    rule_protocol=""
    previous=""
    for token in ${rule}; do
      if [[ "${previous}" == "port" && "${token}" =~ ^[0-9]+$ ]]; then
        rule_port="${token}"
      elif [[ "${previous}" == "proto" ]]; then
        rule_protocol="${token}"
      elif [[ "${token}" =~ ^([0-9]+)(/(tcp|udp))?$ ]]; then
        rule_port="${BASH_REMATCH[1]}"
        [[ -n "${BASH_REMATCH[3]:-}" ]] && rule_protocol="${BASH_REMATCH[3]}"
      fi
      previous="${token}"
    done

    if [[ -z "${rule_port}" ]]; then
      return 0
    fi
    if [[ "${rule_port}" == "${port}" \
      && ( -z "${rule_protocol}" || "${rule_protocol}" == "${protocol}" ) ]]; then
      return 0
    fi
  done < <(ufw_cmd show added 2>/dev/null || true)

  return 1
}

assert_no_firewall_rule_conflicts() {
  local ssh_ports="$1"
  local ssh_port

  while IFS= read -r ssh_port; do
    [[ -n "${ssh_port}" ]] || continue
    if firewall_rule_conflicts "${ssh_port}" tcp true; then
      die "UFW содержит DENY/REJECT для SSH-порта ${ssh_port}. Firewall не изменён."
      return 1
    fi
  done <<<"${ssh_ports}"

  if firewall_rule_conflicts 80 tcp; then
    die "UFW содержит глобальный DENY/REJECT для 80/tcp. Firewall не изменён."
    return 1
  fi
  if firewall_rule_conflicts 443 tcp; then
    die "UFW содержит глобальный DENY/REJECT для 443/tcp. Firewall не изменён."
    return 1
  fi
  if firewall_rule_conflicts 443 udp; then
    die "UFW содержит глобальный DENY/REJECT для 443/udp. Firewall не изменён."
    return 1
  fi
}

verify_host_firewall() {
  command_exists ufw || return 1

  local status_output
  local ssh_ports
  local ssh_port
  local required_rule
  status_output="$(ufw_cmd status verbose 2>/dev/null || true)"

  grep -Fqx 'Status: active' <<<"${status_output}" || return 1
  grep -Fq 'Default: deny (incoming), allow (outgoing)' <<<"${status_output}" || return 1
  firewall_ipv6_enabled || return 1

  ssh_ports="$(detect_ssh_ports)" || return 1
  while IFS= read -r ssh_port; do
    [[ -n "${ssh_port}" ]] || continue
    firewall_public_rule_allows "${status_output}" "${ssh_port}" tcp || return 1
    if firewall_ipv6_enabled; then
      firewall_public_ipv6_rule_allows "${status_output}" "${ssh_port}" tcp || return 1
    fi
  done <<<"${ssh_ports}"

  for required_rule in '80 tcp' '443 tcp' '443 udp'; do
    read -r port protocol <<<"${required_rule}"
    firewall_public_rule_allows "${status_output}" "${port}" "${protocol}" || return 1
    if firewall_ipv6_enabled; then
      firewall_public_ipv6_rule_allows "${status_output}" "${port}" "${protocol}" || return 1
    fi
  done
}

create_firewall_backup() {
  local state_dir="${STATE_DIR:-${DEFAULT_PROJECT_ROOT:-/opt/bot-stack}/state}"
  local backup_root="${state_dir}/firewall-backups"
  local timestamp
  local backup_dir

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="${backup_root}/${timestamp}"
  if [[ -e "${backup_dir}" ]]; then
    backup_dir="${backup_dir}-$$"
  fi

  mkdir -p "${backup_dir}"
  if [[ -d "${UFW_CONFIG_DIR}" ]]; then
    cp -a "${UFW_CONFIG_DIR}" "${backup_dir}/ufw"
  fi
  if [[ -f "${UFW_DEFAULT_FILE}" ]]; then
    mkdir -p "${backup_dir}/default"
    cp -a "${UFW_DEFAULT_FILE}" "${backup_dir}/default/ufw"
  fi
  ufw_cmd status verbose > "${backup_dir}/status.txt" 2>&1 || true
  chmod -R go-rwx "${backup_dir}"
  log_info "Создана резервная копия UFW: ${backup_dir}"
}

configure_host_firewall() {
  ensure_root
  ensure_ufw_installed

  local ssh_ports
  local ssh_port
  ssh_ports="$(detect_ssh_ports)" || return 1

  if verify_host_firewall; then
    log_info "UFW уже содержит базовые правила Bot Stack."
    return 0
  fi

  assert_no_firewall_rule_conflicts "${ssh_ports}" || return 1

  create_firewall_backup
  enable_firewall_ipv6

  while IFS= read -r ssh_port; do
    [[ -n "${ssh_port}" ]] || continue
    ufw_cmd allow "${ssh_port}/tcp" comment 'SSH' \
      || { die "Не удалось разрешить SSH-порт ${ssh_port}/tcp в UFW."; return 1; }
  done <<<"${ssh_ports}"
  ufw_cmd allow 80/tcp comment 'Caddy HTTP' \
    || { die "Не удалось разрешить 80/tcp в UFW."; return 1; }
  ufw_cmd allow 443/tcp comment 'Caddy HTTPS' \
    || { die "Не удалось разрешить 443/tcp в UFW."; return 1; }
  ufw_cmd allow 443/udp comment 'Caddy HTTP3' \
    || { die "Не удалось разрешить 443/udp в UFW."; return 1; }
  ufw_cmd default deny incoming \
    || { die "Не удалось установить deny incoming в UFW."; return 1; }
  ufw_cmd default allow outgoing \
    || { die "Не удалось установить allow outgoing в UFW."; return 1; }
  ufw_cmd logging low \
    || { die "Не удалось включить логирование UFW."; return 1; }
  ufw_cmd --force enable \
    || { die "Не удалось включить UFW."; return 1; }

  verify_host_firewall \
    || die "UFW включён, но обязательные правила не прошли проверку. Проверьте: ufw status verbose"
  log_info "UFW активирован: SSH, 80/tcp, 443/tcp и 443/udp разрешены."
}

print_host_firewall_status() {
  if ! command_exists ufw; then
    log_warn "UFW не установлен."
    return 0
  fi

  ufw_cmd status verbose
}

host_port_has_public_listener() {
  local port="$1"
  local local_address
  local listeners

  command_exists ss || return 2
  listeners="$(ss -H -ltn "( sport = :${port} )" 2>/dev/null)" || return 2

  while IFS= read -r local_address; do
    [[ -n "${local_address}" ]] || continue
    case "${local_address}" in
      127.*:"${port}"|\[::1\]:"${port}"|::1:"${port}") ;;
      *) return 0 ;;
    esac
  done < <(awk '{print $4}' <<<"${listeners}")

  return 1
}

host_port_has_no_public_listener() {
  local port="$1"
  local result

  if host_port_has_public_listener "${port}"; then
    return 1
  else
    result=$?
  fi

  [[ "${result}" == "1" ]]
}

verify_private_runtime_ports() {
  local bot_port="${BOT_HTTP_PORT:-${DEFAULT_BOT_HTTP_PORT:-8080}}"
  local published_ports
  local binding
  local container_name

  host_port_has_no_public_listener "${bot_port}" || return 1
  host_port_has_no_public_listener 5432 || return 1
  host_port_has_no_public_listener 6379 || return 1

  command_exists docker || return 1
  docker info >/dev/null 2>&1 || return 1
  if docker container inspect botstack_bot >/dev/null 2>&1; then
    published_ports="$(docker port botstack_bot 2>/dev/null)" || return 1
    [[ -n "${published_ports}" ]] || return 1
    while IFS= read -r binding; do
      [[ "${binding}" == "8080/tcp -> 127.0.0.1:${bot_port}" \
        || "${binding}" == "8080/tcp -> [::1]:${bot_port}" ]] \
        || return 1
    done <<<"${published_ports}"
  fi

  for container_name in botstack_postgres botstack_redis; do
    if docker container inspect "${container_name}" >/dev/null 2>&1; then
      published_ports="$(docker port "${container_name}" 2>/dev/null)" || return 1
      [[ -z "${published_ports}" ]] || return 1
    fi
  done
}
