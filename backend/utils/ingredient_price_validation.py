from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional


@dataclass
class UnitPriceValidationResult:
    ok: bool
    adjusted_price_data: Dict[str, Any]
    reason: str = ""


_KNOWN_GRAMS_PER_PIECE: Dict[str, float] = {
    "두부": 300.0,
    "계란": 52.0,
    "달걀": 52.0,
    "버터": 450.0,
    "스팸": 200.0,
    "참치캔": 135.0,
    "브로콜리": 350.0,
    "애호박": 350.0,
    "청양고추": 12.0,
}

_MIN_G_PER_PIECE = 20.0
_MAX_G_PER_PIECE = 1200.0
_MIN_ML_PER_PIECE = 20.0
_MAX_ML_PER_PIECE = 2000.0
_COUNT_LIKE_UNITS = {"개", "캔", "팩", "봉", "봉지", "통", "병"}


def _to_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _is_count_like_unit(unit: str) -> bool:
    return (unit or "").strip().lower() in _COUNT_LIKE_UNITS


def validate_and_adjust_unit_price(
    *,
    ingredient_name: str,
    unit_key: str,
    top_price_doc: Optional[Dict[str, Any]],
    price_data: Dict[str, Any],
) -> UnitPriceValidationResult:
    """
    on-demand unit price 저장 전 검증/보정.
    - 같은 단위를 중복 생성하면 top 가격으로 강제 정합화
    - 개 <-> g/ml 환산이 비정상 범위이면 차단
    - 일부 핵심 재료는 표준 중량으로 자동 보정
    """
    if not top_price_doc:
        return UnitPriceValidationResult(ok=True, adjusted_price_data=price_data)

    adjusted = dict(price_data)
    top_unit = str(top_price_doc.get("baseUnit") or "").strip().lower()
    top_price = _to_float(top_price_doc.get("unitPrice"))
    req_unit = str(unit_key or "").strip().lower()
    req_price = _to_float(adjusted.get("unitPrice"))

    if not top_unit or top_price is None or req_price is None or req_price <= 0:
        return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

    # same-unit 중복 요청은 top 문서 값을 우선으로 강제
    if req_unit == top_unit:
        if abs(req_price - top_price) > 0.01:
            adjusted["unitPrice"] = top_price
            adjusted["source"] = "consistency_adjusted"
            adjusted["reasoning"] = (
                f"Top 문서와 동일 단위({req_unit}) 불일치 보정: "
                f"{req_price} -> {top_price}"
            )
        return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

    # top=개, request=g/ml
    if _is_count_like_unit(top_unit) and req_unit in ("g", "ml"):
        implied = top_price / req_price
        min_v, max_v = (
            (_MIN_G_PER_PIECE, _MAX_G_PER_PIECE)
            if req_unit == "g"
            else (_MIN_ML_PER_PIECE, _MAX_ML_PER_PIECE)
        )
        if min_v <= implied <= max_v:
            return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

        std_g = _KNOWN_GRAMS_PER_PIECE.get(ingredient_name)
        if req_unit == "g" and std_g:
            corrected = round(top_price / std_g, 4)
            adjusted["unitPrice"] = corrected
            adjusted["source"] = "consistency_adjusted"
            adjusted["reasoning"] = (
                f"비정상 환산({implied:.1f}{req_unit}/{top_unit}) 자동 보정: "
                f"{ingredient_name} 표준 {std_g:g}g/{top_unit} 기준 {corrected}원/g"
            )
            return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

        return UnitPriceValidationResult(
            ok=False,
            adjusted_price_data=adjusted,
            reason=(
                f"비정상 단위 환산 감지: top={top_price}원/{top_unit}, "
                f"request={req_price}원/{req_unit}, implied={implied:.1f}{req_unit}/{top_unit}"
            ),
        )

    # top=g/ml, request=count-like
    if top_unit in ("g", "ml") and _is_count_like_unit(req_unit):
        implied = req_price / top_price
        min_v, max_v = (
            (_MIN_G_PER_PIECE, _MAX_G_PER_PIECE)
            if top_unit == "g"
            else (_MIN_ML_PER_PIECE, _MAX_ML_PER_PIECE)
        )
        if min_v <= implied <= max_v:
            return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

        std_g = _KNOWN_GRAMS_PER_PIECE.get(ingredient_name)
        if top_unit == "g" and std_g:
            corrected = round(top_price * std_g, 2)
            adjusted["unitPrice"] = corrected
            adjusted["source"] = "consistency_adjusted"
            adjusted["reasoning"] = (
                f"비정상 환산({implied:.1f}g/{req_unit}) 자동 보정: "
                f"{ingredient_name} 표준 {std_g:g}g/{req_unit} 기준 {corrected}원/{req_unit}"
            )
            return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)

        return UnitPriceValidationResult(
            ok=False,
            adjusted_price_data=adjusted,
            reason=(
                f"비정상 단위 환산 감지: top={top_price}원/{top_unit}, "
                f"request={req_price}원/{req_unit}, implied={implied:.1f}{top_unit}/{req_unit}"
            ),
        )

    return UnitPriceValidationResult(ok=True, adjusted_price_data=adjusted)
