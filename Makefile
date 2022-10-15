## Format and build the project.
default: fmt README.html fixture.html

## Build the README.html file from README.md.
README.html: image-id README.md
	docker run --rm -i "$(file < image-id)" < README.md > README.html

## Build the fixture.html file from fixture.md.
fixture.html: image-id fixture.md
	docker run --rm -i "$(file < image-id)" < fixture.md > fixture.html

## Build the Docker image.
image-id: Dockerfile md2html $(wildcard wrap_*.html)
	docker build -q . > image-id

## Reset image-id so it will NOT be rebuilt, but use the default image.
reset-image-id:
	git restore --stage image-id
	git restore image-id
	touch image-id

## Format README.md.
fmt:
	deno fmt README.md

.PHONY: default fmt reset-image-id
