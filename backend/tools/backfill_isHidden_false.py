import os
import sys
from typing import Any, Dict, Optional

import firebase_admin
from firebase_admin import credentials, firestore


BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # .../backend


BATCH_SIZE = 450  # keep safely under Firestore's 500 write ops/batch limit


def _is_missing_isHidden(data: Optional[Dict[str, Any]]) -> bool:
    if not data:
        return True
    if "isHidden" not in data:
        return True
    if data.get("isHidden") is None:
        return True
    return False


def _init_firestore_client() -> firestore.Client:
    if firebase_admin._apps:
        return firestore.client()

    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    if service_account_json:
        if os.path.exists(service_account_json):
            cred = credentials.Certificate(service_account_json)
            firebase_admin.initialize_app(cred)
            return firestore.client()
        # If env is JSON content, try loading as dict-like string
        try:
            import json

            cred_dict = json.loads(service_account_json)
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
            return firestore.client()
        except Exception:
            pass

    canonical = os.path.join(BACKEND_DIR, "firebase-service-account.json")
    if os.path.exists(canonical):
        cred = credentials.Certificate(canonical)
        firebase_admin.initialize_app(cred)
        return firestore.client()

    # Last fallback: application default credentials
    firebase_admin.initialize_app()
    return firestore.client()


def main() -> None:
    dry_run = "--dry-run" in sys.argv

    db = _init_firestore_client()

    total_recipes_missing = 0
    total_reviews_missing = 0
    total_comments_missing = 0
    updated_recipes = 0
    updated_reviews = 0
    updated_comments = 0

    # -------- recipes --------
    batch = db.batch()
    pending_ops = 0

    print("[Backfill] Scanning `recipes` for missing isHidden...")
    for doc in db.collection("recipes").stream():
        data = doc.to_dict() or {}
        if _is_missing_isHidden(data):
            total_recipes_missing += 1
            if not dry_run:
                batch.update(doc.reference, {"isHidden": False})
            updated_recipes += 1
            pending_ops += 1
            if pending_ops >= BATCH_SIZE:
                if not dry_run:
                    batch.commit()
                batch = db.batch()
                pending_ops = 0

    if not dry_run and pending_ops > 0:
        batch.commit()
    print(f"[Backfill] recipes missing={total_recipes_missing}, updated={updated_recipes}")

    # -------- reviews --------
    batch = db.batch()
    pending_ops = 0
    print("[Backfill] Scanning `reviews` for missing isHidden...")
    for doc in db.collection("reviews").stream():
        data = doc.to_dict() or {}
        if _is_missing_isHidden(data):
            total_reviews_missing += 1
            if not dry_run:
                batch.update(doc.reference, {"isHidden": False})
            updated_reviews += 1
            pending_ops += 1
            if pending_ops >= BATCH_SIZE:
                if not dry_run:
                    batch.commit()
                batch = db.batch()
                pending_ops = 0

    if not dry_run and pending_ops > 0:
        batch.commit()
    print(f"[Backfill] reviews missing={total_reviews_missing}, updated={updated_reviews}")

    # -------- comments (subcollection under reviews) --------
    batch = db.batch()
    pending_ops = 0
    print("[Backfill] Scanning `reviews/{reviewId}/comments` for missing isHidden...")

    for review_doc in db.collection("reviews").stream():
        comments_ref = review_doc.reference.collection("comments")
        for comment_doc in comments_ref.stream():
            data = comment_doc.to_dict() or {}
            if _is_missing_isHidden(data):
                total_comments_missing += 1
                if not dry_run:
                    batch.update(comment_doc.reference, {"isHidden": False})
                updated_comments += 1
                pending_ops += 1
                if pending_ops >= BATCH_SIZE:
                    if not dry_run:
                        batch.commit()
                    batch = db.batch()
                    pending_ops = 0

    if not dry_run and pending_ops > 0:
        batch.commit()

    print(
        "[Backfill] done.\n"
        f"  recipes missing={total_recipes_missing}, updated={updated_recipes}\n"
        f"  reviews missing={total_reviews_missing}, updated={updated_reviews}\n"
        f"  comments missing={total_comments_missing}, updated={updated_comments}"
    )


if __name__ == "__main__":
    main()

