"""Firestore 기반 분산 스케줄 실행 간격/리스 보호."""

from __future__ import annotations

import logging
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from firebase_admin import firestore as admin_firestore


SCHEDULE_COLLECTION = "system_schedules"
logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ScheduleLease:
    """스케줄 실행권 획득 결과."""

    acquired: bool
    token: Optional[str]
    retry_after_seconds: float


def _as_utc(value: Any) -> Optional[datetime]:
    """Firestore datetime 값을 UTC aware datetime으로 정규화한다."""
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _lease_decision(
    data: dict[str, Any],
    *,
    now: datetime,
    interval_seconds: float,
) -> tuple[bool, float]:
    """현재 상태에서 실행 가능 여부와 다음 확인까지의 초를 계산한다."""
    lease_until = _as_utc(data.get("leaseUntil"))
    if lease_until is not None and lease_until > now:
        return False, max(1.0, (lease_until - now).total_seconds())

    last_completed = _as_utc(data.get("lastCompletedAt"))
    if last_completed is not None:
        next_run = last_completed + timedelta(seconds=max(0.0, interval_seconds))
        if next_run > now:
            return False, max(1.0, (next_run - now).total_seconds())

    return True, 0.0


def try_acquire_schedule_lease(
    db: Any,
    schedule_name: str,
    *,
    interval_seconds: float,
    lease_seconds: float,
) -> ScheduleLease:
    """트랜잭션으로 스케줄 실행권을 획득한다.

    여러 Railway replica가 동시에 시도해도 하나만 lease token을 받는다.
    완료 시각 기준 interval이 지나지 않았거나 기존 lease가 살아 있으면
    읽기만 하고 다음 확인 권장 시간을 반환한다.
    """
    ref = db.collection(SCHEDULE_COLLECTION).document(schedule_name)
    token = uuid.uuid4().hex
    now = datetime.now(timezone.utc)
    transaction = db.transaction()

    @admin_firestore.transactional
    def _claim(txn: Any) -> ScheduleLease:
        snapshot = ref.get(transaction=txn)
        data = snapshot.to_dict() or {} if snapshot.exists else {}
        acquired, retry_after = _lease_decision(
            data,
            now=now,
            interval_seconds=interval_seconds,
        )
        if not acquired:
            return ScheduleLease(False, None, retry_after)

        txn.set(
            ref,
            {
                "leaseToken": token,
                "leaseUntil": now + timedelta(seconds=max(1.0, lease_seconds)),
                "lastStartedAt": admin_firestore.SERVER_TIMESTAMP,
                "status": "running",
                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return ScheduleLease(True, token, 0.0)

    return _claim(transaction)


def complete_schedule_lease(
    db: Any,
    schedule_name: str,
    token: str,
) -> bool:
    """현재 token의 실행을 완료 처리한다. 다른 실행의 lease는 덮지 않는다."""
    ref = db.collection(SCHEDULE_COLLECTION).document(schedule_name)
    transaction = db.transaction()

    @admin_firestore.transactional
    def _complete(txn: Any) -> bool:
        snapshot = ref.get(transaction=txn)
        data = snapshot.to_dict() or {} if snapshot.exists else {}
        if data.get("leaseToken") != token:
            return False
        txn.set(
            ref,
            {
                "leaseToken": None,
                "leaseUntil": None,
                "lastCompletedAt": admin_firestore.SERVER_TIMESTAMP,
                "status": "idle",
                "lastError": None,
                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return True

    return _complete(transaction)


def renew_schedule_lease(
    db: Any,
    schedule_name: str,
    token: str,
    *,
    lease_seconds: float,
) -> bool:
    """현재 token의 lease 만료 시각을 연장한다."""
    ref = db.collection(SCHEDULE_COLLECTION).document(schedule_name)
    transaction = db.transaction()
    now = datetime.now(timezone.utc)

    @admin_firestore.transactional
    def _renew(txn: Any) -> bool:
        snapshot = ref.get(transaction=txn)
        data = snapshot.to_dict() or {} if snapshot.exists else {}
        if data.get("leaseToken") != token:
            return False
        txn.set(
            ref,
            {
                "leaseUntil": now + timedelta(seconds=max(1.0, lease_seconds)),
                "lastHeartbeatAt": admin_firestore.SERVER_TIMESTAMP,
                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return True

    return _renew(transaction)


class ScheduleLeaseHeartbeat:
    """장시간 작업 중 lease 만료를 막는 daemon heartbeat."""

    def __init__(
        self,
        db: Any,
        schedule_name: str,
        token: str,
        *,
        lease_seconds: float,
    ) -> None:
        self._db = db
        self._schedule_name = schedule_name
        self._token = token
        self._lease_seconds = max(1.0, lease_seconds)
        self._interval_seconds = max(
            30.0,
            min(300.0, self._lease_seconds / 3.0),
        )
        self._stop_event = threading.Event()
        self._lease_lost_event = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name=f"ScheduleLeaseHeartbeat-{schedule_name}",
        )

    def start(self) -> None:
        """Heartbeat 스레드를 시작한다."""
        self._thread.start()

    def stop(self) -> None:
        """Heartbeat를 중단하고 짧게 종료를 기다린다."""
        self._stop_event.set()
        self._thread.join(timeout=1.0)

    @property
    def lease_lost(self) -> bool:
        """다른 실행이 token을 가져갔는지 반환한다."""
        return self._lease_lost_event.is_set()

    def _run(self) -> None:
        while not self._stop_event.wait(self._interval_seconds):
            try:
                renewed = renew_schedule_lease(
                    self._db,
                    self._schedule_name,
                    self._token,
                    lease_seconds=self._lease_seconds,
                )
                if not renewed:
                    self._lease_lost_event.set()
                    logger.warning(
                        "[ScheduleGuard] heartbeat stopped: token lost (%s)",
                        self._schedule_name,
                    )
                    return
            except Exception:
                # 일시 오류 한 번으로 실행권을 포기하지 않고 다음 heartbeat에서 재시도.
                logger.exception(
                    "[ScheduleGuard] heartbeat failed (%s)",
                    self._schedule_name,
                )


def fail_schedule_lease(
    db: Any,
    schedule_name: str,
    token: str,
    error: str,
) -> bool:
    """실패한 실행의 lease를 즉시 해제해 다음 루프에서 복구 가능하게 한다."""
    ref = db.collection(SCHEDULE_COLLECTION).document(schedule_name)
    transaction = db.transaction()

    @admin_firestore.transactional
    def _fail(txn: Any) -> bool:
        snapshot = ref.get(transaction=txn)
        data = snapshot.to_dict() or {} if snapshot.exists else {}
        if data.get("leaseToken") != token:
            return False
        txn.set(
            ref,
            {
                "leaseToken": None,
                "leaseUntil": None,
                "status": "failed",
                "lastError": str(error)[:1000],
                "lastFailedAt": admin_firestore.SERVER_TIMESTAMP,
                "updatedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return True

    return _fail(transaction)
