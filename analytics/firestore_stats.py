"""Count recipes and cart usage from Firestore. Run: python analytics/firestore_stats.py"""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
sys.path.insert(0, str(BACKEND))

os.chdir(BACKEND)

from firebase_admin import firestore  # noqa: E402
from services.firebase_service import get_firebase_service  # noqa: E402


def main() -> None:
    get_firebase_service()
    db = firestore.client()

    recipe_count = 0
    completed_count = 0
    parsing_count = 0
    error_count = 0
    hidden_count = 0

    for doc in db.collection("recipes").stream():
        recipe_count += 1
        data = doc.to_dict() or {}
        status = (data.get("status") or "").lower()
        if status == "completed":
            completed_count += 1
        elif status == "parsing":
            parsing_count += 1
        elif status == "error":
            error_count += 1
        if data.get("isHidden") is True:
            hidden_count += 1

    users_with_cart = 0
    users_with_saved = 0
    total_users = 0
    total_cart_items = 0

    for doc in db.collection("users").stream():
        total_users += 1
        data = doc.to_dict() or {}
        cart = data.get("cartItems")
        if isinstance(cart, list) and len(cart) > 0:
            users_with_cart += 1
            total_cart_items += len(cart)
        saved = data.get("savedRecipes")
        if isinstance(saved, list) and len(saved) > 0:
            users_with_saved += 1

    stats = {
        "recipes_total": recipe_count,
        "recipes_completed": completed_count,
        "recipes_parsing": parsing_count,
        "recipes_error": error_count,
        "recipes_hidden": hidden_count,
        "users_total": total_users,
        "users_with_cart_items": users_with_cart,
        "users_with_saved_recipes": users_with_saved,
        "total_cart_items_across_users": total_cart_items,
        "pct_users_with_cart": (
            round(users_with_cart / total_users * 100, 2) if total_users else 0
        ),
    }

    out = ROOT / "analytics" / "firestore_stats.json"
    out.write_text(json.dumps(stats, indent=2), encoding="utf-8")
    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()
