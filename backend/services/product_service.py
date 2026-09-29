"""
Product service for product search and matching

Handles Coupang API, Naver Shopping API, web scraping, and product matching logic.
"""

import os
import json
import hashlib
import re
import hmac
import time
import urllib.parse
import random
import asyncio
import logging
import threading
from typing import List, Dict, Any, Optional, Tuple, Callable
import requests
from bs4 import BeautifulSoup
from google.cloud.firestore_v1 import FieldFilter

from utils import convert_to_base_unit
from services.coupang_partner_urls import (
    extract_partner_urls_from_scraped,
    is_coupang_affsdp_landing_url,
    split_partner_urls,
)
from models import (
    ProductSearchRequest,
    ProductRecommendationResponse,
    AdvancedProductSearchResponse,
    CoupangProduct,
    ProductSearchResult,
    recommendation_payload_lists,
)


# ========== Coupang API Queue Scheduler Constants ==========

# 유사 단어 매핑 (필터링용)
# 키: 재료명, 값: 해당 재료명과 유사한 단어들의 리스트
SIMILAR_WORDS_MAP = {
    # 소금 관련
    "소금": ["소금", "천일염", "맛소금", "굵은소금", "꽃소금", "핑크소금"],
    "천일염": ["소금", "천일염", "맛소금", "굵은소금"],
    "맛소금": ["소금", "천일염", "맛소금"],
    "굵은소금": ["소금", "천일염", "굵은소금"],

    # 고춧가루 관련
    "고춧가루": ["고춧가루", "고추가루"],
    "고추가루": ["고춧가루", "고추가루"],

    # 간장 관련
    "간장": ["간장", "진간장", "양조간장"],
    "진간장": ["간장", "진간장", "양조간장"],
    "양조간장": ["간장", "진간장", "양조간장"],
    "국간장": ["국간장", "간장"],

    # 마늘 관련 (다진 마늘 is canonical after cleanup)
    "마늘": ["마늘", "다진 마늘"],
    "다진 마늘": ["다진 마늘", "마늘"],

    # 계란 관련 (달걀 → 계란 after cleanup)
    "계란": ["계란", "달걀"],
    "달걀": ["계란", "달걀"],

    # 후추 관련 (후춧가루/후추가루 → 후추 after cleanup)
    "후추": ["후추", "후춧가루", "후추가루", "백후추", "통후추"],
    "백후추": ["후추", "백후추"],
    "통후추": ["후추", "통후추"],

    # 케첩 관련
    "케첩": ["케첩", "케찹", "케챱"],

    # 소시지 관련 (소세지 → 소시지 after cleanup)
    "소시지": ["소시지", "소세지"],

    # 버섯 관련
    "버섯": ["버섯", "팽이버섯", "표고버섯", "새송이버섯"],
    "팽이버섯": ["버섯", "팽이버섯"],
    "표고버섯": ["버섯", "표고버섯"],
    "새송이버섯": ["버섯", "새송이버섯"],

    # 치즈 관련
    "모짜렐라 치즈": ["모짜렐라 치즈", "모짜렐라치즈", "피자치즈"],
    "체다 치즈": ["체다 치즈", "체다치즈"],
    "치즈": ["치즈", "모짜렐라 치즈", "체다 치즈"],

    # 김치 관련
    "김치": ["김치", "배추김치", "신김치", "묵은지"],
    "묵은지": ["묵은지", "김치"],

    # 매실 관련 (매실액 → 매실청 after cleanup)
    "매실청": ["매실청", "매실액"],

    # 깨 관련
    "통깨": ["통깨", "참깨", "깨"],
    "깨": ["깨", "통깨", "참깨"],

    # 코인 육수 / 다시다 관련
    "코인 육수": ["코인 육수", "코인육수", "분말육수"],
    "다시다": ["다시다", "소고기 다시다", "멸치 다시다"],

    # 토마토 소스 관련
    "토마토 소스": ["토마토 소스", "토마토소스"],
}

# ── Cart display normalizer ──
# Maps specific ingredient names to a simplified display name for the shopping cart.
# The display name is what the user sees; the search still checks all relevant product docs.
CART_DISPLAY_MAP: Dict[str, str] = {
    # Part → whole
    "대파 흰부분": "대파",
    "대파 파란 부분": "대파",
    "대파 초록 부분": "대파",
    "대파 흰 부분": "대파",
    "대파 흰대": "대파",

    # Prep-method variants: display the base + search both
    "다진 양파": "양파",
    "다진 대파": "대파",
    "다진 파": "대파",
    "다진 파슬리": "파슬리",
    "다진 삼겹살": "삼겹살",
    "다진 부추": "부추",
    "다진 채소": "채소",
    "다진 볶음 땅콩": "땅콩",
    "다진 땅콩": "땅콩",

    # Egg parts
    "계란 노른자": "계란",

    # Cooked/state variants
    "볶은 김치": "김치",
    "배추김치": "김치",
    "자투리 야채": "채소",
    "각종 채소": "채소",
    "레몬즙 넣은 다진 양파": "양파",

    # 김 variants
    "건조김": "김",
    "김밥김": "김",
    "조미김": "김",
    "구운 김": "김",
    "트러플 김": "김",

    # Broth/stock simplification for display
    "치킨스톡": "치킨스톡",
    "소고기 다시다": "다시다",
    "쇠고기 다시다": "다시다",
    "멸치 다시다": "다시다",
    "코인 육수": "코인 육수",

    # Sauce simplification
    "돈까스 소스": "돈까스소스",
    "돈가스소스": "돈까스소스",
}

# ── Search expansion map ──
# When looking up products, also search these additional doc IDs.
# Key: ingredient name, Value: list of additional coupang_products doc IDs to check.
CART_SEARCH_EXPANSION: Dict[str, List[str]] = {
    "다진 마늘": ["마늘"],
    "통마늘": ["마늘"],
    "편마늘": ["마늘"],
    "다진 생강": ["생강"],
    "간 생강": ["생강"],
    "생강즙": ["생강"],
    "계란 노른자": ["계란"],
    "삶은 계란": ["계란"],
    "레몬즙": ["레몬"],
    "레몬주스": ["레몬"],
    "레몬 슬라이스": ["레몬"],
    "김치국물": ["김치"],
    "볶은 김치": ["김치"],
    "신김치": ["김치"],
    "배추김치": ["김치"],
    "묵은지": ["김치"],
    "대파 흰부분": ["대파"],
    "대파 흰 부분": ["대파"],
    "대파 흰대": ["대파"],
    "대파 파란 부분": ["대파"],
    "다진 대파": ["대파"],
    "다진 양파": ["양파"],
    "쌀": ["쌀", "햇반"],
    "매실청": ["매실액", "매실청"],
    "밥": ["쌀", "햇반"],
    "김밥김": ["김"],
    "건조김": ["김"],
    "조미김": ["김"],
}


def normalize_cart_display_name(ingredient_name: str) -> str:
    """Return a user-friendly display name for the shopping cart.
    Falls back to the original name if no mapping exists."""
    return CART_DISPLAY_MAP.get(ingredient_name, ingredient_name)


def get_search_names(ingredient_name: str) -> List[str]:
    """Return all coupang_products doc IDs to search for this ingredient.
    Always includes the original name first, plus any expansion entries."""
    names = [ingredient_name]
    extras = CART_SEARCH_EXPANSION.get(ingredient_name, [])
    for e in extras:
        if e not in names:
            names.append(e)
    return names


# 단위 정의 (UNIT_STEPS) - 카테고리별 검색 단위
UNIT_STEPS = {
    "GRAIN": ["500g", "1kg", "4kg", "10kg", "20kg"],
    "POWDER_SEASONING": ["100g", "200g", "500g", "1kg"],
    "NOODLE": ["500g", "1kg", "3kg", "5kg"],
    "VEG_WEIGHT": ["200g", "500g", "1kg", "2kg", "1박스"],
    "VEG_COUNT": ["1개", "3개", "5개", "10개", "1kg", "3kg"],
    "MEAT": ["300g", "600g", "1kg", "2kg"],
    "SEAFOOD": ["1kg", "3kg", "5개", "10개", "15개"],
    "LIQUID": ["250ml", "500ml", "900ml", "1.8L"],
    "PROCESSED_COUNT": ["1개", "3개", "1팩", "3팩", "1박스"],
    "EGG": ["10구", "15구", "30구", "60구"],
}

# 접두사 정의 (PREFIXES) - 카테고리별 검색 접두사
PREFIXES = {
    "GRAIN": ["", "국산 ", "국내산 ", "유기농 ", "혼합 ", "세척 "],
    "POWDER_SEASONING": ["", "국산 ", "국내산 ", "무첨가 ", "대용량 "],
    "NOODLE": ["", "국산 ", "국내산 ", "유기농 "],
    "VEG_WEIGHT": ["", "국산 ", "국내산 ", "유기농 ", "손질 ", "세척 ", "대용량 "],
    "VEG_COUNT": ["", "국산 ", "국내산 ", "유기농 ", "손질 ", "세척 "],
    "MEAT": ["", "국산 ", "국내산 ", "수입 ", "냉동 ", "고급"],
    "SEAFOOD": ["", "국산 ", "국내산 ", "냉동 ", "손질 "],
    "LIQUID": ["", "국산 ", "국내산 "],
    "PROCESSED_COUNT": ["", "국산", "국내산"],
    "EGG": ["", "무항생제 ", "특란 ", "대란 "],
}

# 식재료 매핑 (INGREDIENT_MAPPING) - 재료명을 카테고리로 매핑
INGREDIENT_MAPPING = {
    # GRAIN (곡물 및 대용량 가루)
    "쌀": "GRAIN",
    "현미": "GRAIN",
    "밀가루": "GRAIN",
    "찹쌀": "GRAIN",
    "잡곡": "GRAIN",
    "오트밀": "GRAIN",
    
    # POWDER_SEASONING (조미료 및 소량 가루)
    "고추장": "POWDER_SEASONING",
    "된장": "POWDER_SEASONING",
    "쌈장": "POWDER_SEASONING",
    "설탕": "POWDER_SEASONING",
    "소금": "POWDER_SEASONING",
    "고춧가루": "POWDER_SEASONING",
    "후추": "POWDER_SEASONING",
    "다시다": "POWDER_SEASONING",
    "미원": "POWDER_SEASONING",
    "통깨": "POWDER_SEASONING",
    "파슬리": "POWDER_SEASONING",
    "카레가루": "POWDER_SEASONING",
    "전분": "POWDER_SEASONING",
    "빵가루": "POWDER_SEASONING",
    "계피가루": "POWDER_SEASONING",
    "이스트": "POWDER_SEASONING",
    "베이킹파우더": "POWDER_SEASONING",
    "코코아파우더": "POWDER_SEASONING",
    
    # NOODLE (면류)
    "소면": "NOODLE",
    "파스타면": "NOODLE",
    "당면": "NOODLE",
    "칼국수면": "NOODLE",
    "메밀면": "NOODLE",
    "쫄면": "NOODLE",
    "우동면": "NOODLE",
    
    # VEG_WEIGHT (중량 단위 채소 - 잎/뿌리)
    "대파": "VEG_WEIGHT",
    "다진 마늘": "VEG_WEIGHT",
    "당근": "VEG_WEIGHT",
    "콩나물": "VEG_WEIGHT",
    "숙주": "VEG_WEIGHT",
    "시금치": "VEG_WEIGHT",
    "깻잎": "VEG_WEIGHT",
    "상추": "VEG_WEIGHT",
    "양파": "VEG_WEIGHT",
    "배추": "VEG_WEIGHT",
    "무": "VEG_WEIGHT",
    "감자": "VEG_WEIGHT",
    "양배추": "VEG_WEIGHT",
    "고구마": "VEG_WEIGHT",
    "연근": "VEG_WEIGHT",
    "우엉": "VEG_WEIGHT",
    "미나리": "VEG_WEIGHT",
    "부추": "VEG_WEIGHT",
    "쪽파": "VEG_WEIGHT",
    "청경채": "VEG_WEIGHT",
    "미역": "VEG_WEIGHT",
    "다시마": "VEG_WEIGHT",
    "생강": "VEG_WEIGHT",
    "바질": "VEG_WEIGHT",
    "로즈마리": "VEG_WEIGHT",
    "월계수잎": "VEG_WEIGHT",
    
    # VEG_COUNT (개수 단위 채소 - 과채류)
    "애호박": "VEG_COUNT",
    "오이": "VEG_COUNT",
    "가지": "VEG_COUNT",
    "파프리카": "VEG_COUNT",
    "아보카도": "VEG_COUNT",
    "브로콜리": "VEG_COUNT",
    "단호박": "VEG_COUNT",
    "레몬": "VEG_COUNT",
    "토마토": "VEG_COUNT",
    "방울토마토": "VEG_COUNT",
    "팽이버섯": "VEG_COUNT",
    "표고버섯": "VEG_COUNT",
    "새송이버섯": "VEG_COUNT",
    "청양고추": "VEG_COUNT",
    
    # MEAT (육류)
    "돼지고기 삼겹살": "MEAT",
    "돼지고기 목살": "MEAT",
    "돼지고기 앞다리살": "MEAT",
    "소고기 국거리": "MEAT",
    "소고기 구이용": "MEAT",
    "닭고기": "MEAT",
    "닭가슴살": "MEAT",
    "베이컨": "MEAT",
    
    # SEAFOOD (수산물)
    "고등어": "SEAFOOD",
    "갈치": "SEAFOOD",
    "오징어": "SEAFOOD",
    "낙지": "SEAFOOD",
    "쭈꾸미": "SEAFOOD",
    "꽃게": "SEAFOOD",
    "냉동새우": "SEAFOOD",
    "새우": "SEAFOOD",
    "바지락": "SEAFOOD",
    "홍합": "SEAFOOD",
    "전복": "SEAFOOD",
    "굴": "SEAFOOD",
    "멸치": "SEAFOOD",
    "명란젓": "SEAFOOD",
    
    # LIQUID (액체류)
    "진간장": "LIQUID",
    "국간장": "LIQUID",
    "식용유": "LIQUID",
    "참기름": "LIQUID",
    "올리브유": "LIQUID",
    "식초": "LIQUID",
    "맛술": "LIQUID",
    "케첩": "LIQUID",
    "마요네즈": "LIQUID",
    "우유": "LIQUID",
    "굴소스": "LIQUID",
    "액젓": "LIQUID",
    "올리고당": "LIQUID",
    "매실청": "LIQUID",
    "새우젓": "LIQUID",
    "생크림": "LIQUID",
    "휘핑크림": "LIQUID",
    "요거트": "LIQUID",
    "돈가스소스": "LIQUID",
    "데리야끼소스": "LIQUID",
    "칠리소스": "LIQUID",
    "머스터드": "LIQUID",
    "땅콩버터": "LIQUID",
    "바닐라익스트랙": "LIQUID",
    "마라소스": "LIQUID",
    "두반장": "LIQUID",
    "춘장": "LIQUID",
    "와사비": "LIQUID",
    
    # PROCESSED_COUNT (가공식품/개수)
    "두부": "PROCESSED_COUNT",
    "치즈": "PROCESSED_COUNT",
    "모짜렐라": "PROCESSED_COUNT",
    "체다": "PROCESSED_COUNT",
    "버터": "PROCESSED_COUNT",
    "김": "PROCESSED_COUNT",
    "참치캔": "PROCESSED_COUNT",
    "스팸": "PROCESSED_COUNT",
    "라면": "PROCESSED_COUNT",
    "냉동만두": "PROCESSED_COUNT",
    "어묵": "PROCESSED_COUNT",
    "비엔나소시지": "PROCESSED_COUNT",
    "프랑크소시지": "PROCESSED_COUNT",
    "맛살": "PROCESSED_COUNT",
    "베이크드빈": "PROCESSED_COUNT",
    "옥수수콘": "PROCESSED_COUNT",
    "순대": "PROCESSED_COUNT",
    "쌈무": "PROCESSED_COUNT",
    "김치": "PROCESSED_COUNT",
    "라이스페이퍼": "PROCESSED_COUNT",
    "시리얼": "PROCESSED_COUNT",
    "떡국떡": "PROCESSED_COUNT",
    "떡볶이떡": "PROCESSED_COUNT",
    "초콜릿": "PROCESSED_COUNT",
    
    # EGG (계란)
    "달걀": "EGG",
    "계란": "EGG",
}

