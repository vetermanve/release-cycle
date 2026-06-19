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
| BT-16, BT-25 | svc-a / svc-b | одиночный backend |
| BT-30 | svc-a + frontend | multi-repo (одноимённые ветки) |
| BT-42, BT-43 | svc-a / svc-b | постоянные демо-фичи |
| BT-77, BT-78 | svc-a (`shared.json`) | конфликтная пара (один ханк) |
| BT-79 | svc-a (`shared.json`) | третий в кластере (тройной конфликт, `mkmerge`) |
| BT-81, BT-82 | svc-a (`flags.json`) | дизъюнктная конфликтная пара (другой файл -> композится) |
| BT-99 | svc-b | дефектный (stop-the-line) |

Описания БТ — в `seed/jira/BT-<N>` (mock-Jira). Состав поезда (`bt-set.yaml`) — только id, без поля migration.

---

## 2. Стенды и deploy-симуляция

Стенд = один nginx-образ, собранный с замердженным контентом ветки `<env>-<DATE>`, запущенный на своём порту.
Стенд деплоится, только если на него указывает `stands/<env>`.

| Стенд | Ветка | Порт |
|-------|-------|------|
| dev | `dev-<DATE>` | 8081 |
| test | `test-<DATE>` | 8082 |
| prepod | `prepod-<DATE>` | 8083 |
| prod | `prod-<DATE>` | 8084 |

Каждая `<env>-<DATE>` собирается reconcile НЕЗАВИСИМО (`master + БТ + merge-ветки`), не срезом.
`deploy_stand.sh` (docker через socket): clone веток репо по каталогу -> webroot (frontend в `/`, бэкенды в
`/<repo>/`, генерим `features/index.json` для любого `*/features` + `meta.json`) -> `docker build stand-<env>:<train>`
-> `docker run`. DinD не нужен — docker-out-of-docker через сокет.

---

## 3. Жизненный цикл (что проигрываем)

1. `make dev DATE= BTS=` -> bt-set + `stands/dev` -> reconcile собирает `dev-DATE` + deploy dev.
2. Push в `feature/bt-N` -> сервисный CI триггерит reconcile -> рефреш активных **dev/test** (prepod/prod нет).
3. `make test DATE=` -> `stands/test=DATE` -> собрать test напрямую (можно минуя dev).
4. `make release DATE=` -> `stands/prepod+prod=DATE` -> собрать предпрод+прод; **master не трогаем**.
5. `make accept DATE=` -> прод принят: `prod-DATE -> master` + tag `shipped-DATE` -> master подмержен -> рефреш активных dev/test; `status: shipped`.
6. `make stop DATE=` (или defect inject) -> `stopped` + `postmortem.md`, БТ -> следующий поезд.
7. Конфликт -> `merge/bt-X-bt-Y` skeleton -> `make resolve` (или `mkmerge` для кластеров) -> `rebuild`.
8. Каденс: `next-train` из `schedule.yaml` (Вт/Чт | daily) + `make tick`.

---

## 4. Инварианты автономной проверки (make check / make demo)

- reconcile: dev-стенд (8081) = состав поезда (meta.json); выдернуть БТ -> пересобран без него.
- multi-repo: BT-30 -> svc-a и frontend на стенде.
- авто-рефреш: push в feature/bt-16 -> dev/test обновлены, prepod/prod нет.
- release: prod-стенд (8084) = состав, master НЕ тронут (до accept не shipped).
- accept: после `make accept` -> `status: shipped`, тег `shipped-DATE`, master содержит merge, dev/test пересобраны.
- stop: `stopped` + postmortem.md; БТ в следующем поезде.
- конфликт: skeleton создан, bt-ветки чистые; resolve -> dev разрешён; дизъюнктные merge-ветки композятся.
- каденс: next-train Вт/Чт корректен.

Все проверки — curl стендов + GitLab API (ветки/теги/pipeline-статусы) -> assert. Без ручных шагов.

---

## 5. Воспроизводимость

- Единая точка входа — `Makefile`.
- `make reset` = полный destroy + bootstrap из seed -> детерминированное состояние.
- `make reset && make demo && make check` зелёный с нуля.
- Весь seed-контент в репо (`seed/`), GitLab — рантайм-носитель.
- Идемпотентность: повтор любой команды не ломает состояние (демо требует чистый старт `make reset`).

---

## 6. Точки входа Makefile

```
make up            # colima-check, GitLab+runner up, seed (идемпотентно)
make down          # стек вниз, снести stand-* контейнеры
make reset         # down + очистка томов + up (чистый прогон)
make demo          # полный сценарий с проверками
make check         # автономные ассерты (curl + API)
make status        # поезда + содержимое стендов
make build DATE= BTS=  # определить поезд (bt-set) без деплоя
make dev DATE= BTS=    # bt-set + привязать dev -> собрать dev
make test DATE=        # привязать test -> собрать test (напрямую)
make release DATE=     # prepod+prod (master не трогает)
make accept DATE=      # merge prod->master + tag + рефреш dev/test
make stop DATE=        # stop-the-line
make resolve REPO= MB= / mkmerge REPO= BTS= / rebuild DATE=   # конфликты
make crashtest [NSVC= NBT=]   # краш-тест на масштабе
make next-train / tick DAYS=  # каденс
make logs
```

---

## 7. Решения этой сборки

- GitLab CE low-mem (omnibus tune): без monitoring/registry/kas/pages, puma 2, sidekiq low.
- Runner: docker executor + bind `/var/run/docker.sock` (docker-out-of-docker, надёжнее DinD локально).
- Порты: GitLab 8929 (http) / 2222 (ssh); стенды 8081-8084.
- Образы стендов: `stand-<env>:<train>`, пересоздаются на каждый deploy.
- Язык tools: bash + python3 (есть в runner-образе) для yaml/json.
