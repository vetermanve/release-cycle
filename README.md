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

## Политика деплоя (единая)

Стенд деплоит **только тот поезд, на который указывает `stands/<env>`**. dev не особенный — те же правила.
`reconcile` собирает `<env>-DATE` = `master + БТ поезда + merge-ветки` (симметрично для dev/test/prepod/prod)
и деплоит **привязанные** стенды. Любой стенд можно собрать **напрямую**, минуя другие (например, починить test минуя dev).

## Ручной сценарий (команда = стенд)

```bash
make dev     DATE=26.06.09 BTS=16,25     # bt-set + привязать dev -> dev-стенд (8081)
make dev     DATE=26.06.09 BTS=16,25,30  # БТ-30 (пересборка привязанного dev)
make test    DATE=26.06.09               # привязать test -> собрать test-стенд (8082) напрямую
make release DATE=26.06.09               # привязать prepod+prod -> (8083)+(8084), merge master + тег
make stop    DATE=26.06.09               # дефект: stop-the-line + postmortem
# собрать test, минуя dev:
make build   DATE=26.06.30 BTS=42        # определить поезд (bt-set), ничего не деплоить
make test    DATE=26.06.30               # test-стенд собран напрямую, dev не тронут
```

## Команды

| Команда | Действие |
|---------|----------|
| `make up` | поднять и засеять |
| `make demo` | полный сценарий с проверками |
| `make check` | ассерты конечного состояния |
| `make status` | поезда + стенды |
| `make build DATE= BTS=` | определить поезд (bt-set) без привязки к стенду |
| `make dev DATE= BTS=` | bt-set + привязать dev -> собрать dev-стенд |
| `make test DATE=` | привязать test -> собрать test-стенд (напрямую) |
| `make release DATE=` | привязать prepod+prod -> собрать + merge master + тег |
| `make stop DATE=` | stop-the-line (дефект) |
| `make rebuild DATE=` | пересобрать привязанные стенды поезда (после resolve) |
| `make resolve REPO= MB=` / `make mkmerge REPO= BTS=` | резолв конфликта (демо) |
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

- **`stands/<env>`** (по файлу на стенд: `stands/dev|test|prepod|prod` — в каждом дата поезда) = desired state
  «какой поезд на стенде». Меняется stands/ ИЛИ bt-set ИЛИ feature -> CI **reconcile**: пересобирает и
  деплоит ПРИВЯЗАННЫЕ стенды. `<env>-DATE = master + БТ поезда + merge-ветки` — симметрично для всех env.
- **Единая политика:** деплоится только то, на что указывает `stands/<env>`. Любой стенд собирается напрямую
  (можно починить test минуя dev). prod дополнительно: merge в master + tag.
- `seed/release-repo/.gitlab-ci.yml` — один джоб `reconcile` (changes `trains/**/bt-set.yaml` или `stands/**`).
- `seed/release-repo/tools/` — `reconcile.sh` (сборка+деплой привязанных стендов), `deploy_stand.sh`
  (печёт nginx-образ стенда), `gen_release_page.py` (doc-as-code, описания БТ из Jira).
- `seed/_service-ci/.gitlab-ci.yml` — push в `feature/bt-*` дёргает reconcile (multi-project trigger).
- `tools/bootstrap.sh` — засев GitLab; `tools/ctl.sh` — обёртки (коммитят bt-set/stands через Commits API).
- **Rollback:** `git revert` коммита `stands/<env>` -> reconcile откатывает стенд на прошлый поезд.
- **Конфликты:** reconcile мержит отложенно (конфликт -> отложить -> повтор); при настоящем
  конфликте находит пару и создаёт `merge/bt-X-bt-Y` (skeleton), падает. Разраб разрешает в
  этой ветке (`make resolve REPO= MB=` — демо-резолв), `make rebuild DATE=` пересобирает.
  feature-ветки остаются чистыми; сборка мержит merge-ветку (резолв) + все feature (новые коммиты).
- **Сборка включает ВСЕ merge-ветки** с БТ⊆поезда (могут разрешать разные конфликты — все нужны).
  Дизъюнктные (`merge/bt-42-bt-43` + `merge/bt-77-bt-78`) композятся. Две ветки на один ханк по-разному
  -> конфликт между ними (корректно). Дисциплина: один конфликт-кластер = одна merge-ветка.
- **Тройные+ конфликты — вручную:** reconcile авто-создаёт только парные skeleton. Для кластера 3+
  `make mkmerge REPO=svc-a BTS=77,78,79` -> `merge/bt-77-bt-78-bt-79` (подключается по имени, БТ⊆поезда).
  Эскалация пары в тройку = пересоздать тройную и **удалить** парную (один ханк — одна ветка).

## Траблшутинг

- `docker не запущен` -> `colima start` (или запустить Docker Desktop).
- GitLab долго стартует на первом `make up` — это нормально (миграции БД).
- Стенд не открывается -> `make status` покажет, поднят ли контейнер; `docker logs stand-dev`.
- Полный сброс: `make reset`.
