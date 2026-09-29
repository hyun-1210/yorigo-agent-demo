#!/usr/bin/env python3
"""기존 savedRecipes 미니에 본체 saveCount / sourceViewCount 를 merge 백필."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import firebase_admin
from firebase_admin import credentials, firestore

SA = Path(__file__).resolve().parents[1] / "backend" / "firebase-service-account.json"
OUT = Path(__file__).with_name("_backfill_mini_social_counts.json")
VIEW_KEYS = (
    "play_count",
    "playCount",
    "view_count",
    "videoViewCount",
    "views",
    "viewCount",
)


def _init() -> firestore.Client:
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(str(SA)))
    return firestore.client()


def _int_from(raw: Any) -> int | None:
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return int(raw)
    if isinstance(raw, str):
        digits = "".join(ch for ch in raw if ch.isdigit())
        if digits:
            return int(digits)
    return None


def _view_from_source(source: dict[str, Any]) -> int | None:
    for key in VIEW_KEYS:
        n = _int_from(source.get(key))
        if n is not None:
            return n
    for nested_key in ("statistics", "stats", "engagement"):
        nested = source.get(nested_key)
        if isinstance(nested, dict):
            found = _view_from_source(nested)
            if found is not None:
                return found
    return None


def _social_fields(data: dict[str, Any]) -> dict[str, Any]:
    save = _int_from(data.get("saveCount")) or 0
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    views = _view_from_source(source) if source else None
    out: dict[str, Any] = {"saveCount": save}
    if views is not None:
        out["sourceViewCount"] = views
    return out


def main() -> None:
    db = _init()
    minis = list(db.collection_group("savedRecipes").stream())
    need: list[Any] = []
    already = 0
    for doc in minis:
        data = doc.to_dict() or {}
        if "saveCount" in data:
            already += 1
            continue
        need.append(doc)

    recipe_ids = sorted({doc.id for doc in need})
    mains: dict[str, dict[str, Any]] = {}
    for i in range(0, len(recipe_ids), 100):
        chunk = recipe_ids[i : i + 100]
        refs = [db.collection("recipes").document(rid) for rid in chunk]
        for snap in db.get_all(refs):
            if snap.exists:
                mains[snap.id] = snap.to_dict() or {}

    updated = 0
    missing_main = 0
    with_view = 0
    batch = db.batch()
    pending = 0
    for doc in need:
        main = mains.get(doc.id)
        if main is None:
            missing_main += 1
            fields = {"saveCount": 0}
        else:
            fields = _social_fields(main)
            if "sourceViewCount" in fields:
                with_view += 1
        batch.set(doc.reference, fields, merge=True)
        pending += 1
        updated += 1
        if pending >= 400:
            batch.commit()
            batch = db.batch()
            pending = 0
    if pending:
        batch.commit()

    out = {
        "mini_total": len(minis),
        "already_had_saveCount": already,
        "patched": updated,
        "patched_with_view": with_view,
        "main_missing": missing_main,
        "unique_recipes": len(recipe_ids),
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
