FROM busybox as builder
RUN wget https://sindresorhus.com/github-markdown-css/github-markdown.css
COPY wrap_end_1.html .
COPY wrap_end_2.html .
RUN cat wrap_end_1.html github-markdown.css wrap_end_2.html > /wrap_end.html

FROM python:3.9-alpine

ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static /tini
RUN chmod +rx /tini
ENTRYPOINT ["/tini", "--"]

RUN mkdir -p /app
WORKDIR /app

ENV PLANTUML_VERSION 1.2021.6
ADD https://oss.sonatype.org/content/repositories/releases/net/sourceforge/plantuml/plantuml/${PLANTUML_VERSION}/plantuml-${PLANTUML_VERSION}.jar /app/plantuml.jar

RUN apk add --no-cache \
    bash \
    html-xml-utils \
    graphviz \
    openjdk8-jre \
    ttf-droid \
    ttf-droid-nonlatin \
    && echo -e '#!/usr/bin/env sh \njava -jar /app/plantuml.jar "${@}"' >> /usr/local/bin/plantuml \
    && chmod +x /usr/local/bin/plantuml \
    && pip install \
    markdown \
    py-gfm \
    plantuml-markdown \
    six

COPY wrap_begin.html .
COPY --from=builder /wrap_end.html .
COPY md2html .

CMD ["./md2html"]

