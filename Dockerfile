FROM python:3.11-slim

# Install FFmpeg and other dependencies
# Xvfb (X Virtual Framebuffer) for virtual display in headless environments
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    xvfb \
    x11vnc \
    x11-xserver-utils \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY backend/requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy all Python modules from backend
# IMPORTANT: coupang_scheduler.py must be included
COPY backend/coupang_scheduler.py .
COPY backend/backend.py .
COPY backend/models.py .
COPY backend/cookie_manager.py .
COPY backend/watchdog.py .
COPY backend/rate_limiter.py .

# Copy backend directories
COPY backend/utils/ ./utils/
COPY backend/services/ ./services/
COPY backend/routers/ ./routers/

# Expose port (Railway will set $PORT)
EXPOSE ${PORT:-8000}

# Start command with multiple workers for Railway Pro
# Use environment variable to control worker count (default: 4)
CMD uvicorn backend:app --host 0.0.0.0 --port ${PORT:-8000} --workers ${UVICORN_WORKERS:-4}

