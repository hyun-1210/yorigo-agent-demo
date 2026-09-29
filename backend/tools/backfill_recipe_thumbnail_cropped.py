import argparse
import io
import json
import os
import uuid
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import quote

import firebase_admin
import requests
from PIL import Image
from firebase_admin import credentials, firestore, storage


BACKEND_DIR = Path(__file__).resolve().parents[1]
REQUEST_TIMEOUT = 25
SCALE_X = 3.20
SCALE_Y = 1.28


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


def _init_app() -> firebase_admin.App:
    if firebase_admin._apps:
        return firebase_admin.get_app()

    _load_env()
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()

    options: Dict[str, Any] = {}
    if bucket:
        options["storageBucket"] = bucket

    if service_account_json:
        try:
            if Path(service_account_json).exists():
                return firebase_admin.initialize_app(
                    credentials.Certificate(service_account_json),
                    options if options else None,
                )
            cred_dict = json.loads(service_account_json)
            return firebase_admin.initialize_app(
                credentials.Certificate(cred_dict),
                options if options else None,
            )
        except Exception:
            pass

    canonical = BACKEND_DIR / "firebase-service-account.json"
    if canonical.exists():
        return firebase_admin.initialize_app(
            credentials.Certificate(str(canonical)),
            options if options else None,
        )

    return firebase_admin.initialize_app(options=options if options else None)


def _is_youtube_recipe(data: Dict[str, Any]) -> bool:
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    platform = str(source.get("platform") or data.get("platform") or "").lower()
    if "youtube" in platform:
        return True
    source_url = str(data.get("sourceUrl") or source.get("url") or "").lower()
    if "youtube.com" in source_url or "youtu.be" in source_url:
        return True
    thumbnail = str(
        data.get("thumbnailUrl")
        or data.get("thumbnailUrlLarge")
        or source.get("thumbnail")
        or ""
    ).lower()
    return "ytimg.com" in thumbnail


def _pick_thumbnail_url(data: Dict[str, Any]) -> str:
    """크롭 입력 URL. Cloud Function `ensureYoutubeCroppedThumbnailForRecipe` 와 동일하게 ytimg 우선."""
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    st = str(source.get("thumbnail") or "").strip()
    st_low = st.lower()
    if st and ("ytimg.com" in st_low or "youtube.com/vi/" in st_low):
        return st
    for key in ("thumbnailUrl", "thumbnailUrlLarge"):
        u = str(data.get(key) or "").strip()
        low = u.lower()
        if u and ("ytimg.com" in low or "youtube.com/vi/" in low):
            return u
    return str(
        data.get("thumbnailUrlLarge")
        or data.get("thumbnailUrl")
        or source.get("thumbnail")
        or ""
    ).strip()


def _fixed_scale_crop_bounds(image: Image.Image) -> Optional[Tuple[int, int, int, int]]:
    w, h = image.size
    if w < 2 or h < 2:
        return None
    sx = SCALE_X if SCALE_X > 1.0 else 1.0
    sy = SCALE_Y if SCALE_Y > 1.0 else 1.0
    if sx <= 1.0 and sy <= 1.0:
        return None

    crop_w = max(1, min(w, round(w / sx)))
    crop_h = max(1, min(h, round(h / sy)))
    if crop_w >= w and crop_h >= h:
        return None
    crop_x = max(0, min(w - crop_w, round((w - crop_w) / 2.0)))
    crop_y = max(0, min(h - crop_h, round((h - crop_h) / 2.0)))
    return crop_x, crop_y, crop_w, crop_h


def _download_bytes(url: str) -> Optional[bytes]:
    if not url:
        return None
    try:
        resp = requests.get(url, timeout=REQUEST_TIMEOUT)
        if resp.status_code != 200 or not resp.content:
            return None
        return resp.content
    except Exception:
        return None


def _build_download_url(bucket_name: str, object_path: str, token: str) -> str:
    return (
        f"https://firebasestorage.googleapis.com/v0/b/{bucket_name}/o/"
        f"{quote(object_path, safe='')}?alt=media&token={token}"
    )


