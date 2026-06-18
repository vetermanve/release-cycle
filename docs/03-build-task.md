# Build-задача: полигон жизненного цикла релиз-трейна

**Цель:** локальная, воспроизводимая, перепрогоняемая инсталляция, которая на демо-репозиториях проигрывает полный жизненный цикл релизного поезда (`docs/01-architecture.md`). Claude собирает и **автономно прогоняет** сам; пользователь потом показывает руками.

---

## 1. Демо-контент (что катаем)

Четыре репозитория в локальном GitLab:

| Репо | Тип | Содержимое |
|------|-----|------------|
| `svc-a` | backend | `features/` — по файлу на БТ (`bt-16.json` и т.п.); deploy генерит `features/index.json` |
| `svc-b` | backend | то же, независимый сервис |
| `frontend` | frontend | `index.html` + JS: каждую 1с фетчит `/svc-a/...` и `/svc-b/...`, рисует live-доску "что на этом стенде" |
| `release-repo` | оркестрация | `catalog/repos.yaml`, `schedule.yaml`, `trains/<DATE>/bt-set.yaml`, `.gitlab-ci.yml`, `tools/` (описания БТ — из Jira по API) |
| `mock-jira` | имитация Jira | `seed/jira/BT-<N>` -> `/rest/api/2/issue/BT-<N>`; release-page тянет summary/status |

Каждый БТ = отдельный файл в затронутом сервисе (`features/bt-N.json`) -> merge разных БТ не конфликтует (happy path). Конфликт-сценарий — отдельный БТ, трогающий общий файл.

### Фикстуры БТ (детерминированы в seed)

| БТ | Репо | Назначение демо |
|----|------|-----------------|
| BT-16 | svc-a | одиночный backend |
| BT-25 | svc-b | одиночный backend |
| BT-30 | svc-a + frontend | multi-repo (одноимённые ветки) |
| BT-77 | svc-a | конфликт (трогает общий `shared.json`) |
| BT-99 | svc-b | дефектный (gate fail при inject) |

---

## 2. Стенды и deploy-симуляция

Стенд = один nginx-образ, собранный с замердженным контентом ветки, запущенный на своём порту.

| Стенд | Ветка | Порт |
|-------|-------|------|
| dev | `dev-<DATE>` | 8081 |
| test | `test-<DATE>` | 8082 |
| prepod | `release-<DATE>` | 8083 |
| prod | `master` (после merge) | 8084 |

Deploy-job (GitLab CI, docker через socket):
1. clone env-ветку 3 репо;
2. собрать webroot: frontend -> `/`, svc-a -> `/svc-a/`, svc-b -> `/svc-b/`; сгенерить `features/index.json` на бэкенд и `meta.json` (train, env, БТ, время);
3. `docker build` образ `stand-<env>:<train>` с этим webroot (FROM nginx:alpine);
4. `docker rm -f stand-<env>; docker run -d --name stand-<env> -p <port>:80 stand-<env>:<train>`.

Это и есть "разливаем статические файлы на разные docker-образы". DinD не нужен — docker-out-of-docker через сокет.

---

## 3. Жизненный цикл (что проигрываем)

1. Разработчик добавляет БТ в `trains/<DATE>/bt-set.yaml` (MR в release-repo).
2. CI release-repo (reconcile): пересборка `dev-<DATE>` от master + merge feature-веток по auto-scan -> deploy dev-стенд. Live-доска dev показывает набор БТ.
3. Push в `feature/bt-N` -> сервисный CI триггерит reconcile (multi-project trigger) -> dev пересобран.
4. Отправление (`make train` / cron): `open->departed`, cut `test-<DATE>`, deploy test-стенд.
5. Gate-сигнал (`make gate RESULT=pass`): cut `release-<DATE>`, deploy prepod; затем prod: merge `release-<DATE>`->`master` во всех репо, deploy prod, `status: shipped`.
6. Gate fail (`make gate RESULT=fail` / defect inject): `stopped`, `postmortem.md`, БТ -> следующий поезд.
7. Каденс: `next-train` из `schedule.yaml` (Вт/Чт | daily) + симулированные часы (`make tick`).

---

## 4. Инварианты автономной проверки (make test)

- reconcile: bt-set с BT-16,BT-25 -> dev-стенд (8081) отдаёт оба в meta.json.
- pull БТ: убрать BT-25 -> dev пересобран без него.
- multi-repo: BT-30 -> и svc-a, и frontend на стенде содержат его.
- конфликт: BT-77 + второй на общий файл -> pipeline reconcile красный.
- depart: test-стенд (8082) = состав поезда.
- gate pass: prod-стенд (8084) = состав; master содержит merge; тег есть.
- gate fail: stopped + postmortem.md; БТ в следующем поезде.
- каденс: next-train Вт/Чт корректен; tick на daily меняет поведение.

Все проверки — curl стендов + GitLab API (ветки/теги/pipeline-статусы) -> assert. Без ручных шагов.

---

## 5. Воспроизводимость

- Единая точка входа — `Makefile`.
- `make reset` = полный destroy + bootstrap из seed -> детерминированное состояние.
- `make reset && make demo && make test` зелёный с нуля.
- Весь seed-контент в репо (`*-seed/`), GitLab — рантайм-носитель.
- Идемпотентность: повтор любой команды не ломает состояние.

---

## 6. Точки входа Makefile

```
make up            # colima-check, GitLab+runner up, seed (идемпотентно)
make down          # стек вниз, снести stand-* контейнеры
make reset         # down + очистка томов + up (чистый прогон)
make demo          # проиграть полный happy-path лайфцикл
make test          # автономные ассерты (curl + API)
make status        # поезда + содержимое стендов
make train DATE=   # отправление
make gate DATE= RESULT=pass|fail
make inject-defect SVC= BT=
make tick DAYS=    # симулированные часы
make logs
```

---

## 7. Решения этой сборки

- GitLab CE low-mem (omnibus tune): без monitoring/registry/kas/pages, puma 2, sidekiq low.
- Runner: docker executor + bind `/var/run/docker.sock` (docker-out-of-docker, надёжнее DinD локально).
- Порты: GitLab 8929 (http) / 2222 (ssh); стенды 8081-8084.
- Образы стендов: `stand-<env>:<train>`, пересоздаются на каждый deploy.
- Язык tools: bash + python3 (есть в runner-образе) для yaml/json.
