#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_directory
exec python3 "${script_directory}/update_css.py" "${@}"
