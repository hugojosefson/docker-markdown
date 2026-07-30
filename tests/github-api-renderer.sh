#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root

main() {
  cat "${root}/src/templates/wrap_begin.html"

  gh api \
    --method POST \
    --field "text=@-" \
    --field "mode=gfm" \
    -H "Accept: application/vnd.github+json" \
    /markdown

  cat "${root}/src/templates/wrap_end_1.html" "${root}/src/vendor/github-markdown.css" "${root}/src/templates/wrap_end_2.html"
}

main "$@"
