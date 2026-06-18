#!/usr/bin/env bash
# Общие хелперы для CI-скриптов полигона. source-ить из reconcile/train/deploy.
set -euo pipefail

GL="${GITLAB_INTERNAL_URL:-http://gitlab:8929}"
TOK="${GITLAB_TOKEN:?GITLAB_TOKEN не задан}"
GL_HOST="${GL#http://}"; GL_HOST="${GL_HOST#https://}"   # gitlab:8929

# Каталог tools (этот файл лежит в нём)
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Корень чекаута release-repo
RELREPO_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"

CATALOG="${RELREPO_DIR}/catalog/repos.yaml"
GROUP="$(python3 "${TOOLS_DIR}/cfg.py" repos "${CATALOG}" | head -1)"

# git-url с токеном для push/clone по http
auth_url() {  # auth_url <repo-name>
  echo "http://oauth2:${TOK}@${GL_HOST}/${GROUP}/$1.git"
}

api() {  # api <method> <path> [curl-args...]
  local method="$1" path="$2"; shift 2
  curl -sS --fail-with-body -X "$method" \
    -H "PRIVATE-TOKEN: ${TOK}" \
    "${GL}/api/v4${path}" "$@"
}

# Список репо из каталога: строки "name<TAB>mount"
catalog_repos() { python3 "${TOOLS_DIR}/cfg.py" repos "${CATALOG}" | tail -n +2; }

# сеть для стенд-контейнеров (group CI-var NETWORK)
NET="${NETWORK:-relcycle_gitlabnet}"

port_for() {  # port_for <env> (порты из group CI-vars STAND_*_PORT)
  case "$1" in
    dev) echo "${STAND_DEV_PORT:-8081}";;
    test) echo "${STAND_TEST_PORT:-8082}";;
    prepod) echo "${STAND_PREPOD_PORT:-8083}";;
    prod) echo "${STAND_PROD_PORT:-8084}";;
    *) echo "unknown env: $1" >&2; return 1;;
  esac
}

branch_for() {  # branch_for <env> <date>
  case "$1" in
    dev) echo "dev-$2";; test) echo "test-$2";; prepod) echo "release-$2";; prod) echo "master";;
    *) echo "unknown env: $1" >&2; return 1;;
  esac
}

now_utc() { date -u +%FT%TZ; }

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
