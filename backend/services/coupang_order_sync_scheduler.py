"""쿠팡 주문 리포트 → 계정 매칭 스케줄러."""

from __future__ import annotations

import logging
import os
import time
from typing import Any

from utils.firestore_schedule_guard import (
    ScheduleLeaseHeartbeat,
    complete_schedule_lease,
    fail_schedule_lease,
    try_acquire_schedule_lease,
)

logger = logging.getLogger(__name__)

_SCHEDULE_NAME = "coupang_order_sync"
_DEFAULT_INTERVAL_SECONDS = 6 * 60 * 60
_INITIAL_DELAY_SECONDS = 90


def run_coupang_order_sync_scheduler(db: Any) -> None:
    """데몬 스레드 진입점. 기본 6시간마다 최근 주문 창을 동기화한다."""
    from services.coupang_order_attribution_service import CoupangOrderAttributionService

    interval_seconds = max(
        60,
        int(os.getenv("COUPANG_ORDER_SYNC_INTERVAL_SECONDS", str(_DEFAULT_INTERVAL_SECONDS))),
    )
    lease_seconds = max(
        300,
        int(os.getenv("COUPANG_ORDER_SYNC_LEASE_SECONDS", str(30 * 60))),
    )
    failure_retry_seconds = max(
        60,
        int(os.getenv("COUPANG_ORDER_SYNC_FAILURE_RETRY_SECONDS", "300")),
    )
    time.sleep(_INITIAL_DELAY_SECONDS)
    logger.info("[CoupangOrderSync] 스케줄러 시작 (주기=%ds)", interval_seconds)

    service = CoupangOrderAttributionService(db)
    while True:
        lease_token: str | None = None
        heartbeat: ScheduleLeaseHeartbeat | None = None
        next_sleep = float(interval_seconds)
        try:
            lease = try_acquire_schedule_lease(
                db,
                _SCHEDULE_NAME,
                interval_seconds=interval_seconds,
                lease_seconds=lease_seconds,
            )
            if not lease.acquired or not lease.token:
                next_sleep = max(60.0, lease.retry_after_seconds)
                logger.info(
                    "[CoupangOrderSync] schedule guard로 건너뜀 (retry_after=%.0fs)",
                    next_sleep,
                )
                time.sleep(next_sleep)
                continue

            lease_token = lease.token
            heartbeat = ScheduleLeaseHeartbeat(
                db,
                _SCHEDULE_NAME,
                lease_token,
                lease_seconds=lease_seconds,
            )
            heartbeat.start()
            service.sync_recent_window()
            if heartbeat.lease_lost:
                raise RuntimeError("coupang order sync lease lost")
            heartbeat.stop()
            heartbeat = None
            if not complete_schedule_lease(db, _SCHEDULE_NAME, lease_token):
                logger.warning(
                    "[CoupangOrderSync] lease 완료 처리를 건너뜀 (token no longer current)"
                )
        except Exception as e:
            logger.exception("[CoupangOrderSync] 동기화 실패: %s", e)
            next_sleep = float(failure_retry_seconds)
            if heartbeat:
                heartbeat.stop()
            if lease_token:
                try:
                    fail_schedule_lease(db, _SCHEDULE_NAME, lease_token, str(e))
                except Exception:
                    logger.exception("[CoupangOrderSync] schedule lease 해제 실패")

        time.sleep(max(60.0, next_sleep))
