# Corresponding source

Each release source artifact uses
`application/vnd.hugojosefson.markdown.source.v1` and directly refers to the
published image index.

## When to run source checks

Run the relevant checks below after changing image packages, dependency source
mappings, source selection policy, or source-artifact scripts and workflows.
Dependency version changes also require the
[dependency update checklist](dependencies.md#dependency-update-checklist).

## Inspect source inputs

Query both image platforms without downloading source files:

```bash
make source-inventory \
  SOURCE_IMAGE=docker.io/hugojosefson/markdown@sha256:<index-digest>
```

The input must be a published multi-platform index because a native local build
does not provide both platforms.

Validate a collection request without downloading sources:

```bash
./scripts/source-artifact.sh collect \
  docker.io/hugojosefson/markdown@sha256:<index-digest> \
  vX.Y.Z source-artifact --dry-run
```

## Test publication locally

Test OCI publication and verification against an ephemeral local registry:

```bash
make source-integration-test
```

This requires [Docker](https://www.docker.com/) and [ORAS](https://oras.land/).

## Test real source collection

Before releasing, run the real collection path against a temporary
multi-platform image on [Docker Hub](https://hub.docker.com/). Authenticate with
`docker login`, ensure the working tree is clean, then run:

```bash
make source-collection-test
```

The test creates a local `v0.0.0` tag for the duration of the command, pushes a
`source-test-<commit>` runtime image, and leaves the verified source under
`source-artifact-test/` for review. It does not publish a source OCI artifact.
Delete the temporary [Docker Hub](https://hub.docker.com/) tag after review.

Override defaults when needed:

```bash
SOURCE_TEST_RELEASE=v0.0.1 \
SOURCE_TEST_IMAGE=docker.io/hugojosefson/markdown \
SOURCE_TEST_OUTPUT="$PWD/source-artifact-test" \
make source-collection-test
```

## Release behavior

The release job attaches the source artifact to the published image index with
retention tags `source-vX.Y.Z` and `source-sha256-<64-hex-index-digest>`. Each
archive or sdist uses a separate OCI layer so unchanged blobs can be reused
across releases.

Source collection starts after runtime publication. A collection or attachment
error therefore fails the release job after the runtime image may already be
visible.

## Retrieve and verify a release

```bash
image=docker.io/hugojosefson/markdown
subject=sha256:<published-image-index-digest>
artifact=sha256:<source-artifact-digest-from-oras-discover>
oras discover "${image}@${subject}" \
  --artifact-type application/vnd.hugojosefson.markdown.source.v1 \
  --format json --depth 1
oras pull "${image}@${artifact}" --output source-vX.Y.Z
mkdir source-verifier
tar -xf source-vX.Y.Z/project/*.tar -C source-verifier
python3 source-verifier/scripts/source-artifact.py verify \
  --index source-vX.Y.Z/source-index.json --source-dir source-vX.Y.Z \
  --policy source-verifier/compliance/source-artifact-policy.json \
  --artifact-type application/vnd.hugojosefson.markdown.source.v1 \
  --release vX.Y.Z --subject "${image}@${subject}"
# Discover the direct referrer, pull it, and run the same strict verification:
./scripts/source-artifact.sh verify-published "${image}" "${subject}" vX.Y.Z "${artifact}"
```

Verification uses immutable digests. `source-index.json` records the immutable
subject, inventories, files, checksums, sizes, and source mappings.
