"""
컬리 Firestore 읽기 전용 (스크래핑/셀레니움 없음).

Railway 등 API 전용 이미지에서 `kurly_service`를 import하지 않고
`kurly_products` 컬렉션만 조회할 때 사용한다.
"""

import logging
from typing import Any, Dict, List

from services.firebase_service import get_firebase_service
from services.product_service import SIMILAR_WORDS_MAP
from services.product_doc_cache import get_cached_firestore_doc

logger = logging.getLogger(__name__)


def get_kurly_products_for_ingredient(
    ingredient_name: str,
    collection_name: str = "kurly_products",
) -> List[Dict[str, Any]]:
    """
    Firestore kurly_products에서 재료명(검색어) 문서의 products 배열을 반환.
    recommend_products(kurly)에서 사용.
    """
    if not ingredient_name or not ingredient_name.strip():
        return []
    firebase_service = get_firebase_service()
    if not firebase_service or not firebase_service.is_available():
        logger.warning("Firebase가 사용 불가능합니다.")
        return []
    try:
        db = firebase_service.db
        if not db:
            return []
        key = ingredient_name.strip()
        # 4일 TTL 캐시 우선 조회 (문서 없음도 캐싱됨) — Firestore stuck 방지를 위해
        # 내부적으로 timeout=5 유지.
        data = get_cached_firestore_doc(db, collection_name, key)
        if data is not None:
            products = data.get("products") or []
            logger.info(f"컬리 상품 {len(products)}개 조회 (재료: {key})")
            return products
        similar = SIMILAR_WORDS_MAP.get(key, [])
        for word in similar:
            if word == key:
                continue
            data = get_cached_firestore_doc(db, collection_name, word)
            if data is not None:
                products = data.get("products") or []
                logger.info(f"컬리 상품 유사어 '{word}'로 {len(products)}개 조회 (재료: {key})")
                return products
        logger.debug(f"컬리 상품 없음 (재료: {key})")
        return []
    except Exception as e:
        logger.error(f"컬리 Firestore 조회 오류: {e}")
        return []
