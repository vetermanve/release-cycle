# Полигон частых релизов (release train lifecycle)

Локальный воспроизводимый стенд, который на демо-репозиториях проигрывает полный
жизненный цикл релизного поезда: feature-ветки -> reconcile dev -> отправление ->
гейт -> предпрод -> прод, плюс stop-the-line и конфликты. Всё на локальном GitLab + GitLab CI.

Концепция и решения: `docs/01-architecture.md`, план: `docs/02-polygon-plan.md`,
контракт сборки: `docs/03-build-task.md`.

## Что внутри

- **GitLab CE + runner** в docker-compose (`infra/gitlab/`).
- **4 репозитория** (создаются автоматически в группе `polygon`):
  - `svc-a`, `svc-b` — backend, отдают JSON из `features/`;
  - `frontend` — HTML, каждую секунду фетчит JSON бэкендов и рисует live-доску стенда;
  - `release-repo` — оркестрация: `bt-set.yaml`, `catalog`, `schedule`, CI-логика поезда. Состав поезда = id БТ; **описания БТ берутся из Jira по API**.
- **mock-jira** (`:8090`) — отдаёт БТ Jira-образным JSON по `/rest/api/2/issue/BT-<N>` (фикстуры в `seed/jira/`). Моделирует «БТ живут в Jira».
- **4 стенда** = nginx-образы с замердженным контентом ветки: `dev :8081`, `test :8082`, `prepod :8083`, `prod :8084`.

## Требования

- docker (colima/Docker Desktop), ~12 ГБ RAM и ~6 ГБ свободного диска под GitLab.
- make, curl.

## Быстрый старт

```bash
make up        # поднять GitLab+runner, засеять репозитории (3-6 мин на первый старт)
make demo      # проиграть полный цикл с проверками (создаёт поезда, гоняет пайплайны)
make check     # автономные ассерты конечного состояния
make status    # статус поездов и содержимое стендов
```

Открыть в браузере:
- GitLab: http://localhost:8929 (root / `Kx7Qm2Zp9Lt4Bv8Rn`) — пайплайны, ветки, MR.
- Стенды: http://localhost:8081 (dev), :8082 (test), :8083 (prepod), :8084 (prod).
  Доска обновляется раз в секунду и показывает, какие БТ «доехали» на этот стенд.

## Ручной сценарий (команда = стенд, куда катит)

```bash
make dev     DATE=26.06.09 BTS=16,25     # собрать поезд -> dev-стенд (8081)
make dev     DATE=26.06.09 BTS=16,25,30  # добавить multi-repo БТ-30 (пересборка dev)
make test    DATE=26.06.09               # -> тест-стенд (8082), срез test-
make release DATE=26.06.09               # -> предпрод (8083) + прод (8084), merge master + тег
# при дефекте на тесте вместо release:
make stop    DATE=26.06.09               # stop-the-line: поезд остановлен + postmortem
```

## Команды

| Команда | Действие |
|---------|----------|
| `make up` | поднять и засеять |
| `make demo` | полный сценарий с проверками |
| `make check` | ассерты конечного состояния |
| `make status` | поезда + стенды |
| `make dev DATE= BTS=` | собрать поезд -> dev-стенд (reconcile) |
| `make test DATE=` | -> тест-стенд (срез test-) |
| `make release DATE=` | -> предпрод + прод, merge master + тег |
| `make stop DATE=` | stop-the-line (дефект на тесте) |
| `make inject-defect DATE= BT=` | демо stop-the-line |
| `make next-train` | ближайшая дата поезда по `schedule.yaml` и часам |
| `make tick DAYS=` | прокрутить симулированные часы (каденс Вт/Чт vs daily) |
| `make logs` | логи GitLab/runner |
| `make down` | остановить (тома сохранить) |
| `make reset` | полный сброс и заново (воспроизводимость) |

## Воспроизводимость

`make reset && make demo && make check` поднимает всё с нуля и проходит зелёным.
Весь seed-контент в `seed/`, GitLab — рантайм-носитель. Состояние (токены, id проектов)
кладётся в `.state/` при bootstrap.

## Как это устроено (GitOps)

- **`bt-set.yaml`** (состав поезда) меняется -> CI **reconcile**: пересборка `dev-DATE` + dev-стенд.
- **`stands/<slot>`** (по файлу на стенд: `stands/test`, `stands/prepod`, `stands/prod` — в каждом дата поезда)
  меняется -> CI **promote**: довести ветку (`test-`/`release-`) и задеплоить. Промоушн = git-правка
  (UI или `make test/release`). По файлу на стенд = нет RMW-гонки общего файла.
- `seed/release-repo/.gitlab-ci.yml` — джобы `reconcile` (changes `trains/**/bt-set.yaml`) и
  `promote` (changes `stands/**`).
- `seed/release-repo/tools/` — `reconcile.sh`, `promote.sh`, `deploy_stand.sh` (печёт nginx-образ стенда),
  `gen_release_page.py` (doc-as-code, описания БТ из Jira).
- `seed/_service-ci/.gitlab-ci.yml` — push в `feature/bt-*` дёргает reconcile (multi-project trigger).
- `tools/bootstrap.sh` — засев GitLab; `tools/ctl.sh` — обёртки (коммитят bt-set/stands.yaml через Commits API).
- **Rollback:** `git revert` коммита `stands/<slot>` -> CI откатывает стенд на прошлый поезд.

## Траблшутинг

- `docker не запущен` -> `colima start` (или запустить Docker Desktop).
- GitLab долго стартует на первом `make up` — это нормально (миграции БД).
- Стенд не открывается -> `make status` покажет, поднят ли контейнер; `docker logs stand-dev`.
- Полный сброс: `make reset`.
