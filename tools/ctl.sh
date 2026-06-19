#!/usr/bin/env bash
# Оркестрация полигона через GitLab API. Запускается в ci-tools на gitlabnet.
# Монтировано: /state/state.env (из bootstrap). Подкоманды: create-train/set-bts/depart/gate/status/demo/test.
set -uo pipefail
source /state/state.env
GL="$GITLAB_INTERNAL_URL"
REL="$RELEASE_REPO_ID"

gapi() { curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@"; }
enc() { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# Надёжное чтение файла с master: ретраи, непустой результат (иначе read-modify-write затрёт).
raw_file() {  # path -> content на stdout; ненулевой код если стойко пусто
  local e out; e="$(enc "$1")"
  for _ in $(seq 1 6); do
    out="$(gapi "$GL/api/v4/projects/$REL/repository/files/$e/raw?ref=master")"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 1
  done
  return 1
}
ok()   { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*"; FAILED=1; }

btset_yaml() {  # date "id,id,id" — bt-set = просто список БТ. Миграции детектятся по факту (migrations-репо).
  python3 - "$1" "$2" <<'PY'
import sys
date, ids = sys.argv[1], sys.argv[2]
ids = [i for i in ids.split(",") if i.strip()]
print('train: "%s"' % date)
print('status: open')
print('bts:')
for i in ids:
    print('  - id: %s' % i)
PY
}

latest_pipeline_id() { gapi "$GL/api/v4/projects/$REL/pipelines?per_page=1" | jq -r '.[0].id // 0'; }

wait_pipeline() {  # pid -> echoes status
  local pid="$1" st
  for _ in $(seq 1 120); do
    st="$(gapi "$GL/api/v4/projects/$REL/pipelines/$pid" | jq -r '.status')"
    case "$st" in success|failed|canceled|skipped) echo "$st"; return 0;; esac
    sleep 3
  done
  echo "timeout"
}

wait_new_pipeline() {  # before_id -> echoes "pid status"
  local before="$1" pid=""
  for _ in $(seq 1 40); do
    pid="$(gapi "$GL/api/v4/projects/$REL/pipelines?per_page=10" \
      | jq -r "[.[]|select(.id> $before)]|sort_by(.id)|.[0].id // empty")"
    [ -n "$pid" ] && break
    sleep 3
  done
  [ -n "$pid" ] || { echo "0 nonew"; return 0; }
  echo "$pid $(wait_pipeline "$pid")"
}

# Атомарный коммит через Commits API -> возвращает sha (надёжнее Files API: знаем свой коммит).
gl_commit() {  # message actions_json -> echoes sha
  gapi -X POST "$GL/api/v4/projects/$REL/repository/commits" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg b master --arg m "$1" --argjson acts "$2" \
              '{branch:$b, commit_message:$m, actions:$acts}')" \
    | jq -r '.id // empty'
}

# Ждать пайплайн ИМЕННО нашего коммита (по sha) -> не путаем со skip-ci пайплайнами.
wait_sha_pipeline() {  # sha -> echoes status
  local sha="$1" pid
  for _ in $(seq 1 60); do
    pid="$(gapi "$GL/api/v4/projects/$REL/pipelines?sha=$sha" | jq -r '.[0].id // empty')"
    [ -n "$pid" ] && break
    sleep 2
  done
  [ -n "$pid" ] || { echo "nopipeline"; return 0; }
  wait_pipeline "$pid"
}

gl_trigger() {  # action date -> pipeline status (для ре-рана reconcile после resolve)
  local pid
  pid="$(curl -sS -X POST -F "token=$TRIGGER_TOKEN" -F "ref=master" \
    -F "variables[ACTION]=$1" -F "variables[TRAIN_DATE]=$2" \
    "$GL/api/v4/projects/$REL/trigger/pipeline" | jq -r '.id // empty')"
  [ -n "$pid" ] || { echo "notrigger"; return 0; }
  wait_pipeline "$pid"
}

proj_file() {  # project_id path ref -> raw содержимое
  gapi "$GL/api/v4/projects/$1/repository/files/$(enc "$2")/raw?ref=$(enc "$3")"
}

put_btset() {  # date "ids" -> commit bt-set -> reconcile. echoes pipeline status
  local date="$1" ids="$2" path content act sha
  path="trains/${date}/bt-set.yaml"
  content="$(btset_yaml "$date" "$ids")"
  if file_exists "$path"; then act=update; else act=create; fi
  sha="$(gl_commit "train(${date}): set bts=${ids}" \
    "$(jq -n --arg a "$act" --arg p "$path" --arg c "$content" '[{action:$a,file_path:$p,content:$c}]')")"
  [ -n "$sha" ] || { echo "nocommit"; return 0; }
  wait_sha_pipeline "$sha"
}

slot_cur() {  # env -> текущая привязка stands/<env> (пусто допустимо)
  gapi "$GL/api/v4/projects/$REL/repository/files/$(enc "stands/$1")/raw?ref=master" 2>/dev/null | tr -d '[:space:]'
}

stands_put() {  # slot date [slot date...] -> правит ТОЛЬКО изменившиеся stands/<slot>, коммит -> reconcile
  local label="$*" acts="[]" slot val cur sha
  while [ "$#" -ge 2 ]; do
    slot="$1"; val="$2"; shift 2
    cur="$(slot_cur "$slot")"
    [ "$cur" = "$val" ] && continue
    acts="$(printf '%s' "$acts" | jq --arg fp "stands/$slot" --arg c "$val" '. + [{action:"update",file_path:$fp,content:$c}]')"
  done
  [ "$acts" = "[]" ] && { echo "noop"; return 0; }
  sha="$(gl_commit "promote: $label" "$acts")"
  [ -n "$sha" ] || { echo "nocommit"; return 0; }
  wait_sha_pipeline "$sha"
}

cmd_dev() {  # date bts -> ОДИН коммит: bt-set + (если надо) stands/dev -> reconcile собирает dev. echoes status
  local date="$1" bts="$2" btact curdev acts sha
  if file_exists "trains/$date/bt-set.yaml"; then btact=update; else btact=create; fi
  acts="$(jq -n --arg a "$btact" --arg p "trains/$date/bt-set.yaml" --arg c "$(btset_yaml "$date" "$bts")" \
          '[{action:$a,file_path:$p,content:$c}]')"
  curdev="$(slot_cur dev)"
  if [ "$curdev" != "$date" ]; then
    acts="$(printf '%s' "$acts" | jq --arg c "$date" '. + [{action:"update",file_path:"stands/dev",content:$c}]')"
  fi
  sha="$(gl_commit "dev: поезд ${date} (bts=${bts})" "$acts")"
  [ -n "$sha" ] || { echo "nocommit"; return 0; }
  wait_sha_pipeline "$sha"
}

# демо-резолюция: owner = bt-X+bt-Y[+...] из имени merge-ветки. Чинит ТОЛЬКО конфликтные файлы.
resolve_conflicts() {  # workdir mb
  local d="$1" mb="$2" owner
  owner="$(echo "$mb" | grep -oE 'bt-[0-9]+' | sort -u | paste -sd+ -)"
  if [ -f "$d/shared.json" ] && grep -q '<<<<<<<' "$d/shared.json" 2>/dev/null; then
    printf '{\n  "owner": "%s",\n  "counter": 0\n}\n' "$owner" > "$d/shared.json"
  fi
  if [ -f "$d/flags.json" ] && grep -q '<<<<<<<' "$d/flags.json" 2>/dev/null; then
    printf '{\n  "owner": "%s",\n  "enabled": true\n}\n' "$owner" > "$d/flags.json"
  fi
}

cmd_resolve() {  # repo mb -> ДЕМО-резолв СУЩЕСТВУЮЩЕЙ skeleton-ветки (от reconcile) + push.
  local repo="$1" mb="$2" d url
  url="http://oauth2:$GITLAB_TOKEN@gitlab:8929/$GROUP/$repo.git"
  d="$(mktemp -d)"; git clone -q "$url" "$d"
  git -C "$d" checkout -q "$mb"
  git -C "$d" config user.email dev@polygon.local; git -C "$d" config user.name dev
  resolve_conflicts "$d" "$mb"
  git -C "$d" add -A
  git -C "$d" commit -q -m "resolve: разрешить конфликт в ${mb}" || true
  git -C "$d" push -q "$url" "$mb"
  echo "resolved ${mb}"
}

cmd_mkmerge() {  # repo "77,78,79" -> создать merge-ветку С НУЛЯ от master, влить БТ, резолв, push.
  # Ручной путь разработчика (в т.ч. для троек, что reconcile сам не создаёт).
  local repo="$1" csv="$2" d url ids mb n
  url="http://oauth2:$GITLAB_TOKEN@gitlab:8929/$GROUP/$repo.git"
  ids="$(echo "$csv" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n)"
  mb="merge/$(echo "$ids" | sed 's/^/bt-/' | paste -sd- -)"   # merge/bt-77-bt-78-bt-79
  d="$(mktemp -d)"; git clone -q "$url" "$d"
  git -C "$d" config user.email dev@polygon.local; git -C "$d" config user.name dev
  git -C "$d" checkout -q -B "$mb" origin/master
  # мержим по одной, конфликт резолвим И коммитим СРАЗУ (иначе следующий merge не стартует)
  for n in $ids; do
    if ! git -C "$d" merge --no-edit "origin/feature/bt-${n}" >/dev/null 2>&1; then
      resolve_conflicts "$d" "$mb"
      git -C "$d" add -A
      git -C "$d" commit -q --no-edit
    fi
  done
  git -C "$d" push -q -f "$url" "$mb"
  echo "created+resolved ${mb}"
}

cmd_stop() {  # date -> status=stopped + postmortem одним коммитом (reconcile no-op: status!=open)
  local date="$1" cur new pm pact sha
  cur="$(raw_file "trains/$date/bt-set.yaml")" || { echo "fetch-failed"; return 1; }
  new="$(printf '%s' "$cur" | python3 -c 'import sys,re; print(re.sub(r"(?m)^status:.*$","status: stopped",sys.stdin.read()), end="")')"
  pm="$(printf '# Postmortem поезда %s\n\n- Гейт: FAILED (тест-стенд)\n- Поезд остановлен (stop-the-line), не реанимируется.\n- Дефектный БТ выпадает, чинится в feature-ветке, едет следующим поездом.\n' "$date")"
  if file_exists "trains/$date/postmortem.md"; then pact=update; else pact=create; fi
  sha="$(gl_commit "stop($date): stop-the-line" \
    "$(jq -n --arg bp "trains/$date/bt-set.yaml" --arg bc "$new" \
             --arg pa "$pact" --arg pp "trains/$date/postmortem.md" --arg pc "$pm" \
       '[{action:"update",file_path:$bp,content:$bc},{action:$pa,file_path:$pp,content:$pc}]')")"
  wait_sha_pipeline "$sha" >/dev/null
  echo "stopped"
}

train_status() {  # date
  local e; e="$(enc "trains/$1/bt-set.yaml")"
  gapi "$GL/api/v4/projects/$REL/repository/files/$e/raw?ref=master" 2>/dev/null \
    | python3 -c 'import sys,yaml; print((yaml.safe_load(sys.stdin) or {}).get("status","?"))' 2>/dev/null || echo "нет"
}

file_exists() {  # path
  local e; e="$(enc "$1")"
  [ "$(gapi -o /dev/null -w '%{http_code}' "$GL/api/v4/projects/$REL/repository/files/$e?ref=master")" = "200" ]
}

branch_exists() {  # project_id branch
  [ "$(gapi -o /dev/null -w '%{http_code}' "$GL/api/v4/projects/$1/repository/branches/$(enc "$2")")" = "200" ]
}

tag_exists() {  # project_id tag
  [ "$(gapi -o /dev/null -w '%{http_code}' "$GL/api/v4/projects/$1/repository/tags/$(enc "$2")")" = "200" ]
}

stand_meta() {  # env -> raw meta.json (retry)
  local env="$1"
  for _ in $(seq 1 15); do
    out="$(curl -sS "http://stand-${env}/meta.json" 2>/dev/null)"
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 2
  done
  echo "{}"
}

stand_has_bt() {  # env btid
  stand_meta "$1" | jq -e --argjson b "$2" '.bts | index($b) != null' >/dev/null 2>&1
}

stand_feature_exists() {  # env path(e.g. svc-a/features/bt-30.json)
  [ "$(curl -sS -o /dev/null -w '%{http_code}' "http://stand-$1/$2" 2>/dev/null)" = "200" ]
}

cmd_status() {
  echo "== Поезда =="
  for d in $(gapi "$GL/api/v4/projects/$REL/repository/tree?path=trains&per_page=100" | jq -r '.[]|select(.type=="tree")|.name' | sort); do
    echo "  $d -> $(train_status "$d")"
  done
  echo "== Стенды =="
  for env in dev test prepod prod; do
    case "$env" in
      dev) p="${STAND_DEV_PORT:-8081}";; test) p="${STAND_TEST_PORT:-8082}";;
      prepod) p="${STAND_PREPOD_PORT:-8083}";; prod) p="${STAND_PROD_PORT:-8084}";;
    esac
    m="$(curl -sS "http://stand-${env}/meta.json" 2>/dev/null)"
    if [ -n "$m" ]; then
      echo "  $env (localhost:$p): $(echo "$m" | jq -c '{train,bts}')"
    else
      echo "  $env: не поднят"
    fi
  done
}

