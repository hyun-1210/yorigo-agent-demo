"""
Product search and recommendation endpoints
"""

import json
from contextlib import nullcontext
from datetime import datetime
from typing import Optional, Dict, Any, List

from fastapi import APIRouter, Header, HTTPException
from fastapi.responses import StreamingResponse
from firebase_admin import auth as firebase_auth
from firebase_admin import firestore as admin_firestore
from google.cloud.firestore_v1 import FieldFilter
from models import (
    ProductSearchRequest,
    ProductRecommendationResponse,
    BatchProductSearchRequest,
    BatchProductRecommendationResponse,
    AdvancedProductSearchResponse,
    AdminExcludeProductRequest,
    AdminExcludedProductListResponse,
    AdminExcludedProductItem,
)
from services.product_service import ProductService, get_product_service, check_ingredient_product_coverage
from services.firebase_service import get_firebase_service

# A-5: watchdog tracking. import 실패해도 router는 동작해야 하므로 fallback로 no-op.
try:
    from watchdog import track_request as _wd_track_request
except Exception:
    _wd_track_request = nullcontext  # type: ignore


def create_product_router(product_service: ProductService = None):
    """Create product router with service injected. If service is None, it will be lazily loaded."""
    router = APIRouter(prefix="", tags=["product"])
    
    def get_service() -> ProductService:
        """Get product service, lazy loading if needed"""
        if product_service is not None:
            return product_service
        return get_product_service()

    def _verify_admin_user(authorization: Optional[str]) -> Dict[str, Any]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
        token = authorization[7:].strip()
        if not token:
            raise HTTPException(status_code=401, detail="Empty bearer token")

        try:
            decoded = firebase_auth.verify_id_token(token)
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid or expired ID token")

        email = (decoded.get("email") or "").strip().lower()
        email_verified = bool(decoded.get("email_verified"))
        uid = (decoded.get("uid") or "").strip()
        if not uid or not email or not email_verified:
            raise HTTPException(status_code=403, detail="Admin access required")

        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        admin_doc = firebase.db.collection("admin_emails").document(email).get()
        data = admin_doc.to_dict() if admin_doc.exists else {}
        if not admin_doc.exists or not bool((data or {}).get("active", False)):
            raise HTTPException(status_code=403, detail="Admin access required")

        return {"uid": uid, "email": email}
    
    @router.post("/recommend_products", response_model=ProductRecommendationResponse)
    async def recommend_products(req: ProductSearchRequest):
        """Recommend products using multiple search strategies"""
        with _wd_track_request():
            return await get_service().recommend_products(req)

    @router.post(
        "/recommend_products_batch",
        response_model=BatchProductRecommendationResponse,
    )
    async def recommend_products_batch(req: BatchProductSearchRequest):
        """
        여러 재료에 대한 추천을 한 번의 HTTP 요청으로 처리.
        items의 marketplace는 항목별로 달라도 됨(쿠팡/컬리 혼용 가능).
        """
        with _wd_track_request():
            results = await get_service().recommend_products_batch(req.items)
        return BatchProductRecommendationResponse(items=results)

    @router.post("/recommend_products_stream")
    async def recommend_products_stream(req: BatchProductSearchRequest):
        """
        recommend_products_batch와 동일한 계산이지만, 완료되는 항목을 즉시
        한 줄씩(NDJSON) 스트리밍한다. 가장 느린 재료 하나 때문에 전체 응답이
        지연되는 것을 막기 위한 progressive 버전 — 기존 batch 엔드포인트는
        하위 호환을 위해 그대로 유지한다.

        응답 형식: 줄바꿈으로 구분된 JSON 객체들.
        {"index": <items 배열에서의 원래 순서>, "result": <ProductRecommendationResponse>}
        프론트는 index로 원래 요청과 매칭해서 도착하는 대로 즉시 반영한다.
        """
        service = get_service()
        items = req.items

        async def event_generator():
            async for idx, result in service.recommend_products_stream_items(items):
                line = json.dumps(
                    {"index": idx, "result": result.model_dump()},
                    ensure_ascii=False,
                )
                yield line + "\n"

        return StreamingResponse(
            event_generator(),
            media_type="application/x-ndjson",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )

    @router.get("/admin/product-doc-cache-stats")
    def product_doc_cache_stats(authorization: Optional[str] = Header(None)):
        """관리자 전용: coupang/kurly 문서 TTL 캐시 히트율 확인 (검증용)."""
        _verify_admin_user(authorization)
        from services.product_doc_cache import get_cache_stats

        return get_cache_stats()

    @router.post("/search_products_advanced", response_model=AdvancedProductSearchResponse)
    def search_products_advanced(req: ProductSearchRequest):
        """Advanced product search with match scoring"""
        return get_service().search_products_advanced(req)

    @router.get("/admin/excluded-products", response_model=AdminExcludedProductListResponse)
    def get_excluded_products(authorization: Optional[str] = Header(None)):
        """관리자 전용: 전역 제외 상품 목록 조회"""
        _verify_admin_user(authorization)
        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        items: List[AdminExcludedProductItem] = []
        docs = (
            firebase.db.collection("excluded_products_global")
            .where(filter=FieldFilter("active", "==", True))
            .stream()
        )
        for doc in docs:
            data = doc.to_dict() or {}
            created_at = data.get("createdAt")
            created_at_iso = None
            if hasattr(created_at, "timestamp"):
                created_at_iso = datetime.fromtimestamp(created_at.timestamp()).isoformat()
            elif isinstance(created_at, datetime):
                created_at_iso = created_at.isoformat()
            elif isinstance(created_at, str):
                created_at_iso = created_at

            items.append(
                AdminExcludedProductItem(
                    productId=str(data.get("productId") or doc.id),
                    reason=data.get("reason"),
                    active=bool(data.get("active", True)),
                    createdBy=data.get("createdBy"),
                    createdAt=created_at_iso,
                )
            )
        return AdminExcludedProductListResponse(items=items)

    @router.post("/admin/excluded-products")
    def add_excluded_product(
        req: AdminExcludeProductRequest,
        authorization: Optional[str] = Header(None),
    ):
        """관리자 전용: 전역 제외 상품 추가"""
        admin_info = _verify_admin_user(authorization)
        product_id = (req.product_id or "").strip()
        if not product_id:
            raise HTTPException(status_code=400, detail="product_id is required")

        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        firebase.db.collection("excluded_products_global").document(product_id).set(
            {
                "productId": product_id,
                "reason": (req.reason or "").strip() or None,
                "createdBy": admin_info["uid"],
                "createdByEmail": admin_info["email"],
                "createdAt": admin_firestore.SERVER_TIMESTAMP,
                "active": True,
            },
            merge=True,
        )
        return {"success": True, "productId": product_id}

    @router.delete("/admin/excluded-products/{product_id}")
    def remove_excluded_product(product_id: str, authorization: Optional[str] = Header(None)):
        """관리자 전용: 전역 제외 상품 해제"""
        _verify_admin_user(authorization)
        pid = (product_id or "").strip()
        if not pid:
            raise HTTPException(status_code=400, detail="product_id is required")

        firebase = get_firebase_service()
        if not firebase.is_available() or firebase.db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        firebase.db.collection("excluded_products_global").document(pid).set(
            {
                "active": False,
                "removedAt": admin_firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return {"success": True, "productId": pid}

    @router.post("/admin/run-health-check")
    def run_health_check(authorization: Optional[str] = Header(None)):
        """Admin: manually trigger ingredient product coverage health check."""
        _verify_admin_user(authorization)
        result = check_ingredient_product_coverage()
        return result

    return router

