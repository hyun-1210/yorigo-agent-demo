"""Railway 단일 컨테이너용 API + Timestamp 프로세스 감독자.

PID 1로 동작하며:
  - API(uvicorn)와 timestamp 전용 프로세스(기본 2슬롯)를 기동
  - API 자식에는 ENABLE_TIMESTAMP_WORKER=false 강제
  - 자식은 서로 독립적으로 감시됨: 한쪽이 죽어도(정상 종료 코드 포함)
    다른 쪽은 계속 서빙하고, 죽은 자식만 지수 백오프 후 재시작한다
    (전체 fail-fast 없음 — 부가 기능 장애가 핵심 API 다운타임으로
    번지지 않도록 함)
  - SIGTERM/SIGINT(정상 종료 요청)를 받으면 재시작 없이 양쪽에 전달,
    제한시간 후 SIGKILL
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, List, Mapping, Optional, Sequence


DEFAULT_SHUTDOWN_GRACE_SECONDS = 25.0
DEFAULT_KILL_GRACE_SECONDS = 5.0
DEFAULT_RESTART_BACKOFF_BASE_SECONDS = 1.0
DEFAULT_RESTART_BACKOFF_MAX_SECONDS = 30.0
DEFAULT_RESTART_WARN_WINDOW_SECONDS = 600.0
DEFAULT_RESTART_WARN_THRESHOLD = 5


@dataclass
class ChildSpec:
    """감독할 자식 프로세스 명세."""

    name: str
    argv: Sequence[str]
    env_overrides: Mapping[str, str]


@dataclass
class ManagedChild:
    """실행 중인 자식 프로세스."""

    spec: ChildSpec
    process: subprocess.Popen
    process_group_id: Optional[int] = None


def build_api_env(base_env: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """API 자식용 환경변수. 내장 timestamp 워커를 반드시 끈다."""
    env = dict(base_env or os.environ)
    env["ENABLE_TIMESTAMP_WORKER"] = "false"
    return env


def build_timestamp_env(base_env: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Timestamp 자식용 환경변수.

    자식 프로세스 안에서는 항상 in-process concurrency=1이 안전하다
    (budget 초과 시 ``os._exit``로 orphan을 끊기 위해). 슬롯 개수(N)는
    supervisor가 ``default_child_specs``에서 이미 반영한다.
    """
    env = dict(base_env or os.environ)
    env["TIMESTAMP_WORKER_CONCURRENCY"] = "1"
    # 전용 프로세스이므로 내장 스레드 워커 플래그는 의미 없지만 명시적으로 끈다.
    env["ENABLE_TIMESTAMP_WORKER"] = "false"
    return env


def default_child_specs(
    *,
    python_executable: Optional[str] = None,
    port: Optional[str] = None,
    uvicorn_workers: Optional[str] = None,
    enable_timestamp_worker: Optional[bool] = None,
    timestamp_worker_count: Optional[int] = None,
) -> List[ChildSpec]:
    """기본 API/Timestamp 자식 명세를 만든다.

    ``TIMESTAMP_WORKER_CONCURRENCY``(N)는 이 프로세스(supervisor) 레벨에서는
    "몇 개의 독립 timestamp 프로세스를 띄울지"로 해석된다. 각 timestamp 자식
    프로세스는 자기 안에서 항상 ``TIMESTAMP_WORKER_CONCURRENCY=1``로 동작해
    budget 초과 시 orphan 없이(``os._exit``) 자기 자신만 종료할 수 있다.
    N개로 나누면 한 잡의 budget 초과가 다른 잡에 영향을 주지 않고, 죽은
    슬롯만 독립적으로 재시작된다(다른 슬롯/API는 계속 서빙).
    """
    py = python_executable or sys.executable
    host_port = port or os.getenv("PORT", "8000")
    workers = uvicorn_workers or os.getenv("UVICORN_WORKERS", "1")
    timestamp_enabled = (
        enable_timestamp_worker
        if enable_timestamp_worker is not None
        else os.getenv("ENABLE_TIMESTAMP_WORKER", "false").lower()
        in {"1", "true", "yes", "on"}
    )
    specs = [
        ChildSpec(
            name="api",
            argv=[
                py,
                "-m",
                "uvicorn",
                "backend:app",
                "--host",
                "0.0.0.0",
                "--port",
                str(host_port),
                "--workers",
                str(workers),
            ],
            env_overrides={"ENABLE_TIMESTAMP_WORKER": "false"},
        ),
    ]
    if timestamp_enabled:
        count = timestamp_worker_count
        if count is None:
            # 기본 2: API와 분리된 타임스탬프 슬롯을 최대 2개까지 동시에 돌린다.
            count = max(1, int(os.getenv("TIMESTAMP_WORKER_CONCURRENCY", "2")))
        count = max(1, count)
        for i in range(count):
            specs.append(
                ChildSpec(
                    # 슬롯이 1개뿐이면 기존 이름("timestamp")을 유지해 로그/
                    # 기존 도구 호환성을 지킨다.
                    name="timestamp" if count == 1 else f"timestamp-{i}",
                    argv=[py, "timestamp_worker_main.py"],
                    env_overrides={
                        "ENABLE_TIMESTAMP_WORKER": "false",
                        "TIMESTAMP_WORKER_CONCURRENCY": "1",
                        "TIMESTAMP_WORKER_SLOT": str(i),
                    },
                )
            )
    return specs


