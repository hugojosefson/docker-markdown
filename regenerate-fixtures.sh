#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

image="docker.io/hugojosefson/markdown:latest"
for fixture in README fixture link-rewriting; do
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  if [[ "${fixture}" == "link-rewriting" ]]; then
    docker run --rm -i --user markdown --env LINK_README_TO_INDEX=true --env LINK_INDEX_TO_DIR=true --entrypoint /app/md2html "${image}" < "${fixture}.md" > "${actual}"
  else
    docker run --rm -i --user markdown --entrypoint /app/md2html "${image}" < "${fixture}.md" > "${actual}"
  fi
  mv "${actual}" "${fixture}.html"
  trap - EXIT
done
