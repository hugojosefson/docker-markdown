# Source artifact retrieval

Each release source artifact uses
`application/vnd.hugojosefson.markdown.source.v1` and directly refers to the
published image index.

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
python3 source-verifier/source-artifact.py verify \
  --index source-vX.Y.Z/source-index.json --source-dir source-vX.Y.Z \
  --policy source-verifier/source-artifact-policy.json \
  --artifact-type application/vnd.hugojosefson.markdown.source.v1 \
  --release vX.Y.Z --subject "${image}@${subject}"
# Discover the direct referrer, pull it, and run the same strict verification:
./source-artifact.sh verify-published "${image}" "${subject}" vX.Y.Z "${artifact}"
```

The artifact has tags `source-vX.Y.Z` and `source-sha256-<64-hex-digest>`, but
verification uses immutable digests. `source-index.json` records the immutable
subject, inventories, files, checksums, sizes, and source mappings. Collection
happens after runtime publication, so source collection or attachment can fail
after the runtime image is visible. Each source archive or sdist is a separate
layer, allowing unchanged blobs to be reused across releases.
