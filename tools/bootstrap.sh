#!/usr/bin/env bash
# Bootstrap GitLab: токен, группа, проекты, seed-контент + feature-ветки, group CI-vars,
# trigger-токен, регистрация раннера. Идемпотентно. Запускается в ci-tools на gitlabnet.
# Монтировано: /seed (ro), /out (rw, -> .state на хосте), /var/run/docker.sock.
set -euo pipefail

# Все настройки приходят из .env (docker run --env-file)
GL="${GITLAB_INTERNAL_URL:-http://gitlab:8929}"
ROOT_PW="${GITLAB_ROOT_PASSWORD:?GITLAB_ROOT_PASSWORD не задан}"
GROUP="${GROUP:-polygon}"
NETWORK="${NETWORK:-relcycle_gitlabnet}"
JIRA_URL="${JIRA_URL:-http://mock-jira}"
OUT="/out"
RUNNER_CONTAINER="relcycle_runner"

echo ">> ждём готовности GitLab rails..."
ready=0
for i in $(seq 1 100); do
  if docker exec relcycle_gitlab gitlab-rails runner 'puts "OK" if User.count >= 0' 2>/dev/null | grep -q OK; then
    ready=1; break
  fi
  echo "   ... ($i)"; sleep 6
done
[ "$ready" = 1 ] || { echo "!! rails не готов"; exit 1; }
echo ">> rails готов"

# гарантируем root-админа (GitLab не всегда сеет его сам)
docker exec relcycle_gitlab gitlab-rails runner "
pw='${ROOT_PW}'
u = User.find_by_username('root')
if u.nil?
  u = Users::CreateService.new(nil, username:'root', name:'Administrator', email:'admin@example.com', password: pw, password_confirmation: pw, skip_confirmation: true).execute
  u.update!(admin: true) if u.persisted?
else
  u.password=pw; u.password_confirmation=pw; u.password_automatically_set=false; u.save!
end
puts(u && u.persisted? ? 'ROOT_READY' : 'ROOT_FAIL')
" 2>&1 | grep -q ROOT_READY || { echo '!! не удалось создать root'; exit 1; }
echo ">> root готов"

# PAT root через rails (надёжно, без oauth)
TOK="$(docker exec relcycle_gitlab gitlab-rails runner \
  "t=User.find_by_username('root').personal_access_tokens.create!(name:'polygon-'+Time.now.to_i.to_s, scopes:['api','write_repository','sudo'], expires_at: 365.days.from_now); puts t.token" \
  2>/dev/null | grep -oE 'glpat-[A-Za-z0-9_-]+' | tail -1)"
[ -n "$TOK" ] || { echo "!! не создан PAT через rails"; exit 1; }
echo ">> PAT создан"

gapi() { curl -sS -H "PRIVATE-TOKEN: $TOK" "$@"; }
GITURL() { echo "http://oauth2:${TOK}@gitlab:8929/${GROUP}/$1.git"; }

# группа
GID="$(gapi "$GL/api/v4/groups?search=$GROUP" | jq -r ".[] | select(.path==\"$GROUP\") | .id" | head -1)"
if [ -z "$GID" ]; then
  GID="$(gapi -X POST "$GL/api/v4/groups" -d "name=$GROUP" -d "path=$GROUP" -d "visibility=internal" | jq -r .id)"
fi
echo ">> группа $GROUP id=$GID"

create_project() {
  local name="$1" pid
  pid="$(gapi "$GL/api/v4/groups/$GID/projects?search=$name" | jq -r ".[] | select(.path==\"$name\") | .id" | head -1)"
  if [ -z "$pid" ]; then
    pid="$(gapi -X POST "$GL/api/v4/projects" \
      -d "name=$name" -d "path=$name" -d "namespace_id=$GID" \
      -d "initialize_with_readme=false" | jq -r .id)"
  fi
  echo "$pid"
}

SVCA="$(create_project svc-a)"
SVCB="$(create_project svc-b)"
FRONT="$(create_project frontend)"
REL="$(create_project release-repo)"
echo ">> проекты: svc-a=$SVCA svc-b=$SVCB frontend=$FRONT release-repo=$REL"

