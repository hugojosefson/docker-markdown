FROM python:3.7-alpine

ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static /tini
RUN chmod +rx /tini
ENTRYPOINT ["/tini", "--"]

RUN mkdir -p /app
WORKDIR /app

ENV PLANTUML_VERSION 1.2019.8
ADD https://oss.sonatype.org/content/repositories/releases/net/sourceforge/plantuml/plantuml/${PLANTUML_VERSION}/plantuml-${PLANTUML_VERSION}.jar /app/plantuml.jar

RUN apk add --no-cache \
    bash \
    html-xml-utils \
    graphviz \
    openjdk8-jre \
    ttf-droid \
    ttf-droid-nonlatin \
    && echo -e '#!/usr/bin/env sh \njava -jar /app/plantuml.jar ${@}' >> /usr/local/bin/plantuml \
    && chmod +x /usr/local/bin/plantuml \
    && pip install \
    'Markdown<3' \
    py-gfm \
    plantuml-markdown

COPY wrap_end.html .
COPY wrap_begin.html .
COPY md2html .

CMD ["./md2html"]

