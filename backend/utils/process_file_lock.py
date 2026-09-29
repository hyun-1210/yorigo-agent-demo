"""프로세스/워커 간 전용 파일 락 (Windows PID + Unix fcntl).

uvicorn 멀티워커에서 스케줄러/백그라운드 루프가 1개만 기동되도록 쓴다.
"""

from __future__ import annotations

import logging
import os
import sys
import tempfile
from typing import Optional, TextIO, Tuple

logger = logging.getLogger(__name__)


def try_acquire_process_file_lock(
    lock_name: str,
    *,
    lock_path: Optional[str] = None,
    log_prefix: str = "process_file_lock",
) -> Tuple[bool, Optional[TextIO]]:
    """논블로킹 파일 락을 잡는다.

    Args:
        lock_name: tempfile 아래 쓸 파일명 (예: yorigo_product_health_check.lock)
        lock_path: 절대 경로를 직접 지정할 때 (테스트용)
        log_prefix: 실패 로그 prefix

    Returns:
        (acquired, lock_file_handle). handle는 프로세스 종료까지 열어 둔다.
    """
    path = lock_path or os.path.join(tempfile.gettempdir(), lock_name)
    lock_file: Optional[TextIO] = None
    try:
        if sys.platform == "win32":
            try:
                lock_file = open(path, "x", encoding="utf-8")
            except FileExistsError:
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        old_pid = int((f.read() or "0").strip() or "0")
                    if old_pid > 0:
                        try:
                            os.kill(old_pid, 0)
                            return False, None
                        except (OSError, ProcessLookupError):
                            os.remove(path)
                            lock_file = open(path, "x", encoding="utf-8")
                    else:
                        return False, None
                except Exception:
                    return False, None
        else:
            import fcntl

            lock_file = open(path, "w", encoding="utf-8")
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, BlockingIOError):
                lock_file.close()
                return False, None

        assert lock_file is not None
        lock_file.write(str(os.getpid()))
        lock_file.flush()
        return True, lock_file
    except Exception as e:
        logger.warning("[%s] lock failed path=%s: %s", log_prefix, path, e)
        if lock_file:
            try:
                lock_file.close()
            except Exception:
                pass
        return False, None
