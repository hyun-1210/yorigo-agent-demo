"""
냉장고 사진/영수증 스캔 엔드포인트

Firebase ID Token 인증 필수 (비전 LLM 호출 비용이 있어 비회원/우회 호출을 막는다).
Phase 1 = photo_type="receipt" 만 프론트에 노출. "fridge_interior"는 백엔드
계약을 미리 완성해 둔 것으로, Phase 2에서 프론트가 붙는다.
"""

import logging
import os
from typing import Optional

from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from firebase_admin import auth as firebase_auth

from models import FridgeScanResponse
from rate_limiter import check_fridge_photo_scan_rate_limit
from services.firebase_service import get_firebase_service
from services.fridge_vision_service import FridgeVisionService, get_fridge_vision_service
from services.mixpanel_service import get_mixpanel_service

logger = logging.getLogger(__name__)

_VALID_PHOTO_TYPES = {"receipt", "fridge_interior"}
_MAX_IMAGE_BYTES = int(os.getenv("FRIDGE_SCAN_MAX_IMAGE_BYTES", str(8 * 1024 * 1024)))


def _verify_bearer_uid(authorization: Optional[str]) -> str:
    """ingredient_price.py와 동일한 Firebase ID Token 검증 패턴."""
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


def _track_llm_usage(uid: str, event: str, usage_tokens, **extra) -> None:
    inp, out, think = usage_tokens or (0, 0, 0)
    if not (inp or out or think):
        return
    get_mixpanel_service().track(uid, event, {
        "llm_input_tokens": inp,
        "llm_output_tokens": out,
        "llm_thinking_tokens": think,
        "llm_total_tokens": inp + out + think,
        **extra,
    })


def create_fridge_router(fridge_vision_service: FridgeVisionService = None):
    """Create fridge router with service injected. If None, lazily loaded."""
    router = APIRouter(prefix="/fridge", tags=["fridge"])

    def get_service() -> FridgeVisionService:
        return fridge_vision_service if fridge_vision_service is not None else get_fridge_vision_service()

    @router.post("/scan_photo", response_model=FridgeScanResponse)
    async def scan_photo(
        image: UploadFile = File(...),
        photo_type: str = Form(...),
        authorization: Optional[str] = Header(None),
    ):
        """
        영수증/냉장고 사진을 업로드하면 Gemini 비전으로 재료 목록을 인식해
        반환합니다. Firebase ID Token 필수. 실패해도 500이 아니라
        items=[] + warning으로 응답해 프론트가 수동 추가로 자연스럽게
        디그레이드할 수 있게 합니다.
        """
        if os.getenv("ENABLE_FRIDGE_PHOTO_SCAN", "true").lower() not in ("1", "true", "yes"):
            raise HTTPException(status_code=503, detail="Feature disabled")

        photo_type_norm = (photo_type or "").strip()
        if photo_type_norm not in _VALID_PHOTO_TYPES:
            raise HTTPException(status_code=400, detail=f"invalid photo_type: {photo_type!r}")

        uid = _verify_bearer_uid(authorization)
        check_fridge_photo_scan_rate_limit(uid)

        # 클라이언트가 Content-Type을 안 붙이는 경우(예: 기본 옥텟스트림)가 흔해
        # 명시적으로 텍스트/PDF 등인 경우만 걸러내고, 나머지는 이미지 디코딩
        # 단계(FridgeVisionService._downscale_image)에서 자연히 걸러지게 둔다.
        content_type = (image.content_type or "").lower()
        if content_type and content_type.startswith(("text/", "application/pdf")):
            raise HTTPException(status_code=400, detail="uploaded file must be an image")

        raw = await image.read()
        if not raw:
            raise HTTPException(status_code=400, detail="empty image")
        if len(raw) > _MAX_IMAGE_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"image too large (max {_MAX_IMAGE_BYTES} bytes)",
            )

        service = get_service()
        result = service.analyze_photo(raw, photo_type=photo_type_norm)

        _track_llm_usage(
            uid,
            "llm_fridge_photo_scan",
            getattr(service, "last_usage_tokens", None),
            photo_type=photo_type_norm,
            item_count=len(result.items),
            has_warning=bool(result.warning),
        )

        # 영수증 스캔은 "냉장고에 뭘 담을지"와 무관하게 실제 구매 이력(가격/매장명/
        # 수량/재료)을 사용자별로 남긴다. 사용자가 review 다이얼로그에서 일부만
        # 골라 냉장고에 담아도, 영수증에 찍힌 구매 내역 자체는 그대로 저장한다.
        # 실패해도 스캔 응답 자체는 정상 반환한다(best-effort, 부가 기능).
        if photo_type_norm == "receipt" and result.items:
            try:
                from services.fridge_vision_service import build_store_match_query

                get_firebase_service().save_receipt_purchase(
                    uid,
                    store_name=result.store_name,
                    store_branch=result.store_branch,
                    store_address=result.store_address,
                    region_sido=result.region_sido,
                    region_sigungu=result.region_sigungu,
                    match_query=build_store_match_query(
                        store_name=result.store_name,
                        store_branch=result.store_branch,
                        store_address=result.store_address,
                        region_sido=result.region_sido,
                        region_sigungu=result.region_sigungu,
                    ),
                    purchased_at=result.purchased_at,
                    items=[item.model_dump() for item in result.items],
                )
            except Exception:
                logger.exception("영수증 구매 이력 저장 실패 (uid=%s)", uid)

        return result

    return router
