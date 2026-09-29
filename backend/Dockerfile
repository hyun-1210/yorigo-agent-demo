# Railway-optimized image: API only, no Chrome/Xvfb or scraping schedulers.
# Scraping and cookie extraction run on local backend only.
FROM python:3.11-slim

# Minimal deps: FFmpeg for transcription; ca-certificates for HTTPS; curl+unzip for Deno install
# libgl1: OpenCV (used by RapidOCR) requires libGL.so.1 (not in python-slim)
# libglib2.0-0: OpenCV requires libgthread-2.0.so.0
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    ca-certificates \
    curl \
    unzip \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Deno for yt-dlp EJS (YouTube signature/n challenge solving).
# deno.land can fail on CI with curl exit 56 — retry + GitHub release fallback.
RUN set -eux; \
    install_deno() { curl -fsSL https://deno.land/install.sh | sh; }; \
    if ! install_deno; then \
      echo "[build] deno.land install failed, retrying..."; sleep 15; install_deno; \
    fi; \
    mv /root/.deno/bin/deno /usr/local/bin/deno; \
    rm -rf /root/.deno; \
    deno --version

WORKDIR /app

COPY backend/requirements-railway.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements-railway.txt

# Smoke-test: verify RapidOCR + onnxruntime import cleanly.
RUN python -c "from rapidocr import RapidOCR; print('[build] RapidOCR import OK')"

# RapidOCR: download Korean det/rec/cls ONNX models at build time
# [Ss]cripts: Windows working trees may be Scripts/; git/Linux checkouts use scripts/
COPY backend/[Ss]cripts/bake_rapidocr_models.py /tmp/bake_rapidocr_models.py
RUN python /tmp/bake_rapidocr_models.py && rm -f /tmp/bake_rapidocr_models.py

# Application code
COPY backend/backend.py /app/backend.py
COPY backend/models.py /app/models.py
COPY backend/cookie_manager.py /app/cookie_manager.py
COPY backend/watchdog.py /app/watchdog.py
COPY backend/rate_limiter.py /app/rate_limiter.py
COPY backend/blocking_pool.py /app/blocking_pool.py
COPY backend/ffmpeg_cap.py /app/ffmpeg_cap.py
COPY backend/proxy_manager.py /app/proxy_manager.py
COPY backend/process_supervisor.py /app/process_supervisor.py
COPY backend/timestamp_worker_main.py /app/timestamp_worker_main.py

# Price collection scheduler (Railway only, enabled via ENABLE_PRICE_COLLECTION_SCHEDULER)
COPY backend/ingredient_price_scheduler.py /app/ingredient_price_scheduler.py

COPY backend/utils/ /app/utils/
COPY backend/services/ /app/services/
COPY backend/routers/ /app/routers/
COPY backend/data/ /app/data/

# 런타임에 product_service가 import하는 재료 목록만 포함 (나머지 스크립트는 로컬/테스트용)
RUN mkdir -p /app/scripts
COPY backend/[Ss]cripts/updated_ingredients.py /app/scripts/

EXPOSE ${PORT:-8000}

# Conservative concurrency defaults (tighten if "can't start new thread" reappears).
# Dual-process: process_supervisor runs API (uvicorn) + dedicated timestamp workers.
# API child forces ENABLE_TIMESTAMP_WORKER=false; timestamp children have no HTTP listener.
# TIMESTAMP_WORKER_CONCURRENCY=N → supervisor spawns N independent timestamp processes
# (each forced to in-process concurrency=1 for safe budget self-exit).
ENV UVICORN_WORKERS=1 \
    TIMESTAMP_WORKER_CONCURRENCY=2 \
    TIMESTAMP_WORKER_IDLE_BACKOFF_BASE_SECONDS=1 \
    TIMESTAMP_WORKER_IDLE_BACKOFF_MAX_SECONDS=60 \
    BLOCKING_POOL_WORKERS=20 \
    PARSE_MAX_CONCURRENT=13 \
    WHISPER_MAX_CONCURRENT=2 \
    OCR_MAX_CONCURRENT=2 \
    STEP_TS_MAX_CONCURRENT=1 \
    CDN_DOWNLOAD_PARALLEL=true \
    FFMPEG_MAX_CONCURRENT=1 \
    FFMPEG_THREADS=1 \
    FFMPEG_EAGAIN_RETRIES=3 \
    FFMPEG_EAGAIN_BACKOFF_SEC=3 \
    PARSE_STEP_TS_RETRIES=1 \
    PARSE_STEP_TS_RETRY_BACKOFF_SEC=5 \
    TS_ENRICH_RETRIES=1 \
    SUPERVISOR_SHUTDOWN_GRACE_SECONDS=25 \
    SUPERVISOR_KILL_GRACE_SECONDS=5 \
    SUPERVISOR_RESTART_BACKOFF_BASE_SECONDS=1 \
    SUPERVISOR_RESTART_BACKOFF_MAX_SECONDS=30 \
    SUPERVISOR_RESTART_WARN_WINDOW_SECONDS=600 \
    SUPERVISOR_RESTART_WARN_THRESHOLD=5

# JSON exec form: Python supervisor is PID 1 (receives SIGTERM directly).
CMD ["python", "process_supervisor.py"]
