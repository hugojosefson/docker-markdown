#!/usr/bin/env bash

set -euo pipefail
IFS=$'\t\n'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="${script_dir}/third-party-license-sources.tsv"
notices_only=false
dry_run=false

while [[ "${#}" -gt 0 ]]; do
  case "${1}" in
    --notices-only)
      notices_only=true
      ;;
    --dry-run)
      dry_run=true
      ;;
    --help)
      printf 'Usage: %s [--notices-only] [--dry-run] [OUTPUT_ROOT]\n' "${0}"
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "${1}" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
  shift
done

output_root="${1:-${script_dir}}"
if [[ "${#}" -gt 1 ]]; then
  printf 'Only one OUTPUT_ROOT may be specified.\n' >&2
  exit 2
fi

sha256_file() {
  local path="${1}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | cut -d ' ' -f 1
  else
    shasum -a 256 "${path}" | cut -d ' ' -f 1
  fi
}

refuse_symlink_target() {
  local root="${1}"
  local relative_path="${2}"
  local directory="${relative_path%/*}"
  local current="${root}"
  local part
  local -a parts

  if [[ "${directory}" != "${relative_path}" ]]; then
    IFS='/' read -r -a parts <<< "${directory}"
    for part in "${parts[@]}"; do
      current="${current}/${part}"
      if [[ -L "${current}" ]]; then
        printf 'Refusing symlinked destination directory: %s\n' "${current}" >&2
        return 1
      fi
    done
  fi

  if [[ -L "${root}/${relative_path}" ]]; then
    printf 'Refusing symlinked destination file: %s\n' \
      "${root}/${relative_path}" >&2
    return 1
  fi
}

while IFS=$'\t' read -r kind relative_path expected_sha256 url component; do
  if [[ -z "${kind}" || "${kind}" == \#* ]]; then
    continue
  fi
  if [[ "${notices_only}" == true && "${kind}" == "source" ]]; then
    continue
  fi
  if [[ "${kind}" != "notice" && "${kind}" != "source" ]]; then
    printf 'Unknown manifest kind: %s\n' "${kind}" >&2
    exit 1
  fi
  if [[ -z "${relative_path}" || "${relative_path}" == */ ||
    "${relative_path}" == *//* ||
    ! "${expected_sha256}" =~ ^[0-9a-f]{64}$ ||
    "${url}" != https://* || -z "${component}" ]]; then
    printf 'Malformed manifest row for: %s\n' "${relative_path}" >&2
    exit 1
  fi
  if [[ "${relative_path}" == /* || "${relative_path}" == ".." ||
    "${relative_path}" == ../* || "${relative_path}" == */../* ||
    "${relative_path}" == */.. ]]; then
    printf 'Unsafe destination in manifest: %s\n' "${relative_path}" >&2
    exit 1
  fi

  target="${output_root}/${relative_path}"
  if [[ "${dry_run}" == true ]]; then
    printf '%s\t%s\t%s\n' "${component}" "${target}" "${url}"
    continue
  fi

  if ! refuse_symlink_target "${output_root}" "${relative_path}"; then
    exit 1
  fi

  if [[ -e "${target}" ]]; then
    actual_sha256="$(sha256_file "${target}")"
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
      printf 'Refusing to overwrite modified file: %s\n' "${target}" >&2
      exit 1
    fi
    printf 'Verified existing %s\n' "${relative_path}"
    continue
  fi

  mkdir -p "$(dirname -- "${target}")"
  temporary="$(mktemp "${target}.tmp.XXXXXX")"
  trap 'rm -f "${temporary}"' EXIT
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --show-error --silent --output "${temporary}" "${url}"
  actual_sha256="$(sha256_file "${temporary}")"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    printf 'Checksum mismatch for %s: expected %s, got %s\n' \
      "${component}" "${expected_sha256}" "${actual_sha256}" >&2
    exit 1
  fi
  chmod 0644 "${temporary}"
  mv "${temporary}" "${target}"
  trap - EXIT
  printf 'Downloaded %s\n' "${relative_path}"
done < "${manifest}"