def _log(role: str, message: str) -> None:
    print(f"[supervisor:{role}] {message}", flush=True)


def _merge_env(
    base_env: Mapping[str, str],
    overrides: Mapping[str, str],
) -> Dict[str, str]:
    env = dict(base_env)
    env.update(overrides)
    return env


def start_child(
    spec: ChildSpec,
    *,
    cwd: Optional[str] = None,
    base_env: Optional[Mapping[str, str]] = None,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
) -> ManagedChild:
    """자식 프로세스를 기동한다."""
    env = _merge_env(base_env or os.environ, spec.env_overrides)
    _log(spec.name, f"starting: {' '.join(spec.argv)}")
    proc = popen(
        list(spec.argv),
        cwd=cwd,
        env=env,
        # POSIX에서는 자식별 프로세스 그룹을 만들어 ffmpeg/yt-dlp 등
        # 손자 프로세스까지 함께 종료할 수 있게 한다.
        start_new_session=(os.name == "posix"),
    )
    _log(spec.name, f"started pid={proc.pid}")
    return ManagedChild(
        spec=spec,
        process=proc,
        process_group_id=proc.pid if os.name == "posix" else None,
    )


def signal_child(child: ManagedChild, sig: signal.Signals) -> None:
    """자식에 시그널을 보낸다. 이미 종료된 경우 무시."""
    if child.process.poll() is not None:
        return
    try:
        if os.name == "posix" and isinstance(child.process, subprocess.Popen):
            os.killpg(os.getpgid(child.process.pid), sig)
        else:
            child.process.send_signal(sig)
        _log(child.spec.name, f"sent {sig.name}")
    except ProcessLookupError:
        return
    except Exception as exc:
        _log(child.spec.name, f"signal {sig.name} failed: {exc}")


