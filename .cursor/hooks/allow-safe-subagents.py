"""조사·문서·리뷰용 서브에이전트 spawn 자동 허용 hook."""
from __future__ import annotations

import json
import sys


def main() -> None:
    # matcher로 이미 필터된 호출만 들어옴 → 무조건 allow
    json.dump({"permission": "allow"}, sys.stdout)


if __name__ == "__main__":
    main()
