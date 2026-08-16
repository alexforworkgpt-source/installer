#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="/opt/bot-stack-recovery-adapter-test"
FAKE_BIN="${TEMP_ROOT}/bin"
export RECOVERY_FAKE_STATE="${TEMP_ROOT}/fake-state"

cleanup() {
  rm -rf "${TEMP_ROOT}"
  rm -rf "${PROJECT_ROOT}"
  rm -rf /etc/caddy/conf.d /etc/caddy/Caddyfile
}
trap cleanup EXIT

mkdir -p \
  "${FAKE_BIN}" \
  "${RECOVERY_FAKE_STATE}" \
  "${PROJECT_ROOT}/state" \
  "${PROJECT_ROOT}/runtime/bot/data" \
  "${PROJECT_ROOT}/runtime/bot/logs" \
  "${PROJECT_ROOT}/runtime/bot/uploads" \
  "${PROJECT_ROOT}/runtime/cabinet-dist"

cat > "${PROJECT_ROOT}/state/install.state" <<EOF
PROJECT_ROOT='${PROJECT_ROOT}'
HOOK_DOMAIN='hooks.example.test'
APP_DOMAIN='app.example.test'
WEBHOOK_URL='https://hooks.example.test'
BOT_TOKEN='disposable-test-token'
WEBHOOK_SECRET_TOKEN='disposable-test-webhook-secret'
BOT_RUN_MODE='webhook'
BOT_HTTP_PORT='8080'
POSTGRES_USER='test_user'
POSTGRES_DB='test_db'
EOF
printf '%s\n' 'TEST=true' > "${PROJECT_ROOT}/state/bot.env"
printf '%s\n' 'services: {}' > "${PROJECT_ROOT}/state/docker-compose.yml"
printf '%s\n' 'app.example.test { respond "ok" }' > "${PROJECT_ROOT}/state/bot-stack.caddy"
printf '%s\n' 'running' > "${RECOVERY_FAKE_STATE}/bot"
printf '%s\n' 'running' > "${RECOVERY_FAKE_STATE}/caddy"

cat > "${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  info) exit 0 ;;
  ps)
    if [[ "$*" == *'-aq'* ]]; then
      printf '%s\n' bot-container-id
    elif [[ "$*" == *'-q'* && "$(<"${RECOVERY_FAKE_STATE}/bot")" == running ]]; then
      printf '%s\n' bot-container-id
    fi
    exit 0
    ;;
  stop)
    printf '%s\n' 'stopped' > "${RECOVERY_FAKE_STATE}/bot"
    exit 0
    ;;
  container)
    [[ "${2:-}" == "inspect" ]] || exit 1
    if [[ "$*" == *'--format'* ]]; then
      [[ "$(<"${RECOVERY_FAKE_STATE}/bot")" == 'running' ]] && printf '%s\n' 'true' || printf '%s\n' 'false'
    fi
    exit 0
    ;;
  port)
    case "${2:-}" in
      bot-container-id) printf '%s\n' '8080/tcp -> 127.0.0.1:8080' ;;
      postgres-container-id|redis-container-id) : ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  compose)
    if [[ "$*" == *' stop bot'* ]]; then
      printf '%s\n' 'stopped' > "${RECOVERY_FAKE_STATE}/bot"
    elif [[ "$*" == *' up '* ]]; then
      printf '%s\n' 'running' > "${RECOVERY_FAKE_STATE}/bot"
    elif [[ "$*" == *' ps --status running --services'* ]]; then
      printf '%s\n' postgres redis
      [[ "$(<"${RECOVERY_FAKE_STATE}/bot")" != running ]] || printf '%s\n' bot
    elif [[ "$*" == *' ps -q bot'* ]]; then
      printf '%s\n' bot-container-id
    elif [[ "$*" == *' ps -q postgres'* ]]; then
      printf '%s\n' postgres-container-id
    elif [[ "$*" == *' ps -q redis'* ]]; then
      printf '%s\n' redis-container-id
    elif [[ "$*" == *' exec -T redis redis-cli ping'* ]]; then
      printf '%s\n' PONG
    fi
    exit 0
    ;;