# Lazy-loaded ingredient set from Firestore (single source of truth).
# Falls back to the static file if Firestore is unavailable.
_cached_all_ingredients: set = set()
_cached_all_ingredients_loaded: bool = False


def _load_all_ingredients() -> set:
    """Load ingredient names from the unified Firestore scraping list."""
    global _cached_all_ingredients, _cached_all_ingredients_loaded
    if _cached_all_ingredients_loaded:
        return _cached_all_ingredients
    try:
        from services.firebase_service import get_firebase_service
        fb = get_firebase_service()
        if fb.is_available():
            names = fb.get_scraping_ingredient_names()
            if names:
                _cached_all_ingredients = names
                _cached_all_ingredients_loaded = True
                return _cached_all_ingredients
    except Exception:
        pass
    # Fallback to static file
    try:
        from scripts.updated_ingredients import ALL_INGREDIENTS_WITH_FREQ as _static
        _cached_all_ingredients = {n for n, _ in _static}
        _cached_all_ingredients_loaded = True
    except ImportError:
        _cached_all_ingredients = set()
        _cached_all_ingredients_loaded = True
    return _cached_all_ingredients


# Keep module-level names for backward compatibility (tools scripts may still import these)
try:
    from scripts.updated_ingredients import ALL_INGREDIENTS_WITH_FREQ
except ImportError:
    ALL_INGREDIENTS_WITH_FREQ = []

ALL_INGREDIENTS = [ing[0] for ing in ALL_INGREDIENTS_WITH_FREQ]

# 스케줄러 설정 - 24시간 주기 방식
SCHEDULER_BATCH_SIZE = 1  # 한 번에 처리할 쿼리 수 (1개씩 처리)
SCHEDULER_QUERY_INTERVAL = 33  # 쿼리 간 대기 시간 (초) - 33초 간격 (24시간 주기 기준)
SCHEDULER_TARGET_CYCLE_HOURS = 24  # 목표 주기: 24시간


# Configure logger for product service
logger = logging.getLogger(__name__)