def _default_bucket_name() -> str:
    app = firebase_admin.get_app()
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    project_id = app.project_id or os.getenv("FIREBASE_PROJECT_ID", "").strip()
    if not project_id:
        return ""
    # New Firebase projects generally use *.firebasestorage.app.
    return f"{project_id}.firebasestorage.app"


def _ensure_bucket() -> storage.bucket:
    app = firebase_admin.get_app()
    bucket_name = _default_bucket_name()
    if bucket_name:
        return storage.bucket(bucket_name, app=app)
    raise RuntimeError("Storage bucket is not configured.")


def backfill(limit: int, dry_run: bool) -> Dict[str, int]:
    app = _init_app()
    db = firestore.client(app=app)
    bucket = None if dry_run else _ensure_bucket()
    bucket_name = _default_bucket_name() if dry_run else bucket.name

    stats = {
        "scanned": 0,
        "youtube_target": 0,
        "already_cropped": 0,
        "no_thumbnail_url": 0,
        "download_failed": 0,
        "no_crop_needed": 0,
        "updated": 0,
        "errors": 0,
    }

    page_size = 120
    last_doc = None
    done = False
    while not done:
        query = db.collection("recipes").order_by("__name__").limit(page_size)
        if last_doc is not None:
            query = query.start_after(last_doc)
        docs = list(query.stream())
        if not docs:
            break

        for doc in docs:
            if limit > 0 and stats["scanned"] >= limit:
                done = True
                break
            stats["scanned"] += 1
            try:
                data = doc.to_dict() or {}
                if not _is_youtube_recipe(data):
                    continue
                stats["youtube_target"] += 1

                existing_cropped = str(data.get("thumbnailUrlCropped") or "").strip()
                if existing_cropped:
                    stats["already_cropped"] += 1
                    continue

                source_url = _pick_thumbnail_url(data)
                if not source_url:
                    stats["no_thumbnail_url"] += 1
                    continue

                raw = _download_bytes(source_url)
                if not raw:
                    stats["download_failed"] += 1
                    continue

                try:
                    image = Image.open(io.BytesIO(raw))
                except Exception:
                    stats["download_failed"] += 1
                    continue

                bounds = _fixed_scale_crop_bounds(image)
                if bounds is None:
                    stats["no_crop_needed"] += 1
                    continue

                x, y, w, h = bounds
                cropped = image.convert("RGB").crop((x, y, x + w, y + h))
                out = io.BytesIO()
                cropped.save(out, format="JPEG", quality=90)
                cropped_bytes = out.getvalue()
                if not cropped_bytes:
                    stats["errors"] += 1
                    continue

                object_path = f"recipe_thumbnails/cropped/{doc.id}_cropped.jpg"
                token = str(uuid.uuid4())
                if not bucket_name:
                    stats["errors"] += 1
                    continue
                download_url = _build_download_url(bucket_name, object_path, token)

                if not dry_run:
                    assert bucket is not None
                    blob = bucket.blob(object_path)
                    blob.metadata = {
                        "firebaseStorageDownloadTokens": token,
                        "variant": "cropped",
                        "sourceUrl": source_url,
                    }
                    blob.upload_from_string(cropped_bytes, content_type="image/jpeg")
                    doc.reference.update(
                        {
                            "thumbnailUrlCropped": download_url,
                            "updatedAt": firestore.SERVER_TIMESTAMP,
                        }
                    )

                stats["updated"] += 1
            except Exception:
                stats["errors"] += 1

        last_doc = docs[-1]

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Backfill thumbnailUrlCropped for YouTube recipe documents."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum number of recipe docs to scan (0 = all).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyze and print stats without writing to Firestore/Storage.",
    )
    args = parser.parse_args()

    stats = backfill(limit=args.limit, dry_run=args.dry_run)
    print("[backfill_recipe_thumbnail_cropped]")
    for k, v in stats.items():
        print(f"{k}={v}")


if __name__ == "__main__":
    main()
