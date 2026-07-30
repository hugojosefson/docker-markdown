IMAGE := docker.io/hugojosefson/markdown:latest

.DEFAULT_GOAL := test

## Build the local Docker image. Fixture tests run during this build.
build:
	docker build --tag "$(IMAGE)" .

## Build and run fixture tests plus source-artifact unit tests.
test: build source-test

## Regenerate fixtures with the pre-test runtime, then verify the final image.
fixtures:
	docker build --target runtime --tag "$(IMAGE)" .
	./regenerate-fixtures.sh
	docker build --tag "$(IMAGE)" .

## Regenerate GitHub Markdown API comparison fixtures using existing gh auth.
gh-api-fixtures:
	./regenerate-gh-api-fixtures.sh

## Vendor github-markdown-css v5.9.0 from its immutable Git tag.
update-css:
	./update-css.sh

## Query a published immutable multi-platform image without downloading sources.
source-inventory:
	@test -n "$(SOURCE_IMAGE)" || { printf '%s\n' 'Set SOURCE_IMAGE=IMAGE@sha256:DIGEST; a native local build cannot supply both platforms.' >&2; exit 1; }
	./source-artifact.sh inventory "$(SOURCE_IMAGE)" source-inventory.json

## Test source artifact metadata parsing and canonicalization; no source artifacts are created.
source-test:
	python3 -m unittest discover --start-directory tests --pattern 'test_*.py'

## Test ORAS publication and verification against an ephemeral local registry.
source-integration-test:
	bash tests/test_oras_integration.sh

.PHONY: build test fixtures gh-api-fixtures update-css source-inventory source-test source-integration-test
