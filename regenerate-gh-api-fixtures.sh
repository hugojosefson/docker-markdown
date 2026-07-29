#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

for fixture in README fixture; do
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  ./md2html.gh-api < "${fixture}.md" > "${actual}"
  mv "${actual}" "${fixture}.gh-api.html"
  trap - EXIT
done
