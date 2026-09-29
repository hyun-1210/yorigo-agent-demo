"""
Clean up duplicate recipe documents in Firestore.

For each group of recipes sharing the same sourceUrl, keeps the best
canonical document and:
  1. Migrates all users' savedRecipes references to the canonical doc.
  2. Migrates cartItems references to the canonical doc.
  3. Hides duplicate docs (isHidden=True) with a hiddenReason pointer.

Usage:
  python backend/scripts/cleanup_duplicate_recipes.py --dry-run
  python backend/scripts/cleanup_duplicate_recipes.py
  python backend/scripts/cleanup_duplicate_recipes.py --limit 10
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

CURRENT_DIR = Path(__file__).resolve().parent
BACKEND_DIR = CURRENT_DIR.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

try:
    from dotenv import load_dotenv
except Exception:
    load_dotenv = None

if load_dotenv:
    env_path = BACKEND_DIR / ".env"
    if env_path.exists():
        load_dotenv(str(env_path))

from services.firebase_service import get_firebase_service


def _pick_canonical(docs: list) -> tuple:
    """Pick the best doc to keep. Returns (canonical_doc, duplicate_docs)."""
    scored = []
    for doc in docs:
        data = doc.to_dict()
        score = 0
        status = (data.get("status") or "").lower()
        if status == "completed":
            score += 1000
        recipe = data.get("recipe") or {}
        if isinstance(recipe, dict):
            if recipe.get("steps"):
                score += 100
            if recipe.get("ingredients"):
                score += 50
        if data.get("thumbnailUrl"):
            score += 10
        created = data.get("createdAt")
        if created:
            try:
                score += created.timestamp() * 0.001
            except Exception:
                pass
        scored.append((score, doc))

    scored.sort(key=lambda x: x[0], reverse=True)
    canonical = scored[0][1]
    duplicates = [s[1] for s in scored[1:]]
    return canonical, duplicates


def main():
    parser = argparse.ArgumentParser(description="Clean up duplicate recipes")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without writing")
    parser.add_argument("--limit", type=int, default=0, help="Max groups to process (0=all)")
    args = parser.parse_args()

    fb = get_firebase_service()
    if not fb or not fb.is_available():
        print("Firebase not available")
        sys.exit(1)
    db = fb.db

    print("Loading all visible, non-hidden recipes...")
    all_recipes = list(
        db.collection("recipes")
        .where("isHidden", "==", False)
        .stream()
    )
    print(f"Total recipes: {len(all_recipes)}")

    url_groups: dict[str, list] = defaultdict(list)
    for doc in all_recipes:
        data = doc.to_dict()
        source_url = (data.get("sourceUrl") or "").strip()
        if not source_url:
            continue
        url_groups[source_url].append(doc)

    dup_groups = {url: docs for url, docs in url_groups.items() if len(docs) > 1}
    print(f"Duplicate groups: {len(dup_groups)}")

    if not dup_groups:
        print("No duplicates found!")
        return

    print("\nLoading all user documents for savedRecipes / cartItems migration...")
    all_users = list(db.collection("users").stream())
    print(f"Total users: {len(all_users)}")

    user_saved: dict[str, list[str]] = {}
    user_cart: dict[str, list] = {}
    for u in all_users:
        ud = u.to_dict()
        sr = ud.get("savedRecipes") or []
        ci = ud.get("cartItems") or []
        if sr:
            user_saved[u.id] = [x for x in sr if isinstance(x, str)]
        if ci:
            user_cart[u.id] = list(ci)

    total_dupes_hidden = 0
    total_refs_migrated = 0
    processed = 0

    from google.cloud.firestore import ArrayUnion, ArrayRemove

    for url, docs in sorted(dup_groups.items(), key=lambda x: -len(x[1])):
        if args.limit and processed >= args.limit:
            break

        canonical, duplicates = _pick_canonical(docs)
        dup_ids = {d.id for d in duplicates}
        canonical_id = canonical.id

        print(f"\n--- {url}")
        print(f"    Canonical: {canonical_id} (status={canonical.to_dict().get('status')})")
        print(f"    Duplicates ({len(duplicates)}): {[d.id for d in duplicates]}")

        for uid, saved_list in user_saved.items():
            overlapping = [rid for rid in saved_list if rid in dup_ids]
            if not overlapping:
                continue

            has_canonical = canonical_id in saved_list
            print(f"    User {uid}: saved refs to migrate: {overlapping}, has canonical={has_canonical}")

            if args.dry_run:
                total_refs_migrated += len(overlapping)
                continue

            updates = {}
            if not has_canonical:
                updates["savedRecipes"] = ArrayUnion([canonical_id])
            try:
                db.collection("users").document(uid).update({
                    "savedRecipes": ArrayRemove(overlapping),
                })
                if updates:
                    db.collection("users").document(uid).update(updates)
                total_refs_migrated += len(overlapping)
            except Exception as e:
                print(f"    ERROR migrating savedRecipes for {uid}: {e}")

        for uid, cart_list in user_cart.items():
            items_to_remove = []
            items_to_add = []
            has_canonical_in_cart = any(
                isinstance(ci, dict) and ci.get("recipeId") == canonical_id
                for ci in cart_list
            )
            for ci in cart_list:
                if not isinstance(ci, dict):
                    continue
                rid = ci.get("recipeId")
                if rid in dup_ids:
                    items_to_remove.append(ci)
                    if not has_canonical_in_cart:
                        migrated = dict(ci)
                        migrated["recipeId"] = canonical_id
                        items_to_add.append(migrated)
                        has_canonical_in_cart = True

            if not items_to_remove:
                continue

            print(f"    User {uid}: cart items to migrate: {len(items_to_remove)}, has canonical={has_canonical_in_cart}")

            if args.dry_run:
                total_refs_migrated += len(items_to_remove)
                continue

            try:
                db.collection("users").document(uid).update({
                    "cartItems": ArrayRemove(items_to_remove),
                })
                if items_to_add:
                    db.collection("users").document(uid).update({
                        "cartItems": ArrayUnion(items_to_add),
                    })
                total_refs_migrated += len(items_to_remove)
            except Exception as e:
                print(f"    ERROR migrating cartItems for {uid}: {e}")

        for dup_doc in duplicates:
            action = "WOULD HIDE" if args.dry_run else "HIDING"
            print(f"    {action} {dup_doc.id}")
            if not args.dry_run:
                try:
                    db.collection("recipes").document(dup_doc.id).update({
                        "isHidden": True,
                        "hiddenReason": f"duplicate_of:{canonical_id}",
                    })
                except Exception as e:
                    print(f"    ERROR hiding {dup_doc.id}: {e}")
            total_dupes_hidden += 1

        processed += 1
        if not args.dry_run and processed % 20 == 0:
            time.sleep(0.5)

    print(f"\n{'[DRY RUN] ' if args.dry_run else ''}Done!")
    print(f"  Groups processed: {processed}")
    print(f"  Duplicates hidden: {total_dupes_hidden}")
    print(f"  User refs migrated: {total_refs_migrated}")


if __name__ == "__main__":
    main()
