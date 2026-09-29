"""
파싱용 적응형(adaptive) 프록시 관리자.

전략:
- 평소에는 서버(맥미니)의 집 IP로 파싱한다 (무료·빠름·신뢰도 높음).
- 차단 신호(봇 탐지 / 429 / 403 / 로그인월 / captcha)가 감지되면 해당 플랫폼을
  일정 시간(cooldown) 동안 "프록시 모드"로 전환한다.
- cooldown 동안 들어오는 요청은 처음부터 프록시로 나가 집 IP를 식힌다.
- cooldown 종료 후에는 다시 집 IP를 우선 사용(probation)하고, 또 막히면 cooldown을
  더 길게 연장한다.

이 모듈은 IP 레벨의 상태만 관리하며, 실제 프록시 주입은 youtube_service가 담당한다.
TikTok은 RapidAPI 전용(proxy=off 정책)이라 이 관리자의 대상이 아니다.
"""

import os
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Dict, Optional

# 차단으로 간주할 키워드 (cookie_manager의 봇 탐지 키워드와 동일 계열)
_BLOCK_KEYWORDS = (
    "bot",
    "captcha",
    "sign in to confirm",
    "too many requests",
    "forbidden",
    "403",
    "429",
    "rate-limit",
    "rate limit",
    "login required",
    "login_required",
    "please log in",
    "requested content is not available",
    "checkpoint",
    "challenge",
)

# 프록시 적용 대상 플랫폼
_SUPPORTED_PLATFORMS = ("instagram", "youtube")


@dataclass
class _PlatformState:
    """플랫폼별 프록시 cooldown 상태."""

    blocked_until: Optional[datetime] = None
    consecutive_blocks: int = 0
    total_blocks: int = 0
    last_block_at: Optional[datetime] = None


