#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

for fixture in README fixture link-rewriting; do
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  if [[ "${fixture}" == "link-rewriting" ]]; then
    LINK_README_TO_INDEX=true LINK_INDEX_TO_DIR=true ./md2html < "${fixture}.md" > "${actual}"
  else
    ./md2html < "${fixture}.md" > "${actual}"
  fi
  if ! grep -Fq '<body class="markdown-body">' "${actual}" || grep -Fq '<article class="markdown-body">' "${actual}"; then
    printf 'Fixture failed: markdown-body must be applied to body, not article.\n' >&2
    exit 1
  fi
  if [[ "${fixture}" == "README" ]]; then
    if ! grep -Eq 'src="data:image/png;base64,[^"]+"' "${actual}" ||
      ! grep -Fq '<svg ' "${actual}" ||
      ! grep -Fq '|Alice|' "${actual}"; then
      printf 'Fixture failed: PlantUML PNG, inline SVG, and text output must be non-empty.\n' >&2
      exit 1
    fi
  fi
  if [[ "${fixture}" == "fixture" ]]; then
    if ! grep -Fq '<del>Scratch this.</del>' "${actual}" ||
      ! grep -Fq '<a href="https://github.com/sindresorhus/generate-github-markdown-css/' "${actual}"; then
      printf 'Fixture failed: GFM strikethrough and automatic links must render.\n' >&2
      exit 1
    fi
  fi
  if ! diff -u "${fixture}.html" "${actual}"; then
    printf 'Fixture failed: %s.md differs from %s.html. Run make fixtures to accept the renderer output.\n' "${fixture}" "${fixture}" >&2
    exit 1
  fi
  rm -f "${actual}"
  trap - EXIT
done
