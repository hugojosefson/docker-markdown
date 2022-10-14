## Format and build the project.
default: fmt README.html

## Build the README.html file from README.md.
README.html: image-id README.md
	docker run --rm -i "$(file < image-id)" < README.md > README.html

## Build the Docker image.
image-id: Dockerfile md2html $(wildcard wrap_*.html)
	docker build -q . > image-id

## Reset image-id so it will NOT be rebuilt, but use the default image.
reset-image-id:
	git restore --stage image-id
	git restore image-id
	touch image-id

## Format markdown files.
fmt:
	deno fmt $(wildcard *.md)

.PHONY: default fmt reset-image-id
