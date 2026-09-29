"""
Shared bounded thread pool for blocking I/O (Firestore sync, product lookup, parse deadline).

One pool per uvicorn worker process. Extra work queues instead of spawning unbounded threads.
"""

from __future__ import annotations

import asyncio
import os
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any, Callable, NoReturn, Optional, TypeVar

T = TypeVar("T")

_pool: Optional[ThreadPoolExecutor] = None
_pool_lock = threading.Lock()


def blocking_pool_workers() -> int:
    return max(1, int(os.getenv("BLOCKING_POOL_WORKERS", "20")))


def get_blocking_pool() -> ThreadPoolExecutor:
    global _pool
    with _pool_lock:
        if _pool is None:
            _pool = ThreadPoolExecutor(
                max_workers=blocking_pool_workers(),
                thread_name_prefix="blocking",
            )
        return _pool


def _fatal_on_thread_exhaustion(exc: BaseException) -> NoReturn:
    from watchdog import fatal_worker_exit, is_thread_exhaustion_error

    if is_thread_exhaustion_error(exc):
        fatal_worker_exit("blocking_pool submit thread exhaustion", exc=exc)
    raise exc


def submit_blocking(func: Callable[..., T], *args: Any, **kwargs: Any) -> Future[T]:
    pool = get_blocking_pool()
    try:
        if kwargs:
            return pool.submit(lambda: func(*args, **kwargs))
        return pool.submit(func, *args)
    except RuntimeError as e:
        _fatal_on_thread_exhaustion(e)
    except Exception as e:
        _fatal_on_thread_exhaustion(e)


def try_submit_blocking(func: Callable[..., T], *args: Any, **kwargs: Any) -> Future[T]:
    """Like submit_blocking; thread exhaustion triggers immediate worker exit."""
    return submit_blocking(func, *args, **kwargs)


def run_blocking_with_timeout(
    timeout_seconds: float,
    func: Callable[..., T],
    *args: Any,
    **kwargs: Any,
) -> T:
    fut = submit_blocking(func, *args, **kwargs)
    return fut.result(timeout=timeout_seconds)


async def run_blocking_async(
    func: Callable[..., T],
    *args: Any,
    **kwargs: Any,
) -> T:
    loop = asyncio.get_running_loop()
    pool = get_blocking_pool()
    if kwargs:
        return await loop.run_in_executor(
            pool,
            lambda: func(*args, **kwargs),
        )
    return await loop.run_in_executor(pool, func, *args)
