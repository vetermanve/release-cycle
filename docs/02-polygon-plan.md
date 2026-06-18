# Полигон частых релизов: план обкатки

**Цель:** локально, на GitLab CE + GitLab CI, воспроизвести жизненный цикл релизного поезда и проверить инварианты архитектуры (`docs/01-architecture.md`) до реальной инфры. Принцип: `destroy -> apply -> работает`, fast-forward по дням без реального ожидания.

**Скоуп (важно):** наша автоматизация — **git-оркестрация веток** (намерживание feature -> стенд-ветки). Деплой в полигоне — **простая симуляция на GitLab CI** (job поднимает/обновляет compose-стек по ветке, чисто визуализация "ветка приехала на стенд"). НЕ ArgoCD/OpenShift, НЕ digest/reproducible build — это deploy-слой реальной инфры, вне зоны.

---

## 1. Что проверяем (инварианты)

Полигон зелёный, когда подтверждены:

1. Меняешь `bt-set.yaml` -> reconcile-pipeline релиз-трейна пересобирает `dev-DATE` во всех затронутых репо. (ADR-1,2)
2. Push в `feature/bt-N` -> сервисный CI триггерит pipeline релиз-трейна (multi-project trigger) -> `dev-DATE` пересобран. (раздел 4 арх.)
3. Auto-scan находит ровно затронутые репо по `catalog/repos.yaml`, остальные пропускает. (ADR-4)
4. Выдернуть БТ (убрать строку) -> `dev-DATE` пересобран без него, без un-merge. (ADR-2)
5. Конфликт merge -> pipeline красный, чинится в feature-ветке, не в стенд-ветке. (ADR-7)
6. Отправление: `status open->departed`, срез `test-DATE` без изменений, простой deploy-job показывает версию на тест-стенде.
7. Гейт-сигнал pass -> срез `release-DATE`, deploy предпрод/прод, merge в `master` + тег. (раздел 5 арх.)
8. Гейт-сигнал fail (defect injection) -> stop-the-line, `status: stopped`, `postmortem.md`, БТ уезжает в следующий поезд. (ADR-8)
9. Migration-репо мержатся в стенд-ветки наравне с сервисом; фаза `migration:` попадает в release-page. (ADR-6)
10. Каденс Вт/Чт и daily считаются из `schedule.yaml`; симулированные часы прокручивают дни.
11. `release-page.md` генерируется doc-as-code из состава поезда.

> Вне инвариантов (deploy-слой, не проверяем): test-what-you-ship, digest-verify, реальный rollback rollout.

---

## 2. Стек полигона

| Компонент | Реализация | Заметка |
|-----------|------------|---------|
| Git + CI | GitLab CE + gitlab-runner (docker executor) в compose | ~4 ГБ RAM под GitLab; единственный тяжёлый компонент |
| Микросервисы | 3 fake-сервиса svc-a/b/c, HTTP, отдают version+BT-set | минимальный рантайм |
| Миграции | svc-X-migrations, Liquibase changelog, отдельный репо | мержится наравне с сервисом |
| Релиз-репо | `catalog/`, `schedule.yaml`, `trains/`, `.gitlab-ci.yml` | source of truth + pipelines поезда |
| Deploy-симуляция | GitLab CI job -> compose стек на стенд | простая, по ветке dev-/test-/release- |
| Стенды dev/test/prepod/prod | compose-проекты (COMPOSE_PROJECT_NAME) | визуализация версии на стенде |
| Гейт | внешний сигнал pass/fail (ручной/scripted) -> в pipeline | тесты не гоняем сами |
| Симулированные часы | файл/env "текущая дата", train pipeline читает | fast-forward каденса |
| Defect injection | флаг, дающий гейту fail | проверка stop-the-line |
| Оркестрация | Makefile: up/down/train/inject/tick/status | единая точка входа |

---

## 3. Структура репозитория полигона

