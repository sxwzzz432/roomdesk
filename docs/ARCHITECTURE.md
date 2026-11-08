# 架构说明：每个 PostgreSQL / Docker 特性为什么这么用

这份文档回答"为什么"，README 回答"是什么、怎么跑"。
每一节都能在代码里找到对应位置，改之前先看这里的权衡。

---

## 1. 三条数据链路

### 1.1 写路径

```
POST /api/bookings
   → repositories/bookings.py  INSERT ... tstzrange(...)
   → PostgreSQL:
       ① EXCLUDE 约束判定重叠（失败 → 409，应用层没有判重代码）
       ② AFTER INSERT 触发器 log_booking_event()   → booking_events（分区表）
       ③ AFTER INSERT 触发器 notify_booking_event() → pg_notify('roomdesk_bookings', …)
   → 事务提交
   → worker 的 LISTEN 收到通知 → INSERT INTO notifications
```

关键点：**②③ 和业务写入在同一个事务里**。所以"预约成功但事件丢了"不可能发生；
如果事务回滚，`pg_notify` 也不会发出（NOTIFY 在提交时才真正投递）。

### 1.2 读路径（报表）

```
GET /api/reports/utilization
   → reporting.mv_room_daily_usage（房间 × 天的预聚合）
   → 再套一层窗口函数算排名 / 占比 / 累计
   → 附上 reporting.report_state 里的「最后一次刷新时间」
```

对比 `GET /api/reports/peak-hours`：它**现场**扫 `v_confirmed_bookings`。
两个接口刻意放在一起，就是为了讲清"预聚合读模型"和"实时查询"的代价差异
（`make bench` 的第 3 组会打出两者的执行计划）。

### 1.3 刷新路径

```
worker 容器
   ├─ 启动先刷一次
   ├─ 收到 NOTIFY 后（≥1 秒节流）刷一次
   └─ 兜底：每 REFRESH_INTERVAL（默认 15s）刷一次
   → REFRESH MATERIALIZED VIEW CONCURRENTLY
   → UPDATE reporting.report_state SET refreshed_at = now(), row_count = …
```

为什么是 worker 而不是 API 进程：刷新是"后台任务"，不该占用请求线程，
也不该因为 API 重启频率高而反复执行。为什么单独一个容器：它可以独立扩缩、独立重启、
日志独立（`make logs-worker`）。

---

## 2. 并发正确性完全交给数据库

```sql
CONSTRAINT bookings_no_overlap EXCLUDE USING gist (
    room_id WITH =,
    period  WITH &&
) WHERE (status = 'confirmed')
```

- 需要 `btree_gist`：`=` 不是 GiST 原生操作符类。
- 应用层"先 SELECT 查冲突再 INSERT"在并发下必然有窗口期；排他约束内部用**谓词锁**，
  第二个事务会阻塞，等第一个提交后直接报 `exclusion_violation`。
- `WHERE status = 'confirmed'`：取消后自动脱离约束范围 → 时段释放。
  这也解释了为什么"取消"是 `UPDATE status` 而不是 `DELETE`。
- `[)` 半开区间：10:00–11:00 与 11:00–12:00 不算重叠（测试里有这个用例）。
- 100 万行还撑得住吗？这个约束的代价是**写入时的索引检查**，与"被检查的行数"相关，
  和表总量关系不大（GiST 索引 + 谓词锁的范围由查询条件决定）。验证方法：
  `scripts/explain_lab.sql` 里的第 2 组 + 并发测试。

---

## 3. 权限模型：三个角色 + 两个 schema

| 角色 | 用途 | 能做什么 | 不能做什么 |
| --- | --- | --- | --- |
| `roomdesk_migrator` | 迁移容器 | 建/改表、建索引、授权 | 不参与跑业务查询 |
| `roomdesk_app` | API / worker | DML、`EXECUTE` 函数、`REFRESH` 自己的物化视图 | **不能在 `roomdesk` schema 建表** |
| `roomdesk_reader` | 排查 / BI | 只读 | 不能写 |

`db/bootstrap.sql` 里还做了三件容易被忽略的事：

