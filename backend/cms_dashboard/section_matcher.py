"""home_section_rules 매칭 (CF homeSectionRules.js 와 동일한 판정 범위)."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any


def _text(v: Any) -> str:
    return str(v or "").strip()


def _as_dict(v: Any) -> dict[str, Any]:
    return v if isinstance(v, dict) else {}


def recipe_title(data: dict[str, Any]) -> str:
    nested = _as_dict(data.get("recipe"))
    return _text(nested.get("title") or data.get("title") or nested.get("name") or data.get("name"))


def _platform(data: dict[str, Any]) -> str:
    src = _as_dict(data.get("source"))
    return _text(src.get("platform")).lower()


def _source_text(data: dict[str, Any]) -> str:
    source = _as_dict(data.get("source"))
    nested = _as_dict(data.get("recipe"))
    parts = [
        source.get("title"),
        source.get("uploader"),
        source.get("channel"),
        data.get("uploader"),
        data.get("channel"),
        nested.get("title") or data.get("title") or nested.get("name"),
        data.get("sourceUrl") or source.get("url") or source.get("sourceUrl"),
    ]
    return " ".join(_text(p) for p in parts if _text(p))


def _num(v: Any) -> float | None:
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _total_minutes(data: dict[str, Any]) -> float:
    nested = _as_dict(data.get("recipe"))
    steps = nested.get("steps")
    if not isinstance(steps, list):
        return 0.0
    total = 0.0
    for step in steps:
        if not isinstance(step, dict):
            continue
        m = _num(step.get("est_minutes"))
        if m is not None and m > 0:
            total += m
    return total


def _ingredient_count(data: dict[str, Any]) -> int:
    nested = _as_dict(data.get("recipe"))
    ingredients = nested.get("ingredients")
    return len(ingredients) if isinstance(ingredients, list) else 0


def _tags(data: dict[str, Any]) -> list[str]:
    nested = _as_dict(data.get("recipe"))
    source = _as_dict(data.get("source"))
    chunks = [
        data.get("tags"),
        data.get("occasionTags"),
        nested.get("tags"),
        nested.get("occasionTags"),
        source.get("tags"),
        source.get("occasionTags"),
    ]
    out: list[str] = []
    seen: set[str] = set()
    for raw in chunks:
        if not isinstance(raw, list):
            continue
        for t in raw:
            s = _text(t)
            key = s.lower()
            if not s or key in seen:
                continue
            seen.add(key)
            out.append(s)
    return out


def _menu_types(data: dict[str, Any]) -> list[str]:
    cats = _as_dict(data.get("categories"))
    nested = _as_dict(data.get("recipe"))
    nested_cats = _as_dict(nested.get("categories"))
    raw = cats.get("menu_type") or nested_cats.get("menu_type") or []
    if isinstance(raw, str):
        return [raw] if raw.strip() else []
    if isinstance(raw, list):
        return [_text(x) for x in raw if _text(x)]
    return []


def _protein_g(data: dict[str, Any]) -> float | None:
    nutrition = _as_dict(data.get("nutrition"))
    est = _as_dict(nutrition.get("llm_estimate"))
    return _num(est.get("protein_g"))


def _fat_g(data: dict[str, Any]) -> float | None:
    nutrition = _as_dict(data.get("nutrition"))
    est = _as_dict(nutrition.get("llm_estimate"))
    return _num(est.get("fat_g"))


def _contains_any(haystack: str, needles: list[str]) -> bool:
    h = haystack.lower()
    return any(n.lower() in h for n in needles if n)


def is_visible_completed(data: dict[str, Any]) -> bool:
    if data.get("isHidden") is True:
        return False
    return _text(data.get("status")).lower() == "completed"


def matches_rule(data: dict[str, Any], rule: dict[str, Any]) -> bool:
    if not rule:
        return False
    active_until = _text(rule.get("activeUntil"))
    if active_until:
        try:
            until = date.fromisoformat(active_until[:10])
            if date.today() > until:
                return False
        except ValueError:
            pass

    excluded_platforms = rule.get("excludePlatforms") or []
    if isinstance(excluded_platforms, list) and _platform(data) in [
        _text(p).lower() for p in excluded_platforms
    ]:
        return False

    title = recipe_title(data)
    exclude_title = rule.get("excludeTitleKeywords") or []
    if isinstance(exclude_title, list) and exclude_title and _contains_any(title, [str(x) for x in exclude_title]):
        return False

    any_tags = rule.get("anyTags") or []
    title_kw = rule.get("titleKeywords") or []
    source_kw = rule.get("sourceKeywords") or []
    menu_types = rule.get("menuTypes") or []

    tag_hit = False
    if isinstance(any_tags, list) and any_tags:
        tags = {t.lower() for t in _tags(data)}
        tag_hit = any(_text(t).lower() in tags for t in any_tags)

    title_hit = False
    if isinstance(title_kw, list) and title_kw:
        title_hit = _contains_any(title, [str(x) for x in title_kw])

    source_hit = False
    if isinstance(source_kw, list) and source_kw:
        source_hit = _contains_any(_source_text(data), [str(x) for x in source_kw])

    menu_hit = False
    if isinstance(menu_types, list) and menu_types:
        have = {m.lower() for m in _menu_types(data)}
        menu_hit = any(_text(m).lower() in have for m in menu_types)

    needs_any = bool(any_tags or title_kw or source_kw or menu_types)
    if needs_any and not (tag_hit or title_hit or source_hit or menu_hit):
        time_max = rule.get("timeMaxMinutes")
        max_ing = rule.get("maxIngredients")
        protein_min = rule.get("proteinMin")
        if time_max is None and max_ing is None and protein_min is None:
            return False

    time_max = rule.get("timeMaxMinutes")
    if time_max is not None:
        minutes = _total_minutes(data)
        if minutes <= 0 or minutes > float(time_max):
            return False

    max_ing = rule.get("maxIngredients")
    if max_ing is not None and _ingredient_count(data) > int(max_ing):
        return False

    protein_min = rule.get("proteinMin")
    if protein_min is not None:
        protein = _protein_g(data)
        if protein is None or protein < float(protein_min):
            return False

    fat_max = rule.get("fatMax")
    if fat_max is not None:
        fat = _fat_g(data)
        if fat is None or fat > float(fat_max):
            return False

    return True
