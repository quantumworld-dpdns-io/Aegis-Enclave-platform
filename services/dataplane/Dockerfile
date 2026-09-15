# 多階段建置：最終映像不含編譯器與 lock 以外的開發工具，並以非 root 執行。
# 容器內 Python 固定 3.12，對齊 docs/CONTRACT.md 第 1 節。
FROM python:3.14-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:0.8.15 /uv /usr/local/bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY app ./app

FROM python:3.14-slim-bookworm

# 10002 對齊 infra/k8s/base/dataplane.yaml 的 runAsUser。
RUN groupadd --gid 10002 aegis \
    && useradd --uid 10002 --gid 10002 --system --no-create-home aegis \
    && mkdir -p /app \
    && chown aegis:aegis /app

WORKDIR /app
COPY --from=builder --chown=aegis:aegis /app/.venv /app/.venv
COPY --from=builder --chown=aegis:aegis /app/app /app/app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app

USER 10002:10002
EXPOSE 8000

# 根檔案系統在 K8s 會是唯讀；這裡只讀自己的程式與 venv。
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
