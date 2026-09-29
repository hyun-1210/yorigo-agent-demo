"""
구매완료 사진 인증 엔드포인트 (온라인 주문확인 스크린샷)

Firebase ID Token 인증 필수. 기존 냉장고 영수증 스캔(routers/fridge.py)과는
완전히 별도의 플로우 — 대상은 쿠팡/컬리 온라인 주문확인 화면 스크린샷이다.

판정 로직 (스크린샷 위변조는 100% 방지 불가하므로 다층 방어):
1. 이미지 해시 중복 제출 → 즉시 거절
2. Gemini Vision으로 마켓/주문번호/금액/주문일시 추출
3. 주문확인 화면이 아니라고 판단되면 → 거절
4. 동일 계정 내 주문번호 재사용 → 거절
5. 주문일시가 48시간 이내가 아니면 → 관리자 검수 큐
6. 신뢰도가 낮거나 핵심 필드(주문번호/금액)가 비어있으면 → 관리자 검수 큐
7. 결제금액이 최소 기준 미만이면 → 자가신고 수준으로 다운그레이드해 즉시 승인
8. 그 외(신뢰도 충분 + 최근 + 필드 완비) → 즉시 승인, 최고 배점 지급
"""

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from firebase_admin import auth as firebase_auth, firestore

from models import (
    PurchaseVerificationReviewRequest,
    PurchaseVerificationStatusResponse,
    PurchaseVerificationSubmitResponse,
)
from rate_limiter import check_purchase_verification_rate_limit
from services.firebase_service import get_firebase_service
from services.purchase_verification_service import (
    PurchaseVerificationService,
    get_purchase_verification_service,
)
from services.rewards_service import get_rewards_service

logger = logging.getLogger(__name__)

_MAX_IMAGE_BYTES = int(os.getenv("PURCHASE_VERIFICATION_MAX_IMAGE_BYTES", str(8 * 1024 * 1024)))
_MIN_VERIFIED_AMOUNT = 5_000
_RECENCY_WINDOW_HOURS = 48
_AUTO_APPROVE_MIN_CONFIDENCE = 0.75
_QUEUE_COLLECTION = "purchase_verification_queue"


def _verify_bearer_uid(authorization: Optional[str]) -> str:
    """fridge.py와 동일한 Firebase ID Token 검증 패턴."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Empty bearer token")
    try:
        decoded = firebase_auth.verify_id_token(token)
        uid = decoded.get("uid")
        if not uid:
            raise HTTPException(status_code=401, detail="Invalid token payload")
        return uid
    except HTTPException:
        raise
    except Exception as e:
        logger.warning(f"Firebase ID token verification failed: {e}")
        raise HTTPException(status_code=401, detail="Invalid or expired ID token")


def _verify_admin_decoded_token(authorization: Optional[str]) -> str:
    """관리자 전용 엔드포인트용 — uid 검증 + admin_emails 컬렉션 확인."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization[7:].strip()
    try:
        decoded = firebase_auth.verify_id_token(token)
    except Exception as e:
        logger.warning(f"Firebase ID token verification failed: {e}")
        raise HTTPException(status_code=401, detail="Invalid or expired ID token")

    uid = decoded.get("uid")
    email = (decoded.get("email") or "").strip().lower()
    email_verified = bool(decoded.get("email_verified"))
    if not uid or not email or not email_verified:
        raise HTTPException(status_code=403, detail="Admin check failed")

    db = get_firebase_service().db
    if db is None:
        raise HTTPException(status_code=503, detail="Firebase unavailable")
    admin_doc = db.collection("admin_emails").document(email).get()
    admin_data = admin_doc.to_dict() or {}
    if not admin_doc.exists or admin_data.get("active") is not True:
        raise HTTPException(status_code=403, detail="Admin only")
    return uid


