"""
ingredient_unit_prices 보조: 클라이언트가 가격 문서가 없는 재료명을 보고하여 큐에 적재
"""

import os
import logging
from typing import List, Optional

from fastapi import APIRouter, Header, HTTPException

from firebase_admin import auth as firebase_auth

from models import (
    ReportMissingIngredientPricesRequest,
    ReportMissingIngredientPricesResponse,
    ReportIngredientPriceIssueRequest,
    ReportIngredientPriceIssueResponse,
    RequestIngredientUnitPriceRequest,
    RequestIngredientUnitPriceResponse,
)
from services.firebase_service import get_firebase_service
from services.llm_service import get_llm_service
from services.mixpanel_service import get_mixpanel_service
from utils.ingredient_price_validation import validate_and_adjust_unit_price
from rate_limiter import check_report_missing_ingredient_prices_rate_limit
from rate_limiter import check_report_ingredient_price_issue_rate_limit
from rate_limiter import check_request_unit_price_rate_limit

logger = logging.getLogger(__name__)


def _max_names() -> int:
    return int(os.getenv("REPORT_MISSING_INGREDIENT_PRICES_MAX_NAMES", "30"))


def _max_name_len() -> int:
    return int(os.getenv("REPORT_MISSING_INGREDIENT_PRICE_NAME_MAX_LEN", "80"))


