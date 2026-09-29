"""
Worker self-watchdog.

A-5: "프로세스는 살아있지만 HTTP 처리가 영구히 잠긴" zombie 워커 상태를 잡기 위한
별도 OS 스레드. asyncio 이벤트 루프와 무관하게 동작하므로, 루프가 stuck이어도
이 스레드는 살아있고 결정을 내릴 수 있다.

동작 원리:
  - HTTP 핸들러·백그라운드 async parse 등 진입 시 `mark_request_started()` /
    `mark_background_job_started()` 호출 → in-flight 카운터 +1, 시작 시각 기록.
  - 완료(성공/타임아웃 무관) 시 `mark_request_completed(started_at)` /
    `mark_background_job_completed(started_at)` 호출 → in-flight -1,
    해당 요청의 시작 시각 기록 제거 + 마지막 완료 시각 갱신(디버그용).
  - 별도 스레드가 주기적으로 점검:
      * in_flight == 0  →  단지 idle, 자살 안 함 (false positive 방지)
      * 지금 열려 있는 in-flight 요청 중 "가장 오래된 것의 나이" > STUCK_THRESHOLD
        →  자살.
    (예전엔 "마지막 완료 이후 경과 시간"으로 판단했는데, 트래픽이 뜸했다가
    막 새 요청이 하나 들어온 순간에도 last_completed가 오래 전이라는 이유만으로
    즉시 STUCK 오탐이 발생하는 버그가 있었음 — 요청별 시작 시각 추적으로 수정.)
  - 자살은 `os._exit(1)`. 부모 uvicorn 프로세스가 새 워커로 즉시 교체.

환경변수:
  ENABLE_WATCHDOG: "false"이면 비활성화 (기본 true)
  WATCHDOG_STUCK_THRESHOLD_SECONDS: 자살 임계값 (기본 300)
  WATCHDOG_CHECK_INTERVAL_SECONDS: 점검 주기 (기본 60)
"""

import logging
import os
import threading
import time
from contextlib import contextmanager
from typing import List, Optional

logger = logging.getLogger(__name__)

_state_lock = threading.Lock()
_in_flight_count: int = 0
# 현재 열려 있는 각 요청의 시작 시각(monotonic). stuck 판정은 이 목록의
# 최솟값(가장 오래된 요청의 나이)만 본다 — "마지막 완료 시각" 기반 판정은
# 트래픽 공백 후 신규 요청에서 오탐을 냈다(아래 _is_stuck 주석 참고).
_in_flight_started_at: List[float] = []
_last_completed_at: Optional[float] = None
_started_at: float = time.monotonic()
_watchdog_thread: Optional[threading.Thread] = None
_watchdog_started_lock = threading.Lock()


def mark_request_started() -> float:
    """핵심 핸들러 진입 시 호출. in-flight 카운터 증가 + 시작 시각 기록.

    반환값(시작 시각)은 반드시 `mark_request_completed()`에 그대로 넘겨야
    stuck 판정이 이 요청을 정확히 추적/해제할 수 있다."""
    global _in_flight_count
    started_at = time.monotonic()
    with _state_lock:
        _in_flight_count += 1
        _in_flight_started_at.append(started_at)
    return started_at


def mark_request_completed(started_at: Optional[float] = None) -> None:
    """핵심 핸들러 종료(성공/실패/타임아웃 무관) 시 호출.
    in-flight 카운터 감소 + 해당 요청의 시작 시각 기록 제거 + 마지막 완료 시각 갱신."""
    global _in_flight_count, _last_completed_at
    with _state_lock:
        if _in_flight_count > 0:
            _in_flight_count -= 1
        _last_completed_at = time.monotonic()
        if started_at is not None:
            try:
                _in_flight_started_at.remove(started_at)
            except ValueError:
                # mark_request_started() 없이 호출됐거나 이미 제거된 경우 — 무시.
                pass


def is_thread_exhaustion_error(exc: BaseException) -> bool:
    """OS/process thread limit hit — worker recycle is the only safe recovery."""
    msg = str(exc).lower()
    return (
        "can't start new thread" in msg
        or "cannot start new thread" in msg
        or "interpreter shutdown" in msg
    )


def fatal_worker_exit(reason: str, exc: Optional[BaseException] = None) -> None:
    """Immediate worker suicide. Uvicorn master spawns a fresh worker process."""
    try:
        snap = get_state_snapshot()
        logger.error(
            "[Watchdog] FATAL worker exit: %s in_flight=%s uptime=%.0fs — os._exit(1)",
            reason,
            snap["in_flight"],
            snap["uptime_seconds"],
            exc_info=exc,
        )
    except Exception:
        pass
    try:
        logging.shutdown()
    except Exception:
        pass
    os._exit(1)


