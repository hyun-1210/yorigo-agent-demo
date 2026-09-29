"""
구매완료 사진 인증 서비스 (온라인 주문확인 스크린샷 검증)

장바구니 → 쿠팡/컬리 "구매 완료" 시 자가신고(15P 대비 훨씬 낮은 신뢰도)보다
훨씬 높은 포인트를 주기 위해, 온라인 주문확인 화면 스크린샷을 Gemini 비전으로
분석해 마켓명/주문번호/결제금액/주문일시를 추출한다.

기존 냉장고 영수증 스캔(fridge_vision_service.py, photo_type=receipt)과는
완전히 별도의 플로우다 — 영수증은 오프라인 매장 영수증에서 "식재료 목록"을
뽑는 것이고, 이건 온라인 마켓 주문확인 화면에서 "주문 메타데이터"만 뽑는다.

스크린샷 위변조는 100% 방지할 수 없으므로(포토샵, 과거 캡처 재사용) 다층
방어를 전제로 설계한다 — 최종 판단(자동승인 vs 관리자 검수 큐)은 이 서비스가
아니라 라우터(purchase_verification.py)가 휴리스틱 점수를 조합해 내린다.
"""

import hashlib
import io
import json
import logging
import os
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional

from google import genai
from google.genai import types

logger = logging.getLogger(__name__)

_MAX_IMAGE_DIMENSION = 1600
_MAX_RETRIES = 1

_KNOWN_MARKETPLACES = {"coupang", "kurly", "unknown"}

_ORDER_SCREENSHOT_PROMPT = """
당신은 한국 온라인 쇼핑몰(쿠팡, 마켓컬리 등)의 "주문 완료/주문 상세" 화면
스크린샷을 읽고 주문 정보를 구조화하는 비전 모델입니다.

작업:
1. 화면이 쿠팡(Coupang)인지 마켓컬리(Market Kurly)인지 로고·UI 스타일·색상으로
   판별하세요. 확신이 없으면 "unknown"으로 두세요.
2. 주문번호(주문 ID)를 찾아 그대로 넣으세요. 여러 자리 숫자/영숫자 조합입니다.
   찾을 수 없으면 null.
3. 총 결제금액(원)을 숫자로 넣으세요. "총 결제금액", "결제완료", "합계" 등의
   라벨 옆 숫자를 사용하세요. 할인 전 금액이 아니라 실제 결제된 최종 금액입니다.
4. 주문일시를 찾아 "YYYY-MM-DD HH:MM" 형식으로 넣으세요 (시간이 없으면 날짜만,
   "YYYY-MM-DD"). 찾을 수 없으면 null.
5. 이 화면이 실제 "주문 완료/주문 상세" 화면이 아니라(예: 장바구니, 상품
   상세, 관계없는 스크린샷) 판단되면 is_order_confirmation=false로 표시하세요.
6. 개인정보(수령인 이름, 전화번호, 상세 배송주소)는 어떤 필드에도 담지 마세요.

출력 형식 (JSON 객체 1개, 다른 설명·마크다운 절대 금지):
{
  "marketplace": "coupang" | "kurly" | "unknown",
  "order_number": str|null,
  "total_amount": number|null,
  "purchased_at": str|null,
  "is_order_confirmation": bool,
  "confidence": number(0~1)
}
"""


@dataclass
class PurchaseScreenshotResult:
    marketplace: str
    order_number: Optional[str]
    total_amount: Optional[int]
    purchased_at: Optional[str]
    is_order_confirmation: bool
    confidence: float
    warning: Optional[str] = None


