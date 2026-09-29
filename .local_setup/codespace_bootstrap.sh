#!/usr/bin/env bash
set -euo pipefail

QUIET=0
if [[ "${1:-}" == "--quiet" ]]; then
  QUIET=1
fi

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "[yorigo-setup] $*"
  fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$REPO_ROOT/backend"
FRONTEND_DIR="$REPO_ROOT/yorigo-frontend"

PY_REQ="$BACKEND_DIR/requirements.txt"
PY_VENV="$BACKEND_DIR/.venv"
PY_STAMP="$PY_VENV/.requirements.sha256"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[yorigo-setup] python3 is not available in this environment." >&2
  exit 1
fi

if [[ ! -d "$PY_VENV" ]]; then
  log "Creating Python virtual environment at backend/.venv"
  python3 -m venv "$PY_VENV"
fi

REQ_HASH="$(sha256sum "$PY_REQ" | awk '{print $1}')"
CUR_REQ_HASH=""
if [[ -f "$PY_STAMP" ]]; then
  CUR_REQ_HASH="$(cat "$PY_STAMP")"
fi

if [[ "$REQ_HASH" != "$CUR_REQ_HASH" ]]; then
  log "Installing backend Python dependencies"
  "$PY_VENV/bin/python" -m pip install --upgrade pip
  "$PY_VENV/bin/pip" install -r "$PY_REQ"
  printf "%s" "$REQ_HASH" > "$PY_STAMP"
else
  log "Backend Python dependencies are up to date"
fi

FLUTTER_HOME="$HOME/.local/flutter"
if [[ ! -x "$FLUTTER_HOME/bin/flutter" ]]; then
  log "Installing Flutter SDK (stable) to $FLUTTER_HOME"
  mkdir -p "$HOME/.local"
  git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_HOME"
fi

export PATH="$FLUTTER_HOME/bin:$PATH"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[yorigo-setup] Flutter command is unavailable after install." >&2
  exit 1
fi

flutter config --no-analytics >/dev/null 2>&1 || true

PUBSPEC_FILE="$FRONTEND_DIR/pubspec.yaml"
PUBSPEC_HASH="$(sha256sum "$PUBSPEC_FILE" | awk '{print $1}')"
PUBSPEC_STAMP="$FRONTEND_DIR/.dart_tool/.pubspec.sha256"
CUR_PUBSPEC_HASH=""
if [[ -f "$PUBSPEC_STAMP" ]]; then
  CUR_PUBSPEC_HASH="$(cat "$PUBSPEC_STAMP")"
fi

if [[ "$PUBSPEC_HASH" != "$CUR_PUBSPEC_HASH" ]]; then
  log "Installing frontend Flutter dependencies (flutter pub get)"
  (
    cd "$FRONTEND_DIR"
    flutter pub get
  )
  mkdir -p "$FRONTEND_DIR/.dart_tool"
  printf "%s" "$PUBSPEC_HASH" > "$PUBSPEC_STAMP"
else
  log "Frontend Flutter dependencies are up to date"
fi

log "Bootstrap complete."
