"""쿠팡 주문 매칭 조회/수동 동기화."""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from fastapi import APIRouter, Header, HTTPException

from models import (
    CoupangAttributedOrder,
    CoupangAttributedOrderListResponse,
    CoupangOrderSyncResponse,
)
from services.coupang_order_attribution_service import (
    get_coupang_order_attribution_service,
    row_to_api_item,
)
from services.firebase_service import get_firebase_service

logger = logging.getLogger(__name__)


def create_coupang_orders_router() -> APIRouter:
    router = APIRouter(prefix="", tags=["coupang-orders"])

    def _verify_bearer_uid(authorization: Optional[str]) -> str:
        from firebase_admin import auth as firebase_auth

        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
        token = authorization[7:].strip()
        if not token:
            raise HTTPException(status_code=401, detail="Empty bearer token")
        try:
            decoded = firebase_auth.verify_id_token(token)
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid or expired ID token")
        uid = (decoded.get("uid") or "").strip()
        if not uid:
            raise HTTPException(status_code=401, detail="Invalid token payload")
        return uid

    def _verify_admin_user(authorization: Optional[str]) -> Dict[str, Any]:
        from firebase_admin import auth as firebase_auth

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

    @router.post("/admin/coupang_orders/sync", response_model=CoupangOrderSyncResponse)
    async def sync_coupang_orders(authorization: Optional[str] = Header(None)):
        """관리자가 최근 주문 창을 즉시 동기화한다."""
        _verify_admin_user(authorization)
        service = get_coupang_order_attribution_service()
        stats = service.sync_recent_window()
        return CoupangOrderSyncResponse(**stats.as_dict())

    @router.get(
        "/admin/coupang_orders/recent",
        response_model=CoupangAttributedOrderListResponse,
    )
    async def list_recent_coupang_orders(
        authorization: Optional[str] = Header(None),
        limit: int = 50,
    ):
        _verify_admin_user(authorization)
        service = get_coupang_order_attribution_service()
        items = [
            CoupangAttributedOrder(**row_to_api_item(row))
            for row in service.list_recent_orders(limit=limit)
        ]
        return CoupangAttributedOrderListResponse(items=items)

    @router.get("/coupang_orders/me", response_model=CoupangAttributedOrderListResponse)
    async def list_my_coupang_orders(
        authorization: Optional[str] = Header(None),
        limit: int = 50,
    ):
        uid = _verify_bearer_uid(authorization)
        service = get_coupang_order_attribution_service()
        items = [
            CoupangAttributedOrder(**row_to_api_item(row))
            for row in service.list_user_orders(uid, limit=limit)
        ]
        return CoupangAttributedOrderListResponse(items=items)

    return router
