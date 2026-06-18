# Образ для CI-джобов полигона: git + python(yaml) + docker-cli + curl/jq.
# Используется и для bootstrap, и для job'ов раннера (pull_policy if-not-present).
FROM docker:27-cli

RUN apk add --no-cache \
    bash \
    git \
    python3 \
    py3-yaml \
    curl \
    jq \
    coreutils

# git без интерактива
ENV GIT_TERMINAL_PROMPT=0
RUN git config --global user.email "ci@polygon.local" \
 && git config --global user.name "polygon-ci" \
 && git config --global init.defaultBranch master \
 && git config --global advice.detachedHead false

WORKDIR /work
