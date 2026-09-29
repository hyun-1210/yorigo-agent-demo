import argparse
import json
import os
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import firebase_admin
from firebase_admin import credentials, firestore


BACKEND_DIR = Path(__file__).resolve().parents[1]


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
        v = v.strip()
        if k and k not in os.environ:
            os.environ[k] = v


def _init_firestore_client() -> firestore.Client:
    if firebase_admin._apps:
        return firestore.client()

    _load_env()
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    if service_account_json:
        try:
            if Path(service_account_json).exists():
                cred = credentials.Certificate(service_account_json)
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


def _source_from_recipe(data: Dict[str, Any]) -> Tuple[str, str]:
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    source_url = str(data.get("sourceUrl") or source.get("url") or "").strip()
    platform = str(source.get("platform") or data.get("platform") or "").strip()
    return source_url, platform


def _thumbnail_from_recipe(data: Dict[str, Any]) -> str:
    return str(
        data.get("thumbnailUrlCropped")
        or data.get("thumbnailUrlLarge")
        or data.get("thumbnailUrl")
        or ""
    ).strip()


def _build_thumb_lookup(
    db: firestore.Client,
) -> Tuple[Dict[str, Tuple[str, str]], Dict[str, int]]:
    choices: Dict[str, set] = {}
    scanned = 0
    for doc in db.collection("recipes").stream():
        scanned += 1
        data = doc.to_dict() or {}
        thumb = str(data.get("thumbnailUrl") or "").strip()
        if not thumb:
            continue
        source_url, platform = _source_from_recipe(data)
        if not source_url and not platform:
            continue
        if thumb not in choices:
            choices[thumb] = set()
        choices[thumb].add((source_url, platform))

    resolved: Dict[str, Tuple[str, str]] = {}
    for thumb, values in choices.items():
        if len(values) == 1:
            resolved[thumb] = next(iter(values))

    stats = {
        "recipe_docs_scanned": scanned,
        "thumb_candidates": len(choices),
        "thumb_unique_mapping": len(resolved),
        "thumb_ambiguous": len(choices) - len(resolved),
    }
    return resolved, stats


