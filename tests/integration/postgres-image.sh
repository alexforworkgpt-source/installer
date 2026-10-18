#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
# Image references may be immutable digests: use image metadata, not tag names.
docker() {
  [[ "$*" == 'image inspect --format {{range .Config.Env}}{{println .}}{{end}} postgres@sha256:fixture' ]] || return 1
  printf '%s\n' PATH=/bin "PG_MAJOR=${TEST_IMAGE_MAJOR}" PGDATA=/var/lib/postgresql/18/docker
}
TEST_IMAGE_MAJOR=18
[[ "$(postgres_image_major postgres@sha256:fixture)" == 18 ]]
TEST_IMAGE_MAJOR=15
[[ "$(postgres_image_major postgres@sha256:fixture)" == 15 ]]
TEST_IMAGE_MAJOR=17
if postgres_image_major postgres@sha256:fixture; then
  printf '%s\n' 'Unknown major was accepted.' >&2
  exit 1
fi
printf '%s\n' 'PostgreSQL image metadata harness passed.'
