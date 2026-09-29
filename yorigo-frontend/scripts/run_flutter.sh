#!/usr/bin/env bash
# 프론트 루트(yorigo-frontend) 기준: 상위에 dart_defines.json 이 있으면 자동으로 함께 전달
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFINES="${ROOT}/dart_defines.json"

has_arg() {
  local needle="$1"
  shift
  for arg in "$@"; do
    [[ "${arg}" == "${needle}" ]] && return 0
  done
  return 1
}

supports_dart_defines() {
  [[ "$#" -gt 0 ]] || return 1
  case "$1" in
    run|build|test|drive) return 0 ;;
    *) return 1 ;;
  esac
}

run_instagram_cropped_backfill() {
  if [[ "${SKIP_INSTAGRAM_CROPPED_BACKFILL:-}" == "true" ]]; then
    echo "[run_flutter] SKIP_INSTAGRAM_CROPPED_BACKFILL=true, Instagram cropped thumbnail backfill skipped."
    return 0
  fi

  local script="${ROOT}/../backend/tools/backfill_instagram_thumbnail_cropped.py"
  if [[ ! -f "${script}" ]]; then
    echo "[run_flutter] Instagram cropped thumbnail backfill script not found: ${script}" >&2
    return 1
  fi

  local args=("${script}")
  if [[ -n "${INSTAGRAM_CROPPED_BACKFILL_LIMIT:-}" ]]; then
    args+=("--limit" "${INSTAGRAM_CROPPED_BACKFILL_LIMIT}")
  fi
  if [[ "${INSTAGRAM_CROPPED_BACKFILL_FORCE:-}" == "true" ]]; then
    args+=("--force")
  fi

  echo "[run_flutter] Running Instagram cropped thumbnail backfill..."
  if command -v python3 >/dev/null 2>&1; then
    python3 "${args[@]}"
  else
    python "${args[@]}"
  fi
}

if [[ -f "${DEFINES}" ]] && supports_dart_defines "$@"; then
  flutter "$@" --dart-define-from-file="${DEFINES}"
else
  flutter "$@"
fi

if has_arg "build" "$@" && has_arg "appbundle" "$@" &&
  { has_arg "--release" "$@" || { ! has_arg "--debug" "$@" && ! has_arg "--profile" "$@"; }; }; then
  run_instagram_cropped_backfill
fi
