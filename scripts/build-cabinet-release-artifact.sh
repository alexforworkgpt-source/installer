#!/usr/bin/env bash

set -Eeuo pipefail

if (($# != 6)); then
  printf '%s\n' 'usage: build-cabinet-release-artifact.sh <repository> <sha> <archive> <installer-root> <node-image> <nginx-image>' >&2
  exit 2
fi

repository="$1"
cabinet_sha="$2"
archive_path="$3"
installer_root="$4"
node_builder_image="$5"
nginx_runtime_image="$6"
work_dir="$(mktemp -d)"
source_dir="${work_dir}/cabinet"
dist_dir="${work_dir}/dist"
image_tag="bedolaga-cabinet-release:${cabinet_sha}"
container_name="bedolaga-cabinet-release-${cabinet_sha:0:12}-$$"

cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
  docker image rm -f "${image_tag}" >/dev/null 2>&1 || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT

resolved_sha="$(python3 "${installer_root}/lib/release_bundle.py" resolve-ref "${repository}" "${cabinet_sha}")"
[[ "${resolved_sha}" == "${cabinet_sha}" ]]

git clone --quiet --no-checkout "${repository}" "${source_dir}"
git -C "${source_dir}" checkout --quiet --detach "${cabinet_sha}"
python3 "${installer_root}/lib/release_bundle.py" verify-head "${source_dir}" "${cabinet_sha}"
python3 "${installer_root}/scripts/release_bundle_publication.py" \
  pin-cabinet-dockerfile \
  "${source_dir}/Dockerfile" \
  "${work_dir}/Dockerfile.pinned" \
  "${node_builder_image}" \
  "${nginx_runtime_image}"

docker build \
  --file "${work_dir}/Dockerfile.pinned" \
  --build-arg VITE_API_URL=/api \
  --build-arg VITE_TELEGRAM_BOT_USERNAME= \
  --build-arg VITE_APP_NAME=Cabinet \
  --build-arg VITE_APP_LOGO=V \
  --tag "${image_tag}" \
  "${source_dir}"

docker create --name "${container_name}" "${image_tag}" >/dev/null
mkdir -p "${dist_dir}"
docker cp "${container_name}:/usr/share/nginx/html/." "${dist_dir}/"

python3 "${installer_root}/scripts/release_bundle_publication.py" \
  package-cabinet "${dist_dir}" "${archive_path}"