class PurchaseVerificationService:
    """온라인 주문확인 스크린샷 → 구조화된 주문 메타데이터 추출."""

    def __init__(self) -> None:
        self._model = os.getenv(
            "PURCHASE_VERIFICATION_GEMINI_MODEL", os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
        )
        self._client: Optional["genai.Client"] = None

    def _get_gemini_client(self) -> "genai.Client":
        if self._client is not None:
            return self._client
        key = os.getenv("GEMINI_API_KEY")
        if not key:
            raise ValueError("GEMINI_API_KEY not found in environment")
        timeout_ms = int(os.getenv("PURCHASE_VERIFICATION_HTTP_TIMEOUT_SECONDS", "60")) * 1000
        self._client = genai.Client(api_key=key, http_options={"timeout": timeout_ms})
        return self._client

    @staticmethod
    def image_sha256(image_bytes: bytes) -> str:
        """동일 이미지 재제출(재사용) 탐지용 정확 일치 해시.

        진짜 perceptual hash(약간의 크롭/리사이즈에도 강건)는 아니지만, 같은
        스크린샷 파일을 그대로 재업로드하는 가장 흔한 어뷰징 패턴은 막는다.
        """
        return hashlib.sha256(image_bytes).hexdigest()

    @staticmethod
    def _downscale_image(image_bytes: bytes) -> bytes:
        try:
            from PIL import Image
        except ImportError:
            return image_bytes
        try:
            img = Image.open(io.BytesIO(image_bytes))
            img = img.convert("RGB")
        except Exception:
            return image_bytes
        w, h = img.size
        if max(w, h) > _MAX_IMAGE_DIMENSION:
            scale = _MAX_IMAGE_DIMENSION / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
        try:
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=88)
            return buf.getvalue()
        except Exception:
            return image_bytes

    @staticmethod
    def _strip_md_fences(text: str) -> str:
        s = text.strip()
        if s.startswith("```"):
            nl = s.find("\n")
            s = s[nl + 1:] if nl != -1 else s[3:]
            if s.rstrip().endswith("```"):
                s = s.rstrip()[:-3].rstrip()
        return s

    def _parse_result(self, data: Dict[str, Any]) -> PurchaseScreenshotResult:
        marketplace = str(data.get("marketplace") or "unknown").strip().lower()
        if marketplace not in _KNOWN_MARKETPLACES:
            marketplace = "unknown"

        order_number = data.get("order_number")
        order_number_str = str(order_number).strip()[:64] if order_number else None

        total_amount: Optional[int] = None
        raw_amount = data.get("total_amount")
        if raw_amount is not None:
            try:
                amount_val = round(float(raw_amount))
                if 0 < amount_val <= 50_000_000:
                    total_amount = int(amount_val)
            except (TypeError, ValueError):
                total_amount = None

        purchased_at = data.get("purchased_at")
        purchased_at_str = str(purchased_at).strip()[:32] if purchased_at else None

        is_order_confirmation = bool(data.get("is_order_confirmation", False))

        try:
            confidence = float(data.get("confidence"))
        except (TypeError, ValueError):
            confidence = 0.5
        confidence = max(0.0, min(1.0, confidence))

        return PurchaseScreenshotResult(
            marketplace=marketplace,
            order_number=order_number_str,
            total_amount=total_amount,
            purchased_at=purchased_at_str,
            is_order_confirmation=is_order_confirmation,
            confidence=confidence,
        )

    def analyze_screenshot(self, image_bytes: bytes) -> PurchaseScreenshotResult:
        """실패해도 예외를 던지지 않고 warning이 채워진 결과를 반환한다."""
        resized = self._downscale_image(image_bytes)

        try:
            client = self._get_gemini_client()
        except Exception as e:
            logger.warning("PurchaseVerificationService: Gemini client unavailable: %s", e)
            return PurchaseScreenshotResult(
                marketplace="unknown",
                order_number=None,
                total_amount=None,
                purchased_at=None,
                is_order_confirmation=False,
                confidence=0.0,
                warning="지금은 사진 인증을 사용할 수 없어요. 잠시 후 다시 시도해주세요.",
            )

        parts = [
            types.Part.from_text(text=_ORDER_SCREENSHOT_PROMPT),
            types.Part.from_bytes(data=resized, mime_type="image/jpeg"),
        ]
        config_kwargs: Dict[str, Any] = {
            "response_mime_type": "application/json",
            "temperature": 0.1,
        }
        if hasattr(types, "ThinkingConfig"):
            config_kwargs["thinking_config"] = types.ThinkingConfig(thinking_budget=0)

        last_err: Optional[Exception] = None
        for attempt in range(_MAX_RETRIES + 1):
            try:
                resp = client.models.generate_content(
                    model=self._model,
                    contents=[types.Content(role="user", parts=parts)],
                    config=types.GenerateContentConfig(**config_kwargs),
                )
                raw = (getattr(resp, "text", None) or "").strip()
                if not raw:
                    raise ValueError("Empty response from Gemini")
                cleaned = self._strip_md_fences(raw)
                data = json.loads(cleaned)
                if not isinstance(data, dict):
                    raise ValueError("Unexpected response shape")
                return self._parse_result(data)
            except Exception as e:
                last_err = e
                if attempt < _MAX_RETRIES:
                    time.sleep(1.0)
                    continue
                break

        logger.warning("PurchaseVerificationService: analyze_screenshot failed: %s", last_err)
        return PurchaseScreenshotResult(
            marketplace="unknown",
            order_number=None,
            total_amount=None,
            purchased_at=None,
            is_order_confirmation=False,
            confidence=0.0,
            warning="스크린샷에서 주문 정보를 인식하지 못했어요.",
        )


_purchase_verification_service: Optional[PurchaseVerificationService] = None


def get_purchase_verification_service() -> PurchaseVerificationService:
    global _purchase_verification_service
    if _purchase_verification_service is None:
        _purchase_verification_service = PurchaseVerificationService()
    return _purchase_verification_service
