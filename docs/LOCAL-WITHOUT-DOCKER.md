# 不用 Docker 的本地开发方式（本机已装原生 PostgreSQL 16）

Docker 负责"整套多服务编排 + pgbouncer 连接池"，日常改代码时不必背着它。
本机 `D:\PostgreSQL` 已经装好 PostgreSQL 16.11，`run-local.cmd` 会把它自动准备好。

## 一、一键启动（推荐）

```powershell
D:\实习\roomdesk\run-local.cmd
```

脚本会按顺序做完这七步，任何一步失败都会停下来告诉你原因，而不是甩一堆红字：

| 步骤 | 做什么 | 缺什么会自动补 |
| --- | --- | --- |
| 1/7 | 找工具 | `psql`（自动定位 `D:\PostgreSQL\16\bin`）、Git Bash、Python |
| 2/7 | 数据库在跑吗 | 没在跑就调 `D:\PostgreSQL\start-pg.cmd`，最多等 30 秒 |
| 3/7 | 库 `roomdesk_local` 在吗 | 不在就 `createdb` |
| 4/7 | 表结构 / 三角色在吗 | 不在（或加了 `-Migrate`）就跑 `scripts/migrate.sh` |
| 5/7 | Python 依赖齐吗 | 缺 `fastapi/psycopg` 就 `pip install -r app/requirements-dev.txt` |
| 6/7 | 刷一次物化视图 | 保证报表接口开箱就有数据 |
| 7/7 | 起服务 | 新窗口起 worker（除 `-NoWorker`）+ 前台起 API |

常用参数（`run-local.cmd -xxx` 直接透传给 `run-local.ps1`）：

```powershell
run-local.cmd -PreflightOnly     # 只检查/准备，不启动服务（排查环境最快）
run-local.cmd -NoWorker          # 不拉 worker（LISTEN/NOTIFY 与定时刷新就没有了）
run-local.cmd -Port 8001         # 换端口（Docker 那套占着 8000 时用这个）
run-local.cmd -NoReload          # 关掉热重载，长时间跑更稳
run-local.cmd -Migrate           # 强制重跑迁移（幂等，只 apply 新的）
run-local.cmd -Reset             # 删掉本机库重建（会丢本地数据）
```

启动后看这个页面（不是 `/docs`）：

| 地址 | 是什么 |
| --- | --- |
| http://127.0.0.1:8000/ui/ | **前端界面**：总览 / 找空房 / 预约 / 报表 / 事件·运维 |
| http://127.0.0.1:8000/docs | 接口文档（Swagger），不是界面 |
| http://127.0.0.1:8000/health | 纯 JSON 健康检查 |

前端是 `app/static/` 里的 `index.html + app.js + style.css`，由 FastAPI 的
`StaticFiles` 托管，改完刷新浏览器即可（`--reload` 只影响 Python 代码，静态文件本来就直接读磁盘）。

> Docker 那套和本机这套可以**同时跑**：它们用的是不同的库
> （容器里是 `roomdesk`，本机是 `roomdesk_local`），只是别抢同一个 API 端口。
>
> 配置来源：脚本会读项目根的 `.env`（和 docker compose 共用），
> 只取 `APP_USER / APP_PASSWORD / READER_* / MIGRATOR_* / ADMIN_TOKEN / REFRESH_INTERVAL`；
> 库名、端口走参数，避免误用 compose 的 `DB_PORT=55432`。

## 二、脚本背后的手工步骤（想搞清原理时看这段）

```powershell
# 1. 确认数据库在跑（开机自启通常已拉起）
D:\PostgreSQL\start-pg.cmd

# 2. 建独立库（别用旧的 roomdesk，那是上一版的表结构）
& 'D:\PostgreSQL\16\bin\createdb.exe' -h 127.0.0.1 -U postgres roomdesk_local

# 3. 跑迁移（和容器里的 migrator 完全同一套脚本）
cd D:\实习\roomdesk
$env:PGHOST='127.0.0.1'; $env:PGPORT='5432'
$env:DB_NAME='roomdesk_local'
$env:SUPERUSER_USER='postgres'; $env:SUPERUSER_PASSWORD='postgres'
$env:SEED='1'
bash scripts/migrate.sh

# 4. 起 API
cd app
$env:DATABASE_URL = 'postgresql://roomdesk_app:app_pw@127.0.0.1:5432/roomdesk_local'
$env:ADMIN_TOKEN   = 'dev-admin-token'
python -m uvicorn main:app --host 127.0.0.1 --port 8000 --reload

# 5.（可选）另开一个终端起 worker，本地也有事件链路
cd ..\worker
$env:WORKER_DSN = 'postgresql://roomdesk_app:app_pw@127.0.0.1:5432/roomdesk_local'
$env:REFRESH_INTERVAL = '15'
python -u consumer.py
```

迁移做三件事（等价于容器的三个阶段）：

