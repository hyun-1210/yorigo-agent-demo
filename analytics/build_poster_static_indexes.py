#!/usr/bin/env python3
"""홈 포스터용 정적 섹션 인덱스 일회성 빌드.

CF 규칙/자동 갱신에 넣지 않는다. 기존 completed 레시피만 스캔해
`home_section_index/{poster_*}` 에 recipeIds 를 기록한다.

사용:
  python analytics/build_poster_static_indexes.py            # dry-run
  python analytics/build_poster_static_indexes.py --write    # Firestore 기록
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from google.cloud import firestore
from google.oauth2 import service_account

SA = Path(__file__).resolve().parents[1] / "backend" / "firebase-service-account.json"
OUT_JSON = Path(__file__).with_name("poster_static_indexes_snapshot.json")

# 카테고리당 최대 보관 수 (클라 fetch 상한과 맞춤)
MAX_IDS = 200

# ── 여름 칩 (제목 우선, 짧은 토큰/오탐 최소화) ─────────────────────
SUMMER_CHIPS: dict[str, list[str]] = {
    "poster_summer_cold_noodle": [
        "물냉면",
        "비빔냉면",
        "냉면",
        "밀면",
        "막국수",
    ],
    "poster_summer_guksu": [
        "콩국수",
        "냉모밀",
        "메밀소바",
        "열무국수",
        "초계국수",
        "비빔국수",
        "잔치국수",
        "쫄면",
        "소바",
    ],
    "poster_summer_cold_soup": [
        "오이냉국",
        "미역냉국",
        "냉국",
        "묵사발",
        "도토리묵",
        "묵무침",
        "청포묵",
    ],
    "poster_summer_salad": [
        "해파리냉채",
        "냉채",
        "오이무침",
        "샐러드",
    ],
}

# ── 초보 한 그릇 (제목 중심, '볼' 단독 제외) ───────────────────────
ONE_BOWL_TITLE_KEYWORDS = [
    "덮밥",
    "비빔밥",
    "한그릇",
    "한 그릇",
    "돈부리",
    "규동",
    "가츠동",
    "오야코동",
    "회덮밥",
    "볶음밥",
    "리조또",
    "오므라이스",
    "카레라이스",
    "컵밥",
    "마요덮밥",
    "스테이크덮밥",
]

TEN_MIN_COOK_LABELS = ("5분컷", "10분 내", "10분내", "10분 완성", "10분완성")


def _as_dict(v: Any) -> dict[str, Any]:
    return v if isinstance(v, dict) else {}


def _title(data: dict[str, Any]) -> str:
    nested = _as_dict(data.get("recipe"))
    return str(nested.get("title") or data.get("title") or nested.get("name") or "").strip()


def _platform(data: dict[str, Any]) -> str:
    src = _as_dict(data.get("source"))
    return str(src.get("platform") or "").strip().lower()


def _ingredient_text(data: dict[str, Any]) -> str:
    nested = _as_dict(data.get("recipe"))
    ingredients = nested.get("ingredients", data.get("ingredients"))
    if isinstance(ingredients, list):
        return " ".join(str(x) for x in ingredients)
    return str(ingredients or "")


def _haystack(data: dict[str, Any]) -> str:
    nested = _as_dict(data.get("recipe"))
    tags = data.get("tags")
    tag_text = " ".join(str(t) for t in tags) if isinstance(tags, list) else str(tags or "")
    parts = [
        _title(data),
        nested.get("name"),
        _ingredient_text(data),
        nested.get("category"),
        tag_text,
    ]
    return " ".join(str(p or "") for p in parts).lower()


def _contains_any(text: str, keywords: list[str]) -> bool:
    for kw in keywords:
        k = kw.lower().strip()
        if not k:
            continue
        # '메밀면' 이 '밀면' 에 걸리지 않도록
        if k == "밀면":
            if re.search(r"(?<!메)밀면", text):
                return True
            continue
        if k in text:
            return True
    return False


def _parsed_at_ms(data: dict[str, Any]) -> int:
    for key in ("completedAt", "createdAt", "updatedAt"):
        value = data.get(key)
        if value is None:
            continue
        if hasattr(value, "timestamp"):
            try:
                return int(value.timestamp() * 1000)
            except Exception:
                pass
        if isinstance(value, datetime):
            return int(value.timestamp() * 1000)
    return 0


def _step_total_minutes(data: dict[str, Any]) -> float:
    nested = _as_dict(data.get("recipe"))
    steps = nested.get("steps")
    if not isinstance(steps, list):
        return 0.0
    total = 0.0
    for step in steps:
        if not isinstance(step, dict):
            continue
        m = step.get("est_minutes")
        try:
            n = float(m)
        except (TypeError, ValueError):
            continue
        if n > 0:
            total += n
    return total


def _cook_time_labels(data: dict[str, Any]) -> list[str]:
    cats = _as_dict(data.get("categories"))
    out: list[str] = []
    for key in ("cook_time", "time_category"):
        raw = cats.get(key)
        if isinstance(raw, list):
            out.extend(str(x) for x in raw)
        elif raw is not None:
            out.append(str(raw))
    return out


def is_visible_completed(data: dict[str, Any]) -> bool:
    if data.get("isHidden") is True:
        return False
    status = str(data.get("status") or "").strip().lower()
    return status == "completed"


def match_summer_chip(data: dict[str, Any], keywords: list[str]) -> bool:
    """여름: 제목 매칭만 (재료 오탐 방지)."""
    title = _title(data).lower()
    return _contains_any(title, keywords)


def match_one_bowl(data: dict[str, Any]) -> bool:
    title = _title(data).lower()
    if _contains_any(title, ONE_BOWL_TITLE_KEYWORDS):
        return True
    # 재료에만 있는 경우 제외 — 한 그릇은 메뉴 정체성이 제목에 있어야 함
    return False


def match_ten_min(data: dict[str, Any]) -> bool:
    labels = " ".join(_cook_time_labels(data))
    if any(lbl in labels for lbl in TEN_MIN_COOK_LABELS):
        return True
    total = _step_total_minutes(data)
    # 스텝 시간 합이 실제로 1~10분인 경우만 (0분은 미기재로 간주해 제외)
    return 0 < total <= 10


def classify(data: dict[str, Any]) -> set[str]:
    keys: set[str] = set()
    if not is_visible_completed(data):
        return keys
    if _platform(data) == "naver_blog":
        return keys

    summer_hits: list[str] = []
    for section_key, kws in SUMMER_CHIPS.items():
        if match_summer_chip(data, kws):
            summer_hits.append(section_key)
            keys.add(section_key)
    if summer_hits:
        keys.add("poster_summer_all")

    if match_ten_min(data):
        keys.add("poster_beginner_10min")
    if match_one_bowl(data):
        keys.add("poster_beginner_one_bowl")
    return keys


SECTION_META = {
    "poster_summer_all": "여름 시원한 메뉴 · 전체",
    "poster_summer_cold_noodle": "여름 · 냉면·밀면",
    "poster_summer_guksu": "여름 · 국수·소바",
    "poster_summer_cold_soup": "여름 · 냉국·묵",
    "poster_summer_salad": "여름 · 냉채·샐러드",
    "poster_beginner_10min": "초보 · 10분",
    "poster_beginner_one_bowl": "초보 · 한 그릇",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write",
        action="store_true",
        help="Firestore home_section_index 에 기록 (기본은 dry-run)",
    )
    parser.add_argument(
        "--limit-scan",
        type=int,
        default=0,
        help="스캔 상한(테스트용). 0이면 전체",
    )
    args = parser.parse_args()

    info = json.loads(SA.read_text(encoding="utf-8"))
    creds = service_account.Credentials.from_service_account_file(str(SA))
    db = firestore.Client(project=info["project_id"], credentials=creds)

    buckets: dict[str, list[tuple[int, str, str]]] = defaultdict(list)
    scanned = 0
    completed = 0

    print("Scanning recipes (projected fields)...")
    fields = [
        "status",
        "isHidden",
        "title",
        "tags",
        "categories",
        "source",
        "completedAt",
        "createdAt",
        "updatedAt",
        "recipe.title",
        "recipe.name",
        "recipe.ingredients",
        "recipe.category",
        "recipe.steps",
    ]
    page_size = 400
    last_doc = None
    while True:
        query = (
            db.collection("recipes")
            .order_by("__name__")
            .select(fields)
            .limit(page_size)
        )
        if last_doc is not None:
            query = query.start_after(last_doc)
        page = list(query.stream())
        if not page:
            break
        for snap in page:
            scanned += 1
            if args.limit_scan and scanned > args.limit_scan:
                break
            data = snap.to_dict() or {}
            if not is_visible_completed(data):
                continue
            completed += 1
            keys = classify(data)
            if not keys:
                continue
            title = _title(data)
            score = _parsed_at_ms(data)
            for key in keys:
                buckets[key].append((score, snap.id, title))
        last_doc = page[-1]
        print(f"  scanned={scanned} completed_visible={completed}")
        if args.limit_scan and scanned > args.limit_scan:
            break
        if len(page) < page_size:
            break

    result: dict[str, Any] = {
        "builtAt": datetime.now(timezone.utc).isoformat(),
        "scanned": scanned,
        "completedVisible": completed,
        "maxIds": MAX_IDS,
        "write": bool(args.write),
        "sections": {},
    }

    print("\n=== classification counts ===")
    # 여름 전체: 칩별 결과를 라운드로빈으로 합쳐 샐러드 편향을 줄인다.
    summer_chip_keys = [
        "poster_summer_cold_noodle",
        "poster_summer_guksu",
        "poster_summer_cold_soup",
        "poster_summer_salad",
    ]
    summer_all_matched = len({rid for _, rid, _ in buckets.get("poster_summer_all", [])})
    per_chip_sorted: dict[str, list[tuple[int, str, str]]] = {}
    for key in summer_chip_keys:
        rows = sorted(buckets.get(key, []), key=lambda x: x[0], reverse=True)
        deduped: list[tuple[int, str, str]] = []
        seen: set[str] = set()
        for row in rows:
            if row[1] in seen:
                continue
            seen.add(row[1])
            deduped.append(row)
        per_chip_sorted[key] = deduped

    balanced_all: list[tuple[int, str, str]] = []
    seen_all: set[str] = set()
    max_len = max((len(per_chip_sorted[k]) for k in summer_chip_keys), default=0)
    for i in range(max_len):
        for key in summer_chip_keys:
            rows = per_chip_sorted[key]
            if i >= len(rows):
                continue
            row = rows[i]
            if row[1] in seen_all:
                continue
            seen_all.add(row[1])
            balanced_all.append(row)
            if len(balanced_all) >= MAX_IDS:
                break
        if len(balanced_all) >= MAX_IDS:
            break
    buckets["poster_summer_all"] = balanced_all

    for key in SECTION_META:
        rows = buckets.get(key, [])
        if key == "poster_summer_all":
            unique_all = set()  # placeholder; override below
            matched_total = summer_all_matched
        else:
            unique_all = {rid for _, rid, _ in rows}
            matched_total = len(unique_all)
        ids: list[str] = []
        samples: list[str] = []
        seen_ids: set[str] = set()
        for _score, rid, title in sorted(rows, key=lambda x: x[0], reverse=True):
            if rid in seen_ids:
                continue
            seen_ids.add(rid)
            if len(ids) >= MAX_IDS:
                break
            ids.append(rid)
            if len(samples) < 8:
                samples.append(title or rid)

        result["sections"][key] = {
            "label": SECTION_META[key],
            "matchedTotal": matched_total,
            "stored": len(ids),
            "recipeIds": ids,
            "samples": samples,
        }
        safe_samples = [re.sub(r"[^\w\s가-힣·\-]", "", s)[:40] for s in samples[:3]]
        print(
            f"{key}: matched={matched_total} stored={len(ids)} "
            f"samples={safe_samples}"
        )

        if args.write:
            db.collection("home_section_index").document(key).set(
                {
                    "sectionKey": key,
                    "recipeIds": ids,
                    "count": len(ids),
                    "label": SECTION_META[key],
                    "staticPosterIndex": True,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                    "note": "one-shot poster curation; not CF-managed",
                },
                merge=True,
            )

    OUT_JSON.write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\nWrote snapshot {OUT_JSON}")
    if args.write:
        print("Firestore home_section_index updated.")
    else:
        print("Dry-run only. Re-run with --write to persist.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
