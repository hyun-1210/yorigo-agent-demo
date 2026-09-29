#!/usr/bin/env python3
"""포스터 정적 인덱스가 Firestore에 있고 클라 칩 매핑과 일치하는지 검증."""

from __future__ import annotations

import json
from pathlib import Path

from google.cloud import firestore
from google.oauth2 import service_account

SA = Path(__file__).resolve().parents[1] / "backend" / "firebase-service-account.json"

EXPECTED = {
    "first_main_for_two": [
        ("전체", "poster_summer_all"),
        ("냉면·밀면", "poster_summer_cold_noodle"),
        ("국수·소바", "poster_summer_guksu"),
        ("냉국·묵", "poster_summer_cold_soup"),
        ("냉채·샐러드", "poster_summer_salad"),
    ],
    "newlywed_kitchen_starter": [
        ("전체", "poster_beginner_10min"),
        ("10분", "poster_beginner_10min"),
        ("한 그릇", "poster_beginner_one_bowl"),
    ],
}

MIN_SHOWN = {
    "poster_summer_all": 40,
    "poster_summer_cold_noodle": 20,
    "poster_summer_guksu": 40,
    "poster_summer_cold_soup": 20,
    "poster_summer_salad": 40,
    "poster_beginner_10min": 40,
    "poster_beginner_one_bowl": 40,
}


def main() -> int:
    info = json.loads(SA.read_text(encoding="utf-8"))
    creds = service_account.Credentials.from_service_account_file(str(SA))
    db = firestore.Client(project=info["project_id"], credentials=creds)

    keys = sorted({sk for chips in EXPECTED.values() for _, sk in chips})
    print("=== Firestore home_section_index ===")
    ok = True
    for key in keys:
        snap = db.collection("home_section_index").document(key).get()
        data = snap.to_dict() or {}
        ids = data.get("recipeIds") or []
        count = int(data.get("count") or len(ids))
        static = bool(data.get("staticPosterIndex"))
        min_need = MIN_SHOWN.get(key, 10)
        status = "OK" if snap.exists and len(ids) >= min_need and static else "FAIL"
        if status == "FAIL":
            ok = False
        print(
            f"[{status}] {key}: exists={snap.exists} static={static} "
            f"count={count} ids={len(ids)} min={min_need} "
            f"sample={ids[:2]}"
        )
        # 샘플 레시피 문서 존재 확인
        if ids:
            doc = db.collection("recipes").document(ids[0]).get()
            title = ""
            if doc.exists:
                d = doc.to_dict() or {}
                r = d.get("recipe") if isinstance(d.get("recipe"), dict) else {}
                title = str(r.get("title") or d.get("title") or "")[:40]
            print(f"         first_recipe_ok={doc.exists} title={title!r}")
            if not doc.exists:
                ok = False

    print("\n=== chip mapping coverage ===")
    for poster, chips in EXPECTED.items():
        for label, key in chips:
            print(f"{poster} / {label} -> {key}")

    print("\nRESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
