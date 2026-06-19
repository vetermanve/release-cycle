# Полигон жизненного цикла релиз-трейна. Единая точка входа.
SHELL := /bin/bash

# .env: создать из шаблона при отсутствии, затем подключить и экспортировать в рецепты.
$(shell [ -f .env ] || cp .env.template .env)
-include .env
export

DC     := docker compose --env-file .env -f infra/gitlab/docker-compose.yml
CITOOLS := $(CI_TOOLS_IMAGE)

# обёртка запуска оркестратора в ci-tools на сети полигона (.env прокинут внутрь)
RUNCTL = docker run --rm --network $(NETWORK) --env-file $(CURDIR)/.env \
  -v $(CURDIR)/.state:/state:ro -v $(CURDIR)/tools:/tools:ro \
  $(CITOOLS) bash /tools/ctl.sh

.DEFAULT_GOAL := help

help: ## список команд
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

guard-docker:
	@docker info >/dev/null 2>&1 || { echo "docker не запущен. colima start?"; exit 1; }

ci-image: guard-docker ## собрать ci-tools образ
	@docker build -q -t $(CITOOLS) infra/ci-tools >/dev/null && echo "$(CITOOLS) готов"

up: guard-docker ci-image ## поднять GitLab+runner+mock-jira и засеять
	@$(DC) up -d
	@$(MAKE) --no-print-directory wait-gitlab
	@$(MAKE) --no-print-directory bootstrap
	@echo ""
	@echo "GitLab:   http://localhost:$(GITLAB_HTTP_PORT)  (root / $(GITLAB_ROOT_PASSWORD))"
	@echo "Jira:     http://localhost:$(MOCK_JIRA_PORT)/rest/api/2/issue/"
	@echo "Стенды:   dev :$(STAND_DEV_PORT)  test :$(STAND_TEST_PORT)  prepod :$(STAND_PREPOD_PORT)  prod :$(STAND_PROD_PORT)"

wait-gitlab:
	@echo "ждём GitLab health (healthcheck контейнера)..."
	@for i in $$(seq 1 100); do \
	  st=$$(docker inspect --format '{{.State.Health.Status}}' relcycle_gitlab 2>/dev/null); \
	  if [ "$$st" = "healthy" ]; then echo "GitLab healthy"; exit 0; fi; \
	  sleep 5; done; \
	  echo "GitLab health timeout" >&2; exit 1

bootstrap: ## (пере)сеять GitLab из seed
	@mkdir -p .state
	@docker run --rm --network $(NETWORK) --env-file $(CURDIR)/.env \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $(CURDIR)/seed:/seed:ro \
	  -v $(CURDIR)/tools:/tools:ro \
	  -v $(CURDIR)/.state:/out \
	  $(CITOOLS) bash /tools/bootstrap.sh

demo: ## проиграть полный жизненный цикл с проверками
	@$(RUNCTL) demo

check: ## автономные ассерты end-state
	@$(RUNCTL) test

status: ## статус поездов и стендов
	@$(RUNCTL) status

# --- стенды: команда = стенд. Деплоится только то, на что указывает stands/<env>. ---
build: ## определить поезд (bt-set) без привязки к стенду: make build DATE=26.06.30 BTS=42
	@$(RUNCTL) create-train $(DATE) $(BTS)

dev: ## bt-set + привязать dev -> собрать dev-стенд: make dev DATE=26.06.09 BTS=16,25
	@$(RUNCTL) dev $(DATE) $(BTS)

test: ## привязать test=DATE -> собрать test-стенд напрямую (минуя dev): make test DATE=26.06.09
	@$(RUNCTL) promote-test $(DATE)

release: ## привязать prepod+prod=DATE -> собрать предпрод+прод (БЕЗ merge master)
	@$(RUNCTL) promote-release $(DATE)

accept: ## приёмка прода: merge prod->master + tag + рефреш активных dev/test: make accept DATE=
	@$(RUNCTL) accept $(DATE)

stop: ## stop-the-line (дефект): make stop DATE=26.06.09
	@$(RUNCTL) stop $(DATE)

resolve: ## демо-резолв существующей skeleton-ветки: make resolve REPO=svc-a MB=merge/bt-77-bt-78
	@$(RUNCTL) resolve $(REPO) $(MB)

mkmerge: ## создать+резолв merge-ветку с нуля (в т.ч. тройную): make mkmerge REPO=svc-a BTS=77,78,79
	@$(RUNCTL) mkmerge $(REPO) $(BTS)

rebuild: ## пересобрать dev поезда (после resolve): make rebuild DATE=26.06.16
	@$(RUNCTL) rebuild $(DATE)

inject-defect: ## демо stop-the-line: make inject-defect DATE=26.06.20 BT=99
	@$(RUNCTL) create-train $(DATE) $(BT)
	@$(RUNCTL) promote-test $(DATE)
	@$(RUNCTL) stop $(DATE)

crashtest: ## краш-тест: куча репо+веток+конфликтов -> собрать большой поезд (NSVC=5 NBT=24)
	@echo "=== генерю мусор (репо/ветки/конфликты) ==="
	@bts=$$(docker run --rm --network $(NETWORK) -v $(CURDIR)/.state:/state:ro -v $(CURDIR)/tools:/tools:ro \
	    $(CITOOLS) bash /tools/crashtest.sh $(or $(NSVC),5) $(or $(NBT),24)); \
	  echo "BTS=$$bts"; \
	  echo "=== сборка большого поезда 99.99.01 ==="; \
	  $(RUNCTL) dev 99.99.01 "$$bts"

logs: ## логи GitLab/runner
	@$(DC) logs --tail=60

clock-init:
	@mkdir -p .state; [ -f .state/clock ] || echo $(CLOCK_DEFAULT) > .state/clock

next-train: clock-init ## ближайшая дата поезда по schedule.yaml и часам
	@c=$$(cat .state/clock); \
	nt=$$(docker run --rm -v $(CURDIR):/w $(CITOOLS) python3 /w/tools/cadence.py next $$c /w/seed/release-repo/schedule.yaml); \
	echo "clock=$$c -> ближайший поезд: $$nt (ветка dev-$$nt)"

tick: clock-init ## прокрутить симулированные часы: make tick DAYS=1
	@c=$$(cat .state/clock); \
	n=$$(docker run --rm -v $(CURDIR):/w $(CITOOLS) python3 /w/tools/cadence.py advance $$c $(or $(DAYS),1)); \
	echo $$n > .state/clock; echo "clock: $$c -> $$n"

down: guard-docker ## остановить стек, снести стенды (тома сохраняются)
	@ids=$$(docker ps -aq --filter label=relcycle=stand); [ -n "$$ids" ] && docker rm -f $$ids >/dev/null || true
	@$(DC) down
	@echo "down: стек остановлен, стенды снесены"

reset: guard-docker ## полный сброс (тома, state, стенд-образы) и заново
	@ids=$$(docker ps -aq --filter label=relcycle=stand); [ -n "$$ids" ] && docker rm -f $$ids >/dev/null || true
	@imgs=$$(docker images -q 'stand-*'); [ -n "$$imgs" ] && docker rmi -f $$imgs >/dev/null 2>&1 || true
	@$(DC) down -v
	@rm -rf .state
	@echo "reset: всё снесено, поднимаю заново..."
	@$(MAKE) --no-print-directory up

.PHONY: help guard-docker ci-image up wait-gitlab bootstrap demo check status build dev test release accept stop resolve mkmerge rebuild inject-defect crashtest logs clock-init next-train tick down reset
