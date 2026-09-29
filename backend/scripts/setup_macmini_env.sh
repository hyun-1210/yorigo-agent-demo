#!/usr/bin/env bash
# Railway/로컬 백업에서 맥미니 .env 및 Firebase JSON 복사
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  setup_macmini_env.sh --env /path/to/railway-env-backup.env [--firebase /path/to/firebase.json]
  setup_macmini_env.sh --firebase /path/to/firebase.json

옵션:
  --env PATH       Railway/EC2 백업 .env 파일 (KEY=VALUE 형식)
  --firebase PATH  Firebase service account JSON
  --force          기존 .env / firebase-service-account.json 덮어쓰기

예시:
  ./scripts/setup_macmini_env.sh \
    --env ~/Downloads/railway-env-backup.env \
    --firebase ~/Downloads/yorigo-firebase-adminsdk.json
EOF
}

ENV_SRC=""
FB_SRC=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_SRC="${2:-}"; shift 2 ;;
    --firebase) FB_SRC="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ENV_SRC" && -z "$FB_SRC" ]]; then
  usage
  exit 1
fi

DEST_ENV="$BACKEND_DIR/.env"
DEST_FB="$BACKEND_DIR/firebase-service-account.json"
EXAMPLE="$BACKEND_DIR/.env.macmini.example"

if [[ -n "$ENV_SRC" ]]; then
  if [[ ! -f "$ENV_SRC" ]]; then
    echo "[setup] env 파일 없음: $ENV_SRC" >&2
    exit 1
  fi
  if [[ -f "$DEST_ENV" && "$FORCE" != true ]]; then
    echo "[setup] $DEST_ENV 이미 존재. --force 로 덮어쓰기" >&2
    exit 1
  fi

  if [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$DEST_ENV"
    echo "[setup] .env.macmini.example 기반으로 생성"
  else
    touch "$DEST_ENV"
  fi

  # 백업 env의 KEY=VALUE를 .env에 merge (기존 값 유지, 새 값만 추가/갱신)
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="$(echo "$key" | xargs)"
    [[ -z "$key" ]] && continue
    if grep -q "^${key}=" "$DEST_ENV" 2>/dev/null; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^${key}=.*|${key}=${val}|" "$DEST_ENV"
      else
        sed -i "s|^${key}=.*|${key}=${val}|" "$DEST_ENV"
      fi
    else
      echo "${key}=${val}" >> "$DEST_ENV"
    fi
  done < "$ENV_SRC"

  # 맥미니 파싱 전담 플래그·동시성 강제 (Railway 고동시성 값 덮어쓰기 방지)
  # Instagram Step1은 APIFY_API_TOKEN 필요(Railway .env 백업에서 merge).
  # 타임스탬프는 Railway 워커가 처리 → 큐만 적재, 로컬 워커 OFF.
  for kv in \
    "YORIGO_PARSE_WORKER=true" \
    "STEP_TIMESTAMP_DISPATCH=queue" \
    "ENABLE_TIMESTAMP_WORKER=false" \
    "ENABLE_PRODUCTION_SCHEDULERS=false" \
    "ENABLE_SCRAPING_SCHEDULER=false" \
    "ENABLE_KURLY_SCRAPING_SCHEDULER=false" \
    "ENABLE_PRICE_COLLECTION_SCHEDULER=false" \
    "ENABLE_PRODUCT_HEALTH_CHECK=false" \
    "ENABLE_UNDERAGE_CLEANUP_SCHEDULER=false" \
    "UVICORN_WORKERS=1" \
    "UVICORN_MAX_REQUESTS=100" \
    "BLOCKING_POOL_WORKERS=12" \
    "PARSE_MAX_CONCURRENT=4" \
    "WHISPER_MAX_CONCURRENT=2" \
    "OCR_MAX_CONCURRENT=2" \
    "FFMPEG_MAX_CONCURRENT=2" \
    "WHISPER_CPU_THREADS=4" \
    "OMP_NUM_THREADS=2" \
    "ONNXRUNTIME_SESSION_THREAD_POOL_SIZE=2" \
    "FFMPEG_THREADS=2"
  do
    k="${kv%%=*}"
    v="${kv#*=}"
    if grep -q "^${k}=" "$DEST_ENV" 2>/dev/null; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^${k}=.*|${k}=${v}|" "$DEST_ENV"
      else
        sed -i "s|^${k}=.*|${k}=${v}|" "$DEST_ENV"
      fi
    else
      echo "${k}=${v}" >> "$DEST_ENV"
    fi
  done

  if grep -q "^APIFY_API_TOKEN=" "$DEST_ENV" 2>/dev/null; then
    echo "[setup] APIFY_API_TOKEN 확인됨 (Instagram Apify Step1)"
  else
    echo "[setup] WARN: APIFY_API_TOKEN 없음 — Instagram Step1이 yt-dlp fallback만 사용합니다." >&2
    echo "[setup]       Railway/운영 .env에 APIFY_API_TOKEN을 넣어 --env 로 다시 merge 하세요." >&2
  fi

  echo "[setup] .env 생성/갱신: $DEST_ENV"
fi

if [[ -n "$FB_SRC" ]]; then
  if [[ ! -f "$FB_SRC" ]]; then
    echo "[setup] Firebase JSON 없음: $FB_SRC" >&2
    exit 1
  fi
  if [[ -f "$DEST_FB" && "$FORCE" != true ]]; then
    echo "[setup] $DEST_FB 이미 존재. --force 로 덮어쓰기" >&2
    exit 1
  fi
  cp "$FB_SRC" "$DEST_FB"
  chmod 600 "$DEST_FB"
  echo "[setup] Firebase JSON 복사: $DEST_FB"
fi

echo "[setup] 완료. scripts/check_macmini_ready.sh 로 검증하세요."
