#!/usr/bin/env bash
# Краш-тест: создать кучу сервисов + feature-веток (multi-repo + конфликты + кластеры),
# добавить их в каталог, отдать большой поезд на сборку. Цель — всплытие косяков/подгонок.
# Запуск в ci-tools на gitlabnet. Монтировано: /state/state.env. Печатает BTS для make dev.
set -uo pipefail
source /state/state.env
GL="$GITLAB_INTERNAL_URL"
gapi(){ curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@"; }
giturl(){ echo "http://oauth2:$GITLAB_TOKEN@gitlab:8929/$GROUP/$1.git"; }
enc(){ python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

NSVC=${1:-5}; NBT=${2:-24}
echo ">> NSVC=$NSVC NBT=$NBT group=$GROUP gid=$GROUP_ID" >&2

SVCS=()
for i in $(seq 1 "$NSVC"); do
  name="crash-svc-$i"; SVCS+=("$name")
  pid=$(gapi "$GL/api/v4/groups/$GROUP_ID/projects?search=$name" | jq -r ".[]|select(.path==\"$name\")|.id"|head -1)
  [ -z "$pid" ] && pid=$(gapi -X POST "$GL/api/v4/projects" -d "name=$name" -d "path=$name" -d "namespace_id=$GROUP_ID" -d "initialize_with_readme=false"|jq -r .id)
  d=$(mktemp -d)
  printf '{\n  "owner": "base"\n}\n' > "$d/shared.json"
  mkdir -p "$d/features"; printf '{"bt":"baseline"}\n' > "$d/features/baseline.json"
  git -C "$d" init -q -b master; git -C "$d" -c user.email=c@x -c user.name=c add -A >/dev/null
  git -C "$d" -c user.email=c@x -c user.name=c commit -q -m seed
  gapi -X DELETE "$GL/api/v4/projects/$(enc "$GROUP/$name")/protected_branches/master" >/dev/null 2>&1 || true
  git -C "$d" push -q -o ci.skip -f "$(giturl "$name")" master
  echo "   svc $name (id=$pid)" >&2
done

# клоны для веток
declare -A CL
for s in "${SVCS[@]}"; do CL[$s]=$(mktemp -d); git clone -q "$(giturl "$s")" "${CL[$s]}"; done

BTS=""
for n in $(seq 100 $((100+NBT-1))); do
  BTS="$BTS,$n"
  if [ $((n % 5)) -eq 0 ]; then
    # конфликтный кластер: правят один shared.json в crash-svc-1
    t=crash-svc-1; d=${CL[$t]}
    git -C "$d" checkout -q -B "feature/bt-$n" origin/master
    printf '{\n  "owner": "bt-%s"\n}\n' "$n" > "$d/shared.json"
    git -C "$d" -c user.email=c@x -c user.name=c commit -aqm "bt-$n conflict"
    git -C "$d" push -q -o ci.skip -f "$(giturl "$t")" "feature/bt-$n"
  else
    s1=${SVCS[$((n % NSVC))]}; d=${CL[$s1]}
    git -C "$d" checkout -q -B "feature/bt-$n" origin/master
    mkdir -p "$d/features"; printf '{"bt":%s}\n' "$n" > "$d/features/bt-$n.json"
    git -C "$d" -c user.email=c@x -c user.name=c add -A >/dev/null
    git -C "$d" -c user.email=c@x -c user.name=c commit -q -m "bt-$n"
    git -C "$d" push -q -o ci.skip -f "$(giturl "$s1")" "feature/bt-$n"
    if [ $((n % 3)) -eq 0 ]; then
      s2=${SVCS[$(((n+1) % NSVC))]}; d2=${CL[$s2]}
      git -C "$d2" checkout -q -B "feature/bt-$n" origin/master
      mkdir -p "$d2/features"; printf '{"bt":%s,"svc":"%s"}\n' "$n" "$s2" > "$d2/features/bt-$n.json"
      git -C "$d2" -c user.email=c@x -c user.name=c add -A >/dev/null
      git -C "$d2" -c user.email=c@x -c user.name=c commit -q -m "bt-$n multi"
      git -C "$d2" push -q -o ci.skip -f "$(giturl "$s2")" "feature/bt-$n"
    fi
  fi
done
BTS="${BTS#,}"

# добавить crash-svc-* в каталог
echo ">> обновляю catalog..." >&2
cur=$(gapi "$GL/api/v4/projects/$RELEASE_REPO_ID/repository/files/$(enc catalog/repos.yaml)/raw?ref=master")
export SVCS_STR="${SVCS[*]}"
newcat=$(printf '%s' "$cur" | python3 -c '
import sys, yaml, os
d = yaml.safe_load(sys.stdin) or {}
have = {r["name"] for r in d.get("repos", [])}
for s in os.environ["SVCS_STR"].split():
    if s not in have:
        d["repos"].append({"name": s, "mount": s})
print(yaml.safe_dump(d, allow_unicode=True, sort_keys=False), end="")
')
gapi -X PUT "$GL/api/v4/projects/$RELEASE_REPO_ID/repository/files/$(enc catalog/repos.yaml)" \
  -d "branch=master" --data-urlencode "content=$newcat" \
  --data-urlencode "commit_message=crashtest: +$NSVC сервисов в каталог" >/dev/null

echo ">> каталог:" >&2; printf '%s\n' "$newcat" | sed 's/^/   /' >&2
echo "$BTS"
