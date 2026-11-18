# API 镜像：base → deps-runtime / deps-dev → runtime / dev
# runtime 不带测试依赖；dev 给 pytest 与 --reload 用（docker build --target dev）
ARG PYTHON_IMAGE=python:3.12-slim
ARG PIP_INDEX_URL=https://pypi.org/simple

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

RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home app

WORKDIR /srv

FROM base AS deps-runtime
COPY requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

FROM deps-runtime AS deps-dev
COPY requirements-dev.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/pip install -r requirements-dev.txt

FROM base AS runtime
COPY --from=deps-runtime /opt/venv /opt/venv
COPY --chown=root:app . .

USER app
EXPOSE 8000
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" || exit 1

CMD ["uvicorn", "main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--proxy-headers", "--timeout-graceful-shutdown", "10"]

FROM base AS dev
COPY --from=deps-dev /opt/venv /opt/venv
COPY --chown=root:app . .

USER app
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