1. `bootstrap.sql`：建 `btree_gist` / `pg_trgm` / `pg_stat_statements` 扩展，
   建 `roomdesk_migrator` / `roomdesk_app` / `roomdesk_reader` 三个角色，
   建 `roomdesk` / `reporting` 两个 schema 并授权；
2. `db/migrations/*.sql`：表、约束、触发器、物化视图、函数，记录进 `roomdesk.schema_migrations`；
3. `db/seed/seed.sql`：演示数据（幂等）。

注意：本地没有 pgbouncer，API **直连 5432**。连接池的"代价与收益"只能在 Docker
环境里演示（`make pools` + `pg_stat_activity`，见 `docs/ARCHITECTURE.md` 第 4 节）。

跑测试（需要 API 已启动）：

```powershell
cd D:\实习\roomdesk
$env:BASE_URL='http://127.0.0.1:8000'
python -m pytest -q tests -p no:cacheprovider
```

> 有 1 个用例依赖 Docker 环境里的东西，本地会失败：
> `test_notify_pipeline_worker_to_notifications_table` 需要 worker 容器
> （用 `run-local.cmd` 起了 worker 窗口的话，本地也能过）。
> 其余用例（约束 / 并发 / 幂等 / 权限 / 报表）本地都能跑。

## 三、和 Docker 版的差异（正好是很好的对比材料）

| 项 | 本机原生 | docker compose |
| --- | --- | --- |
| API → 数据库 | 直连 `127.0.0.1:5432` | `api → pgbouncer:6432 → db:5432` |
| 连接池 | 只有应用侧 `psycopg_pool` | 应用池 + pgbouncer 事务池（两级） |
| 迁移 | `scripts/migrate.sh` | `migrator` 一次性容器，`service_completed_successfully` |
| 事件消费者 | `run-local.cmd` 起的 worker 窗口 | `worker` 服务（独立容器、独立日志） |
| 读模型新鲜度 | 脚本启动时刷一次 + worker 定时刷 | worker 每 `REFRESH_INTERVAL` 秒刷 |
| 数据目录 | `D:\PostgreSQL\data` | 命名卷 `roomdesk_pgdata` |
| 备份 | `pg_dump -Fc` 手工 | `ops` profile 的 `backup` 容器 |
| 隔离性 | 与本机其它服务共享 5432 | 完全隔离，`down -v` 就重来 |

两者用**同一份 SQL、同一套迁移脚本、同一份 API 源码**，`db/` 目录是唯一事实来源。

## 四、本地手动刷新读模型

worker 没起的时候，物化视图不会自动更新：

```powershell
$env:PGPASSWORD='app_pw'
& 'D:\PostgreSQL\16\bin\psql.exe' -h 127.0.0.1 -U roomdesk_app -d roomdesk_local `
  -c 'REFRESH MATERIALIZED VIEW CONCURRENTLY reporting.mv_room_daily_usage' `
  -c "UPDATE reporting.report_state SET refreshed_at = now(), row_count = (SELECT count(*) FROM reporting.mv_room_daily_usage), last_source='manual' WHERE name = 'mv_room_daily_usage'"
```

或者调接口（带 token）：

```powershell
Invoke-WebRequest -Method POST 'http://127.0.0.1:8000/api/ops/refresh' `
  -Headers @{ 'X-Admin-Token' = 'dev-admin-token' } -UseBasicParsing
```

## 五、常用 psql 操作

```sql
-- 超级用户：D:\PostgreSQL\psql.cmd -d roomdesk_local
-- 应用角色：psql -h 127.0.0.1 -U roomdesk_app -d roomdesk_local（PGPASSWORD=app_pw）
\dn                          -- schema：roomdesk / reporting
\dt roomdesk.*               -- 业务表
\d+ roomdesk.bookings        -- 能看到 EXCLUDE 约束
\dm reporting.*              -- 物化视图
SELECT * FROM roomdesk.schema_migrations ORDER BY version;
SELECT * FROM roomdesk.free_rooms(now() + interval '1 day', now() + interval '1 day 2 hours', 8);
SELECT tableoid::regclass, count(*) FROM roomdesk.booking_events GROUP BY 1;
SELECT has_schema_privilege('roomdesk_app', 'roomdesk', 'CREATE');   -- 期望 f
```

## 六、重置

```powershell
# 只重置本机库（脚本自带）
D:\实习\roomdesk\run-local.cmd -Reset

# 或手工
& 'D:\PostgreSQL\16\bin\dropdb.exe' -h 127.0.0.1 -U postgres roomdesk_local
# 然后重新跑 run-local.cmd

# 连数据库实例一起重置
D:\PostgreSQL\stop-pg.cmd
Remove-Item -Recurse -Force D:\PostgreSQL\data
powershell -ExecutionPolicy Bypass -File D:\PostgreSQL\install-postgres.ps1
```
