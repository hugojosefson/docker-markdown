#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
fixtures="${root}/tests/fixtures/renderer"
readonly fixtures
image="docker.io/hugojosefson/markdown:latest"
for fixture in README general link-rewriting; do
  input="${fixtures}/${fixture}.md"
  if [[ "${fixture}" == "README" ]]; then
    input="${root}/README.md"
  fi
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  if [[ "${fixture}" == "link-rewriting" ]]; then
    docker run --rm -i --user markdown --env LINK_README_TO_INDEX=true --env LINK_INDEX_TO_DIR=true --entrypoint /app/src/md2html "${image}" < "${input}" > "${actual}"
  else
    docker run --rm -i --user markdown --entrypoint /app/src/md2html "${image}" < "${input}" > "${actual}"
  fi
  mv "${actual}" "${fixtures}/${fixture}.html"
  trap - EXIT
done