```
release_cycle/
├─ docs/                       # 01-architecture.md, 02-polygon-plan.md
├─ infra/
│  ├─ gitlab/                  # compose: GitLab CE + runner
│  └─ stands/                  # compose-шаблон стенда (env, ветка)
├─ services/
│  ├─ svc-a/  (Dockerfile, контракт)   + svc-a-migrations/
│  ├─ svc-b/                            + svc-b-migrations/
│  └─ svc-c/                            + svc-c-migrations/
├─ release-repo-seed/          # начинка релиз-репо: catalog, schedule, .gitlab-ci.yml, ci-шаблоны
├─ ci/                         # job-шаблоны: reconcile, train, deploy-sim, doc-as-code
├─ tools/                      # release-page генератор, next-train, reconcile-логика
└─ Makefile
```

GitLab — source of truth в рантайме; `*-seed/` — чем засеваем при `make up` (reproducible bootstrap).

---

## 4. Фазы (каждая с критерием приёмки)

### Фаза 0 — Bootstrap
- compose: GitLab CE + runner. Скрипт засева: группы/проекты (svc-a/b/c + их migrations + release-repo), залить seed, зарегистрировать runner.
- **Приёмка:** `make up` с нуля -> GitLab жив, репо созданы, runner онлайн; `make down` чистит всё.

### Фаза 1 — Reconcile dev-DATE (ядро)
- `.gitlab-ci.yml` релиз-репо: reconcile-job на изменение `trains/*/bt-set.yaml`.
- Auto-scan по `catalog/repos.yaml`; пересборка `dev-DATE` от master + merge `feature/bt-N` по возрастанию N; force-push; запись `affected-repos.lock`; генерация `release-page.md`.
- Multi-project trigger: сервисный CI на `feature/bt-*` дёргает pipeline релиз-трейна.
- **Приёмка:** инварианты 1-5.

### Фаза 2 — Deploy-симуляция
- GitLab CI deploy-job: на ветке dev-/test-/release- поднимает/обновляет compose-стек стенда, контейнер отдаёт version+BT-set.
- **Приёмка:** инвариант 6. `make status` показывает версию на каждом стенде = состав соответствующей ветки.

### Фаза 3 — Отправление + промоушн по гейту
- train pipeline: `open->departed`, срез `test-DATE`, deploy тест-стенд; ожидание гейт-сигнала; pass -> срез `release-DATE`, deploy предпрод/прод, merge `master` + тег, `status: shipped`.
- **Приёмка:** инварианты 7, 11.

### Фаза 4 — Stop-the-line
- defect injection -> гейт fail -> `status: stopped`, `postmortem.md` стаб, БТ выпадает, перенос в следующий поезд (Вт/Чт и daily).
- **Приёмка:** инвариант 8.

### Фаза 5 — Миграции
- svc-a-migrations: `feature/bt-N` мержится в стенд-ветки наравне с сервисом; фаза `migration:` (expand/contract) в release-page.
- **Приёмка:** инвариант 9.

### Фаза 6 — Каденс engine
- `schedule.yaml` Вт/Чт; `next-train` из симулированных часов; прокрутка на daily.
- **Приёмка:** инвариант 10.

---

## 5. Команды (целевой Makefile)

```
make up              # GitLab+runner, засеять репо
make down            # снести всё (destroy)
make status          # поезда + версии на стендах
make train DATE=...  # ручной запуск отправления (обычно cron/часы)
make gate DATE=... RESULT=pass|fail   # подать сигнал гейта
make inject-defect SVC=svc-b BT=25    # сломать гейт
make tick [DAYS=1]   # прокрутить симулированные часы
make logs            # логи pipeline/стендов
```

---

## 6. Ограничения

- **GitLab CE тяжёлый** (RAM/диск). Если тесно — урезать сервисы GitLab или вынести на VM. Остальное лёгкое.
- **Deploy — симуляция**, намеренно простая: показать "ветка -> стенд", не воспроизводить ArgoCD/OpenShift.
- **Симулированное время** только в полигоне, не в реальные cron.

---

## 7. Следующий шаг

Фаза 0: поднять GitLab+runner в compose и засеять репозитории. После зелёной Фазы 0 — по фазам, каждая через `destroy -> apply -> работает`.
