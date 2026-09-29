"""일일 레시피 DB 스냅샷 → Mixpanel 전송 스케줄러.

하루 1회 Firestore 에서 유효한(completed + non-hidden) 레시피 수를 집계하고
``daily_recipe_db_snapshot`` 이벤트를 Mixpanel 에 전송한다.
"""

import logging
import os
import time
from collections import defaultdict
from typing import Any, Callable, Optional

from utils.firestore_schedule_guard import (
    ScheduleLeaseHeartbeat,
    complete_schedule_lease,
    fail_schedule_lease,
    try_acquire_schedule_lease,
)

logger = logging.getLogger(__name__)

_SNAPSHOT_INTERVAL_SECONDS = 24 * 60 * 60  # 24시간
_INITIAL_DELAY_SECONDS = 60  # 서버 기동 직후 1분 대기
_SCHEDULE_NAME = "recipe_snapshot"


def _count_unique_recipes(
    db: Any,
    should_stop: Optional[Callable[[], bool]] = None,
) -> dict[str, Any]:
    """Firestore 에서 유효한 고유 레시피 수를 집계한다.

    Returns:
        total_unique_recipes, recipes_by_platform 등을 담은 dict.
    """
    seen_keys: set[str] = set()
    platform_counts: dict[str, int] = defaultdict(int)
    total = 0

    try:
        stream = (
            db.collection("recipes")
            .where("status", "==", "completed")
            .where("isHidden", "==", False)
            .select(["sourceKey", "sourceUrl", "source.platform"])
            .stream()
        )
        for doc in stream:
            if should_stop is not None and should_stop():
                raise RuntimeError("recipe snapshot lease lost during scan")
            data = doc.to_dict() or {}
            key = data.get("sourceKey") or data.get("sourceUrl") or doc.id
            if key in seen_keys:
                continue
            seen_keys.add(key)
            total += 1

            source = data.get("source")
            if isinstance(source, dict):
                plat = source.get("platform", "unknown")
            else:
                plat = "unknown"
            platform_counts[plat] += 1
    except Exception as e:
        logger.error("[RecipeSnapshot] Firestore 조회 실패: %s", e)
        return {"total_unique_recipes": -1}

    return {
        "total_unique_recipes": total,
        **{f"recipes_{k}": v for k, v in platform_counts.items()},
    }


def run_recipe_snapshot_scheduler(db: Any) -> None:
    """데몬 스레드 진입점. 24시간 주기로 스냅샷을 전송한다."""
    from services.mixpanel_service import get_mixpanel_service

    interval_seconds = max(
        60,
        int(os.getenv("RECIPE_SNAPSHOT_INTERVAL_SECONDS", str(_SNAPSHOT_INTERVAL_SECONDS))),
    )
    lease_seconds = max(
        300,
        int(os.getenv("RECIPE_SNAPSHOT_LEASE_SECONDS", str(2 * 60 * 60))),
    )
    failure_retry_seconds = max(
        60,
        int(os.getenv("RECIPE_SNAPSHOT_FAILURE_RETRY_SECONDS", "300")),
    )
    time.sleep(_INITIAL_DELAY_SECONDS)
    logger.info("[RecipeSnapshot] 스케줄러 시작 (주기=%ds)", interval_seconds)

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
                    "[RecipeSnapshot] schedule guard로 건너뜀 (retry_after=%.0fs)",
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
            mp = get_mixpanel_service()
            if not mp.enabled:
                logger.info("[RecipeSnapshot] Mixpanel 비활성 — 건너뜀")
            else:
                counts = _count_unique_recipes(
                    db,
                    should_stop=lambda: (
                        heartbeat is not None and heartbeat.lease_lost
                    ),
                )
                if counts.get("total_unique_recipes", -1) < 0:
                    raise RuntimeError("Firestore recipe snapshot query failed")
                if heartbeat.lease_lost:
                    raise RuntimeError("recipe snapshot lease lost before Mixpanel send")
                mp.track("system_daily_snapshot", "daily_recipe_db_snapshot", counts)
                logger.info(
                    "[RecipeSnapshot] 전송 완료: %d 고유 레시피",
                    counts["total_unique_recipes"],
                )
            heartbeat.stop()
            heartbeat = None
            if not complete_schedule_lease(db, _SCHEDULE_NAME, lease_token):
                logger.warning(
                    "[RecipeSnapshot] lease 완료 처리를 건너뜀 (token no longer current)"
                )
        except Exception as e:
            logger.exception("[RecipeSnapshot] 스냅샷 전송 실패: %s", e)
            next_sleep = float(failure_retry_seconds)
            if heartbeat:
                heartbeat.stop()
            if lease_token:
                try:
                    fail_schedule_lease(db, _SCHEDULE_NAME, lease_token, str(e))
                except Exception:
                    logger.exception("[RecipeSnapshot] schedule lease 해제 실패")

        time.sleep(max(60.0, next_sleep))
