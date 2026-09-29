"""상세 레시피 도우미 QA 러너. LLM/앱 없이 가드·라우터만 돈다.

사용:
  backend/.venv/bin/python scripts/qa_recipe_agent.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]


def main() -> int:
    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "-q",
        "tests/test_recipe_agent_guards.py",
        "tests/test_recipe_agent_turn.py",
        "tests/test_recipe_agent_router.py",
        "tests/test_agent_flags.py",
    ]
    print("[qa] recipe helper contract + router")
    print(" ".join(cmd))
    result = subprocess.run(cmd, cwd=str(BACKEND), check=False)
    print()
    if result.returncode == 0:
        print("[qa] recipe helper OK")
        print("앱 QA: flutter run --dart-define=RECIPE_AGENT_ENABLED=true")
        print("서버 QA: RECIPE_AGENT_ENABLED=true 후 backend.py 재시작")
        print("홈 검색 도우미는 아직 꺼져 있음 (HOME_AGENT_ENABLED)")
    else:
        print("[qa] recipe helper FAILED")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
