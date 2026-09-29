"""signal_deidentify_service 단위 테스트."""

from __future__ import annotations

import gzip
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from services.signal_deidentify_service import (  # noqa: E402
    _deidentify_processed_blobs,
    _deidentify_raw_blobs,
    _gzip_jsonl_lines,
    compute_scan_dates,
    deidentify_event,
    event_belongs_to_user,
)


class TestDeidentifyEvent(unittest.TestCase):
    def test_strips_identifying_fields(self) -> None:
        uid = "abc123UID"
        event = {
            "eventId": "uuid-1",
            "userId": uid,
            "deviceId": "dev-1",
            "sessionId": "sess-1",
            "eventType": "click",
            "recipeId": "r1",
            "contentType": "recipe_save",
        }
        out = deidentify_event(event, uid)
        self.assertNotIn("userId", out)
        self.assertNotIn("deviceId", out)
        self.assertNotIn("sessionId", out)
        self.assertEqual(out["recipeId"], "r1")
        self.assertTrue(out["deidentified"])
        # 원본 불변
        self.assertEqual(event["userId"], uid)

    def test_rewrites_event_id_containing_uid(self) -> None:
        uid = "user_xyz"
        event = {
            "eventId": f"backfill_save_{uid}_recipe99",
            "userId": uid,
            "eventType": "click",
        }
        out = deidentify_event(event, uid)
        self.assertNotIn(uid, out["eventId"])
        self.assertTrue(out["eventId"].startswith("deid_"))

    def test_redacts_uid_in_other_string_fields(self) -> None:
        uid = "uid999"
        event = {
            "eventId": "ok",
            "userId": uid,
            "cardId": f"path/{uid}/x",
        }
        out = deidentify_event(event, uid)
        self.assertEqual(out["cardId"], "path/[redacted]/x")

    def test_event_belongs_to_user(self) -> None:
        uid = "u1"
        self.assertTrue(event_belongs_to_user({"userId": "u1"}, uid))
        self.assertTrue(
            event_belongs_to_user({"eventId": "backfill_save_u1_r"}, uid)
        )
        self.assertFalse(event_belongs_to_user({"userId": "other"}, uid))


class _FakeBlob:
    def __init__(self, name: str, data: bytes):
        self.name = name
        self._data = data
        self.deleted = False
        self.uploads: list[bytes] = []

    def download_as_bytes(self) -> bytes:
        return self._data

    def upload_from_string(self, data: bytes, content_type: str = "") -> None:
        self._data = data if isinstance(data, (bytes, bytearray)) else data.encode()
        self.uploads.append(self._data)

    def delete(self) -> None:
        self.deleted = True


class _FakeBucket:
    def __init__(self, blobs: list[_FakeBlob]):
        self._blobs = {b.name: b for b in blobs}
        # 어떤 prefix로 list_blobs가 호출됐는지 기록 — 비용 최적화(범위 좁힘)
        # 검증용. 실제 GCS 비용은 list 호출 수 + 다운로드한 바이트에 비례한다.
        self.list_calls: list[str] = []

    def list_blobs(self, prefix: str = ""):
        self.list_calls.append(prefix)
        for name, blob in list(self._blobs.items()):
            if name.startswith(prefix):
                yield blob

    def blob(self, name: str) -> _FakeBlob:
        if name not in self._blobs:
            self._blobs[name] = _FakeBlob(name, b"")
        return self._blobs[name]


