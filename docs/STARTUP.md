# 从零到「前端能点」：完整启动流程

> 目标：一台**只有 Windows + Docker Desktop** 的机器，从拉镜像开始，
> 到浏览器里点开 http://localhost:8000/ui/ 能下单，全程可复现。
>
> 每条命令后面都写了「正常应该看到什么」，对不上就去第 9 节排障表。
> 命令全部给了三种写法：`make`（Git Bash）/ `pwsh task.ps1`（PowerShell）/ 原生 `docker compose`。

目录

- [0. 前置检查](#0-前置检查)
- [1. 拉基础镜像](#1-拉基础镜像)
- [2. 构建本项目镜像](#2-构建本项目镜像)
- [3. 启动编排](#3-启动编排)
- [4. 验证服务](#4-验证服务)
- [5. 跑测试](#5-跑测试)
- [6. 打开前端](#6-打开前端)
- [7. 日常开发的三条路径](#7-日常开发的三条路径)
- [8. 停止 / 重启 / 重置 / 备份](#8-停止--重启--重置--备份)
- [9. 排障速查](#9-排障速查)
- [附录 A：命令对照表](#附录-a命令对照表)
- [附录 B：端口与账号](#附录-b端口与账号)

---

## 0. 前置检查

### 0.0 先确认：你要走哪条启动路径

本项目有**两条互不相干**的启动方式，别混用（尤其别让它们抢同一个 8000 端口）：

| | Docker 路径（本文） | 本机路径 |
| --- | --- | --- |
| 入口命令 | `make up` / `pwsh ./task.ps1 up` / `docker compose up -d --build` | `D:\实习\roomdesk\run-local.cmd` |
| 起来的服务 | 6 个：db / migrator / pgbouncer / api / worker / adminer | 3 样：本机 PostgreSQL + worker 窗口 + uvicorn |
| 连接池 | 有（pgbouncer 事务池，API → 池 → 库） | 无（API 直连 5432） |
| 迁移 | `migrator` 一次性容器 | `run-local.ps1` 调 `scripts/migrate.sh` |
| 数据库 | 容器内 `roomdesk`，宿主端口 55432 | 本机 `roomdesk_local`，端口 5432 |
| 前端 | `http://localhost:8000/ui/` | `http://127.0.0.1:8000/ui/`（同一个前端） |
| 适合 | 演示 / 验收 / 练"生产形态" | 只想改代码、不想开 Docker |
| 细节 | 本文 | [LOCAL-WITHOUT-DOCKER.md](LOCAL-WITHOUT-DOCKER.md) |

> 判断"现在跑的是哪一套"：
> ```powershell
> docker compose ps                     # 有 5 个容器在跑 → Docker 那套
> Get-NetTCPConnection -LocalPort 8000  # OwningProcess 是 wslrelay → Docker；是 python → 本机脚本
> ```

### 0.1 Docker 是否就绪

```powershell
docker version --format '{{.Server.Version}}'
```

正常输出一个版本号（本机实测 `29.9.2`）。如果报
`failed to connect to the docker API at npipe://...dockerDesktopLinuxEngine`，
说明 **Docker Desktop 没启动**（不是没装）——从开始菜单启动它，等托盘鲸鱼图标变绿再试。

`docker compose version` 应为 v2 及以上（本机 `v5.6.1`）——本项目用了
`depends_on: condition: service_completed_successfully`，只有 v2+ 支持。

### 0.2 端口占用

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8000,8080,55432 -ErrorAction SilentlyContinue
```

应该**什么都不输出**。默认端口故意避开常见值：

| 用途 | 宿主端口 | 说明 |
| --- | --- | --- |
| API / 前端 | `8000` | `/ui/` 前端、`/docs` 接口文档 |
| Adminer | `8080` | 浏览器看表 |
| PostgreSQL | `55432` | 映射到容器 5432，避开本机原生 PG 的 5432 |
| pgbouncer | — | 只在 compose 内网，不映射宿主 |

要改端口：复制 `.env.example` 为 `.env`，改 `API_PORT / ADMINER_PORT / DB_PORT`。

### 0.3 磁盘与内存

镜像总占用约 **0.6 GB**（见第 2 节），数据卷初始约 50 MB。
Docker Desktop 建议至少给 4 GB 内存；`db` 和 `api` 各限了 1 GB（`deploy.resources.limits`）。

---

## 1. 拉基础镜像

本项目自己的镜像要基于这些官方镜像构建。**先单独 pull 一次**，原因在下面。

```bash
# make
make pull

# PowerShell
pwsh ./task.ps1 pull

# 原生
docker pull python:3.12-slim
docker pull postgres:16-alpine
docker pull adminer:4
docker pull alpine:3.20
```

| 镜像 | 用在哪 | 大小 |
| --- | --- | --- |
| `python:3.12-slim` | api（含 dev 目标）、worker 的基础 | ~170 MB |
| `postgres:16-alpine` | db、migrator、backup | ~250 MB |
| `alpine:3.20` | 自建 pgbouncer 镜像的基础 | ~8 MB |
| `adminer:4` | 浏览器看表 | ~170 MB |

### 为什么要先单独 pull？

`docker compose up --build` 时，BuildKit 在**解析 `FROM`** 这一步会去
`auth.docker.io` 换 token；这一步走直连、**不经过 Docker Desktop 的代理**。
在代理环境或国内网络里它经常超时，报：

```
failed to solve: failed to fetch oauth token:
Post "https://auth.docker.io/token": dial tcp 118.107.180.216:443: connectex: ...
```

而普通的 `docker pull` 走的是守护进程 + Docker Desktop 内部代理
（`http.docker.internal:3128`），通常是通的。所以：

1. 先 `pull` 把基础镜像落到本地；
2. 再 `up --build` 时 BuildKit 直接命中本地镜像，不再请求元数据。

> 本机实测就是这样救回来的：`adminer`/`postgres` 能拉、`python:3.12-slim` 的元数据超时，
> 单独 `docker pull python:3.12-slim` 成功后构建立刻通过。

如果 `pull` 也失败：给 Docker Desktop 配代理
（Settings → Resources → Proxies → Manual，填 `http://host.docker.internal:<你的代理端口>`），
或者用国内镜像加速器（Settings → Docker Engine 里加 `registry-mirrors`）。

验证：

```powershell
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' |
  Select-String 'python|postgres|alpine|adminer'
```

四个都在，就可以往下走了。

---

## 2. 构建本项目镜像

```bash
make build                                  # 只构建，不启动（含 test 用的 dev 目标）
# 或
docker compose --profile test build
```

正常结束时会看到 4 个 Image Built：

```
 Image roomdesk-api Built
 Image roomdesk-test Built
 Image roomdesk-worker Built
 Image roomdesk-pgbouncer Built
```

### 2.1 四个镜像分别是什么

| 镜像 | Dockerfile | 阶段 | 内容 | 大小（实测） |
| --- | --- | --- | --- | --- |
| `roomdesk-api` | `app/Dockerfile` | `runtime` | FastAPI + psycopg，**不含 pytest** | 282 MB |
| `roomdesk-test` | `app/Dockerfile` | `dev` | 同上 `+ pytest + httpx` | 303 MB |
| `roomdesk-worker` | `worker/Dockerfile` | `runtime` | 只有 psycopg + `consumer.py` | 224 MB |
| `roomdesk-pgbouncer` | `pgbouncer/Dockerfile` | — | alpine + pgbouncer + pg 客户端 | 21.6 MB |

### 2.2 API 镜像的五个阶段

```
base            python:3.12-slim + 环境变量 + 非 root 用户 uid=1001 + WORKDIR /srv
 ├ deps-runtime 创建 /opt/venv，装 requirements.txt           ← 生产依赖
 │   └ deps-dev 再装 requirements-dev.txt（pytest/httpx）      ← 测试依赖
 ├ runtime      COPY deps-runtime 的 venv + 源码 → 最终生产镜像
 └ dev          COPY deps-dev 的 venv + 源码     → 测试/调试镜像
```

好处很实在：

```powershell
# 生产镜像里【没有】pytest —— 实测会报 ModuleNotFoundError
docker run --rm --entrypoint python roomdesk-api -c "import pytest"

# 测试镜像里有 —— 实测 pytest 8.4.2
docker run --rm --entrypoint python roomdesk-test -c "import pytest, httpx; print(pytest.__version__)"
```

### 2.3 两个构建优化

**① pip 缓存挂载**

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv && /opt/venv/bin/pip install -r requirements.txt
```

wheel 缓存存在 BuildKit 的构建缓存里（不在镜像层里），重建时不再重复下载。

**② COPY 顺序：先依赖描述文件，再源码**

```
COPY requirements.txt ./        ← 只要它不变，下面这层就命中缓存
RUN  pip install …
COPY . .                        ← 改代码只影响这一层
```

实测：**改一行 Python 代码后 `docker compose build api` 只要 1.0 秒**（依赖层全部命中）。
而 `--no-cache` 冷构建要重新装一遍依赖：本机实测 **api 304.7 秒、worker 112.9 秒**
（瓶颈是 pip 下载，不是编译）。所以：

- 第一次构建慢是正常的，**不要中途 Ctrl+C**（会留下半截缓存层）；
- 网络慢就换 pip 源，在 `.env` 里加一行即可让 compose 构建自动带上：

  ```ini
  PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
  ```

### 2.4 可选构建参数

```bash
# 钉住基础镜像版本（默认 python:3.12-slim）
docker build --build-arg PYTHON_IMAGE=python:3.12.7-slim --target runtime -t roomdesk-api ./app

# 国内网络换 pip 源（compose 里也可以用 .env 传）
docker build --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
             --target runtime -t roomdesk-api ./app
```

`.env` 里加一行 `PIP_INDEX_URL=...`，`docker compose build` 会自动带上。

### 2.5 核对镜像

```bash
make images        # 或 pwsh ./task.ps1 images
```

```
REPOSITORY:TAG              SIZE
roomdesk-test:latest        303MB
roomdesk-api:latest         282MB
roomdesk-worker:latest      224MB
roomdesk-pgbouncer:latest   21.6MB
```

另外可以核对「非 root」和「镜像自带健康检查」：

```powershell
docker run --rm --entrypoint id roomdesk-api
# uid=1001(app) gid=1001(app) groups=1001(app)

docker inspect roomdesk-api --format '{{json .Config.Healthcheck.Test}}'
# ["CMD-SHELL","python -c \"import urllib.request;...\""]
```

### 2.6 这些镜像从哪来？换机器要不要"拉"？

先把两种镜像分清楚——这是最容易搞混的地方：

| 镜像 | 从哪来 | 有没有 Docker Hub 上的地址 | 换机器怎么办 |
| --- | --- | --- | --- |
| `python:3.12-slim`、`postgres:16-alpine`、`adminer:4`、`alpine:3.20` | **Docker Hub 拉取**（`docker pull`） | 有（`docker.io/library/...`） | 自动拉，`make pull` 即可 |
| `roomdesk-api`、`roomdesk-test`、`roomdesk-worker`、`roomdesk-pgbouncer` | **本机用 Dockerfile 构建** | **没有**（`docker image inspect` 里没有 registry 摘要） | **不需要拉**，`up --build` 会在那台机器上自己构建 |

也就是说：**项目自己的 4 个镜像从来不是"拉"下来的，而是每次 `docker compose build` 现场构建出来的**。
这是 Docker 项目的常态——把 Dockerfile 和源码带过去就够了，镜像可以随时重建、也可以随手删掉。

验证一下"我们自己的镜像确实没有仓库来源"：

```powershell
docker image inspect roomdesk-api:latest --format '{{.RepoDigests}}'
# [roomdesk-api@sha256:6a577fa...]      ← 只是本地内容摘要，没有 docker.io/xxx 前缀
docker image inspect python:3.12-slim --format '{{.RepoDigests}}'
# [python@sha256:4840d51...]            ← 这个是 Hub 上的真镜像
```

**换机器 / 给他人**的三条路，按推荐顺序：

**① 有源码（推荐，零镜像传输）**

```bash
# 新机器上：装好 Docker Desktop → 拷项目目录 → 
make pull                          # 先拉 4 个基础镜像（规避 BuildKit 元数据超时）
docker compose up -d --build       # 现场构建 + 启动
```

代价只有一次构建时间（本机实测冷构建 api 约 5 分钟、worker 约 2 分钟，取决于网络；
慢就设 `PIP_INDEX_URL` 换源）。**数据不在镜像里**——要迁数据用 `pg_dump`/`pg_restore`，见 §8.3。

**② 走镜像仓库（对方只用不构建，比如给测试/运维）**

```bash
# 构建机：打 tag 推到仓库（Docker Hub / GHCR / 公司 Harbor 都行）
docker tag roomdesk-api:latest  <registry>/<user>/roomdesk-api:1.1.0
docker tag roomdesk-worker:latest <registry>/<user>/roomdesk-worker:1.1.0
docker push <registry>/<user>/roomdesk-api:1.1.0
docker push <registry>/<user>/roomdesk-worker:1.1.0

# 另一台：拉下来，并把 compose 里的 build: 换成 image:
#   api:
#     image: <registry>/<user>/roomdesk-api:1.1.0
#     # build: { … }        ← 注释掉
docker pull <registry>/<user>/roomdesk-api:1.1.0
docker compose up -d
```

注意两点：一是**版本一定要打 tag**（别用 `latest` 推生产）；二是 `migrator` 和 `db` 用的是官方
`postgres:16-alpine`，不需要推自己的。

**③ 离线 / 不能连网（U 盘拷镜像）**

```bash
# 有网的机器
docker save -o roomdesk-images.tar \
  roomdesk-api:latest roomdesk-worker:latest roomdesk-pgbouncer:latest \
  python:3.12-slim postgres:16-alpine adminer:4 alpine:3.20

# 目标机器
docker load -i roomdesk-images.tar
docker compose up -d            # 镜像已在本地，--build 也可以省
```

> `docker save` 出来通常是几百 MB 到 1 GB（4 个 base + 4 个自建）。
> 如果只是换一台有网的机器，**用第 ① 条**：拷几 MB 源码比拷 1 GB 镜像省事得多。

---

## 3. 启动编排

```bash
make up            # = docker compose up -d --build
# 或
docker compose up -d --build
```

`up` 会**先重建镜像再启动**，所以第 2 步可以省略；分开做只是为了看清每步发生了什么。

> 期望耗时（本机实测，镜像已构建、数据卷已存在）：
> **容器 12 秒全部起来，`api` 在第 19 秒左右变 healthy**。
> 如果数据卷是空的（第一次启动），多 3~5 秒（建库 + 跑 6 个迁移 + seed）。

### 3.1 七个服务与启动顺序

```
db（postgres:16-alpine）
 │  healthcheck: pg_isready -U $POSTGRES_USER -d $POSTGRES_DB
 ├──────────────▶ migrator（一次性：bootstrap → 迁移 → seed）
 │                   │  成功退出（exit 0）
 │                   ├──▶ api（等 pgbouncer 也 healthy 才起）
 │                   └──▶ worker
 ├──────────────▶ pgbouncer（自建镜像，等 db healthy）
 │                   └──▶ api（depends_on: service_healthy）
 ├──────────────▶ adminer
 └──────────────▶ backup（profile: ops，默认不启动）
                    test（profile: test，默认不启动）
```

用到的三种依赖条件，正好对应三种"准备好了"的定义：

| 条件 | 用在哪 | 含义 |
| --- | --- | --- |
| `service_healthy` | db → pgbouncer / adminer / worker | 健康检查通过才继续 |
| `service_completed_successfully` | migrator → api / worker | **一次性容器成功退出**（迁移失败就不启动 API） |
| `service_healthy` | pgbouncer → api | 连接池能接受连接 |

全程没有 `sleep`。

### 3.2 migrator 做的三件事

```
== 1/3 bootstrap（超级用户）：扩展 / 角色 / schema / 权限
bootstrap: 扩展 / 角色 / schema / 权限 已就绪

== 2/3 迁移（roomdesk_migrator）
   apply  0001_schema.sql
   apply  0002_events.sql
   apply  0003_views.sql
   apply  0004_functions.sql
   apply  0005_grants.sql
   apply  0006_booking_tags.sql
   新增 6 个，跳过 0 个

== 3/3 演示数据
   已灌入演示数据

== 结果
rooms=6
staff=8
bookings=16
迁移完成。
```

- 第一次跑：`新增 6 个`
- 之后每次 `up` 都会再跑一次 migrator，但全部 `skip`（幂等），几秒钟就退出。
- 迁移失败会返回非 0 → **api 不会启动**，这是有意的。

看它的输出：

```bash
docker compose logs migrator
```

### 3.3 看启动过程

```bash
docker compose logs -f --tail=50
```

`api` 起来后会有：

```
INFO:     Started parent process [1]
INFO:     Started server process [8]
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

`worker` 会有：

```
2026-11-08 ... INFO [worker] LISTEN roomdesk_bookings 已就绪
2026-11-08 ... INFO [worker] 读模型已刷新 rows=14
```

---

## 4. 验证服务

### 4.1 容器状态

```bash
docker compose ps
# 或
make ps          # 带 ops profile
```

正常应该长这样（**db / pgbouncer / api 必须是 (healthy)**）：

```
NAME                 STATUS                        PORTS
roomdesk-adminer     Up 2 minutes                  0.0.0.0:8080->8080/tcp
roomdesk-api         Up 40 seconds (healthy)       0.0.0.0:8000->8000/tcp
roomdesk-db          Up 1 minute (healthy)         0.0.0.0:55432->5432/tcp
roomdesk-pgbouncer   Up 45 seconds (healthy)       6432/tcp
roomdesk-worker      Up 40 seconds
```

`api` 显示 `health: starting` 是正常的，等 10~20 秒会转 `healthy`。

### 4.2 逐层验证数据链路

```powershell
# ① 数据库
docker compose exec db pg_isready -U roomdesk -d roomdesk
#    /var/run/postgresql:5432 - accepting connections

# ② 迁移结果
docker compose exec db psql -U roomdesk -d roomdesk -c "SELECT version FROM roomdesk.schema_migrations ORDER BY 1;"
#    6 行：0001_schema.sql … 0006_booking_tags.sql

# ③ 连接池（能看到 pool_mode = transaction）
make pools
#    database  |     user     | cl_active | sv_idle | pool_mode
#    roomdesk  | roomdesk_app |         5 |       3 | transaction

# ④ API 是否走的是池 + 最小权限角色
curl http://localhost:8000/health
#    {"status":"ok","db_user":"roomdesk_app","database":"roomdesk",
#     "server_version":"16.15","connections":3}
```

> `db_user` 必须是 `roomdesk_app`。如果它是 `roomdesk`（超级用户），说明 DATABASE_URL 配错了。

### 4.3 四个 HTTP 入口

```powershell
foreach ($p in '/ui/','/docs','/health','/api/ops/db') {
  $r = Invoke-WebRequest ("http://localhost:8000" + $p) -UseBasicParsing
  "{0,-14} {1}  {2}" -f $p, $r.StatusCode, $r.Headers['Content-Type']
}
```

```
/ui/           200  text/html; charset=utf-8
/docs          200  text/html; charset=utf-8
/health        200  application/json
/api/ops/db    200  application/json
```

---

## 5. 跑测试

测试跑在**另一个镜像**（`dev` 目标，带 pytest）里，通过 HTTP 打 `api` 服务：

```bash
make test
# 或
docker compose --profile test run --rm test
```

正常输出：

```
.................                                                        [100%]
17 passed in 0.67s
```

要点：

- `test` 服务的 `BASE_URL=http://api:8000`（走 compose 内网），不是 `127.0.0.1`；
- 它会自动拉起依赖（db / migrator / pgbouncer / **api / worker**），跑完 `--rm` 自动删掉容器；
- 为什么必须带 worker：`test_notify_pipeline_worker_to_notifications_table` 要验证
  `LISTEN/NOTIFY` 全链路，worker 不在就必然失败（**这条依赖是踩过坑才补上的**）；
- 生产镜像里没有 pytest，所以测试命令**不能**用 `docker compose exec api pytest`。

17 个用例覆盖：健康检查、池化+最小权限、应用角色不能 DDL、建预约、重叠 409、
8 线程并发抢房、幂等键、可用房间过滤、取消释放+分区事件、设备筛选、
非法区间 422、报表读物化视图、峰值小时、手动刷新鉴权、运维面板、分区行数、NOTIFY 全链路。

---

## 6. 打开前端

**这是最终目的，前面全是铺垫。**

```
http://localhost:8000/ui/
```

（`http://localhost:8000/` 会 307 跳到 `/ui/`。）

### 6.1 五个页签看什么

| 页签 | 你会看到 | 背后调用的接口 | 对应哪个数据库能力 |
| --- | --- | --- | --- |
| **总览** | 房间/人员/预约数、读模型新鲜度、最近 8 条预约 | `/api/ops/stats`、`/api/reports/utilization` | `count(*)`、物化视图 |
| **找空房** | 选时段/容量/设备 → 可用房间列表 + 「订它」 | `/api/rooms/available` | `free_rooms()` + `tstzrange &&` + JSONB `?&` |
| **预约** | 下单表单、搜索、取消；冲突时显示 409 的原文 | `POST/GET /api/bookings` | **GiST 排他约束** |
| **报表** | 使用率表（排名/占比/累计 + 条形）、按小时柱状图、刷新读模型 | `/api/reports/*`、`POST /api/ops/refresh` | 物化视图 + 窗口函数 vs 实时聚合 |
| **事件/运维** | NOTIFY 事件流（5s 自动刷新）、分区行数、慢 SQL、表体积 | `/api/ops/notifications`、`/partitions`、`/db` | 分区表、`pg_stat_statements` |

### 6.2 五分钟演示动线（建议按这个顺序点）

1. **找空房**：时间默认"明天 10:00–11:00"，容量填 8，勾 `投影仪` → 点「查询」→ 出现若干房间。
2. 点某个房间的 **「订它」** → 自动跳到「预约」页，房间和时段已填好。
3. 补充用途（如"技术评审"）→ **提交预约** → 顶部绿色提示 `预约成功：#id …`。
4. **再提交一次同一个表单** → 红色提示：
   > 失败（HTTP 409）：该房间在所选时间段已有预约（数据库排他约束拦下）
   > 由 PostgreSQL 的 EXCLUDE 约束拦下，应用层没有判重代码。

   **这句是整套项目最有说服力的一屏**：正确性来自数据库，不是来自 if 判断。
5. 回「找空房」重新查同一时段 → 该房间消失了（被占用）。
6. 去「预约」页点那条记录的 **取消** → 再查空房 → 它又回来了（部分索引 `status='confirmed'` 失效）。
7. 切到「报表」→ 看到排名/占比/累计；点「刷新读模型」→ 新鲜度秒数归零。等 15 秒再刷新页面，
   会发现 worker 自动刷过（`last_source` 变成 `worker`）。
8. 切到「事件/运维」→ 刚才的 `booking.created` / `booking.cancelled` 都在列表里
   （这是 worker 的 `LISTEN` 收到的 `NOTIFY`）；下面还有分区行数和最耗时的 SQL。

---

## 7. 日常开发的三条路径

### 7.1 只改 Python 代码

```bash
docker compose up -d --build api      # 增量重建，实测 ~1 秒
# 或不想重建：把 dev 目标跑起来，带 --reload
docker compose --profile test run --rm --service-ports api-dev 2>$null
```

> 本项目默认镜像不带 `--reload`。要热重载就把 `api` 的 `build.target` 临时改成 `dev`，
> 或者直接用本机模式（`run-local.cmd`，见 `docs/LOCAL-WITHOUT-DOCKER.md`）——改代码最快的一条路。

**只改前端**（`app/static/` 下的 html/js/css）：静态文件由 FastAPI 直接读磁盘，
**不需要重建镜像**，刷新浏览器即可（`/ui/` 的响应会重新读文件）。

### 7.2 改表结构

```bash
# 1. 新建迁移文件，别改已执行过的
vim db/migrations/0007_add_room_phone.sql

# 2. 应用（migrator 幂等，只跑新的）
docker compose run --rm migrator
# 或 make migrate（宿主机直连，不进容器）

# 3. 确认
docker compose exec db psql -U roomdesk -d roomdesk \
  -c "SELECT version FROM roomdesk.schema_migrations ORDER BY 1;"
```

### 7.3 什么时候必须加 `--build`

| 改了什么 | 要不要 `--build` |
| --- | --- |
| `app/**/*.py` | 要（代码在镜像里） |
| `app/requirements*.txt` | 要（依赖层重装） |
| `app/static/*` | 不要，刷新浏览器即可 |
| `db/**`、`scripts/**` | 不要（migrator 容器是挂载的） |
| `docker-compose.yml` / `.env` | 不要（`up -d` 会重建容器） |
| `worker/*.py` | 要（重建 worker 镜像） |
| `pgbouncer/*` | 要（重建 pgbouncer 镜像） |

---

## 8. 停止 / 重启 / 重置 / 备份

### 8.1 停止与重启

```bash
docker compose stop            # 停容器，保留数据
docker compose start           # 再启动
docker compose restart api     # 只重启某个服务
docker compose down            # 停 + 删容器/网络（**数据卷保留**）
make up                        # 重新拉起
```

### 8.2 彻底重置（数据全丢）

```bash
make reset                     # = docker compose --profile ops down -v && up -d --build
```

删掉的是命名卷 `roomdesk_pgdata`。重置后 migrator 会重新跑 6 个迁移 + seed。

### 8.3 备份与恢复

```bash
make backup                                   # 手动：pg_dump -Fc → ./backups/
# PowerShell 等价：pwsh ./task.ps1 backup
docker compose --profile ops up -d backup     # 定时：每小时一次（容器内循环）
ls backups/                                   # roomdesk-<时间戳>.dump + .schema.sql

# 恢复（会把库清空后重建对象）
make restore FILE=backups/roomdesk-20261108-143000.dump
```

备份脚本（`scripts/backup.sh`）做的不只是 `pg_dump`：

| 步骤 | 做什么 | 为什么 |
| --- | --- | --- |
| 0 | 清掉历史上 0 字节的 `.dump` | 失败过一次就会留下"假备份"，不清理会一直混在里面 |
| 1 | 先写 `*.dump.part` | 中途失败不会在正式文件名下留半截文件 |
| 2 | `pg_restore --list` 读一遍 | 文件能打开才算有效备份 |
| 3 | 校验通过才 `mv` 成正式名 | 失败时只留下 `.part`，且会被清掉 |
| 4 | 轮转，只保留最近 `BACKUP_KEEP`（默认 14）份 | 每小时一份，不轮转几天就撑爆磁盘 |

实测输出：

```
== 备份到 ./backups（保留最近 14 份）
  已清理 0 字节的空备份
   pg_dump ...
   校验 dump 可读 ...

-rw-r--r-- 1 app      app      37K ./backups/roomdesk-20261108-212813.dump
-rw-r--r-- 1 app      app      19K ./backups/roomdesk-20261108-212813.schema.sql
现有备份 10 份，最新：roomdesk-20261108-212813.dump
```

把 `BACKUP_KEEP` 调小可以验证轮转（默认 14，`.env` 里可改）：

```bash
BACKUP_KEEP=5 bash scripts/backup.sh
#    轮转删除 roomdesk-20261107-184257.dump
#    ...
# 现有备份 5 份，最新：roomdesk-20261108-212821.dump
```

演练过的完整流程：备份 → `DROP SCHEMA roomdesk CASCADE` → 恢复 → 核对行数（6/24/25）。

---

## 9. 排障速查

按**报错信息**索引。前三条是这套项目最常遇到的。

| 报错 / 现象 | 原因 | 解决 |
| --- | --- | --- |
| `failed to fetch oauth token … auth.docker.io` | BuildKit 拉 `FROM` 元数据走直连，绕过代理 | 先 `make pull` 把基础镜像拉到本地，再 `up --build`（见 §1） |
| `failed to connect to the docker API at npipe://…` | Docker Desktop 没启动 | 启动 Docker Desktop，等图标变绿 |
| `Virtual Machine Platform is not enabled`（但其实已启用） | Windows 功能已启用但**没重启**，`WslService` 起不来 | 重启电脑，再启动 Docker Desktop |
| `api` 一直 `health: starting` 不转 healthy | `/health` 打不通数据库 | `docker compose logs api`；再 `docker compose exec db pg_isready -U roomdesk` |
| `api` 根本没启动 | migrator 失败了（`service_completed_successfully` 不满足） | `docker compose logs migrator` 看哪一步报错 |
| `permission denied for schema roomdesk` | 用的是应用角色（设计如此） | 需要 DDL 用 `make psql`（超级用户）；应用角色就不该建表 |
| `test_notify_pipeline_… FAILED`（其他都过） | `test` 服务要验证 NOTIFY 链路，但 **worker 没在跑** | 先 `make up`（会起 worker）；`test` 已声明对 worker 的依赖，正常不会漏 |
| `execvpe(/bin/bash) failed: No such file or directory` | PowerShell 里 `bash` 解析到了 `C:\Windows\System32\bash.exe`（WSL 存根），而机器没装发行版 | 用 `pwsh ./task.ps1 backup`（已显式找 Git Bash）或在 Git Bash 里跑 `make`；别在 PowerShell 里直接敲 `bash xxx.sh` |
| `prepared statement "…" already exists` | 走事务池却开了服务端预编译 | `app/db.py` 里 `prepare_threshold=None` 不能去掉 |
| `REFRESH MATERIALIZED VIEW CONCURRENTLY cannot run inside a transaction block` | 在事务里刷新 | 用 `db.autocommit_connection()`；且物化视图要有唯一索引 |
| `only '%s','%b','%t' are allowed as placeholders` | SQL 里的 `%` 被 psycopg 当占位符 | 写成 `%%`（`ILIKE '%%x%%'`） |
| `pg_stat_statements` 里全是 `<insufficient privilege>` | 缺预定义角色 | `bootstrap.sql` 里 `GRANT pg_read_all_stats` |
| 端口 `8000/8080/55432` 被占 | 有别的服务在用 | 改 `.env` 里的 `API_PORT / ADMINER_PORT / DB_PORT` |
| `/` 返回 404 / `/ui/` 404 | 镜像太旧（前端是后来加的） | `docker compose up -d --build api` |
| 前端页面能开但列表全空 | DB 没数据 / worker 没起 | `docker compose logs worker`；`make test` 会灌一些数据 |
| `docker compose exec api pytest` 报 `No module named pytest` | 生产镜像故意不带测试依赖 | 用 `make test`（dev 目标镜像 + test 服务） |
| worker 日志没有 `LISTEN ... 已就绪` | 连不上 db 或角色没权限 | `docker compose logs worker`；确认 `WORKER_DSN` 里的角色存在 |

常用诊断命令一览：

```bash
docker compose ps                              # 谁不 healthy
docker compose logs --tail=100 api             # 应用日志
docker compose logs --tail=100 migrator        # 迁移日志
docker compose logs --tail=50 worker           # LISTEN / REFRESH
docker compose exec db pg_isready -U roomdesk  # 数据库
make pools                                     # 连接池
docker inspect roomdesk-api --format '{{.State.Health.Status}}'
```

---

## 附录 A：命令对照表

| 动作 | make | task.ps1 | 原生 |
| --- | --- | --- | --- |
| 拉基础镜像 | `make pull` | `pwsh ./task.ps1 pull` | 4 条 `docker pull` |
| 只构建 | `make build` | `… build` | `docker compose --profile test build` |
| 构建并启动 | `make up` | `… up` | `docker compose up -d --build` |
| 看状态 | `make ps` | `… ps` | `docker compose ps` |
| 跑测试 | `make test` | `… test` | `docker compose --profile test run --rm test` |
| 迁移 | `make migrate` | `… migrate` | `docker compose run --rm migrator` |
| 连接池 | `make pools` | `… pools` | `docker compose exec -e PGPASSWORD=… pgbouncer psql …` |
| 应用角色 psql | `make psql-app` | `… psql-app` | `docker compose exec -e PGPASSWORD=app_pw db psql -h pgbouncer …` |
| 备份 | `make backup` | `… backup` | `bash scripts/backup.sh` |
| 重置 | `make reset` | `… reset` | `docker compose --profile ops down -v && up -d --build` |

## 附录 B：端口与账号

| 项 | 值 |
| --- | --- |
| API / 前端 | `http://localhost:8000` → `/ui/`（前端）、`/docs`（接口文档） |
| Adminer | `http://localhost:8080`，System=PostgreSQL，Server=`db` |
| 数据库（宿主映射） | `localhost:55432` |
| 连接池 | `pgbouncer:6432`（compose 内网） |
| 超级用户 | `roomdesk` / `roomdesk`（`POSTGRES_USER`） |
| 应用角色 | `roomdesk_app` / `app_pw` |
| 只读角色 | `roomdesk_reader` / `reader_pw` |
| 运维接口 token | `dev-admin-token`（`X-Admin-Token` 头） |
| 数据库名 | `roomdesk`（schema：`roomdesk` + `reporting`） |

全部可在 `.env` 里改（复制 `.env.example`）。
