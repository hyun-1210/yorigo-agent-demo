#!/usr/bin/env bash
# Run Flutter on iOS device/simulator with local dart-define keys (Android parity).
# Usage:
#   ./tool/run_ios_with_keys.sh
#   ./tool/run_ios_with_keys.sh -d <device-id>

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
exec bash tool/flutter_with_local_keys.sh run -d ios "$@"
