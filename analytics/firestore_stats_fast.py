"""Fast Firestore counts using aggregate count() queries (avoids full-collection scans).

Run: python analytics/firestore_stats_fast.py
"""

import json
import os
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)

from firebase_admin import firestore  # noqa: E402
from services.firebase_service import get_firebase_service  # noqa: E402


def count(query) -> int:
    result = query.count().get()
    return int(result[0][0].value)


def main() -> None:
    get_firebase_service()
    db = firestore.client()

    recipes = db.collection("recipes")
    users = db.collection("users")

    stats = {
        "fetched_at": date.today().isoformat(),
        "recipes_total": count(recipes),
        "recipes_completed": count(recipes.where("status", "==", "completed")),
        "recipes_completed_visible": count(
            recipes.where("status", "==", "completed").where("isHidden", "==", False)
        ),
        "recipes_parsing": count(recipes.where("status", "==", "parsing")),
        "recipes_error": count(recipes.where("status", "==", "error")),
        "users_total": count(users),
        "reviews_total": count(db.collection("reviews")),
    }

    out = ROOT / "analytics" / "firestore_stats.json"
    out.write_text(json.dumps(stats, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(stats, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
