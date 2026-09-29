#!/usr/bin/env python3
"""Watchdog stuck 판정 단위 테스트 (네트워크 불필요).

트래픽 공백 후 신규 요청이 들어와도 STUCK 오탐이 나지 않고,
실제로 threshold를 넘긴 in-flight 요청만 잡는지 검증한다.

Usage:
  cd backend
  python Scripts/test_watchdog_stuck_detection.py
"""

from __future__ import annotations

import io
import os
import sys
import time
from typing import List, Tuple

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

_HERE = os.path.dirname(os.path.abspath(__file__))
_BACKEND = os.path.dirname(_HERE)
if _BACKEND not in sys.path:
    sys.path.insert(0, _BACKEND)

import watchdog as wd  # noqa: E402

GREEN = "\033[92m"
RED = "\033[91m"
RESET = "\033[0m"
_results: List[Tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    tag = f"{GREEN}PASS{RESET}" if cond else f"{RED}FAIL{RESET}"
    print(f"  [{tag}] {msg}")
    _results.append((cond, msg))


def _reset_state() -> None:
    with wd._state_lock:
        wd._in_flight_count = 0
        wd._in_flight_started_at.clear()
        wd._last_completed_at = None
        wd._started_at = time.monotonic()


def test_idle_not_stuck() -> None:
    print("\n[1] idle (in_flight=0) 은 stuck 아님")
    _reset_state()
    check(wd._is_stuck(510) is None, "in_flight=0 → None")


def test_fresh_request_after_long_idle_not_stuck() -> None:
    """과거 버그: last_completed가 오래 전인데 in_flight>0이면 즉시 STUCK.

    수정 후: 방금 시작한 요청의 나이는 ~0이므로 threshold 미만."""
    print("\n[2] 긴 idle 후 신규 요청은 stuck 아님 (오탐 회귀)")
    _reset_state()
    # 마지막 완료가 600초 전인 것처럼 설정 (과거 판정 기준이었다면 오탐)
    with wd._state_lock:
        wd._last_completed_at = time.monotonic() - 600.0

    started = wd.mark_request_started()
    age = wd._is_stuck(510)
    check(age is None, f"신규 요청 age~0 -> not stuck (got {age!r})")
    snap = wd.get_state_snapshot()
    oldest = snap.get("oldest_in_flight_age_seconds")
    check(
        oldest is not None and oldest < 5.0,
        f"oldest_in_flight_age_seconds < 5 (got {oldest!r})",
    )
    wd.mark_request_completed(started)
    check(wd._is_stuck(510) is None, "완료 후 in_flight=0 → not stuck")


def test_old_in_flight_is_stuck() -> None:
    print("\n[3] threshold를 넘긴 in-flight는 stuck")
    _reset_state()
    old_started = time.monotonic() - 520.0
    with wd._state_lock:
        wd._in_flight_count = 1
        wd._in_flight_started_at[:] = [old_started]

    age = wd._is_stuck(510)
    check(age is not None and age > 510, f"age>510 stuck (got {age!r})")
    wd.mark_request_completed(old_started)
    check(wd._is_stuck(510) is None, "오래된 요청 완료 후 not stuck")


def test_track_request_token_cleanup() -> None:
    print("\n[4] track_request 가 시작 토큰을 정리함")
    _reset_state()
    with wd.track_request():
        check(wd.get_state_snapshot()["in_flight"] == 1, "enter → in_flight=1")
        check(len(wd._in_flight_started_at) == 1, "started_at 1개 기록")
    check(wd.get_state_snapshot()["in_flight"] == 0, "exit → in_flight=0")
    check(len(wd._in_flight_started_at) == 0, "started_at 목록 비움")


def test_oldest_of_multiple_in_flight() -> None:
    print("\n[5] 여러 in-flight 중 가장 오래된 것 기준")
    _reset_state()
    old = time.monotonic() - 600.0
    fresh = time.monotonic()
    with wd._state_lock:
        wd._in_flight_count = 2
        wd._in_flight_started_at[:] = [old, fresh]

    age = wd._is_stuck(510)
    check(age is not None and age > 510, f"old+fresh → stuck by oldest (got {age!r})")

    wd.mark_request_completed(old)
    check(wd.get_state_snapshot()["in_flight"] == 1, "오래된 요청만 완료 → in_flight=1")
    check(wd._is_stuck(510) is None, "남은 fresh만 → not stuck")
    wd.mark_request_completed(fresh)


def main() -> int:
    print("=== watchdog stuck detection ===")
    test_idle_not_stuck()
    test_fresh_request_after_long_idle_not_stuck()
    test_old_in_flight_is_stuck()
    test_track_request_token_cleanup()
    test_oldest_of_multiple_in_flight()

    failed = [m for ok, m in _results if not ok]
    print(f"\n{len(_results) - len(failed)}/{len(_results)} passed")
    if failed:
        print("FAILED:")
        for m in failed:
            print(f"  - {m}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
