"""
공유 TTL 캐시: coupang_products / kurly_products Firestore 문서 조회를
프로세스 메모리에 4일(기본) 캐싱한다.

목적
----
- 동일 재료를 여러 사용자가 검색할 때 Firestore 읽기 비용을 줄인다.
  (사용자 A가 캐시를 채우면 이후 TTL 동안 사용자 B/C/D는 Firestore를 읽지 않는다.)
- 캐시 히트 시 응답 지연을 Firestore 왕복(수백ms~수초)에서 메모리 조회(마이크로초)로 낮춘다.

문서가 존재하지 않는 경우(exists=False)도 캐싱한다 — 검색어 확장(CART_SEARCH_EXPANSION)과
유사어 폴백(SIMILAR_WORDS_MAP)에서 반복적으로 miss가 나는 이름들을 매 요청마다
다시 조회하지 않기 위함이다.

TTL 근거
--------
스크래핑 스케줄러는 10일 사이클(CYCLE_HOURS=240)이고, hot/warm 신선도는 5일
(FRESHNESS_DAYS_HOT_WARM=5)이다. 상품 문서가 시간 단위로 바뀌지 않으므로
1시간 TTL은 과했고, hot/warm 신선도보다 하루 짧게(4일) 잡아 재스크래핑·priority
갱신 직후 옛 데이터를 너무 오래 주지 않으면서 Firestore 읽기를 최소화한다.
Railway 재배포 시 in-memory 캐시는 어차피 초기화된다.

프로세스 단일 인스턴스(Railway numReplicas=1) 기준으로 설계되었다 — 별도 Redis 등
외부 인프라 없이 in-process dict로 충분하다(실측: coupang_products 전체 캐싱 시 약
91MB, kurly_products 약 5.8MB — 이미 OCR/Whisper 모델을 상시 로드하는 컨테이너 기준
무시 가능한 증가분).
"""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Dict, Optional, Tuple

logger = logging.getLogger(__name__)

# (collection_name, doc_id) -> (cached_at_epoch, data_or_None)
# data_or_None이 None이면 "문서 없음"도 캐싱된 것.
_CACHE: Dict[Tuple[str, str], Tuple[float, Optional[dict]]] = {}
_CACHE_LOCK = threading.Lock()

# 기본 4일 (= hot/warm 신선도 5일보다 하루 짧게). env로 초 단위 오버라이드 가능.
_TTL_SECONDS: int = int(os.getenv("PRODUCT_DOC_CACHE_TTL_SECONDS", str(4 * 86400)))
_MAX_ENTRIES: int = int(os.getenv("PRODUCT_DOC_CACHE_MAX_ENTRIES", "6000"))

_hits = 0
_misses = 0
_stats_lock = threading.Lock()


def get_cached_firestore_doc(db: Any, collection_name: str, doc_id: str) -> Optional[dict]:
    """collection/doc_id 문서를 캐시 우선으로 조회.

    Returns:
        doc.to_dict() 또는 문서가 없으면 None. None도 TTL 동안 캐싱되므로
        존재하지 않는 문서를 반복 조회하지 않는다.
    """
    global _hits, _misses
    key = (collection_name, doc_id)
    now = time.time()

    with _CACHE_LOCK:
        cached = _CACHE.get(key)
        if cached is not None and now - cached[0] < _TTL_SECONDS:
            with _stats_lock:
                _hits += 1
            return cached[1]

    with _stats_lock:
        _misses += 1

    doc = db.collection(collection_name).document(doc_id).get(timeout=5)
    data = doc.to_dict() if doc.exists else None

    with _CACHE_LOCK:
        if len(_CACHE) >= _MAX_ENTRIES:
            # 캡 초과 시 가장 오래된 항목부터 10% 정리 (LRU 근사치, 별도 의존성 없이 구현).
            oldest_keys = sorted(_CACHE.items(), key=lambda kv: kv[1][0])[
                : max(1, len(_CACHE) // 10)
            ]
            for k, _ in oldest_keys:
                _CACHE.pop(k, None)
        _CACHE[key] = (now, data)

    return data


def get_cache_stats() -> Dict[str, Any]:
    """헬스체크/검증용 캐시 통계."""
    with _CACHE_LOCK:
        size = len(_CACHE)
    with _stats_lock:
        hits, misses = _hits, _misses
    total = hits + misses
    hit_rate = (hits / total) if total else 0.0
    return {
        "entries": size,
        "hits": hits,
        "misses": misses,
        "hit_rate": round(hit_rate, 4),
        "ttl_seconds": _TTL_SECONDS,
        "max_entries": _MAX_ENTRIES,
    }


def clear_cache() -> None:
    """테스트 또는 운영상 강제 무효화가 필요할 때 사용."""
    global _hits, _misses
    with _CACHE_LOCK:
        _CACHE.clear()
    with _stats_lock:
        _hits = 0
        _misses = 0
    logger.info("[ProductDocCache] cache cleared")