1. **`search_path` 设在角色上**（`ALTER ROLE ... SET search_path`）。
   放角色而不是连接串里，是因为走 pgbouncer 事务池时连接串里的 `options` 会失效。
2. **默认权限**（`ALTER DEFAULT PRIVILEGES`）：以后 migrator 新建的表自动给 app 授权，
   否则每加一张表都要补 `GRANT`，早晚会漏。
3. **`pg_read_all_stats`**：不给的话 `/api/ops/db` 里别人执行的语句会显示
   `<insufficient privilege>`。

### 3.1 为什么物化视图的 owner 是 app

`REFRESH MATERIALIZED VIEW` 的权限检查是**对象所有权**，没有对应的 `GRANT`。
而 API/worker 用的正是 `roomdesk_app`，所以：

- `reporting` schema 单独授了 `CREATE`（业务 schema 没给任何 DDL 权限）
- 迁移最后把 `mv_room_daily_usage` 的 owner 转给 `roomdesk_app`
- 转账需要 migrator 是 app 的成员 → `GRANT roomdesk_app TO roomdesk_migrator`

这是本项目最"实战"的一处设计取舍：**用 schema 隔离把这点 DDL 权限圈进一个笼子里**。

---

## 4. pgbouncer 事务池的代价

好处：200 个客户端连接只压出十几条真实 PG 连接（`make pools` 里能看到
`cl_active` 与 `sv_idle` 的对比），移动端/短连接场景下省掉大量连接建立开销。

代价有三条，项目里都踩到了：

1. **服务端预编译语句会串味** → `psycopg_pool` 的 `prepare_threshold=None`（`app/db.py`）。
2. **`LISTEN` 不可用**（会话级语义）→ worker 直连 `db:5432`；`pg_stat_activity` 里能同时
   看到 worker 的直连和 API 的池连接。
3. **`SET` 类会话状态只对当前事务有效** → 所以 `search_path`、`time_zone` 这类东西
   一律放角色级或写进 SQL，不靠 `SET`。

另外 `auth_type = plain` 只适合内网：`userlist.txt` 由 entrypoint 从环境变量生成，
密码不进仓库。生产应该换成 `auth_type = scram-sha-256` + `AUTH_FILE` 里放 SCRAM verifier。

---

## 5. 迁移体系：为什么不是 initdb 脚本

早期版本用 `docker-entrypoint-initdb.d`，问题很实在：**只在数据卷为空时执行一次**，
改了 schema 只能 `down -v` 删库。现在的做法：

```
migrator 容器（每次 up 都会跑，幂等）
  ① bootstrap.sql   —— 超级用户：扩展 / 角色 / schema / schema 权限
  ② db/migrations/*.sql —— roomdesk_migrator：对象定义
     每个文件一个事务（psql -1），版本写进 roomdesk.schema_migrations
  ③ db/seed/seed.sql —— 库为空时灌演示数据
```

好处：

- **DDL 与运行时解耦**：API 启动时不会偷偷改表结构。
- **失败即阻断**：`depends_on: service_completed_successfully` 让迁移失败时 API 根本不启动，
  而不是带着半套 schema 跑起来。
- **可追溯**：`SELECT * FROM roomdesk.schema_migrations` 就是变更历史。
- **容器内外同一套脚本**：`make migrate` 在宿主机上也能跑（见 `docs/LOCAL-WITHOUT-DOCKER.md`）。

---

## 6. 分区表与 DEFAULT 分区的坑

`booking_events` 按月 RANGE 分区，迁移时用 `ensure_month_partition()` 建好本月和下月。

坑：**DEFAULT 分区里只要已经有某月的数据，之后再补建该月分区就会失败**。所以：

- 显示上，`/api/ops/partitions` 能直接看到 `booking_events_YYYYmMM` 和 `_default` 的行数；
- 正确的运维动作是每月提前建下个月分区（扩展方向里的 cron 容器）；
- 查询要剪枝就得**上下界都写**（`explain_lab.sql` 第 4 组有对照）。

---

## 7. Docker 侧的设计取舍

