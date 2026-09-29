"""
Rate limiter to protect YouTube accounts from excessive requests.
Prevents cookies from being abused or triggering YouTube limits.
Supports per-cookie rate limiting for cookie pool.
"""

import time
import threading
from collections import defaultdict
from datetime import datetime, timedelta
from typing import Dict, Optional


class RateLimiter:
    """Rate limiter for YouTube requests with per-cookie tracking"""
    
    def __init__(self, max_requests_per_minute=10, max_requests_per_hour=100):
        self.max_per_minute = max_requests_per_minute
        self.max_per_hour = max_requests_per_hour
        # Track requests per cookie
        self.cookie_minute_requests: Dict[str, list] = defaultdict(list)
        self.cookie_hour_requests: Dict[str, list] = defaultdict(list)
        # Global rate limit across all cookies
        self.global_minute_requests = []
        self.global_hour_requests = []
        self.lock = threading.Lock()
        
    def is_allowed(self, cookie_id: Optional[str] = None) -> bool:
        """
        Check if a new request is allowed.
        If cookie_id provided, checks per-cookie limit AND global limit.
        Otherwise, only checks global limit.
        """
        with self.lock:
            now = datetime.now()
            minute_ago = now - timedelta(minutes=1)
            hour_ago = now - timedelta(hours=1)
            
            # Clean up old global requests
            self.global_minute_requests = [t for t in self.global_minute_requests if t > minute_ago]
            self.global_hour_requests = [t for t in self.global_hour_requests if t > hour_ago]
            
            # Check global limits (prevent overwhelming YouTube regardless of cookies)
            # With multiple cookies, increase global limit proportionally
            global_minute_limit = self.max_per_minute * max(1, len(self.cookie_minute_requests))
            global_hour_limit = self.max_per_hour * max(1, len(self.cookie_hour_requests))
            
            if len(self.global_minute_requests) >= global_minute_limit:
                return False
            if len(self.global_hour_requests) >= global_hour_limit:
                return False
            
            # If cookie_id provided, check per-cookie limits
            if cookie_id:
                # Clean up old cookie requests
                self.cookie_minute_requests[cookie_id] = [
                    t for t in self.cookie_minute_requests[cookie_id] if t > minute_ago
                ]
                self.cookie_hour_requests[cookie_id] = [
                    t for t in self.cookie_hour_requests[cookie_id] if t > hour_ago
                ]
                
                # Check per-cookie limits
                if len(self.cookie_minute_requests[cookie_id]) >= self.max_per_minute:
                    return False
                if len(self.cookie_hour_requests[cookie_id]) >= self.max_per_hour:
                    return False
            
            return True
    
    def record_request(self, cookie_id: Optional[str] = None):
        """Record a new request"""
        with self.lock:
            now = datetime.now()
            
            # Always record to global
            self.global_minute_requests.append(now)
            self.global_hour_requests.append(now)
            
            # Record to per-cookie if provided
            if cookie_id:
                self.cookie_minute_requests[cookie_id].append(now)
                self.cookie_hour_requests[cookie_id].append(now)
        
    def wait_time(self, cookie_id: Optional[str] = None) -> int:
        """Get seconds to wait until next request is allowed"""
        with self.lock:
            now = datetime.now()
            wait_times = []
            
            # Check global limits
            if self.global_minute_requests:
                oldest = min(self.global_minute_requests)
                wait = (oldest + timedelta(minutes=1) - now).total_seconds()
                if wait > 0:
                    wait_times.append(wait)
                    
            if self.global_hour_requests:
                oldest = min(self.global_hour_requests)
                wait = (oldest + timedelta(hours=1) - now).total_seconds()
                if wait > 0:
                    wait_times.append(wait)
            
            # Check per-cookie limits if provided
            if cookie_id:
                if self.cookie_minute_requests[cookie_id]:
                    oldest = min(self.cookie_minute_requests[cookie_id])
                    wait = (oldest + timedelta(minutes=1) - now).total_seconds()
                    if wait > 0:
                        wait_times.append(wait)
                        
                if self.cookie_hour_requests[cookie_id]:
                    oldest = min(self.cookie_hour_requests[cookie_id])
                    wait = (oldest + timedelta(hours=1) - now).total_seconds()
                    if wait > 0:
                        wait_times.append(wait)
            
            return int(max(wait_times)) + 1 if wait_times else 0
    
    def get_stats(self) -> Dict:
        """Get current rate limiter statistics"""
        with self.lock:
            now = datetime.now()
            minute_ago = now - timedelta(minutes=1)
            hour_ago = now - timedelta(hours=1)
            
            # Clean up old requests first
            self.global_minute_requests = [t for t in self.global_minute_requests if t > minute_ago]
            self.global_hour_requests = [t for t in self.global_hour_requests if t > hour_ago]
            
            per_cookie_stats = {}
            for cookie_id in self.cookie_minute_requests.keys():
                self.cookie_minute_requests[cookie_id] = [
                    t for t in self.cookie_minute_requests[cookie_id] if t > minute_ago
                ]
                self.cookie_hour_requests[cookie_id] = [
                    t for t in self.cookie_hour_requests[cookie_id] if t > hour_ago
                ]
                
                per_cookie_stats[cookie_id] = {
                    'requests_last_minute': len(self.cookie_minute_requests[cookie_id]),
                    'requests_last_hour': len(self.cookie_hour_requests[cookie_id])
                }
            
            return {
                'global_requests_last_minute': len(self.global_minute_requests),
                'global_requests_last_hour': len(self.global_hour_requests),
                'per_cookie': per_cookie_stats
            }


