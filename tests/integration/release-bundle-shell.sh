#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
MUTATION_LOG="${TEMP_ROOT}/mutations.log"
PROTECTED_UPDATE_ADAPTER="${TEMP_ROOT}/protected-update-adapter.sh"
INJECTED_STAGE=""
INJECT_CABINET_ACTIVATION_FAILURE="false"
export MUTATION_LOG TEMP_ROOT INJECTED_STAGE INJECT_CABINET_ACTIVATION_FAILURE

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"

create_repository() {
  local name="$1"
  local source_dir="${TEMP_ROOT}/${name}-source"
  local checkout_dir="${TEMP_ROOT}/${name}-checkout"

  git init --quiet --initial-branch=main "${source_dir}"
  git -C "${source_dir}" config user.email "release-shell-tests@example.com"
  git -C "${source_dir}" config user.name "Release Shell Tests"
  printf '%s\n' "${name} release" > "${source_dir}/release.txt"
  git -C "${source_dir}" add release.txt
  git -C "${source_dir}" commit --quiet -m "initial ${name} release"
  git clone --quiet "${source_dir}" "${checkout_dir}"
  printf '%s\n%s\n' "${source_dir}" "${checkout_dir}"
}

mapfile -t bot_repository < <(create_repository bot)
mapfile -t cabinet_repository < <(create_repository cabinet)
BOT_REPO_URL="${bot_repository[0]}"
BOT_REPO_DIR="${bot_repository[1]}"
CABINET_REPO_URL="${cabinet_repository[0]}"
CABINET_REPO_DIR="${cabinet_repository[1]}"
BOT_SHA="$(git -C "${BOT_REPO_DIR}" rev-parse HEAD)"
MISSING_CABINET_SHA="ffffffffffffffffffffffffffffffffffffffff"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
RUNTIME_DIR="${PROJECT_ROOT}/runtime"
CABINET_DIST_DIR="${RUNTIME_DIR}/cabinet-dist"
STATE_FILE="${STATE_DIR}/install.state"
INSTALLER_DIR="${SCRIPT_DIR}"
mkdir -p "${STATE_DIR}" "${CABINET_DIST_DIR}"
printf '%s\n' 'old cabinet' > "${CABINET_DIST_DIR}/index.html"
printf '%s\n' 'state' > "${STATE_FILE}"

ARTIFACT_SOURCE="${TEMP_ROOT}/artifact"
ARTIFACT_FILE="${TEMP_ROOT}/cabinet-dist.tar.gz"
mkdir -p "${ARTIFACT_SOURCE}"
printf '%s\n' 'new cabinet' > "${ARTIFACT_SOURCE}/index.html"
tar -C "${ARTIFACT_SOURCE}" -czf "${ARTIFACT_FILE}" index.html
ARTIFACT_SHA256="$(sha256sum "${ARTIFACT_FILE}" | awk '{print $1}')"

MANIFEST_FILE="${TEMP_ROOT}/release.json"
write_manifest() {
  local bot_sha="$1"
  local cabinet_sha="$2"
  local artifact_sha256="$3"
  local migration_policy="${4:-rollback-compatible}"

  cat > "${MANIFEST_FILE}" <<EOF
{
  "schema_version": 1,
  "release": "shell-test-release",
  "bot": {
    "repository": "${BOT_REPO_URL}",
    "sha": "${bot_sha}",
    "backend_contract": "1"
  },
  "cabinet": {
    "source_sha": "${cabinet_sha}",
    "artifact_url": "https://example.test/cabinet-dist.tar.gz",
    "artifact_sha256": "${artifact_sha256}",
    "backend_contract": "1"
  },
  "images": {
    "postgres": "postgres@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "redis": "redis@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  },
  "backend_contract": "1",
  "configuration_schema": 1,
  "migration_policy": "${migration_policy}"
}
EOF
}

write_manifest "${BOT_SHA}" "${MISSING_CABINET_SHA}" "${ARTIFACT_SHA256}"

