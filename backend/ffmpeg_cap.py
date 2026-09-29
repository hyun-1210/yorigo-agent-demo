"""
Global concurrency cap for ffmpeg subprocess invocations.

Limits simultaneous ffmpeg *processes* (heavy CPU/RAM) separately from the
Python blocking thread pool. Extra callers block on a semaphore — no extra
threads or subprocesses are spawned while waiting.
"""

from __future__ import annotations

import logging
import os
import subprocess
import threading
import time
from typing import Any, Sequence

logger = logging.getLogger(__name__)

_semaphore: threading.Semaphore | None = None
_semaphore_lock = threading.Lock()


def ffmpeg_max_concurrent() -> int:
    return max(1, int(os.getenv("FFMPEG_MAX_CONCURRENT", "1")))


def _get_semaphore() -> threading.Semaphore:
    global _semaphore
    with _semaphore_lock:
        if _semaphore is None:
            _semaphore = threading.Semaphore(ffmpeg_max_concurrent())
        return _semaphore


def _ffmpeg_threads_flag() -> list[str]:
    raw = (os.getenv("FFMPEG_THREADS") or "1").strip().lower()
    if raw in ("", "0", "auto", "none"):
        return []
    return ["-threads", raw]


def inject_ffmpeg_threads(cmd: Sequence[str]) -> list[str]:
    """Insert ``-threads N`` after the ffmpeg binary when not already present."""
    parts = list(cmd)
    if not parts or "-threads" in parts:
        return parts
    flags = _ffmpeg_threads_flag()
    if not flags:
        return parts
    return [parts[0], *flags, *parts[1:]]


def _stderr_text(stderr: Any) -> str:
    if not stderr:
        return ""
    if isinstance(stderr, bytes):
        return stderr.decode("utf-8", errors="replace")
    return str(stderr)


def is_ffmpeg_eagain(stderr: Any) -> bool:
    lower = _stderr_text(stderr).lower()
    return "resource temporarily unavailable" in lower


def run_ffmpeg(*popenargs: Any, **kwargs: Any) -> subprocess.CompletedProcess[Any]:
    """subprocess.run wrapper — global ffmpeg slot, ``-threads`` cap, EAGAIN retry."""
    max_retries = max(1, int(os.getenv("FFMPEG_EAGAIN_RETRIES", "3")))
    base_backoff = float(os.getenv("FFMPEG_EAGAIN_BACKOFF_SEC", "3"))
    check = bool(kwargs.get("check", False))

    args = list(popenargs)
    if args and isinstance(args[0], (list, tuple)):
        args[0] = inject_ffmpeg_threads(list(args[0]))

    last_error: subprocess.CalledProcessError | None = None
    for attempt in range(1, max_retries + 1):
        sem = _get_semaphore()
        t0 = time.monotonic()
        sem.acquire()
        waited = time.monotonic() - t0
        if waited >= 1.0:
            logger.info(
                "[FFmpegCap] slot acquired after %.1fs wait (max=%s)",
                waited,
                ffmpeg_max_concurrent(),
            )
        try:
            run_kwargs = dict(kwargs)
            run_kwargs["check"] = False
            result = subprocess.run(*args, **run_kwargs)
            if result.returncode != 0:
                err = subprocess.CalledProcessError(
                    result.returncode,
                    args[0] if args else None,
                    result.stdout,
                    result.stderr,
                )
                if is_ffmpeg_eagain(result.stderr) and attempt < max_retries:
                    delay = base_backoff * attempt
                    logger.warning(
                        "[FFmpegCap] EAGAIN on attempt %d/%d — retry in %.1fs",
                        attempt,
                        max_retries,
                        delay,
                    )
                    last_error = err
                    time.sleep(delay)
                    continue
                if check:
                    raise err
            return result
        finally:
            sem.release()

    if last_error is not None:
        if check:
            raise last_error
        return subprocess.CompletedProcess(
            args=args[0] if args else [],
            returncode=last_error.returncode,
            stdout=last_error.stdout,
            stderr=last_error.stderr,
        )
    raise RuntimeError("run_ffmpeg: exhausted retries without result")
