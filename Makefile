IMAGE := docker.io/hugojosefson/markdown:latest

.DEFAULT_GOAL := test

## Build the local Docker image. Fixture tests run during this build.
build:
	docker build --tag "$(IMAGE)" .

## Build and run fixture tests. Diffs identify the mismatched fixture.
test: build

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

.PHONY: build test fixtures gh-api-fixtures update-css
