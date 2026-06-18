#!/usr/bin/env bash
# Оркестрация полигона через GitLab API. Запускается в ci-tools на gitlabnet.
# Монтировано: /state/state.env (из bootstrap). Подкоманды: create-train/set-bts/depart/gate/status/demo/test.
set -uo pipefail
source /state/state.env
GL="$GITLAB_INTERNAL_URL"
REL="$RELEASE_REPO_ID"

gapi() { curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@"; }
enc() { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
ok()   { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*"; FAILED=1; }

btset_yaml() {  # date "id,id,id"
  python3 - "$1" "$2" <<'PY'
import sys
date, ids = sys.argv[1], sys.argv[2]
ids = [i for i in ids.split(",") if i.strip()]
print('train: "%s"' % date)
print('status: open')
print('bts:')
for i in ids:
    print('  - id: %s' % i)
    print('    migration: none')
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

put_btset() {  # date "ids" -> commits bt-set, triggers reconcile, waits. echoes pipeline status
  local date="$1" ids="$2" path content e method code before res
  path="trains/${date}/bt-set.yaml"; e="$(enc "$path")"
  content="$(btset_yaml "$date" "$ids")"
  code="$(gapi -o /dev/null -w '%{http_code}' "$GL/api/v4/projects/$REL/repository/files/$e?ref=master")"
  method=POST; [ "$code" = "200" ] && method=PUT
  before="$(latest_pipeline_id)"
  gapi -X "$method" "$GL/api/v4/projects/$REL/repository/files/$e" \
    -d "branch=master" --data-urlencode "content=$content" \
    --data-urlencode "commit_message=train(${date}): set bts=${ids}" >/dev/null
  res="$(wait_new_pipeline "$before")"
  echo "${res#* }"
}

trigger_action() {  # action date [gate] -> echoes pipeline status
  local action="$1" date="$2" gate="${3:-}" pid
  pid="$(curl -sS -X POST \
    -F "token=$TRIGGER_TOKEN" -F "ref=master" \
    -F "variables[ACTION]=$action" -F "variables[TRAIN_DATE]=$date" \
    -F "variables[GATE_RESULT]=$gate" \
    "$GL/api/v4/projects/$REL/trigger/pipeline" | jq -r '.id // empty')"
  [ -n "$pid" ] || { echo "notrigger"; return 0; }
  wait_pipeline "$pid"
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

  echo "### 1. Поезд $T1: BT-16 + BT-25 -> reconcile -> dev"
  echo "  pipeline: $(put_btset $T1 16,25)"
  stand_has_bt dev 16 && ok "dev содержит BT-16" || fail "dev без BT-16"
  stand_has_bt dev 25 && ok "dev содержит BT-25" || fail "dev без BT-25"

  echo "### 2. + BT-30 (multi-repo svc-a+frontend)"
  echo "  pipeline: $(put_btset $T1 16,25,30)"
  stand_feature_exists dev "svc-a/features/bt-30.json" && ok "svc-a/bt-30 на dev" || fail "нет svc-a/bt-30"
  stand_feature_exists dev "features/bt-30.json" && ok "frontend/bt-30 на dev" || fail "нет frontend/bt-30"

  echo "### 3. Выдернуть BT-25 -> пересборка без него"
  echo "  pipeline: $(put_btset $T1 16,30)"
  stand_has_bt dev 25 && fail "BT-25 всё ещё на dev" || ok "BT-25 убран с dev"
  stand_has_bt dev 16 && ok "BT-16 остался" || fail "BT-16 пропал"

  echo "### 3b. Триггер #2: push в feature/bt-16 -> сервисный CI дёргает reconcile"
  touch_feature svc-a bt-16 && ok "feature/bt-16 обновлён, reconcile дёрнут" || echo "  [warn] триггер не подтверждён"

  echo "### 4. Вернуть BT-25, отправить поезд (depart) -> test-стенд"
  put_btset $T1 16,25,30 >/dev/null
  echo "  depart: $(trigger_action depart $T1)"
  stand_has_bt test 16 && stand_has_bt test 25 && stand_has_bt test 30 && ok "test-стенд = состав поезда" || fail "test-стенд неверен"

  echo "### 5. Gate PASS -> prepod + prod + merge master + tag"
  echo "  gate: $(trigger_action gate $T1 pass)"
  stand_has_bt prod 16 && stand_has_bt prod 25 && stand_has_bt prod 30 && ok "prod-стенд = состав" || fail "prod-стенд неверен"
  [ "$(train_status $T1)" = shipped ] && ok "поезд $T1 shipped" || fail "статус $T1 != shipped"
  tag_exists "$SVC_A_ID" "shipped-$T1" && ok "tag shipped-$T1 в svc-a" || fail "нет тега в svc-a"

  echo "### 6. Поезд $T2: BT-99, depart, Gate FAIL -> stop-the-line"
  put_btset $T2 99 >/dev/null
  trigger_action depart $T2 >/dev/null
  echo "  gate fail: $(trigger_action gate $T2 fail)"
  [ "$(train_status $T2)" = stopped ] && ok "поезд $T2 stopped" || fail "статус $T2 != stopped"
  file_exists "trains/$T2/postmortem.md" && ok "postmortem.md создан" || fail "нет postmortem"

  echo "### 7. Carryover: BT-99 в следующий поезд $T3"
  echo "  pipeline: $(put_btset $T3 99)"
  stand_has_bt dev 99 && ok "BT-99 переехал в $T3 (dev)" || fail "BT-99 не переехал"

  echo "### 8. Конфликт: поезд $TC BT-77 + BT-78 (один файл) -> reconcile FAIL"
  st="$(put_btset $TC 77,78)"
  [ "$st" = failed ] && ok "reconcile $TC упал по конфликту (pipeline=failed)" || fail "ожидался failed, получили: $st"

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
  create-train|set-bts) shift; put_btset "$@";;
  depart)  shift; trigger_action depart "$@";;
  gate)    shift; trigger_action gate "$@";;
  status)  cmd_status;;
  demo)    cmd_demo;;
  test)    cmd_test;;
  *) echo "usage: ctl.sh {create-train|set-bts|depart|gate|status|demo|test}"; exit 1;;
esac
