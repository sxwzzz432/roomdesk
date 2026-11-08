# RoomDesk 实习项目计划书（2 周 / 10 个工作日）

> 适用对象：会一点 Python、SQL 只写过 `SELECT/INSERT` 的实习生。
> 交付物：一套 `docker compose up` 起得来的系统 + 一份能讲 15 分钟的设计说明。
> 项目定位：业务很小（3 张表），但**数据链路、权限模型、读模型、事件管道都是生产形态**。

---

## 一、这套架构想让他学到什么

| 想让他掌握的 | 具体载体 |
| --- | --- |
| 并发正确性交给数据库 | `EXCLUDE USING gist`，并发测试 |
| 最小权限是真的能落地的 | 三个角色 + 两个 schema，`make psql-app` 里建表被拒 |
| 读写分离的思路（不用上主从） | 物化视图 + worker 定时刷新 + 新鲜度水位 |
| 事件驱动的最小实现 | 触发器 `pg_notify` → worker `LISTEN` → 落库 |
| DDL 不该在应用启动路径里 | `migrator` 一次性容器 + `service_completed_successfully` |
| 连接池的真实代价 | pgbouncer 事务池 + 关掉预编译 + `LISTEN` 不能走池 |
| 容器化的细活 | 多阶段构建、非 root、健康检查、profiles、日志轮转、资源限制 |

---

## 二、10 天日程

### 第 1 天｜跑起来，建立全局图
- `docker compose up -d --build`，`docker compose ps` 看到 5 个服务（+ adminer）。
- 画出数据流：`api → pgbouncer → db`、`worker → db`、`migrator` 只跑一次。
- 打开 `/ui/`（前端）、`/docs`（接口文档）、`/health`、`/api/ops/db`、`/api/ops/notifications` 各点一次。
- 在 `/ui/` 上把「找空房 → 订它 → 用同一时段再订一次（看 409）→ 报表 → 事件流」走一遍。
- **交付**：一张自己画的服务依赖图 + 每个容器一句话职责。
- 必答题：`service_completed_successfully` 和 `service_healthy` 有什么区别？

### 第 2 天｜读 bootstrap 与迁移，理解权限
- 读 `db/bootstrap.sql`：为什么扩展和角色要超级用户？`\gexec` 在干什么？
- 读 `0001`~`0006`，重点看 `0005_grants.sql` 和 `0002_events.sql`。
- 亲手做：`make psql-app`，执行 `CREATE TABLE roomdesk.x(id int);` → 被拒；再在 `reporting` 里建 → 成功。
- **交付**：`docs/notes.md` 写清「谁能对哪个 schema 做什么」，附截图。

### 第 3 天｜并发与排他约束
- 两个 psql 窗口复现阻塞：一个 `BEGIN; INSERT…` 不提交，另一个插重叠时段。
- 跑 `make test`，定位并发用例为什么必然只成功 1 个。
- 读 `0001` 里 `WHERE status='confirmed'` 的作用，解释「取消即释放」。
- **交付**：200 字说明「为什么不需要 `SELECT … FOR UPDATE`」+ 两个窗口截图。

### 第 4 天｜两次实现同一件事
- 用 Python 在路由层**重新实现一遍** `free_rooms`（不要调数据库函数），
  然后和 SQL 版本对比：区间语义、索引、维护成本。
- **交付**：两份代码 + 结论（什么时候该写成数据库函数）。

### 第 5 天｜周会演示 + 补测试
- 30 分钟演示：预约 / 409 / 取消重订 / 报表 / 事件流。
- 补 2 个自己想的边界用例（如「跨零点预约」「取消后他人重订」）。
- **交付**：周报（做过什么 / 卡在哪 / 下周计划）。

### 第 6 天｜读模型：物化视图 vs 现场聚合
- 对比 `/api/reports/utilization`（读物化视图）和 `/api/reports/peak-hours`（现场算）。
- `make bench` 看第 3 组执行计划，把两者耗时记下来。
- 新写一个接口 `GET /api/reports/gaps`：找出「某房间连续空闲 ≥ 2 小时」的时段
  （提示：`generate_series` 造半小时骨架 → `LEFT JOIN` 已订时段 → `lag()` 打标记）。