def _parse_purchased_at(raw: Optional[str]) -> Optional[datetime]:
    if not raw:
        return None
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(raw, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def create_purchase_verification_router(
    service: PurchaseVerificationService = None,
) -> APIRouter:
    router = APIRouter(prefix="/purchase-verification", tags=["purchase-verification"])

    def get_service() -> PurchaseVerificationService:
        return service if service is not None else get_purchase_verification_service()

    @router.post("/submit", response_model=PurchaseVerificationSubmitResponse)
    async def submit(
        image: UploadFile = File(...),
        authorization: Optional[str] = Header(None),
    ):
        if os.getenv("ENABLE_PURCHASE_VERIFICATION", "true").lower() not in ("1", "true", "yes"):
            raise HTTPException(status_code=503, detail="Feature disabled")

        uid = _verify_bearer_uid(authorization)
        check_purchase_verification_rate_limit(uid)

        content_type = (image.content_type or "").lower()
        if content_type and content_type.startswith(("text/", "application/pdf")):
            raise HTTPException(status_code=400, detail="uploaded file must be an image")

        raw = await image.read()
        if not raw:
            raise HTTPException(status_code=400, detail="empty image")
        if len(raw) > _MAX_IMAGE_BYTES:
            raise HTTPException(status_code=413, detail=f"image too large (max {_MAX_IMAGE_BYTES} bytes)")

        firebase = get_firebase_service()
        db = firebase.db
        if db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        image_hash = PurchaseVerificationService.image_sha256(raw)
        verifications_col = db.collection("users").document(uid).collection("purchase_verifications")

        # 1) 동일 이미지 재제출 차단
        dup_image = list(verifications_col.where("imageHash", "==", image_hash).limit(1).stream())
        if dup_image:
            return PurchaseVerificationSubmitResponse(
                verificationId=dup_image[0].id,
                status="rejected",
                reason="duplicate_image",
            )

        result = get_service().analyze_screenshot(raw)

        verification_ref = verifications_col.document()
        base_doc = {
            "imageHash": image_hash,
            "marketplace": result.marketplace,
            "orderNumber": result.order_number,
            "extractedAmount": result.total_amount,
            "purchasedAtRaw": result.purchased_at,
            "confidence": result.confidence,
            "createdAt": firestore.SERVER_TIMESTAMP,
        }

        def _finalize(status: str, points_awarded: int = 0, reason: Optional[str] = None):
            base_doc.update({"status": status, "pointsAwarded": points_awarded, "reason": reason})
            verification_ref.set(base_doc)
            return PurchaseVerificationSubmitResponse(
                verificationId=verification_ref.id,
                status=status,
                pointsAwarded=points_awarded,
                marketplace=result.marketplace,
                extractedAmount=result.total_amount,
                extractedOrderNumber=result.order_number,
                reason=reason,
            )

        # 2) 주문확인 화면이 아니라고 판단되면 거절
        if not result.is_order_confirmation and result.confidence >= 0.6:
            return _finalize("rejected", reason="not_order_confirmation")

        # 3) 동일 계정 내 주문번호 재사용 차단
        if result.order_number:
            dup_order = [
                d for d in verifications_col.where("orderNumber", "==", result.order_number).limit(5).stream()
                if (d.to_dict() or {}).get("status") in ("approved", "pending")
            ]
            if dup_order:
                return _finalize("rejected", reason="duplicate_order_number")

        purchased_at_dt = _parse_purchased_at(result.purchased_at)
        is_recent = (
            purchased_at_dt is not None
            and datetime.now(timezone.utc) - purchased_at_dt <= timedelta(hours=_RECENCY_WINDOW_HOURS)
        )
        has_core_fields = bool(result.order_number) and result.total_amount is not None

        needs_manual_review = (
            not has_core_fields
            or not is_recent
            or result.confidence < _AUTO_APPROVE_MIN_CONFIDENCE
        )

        if needs_manual_review:
            base_doc["status"] = "pending"
            base_doc["pointsAwarded"] = 0
            verification_ref.set(base_doc)
            # 관리자 검수용 큐에도 미러링 (uid를 top-level에 저장해 collectionGroup 없이 조회)
            db.collection(_QUEUE_COLLECTION).document(verification_ref.id).set({
                **base_doc,
                "uid": uid,
            })
            return PurchaseVerificationSubmitResponse(
                verificationId=verification_ref.id,
                status="pending",
                marketplace=result.marketplace,
                extractedAmount=result.total_amount,
                extractedOrderNumber=result.order_number,
                reason="manual_review_required",
            )

        # 4) 최소 결제금액 미달 → 자가신고 수준으로 다운그레이드
        action = "points_purchase_photo_verified"
        if result.total_amount is not None and result.total_amount < _MIN_VERIFIED_AMOUNT:
            action = "points_purchase_self_report"

        award = get_rewards_service().award(
            uid,
            action,
            idempotency_key=f"photo_verify:{uid}:{verification_ref.id}",
            source_ref=verification_ref.id,
        )
        return _finalize(
            "approved" if award.granted else "rejected",
            points_awarded=award.amount if award.granted else 0,
            reason=None if award.granted else award.reason,
        )

    @router.get("/status/{verification_id}", response_model=PurchaseVerificationStatusResponse)
    async def get_status(verification_id: str, authorization: Optional[str] = Header(None)):
        uid = _verify_bearer_uid(authorization)
        db = get_firebase_service().db
        if db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")
        doc = db.collection("users").document(uid).collection("purchase_verifications").document(verification_id).get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="not found")
        data = doc.to_dict() or {}
        created_at = data.get("createdAt")
        return PurchaseVerificationStatusResponse(
            verificationId=doc.id,
            status=data.get("status", "pending"),
            pointsAwarded=int(data.get("pointsAwarded", 0) or 0),
            marketplace=data.get("marketplace"),
            createdAt=created_at.isoformat() if hasattr(created_at, "isoformat") else None,
        )

    @router.get("/admin/queue")
    async def admin_list_queue(authorization: Optional[str] = Header(None)):
        _verify_admin_decoded_token(authorization)
        db = get_firebase_service().db
        if db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")
        docs = (
            db.collection(_QUEUE_COLLECTION)
            .where("status", "==", "pending")
            .limit(100)
            .stream()
        )
        items = []
        for d in docs:
            data = d.to_dict() or {}
            created_at = data.get("createdAt")
            items.append({
                "id": d.id,
                "uid": data.get("uid"),
                "marketplace": data.get("marketplace"),
                "orderNumber": data.get("orderNumber"),
                "extractedAmount": data.get("extractedAmount"),
                "purchasedAtRaw": data.get("purchasedAtRaw"),
                "confidence": data.get("confidence"),
                "createdAt": created_at.isoformat() if hasattr(created_at, "isoformat") else None,
            })
        return {"items": items}

    @router.post("/{verification_id}/review")
    async def admin_review(
        verification_id: str,
        req: PurchaseVerificationReviewRequest,
        authorization: Optional[str] = Header(None),
    ):
        admin_uid = _verify_admin_decoded_token(authorization)
        if req.action not in ("approve", "reject"):
            raise HTTPException(status_code=400, detail="action must be approve|reject")

        db = get_firebase_service().db
        if db is None:
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        queue_ref = db.collection(_QUEUE_COLLECTION).document(verification_id)
        queue_doc = queue_ref.get()
        if not queue_doc.exists:
            raise HTTPException(status_code=404, detail="not found")
        queue_data = queue_doc.to_dict() or {}
        target_uid = queue_data.get("uid")
        if not target_uid:
            raise HTTPException(status_code=500, detail="malformed queue entry")

        user_verification_ref = (
            db.collection("users").document(target_uid).collection("purchase_verifications").document(verification_id)
        )

        points_awarded = 0
        if req.action == "approve":
            award = get_rewards_service().award(
                target_uid,
                "points_purchase_photo_verified",
                idempotency_key=f"photo_verify:{target_uid}:{verification_id}",
                source_ref=verification_id,
            )
            points_awarded = award.amount if award.granted else 0
            new_status = "approved" if award.granted else "rejected"
        else:
            new_status = "rejected"

        update_payload = {
            "status": new_status,
            "pointsAwarded": points_awarded,
            "reviewedBy": admin_uid,
            "reviewedAt": firestore.SERVER_TIMESTAMP,
            "reviewNote": req.note,
        }
        user_verification_ref.set(update_payload, merge=True)
        queue_ref.set(update_payload, merge=True)

        return {"verificationId": verification_id, "status": new_status, "pointsAwarded": points_awarded}

    return router
