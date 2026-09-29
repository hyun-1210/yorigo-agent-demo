"""
Backfill latestThumbnailUrl for recipe_groups docs that are missing one.

For each group without a thumbnail, finds the top recipe (by saveCount)
that has a thumbnailUrl and updates the group doc.

Usage:
  python backend/scripts/backfill_group_thumbnails.py --dry-run
  python backend/scripts/backfill_group_thumbnails.py --commit
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_DIR))

if (BACKEND_DIR / ".env").exists():
    from dotenv import load_dotenv
    load_dotenv(str(BACKEND_DIR / ".env"))

from services.firebase_service import get_firebase_service


def main() -> None:
    parser = argparse.ArgumentParser(description="Backfill recipe_groups thumbnails")
    parser.add_argument("--dry-run", action="store_true", help="Preview only")
    parser.add_argument("--commit", action="store_true", help="Apply changes")
    args = parser.parse_args()

    if not args.dry_run and not args.commit:
        print("Pass --dry-run or --commit"); return

    fb = get_firebase_service()
    if not fb or not fb.db:
        print("[FATAL] Firebase not initialized"); return
    db = fb.db

    print("[1/3] Loading recipe_groups...", flush=True)
    groups = list(db.collection("recipe_groups").stream())
    print(f"  Found {len(groups)} groups total", flush=True)

    missing = []
    for g in groups:
        data = g.to_dict() or {}
        thumb = (data.get("latestThumbnailUrl") or "").strip()
        if not thumb:
            missing.append((g.id, data))

    print(f"  {len(missing)} groups missing thumbnails", flush=True)
    if not missing:
        print("[Done] All groups already have thumbnails."); return

    print(f"\n[2/3] Finding thumbnails for {len(missing)} groups...", flush=True)
    updates = []
    for group_id, group_data in missing:
        name = (group_data.get("name") or "").strip()
        if not name:
            print(f"  SKIP {group_id}: no name")
            continue

        snap = (
            db.collection("recipes")
            .where("groupKey", "==", name)
            .limit(50)
            .get()
        )

        candidates = []
        for doc in snap:
            d = doc.to_dict() or {}
            if d.get("isHidden") or d.get("status") != "completed":
                continue
            url = (d.get("thumbnailUrl") or "").strip()
            if url:
                sc = int(d.get("saveCount") or 0)
                candidates.append((sc, url))
        candidates.sort(key=lambda x: x[0], reverse=True)
        thumb_url = candidates[0][1] if candidates else None

        if thumb_url:
            updates.append((group_id, name, thumb_url))
            print(f"  OK  #{name} -> {thumb_url[:80]}...")
        else:
            print(f"  MISS #{name}: no recipe with thumbnail found")

    print(f"\n[3/3] {'DRY-RUN' if args.dry_run else 'UPDATING'} {len(updates)} groups...", flush=True)

    if args.commit and updates:
        batch = db.batch()
        for i, (group_id, name, thumb_url) in enumerate(updates):
            ref = db.collection("recipe_groups").document(group_id)
            batch.update(ref, {"latestThumbnailUrl": thumb_url})
            if (i + 1) % 400 == 0:
                batch.commit()
                batch = db.batch()
        batch.commit()
        print(f"  Updated {len(updates)} groups in Firestore")
    elif args.dry_run:
        print(f"  Would update {len(updates)} groups (dry-run)")

    print("[Done]")


if __name__ == "__main__":
    main()