def _install_thread_exhaustion_log_hook() -> None:
    """Catch thread exhaustion logged outside blocking_pool (OCR, yt-dlp, etc.)."""

    class _ThreadExhaustionLogHook(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            try:
                msg = record.getMessage().lower()
            except Exception:
                return
            if "can't start new thread" in msg or "cannot start new thread" in msg:
                fatal_worker_exit(f"log: {record.getMessage()[:300]}")

    hook = _ThreadExhaustionLogHook()
    hook.setLevel(logging.ERROR)
    logging.getLogger().addHandler(hook)


@contextmanager
def track_request():
    """`with track_request():` 패턴으로 mark_started/completed를 안전하게 묶음.
    예외가 나도 completed가 반드시 호출됨."""
    started_at = mark_request_started()
    try:
        yield
    finally:
        mark_request_completed(started_at)


def mark_background_job_started() -> float:
    """Background async parse job started (same in-flight counter as HTTP)."""
    return mark_request_started()


def mark_background_job_completed(started_at: Optional[float] = None) -> None:
    """Background async parse job finished."""
    mark_request_completed(started_at)


@contextmanager
def track_background_job():
    """Watchdog coverage for POST /parse_recipe_async background work."""
    started_at = mark_background_job_started()
    try:
        yield
    finally:
        mark_background_job_completed(started_at)


def get_state_snapshot() -> dict:
    """디버그/헬스 노출용 스냅샷."""
    with _state_lock:
        oldest_started = min(_in_flight_started_at) if _in_flight_started_at else None
        return {
            "in_flight": _in_flight_count,
            "last_completed_at": _last_completed_at,
            "idle_seconds": (
                (time.monotonic() - _last_completed_at)
                if _last_completed_at is not None
                else None
            ),
            "oldest_in_flight_age_seconds": (
                (time.monotonic() - oldest_started)
                if oldest_started is not None
                else None
            ),
            "uptime_seconds": time.monotonic() - _started_at,
        }


def _is_stuck(stuck_threshold_seconds: float) -> Optional[float]:
    """stuck으로 판정되면 (가장 오래된 in-flight 요청의) 나이를 반환, 아니면 None.

    핵심 조건: **지금 열려 있는 요청 중 가장 오래된 것이 threshold를 넘겨서까지
    끝나지 않음.** 트래픽이 단순히 없는 경우(in_flight == 0)는 stuck이 아님.

    (과거 버전은 "마지막 완료 시각 이후 경과 시간"으로 판정했다. 이는 서버가
    한동안 idle하다가 막 새 요청이 하나 들어온 순간 — 그 요청은 시작한 지
    1초도 안 됐는데도 — last_completed_at이 오래 전이라는 이유만으로 즉시
    STUCK 오탐을 내는 버그였다. 요청별 시작 시각을 직접 추적하는 것으로
    수정했다: 방금 시작한 요청은 나이가 0에 가까우므로 오탐이 사라지고,
    이벤트 루프가 실제로 멈춰서 요청이 안 끝나는 경우만 정확히 잡아낸다.)"""
    with _state_lock:
        if not _in_flight_started_at:
            return None  # in-flight 없음 → 단순 idle, 자살 안 함.
        oldest_started = min(_in_flight_started_at)

    age = time.monotonic() - oldest_started
    if age > stuck_threshold_seconds:
        return age
    return None


def _watchdog_loop(
    stuck_threshold_seconds: float,
    check_interval_seconds: float,
) -> None:
    while True:
        try:
            time.sleep(check_interval_seconds)
            oldest_age = _is_stuck(stuck_threshold_seconds)
            if oldest_age is not None:
                snap = get_state_snapshot()
                logger.error(
                    "[Watchdog] STUCK detected: in_flight=%s "
                    "oldest_in_flight_age=%.0fs threshold=%.0fs "
                    "uptime=%.0fs — exiting worker (os._exit 1)",
                    snap["in_flight"],
                    oldest_age,
                    stuck_threshold_seconds,
                    snap["uptime_seconds"],
                )
                try:
                    logging.shutdown()
                except Exception:
                    pass
                os._exit(1)
        except Exception as e:
            try:
                logger.exception("[Watchdog] loop error: %s", e)
            except Exception:
                pass


def start_watchdog() -> bool:
    """워커 1개당 1번만 시작. 멱등."""
    global _watchdog_thread
    if os.getenv("ENABLE_WATCHDOG", "true").lower() not in ("1", "true", "yes"):
        return False
    with _watchdog_started_lock:
        if _watchdog_thread is not None and _watchdog_thread.is_alive():
            return False
        stuck_threshold = float(
            os.getenv("WATCHDOG_STUCK_THRESHOLD_SECONDS", "510")
        )
        check_interval = float(os.getenv("WATCHDOG_CHECK_INTERVAL_SECONDS", "60"))
        _watchdog_thread = threading.Thread(
            target=_watchdog_loop,
            args=(stuck_threshold, check_interval),
            daemon=True,
            name="Watchdog",
        )
        _watchdog_thread.start()
        _install_thread_exhaustion_log_hook()
        return True
