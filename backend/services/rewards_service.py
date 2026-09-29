"""
리워드(EXP/포인트) 적립 서비스 — 구매완료 사진 인증(Gemini Vision 검증) 전용.

일반 행동(출석/장바구니/좋아요/댓글/게시물 등)의 EXP·포인트 청구는 이제
Firebase Cloud Functions(yorigo-frontend/functions/rewards.js)가 담당한다 —
Firestore와 같은 프로젝트라 Railway 백엔드 왕복보다 훨씬 빠르고 저렴하고,
EXP/포인트 모두 아직 소비처가 없어(적립+랭킹만) 남용돼도 실질 피해가 없기
때문이다. 이 Python 서비스는 Gemini Vision으로 주문확인 스크린샷을 분석해야
하는 points_purchase_photo_verified와 그 자가신고 하향 케이스만 지급한다
(routers/purchase_verification.py에서만 호출됨).

**중요**: 아래 REWARD_CATALOG/원장 스키마(exp_ledger, points_ledger,
daily_action_counters, weekly_point_counters, users/{uid}의 expTotal·level·
pointsBalance·pointsLifetimeEarned 필드)는 Cloud Functions 쪽 카탈로그와
반드시 동일하게 유지해야 한다 — 두 구현이 같은 문서를 공유한다.

지급 단위 원칙: 한 자릿수 지급은 지양하고 10 단위 이상의 "딱 떨어지는" 값만
사용한다 (기획 문서 EXP-포인트 리워드 시스템 §1 참고).
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, Optional

from firebase_admin import firestore

from services.firebase_service import get_firebase_service

logger = logging.getLogger(__name__)


class RewardTrack(str, Enum):
    EXP = "exp"
    POINTS = "points"


@dataclass(frozen=True)
class RewardActionConfig:
    track: RewardTrack
    amount: int
    daily_limit: Optional[int] = None  # None = 이 카운터로는 제한하지 않음(1회성 등은 idempotency_key로 제한)
    weekly_capped: bool = False  # 무검증/자가신고성 행동만 True (주간 총량 캡 대상)
    new_account_dampening: bool = True  # 가입 3일 이내 지급률 50%


# ── 행동 카탈로그 (기획서 §2/§3 그대로 반영) ────────────────────────────
REWARD_CATALOG: Dict[str, RewardActionConfig] = {
    # ---- EXP: 앱 사용 전반, 넓고 얕게 ----
    "exp_recipe_viewed": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=20, new_account_dampening=False),
    "exp_search": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=10, new_account_dampening=False),
    "exp_fridge_ingredient_added": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=10, new_account_dampening=False),
    "exp_follow": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=5, new_account_dampening=False),
    "exp_session_start": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=1, new_account_dampening=False),
    "exp_recipe_bookmarked": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=10, new_account_dampening=False),
    "exp_cooking_started": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=3, new_account_dampening=False),
    "exp_meal_calendar_used": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=5, new_account_dampening=False),
    "exp_cooking_completed": RewardActionConfig(RewardTrack.EXP, 30, daily_limit=2, new_account_dampening=False),
    "exp_cooking_logged": RewardActionConfig(RewardTrack.EXP, 50, daily_limit=8, new_account_dampening=False),
    "exp_cooking_logged_text": RewardActionConfig(RewardTrack.EXP, 30, daily_limit=8, new_account_dampening=False),
    "exp_recipe_parsed": RewardActionConfig(RewardTrack.EXP, 30, daily_limit=5, new_account_dampening=False),
    "exp_recipe_registered": RewardActionConfig(RewardTrack.EXP, 50, daily_limit=3, new_account_dampening=False),
    "exp_profile_completed": RewardActionConfig(RewardTrack.EXP, 100, daily_limit=1, new_account_dampening=False),
    "exp_attendance": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=1, new_account_dampening=False),
    "exp_streak_3": RewardActionConfig(RewardTrack.EXP, 30, new_account_dampening=False),
    "exp_streak_7": RewardActionConfig(RewardTrack.EXP, 70, new_account_dampening=False),
    "exp_streak_14": RewardActionConfig(RewardTrack.EXP, 150, new_account_dampening=False),
    "exp_streak_30": RewardActionConfig(RewardTrack.EXP, 300, new_account_dampening=False),
    "exp_like": RewardActionConfig(RewardTrack.EXP, 10, daily_limit=15, new_account_dampening=False),
    "exp_comment": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=10, new_account_dampening=False),
    "exp_post_created": RewardActionConfig(RewardTrack.EXP, 40, daily_limit=3, new_account_dampening=False),
    "exp_post_created_short": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=3, new_account_dampening=False),
    "exp_likes_10": RewardActionConfig(RewardTrack.EXP, 50, new_account_dampening=False),
    "exp_likes_30": RewardActionConfig(RewardTrack.EXP, 100, new_account_dampening=False),
    "exp_comments_5": RewardActionConfig(RewardTrack.EXP, 50, new_account_dampening=False),
    "exp_comments_15": RewardActionConfig(RewardTrack.EXP, 100, new_account_dampening=False),
    "exp_feedback": RewardActionConfig(RewardTrack.EXP, 80, daily_limit=2, new_account_dampening=False),
    "exp_recipe_shared": RewardActionConfig(RewardTrack.EXP, 20, daily_limit=3, new_account_dampening=False),

    # ---- Points: 구매/플랫폼 (후하게) ----
    "points_attendance": RewardActionConfig(RewardTrack.POINTS, 30, daily_limit=1, weekly_capped=True),
    "points_streak_7": RewardActionConfig(RewardTrack.POINTS, 100),
    "points_streak_14": RewardActionConfig(RewardTrack.POINTS, 300),
    "points_streak_30": RewardActionConfig(RewardTrack.POINTS, 1000),
    "points_cart_add": RewardActionConfig(RewardTrack.POINTS, 50, daily_limit=10, weekly_capped=True),
    "points_purchase_self_report": RewardActionConfig(RewardTrack.POINTS, 300, daily_limit=5, weekly_capped=True),
    # 실제 지출이 증빙되므로 주간 캡 대상 제외, 신규계정 감쇄도 제외(실지출은 신뢰도가 높음)
    "points_purchase_photo_verified": RewardActionConfig(
        RewardTrack.POINTS, 1500, daily_limit=3, weekly_capped=False, new_account_dampening=False
    ),

    # ---- Points: 커뮤니티 (구매 대비 낮지만 존재감 있게) ----
    "points_like": RewardActionConfig(RewardTrack.POINTS, 20, daily_limit=15, weekly_capped=True),
    "points_comment": RewardActionConfig(RewardTrack.POINTS, 50, daily_limit=10, weekly_capped=True),
    "points_post_created": RewardActionConfig(RewardTrack.POINTS, 200, daily_limit=2, weekly_capped=True),
    "points_post_created_low_quality": RewardActionConfig(RewardTrack.POINTS, 30, daily_limit=2, weekly_capped=True),
    "points_post_popular": RewardActionConfig(RewardTrack.POINTS, 500, weekly_capped=False),
}

WEEKLY_POINTS_CAP = 12_000
NEW_ACCOUNT_GRACE_DAYS = 3
NEW_ACCOUNT_DAMPENING_RATIO = 0.5


def _day_key(dt: Optional[datetime] = None) -> str:
    dt = dt or datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%d")


def _week_key(dt: Optional[datetime] = None) -> str:
    dt = dt or datetime.now(timezone.utc)
    year, week, _ = dt.isocalendar()
    return f"{year}-W{week:02d}"


def exp_required_for_level(level: int) -> int:
    """레벨 N 도달 누적 EXP. Lv.2는 사진 기록 1번(50). 초반은 잘 오른다."""
    if level <= 1:
        return 0
    n = level - 1
    return round(50 * (n**1.38))


def level_for_exp(total_exp: int) -> int:
    """누적 EXP로 레벨을 계산한다. Flutter/Cloud Functions와 동일 공식."""
    if total_exp <= 0:
        return 1
    lo, hi = 1, 8
    while exp_required_for_level(hi) <= total_exp:
        hi *= 2
        if hi > 100000:
            break
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if exp_required_for_level(mid) <= total_exp:
            lo = mid
        else:
            hi = mid - 1
    return lo


@dataclass
class AwardResult:
    granted: bool
    track: RewardTrack
    amount: int = 0
    reason: Optional[str] = None
    balance: Optional[int] = None
    level: Optional[int] = None


class RewardsService:
    """EXP/포인트 지급, 일일·주간 한도 체크, 원장 기록을 담당하는 서비스."""

    def __init__(self) -> None:
        self._fb = get_firebase_service()

    @property
    def _db(self):
        return self._fb.db

    def _user_ref(self, uid: str):
        return self._db.collection("users").document(uid)

    def _counter_ref(self, uid: str, day_key: str):
        return self._user_ref(uid).collection("daily_action_counters").document(day_key)

    def _weekly_counter_ref(self, uid: str, week_key: str):
        return self._user_ref(uid).collection("weekly_point_counters").document(week_key)

    def _ledger_col(self, uid: str, track: RewardTrack):
        name = "exp_ledger" if track == RewardTrack.EXP else "points_ledger"
        return self._user_ref(uid).collection(name)

    def award(
        self,
        uid: str,
        action: str,
        *,
        idempotency_key: str,
        source_ref: Optional[str] = None,
        amount_override: Optional[int] = None,
    ) -> AwardResult:
        """행동에 대한 EXP/포인트를 지급한다. 한도 초과/중복 요청이면 granted=False.

        모든 지급은 단일 Firestore 트랜잭션 안에서 (중복 체크 → 일일/주간 한도
        체크 → 원장 기록 → 잔액 갱신)을 원자적으로 수행한다.
        """
        if self._db is None:
            logger.warning("RewardsService.award skipped: Firestore not initialized")
            return AwardResult(granted=False, track=RewardTrack.POINTS, reason="db_unavailable")

        config = REWARD_CATALOG.get(action)
        if config is None:
            raise ValueError(f"unknown reward action: {action!r}")

        now = datetime.now(timezone.utc)
        day_key = _day_key(now)
        week_key = _week_key(now)
        base_amount = amount_override if amount_override is not None else config.amount
        # Firestore 문서 ID는 '/' 불가 — Cloud Functions rewards.js와 동일 규칙.
        safe_idempotency_key = (idempotency_key or "").replace("/", "_")[:200]
        if not safe_idempotency_key:
            return AwardResult(granted=False, track=config.track, reason="missing_idempotency_key")

        user_ref = self._user_ref(uid)
        counter_ref = self._counter_ref(uid, day_key)
        ledger_ref = self._ledger_col(uid, config.track).document(safe_idempotency_key)
        weekly_ref = self._weekly_counter_ref(uid, week_key) if config.weekly_capped else None

        @firestore.transactional
        def _run(transaction) -> AwardResult:
            ledger_snap = transaction.get(ledger_ref)
            if ledger_snap.exists:
                return AwardResult(granted=False, track=config.track, reason="duplicate")

            counter_snap = transaction.get(counter_ref)
            counter_data = counter_snap.to_dict() or {}
            current_count = int(counter_data.get(action, 0) or 0)
            if config.daily_limit is not None and current_count >= config.daily_limit:
                return AwardResult(granted=False, track=config.track, reason="daily_limit_reached")

            weekly_total = 0
            if weekly_ref is not None:
                weekly_snap = transaction.get(weekly_ref)
                weekly_total = int((weekly_snap.to_dict() or {}).get("total", 0) or 0)
                if weekly_total >= WEEKLY_POINTS_CAP:
                    return AwardResult(granted=False, track=config.track, reason="weekly_cap_reached")

            user_snap = transaction.get(user_ref)
            user_data = user_snap.to_dict() or {}

            final_amount = base_amount
            if config.new_account_dampening:
                created_at = user_data.get("createdAt")
                if isinstance(created_at, datetime):
                    created_at_utc = created_at if created_at.tzinfo else created_at.replace(tzinfo=timezone.utc)
                    age_days = (now - created_at_utc).days
                    if age_days < NEW_ACCOUNT_GRACE_DAYS:
                        final_amount = max(1, round(base_amount * NEW_ACCOUNT_DAMPENING_RATIO))

            if weekly_ref is not None:
                remaining = WEEKLY_POINTS_CAP - weekly_total
                final_amount = max(0, min(final_amount, remaining))
                if final_amount <= 0:
                    return AwardResult(granted=False, track=config.track, reason="weekly_cap_reached")

            transaction.set(ledger_ref, {
                "action": action,
                "amount": final_amount,
                "track": config.track.value,
                "status": "confirmed",
                "sourceRef": source_ref,
                "createdAt": firestore.SERVER_TIMESTAMP,
            })
            transaction.set(counter_ref, {action: current_count + 1}, merge=True)
            if weekly_ref is not None:
                transaction.set(weekly_ref, {"total": weekly_total + final_amount}, merge=True)

            if config.track == RewardTrack.EXP:
                current_exp = int(user_data.get("expTotal", 0) or 0)
                new_exp = current_exp + final_amount
                new_level = level_for_exp(new_exp)
                transaction.set(user_ref, {
                    "expTotal": new_exp,
                    "level": new_level,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                }, merge=True)
                return AwardResult(granted=True, track=config.track, amount=final_amount, balance=new_exp, level=new_level)
            else:
                current_balance = int(user_data.get("pointsBalance", 0) or 0)
                current_lifetime = int(user_data.get("pointsLifetimeEarned", 0) or 0)
                new_balance = current_balance + final_amount
                transaction.set(user_ref, {
                    "pointsBalance": new_balance,
                    "pointsLifetimeEarned": current_lifetime + final_amount,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                }, merge=True)
                return AwardResult(granted=True, track=config.track, amount=final_amount, balance=new_balance)

        transaction = self._db.transaction()
        try:
            return _run(transaction)
        except Exception:
            logger.exception("RewardsService.award failed (uid=%s, action=%s)", uid, action)
            return AwardResult(granted=False, track=config.track, reason="internal_error")

    def revoke(self, uid: str, track: RewardTrack, amount: int, *, reason: str, source_ref: Optional[str] = None) -> bool:
        """신고/취소된 행동의 포인트·EXP를 마이너스 원장으로 회수한다. 잔액은 0 하한."""
        if self._db is None or amount <= 0:
            return False
        user_ref = self._user_ref(uid)
        ledger_ref = self._ledger_col(uid, track).document()

        @firestore.transactional
        def _run(transaction) -> bool:
            user_snap = transaction.get(user_ref)
            user_data = user_snap.to_dict() or {}
            balance_field = "expTotal" if track == RewardTrack.EXP else "pointsBalance"
            current_balance = int(user_data.get(balance_field, 0) or 0)
            new_balance = max(0, current_balance - amount)
            transaction.set(ledger_ref, {
                "action": reason,
                "amount": -(current_balance - new_balance),
                "track": track.value,
                "status": "reversed",
                "sourceRef": source_ref,
                "createdAt": firestore.SERVER_TIMESTAMP,
            })
            updates: Dict[str, Any] = {balance_field: new_balance, "updatedAt": firestore.SERVER_TIMESTAMP}
            if track == RewardTrack.EXP:
                updates["level"] = level_for_exp(new_balance)
            transaction.set(user_ref, updates, merge=True)
            return True

        transaction = self._db.transaction()
        try:
            return _run(transaction)
        except Exception:
            logger.exception("RewardsService.revoke failed (uid=%s)", uid)
            return False

_rewards_service: Optional[RewardsService] = None


def get_rewards_service() -> RewardsService:
    global _rewards_service
    if _rewards_service is None:
        _rewards_service = RewardsService()
    return _rewards_service
