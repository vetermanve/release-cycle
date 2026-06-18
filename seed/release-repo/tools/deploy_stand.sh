#!/usr/bin/env bash
# Deploy-симуляция: собрать webroot из веток репо, испечь nginx-образ stand-<env>:<date>,
# запустить контейнер на порту стенда. "Разливаем статику на разные docker-образы".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

ENV="${1:?env}"; DATE="${2:?date}"
BRANCH="$(branch_for "$ENV" "$DATE")"
PORT="$(port_for "$ENV")"

BTSET="${RELREPO_DIR}/trains/${DATE}/bt-set.yaml"
IDS_CSV=""
[ -f "$BTSET" ] && IDS_CSV="$(python3 "${HERE}/cfg.py" bts "$BTSET" | sort -n | paste -sd, -)"

work="$(mktemp -d)"; web="${work}/web"; mkdir -p "$web"

while IFS=$'\t' read -r name mount; do
  [ -n "$name" ] || continue
  local_src="${work}/src-${name}"
  git clone -q "$(auth_url "$name")" "$local_src"
  # ветка стенда, если есть в репо; иначе master (репо не затронут поездом)
  ref="master"
  if git -C "$local_src" rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null; then
    ref="origin/${BRANCH}"
  fi
  target="${web}"; [ -n "$mount" ] && target="${web}/${mount}"
  mkdir -p "$target"
  git -C "$local_src" archive --format=tar "$ref" | tar -x -C "$target"
  log "  ${ENV}: ${name} <- ${ref} -> /${mount}"
done < <(catalog_repos)

python3 "${HERE}/stand_assets.py" "$web" "$ENV" "$DATE" "$BRANCH" "${IDS_CSV}"

cat > "${work}/Dockerfile" <<'EOF'
FROM nginx:alpine
COPY . /usr/share/nginx/html
EOF

docker build -q -t "stand-${ENV}:${DATE}" -f "${work}/Dockerfile" "$web" >/dev/null
docker rm -f "stand-${ENV}" >/dev/null 2>&1 || true
# В сети полигона -> CI-контейнер видит по имени stand-<env>; -p -> хост видит по localhost:PORT.
docker run -d --label relcycle=stand --network "${NET}" \
  --name "stand-${ENV}" -p "${PORT}:80" "stand-${ENV}:${DATE}" >/dev/null
log "${ENV}-стенд: http://localhost:${PORT}  (ветка ${BRANCH}, БТ=${IDS_CSV:-нет})"