# Global rate limiter instance
# Per-cookie limits: 10/min, 100/hour (safe for YouTube)
youtube_rate_limiter = RateLimiter(
    max_requests_per_minute=10,   # Max 10 videos per minute per cookie
    max_requests_per_hour=100     # Max 100 videos per hour per cookie
)

# /ingredient_prices/report_missing — Firebase uid 기준
report_missing_ingredient_prices_limiter = RateLimiter(
    max_requests_per_minute=5,
    max_requests_per_hour=100,
)


# /ingredient_prices/request_unit_price — Firebase uid 기준
request_unit_price_limiter = RateLimiter(
    max_requests_per_minute=10,
    max_requests_per_hour=200,
)

# /ingredient_prices/report_price_issue — Firebase uid 기준
report_ingredient_price_issue_limiter = RateLimiter(
    max_requests_per_minute=5,
    max_requests_per_hour=50,
)

# /fridge/scan_photo — Firebase uid 기준. 사진 1장당 비전 LLM 호출 1회라
# 비용 방어를 위해 다른 LLM 엔드포인트보다 보수적으로 제한한다.
fridge_photo_scan_limiter = RateLimiter(
    max_requests_per_minute=5,
    max_requests_per_hour=30,
)

# /purchase-verification/submit — 구매완료 사진 인증. 1일 3회 캡(daily_action_counters)
# 이 사실상의 상한이지만, 비전 LLM 호출 자체를 짧은 시간에 몰아 재시도하는 것도
# 막기 위해 보수적으로 제한한다.
purchase_verification_limiter = RateLimiter(
    max_requests_per_minute=3,
    max_requests_per_hour=10,
)

# /recipe_agent/turn — 로그인 uid 기준. LLM 1회/턴이라 시간·일 한도를 같이 둔다.
recipe_agent_limiter = RateLimiter(
    max_requests_per_minute=10,
    max_requests_per_hour=60,
)
_recipe_agent_day_hits: Dict[str, list] = defaultdict(list)
_recipe_agent_day_lock = threading.Lock()
_RECIPE_AGENT_MAX_PER_DAY = 80


def check_recipe_agent_rate_limit(uid: str) -> None:
    """레시피 에이전트 턴 속도 제한 (10/분, 60/시간, 80/일)."""
    from fastapi import HTTPException

    if not recipe_agent_limiter.is_allowed(uid):
        wait_seconds = recipe_agent_limiter.wait_time(uid)
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    with _recipe_agent_day_lock:
        now = datetime.now()
        day_ago = now - timedelta(hours=24)
        hits = [t for t in _recipe_agent_day_hits[uid] if t > day_ago]
        _recipe_agent_day_hits[uid] = hits
        if len(hits) >= _RECIPE_AGENT_MAX_PER_DAY:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded. Please try again tomorrow.",
            )
        hits.append(now)
        _recipe_agent_day_hits[uid] = hits
        recipe_agent_limiter.record_request(uid)