- **交付**：新接口 + 测试 + 两个报表的耗时对比表。

### 第 7 天｜索引与执行计划
- 用 `generate_series` 造 10 万条预约（自己写，不要抄）。
- 跑 `make bench`，重点看 `Buffers` 与扫描方式；对比加索引前后。
- 看 `pg_stat_statements`（`/api/ops/db`）里自己的 SQL 排到第几。
- **交付**：一页「加索引前后」真实数字 + 截图。

### 第 8 天｜迁移、备份、恢复（运维基本功）
- 写自己的迁移 `db/migrations/0007_*.sql`，`docker compose run --rm migrator` 应用。
- 再跑一次，验证「跳过已执行」。
- `make backup` → 手动 `DROP SCHEMA roomdesk CASCADE` → `make restore` → 验证数据回来。
- 演练 `pg_stat_activity` 里能看到 worker 直连和 API 池连接的区别。
- **交付**：备份恢复演练记录（含出错那次的原始报错）。

### 第 9 天｜容器化收尾
- `make pools` 看连接复用；把 `DB_POOL_MAX` 改大改小观察 `SHOW POOLS`。
- `docker compose --profile ops up -d backup`，确认 `./backups` 里有产物。
- 删掉镜像后从零 `up`，记录踩坑；再试 `docker compose up -d api --scale api=2`。
- **交付**：`docs/deploy.md`（新机器 5 步部署清单）。

### 第 10 天｜文档与答辩
- 补 README 的「PostgreSQL / Docker 能力表」，每条都要能落到文件与行。
- 15 分钟分享 + 15 分钟问答（题库见下）。

---

## 三、验收标准（硬指标）

功能：
- [ ] 干净机器 `docker compose up -d --build` 一条命令起得来，`db/pgbouncer/api` 全 healthy
- [ ] `make test` 全绿（17 个用例，含并发与事件链路）
- [ ] 第二个重叠请求返回 **409**，且 detail 说明是数据库约束所致
- [ ] 取消后同一时段可再次预订
- [ ] `Idempotency-Key` 重复提交返回 200 且 id 相同
- [ ] `/health` 的 `db_user` 是 `roomdesk_app`（证明走池 + 最小权限）
- [ ] `make psql-app` 里在 `roomdesk` schema 建表**被拒**
- [ ] `/api/reports/utilization` 的 `source` 是物化视图，且带 `freshness`
- [ ] 新建预约后 5 秒内，`/api/ops/notifications` 能查到对应事件
- [ ] `make pools` 显示 `pool_mode = transaction` 且存在 server 连接复用

工程：
- [ ] 结构变更走 `db/migrations/`，`schema_migrations` 有记录
- [ ] 完成一次 `pg_dump` → 删 schema → `pg_restore` 演练并留档
- [ ] `make bench` 至少有一组「索引前后」真实对比数字
- [ ] 能说明三处「容器/池化带来的限制」（预编译、LISTEN、REFRESH 事务）

表达：
- [ ] 不看稿讲清「为什么用排他约束而不是应用层判重」
- [ ] 讲清「为什么物化视图的 owner 必须是 app」
- [ ] 说出本项目 2 个已知不足和改法

---

## 四、评分表（100 分）

| 维度 | 分值 | 满分表现 | 常见扣分 |
| --- | --- | --- | --- |
| 环境可复现 | 15 | 干净机器一条命令起、全 healthy、不靠 sleep | 只在本人机器能跑 |
| 数据建模 | 20 | 区间类型、排他约束、分区、JSONB 用在对的地方 | 用两列 start/end + 应用层判重 |
| 并发正确性 | 20 | 真并发测试，能解释谓词锁 | 只写「查询后插入」还声称没问题 |
| 权限与安全 | 15 | 三角色 + schema 隔离，能演示 DDL 被拒 | 全程超级用户 |
| 读模型/事件 | 15 | 物化视图 + 新鲜度；NOTIFY 链路能跑通并解释 | 只照抄代码讲不出权衡 |
| 容器化 | 10 | 迁移容器、多阶段、非 root、profiles | 全部塞在一个容器里 |
| 文档与表达 | 5 | 有自己的笔记，能应对追问 | 直接抄 README |

