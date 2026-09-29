"""
Coupang scraping utilities
쿠팡 크롤링 유틸리티 함수들
"""
from typing import List, Dict, Any, Tuple
from datetime import datetime, timezone, timedelta
from services.product_service import ProductService

# Tier thresholds
TIER_HOT_FREQ = 10       # freq >= 10 → hot
TIER_WARM_FREQ_MIN = 2   # freq 2-9  → warm
CART_HIT_WINDOW_DAYS = 30 # cart hit within N days → promote to hot

# Scraping schedule: hot+warm every cycle, cold every 2nd cycle
COLD_CYCLE_INTERVAL = 2  # include cold items every Nth cycle


def classify_tier(item: Dict[str, Any], cart_hit_map: Dict[str, Any] = None) -> str:
    """Classify an ingredient into hot / warm / cold.

    - hot:  freq >= 10 OR cart hit in last 30 days
    - warm: freq 2-9
    - cold: freq <= 1 with no recent cart hit

    cart_hit_map: {재료명: last_cart_hit} — get_firebase_service().get_cart_hit_map()
    으로 한 번에 읽어 전달. 없으면(None) freq만으로 판정한다.
    """
    freq = int(item.get("freq") or 1)
    name = str(item.get("name") or "").strip()
    last_hit = (cart_hit_map or {}).get(name)

    if freq >= TIER_HOT_FREQ:
        return "hot"

    if last_hit:
        try:
            if isinstance(last_hit, str):
                hit_dt = datetime.fromisoformat(last_hit.replace("Z", "+00:00"))
            else:
                hit_dt = last_hit
            if hit_dt.tzinfo is None:
                hit_dt = hit_dt.replace(tzinfo=timezone.utc)
            if datetime.now(timezone.utc) - hit_dt < timedelta(days=CART_HIT_WINDOW_DAYS):
                return "hot"
        except (ValueError, TypeError):
            pass

    if freq >= TIER_WARM_FREQ_MIN:
        return "warm"

    return "cold"


def get_ingredients_list(cycle_number: int = None) -> List[str]:
    """
    검색할 식재료 목록 반환 (Firestore 단일 소스, 티어 기반)

    - hot + warm: every cycle (5 days)
    - cold: every 2nd cycle (10 days)
    - frequency weighting still applies (hot items repeat 1-3x)

    Args:
        cycle_number: current scraping cycle. If None, reads from Firestore.

    Returns:
        List[str]: 식재료 목록
    """
    try:
        from services.firebase_service import get_firebase_service
        firebase = get_firebase_service()
        if not firebase.is_available():
            return _fallback_list()

        items = firebase.get_scraping_ingredients()
        if not items:
            return _fallback_list()

        if cycle_number is None:
            cycle_number = firebase.get_scraping_cycle_number()

        cart_hit_map = firebase.get_cart_hit_map()
        include_cold = (cycle_number % COLD_CYCLE_INTERVAL == 0)

        ingredients_list = []
        for item in items:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "").strip()
            if not name:
                continue

            tier = classify_tier(item, cart_hit_map)

            if tier == "cold" and not include_cold:
                continue

            freq = int(item.get("freq") or 1)
            scraping_count = ProductService.get_scraping_count(freq)
            for _ in range(scraping_count):
                ingredients_list.append(name)

        return ingredients_list
    except Exception:
        return _fallback_list()


def get_tier_summary() -> Dict[str, Any]:
    """Return a summary of ingredient tier distribution (for logging/debugging)."""
    try:
        from services.firebase_service import get_firebase_service
        firebase = get_firebase_service()
        if not firebase.is_available():
            return {}

        items = firebase.get_scraping_ingredients()
        cycle = firebase.get_scraping_cycle_number()
        cart_hit_map = firebase.get_cart_hit_map()
        counts = {"hot": 0, "warm": 0, "cold": 0}
        for item in items:
            if isinstance(item, dict) and item.get("name"):
                counts[classify_tier(item, cart_hit_map)] += 1

        include_cold = (cycle % COLD_CYCLE_INTERVAL == 0)
        active = counts["hot"] + counts["warm"] + (counts["cold"] if include_cold else 0)

        return {
            "cycle": cycle,
            "include_cold_this_cycle": include_cold,
            "tiers": counts,
            "total": sum(counts.values()),
            "active_this_cycle": active,
        }
    except Exception:
        return {}


def _fallback_list() -> List[str]:
    """Fallback: read from static file if Firestore is unavailable."""
    try:
        from scripts.updated_ingredients import ALL_INGREDIENTS_WITH_FREQ
        result = []
        for name, freq in ALL_INGREDIENTS_WITH_FREQ:
            count = ProductService.get_scraping_count(freq)
            for _ in range(count):
                result.append(name)
        return result
    except ImportError:
        return []
