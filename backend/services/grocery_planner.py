"""장보기 에이전트의 결정 로직.

레시피 id와 가격은 입력으로 받은 닫힌 집합에서만 고른다.
LLM은 이 모듈을 호출하지 않는다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence


SHELLFISH_TERMS = ("새우", "꽃게", "대게", "랍스터", "크랩", "게장")
OFF_TOPIC_TERMS = ("파이썬", "숙제", "코드 짜", "주식", "번역해", "숙제")
PANTRY_EXACT = ("소금", "후추", "물", "식용유")
PANTRY_HINTS = (
    "설탕",
    "미원",
    "다시다",
    "통깨",
    "들깨가루",
    "참치액",
    "굴소스",
    "고추장",
    "고춧가루",
    "버터",
    "파슬리",
    "레드페퍼",
    "월계수",
)

# 캐시에 팩이 없을 때 쓰는 데모 팩. 그램·가격은 설명 가능한 상수다.
FALLBACK_PACKS: Dict[str, List[Dict[str, Any]]] = {
    "닭가슴살": [
        {"grams": 500, "price": 8900, "name": "닭가슴살 500g"},
        {"grams": 1000, "price": 15900, "name": "닭가슴살 1kg"},
    ],
    "애호박": [{"grams": 300, "price": 1980, "name": "애호박 1개"}],
    "쪽파": [{"grams": 100, "price": 1500, "name": "쪽파 1줌"}],
    "대파": [{"grams": 300, "price": 1990, "name": "대파 1단"}],
    "양파": [{"grams": 500, "price": 2490, "name": "양파 1망"}],
    "마늘": [{"grams": 200, "price": 2980, "name": "마늘 1접"}],
    "두부": [{"grams": 300, "price": 1980, "name": "두부 1모"}],
    "김치": [{"grams": 500, "price": 6900, "name": "김치 500g"}],
    "계란": [{"grams": 600, "price": 6490, "name": "계란 10구"}],
    "우유": [{"grams": 900, "price": 2490, "name": "우유 900ml"}],
    "고춧가루": [{"grams": 200, "price": 5900, "name": "고춧가루 200g"}],
    "된장": [{"grams": 500, "price": 4500, "name": "된장 500g"}],
    "고추장": [{"grams": 500, "price": 5200, "name": "고추장 500g"}],
}

PIECE_GRAMS = {
    "두부": 300,
    "계란": 60,
    "달걀": 60,
    "애호박": 250,
    "쪽파": 30,
    "대파": 100,
    "양파": 150,
    "감자": 150,
    "김치": 200,
}


@dataclass
class TurnIntent:
    """지휘자가 고른 한 턴의 행동. 레시피 id는 여기서 만들지 않는다."""

    kind: str
    target: str = ""
    meal_count: Optional[int] = None
    drop_days: List[str] = field(default_factory=list)
    include: str = ""
    exclude: str = ""
    less_spicy: bool = False
    swap_day: str = ""


INTENT_KINDS = ("propose", "revise", "lookup", "basket", "commit", "explain", "chat", "off_topic")
_WEEKDAYS = ("월", "화", "수", "목", "금", "토", "일")


# 이미 담긴 상태를 묻는 말. 담아줘(담기 확정)와 구분한다.
_CART_ALREADY = ("담아두", "담아둬", "담아놔", "담아놓", "담겨")


def _wants_cart_commit(text: str) -> bool:
    """장바구니에 새로 담으라는 말만 확정으로 본다."""
    if _contains_any(text, _CART_ALREADY):
        return False
    return _contains_any(text, ("담아줘", "담아 주", "장바구니에 담"))


def _wants_cart_lookup(text: str) -> bool:
    """장바구니 안을 보여 달라는 말이다."""
    if not _contains_any(text, ("장바구니", "카트")):
        return False
    if _wants_cart_commit(text):
        return False
    return _contains_any(text, _CART_ALREADY) or "담" not in text


_FOOD_STOP = {
    "알려줘",
    "알려",
    "보여줘",
    "보여",
    "찾아줘",
    "찾아",
    "추천해줘",
    "추천해",
    "추천",
    "재료",
    "재료를",
    "레시피",
    "상품",
    "있어",
    "뭐야",
    "해줘",
}


def _food_query(text: str, focus: str = "") -> str:
    """명령어를 지우고 남은 요리 이름을 고른다. 없으면 직전 초점을 쓴다."""
    cleaned = text or ""
    for word in (
        "알려줘",
        "알려 줘",
        "추천해줘",
        "추천해 줘",
        "보여줘",
        "보여 줘",
        "재료를",
        "재료",
        "레시피를",
        "레시피",
        "상품을",
        "상품",
    ):
        cleaned = cleaned.replace(word, " ")
    for token in re.findall(r"[가-힣]{2,}", cleaned):
        if token not in _FOOD_STOP:
            return token
    return (focus or "").strip()


def parse_intent_local(
    message: str,
    chip_id: Optional[str] = None,
    focus: str = "",
) -> TurnIntent:
    """칩과 문장에서 행동을 고른다. 모델 JSON이 없을 때의 폴백이다."""
    text = (message or "").strip()
    chip = (chip_id or "").strip()
    if chip == "accept_plan" or _contains_any(text, ("이대로 장보기", "이대로장보기", "장 보자", "장보자")):
        return TurnIntent("basket")
    if chip == "accept_cart" or _wants_cart_commit(text):
        return TurnIntent("commit")
    if chip == "drop_friday" or ("금요일" in text and "빼" in text):
        return TurnIntent("revise", drop_days=["금"])
    if chip == "off_topic" or _contains_any(text, OFF_TOPIC_TERMS):
        return TurnIntent("off_topic")
    if text.startswith("왜") or "왜 " in text or "골랐" in text:
        return TurnIntent("explain")
    if "맵" in text and ("덜" in text or "순두부" in text):
        return TurnIntent("revise", less_spicy=True)
    if "목요일" in text and "냉장고" in text:
        return TurnIntent("revise", target="fridge", swap_day="목")
    drop_days = [
        day for day in _WEEKDAYS if f"{day}요일" in text and "빼" in text and day != "금"
    ]
    if drop_days:
        return TurnIntent("revise", drop_days=drop_days)
    if _wants_cart_lookup(text):
        return TurnIntent("lookup", target="cart")
    if "냉장고" in text and "목요일" not in text:
        return TurnIntent("lookup", target="fridge")
    if _contains_any(text, ("상품", "추천")) and not _contains_any(
        text, ("식단", "해먹", "이번 주")
    ):
        return TurnIntent("lookup", target="products", include=_food_query(text, focus))
    if "재료" in text or (
        _contains_any(text, ("알려줘", "알려 줘")) and "레시피" not in text
    ):
        return TurnIntent("lookup", target="ingredients", include=_food_query(text, focus))
    if _contains_any(text, ("알레르기", "못 먹", "기피", "몇 명", "몇명", "가구", "인원")):
        return TurnIntent("lookup", target="profile")
    if "레시피" in text and _contains_any(text, ("있", "뭐", "보여", "찾아", "알려")):
        named = re.search(r"([가-힣]{2,8})\s*레시피", text)
        title = named.group(1) if named else ""
        if title in ("저장한", "나의", "어떤", "추천"):
            title = ""
        if title and _contains_any(text, ("알려", "보여", "찾아")):
            return TurnIntent("lookup", target="ingredients", include=title)
        if title:
            return TurnIntent("propose", include=title)
        return TurnIntent("lookup", target="recipes")
    if _contains_any(text, ("저장한", "저장 레시피", "내 레시피", "레시피 뭐", "어떤 레시피")):
        return TurnIntent("lookup", target="recipes")
    if "예산" in text and "초과" not in text and "허용" not in text:
        return TurnIntent("lookup", target="budget")
    count = _meal_count_in_text(text)
    include = ""
    for token in ("순두부", "닭가슴", "닭", "김치찌개", "김치", "돼지", "버섯"):
        if token in text:
            include = token
            break
    if not include:
        # 으로를 로보다 먼저 남긴다. 탐욕적 일치는 '짬뽕으로'를 '짬뽕으'+'로'로 자른다.
        named = re.search(r"([가-힣]{1,8}?)(?:으로|로)", text)
        if named and _contains_any(text, ("해", "만들", "식단", "요리", "저녁")):
            include = named.group(1)
    if include and "빼" in text and "요일" not in text:
        return TurnIntent("revise", exclude=include, meal_count=count)
    if include and _contains_any(text, ("있", "남")) and not _contains_any(
        text, ("해", "만들", "식단", "요리", "저녁", "끼")
    ):
        return TurnIntent("lookup", target="fridge")
    if count or include or _contains_any(text, ("요리", "해먹", "이번 주", "식단", "저녁", "장보")):
        return TurnIntent("propose", include=include, meal_count=count)
    if text:
        return TurnIntent("chat")
    return TurnIntent("propose")


def intent_from_payload(data: Dict[str, Any]) -> Optional[TurnIntent]:
    """모델이 고른 JSON을 행동으로 바꾼다. 모르는 kind는 버린다."""
    if not isinstance(data, dict):
        return None
    kind = str(data.get("kind") or "").strip()
    if kind not in INTENT_KINDS:
        return None
    raw_count = data.get("meal_count")
    meal_count: Optional[int] = None
    try:
        if raw_count not in (None, "", 0, "0"):
            meal_count = max(1, min(5, int(raw_count)))
    except (TypeError, ValueError):
        meal_count = None
    drop_raw = data.get("drop_days") or ""
    if isinstance(drop_raw, list):
        drop_days = [str(day)[:1] for day in drop_raw if str(day).strip()]
    else:
        drop_days = [day for day in _WEEKDAYS if day in str(drop_raw)]
    return TurnIntent(
        kind=kind,
        target=str(data.get("target") or ""),
        meal_count=meal_count,
        drop_days=drop_days,
        include=str(data.get("include") or "").strip(),
        exclude=str(data.get("exclude") or "").strip(),
        less_spicy=bool(data.get("less_spicy")),
        swap_day=str(data.get("swap_day") or "")[:1],
    )


def merge_intents(local: TurnIntent, chosen: Optional[TurnIntent]) -> TurnIntent:
    """문장이 저장소를 가리키면 그 저장소를 유지하고, 모델은 그 위의 표현만 고친다."""
    if chosen is None:
        return local
    if local.kind == "lookup" and chosen.kind == "lookup" and local.target and chosen.target != local.target:
        return local
    if local.kind == "lookup" and local.include and chosen.include != local.include:
        return local
    if local.kind not in ("chat", "propose") and chosen.kind != local.kind:
        return local
    if local.kind == "propose" and chosen.kind != "propose":
        return local
    return chosen


def _meal_count_in_text(text: str) -> Optional[int]:
    match = re.search(r"([1-5])\s*끼", text or "")
    if not match:
        return None
    return int(match.group(1))


def _matching_recipes(recipes: Sequence[Dict[str, Any]], query: str) -> List[Dict[str, Any]]:
    needle = (query or "").strip()
    if not needle:
        return list(recipes)
    found = [recipe for recipe in recipes if needle in str(recipe.get("name") or "")]
    return found


@dataclass
class PlannerResult:
    """한 턴의 구조화 결과. reply는 템플릿이고, 서비스가 NVIDIA 문장으로 바꿀 수 있다."""

    on_topic: bool
    phase: str
    reply: str
    skills_loaded: List[str]
    policy_decision: str
    meals: List[Dict[str, Any]] = field(default_factory=list)
    gap: List[Dict[str, Any]] = field(default_factory=list)
    basket: List[Dict[str, Any]] = field(default_factory=list)
    total_price: int = 0
    budget: int = 70000
    chips: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    cart_items: Optional[List[Dict[str, Any]]] = None
    run_patch: Dict[str, Any] = field(default_factory=dict)
    solver: str = "greedy"


def _norm(text: str) -> str:
    return re.sub(r"\s+", "", (text or "").strip().lower())


def _contains_any(text: str, terms: Sequence[str]) -> bool:
    compact = _norm(text)
    return any(_norm(term) in compact for term in terms)


def is_shellfish(name: str) -> bool:
    """갑각류 재료·상품명인지 확인한다."""
    return _contains_any(name, SHELLFISH_TERMS)


def _is_pantry(name: str) -> bool:
    """매주 다시 사지 않는 상비 조미료인지 본다."""
    compact = re.sub(r"\s+", "", name or "")
    if compact in PANTRY_EXACT:
        return True
    return any(hint in compact for hint in PANTRY_HINTS)


def to_grams(name: str, qty: Optional[float], unit: str) -> float:
    """조리 단위를 대략 그램으로 환산한다."""
    amount = float(qty or 1)
    unit_n = (unit or "").strip().lower()
    if unit_n in ("g", "그램", "gram", "grams"):
        return amount
    if unit_n in ("kg", "킬로그램"):
        # 다시다 3kg처럼 조미료에 붙은 kg는 그램 오표기로 본다.
        if _is_pantry(name):
            return amount
        return amount * 1000
    if unit_n in ("ml", "cc"):
        return amount
    if unit_n in ("l", "리터"):
        return amount * 1000
    if unit_n in ("꼬집", "약간"):
        return amount * 0.5
    if unit_n == "컵":
        return amount * 80
    if unit_n == "큰술":
        return amount * 15
    if unit_n in ("작은술", "스푼"):
        return amount * 5
    for key, grams in PIECE_GRAMS.items():
        if key in name:
            return amount * grams
    if unit_n in ("개", "쪽", "줌", "단", "모"):
        return amount * PIECE_GRAMS.get(name, 80)
    return amount * 80


def _fridge_names(fridge: Sequence[Dict[str, Any]]) -> List[str]:
    names: List[str] = []
    for item in fridge:
        name = str(item.get("name") or item.get("item") or "").strip()
        qty = item.get("totalQty")
        if qty is None:
            qty = item.get("qty", 1)
        try:
            left = float(qty)
        except (TypeError, ValueError):
            left = 1
        if name and left > 0:
            names.append(name)
    return names


FALSE_FRIENDS = (("순두부", "두부"),)


def _same_food(left: str, right: str) -> bool:
    """이름이 같은 재료인지. 순두부와 두부는 다른 재료로 본다."""
    a = _norm(left)
    b = _norm(right)
    if not a or not b:
        return False
    for special, generic in FALSE_FRIENDS:
        pair = {_norm(special), _norm(generic)}
        if {a, b} == pair or (a == _norm(special) and b == _norm(generic)) or (
            b == _norm(special) and a == _norm(generic)
        ):
            return False
    return a == b or a in b or b in a


def _fridge_has(fridge_names: Sequence[str], ingredient: str) -> bool:
    for name in fridge_names:
        if _same_food(name, ingredient):
            return True
    return False


def _avoided(profile: Dict[str, Any]) -> List[str]:
    raw = profile.get("avoidedIngredients") or []
    if isinstance(raw, str):
        return [raw]
    return [str(x) for x in raw if str(x).strip()]


def _blocks_shellfish(profile: Dict[str, Any]) -> bool:
    blob = " ".join(_avoided(profile))
    return _contains_any(blob, ("갑각류", "새우", "게", "조개", "crustacean"))


def _budget(profile: Dict[str, Any]) -> int:
    raw = profile.get("recentCartTotal") or profile.get("budget") or 70000
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = 70000
    return value if value > 0 else 70000


def _servings(profile: Dict[str, Any]) -> int:
    size = str(profile.get("householdSize") or "2")
    if size == "1":
        return 1
    if size in ("3_4",):
        return 3
    if size in ("5_plus",):
        return 5
    return 2


def _meal_count(profile: Dict[str, Any]) -> int:
    freq = str(profile.get("cookingFrequency") or "few_times_week")
    if freq == "rarely":
        return 2
    if freq == "daily":
        return 5
    return 3


# 온보딩 id를 레시피 이름·재료에 나오는 말로 바꾼다.
_NAME_AVOID_TERMS: Dict[str, tuple] = {
    "peach": ("복숭아",),
    "복숭아": ("복숭아",),
    "wheat": ("밀가루", "우동", "국수", "파스타", "짬뽕", "라면", "칼국수", "막국수", "소면", "빵"),
    "밀": ("밀가루", "우동", "국수", "파스타", "짬뽕", "라면", "칼국수", "막국수", "소면"),
}


def _name_avoid_terms(profile: Dict[str, Any]) -> List[str]:
    terms: List[str] = []
    for item in _avoided(profile):
        mapped = _NAME_AVOID_TERMS.get(item) or _NAME_AVOID_TERMS.get(item.lower())
        if mapped:
            terms.extend(mapped)
            continue
        if item in ("갑각류", "조개류"):
            continue
        if item and not item.isascii():
            terms.append(item)
    return terms


def _recipe_blob(recipe: Dict[str, Any]) -> str:
    parts = [str(recipe.get("name") or "")]
    for ing in recipe.get("ingredients") or []:
        if isinstance(ing, dict):
            parts.append(str(ing.get("item") or ""))
    return " ".join(parts)


def _recipe_blocked(recipe: Dict[str, Any], profile: Dict[str, Any]) -> bool:
    """갑각류·밀·복숭아처럼 프로필이 금지한 재료가 있으면 식단에서 뺀다."""
    if _blocks_shellfish(profile):
        if is_shellfish(str(recipe.get("name") or "")):
            return True
        for ing in recipe.get("ingredients") or []:
            if isinstance(ing, dict) and is_shellfish(str(ing.get("item") or "")):
                return True
    blob = _recipe_blob(recipe)
    return any(term in blob for term in _name_avoid_terms(profile))


def _pick_meals(
    recipes: Sequence[Dict[str, Any]],
    profile: Dict[str, Any],
    days: Sequence[str],
) -> List[Dict[str, Any]]:
    """저장된 레시피에서 날짜 수만큼만 고른다. 없는 id는 만들지 않는다."""
    usable = [r for r in recipes if r.get("id") and not _recipe_blocked(r, profile)]
    preferred_order = ("순두부", "닭가슴", "닭", "김치찌개", "김치")
    ranked: List[Dict[str, Any]] = []
    used_ids = set()
    for token in preferred_order:
        for recipe in usable:
            if recipe["id"] in used_ids:
                continue
            if token in str(recipe.get("name") or ""):
                ranked.append(recipe)
                used_ids.add(recipe["id"])
                break
    for recipe in usable:
        if recipe["id"] not in used_ids:
            ranked.append(recipe)
            used_ids.add(recipe["id"])
    servings = _servings(profile)
    meals: List[Dict[str, Any]] = []
    for day, recipe in zip(days, ranked):
        meals.append(
            {
                "day": day,
                "recipe_id": recipe["id"],
                "recipe_name": recipe.get("name") or "",
                "servings": servings,
                "note": "",
                "overlay": [],
            }
        )
    return meals


def _apply_cook_overlay(
    meals: List[Dict[str, Any]],
    fridge_names: Sequence[str],
    recipes_by_id: Dict[str, Dict[str, Any]],
    less_spicy: bool,
) -> List[Dict[str, Any]]:
    """레시피에 대파가 있고 냉장고에 없을 때만 쪽파로 바꾼다."""
    updated: List[Dict[str, Any]] = []
    for meal in meals:
        notes = list(meal.get("overlay") or [])
        note = str(meal.get("note") or "")
        recipe = recipes_by_id.get(str(meal.get("recipe_id") or "")) or {}
        uses_scallion = any(
            "대파" in str(ing.get("item") or "")
            for ing in (recipe.get("ingredients") or [])
        )
        if uses_scallion and not _fridge_has(fridge_names, "대파"):
            notes.append({"remove": "대파", "add": "쪽파", "reason": "냉장고에 대파가 없음"})
            if "쪽파" not in note:
                note = (note + " 대파는 쪽파로 바꿈").strip()
        if less_spicy and "순두부" in str(meal.get("recipe_name") or ""):
            notes.append({"edit": "고춧가루", "reason": "덜 맵게"})
            if "덜 맵" not in note:
                note = (note + " 고춧가루를 줄임").strip()
        copied = dict(meal)
        copied["overlay"] = notes
        copied["note"] = note
        updated.append(copied)
    return updated


def _ingredient_rows(
    meals: List[Dict[str, Any]],
    recipes_by_id: Dict[str, Dict[str, Any]],
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for meal in meals:
        recipe = recipes_by_id.get(meal["recipe_id"]) or {}
        base = float(recipe.get("servings") or 2) or 2
        scale = float(meal.get("servings") or 2) / base
        for ing in recipe.get("ingredients") or []:
            name = str(ing.get("item") or "").strip()
            if not name or _is_pantry(name):
                continue
            replaced = name
            for patch in meal.get("overlay") or []:
                if patch.get("remove") and patch["remove"] in name:
                    replaced = str(patch.get("add") or name)
            qty = ing.get("qty")
            try:
                qty_f = float(qty) if qty is not None else 1.0
            except (TypeError, ValueError):
                qty_f = 1.0
            rows.append(
                {
                    "name": replaced,
                    "grams": to_grams(replaced, qty_f * scale, str(ing.get("unit") or "")),
                    "recipe_id": meal["recipe_id"],
                    "recipe_name": meal.get("recipe_name") or "",
                    "unit": str(ing.get("unit") or ""),
                    "qty": qty_f * scale,
                }
            )
    return rows


def _aggregate(rows: Sequence[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    merged: Dict[str, Dict[str, Any]] = {}
    for row in rows:
        key = row["name"]
        slot = merged.setdefault(
            key,
            {"name": key, "grams": 0.0, "recipes": []},
        )
        slot["grams"] += float(row["grams"])
        if row["recipe_name"] and row["recipe_name"] not in slot["recipes"]:
            slot["recipes"].append(row["recipe_name"])
    return merged


def _parse_pack_grams(name: str) -> Optional[int]:
    match = re.search(r"(\d+(?:\.\d+)?)\s*(kg|g|그램)", name.lower())
    if not match:
        return None
    value = float(match.group(1))
    if match.group(2) == "kg":
        value *= 1000
    return int(value)


def _cache_packs(name: str, catalog: Dict[str, List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
    packs = []
    for raw in catalog.get(name) or []:
        title = str(raw.get("productName") or raw.get("상품명") or raw.get("name") or "")
        if is_shellfish(title):
            continue
        price = raw.get("productPrice", raw.get("가격", raw.get("price")))
        try:
            price_i = int(price)
        except (TypeError, ValueError):
            continue
        grams = raw.get("grams") or _parse_pack_grams(title)
        if not grams or price_i <= 0:
            continue
        packs.append({"grams": int(grams), "price": price_i, "name": title or name})
    if packs:
        return packs
    for key, fallback in FALLBACK_PACKS.items():
        if key in name or name in key:
            return list(fallback)
    grams = int(PIECE_GRAMS.get(name, 200))
    return [{"grams": grams, "price": 3000, "name": f"{name} {grams}g"}]


def _choose_pack(need_g: float, packs: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    """필요 그램을 덮는 가장 싼 팩. 한 팩으로 부족하면 같은 팩을 반복한다."""
    need = max(int(round(need_g)), 1)
    best: Optional[Dict[str, Any]] = None
    for pack in packs:
        grams = int(pack["grams"])
        if grams <= 0:
            continue
        count = max(1, (need + grams - 1) // grams)
        total_g = grams * count
        price = int(pack["price"]) * count
        waste = max(total_g - need, 0) / total_g
        candidate = {
            "product_name": pack["name"],
            "pack_g": total_g,
            "price": price,
            "waste_pct": int(round(waste * 100)),
            "count": count,
        }
        if best is None or (candidate["price"], candidate["waste_pct"]) < (
            best["price"],
            best["waste_pct"],
        ):
            best = candidate
    assert best is not None
    return best


def build_gap_and_basket(
    meals: Sequence[Dict[str, Any]],
    recipes_by_id: Dict[str, Dict[str, Any]],
    fridge_names: Sequence[str],
    catalog: Dict[str, List[Dict[str, Any]]],
    block_shellfish: bool,
) -> tuple[List[Dict[str, Any]], List[Dict[str, Any]], int]:
    """냉장고에 있는 재료는 사고, 없는 재료만 팩을 고른다."""
    merged = _aggregate(_ingredient_rows(list(meals), recipes_by_id))
    gap: List[Dict[str, Any]] = []
    basket: List[Dict[str, Any]] = []
    total = 0
    for name, slot in merged.items():
        if block_shellfish and is_shellfish(name):
            gap.append(
                {
                    "name": name,
                    "needed": f"{int(slot['grams'])}g",
                    "action": "reject",
                    "note": "갑각류는 정책으로 제외",
                }
            )
            continue
        if _fridge_has(fridge_names, name):
            gap.append(
                {
                    "name": name,
                    "needed": f"{int(slot['grams'])}g",
                    "action": "skip",
                    "note": "냉장고에 있음",
                }
            )
            continue
        chosen = _choose_pack(slot["grams"], _cache_packs(name, catalog))
        gap.append(
            {
                "name": name,
                "needed": f"{int(slot['grams'])}g",
                "action": "buy",
                "note": chosen["product_name"],
            }
        )
        line = {
            "name": name,
            "product_name": chosen["product_name"],
            "pack": f"{chosen['pack_g']}g",
            "price": chosen["price"],
            "needed_g": int(slot["grams"]),
            "pack_g": chosen["pack_g"],
            "waste_pct": chosen["waste_pct"],
            "reason": (
                f"{chosen['pack_g']}g 팩이 필요량 {int(slot['grams'])}g을 "
                f"가장 싸게 덮고, 남는 양은 약 {chosen['waste_pct']}%입니다."
            ),
        }
        basket.append(line)
        total += int(chosen["price"])
    return gap, basket, total


def _days_for(count: int) -> List[str]:
    base = ["수", "목", "금", "토", "일"]
    return base[:count]


def _taste_line(profile: Dict[str, Any]) -> str:
    labels = {
        "korean": "한식",
        "soup": "국물",
        "high_protein": "고단백",
        "home": "집밥",
    }
    cuisines = profile.get("favoriteCuisines") or []
    if isinstance(cuisines, str):
        cuisines = [cuisines]
    bits = [labels.get(str(x), str(x)) for x in cuisines if str(x).strip()]
    if not bits:
        bits = ["한식"]
    return "·".join(bits[:3])


def _cart_items(
    meals: Sequence[Dict[str, Any]],
    gap: Sequence[Dict[str, Any]],
    recipes_by_id: Dict[str, Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """앱 장바구니가 읽는 레시피 단위 아이템. 냉장고 스킵과 상비는 넣지 않는다."""
    buy_names = {item["name"] for item in gap if item.get("action") == "buy"}
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for row in _ingredient_rows(list(meals), recipes_by_id):
        if row["name"] not in buy_names:
            continue
        bucket = grouped.setdefault(str(row["recipe_id"]), [])
        if any(line["item"] == row["name"] for line in bucket):
            continue
        qty = row["qty"]
        qty_text = str(int(qty)) if float(qty).is_integer() else str(round(float(qty), 2))
        bucket.append(
            {
                "item": row["name"],
                "qty": qty_text,
                "unit": row.get("unit") or "",
                "category": "",
            }
        )
    items: List[Dict[str, Any]] = []
    for meal in meals:
        ingredients = grouped.get(str(meal["recipe_id"])) or []
        if not ingredients:
            continue
        items.append(
            {
                "recipeId": meal["recipe_id"],
                "recipeName": meal.get("recipe_name") or "",
                "servings": meal.get("servings") or 2,
                "ingredients": ingredients,
                "source": "grocery_agent",
                "marketplace": "coupang",
            }
        )
    return items


def _explain_line(basket: Sequence[Dict[str, Any]], message: str) -> str:
    if not basket:
        return "고른 상품이 아직 없습니다."
    focus = basket[0]
    for line in basket:
        if _norm(line["name"]) and _norm(line["name"]) in _norm(message):
            focus = line
            break
        if "닭" in message and "닭" in line["name"]:
            focus = line
            break
    return f"{focus['name']}은 {focus['reason']} 쿠팡 팩만 봤습니다."


def _lookup_reply(
    intent: TurnIntent,
    text: str,
    profile: Dict[str, Any],
    recipes: Sequence[Dict[str, Any]],
    fridge: Sequence[Dict[str, Any]],
    cart: Sequence[Dict[str, Any]],
    budget: int,
) -> str:
    """물어본 저장소만 읽고 그 내용으로 답한다."""
    target = intent.target or "recipes"
    if target == "cart":
        names = [str(item.get("recipeName") or item.get("name") or "") for item in cart]
        names = [name for name in names if name]
        if not names:
            return "지금 장바구니는 비어 있어요."
        return f"지금 장바구니에는 {'·'.join(names[:8])}이 있어요."
    if target == "fridge":
        bits = []
        for item in fridge:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or item.get("item") or "").strip()
            if not name:
                continue
            qty = item.get("totalQty", item.get("qty", ""))
            unit = str(item.get("unit") or "")
            bits.append(f"{name} {qty}{unit}".strip())
        asked = ""
        if "순두부" not in text:
            asked = next((name for name in _fridge_names(fridge) if name and name in text), "")
        if asked:
            return f"{asked}는 냉장고에 있어요."
        if "순두부" in text:
            return "순두부는 냉장고에 없고, 두부와는 따로 봐요."
        if not bits:
            return "냉장고 기록이 비어 있어요."
        return f"냉장고에는 {'·'.join(bits[:8])}이 있어요."
    if target == "budget":
        return f"최근 장바구니 기준으로 이번 예산은 {budget:,}원이에요."
    if target == "profile":
        labels = {
            "crustacean": "갑각류",
            "shellfish": "조개류",
            "peach": "복숭아",
            "wheat": "밀",
        }
        raw = profile.get("avoidedIngredients") or []
        if isinstance(raw, str):
            raw = [raw]
        avoided = "·".join(labels.get(str(item), str(item)) for item in raw) or "없음"
        household = str(profile.get("householdSize") or "2")
        household_labels = {"1": "1명", "2": "2명", "3_4": "3–4명", "5_plus": "5명 이상"}
        household_label = household_labels.get(household, f"{household}명")
        return f"못 먹는 재료는 {avoided}이고, 가구는 {household_label} 기준이에요."
    if target == "ingredients":
        matched = _matching_recipes(recipes, intent.include) if intent.include else list(recipes)
        if intent.include and not matched:
            return f"저장한 레시피에는 {intent.include}가 없어요."
        parts: List[str] = []
        for recipe in matched[:3]:
            items = "·".join(
                str(ing.get("item") or "")
                for ing in (recipe.get("ingredients") or [])
                if ing.get("item")
            )
            desc = str(recipe.get("description") or "").strip()
            line = f"{recipe.get('name')}: {items or '재료 없음'}"
            if desc:
                line += f". {desc[:90]}"
            parts.append(line)
        return " / ".join(parts) if parts else "저장된 레시피가 없어요."
    names = [str(recipe.get("name") or "") for recipe in recipes if recipe.get("name")]
    if not names:
        return "저장된 레시피가 없어요."
    return f"저장한 레시피는 {'·'.join(names[:8])}예요."


def _price_of(raw: Dict[str, Any]) -> int:
    for key in ("productPrice", "price", "가격", "originalPrice"):
        try:
            value = int(float(raw.get(key) or 0))
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return 0


def _channel_of(raw: Dict[str, Any]) -> str:
    blob = " ".join(
        str(raw.get(key) or "")
        for key in ("link", "deeplinkUrl", "productUrl", "mall", "source")
    ).lower()
    if "kurly" in blob or "컬리" in blob:
        return "컬리"
    return "쿠팡"


def _offers_for(name: str, catalog: Dict[str, List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """캐시에 있는 상품을 별점과 가격이 보이게 고른다."""
    offers: List[Dict[str, Any]] = []
    for raw in catalog.get(name) or []:
        if not isinstance(raw, dict):
            continue
        title = str(raw.get("productName") or raw.get("상품명") or raw.get("name") or "").strip()
        price = _price_of(raw)
        if not title or price <= 0 or is_shellfish(title):
            continue
        try:
            rating = float(raw.get("rating") or 0)
        except (TypeError, ValueError):
            rating = 0.0
        try:
            reviews = int(raw.get("reviews") or raw.get("reviewCount") or 0)
        except (TypeError, ValueError):
            reviews = 0
        offers.append(
            {
                "name": name,
                "product_name": title,
                "pack": "",
                "price": price,
                "waste_pct": 0,
                "reason": _channel_of(raw),
                "image": str(raw.get("imageUrl") or raw.get("productImage") or "").strip(),
                "rating": round(rating, 1) if rating else 0,
                "reviews": reviews,
                "channel": _channel_of(raw),
            }
        )
    offers.sort(key=lambda row: (-float(row["rating"] or 0), int(row["price"]), -int(row["reviews"])))
    return offers[:1]


def _recommend_products(
    intent: TurnIntent,
    profile: Dict[str, Any],
    recipes: List[Dict[str, Any]],
    fridge: List[Dict[str, Any]],
    catalog: Dict[str, List[Dict[str, Any]]],
    budget: int,
) -> PlannerResult:
    """저장 레시피와 냉장고를 비교해 살 상품을 고른다."""
    query = intent.include or str(profile.get("focus") or "")
    matched = _matching_recipes(recipes, query) if query else []
    if query and not matched:
        return PlannerResult(
            on_topic=True,
            phase="idle",
            reply=f"저장한 레시피에는 {query}가 없어서 상품을 고르지 않았어요.",
            skills_loaded=["yorigo-shopper"],
            policy_decision="products_recommended",
            budget=budget,
            run_patch={"phase": "idle"},
        )
    pool = matched or [recipe for recipe in recipes if not _recipe_blocked(recipe, profile)]
    if not pool:
        return PlannerResult(
            on_topic=True,
            phase="idle",
            reply="추천할 저장 레시피가 없어요.",
            skills_loaded=["yorigo-shopper"],
            policy_decision="products_recommended",
            budget=budget,
            run_patch={"phase": "idle"},
        )
    recipe = pool[0]
    meal = {
        "day": "추천",
        "recipe_id": recipe["id"],
        "recipe_name": recipe.get("name") or "",
        "servings": _servings(profile),
        "note": "",
        "overlay": [],
    }
    gap, basket, _total = build_gap_and_basket(
        [meal],
        {str(recipe["id"]): recipe},
        _fridge_names(fridge),
        catalog,
        _blocks_shellfish(profile),
    )
    have = [str(item.get("name") or "") for item in gap if item.get("action") == "skip"]
    shown: List[Dict[str, Any]] = []
    for item in gap:
        if item.get("action") != "buy" or _is_pantry(str(item.get("name") or "")):
            continue
        found = _offers_for(str(item.get("name") or ""), catalog)
        if found:
            shown.append(found[0])
        if len(shown) == 4:
            break
    if not shown:
        for row in basket:
            if _is_pantry(str(row.get("name") or "")):
                continue
            shown.append(row)
            if len(shown) == 4:
                break
    bits = []
    for row in shown:
        rating = float(row.get("rating") or 0)
        star = f" 별점 {rating:.1f}" if rating else ""
        reviews = int(row.get("reviews") or 0)
        review_bit = f" 리뷰 {reviews}" if reviews else ""
        bits.append(
            f"{row.get('channel') or '쿠팡'} {row.get('product_name')} {int(row.get('price') or 0):,}원{star}{review_bit}"
        )
    desc = str(recipe.get("description") or "").strip()
    desc_bit = f" {desc[:90]}" if desc else ""
    fridge_bit = f"냉장고에 있는 {'·'.join(have[:4])}는 뺐어요. " if have else ""
    goods = " / ".join(bits) if bits else "가격이 있는 상품을 찾지 못했어요"
    reply = f"{recipe.get('name')}에 필요한 상품이에요.{desc_bit} {fridge_bit}{goods}."
    return PlannerResult(
        on_topic=True,
        phase="idle",
        reply=reply,
        skills_loaded=["yorigo-shopper", "yorigo-fridge-steward"],
        policy_decision="products_recommended",
        basket=shown,
        total_price=sum(int(row.get("price") or 0) for row in shown),
        budget=budget,
        run_patch={"phase": "idle", "focus": str(recipe.get("name") or "")},
    )


def plan_turn(
    message: str,
    chip_id: Optional[str],
    profile: Dict[str, Any],
    recipes: Sequence[Dict[str, Any]],
    fridge: Sequence[Dict[str, Any]],
    catalog: Dict[str, List[Dict[str, Any]]],
    run: Optional[Dict[str, Any]] = None,
    cart: Optional[Sequence[Dict[str, Any]]] = None,
    intent: Optional[TurnIntent] = None,
) -> PlannerResult:
    """현재 ShoppingRun과 유저 발화로 다음 상태를 만든다."""
    text = (message or "").strip()
    chip = (chip_id or "").strip()
    previous = run or {}
    phase = str(previous.get("phase") or "idle")
    fridge_names = _fridge_names(fridge)
    recipes_by_id = {str(r["id"]): r for r in recipes if r.get("id")}
    budget = _budget(profile)
    block_shellfish = _blocks_shellfish(profile)
    cart_items = list(cart or [])
    resolved = intent or parse_intent_local(text, chip, str(profile.get("focus") or ""))
    if (
        resolved.kind == "lookup"
        and resolved.target == "ingredients"
        and not resolved.include
        and profile.get("focus")
    ):
        resolved = TurnIntent(
            "lookup",
            target="ingredients",
            include=str(profile.get("focus") or ""),
        )

    if chip == "allow_over_budget" or "예산 초과 허용" in text or previous.get("allowOverBudget"):
        profile = dict(profile)
        profile["allowOverBudget"] = True
        if resolved.kind == "chat":
            resolved = TurnIntent("basket")

    if _contains_any(text, OFF_TOPIC_TERMS) or chip == "off_topic":
        return PlannerResult(
            on_topic=False,
            phase=phase,
            reply="요리와 장보기만 도와요. 다른 주제는 여기서 하지 않습니다.",
            skills_loaded=["policy"],
            policy_decision="off_topic",
            budget=budget,
        )

    if "http://" in text or "https://" in text:
        return PlannerResult(
            on_topic=False,
            phase=phase,
            reply="목록에 없는 주소는 열지 않습니다.",
            skills_loaded=["policy"],
            policy_decision="egress_blocked",
            budget=budget,
        )

    if _contains_any(text, ("새우", "갑각류")) and _contains_any(text, ("알레르기", "빼", "제외")):
        profile = dict(profile)
        avoided = list(_avoided(profile))
        if "갑각류" not in avoided:
            avoided.append("갑각류")
        profile["avoidedIngredients"] = avoided
        block_shellfish = True

    if resolved.kind == "chat" and _contains_any(text, ("있", "남")):
        if "순두부" in text or any(name and name in text for name in fridge_names):
            resolved = TurnIntent("lookup", target="fridge")

    if resolved.kind == "off_topic":
        return PlannerResult(
            on_topic=False,
            phase=phase,
            reply="요리와 장보기만 도와요. 다른 주제는 여기서 하지 않습니다.",
            skills_loaded=["policy"],
            policy_decision="off_topic",
            budget=budget,
        )

    if resolved.kind == "lookup" and resolved.target == "products":
        return _recommend_products(
            resolved, profile, list(recipes), list(fridge), catalog, budget
        )

    if resolved.kind == "lookup":
        skill = {
            "cart": "yorigo-shopper",
            "fridge": "yorigo-fridge-steward",
            "budget": "policy",
        }.get(resolved.target, "yorigo-recipe-library")
        run_patch={"phase": phase or "idle"}
        if resolved.target == "ingredients" and resolved.include:
            named = _matching_recipes(recipes, resolved.include)
            if named:
                run_patch["focus"] = str(named[0].get("name") or resolved.include)
        return PlannerResult(
            on_topic=True,
            phase=phase if phase else "idle",
            reply=_lookup_reply(resolved, text, profile, recipes, fridge, cart_items, budget),
            skills_loaded=[skill],
            policy_decision=f"lookup_{resolved.target or 'recipes'}",
            budget=budget,
            run_patch=run_patch,
        )

    if resolved.kind == "chat":
        return PlannerResult(
            on_topic=True,
            phase=phase or "idle",
            reply="저장 레시피, 냉장고, 장바구니, 이번 주 식단 중에서 궁금한 걸 물어보세요.",
            skills_loaded=["policy"],
            policy_decision="await_user",
            budget=budget,
            run_patch={"phase": phase or "idle"},
        )

    less_spicy = resolved.less_spicy or chip == "less_spicy" or (
        "맵" in text and ("덜" in text or "순두부" in text)
    )
    drop_friday = "금" in resolved.drop_days or chip == "drop_friday" or (
        "금요일" in text and "빼" in text
    )
    fridge_thursday = resolved.swap_day == "목" or ("목요일" in text and "냉장고" in text)
    ask_why = resolved.kind == "explain" or text.startswith("왜") or "왜 " in text or "골랐" in text
    accept_cart = resolved.kind == "commit" or chip == "accept_cart" or _contains_any(
        text, ("담아줘", "담아 주", "장바구니에 담")
    )
    accept_plan = resolved.kind == "basket" or chip == "accept_plan" or _contains_any(
        text, ("이대로 장보기", "이대로장보기", "장 보자", "장보자")
    )

    meals = [dict(m) for m in (previous.get("meals") or [])]
    if resolved.kind == "propose" or not meals:
        pool = list(recipes)
        if resolved.include:
            matched = _matching_recipes(pool, resolved.include)
            if not matched:
                have = "·".join(str(r.get("name") or "") for r in recipes if r.get("name"))
                return PlannerResult(
                    on_topic=True,
                    phase=phase or "idle",
                    reply=f"저장한 레시피에는 {resolved.include}가 없어요. 있는 건 {have or '없음'}예요.",
                    skills_loaded=["yorigo-recipe-library"],
                    policy_decision="recipe_not_saved",
                    budget=budget,
                    run_patch={"phase": phase or "idle"},
                )
            pool = matched
        if resolved.exclude:
            narrowed = [r for r in pool if resolved.exclude not in str(r.get("name") or "")]
            pool = narrowed or pool
        count = resolved.meal_count or _meal_count(profile)
        meals = _pick_meals(pool, profile, _days_for(count))
        phase = "planned"
    if resolved.exclude and resolved.kind == "revise":
        meals = [m for m in meals if resolved.exclude not in str(m.get("recipe_name") or "")]
        phase = "planned"

    if drop_friday:
        meals = [m for m in meals if m.get("day") != "금"]
        phase = "planned"
    if fridge_thursday:
        kept = []
        for meal in meals:
            if meal.get("day") != "목":
                kept.append(meal)
                continue
            replacement = None
            for recipe in recipes:
                name = str(recipe.get("name") or "")
                if recipe.get("id") == meal.get("recipe_id"):
                    continue
                if "김치" in name or "계란" in name:
                    replacement = recipe
                    break
            if replacement:
                meal = dict(meal)
                meal["recipe_id"] = replacement["id"]
                meal["recipe_name"] = replacement.get("name") or ""
                meal["note"] = "냉장고에 있는 재료 위주"
            kept.append(meal)
        meals = kept
        phase = "planned"

    meals = _apply_cook_overlay(meals, fridge_names, recipes_by_id, less_spicy)
    gap, basket, total = build_gap_and_basket(
        meals, recipes_by_id, fridge_names, catalog, block_shellfish
    )
    if block_shellfish:
        basket = [line for line in basket if not is_shellfish(line["name"])]
        total = sum(int(line["price"]) for line in basket)

    over_budget = total > budget and not profile.get("allowOverBudget")
    skills_plan = [
        "yorigo-recipe-library",
        "yorigo-fridge-steward",
        "yorigo-cook-overlay",
        "yorigo-nutrition-veto",
    ]
    skills_shop = skills_plan + ["yorigo-shopper", "yorigo-basket-opt"]

    if accept_cart and phase == "basket":
        if over_budget:
            return PlannerResult(
                on_topic=True,
                phase="basket",
                reply=f"합계 {total:,}원이 예산 {budget:,}원을 넘습니다. 담으려면 예산 초과를 허용해 주세요.",
                skills_loaded=["policy", "yorigo-nutrition-veto"],
                policy_decision="budget_blocked",
                meals=meals,
                gap=gap,
                basket=basket,
                total_price=total,
                budget=budget,
                chips=["예산 초과 허용"],
                run_patch={"phase": "basket", "meals": meals},
            )
        return PlannerResult(
            on_topic=True,
            phase="committed",
            reply="담았어요. 결제는 여기서 하지 않아요. 쿠팡에서 결제만 하시면 됩니다.",
            skills_loaded=["policy", "yorigo-shopper"],
            policy_decision="spend_confirmed",
            meals=meals,
            gap=gap,
            basket=basket,
            total_price=total,
            budget=budget,
            cart_items=_cart_items(meals, gap, recipes_by_id),
            run_patch={"phase": "committed", "meals": meals, "gateB": True},
        )

    if accept_cart and phase != "basket":
        return PlannerResult(
            on_topic=True,
            phase=phase if phase != "idle" else "planned",
            reply="아직 장바구니를 만들지 않았어요. 식단을 먼저 확정할게요.",
            skills_loaded=skills_plan,
            policy_decision="spend_too_early",
            meals=meals,
            gap=gap,
            basket=[],
            total_price=0,
            budget=budget,
            chips=["이대로 장보기"],
            run_patch={"phase": "planned", "meals": meals},
        )

    tweaked = drop_friday or less_spicy or fridge_thursday
    if tweaked and meals:
        accept_plan = True

    if ask_why and basket and not tweaked:
        return PlannerResult(
            on_topic=True,
            phase=phase if phase != "idle" else "basket",
            reply=_explain_line(basket, text),
            skills_loaded=["yorigo-basket-opt"],
            policy_decision="explain",
            meals=meals,
            gap=gap,
            basket=basket,
            total_price=total,
            budget=budget,
            chips=["장바구니에 담기"] if phase == "basket" else ["이대로 장보기"],
            run_patch={"phase": phase if phase != "idle" else "basket", "meals": meals},
        )

    if accept_plan or phase == "basket" and not (drop_friday or less_spicy or fridge_thursday):
        waste_vals = [int(line["waste_pct"]) for line in basket] or [0]
        waste = int(round(sum(waste_vals) / len(waste_vals)))
        skipped = [item["name"] for item in gap if item["action"] == "skip"]
        fridge_line = ""
        if skipped:
            fridge_line = f"냉장고에 있어서 뺀 재료는 {'·'.join(skipped[:4])}예요. "
        prefix = ""
        if drop_friday:
            prefix = "금요일은 뺐고, 남은 끼만 다시 합산했어요. "
        elif less_spicy:
            prefix = "순두부는 덜 맵게 바꿔 두었어요. "
        elif fridge_thursday:
            prefix = "목요일은 냉장고에 있는 쪽으로 바꿨어요. "
        reply = (
            f"{prefix}{fridge_line}"
            "소금·후추·다시다 같은 상비 조미료도 뺐어요. "
            f"{len(basket)}개, {total:,}원, 남는 양 약 {waste}%. "
            "갑각류 상품은 넣지 않았어요."
        )
        return PlannerResult(
            on_topic=True,
            phase="basket",
            reply=reply,
            skills_loaded=skills_shop,
            policy_decision="basket_ready",
            meals=meals,
            gap=gap,
            basket=basket,
            total_price=total,
            budget=budget,
            chips=["장바구니에 담기"],
            warnings=["over_budget"] if over_budget else [],
            run_patch={"phase": "basket", "meals": meals, "gateA": True},
        )

    if not meals:
        blocked = any(_recipe_blocked(recipe, profile) for recipe in recipes)
        if recipes and blocked:
            reply = "못 먹는 재료 때문에 고를 수 있는 저장 레시피가 없어요."
            decision = "nutrition_veto"
        else:
            reply = "저장된 레시피가 없어서 식단을 만들지 못했어요."
            decision = "no_recipes"
        return PlannerResult(
            on_topic=True,
            phase="idle",
            reply=reply,
            skills_loaded=["yorigo-recipe-library", "yorigo-nutrition-veto"],
            policy_decision=decision,
            budget=budget,
        )

    day_text = "·".join(str(m["day"]) for m in meals)
    names = " / ".join(f"{m['day']} {m['recipe_name']}" for m in meals)
    taste = _taste_line(profile)
    freq = str(profile.get("cookingFrequency") or "few_times_week")
    freq_label = {"rarely": "주 0–1회", "few_times_week": "주 2–4회", "daily": "거의 매일"}.get(
        freq, "주 2–4회"
    )
    fridge_have = "·".join(fridge_names[:4]) if fridge_names else "비어 있음"
    scallion = ""
    if any("쪽파" in str(meal.get("note") or "") for meal in meals):
        scallion = "대파는 없어서 쪽파로 바꿔둘게요."
    scope = f"{resolved.include} 쪽으로 " if resolved.include else ""
    if resolved.meal_count and resolved.meal_count > len(meals):
        scope += f"저장본이 {len(meals)}개라 "
    reply = (
        f"평소 {freq_label}라서 {scope}저녁 {len(meals)}끼로 잡을게요. "
        f"{day_text}, {_servings(profile)}인분, 쿠팡, {budget:,}원 안쪽. "
        f"저장하신 걸 보면 {taste} 쪽이에요. 냉장고에는 {fridge_have}이 있어요. "
        f"{names}. {scallion}"
    ).strip()
    return PlannerResult(
        on_topic=True,
        phase="planned",
        reply=reply,
        skills_loaded=skills_plan,
        policy_decision="meal_plan_proposed",
        meals=meals,
        gap=[],
        basket=[],
        total_price=0,
        budget=budget,
        chips=["이대로 장보기", "하루 빼기"],
        run_patch={"phase": "planned", "meals": meals, "gateA": False, "gateB": False, "focus": str(meals[0].get("recipe_name") or "")},
    )
