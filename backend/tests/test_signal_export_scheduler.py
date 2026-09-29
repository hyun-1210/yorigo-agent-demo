"""signal_export_scheduler 단위 테스트 (재시도 + 부분실패 abort)."""

from __future__ import annotations

import gzip
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

# services/__init__.py 가 FirebaseService 등 무거운 의존성을 끌어오므로
# 모듈 파일을 직접 로드한다 (GH Actions 등 최소 의존성 환경 대응).
_MODULE_PATH = BACKEND_DIR / "services" / "signal_export_scheduler.py"
_SPEC = importlib.util.spec_from_file_location(
    "signal_export_scheduler_under_test", _MODULE_PATH
)
assert _SPEC is not None and _SPEC.loader is not None
ses = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = ses
_SPEC.loader.exec_module(ses)


class _FakeBlob:
    def __init__(self, name: str, payload: bytes | None = None, fail_times: int = 0):
        self.name = name
        self._payload = payload or b""
        self._fail_times = fail_times
        self._calls = 0
        self.uploaded: bytes | None = None
        self.content_type: str | None = None

    def download_as_bytes(self) -> bytes:
        self._calls += 1
        if self._calls <= self._fail_times:
            raise ConnectionError(f"transient fail #{self._calls}")
        return self._payload

    def upload_from_string(self, data: bytes, content_type: str = "") -> None:
        self.uploaded = data
        self.content_type = content_type


class _FakeBucket:
    def __init__(self, blobs: list[_FakeBlob]):
        self._blobs = blobs
        self._by_name = {b.name: b for b in blobs}

    def list_blobs(self, prefix: str = ""):
        return [b for b in self._blobs if b.name.startswith(prefix)]

    def blob(self, name: str) -> _FakeBlob:
        if name not in self._by_name:
            self._by_name[name] = _FakeBlob(name)
            self._blobs.append(self._by_name[name])
        return self._by_name[name]


class TestDownloadRetry(unittest.TestCase):
    def test_retries_then_succeeds(self) -> None:
        blob = _FakeBlob("signals/raw/2026-08-04/u/a.jsonl", b'{"x":1}\n', fail_times=2)
        sleeps: list[float] = []
        text = ses._download_blob_text(
            blob,
            max_attempts=3,
            backoff_base=0.1,
            sleep_fn=sleeps.append,
        )
        self.assertEqual(text, '{"x":1}')
        self.assertEqual(blob._calls, 3)
        self.assertEqual(sleeps, [0.1, 0.2])

    def test_raises_after_exhausting_attempts(self) -> None:
        blob = _FakeBlob("signals/raw/2026-08-04/u/a.jsonl", b"ok", fail_times=99)
        with self.assertRaises(ConnectionError):
            ses._download_blob_text(
                blob,
                max_attempts=2,
                backoff_base=0.0,
                sleep_fn=lambda _: None,
            )
        self.assertEqual(blob._calls, 2)


class TestMergeDateAbort(unittest.TestCase):
    def test_uploads_when_all_downloads_ok(self) -> None:
        date = "2026-08-04"
        raw1 = _FakeBlob(
            f"signals/raw/{date}/u/a.jsonl",
            b'{"eventId":"1"}\n',
        )
        raw2 = _FakeBlob(
            f"signals/raw/{date}/u/b.jsonl",
            b'{"eventId":"2"}\n',
        )
        bucket = _FakeBucket([raw1, raw2])
        result = ses._merge_date(bucket, date)
        self.assertTrue(result["uploaded"])
        self.assertFalse(result["aborted"])
        self.assertEqual(result["event_count"], 2)
        processed = bucket.blob(f"signals/processed/dt={date}/events.jsonl.gz")
        self.assertIsNotNone(processed.uploaded)
        assert processed.uploaded is not None
        lines = gzip.decompress(processed.uploaded).decode("utf-8").strip().split("\n")
        self.assertEqual(len(lines), 2)

    def test_aborts_upload_when_any_download_fails(self) -> None:
        date = "2026-08-04"
        ok = _FakeBlob(f"signals/raw/{date}/u/ok.jsonl", b'{"eventId":"1"}\n')
        bad = _FakeBlob(f"signals/raw/{date}/u/bad.jsonl", b'{"eventId":"2"}\n')
        # 기존 processed가 있어도 덮어쓰지 않아야 함
        existing = _FakeBlob(
            f"signals/processed/dt={date}/events.jsonl.gz",
            b"existing",
        )
        existing.uploaded = b"KEEP_ME"
        bucket = _FakeBucket([ok, bad, existing])

        def download_fn(blob: _FakeBlob) -> str:
            if "bad" in blob.name:
                raise ConnectionError("permanent")
            return blob.download_as_bytes().decode("utf-8").strip("\n")

        result = ses._merge_date(bucket, date, download_fn=download_fn)
        self.assertTrue(result["aborted"])
        self.assertFalse(result["uploaded"])
        self.assertEqual(result["failed_downloads"], 1)
        self.assertEqual(existing.uploaded, b"KEEP_ME")

    def test_skips_when_no_raw(self) -> None:
        bucket = _FakeBucket([])
        result = ses._merge_date(bucket, "2026-08-01")
        self.assertTrue(result["skipped"])
        self.assertFalse(result["uploaded"])
        self.assertFalse(result["aborted"])


class TestRunSummary(unittest.TestCase):
    def test_ok_false_when_aborted_dates(self) -> None:
        from datetime import datetime, timezone

        started = datetime(2026, 8, 4, 0, 0, tzinfo=timezone.utc)
        finished = datetime(2026, 8, 4, 0, 1, tzinfo=timezone.utc)
        summary = ses._build_run_summary(
            run_id="abc",
            started_at=started,
            finished_at=finished,
            lookback_days=3,
            date_results=[
                {
                    "date": "2026-08-04",
                    "raw_file_count": 2,
                    "event_count": 0,
                    "aborted": True,
                    "uploaded": False,
                    "skipped": False,
                    "failed_downloads": 1,
                }
            ],
        )
        self.assertFalse(summary["ok"])
        self.assertEqual(summary["status"], "partial_failure")
        self.assertEqual(summary["abortedDates"], ["2026-08-04"])


class TestRunOncePersists(unittest.TestCase):
    def test_persists_last_run(self) -> None:
        date = "2026-08-04"
        raw = _FakeBlob(f"signals/raw/{date}/u/a.jsonl", b'{"eventId":"1"}\n')
        bucket = _FakeBucket([raw])
        db = MagicMock()
        schedule_doc = MagicMock()
        runs_doc = MagicMock()
        db.collection.side_effect = lambda name: MagicMock(
            document=lambda _id: schedule_doc if name == "system_schedules" else runs_doc
        )

        # lookback=1이면 오늘 날짜만 — 고정 버킷으로 mock
        summary = ses.run_signal_export_once(
            db,
            lookback_days=1,
            bucket=bucket,
        )
        self.assertIn(summary["status"], ("success", "partial_failure", "failure"))
        self.assertTrue(schedule_doc.set.called or runs_doc.set.called)


if __name__ == "__main__":
    unittest.main()
