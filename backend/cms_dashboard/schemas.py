"""홈 CMS 문서 검증."""

from __future__ import annotations

import re
from typing import Any

from seed_data import MAX_ENABLED_POSTERS, MAX_ENABLED_TREND_SECTIONS

_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_KINDS = {"trend", "program", "moment", "poster_pool"}


def sanitize_key(raw: Any) -> str:
    return str(raw or "").strip()


def require_section_key(raw: Any) -> str:
    key = sanitize_key(raw)
    if not _KEY_RE.match(key):
        raise ValueError("sectionKey 는 영문 소문자/숫자/밑줄만 가능합니다")
    return key


def require_poster_id(raw: Any) -> str:
    key = sanitize_key(raw)
    if not _KEY_RE.match(key):
        raise ValueError("poster id 는 영문 소문자/숫자/밑줄만 가능합니다")
    return key


def _str_list(raw: Any) -> list[str]:
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        s = str(item or "").strip()
        if not s or s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out


def normalize_poster(payload: dict[str, Any], poster_id: str) -> dict[str, Any]:
    chips_in = payload.get("chips") if isinstance(payload.get("chips"), list) else []
    chips: list[dict[str, Any]] = []
    for chip in chips_in:
        if not isinstance(chip, dict):
            continue
        label = str(chip.get("label") or "").strip()
        if not label:
            continue
        section_key = str(chip.get("sectionKey") or "").strip() or None
        chips.append({
            "label": label,
            "sectionKey": section_key,
            "matchKeywords": _str_list(chip.get("matchKeywords")),
        })
    if not chips:
        raise ValueError("칩을 하나 이상 넣어 주세요")

    tips_in = payload.get("tips") if isinstance(payload.get("tips"), list) else []
    tips: list[dict[str, Any]] = []
    for tip in tips_in:
        if not isinstance(tip, dict):
            continue
        title = str(tip.get("title") or "").strip()
        body = str(tip.get("body") or "").strip()
        if not title and not body:
            continue
        tips.append({
            "title": title,
            "body": body,
            "icon": str(tip.get("icon") or "info_outline").strip() or "info_outline",
        })

    products_in = payload.get("products") if isinstance(payload.get("products"), list) else []
    products: list[dict[str, Any]] = []
    for prod in products_in:
        if not isinstance(prod, dict):
            continue
        pid = str(prod.get("id") or "").strip()
        name = str(prod.get("name") or "").strip()
        if not pid or not name:
            continue
        products.append({
            "id": pid,
            "name": name,
            "subtitle": str(prod.get("subtitle") or "").strip(),
            "badge": str(prod.get("badge") or "").strip(),
            "imageUrl": str(prod.get("imageUrl") or "").strip() or None,
            "priceLabel": str(prod.get("priceLabel") or "").strip() or None,
            "searchQuery": str(prod.get("searchQuery") or "").strip() or None,
            "productUrl": str(prod.get("productUrl") or "").strip() or None,
            "landingUrl": str(prod.get("landingUrl") or "").strip() or None,
            "deeplinkUrl": str(prod.get("deeplinkUrl") or "").strip() or None,
        })

    poster_title = str(payload.get("posterTitle") or "").strip()
    if not poster_title:
        raise ValueError("포스터 제목이 필요합니다")

    return {
        "id": poster_id,
        "order": int(payload.get("order") or 0),
        "enabled": bool(payload.get("enabled", True)),
        "assetPath": str(payload.get("assetPath") or "").strip(),
        "imageUrl": str(payload.get("imageUrl") or "").strip() or None,
        "posterTitle": poster_title,
        "subtitle": str(payload.get("subtitle") or "").strip(),
        "pageTitle": str(payload.get("pageTitle") or poster_title).strip(),
        "body": str(payload.get("body") or "").strip(),
        "eyebrow": str(payload.get("eyebrow") or "요리고 큐레이션").strip(),
        "chips": chips,
        "poolSectionKeys": _str_list(payload.get("poolSectionKeys")),
        "tips": tips,
        "tipsSectionTitle": str(payload.get("tipsSectionTitle") or "").strip() or None,
        "products": products,
        "productsSectionTitle": str(payload.get("productsSectionTitle") or "추천 상품").strip(),
        "recipeSectionTitle": str(payload.get("recipeSectionTitle") or "레시피 고르기").strip(),
        "showFridgeCta": bool(payload.get("showFridgeCta", False)),
        "fridgeCtaLabel": str(payload.get("fridgeCtaLabel") or "").strip() or None,
        "strictKeywordMatch": bool(payload.get("strictKeywordMatch", False)),
        "imageAlignment": str(payload.get("imageAlignment") or "centerRight").strip()
        or "centerRight",
    }


def normalize_section(payload: dict[str, Any], section_key: str) -> dict[str, Any]:
    label = str(payload.get("label") or "").strip()
    if not label:
        raise ValueError("섹션 라벨이 필요합니다")
    kind = str(payload.get("kind") or "trend").strip()
    if kind not in _KINDS:
        raise ValueError(f"kind 는 {_KINDS} 중 하나여야 합니다")
    match_rules = payload.get("matchRules")
    if match_rules is None:
        match_rules = {}
    if not isinstance(match_rules, dict):
        raise ValueError("matchRules 는 객체여야 합니다")
    ui_hints = payload.get("uiHints")
    if ui_hints is not None and not isinstance(ui_hints, dict):
        ui_hints = {}
    active_until = str(payload.get("activeUntil") or "").strip() or None
    return {
        "sectionKey": section_key,
        "label": label,
        "order": int(payload.get("order") or 0),
        "enabled": bool(payload.get("enabled", True)),
        "kind": kind,
        "membersOnly": bool(payload.get("membersOnly", False)),
        "activeUntil": active_until,
        "matchRules": match_rules,
        "uiHints": ui_hints or {},
    }


def assert_exposure_caps(
    posters: list[dict[str, Any]],
    sections: list[dict[str, Any]],
) -> None:
    enabled_posters = sum(1 for p in posters if p.get("enabled"))
    if enabled_posters > MAX_ENABLED_POSTERS:
        raise ValueError(f"노출 포스터는 최대 {MAX_ENABLED_POSTERS}개입니다")
    enabled_trend = sum(
        1
        for s in sections
        if s.get("enabled") and s.get("kind") in ("trend", "moment")
    )
    if enabled_trend > MAX_ENABLED_TREND_SECTIONS:
        raise ValueError(f"노출 카테고리는 최대 {MAX_ENABLED_TREND_SECTIONS}개입니다")
    if enabled_posters < 1:
        raise ValueError("포스터를 최소 1개는 켜 두세요")