ensure_root() { :; }
require_state_file() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
prompt_optional_input() { printf '%s' "${MANIFEST_FILE}"; }
prompt_yes_no() { return 0; }
command_exists() {
  [[ "$1" == "jq" ]] || command -v "$1" >/dev/null 2>&1
}
jq() {
  local query="${2#.}"
  run_python -c '
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[part]
print(value)
' "${query}"
}
copy_or_download_release_file() {
  local destination="$2"
  case "${destination}" in
    */release.json) cp "${MANIFEST_FILE}" "${destination}" ;;
    *) cp "${ARTIFACT_FILE}" "${destination}" ;;
  esac
}
create_verified_update_dump() {
  printf '%s\n' dump > "${TEMP_ROOT}/database.dump"
  printf '%s' "${TEMP_ROOT}/database.dump"
}
current_alembic_revision() { printf '%s' 'revision-before'; }
create_update_snapshot() { printf '%s\n' snapshot >> "${MUTATION_LOG}"; }
checkout_repo_ref() {
  printf 'checkout:%s\n' "$3" >> "${MUTATION_LOG}"
  git -C "$1" fetch --quiet --tags origin
  git -C "$1" checkout --quiet "$3"
}
render_compose_file() { :; }
compose_cmd() { :; }
reload_caddy() { :; }
apply_telegram_runtime_mode() { :; }
wait_for_runtime_ready() { :; }
verify_runtime_health() { :; }
mark_runtime_apply_state() { :; }
save_state() {
  printf '%s\n' "${CURRENT_RELEASE_BUNDLE_IDENTITY:-}" > "${TEMP_ROOT}/saved-bundle-identity"
  printf '%s\n' "${CURRENT_CABINET_ARTIFACT_SHA256:-}" > "${TEMP_ROOT}/saved-cabinet-identity"
}
secure_private_file() { :; }
status_stack() { :; }

cat > "${PROTECTED_UPDATE_ADAPTER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

context_dir="$2"
stage="$3"
case "${stage}" in
  current-revision)
    revision_calls="${context_dir}/revision-calls"
    calls=0
    [[ ! -f "${revision_calls}" ]] || calls="$(<"${revision_calls}")"
    calls=$((calls + 1))
    printf '%s\n' "${calls}" > "${revision_calls}"
    if [[ "${INJECTED_STAGE:-}" == revision && "${calls}" -gt 1 ]]; then
      exit 1
    fi
    printf '%s\n' revision-before
    ;;
  current-release) < "${context_dir}/previous-release-key" tr -d '\n' ;;
  create-dump)
    dump_file="${context_dir}/verified.dump"
    printf '%s\n' dump > "${dump_file}"
    printf '%s\n' "${dump_file}"
    ;;
  apply-release)
    printf '%s\n' apply-release >> "${MUTATION_LOG}"
    if [[ "${INJECT_CABINET_ACTIVATION_FAILURE:-false}" == true \
      || "${INJECTED_STAGE:-}" == checkout \
      || "${INJECTED_STAGE:-}" == cabinet \
      || "${INJECTED_STAGE:-}" == compose \
      || "${INJECTED_STAGE:-}" == caddy \
      || "${INJECTED_STAGE:-}" == telegram ]]; then
      exit 1
    fi
    ;;
  verify-release) [[ "${INJECTED_STAGE:-}" != health ]] ;;
  commit-release)
    cp "${context_dir}/target-bundle-identity" "${TEMP_ROOT}/saved-bundle-identity"
    cp "${context_dir}/target-artifact-sha256" "${TEMP_ROOT}/saved-cabinet-identity"
    ;;
  rollback-release) printf '%s\n' rollback-release >> "${MUTATION_LOG}" ;;
  restore-dump) printf 'restore-dump:%s:%s\n' "$4" "$5" >> "${MUTATION_LOG}" ;;
  verify-rollback) : ;;
  safe-stop) printf '%s\n' safe-stop >> "${MUTATION_LOG}" ;;
esac
EOF
chmod +x "${PROTECTED_UPDATE_ADAPTER}"

POSTGRES_IMAGE="postgres:previous"
REDIS_IMAGE="redis:previous"
BOT_VERSION_REF="${BOT_SHA}"
CABINET_VERSION_REF="$(git -C "${CABINET_REPO_DIR}" rev-parse HEAD)"
CURRENT_RELEASE="previous-release"

if (update_from_release_bundle); then
  printf '%s\n' 'Missing Cabinet ref was accepted.' >&2
  exit 1
fi

if [[ -s "${MUTATION_LOG}" ]]; then
  printf '%s\n' 'Missing Cabinet ref was rejected after mutation started:' >&2
  cat "${MUTATION_LOG}" >&2
  exit 1
fi

[[ "$(<"${CABINET_DIST_DIR}/index.html")" == 'old cabinet' ]]

printf '%s\n' 'second bot release' > "${bot_repository[0]}/release.txt"
git -C "${bot_repository[0]}" commit --quiet -am 'second bot release'
TARGET_BOT_SHA="$(git -C "${bot_repository[0]}" rev-parse HEAD)"
TARGET_CABINET_SHA="$(git -C "${cabinet_repository[0]}" rev-parse HEAD)"
write_manifest "${TARGET_BOT_SHA}" "${TARGET_CABINET_SHA}" "${ARTIFACT_SHA256}"
: > "${MUTATION_LOG}"

