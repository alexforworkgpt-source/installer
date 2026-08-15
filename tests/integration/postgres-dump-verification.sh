#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
POSTGRES_USER="test-user"
POSTGRES_DB="test-db"
ORDER_LOG="${TEMP_ROOT}/order.log"
PG_DUMP_RESULT="success"
PG_RESTORE_LIST_RESULT="success"
PG_RESTORE_VERIFY_RESULT="success"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STATE_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"

PROJECT_ROOT="${TEMP_ROOT}/project"
STATE_DIR="${PROJECT_ROOT}/state"
POSTGRES_USER="test-user"
POSTGRES_DB="test-db"
backup_dir_root() { printf '%s' "${STATE_DIR}/backups"; }
secure_private_file() { chmod 600 "$1"; }

compose_cmd() {
  printf '%s\n' "$*" >> "${ORDER_LOG}"
  case "$*" in
    *' pg_dump '*)
      printf '%s\n' custom-dump
      [[ "${PG_DUMP_RESULT}" == success ]]
      ;;
    *' pg_restore --list'*)
      [[ "${PG_RESTORE_LIST_RESULT}" == success ]]
      ;;
    *' pg_restore '*'installer_verify_'*)
      [[ "${PG_RESTORE_VERIFY_RESULT}" == success ]]
      ;;
    *' psql '*'installer_verify_'*) printf '%s\n' rev-old ;;
    *) return 0 ;;
  esac
}

dump_reference="$(create_verified_update_dump release-good)"
[[ -s "${dump_reference}" ]]
grep -Fq 'pg_restore -U test-user -d installer_verify_' "${ORDER_LOG}"
grep -Fq -- '--exit-on-error' "${ORDER_LOG}"
grep -Fq 'dropdb -U test-user --if-exists --force installer_verify_' "${ORDER_LOG}"

: > "${ORDER_LOG}"
PG_DUMP_RESULT="failure"
if create_verified_update_dump release-pg-dump-failure >/dev/null; then
  printf '%s\n' 'Failed pg_dump was accepted.' >&2
  exit 1
fi
shopt -s nullglob
failed_dumps=("${STATE_DIR}/backups/database/before-release-release-pg-dump-failure-"*.dump)
shopt -u nullglob
((${#failed_dumps[@]} == 0))

: > "${ORDER_LOG}"
PG_DUMP_RESULT="success"
PG_RESTORE_VERIFY_RESULT="failure"
if create_verified_update_dump release-restore-failure >/dev/null; then
  printf '%s\n' 'Dump that cannot be restored into a temporary database was accepted.' >&2
  exit 1
fi
grep -Fq 'dropdb -U test-user --if-exists --force installer_verify_' "${ORDER_LOG}"

: > "${ORDER_LOG}"
PG_RESTORE_VERIFY_RESULT="success"
PG_RESTORE_LIST_RESULT="failure"
if restore_verified_update_dump "${dump_reference}" rev-old; then
  printf '%s\n' 'Unreadable dump reached destructive restore.' >&2
  exit 1
fi
if grep -Fq 'dropdb -U test-user --if-exists --force test-db' "${ORDER_LOG}"; then
  printf '%s\n' 'Database was dropped before dump revalidation.' >&2
  exit 1
fi

printf '%s\n' 'PostgreSQL dump verification harness passed.'
