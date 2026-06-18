#!/usr/bin/env bash
# Единый реконсайлер (GitOps).
# Desired state: stands/<env> (какой поезд на стенде) + bt-set + feature/* + merge/*.
# Цель: каждый ПРИВЯЗАННЫЙ стенд = master + БТ его поезда + merge-ветки (свежая сборка).
# Симметрично для dev/test/prepod/prod. Можно собрать любой стенд напрямую, минуя другие.
# Сборка одного env: отложенный merge юнитов (merge-ветки первыми + все feature), при конфликте
# найти пару, создать merge/bt-X-bt-Y skeleton, fail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"

parse_bts() { echo "$1" | grep -oE 'bt-[0-9]+' | grep -oE '[0-9]+'; }
in_set() { echo " $2 " | grep -q " $1 "; }
has_markers() { git -C "$1" grep -I -q -e '<<<<<<<' "$2" 2>/dev/null; }

BUILD_SHA=""; BUILD_BTS=""; CONFLICT_MSG=""

handle_pair() {  # rdir name env date merged_feats yId
  local rdir="$1" name="$2" env="$3" date="$4" merged="$5" Y="$6" M lo hi mb X=""
  for M in $merged; do
    git -C "$rdir" checkout -q -B __probe origin/master
    git -C "$rdir" merge --no-edit "origin/feature/bt-${M}" >/dev/null 2>&1 || true
    if ! git -C "$rdir" merge --no-edit "origin/feature/bt-${Y}" >/dev/null 2>&1; then
      git -C "$rdir" merge --abort >/dev/null 2>&1 || true; X="$M"; break
    fi
    git -C "$rdir" merge --abort >/dev/null 2>&1 || true
  done
  git -C "$rdir" checkout -q "${env}-${date}" >/dev/null 2>&1 || true
  [ -n "$X" ] || { CONFLICT_MSG="${name}: bt-${Y} конфликтует (пару не определить)"; return; }
  lo="$X"; hi="$Y"; if [ "$lo" -gt "$hi" ]; then lo="$Y"; hi="$X"; fi
  mb="merge/bt-${lo}-bt-${hi}"
  if git -C "$rdir" rev-parse --verify -q "origin/${mb}" >/dev/null; then
    CONFLICT_MSG="${name}: конфликт bt-${X}/bt-${Y}; ветка ${mb} есть, но НЕ разрешена. Разреши и запушь."
    return
  fi
  git -C "$rdir" checkout -q -B "${mb}" origin/master
  git -C "$rdir" merge --no-edit "origin/feature/bt-${lo}" >/dev/null 2>&1 || true
  git -C "$rdir" merge --no-edit "origin/feature/bt-${hi}" >/dev/null 2>&1 || true
  git -C "$rdir" add -A
  git -C "$rdir" commit -q -m "merge skeleton bt-${lo}+bt-${hi} (UNRESOLVED)" || true
  git -C "$rdir" push -q -f "$(auth_url "$name")" "${mb}"
  git -C "$rdir" checkout -q "${env}-${date}" >/dev/null 2>&1 || true
  CONFLICT_MSG="${name}: конфликт bt-${X}/bt-${Y}; создана ${mb} (разреши маркеры, запушь, ре-ран)"
}