checkout_repo_ref() {
  printf 'checkout:%s\n' "$3" >> "${MUTATION_LOG}"
  if [[ "$1" == "${BOT_REPO_DIR}" && "$3" == "${TARGET_BOT_SHA}" ]]; then
    return 0
  fi
  git -C "$1" fetch --quiet --tags origin
  git -C "$1" checkout --quiet "$3"
}

INJECTED_STAGE="checkout"
if (update_from_release_bundle); then
  printf '%s\n' 'Repository HEAD mismatch was accepted.' >&2
  exit 1
fi
INJECTED_STAGE=""

if [[ "$(<"${CABINET_DIST_DIR}/index.html")" != 'old cabinet' ]]; then
  printf '%s\n' 'Repository HEAD mismatch activated Cabinet runtime.' >&2
  exit 1
fi

write_manifest \
  "${TARGET_BOT_SHA}" \
  "${TARGET_CABINET_SHA}" \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
: > "${MUTATION_LOG}"
checkout_repo_ref() {
  printf 'checkout:%s\n' "$3" >> "${MUTATION_LOG}"
  git -C "$1" fetch --quiet --tags origin
  git -C "$1" checkout --quiet "$3"
}

if (update_from_release_bundle); then
  printf '%s\n' 'Invalid Cabinet checksum was accepted.' >&2
  exit 1
fi

if [[ -s "${MUTATION_LOG}" ]]; then
  printf '%s\n' 'Invalid Cabinet checksum was rejected after mutation started:' >&2
  cat "${MUTATION_LOG}" >&2
  exit 1
fi

write_manifest "${TARGET_BOT_SHA}" "${TARGET_CABINET_SHA}" "${ARTIFACT_SHA256}"
run_python -c '
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["cabinet"]["backend_contract"] = "2"
path.write_text(json.dumps(manifest), encoding="utf-8")
' "${MANIFEST_FILE}"
: > "${MUTATION_LOG}"
if (update_from_release_bundle); then
  printf '%s\n' 'Incompatible Bot/Cabinet pair was accepted.' >&2
  exit 1
fi
if [[ -s "${MUTATION_LOG}" ]]; then
  printf '%s\n' 'Incompatible Bot/Cabinet pair reached mutation.' >&2
  exit 1
fi

write_manifest "${TARGET_BOT_SHA}" "${TARGET_CABINET_SHA}" "${ARTIFACT_SHA256}"
: > "${MUTATION_LOG}"
INJECT_CABINET_ACTIVATION_FAILURE="true"
run_python() {
  local cmd
  if [[ "${INJECT_CABINET_ACTIVATION_FAILURE}" == "true" && "${2:-}" == "activate-cabinet" ]]; then
    return 1
  fi
  cmd="$(python_cmd)" || return 1
  # shellcheck disable=SC2086
  ${cmd} "$@"
}
compose_cmd() { printf '%s\n' runtime >> "${MUTATION_LOG}"; }

if (update_from_release_bundle); then
  printf '%s\n' 'Injected Cabinet activation failure was accepted.' >&2
  exit 1
fi
if grep -Fxq runtime "${MUTATION_LOG}"; then
  printf '%s\n' 'Cabinet activation failure mutated Compose runtime.' >&2
  exit 1
fi
[[ "$(<"${CABINET_DIST_DIR}/index.html")" == 'old cabinet' ]]

: > "${MUTATION_LOG}"
INJECT_CABINET_ACTIVATION_FAILURE="false"
INJECTED_STAGE="revision"
compose_cmd() { :; }
REVISION_CALL_FILE="${TEMP_ROOT}/revision-calls"
printf '%s\n' 0 > "${REVISION_CALL_FILE}"
current_alembic_revision() {
  local call_count
  call_count="$(( $(<"${REVISION_CALL_FILE}") + 1 ))"
  printf '%s\n' "${call_count}" > "${REVISION_CALL_FILE}"
  if ((call_count == 2)); then
    return 0
  fi
  printf '%s' 'revision-before'
}
reload_caddy() { :; }
restore_verified_update_dump() {
  printf 'restore-dump:%s:%s\n' "$1" "$2" >> "${MUTATION_LOG}"
}

if (update_from_release_bundle); then
  printf '%s\n' 'Missing post-update Alembic revision was accepted.' >&2
  exit 1
fi
if ! grep -Fq 'restore-dump:' "${MUTATION_LOG}"; then
  printf '%s\n' 'Missing post-update Alembic revision did not trigger database rollback.' >&2
  exit 1
fi

