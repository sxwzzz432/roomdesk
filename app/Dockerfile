# ============================================================
#  API 镜像（多阶段构建）
#
#  阶段划分直接对应"构建一次、用在不同地方"：
#    base         → 公共环境变量 + 非 root 用户（uid 1001）
#    deps-runtime → venv，只装 requirements.txt（生产依赖）
#    deps-dev     → 在 runtime 依赖上再加 pytest / httpx
#    runtime      → 最终镜像：只带 runtime venv + 源码（**不带测试依赖**）
#    dev          → 带测试依赖 + --reload，给 `make test` / 本地调试
#
#  两个刻意的优化：
#    · RUN --mount=type=cache,target=/root/.cache/pip
#      pip 的 wheel 缓存挂在构建缓存里，重建时不再重复下载
#    · COPY 顺序：先 requirements 再源码
#      只改代码时，依赖层直接命中缓存
#
#  用法：
#    docker build --target runtime -t roomdesk-api ./app        # 生产
#    docker build --target dev     -t roomdesk-api:dev ./app    # 跑测试
# ============================================================
ARG PYTHON_IMAGE=python:3.12-slim
ARG PIP_INDEX_URL=https://pypi.org/simple

# ---------- 公共底座 ----------
FROM ${PYTHON_IMAGE} AS base

LABEL org.opencontainers.image.title="roomdesk-api" \
      org.opencontainers.image.description="会议室预约与分析平台 API（FastAPI + psycopg3，手写 SQL）" \
      org.opencontainers.image.source="roomdesk/app"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=0 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    PATH=/opt/venv/bin:$PATH

# 固定 uid/gid：容器内不以 root 跑，挂载卷的归属也可预期
RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home app

WORKDIR /srv

# ---------- 只装运行时依赖 ----------
FROM base AS deps-runtime
COPY requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

# ---------- 运行时依赖 + 测试依赖 ----------
FROM deps-runtime AS deps-dev
COPY requirements-dev.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/pip install -r requirements-dev.txt

# ---------- 最终镜像（生产） ----------
FROM base AS runtime
COPY --from=deps-runtime /opt/venv /opt/venv
# 源码 root:app 0755，运行用户只读
COPY --chown=root:app . .

USER app
EXPOSE 8000
STOPSIGNAL SIGTERM

# 镜像自带健康检查（compose 里若另配会覆盖它）
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" || exit 1

# 2 个 worker 进程：容器内的水平扩展，配合 pgbouncer 才不会压垮连接数
CMD ["uvicorn", "main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--proxy-headers", "--timeout-graceful-shutdown", "10"]

# ---------- 测试 / 调试镜像 ----------
FROM base AS dev
COPY --from=deps-dev /opt/venv /opt/venv
COPY --chown=root:app . .

USER app
EXPOSE 8000
# 这个阶段不带 healthcheck：它主要用于 pytest 与 --reload
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