def cleanup_exited_child_group(
    child: ManagedChild,
    *,
    grace_seconds: float = 0.5,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> None:
    """종료된 POSIX 자식이 남긴 ffmpeg/yt-dlp 프로세스 그룹을 정리한다."""
    pgid = child.process_group_id
    if os.name != "posix" or pgid is None:
        return

    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except Exception as exc:
        _log(child.spec.name, f"orphan group SIGTERM failed: {exc}")
        return

    deadline = time.monotonic() + max(0.0, grace_seconds)
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            break
        sleep_fn(0.05)

    try:
        os.killpg(pgid, signal.SIGKILL)
        _log(child.spec.name, f"cleaned orphan process group pgid={pgid}")
    except ProcessLookupError:
        return
    except Exception as exc:
        _log(child.spec.name, f"orphan group SIGKILL failed: {exc}")


def terminate_children(
    children: Sequence[ManagedChild],
    *,
    grace_seconds: float = DEFAULT_SHUTDOWN_GRACE_SECONDS,
    kill_grace_seconds: float = DEFAULT_KILL_GRACE_SECONDS,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> None:
    """모든 자식에 SIGTERM → 대기 → SIGKILL 순으로 종료한다."""
    for child in children:
        signal_child(child, signal.SIGTERM)

    deadline = time.monotonic() + max(0.0, grace_seconds)
    while time.monotonic() < deadline:
        if all(child.process.poll() is not None for child in children):
            return
        sleep_fn(0.1)

    for child in children:
        if child.process.poll() is None:
            _log(child.spec.name, "grace period expired - SIGKILL")
            try:
                if os.name == "posix" and isinstance(child.process, subprocess.Popen):
                    os.killpg(os.getpgid(child.process.pid), signal.SIGKILL)
                else:
                    child.process.kill()
            except Exception as exc:
                _log(child.spec.name, f"kill failed: {exc}")

    kill_deadline = time.monotonic() + max(0.0, kill_grace_seconds)
    while time.monotonic() < kill_deadline:
        if all(child.process.poll() is not None for child in children):
            return
        sleep_fn(0.05)


def wait_for_any_exit(
    children: Sequence[ManagedChild],
    *,
    poll_interval: float = 0.25,
    sleep_fn: Callable[[float], None] = time.sleep,
    should_stop: Optional[Callable[[], bool]] = None,
) -> Optional[ManagedChild]:
    """자식 중 하나가 종료될 때까지 대기한다."""
    while True:
        if should_stop is not None and should_stop():
            return None
        for child in children:
            code = child.process.poll()
            if code is not None:
                _log(child.spec.name, f"exited code={code}")
                return child
        sleep_fn(poll_interval)


def _compute_restart_backoff(
    restart_count_in_window: int,
    *,
    base_seconds: float,
    max_seconds: float,
) -> float:
    """윈도우 내 재시작 횟수 기준 지수 백오프(1st=base, 2nd=2*base, ...)."""
    if restart_count_in_window <= 0:
        return 0.0
    return min(base_seconds * (2 ** (restart_count_in_window - 1)), max_seconds)


def _sleep_until_or_stop(
    seconds: float,
    *,
    should_stop: Callable[[], bool],
    sleep_fn: Callable[[float], None],
) -> bool:
    """백오프 중에도 종료 신호에 빠르게 반응한다."""
    deadline = time.monotonic() + max(0.0, seconds)
    while not should_stop():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        sleep_fn(min(remaining, 0.25))
    return True


def run_supervisor(
    specs: Sequence[ChildSpec],
    *,
    cwd: Optional[str] = None,
    base_env: Optional[Mapping[str, str]] = None,
    grace_seconds: float = DEFAULT_SHUTDOWN_GRACE_SECONDS,
    kill_grace_seconds: float = DEFAULT_KILL_GRACE_SECONDS,
    restart_backoff_base_seconds: float = DEFAULT_RESTART_BACKOFF_BASE_SECONDS,
    restart_backoff_max_seconds: float = DEFAULT_RESTART_BACKOFF_MAX_SECONDS,
    restart_warn_window_seconds: float = DEFAULT_RESTART_WARN_WINDOW_SECONDS,
    restart_warn_threshold: int = DEFAULT_RESTART_WARN_THRESHOLD,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
    sleep_fn: Callable[[float], None] = time.sleep,
    stop_event: Optional[threading.Event] = None,
) -> int:
    """N개 자식을 독립적으로 감독한다.

    자식이 죽으면(정상 종료 요청이 아닌 한) 그 자식만 지수 백오프 후
    재시작한다. 다른 자식은 영향받지 않고 계속 서빙한다. 재시작 횟수에
    상한(circuit breaker)은 없음 — 일시 장애의 자연 복구를 우선하되,
    윈도우 내 재시작이 임계치를 넘으면 CRITICAL 로그로 경고한다.

    SIGTERM/SIGINT(또는 주입된 stop_event)를 받으면 재시작 없이 모든
    자식을 정리하고 정상 종료(0)한다.
    """
    if not specs:
        _log("main", "no child specs provided")
        return 1

    stop_requested = {"value": False}

    def _should_stop() -> bool:
        return stop_requested["value"] or (stop_event is not None and stop_event.is_set())

    def _on_signal(signum: int, _frame: object) -> None:
        name = signal.Signals(signum).name if signum else str(signum)
        _log("main", f"received {name} - shutting down children")
        stop_requested["value"] = True

    previous_handlers: Dict[int, object] = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            previous_handlers[sig] = signal.signal(sig, _on_signal)
        except (ValueError, OSError):
            # 일부 환경(비메인 스레드/Windows 제한)에서는 등록 실패 가능.
            pass

    children: List[ManagedChild] = []
    restart_history: Dict[str, List[float]] = {spec.name: [] for spec in specs}
    exit_code = 0
    try:
        for spec in specs:
            children.append(
                start_child(
                    spec,
                    cwd=cwd,
                    base_env=base_env,
                    popen=popen,
                )
            )

        while not _should_stop():
            exited = wait_for_any_exit(
                children,
                sleep_fn=sleep_fn,
                should_stop=_should_stop,
            )
            if _should_stop() or exited is None:
                break

            code = int(exited.process.returncode or 0)
            _log(
                exited.spec.name,
                f"exited code={code} - restarting independently "
                "(other children unaffected)",
            )
            cleanup_exited_child_group(exited, sleep_fn=sleep_fn)

            now = time.monotonic()
            history = restart_history.setdefault(exited.spec.name, [])
            history.append(now)
            cutoff = now - restart_warn_window_seconds
            while history and history[0] < cutoff:
                history.pop(0)

            if len(history) >= restart_warn_threshold:
                _log(
                    exited.spec.name,
                    f"CRITICAL: restarted {len(history)}x in last "
                    f"{restart_warn_window_seconds:.0f}s - possible crash loop",
                )

            backoff = _compute_restart_backoff(
                len(history),
                base_seconds=restart_backoff_base_seconds,
                max_seconds=restart_backoff_max_seconds,
            )
            if backoff > 0:
                _log(exited.spec.name, f"restarting in {backoff:.1f}s")
                stopped = _sleep_until_or_stop(
                    backoff,
                    should_stop=_should_stop,
                    sleep_fn=sleep_fn,
                )
                if stopped:
                    break

            if _should_stop():
                break

            idx = next(i for i, c in enumerate(children) if c is exited)
            children[idx] = start_child(
                exited.spec,
                cwd=cwd,
                base_env=base_env,
                popen=popen,
            )

        exit_code = 0
    except Exception as exc:
        _log("main", f"supervisor error: {exc}")
        exit_code = 1
    finally:
        terminate_children(
            children,
            grace_seconds=grace_seconds,
            kill_grace_seconds=kill_grace_seconds,
            sleep_fn=sleep_fn,
        )
        for child in children:
            code = child.process.poll()
            _log(child.spec.name, f"final code={code}")
        for sig, handler in previous_handlers.items():
            try:
                signal.signal(sig, handler)  # type: ignore[arg-type]
            except Exception:
                pass

    _log("main", f"exiting code={exit_code}")
    return int(exit_code or 0)


def main(argv: Optional[Sequence[str]] = None) -> int:
    """CLI 진입점."""
    _ = argv  # 확장용
    backend_dir = os.path.dirname(os.path.abspath(__file__))
    grace = float(os.getenv("SUPERVISOR_SHUTDOWN_GRACE_SECONDS", str(DEFAULT_SHUTDOWN_GRACE_SECONDS)))
    kill_grace = float(
        os.getenv("SUPERVISOR_KILL_GRACE_SECONDS", str(DEFAULT_KILL_GRACE_SECONDS))
    )
    restart_backoff_base = float(
        os.getenv(
            "SUPERVISOR_RESTART_BACKOFF_BASE_SECONDS",
            str(DEFAULT_RESTART_BACKOFF_BASE_SECONDS),
        )
    )
    restart_backoff_max = float(
        os.getenv(
            "SUPERVISOR_RESTART_BACKOFF_MAX_SECONDS",
            str(DEFAULT_RESTART_BACKOFF_MAX_SECONDS),
        )
    )
    restart_warn_window = float(
        os.getenv(
            "SUPERVISOR_RESTART_WARN_WINDOW_SECONDS",
            str(DEFAULT_RESTART_WARN_WINDOW_SECONDS),
        )
    )
    restart_warn_threshold = int(
        os.getenv("SUPERVISOR_RESTART_WARN_THRESHOLD", str(DEFAULT_RESTART_WARN_THRESHOLD))
    )
    specs = default_child_specs()
    _log("main", f"cwd={backend_dir} children={[s.name for s in specs]}")
    return run_supervisor(
        specs,
        cwd=backend_dir,
        grace_seconds=grace,
        kill_grace_seconds=kill_grace,
        restart_backoff_base_seconds=restart_backoff_base,
        restart_backoff_max_seconds=restart_backoff_max,
        restart_warn_window_seconds=restart_warn_window,
        restart_warn_threshold=restart_warn_threshold,
    )


if __name__ == "__main__":
    raise SystemExit(main())
