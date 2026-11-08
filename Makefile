SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: help pull build images up down reset ps logs logs-db logs-worker migrate seed test \
        psql psql-app psql-reader pools bench backup restore shell clean

help:  ## 列出所有命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

pull:  ## 预拉基础镜像（规避 BuildKit 拉元数据超时）
	docker pull python:3.12-slim
	docker pull postgres:16-alpine
	docker pull adminer:4
	docker pull alpine:3.20

build:  ## 只构建镜像（含 test 用的 dev 目标），不启动
	$(COMPOSE) --profile test build

images:  ## 看本项目镜像体积
	@docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' | grep -Ei 'roomdesk|REPOSITORY'

up:  ## 构建并启动全部服务（含迁移容器）
	$(COMPOSE) up -d --build
	@echo ""
	@echo "  前端界面   http://localhost:8000/ui/"
	@echo "  API 文档   http://localhost:8000/docs"
	@echo "  运维面板   http://localhost:8000/api/ops/db"
	@echo "  Adminer    http://localhost:8080   (Server=db, User=roomdesk_app, DB=roomdesk)"
	@echo "  连接池     make pools"
	@echo ""

down:  ## 停止服务（保留数据卷）
	$(COMPOSE) --profile ops down

reset:  ## 删掉数据卷后重建（数据全丢）
	$(COMPOSE) --profile ops down -v
	$(COMPOSE) up -d --build

ps:  ## 容器状态
	$(COMPOSE) --profile ops ps

logs:  ## 跟踪全部日志
	$(COMPOSE) logs -f --tail=100

logs-db:  ## 数据库日志（含慢查询）
	$(COMPOSE) logs -f --tail=100 db

logs-worker:  ## worker 日志（LISTEN / REFRESH）
	$(COMPOSE) logs -f --tail=100 worker

migrate:  ## 在宿主机上跑迁移（不用 Docker 时）
	SEED=$${SEED:-1} bash scripts/migrate.sh

test:  ## 用 dev 目标镜像跑接口/集成测试（会先确保 api 已 healthy）
	$(COMPOSE) --profile test run --rm test

psql:  ## 超级用户 psql（DDL 排查用）
	$(COMPOSE) exec db sh -lc 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

psql-app:  ## 应用角色 psql（顺便验证它走的是 pgbouncer）
	$(COMPOSE) exec -e PGPASSWORD=$${APP_PASSWORD:-app_pw} db \
		psql -h pgbouncer -p 6432 -U $${APP_USER:-roomdesk_app} -d $${DB_NAME:-roomdesk}

psql-reader:  ## 只读角色 psql（验证最小权限）
	$(COMPOSE) exec -e PGPASSWORD=$${READER_PASSWORD:-reader_pw} db \
		psql -U $${READER_USER:-roomdesk_reader} -d $${DB_NAME:-roomdesk}

pools:  ## pgbouncer 控制台：SHOW POOLS / SHOW STATS
	$(COMPOSE) exec -e PGPASSWORD=$${PGBOUNCER_ADMIN_PASSWORD:-pgb_admin_pw} pgbouncer \
		psql -h 127.0.0.1 -p 6432 -U $${PGBOUNCER_ADMIN_USER:-pgb_admin} pgbouncer \
		-c 'SHOW POOLS;' -c 'SHOW STATS;'

bench:  ## 执行计划 / 权限矩阵 / 慢查询 / 分区剪枝
	$(COMPOSE) run --rm --no-deps --entrypoint bash migrator -lc \
		'PGUSER=$$SUPERUSER_USER PGPASSWORD=$$SUPERUSER_PASSWORD psql -d $$DB_NAME -f /workspace/scripts/explain_lab.sql'

backup:  ## 逻辑备份到 ./backups
	bash scripts/backup.sh

restore:  ## 恢复：make restore FILE=backups/xxx.dump
	bash scripts/restore.sh $(FILE)

shell:  ## 进 api 容器
	$(COMPOSE) exec api bash