红线：`docker compose up` 起不来、测试靠跳过通过、整段复制且解释不了。

---

## 五、答辩问题库

**数据库设计**
1. 为什么时间是 `tstzrange` 而不是两列？查询/约束/索引差在哪？
2. `[)` 半开区间是必须的吗？改成全闭区间会怎样？
3. 排他约束为什么需要 `btree_gist`？不加报什么错？
4. 100 万条预约时这个约束还撑得住吗？怎么验证？
5. 为什么索引建在 `lower(period)`、`booking_events` 为什么必须有分区键在主键里？

**权限**
6. 应用角色为什么不能建表？那它怎么建月度分区（提示：`SECURITY DEFINER`）？
7. 为什么物化视图的 owner 要转给应用角色？`REFRESH` 为什么没有 GRANT？
8. `ALTER DEFAULT PRIVILEGES` 解决什么问题？不写会出什么事故？
9. `search_path` 为什么放角色上，而不是连接串？

**并发与池化**
10. 两个事务同时插重叠时段，第二个阻塞还是立刻失败？为什么？
11. pgbouncer 事务池为什么会破坏预编译语句？怎么发现、怎么修？
12. 为什么 worker 不走 pgbouncer？
13. `REFRESH ... CONCURRENTLY` 为什么不能在函数/事务里跑？唯一索引起什么作用？

**性能**
14. 物化视图和现场聚合，谁更快？什么时候不能读物化视图？
15. 这条 SQL 走 `Bitmap Heap Scan`，和 `Index Scan` 的取舍是什么？
16. 分区剪枝什么时候失效？（只写下界）

**运维**
17. `migrator` 失败了，`api` 会怎样？为什么这样设计？
18. 备份用 `-Fc` 的好处？怎么只恢复一张表？
19. `pg_stat_statements` 里出现 `<insufficient privilege>` 怎么办？

**工程判断**
20. 这个项目现在最不适合上生产的三个地方是什么？
21. 如果要求「预约成功发通知」，你会放在事务里吗？为什么？

---

## 六、扩展方向（按加分排序）

| 方向 | 具体做法 | 覆盖面 |
| --- | --- | --- |
| 前端周视图 | 原生 JS 画可用时段表格 | 演示效果 +1 档 |
| 重复预约 | `recurrences` 表 + 事务内展开，撞约束整体回滚 | 事务边界 |
| 读副本 | 逻辑复制 + 报表走 `roomdesk_reader` 连的只读实例 | 架构 |
| 分区自动化 | cron 容器每月跑 `ensure_month_partition`，监控 DEFAULT 分区行数 | 运维 |
| 指标导出 | `postgres_exporter` + Grafana（连接数/QPS/慢查询） | 可观测 |
| 行级安全 | `ENABLE ROW LEVEL SECURITY` + `SET LOCAL app.staff_id`，每人只看自己的 | PostgreSQL 特性 |
| pgbouncer 加固 | `auth_type=scram-sha-256` + SCRAM verifier，去掉明文 userlist | 安全 |

---

## 七、给带教者的提示

- 第 1 天不要讲原理，先让他把系统跑起来点到 409，好奇心比讲解有效。
- 第 3 天的双窗口阻塞实验是整条主线的锚点，务必看他亲手做一次。
- 第 6 天（读模型）和第 8 天（权限演练）是本项目最"值钱"的两天，别压缩。
- 卡住超过 40 分钟再介入；介入时给"去哪看"（日志、`EXPLAIN`、`pg_stat_activity`、`make pools`），不给答案。
- 每天 15 分钟站会：昨天交付了什么 / 今天要交付什么 / 卡在哪。