# Собрать ветку <env>-<date> в клоне. rc: 0 собрано, 1 конфликт, 2 репо не затронут.
build_repo() {  # rdir name env date ids
  local rdir="$1" name="$2" env="$3" date="$4" ids="$5"
  BUILD_SHA=""; BUILD_BTS=""; CONFLICT_MSG=""
  local merge_units=() ref short bts cnt b okm
  while read -r ref; do
    [ -n "$ref" ] || continue
    short="${ref#origin/}"; bts="$(parse_bts "$short" | tr '\n' ' ')"
    cnt="$(echo $bts | wc -w)"; [ "$cnt" -ge 2 ] || continue
    okm=1; for b in $bts; do in_set "$b" "$ids" || okm=0; done
    [ "$okm" = 1 ] && merge_units+=("$short")
  done < <(git -C "$rdir" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/merge/*' 2>/dev/null)

  local feat_units=() id
  for id in $ids; do
    git -C "$rdir" rev-parse --verify -q "origin/feature/bt-${id}" >/dev/null 2>&1 && feat_units+=("feature/bt-${id}")
  done
  [ "${#feat_units[@]}" -gt 0 ] || return 2

  git -C "$rdir" checkout -q -B "${env}-${date}" origin/master
  local pending=() u
  pending=( ${merge_units[@]+"${merge_units[@]}"} ${feat_units[@]+"${feat_units[@]}"} )
  local merged_feats="" blocked=""
  while :; do
    local progress=0 still=()
    for u in ${pending[@]+"${pending[@]}"}; do
      if [[ "$u" == merge/* ]] && has_markers "$rdir" "origin/${u}"; then blocked+=" ${u}"; continue; fi
      if git -C "$rdir" merge --no-edit --no-ff "origin/${u}" >/dev/null 2>&1; then
        progress=1; [[ "$u" == feature/bt-* ]] && merged_feats+=" ${u#feature/bt-}"
        log "    ${name}/${env}: merged ${u}"
      else
        git -C "$rdir" merge --abort >/dev/null 2>&1 || true; still+=("$u")
      fi
    done
    pending=( ${still[@]+"${still[@]}"} ); [ "$progress" = 1 ] || break
  done

  if [ -n "$blocked" ]; then CONFLICT_MSG="${name}: merge-ветка(и) не разрешена:${blocked}"; return 1; fi
  if [ "${#pending[@]}" -gt 0 ]; then
    local first="" Y=""
    for u in "${pending[@]}"; do [[ "$u" == feature/bt-* ]] && { first="$u"; break; }; done
    Y="${first#feature/bt-}"
    handle_pair "$rdir" "$name" "$env" "$date" "$merged_feats" "$Y"
    return 1
  fi
  git -C "$rdir" push -q -f "$(auth_url "$name")" "${env}-${date}"
  BUILD_SHA="$(git -C "$rdir" rev-parse --short HEAD)"
  BUILD_BTS="$(echo $merged_feats | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | paste -sd, -)"
  return 0
}

set_status() {  # date status (commit [skip ci])
  python3 "${HERE}/cfg.py" set-status "${RELREPO_DIR}/trains/$1/bt-set.yaml" "$2"
  ( cd "${RELREPO_DIR}"; git config user.email ci@polygon.local; git config user.name polygon-ci
    git add "trains/$1/bt-set.yaml"
    git diff --cached --quiet || { git commit -q -m "ci($1): status=$2 [skip ci]"; git push -q -o ci.skip "$(auth_url release-repo)" HEAD:master; } )
}

# Собрать и задеплоить ОДИН стенд из его поезда. rc 0/1.
assemble_stand() {  # env date
  local env="$1" date="$2"
  local btset="${RELREPO_DIR}/trains/${date}/bt-set.yaml"
  [ -f "$btset" ] || { log "  ${env}: нет поезда ${date}"; return 0; }
  local status; status="$(python3 "${HERE}/cfg.py" status "$btset")"
  if [ "$status" = "stopped" ]; then log "  ${env}: поезд ${date} stopped, пропуск"; return 0; fi
  local ids; ids="$(python3 "${HERE}/cfg.py" bts "$btset" | sort -n | tr '\n' ' ')"
  log "  assemble ${env} <- поезд ${date} (БТ ${ids})"

  local work; work="$(mktemp -d)"
  local lock="${RELREPO_DIR}/trains/${date}/affected-repos.lock"; : > "$lock"
  local conflict=0 name mount rc
  while IFS=$'\t' read -r name mount; do
    [ -n "$name" ] || continue
    local rdir="${work}/${name}"
    git clone -q "$(auth_url "$name")" "$rdir"
    git -C "$rdir" config user.email ci@polygon.local; git -C "$rdir" config user.name polygon-ci
    rc=0; build_repo "$rdir" "$name" "$env" "$date" "$ids" || rc=$?
    case "$rc" in
      2) :;;
      0) echo "${name} ${env}-${date} ${BUILD_SHA} bts=${BUILD_BTS}" >> "$lock"
         # prod: влить в master + тег (история/тег)
         if [ "$env" = prod ]; then
           git -C "$rdir" checkout -q master
           git -C "$rdir" merge --no-edit --no-ff "origin/prod-${date}" >/dev/null 2>&1 || true
           git -C "$rdir" tag -f "shipped-${date}" >/dev/null
           git -C "$rdir" push -q "$(auth_url "$name")" master 2>/dev/null || true
           git -C "$rdir" push -q -f "$(auth_url "$name")" "shipped-${date}"
         fi
         log "    ${name}: ${env}-${date} ${BUILD_SHA} (БТ=${BUILD_BTS})";;
      *) conflict=1; CONFLICT_MSG="${CONFLICT_MSG}"; log "    CONFLICT ${CONFLICT_MSG}"; break;;
    esac
  done < <(catalog_repos)

  python3 "${HERE}/gen_release_page.py" "${RELREPO_DIR}" "${date}" "${CONFLICT_MSG}" \
    > "${RELREPO_DIR}/trains/${date}/release-page.md"
  push_generated "${date}"
  [ "$conflict" -eq 0 ] || { log "  ${env}: ОСТАНОВЛЕН (${CONFLICT_MSG})"; return 1; }

  bash "${HERE}/deploy_stand.sh" "$env" "${date}"
  [ "$env" = prod ] && set_status "$date" shipped
  log "  ${env}-стенд: поезд ${date} задеплоен"
}

push_generated() {
  local date="$1"; cd "${RELREPO_DIR}"
  git config user.email ci@polygon.local; git config user.name polygon-ci
  git add "trains/${date}/affected-repos.lock" "trains/${date}/release-page.md" 2>/dev/null || true
  git diff --cached --quiet || { git commit -q -m "ci(${date}): lock+release-page [skip ci]"; git push -q -o ci.skip "$(auth_url release-repo)" HEAD:master; }
}

# Какие (env,date) рефрешить по изменению.
main() {
  local arg="${1:-}" targets="" env d changed T
  if [ -n "$arg" ]; then
    # явная дата (rebuild) -> все стенды, привязанные к ней
    for env in dev test prepod prod; do [ "$(slot_read "$env")" = "$arg" ] && targets+=" ${env}:${arg}"; done
  elif [ "${CI_PIPELINE_SOURCE:-}" = "push" ]; then
    changed="$(cd "${RELREPO_DIR}" && git diff --name-only HEAD~1 HEAD 2>/dev/null)"
    # изменён stands/<env> -> этот стенд
    for env in dev test prepod prod; do
      echo "$changed" | grep -qx "stands/${env}" && { d="$(slot_read "$env")"; [ -n "$d" ] && targets+=" ${env}:${d}"; }
    done
    # изменён trains/<T>/bt-set -> стенды, привязанные к T
    for T in $(echo "$changed" | sed -nE 's#^trains/([^/]+)/bt-set.yaml$#\1#p' | sort -u); do
      for env in dev test prepod prod; do [ "$(slot_read "$env")" = "$T" ] && targets+=" ${env}:${T}"; done
    done
  else
    # триггер (feature-пуш) -> все привязанные стенды
    for env in dev test prepod prod; do d="$(slot_read "$env")"; [ -n "$d" ] && targets+=" ${env}:${d}"; done
  fi

  targets="$(echo $targets | tr ' ' '\n' | sort -u | grep -v '^$' || true)"
  [ -n "$targets" ] || { log "reconcile: привязанных стендов для рефреша нет"; return 0; }
  local rc=0 t
  for t in $targets; do
    assemble_stand "${t%%:*}" "${t##*:}" || rc=1
  done
  return "$rc"
}
main "${1:-}"
