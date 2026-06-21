FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    HF_HOME=/models \
    FASTEMBED_CACHE_PATH=/models

WORKDIR /app

RUN uv pip install --system --no-cache \
    fastapi==0.115.6 \
    "uvicorn[standard]==0.34.0" \
    fastembed==0.7.3

COPY app.py /app/app.py

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
