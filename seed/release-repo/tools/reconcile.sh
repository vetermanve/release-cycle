#!/usr/bin/env bash
# Пересборка dev-<DATE>: master + merge юнитов.
# Юниты = merge/*-ветки (резолв конфликтов, БТ⊆поезда) + ВСЕ feature/bt-N поезда.
# Стратегия: мерж-ветки первыми (несут резолв), потом feature; отложенный итеративный
# merge до фикспоинта; при настоящем конфликте — найти пару, создать merge/bt-X-bt-Y skeleton, fail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

parse_bts() { echo "$1" | grep -oE 'bt-[0-9]+' | grep -oE '[0-9]+'; }
in_set() { echo " $2 " | grep -q " $1 "; }   # in_set <id> <space-list>
has_markers() { git -C "$1" grep -I -q -e '<<<<<<<' "$2" 2>/dev/null; }   # rdir ref

# Глобалы-выходы build_repo:
DEV_SHA=""; DEV_BTS=""; CONFLICT_MSG=""

# Найти merged-feature, конфликтующий с bt-Y, и создать skeleton merge/bt-X-bt-Y.
handle_pair() {  # rdir name date merged_feats yId
  local rdir="$1" name="$2" date="$3" merged="$4" Y="$5" M lo hi mb
  local X=""
  for M in $merged; do
    git -C "$rdir" checkout -q -B __probe origin/master
    git -C "$rdir" merge --no-edit "origin/feature/bt-${M}" >/dev/null 2>&1 || true
    if ! git -C "$rdir" merge --no-edit "origin/feature/bt-${Y}" >/dev/null 2>&1; then
      git -C "$rdir" merge --abort >/dev/null 2>&1 || true
      X="$M"; break
    fi
    git -C "$rdir" merge --abort >/dev/null 2>&1 || true
  done
  git -C "$rdir" checkout -q "dev-${date}" >/dev/null 2>&1 || true
  [ -n "$X" ] || { CONFLICT_MSG="${name}: bt-${Y} конфликтует (пару определить не удалось)"; return; }

  lo="$X"; hi="$Y"; if [ "$lo" -gt "$hi" ]; then lo="$Y"; hi="$X"; fi
  mb="merge/bt-${lo}-bt-${hi}"
  if git -C "$rdir" rev-parse --verify -q "origin/${mb}" >/dev/null; then
    CONFLICT_MSG="${name}: конфликт bt-${X}/bt-${Y}; ветка ${mb} есть, но НЕ разрешена (маркеры). Разреши и запушь."
    return
  fi
  # создать skeleton: master + bt-lo + bt-hi (с маркерами), запушить для разраба
  git -C "$rdir" checkout -q -B "${mb}" origin/master
  git -C "$rdir" merge --no-edit "origin/feature/bt-${lo}" >/dev/null 2>&1 || true
  git -C "$rdir" merge --no-edit "origin/feature/bt-${hi}" >/dev/null 2>&1 || true
  git -C "$rdir" add -A
  git -C "$rdir" commit -q -m "merge skeleton bt-${lo}+bt-${hi} (UNRESOLVED: разреши конфликт-маркеры)" || true
  git -C "$rdir" push -q -f "$(auth_url "$name")" "${mb}"
  git -C "$rdir" checkout -q "dev-${date}" >/dev/null 2>&1 || true
  CONFLICT_MSG="${name}: конфликт bt-${X}/bt-${Y}; создана ${mb} (разреши маркеры, запушь, ре-ран)"
}

