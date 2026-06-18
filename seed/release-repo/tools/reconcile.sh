#!/usr/bin/env bash
# Пересборка dev-<DATE> с нуля: master + merge feature/bt-<N> по возрастанию N,
# auto-scan по каталогу. Идемпотентно. Конфликт -> exit 1 (красный pipeline).
# Деплой dev-стенда. Запись affected-repos.lock + release-page.md в release-repo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

reconcile_one() {
  local date="$1"
  local btset="${RELREPO_DIR}/trains/${date}/bt-set.yaml"
  [ -f "$btset" ] || { log "нет bt-set для ${date}, пропуск"; return 0; }
  local status; status="$(python3 "${HERE}/cfg.py" status "$btset")"
  if [ "$status" != "open" ]; then log "поезд ${date} status=${status}, reconcile пропущен"; return 0; fi

  local ids; ids="$(python3 "${HERE}/cfg.py" bts "$btset" | sort -n)"
  log "reconcile ${date}: БТ = $(echo $ids | tr '\n' ' ')"

  local work; work="$(mktemp -d)"
  local lock="${RELREPO_DIR}/trains/${date}/affected-repos.lock"
  : > "$lock"
  local conflict=0 conflict_msg=""

  while IFS=$'\t' read -r name mount; do
    [ -n "$name" ] || continue
    local rdir="${work}/${name}"
    git clone -q "$(auth_url "$name")" "$rdir"
    git -C "$rdir" config user.email "ci@polygon.local"
    git -C "$rdir" config user.name "polygon-ci"

    # какие из БТ присутствуют в этом репо
    local present=()
    for id in $ids; do
      if git -C "$rdir" rev-parse --verify --quiet "refs/remotes/origin/feature/bt-${id}" >/dev/null; then
        present+=("$id")
      fi
    done
    [ "${#present[@]}" -gt 0 ] || { log "  ${name}: не затронут"; continue; }

    git -C "$rdir" checkout -q -B "dev-${date}" origin/master
    for id in "${present[@]}"; do
      if git -C "$rdir" merge --no-edit --no-ff "origin/feature/bt-${id}" >/dev/null 2>&1; then
        log "  ${name}: merged bt-${id}"
      else
        git -C "$rdir" merge --abort || true
        conflict=1; conflict_msg="${name}: конфликт при merge feature/bt-${id}"
        log "  CONFLICT ${conflict_msg}"
        break
      fi
    done
    [ "$conflict" -eq 0 ] || break

    git -C "$rdir" push -q -f "$(auth_url "$name")" "dev-${date}"
    local sha; sha="$(git -C "$rdir" rev-parse --short HEAD)"
    echo "${name} dev-${date} ${sha} bts=$(IFS=,; echo "${present[*]}")" >> "$lock"
    log "  ${name}: dev-${date} pushed (${sha})"
  done < <(catalog_repos)

  # release-page (всегда, чтобы показать и конфликт)
  python3 "${HERE}/gen_release_page.py" "${RELREPO_DIR}" "${date}" "${conflict_msg}" \
    > "${RELREPO_DIR}/trains/${date}/release-page.md"

  push_generated "${date}"

  if [ "$conflict" -ne 0 ]; then
    log "reconcile ${date}: ОСТАНОВЛЕН по конфликту (${conflict_msg})"
    return 1
  fi

  bash "${HERE}/deploy_stand.sh" dev "${date}"
  log "reconcile ${date}: OK, dev-стенд обновлён"
}

push_generated() {  # коммит сгенерированных файлов обратно в release-repo (ci.skip)
  local date="$1"
  cd "${RELREPO_DIR}"
  git config user.email "ci@polygon.local"
  git config user.name "polygon-ci"
  git add "trains/${date}/affected-repos.lock" "trains/${date}/release-page.md" 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -q -m "ci(${date}): обновить affected-repos.lock и release-page [skip ci]"
    git push -q -o ci.skip "$(auth_url release-repo)" "HEAD:master"
    log "  release-page/affected закоммичены в release-repo"
  fi
}

main() {
  if [ "${1:-}" != "" ]; then
    reconcile_one "$1"
  else
    # все открытые поезда
    for d in "${RELREPO_DIR}"/trains/*/bt-set.yaml; do
      [ -e "$d" ] || continue
      local date; date="$(basename "$(dirname "$d")")"
      reconcile_one "$date"
    done
  fi
}
main "${1:-}"
