#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
exec python3 "${script_dir}/update_css.py" "${@}"
