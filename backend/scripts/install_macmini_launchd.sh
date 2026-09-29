#!/usr/bin/env bash
# launchd 서비스 등록 (맥미니 파싱 워커 + cloudflared)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_DIR="$BACKEND_DIR/deploy/macmini"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

mkdir -p "$LAUNCH_AGENTS" "$HOME/Library/Logs"

install_plist() {
  local name="$1"
  local src="$DEPLOY_DIR/$name"
  local dest="$LAUNCH_AGENTS/$name"
  if [[ ! -f "$src" ]]; then
    echo "[launchd] plist 없음: $src" >&2
    exit 1
  fi
  local label="${name%.plist}"
  cp "$src" "$dest"
  echo "[launchd] 설치: $dest"
  # launchctl 서비스 타깃은 파일명(.plist)이 아니라 plist의 Label을 써야 한다.
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dest"
  launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
  echo "[launchd] 시작: $label"
}

bash "$BACKEND_DIR/scripts/check_macmini_ready.sh"

install_plist "com.yorigo.parse-worker.plist"

if [[ -x "$HOME/bin/cloudflared" && -f "$HOME/.cloudflared/config.yml" ]]; then
  install_plist "com.yorigo.cloudflared.plist"
else
  echo "[launchd] cloudflared 미설정 — tunnel 설정 후 com.yorigo.cloudflared.plist 수동 등록"
fi

echo "[launchd] 완료. 로그: ~/Library/Logs/yorigo-*.log"
