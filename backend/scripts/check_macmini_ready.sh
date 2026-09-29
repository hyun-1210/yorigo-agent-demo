#!/usr/bin/env bash
# 맥미니 파싱 워커 준비 상태 검사
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$BACKEND_DIR"

export PATH="$HOME/.local/bin:$HOME/.deno/bin:$HOME/miniforge3/bin:$PATH"

PASS=0
FAIL=0
WARN=0

ok() { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
ng() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

echo "=== Yorigo Mac mini Parse Worker Readiness Check ==="
echo

echo "[1] Toolchain"
if [[ -x "$BACKEND_DIR/.venv/bin/python" ]]; then
  PY_VER="$("$BACKEND_DIR/.venv/bin/python" --version 2>&1)"
  ok "Python venv: $PY_VER"
else
  ng "Python venv 없음 ($BACKEND_DIR/.venv)"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)"
else
  ng "ffmpeg 없음 (miniforge3/bin/ffmpeg 또는 PATH 확인)"
fi

if command -v deno >/dev/null 2>&1; then
  ok "deno: $(deno --version 2>/dev/null | head -1)"
else
  ng "deno 없음 ($HOME/.deno/bin/deno)"
fi

if [[ -x "$BACKEND_DIR/.venv/bin/python" ]]; then
  if "$BACKEND_DIR/.venv/bin/python" -c "from rapidocr import RapidOCR" 2>/dev/null; then
    ok "RapidOCR import"
  else
    ng "RapidOCR import 실패"
  fi
fi

echo
echo "[2] Secrets / Config"
if [[ -f "$BACKEND_DIR/.env" ]]; then
  ok ".env 존재"
  set -a
  # shellcheck disable=SC1091
  source "$BACKEND_DIR/.env"
  set +a
else
  ng ".env 없음 — cp .env.macmini.example .env 후 값을 채우거나 setup_macmini_env.sh 실행"
fi

FB_JSON="${FIREBASE_SERVICE_ACCOUNT_JSON:-firebase-service-account.json}"
if [[ "$FB_JSON" != "{"* ]]; then
  if [[ ! "$FB_JSON" = /* ]]; then
    FB_JSON="$BACKEND_DIR/$FB_JSON"
  fi
fi

if [[ -f "$FB_JSON" ]]; then
  ok "Firebase credentials: $(basename "$FB_JSON")"
elif [[ -n "${FIREBASE_SERVICE_ACCOUNT_JSON:-}" && "$FIREBASE_SERVICE_ACCOUNT_JSON" == "{"* ]]; then
  ok "Firebase credentials: env JSON string"
else
  ng "Firebase service account 없음 ($FB_JSON)"
fi

for VAR in GEMINI_API_KEY; do
  if [[ -n "${!VAR:-}" ]]; then
    ok "$VAR 설정됨"
  else
    ng "$VAR 미설정"
  fi
done

if [[ -n "${YOUTUBE_COOKIES_SOURCE_URL:-}" || -n "${YOUTUBE_COOKIES_BASE64:-}" ]]; then
  ok "YouTube cookies 설정됨"
else
  warn "YouTube cookies 미설정 — YouTube 파싱 실패 가능"
fi

if [[ "${YORIGO_PARSE_WORKER:-false}" == "true" ]]; then
  ok "YORIGO_PARSE_WORKER=true"
else
  warn "YORIGO_PARSE_WORKER 미설정 — 파싱 전담 모드 아님"
fi

echo
echo "[3] Scheduler gating"
if [[ "${ENABLE_PRODUCTION_SCHEDULERS:-false}" == "true" ]]; then
  warn "ENABLE_PRODUCTION_SCHEDULERS=true — 맥미니에서는 false 권장"
else
  ok "ENABLE_PRODUCTION_SCHEDULERS=false (또는 미설정)"
fi

if [[ "${ENABLE_SCRAPING_SCHEDULER:-false}" == "true" ]]; then
  warn "ENABLE_SCRAPING_SCHEDULER=true — 맥미니에서는 false 권장"
else
  ok "ENABLE_SCRAPING_SCHEDULER=false (또는 미설정)"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed, $WARN warnings ==="
if [[ $FAIL -gt 0 ]]; then
  echo "준비 미완료. 위 FAIL 항목을 해결한 뒤 다시 실행하세요."
  exit 1
fi
echo "준비 완료. scripts/run_macmini.sh 로 서버를 시작할 수 있습니다."
exit 0