esac
exit 1
EOF

cat > "${FAKE_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  stop) printf '%s\n' 'stopped' > "${RECOVERY_FAKE_STATE}/caddy" ;;
  start|reload) printf '%s\n' 'running' > "${RECOVERY_FAKE_STATE}/caddy" ;;
  show)
    [[ "$(<"${RECOVERY_FAKE_STATE}/caddy")" == 'running' ]] && printf '%s\n' active || printf '%s\n' inactive
    ;;
  is-active)
    [[ "$(<"${RECOVERY_FAKE_STATE}/caddy")" == 'running' ]]
    ;;
esac
EOF

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *'/setWebhook'* ]]; then
  attempts_file="${RECOVERY_FAKE_STATE}/set-webhook-attempts"
  attempts="$(( $(cat "${attempts_file}" 2>/dev/null || printf '0') + 1 ))"
  printf '%s\n' "${attempts}" > "${attempts_file}"
  if [[ "${attempts}" == "1" ]]; then
    printf '%s\n' 'simulated transient DNS failure' >&2
    exit 28
  fi
  printf '%s\n' '{"ok":true}'
elif [[ "$*" == *'%{http_code}'* ]]; then
  [[ "$*" == *'hooks.example.test/'* ]] && printf '%s' '404' || printf '%s' '200'
elif [[ "$*" == *'/health/unified'* ]]; then
  printf '%s\n' '{"status":"ok","web_api_enabled":true,"miniapp_static":{"mounted":true,"path":"/cabinet"},"remnawave_webhook":{"enabled":true,"path":"/remnawave-webhook"}}'
elif [[ "$*" == *'/remnawave-webhook'* ]]; then
  printf '%s\n' '{"status":"ok","service":"remnawave_webhook","enabled":true}'
elif [[ "$*" == *'/branding'* ]]; then
  printf '%s\n' '{}'
elif [[ "$*" == *'getWebhookInfo'* ]]; then
  printf '%s\n' '{"ok":true,"result":{"url":"https://hooks.example.test/webhook"}}'
else
  printf '%s\n' '{"ok":true}'
fi
EOF

for command_name in caddy chown; do
  cat > "${FAKE_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
cat > "${FAKE_BIN}/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
cat > "${FAKE_BIN}/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:${PATH}"
export CURL_RETRY_DELAY=0

bash "${SCRIPT_DIR}/lib/recovery_runtime.sh" quiesce "${PROJECT_ROOT}"
[[ "$(<"${RECOVERY_FAKE_STATE}/bot")" == 'stopped' ]]
[[ "$(<"${RECOVERY_FAKE_STATE}/caddy")" == 'stopped' ]]

bash "${SCRIPT_DIR}/lib/recovery_runtime.sh" activate "${PROJECT_ROOT}"
[[ "$(<"${RECOVERY_FAKE_STATE}/bot")" == 'running' ]]
[[ "$(<"${RECOVERY_FAKE_STATE}/caddy")" == 'running' ]]
[[ "$(<"${RECOVERY_FAKE_STATE}/set-webhook-attempts")" == '2' ]]

bash "${SCRIPT_DIR}/lib/recovery_runtime.sh" verify "${PROJECT_ROOT}"

rm -f "${PROJECT_ROOT}/state/install.state"
bash "${SCRIPT_DIR}/lib/recovery_runtime.sh" safe-stop "${PROJECT_ROOT}"
[[ "$(<"${RECOVERY_FAKE_STATE}/bot")" == 'stopped' ]]
[[ "$(<"${RECOVERY_FAKE_STATE}/caddy")" == 'stopped' ]]

printf '%s\n' 'Recovery runtime adapter harness passed.'
