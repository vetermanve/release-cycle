# Полигон частых релизов: что собрано и что проверяем

**Цель:** локально, на GitLab CE + GitLab CI, воспроизвести жизненный цикл релизного поезда по
`docs/01-architecture.md`. Принцип: `make reset` -> `make demo` -> `make check` зелёный с нуля.

**Скоуп:** наша автоматизация — **git-оркестрация** (сборка `<env>-DATE` из master + БТ + merge-ветки,
binding `stands/<env>`). Деплой в полигоне — **простая симуляция**: `deploy_stand.sh` печёт nginx-образ
со статикой ветки и поднимает контейнер `stand-<env>` на порту. НЕ ArgoCD/OpenShift, НЕ digest — это
deploy-слой реальной инфры, вне зоны (фиксируем как риск test-what-you-ship).

---

## 1. Инварианты (полигон зелёный, когда подтверждены)

1. Меняешь `bt-set` или `stands/<env>` -> reconcile пересобирает и деплоит **привязанные** стенды. (ADR-1,2,3)
2. Деплоится только то, на что указывает `stands/<env>`; dev не особенный. (ADR-3,5)
3. Любой стенд собирается **напрямую** (test минуя dev). (ADR-2)
4. Auto-scan по `catalog/repos.yaml` + `ls-remote` фильтр: незатронутые репо не клонируются. (ADR-4)
5. Multi-repo БТ (одноимённая ветка в нескольких репо) собирается во всех. 
6. **Авто-рефреш** (push в `feature/bt-*` / смена `bt-set`) -> только активные **dev/test**; prepod/prod не трогаются. (ADR-5)
7. `make release` катит prepod+prod, master **не трогает**; `make accept` -> merge `prod->master` + tag + рефреш dev/test. (ADR-6)
8. Stop-the-line: `make stop` -> `status: stopped` + `postmortem.md`, БТ -> следующий поезд. (ADR-9)
9. Конфликт -> отложенный merge -> `merge/bt-X-bt-Y` skeleton -> `resolve` -> сборка; **bt-ветки чистые**. (ADR-8)
10. Все merge-ветки (БТ⊆поезда) включаются; дизъюнктные композятся; кластеры 3+ через `mkmerge`. (ADR-8)
11. Каденс Вт/Чт vs daily из `schedule.yaml` + симулированные часы (`make tick`/`next-train`).
12. `release-page.md` (doc-as-code), описания БТ из mock-Jira; миграции — по факту (`*-migrations` в каталоге).

> Вне инвариантов (deploy-слой): реальный rollout, digest/reproducible build, строгий test-what-you-ship.

---

## 2. Стек полигона

| Компонент | Реализация |
|-----------|------------|
| Git + CI | GitLab CE + gitlab-runner (docker executor, socket-mount) в compose (`infra/gitlab/`) |
| Job-образ | `ci-tools` (git+python+jq+docker-cli, `infra/ci-tools/`) |
| Микросервисы | `svc-a`, `svc-b` (backend JSON), `frontend` (HTML, live-доска) |
| Миграции | `*-migrations` репо в каталоге (по факту, как код) — поддержано, в демо-фикстурах нет |
| Релиз-репо | `catalog/`, `schedule.yaml`, `stands/`, `trains/`, `.gitlab-ci.yml`, `tools/` |
| mock-Jira | nginx, `seed/jira/BT-<N>` -> `/rest/api/2/issue/BT-<N>` (`:8090`) |
| Deploy-симуляция | `deploy_stand.sh`: nginx-образ `stand-<env>:<train>` -> контейнер на порту |
| Стенды | dev :8081, test :8082, prepod :8083, prod :8084 |
| Гейт | внешний сигнал: `make release`/`accept` (pass) или `make stop` (fail) |
| Часы/каденс | локальный `.state/clock` + `schedule.yaml` (`make tick`/`next-train`) |
| Краш-тест | `make crashtest` (куча репо/веток/конфликтов, большой поезд) |
| Оркестрация | `Makefile` + `tools/ctl.sh` (через GitLab API) |

---

## 3. Структура репозитория

```
release_cycle/
├─ docs/                       # 01-architecture, 02-polygon-plan, 03-build-task
├─ .env(.template)             # конфиг (порты/образы/пароль/сеть)
├─ infra/{gitlab,ci-tools,mock-jira}/
├─ seed/                       # начинка репозиториев GitLab (засев при bootstrap)
│  ├─ svc-a/ svc-b/ frontend/  # master-контент сервисов
│  ├─ _features/<svc>/bt-<N>/  # фикстуры feature-веток
│  ├─ jira/BT-<N>              # фикстуры Jira-issue
│  └─ release-repo/            # catalog, schedule, stands/, trains/, .gitlab-ci.yml, tools/
├─ tools/                      # bootstrap.sh, ctl.sh, crashtest.sh, cadence.py
├─ .state/                     # рантайм (токены, id, clock) — gitignored
└─ Makefile
```

GitLab — рантайм-носитель; `seed/` -> засев при `make up` (reproducible bootstrap).

---

## 4. Что реализовано (по слоям)

- **Bootstrap** (`make up`): GitLab+runner+mock-jira в compose; `bootstrap.sh` создаёт root (через rails),
  проекты в группе `polygon`, заливает seed + feature-ветки, group CI-vars, регистрирует runner.
- **Reconcile** (`seed/release-repo/tools/reconcile.sh`): единый — сборка `<env>-DATE` + деплой привязанных
  стендов; отложенный merge + карантин конфликтов; `ls-remote` фильтр; `accept_train`.
- **Промоушн** (`stands/<env>`): `make dev/test/release/accept/stop` -> коммит binding -> reconcile.
- **Конфликты:** `make resolve` (skeleton), `make mkmerge` (кластеры), `make rebuild`.
- **Deploy-симуляция** (`deploy_stand.sh` + `stand_assets.py`): nginx-образ на стенд, live-доска.
- **doc-as-code** (`gen_release_page.py`): release-page из Jira.
- **Каденс** (`cadence.py`): `next-train`/`tick`.

---

## 5. Команды

```
make up / down / reset           # поднять+засеять / снести / сброс и заново
make demo / check / status       # полный сценарий с проверками / ассерты / статус
make build  DATE= BTS=           # определить поезд (bt-set) без деплоя
make dev    DATE= BTS=           # bt-set + привязать dev -> собрать dev
make test   DATE=                # привязать test -> собрать test (напрямую)
make release DATE=               # prepod+prod (master не трогает)
make accept DATE=                # merge prod->master + tag + рефреш активных dev/test
make stop   DATE=                # stop-the-line
make resolve REPO= MB= / mkmerge REPO= BTS= / rebuild DATE=   # конфликты
make crashtest [NSVC= NBT=]      # краш-тест на масштабе
make next-train / tick [DAYS=]   # каденс
```

---

## 6. Ограничения

- **GitLab CE тяжёлый** (RAM/диск, ~4 ГБ). Единственный тяжёлый компонент.
- **Deploy — симуляция** (nginx-образ на стенд), не воспроизводит ArgoCD/OpenShift.
- **`make demo` не идемпотентен** к остаточным merge-веткам прошлых прогонов — контракт `make reset && make demo`.
- **Производительность:** `ls-remote` фильтр уже не клонирует лишнее; на сотнях репо — кэш/параллелизм при росте.
