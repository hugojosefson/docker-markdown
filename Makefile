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
	./scripts/regenerate-fixtures.sh
	docker build --tag "$(IMAGE)" .

## Regenerate GitHub Markdown API comparison fixtures using existing gh auth.
gh-api-fixtures:
	./scripts/regenerate-gh-api-fixtures.sh

## Discover and vendor the latest stable github-markdown-css release.
update-css:
	./scripts/update-css.sh
	$(MAKE) fixtures
	$(MAKE) gh-api-fixtures

## Run the GitHub CI workflow locally; requires Docker, act, gh authentication, and its token scope.
ci-local:
	@act --version | python3 -c 'import re, sys; match = re.search(r"([0-9]+)\.([0-9]+)\.([0-9]+)", sys.stdin.read()); valid = match and tuple(map(int, match.groups())) >= (0, 2, 86); sys.exit(0 if valid else "act 0.2.86 or newer is required")'
	@GITHUB_TOKEN="$$(gh auth token)" act --secret GITHUB_TOKEN --workflows .github/workflows/ci.yml

## Query a published immutable multi-platform image without downloading sources.
source-inventory:
	@test -n "$(SOURCE_IMAGE)" || { printf '%s\n' 'Set SOURCE_IMAGE=IMAGE@sha256:DIGEST; a native local build cannot supply both platforms.' >&2; exit 1; }
	./scripts/source-artifact.sh inventory "$(SOURCE_IMAGE)" source-inventory.json

## Test source artifact metadata parsing and canonicalization; no source artifacts are created.
source-test:
	python3 -m unittest discover --start-directory tests --pattern 'test_*.py'

## Test ORAS publication and verification against an ephemeral local registry.
source-integration-test:
	bash tests/test_oras_integration.sh

## Build a temporary published image and collect its real corresponding sources.
source-collection-test:
	./scripts/test-source-collection.sh

.PHONY: build test fixtures gh-api-fixtures update-css ci-local source-inventory source-test source-integration-test source-collection-test
