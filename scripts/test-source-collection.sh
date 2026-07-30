#!/usr/bin/env bash
# Build a temporary multi-platform image and collect its corresponding sources.
set -euo pipefail
IFS=$'\t\n'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root

release="${SOURCE_TEST_RELEASE:-v0.0.0}"
image="${SOURCE_TEST_IMAGE:-docker.io/hugojosefson/markdown}"
output="${SOURCE_TEST_OUTPUT:-${root}/source-artifact-test}"
dry_run=false
if [[ "${output}" != /* ]]; then
  output="${root}/${output}"
fi

case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) printf 'Usage: %s [--dry-run]\n' "${0}" >&2; exit 2 ;;
esac
[[ "${#}" -le 1 ]] || { printf 'Usage: %s [--dry-run]\n' "${0}" >&2; exit 2; }

require() {
  command -v "${1}" >/dev/null || {
    printf 'Missing command: %s\n' "${1}" >&2
    exit 1
  }
}

discover_builder() {
  docker buildx ls --format json | python3 -c '
import json
import sys

candidate = ""
requested = sys.argv[1]
for line in sys.stdin:
    builder = json.loads(line)
    platforms = {
        platform.rstrip("*")
        for node in builder.get("Nodes", [])
        for platform in node.get("Platforms", [])
    }
    if (
        not candidate
        and (not requested or builder.get("Name") == requested)
        and builder.get("Driver") != "docker"
        and {"linux/amd64", "linux/arm64"} <= platforms
    ):
        candidate = builder["Name"]
print(candidate)
' "${1}"
}

for command in docker git python3; do
  require "${command}"
done

[[ "${release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'SOURCE_TEST_RELEASE must match vX.Y.Z; got %s\n' "${release}" >&2
  exit 1
}
[[ "${image}" != *@* && "${image}" != *[[:space:]]* && "${image##*/}" != *:* ]] || {
  printf 'SOURCE_TEST_IMAGE must be an untagged image repository; got %s\n' "${image}" >&2
  exit 1
}
! git -C "${root}" show-ref --verify --quiet "refs/tags/${release}" || {
  printf 'Temporary release tag already exists: %s\n' "${release}" >&2
  exit 1
}
[[ ! -e "${output}" ]] || {
  printf 'Source output already exists: %s\n' "${output}" >&2
  exit 1
}
[[ -d "$(dirname -- "${output}")" ]] || {
  printf 'Source output parent does not exist: %s\n' "$(dirname -- "${output}")" >&2
  exit 1
}

revision="$(git -C "${root}" rev-parse --short=12 HEAD)"
runtime_tag="source-test-${revision}"
runtime_reference="${image}:${runtime_tag}"
builder="$(discover_builder "${SOURCE_TEST_BUILDER:-}")"
[[ -n "${builder}" ]] || {
  if [[ -n "${SOURCE_TEST_BUILDER:-}" ]]; then
    printf '%s: %s\n' \
      'SOURCE_TEST_BUILDER is not a non-docker builder advertising linux/amd64 and linux/arm64' \
      "${SOURCE_TEST_BUILDER}" >&2
  else
    printf 'No non-docker buildx builder advertises linux/amd64 and linux/arm64.\n' >&2
  fi
  printf 'Create one with multi-platform support or set SOURCE_TEST_BUILDER.\n' >&2
  exit 1
}

if [[ "${dry_run}" == true ]]; then
  printf 'Would create local tag: %s\n' "${release}"
  printf 'Would use buildx builder: %s\n' "${builder}"
  printf 'Would push temporary image: %s\n' "${runtime_reference}"
  printf 'Would collect sources into: %s\n' "${output}"
  exit 0
fi

[[ -z "$(git -C "${root}" status --porcelain)" ]] || {
  printf 'Working tree must be clean.\n' >&2
  exit 1
}

git -C "${root}" tag "${release}" HEAD
runtime_pushed=false
collection_verified=false
cleanup() {
  git -C "${root}" tag --delete "${release}" >/dev/null 2>&1 || true
  if [[ "${runtime_pushed}" == true && "${collection_verified}" == false ]]; then
    printf 'Temporary runtime image remains after failure: %s\n' "${runtime_reference}" >&2
    printf 'Delete that tag from Docker Hub after investigation.\n' >&2
  fi
}
trap cleanup EXIT

docker buildx build \
  --builder "${builder}" \
  --platform linux/amd64,linux/arm64 \
  --provenance=false \
  --tag "${runtime_reference}" \
  --push \
  "${root}"
runtime_pushed=true

subject_digest="$(
  docker buildx imagetools inspect "${runtime_reference}" \
    --format '{{json .Manifest}}' |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["digest"])'
)"

SOURCE_ARTIFACT_BUILDER="${builder}" "${root}/scripts/source-artifact.sh" collect \
  "${image}@${subject_digest}" \
  "${release}" \
  "${output}"

python3 "${root}/scripts/source-artifact.py" verify \
  --index "${output}/source-index.json" \
  --source-dir "${output}" \
  --policy "${root}/compliance/source-artifact-policy.json" \
  --artifact-type application/vnd.hugojosefson.markdown.source.v1 \
  --release "${release}" \
  --subject "${image}@${subject_digest}"

collection_verified=true
printf 'Source collection verified: %s\n' "${output}"
printf 'Temporary runtime image remains for review: %s\n' "${runtime_reference}"
printf 'Delete that tag from Docker Hub after review.\n'