# ---- сценарий ----
cmd_demo() {
  FAILED=0
  local T1=26.06.09 T2=26.06.11 T3=26.06.13 TC=26.06.16

  echo "### 1. Поезд $T1: BT-16 + BT-25 -> dev"
  echo "  dev: $(cmd_dev $T1 16,25)"
  stand_has_bt dev 16 && ok "dev содержит BT-16" || fail "dev без BT-16"
  stand_has_bt dev 25 && ok "dev содержит BT-25" || fail "dev без BT-25"

  echo "### 2. + BT-30 (multi-repo svc-a+frontend)"
  echo "  dev: $(cmd_dev $T1 16,25,30)"
  stand_feature_exists dev "svc-a/features/bt-30.json" && ok "svc-a/bt-30 на dev" || fail "нет svc-a/bt-30"
  stand_feature_exists dev "features/bt-30.json" && ok "frontend/bt-30 на dev" || fail "нет frontend/bt-30"

  echo "### 3. Выдернуть BT-25 -> пересборка без него"
  echo "  dev: $(cmd_dev $T1 16,30)"
  stand_has_bt dev 25 && fail "BT-25 всё ещё на dev" || ok "BT-25 убран с dev"
  stand_has_bt dev 16 && ok "BT-16 остался" || fail "BT-16 пропал"

  echo "### 3b. Триггер #2: push в feature/bt-16 -> reconcile рефрешит привязанный dev"
  touch_feature svc-a bt-16 && ok "feature/bt-16 обновлён, reconcile дёрнут" || echo "  [warn] триггер не подтверждён"

  echo "### 4. Вернуть BT-25, стенд test=$T1 — собирается напрямую (минуя срез)"
  cmd_dev $T1 16,25,30 >/dev/null
  echo "  test: $(stands_put test $T1)"
  stand_has_bt test 16 && stand_has_bt test 25 && stand_has_bt test 30 && ok "test-стенд = состав поезда" || fail "test-стенд неверен"

  echo "### 5. Релиз prepod+prod=$T1 (без merge master), затем accept"
  echo "  release: $(stands_put prepod $T1 prod $T1)"
  stand_has_bt prod 16 && stand_has_bt prod 25 && stand_has_bt prod 30 && ok "prod-стенд = состав" || fail "prod-стенд неверен"
  [ "$(train_status $T1)" != shipped ] && ok "до accept статус не shipped (master не тронут)" || fail "shipped до accept?"
  echo "  accept: $(gl_trigger accept $T1)"
  [ "$(train_status $T1)" = shipped ] && ok "после accept: $T1 shipped" || fail "статус $T1 != shipped"
  tag_exists "$SVC_A_ID" "shipped-$T1" && ok "tag shipped-$T1 в svc-a (accept)" || fail "нет тега в svc-a"

  echo "### 6. Поезд $T2: BT-99 -> dev + test -> stop-the-line"
  cmd_dev $T2 99 >/dev/null
  stands_put test $T2 >/dev/null
  echo "  stop: $(cmd_stop $T2)"
  [ "$(train_status $T2)" = stopped ] && ok "поезд $T2 stopped" || fail "статус $T2 != stopped"
  file_exists "trains/$T2/postmortem.md" && ok "postmortem.md создан" || fail "нет postmortem"

  echo "### 7. Carryover: BT-99 в следующий поезд $T3"
  echo "  dev: $(cmd_dev $T3 99)"
  stand_has_bt dev 99 && ok "BT-99 переехал в $T3 (dev)" || fail "BT-99 не переехал"

  echo "### 8. Конфликт bt-77/bt-78 -> skeleton -> resolve -> зелено, bt-ветки чистые"
  st="$(cmd_dev $TC 77,78)"
  [ "$st" = failed ] && ok "reconcile упал, нужен резолв" || fail "ожидался failed, получили: $st"
  branch_exists "$SVC_A_ID" "merge/bt-77-bt-78" && ok "создана merge/bt-77-bt-78 (skeleton)" || fail "нет merge-ветки"
  echo "  resolve: $(cmd_resolve svc-a merge/bt-77-bt-78)"
  echo "  rebuild: $(gl_trigger reconcile $TC)"
  local owner o77 o78
  owner="$(proj_file "$SVC_A_ID" shared.json "dev-$TC" | jq -r '.owner' 2>/dev/null)"
  [ "$owner" = "bt-77+bt-78" ] && ok "dev shared.json разрешён (owner=$owner)" || fail "dev не разрешён (owner=$owner)"
  o77="$(proj_file "$SVC_A_ID" shared.json "feature/bt-77" | jq -r '.owner' 2>/dev/null)"
  o78="$(proj_file "$SVC_A_ID" shared.json "feature/bt-78" | jq -r '.owner' 2>/dev/null)"
  { [ "$o77" = "bt-77" ] && [ "$o78" = "bt-78" ]; } && ok "feature/bt-77,78 чистые ($o77/$o78)" || fail "bt-ветки загажены ($o77/$o78)"

  echo "### 9. Дизъюнктные конфликты: 77/78 (shared.json) + 81/82 (flags.json) -> ОБЕ merge-ветки"
  local TD=26.06.18 osh ofl
  st="$(cmd_dev $TD 77,78,81,82)"   # merge/bt-77-bt-78 готова; 81/82 -> новый skeleton, fail
  [ "$st" = failed ] && ok "reconcile создал skeleton merge/bt-81-bt-82" || fail "ожидался failed: $st"
  branch_exists "$SVC_A_ID" "merge/bt-81-bt-82" && ok "создана merge/bt-81-bt-82" || fail "нет merge/bt-81-bt-82"
  echo "  resolve: $(cmd_resolve svc-a merge/bt-81-bt-82)"
  echo "  rebuild: $(gl_trigger reconcile $TD)"
  osh="$(proj_file "$SVC_A_ID" shared.json "dev-$TD" | jq -r '.owner' 2>/dev/null)"
  ofl="$(proj_file "$SVC_A_ID" flags.json "dev-$TD" | jq -r '.owner' 2>/dev/null)"
  { [ "$osh" = "bt-77+bt-78" ] && [ "$ofl" = "bt-81+bt-82" ]; } \
    && ok "ОБЕ merge-ветки включены и скомпозились (shared=$osh, flags=$ofl)" \
    || fail "композ не вышел (shared=$osh flags=$ofl)"

  echo
  [ "${FAILED:-0}" = 0 ] && echo "DEMO: ВСЕ ПРОВЕРКИ ЗЕЛЁНЫЕ" || echo "DEMO: ЕСТЬ ПАДЕНИЯ"
  return "${FAILED:-0}"
}

