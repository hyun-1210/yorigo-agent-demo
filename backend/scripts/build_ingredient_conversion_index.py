"""
Build ingredient unit conversion index from Firestore data.

Goal:
- Derive per-ingredient conversion candidates (e.g. 1개 ~= 185g) from real app data.
- Prefer observed ratios from fridge recipe ingredients that contain both cooking and shopping units.
- Fall back to broad defaults only when observations are insufficient.

Output:
- backend/data/ingredient_conversion_index.json
"""

import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

# Path bootstrap
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(CURRENT_DIR)
sys.path.insert(0, BACKEND_DIR)

try:
    from dotenv import load_dotenv

    load_dotenv(os.path.join(BACKEND_DIR, ".env"))
except Exception:
    pass

from services.firebase_service import get_firebase_service  # noqa: E402


COUNT_UNITS = {"개", "구", "알", "송이", "줄기", "토막"}
SHOPPING_BASE_UNITS = {"g", "ml", "개", "구"}


def _to_float(v: Any) -> Optional[float]:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v.strip())
        except Exception:
            return None
    return None


def _normalize_unit(raw: Any) -> str:
    if raw is None:
        return ""
    s = str(raw).strip()
    if not s:
        return ""
    lower = s.lower()
    if lower in {"그램", "gram", "grams", "g"}:
        return "g"
    if lower in {"킬로그램", "kg", "kilogram"}:
        return "kg"
    if lower in {"밀리리터", "ml", "milliliter"}:
        return "ml"
    if lower in {"리터", "l", "liter"}:
        return "l"
    if lower in {"ea"}:
        return "개"
    if lower in {"tbsp", "테이블스푼"}:
        return "큰술"
    if lower in {"tsp", "티스푼"}:
        return "작은술"
    return s


def _to_base_shopping_unit(qty: float, unit: str) -> Tuple[float, str]:
    if unit == "kg":
        return qty * 1000.0, "g"
    if unit == "l":
        return qty * 1000.0, "ml"
    return qty, unit


def _looks_egg(name: str) -> bool:
    n = name.lower()
    return ("계란" in n) or ("달걀" in n) or ("에그" in n)


def _trimmed(values: List[float], trim_ratio: float = 0.1) -> List[float]:
    if len(values) < 5:
        return values
    sorted_vals = sorted(values)
    k = int(len(sorted_vals) * trim_ratio)
    if k == 0:
        return sorted_vals
    return sorted_vals[k:-k] if len(sorted_vals) - 2 * k >= 3 else sorted_vals


def _robust_center(values: List[float]) -> Optional[float]:
    if not values:
        return None
    vals = _trimmed(values)
    return statistics.median(vals)