class ProxyManager:
    """파싱 차단 대응용 적응형 프록시 상태 관리자 (스레드 안전)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._state: Dict[str, _PlatformState] = {
            p: _PlatformState() for p in _SUPPORTED_PLATFORMS
        }

    # ── 설정 ─────────────────────────────────────────────────────────
    def _base_cooldown_minutes(self) -> float:
        """기본 cooldown 길이(분). 연속 차단 시 이 값의 배수로 연장된다."""
        try:
            return max(1.0, float(os.getenv("PARSE_PROXY_COOLDOWN_MINUTES", "20")))
        except (TypeError, ValueError):
            return 20.0

    def _max_cooldown_minutes(self) -> float:
        try:
            return max(
                self._base_cooldown_minutes(),
                float(os.getenv("PARSE_PROXY_MAX_COOLDOWN_MINUTES", "120")),
            )
        except (TypeError, ValueError):
            return 120.0

    def get_proxy_url(self, platform: Optional[str]) -> Optional[str]:
        """플랫폼별 프록시 URL을 반환.

        우선순위: 플랫폼 전용 env → 공용 PARSE_PROXY_URL.
        값이 없으면 None (프록시 미설정).
        """
        if platform == "instagram":
            specific = (os.getenv("INSTAGRAM_PROXY_URL") or "").strip()
            if specific:
                return specific
        elif platform == "youtube":
            specific = (os.getenv("YOUTUBE_PROXY_URL") or "").strip()
            if specific:
                return specific
        shared = (os.getenv("PARSE_PROXY_URL") or "").strip()
        return shared or None

    def is_enabled(self, platform: Optional[str]) -> bool:
        """해당 플랫폼에 프록시 폴백이 활성화되어 있는지.

        프록시 URL이 설정되어 있고, PARSE_PROXY_ENABLED가 false가 아니면 활성.
        """
        if platform not in _SUPPORTED_PLATFORMS:
            return False
        if (os.getenv("PARSE_PROXY_ENABLED", "true").strip().lower()) == "false":
            return False
        return bool(self.get_proxy_url(platform))

    # ── 차단 판정 ────────────────────────────────────────────────────
    @staticmethod
    def is_block_error(error_msg: Optional[str]) -> bool:
        """에러 메시지가 IP/봇 차단 계열인지 판정."""
        if not error_msg:
            return False
        low = str(error_msg).lower()
        return any(k in low for k in _BLOCK_KEYWORDS)

    @staticmethod
    def platform_from_url(url: Optional[str]) -> Optional[str]:
        """원본 URL에서 플랫폼 추론 (instagram/youtube/None)."""
        low = (url or "").lower()
        if "instagram.com" in low or "instagr.am" in low:
            return "instagram"
        if "youtube.com" in low or "youtu.be" in low:
            return "youtube"
        return None

    @staticmethod
    def platform_from_cdn_url(cdn_url: Optional[str]) -> Optional[str]:
        """CDN(직접 다운로드) URL에서 플랫폼 추론.

        TikTok CDN은 대상이 아니므로 None을 반환한다(프록시 미적용 → proxy=off 유지).
        """
        low = (cdn_url or "").lower()
        if "cdninstagram" in low or "fbcdn" in low or "instagram" in low:
            return "instagram"
        if "googlevideo" in low or "youtube" in low or "ytimg" in low:
            return "youtube"
        return None

    # ── 상태 조회/변경 ───────────────────────────────────────────────
    def should_use_proxy(self, platform: Optional[str]) -> bool:
        """현재 해당 플랫폼이 프록시 cooldown 중인지 (프록시로 나가야 하는지)."""
        if not self.is_enabled(platform):
            return False
        with self._lock:
            st = self._state[platform]
            if st.blocked_until and datetime.now() < st.blocked_until:
                return True
        return False

    def resolve_proxy_for_url(self, url: Optional[str]) -> Optional[str]:
        """원본 URL 기준: cooldown 중이면 프록시 URL, 아니면 None."""
        platform = self.platform_from_url(url)
        if self.should_use_proxy(platform):
            return self.get_proxy_url(platform)
        return None

    def resolve_proxy_for_cdn(self, cdn_url: Optional[str]) -> Optional[str]:
        """CDN URL 기준: 해당 플랫폼이 cooldown 중이면 프록시 URL, 아니면 None."""
        platform = self.platform_from_cdn_url(cdn_url)
        if self.should_use_proxy(platform):
            return self.get_proxy_url(platform)
        return None

    def note_block(self, platform: Optional[str]) -> Optional[datetime]:
        """차단 감지 → 프록시 cooldown 진입/연장. 새 blocked_until 반환."""
        if platform not in _SUPPORTED_PLATFORMS:
            return None
        with self._lock:
            st = self._state[platform]
            st.consecutive_blocks += 1
            st.total_blocks += 1
            st.last_block_at = datetime.now()
            # 연속 차단 시 cooldown을 선형 연장 (상한 적용)
            minutes = min(
                self._base_cooldown_minutes() * st.consecutive_blocks,
                self._max_cooldown_minutes(),
            )
            st.blocked_until = datetime.now() + timedelta(minutes=minutes)
            print(
                f"🛡️  [ProxyManager] {platform} 차단 감지 → 프록시 모드 {minutes:.0f}분 "
                f"(연속 {st.consecutive_blocks}회, blocked_until={st.blocked_until:%H:%M:%S})",
                flush=True,
            )
            return st.blocked_until

    def note_success(self, platform: Optional[str], used_proxy: bool) -> None:
        """성공 기록.

        - 집 IP(used_proxy=False)로 성공 → 집 IP 회복으로 보고 cooldown 해제.
        - 프록시로 성공 → 집 IP는 아직 식히는 중이므로 cooldown 유지.
        """
        if platform not in _SUPPORTED_PLATFORMS:
            return
        if used_proxy:
            return
        with self._lock:
            st = self._state[platform]
            if st.blocked_until or st.consecutive_blocks:
                print(
                    f"✅ [ProxyManager] {platform} 집 IP 성공 → 프록시 모드 해제",
                    flush=True,
                )
            st.blocked_until = None
            st.consecutive_blocks = 0

    def get_status(self) -> Dict[str, Dict[str, object]]:
        """모니터링용 상태 스냅샷."""
        now = datetime.now()
        with self._lock:
            out: Dict[str, Dict[str, object]] = {}
            for platform, st in self._state.items():
                active = bool(st.blocked_until and now < st.blocked_until)
                out[platform] = {
                    "enabled": self.is_enabled(platform),
                    "proxy_active": active,
                    "blocked_until": (
                        st.blocked_until.isoformat() if st.blocked_until else None
                    ),
                    "consecutive_blocks": st.consecutive_blocks,
                    "total_blocks": st.total_blocks,
                    "last_block_at": (
                        st.last_block_at.isoformat() if st.last_block_at else None
                    ),
                }
            return out


# 싱글톤
_proxy_manager = ProxyManager()


def get_proxy_manager() -> ProxyManager:
    """전역 ProxyManager 싱글톤 반환."""
    return _proxy_manager
