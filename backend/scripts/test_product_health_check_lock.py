"""WU2: Product health check 싱글 워커 파일 락 검증.

  python Scripts/test_product_health_check_lock.py
"""

from __future__ import annotations

import os
import sys
import tempfile

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


def test_lock_exclusive() -> None:
    print("\n[WU2-a] process file lock is exclusive")
    from utils.process_file_lock import try_acquire_process_file_lock

    path = os.path.join(
        tempfile.gettempdir(), f"yorigo_product_health_check_test_{os.getpid()}.lock"
    )
    if os.path.exists(path):
        try:
            os.remove(path)
        except OSError:
            pass

    try:
        ok1, fh1 = try_acquire_process_file_lock(
            "unused", lock_path=path, log_prefix="test"
        )
        check(ok1 is True, "first acquire succeeds")
        check(fh1 is not None, "first handle open")

        ok2, fh2 = try_acquire_process_file_lock(
            "unused", lock_path=path, log_prefix="test"
        )
        check(ok2 is False, "second acquire fails while held")
        check(fh2 is None, "second handle is None")

        if fh1:
            fh1.close()
        # Windows: PID 파일이 남아 있으면 같은 PID라 여전히 실패할 수 있음
        if sys.platform == "win32" and os.path.exists(path):
            os.remove(path)

        ok3, fh3 = try_acquire_process_file_lock(
            "unused", lock_path=path, log_prefix="test"
        )
        check(ok3 is True, "re-acquire after release succeeds")
        if fh3:
            fh3.close()
            if sys.platform == "win32" and os.path.exists(path):
                os.remove(path)
    finally:
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass


def test_backend_wiring() -> None:
    print("\n[WU2-b] backend.py wires health check lock")
    path = os.path.join(_BACKEND, "backend.py")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    check("try_acquire_process_file_lock" in src, "imports process file lock")
    check(
        "yorigo_product_health_check.lock" in src,
        "uses health check lock name",
    )
    check(
        "another worker holds yorigo_product_health_check.lock" in src,
        "logs skip when lock not acquired",
    )
    check(
        "single-worker lock" in src,
        "startup message mentions single-worker lock",
    )
    # 락 성공 후에만 스레드 기동되는지: lock 호출이 health check 블록 안에 있음
    idx_lock = src.find("yorigo_product_health_check.lock")
    idx_thread = src.find('name="ProductHealthCheckScheduler"')
    check(idx_lock > 0 and idx_thread > idx_lock, "lock acquired before thread start")


def test_util_module_importable() -> None:
    print("\n[WU2-c] util module importable")
    from utils.process_file_lock import try_acquire_process_file_lock

    check(callable(try_acquire_process_file_lock), "function callable")


def main() -> int:
    print("=" * 60)
    print("product health check lock (WU2) tests")
    print("=" * 60)
    test_util_module_importable()
    test_lock_exclusive()
    test_backend_wiring()
    print("\n" + "=" * 60)
    print(f"PASS={_PASS} FAIL={_FAIL}")
    print("=" * 60)
    return 1 if _FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