class ProductService:
    """Service for product search and matching operations"""
    
    @staticmethod
    def get_scraping_count(frequency: int) -> int:
        """
        빈도수에 따라 스크래핑 횟수 결정
        
        Args:
            frequency: 재료의 빈도수
            
        Returns:
            int: 스크래핑 횟수 (1-3)
        """
        if frequency >= 50:
            return 3  # 빈도수 높은 재료: 3회
        elif frequency >= 20:
            return 2  # 빈도수 중간 재료: 2회
        else:
            return 1  # 빈도수 낮은 재료 또는 새로운 재료: 1회
    
    def __init__(self, firebase_service=None):
        """
        Initialize product service.
        
        Args:
            firebase_service: FirebaseService instance for caching (optional)
        """
        self.firebase_service = firebase_service
        self.cache_collection = "search_query_cache"
        self.cache_ttl_hours = 24  # 24시간으로 설정 (스케줄러 전체 순환 시간 24시간 기준)
        
        # API credentials
        self.coupang_access_key = os.getenv("COUPANG_ACCESS_KEY", "")
        self.coupang_secret_key = os.getenv("COUPANG_SECRET_KEY", "")
        self.coupang_partner_subid = os.getenv("COUPANG_PARTNER_SUBID", "YorigoMobile")
        self.naver_client_id = os.getenv("NAVER_CLIENT_ID", "")
        self.naver_client_secret = os.getenv("NAVER_CLIENT_SECRET", "")
        # 0 or negative: unlimited (default)
        self.see_more_soft_cap = int(os.getenv("SEE_MORE_SOFT_CAP", "0"))
        self._excluded_products_cache: Optional[set[str]] = None
        self._excluded_products_cache_at: float = 0.0
        self._excluded_products_cache_ttl_seconds: int = int(
            os.getenv("EXCLUDED_PRODUCTS_CACHE_TTL_SECONDS", "300")
        )
        # 캐시 만료 순간 여러 재료가 동시에 갱신을 시도하는 "cache stampede" 방지용.
        # 실측: excluded_products_global 컬렉션 쿼리가 3.5초+ 걸려서, 만료 직후
        # 배치/스트림으로 몰려온 요청 4~6개가 동시에 이걸 각각 다시 조회하면
        # 그만큼 지연이 겹쳐 보임. 락으로 첫 스레드만 실제로 조회하고 나머지는
        # 결과를 재사용하게 한다.
        self._excluded_products_refresh_lock = threading.Lock()
        to_thread_limit = int(
            os.getenv(
                "PRODUCT_RECOMMEND_TO_THREAD_CONCURRENCY",
                os.getenv("BLOCKING_POOL_WORKERS", "10"),
            )
        )
        self._to_thread_concurrency = max(1, to_thread_limit)
        self._to_thread_semaphore = asyncio.Semaphore(self._to_thread_concurrency)
        # Coupang Partners deeplink API 결과 캐시 (동일 상품 URL 반복 호출 방지)
        self._deeplink_url_cache: Dict[str, str] = {}
        self._partner_links_cache: Dict[str, Dict[str, str]] = {}
        self._deeplink_cache_lock = threading.Lock()
        # fire-and-forget 백그라운드 태스크 강참조 보관용 (GC로 중간에 취소되는 것 방지).
        # 완료되면 done_callback에서 자동 discard.
        self._background_tasks: set = set()
        # cart-hit 같은 배경 기록용 전용 세마포어. 메인 상품 조회
        # (_to_thread_semaphore)와 풀을 분리해, 느린 배경 쓰기가 몰려도
        # 사용자 응답 경로의 동시성 슬롯을 잠식하지 않게 한다.
        # (참고: 둘 다 결국 blocking_pool의 동일한 전역 ThreadPoolExecutor를
        # 공유하므로 완전한 격리는 아니다 — 그래서 아래 디바운스로 애초에
        # 배경 쓰기 실행 빈도 자체를 최소화한다.)
        self._background_write_semaphore = asyncio.Semaphore(
            int(os.getenv("BACKGROUND_WRITE_CONCURRENCY", "8"))
        )
        # cart-hit 기록 디바운스: update_scraping_ingredient_cart_hit는 이제
        # 재료별 독립 문서에 사전 읽기 없이 바로 쓰므로(더 이상 대형 공유
        # 배열 문서 read+rewrite가 아님) 개별 쓰기 자체는 가벼워졌다. 다만
        # 이 타임스탬프는 tier 승격 판정 창(coupang_utils.CART_HIT_WINDOW_DAYS,
        # 30일)에만 쓰이는 힌트라 그보다 훨씬 잦은 갱신은 무의미 — 같은 재료가
        # 하루에도 수십 번 검색될 수 있으므로, 디바운스를 그 판정 창에 맞춰
        # 크게 늘려 Firestore 쓰기 횟수(=비용)를 최소화한다. 29일로 잡아 30일
        # 경계에서 hot 판정이 하루 정도 끊기는 미세한 gap을 피한다.
        self._cart_hit_last_recorded: Dict[str, float] = {}
        self._cart_hit_debounce_lock = threading.Lock()
        self._cart_hit_debounce_seconds: int = int(
            os.getenv("CART_HIT_DEBOUNCE_DAYS", "29")
        ) * 86400

    def _resolve_coupang_partner_deeplink(self, coupang_page_url: str) -> str:
        """Partners shorten/landing URL로 변환. 키 없거나 실패 시 원본 URL."""
        url = (coupang_page_url or "").strip()
        if not url.startswith("http") or "coupang.com" not in url.lower():
            return url
        if not self.coupang_access_key or not self.coupang_secret_key:
            return url
        with self._deeplink_cache_lock:
            if url in self._deeplink_url_cache:
                return self._deeplink_url_cache[url]
        from services.coupang_service import convert_single_url_to_deeplink

        sub_id = self.coupang_partner_subid or "YorigoMobile"
        resolved = convert_single_url_to_deeplink(
            url, self.coupang_access_key, self.coupang_secret_key, sub_id
        )
        with self._deeplink_cache_lock:
            if len(self._deeplink_url_cache) > 800:
                self._deeplink_url_cache.clear()
            self._deeplink_url_cache[url] = resolved
        return resolved

    def _enrich_coupang_product_deeplink_fields(self, p: CoupangProduct) -> CoupangProduct:
        """단축 URL은 보강하되 AFFSDP 랜딩은 절대 덮어쓰지 않는다.

        프론트는 landing_url이 있으면 그걸 먼저 연다. product_url/deeplink_url은
        기존 클라 호환을 위해 단축 URL을 유지한다.
        """
        short_url, landing_url = split_partner_urls(p.deeplink_url, p.landing_url)
        existing_landing = landing_url or (
            (p.landing_url or "").strip()
            if is_coupang_affsdp_landing_url(p.landing_url)
            else ""
        )

        if short_url.startswith("http"):
            return p.model_copy(
                update={
                    "product_url": short_url,
                    "deeplink_url": short_url,
                    "landing_url": existing_landing or None,
                }
            )
        if existing_landing:
            display = (p.product_url or "").strip() or existing_landing
            return p.model_copy(
                update={
                    "product_url": display,
                    "landing_url": existing_landing,
                }
            )

        base = (p.original_url or "").strip()
        if not base.startswith("http"):
            base = (p.product_url or "").strip()
        if not base.startswith("http") or "coupang.com" not in base.lower():
            return p.model_copy(update={"landing_url": existing_landing or None})

        links = self._cached_partner_links(base)
        resolved_short = (links.get("shorten_url") or "").strip()
        resolved_landing = existing_landing or (links.get("landing_url") or "").strip()
        if not resolved_short.startswith("http"):
            return p.model_copy(update={"landing_url": resolved_landing or None})
        return p.model_copy(
            update={
                "product_url": resolved_short,
                "deeplink_url": resolved_short,
                "landing_url": resolved_landing or None,
                "original_url": p.original_url or base,
            }
        )

    def _cached_partner_links(self, url: str) -> Dict[str, str]:
        """동일 URL의 파트너스 딥링크 API 호출을 프로세스 메모리에서 재사용한다."""
        key = (url or "").strip()
        empty = {"shorten_url": "", "landing_url": ""}
        if not key:
            return empty
        with self._deeplink_cache_lock:
            cached = self._partner_links_cache.get(key)
            if cached is not None:
                return cached
        from services.coupang_service import convert_url_to_partner_links

        links = convert_url_to_partner_links(
            key,
            self.coupang_access_key,
            self.coupang_secret_key,
            self.coupang_partner_subid or "YorigoMobile",
        )
        shorten = (links.get("shorten_url") or "").strip()
        landing = (links.get("landing_url") or "").strip()
        if shorten.startswith("http") or landing.startswith("http"):
            with self._deeplink_cache_lock:
                if len(self._partner_links_cache) > 800:
                    self._partner_links_cache.clear()
                self._partner_links_cache[key] = links
        return links

    def _recommendation_lists(
        self,
        req: ProductSearchRequest,
        sorted_products: List[CoupangProduct],
        best_match: Optional[CoupangProduct],
    ) -> tuple[List[CoupangProduct], List[CoupangProduct]]:
        """see_more 포함 여부에 따라 응답 리스트와 딥링크 보강 대상을 고른다.

        미리보기(include_see_more=False)는 best_match만 보강해 파트너스 API
        호출·페이로드를 재료당 1개로 줄인다. 장바구니는 기존처럼 see_more 전체.
        """
        include_see_more = bool(getattr(req, "include_see_more", True))
        return recommendation_payload_lists(
            include_see_more,
            sorted_products,
            best_match,
            see_more_cap=self.see_more_soft_cap,
        )

    def _enrich_coupang_products_deeplinks_sync(
        self, products: List[CoupangProduct]
    ) -> List[CoupangProduct]:
        return [self._enrich_coupang_product_deeplink_fields(p) for p in products]

    def _enrich_product_search_result_deeplink(self, p: ProductSearchResult) -> ProductSearchResult:
        u = (p.product_url or "").strip()
        if not u.startswith("http") or "coupang.com" not in u.lower():
            return p
        resolved = self._resolve_coupang_partner_deeplink(u)
        if resolved.startswith("http"):
            return p.model_copy(update={"product_url": resolved})
        return p

    def _fire_and_forget(self, coro) -> None:
        """예외를 삼키는 백그라운드 코루틴을 실행하고 태스크 참조를 보관한다.
        (참조를 안 들고 있으면 GC가 실행 중인 태스크를 중간에 회수할 수 있음)."""
        task = asyncio.create_task(coro)
        self._background_tasks.add(task)
        task.add_done_callback(self._background_tasks.discard)

    def _should_record_cart_hit(self, ingredient_name: str) -> bool:
        """디바운스 윈도우 내 동일 재료 재기록을 건너뛴다 (스레드풀/쓰기비용 절약)."""
        key = (ingredient_name or "").strip()
        if not key:
            return False
        now = time.time()
        with self._cart_hit_debounce_lock:
            last = self._cart_hit_last_recorded.get(key, 0.0)
            if now - last < self._cart_hit_debounce_seconds:
                return False
            self._cart_hit_last_recorded[key] = now
            # 무한 성장 방지: 캡 초과 시 가장 오래된 절반 정리.
            if len(self._cart_hit_last_recorded) > 4000:
                oldest = sorted(
                    self._cart_hit_last_recorded.items(), key=lambda kv: kv[1]
                )[: len(self._cart_hit_last_recorded) // 2]
                for k, _ in oldest:
                    self._cart_hit_last_recorded.pop(k, None)
            return True

    async def _run_background_write(self, func: Callable[..., Any], *args: Any) -> None:
        """사용자 응답을 기다리게 하면 안 되는 배경 쓰기(cart-hit 등) 전용 실행기.
        전용 세마포어를 사용해 메인 상품 조회 경로(_to_thread_semaphore)와
        스레드 동시성 슬롯을 공유하지 않는다. 예외는 삼킨다(호출부가 이미
        fire-and-forget으로 실패를 허용하는 부가 기록이므로)."""
        async with self._background_write_semaphore:
            try:
                from blocking_pool import run_blocking_async

                await run_blocking_async(func, *args)
            except Exception:
                pass

    async def _run_to_thread_limited(
        self,
        func: Callable[..., Any],
        *args: Any,
        fallback: Any = None,
        op_name: str = "to_thread_task",
    ) -> Any:
        """동시성 제한 하에서 blocking 함수를 thread로 실행.

        B-2: 3초 이상 걸리는 호출은 [SlowToThread] WARN으로 남김.
        P95/P99 추세를 추적해 외부 호출 timeout 튜닝의 근거로 사용.
        """
        async with self._to_thread_semaphore:
            t0 = time.perf_counter()
            try:
                from blocking_pool import run_blocking_async

                result = await run_blocking_async(func, *args)
                elapsed = time.perf_counter() - t0
                if elapsed > 3.0:
                    logger.warning(
                        "[SlowToThread] op=%s elapsed=%.2fs (limit=%s)",
                        op_name,
                        elapsed,
                        self._to_thread_concurrency,
                    )
                return result
            except RuntimeError as e:
                if "can't start new thread" in str(e).lower():
                    from watchdog import fatal_worker_exit

                    fatal_worker_exit(f"run_blocking_async:{op_name}", exc=e)
                raise

    def _get_excluded_product_ids(self) -> set[str]:
        """전역 제외 상품 ID 목록을 캐시 포함하여 조회.

        만료 직후 여러 스레드(배치/스트림의 동시 항목들)가 몰리는 cache
        stampede를 락으로 방지 — 첫 스레드만 Firestore를 조회하고 나머지는
        락 해제 후 신선해진 캐시를 그대로 재사용한다.
        """
        now = time.time()
        if (
            self._excluded_products_cache is not None
            and now - self._excluded_products_cache_at < self._excluded_products_cache_ttl_seconds
        ):
            return self._excluded_products_cache

        with self._excluded_products_refresh_lock:
            # Double-check: 락 대기 중 다른 스레드가 이미 갱신했을 수 있음.
            now = time.time()
            if (
                self._excluded_products_cache is not None
                and now - self._excluded_products_cache_at < self._excluded_products_cache_ttl_seconds
            ):
                return self._excluded_products_cache

            excluded_ids: set[str] = set()
            try:
                firebase = self.firebase_service
                if firebase is None:
                    from services.firebase_service import get_firebase_service

                    firebase = get_firebase_service()
                if not firebase or not firebase.is_available() or firebase.db is None:
                    self._excluded_products_cache = excluded_ids
                    self._excluded_products_cache_at = now
                    return excluded_ids

                docs = (
                    firebase.db.collection("excluded_products_global")
                    .where(filter=FieldFilter("active", "==", True))
                    .stream()
                )
                for doc in docs:
                    data = doc.to_dict() or {}
                    pid = str(data.get("productId") or doc.id).strip()
                    if pid:
                        excluded_ids.add(pid)
            except Exception as e:
                logger.warning(f"전역 제외 상품 조회 실패: {e}")

            self._excluded_products_cache = excluded_ids
            self._excluded_products_cache_at = now
            return excluded_ids

    def _filter_excluded_raw_products(self, raw_products: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        excluded_ids = self._get_excluded_product_ids()
        if not excluded_ids:
            return raw_products
        filtered: List[Dict[str, Any]] = []
        removed = 0
        for item in raw_products:
            pid = str(item.get("productId", item.get("id", ""))).strip()
            if pid and pid in excluded_ids:
                removed += 1
                continue
            filtered.append(item)
        if removed > 0:
            logger.info(f"전역 제외 상품 필터 적용: {removed}개 제거")
        return filtered

    def _filter_excluded_coupang_products(self, products: List[CoupangProduct]) -> List[CoupangProduct]:
        excluded_ids = self._get_excluded_product_ids()
        if not excluded_ids:
            return products
        filtered = [p for p in products if str(p.product_id).strip() not in excluded_ids]
        removed = len(products) - len(filtered)
        if removed > 0:
            logger.info(f"전역 제외 상품 필터 적용(객체): {removed}개 제거")
        return filtered

    def _filter_excluded_product_search_results(
        self, products: List[ProductSearchResult]
    ) -> List[ProductSearchResult]:
        excluded_ids = self._get_excluded_product_ids()
        if not excluded_ids:
            return products
        filtered = [p for p in products if str(p.product_id).strip() not in excluded_ids]
        removed = len(products) - len(filtered)
        if removed > 0:
            logger.info(f"전역 제외 상품 필터 적용(고급검색): {removed}개 제거")
        return filtered
    
    def generate_coupang_hmac(self, method: str, url: str, secret_key: str = None, access_key: str = None) -> str:
        """Generate HMAC signature for Coupang API authentication"""
        secret_key = secret_key or self.coupang_secret_key
        access_key = access_key or self.coupang_access_key
        
        # Remove domain to get path and query string
        if url.startswith("https://api-gateway.coupang.com"):
            path_with_query = url.replace("https://api-gateway.coupang.com", "")
        else:
            path_with_query = url
        
        # Split path and query string
        path, *query = path_with_query.split("?")
        query_string = query[0] if query else ""
        
        # Generate datetime in format: yymmddTHHMMSSZ
        os_time = time.gmtime()
        datetime_gmt = time.strftime('%y%m%d', os_time) + 'T' + time.strftime('%H%M%S', os_time) + 'Z'
        
        # Create message: datetime + method + path + query_string
        message = datetime_gmt + method + path + (query_string if query_string else "")
        
        # Generate HMAC signature
        signature = hmac.new(
            bytes(secret_key, "utf-8"),
            message.encode("utf-8"),
            hashlib.sha256
        ).hexdigest()
        
        return f"CEA algorithm=HmacSHA256, access-key={access_key}, signed-date={datetime_gmt}, signature={signature}"
    
    def parse_product_size(self, product_name: str) -> Tuple[Optional[float], Optional[str]]:
        """Extract package size and unit from product name. E.g. '500g, 2개' -> (1000, 'g')."""
        patterns = [
            (r'(\d+(?:\.\d+)?)\s*(kg|킬로그램|KG)', False),
            (r'(\d+(?:\.\d+)?)\s*(g|그램)', False),
            (r'(\d+(?:\.\d+)?)\s*(l|리터|L)', False),
            (r'(\d+(?:\.\d+)?)\s*(ml|밀리리터|ML)', False),
            (r'(\d+(?:\.\d+)?)\s*(개입)', False),
            (r'(\d+(?:\.\d+)?)\s*(봉지)', False),
            (r'(\d+(?:\.\d+)?)\s*개(?!입)', True),   # "2개" (개입 제외)
            (r'(\d+(?:\.\d+)?)\s*세트', True),        # "6세트" — pack multiplier like 개
            (r'(\d+(?:\.\d+)?)(kg|킬로그램|KG)(?![a-zA-Z0-9])', False),
            (r'(\d+(?:\.\d+)?)(g|그램)(?![a-zA-Z0-9])', False),
            (r'(\d+(?:\.\d+)?)(l|리터|L)(?![a-zA-Z0-9])', False),
            (r'(\d+(?:\.\d+)?)(ml|밀리리터|ML)(?![a-zA-Z0-9])', False),
        ]
        
        weight_matches = []
        count_ea = None
        
        for pattern, is_count_only in patterns:
            for match in re.finditer(pattern, product_name, re.IGNORECASE):
                size = float(match.group(1))
                unit = match.group(2).lower() if not is_count_only else '개'
                if is_count_only:
                    count_ea = int(size) if size == int(size) else size
                else:
                    weight_matches.append((size, unit, match.start()))
        
        # Ignore unrealistic pack counts (e.g. "100개" is a sales count, not a multiplier).
        if count_ea is not None and count_ea > 30:
            count_ea = None

        # "500g, 2개" 형태: 총량으로 반환 (g 또는 ml)
        if count_ea is not None and count_ea > 0 and weight_matches:
            for size, unit, _ in weight_matches:
                if unit in ['kg', '킬로그램']:
                    return (size * 1000 * count_ea, 'g')
                if unit in ['g', '그램']:
                    return (size * count_ea, 'g')
                if unit in ['l', '리터']:
                    return (size * 1000 * count_ea, 'ml')
                if unit in ['ml', '밀리리터']:
                    return (size * count_ea, 'ml')
        
        if not weight_matches:
            return (None, None)
        
        # Select largest size
        best_match = None
        best_size = 0.0
        
        for size, unit, _ in weight_matches:
            if unit in ['kg', '킬로그램']:
                normalized_size = size * 1000
                normalized_unit = 'g'
            elif unit in ['l', '리터']:
                normalized_size = size * 1000
                normalized_unit = 'ml'
            elif unit in ['g', '그램']:
                normalized_size = size
                normalized_unit = 'g'
            elif unit in ['ml', '밀리리터']:
                normalized_size = size
                normalized_unit = 'ml'
            elif unit in ['개입']:
                normalized_size = size
                normalized_unit = '개'
            elif unit in ['봉지']:
                normalized_size = size
                normalized_unit = '봉지'
            else:
                continue
            
            if normalized_size > best_size:
                best_size = normalized_size
                best_match = (size, unit)
        
        if best_match:
            size, unit = best_match
            if unit in ['kg', '킬로그램']:
                return (size * 1000, 'g')
            elif unit in ['l', '리터']:
                return (size * 1000, 'ml')
            elif unit in ['g', '그램']:
                return (size, 'g')
            elif unit in ['ml', '밀리리터']:
                return (size, 'ml')
            elif unit in ['개입']:
                return (size, '개')
            elif unit in ['봉지']:
                return (size, '봉지')
        
        return (None, None)
    
    def generate_bulk_keyword(self, name: str, amount: Optional[str] = None) -> str:
        """Generate bulk keyword for searching large quantity products"""
        # Default bulk keywords (fallback)
        DEFAULT_BULK_KEYWORDS = ["1kg", "2kg", "3kg", "5kg", "10kg"]
        
        name_lower = name.strip().lower()
        
        # Category B: Parse amount if provided
        if amount:
            pattern = r'(\d+(?:\.\d+)?)\s*(g|kg|ml|l|그램|킬로그램|밀리리터|리터|G|KG|ML|L)'
            match = re.search(pattern, amount, re.IGNORECASE)
            
            if match:
                qty = float(match.group(1))
                unit = match.group(2).lower()
                
                if unit in ['kg', '킬로그램']:
                    base_qty = qty * 1000
                    base_unit = 'g'
                elif unit in ['l', '리터']:
                    base_qty = qty * 1000
                    base_unit = 'ml'
                elif unit in ['g', '그램']:
                    base_qty = qty
                    base_unit = 'g'
                elif unit in ['ml', '밀리리터']:
                    base_qty = qty
                    base_unit = 'ml'
                else:
                    return DEFAULT_BULK_KEYWORDS[0]
                
                if base_unit == 'g':
                    if base_qty < 1000:
                        return "2kg" if base_qty * 2 <= 2000 else "1kg"
                    elif base_qty < 2000:
                        return "3kg"
                    elif base_qty < 5000:
                        return "10kg"
                    else:
                        return f"{int(base_qty / 1000)}kg"
                elif base_unit == 'ml':
                    if base_qty < 1000:
                        return "2L" if base_qty * 2 <= 2000 else "1L"
                    elif base_qty < 2000:
                        return "3L"
                    elif base_qty < 5000:
                        return "10L"
                    else:
                        return f"{int(base_qty / 1000)}L"
                else:
                    return DEFAULT_BULK_KEYWORDS[0]
            else:
                return DEFAULT_BULK_KEYWORDS[0]
        
        # Category C: Fallback
        return DEFAULT_BULK_KEYWORDS[0]
    
    def encode_affiliate_link(self, product_url: str, product_id: Optional[str] = None) -> str:
        """Construct raw Coupang product URL with affiliate tracking"""
        if not product_id and product_url:
            try:
                parsed = urllib.parse.urlparse(product_url)
                if '/vp/products/' in parsed.path:
                    product_id = parsed.path.split('/vp/products/')[-1].split('/')[0].split('?')[0]
                elif not product_id:
                    query_params = urllib.parse.parse_qs(parsed.query)
                    product_id = query_params.get('productId', [None])[0] or query_params.get('product_id', [None])[0]
            except Exception as e:
                logger.warning(f"Could not extract product_id from URL: {e}")
        
        if not product_id:
            if product_url and product_url.startswith(('http://', 'https://')):
                if 'subId=' not in product_url and 'sub_id=' not in product_url:
                    try:
                        parsed = urllib.parse.urlparse(product_url)
                        query_params = urllib.parse.parse_qs(parsed.query)
                        query_params['subId'] = [self.coupang_partner_subid]
                        new_query = urllib.parse.urlencode(query_params, doseq=True)
                        return urllib.parse.urlunparse((
                            parsed.scheme, parsed.netloc, parsed.path,
                            parsed.params, new_query, parsed.fragment
                        ))
                    except Exception:
                        pass
                return product_url
            else:
                logger.warning("No product_id or valid URL provided")
                return ""
        
        raw_product_url = f"https://www.coupang.com/vp/products/{product_id}"
        affiliate_url = f"{raw_product_url}?subId={self.coupang_partner_subid}"
        
        logger.debug(f"Constructed raw Coupang product link: {affiliate_url[:100]}...")
        return affiliate_url
    
    def calculate_match_score(
        self,
        needed_qty: Optional[float],
        needed_unit: Optional[str],
        product_size: Optional[float],
        product_unit: Optional[str],
        product_price: int,
        unit_price: Optional[float] = None,
        avg_unit_price: Optional[float] = None,
        is_rocket: bool = False,
        sales_rank: Optional[int] = None,
        product_name: Optional[str] = None
    ) -> float:
        """
        Calculate match score for a product (0-100)
        
        If product_name is provided and doesn't contain any unit indicators (g, kg, ml, L, 개, 팩, etc.),
        amount match score will be 0.
        """
        score = 0.0
        
        # Check if product name contains unit indicators (for amount score)
        has_unit_in_name = True
        if product_name:
            unit_patterns = [
                r'\d+\s*g\b',  # 숫자 + g (예: 500g, 1kg)
                r'\d+\s*kg\b',  # 숫자 + kg
                r'\d+\s*ml\b',  # 숫자 + ml
                r'\d+\s*L\b',   # 숫자 + L
                r'\d+\s*개\b',   # 숫자 + 개
                r'\d+\s*팩\b',   # 숫자 + 팩
                r'\d+\s*박스\b', # 숫자 + 박스
                r'\d+\s*봉\b',   # 숫자 + 봉
                r'\d+\s*입\b',   # 숫자 + 입
                r'\d+\s*구\b',   # 숫자 + 구
            ]
            has_unit_in_name = any(re.search(pattern, product_name, re.IGNORECASE) for pattern in unit_patterns)
            if not has_unit_in_name:
                logger.debug(f"Product name '{product_name[:50]}' doesn't contain unit indicators, amount match score will be 0")
        
        # Amount match score (25 points max)
        if needed_qty and needed_unit and product_size and product_unit and has_unit_in_name:
            # 양이 표시되어 있는 경우: 정상 계산
            needed_base_qty, needed_base_unit = convert_to_base_unit(needed_qty, needed_unit)
            product_base_qty, product_base_unit = convert_to_base_unit(product_size, product_unit)
            
            if needed_base_unit == product_base_unit:
                ratio = product_base_qty / needed_base_qty
                
                # Scale down from 40 points to 25 points (multiply by 25/40 = 0.625)
                if 0.95 <= ratio <= 1.05:
                    score += 25.0
                elif 1.05 < ratio <= 1.5:
                    score += (35.0 + ((1.5 - ratio) / 0.45) * 5.0) * 0.625
                elif 0.9 <= ratio < 0.95:
                    score += (35.0 + ((ratio - 0.9) / 0.05) * 5.0) * 0.625
                elif 1.5 < ratio <= 2.0:
                    score += (30.0 + ((2.0 - ratio) / 0.5) * 5.0) * 0.625
                elif 0.8 <= ratio < 0.9:
                    score += (25.0 + ((ratio - 0.8) / 0.1) * 5.0) * 0.625
                elif 2.0 < ratio <= 2.5:
                    score += (25.0 + ((2.5 - ratio) / 0.5) * 5.0) * 0.625
                elif 0.7 <= ratio < 0.8:
                    score += (20.0 + ((ratio - 0.7) / 0.1) * 5.0) * 0.625
                elif 2.5 < ratio <= 4.0:
                    score += (15.0 + ((4.0 - ratio) / 1.5) * 10.0) * 0.625
                elif 0.5 <= ratio < 0.7:
                    score += (10.0 + ((ratio - 0.5) / 0.2) * 10.0) * 0.625
                elif 4.0 < ratio <= 10.0:
                    score += max(0.0, (10.0 - ((ratio - 4.0) / 6.0) * 10.0) * 0.625)
                elif ratio < 0.5:
                    score += (5.0 * (ratio / 0.5)) * 0.625
                elif 10.0 < ratio <= 50.0:
                    score += max(0.0, (5.0 - ((ratio - 10.0) / 40.0) * 5.0) * 0.625)
        elif not has_unit_in_name:
            # 상품명에 단위가 없는 경우: 양 점수 0점
            # (양이 표시되지 않은 경우와 구분)
            pass  # 양 점수 0점
        else:
            # 양이 표시되지 않은 경우: 15점만 부여
            score += 15.0
        
        # Price score (40 points max)
        if unit_price is not None and avg_unit_price is not None and avg_unit_price > 0:
            price_ratio = unit_price / avg_unit_price
            if price_ratio <= 0.5:
                score += 40.0
            elif price_ratio <= 0.7:
                score += 30.0 + ((0.7 - price_ratio) / 0.2) * 10.0
            elif price_ratio <= 0.9:
                score += 20.0 + ((0.9 - price_ratio) / 0.2) * 10.0
            elif price_ratio <= 1.1:
                score += 10.0 + ((1.1 - price_ratio) / 0.2) * 10.0
            elif price_ratio <= 1.5:
                score += 5.0 + ((1.5 - price_ratio) / 0.4) * 5.0
            else:
                score += max(0.0, 5.0 - ((price_ratio - 1.5) / 1.0) * 5.0)
        elif unit_price is not None:
            score += 20.0
        else:
            score += 10.0
        
        # Rocket delivery score (20 points max)
        if is_rocket:
            score += 20.0
        
        # Sales rank score (15 points max) - lower rank number = higher score
        # Rank는 1위부터 10위까지만 존재
        if sales_rank is not None and sales_rank > 0:
            if sales_rank <= 1:
                rank_score = 15.0  # 1위: 15점
            elif sales_rank <= 10:
                # 1위=15점, 10위=0점으로 선형 감소
                rank_score = 15.0 * (1.0 - (sales_rank - 1) / 9.0)
            else:
                # 10위 초과는 0점
                rank_score = 0.0
            score += rank_score
        
        return min(score, 100)
    
    def calculate_amount_match_score(
        self,
        needed_qty: Optional[float],
        needed_unit: Optional[str],
        product_size: Optional[float],
        product_unit: Optional[str],
        product_name: Optional[str] = None
    ) -> float:
        """
        Calculate how well the product amount matches the needed amount (0-100)
        
        If product_name is provided and doesn't contain any unit indicators (g, kg, ml, L, 개, 팩, etc.),
        returns 0.0 immediately.
        """
        # Check if product name contains unit indicators
        if product_name:
            # Check for common unit patterns in product name
            unit_patterns = [
                r'\d+\s*g\b',  # 숫자 + g (예: 500g, 1kg)
                r'\d+\s*kg\b',  # 숫자 + kg
                r'\d+\s*ml\b',  # 숫자 + ml
                r'\d+\s*L\b',   # 숫자 + L
                r'\d+\s*개\b',   # 숫자 + 개
                r'\d+\s*팩\b',   # 숫자 + 팩
                r'\d+\s*박스\b', # 숫자 + 박스
                r'\d+\s*봉\b',   # 숫자 + 봉
                r'\d+\s*입\b',   # 숫자 + 입
                r'\d+\s*구\b',   # 숫자 + 구
            ]
            has_unit = any(re.search(pattern, product_name, re.IGNORECASE) for pattern in unit_patterns)
            if not has_unit:
                logger.debug(f"Product name '{product_name[:50]}' doesn't contain unit indicators, returning 0.0 for amount match score")
                return 0.0
        
        if not needed_qty or not needed_unit or not product_size or not product_unit:
            return 0.0
        
        needed_base_qty, needed_base_unit = convert_to_base_unit(needed_qty, needed_unit)
        product_base_qty, product_base_unit = convert_to_base_unit(product_size, product_unit)
        
        if needed_base_unit != product_base_unit:
            return 0.0
        
        ratio = product_base_qty / needed_base_qty
        
        if 0.95 <= ratio <= 1.05:
            return 100.0
        elif 1.05 < ratio <= 1.5:
            return 85.0 + ((1.5 - ratio) / 0.45) * 15.0
        elif 0.9 <= ratio < 0.95:
            return 85.0 + ((ratio - 0.9) / 0.05) * 15.0
        elif 1.5 < ratio <= 2.0:
            return 70.0 + ((2.0 - ratio) / 0.5) * 15.0
        elif 0.8 <= ratio < 0.9:
            return 60.0 + ((ratio - 0.8) / 0.1) * 10.0
        elif 2.0 < ratio <= 2.5:
            return 60.0 + ((2.5 - ratio) / 0.5) * 10.0
        elif 0.7 <= ratio < 0.8:
            return 50.0 + ((ratio - 0.7) / 0.1) * 10.0
        elif 2.5 < ratio <= 4.0:
            return 40.0 + ((4.0 - ratio) / 1.5) * 20.0
        elif 0.5 <= ratio < 0.7:
            return 30.0 + ((ratio - 0.5) / 0.2) * 20.0
        elif 4.0 < ratio <= 10.0:
            return max(0.0, 20.0 - ((ratio - 4.0) / 6.0) * 20.0)
        elif ratio < 0.5:
            return 10.0 * (ratio / 0.5)
        elif 10.0 < ratio <= 50.0:
            return max(0.0, 10.0 - ((ratio - 10.0) / 40.0) * 10.0)
        else:
            return 0.0
    
    def _extract_product_id_from_url(self, url: str) -> str:
        """Extract product ID from URL"""
        match = re.search(r'/products/(\d+)', url)
        if match:
            return match.group(1)
        return hashlib.md5(url.encode()).hexdigest()[:16]
    
    def _extract_prefixes_from_product_name(self, product_name: str, ingredient_name: str) -> List[str]:
        """
        상품명에서 접두사를 추출합니다. 띄어쓰기가 없어도 동작합니다.
        
        로직:
        1. 재료명의 위치를 찾습니다 (띄어쓰기 무시)
        2. 재료명 앞부분을 추출합니다
        3. 앞부분에서 접두사를 매칭합니다 (띄어쓰기 무시)
        
        예시:
            "국산 세척 배추 1kg" -> ["국산", "세척"]
            "국산세척배추 1kg" -> ["국산", "세척"]
            "유기농쌀 10kg" -> ["유기농"]
            "배추 1kg" -> []
            "국산 배추무농약 1kg" -> ["국산"]
        
        Args:
            product_name: 상품명
            ingredient_name: 재료명 (예: "배추", "쌀")
            
        Returns:
            찾은 접두사 리스트 (띄어쓰기 제거된 순수 접두사)
        """
        # 재료명의 카테고리 확인
        category = INGREDIENT_MAPPING.get(ingredient_name, "VEG_WEIGHT")
        possible_prefixes = PREFIXES.get(category, [""])
        
        # 빈 접두사 제거 및 정렬 (긴 것부터 - "무항생제"를 "무"보다 먼저)
        prefix_list = sorted([p.strip() for p in possible_prefixes if p.strip()], 
                            key=len, reverse=True)
        
        if not prefix_list:
            return []
        
        # 상품명과 재료명을 모두 띄어쓰기 제거하여 비교
        product_name_clean = product_name.replace(" ", "").replace("\t", "")
        ingredient_name_clean = ingredient_name.replace(" ", "")
        
        # 재료명의 위치 찾기 (띄어쓰기 무시)
        ingredient_index = product_name_clean.find(ingredient_name_clean)
        
        if ingredient_index == -1:
            # 재료명을 찾을 수 없으면 빈 리스트 반환
            return []
        
        # 재료명 앞부분 추출 (띄어쓰기 제거된 버전)
        prefix_part_clean = product_name_clean[:ingredient_index]
        
        if not prefix_part_clean:
            return []
        
        # 접두사 매칭 (띄어쓰기 제거된 텍스트에서)
        found_prefixes = []
        remaining_text = prefix_part_clean
        
        for prefix in prefix_list:
            prefix_clean = prefix.replace(" ", "").replace("\t", "")
            
            if not prefix_clean:
                continue
            
            # 접두사가 남은 텍스트에 포함되어 있는지 확인
            if prefix_clean in remaining_text:
                found_prefixes.append(prefix.strip())  # 원본 접두사 저장 (띄어쓰기 포함)
                # 매칭된 부분 제거 (중복 방지)
                remaining_text = remaining_text.replace(prefix_clean, "", 1)
        
        # 중복 제거 및 원래 순서 유지
        seen = set()
        unique_prefixes = []
        for prefix in found_prefixes:
            if prefix not in seen:
                seen.add(prefix)
                unique_prefixes.append(prefix)
        
        return unique_prefixes
    
    def _get_similar_words(self, ingredient_name: str) -> List[str]:
        """
        Get similar words for an ingredient name.
        Returns a list of words that should be considered equivalent for filtering.
        
        Args:
            ingredient_name: The ingredient name to find similar words for
            
        Returns:
            List of similar words (including the original word)
        """
        if not ingredient_name:
            return []
        
        ingredient_lower = ingredient_name.lower().strip()
        
        # Check if ingredient name is in the similar words map
        if ingredient_lower in SIMILAR_WORDS_MAP:
            return SIMILAR_WORDS_MAP[ingredient_lower]
        
        # Check if any similar word group contains this ingredient
        for similar_group in SIMILAR_WORDS_MAP.values():
            if ingredient_lower in similar_group:
                return similar_group
        
        # No similar words found, return just the original word
        return [ingredient_name]

    @staticmethod
    def _top_percent_count(length: int, ratio: float) -> int:
        if length <= 0:
            return 0
        return max(1, int((length * ratio) + 0.999999))

    def _normalize_volume(self, package_size: Optional[float], package_unit: Optional[str]) -> Tuple[Optional[float], Optional[str]]:
        if not package_size or not package_unit:
            return None, None
        try:
            base_qty, base_unit = convert_to_base_unit(package_size, package_unit)
            return float(base_qty), str(base_unit)
        except Exception:
            return None, None

    def _infer_large_category(self, ingredient_name: str, product_name: str) -> str:
        mapped = INGREDIENT_MAPPING.get((ingredient_name or "").strip(), "")
        if mapped in {"MEAT"}:
            return "meat"
        if mapped in {"SEAFOOD"}:
            return "fish"
        if mapped in {"VEG_WEIGHT", "VEG_COUNT"}:
            return "produce"

        name = (product_name or "").lower()
        if any(k in name for k in ["삼겹", "목살", "소고기", "닭", "돼지", "우삼겹", "한우"]):
            return "meat"
        if any(k in name for k in ["고등어", "갈치", "오징어", "새우", "생선", "연어", "참치"]):
            return "fish"
        if any(k in name for k in ["양파", "감자", "배추", "대파", "당근", "과일", "사과", "바나나"]):
            return "produce"
        return "others"

    def _sort_and_attach_final_tags(
        self,
        products: List[CoupangProduct],
        ingredient_name: str,
        needed_qty: Optional[float],
        needed_unit: Optional[str],
    ) -> List[CoupangProduct]:
        if not products:
            return []

        # 0) 공통 전처리
        valid_ratings = [p.rating for p in products if p.rating is not None]
        global_avg_rating = (sum(valid_ratings) / len(valid_ratings)) if valid_ratings else 0.0
        bayesian_c = 50.0

        for p in products:
            volume_base, volume_unit = self._normalize_volume(p.package_size, p.package_unit)
            p.volume_g = volume_base if volume_base and volume_base > 0 else None
            if p.volume_g and p.volume_g > 0:
                # 100g(or ml) 단위 단가
                p.unit_price = (p.product_price / p.volume_g) * 100.0

            rating_val = float(p.rating) if p.rating is not None else 0.0
            review_val = float(max(p.reviews or 0, 0))
            m = global_avg_rating
            p.bayesian_rating = (review_val / (review_val + bayesian_c)) * rating_val + (
                bayesian_c / (review_val + bayesian_c)
            ) * m
            if p.unit_price and p.unit_price > 0:
                p.value_score = p.bayesian_rating / p.unit_price
            else:
                p.value_score = None

        tags_by_id: Dict[str, List[str]] = {p.product_id: [] for p in products}

        def add_tag(pid: str, tag: str):
            if not tag:
                return
            arr = tags_by_id.setdefault(pid, [])
            if tag not in arr:
                arr.append(tag)

        # 1) 가성비 최고: 상위 30%
        value_candidates = [p for p in products if p.value_score is not None]
        value_candidates.sort(key=lambda x: x.value_score or 0.0, reverse=True)
        top_n_value = self._top_percent_count(len(value_candidates), 0.3)
        for i in range(min(top_n_value, len(value_candidates))):
            add_tag(value_candidates[i].product_id, "가성비 최고")

        # 2) 단가 낮은: 최저 단가 * 1.3 이하
        unit_candidates = [p for p in products if p.unit_price is not None and p.unit_price > 0]
        if unit_candidates:
            min_unit_price = min((p.unit_price or 0.0) for p in unit_candidates)
            threshold = min_unit_price * 1.3
            for p in unit_candidates:
                if (p.unit_price or 0.0) <= threshold:
                    add_tag(p.product_id, "단가 낮은")

        # 3) 많이 산: 리뷰수 상위 30%
        pop_candidates = [p for p in products if (p.reviews or 0) > 0]
        pop_candidates.sort(key=lambda x: x.reviews or 0, reverse=True)
        top_n_pop = self._top_percent_count(len(pop_candidates), 0.3)
        for i in range(min(top_n_pop, len(pop_candidates))):
            add_tag(pop_candidates[i].product_id, "많이 산")

        # 4) 국내산: 상품명 키워드 휴리스틱
        domestic_keywords = ["국내산", "국산", "국내", "한국산"]
        for p in products:
            text = (p.product_name or "").lower()
            if any(kw in text for kw in domestic_keywords):
                add_tag(p.product_id, "국내산")

        # 5) 대용량
        meat_like = []
        produce = []
        others = []
        for p in products:
            if not p.volume_g or p.volume_g <= 0:
                continue
            cat = self._infer_large_category(ingredient_name, p.product_name)
            if cat in {"meat", "fish"}:
                meat_like.append(p)
            elif cat == "produce":
                produce.append(p)
            else:
                others.append(p)

        def mark_large_with_fallback(items: List[CoupangProduct], fixed_threshold: Optional[float], fallback_ratio: float, min_threshold: float = 0.0):
            if not items:
                return
            selected = [p for p in items if fixed_threshold is not None and (p.volume_g or 0.0) >= fixed_threshold]
            if not selected:
                sorted_items = sorted(items, key=lambda x: x.volume_g or 0.0, reverse=True)
                idx = self._top_percent_count(len(sorted_items), fallback_ratio) - 1
                cutoff = sorted_items[max(0, idx)].volume_g or float("inf")
                selected = [p for p in items if (p.volume_g or 0.0) >= cutoff]
            for p in selected:
                if (p.volume_g or 0.0) >= min_threshold:
                    add_tag(p.product_id, "대용량")

        mark_large_with_fallback(meat_like, fixed_threshold=2000.0, fallback_ratio=0.2)
        mark_large_with_fallback(produce, fixed_threshold=1000.0, fallback_ratio=0.2)
        mark_large_with_fallback(others, fixed_threshold=None, fallback_ratio=0.3, min_threshold=500.0)

        # 6) 딱 필요한 양
        required_base_qty = None
        required_base_unit = None
        if needed_qty and needed_unit:
            try:
                required_base_qty, required_base_unit = convert_to_base_unit(needed_qty, needed_unit)
            except Exception:
                required_base_qty, required_base_unit = None, None
        if required_base_qty and required_base_qty > 0 and required_base_unit:
            for p in products:
                if not p.package_size or not p.package_unit:
                    continue
                try:
                    product_base_qty, product_base_unit = convert_to_base_unit(p.package_size, p.package_unit)
                except Exception:
                    continue
                if product_base_unit != required_base_unit:
                    continue
                if product_base_qty < required_base_qty:
                    continue
                diff = product_base_qty - required_base_qty
                r = float(required_base_qty)
                abs_limit = max(r, 0.5 * r + 200.0)
                if r <= 300.0:
                    low_need_floor = 300.0 + 0.65 * (300.0 - r)
                    abs_limit = max(abs_limit, low_need_floor)
                    if r < 100.0:
                        abs_limit = max(abs_limit, min(580.0, 12.0 * r))
                if diff > abs_limit:
                    continue
                if r < 200.0:
                    max_multiple = 12.0
                elif r <= 300.0:
                    max_multiple = 6.5
                else:
                    max_multiple = 2.75
                if product_base_qty > max_multiple * r:
                    continue
                add_tag(p.product_id, "딱 필요한 양")

        for p in products:
            final_tags: List[str] = []
            priority_tags = ["딱 필요한 양", "가성비 최고", "단가 낮은", "많이 산", "국내산", "대용량"]
            for t in priority_tags:
                if t in tags_by_id.get(p.product_id, []):
                    final_tags.append(t)
            if p.is_rocket:
                final_tags.append("로켓프레시")
            if p.is_free_shipping:
                final_tags.append("무료배송")
            p.tag = ", ".join(final_tags)

        def sort_key(p: CoupangProduct) -> Tuple:
            tag_set = set(tags_by_id.get(p.product_id, []))
            return (
                0 if "딱 필요한 양" in tag_set else 1,
                0 if "가성비 최고" in tag_set else 1,
                0 if "단가 낮은" in tag_set else 1,
                0 if "많이 산" in tag_set else 1,
                0 if "국내산" in tag_set else 1,
                0 if "대용량" in tag_set else 1,
                -(p.value_score or 0.0),
                (p.unit_price or float("inf")),
                -(p.reviews or 0),
            )

        return sorted(products, key=sort_key)

    @staticmethod
    def _coupang_display_tag_count(p: CoupangProduct) -> int:
        s = (p.tag or "").strip()
        if not s:
            return 0
        return len([x for x in s.split(", ") if x.strip()])

    @staticmethod
    def _coupang_has_close_amount_tag(p: CoupangProduct) -> bool:
        parts = [x.strip() for x in (p.tag or "").split(",")]
        return "딱 필요한 양" in parts

    def _pick_coupang_best_from_cheapest_tag_pool(
        self,
        sorted_for_see_more: List[CoupangProduct],
    ) -> Optional[CoupangProduct]:
        """
        쿠팡 best_match 전용: 절대가격이 낮은 순으로 3~5개 후보를 두고,
        그 안에서 (1) 딱 필요한 양 태그 유무 (2) 화면 태그 개수 순으로 고른다.
        (see_more 정렬은 sorted_for_see_more 그대로 유지)
        """
        if not sorted_for_see_more:
            return None
        big = 2**62

        def price_sort_key(p: CoupangProduct) -> Tuple:
            pr = p.product_price if (p.product_price or 0) > 0 else big
            return (pr, p.product_id)

        by_price = sorted(sorted_for_see_more, key=price_sort_key)
        n = len(by_price)
        if n < 3:
            pool = by_price
        else:
            pool_size = max(3, min(5, n))
            pool = by_price[:pool_size]

        return max(
            pool,
            key=lambda p: (
                1 if self._coupang_has_close_amount_tag(p) else 0,
                self._coupang_display_tag_count(p),
                p.reviews or 0,
                -((p.product_price if (p.product_price or 0) > 0 else big)),
                p.product_id,
            ),
        )

    def _apply_see_more_soft_cap(self, products: List[CoupangProduct]) -> List[CoupangProduct]:
        cap = self.see_more_soft_cap
        if cap and cap > 0:
            return products[:cap]
        return products
    
    def _convert_to_coupang_partners_link(self, original_url: str) -> str:
        """Convert Coupang product URL to Partners affiliate link"""
        product_id = self._extract_product_id_from_url(original_url)
        if product_id:
            return self.encode_affiliate_link(original_url, product_id)
        return original_url
    
    def _get_mock_coupang_products(self, query: str, limit: int = 10) -> List[Dict[str, Any]]:
        """Generate mock product data for testing"""
        package_sizes = [
            (500, "g"), (1000, "g"), (300, "g"), (200, "g"),
            (1, "kg"), (2, "kg"), (500, "ml"), (1000, "ml"),
            (1, "L"), (2, "L")
        ]
        
        mock_products = []
        for i in range(min(limit, 50)):
            size, unit = random.choice(package_sizes)
            price = random.randint(2000, 8000)
            rating = round(random.uniform(3.5, 5.0), 1)
            reviews = random.randint(50, 1000)
            
            if unit in ["g", "kg"]:
                display_name = f"{query} {size}kg" if unit == "kg" else f"{query} {size}g"
            else:
                display_name = f"{query} {size}L" if unit == "L" else f"{query} {size}ml"
            
            mock_product_id = f"{1000000 + (i+1) * 1000 + (hash(query) % 1000)}"
            mock_url = ""
            
            mock_products.append({
                "productId": mock_product_id,
                "productName": display_name,
                "productPrice": price,
                "productImage": "https://via.placeholder.com/200?text=" + query.replace(" ", "+"),
                "productUrl": mock_url,
                "rating": rating,
                "reviewCount": reviews
            })
        
        return mock_products
    
    def get_cached_search_results(self, query: str) -> Optional[List[Dict[str, Any]]]:
        """Check Firestore cache for search query results"""
        if not self.firebase_service:
            return None
        return self.firebase_service.get_cached_search_results(
            query, 
            cache_collection=self.cache_collection, 
            ttl_hours=self.cache_ttl_hours
        )
    
    def save_search_results_to_cache(self, query: str, results: List[Dict[str, Any]], ingredient_name: Optional[str] = None):
        """Save search results to Firestore cache"""
        if not self.firebase_service:
            return
        self.firebase_service.save_search_results_to_cache(query, results, ingredient_name=ingredient_name)
    
    async def recommend_products(self, req: ProductSearchRequest) -> ProductRecommendationResponse:
        """
        Recommend products using scheduler's queries for the ingredient.
        
        This method:
        - Generates queries for the ingredient (same as scheduler, 카테고리별로 개수 다름)
        - Fetches all cached results for this ingredient name from Firestore
        - Calculates match scores based on needed quantity/unit
        - Selects best products for recommendation
        
        Args:
            req: ProductSearchRequest with ingredient_name, needed_qty, needed_unit, marketplace
            
        Returns:
            ProductRecommendationResponse with best match and see_more_list
        """
        marketplace = (req.marketplace or "coupang").strip().lower()
        if marketplace == "kurly":
            return await self._recommend_products_kurly(req)

        # Record cart hit for tier-based scraping prioritization.
        # Fire-and-forget + long debounce (~29 days, matches the 30-day tier
        # promotion window in coupang_utils.classify_tier): the write itself
        # now targets a dedicated per-ingredient doc (no read, no shared
        # array rewrite), but it must still never block the user-facing
        # recommendation response, and repeat searches of the same
        # ingredient within _cart_hit_debounce_seconds skip the write
        # entirely since more frequent updates give no additional signal.
        wants_cart_hit = bool(getattr(req, "record_cart_hit", True))
        if wants_cart_hit and self._should_record_cart_hit(req.ingredient_name or ""):
            from services.firebase_service import get_firebase_service

            self._fire_and_forget(
                self._run_background_write(
                    get_firebase_service().update_scraping_ingredient_cart_hit,
                    req.ingredient_name or "",
                )
            )

        display_name = normalize_cart_display_name(req.ingredient_name or "")

        logger.info(f"Starting recommendation for: {req.ingredient_name} (display: {display_name}, needed: {req.needed_qty} {req.needed_unit})")
        
        # 먼저 스크래핑 결과 조회
        from services.coupang_service import get_scraped_products_for_ingredient
        scraped_products = await self._run_to_thread_limited(
            get_scraped_products_for_ingredient,
            req.ingredient_name,
            fallback=[],
            op_name="get_scraped_products_for_ingredient",
        )
        
        # 스크래핑 결과만 사용 (쿠팡 API 요청 로직은 주석처리)
        all_raw_products = []
        use_scraped = len(scraped_products) > 0
        
        if use_scraped:
            logger.debug(f"스크래핑 결과 {len(scraped_products)}개 상품 발견, 스크래핑 결과 사용")
            # 스크래핑 결과를 raw_product 형태로 변환 (추가 정보 포함)
            for product in scraped_products:
                all_raw_products.append({
                    "productId": product.product_id,
                    "productName": product.product_name,
                    "productPrice": product.product_price,  # 실제 가격
                    "productImage": product.product_image,
                    "productUrl": product.product_url,
                    # Keep original/deeplink split so frontend link policy can switch correctly.
                    "link": product.original_url or product.product_url,
                    "deeplinkUrl": product.deeplink_url or "",
                    "landingUrl": product.landing_url or "",
                    "isRocket": product.is_rocket,
                    "isFreeShipping": product.is_free_shipping,
                    "rank": product.sales_rank,
                    "unitPrice": product.unit_price,  # 단위당 가격
                    "packageSize": product.package_size,
                    "packageUnit": product.package_unit,
                    # 스크래핑 데이터에서 가져온 추가 정보 포함
                    "rating": product.rating,
                    "reviews": product.reviews,
                    "isRocketFresh": product.is_rocket,
                    "arrivalInfo": product.arrival_info,
                    "originalPrice": product.original_price,
                    "discountRate": product.discount_rate,
                    "delivery_text_raw": product.delivery_text_raw,
                    "delivery_eta_days": product.delivery_eta_days,
                })
        else:
            logger.debug("스크래핑 결과 없음, 상품 없음으로 처리")
            # 쿠팡 API 요청 로직 주석처리 (당분간 작동 안함)
            # 스크래핑 데이터가 없으면 상품이 없다는 것으로 처리
    #     elif not req.original_ingredient_name:
            #         # If no original name provided, use preprocessed name
            #         preprocessed_results = await asyncio.to_thread(
            #             self.firebase_service.get_cached_results_by_ingredient,
            #             req.ingredient_name,
            #             self.cache_collection,
            #             self.cache_ttl_hours
            #         )
            #         if preprocessed_results:
            #             all_raw_products.extend(preprocessed_results)
            #     
            #     # Remove duplicates by productId
            #     if all_raw_products:
            #         seen_ids = set()
            #         unique_products = []
            #         for product in all_raw_products:
            #             product_id = str(product.get("productId", product.get("id", "")))
            #             if product_id and product_id not in seen_ids:
            #                 seen_ids.add(product_id)
            #                 unique_products.append(product)
            #         all_raw_products = unique_products
        all_raw_products = await self._run_to_thread_limited(
            self._filter_excluded_raw_products,
            all_raw_products,
            fallback=[],
            op_name="filter_excluded_raw_products",
        )
        logger.debug(f"Collected {len(all_raw_products)} unique products for ingredient '{req.ingredient_name}'")
        
        if not all_raw_products:
            ingredient_stripped = (req.ingredient_name or "").strip()
            if ingredient_stripped:
                def _queue_missing_ingredient() -> None:
                    try:
                        from services.firebase_service import get_firebase_service
                        fb = get_firebase_service()
                        fb.add_priority_scraping_ingredient(ingredient_stripped, source="cart")
                        if ingredient_stripped not in _load_all_ingredients():
                            fb.add_scraping_ingredient(ingredient_stripped, freq=1, source="cart")
                    except Exception as e:
                        logger.debug(f"Could not queue missing ingredient (non-fatal): {e}")
                await self._run_to_thread_limited(
                    _queue_missing_ingredient,
                    fallback=None,
                    op_name="queue_missing_ingredient",
                )
            logger.warning(f"No products found in cache for {req.ingredient_name}")
            return ProductRecommendationResponse(
                ingredient=req.ingredient_name,
                display_name=display_name,
                needed_qty=req.needed_qty,
                needed_unit=req.needed_unit,
                best_match=None,
                see_more_list=[],
                all_products=[]
            )
        
        # Parse and enrich products
        products: List[CoupangProduct] = []
        unit_prices = []
        
        # Normalize ingredient name for filtering
        # 원본 재료명이 있으면 그것을 사용, 없으면 전처리된 재료명 사용
        filter_ingredient_name = req.original_ingredient_name if req.original_ingredient_name else req.ingredient_name
        ingredient_name_lower = filter_ingredient_name.lower().strip() if filter_ingredient_name else ""
        ingredient_name_clean = ingredient_name_lower.replace(" ", "").replace("\t", "") if ingredient_name_lower else ""
        
        # 유사 단어 목록 생성
        similar_words = self._get_similar_words(filter_ingredient_name)
        similar_words_clean = [word.lower().replace(" ", "").replace("\t", "") for word in similar_words]
        
        logger.debug(f"Filtering products for ingredient: original='{req.original_ingredient_name}', preprocessed='{req.ingredient_name}', using for filter='{filter_ingredient_name}' (normalized: '{ingredient_name_clean}')")
        logger.debug(f"Similar words for filtering: {similar_words}")
        logger.debug(f"Total products before filtering: {len(all_raw_products)}")
        
        filtered_count = 0
        for raw_product in all_raw_products:
            product_id = str(raw_product.get("productId", raw_product.get("id", "")))
            product_name = raw_product.get("productName", raw_product.get("name", ""))
            
            # 필터링: 재료명이 제공된 경우, 상품 이름에 재료명 또는 유사 단어가 포함되어 있는지 확인
            if ingredient_name_clean:
                if not product_name:
                    logger.debug(f"Skipping product (no product name): productId={product_id}")
                    filtered_count += 1
                    continue
                    
                product_name_lower = product_name.lower()
                product_name_clean = product_name_lower.replace(" ", "").replace("\t", "")
                
                # 원본 단어 또는 유사 단어 중 하나라도 포함되어 있는지 확인
                found_match = False
                matched_word = None
                
                # 원본 단어 확인
                if ingredient_name_clean in product_name_clean:
                    found_match = True
                    matched_word = filter_ingredient_name
                else:
                    # 유사 단어 확인
                    for idx, similar_word_clean in enumerate(similar_words_clean):
                        if similar_word_clean and similar_word_clean in product_name_clean:
                            found_match = True
                            matched_word = similar_words[idx]  # 원본 단어 사용
                            break
                
                if not found_match:
                    logger.debug(f"FILTERED OUT: productId={product_id}, productName='{product_name[:50]}', ingredient='{filter_ingredient_name}' (normalized: '{ingredient_name_clean}') and similar words not in product name (normalized: '{product_name_clean[:50]}')")
                    filtered_count += 1
                    continue
                else:
                    logger.debug(f"PASSED FILTER: productId={product_id}, productName='{product_name[:50]}', matched word='{matched_word}' for ingredient='{filter_ingredient_name}'")
            else:
                logger.warning(f"No ingredient name provided for filtering, skipping filter check for productId={product_id}")
            
            product_price = int(raw_product.get("productPrice", raw_product.get("price", 0)))
            product_image = raw_product.get("productImage", raw_product.get("imageUrl", ""))
            
            deeplink_url, landing_url = extract_partner_urls_from_scraped(raw_product)
            original_url = raw_product.get(
                "link",
                raw_product.get("productUrl", raw_product.get("url", "")),
            )
            product_url = raw_product.get("productUrl", raw_product.get("url", ""))
            if deeplink_url:
                product_url = deeplink_url
            elif landing_url:
                product_url = landing_url
            
            is_rocket = raw_product.get("isRocket", False)
            is_free_shipping = raw_product.get("isFreeShipping", False)
            rank = raw_product.get("rank", None)
            if rank:
                try:
                    rank = int(rank)
                except (ValueError, TypeError):
                    rank = None
            
            # 스크래핑 데이터에서 추가 정보 가져오기
            original_price = raw_product.get("originalPrice")
            if original_price:
                try:
                    original_price = int(original_price)
                except (ValueError, TypeError):
                    original_price = None
            
            discount_rate = raw_product.get("discountRate")
            if discount_rate:
                try:
                    discount_rate = float(discount_rate)
                except (ValueError, TypeError):
                    discount_rate = None
            
            rating = raw_product.get("rating")
            if rating:
                try:
                    rating = float(rating)
                except (ValueError, TypeError):
                    rating = None
            
            reviews = raw_product.get("reviews")
            if reviews:
                try:
                    reviews = int(reviews)
                except (ValueError, TypeError):
                    reviews = None
            
            arrival_info = raw_product.get("arrivalInfo")
            delivery_text_raw = raw_product.get("delivery_text_raw")
            delivery_eta_days = raw_product.get("delivery_eta_days")
            
            final_product_url = product_url if product_url and product_url.startswith('http') else ""
            package_size, package_unit = self.parse_product_size(product_name)
            
            unit_price = None
            if package_size and package_size > 0:
                unit_price = product_price / package_size
                unit_prices.append(unit_price)
            
            product = CoupangProduct(
                product_id=product_id,
                product_name=product_name,
                product_price=product_price,
                product_image=product_image,
                product_url=final_product_url,
                original_url=original_url if isinstance(original_url, str) and original_url.startswith("http") else None,
                deeplink_url=deeplink_url if isinstance(deeplink_url, str) and deeplink_url.startswith("http") else None,
                landing_url=landing_url if landing_url.startswith("http") else None,
                is_rocket=is_rocket,
                is_free_shipping=is_free_shipping,
                unit_price=unit_price,
                package_size=package_size,
                package_unit=package_unit,
                match_score=0.0,
                tag=None,
                sales_rank=rank,
                original_price=original_price,
                discount_rate=discount_rate,
                rating=rating,
                reviews=reviews,
                arrival_info=arrival_info,
                delivery_text_raw=delivery_text_raw,
                delivery_eta_days=int(delivery_eta_days) if delivery_eta_days is not None else None,
            )
            
            products.append(product)
        
        logger.info(f"Filtered out {filtered_count} products, {len(products)} products remaining after filtering")
        
        # Calculate average unit price
        avg_unit_price = None
        if unit_prices:
            avg_unit_price = sum(unit_prices) / len(unit_prices)
        
        # Calculate match scores based on needed quantity/unit
        logger.debug(f"Calculating match scores for {len(products)} products (use_scraped={use_scraped})")
        
        if use_scraped:
            # 스크래핑 결과 사용 시: calculate_scraping_product_score 사용.
            # all_raw_products는 이미 get_scraped_products_for_ingredient 단계에서
            # rating/reviews/originalPrice/discountRate/arrivalInfo/deeplinkUrl 등을
            # 모두 채워서 반환하므로, 같은 coupang_products 컬렉션을 재쿼리하지 않음
            # (재료당 Firestore read 2회 → 1회).
            from services.coupang_service import calculate_scraping_product_score

            max_reviews = 0
            for product in products:
                reviews = product.reviews
                if reviews is not None and isinstance(reviews, (int, float)):
                    max_reviews = max(max_reviews, int(reviews))

            for product in products:
                match_score = calculate_scraping_product_score(
                    needed_qty=req.needed_qty,
                    needed_unit=req.needed_unit,
                    product_size=product.package_size,
                    product_unit=product.package_unit,
                    unit_price=product.unit_price,
                    avg_unit_price=avg_unit_price,
                    is_rocket_fresh=product.is_rocket,
                    is_free_shipping=product.is_free_shipping,
                    rank=product.sales_rank,
                    rating=product.rating,
                    reviews=product.reviews,
                    max_reviews=max_reviews if max_reviews > 0 else None,
                    product_name=product.product_name,
                )
                product.match_score = match_score
        else:
            # API 결과 사용 시: 기존 calculate_match_score 사용
            for product in products:
                match_score = self.calculate_match_score(
                    req.needed_qty,
                    req.needed_unit,
                    product.package_size,
                    product.package_unit,
                    product.product_price,
                    unit_price=product.unit_price,
                    avg_unit_price=avg_unit_price,
                    is_rocket=product.is_rocket,
                    sales_rank=product.sales_rank,
                    product_name=product.product_name  # 상품명 전달하여 단위 포함 여부 확인
                )
                product.match_score = match_score
        
        products = self._filter_excluded_coupang_products(products)

        # 태그 계산 + 정렬(요구사항 기준) 후 전체 후보 반환
        sorted_products = self._sort_and_attach_final_tags(
            products,
            ingredient_name=req.original_ingredient_name or req.ingredient_name,
            needed_qty=req.needed_qty,
            needed_unit=req.needed_unit,
        )
        best_match = self._pick_coupang_best_from_cheapest_tag_pool(sorted_products)
        see_more_list, combined = self._recommendation_lists(
            req, sorted_products, best_match
        )

        logger.info(f"[Tags] ingredient={req.ingredient_name} best_match tag={best_match.tag if best_match else None}")
        if see_more_list:
            for i, p in enumerate(see_more_list[:10]):
                logger.info(f"[Tags]   see_more[{i}] name={p.product_name[:50]}... tag={p.tag!r}")
        logger.info(f"Selected best_match (score: {best_match.match_score if best_match else 0:.2f})")
        logger.debug(f"Returning {len(see_more_list)} products in see_more_list")

        if combined:
            enriched = await self._run_to_thread_limited(
                self._enrich_coupang_products_deeplinks_sync,
                combined,
                fallback=combined,
                op_name="coupang_deeplink_enrich",
            )
            if isinstance(enriched, list) and enriched:
                if best_match:
                    best_match = enriched[0]
                    see_more_list = enriched[1:]
                else:
                    see_more_list = enriched

        return ProductRecommendationResponse(
            ingredient=req.ingredient_name,
            display_name=display_name,
            needed_qty=req.needed_qty,
            needed_unit=req.needed_unit,
            best_match=best_match,
            see_more_list=see_more_list,
            all_products=see_more_list
        )

    async def recommend_products_batch(
        self, items: List[ProductSearchRequest]
    ) -> List[ProductRecommendationResponse]:
        """
        여러 재료를 한 번의 HTTP 호출로 처리. 내부적으로는 기존 recommend_products를
        병렬 실행. 동시성은 _to_thread_semaphore가 제어.
        Coupang/Kurly가 섞여 있어도 marketplace 디스패치는 recommend_products가 처리.

        A-2: 3계층 타임아웃 적용
          - 가장 안쪽 5s: Firestore SDK timeout (coupang_service / kurly_products_read)
          - 가운데 15s: item 1개 단위 wait_for. 한 재료가 stuck이어도 batch 전체는 계속.
          - 바깥 25s: batch 전체 cap. 타임아웃 시에도 완료된 항목은 유지(부분 성공).
        """
        if not items:
            return []

        ITEM_TIMEOUT_SECONDS = float(os.getenv("RECOMMEND_ITEM_TIMEOUT_SECONDS", "15"))
        BATCH_TIMEOUT_SECONDS = float(os.getenv("RECOMMEND_BATCH_TIMEOUT_SECONDS", "25"))

        def _empty_response(req: ProductSearchRequest) -> ProductRecommendationResponse:
            return ProductRecommendationResponse(
                ingredient=req.ingredient_name,
                needed_qty=req.needed_qty,
                needed_unit=req.needed_unit,
                best_match=None,
                see_more_list=[],
                all_products=[],
            )

        async def _safe(req: ProductSearchRequest) -> ProductRecommendationResponse:
            try:
                return await asyncio.wait_for(
                    self.recommend_products(req), timeout=ITEM_TIMEOUT_SECONDS
                )
            except asyncio.TimeoutError:
                logger.warning(
                    "[BatchTimeout] item-level timeout ingredient=%s marketplace=%s timeout=%.1fs",
                    getattr(req, "ingredient_name", None),
                    getattr(req, "marketplace", None),
                    ITEM_TIMEOUT_SECONDS,
                )
                return _empty_response(req)
            except Exception as e:
                logger.warning(
                    "Batch recommend item failed for ingredient=%s marketplace=%s: %s",
                    getattr(req, "ingredient_name", None),
                    getattr(req, "marketplace", None),
                    e,
                )
                return _empty_response(req)

        tasks = [asyncio.create_task(_safe(it)) for it in items]
        done, pending = await asyncio.wait(
            tasks,
            timeout=BATCH_TIMEOUT_SECONDS,
            return_when=asyncio.ALL_COMPLETED,
        )
        if pending:
            logger.error(
                "[BatchTimeout] batch-level timeout n_items=%d done=%d pending=%d "
                "timeout=%.1fs — returning partial results",
                len(items),
                len(done),
                len(pending),
                BATCH_TIMEOUT_SECONDS,
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)

        results: List[ProductRecommendationResponse] = []
        for i, task in enumerate(tasks):
            if task.done() and not task.cancelled() and task.exception() is None:
                results.append(task.result())
            else:
                results.append(_empty_response(items[i]))

        return results

    async def recommend_products_stream_items(
        self, items: List[ProductSearchRequest]
    ):
        """
        recommend_products_batch와 완전히 동일한 매칭/스코어링/타임아웃 정책을
        사용하되, ALL_COMPLETED로 전체를 모았다가 반환하는 대신 완료되는 항목을
        즉시 (index, ProductRecommendationResponse)로 yield한다.

        가장 느린 재료 하나가 전체 응답을 막는 문제를 제거하기 위한 스트리밍
        버전 — 계산 로직은 self.recommend_products를 그대로 재사용하므로
        추천 결과의 랭킹/필터링 동작은 batch와 100% 동일하다.

        타임아웃 정책 (batch와 동일):
          - item 15s: 한 재료가 stuck이어도 다른 재료 스트리밍은 계속됨
          - batch 25s: 전체 cap. 마감 시각까지 못 끝난 항목은 빈 응답으로 즉시 emit
        """
        if not items:
            return

        ITEM_TIMEOUT_SECONDS = float(os.getenv("RECOMMEND_ITEM_TIMEOUT_SECONDS", "15"))
        BATCH_TIMEOUT_SECONDS = float(os.getenv("RECOMMEND_BATCH_TIMEOUT_SECONDS", "25"))

        def _empty_response(req: ProductSearchRequest) -> ProductRecommendationResponse:
            return ProductRecommendationResponse(
                ingredient=req.ingredient_name,
                needed_qty=req.needed_qty,
                needed_unit=req.needed_unit,
                best_match=None,
                see_more_list=[],
                all_products=[],
            )

        async def _run_one(req: ProductSearchRequest) -> ProductRecommendationResponse:
            try:
                return await asyncio.wait_for(
                    self.recommend_products(req), timeout=ITEM_TIMEOUT_SECONDS
                )
            except asyncio.TimeoutError:
                logger.warning(
                    "[StreamTimeout] item-level timeout ingredient=%s marketplace=%s timeout=%.1fs",
                    getattr(req, "ingredient_name", None),
                    getattr(req, "marketplace", None),
                    ITEM_TIMEOUT_SECONDS,
                )
                return _empty_response(req)
            except Exception as e:
                logger.warning(
                    "Stream recommend item failed for ingredient=%s marketplace=%s: %s",
                    getattr(req, "ingredient_name", None),
                    getattr(req, "marketplace", None),
                    e,
                )
                return _empty_response(req)

        tasks = {asyncio.create_task(_run_one(it)): idx for idx, it in enumerate(items)}
        deadline = time.monotonic() + BATCH_TIMEOUT_SECONDS
        pending = set(tasks.keys())

        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            done, pending = await asyncio.wait(
                pending, timeout=remaining, return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                idx = tasks[task]
                try:
                    result = task.result()
                except Exception as e:
                    logger.warning("[StreamTimeout] unexpected task error idx=%d: %s", idx, e)
                    result = _empty_response(items[idx])
                yield idx, result

        if pending:
            logger.error(
                "[StreamTimeout] batch-level timeout n_items=%d done=%d pending=%d "
                "timeout=%.1fs — emitting empty for unfinished",
                len(items),
                len(items) - len(pending),
                len(pending),
                BATCH_TIMEOUT_SECONDS,
            )
            for task in pending:
                idx = tasks[task]
                task.cancel()
                yield idx, _empty_response(items[idx])
            await asyncio.gather(*pending, return_exceptions=True)

    async def _recommend_products_kurly(self, req: ProductSearchRequest) -> ProductRecommendationResponse:
        """컬리 Firestore kurly_products 기반 추천: 재료명 매칭 후보 전체를 태그/정렬 후 반환."""
        from services.kurly_products_read import get_kurly_products_for_ingredient

        raw_list = await self._run_to_thread_limited(
            get_kurly_products_for_ingredient,
            req.ingredient_name,
            fallback=[],
            op_name="get_kurly_products_for_ingredient",
        )
        if not raw_list:
            logger.warning(f"No Kurly products for ingredient: {req.ingredient_name}")
            return ProductRecommendationResponse(
                ingredient=req.ingredient_name,
                display_name=normalize_cart_display_name(req.ingredient_name or ""),
                needed_qty=req.needed_qty,
                needed_unit=req.needed_unit,
                best_match=None,
                see_more_list=[],
                all_products=[],
            )

        keyword = (req.original_ingredient_name or req.ingredient_name or "").strip()
        keyword_clean = keyword.lower().replace(" ", "").replace("\t", "") if keyword else ""

        def has_keyword_in_name(p: Dict[str, Any]) -> bool:
            name = (p.get("productName") or "").strip()
            if not name or not keyword_clean:
                return True
            name_clean = name.lower().replace(" ", "").replace("\t", "")
            return keyword_clean in name_clean

        # 재료명 포함 우선, 그다음 가격 오름차순
        def sort_key(item: Dict[str, Any]) -> tuple:
            name_ok = has_keyword_in_name(item)
            price = int(item.get("price") or item.get("productPrice") or 0)
            return (0 if name_ok else 1, price)

        sorted_list = sorted(raw_list, key=sort_key)

        def to_coupang_product(idx: int, p: Dict[str, Any]) -> CoupangProduct:
            link = (p.get("link") or p.get("productUrl") or "").strip()
            product_id = hashlib.md5(link.encode("utf-8")).hexdigest()[:16] if link else f"kurly-{req.ingredient_name}-{idx}"
            product_name = (p.get("productName") or p.get("name") or "").strip() or "상품"
            product_price = int(p.get("price") or p.get("productPrice") or 0)
            product_image = (p.get("imageUrl") or p.get("productImage") or "").strip()
            product_url = link if link.startswith("http") else ""
            is_free_shipping = bool(p.get("isFreeShipping", False))
            reviews_val = p.get("reviews")
            reviews = int(reviews_val) if reviews_val is not None else None
            orig = p.get("originalPrice")
            original_price = int(orig) if orig is not None else None
            dr = p.get("discountRate")
            discount_rate = float(dr) if dr is not None else None
            rating_val = p.get("rating")
            rating = float(rating_val) if rating_val is not None else None
            package_size, package_unit = self.parse_product_size(product_name)
            unit_price = (product_price / package_size) if package_size and package_size > 0 else None
            return CoupangProduct(
                product_id=product_id,
                product_name=product_name,
                product_price=product_price,
                product_image=product_image,
                product_url=product_url,
                original_url=product_url or None,
                deeplink_url=None,
                is_rocket=False,
                is_free_shipping=is_free_shipping,
                unit_price=unit_price,
                package_size=package_size,
                package_unit=package_unit,
                reviews=reviews,
                rating=rating,
                original_price=original_price,
                discount_rate=discount_rate,
            )

        coupang_products = [to_coupang_product(i, p) for i, p in enumerate(sorted_list)]
        sorted_products = self._sort_and_attach_final_tags(
            coupang_products,
            ingredient_name=req.original_ingredient_name or req.ingredient_name,
            needed_qty=req.needed_qty,
            needed_unit=req.needed_unit,
        )
        best_match = sorted_products[0] if sorted_products else None
        see_more_list, _ = self._recommendation_lists(
            req, sorted_products, best_match
        )

        logger.info(
            f"Kurly recommendation for {req.ingredient_name}: "
            f"best_match={best_match.product_name[:40] if best_match else None}, "
            f"see_more={len(see_more_list)}"
        )
        return ProductRecommendationResponse(
            ingredient=req.ingredient_name,
            display_name=normalize_cart_display_name(req.ingredient_name or ""),
            needed_qty=req.needed_qty,
            needed_unit=req.needed_unit,
            best_match=best_match,
            see_more_list=see_more_list,
            all_products=see_more_list,
        )

    def search_products_advanced(self, req: ProductSearchRequest) -> AdvancedProductSearchResponse:
        """
        Advanced product search with match scoring.
        
        This method handles the business logic for advanced product search:
        - Searches Coupang for products
        - Calculates match scores
        - Returns top products sorted by score
        """
        limit = 10
        raw_products = self.search_coupang_products(req.ingredient_name, limit)
        raw_products = self._filter_excluded_raw_products(raw_products)
        
        if not raw_products:
            return AdvancedProductSearchResponse(
                ingredient=req.ingredient_name,
                needed_qty=req.needed_qty,
                needed_unit=req.needed_unit,
                best_amount_match=None,
                cheapest_same_amount=None,
                cheapest_overall=None,
                all_products=[]
            )
        
        # Parse products
        products: List[ProductSearchResult] = []
        unit_prices = []
        
        for raw_product in raw_products:
            product_id = str(raw_product.get("productId", raw_product.get("id", "")))
            product_name = raw_product.get("productName", raw_product.get("name", ""))
            product_price = int(raw_product.get("productPrice", raw_product.get("price", 0)))
            product_image = raw_product.get("productImage", raw_product.get("imageUrl", ""))
            product_url = raw_product.get("productUrl", raw_product.get("url", ""))
            is_rocket = raw_product.get("isRocket", False)
            is_free_shipping = raw_product.get("isFreeShipping", False)
            
            final_product_url = product_url if product_url and product_url.startswith('http') else ""
            package_size, package_unit = self.parse_product_size(product_name)
            
            unit_price = None
            if package_size and package_size > 0:
                unit_price = product_price / package_size
                unit_prices.append(unit_price)
            
            products.append(ProductSearchResult(
                product_id=product_id,
                product_name=product_name,
                product_price=product_price,
                product_image=product_image,
                product_url=final_product_url,
                is_rocket=is_rocket,
                is_free_shipping=is_free_shipping,
                package_size=package_size,
                package_unit=package_unit,
                unit_price=unit_price,
                amount_match_score=0.0,
                total_match_score=0.0
            ))
        
        products = self._filter_excluded_product_search_results(products)
        unit_prices = [p.unit_price for p in products if p.unit_price is not None]

        # Calculate average unit price
        avg_unit_price = None
        if unit_prices:
            avg_unit_price = sum(unit_prices) / len(unit_prices)
        
        # Calculate match scores
        # Note: We need to get sales_rank from raw_products since ProductSearchResult doesn't have it
        raw_product_map = {str(p.get("productId", p.get("id", ""))): p for p in raw_products}
        
        for product in products:
            amount_match_score = self.calculate_amount_match_score(
                req.needed_qty,
                req.needed_unit,
                product.package_size,
                product.package_unit,
                product.product_name  # 상품명 전달하여 단위 포함 여부 확인
            )
            
            # Get sales_rank from raw product data
            raw_product = raw_product_map.get(product.product_id, {})
            sales_rank = raw_product.get("rank", None)
            if sales_rank:
                try:
                    sales_rank = int(sales_rank)
                except (ValueError, TypeError):
                    sales_rank = None
            
            total_match_score = self.calculate_match_score(
                req.needed_qty,
                req.needed_unit,
                product.package_size,
                product.package_unit,
                product.product_price,
                unit_price=product.unit_price,
                avg_unit_price=avg_unit_price,
                is_rocket=product.is_rocket,
                sales_rank=sales_rank
            )
            
            product.amount_match_score = amount_match_score
            product.total_match_score = total_match_score
        
        # Sort by total match score
        products.sort(key=lambda p: p.total_match_score or 0, reverse=True)
        top_products = [
            self._enrich_product_search_result_deeplink(p) for p in products[:4]
        ]

        return AdvancedProductSearchResponse(
            ingredient=req.ingredient_name,
            needed_qty=req.needed_qty,
            needed_unit=req.needed_unit,
            best_amount_match=None,
            cheapest_same_amount=None,
            cheapest_overall=None,
            all_products=top_products
        )
    
    def search_coupang_products(self, query: str, limit: int = 10) -> List[Dict[str, Any]]:
        """
        Search for products on Coupang from cache only.
        
        This method only retrieves results from cache. All API calls are handled
        by the background scheduler (process_safe_queue).
        
        Args:
            query: Search query string
            limit: Maximum number of results to return
            
        Returns:
            List of product dictionaries, or empty list if not found in cache
        """
        logger.debug(f"search_coupang_products called: query='{query}', limit={limit}")
        
        # Check cache only - no direct API calls
        cached = self.get_cached_search_results(query)
        if cached:
            logger.debug(f"Returning cached results for query: '{query}' ({len(cached)} items)")
            return cached[:limit]
        
        # MOCK MODE (for testing only)
        use_mock = os.getenv("USE_MOCK_COUPANG_DATA", "false").lower() == "true"
        if use_mock:
            logger.info(f"[MOCK MODE] Returning mock data for query: {query}")
            return self._get_mock_coupang_products(query, limit)
        
        # No cache hit - return empty list
        # Results will be available after scheduler processes this query
        logger.debug(f"No cached results for query: '{query}'. Scheduler will process this query in background.")
        return []
    
    def _search_coupang_api(self, query: str, limit: int = 10, ingredient_name: Optional[str] = None) -> List[Dict[str, Any]]:
        """Internal function to search Coupang Partners API"""
        logger.debug(f"_search_coupang_api called: query='{query}', limit={limit}, ingredient_name={ingredient_name}")
        
        domain = "https://api-gateway.coupang.com"
        path = "/v2/providers/affiliate_open_api/apis/openapi/v1/products/search"
        
        params = {
            "keyword": query,
            "limit": limit,
        }
        
        if self.coupang_partner_subid:
            params["subId"] = self.coupang_partner_subid
        
        query_string = urllib.parse.urlencode(params)
        full_path = f"{path}?{query_string}"
        
        authorization = self.generate_coupang_hmac("GET", full_path, self.coupang_secret_key, self.coupang_access_key)
        request_url = f"{domain}{full_path}"
        
        headers = {
            "Authorization": authorization,
            "Content-Type": "application/json"
        }
        
        logger.info(f"Calling Coupang API for query: '{query}' (limit: {limit})")
        
        # Retry logic for 403 rate limit errors
        # Rate limit 에러는 1번만 재시도 (과도한 재시도 방지)
        max_retries = 3
        rate_limit_max_retries = 1  # Rate limit 에러는 1번만 재시도
        retry_delay = 2
        is_rate_limit_error = False
        
        for attempt in range(max_retries):
            response = requests.get(request_url, headers=headers, timeout=10)
            logger.debug(f"API Response Status: {response.status_code}")
            
            if response.status_code == 403:
                try:
                    data = response.json()
                    if "rCode" in data and data.get("rCode") == "403":
                        is_rate_limit_error = True
                        error_msg = data.get("rMessage", "")
                        logger.warning(f"Rate limit error (attempt {attempt + 1}/{rate_limit_max_retries}): {error_msg}")
                        
                        # Rate limit 에러는 최대 1번만 재시도
                        if attempt < rate_limit_max_retries:
                            time_match = re.search(r'(\d{4}-\d{2}-\d{2}T[\d:\.]+)', error_msg)
                            if time_match:
                                from datetime import datetime
                                retry_time_str = time_match.group(1)
                                try:
                                    retry_time = datetime.fromisoformat(retry_time_str.replace('Z', '+00:00'))
                                    wait_seconds = max(retry_delay, (retry_time - datetime.now(retry_time.tzinfo)).total_seconds() + 1)
                                    if wait_seconds > 0:
                                        logger.info(f"Waiting {wait_seconds:.1f} seconds before retry (rate limit)...")
                                        time.sleep(wait_seconds)
                                        continue
                                except Exception as e:
                                    logger.warning(f"Could not parse retry time: {e}")
                            
                            # Rate limit 에러는 최소 60초 대기 (더 보수적으로)
                            wait_seconds = max(60, retry_delay * (2 ** attempt))
                            logger.info(f"Waiting {wait_seconds} seconds before retry (rate limit)...")
                            time.sleep(wait_seconds)
                            continue
                        else:
                            # Rate limit 재시도 횟수 초과 - 에러 반환
                            logger.error(f"Rate limit exceeded. Skipping query '{query}' to avoid further rate limiting.")
                            raise Exception(f"Coupang API rate limit exceeded: {error_msg}")
                except (json.JSONDecodeError, ValueError):
                    pass
            
            if response.status_code != 200:
                logger.error(f"API request failed with status {response.status_code}")
                logger.error(f"Response: {response.text[:500]}")
                if attempt < max_retries - 1:
                    time.sleep(retry_delay * (2 ** attempt))
                    continue
                raise Exception(f"Coupang API request failed: {response.status_code}")
            
            # Parse response
            try:
                data = response.json()
                if data.get("rCode") != "0":
                    error_msg = data.get("rMessage", "Unknown error")
                    logger.error(f"API returned error: {error_msg}")
                    raise Exception(f"Coupang API error: {error_msg}")
                
                products_data = data.get("data", {}).get("productData", [])
                products = []
                
                for item in products_data:
                    product_id = item.get("productId", "")
                    product_name = item.get("productName", "")
                    
                    # 필터링: 상품 이름이 없으면 제외
                    if not product_name or not product_name.strip():
                        logger.debug(f"Skipping product (no name): productId={product_id}")
                        continue
                    
                    # 필터링: 재료명이 제공된 경우, 상품 이름에 재료명이 포함되어 있는지 확인
                    if ingredient_name:
                        product_name_lower = product_name.lower()
                        ingredient_name_lower = ingredient_name.lower()
                        if ingredient_name_lower not in product_name_lower:
                            logger.debug(f"Skipping product (ingredient '{ingredient_name}' not in product name): productId={product_id}, productName={product_name[:50]}")
                            continue
                    
                    product_price = item.get("productPrice", 0)
                    product_image = item.get("productImage", "")
                    product_url = item.get("productUrl", "")
                    is_rocket = item.get("isRocket", False)
                    is_free_shipping = item.get("isFreeShipping", False)
                    rank = item.get("rank", None)  # sales_rank 필드 (1-10위)
                    
                    # Parse package size
                    package_size, package_unit = self.parse_product_size(product_name)
                    
                    # Calculate unit price
                    unit_price = None
                    if package_size and package_unit and product_price > 0:
                        unit_price = product_price / package_size
                    
                    # Convert to affiliate link
                    if product_url:
                        product_url = self.encode_affiliate_link(product_url, product_id)
                    
                    products.append({
                        "productId": product_id,
                        "productName": product_name,
                        "productPrice": product_price,
                        "productImage": product_image,
                        "productUrl": product_url,
                        "isRocket": is_rocket,
                        "isFreeShipping": is_free_shipping,
                        "packageSize": package_size,
                        "packageUnit": package_unit,
                        "unitPrice": unit_price,
                        "rank": rank,  # sales_rank (1-10위)
                    })
                
                logger.info(f"Successfully retrieved {len(products)} products from Coupang API")
                return products
                
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse API response: {e}")
                raise
            except Exception as e:
                logger.error(f"Error processing API response: {e}")
                raise
        
        raise Exception("Failed to get response from Coupang API after retries")
    
    def _scrape_coupang_web(self, query: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Directly scrape Coupang search results from their website"""
        try:
            session = requests.Session()
            
            user_agents = [
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0',
            ]
            
            headers = {
                'User-Agent': random.choice(user_agents),
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
                'Accept-Language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
                'Accept-Encoding': 'gzip, deflate, br',
                'DNT': '1',
                'Connection': 'keep-alive',
                'Upgrade-Insecure-Requests': '1',
                'Sec-Fetch-Dest': 'document',
                'Sec-Fetch-Mode': 'navigate',
                'Sec-Fetch-Site': 'none',
                'Sec-Fetch-User': '?1',
                'Cache-Control': 'max-age=0',
                'Referer': 'https://www.coupang.com/',
            }
            
            encoded_query = urllib.parse.quote(query)
            search_url = f"https://www.coupang.com/np/search?q={encoded_query}"
            
            logger.info(f"Scraping Coupang web search: {search_url}")
            
            delay = random.uniform(1.5, 3.0)
            logger.debug(f"Waiting {delay:.2f}s before request...")
            time.sleep(delay)
            
            try:
                response = session.get(search_url, headers=headers, timeout=15, allow_redirects=True)
            except requests.exceptions.Timeout:
                logger.error("Request timed out")
                return []
            except requests.exceptions.RequestException as e:
                logger.error(f"Request failed: {e}")
                return []
            
            if response.status_code in [403, 429]:
                logger.error(f"Coupang blocked the request (status {response.status_code})")
                return []
            
            if response.status_code != 200:
                logger.error(f"Request failed with status {response.status_code}")
                return []
            
            try:
                soup = BeautifulSoup(response.content, 'lxml')
            except Exception:
                soup = BeautifulSoup(response.content, 'html.parser')
            
            products = []
            product_selectors = [
                'li.search-product',
                'li[data-product-id]',
                '.search-product-wrap li',
                'ul.search-product-list li',
            ]
            
            product_items = []
            for selector in product_selectors:
                product_items = soup.select(selector)
                if product_items:
                    logger.debug(f"Found products using selector: {selector}")
                    break
            
            if not product_items:
                product_items = soup.find_all('li', class_=re.compile(r'product|item', re.I))
                if not product_items:
                    logger.warning("No products found")
                    return []
            
            logger.debug(f"Found {len(product_items)} product elements, processing up to {limit}...")
            
            for idx, item in enumerate(product_items[:limit]):
                try:
                    product_id = (
                        item.get('data-product-id') or
                        item.get('data-item-id') or
                        item.get('data-id') or
                        ''
                    )
                    
                    name_selectors = [
                        '.name', '.product-name', '.search-product-name',
                        'a.name', 'div.name', 'span.name',
                        'h3', 'h4', '.title', '.product-title'
                    ]
                    product_name = ''
                    for selector in name_selectors:
                        name_elem = item.select_one(selector)
                        if name_elem:
                            product_name = name_elem.get_text(strip=True)
                            break
                    
                    if not product_name:
                        link_elem = item.select_one('a')
                        if link_elem:
                            product_name = link_elem.get_text(strip=True)
                    
                    price_selectors = [
                        '.price-value', '.price', '.product-price',
                        '.search-product-price', 'strong.price-value',
                        '[class*="price"]', '.cost'
                    ]
                    product_price = 0
                    for selector in price_selectors:
                        price_elem = item.select_one(selector)
                        if price_elem:
                            price_text = price_elem.get_text(strip=True)
                            price_text = re.sub(r'[^\d]', '', price_text)
                            if price_text:
                                try:
                                    product_price = int(price_text)
                                    break
                                except ValueError:
                                    continue
                    
                    image_selectors = [
                        'img.search-product-image', 'img.product-image',
                        'img[src*="product"]', 'img', '.product-img img'
                    ]
                    product_image = ''
                    for selector in image_selectors:
                        img_elem = item.select_one(selector)
                        if img_elem:
                            product_image = img_elem.get('src') or img_elem.get('data-src') or img_elem.get('data-lazy-src') or ''
                            if product_image:
                                if product_image.startswith('//'):
                                    product_image = 'https:' + product_image
                                elif product_image.startswith('/'):
                                    product_image = 'https://www.coupang.com' + product_image
                                break
                    
                    link_elem = item.select_one('a')
                    product_url = ''
                    if link_elem:
                        href = link_elem.get('href', '')
                        if href:
                            if href.startswith('//'):
                                product_url = 'https:' + href
                            elif href.startswith('/'):
                                product_url = 'https://www.coupang.com' + href
                            elif href.startswith('http'):
                                product_url = href
                    
                    if not product_id and product_url:
                        product_id = self._extract_product_id_from_url(product_url)
                    elif not product_id:
                        product_id = f"scraped_{hashlib.md5((product_name + str(idx)).encode()).hexdigest()[:12]}"
                    
                    if product_url and self.coupang_partner_subid:
                        parsed_url = urllib.parse.urlparse(product_url)
                        query_params = urllib.parse.parse_qs(parsed_url.query)
                        query_params['subId'] = [self.coupang_partner_subid]
                        new_query = urllib.parse.urlencode(query_params, doseq=True)
                        product_url = f"{parsed_url.scheme}://{parsed_url.netloc}{parsed_url.path}?{new_query}"
                    
                    if product_name and product_price > 0:
                        products.append({
                            'productId': product_id,
                            'productName': product_name,
                            'productPrice': product_price,
                            'productImage': product_image,
                            'productUrl': product_url,
                            'rating': None,
                            'reviewCount': None,
                        })
                        
                except Exception as e:
                    logger.warning(f"Failed to parse product {idx+1}: {e}")
                    continue
            
            logger.info(f"Successfully scraped {len(products)} products from Coupang web")
            return products
            
        except Exception as e:
            logger.error(f"Web scraping failed: {e}")
            import traceback
            traceback.print_exc()
            return []
    
    def search_naver_shopping(self, query: str, limit: int = 50, coupang_only: bool = False) -> List[Dict[str, Any]]:
        """Search Naver Shopping API for products"""
        if not self.naver_client_id or not self.naver_client_secret:
            logger.warning("Naver API credentials not configured. Skipping Naver search.")
            return []
        
        url = "https://openapi.naver.com/v1/search/shop.json"
        params = {
            "query": query,
            "display": min(limit, 100),
            "sort": "sim"
        }
        
        headers = {
            "X-Naver-Client-Id": self.naver_client_id,
            "X-Naver-Client-Secret": self.naver_client_secret
        }
        
        logger.info(f"Calling Naver Shopping API for query: '{query}' (limit: {limit})")
        
        try:
            response = requests.get(url, params=params, headers=headers, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            items = data.get("items", [])
            logger.debug(f"Naver returned {len(items)} total products")
            
            products = []
            for item in items:
                mall_name = item.get("mallName", "")
                product_url = item.get("link", "")
                
                is_coupang = (
                    "coupang" in mall_name.lower() or 
                    "coupang.com" in product_url.lower() or
                    "coupang.co.kr" in product_url.lower() or
                    "쿠팡" in mall_name
                )
                
                if coupang_only and not is_coupang:
                    continue
                
                product_id = self._extract_product_id_from_url(item.get("link", ""))
                original_url = item.get("link", "")
                
                if is_coupang:
                    final_url = self._convert_to_coupang_partners_link(original_url)
                else:
                    final_url = original_url
                
                title = item.get("title", "")
                package_size, package_unit = self.parse_product_size(title)
                
                price_str = item.get("lprice", "0")
                try:
                    price = int(price_str)
                except (ValueError, TypeError):
                    price = 0
                
                if price == 0:
                    continue
                
                image = item.get("image", "")
                unit_price = None
                if package_size and package_unit and price > 0:
                    unit_price = price / package_size
                
                clean_title = title.replace("<b>", "").replace("</b>", "")
                
                products.append({
                    "productId": product_id,
                    "productName": clean_title,
                    "productPrice": price,
                    "productImage": image,
                    "productUrl": final_url,
                    "rating": None,
                    "reviewCount": None,
                    "packageSize": package_size,
                    "packageUnit": package_unit,
                    "unitPrice": unit_price,
                    "mallName": mall_name
                })
            
            logger.info(f"Returning {len(products)} products from Naver Shopping")
            return products
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Naver Shopping API request failed: {e}")
            return []
        except Exception as e:
            logger.error(f"Error processing Naver Shopping results: {e}", exc_info=True)
            return []
    
    def generate_queries(self, ingredient: str) -> List[str]:
        """
        재료별로 카테고리에 맞는 검색 쿼리를 생성합니다.
        
        각 카테고리별로 다른 접두사와 단위를 사용하여 쿼리를 생성합니다.
        쿼리 개수는 카테고리별로 다릅니다 (예: 8개~20개).
        
        Args:
            ingredient: 식재료 이름
            
        Returns:
            쿼리 리스트 (접두사 × 단위 조합)
        """
        # 재료의 카테고리 확인
        category = INGREDIENT_MAPPING.get(ingredient, "VEG_WEIGHT")  # 기본값: VEG_WEIGHT
        unit_steps = UNIT_STEPS.get(category, UNIT_STEPS["VEG_WEIGHT"])  # 기본값: VEG_WEIGHT
        prefixes = PREFIXES.get(category, [""])  # 기본값: 빈 접두사
        
        # 접두사 × 단위 조합으로 쿼리 생성
        queries = []
        for prefix in prefixes:
            for unit in unit_steps:
                query = f"{prefix}{ingredient} {unit}".strip()
                queries.append(query)
        
        return queries
    
    def process_safe_queue(self):
        """
        24시간 주기 스케줄러: 모든 재료의 쿼리를 24시간마다 한 번씩 처리합니다.
        
        로직:
        1. 전체 쿼리 수 계산 및 처리 시간 검증
        2. 33초 간격으로 한 번에 1개씩 처리
        3. Circular Queue로 순환 처리
        4. 24시간 주기 완료 후 다시 처음부터 반복
        
        - 초기화: 모든 재료의 쿼리를 생성하여 하나의 리스트(Circular Queue)로 만듦
        - 실행 루프:
          1. 큐에서 1개의 쿼리를 추출 (BATCH_SIZE = 1)
          2. 쿼리 실행 (캐시 확인 후 필요시 API 호출)
          3. 33초 대기 후 다음 쿼리로 진행
          4. 전체 큐 완료 시 처음부터 다시 시작
        """
        logger.info("Initializing 24-hour cycle Coupang API query scheduler...")
        
        # 초기화: 모든 재료의 쿼리 생성 (재료명과 쿼리 매핑 저장)
        all_queries = []
        query_to_ingredient = {}  # 쿼리 -> 재료명 매핑
        _all = list(_load_all_ingredients())
        for ingredient in _all:
            queries = self.generate_queries(ingredient)
            for query in queries:
                query_to_ingredient[query] = ingredient
            all_queries.extend(queries)
        
        total_queries = len(all_queries)
        logger.info(f"Generated {total_queries} queries for {len(_all)} ingredients")
        
        # 처리 시간 계산 및 검증
        total_seconds = total_queries * SCHEDULER_QUERY_INTERVAL
        total_hours = total_seconds / 3600
        target_hours = SCHEDULER_TARGET_CYCLE_HOURS
        
        if total_hours > target_hours:
            logger.warning(f"⚠️  Estimated time ({total_hours:.2f}h) exceeds target ({target_hours}h)")
            logger.warning(f"   Consider reducing query interval or increasing cycle hours")
        else:
            logger.info(f"✅ Estimated completion time: {total_hours:.2f} hours (within {target_hours}h target)")
        
        logger.info(f"Scheduler configuration:")
        logger.info(f"  - Total queries: {total_queries}")
        logger.info(f"  - Batch size: {SCHEDULER_BATCH_SIZE} query per cycle")
        logger.info(f"  - Query interval: {SCHEDULER_QUERY_INTERVAL} seconds")
        logger.info(f"  - Queries per hour: {3600 / SCHEDULER_QUERY_INTERVAL:.0f}")
        logger.info(f"  - Estimated completion: {total_hours:.2f} hours")
        
        # Circular Queue 인덱스
        queue_index = 0
        cycle_count = 0
        cycle_start_time = time.time()  # 전체 사이클 시작 시간
        
        # 무한 루프 (24시간 주기 반복)
        while True:
            try:
                # 전체 사이클이 완료되었는지 확인
                elapsed_since_start = time.time() - cycle_start_time
                if queue_index == 0 and cycle_count > 0:
                    # 새로운 사이클 시작
                    cycle_start_time = time.time()
                    logger.info(f"🔄 Starting new {target_hours}-hour cycle...")
                
                cycle_count += 1
                query_start_time = time.time()
                
                # 큐에서 1개 쿼리 추출
                if queue_index >= total_queries:
                    queue_index = 0  # Circular queue: 처음으로 돌아감
                    cycle_start_time = time.time()  # 새 사이클 시작
                    logger.info(f"✅ Completed full cycle. Starting new cycle...")
                
                query = all_queries[queue_index]
                queue_index += 1
                
                # 진행률 계산
                progress_percent = (queue_index / total_queries) * 100
                remaining_queries = total_queries - queue_index
                estimated_remaining_seconds = remaining_queries * SCHEDULER_QUERY_INTERVAL
                estimated_remaining_hours = estimated_remaining_seconds / 3600
                
                logger.debug(f"Cycle #{cycle_count}: Processing query '{query}' "
                           f"(Progress: {progress_percent:.1f}%, "
                           f"Queue: {queue_index}/{total_queries}, "
                           f"ETA: {estimated_remaining_hours:.2f}h)")
                
                try:
                    # 캐시 확인
                    cached_results = self.get_cached_search_results(query)
                    if cached_results:
                        logger.debug(f"  ✓ Cache hit for '{query}' ({len(cached_results)} products), skipping API call")
                    else:
                        # API 호출
                        logger.debug(f"  → Calling Coupang API for '{query}'...")
                        if self.coupang_access_key and self.coupang_secret_key:
                            try:
                                results = self._search_coupang_api(query, limit=10)
                                if results:
                                    ingredient_name = query_to_ingredient.get(query)
                                    self.save_search_results_to_cache(query, results, ingredient_name=ingredient_name)
                                    logger.debug(f"  ✓ Query '{query}' returned {len(results)} results and saved to cache")
                                else:
                                    logger.debug(f"  ✗ Query '{query}' returned no results")
                            except Exception as api_error:
                                error_msg = str(api_error)
                                # Rate limit 에러인 경우 더 긴 대기 시간
                                if "rate limit" in error_msg.lower() or "403" in error_msg:
                                    logger.error(f"  ✗ Rate limit error for query '{query}': {error_msg}")
                                    logger.warning(f"  ⚠️  Waiting 5 minutes before next query to avoid rate limiting...")
                                    time.sleep(300)  # 5분 대기
                                else:
                                    logger.error(f"  ✗ API error for query '{query}': {error_msg}")
                        else:
                            logger.warning(f"  ✗ Coupang API credentials not configured, skipping query: '{query}'")
                    
                except Exception as e:
                    logger.error(f"  ✗ Error executing query '{query}': {e}", exc_info=True)
                
                # 쿼리 처리 시간 계산
                query_elapsed = time.time() - query_start_time
                
                # 33초 간격 유지 (처리 시간 제외)
                remaining_interval = SCHEDULER_QUERY_INTERVAL - query_elapsed
                if remaining_interval > 0:
                    logger.debug(f"  Waiting {remaining_interval:.2f}s before next query...")
                    time.sleep(remaining_interval)
                else:
                    logger.warning(f"  ⚠️  Query took {query_elapsed:.2f}s (exceeded {SCHEDULER_QUERY_INTERVAL}s interval)")
                    # 간격을 유지하기 위해 최소한의 대기
                    time.sleep(1)
                
            except KeyboardInterrupt:
                logger.info("Received interrupt signal, stopping scheduler...")
                break
            except Exception as e:
                logger.error(f"Unexpected error in scheduler loop: {e}", exc_info=True)
                time.sleep(10)


# Global instance (for backward compatibility during migration)
_product_service: Optional[ProductService] = None


def get_product_service(firebase_service=None) -> ProductService:
    """Get or create global product service instance"""
    global _product_service
    if _product_service is None:
        _product_service = ProductService(firebase_service=firebase_service)
    return _product_service


def check_ingredient_product_coverage() -> Dict[str, Any]:
    """
    Health check: find ingredients that have no products in coupang_products.
    Uses a verified-coverage cache so only NEW ingredients are checked after the first run.

    Returns dict with total, covered, missing count, and missing names.
    """
    from services.firebase_service import get_firebase_service

    firebase = get_firebase_service()
    if not firebase.is_available() or not firebase.db:
        logger.warning("[HealthCheck] Firebase unavailable, skipping")
        return {"total": 0, "covered": 0, "missing": 0, "missing_names": [], "error": "firebase_unavailable"}

    all_ingredients = _load_all_ingredients().copy()

    already_verified = firebase.get_product_coverage_verified()
    to_check = all_ingredients - already_verified
    logger.info(
        f"[HealthCheck] {len(all_ingredients)} total ingredients, "
        f"{len(already_verified)} already verified, {len(to_check)} to check"
    )

    if not to_check:
        return {
            "total": len(all_ingredients),
            "covered": len(already_verified),
            "missing": 0,
            "missing_names": [],
            "checked_this_run": 0,
        }

    db = firebase.db
    existing_doc_ids: set = set()
    invalid_doc_id_names: set = set()
    try:
        # `to_check` is normally tiny after the verified set is populated.
        # Batch-get only those documents instead of scanning every product doc
        # (the catalogue is ~120k documents and this job runs every six hours).
        refs = []
        for name in sorted(to_check):
            try:
                refs.append(db.collection("coupang_products").document(name))
            except (TypeError, ValueError):
                # A name that cannot be a Firestore document ID could not have
                # matched the old exact doc-id scan either, so keep it missing.
                invalid_doc_id_names.add(name)
        for doc in db.get_all(refs):
            if doc.exists:
                existing_doc_ids.add(doc.id)
    except Exception as e:
        logger.warning(f"[HealthCheck] Error checking coupang_products: {e}")
        return {"total": len(all_ingredients), "covered": 0, "missing": 0, "missing_names": [], "error": str(e)}

    newly_verified: List[str] = []
    missing_names: List[str] = []
    for name in to_check:
        if name not in invalid_doc_id_names and name in existing_doc_ids:
            newly_verified.append(name)
        else:
            missing_names.append(name)

    if newly_verified:
        firebase.add_product_coverage_verified(newly_verified)
        logger.info(f"[HealthCheck] Marked {len(newly_verified)} ingredients as verified")

    if missing_names:
        firebase.add_priority_scraping_ingredients_batch(missing_names, source="health_check")
        logger.info(f"[HealthCheck] Queued {len(missing_names)} missing ingredients for priority scraping")

    total_covered = len(already_verified) + len(newly_verified)
    result = {
        "total": len(all_ingredients),
        "covered": total_covered,
        "missing": len(missing_names),
        "missing_names": sorted(missing_names),
        "checked_this_run": len(to_check),
        "newly_verified": len(newly_verified),
    }
    logger.info(f"[HealthCheck] Result: {result['total']} total, {result['covered']} covered, {result['missing']} missing")
    return result