class TestRawAndProcessedPipeline(unittest.TestCase):
    def test_raw_moves_to_processed_and_deletes_original(self) -> None:
        uid = "targetUser"
        other = "otherUser"
        events = [
            json.dumps(
                {
                    "eventId": "e1",
                    "userId": uid,
                    "deviceId": "d1",
                    "sessionId": "s1",
                    "eventType": "click",
                    "recipeId": "r1",
                },
                ensure_ascii=False,
            ),
            json.dumps(
                {
                    "eventId": "e2",
                    "userId": uid,
                    "eventType": "purchase",
                    "ingredientName": "양파",
                },
                ensure_ascii=False,
            ),
        ]
        raw = _FakeBlob(
            f"signals/raw/2026-08-01/{uid}/batch.jsonl",
            ("\n".join(events) + "\n").encode("utf-8"),
        )
        # 다른 유저 raw는 건드리면 안 됨
        other_raw = _FakeBlob(
            f"signals/raw/2026-08-01/{other}/batch.jsonl",
            json.dumps({"eventId": "x", "userId": other}).encode("utf-8"),
        )
        bucket = _FakeBucket([raw, other_raw])
        stats = _deidentify_raw_blobs(bucket, uid)

        self.assertEqual(stats["raw_blobs_matched"], 1)
        self.assertEqual(stats["raw_events_deidentified"], 2)
        self.assertEqual(stats["raw_blobs_deleted"], 1)
        self.assertTrue(raw.deleted)
        self.assertFalse(other_raw.deleted)

        # processed에 deid 파일이 생겼는지
        deid_blobs = [
            b
            for name, b in bucket._blobs.items()
            if name.startswith("signals/processed/dt=2026-08-01/events_deid_")
        ]
        self.assertEqual(len(deid_blobs), 1)
        text = gzip.decompress(deid_blobs[0]._data).decode("utf-8")
        for line in text.strip().splitlines():
            obj = json.loads(line)
            self.assertNotIn("userId", obj)
            self.assertNotIn("deviceId", obj)
            self.assertNotIn(uid, json.dumps(obj))

    def test_processed_rewrites_only_target_user_lines(self) -> None:
        uid = "targetUser"
        lines = [
            json.dumps(
                {
                    "eventId": f"backfill_save_{uid}_r1",
                    "userId": uid,
                    "eventType": "click",
                }
            ),
            json.dumps(
                {
                    "eventId": "keep-me",
                    "userId": "someoneElse",
                    "eventType": "click",
                }
            ),
        ]
        payload = _gzip_jsonl_lines(lines)
        processed = _FakeBlob(
            "signals/processed/dt=2026-07-01/events_backfill.jsonl.gz",
            payload,
        )
        bucket = _FakeBucket([processed])
        stats = _deidentify_processed_blobs(bucket, uid)

        self.assertEqual(stats["processed_blobs_rewritten"], 1)
        self.assertEqual(stats["processed_events_deidentified"], 1)
        text = gzip.decompress(processed._data).decode("utf-8")
        out = [json.loads(x) for x in text.strip().splitlines()]
        self.assertEqual(len(out), 2)
        # target deidentified
        self.assertTrue(out[0].get("deidentified"))
        self.assertNotIn("userId", out[0])
        self.assertNotIn(uid, out[0].get("eventId", ""))
        # other untouched
        self.assertEqual(out[1]["userId"], "someoneElse")
        self.assertEqual(out[1]["eventId"], "keep-me")


class TestComputeScanDates(unittest.TestCase):
    def test_none_created_date_falls_back_to_full_scan(self) -> None:
        result = compute_scan_dates(None)
        self.assertIsNone(result["raw_dates"])
        self.assertIsNone(result["processed_dates"])

    def test_invalid_created_date_falls_back_to_full_scan(self) -> None:
        result = compute_scan_dates("not-a-date")
        self.assertIsNone(result["raw_dates"])
        self.assertIsNone(result["processed_dates"])

    def test_valid_created_date_returns_bounded_range(self) -> None:
        result = compute_scan_dates("2020-01-01")
        self.assertIsNotNone(result["processed_dates"])
        self.assertIsNotNone(result["raw_dates"])
        # processed는 가입일까지 거슬러 올라가고, raw는 lifecycle(14일) 안쪽으로만.
        self.assertIn("2020-01-01", result["processed_dates"])
        self.assertLessEqual(len(result["raw_dates"]), 20)


