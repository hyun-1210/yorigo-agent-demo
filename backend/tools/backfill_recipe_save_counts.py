"""saveCount 가 0/누락인 레시피에 1 이상 시드를 백필한다.

실제 저장 수(1 이상)는 덮지 않는다. weeklySaves/monthlySaves 는 주간·월간
랭킹 신호라서 건드리지 않는다.

사용:
  python backend/tools/backfill_recipe_save_counts.py --dry-run
  python backend/tools/backfill_recipe_save_counts.py --apply
  python backend/tools/backfill_recipe_save_counts.py --apply --skip-minis
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

import firebase_admin
from firebase_admin import credentials, firestore

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from utils.recipe_social_counts import (  # noqa: E402
    needs_seeded_save_count,
    parse_save_count,
    seed_save_count,
)

BATCH_SIZE = 400
PAGE_SIZE = 150
SKIP_STATUSES = {"parsing", "cancelled", "failed", "error"}


def _fetch_page(query: Any, retries: int = 5) -> list[Any]:
    last_err: Exception | None = None
    delay = 2.0
    for _ in range(retries):
        try:
            return list(query.stream())
        except Exception as exc:
            last_err = exc
            print(f"[Backfill] page fetch retry after {exc!r}, sleep {delay:.0f}s")
            time.sleep(delay)
            delay = min(delay * 2, 30.0)
    if last_err is not None:
        raise last_err
    return []


def _load_env() -> None:
    env_path = BACKEND_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k and k not in os.environ:
            os.environ[k] = v


def _init_firestore_client() -> firestore.Client:
    if firebase_admin._apps:
        return firestore.client()

    _load_env()
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    if service_account_json:
        try:
            path = Path(service_account_json)
            if not path.is_absolute():
                path = BACKEND_DIR / path
            if path.exists():
                cred = credentials.Certificate(str(path))
            else:
                cred = credentials.Certificate(json.loads(service_account_json))
            firebase_admin.initialize_app(cred)
            return firestore.client()
        except Exception:
            pass

    canonical = BACKEND_DIR / "firebase-service-account.json"
    if canonical.exists():
        cred = credentials.Certificate(str(canonical))
        firebase_admin.initialize_app(cred)
        return firestore.client()

    firebase_admin.initialize_app()
    return firestore.client()


def _status_of(data: dict[str, Any]) -> str:
    return str(data.get("status") or "").strip().lower()


def _should_skip_recipe(data: dict[str, Any]) -> bool:
    if data.get("isTemporary") is True:
        return True
    return _status_of(data) in SKIP_STATUSES


def backfill_recipes(
    db: firestore.Client,
    *,
    dry_run: bool,
    limit: int,
) -> dict[str, Any]:
    scanned = 0
    skipped = 0
    already = 0
    patched = 0
    seeded_values: list[int] = []
    existing_nonzero: list[int] = []
    pending = 0
    batch = db.batch()
    last_doc = None
    page_no = 0

    print("[Backfill] Scanning `recipes` for saveCount <= 0 ...")
    while True:
        query = (
            db.collection("recipes")
            .order_by("__name__")
            .select(["saveCount", "status", "isTemporary"])
            .limit(PAGE_SIZE)
        )
        if last_doc is not None:
            query = query.start_after(last_doc)
        docs = _fetch_page(query)
        if not docs:
            break
        page_no += 1
        last_doc = docs[-1]

        for doc in docs:
            scanned += 1
            data = doc.to_dict() or {}
            if _should_skip_recipe(data):
                skipped += 1
                continue

            current = data.get("saveCount")
            if not needs_seeded_save_count(current):
                already += 1
                existing_nonzero.append(parse_save_count(current))
                continue

            seeded = seed_save_count(doc.id)
            seeded_values.append(seeded)
            if not dry_run:
                batch.update(doc.reference, {"saveCount": seeded})
                pending += 1
                if pending >= BATCH_SIZE:
                    batch.commit()
                    batch = db.batch()
                    pending = 0
            patched += 1
            if limit > 0 and patched >= limit:
                docs = []
                break

        print(
            f"[Backfill] recipes page={page_no} scanned={scanned} "
            f"patched={patched} already>0={already} last={last_doc.id}"
        )
        if limit > 0 and patched >= limit:
            break

    if not dry_run and pending > 0:
        batch.commit()

    dist = Counter(seeded_values)
    existing_dist = Counter(existing_nonzero)
    print(
        f"[Backfill] recipes scanned={scanned} skipped={skipped} "
        f"already>0={already} patched={patched}"
    )
    if seeded_values:
        print(
            f"[Backfill] seeded min={min(seeded_values)} max={max(seeded_values)} "
            f"avg={sum(seeded_values) / len(seeded_values):.1f} dist={dict(sorted(dist.items()))}"
        )
    if existing_nonzero:
        print(
            f"[Backfill] kept existing min={min(existing_nonzero)} "
            f"max={max(existing_nonzero)} avg={sum(existing_nonzero) / len(existing_nonzero):.1f} "
            f"top={existing_dist.most_common(8)}"
        )
    return {
        "scanned": scanned,
        "skipped": skipped,
        "already": already,
        "patched": patched,
        "seeded_min": min(seeded_values) if seeded_values else None,
        "seeded_max": max(seeded_values) if seeded_values else None,
    }


def _main_save_counts(db: firestore.Client, recipe_ids: list[str]) -> dict[str, int]:
    mains: dict[str, int] = {}
    unique_ids = sorted(set(recipe_ids))
    for i in range(0, len(unique_ids), 100):
        chunk = unique_ids[i : i + 100]
        refs = [db.collection("recipes").document(rid) for rid in chunk]
        for snap in db.get_all(refs):
            if not snap.exists:
                continue
            main = snap.to_dict() or {}
            current = main.get("saveCount")
            if needs_seeded_save_count(current):
                mains[snap.id] = seed_save_count(snap.id)
            else:
                mains[snap.id] = parse_save_count(current)
    return mains


def backfill_minis(
    db: firestore.Client,
    *,
    dry_run: bool,
    limit: int,
) -> dict[str, Any]:
    scanned = 0
    already = 0
    patched = 0
    missing_main = 0
    pending = 0
    batch = db.batch()
    last_doc = None
    page_no = 0

    print("[Backfill] Scanning collectionGroup `savedRecipes` for saveCount <= 0 ...")
    while True:
        query = (
            db.collection_group("savedRecipes")
            .order_by("__name__")
            .select(["saveCount"])
            .limit(PAGE_SIZE)
        )
        if last_doc is not None:
            query = query.start_after(last_doc)
        docs = _fetch_page(query)
        if not docs:
            break
        page_no += 1
        last_doc = docs[-1]

        need: list[Any] = []
        for doc in docs:
            scanned += 1
            data = doc.to_dict() or {}
            if not needs_seeded_save_count(data.get("saveCount")):
                already += 1
                continue
            need.append(doc)
            if limit > 0 and (patched + len(need)) >= limit:
                break

        mains = _main_save_counts(db, [doc.id for doc in need]) if need else {}
        for doc in need:
            seeded = mains.get(doc.id)
            if seeded is None:
                missing_main += 1
                seeded = seed_save_count(doc.id)
            if not dry_run:
                batch.set(doc.reference, {"saveCount": seeded}, merge=True)
                pending += 1
                if pending >= BATCH_SIZE:
                    batch.commit()
                    batch = db.batch()
                    pending = 0
            patched += 1

        print(
            f"[Backfill] minis page={page_no} scanned={scanned} "
            f"patched={patched} already>0={already} last={last_doc.id}"
        )
        if limit > 0 and patched >= limit:
            break

    if not dry_run and pending > 0:
        batch.commit()

    print(
        f"[Backfill] minis scanned={scanned} already>0={already} "
        f"patched={patched} main_missing={missing_main}"
    )
    return {
        "scanned": scanned,
        "already": already,
        "patched": patched,
        "missing_main": missing_main,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Backfill recipes.saveCount with seeded values >= 1."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Scan and print counts without writing (default if --apply is omitted).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually write seeded saveCount values.",
    )
    parser.add_argument(
        "--skip-minis",
        action="store_true",
        help="Do not patch users/*/savedRecipes mini docs.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Max recipes/minis to patch (0 = no limit).",
    )
    args = parser.parse_args()
    dry_run = not args.apply
    if args.dry_run:
        dry_run = True

    mode = "DRY-RUN" if dry_run else "APPLY"
    print(f"[Backfill] mode={mode} skip_minis={args.skip_minis} limit={args.limit}")
    db = _init_firestore_client()
    recipes = backfill_recipes(db, dry_run=dry_run, limit=args.limit)
    minis: dict[str, Any] = {}
    if not args.skip_minis:
        minis = backfill_minis(db, dry_run=dry_run, limit=args.limit)
    print(json.dumps({"mode": mode, "recipes": recipes, "minis": minis}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
