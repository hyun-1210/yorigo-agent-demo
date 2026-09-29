"""Firestore 분산 스케줄 가드 단위 테스트."""

from __future__ import annotations

import unittest
import time
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from utils.firestore_schedule_guard import (
    ScheduleLeaseHeartbeat,
    _lease_decision,
    complete_schedule_lease,
    fail_schedule_lease,
    renew_schedule_lease,
    try_acquire_schedule_lease,
)


class _Snapshot:
    def __init__(self, data: dict | None) -> None:
        self.exists = data is not None
        self._data = data

    def to_dict(self) -> dict:
        return dict(self._data or {})


class _Ref:
    def __init__(self, data: dict | None = None) -> None:
        self.data = dict(data or {})

    def get(self, transaction=None) -> _Snapshot:
        _ = transaction
        return _Snapshot(self.data if self.data else None)


class _Collection:
    def __init__(self, ref: _Ref) -> None:
        self.ref = ref

    def document(self, name: str) -> _Ref:
        _ = name
        return self.ref


class _Transaction:
    def set(self, ref: _Ref, payload: dict, merge: bool = False) -> None:
        if not merge:
            ref.data = {}
        ref.data.update(payload)


class _DB:
    def __init__(self, data: dict | None = None) -> None:
        self.ref = _Ref(data)

    def collection(self, name: str) -> _Collection:
        self.collection_name = name
        return _Collection(self.ref)

    def transaction(self) -> _Transaction:
        return _Transaction()


def _identity_transactional(fn):
    return fn


class FirestoreScheduleGuardTests(unittest.TestCase):
    def test_decision_blocks_active_lease(self) -> None:
        now = datetime.now(timezone.utc)
        acquired, retry_after = _lease_decision(
            {"leaseUntil": now + timedelta(seconds=120)},
            now=now,
            interval_seconds=86400,
        )
        self.assertFalse(acquired)
        self.assertGreaterEqual(retry_after, 119)

    def test_decision_blocks_recent_completion(self) -> None:
        now = datetime.now(timezone.utc)
        acquired, retry_after = _lease_decision(
            {"lastCompletedAt": now - timedelta(hours=1)},
            now=now,
            interval_seconds=24 * 60 * 60,
        )
        self.assertFalse(acquired)
        self.assertGreater(retry_after, 22 * 60 * 60)

    def test_decision_allows_expired_state(self) -> None:
        now = datetime.now(timezone.utc)
        acquired, retry_after = _lease_decision(
            {
                "leaseUntil": now - timedelta(seconds=1),
                "lastCompletedAt": now - timedelta(days=2),
            },
            now=now,
            interval_seconds=24 * 60 * 60,
        )
        self.assertTrue(acquired)
        self.assertEqual(retry_after, 0)

    @patch(
        "utils.firestore_schedule_guard.admin_firestore.transactional",
        side_effect=_identity_transactional,
    )
    def test_acquire_complete_and_reacquire_guard(self, _transactional) -> None:
        db = _DB()
        lease = try_acquire_schedule_lease(
            db,
            "test_schedule",
            interval_seconds=86400,
            lease_seconds=300,
        )
        self.assertTrue(lease.acquired)
        self.assertIsNotNone(lease.token)
        self.assertEqual(db.ref.data["status"], "running")

        blocked = try_acquire_schedule_lease(
            db,
            "test_schedule",
            interval_seconds=86400,
            lease_seconds=300,
        )
        self.assertFalse(blocked.acquired)

        self.assertTrue(complete_schedule_lease(db, "test_schedule", lease.token or ""))
        self.assertEqual(db.ref.data["status"], "idle")
        self.assertIsNone(db.ref.data["leaseToken"])

    @patch(
        "utils.firestore_schedule_guard.admin_firestore.transactional",
        side_effect=_identity_transactional,
    )
    def test_wrong_token_cannot_complete_or_release(self, _transactional) -> None:
        db = _DB({"leaseToken": "current"})
        self.assertFalse(complete_schedule_lease(db, "test", "stale"))
        self.assertFalse(fail_schedule_lease(db, "test", "stale", "error"))
        self.assertEqual(db.ref.data["leaseToken"], "current")

    @patch(
        "utils.firestore_schedule_guard.admin_firestore.transactional",
        side_effect=_identity_transactional,
    )
    def test_failure_releases_current_lease(self, _transactional) -> None:
        db = _DB({"leaseToken": "current"})
        self.assertTrue(fail_schedule_lease(db, "test", "current", "temporary"))
        self.assertIsNone(db.ref.data["leaseToken"])
        self.assertEqual(db.ref.data["status"], "failed")

    @patch(
        "utils.firestore_schedule_guard.admin_firestore.transactional",
        side_effect=_identity_transactional,
    )
    def test_renew_extends_only_current_token(self, _transactional) -> None:
        db = _DB({"leaseToken": "current"})
        self.assertFalse(
            renew_schedule_lease(
                db,
                "test",
                "stale",
                lease_seconds=300,
            )
        )
        self.assertTrue(
            renew_schedule_lease(
                db,
                "test",
                "current",
                lease_seconds=300,
            )
        )
        self.assertIsInstance(db.ref.data["leaseUntil"], datetime)

    @patch(
        "utils.firestore_schedule_guard.renew_schedule_lease",
        return_value=False,
    )
    def test_heartbeat_exposes_lost_token(self, _renew) -> None:
        heartbeat = ScheduleLeaseHeartbeat(
            _DB(),
            "test",
            "token",
            lease_seconds=300,
        )
        heartbeat._interval_seconds = 0.01
        heartbeat.start()
        deadline = time.monotonic() + 1.0
        while not heartbeat.lease_lost and time.monotonic() < deadline:
            time.sleep(0.01)
        heartbeat.stop()
        self.assertTrue(heartbeat.lease_lost)


if __name__ == "__main__":
    unittest.main()
