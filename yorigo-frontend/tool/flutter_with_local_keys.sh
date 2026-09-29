#!/usr/bin/env bash
# Runs flutter with local dart-define secrets (Mac/Linux parity with flutter_with_local_keys.ps1).
# Usage:
#   ./tool/flutter_with_local_keys.sh run -d ios
#   ./tool/flutter_with_local_keys.sh build ipa --release

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

DEFINE_FILE="dart_define.local.json"
if [[ ! -f "${DEFINE_FILE}" ]]; then
  echo "Missing ${DEFINE_FILE}. Copy dart_define.local.json.example and fill real keys." >&2
  exit 1
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "python3/python not found. Install Python to parse ${DEFINE_FILE}." >&2
  exit 1
fi

DEFINE_ARGS=()
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] && continue
  DEFINE_ARGS+=("${line}")
done < <("${PYTHON_BIN}" - <<'PY'
import json
import sys
from pathlib import Path

path = Path("dart_define.local.json")
raw = path.read_text(encoding="utf-8").strip()
if not raw:
    print("dart_define.local.json is empty.", file=sys.stderr)
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"Invalid JSON in dart_define.local.json: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict) or not data:
    print("dart_define.local.json must be a non-empty JSON object.", file=sys.stderr)
    sys.exit(1)

for k, v in data.items():
    if v is None:
        v = ""
    print(f"--dart-define={k}={v}")
PY
)

if [[ "${#DEFINE_ARGS[@]}" -eq 0 ]]; then
  echo "No --dart-define arguments were generated." >&2
  exit 1
fi

flutter "$@" "${DEFINE_ARGS[@]}"
