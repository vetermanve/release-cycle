#!/usr/bin/env bash
# GitOps-промоушн по stands.yaml: для каждого слота довести ветку и задеплоить стенд.
# Идемпотентно. Запускается CI на изменение stands.yaml.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

STANDS_DIR="${RELREPO_DIR}/stands"

# Binding по файлу на стенд: stands/<slot> содержит дату поезда (или пусто).
slot_date() { tr -d '[:space:]' < "${STANDS_DIR}/$1" 2>/dev/null || true; }

affected_names() {  # <date>
  local lock="${RELREPO_DIR}/trains/$1/affected-repos.lock"
  [ -f "$lock" ] && awk '{print $1}' "$lock" || true
}

# обновить status в bt-set без ретриггера пайплайнов ([skip ci])
set_status() {  # <date> <status>
  python3 "${HERE}/cfg.py" set-status "${RELREPO_DIR}/trains/$1/bt-set.yaml" "$2"
  ( cd "$RELREPO_DIR"
    git config user.email ci@polygon.local; git config user.name polygon-ci
    git add "trains/$1/bt-set.yaml"
    if ! git diff --cached --quiet; then
      git commit -q -m "ci($1): status=$2 [skip ci]"
      git push -q -o ci.skip "$(auth_url release-repo)" HEAD:master
    fi
  )
}

ensure_cut() {  # <repo> <from-branch> <to-branch>  (идемпотентно)
  local name="$1" from="$2" to="$3" d
  d="$(mktemp -d)"; git clone -q "$(auth_url "$name")" "$d"
  git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/${to}" >/dev/null && return 0
  if git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/${from}" >/dev/null; then
    git -C "$d" checkout -q -B "$to" "origin/${from}"
    git -C "$d" push -q -f "$(auth_url "$name")" "$to"
    log "  ${name}: ${to} <- ${from}"
  fi
}

promote_test() {  # <date>
  local date="$1" n
  [ -n "$(affected_names "$date")" ] || { log "поезд ${date} не собран на dev, пропуск test"; return 0; }
  for n in $(affected_names "$date"); do ensure_cut "$n" "dev-${date}" "test-${date}"; done
  bash "${HERE}/deploy_stand.sh" test "${date}"
  set_status "$date" departed
  log "тест-стенд: поезд ${date}"
}

promote_prepod() {  # <date>
  local date="$1" n
  for n in $(affected_names "$date"); do ensure_cut "$n" "test-${date}" "release-${date}"; done
  bash "${HERE}/deploy_stand.sh" prepod "${date}"
  log "предпрод: поезд ${date}"
}

promote_prod() {  # <date>  (deploy из release-<date>; master мержим для истории/тега)
  local date="$1" n d
  for n in $(affected_names "$date"); do
    d="$(mktemp -d)"; git clone -q "$(auth_url "$n")" "$d"
    git -C "$d" config user.email ci@polygon.local; git -C "$d" config user.name polygon-ci
    if git -C "$d" rev-parse --verify --quiet "refs/remotes/origin/release-${date}" >/dev/null; then
      git -C "$d" checkout -q master
      git -C "$d" merge --no-edit --no-ff "origin/release-${date}" >/dev/null 2>&1 || true
      git -C "$d" tag -f "shipped-${date}" >/dev/null
      git -C "$d" push -q "$(auth_url "$n")" master 2>/dev/null || true
      git -C "$d" push -q -f "$(auth_url "$n")" "shipped-${date}"
      log "  ${n}: release-${date} -> master, tag shipped-${date}"
    fi
  done
  bash "${HERE}/deploy_stand.sh" prod "${date}"
  set_status "$date" shipped
  log "прод: поезд ${date}"
}

main() {
  local t p r
  t="$(slot_date test)"; p="$(slot_date prepod)"; r="$(slot_date prod)"
  [ -n "$t" ] && promote_test "$t"
  [ -n "$p" ] && promote_prepod "$p"
  [ -n "$r" ] && promote_prod "$r"
  log "promote: test=${t:-—} prepod=${p:-—} prod=${r:-—}"
}
main
