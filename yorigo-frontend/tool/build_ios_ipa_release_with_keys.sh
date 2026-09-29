#!/usr/bin/env bash
# Bash 3.2+ (macOS default): do not use mapfile (Bash 4+ only).

set -euo pipefail

# Build iOS IPA (release) with local dart-define keys.
# Run this script on macOS only.
# 1) cp dart_define.local.json.example dart_define.local.json
# 2) Fill in keys (valid JSON object — cannot be an empty file).

cd "$(dirname "$0")/.."
if [ ! -f "dart_define.local.json" ]; then
  echo "Missing dart_define.local.json in yorigo-frontend root."
  echo "Copy: cp dart_define.local.json.example dart_define.local.json"
  exit 1
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "python3/python not found. Install Python to parse dart_define.local.json."
  exit 1
fi

DEFINE_ARGS=()
while IFS= read -r line || [ -n "${line-}" ]; do
  [ -z "${line}" ] && continue
  DEFINE_ARGS+=("$line")
done < <("$PYTHON_BIN" - <<'PY'
import json
import sys
from pathlib import Path

path = Path("dart_define.local.json")
raw = path.read_text(encoding="utf-8").strip()
if not raw:
    print(
        "dart_define.local.json is empty. Use dart_define.local.json.example as a template.",
        file=sys.stderr,
    )
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"Invalid JSON in dart_define.local.json: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict) or not data:
    print("dart_define.local.json must be a non-empty JSON object { \"KEY\": \"value\" }.", file=sys.stderr)
    sys.exit(1)

for k, v in data.items():
    if v is None:
        v = ""
    print(f"--dart-define={k}={v}")
PY
)

if [ "${#DEFINE_ARGS[@]}" -eq 0 ]; then
  echo "No --dart-define arguments were generated."
  exit 1
fi

flutter build ipa --release "${DEFINE_ARGS[@]}" "$@"
