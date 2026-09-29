#!/usr/bin/env bash
# TestFlight / App Store: release IPA with dart_defines.json embedded.
# Includes USE_MACMINI_PARSING=true → parse.yorigo.kr (Mac mini), Railway/AWS fallback.
# Xcode에서 바로 Archive만 할 경우 dart-define 이 빠져 Kakao 초기화 등이 깨질 수 있음.
#
# 실행: 프로젝트 루트가 아니라 yorigo-frontend 에서 실행하거나 본 스크립트 그대로 호출.
#   ./tool/build_ipa_release_dart_defines.sh
#
# 참고 명령(동일 결과):
#   flutter build ipa --release --dart-define-from-file=dart_defines.json
#
# 존재하지 않는 명령: flutter ios build  (❌ → flutter build ios / flutter build ipa)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

DEFINES="${ROOT}/dart_defines.json"
if [[ ! -f "${DEFINES}" ]]; then
  echo "dart_defines.json not found at: ${DEFINES}" >&2
  echo "Run from yorigo-frontend or create dart_defines.json there." >&2
  exit 1
fi

exec flutter build ipa --release --dart-define-from-file="${DEFINES}" "$@"
