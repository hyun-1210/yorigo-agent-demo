"""레시피 로컬 overlay 머지·압축 스냅샷.

Flutter `recipe_overlay.dart` 와 같은 키 구조:
  ingredients.edits / removed / added
  steps.edits / removed / added
원본 recipes 문서는 수정하지 않는다.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any, Dict, List, Optional, Sequence, Tuple

MAX_INGREDIENTS = 40
MAX_STEPS = 30
MAX_INSTRUCTION_CHARS = 200


def _as_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def firestore_doc_to_base(doc: Dict[str, Any]) -> Dict[str, Any]:
    """recipes/{id} 문서에서 에이전트용 원본 레시피를 뽑는다."""
    inner = doc.get("recipe") if isinstance(doc.get("recipe"), dict) else {}
    name = (inner.get("name") or doc.get("title") or "").strip()
    servings = inner.get("servings")
    if not isinstance(servings, (int, float)) or servings <= 0:
        servings = 2
    ingredients: List[Dict[str, Any]] = []
    for raw in inner.get("ingredients") or []:
        if not isinstance(raw, dict):
            continue
        item = str(raw.get("item") or "").strip()
        if not item:
            continue
        ingredients.append(
            {
                "item": item,
                "qty": _as_float(raw.get("qty")),
                "unit": str(raw.get("unit") or "").strip(),
                "category": str(raw.get("category") or "").strip(),
            }
        )
    steps: List[Dict[str, Any]] = []
    for raw in inner.get("steps") or []:
        if not isinstance(raw, dict):
            continue
        order = raw.get("order")
        try:
            order_i = int(order)
        except (TypeError, ValueError):
            order_i = len(steps) + 1
        instruction = str(raw.get("instruction") or "").strip()
        steps.append({"order": order_i, "instruction": instruction})
    return {
        "name": name,
        "servings": int(servings),
        "ingredients": ingredients,
        "steps": steps,
    }


def client_snapshot_to_base(snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """미저장 파싱본 클라 스냅샷을 원본 형태로 정규화."""
    name = str(snapshot.get("name") or snapshot.get("title") or "").strip()
    servings = snapshot.get("servings")
    if not isinstance(servings, (int, float)) or servings <= 0:
        servings = 2
    ingredients: List[Dict[str, Any]] = []
    for raw in snapshot.get("ingredients") or []:
        if not isinstance(raw, dict):
            continue
        item = str(raw.get("item") or "").strip()
        if not item:
            continue
        ingredients.append(
            {
                "item": item,
                "qty": _as_float(raw.get("qty")),
                "unit": str(raw.get("unit") or "").strip(),
                "category": str(raw.get("category") or "").strip(),
            }
        )
    steps: List[Dict[str, Any]] = []
    for raw in snapshot.get("steps") or []:
        if not isinstance(raw, dict):
            continue
        try:
            order_i = int(raw.get("order"))
        except (TypeError, ValueError):
            order_i = len(steps) + 1
        steps.append(
            {
                "order": order_i,
                "instruction": str(raw.get("instruction") or "").strip(),
            }
        )
    return {
        "name": name,
        "servings": int(servings),
        "ingredients": ingredients,
        "steps": steps,
    }


def apply_overlay(base: Dict[str, Any], overlay: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """원본 위에 overlay 를 적용한 머지 레시피 (에이전트 스냅샷용)."""
    ov = overlay if isinstance(overlay, dict) else {}
    ing_ov = ov.get("ingredients") if isinstance(ov.get("ingredients"), dict) else {}
    edits = ing_ov.get("edits") if isinstance(ing_ov.get("edits"), dict) else {}
    removed = {
        str(x).strip()
        for x in (ing_ov.get("removed") or [])
        if str(x).strip()
    }
    added_raw = ing_ov.get("added") if isinstance(ing_ov.get("added"), list) else []

    merged_ings: List[Dict[str, Any]] = []
    for ing in base.get("ingredients") or []:
        item = str(ing.get("item") or "").strip()
        if not item or item in removed:
            continue
        patch = edits.get(item)
        if isinstance(patch, dict):
            qty = _as_float(patch.get("qty"))
            unit = str(patch.get("unit") or "").strip()
            merged_ings.append(
                {
                    "item": item,
                    "qty": qty if qty is not None else ing.get("qty"),
                    "unit": unit or ing.get("unit") or "",
                    "category": ing.get("category") or "",
                }
            )
        else:
            merged_ings.append(dict(ing))

    for raw in added_raw:
        if not isinstance(raw, dict):
            continue
        item = str(raw.get("item") or "").strip()
        if not item or item in removed:
            continue
        patch = edits.get(item)
        qty = _as_float(raw.get("qty"))
        unit = str(raw.get("unit") or "").strip()
        category = str(raw.get("category") or "").strip()
        if isinstance(patch, dict):
            patched_qty = _as_float(patch.get("qty"))
            if patched_qty is not None:
                qty = patched_qty
            patched_unit = str(patch.get("unit") or "").strip()
            if patched_unit:
                unit = patched_unit
        merged_ings.append(
            {
                "item": item,
                "qty": qty,
                "unit": unit,
                "category": category,
            }
        )

    step_ov = ov.get("steps") if isinstance(ov.get("steps"), dict) else {}
    step_edits = step_ov.get("edits") if isinstance(step_ov.get("edits"), dict) else {}
    removed_steps = set()
    for x in step_ov.get("removed") or []:
        try:
            removed_steps.add(int(x))
        except (TypeError, ValueError):
            continue

    merged_steps: List[Dict[str, Any]] = []
    for st in base.get("steps") or []:
        try:
            order = int(st.get("order"))
        except (TypeError, ValueError):
            continue
        if order in removed_steps:
            continue
        patch = step_edits.get(str(order)) or step_edits.get(order)
        instruction = str(st.get("instruction") or "")
        if isinstance(patch, dict):
            instr = str(patch.get("instruction") or "").strip()
            if instr:
                instruction = instr
        merged_steps.append({"order": order, "instruction": instruction})

    return {
        "name": base.get("name") or "",
        "servings": base.get("servings") or 2,
        "ingredients": merged_ings,
        "steps": merged_steps,
    }


def compact_snapshot(recipe: Dict[str, Any]) -> Tuple[Dict[str, Any], bool]:
    """LLM에 넣을 압축 스냅샷. 상한 초과 시 truncated."""
    ingredients = list(recipe.get("ingredients") or [])[:MAX_INGREDIENTS]
    steps = list(recipe.get("steps") or [])[:MAX_STEPS]
    truncated = len(recipe.get("ingredients") or []) > MAX_INGREDIENTS or len(
        recipe.get("steps") or []
    ) > MAX_STEPS
    out_ings = []
    for ing in ingredients:
        item = str(ing.get("item") or "").strip()
        if not item:
            continue
        out_ings.append(
            {
                "item": item,
                "qty": ing.get("qty"),
                "unit": str(ing.get("unit") or "").strip()[:20],
            }
        )
    out_steps = []
    for st in steps:
        try:
            order = int(st.get("order"))
        except (TypeError, ValueError):
            continue
        instr = str(st.get("instruction") or "").strip()
        if len(instr) > MAX_INSTRUCTION_CHARS:
            instr = instr[:MAX_INSTRUCTION_CHARS]
            truncated = True
        out_steps.append({"order": order, "instruction": instr})
    return (
        {
            "name": str(recipe.get("name") or "")[:80],
            "servings": int(recipe.get("servings") or 2),
            "ingredients": out_ings,
            "steps": out_steps,
        },
        truncated,
    )


def slice_for_ingredient(snapshot: Dict[str, Any], item: str) -> Dict[str, Any]:
    """해당 재료와 이름이 등장하는 단계만 남긴다."""
    focus = (item or "").strip()
    ings = [
        ing
        for ing in snapshot.get("ingredients") or []
        if str(ing.get("item") or "").strip() == focus
    ]
    steps = [
        st
        for st in snapshot.get("steps") or []
        if focus and focus in str(st.get("instruction") or "")
    ]
    return {
        "name": snapshot.get("name") or "",
        "servings": snapshot.get("servings") or 2,
        "ingredients": ings,
        "steps": steps,
        "focus_ingredient": focus,
    }


def apply_patches_to_overlay(
    overlay: Optional[Dict[str, Any]],
    patches: Sequence[Dict[str, Any]],
) -> Dict[str, Any]:
    """에이전트 proposed_patches 를 Flutter overlay 키 구조로 적용한다."""
    next_ov: Dict[str, Any] = deepcopy(overlay) if isinstance(overlay, dict) else {}
    ing = next_ov.get("ingredients") if isinstance(next_ov.get("ingredients"), dict) else {}
    edits = dict(ing.get("edits") or {}) if isinstance(ing.get("edits"), dict) else {}
    removed = [str(x).strip() for x in (ing.get("removed") or []) if str(x).strip()]
    added: List[Dict[str, Any]] = [
        dict(x) for x in (ing.get("added") or []) if isinstance(x, dict)
    ]
    steps = next_ov.get("steps") if isinstance(next_ov.get("steps"), dict) else {}
    step_edits = dict(steps.get("edits") or {}) if isinstance(steps.get("edits"), dict) else {}
    add_i = 0
    for raw in patches or []:
        if not isinstance(raw, dict):
            continue
        action = str(raw.get("action") or "").strip()
        if action == "ingredient.edit":
            item = str(raw.get("item") or "").strip()
            if not item:
                continue
            entry: Dict[str, Any] = dict(edits.get(item) or {}) if isinstance(edits.get(item), dict) else {}
            if raw.get("qty") is not None:
                entry["qty"] = raw.get("qty")
            unit = str(raw.get("unit") or "").strip()
            if unit:
                entry["unit"] = unit
            memo = str(raw.get("memo") or "").strip()
            if memo:
                entry["memo"] = memo
            if entry:
                edits[item] = entry
        elif action == "ingredient.remove":
            item = str(raw.get("item") or "").strip()
            if not item:
                continue
            # 추가분에서 빼고, 원본 재료면 removed 로 숨긴다.
            added = [row for row in added if str(row.get("item") or "").strip() != item]
            edits.pop(item, None)
            if item not in removed:
                removed.append(item)
        elif action == "ingredient.restore":
            item = str(raw.get("item") or "").strip()
            removed = [x for x in removed if x != item]
        elif action == "ingredient.add":
            item = str(raw.get("item") or "").strip()
            if not item:
                continue
            row: Dict[str, Any] = {"id": f"ua_{add_i}", "item": item}
            add_i += 1
            if raw.get("qty") is not None:
                row["qty"] = raw.get("qty")
            unit = str(raw.get("unit") or "").strip()
            if unit:
                row["unit"] = unit
            cat = str(raw.get("category") or "").strip()
            if cat:
                row["category"] = cat
            memo = str(raw.get("memo") or "").strip()
            if memo:
                row["memo"] = memo
            added.append(row)
        elif action == "step.edit":
            try:
                order = int(raw.get("order"))
            except (TypeError, ValueError):
                continue
            entry = dict(step_edits.get(str(order)) or {}) if isinstance(step_edits.get(str(order)), dict) else {}
            instr = str(raw.get("instruction") or "").strip()
            if instr:
                entry["instruction"] = instr
            memo = str(raw.get("memo") or "").strip()
            if memo:
                entry["memo"] = memo
            if entry:
                step_edits[str(order)] = entry
    ingredients: Dict[str, Any] = {}
    if edits:
        ingredients["edits"] = edits
    if removed:
        ingredients["removed"] = removed
    if added:
        ingredients["added"] = added
    if ingredients:
        next_ov["ingredients"] = ingredients
    elif "ingredients" in next_ov:
        next_ov.pop("ingredients", None)
    step_out: Dict[str, Any] = dict(steps)
    if step_edits:
        step_out["edits"] = step_edits
    elif "edits" in step_out:
        step_out.pop("edits", None)
    if step_out:
        next_ov["steps"] = step_out
    elif "steps" in next_ov:
        next_ov.pop("steps", None)
    return next_ov