# /home_agent/turn — 상세 에이전트와 지갑을 섞지 않는다.
home_agent_limiter = RateLimiter(
    max_requests_per_minute=8,
    max_requests_per_hour=40,
)
_home_agent_day_hits: Dict[str, list] = defaultdict(list)
_home_agent_day_lock = threading.Lock()
_HOME_AGENT_MAX_PER_DAY = 50


def check_home_agent_rate_limit(uid: str) -> None:
    """홈 검색 에이전트 턴 속도 제한 (8/분, 40/시간, 50/일)."""
    from fastapi import HTTPException

    if not home_agent_limiter.is_allowed(uid):
        wait_seconds = home_agent_limiter.wait_time(uid)
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    with _home_agent_day_lock:
        now = datetime.now()
        day_ago = now - timedelta(hours=24)
        hits = [t for t in _home_agent_day_hits[uid] if t > day_ago]
        _home_agent_day_hits[uid] = hits
        if len(hits) >= _HOME_AGENT_MAX_PER_DAY:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded. Please try again tomorrow.",
            )
        hits.append(now)
        _home_agent_day_hits[uid] = hits
    home_agent_limiter.record_request(uid)


def check_report_missing_ingredient_prices_rate_limit(uid: str) -> None:
    """로그인 uid당 보고 API 속도 제한. 초과 시 HTTP 429."""
    if not report_missing_ingredient_prices_limiter.is_allowed(uid):
        wait_seconds = report_missing_ingredient_prices_limiter.wait_time(uid)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    report_missing_ingredient_prices_limiter.record_request(uid)


def check_request_unit_price_rate_limit(uid: str) -> None:
    """로그인 uid당 단위별 단가 요청 API 속도 제한. 초과 시 HTTP 429."""
    if not request_unit_price_limiter.is_allowed(uid):
        wait_seconds = request_unit_price_limiter.wait_time(uid)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    request_unit_price_limiter.record_request(uid)


def check_report_ingredient_price_issue_rate_limit(uid: str) -> None:
    """재료 가격 문제 보고 API 속도 제한."""
    if not report_ingredient_price_issue_limiter.is_allowed(uid):
        wait_seconds = report_ingredient_price_issue_limiter.wait_time(uid)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    report_ingredient_price_issue_limiter.record_request(uid)


def check_fridge_photo_scan_rate_limit(uid: str) -> None:
    """냉장고/영수증 사진 스캔 API 속도 제한 (uid당 5회/분, 30회/시간)."""
    if not fridge_photo_scan_limiter.is_allowed(uid):
        wait_seconds = fridge_photo_scan_limiter.wait_time(uid)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    fridge_photo_scan_limiter.record_request(uid)


def check_purchase_verification_rate_limit(uid: str) -> None:
    """구매완료 사진 인증 API 속도 제한 (uid당 3회/분, 10회/시간)."""
    if not purchase_verification_limiter.is_allowed(uid):
        wait_seconds = purchase_verification_limiter.wait_time(uid)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds.",
        )
    purchase_verification_limiter.record_request(uid)


def check_rate_limit(cookie_id: Optional[str] = None):
    """
    Check if request is allowed by rate limit.
    Raises HTTPException if limit exceeded.
    
    Args:
        cookie_id: Optional cookie ID for per-cookie rate limiting
    """
    if not youtube_rate_limiter.is_allowed(cookie_id):
        wait_seconds = youtube_rate_limiter.wait_time(cookie_id)
        from fastapi import HTTPException
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Please try again in {wait_seconds} seconds."
        )
    
    youtube_rate_limiter.record_request(cookie_id)


def get_rate_limit_stats() -> Dict:
    """Get current rate limiter statistics"""
    return youtube_rate_limiter.get_stats()