def build_index() -> Dict[str, Any]:
    firebase = get_firebase_service()
    db = firebase.db
    if db is None:
        raise RuntimeError("Firestore client unavailable. Check credentials/.env setup.")

    # Ingredient observations
    by_name = defaultdict(
        lambda: {
            "cooking_samples": [],  # {qty, unit}
            "shopping_samples": [],  # {qty, unit}
            "paired_count_to_mass": [],  # mass/count ratios (g or ml)
        }
    )

    # 1) Pull recipes for cooking-unit observations.
    recipes_docs = db.collection("recipes").stream()
    recipe_count = 0
    for doc in recipes_docs:
        recipe_count += 1
        data = doc.to_dict() or {}
        recipe = data.get("recipe") or {}
        ingredients = recipe.get("ingredients") or []
        for ing in ingredients:
            if not isinstance(ing, dict):
                continue
            name = str(ing.get("item") or "").strip()
            if not name:
                continue
            qty = _to_float(ing.get("qty"))
            if qty is None or qty <= 0:
                continue
            unit = _normalize_unit(ing.get("unit"))
            if unit:
                by_name[name]["cooking_samples"].append({"qty": qty, "unit": unit})

    # 2) Pull users fridge data for shopping-unit observations and paired signals.
    users_docs = db.collection("users").stream()
    user_count = 0
    for user_doc in users_docs:
        user_count += 1
        data = user_doc.to_dict() or {}
        fridge = data.get("fridgeData") or {}

        # shopping observations
        for ing in (fridge.get("ingredients") or []):
            if not isinstance(ing, dict):
                continue
            name = str(ing.get("name") or "").strip()
            if not name:
                continue
            qty = _to_float(ing.get("totalQty"))
            unit = _normalize_unit(ing.get("unit"))
            if qty is None or qty <= 0 or not unit:
                continue
            qty_base, unit_base = _to_base_shopping_unit(qty, unit)
            if unit_base in SHOPPING_BASE_UNITS:
                by_name[name]["shopping_samples"].append(
                    {"qty": qty_base, "unit": unit_base}
                )

        # paired count -> mass signals from recipe entries where both were stored
        for recipe in (fridge.get("recipes") or []):
            if not isinstance(recipe, dict):
                continue
            for ing in (recipe.get("ingredients") or []):
                if not isinstance(ing, dict):
                    continue
                name = str(ing.get("item") or ing.get("name") or "").strip()
                if not name:
                    continue

                cook_qty = _to_float(ing.get("qty"))
                cook_unit = _normalize_unit(ing.get("unit"))
                shop_qty = _to_float(ing.get("shoppingQty"))
                shop_unit = _normalize_unit(ing.get("shoppingUnit"))
                if (
                    cook_qty is None
                    or cook_qty <= 0
                    or shop_qty is None
                    or shop_qty <= 0
                    or cook_unit not in COUNT_UNITS
                ):
                    continue

                shop_qty_base, shop_unit_base = _to_base_shopping_unit(shop_qty, shop_unit)
                if shop_unit_base not in {"g", "ml"}:
                    continue

                ratio = shop_qty_base / cook_qty
                # Basic outlier guardrails
                if ratio <= 0 or ratio > 5000:
                    continue

                by_name[name]["paired_count_to_mass"].append(
                    {"ratio": ratio, "massUnit": shop_unit_base}
                )

    # Build index
    index = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "stats": {
            "recipeDocsScanned": recipe_count,
            "userDocsScanned": user_count,
            "ingredientCount": 0,
        },
        "ingredients": {},
    }

    for name, payload in by_name.items():
        shopping_units = defaultdict(list)
        for s in payload["shopping_samples"]:
            shopping_units[s["unit"]].append(s["qty"])

        # dominant shopping unit
        dominant_unit = None
        dominant_count = -1
        for unit, values in shopping_units.items():
            if len(values) > dominant_count:
                dominant_unit = unit
                dominant_count = len(values)

        entry: Dict[str, Any] = {
            "dominantShoppingUnit": dominant_unit,
            "shoppingObservationCount": sum(len(v) for v in shopping_units.values()),
            "cookingObservationCount": len(payload["cooking_samples"]),
            "pairedObservationCount": len(payload["paired_count_to_mass"]),
            "countToMass": None,
            "confidence": "low",
        }

        # Derive count->mass from paired observations first
        paired_g = [p["ratio"] for p in payload["paired_count_to_mass"] if p["massUnit"] == "g"]
        paired_ml = [p["ratio"] for p in payload["paired_count_to_mass"] if p["massUnit"] == "ml"]

        if paired_g:
            med = _robust_center(paired_g)
            if med is not None:
                entry["countToMass"] = {"unit": "g", "value": round(med, 2)}
                entry["confidence"] = "high" if len(paired_g) >= 8 else "medium"
        elif paired_ml:
            med = _robust_center(paired_ml)
            if med is not None:
                entry["countToMass"] = {"unit": "ml", "value": round(med, 2)}
                entry["confidence"] = "high" if len(paired_ml) >= 8 else "medium"
        else:
            # Domain fallback for eggs only (keep count unit)
            if _looks_egg(name):
                entry["dominantShoppingUnit"] = "구"
                entry["confidence"] = "high"

        index["ingredients"][name] = entry

    index["stats"]["ingredientCount"] = len(index["ingredients"])
    return index


def main():
    out_dir = os.path.join(BACKEND_DIR, "data")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "ingredient_conversion_index.json")

    index = build_index()
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)

    print(f"[OK] Wrote conversion index: {out_path}")
    print(f"[OK] Ingredients: {index['stats']['ingredientCount']}")
    print(
        "[OK] Scanned recipes/users:",
        index["stats"]["recipeDocsScanned"],
        index["stats"]["userDocsScanned"],
    )


if __name__ == "__main__":
    main()

