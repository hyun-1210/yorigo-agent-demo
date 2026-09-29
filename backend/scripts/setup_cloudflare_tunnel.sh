#!/usr/bin/env bash
# Cloudflare Tunnel 초기 설정 (맥미니 파싱 워커)
set -euo pipefail

HOSTNAME="${1:-parse.yorigo.kr}"
TUNNEL_NAME="${2:-yorigo-parse}"
CF_BIN="${CLOUDFLARED_BIN:-$HOME/bin/cloudflared}"
CONFIG_DIR="$HOME/.cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"

if [[ ! -x "$CF_BIN" ]]; then
  echo "[tunnel] cloudflared 없음. 먼저 설치:" >&2
  echo "  mkdir -p ~/bin && curl -fsSL -o /tmp/cloudflared.tgz https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz" >&2
  echo "  tar -xzf /tmp/cloudflared.tgz -C ~/bin && chmod +x ~/bin/cloudflared" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"

echo "[tunnel] Cloudflare 로그인 (브라우저 열림)"
"$CF_BIN" tunnel login

echo "[tunnel] Tunnel 생성: $TUNNEL_NAME"
"$CF_BIN" tunnel create "$TUNNEL_NAME" || true

CRED_FILE="$(ls -1 "$CONFIG_DIR"/*.json 2>/dev/null | head -1 || true)"
if [[ -z "$CRED_FILE" ]]; then
  echo "[tunnel] credentials JSON을 찾을 수 없습니다." >&2
  exit 1
fi

cat > "$CONFIG_FILE" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:8000
  - service: http_status:404
EOF

echo "[tunnel] DNS 라우트 등록: $HOSTNAME"
"$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"

echo "[tunnel] 설정 완료: $CONFIG_FILE"
echo "[tunnel] 실행: $CF_BIN tunnel run $TUNNEL_NAME"
echo "[tunnel] 또는 launchd: backend/deploy/macmini/com.yorigo.cloudflared.plist 참고"
