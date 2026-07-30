# syntax=docker/dockerfile:1
FROM docker.io/library/alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS plantuml

ARG PLANTUML_VERSION=1.2026.6
ARG PLANTUML_SHA256=89948f14c93756c7a3fb7b69078ff37e8489fd79dd430c582b931e2f65358690
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates curl \
    && curl --fail --location --show-error --silent \
      --output /plantuml.jar \
      "https://github.com/plantuml/plantuml/releases/download/v${PLANTUML_VERSION}/plantuml-${PLANTUML_VERSION}.jar" \
    && printf '%s  %s\n' "${PLANTUML_SHA256}" /plantuml.jar > /tmp/plantuml.sha256 \
    && sha256sum -c /tmp/plantuml.sha256 \
    && rm /tmp/plantuml.sha256

FROM docker.io/library/python:3.14-alpine@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 AS runtime

LABEL org.opencontainers.image.title="markdown" \
      org.opencontainers.image.description="Markdown-to-HTML renderer with PlantUML" \
      org.opencontainers.image.source="https://github.com/hugojosefson/docker-markdown" \
      org.opencontainers.image.url="https://hub.docker.com/r/hugojosefson/markdown"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app

# hadolint ignore=DL3018
RUN apk add --no-cache \
      bash=5.3.9-r1 \
      font-noto=2026.06.01-r0 \
      font-noto-cjk=0_git20220127-r1 \
      graphviz=12.2.1-r3 \
      html-xml-utils=8.7-r0 \
      openjdk21-jre=21.0.11_p10-r0 \
      tini=0.19.0-r3 \
    && addgroup -S markdown \
    && adduser -S -G markdown -h /app markdown

COPY requirements.txt .
RUN pip install --no-cache-dir --requirement requirements.txt

COPY --chown=markdown:markdown LICENSE /usr/share/licenses/markdown/LICENSE
COPY --chown=markdown:markdown THIRD_PARTY_NOTICES/ /usr/share/licenses/markdown/THIRD_PARTY_NOTICES/
COPY --chown=markdown:markdown SOURCE.md /usr/share/licenses/markdown/SOURCE.md
COPY --from=plantuml /plantuml.jar /app/plantuml.jar
COPY md2html wrap_begin.html wrap_end_1.html wrap_end_2.html github-markdown.css ./
RUN printf '%s\n' '#!/bin/sh' 'exec java -jar /app/plantuml.jar "$@"' > /usr/local/bin/plantuml \
    && chmod 0555 /usr/local/bin/plantuml md2html \
    && cat wrap_end_1.html github-markdown.css wrap_end_2.html > wrap_end.html \
    && chown -R markdown:markdown /app

FROM runtime AS fixture-test
COPY --chown=markdown:markdown test-fixtures.sh README.md README.html fixture.md fixture.html link-rewriting.md link-rewriting.html ./
USER markdown
RUN chmod 0555 test-fixtures.sh \
    && printf '%s\n' '@startuml' 'Alice -> Bob' '@enduml' > /tmp/smoke.puml \
    && plantuml -tpng /tmp/smoke.puml \
    && test -s /tmp/smoke.png \
    && rm /tmp/smoke.puml /tmp/smoke.png \
    && test -r /usr/share/licenses/markdown/LICENSE \
    && test -r /usr/share/licenses/markdown/SOURCE.md \
    && test -r /usr/share/licenses/markdown/THIRD_PARTY_NOTICES/PlantUML-1.2026.6-COPYING \
    && ./test-fixtures.sh \
    && touch /tmp/test-passed

FROM runtime AS final
# This dependency makes fixture verification execute in the default target.
COPY --from=fixture-test /tmp/test-passed /tmp/test-passed
USER markdown
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["./md2html"]
