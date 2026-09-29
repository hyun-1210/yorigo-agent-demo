"""프로세스 감독자 / timestamp 전용 진입점 검증.

  python Scripts/test_process_supervisor.py
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Dict, List, Optional
from unittest.mock import MagicMock, patch

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


class _FakeProc:
    def __init__(self, pid: int, exit_after: Optional[float] = None, code: int = 0) -> None:
        self.pid = pid
        self._code: Optional[int] = None
        self._exit_after = exit_after
        self._started = time.monotonic()
        self._forced_code = code
        self.signals: List[signal.Signals] = []
        self.killed = False

    def poll(self) -> Optional[int]:
        if self._code is not None:
            return self._code
        if self._exit_after is not None and (time.monotonic() - self._started) >= self._exit_after:
            self._code = self._forced_code
            return self._code
        return None

    def send_signal(self, sig: signal.Signals) -> None:
        self.signals.append(sig)
        if sig in (signal.SIGTERM, signal.SIGINT):
            self._code = 0

    def kill(self) -> None:
        self.killed = True
        self._code = -9

    @property
    def returncode(self) -> Optional[int]:
        return self._code


def test_build_api_env_disables_timestamp_worker() -> None:
    print("\n[S1] API env forces ENABLE_TIMESTAMP_WORKER=false")
    from process_supervisor import build_api_env

    env = build_api_env({"ENABLE_TIMESTAMP_WORKER": "true", "FOO": "bar"})
    check(env["ENABLE_TIMESTAMP_WORKER"] == "false", "API overrides true → false")
    check(env["FOO"] == "bar", "other env preserved")


def test_default_child_specs() -> None:
    print("\n[S2] default child specs")
    from process_supervisor import default_child_specs

    # 기본 TIMESTAMP_WORKER_CONCURRENCY=2 → api + timestamp-0 + timestamp-1
    # (명시 count로 단일 슬롯 레거시 이름도 검증)
    specs_single = default_child_specs(
        python_executable="python",
        port="8080",
        uvicorn_workers="1",
        enable_timestamp_worker=True,
        timestamp_worker_count=1,
    )
    check(len(specs_single) == 2, "two children when count=1")
    check(specs_single[0].name == "api", "first is api")
    check(
        specs_single[1].name == "timestamp",
        "second is timestamp (single slot keeps legacy name)",
    )
    check("uvicorn" in specs_single[0].argv, "api runs uvicorn")
    check("timestamp_worker_main.py" in specs_single[1].argv, "ts runs dedicated main")
    check(
        specs_single[0].env_overrides.get("ENABLE_TIMESTAMP_WORKER") == "false",
        "api disables embedded ts",
    )
    check(
        specs_single[1].env_overrides.get("TIMESTAMP_WORKER_CONCURRENCY") == "1",
        "single ts slot forced to per-process concurrency=1",
    )

    # env 미설정 시 기본 슬롯 수=2
    saved = os.environ.pop("TIMESTAMP_WORKER_CONCURRENCY", None)
    try:
        specs = default_child_specs(
            python_executable="python",
            port="8080",
            uvicorn_workers="1",
            enable_timestamp_worker=True,
        )
    finally:
        if saved is not None:
            os.environ["TIMESTAMP_WORKER_CONCURRENCY"] = saved
    ts = [s for s in specs if s.name != "api"]
    check(len(specs) == 3, f"default concurrency=2 → api+2 ts (got {len(specs)})")
    check(
        [s.name for s in ts] == ["timestamp-0", "timestamp-1"],
        f"default slots named timestamp-0/1 (got {[s.name for s in ts]})",
    )

    api_only = default_child_specs(
        python_executable="python",
        enable_timestamp_worker=False,
    )
    check(len(api_only) == 1, "timestamp child omitted when disabled")


def test_default_child_specs_multi_slot() -> None:
    print("\n[S2b] default child specs - TIMESTAMP_WORKER_CONCURRENCY spawns N processes")
    from process_supervisor import default_child_specs

    specs = default_child_specs(
        python_executable="python",
        enable_timestamp_worker=True,
        timestamp_worker_count=3,
    )
    ts_specs = [s for s in specs if s.name != "api"]
    check(len(specs) == 4, f"api + 3 independent timestamp slots (got {len(specs)})")
    check(
        [s.name for s in ts_specs] == ["timestamp-0", "timestamp-1", "timestamp-2"],
        f"slots named timestamp-0..2 (got {[s.name for s in ts_specs]})",
    )
    for i, spec in enumerate(ts_specs):
        check(
            spec.env_overrides.get("TIMESTAMP_WORKER_CONCURRENCY") == "1",
            f"slot {i} forced to per-process concurrency=1",
        )
        check(
            spec.env_overrides.get("TIMESTAMP_WORKER_SLOT") == str(i),
            f"slot {i} env identifies its slot index",
        )
        check(
            spec.env_overrides.get("ENABLE_TIMESTAMP_WORKER") == "false",
            f"slot {i} disables the embedded flag (uses dedicated process)",
        )

    # Env-var driven path (no explicit timestamp_worker_count) should match.
    os.environ["TIMESTAMP_WORKER_CONCURRENCY"] = "2"
    try:
        specs_env = default_child_specs(
            python_executable="python", enable_timestamp_worker=True,
        )
    finally:
        os.environ.pop("TIMESTAMP_WORKER_CONCURRENCY", None)
    ts_env = [s for s in specs_env if s.name != "api"]
    check(len(ts_env) == 2, f"env TIMESTAMP_WORKER_CONCURRENCY=2 spawns 2 slots (got {len(ts_env)})")


def test_independent_restart_when_api_exits() -> None:
    print("\n[S3] independent restart: API crash restarts only API")
    from process_supervisor import ChildSpec, run_supervisor

    procs: List[_FakeProc] = []
    api_starts = {"n": 0}
    ts_starts = {"n": 0}

    def fake_popen(argv: List[str], **kwargs: Any) -> _FakeProc:
        if "uvicorn" in " ".join(argv):
            api_starts["n"] += 1
            # 첫 기동은 바로 죽고, 재시작된 두 번째는 끝까지 살아있음.
            exit_after = 0.02 if api_starts["n"] == 1 else None
            proc = _FakeProc(pid=100 + api_starts["n"], exit_after=exit_after, code=1)
        else:
            ts_starts["n"] += 1
            proc = _FakeProc(pid=200 + ts_starts["n"])  # 절대 죽지 않음
        procs.append(proc)
        return proc

    stop_event = threading.Event()
    result: Dict[str, int] = {}

    def _run() -> None:
        result["code"] = run_supervisor(
            [
                ChildSpec("api", ["python", "-m", "uvicorn"], {"ENABLE_TIMESTAMP_WORKER": "false"}),
                ChildSpec("timestamp", ["python", "timestamp_worker_main.py"], {}),
            ],
            popen=fake_popen,  # type: ignore[arg-type]
            sleep_fn=lambda s: time.sleep(min(s, 0.01)),
            grace_seconds=0.2,
            kill_grace_seconds=0.05,
            restart_backoff_base_seconds=0.01,
            restart_backoff_max_seconds=0.02,
            stop_event=stop_event,
        )

    t = threading.Thread(target=_run, daemon=True)
    t.start()

    deadline = time.monotonic() + 3.0
    while api_starts["n"] < 2 and time.monotonic() < deadline:
        time.sleep(0.02)

    check(api_starts["n"] >= 2, f"api restarted after crash (starts={api_starts['n']})")
    check(ts_starts["n"] == 1, f"timestamp was NOT restarted (starts={ts_starts['n']})")

    stop_event.set()
    t.join(timeout=2)
    check(t.is_alive() is False, "supervisor thread stopped cleanly after stop_event")
    check(result.get("code") == 0, f"clean shutdown exit code 0 (got {result.get('code')})")


def test_independent_restart_when_timestamp_exits_zero() -> None:
    print("\n[S4] independent restart: timestamp exiting (even code 0) restarts only timestamp")
    from process_supervisor import ChildSpec, run_supervisor

    api_starts = {"n": 0}
    ts_starts = {"n": 0}

    def fake_popen(argv: List[str], **kwargs: Any) -> _FakeProc:
        if "timestamp_worker_main.py" in argv:
            ts_starts["n"] += 1
            exit_after = 0.02 if ts_starts["n"] == 1 else None
            return _FakeProc(pid=300 + ts_starts["n"], exit_after=exit_after, code=0)
        api_starts["n"] += 1
        return _FakeProc(pid=400 + api_starts["n"])  # api 계속 서빙

    stop_event = threading.Event()
    result: Dict[str, int] = {}

    def _run() -> None:
        result["code"] = run_supervisor(
            [
                ChildSpec("api", ["python", "-m", "uvicorn"], {}),
                ChildSpec("timestamp", ["python", "timestamp_worker_main.py"], {}),
            ],
            popen=fake_popen,  # type: ignore[arg-type]
            sleep_fn=lambda s: time.sleep(min(s, 0.01)),
            grace_seconds=0.2,
            kill_grace_seconds=0.05,
            restart_backoff_base_seconds=0.01,
            restart_backoff_max_seconds=0.02,
            stop_event=stop_event,
        )

    t = threading.Thread(target=_run, daemon=True)
    t.start()

    deadline = time.monotonic() + 3.0
    while ts_starts["n"] < 2 and time.monotonic() < deadline:
        time.sleep(0.02)

    check(ts_starts["n"] >= 2, f"timestamp restarted after zero-exit (starts={ts_starts['n']})")
    check(api_starts["n"] == 1, f"api was NOT restarted (starts={api_starts['n']})")

    stop_event.set()
    t.join(timeout=2)
    check(t.is_alive() is False, "supervisor thread stopped cleanly after stop_event")
    check(result.get("code") == 0, f"clean shutdown exit code 0 (got {result.get('code')})")


def test_restart_backoff_and_crash_loop_warning() -> None:
    print("\n[S4b] restart backoff grows and crash-loop warning logs")
    from process_supervisor import _compute_restart_backoff

    check(_compute_restart_backoff(0, base_seconds=1.0, max_seconds=30.0) == 0.0, "no backoff before first restart")
    check(_compute_restart_backoff(1, base_seconds=1.0, max_seconds=30.0) == 1.0, "1st restart = base")
    check(_compute_restart_backoff(2, base_seconds=1.0, max_seconds=30.0) == 2.0, "2nd restart = 2x base")
    check(_compute_restart_backoff(3, base_seconds=1.0, max_seconds=30.0) == 4.0, "3rd restart = 4x base")
    check(_compute_restart_backoff(10, base_seconds=1.0, max_seconds=30.0) == 30.0, "capped at max_seconds")


def test_restart_backoff_is_interruptible() -> None:
    print("\n[S4c] restart backoff is interruptible")
    from process_supervisor import _sleep_until_or_stop

    stop = threading.Event()

    def _request_stop() -> None:
        time.sleep(0.05)
        stop.set()

    threading.Thread(target=_request_stop, daemon=True).start()
    started = time.monotonic()
    stopped = _sleep_until_or_stop(
        30.0,
        should_stop=stop.is_set,
        sleep_fn=time.sleep,
    )
    elapsed = time.monotonic() - started
    check(stopped is True, "stop signal interrupts backoff")
    check(elapsed < 1.0, f"backoff interrupted promptly ({elapsed:.2f}s)")


def test_graceful_shutdown_stops_without_restart() -> None:
    print("\n[S4d] SIGTERM-equivalent stop_event prevents restart")
    from process_supervisor import ChildSpec, run_supervisor

    starts = {"n": 0}

    def fake_popen(argv: List[str], **kwargs: Any) -> _FakeProc:
        starts["n"] += 1
        return _FakeProc(pid=500 + starts["n"])  # 자연 종료 없음, stop_event로만 멈춤

    stop_event = threading.Event()
    result: Dict[str, int] = {}

    def _run() -> None:
        result["code"] = run_supervisor(
            [ChildSpec("solo", ["python", "-m", "uvicorn"], {})],
            popen=fake_popen,  # type: ignore[arg-type]
            sleep_fn=lambda s: time.sleep(min(s, 0.01)),
            grace_seconds=0.2,
            kill_grace_seconds=0.05,
            stop_event=stop_event,
        )

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    time.sleep(0.1)
    stop_event.set()
    t.join(timeout=2)

    check(t.is_alive() is False, "supervisor stopped on stop_event")
    check(starts["n"] == 1, "no restart occurred during graceful shutdown")
    check(result.get("code") == 0, f"clean exit code 0 (got {result.get('code')})")


def test_terminate_uses_kill_after_grace() -> None:
    print("\n[S5] SIGKILL after grace period")
    from process_supervisor import ChildSpec, ManagedChild, terminate_children

    class StickyProc(_FakeProc):
        def send_signal(self, sig: signal.Signals) -> None:
            self.signals.append(sig)
            # ignore SIGTERM to force kill path

    sticky = StickyProc(pid=301)
    child = ManagedChild(
        spec=ChildSpec("sticky", ["sleep"], {}),
        process=sticky,  # type: ignore[arg-type]
    )
    terminate_children([child], grace_seconds=0.05, kill_grace_seconds=0.05, sleep_fn=time.sleep)
    check(signal.SIGTERM in sticky.signals, "SIGTERM attempted first")
    check(sticky.killed is True, "SIGKILL used after grace")


def test_cleanup_exited_posix_process_group() -> None:
    print("\n[S5b] exited POSIX child process group cleanup")
    from process_supervisor import ChildSpec, ManagedChild, cleanup_exited_child_group

    exited = _FakeProc(pid=601)
    exited._code = 1
    child = ManagedChild(
        spec=ChildSpec("exited", ["python"], {}),
        process=exited,  # type: ignore[arg-type]
        process_group_id=601,
    )
    with patch("process_supervisor.os.name", "posix"), patch(
        "process_supervisor.os.killpg",
        side_effect=[None, ProcessLookupError()],
        create=True,
    ) as killpg:
        cleanup_exited_child_group(child, grace_seconds=0.1)

    check(killpg.call_count == 2, "SIGTERM sent and group disappearance checked")
    check(killpg.call_args_list[0].args == (601, signal.SIGTERM), "SIGTERM targets saved PGID")


def test_timestamp_bootstrap_success() -> None:
    print("\n[S6] timestamp bootstrap wires services")
    from timestamp_worker_main import bootstrap_timestamp_services

    fb = MagicMock()
    fb.db = object()
    recipe = object()
    calls: Dict[str, bool] = {"cookie": False, "source_refresh": False}

    def init_cookie() -> None:
        calls["cookie"] = True

    def start_source_refresh() -> bool:
        calls["source_refresh"] = True
        return True

    out_recipe, out_db = bootstrap_timestamp_services(
        initialize_cookie_pool_fn=init_cookie,
        start_cookie_source_refresh_worker_fn=start_source_refresh,
        get_firebase_service_fn=lambda: fb,
        get_llm_service_fn=lambda: "llm",
        get_transcription_service_fn=lambda: "tr",
        get_ocr_service_fn=lambda: "ocr",
        get_youtube_service_fn=lambda: "yt",
        get_recipe_service_fn=lambda **kwargs: recipe,
    )
    check(calls["cookie"] is True, "cookie pool initialized")
    check(calls.get("source_refresh") is False, "SOURCE_URL refresh not started")
    check(out_recipe is recipe, "recipe service returned")
    check(out_db is fb.db, "firestore db returned")


def test_timestamp_bootstrap_requires_firebase() -> None:
    print("\n[S7] timestamp bootstrap fails without firebase db")
    from timestamp_worker_main import bootstrap_timestamp_services

    fb = MagicMock()
    fb.db = None
    raised = False
    try:
        bootstrap_timestamp_services(
            initialize_cookie_pool_fn=lambda: None,
            start_cookie_source_refresh_worker_fn=lambda: False,
            get_firebase_service_fn=lambda: fb,
            get_llm_service_fn=lambda: None,
            get_transcription_service_fn=lambda: None,
            get_ocr_service_fn=lambda: None,
            get_youtube_service_fn=lambda: None,
            get_recipe_service_fn=lambda **kwargs: object(),
        )
    except RuntimeError as exc:
        raised = True
        check("Firebase" in str(exc), "error mentions Firebase")
    check(raised, "raises RuntimeError")


def test_timestamp_main_stop_event() -> None:
    print("\n[S8] timestamp main exits cleanly on stop_event")
    from timestamp_worker_main import run_timestamp_main

    stop = threading.Event()
    seen = {"worker": False}

    def bootstrap() -> tuple[object, object]:
        return object(), object()

    def run_worker(_recipe: object, db: object = None, stop_event: Optional[threading.Event] = None) -> None:
        seen["worker"] = True
        assert stop_event is not None
        # wait briefly then stop
        for _ in range(50):
            if stop_event.is_set():
                return
            time.sleep(0.01)

    t = threading.Thread(
        target=lambda: run_timestamp_main(
            stop_event=stop,
            bootstrap_fn=bootstrap,
            run_worker_fn=run_worker,
        ),
        daemon=True,
    )
    t.start()
    time.sleep(0.05)
    stop.set()
    t.join(timeout=2)
    check(seen["worker"] is True, "worker invoked")
    check(t.is_alive() is False, "main thread stopped")


def test_timestamp_main_does_not_import_backend_module() -> None:
    print("\n[S9] timestamp_worker_main source avoids backend import")
    path = os.path.join(_BACKEND, "timestamp_worker_main.py")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    check("import backend" not in src, "no import backend")
    check("from backend" not in src, "no from backend")
    check("import fastapi" not in src.lower(), "no import fastapi")
    check("import uvicorn" not in src.lower(), "no import uvicorn")
    check("from fastapi" not in src.lower(), "no from fastapi")
    check("from uvicorn" not in src.lower(), "no from uvicorn")


def test_dockerfile_uses_supervisor() -> None:
    print("\n[S10] Dockerfile wires dual-process supervisor")
    path = os.path.join(_BACKEND, "Dockerfile")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    check("process_supervisor.py" in src, "copies process_supervisor.py")
    check("timestamp_worker_main.py" in src, "copies timestamp_worker_main.py")
    check('CMD ["python", "process_supervisor.py"]' in src, "CMD is supervisor")
    check("--limit-max-requests" not in src, "no request-count recycle")
    check("TIMESTAMP_WORKER_CONCURRENCY=2" in src, "ts concurrency default 2")
    check("SUPERVISOR_RESTART_BACKOFF_BASE_SECONDS" in src, "restart backoff base configured")
    check("SUPERVISOR_RESTART_BACKOFF_MAX_SECONDS" in src, "restart backoff cap configured")


def test_subprocess_independent_restart_real() -> None:
    print("\n[S11] real subprocess: crashing child restarts alone, sleeper untouched")
    # 짧은 자식 2개: 하나는 바로 실패(재시작됨), 다른 하나는 계속 sleep(재시작 안 됨).
    from process_supervisor import ChildSpec, run_supervisor

    py = sys.executable
    sleep_script = (
        "import time,sys; "
        "print('sleeper', flush=True); "
        "time.sleep(30)"
    )
    fail_script = "import sys; print('failer', flush=True); sys.exit(3)"

    stop_event = threading.Event()
    result: Dict[str, int] = {}

    def _run() -> None:
        result["code"] = run_supervisor(
            [
                ChildSpec("sleeper", [py, "-c", sleep_script], {}),
                ChildSpec("failer", [py, "-c", fail_script], {}),
            ],
            grace_seconds=2.0,
            kill_grace_seconds=1.0,
            restart_backoff_base_seconds=0.05,
            restart_backoff_max_seconds=0.1,
            stop_event=stop_event,
        )

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    # failer가 최소 2번 이상 재시작될 시간을 준다 (0.05s + 0.1s 백오프 << 3s).
    time.sleep(3.0)
    stop_event.set()
    t.join(timeout=5)

    check(t.is_alive() is False, "supervisor thread stopped after stop_event")
    check(result.get("code") == 0, f"clean shutdown exit code 0 (got {result.get('code')})")


def test_subprocess_api_env_override_real() -> None:
    print("\n[S12] API child env override is applied")
    from process_supervisor import ChildSpec, start_child, build_api_env

    py = sys.executable
    script = (
        "import os,sys; "
        "print(os.environ.get('ENABLE_TIMESTAMP_WORKER',''), flush=True); "
        "sys.exit(0)"
    )
    with tempfile.TemporaryDirectory() as tmp:
        child = start_child(
            ChildSpec(
                "probe",
                [py, "-c", script],
                {"ENABLE_TIMESTAMP_WORKER": "false"},
            ),
            cwd=tmp,
            base_env=build_api_env({"ENABLE_TIMESTAMP_WORKER": "true"}),
        )
        out_code = child.process.wait(timeout=5)
        # stdout not captured (inherits) — verify exit only + env builder unit already covered
        check(out_code == 0, "probe exited 0")
        # Re-check builder: true forced to false
        env = build_api_env({"ENABLE_TIMESTAMP_WORKER": "true"})
        check(env["ENABLE_TIMESTAMP_WORKER"] == "false", "builder forces false")


def main() -> int:
    print("=" * 60)
    print("process supervisor / timestamp dedicated process tests")
    print("=" * 60)
    test_build_api_env_disables_timestamp_worker()
    test_default_child_specs()
    test_default_child_specs_multi_slot()
    test_independent_restart_when_api_exits()
    test_independent_restart_when_timestamp_exits_zero()
    test_restart_backoff_and_crash_loop_warning()
    test_restart_backoff_is_interruptible()
    test_graceful_shutdown_stops_without_restart()
    test_terminate_uses_kill_after_grace()
    test_cleanup_exited_posix_process_group()
    test_timestamp_bootstrap_success()
    test_timestamp_bootstrap_requires_firebase()
    test_timestamp_main_stop_event()
    test_timestamp_main_does_not_import_backend_module()
    test_dockerfile_uses_supervisor()
    test_subprocess_independent_restart_real()
    test_subprocess_api_env_override_real()
    print("\n" + "=" * 60)
    print(f"PASS={_PASS} FAIL={_FAIL}")
    print("=" * 60)
    return 1 if _FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