def backfill_user_data(
    db: firestore.Client,
    dry_run: bool,
    limit_users: int,
    only_uid: str,
) -> Dict[str, int]:
    thumb_lookup, lookup_stats = _build_thumb_lookup(db)
    recipe_cache: Dict[str, Tuple[str, str, str]] = {}

    def recipe_source(recipe_id: str) -> Tuple[str, str, str]:
        if not recipe_id:
            return "", "", ""
        if recipe_id in recipe_cache:
            return recipe_cache[recipe_id]
        try:
            doc = db.collection("recipes").document(recipe_id).get()
            if not doc.exists:
                recipe_cache[recipe_id] = ("", "", "")
            else:
                source_url, platform = _source_from_recipe(doc.to_dict() or {})
                thumb = _thumbnail_from_recipe(doc.to_dict() or {})
                recipe_cache[recipe_id] = (source_url, platform, thumb)
        except Exception:
            recipe_cache[recipe_id] = ("", "", "")
        return recipe_cache[recipe_id]

    users = db.collection("users").stream()
    stats = {
        **lookup_stats,
        "users_scanned": 0,
        "users_updated": 0,
        "cart_items_checked": 0,
        "cart_items_filled": 0,
        "fridge_recipes_checked": 0,
        "fridge_recipes_filled": 0,
        "cart_thumb_synced": 0,
        "fridge_thumb_synced": 0,
        "filled_by_recipe_id": 0,
        "filled_by_thumbnail_lookup": 0,
        "errors": 0,
    }

    for user_doc in users:
        uid = user_doc.id
        if only_uid and uid != only_uid:
            continue
        if limit_users > 0 and stats["users_scanned"] >= limit_users:
            break
        stats["users_scanned"] += 1

        try:
            data = user_doc.to_dict() or {}
            changed = False

            cart_items = data.get("cartItems")
            updated_cart = None
            if isinstance(cart_items, list):
                updated_cart = []
                for raw in cart_items:
                    if not isinstance(raw, dict):
                        updated_cart.append(raw)
                        continue
                    item = dict(raw)
                    stats["cart_items_checked"] += 1
                    source_url = str(item.get("sourceUrl") or "").strip()
                    platform = str(item.get("platform") or "").strip()
                    thumb_now = str(item.get("thumbnailUrl") or "").strip()

                    recipe_id = str(item.get("recipeId") or "").strip()
                    filled_source = ""
                    filled_platform = ""
                    filled_thumb = ""

                    if recipe_id:
                        filled_source, filled_platform, filled_thumb = recipe_source(
                            recipe_id
                        )
                        if filled_source or filled_platform or filled_thumb:
                            stats["filled_by_recipe_id"] += 1

                    if not filled_source and not filled_platform:
                        thumb = str(item.get("thumbnailUrl") or "").strip()
                        if thumb in thumb_lookup:
                            filled_source, filled_platform = thumb_lookup[thumb]
                            stats["filled_by_thumbnail_lookup"] += 1

                    if filled_source and not source_url:
                        item["sourceUrl"] = filled_source
                        source_url = filled_source
                        changed = True
                        stats["cart_items_filled"] += 1
                    if filled_platform and not platform:
                        item["platform"] = filled_platform
                        platform = filled_platform
                        changed = True
                        if not filled_source:
                            stats["cart_items_filled"] += 1
                    if filled_thumb and thumb_now != filled_thumb:
                        item["thumbnailUrl"] = filled_thumb
                        changed = True
                        stats["cart_thumb_synced"] += 1

                    updated_cart.append(item)

            fridge_data = data.get("fridgeData")
            updated_fridge_data = None
            if isinstance(fridge_data, dict):
                recipes = fridge_data.get("recipes")
                if isinstance(recipes, list):
                    updated_recipes = []
                    for raw in recipes:
                        if not isinstance(raw, dict):
                            updated_recipes.append(raw)
                            continue
                        recipe = dict(raw)
                        stats["fridge_recipes_checked"] += 1
                        source_url = str(recipe.get("sourceUrl") or "").strip()
                        platform = str(recipe.get("platform") or "").strip()
                        thumb_now = str(recipe.get("thumbnailUrl") or "").strip()

                        recipe_id = str(
                            recipe.get("recipeId") or recipe.get("id") or ""
                        ).strip()
                        filled_source = ""
                        filled_platform = ""
                        filled_thumb = ""

                        if recipe_id:
                            filled_source, filled_platform, filled_thumb = recipe_source(
                                recipe_id
                            )
                            if filled_source or filled_platform or filled_thumb:
                                stats["filled_by_recipe_id"] += 1

                        if not filled_source and not filled_platform:
                            thumb = str(recipe.get("thumbnailUrl") or "").strip()
                            if thumb in thumb_lookup:
                                filled_source, filled_platform = thumb_lookup[thumb]
                                stats["filled_by_thumbnail_lookup"] += 1

                        if filled_source and not source_url:
                            recipe["sourceUrl"] = filled_source
                            source_url = filled_source
                            changed = True
                            stats["fridge_recipes_filled"] += 1
                        if filled_platform and not platform:
                            recipe["platform"] = filled_platform
                            changed = True
                            if not filled_source:
                                stats["fridge_recipes_filled"] += 1
                        if filled_thumb and thumb_now != filled_thumb:
                            recipe["thumbnailUrl"] = filled_thumb
                            changed = True
                            stats["fridge_thumb_synced"] += 1

                        updated_recipes.append(recipe)

                    updated_fridge_data = dict(fridge_data)
                    updated_fridge_data["recipes"] = updated_recipes

            if changed:
                patch: Dict[str, Any] = {"updatedAt": firestore.SERVER_TIMESTAMP}
                if updated_cart is not None:
                    patch["cartItems"] = updated_cart
                if updated_fridge_data is not None:
                    patch["fridgeData"] = updated_fridge_data
                if not dry_run:
                    user_doc.reference.set(patch, merge=True)
                stats["users_updated"] += 1
        except Exception:
            stats["errors"] += 1

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Backfill sourceUrl/platform in users cartItems and fridgeData recipes."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyze and print stats without writing changes.",
    )
    parser.add_argument(
        "--limit-users",
        type=int,
        default=0,
        help="Max number of users to scan (0 = all).",
    )
    parser.add_argument(
        "--uid",
        type=str,
        default="",
        help="Only process a single user uid.",
    )
    args = parser.parse_args()

    db = _init_firestore_client()
    stats = backfill_user_data(
        db=db,
        dry_run=args.dry_run,
        limit_users=args.limit_users,
        only_uid=args.uid.strip(),
    )
    print("[backfill_user_cart_fridge_sources]")
    for k, v in stats.items():
        print(f"{k}={v}")


if __name__ == "__main__":
    main()
