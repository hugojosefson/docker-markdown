#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

for fixture in README fixture; do
  actual="$(mktemp)"
  trap 'rm -f "${actual}"' EXIT
  ./md2html.gh-api < "${fixture}.md" > "${actual}"
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
  mv "${actual}" "${fixture}.gh-api.html"
  trap - EXIT
done