| 决定 | 理由 | 代价 |
| --- | --- | --- |
| `migrator` 用 `postgres:16-alpine` 而不是自建镜像 | 只要 psql + bash，复用官方镜像更小更快 | 版本跟着 PG 镜像走 |
| `pgbouncer` 自建镜像（21.6 MB） | 官方没有 pgbouncer 镜像；自建才能真正给出配置文件和 entrypoint | 需要维护一个 Dockerfile |
| **api 镜像分 5 个阶段**（`base`/`deps-runtime`/`deps-dev`/`runtime`/`dev`） | 生产镜像不带 pytest（282 MB vs 303 MB），测试用 `dev` 目标 + 独立 `test` 服务 | 多一个镜像；`docker compose exec api pytest` 不再可用 |
| **worker 独立镜像**（224 MB） | 只需要 psycopg，不必背 fastapi/uvicorn；可独立发布回滚 | 两套构建流程 |
| **pip 缓存挂载**（`--mount=type=cache`） | 依赖不从网络重下，改代码后重建实测 **1.0 秒** | 依赖 BuildKit（Docker Desktop 默认满足） |
| **基础镜像 ARG 可钉 + `PIP_INDEX_URL` 可传** | 版本可复现；国内网络能换源 | 需要在 compose / `.env` 里维护参数 |
| `test` 用 `profile: test` | 默认栈保持精简，测试容器用完即删（`--rm`） | 测试命令变成 `--profile test run --rm test` |
| API `--workers 2` | 演示容器内多进程 + 连接池的配合 | 每个进程各有一份池 |
| 非 root（uid 1001，`USER app`） | 安全基线；挂载卷归属可预期 | 需要 `--chown`、pytest 缓存要关掉 |
| 源码与测试目录分离 | 运行镜像里没有 `tests/`（`.dockerignore` 排除），测试容器单独挂载 | 需要额外一条 volume |
| `backup` 放 `ops` profile | 默认栈保持精简 | 需要显式 `--profile ops` |
| `deploy.resources.limits` | 演示资源约束（Compose v2 非 Swarm 模式也生效） | 数值需要按机器调 |

**启动顺序**：`db(healthy)` → `migrator(completed)` → `api`/`worker`；
`pgbouncer` 只要 `db(healthy)` 就能起，`api` 等它 healthy 才起。
全程没有 `sleep`。

完整的构建与启动步骤（含每一步的预期输出、排障表）见
[STARTUP.md](STARTUP.md)。

---

## 8. 已知不足（答辩时可以主动讲）

1. **没有鉴权**：`staff_id` 由客户端指定，`/api/ops/refresh` 只有一个静态 token。
   真上线要接 OIDC/网关。
2. **单库单机**：报表没走读副本；`roomdesk_reader` 已经留好了，接逻辑复制即可。
3. **物化视图刷新是全量的**：数据量大时应该按 `book_date` 分区或改成增量汇总表。
4. **`auth_type = plain`**：只适合内网开发环境（密码在容器文件系统里是明文）。
5. **没有指标导出**：现在靠 `/api/ops/db` 人肉看，生产要接 Prometheus。
6. **分区的 DEFAULT 兜底没有监控告警**：只有 `/api/ops/partitions` 能看行数。
7. **worker 只能单副本**：`notifications` 表没有唯一键，两个 worker 会把同一条事件落两次。
   要横向扩 worker，得给 `(event, payload->>'id', occurred_at)` 加唯一约束，或改成
   `FOR UPDATE SKIP LOCKED` 拉取式消费。
8. **备份只有逻辑备份**：`pg_dump` + 校验 + 轮转（见 STARTUP §8.3），但**没有 WAL 归档 / PITR**，
   恢复点最细到"上一次备份"。要求 RPO < 1 小时就得配 `archive_mode + pgBackRest/WAL-G`。
9. **没有 CI**：仓库里没有 GitHub Actions / lint（ruff）/ 类型检查（mypy）/
   迁移回滚脚本，全部靠人跑 `make test`。这是实习项目刻意省掉的，也是接手后第一件该补的事。
10. **前端是演示级**：无鉴权、无分页（一次最多 200 条）、无 E2E 测试，
    `/ui/` 只在 Chrome/Edge 上验过。