# Собрать dev-<date> в клоне rdir. rc: 0 собрано, 1 конфликт, 2 репо не затронут.
build_repo() {  # rdir name date ids_list
  local rdir="$1" name="$2" date="$3" ids="$4"
  DEV_SHA=""; DEV_BTS=""; CONFLICT_MSG=""

  # merge/*-ветки, чьи БТ все в наборе и их >=2
  local merge_units=() ref short bts cnt b okm
  while read -r ref; do
    [ -n "$ref" ] || continue
    short="${ref#origin/}"
    bts="$(parse_bts "$short" | tr '\n' ' ')"
    cnt="$(echo $bts | wc -w)"
    [ "$cnt" -ge 2 ] || continue
    okm=1; for b in $bts; do in_set "$b" "$ids" || okm=0; done
    [ "$okm" = 1 ] && merge_units+=("$short")
  done < <(git -C "$rdir" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/merge/*' 2>/dev/null)

  # feature-юниты поезда, что есть в репо
  local feat_units=() id
  for id in $ids; do
    git -C "$rdir" rev-parse --verify -q "origin/feature/bt-${id}" >/dev/null 2>&1 && feat_units+=("feature/bt-${id}")
  done
  [ "${#feat_units[@]}" -gt 0 ] || return 2

  git -C "$rdir" checkout -q -B "dev-${date}" origin/master

  # юниты: мерж-ветки первыми, потом feature
  local pending=() u
  pending=( ${merge_units[@]+"${merge_units[@]}"} ${feat_units[@]+"${feat_units[@]}"} )

  local merged_feats="" blocked=""
  while :; do
    local progress=0 still=()
    for u in ${pending[@]+"${pending[@]}"}; do
      if [[ "$u" == merge/* ]] && has_markers "$rdir" "origin/${u}"; then
        blocked+=" ${u}"; continue
      fi
      if git -C "$rdir" merge --no-edit --no-ff "origin/${u}" >/dev/null 2>&1; then
        progress=1
        [[ "$u" == feature/bt-* ]] && merged_feats+=" ${u#feature/bt-}"
        log "  ${name}: merged ${u}"
      else
        git -C "$rdir" merge --abort >/dev/null 2>&1 || true
        still+=("$u")
      fi
    done
    pending=( ${still[@]+"${still[@]}"} )
    [ "$progress" = 1 ] || break
  done

  if [ -n "$blocked" ]; then
    CONFLICT_MSG="${name}: мерж-ветка(и) не разрешена:${blocked}"
    return 1
  fi
  if [ "${#pending[@]}" -gt 0 ]; then
    # первый отложенный feature -> найти пару, создать skeleton
    local first="" Y=""
    for u in "${pending[@]}"; do [[ "$u" == feature/bt-* ]] && { first="$u"; break; }; done
    Y="${first#feature/bt-}"
    handle_pair "$rdir" "$name" "$date" "$merged_feats" "$Y"
    return 1
  fi

  git -C "$rdir" push -q -f "$(auth_url "$name")" "dev-${date}"
  DEV_SHA="$(git -C "$rdir" rev-parse --short HEAD)"
  DEV_BTS="$(echo $merged_feats | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | paste -sd, -)"
  return 0
}

reconcile_one() {
  local date="$1"
  local btset="${RELREPO_DIR}/trains/${date}/bt-set.yaml"
  [ -f "$btset" ] || { log "нет bt-set для ${date}, пропуск"; return 0; }
  local status; status="$(python3 "${HERE}/cfg.py" status "$btset")"
  if [ "$status" != "open" ]; then log "поезд ${date} status=${status}, reconcile пропущен"; return 0; fi

  local ids; ids="$(python3 "${HERE}/cfg.py" bts "$btset" | sort -n | tr '\n' ' ')"
  log "reconcile ${date}: БТ = ${ids}"

  local work; work="$(mktemp -d)"
  local lock="${RELREPO_DIR}/trains/${date}/affected-repos.lock"
  : > "$lock"
  local conflict=0 conflict_msg="" name mount rc

  while IFS=$'\t' read -r name mount; do
    [ -n "$name" ] || continue
    local rdir="${work}/${name}"
    git clone -q "$(auth_url "$name")" "$rdir"
    git -C "$rdir" config user.email "ci@polygon.local"
    git -C "$rdir" config user.name "polygon-ci"

    rc=0; build_repo "$rdir" "$name" "$date" "$ids" || rc=$?
    case "$rc" in
      2) log "  ${name}: не затронут";;
      0) echo "${name} dev-${date} ${DEV_SHA} bts=${DEV_BTS}" >> "$lock"
         log "  ${name}: dev-${date} ${DEV_SHA} (БТ=${DEV_BTS})";;
      *) conflict=1; conflict_msg="${CONFLICT_MSG}"; log "  CONFLICT ${conflict_msg}"; break;;
    esac
  done < <(catalog_repos)

  python3 "${HERE}/gen_release_page.py" "${RELREPO_DIR}" "${date}" "${conflict_msg}" \
    > "${RELREPO_DIR}/trains/${date}/release-page.md"
  push_generated "${date}"

  if [ "$conflict" -ne 0 ]; then
    log "reconcile ${date}: ОСТАНОВЛЕН (${conflict_msg})"
    return 1
  fi
  bash "${HERE}/deploy_stand.sh" dev "${date}"
  log "reconcile ${date}: OK, dev-стенд обновлён"
}

push_generated() {
  local date="$1"
  cd "${RELREPO_DIR}"
  git config user.email "ci@polygon.local"; git config user.name "polygon-ci"
  git add "trains/${date}/affected-repos.lock" "trains/${date}/release-page.md" 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -q -m "ci(${date}): обновить affected-repos.lock и release-page [skip ci]"
    git push -q -o ci.skip "$(auth_url release-repo)" "HEAD:master"
    log "  release-page/affected закоммичены"
  fi
}

main() {
  if [ "${1:-}" != "" ]; then reconcile_one "$1"; return; fi
  local targets=""
  if [ "${CI_PIPELINE_SOURCE:-}" = "push" ]; then
    targets="$(cd "${RELREPO_DIR}" && git diff --name-only HEAD~1 HEAD 2>/dev/null \
      | sed -nE 's#^trains/([^/]+)/bt-set.yaml$#\1#p' | sort -u)"
  fi
  if [ -z "$targets" ]; then
    for d in "${RELREPO_DIR}"/trains/*/bt-set.yaml; do
      [ -e "$d" ] && targets+=" $(basename "$(dirname "$d")")"
    done
  fi
  local rc=0 d
  for d in $targets; do
    if reconcile_one "$d"; then :; else rc=1; fi
  done
  return "$rc"
}
main "${1:-}"