def create_ingredient_price_router():
    router = APIRouter(prefix="", tags=["ingredient_prices"])

    def _verify_bearer_uid(authorization: Optional[str]) -> str:
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

    @router.post(
        "/ingredient_prices/report_missing",
        response_model=ReportMissingIngredientPricesResponse,
    )
    def report_missing_ingredient_prices(
        req: ReportMissingIngredientPricesRequest,
        authorization: Optional[str] = Header(None),
    ):
        """
        Firebase ID Token 필수. 가격 문서가 없는 재료명을 config/pending_unit_price_ingredients에 적재.
        """
        if os.getenv("ENABLE_REPORT_MISSING_INGREDIENT_PRICES", "true").lower() not in ("1", "true", "yes"):
            raise HTTPException(status_code=503, detail="Feature disabled")

        uid = _verify_bearer_uid(authorization)
        check_report_missing_ingredient_prices_rate_limit(uid)

        max_n = _max_names()
        max_len = _max_name_len()
        raw_names: List[str] = req.names or []
        if len(raw_names) > max_n:
            raise HTTPException(
                status_code=400,
                detail=f"Too many names (max {max_n})",
            )

        firebase = get_firebase_service()
        if not firebase.is_available():
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        skipped = 0
        filtered: List[str] = []
        for raw in raw_names:
            if not isinstance(raw, str):
                skipped += 1
                continue
            s = raw.strip()
            if not s:
                skipped += 1
                continue
            if len(s) > max_len:
                skipped += 1
                continue
            filtered.append(s)

        if not filtered:
            return ReportMissingIngredientPricesResponse(accepted=0, skipped=skipped)

        accepted = firebase.add_pending_unit_price_ingredients(filtered)
        return ReportMissingIngredientPricesResponse(accepted=accepted, skipped=skipped)

    @router.post(
        "/ingredient_prices/report_price_issue",
        response_model=ReportIngredientPriceIssueResponse,
    )
    def report_ingredient_price_issue(
        req: ReportIngredientPriceIssueRequest,
        authorization: Optional[str] = Header(None),
    ):
        """
        Firebase ID Token 필수. 단가가 부정확해 보인다고 보고한 재료를
        config/pending_unit_price_recheck_ingredients에 적재하고, 감사용 로그를 남깁니다.
        24시간 주기 스케줄러가 LLM으로 재추정 후 ingredient_unit_prices를 덮어씁니다.
        """
        if os.getenv("ENABLE_REPORT_INGREDIENT_PRICE_ISSUE", "true").lower() not in (
            "1",
            "true",
            "yes",
        ):
            raise HTTPException(status_code=503, detail="Feature disabled")

        uid = _verify_bearer_uid(authorization)
        check_report_ingredient_price_issue_rate_limit(uid)

        max_n = _max_names()
        max_len = _max_name_len()
        raw_names: List[str] = req.ingredient_names or []
        if len(raw_names) > max_n:
            raise HTTPException(
                status_code=400,
                detail=f"Too many names (max {max_n})",
            )

        firebase = get_firebase_service()
        if not firebase.is_available():
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        skipped = 0
        filtered: List[str] = []
        seen_in_req: set = set()
        for raw in raw_names:
            if not isinstance(raw, str):
                skipped += 1
                continue
            s = raw.strip()
            if not s:
                skipped += 1
                continue
            if len(s) > max_len:
                skipped += 1
                continue
            if s in seen_in_req:
                skipped += 1
                continue
            seen_in_req.add(s)
            filtered.append(s)

        if not filtered:
            return ReportIngredientPriceIssueResponse(accepted=0, skipped=skipped)

        accepted = firebase.add_pending_unit_price_recheck_ingredients(filtered)

        msg = (req.message or "").strip()
        if len(msg) > 500:
            msg = msg[:500]

        firebase.save_ingredient_price_issue_report(
            {
                "userId": uid,
                "ingredientNames": filtered,
                "message": msg,
                "recipeId": (req.recipe_id or "").strip(),
                "recipeTitle": (req.recipe_title or "").strip(),
            }
        )

        return ReportIngredientPriceIssueResponse(accepted=accepted, skipped=skipped)

    @router.post(
        "/ingredient_prices/request_unit_price",
        response_model=RequestIngredientUnitPriceResponse,
    )
    def request_ingredient_unit_price(
        req: RequestIngredientUnitPriceRequest,
        authorization: Optional[str] = Header(None),
    ):
        """
        요청된 baseUnit의 재료 단위가격을 on-demand로 생성해서 저장합니다.
        Firestore 스키마:
          ingredient_unit_prices/{ingredient}/units/{unitKey}
        """
        if os.getenv("ENABLE_REQUEST_UNIT_PRICE", "true").lower() not in ("1", "true", "yes"):
            raise HTTPException(status_code=503, detail="Feature disabled")

        uid = _verify_bearer_uid(authorization)

        firebase = get_firebase_service()
        if not firebase.is_available():
            raise HTTPException(status_code=503, detail="Firebase unavailable")

        ingredient_name = (req.ingredient_name or "").strip()
        requested_base_unit = (req.requested_base_unit or "").strip()
        if not ingredient_name or not requested_base_unit:
            raise HTTPException(status_code=400, detail="Invalid ingredient_name or requested_base_unit")

        unit_key = firebase.normalize_unit_key_for_unit_prices(requested_base_unit)
        if not unit_key:
            raise HTTPException(status_code=400, detail="Invalid requested_base_unit")

        existing = firebase.get_ingredient_unit_price(ingredient_name, unit_key)
        if existing and existing.get("unitPrice") is not None and existing.get("baseUnit"):
            return RequestIngredientUnitPriceResponse(
                ingredientName=ingredient_name,
                unitPrice=float(existing.get("unitPrice")),
                baseUnit=str(existing.get("baseUnit")),
                confidence=float(existing.get("confidence")) if existing.get("confidence") is not None else None,
                source=str(existing.get("source") or "ai_estimate"),
                reasoning=existing.get("reasoning"),
            )

        if firebase.price_retry_block_reason(ingredient_name):
            raise HTTPException(
                status_code=404,
                detail="Unit price lookup already failed for this ingredient",
            )

        check_request_unit_price_rate_limit(uid)
        llm_service = get_llm_service()
        llm_service.reset_last_usage_tokens()
        price_data = llm_service.get_ingredient_price_from_ai_with_base_unit(
            ingredient_name=ingredient_name,
            requested_base_unit=requested_base_unit,
        )
        _inp, _out, _think = llm_service.last_usage_tokens
        if _inp or _out or _think:
            get_mixpanel_service().track(uid, "llm_ingredient_unit_price_ondemand", {
                "llm_input_tokens": _inp,
                "llm_output_tokens": _out,
                "llm_thinking_tokens": _think,
                "llm_total_tokens": _inp + _out + _think,
                "success": bool(price_data and price_data.get("unitPrice") is not None),
                "requested_base_unit": requested_base_unit,
            })

        if not price_data or price_data.get("unitPrice") is None or not price_data.get("baseUnit"):
            if llm_service.last_price_outcome == "unavailable":
                firebase.record_price_attempt_results([], [ingredient_name])
            else:
                firebase.record_price_attempt_results(
                    [], [], permanent_names=[ingredient_name]
                )
            raise HTTPException(status_code=404, detail="Unit price not found for requested baseUnit")

        top_doc = firebase.get_ingredient_price(ingredient_name)
        validation = validate_and_adjust_unit_price(
            ingredient_name=ingredient_name,
            unit_key=unit_key,
            top_price_doc=top_doc,
            price_data=price_data,
        )
        if not validation.ok:
            firebase.record_price_attempt_results([], [], permanent_names=[ingredient_name])
            logger.warning(
                f"Blocked abnormal unit price for '{ingredient_name}' unit '{unit_key}': {validation.reason}"
            )
            raise HTTPException(status_code=422, detail=validation.reason)
        price_data = validation.adjusted_price_data

        saved_ok = firebase.save_ingredient_unit_price(
            ingredient_name=ingredient_name,
            unit_key=unit_key,
            price_data=price_data,
        )
        if not saved_ok:
            firebase.record_price_attempt_results([], [ingredient_name])
            raise HTTPException(status_code=500, detail="Failed to save unit price")
        firebase.record_price_attempt_results([ingredient_name], [])

        return RequestIngredientUnitPriceResponse(
            ingredientName=ingredient_name,
            unitPrice=float(price_data.get("unitPrice")),
            baseUnit=str(price_data.get("baseUnit")),
            confidence=float(price_data.get("confidence")) if price_data.get("confidence") is not None else None,
            source=str(price_data.get("source") or "ai_estimate"),
            reasoning=price_data.get("reasoning"),
        )

    return router
