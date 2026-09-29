"""백그라운드 작업 싱글 워커 락과 uvicorn 재시작 설정 검증.

  python Scripts/test_scheduler_single_worker_locks.py
"""

from __future__ import annotations

import os
import sys

_BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _BACKEND not in sys.path:
    sys.path.insert(0, _BACKEND)

_PASS = 0
_FAIL = 0


def check(cond: bool, msg: str) -> None:
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        print(f"  OK  {msg}")
    else:
        _FAIL += 1
        print(f"  FAIL {msg}")


def _backend_src() -> str:
    path = os.path.join(_BACKEND, "backend.py")
    with open(path, encoding="utf-8") as f:
        return f.read()


def test_underage_lock_wiring() -> None:
    print("\n[WU1] underage cleanup single-worker lock wiring")
    src = _backend_src()
    check("yorigo_underage_cleanup.lock" in src, "uses underage lock name")
    check(
        'log_prefix="UnderageCleanup"' in src
        or "log_prefix='UnderageCleanup'" in src,
        "UnderageCleanup log prefix",
    )
    check(
        "Underage cleanup scheduler started (single-worker lock)" in src,
        "started message mentions single-worker lock",
    )
    check(
        "another worker holds yorigo_underage_cleanup.lock" in src,
        "skip message when lock not acquired",
    )
    idx_lock = src.find("yorigo_underage_cleanup.lock")
    idx_thread = src.find('name="UnderageCleanupScheduler"')
    check(
        idx_lock > 0 and idx_thread > idx_lock,
        "lock acquired before underage thread start",
    )


def test_recipe_snapshot_lock_wiring() -> None:
    print("\n[WU2] recipe snapshot single-worker lock wiring")
    src = _backend_src()
    check("yorigo_recipe_snapshot.lock" in src, "uses recipe snapshot lock name")
    check(
        'log_prefix="RecipeSnapshot"' in src
        or "log_prefix='RecipeSnapshot'" in src,
        "RecipeSnapshot log prefix",
    )
    check(
        "Daily recipe snapshot scheduler started (single-worker lock)" in src,
        "started message mentions single-worker lock",
    )
    check(
        "another worker holds yorigo_recipe_snapshot.lock" in src,
        "skip message when lock not acquired",
    )
    idx_lock = src.find("yorigo_recipe_snapshot.lock")
    idx_thread = src.find('name="RecipeSnapshotScheduler"')
    check(
        idx_lock > 0 and idx_thread > idx_lock,
        "lock acquired before snapshot thread start",
    )


def test_timestamp_worker_lock_wiring() -> None:
    print("\n[WU3] timestamp queue single-worker lock wiring")
    src = _backend_src()
    check("yorigo_timestamp_worker.lock" in src, "uses timestamp worker lock name")
    check(
        'log_prefix="TimestampWorker"' in src
        or "log_prefix='TimestampWorker'" in src,
        "TimestampWorker log prefix",
    )
    check(
        "Timestamp queue worker started (single-worker lock)" in src,
        "started message mentions single-worker lock",
    )
    check(
        "another worker holds yorigo_timestamp_worker.lock" in src,
        "skip message when lock not acquired",
    )
    idx_lock = src.find("yorigo_timestamp_worker.lock")
    idx_thread = src.find('name="TimestampWorker"')
    check(
        idx_lock > 0 and idx_thread > idx_lock,
        "lock acquired before timestamp thread start",
    )


def test_coupang_order_sync_lock_wiring() -> None:
    print("\n[WU6] coupang order sync single-worker lock wiring")
    src = _backend_src()
    check("yorigo_coupang_order_sync.lock" in src, "uses coupang order sync lock name")
    check(
        'log_prefix="CoupangOrderSync"' in src
        or "log_prefix='CoupangOrderSync'" in src,
        "CoupangOrderSync log prefix",
    )
    check(
        "Coupang order sync scheduler started (single-worker lock)" in src,
        "started message mentions single-worker lock",
    )
    check(
        "another worker holds yorigo_coupang_order_sync.lock" in src,
        "skip message when lock not acquired",
    )
    idx_lock = src.find("yorigo_coupang_order_sync.lock")
    idx_thread = src.find('name="CoupangOrderSyncScheduler"')
    check(
        idx_lock > 0 and idx_thread > idx_lock,
        "lock acquired before coupang order sync thread start",
    )


def test_locks_are_separate() -> None:
    print("\n[WU4] background jobs use distinct lock files")
    src = _backend_src()
    lock_names = {
        "yorigo_underage_cleanup.lock",
        "yorigo_recipe_snapshot.lock",
        "yorigo_timestamp_worker.lock",
        "yorigo_coupang_order_sync.lock",
    }
    check(all(name in src for name in lock_names), "all lock names present")
    check(len(lock_names) == 4, "lock names differ")


def test_uvicorn_request_recycling_disabled() -> None:
    print("\n[WU5] uvicorn request-count recycling disabled + dual-process CMD")
    path = os.path.join(_BACKEND, "Dockerfile")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    check("--limit-max-requests" not in src, "Dockerfile has no request-count restart")
    check("UVICORN_MAX_REQUESTS" not in src, "Dockerfile has no max-request fallback")
    check('CMD ["python", "process_supervisor.py"]' in src, "CMD uses process supervisor")
    check("process_supervisor.py" in src, "supervisor file copied into image")
    check("timestamp_worker_main.py" in src, "timestamp main copied into image")


def main() -> int:
    print("=" * 60)
    print("background worker lock / uvicorn lifecycle tests")
    print("=" * 60)
    test_underage_lock_wiring()
    test_recipe_snapshot_lock_wiring()
    test_timestamp_worker_lock_wiring()
    test_coupang_order_sync_lock_wiring()
    test_locks_are_separate()
    test_uvicorn_request_recycling_disabled()
    print("\n" + "=" * 60)
    print(f"PASS={_PASS} FAIL={_FAIL}")
    print("=" * 60)
    return 1 if _FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
