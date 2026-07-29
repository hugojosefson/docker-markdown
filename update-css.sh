#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

version="5.9.0"
source_sha256="6112686f954db5d3806fb96116d2ab20ad3018469ab1015c587fd8efe7d25cf4"
vendored_sha256="e046acf945dc988fd66e6e90c3473f1812f723d4235517b3ebe64a678ce6c78d"
url="https://raw.githubusercontent.com/sindresorhus/github-markdown-css/v${version}/github-markdown.css"
download_temporary="$(mktemp)"
css_temporary="$(mktemp)"
version_temporary="$(mktemp)"
wrap_temporary="$(mktemp)"
trap 'rm -f "${download_temporary}" "${css_temporary}" "${version_temporary}" "${wrap_temporary}"' EXIT
curl --fail --location --show-error --silent --output "${download_temporary}" "${url}"
printf '%s  %s\n' "${source_sha256}" "${download_temporary}" | sha256sum -c -
# Drop only upstream's redundant blank line at EOF; CSS rules remain unchanged.
awk 'NR == 1 { previous = $0; next } { print previous; previous = $0 } END { if (previous != "") print previous }' "${download_temporary}" > "${css_temporary}"
printf '%s  %s\n' "${vendored_sha256}" "${css_temporary}" | sha256sum -c -
printf '%s\n' \
  "github-markdown-css: ${version}" \
  "source: ${url}" \
  "source-sha256: ${source_sha256}" \
  "vendored-sha256: ${vendored_sha256}" > "${version_temporary}"
cat wrap_end_1.html "${css_temporary}" wrap_end_2.html > "${wrap_temporary}"
mv "${css_temporary}" github-markdown.css
mv "${version_temporary}" github-markdown.css.version
mv "${wrap_temporary}" wrap_end.html
trap - EXIT
