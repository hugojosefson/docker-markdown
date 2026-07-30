#!/usr/bin/env bash
# Exercise source attachment, retention tags, pull layout, and verification.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly REGISTRY_IMAGE="docker.io/library/registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
container="source-artifact-registry-${$}"
temporary="$(mktemp -d)"

cleanup() {
  docker rm --force "${container}" >/dev/null 2>&1 || true
  rm -rf "${temporary}"
}
trap cleanup EXIT

for command in docker oras python3; do
  command -v "${command}" >/dev/null || {
    printf 'Missing command: %s\n' "${command}" >&2
    exit 1
  }
done

docker run --detach --rm --publish 127.0.0.1::5000 --name "${container}" \
  "${REGISTRY_IMAGE}" >/dev/null
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "${container}")"
repository="localhost:${port}/test/markdown"

for _ in {1..30}; do
  if oras repo ls --plain-http "localhost:${port}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
oras repo ls --plain-http "localhost:${port}" >/dev/null

printf 'dummy subject\n' > "${temporary}/subject.txt"
(
  cd "${temporary}"
  oras push --plain-http "${repository}:subject" subject.txt:application/octet-stream >/dev/null
)
subject_digest="$(oras resolve --plain-http "${repository}:subject")"

source_dir="${temporary}/source"
mkdir -p "${source_dir}/project" "${source_dir}/plantuml" "${source_dir}/python"
printf 'dummy source\n' > "${source_dir}/project/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar"
printf 'dummy PlantUML source\n' > "${source_dir}/plantuml/plantuml-1.2026.6.tar"
printf 'dummy Python source\n' > "${source_dir}/python/dummy-1.0.tar.gz"
python3 - "${source_dir}/apk-inventory.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({
        "schema": 1,
        "inventories": [
            {"architecture": "amd64", "packages": []},
            {"architecture": "arm64", "packages": []},
        ],
        "selected": [],
    }, output)
PY
python3 "${ROOT}/scripts/source-artifact.py" index \
  --inventory "${source_dir}/apk-inventory.json" \
  --source-dir "${source_dir}" \
  --output "${source_dir}/source-index.json" \
  --policy "${ROOT}/compliance/source-artifact-policy.json" \
  --release v1.2.3 \
  --git aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image "${repository}@${subject_digest}" \
  --plantuml-version 1.2026.6 \
  --plantuml-commit 6287b33c5d1be2f7b0d480687d0b5a1accbd7971

artifact_digest="$(SOURCE_ARTIFACT_PLAIN_HTTP=true "${ROOT}/scripts/source-artifact.sh" \
  publish "${repository}" "${subject_digest}" v1.2.3 "${source_dir}")"
[[ "$(oras resolve --plain-http "${repository}:source-v1.2.3")" == "${artifact_digest}" ]]
[[ "$(oras resolve --plain-http "${repository}:source-sha256-${subject_digest#sha256:}")" == "${artifact_digest}" ]]
SOURCE_ARTIFACT_PLAIN_HTTP=true "${ROOT}/scripts/source-artifact.sh" verify-published \
  "${repository}" "${subject_digest}" v1.2.3 "${artifact_digest}"
