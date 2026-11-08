# ============================================================
#  worker 镜像（事件消费者 + 读模型刷新器）
#
#  故意和 api 分成两个镜像：
#    · worker 只需要 psycopg，不需要 fastapi/uvicorn → 镜像小得多
#    · 两者可以独立发布、独立回滚、独立限流
#
#  非 root（uid 1001）+ pip 缓存挂载，与 api 保持一致的风格。
# ============================================================
ARG PYTHON_IMAGE=python:3.12-slim
ARG PIP_INDEX_URL=https://pypi.org/simple

# ---------- 公共底座 ----------
FROM ${PYTHON_IMAGE} AS base

LABEL org.opencontainers.image.title="roomdesk-worker" \
      org.opencontainers.image.description="LISTEN/NOTIFY 消费者 + 物化视图定时刷新" \
      org.opencontainers.image.source="roomdesk/worker"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    PATH=/opt/venv/bin:$PATH

RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home app

WORKDIR /srv

# ---------- 依赖 ----------
FROM base AS deps
COPY requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

# ---------- 最终镜像 ----------
FROM base AS runtime
COPY --from=deps /opt/venv /opt/venv
COPY --chown=root:app consumer.py ./

USER app
STOPSIGNAL SIGTERM

# worker 没有 HTTP 端口；它是否活着看日志里的 "LISTEN ... 已就绪"，
# 挂掉由 compose 的 restart 策略兜底（见 docker-compose.yml）。
CMD ["python", "-u", "consumer.py"]
