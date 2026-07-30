#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
renderer_fixtures="${root}/tests/fixtures/renderer"
github_fixtures="${root}/tests/fixtures/github-api"
readonly renderer_fixtures github_fixtures

for fixture in README general; do
  input="${renderer_fixtures}/${fixture}.md"
  if [[ "${fixture}" == "README" ]]; then
    input="${root}/README.md"
  fi
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  "${root}/tests/github-api-renderer.sh" < "${input}" > "${actual}"
  python3 - "${actual}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
contents = path.read_text(encoding="utf-8")
contents = re.sub(
    r"(user-content-fn(?:ref)?-[0-9]+)-[0-9a-f]{32}",
    r"\1-fixture",
    contents,
)
path.write_text(contents, encoding="utf-8")
PY
  mv "${actual}" "${github_fixtures}/${fixture}.html"
  trap - EXIT
done
