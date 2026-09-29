#!/usr/bin/env bash
# 맥미니 파싱 전담 백엔드 실행 스크립트
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BACKEND_DIR"

export PATH="$HOME/.local/bin:$HOME/.deno/bin:$HOME/miniforge3/bin:$PATH"

if [[ -f "$BACKEND_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BACKEND_DIR/.env"
  set +a
fi

if [[ ! -d "$BACKEND_DIR/.venv" ]]; then
  echo "[run_macmini] .venv 없음. 먼저 uv venv 및 pip install을 실행하세요." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$BACKEND_DIR/.venv/bin/activate"

UVICORN_ARGS=(
  --host "${HOST:-0.0.0.0}"
  --port "${PORT:-8000}"
  --workers "${UVICORN_WORKERS:-1}"
)

# Railway에서 thread 누수 완화용: N건 처리 후 워커 프로세스 재시작 (0=비활성)
if [[ -n "${UVICORN_MAX_REQUESTS:-}" && "${UVICORN_MAX_REQUESTS}" != "0" ]]; then
  UVICORN_ARGS+=(--limit-max-requests "${UVICORN_MAX_REQUESTS}")
fi

exec python -m uvicorn backend:app "${UVICORN_ARGS[@]}"