: > "${MUTATION_LOG}"
INJECTED_STAGE="caddy"
current_alembic_revision() { printf '%s' 'revision-before'; }
CADDY_ATTEMPTS=0
reload_caddy() {
  CADDY_ATTEMPTS=$((CADDY_ATTEMPTS + 1))
  ((CADDY_ATTEMPTS > 1))
}
restore_verified_update_dump() {
  printf 'restore-dump:%s:%s\n' "$1" "$2" >> "${MUTATION_LOG}"
}

if (update_from_release_bundle); then
  printf '%s\n' 'Injected Caddy failure was accepted.' >&2
  exit 1
fi
if ! grep -Fq 'restore-dump:' "${MUTATION_LOG}"; then
  printf '%s\n' 'Rollback did not restore the verified PostgreSQL dump.' >&2
  exit 1
fi
[[ "$(<"${CABINET_DIST_DIR}/index.html")" == 'old cabinet' ]]

INJECTED_STAGE=""
STAGE_ATTEMPT_FILE="${TEMP_ROOT}/stage-attempts"
fail_injected_stage_once() {
  local stage="$1"
  local attempts
  [[ "${INJECTED_STAGE}" == "${stage}" ]] || return 1
  attempts="$(<"${STAGE_ATTEMPT_FILE}")"
  if ((attempts == 0)); then
    printf '%s\n' 1 > "${STAGE_ATTEMPT_FILE}"
    return 0
  fi
  return 1
}
compose_cmd() {
  if [[ "$*" == *'up -d --build --wait --wait-timeout 180 postgres redis bot'* ]] \
    && fail_injected_stage_once compose; then
    return 1
  fi
  return 0
}
reload_caddy() { :; }
apply_telegram_runtime_mode() {
  ! fail_injected_stage_once telegram
}
verify_runtime_health() {
  ! fail_injected_stage_once health
}

for injected_stage in compose telegram health; do
  INJECTED_STAGE="${injected_stage}"
  printf '%s\n' 0 > "${STAGE_ATTEMPT_FILE}"
  : > "${MUTATION_LOG}"
  if (update_from_release_bundle); then
    printf 'Injected %s failure was accepted.\n' "${injected_stage}" >&2
    exit 1
  fi
  if ! grep -Fq 'restore-dump:' "${MUTATION_LOG}"; then
    printf 'Injected %s failure did not restore PostgreSQL.\n' "${injected_stage}" >&2
    exit 1
  fi
  [[ "$(<"${CABINET_DIST_DIR}/index.html")" == 'old cabinet' ]]
done

: > "${MUTATION_LOG}"
write_manifest "${TARGET_BOT_SHA}" "${TARGET_CABINET_SHA}" "${ARTIFACT_SHA256}" forward-only
INJECTED_STAGE="health"
if (update_from_release_bundle); then
  printf '%s\n' 'Failed forward-only update was accepted.' >&2
  exit 1
fi
if grep -Fxq rollback-release "${MUTATION_LOG}"; then
  printf '%s\n' 'Forward-only update incorrectly rolled back the previous release.' >&2
  exit 1
fi
grep -Fxq safe-stop "${MUTATION_LOG}"

: > "${MUTATION_LOG}"
write_manifest "${TARGET_BOT_SHA}" "${TARGET_CABINET_SHA}" "${ARTIFACT_SHA256}"
INJECTED_STAGE="none"
compose_cmd() { :; }
apply_telegram_runtime_mode() { :; }
verify_runtime_health() { :; }
update_from_release_bundle

if [[ ! "$(<"${TEMP_ROOT}/saved-bundle-identity")" =~ ^[0-9a-f]{64}$ ]]; then
  printf '%s\n' 'Committed Release Bundle identity was not persisted.' >&2
  exit 1
fi
if [[ "$(<"${TEMP_ROOT}/saved-cabinet-identity")" != "${ARTIFACT_SHA256}" ]]; then
  printf '%s\n' 'Committed Cabinet artifact identity was not persisted.' >&2
  exit 1
fi

PREPARE_WORK_DIR="${TEMP_ROOT}/prepared-release"
mkdir -p "${PREPARE_WORK_DIR}"
prepare_release_bundle "${MANIFEST_FILE}" "${PREPARE_WORK_DIR}"
[[ "${PREPARED_BOT_SHA}" == "${TARGET_BOT_SHA}" ]]
[[ "${PREPARED_CABINET_SHA}" == "${TARGET_CABINET_SHA}" ]]
[[ "${PREPARED_POSTGRES_IMAGE}" == *@sha256:* ]]
[[ "${PREPARED_REDIS_IMAGE}" == *@sha256:* ]]
[[ -f "${PREPARED_CABINET_ARTIFACT_FILE}" ]]

printf '%s\n' 'Release Bundle shell preflight harness passed.'
