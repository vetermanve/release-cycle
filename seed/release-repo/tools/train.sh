#!/usr/bin/env bash
# Жизненный цикл поезда: depart (cut test-) и gate (pass -> release-/prod, fail -> stop).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

ACTION="${1:?action: depart|gate}"
DATE="${2:?date}"
GATE="${3:-}"

BTSET="${RELREPO_DIR}/trains/${DATE}/bt-set.yaml"
[ -f "$BTSET" ] || { echo "нет поезда ${DATE}"; exit 1; }

affected_names() {
  local lock="${RELREPO_DIR}/trains/${DATE}/affected-repos.lock"
  [ -f "$lock" ] && awk '{print $1}' "$lock" || true
}

commit_relrepo() {  # commit_relrepo "msg" <paths...>
  local msg="$1"; shift
  cd "${RELREPO_DIR}"
  git config user.email "ci@polygon.local"; git config user.name "polygon-ci"
  git add "$@" 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -q -m "${msg} [skip ci]"
    git push -q -o ci.skip "$(auth_url release-repo)" "HEAD:master"
    log "release-repo: ${msg}"
  fi
}

cut_branch() {  # cut_branch <from-branch> <to-branch>
  local from="$1" to="$2" name
  for name in $(affected_names); do
    local d; d="$(mktemp -d)"
    git clone -q "$(auth_url "$name")" "$d"
    if git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/${from}" >/dev/null; then
      git -C "$d" checkout -q -B "$to" "origin/${from}"
      git -C "$d" push -q -f "$(auth_url "$name")" "$to"
      log "  ${name}: ${to} <- ${from}"
    fi
  done
}

do_depart() {
  if [ -z "$(affected_names)" ]; then
    echo "поезд ${DATE} не собран на dev (нет affected-repos.lock). Сначала: make dev DATE=${DATE} BTS=..."
    exit 1
  fi
  python3 "${HERE}/cfg.py" set-status "$BTSET" departed
  commit_relrepo "ci(${DATE}): depart, status=departed" "trains/${DATE}/bt-set.yaml"
  cut_branch "dev-${DATE}" "test-${DATE}"
  bash "${HERE}/deploy_stand.sh" test "${DATE}"
  log "поезд ${DATE} отправлен на тест-стенд"
}

do_gate_fail() {
  python3 "${HERE}/cfg.py" set-status "$BTSET" stopped
  local pm="${RELREPO_DIR}/trains/${DATE}/postmortem.md"
  {
    echo "# Postmortem поезда ${DATE}"
    echo
    echo "- **Гейт:** FAILED (тест-стенд)"
    echo "- **Состав:** $(python3 "${HERE}/cfg.py" bts "$BTSET" | paste -sd, -)"
    echo
    echo "## Что разобрать"
    echo "- Почему синхронное тестирование на dev не отсекло дефект."
    echo "- Дефектный БТ выпадает из поезда, чинится в feature-ветке, едет следующим поездом."
    echo
    echo "Поезд остановлен и не реанимируется (stop-the-line)."
  } > "$pm"
  commit_relrepo "ci(${DATE}): STOP-THE-LINE, gate failed" "trains/${DATE}/bt-set.yaml" "trains/${DATE}/postmortem.md"
  log "поезд ${DATE} ОСТАНОВЛЕН (stop-the-line), postmortem записан"
}

do_gate_pass() {
  if [ -z "$(affected_names)" ]; then
    echo "поезд ${DATE} не собран. Сначала make dev / make test."
    exit 1
  fi
  # предпрод
  cut_branch "test-${DATE}" "release-${DATE}"
  bash "${HERE}/deploy_stand.sh" prepod "${DATE}"
  # прод: merge release- в master + тег
  local name
  for name in $(affected_names); do
    local d; d="$(mktemp -d)"
    git clone -q "$(auth_url "$name")" "$d"
    git -C "$d" config user.email "ci@polygon.local"; git -C "$d" config user.name "polygon-ci"
    if git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/release-${DATE}" >/dev/null; then
      git -C "$d" checkout -q master
      git -C "$d" merge --no-edit --no-ff "origin/release-${DATE}" >/dev/null
      git -C "$d" tag -f "shipped-${DATE}" >/dev/null
      git -C "$d" push -q "$(auth_url "$name")" master
      git -C "$d" push -q -f "$(auth_url "$name")" "shipped-${DATE}"
      log "  ${name}: release-${DATE} -> master, tag shipped-${DATE}"
    fi
  done
  bash "${HERE}/deploy_stand.sh" prod "${DATE}"
  python3 "${HERE}/cfg.py" set-status "$BTSET" shipped
  python3 "${HERE}/gen_release_page.py" "${RELREPO_DIR}" "${DATE}" \
    > "${RELREPO_DIR}/trains/${DATE}/release-page.md"
  commit_relrepo "ci(${DATE}): shipped to prod" "trains/${DATE}/bt-set.yaml" "trains/${DATE}/release-page.md"
  log "поезд ${DATE} установлен в прод"
}

case "$ACTION" in
  depart) do_depart;;
  gate)
    case "$GATE" in
      pass) do_gate_pass;;
      fail) do_gate_fail;;
      *) echo "gate result: pass|fail"; exit 1;;
    esac;;
  *) echo "action: depart|gate"; exit 1;;
esac