touch_feature() {  # project bt  (push пустого изменения в feature-ветку -> триггер)
  local proj="$1" bt="$2" d before res
  d="$(mktemp -d)"
  git clone -q "http://oauth2:$GITLAB_TOKEN@gitlab:8929/$GROUP/$proj.git" "$d" || return 1
  git -C "$d" checkout -q "feature/$bt" || return 1
  git -C "$d" config user.email ci@polygon.local; git -C "$d" config user.name polygon-ci
  date -u +%s > "$d/.touch"
  git -C "$d" add -A; git -C "$d" commit -q -m "chore($bt): touch"
  before="$(latest_pipeline_id)"
  git -C "$d" push -q "http://oauth2:$GITLAB_TOKEN@gitlab:8929/$GROUP/$proj.git" "feature/$bt" || return 1
  res="$(wait_new_pipeline "$before")"   # сервисный CI -> trigger -> reconcile
  [ -n "$res" ]
}

cmd_test() {  # быстрая проверка персистентного end-state (после demo)
  FAILED=0
  local T1=26.06.09 T2=26.06.11
  stand_has_bt prod 16 && stand_has_bt prod 30 && ok "prod содержит BT-16,30" || fail "prod неполный"
  [ "$(train_status $T1)" = shipped ] && ok "$T1 shipped" || fail "$T1 не shipped"
  [ "$(train_status $T2)" = stopped ] && ok "$T2 stopped" || fail "$T2 не stopped"
  tag_exists "$SVC_A_ID" "shipped-$T1" && ok "tag shipped-$T1" || fail "нет тега"
  branch_exists "$SVC_A_ID" "master" && ok "svc-a master есть" || fail "нет master"
  [ "${FAILED:-0}" = 0 ] && echo "TEST: OK" || echo "TEST: FAIL"
  return "${FAILED:-0}"
}

case "${1:-}" in
  create-train|set-bts)   shift; put_btset "$@";;
  dev)                    shift; cmd_dev "$1" "$2";;
  promote-test)           shift; stands_put test "$1";;
  promote-release)        shift; stands_put prepod "$1" prod "$1";;
  stop)                   shift; cmd_stop "$1";;
  accept)                 shift; gl_trigger accept "$1";;
  resolve)                shift; cmd_resolve "$1" "$2";;
  mkmerge)                shift; cmd_mkmerge "$1" "$2";;
  rebuild)                shift; gl_trigger reconcile "$1";;
  status)  cmd_status;;
  demo)    cmd_demo;;
  test)    cmd_test;;
  *) echo "usage: ctl.sh {create-train|dev|promote-test|promote-release|stop|accept|resolve|mkmerge|rebuild|status|demo|test}"; exit 1;;
esac
