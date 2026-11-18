# worker 镜像：只装 psycopg（不需要 fastapi/uvicorn），可与 api 独立发布
ARG PYTHON_IMAGE=python:3.12-slim
ARG PIP_INDEX_URL=https://pypi.org/simple

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

FROM base AS deps
COPY requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

FROM base AS runtime
COPY --from=deps /opt/venv /opt/venv
COPY --chown=root:app consumer.py ./

USER app
STOPSIGNAL SIGTERM

CMD ["python", "-u", "consumer.py"]
