"""Dart/JSON 홈 설정을 Firestore CMS 로 시드.

사용:
  python migrate_seed.py           # dry-run
  python migrate_seed.py --write   # Firestore 기록
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from firebase_util import get_db  # noqa: E402
from schemas import normalize_poster, normalize_section  # noqa: E402
from seed_data import (  # noqa: E402
    SCHEMA_VERSION,
    SECTION_UI,
    poster_pool_section_keys,
    poster_seeds,
)

RULES_JSON = HERE.parents[1] / "yorigo-frontend" / "functions" / "data" / "home_section_rules.json"


def _load_rules() -> dict[str, Any]:
    return json.loads(RULES_JSON.read_text(encoding="utf-8"))


def build_section_docs() -> list[dict[str, Any]]:
    rules = _load_rules()
    docs: list[dict[str, Any]] = []
    for key, label, kind, order, members_only in SECTION_UI:
        payload = {
            "label": label,
            "kind": kind,
            "order": order,
            "enabled": True,
            "membersOnly": members_only,
            "matchRules": rules.get(key) or {},
            "activeUntil": (rules.get(key) or {}).get("activeUntil"),
        }
        docs.append(normalize_section(payload, key))
    next_order = 80
    for key in poster_pool_section_keys():
        if any(d["sectionKey"] == key for d in docs):
            continue
        docs.append(
            normalize_section(
                {
                    "label": key,
                    "kind": "poster_pool",
                    "order": next_order,
                    "enabled": True,
                    "membersOnly": False,
                    "matchRules": {},
                },
                key,
            )
        )
        next_order += 1
    return docs


def build_poster_docs() -> list[dict[str, Any]]:
    return [normalize_poster(p, p["id"]) for p in poster_seeds()]


def build_bundle(
    posters: list[dict[str, Any]],
    sections: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "updatedBy": "migrate_seed",
        "posters": posters,
        "sections": sections,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    posters = build_poster_docs()
    sections = build_section_docs()
    bundle = build_bundle(posters, sections)
    print(f"posters={len(posters)} sections={len(sections)}")
    if not args.write:
        print("dry-run (pass --write to persist)")
        return

    db = get_db()
    batch = db.batch()
    for poster in posters:
        ref = db.collection("home_cms_posters").document(poster["id"])
        batch.set(ref, poster, merge=True)
    for section in sections:
        ref = db.collection("home_cms_sections").document(section["sectionKey"])
        batch.set(ref, section, merge=True)
    meta_ref = db.collection("home_cms").document("meta")
    bundle_ref = db.collection("home_cms").document("bundle")
    existing = bundle_ref.get()
    if existing.exists:
        db.collection("home_cms").document("rollback").set(existing.to_dict() or {})
    batch.set(
        meta_ref,
        {
            "schemaVersion": SCHEMA_VERSION,
            "updatedAt": datetime.now(timezone.utc),
            "updatedBy": "migrate_seed",
        },
        merge=True,
    )
    batch.set(bundle_ref, bundle, merge=True)
    batch.commit()
    print("wrote home_cms_posters / home_cms_sections / home_cms/bundle")


if __name__ == "__main__":
    main()