seed_repo() {  # name srcdir features(yes/no) ci(yes/no)
  local name="$1" src="$2" feats="$3" ci="$4" d
  d="$(mktemp -d)"
  cp -a "$src/." "$d/"
  [ "$ci" = yes ] && cp /seed/_service-ci/.gitlab-ci.yml "$d/.gitlab-ci.yml"
  git -C "$d" init -q -b master
  git -C "$d" config user.email ci@polygon.local; git -C "$d" config user.name polygon-ci
  git -C "$d" add -A
  git -C "$d" commit -q -m "seed: initial"
  # снять авто-защиту master, чтобы bootstrap был перезапускаемым (idempotent force-push)
  gapi -X DELETE "$GL/api/v4/projects/${GROUP}%2F${name}/protected_branches/master" >/dev/null 2>&1 || true
  git -C "$d" push -q -o ci.skip -f "$(GITURL "$name")" master
  if [ "$feats" = yes ] && [ -d "/seed/_features/$name" ]; then
    for btdir in /seed/_features/"$name"/*/; do
      [ -d "$btdir" ] || continue
      local bt; bt="$(basename "$btdir")"   # bt-16
      git -C "$d" checkout -q -B "feature/$bt" master
      cp -a "$btdir." "$d/"
      git -C "$d" add -A
      git -C "$d" commit -q -m "feat($bt): demo change"
      git -C "$d" push -q -o ci.skip -f "$(GITURL "$name")" "feature/$bt"
      git -C "$d" checkout -q master
    done
  fi
  echo "   seeded $name"
}

echo ">> заливаю seed..."
seed_repo svc-a       /seed/svc-a       yes yes
seed_repo svc-b       /seed/svc-b       yes yes
seed_repo frontend    /seed/frontend    yes yes
seed_repo release-repo /seed/release-repo no  no

# group CI/CD variables
set_var() {  # key value
  local k="$1" v="$2"
  gapi -X POST "$GL/api/v4/groups/$GID/variables" \
    -d "key=$k" --data-urlencode "value=$v" -d "masked=false" -d "protected=false" >/dev/null 2>&1 \
  || gapi -X PUT "$GL/api/v4/groups/$GID/variables/$k" \
    --data-urlencode "value=$v" -d "masked=false" -d "protected=false" >/dev/null
}

# trigger-токен в release-repo
TRIG="$(gapi "$GL/api/v4/projects/$REL/triggers" | jq -r '.[0].token // empty')"
[ -n "$TRIG" ] || TRIG="$(gapi -X POST "$GL/api/v4/projects/$REL/triggers" -d "description=polygon" | jq -r .token)"

set_var GITLAB_TOKEN "$TOK"
set_var GITLAB_INTERNAL_URL "$GL"
set_var RELEASE_REPO_ID "$REL"
set_var RELEASE_TRAIN_TRIGGER_TOKEN "$TRIG"
set_var JIRA_URL "$JIRA_URL"
set_var NETWORK "$NETWORK"
set_var STAND_DEV_PORT "${STAND_DEV_PORT:-8081}"
set_var STAND_TEST_PORT "${STAND_TEST_PORT:-8082}"
set_var STAND_PREPOD_PORT "${STAND_PREPOD_PORT:-8083}"
set_var STAND_PROD_PORT "${STAND_PROD_PORT:-8084}"
echo ">> group CI-vars выставлены"

# runner: пересоздать одного instance-раннера
RTOK="$(gapi -X POST "$GL/api/v4/user/runners" \
  -d "runner_type=instance_type" -d "run_untagged=true" -d "description=polygon" \
  | jq -r '.token // empty')"
[ -n "$RTOK" ] || { echo "!! не создан runner token"; exit 1; }
docker exec "$RUNNER_CONTAINER" gitlab-runner unregister --all-runners >/dev/null 2>&1 || true
docker exec "$RUNNER_CONTAINER" gitlab-runner register --non-interactive \
  --url "$GL" --token "$RTOK" \
  --executor docker --docker-image "${CI_TOOLS_IMAGE:-ci-tools:latest}" \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --docker-network-mode "$NETWORK" \
  --docker-pull-policy "if-not-present" \
  --clone-url "$GL"
echo ">> runner зарегистрирован"

# state -> хост
mkdir -p "$OUT"
cat > "$OUT/state.env" <<EOF
GITLAB_TOKEN=$TOK
GITLAB_URL=http://localhost:${GITLAB_HTTP_PORT:-8929}
GITLAB_INTERNAL_URL=$GL
GROUP=$GROUP
GROUP_ID=$GID
RELEASE_REPO_ID=$REL
SVC_A_ID=$SVCA
SVC_B_ID=$SVCB
FRONTEND_ID=$FRONT
TRIGGER_TOKEN=$TRIG
EOF
echo ">> bootstrap завершён. state -> .state/state.env"
