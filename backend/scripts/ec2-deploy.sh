#!/usr/bin/env bash
# EC2 /opt/yorigo/deploy.sh — GitHub Actions SSM deploy entrypoint.
# Loads ALL /yorigo/prod/* SSM parameters into the Docker container, then merges
# /opt/yorigo/env.production (non-secret flags / domain overrides).
#
# Install on EC2:
#   cp backend/scripts/ec2-deploy.sh /opt/yorigo/deploy.sh
#   chmod +x /opt/yorigo/deploy.sh
#   # Edit ECR_URI below with your AWS account ID.
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ECR_URI="${ECR_URI:-839922332232.dkr.ecr.ap-northeast-2.amazonaws.com/yorigo-backend}"
IMAGE_TAG="${1:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-yorigo-backend}"
SSM_PREFIX="${SSM_PREFIX:-/yorigo/prod}"

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$(echo "$ECR_URI" | cut -d/ -f1)"

RUNTIME_ENV="/opt/yorigo/.env.runtime"
: > "$RUNTIME_ENV"
chmod 600 "$RUNTIME_ENV"
export RUNTIME_ENV

# SSM Parameter Store → .env.runtime (paginated; skips junk keys like "test").
echo "[deploy] Loading SSM parameters from ${SSM_PREFIX} ..."
NEXT_TOKEN=""
while true; do
  if [ -n "$NEXT_TOKEN" ]; then
    RESP=$(aws ssm get-parameters-by-path \
      --path "$SSM_PREFIX" \
      --with-decryption \
      --recursive \
      --region "$AWS_REGION" \
      --starting-token "$NEXT_TOKEN" \
      --output json)
  else
    RESP=$(aws ssm get-parameters-by-path \
      --path "$SSM_PREFIX" \
      --with-decryption \
      --recursive \
      --region "$AWS_REGION" \
      --output json)
  fi

  echo "$RESP" | python3 -c "
import json, os, sys
data = json.load(sys.stdin)
skip = {'test'}
out = os.environ['RUNTIME_ENV']
for p in data.get('Parameters', []):
    key = p['Name'].rstrip('/').split('/')[-1]
    if not key or key in skip:
        continue
    val = p.get('Value') or ''
    if not val:
        continue
    with open(out, 'a', encoding='utf-8') as f:
        f.write(f'{key}={val}\n')
"

  NEXT_TOKEN=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('NextToken') or '')")
  [ -z "$NEXT_TOKEN" ] && break
done

LOADED_COUNT=$(grep -c '^[A-Za-z_]' "$RUNTIME_ENV" 2>/dev/null || echo 0)
echo "[deploy] Loaded ${LOADED_COUNT} SSM keys into .env.runtime"

# SSM typo alias: code reads YOUTUBE_COOKIES_REFRESH_INTERVAL_SECONDS (with trailing S).
if grep -q '^YOUTUBE_COOKIES_REFRESH_INTERVAL_SECOND=' "$RUNTIME_ENV" 2>/dev/null \
   && ! grep -q '^YOUTUBE_COOKIES_REFRESH_INTERVAL_SECONDS=' "$RUNTIME_ENV" 2>/dev/null; then
  VAL=$(grep '^YOUTUBE_COOKIES_REFRESH_INTERVAL_SECOND=' "$RUNTIME_ENV" | cut -d= -f2-)
  echo "YOUTUBE_COOKIES_REFRESH_INTERVAL_SECONDS=${VAL}" >> "$RUNTIME_ENV"
  echo "[deploy] Aliased YOUTUBE_COOKIES_REFRESH_INTERVAL_SECOND → ..._SECONDS"
fi

# Non-secret / infra overrides (PUBLIC_API_DOMAIN, ENABLE_PRODUCTION_SCHEDULERS, NICE URLs, …).
if [ -f /opt/yorigo/env.production ]; then
  echo "[deploy] Merging /opt/yorigo/env.production"
  cat /opt/yorigo/env.production >> "$RUNTIME_ENV"
else
  echo "[deploy] WARN: /opt/yorigo/env.production not found"
fi

echo "[deploy] Disk before cleanup:"
df -h / /var/lib/docker 2>/dev/null || df -h /

echo "[deploy] Stopping old container (free references before image prune) ..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

echo "[deploy] Pruning unused Docker images/layers ..."
docker image prune -af 2>/dev/null || true
docker builder prune -af 2>/dev/null || true

echo "[deploy] Disk after cleanup:"
df -h / /var/lib/docker 2>/dev/null || df -h /

echo "[deploy] Pulling ${ECR_URI}:${IMAGE_TAG} ..."
docker pull "${ECR_URI}:${IMAGE_TAG}"

# CloudWatch Logs (Docker awslogs driver). Requires EC2 role policy — see backend/deploy/iam-ec2-cloudwatch-logs.json
DOCKER_LOG_ARGS=()
if [ "${ENABLE_CLOUDWATCH_LOGS:-true}" = "true" ]; then
  CW_GROUP="${CLOUDWATCH_LOG_GROUP:-/yorigo/backend}"
  CW_STREAM="${CLOUDWATCH_LOG_STREAM:-yorigo-backend}"
  DOCKER_LOG_ARGS=(
    --log-driver=awslogs
    --log-opt "awslogs-region=${AWS_REGION}"
    --log-opt "awslogs-group=${CW_GROUP}"
    --log-opt "awslogs-stream=${CW_STREAM}"
    --log-opt awslogs-create-group=true
  )
  echo "[deploy] CloudWatch Logs enabled: group=${CW_GROUP} stream=${CW_STREAM}"
else
  echo "[deploy] CloudWatch Logs disabled (ENABLE_CLOUDWATCH_LOGS=false)"
fi

docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
  -p 8000:8000 --env-file "$RUNTIME_ENV" \
  "${DOCKER_LOG_ARGS[@]}" \
  "${ECR_URI}:${IMAGE_TAG}"

echo "[deploy] Done: ${ECR_URI}:${IMAGE_TAG}"
docker ps --filter "name=${CONTAINER_NAME}"
