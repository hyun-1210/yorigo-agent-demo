"""서버 사이드 Mixpanel 이벤트 트래킹 서비스.

Mixpanel HTTP Tracking API 를 사용하여 파싱 결과, 데이터베이스 스냅샷 등
백엔드에서만 알 수 있는 이벤트를 fire-and-forget 으로 전송한다.
"""

import base64
import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

_TRACK_URL = "https://api.mixpanel.com/track"
_MAX_WORKERS = 2
_TIMEOUT_SECONDS = 10


class MixpanelService:
    """Mixpanel HTTP Tracking API 래퍼 (싱글톤)."""

    def __init__(self) -> None:
        self._token: str = os.getenv("MIXPANEL_PROJECT_TOKEN", "").strip()
        self._pool: Optional[ThreadPoolExecutor] = None
        if self._token:
            self._pool = ThreadPoolExecutor(
                max_workers=_MAX_WORKERS,
                thread_name_prefix="mixpanel",
            )
            logger.info("[MixpanelService] 초기화 완료 (토큰 설정됨)")
        else:
            logger.warning(
                "[MixpanelService] MIXPANEL_PROJECT_TOKEN 미설정 — 이벤트 전송 비활성"
            )

    @property
    def enabled(self) -> bool:
        return bool(self._token)

    def track(
        self,
        distinct_id: str,
        event: str,
        properties: Optional[dict[str, Any]] = None,
    ) -> None:
        """이벤트를 Mixpanel 에 fire-and-forget 으로 전송한다.

        Args:
            distinct_id: 사용자 식별자 (user_id 또는 시스템 식별자).
            event: 이벤트 이름.
            properties: 이벤트 속성 dict.
        """
        if not self._token or not self._pool:
            return

        payload = {
            "event": event,
            "properties": {
                "token": self._token,
                "distinct_id": distinct_id,
                "time": int(time.time()),
                **(properties or {}),
            },
        }
        self._pool.submit(self._send, payload)

    def _send(self, payload: dict) -> None:
        """동기 HTTP POST — 스레드풀에서 실행."""
        try:
            data_b64 = base64.b64encode(
                json.dumps([payload]).encode()
            ).decode()
            resp = httpx.post(
                _TRACK_URL,
                data={"data": data_b64},
                timeout=_TIMEOUT_SECONDS,
            )
            if resp.status_code != 200 or resp.text.strip() != "1":
                logger.warning(
                    "[MixpanelService] 전송 실패: status=%s body=%s event=%s",
                    resp.status_code,
                    resp.text[:200],
                    payload.get("event"),
                )
        except Exception as e:
            logger.warning("[MixpanelService] 전송 예외: %s", e)


_mixpanel_service: Optional[MixpanelService] = None


def get_mixpanel_service() -> MixpanelService:
    """싱글톤 MixpanelService 인스턴스를 반환한다."""
    global _mixpanel_service
    if _mixpanel_service is None:
        _mixpanel_service = MixpanelService()
    return _mixpanel_service
