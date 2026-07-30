#!/usr/bin/env bash
# Create, inspect, publish, and verify OCI corresponding-source artifacts.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly HELPER="${ROOT}/scripts/source-artifact.py"
readonly POLICY="${ROOT}/compliance/source-artifact-policy.json"
readonly ARTIFACT_TYPE="application/vnd.hugojosefson.markdown.source.v1"
ORAS_FLAGS=()
case "${SOURCE_ARTIFACT_PLAIN_HTTP:-false}" in
  false) ;;
  true) ORAS_FLAGS+=(--plain-http) ;;
  *) printf 'source-artifact: SOURCE_ARTIFACT_PLAIN_HTTP must be true or false\n' >&2; exit 1 ;;
esac
readonly -a ORAS_FLAGS

die() { printf 'source-artifact: %s\n' "${*}" >&2; exit 1; }
require() { command -v "${1}" >/dev/null || die "missing command: ${1}"; }
semantic_tag() { [[ "${1}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release must match vX.Y.Z"; }
digest() { [[ "${1}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest must be sha256:<64 lowercase hex characters>"; }
subject() { [[ "${1}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || die "image must be IMAGE@sha256:<64 lowercase hex characters>"; }
policy() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "${POLICY}" "${1}"; }

platform_reference() (
  local image="${1}" wanted="${2}" temporary architecture platform_digest selected=""
  require docker; require python3; subject "${image}"
  temporary="$(mktemp)"
  trap 'rm -f "${temporary}"' EXIT
  docker buildx imagetools inspect --raw "${image}" > "${temporary}"
  while IFS=$'\t' read -r architecture platform_digest; do
    if [[ "${architecture}" == "${wanted}" ]]; then selected="${platform_digest}"; fi
  done < <(python3 "${HELPER}" platforms --input "${temporary}")
  [[ -n "${selected}" ]] || die "image lacks linux/${wanted}: ${image}"
  printf '%s@%s\n' "${image%@*}" "${selected}"
)

inventory() (
  local image="${1}" output="${2}" architecture="${3}" raw temporary
  require docker; require python3; subject "${image}"
  temporary="$(mktemp -d)"
  trap 'rm -rf "${temporary}"' EXIT
  raw="${temporary}/apk-inventory.json"
  if [[ -n "${SOURCE_ARTIFACT_BUILDER:-}" ]]; then
    mkdir -p "${temporary}/context"
    printf '%s\n' \
      '# syntax=docker/dockerfile:1' \
      'ARG SOURCE_IMAGE=scratch' \
      "FROM \${SOURCE_IMAGE} AS inventory" \
      "RUN apk query --from installed --fields name,version,arch,license,origin,commit --format json '*' > /tmp/apk-inventory.json" \
      'FROM scratch' \
      'COPY --from=inventory /tmp/apk-inventory.json /apk-inventory.json' \
      > "${temporary}/context/Dockerfile"
    docker buildx build \
      --builder "${SOURCE_ARTIFACT_BUILDER}" \
      --platform "linux/${architecture}" \
      --build-arg "SOURCE_IMAGE=${image}" \
      --output "type=local,dest=${temporary}/output" \
      "${temporary}/context"
    raw="${temporary}/output/apk-inventory.json"
    [[ -f "${raw}" ]] || die "buildx inventory did not produce output for ${architecture}"
  else
    docker run --rm --platform "linux/${architecture}" --entrypoint /sbin/apk "${image}" \
      query --from installed --fields name,version,arch,license,origin,commit --format json '*' > "${raw}"
  fi
  python3 "${HELPER}" normalize --architecture "${architecture}" --input "${raw}" --output "${output}"
)

inventory_both() (
  local image="${1}" output="${2}" temporary repository platform architecture platform_digest
  local -a platforms
  require docker; require python3
  subject "${image}"
  [[ ! -e "${output}" ]] || die "output exists: ${output}"
  temporary="$(mktemp -d)"
  trap 'rm -rf "${temporary}"' EXIT
  docker buildx imagetools inspect --raw "${image}" > "${temporary}/index.json"
  mapfile -t platforms < <(python3 "${HELPER}" platforms --input "${temporary}/index.json")
  [[ "${#platforms[@]}" -eq 2 ]] || die "failed to resolve two image platforms"
  repository="${image%@*}"
  for platform in "${platforms[@]}"; do
    IFS=$'\t' read -r architecture platform_digest <<< "${platform}"
    inventory "${repository}@${platform_digest}" "${temporary}/${architecture}.json" "${architecture}"
  done
  python3 "${HELPER}" merge --policy "${POLICY}" \
    --input "${temporary}/amd64.json" "${temporary}/arm64.json" --output "${output}"
)

collect_into() {
  local image="${1}" release="${2}" output="${3}" git_revision alpine aports plantuml_version plantuml_commit python_image expected_python origin commit package_path staging origins
  git_revision="$(git -C "${ROOT}" rev-parse HEAD)"
  [[ "$(git -C "${ROOT}" rev-parse "refs/tags/${release}^{commit}")" == "${git_revision}" ]] \
    || die "release tag ${release} does not resolve to HEAD"
  alpine="$(platform_reference "$(policy alpineImage)" amd64)"; aports="$(policy aportsRepository)"
  plantuml_commit="$(policy plantumlCommit)"; python_image="$(platform_reference "$(policy pythonImage)" amd64)"; expected_python="$(policy expectedPythonRequirements)"
  plantuml_version="$(python3 -c 'import re,sys; match=re.search(r"ARG PLANTUML_VERSION=([^\\n]+)", open(sys.argv[1], encoding="utf-8").read()); print(match.group(1) if match else "")' "${ROOT}/Dockerfile")"
  [[ -n "${plantuml_version}" ]] || die "Dockerfile lacks PLANTUML_VERSION"
  inventory_both "${image}" "${output}/apk-inventory.json"
  git clone --filter=blob:none --no-checkout "${aports}" "${output}/.aports"
  mkdir -p "${output}/alpine"
  origins="${output}/.origins"
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); print("\n".join("%s\t%s" % pair for pair in sorted({(item["origin"], item["commit"]) for item in data["selected"]})))' "${output}/apk-inventory.json" > "${origins}"
  while IFS=$'\t' read -r origin commit; do
    package_path="$(git -C "${output}/.aports" ls-tree -r --name-only "${commit}" | python3 -c 'import sys; origin=sys.argv[1]; matches=[line.rsplit("/", 1)[0] for line in sys.stdin.read().splitlines() if line.endswith("/APKBUILD") and line.rsplit("/", 2)[-2] == origin]; print(matches[0] if len(matches) == 1 else "")' "${origin}")"
    [[ -n "${package_path}" ]] || die "cannot locate aports directory for ${origin} at ${commit}"
    staging="${output}/.stage-${origin}-${commit}"
    mkdir -p "${staging}/aports/${origin}/${commit}" "${staging}/distfiles/${origin}/${commit}"
    git -C "${output}/.aports" archive --format=tar "${commit}:${package_path}" | tar -x -C "${staging}/aports/${origin}/${commit}"
    docker run --rm --platform linux/amd64 \
      --mount "type=bind,src=${staging},dst=/work" -w /work "${alpine}" sh -ec \
      'apk add --no-cache abuild >/dev/null; adduser -D collector; chown -R collector:collector /work; su collector -s /bin/sh -c "cd /work/aports/$1/$2 && SRCDEST=/work/distfiles/$1/$2 abuild fetch" sh "$1" "$2"' sh "${origin}" "${commit}"
    python3 "${HELPER}" archive --source-dir "${staging}" --output "${output}/alpine/${origin}-${commit}.tar"
    rm -rf "${staging}"
  done < "${origins}"
  rm -f "${origins}"
  rm -rf "${output}/.aports"
  mkdir -p "${output}/python"
  docker run --rm --platform linux/amd64 \
    -v "${ROOT}:/project:ro" -v "${output}/python:/output" "${python_image}" \
    sh -ec 'pip download --no-deps --no-binary=:all: --requirement /project/requirements.txt --dest /output'
  local -a sdists=("${output}/python/"*)
  [[ "${#sdists[@]}" -eq "${expected_python}" ]] || die "expected ${expected_python} Python sdists, found ${#sdists[@]}"
  for staging in "${sdists[@]}"; do [[ -f "${staging}" && ! -L "${staging}" ]] || die "Python download is not a regular sdist"; done
  mkdir -p "${output}/plantuml" "${output}/project"
  git clone --filter=blob:none --depth 1 --branch "v${plantuml_version}" --no-checkout \
    "$(policy plantumlRepository)" "${output}/.plantuml"
  [[ "$(git -C "${output}/.plantuml" rev-parse "v${plantuml_version}^{commit}")" == "${plantuml_commit}" ]] || die "PlantUML v${plantuml_version} does not resolve to policy commit"
  git -C "${output}/.plantuml" archive --format=tar "${plantuml_commit}" > "${output}/plantuml/plantuml-${plantuml_version}.tar"
  rm -rf "${output}/.plantuml"
  git -C "${ROOT}" archive --format=tar "${git_revision}" > "${output}/project/${git_revision}.tar"
  python3 "${HELPER}" index --inventory "${output}/apk-inventory.json" \
    --source-dir "${output}" --output "${output}/source-index.json" --policy "${POLICY}" \
    --release "${release}" --git "${git_revision}" --image "${image}" \
    --plantuml-version "${plantuml_version}" --plantuml-commit "${plantuml_commit}"
}

collect() (
  local image="${1}" release="${2}" output="${3}" dry_run="${4:-}" parent base temporary
  semantic_tag "${release}"; subject "${image}"
  [[ ! -e "${output}" ]] || die "output exists: ${output}"
  if [[ -n "${dry_run}" ]]; then
    [[ "${dry_run}" == "--dry-run" ]] || die "unknown collect option: ${dry_run}"
    printf 'would collect amd64 and arm64 from %s into %s\n' "${image}" "${output}"
    return
  fi
  require docker; require git; require tar; require python3
  parent="$(dirname -- "${output}")"; base="$(basename -- "${output}")"
  [[ -d "${parent}" ]] || die "output parent does not exist: ${parent}"
  temporary="$(mktemp -d "${parent}/.${base}.tmp.XXXXXX")"
  trap 'rm -rf "${temporary}"' EXIT
  collect_into "${image}" "${release}" "${temporary}"
  mv "${temporary}" "${output}"
  trap - EXIT
)

publish() {
  local image="${1}" subject_digest="${2}" release="${3}" source_dir="${4}" result artifact digest_tag
  semantic_tag "${release}"; digest "${subject_digest}"; require oras; require python3
  [[ -f "${source_dir}/source-index.json" ]] || die "missing source-index.json"
  python3 "${HELPER}" verify --index "${source_dir}/source-index.json" \
    --source-dir "${source_dir}" --policy "${POLICY}" --artifact-type "${ARTIFACT_TYPE}" \
    --release "${release}" --subject "${image}@${subject_digest}"
  local -a files=() paths=()
  mapfile -t paths < <(python3 -c 'import json,sys; print("\n".join(item["path"] for item in json.load(open(sys.argv[1], encoding="utf-8"))["sources"]))' "${source_dir}/source-index.json")
  for path in "${paths[@]}"; do
    [[ -f "${source_dir}/${path}" && ! -L "${source_dir}/${path}" ]] || die "unsafe source file: ${path}"
    files+=("${path}:application/octet-stream")
  done
  [[ "${#files[@]}" -gt 0 ]] || die "source directory has no files"
  result="$(cd "${source_dir}" && oras attach "${ORAS_FLAGS[@]}" --format json \
    --artifact-type "${ARTIFACT_TYPE}" "${image}@${subject_digest}" \
    "${files[@]}" "source-index.json:application/json")"
  artifact="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])' <<< "${result}")"; digest "${artifact}"
  digest_tag="${subject_digest#sha256:}"
  oras tag "${ORAS_FLAGS[@]}" "${image}@${artifact}" \
    "source-${release}" "source-sha256-${digest_tag}" >/dev/null
  printf '%s\n' "${artifact}"
}

verify_published() (
  local image="${1}" subject_digest="${2}" release="${3}" artifact="${4}" temporary discovered index
  semantic_tag "${release}"; digest "${subject_digest}"; digest "${artifact}"; require oras; require python3
  temporary="$(mktemp -d)"
  trap 'rm -rf "${temporary}"' EXIT
  discovered="$(oras discover "${ORAS_FLAGS[@]}" --format json --depth 1 \
    "${image}@${subject_digest}" --artifact-type "${ARTIFACT_TYPE}")"
  python3 -c 'import json,sys; wanted=sys.argv[1]; data=json.load(sys.stdin); refs=data.get("manifests", data.get("referrers", data.get("references", []))); raise SystemExit(0 if any(item.get("digest") == wanted for item in refs if isinstance(item, dict)) else "expected artifact is not a direct referrer")' "${artifact}" <<< "${discovered}"
  oras pull "${ORAS_FLAGS[@]}" "${image}@${artifact}" --output "${temporary}"
  index="${temporary}/source-index.json"
  [[ -f "${index}" && ! -L "${index}" ]] || die "ORAS pull lacks source-index.json at artifact root"
  python3 "${HELPER}" verify --index "${index}" --source-dir "${temporary}" \
    --policy "${POLICY}" --artifact-type "${ARTIFACT_TYPE}" --release "${release}" \
    --subject "${image}@${subject_digest}"
)

case "${1:-}" in
  inventory) [[ "${#}" -eq 3 ]] || die 'usage: inventory IMAGE@sha256:DIGEST OUTPUT'; inventory_both "${2}" "${3}" ;;
  collect) [[ "${#}" -ge 4 && "${#}" -le 5 ]] || die 'usage: collect IMAGE@sha256:DIGEST vX.Y.Z OUTPUT [--dry-run]'; collect "${2}" "${3}" "${4}" "${5:-}" ;;
  publish) [[ "${#}" -eq 5 ]] || die 'usage: publish IMAGE SUBJECT_DIGEST vX.Y.Z SOURCE_DIR'; publish "${2}" "${3}" "${4}" "${5}" ;;
  verify-published) [[ "${#}" -eq 5 ]] || die 'usage: verify-published IMAGE SUBJECT_DIGEST vX.Y.Z ARTIFACT_DIGEST'; verify_published "${2}" "${3}" "${4}" "${5}" ;;
  *) die 'usage: inventory|collect|publish|verify-published' ;;
esac