class TestBoundedScanCostSavings(unittest.TestCase):
    """계정 생성일로 스캔 범위를 좁혔을 때 실제로 오래된 파티션을
    다운로드/리스트하지 않는지 검증한다(=탈퇴 1건당 비용 절감 확인)."""

    def test_raw_bounded_scan_only_lists_target_dates_and_uid(self) -> None:
        uid = "targetUser"
        other = "otherUser"
        in_range = _FakeBlob(
            f"signals/raw/2026-08-01/{uid}/batch.jsonl",
            json.dumps({"eventId": "e1", "userId": uid}).encode("utf-8"),
        )
        # 스캔 범위 밖(가입일 이전) — 실제로는 존재할 수 없는 날짜지만,
        # 코드가 리스트조차 하지 않는지 확인하기 위한 미끼 데이터.
        out_of_range = _FakeBlob(
            f"signals/raw/2020-01-01/{uid}/old.jsonl",
            json.dumps({"eventId": "old", "userId": uid}).encode("utf-8"),
        )
        other_user_same_date = _FakeBlob(
            f"signals/raw/2026-08-01/{other}/batch.jsonl",
            json.dumps({"eventId": "x", "userId": other}).encode("utf-8"),
        )
        bucket = _FakeBucket([in_range, out_of_range, other_user_same_date])

        stats = _deidentify_raw_blobs(bucket, uid, dates=["2026-08-01"])

        self.assertEqual(stats["raw_blobs_matched"], 1)
        self.assertTrue(in_range.deleted)
        self.assertFalse(out_of_range.deleted, "범위 밖 파일은 건드리면 안 됨")
        self.assertFalse(other_user_same_date.deleted)

        # 정확히 uid+날짜로 좁힌 prefix로만 리스트했는지(다른 유저/전체
        # signals/raw/ 를 통째로 리스트하지 않음 = 리스트 오퍼레이션 절감).
        self.assertEqual(
            bucket.list_calls, [f"signals/raw/2026-08-01/{uid}/"]
        )

    def test_processed_bounded_scan_skips_out_of_range_partition(self) -> None:
        uid = "targetUser"
        in_range = _FakeBlob(
            "signals/processed/dt=2026-08-01/events.jsonl.gz",
            _gzip_jsonl_lines(
                [json.dumps({"eventId": "e1", "userId": uid})]
            ),
        )
        # 가입일 이전 파티션에 우연히 같은 uid 문자열이 있어도(이론상
        # 불가능하지만) 범위 밖이면 다운로드조차 하지 않아야 한다.
        out_of_range = _FakeBlob(
            "signals/processed/dt=2019-01-01/events.jsonl.gz",
            _gzip_jsonl_lines(
                [json.dumps({"eventId": "e0", "userId": uid})]
            ),
        )
        bucket = _FakeBucket([in_range, out_of_range])

        stats = _deidentify_processed_blobs(
            bucket, uid, dates=["2026-08-01"]
        )

        self.assertEqual(stats["processed_blobs_rewritten"], 1)
        self.assertEqual(stats["processed_events_deidentified"], 1)
        # 범위 밖 파티션은 리스트도, 다운로드도, 재업로드도 안 됐어야 한다.
        self.assertEqual(len(out_of_range.uploads), 0)
        rewritten_text = gzip.decompress(in_range._data).decode("utf-8")
        self.assertIn("deidentified", rewritten_text)
        original_out_of_range_text = gzip.decompress(
            out_of_range._data
        ).decode("utf-8")
        self.assertIn(uid, original_out_of_range_text)  # 그대로 남아있음

        self.assertEqual(
            bucket.list_calls, ["signals/processed/dt=2026-08-01/"]
        )

    def test_fallback_full_scan_still_works_without_dates(self) -> None:
        """dates=None이면 여전히 signals/processed/ 전체를 리스트한다
        (계정 생성일을 모를 때의 안전망 — 정확성 우선 폴백)."""
        uid = "targetUser"
        blob = _FakeBlob(
            "signals/processed/dt=2019-01-01/events.jsonl.gz",
            _gzip_jsonl_lines([json.dumps({"eventId": "e0", "userId": uid})]),
        )
        bucket = _FakeBucket([blob])
        stats = _deidentify_processed_blobs(bucket, uid, dates=None)
        self.assertEqual(stats["processed_blobs_rewritten"], 1)
        self.assertEqual(bucket.list_calls, ["signals/processed/"])


if __name__ == "__main__":
    unittest.main()
