"""로컬 홈 CMS 대시보드.

Run:
  python app.py
→ http://127.0.0.1:8787/
"""

from __future__ import annotations

import json
import logging
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from firebase_util import get_bucket, get_db  # noqa: E402
from schemas import (  # noqa: E402
    assert_exposure_caps,
    normalize_poster,
    normalize_section,
    require_poster_id,
    require_section_key,
    sanitize_key,
)
from section_matcher import is_visible_completed, matches_rule, recipe_title  # noqa: E402
from seed_data import SCHEMA_VERSION  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("cms_dashboard")

STATIC_DIR = HERE / "static"
REPO_ROOT = HERE.parents[1]
FRONTEND_ASSETS = REPO_ROOT / "yorigo-frontend"
MAX_IMAGE_BYTES = 3 * 1024 * 1024
SEARCH_SCAN_CAP = 400
REBUILD_SCAN_CAP = 8000
HOST = "127.0.0.1"
PORT = 8787
_LOCAL_ASSET_RE = re.compile(r"^assets/images/home_poster_[a-z0-9_]+\.(png|jpg|jpeg|webp)$")

app = FastAPI(title="Yorigo Home CMS", docs_url=None, redoc_url=None)
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.exception_handler(ValueError)
async def _value_error(_: Request, exc: ValueError) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=400)


def _loopback_or_403(request: Request) -> None:
    host = (request.client.host if request.client else "") or ""
    if host in ("127.0.0.1", "::1", "localhost"):
        return
    raise HTTPException(status_code=403, detail="loopback_only")


@app.middleware("http")
async def _guard_loopback(request: Request, call_next):
    if request.url.path.startswith("/static"):
        return await call_next(request)
    try:
        _loopback_or_403(request)
    except HTTPException as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)
    return await call_next(request)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _serialize(v: Any) -> Any:
    if v is None:
        return None
    if hasattr(v, "isoformat") and callable(getattr(v, "isoformat")) and not isinstance(v, str):
        try:
            return v.isoformat()
        except Exception:
            return str(v)
    if isinstance(v, dict):
        return {k: _serialize(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_serialize(x) for x in v]
    return v


def _load_posters(db: Any) -> list[dict[str, Any]]:
    docs = list(db.collection("home_cms_posters").stream())
    posters = [_serialize({"id": d.id, **(d.to_dict() or {})}) for d in docs]
    posters.sort(key=lambda p: (int(p.get("order") or 0), str(p.get("id") or "")))
    return posters


def _load_sections(db: Any) -> list[dict[str, Any]]:
    docs = list(db.collection("home_cms_sections").stream())
    sections = [_serialize({"sectionKey": d.id, **(d.to_dict() or {})}) for d in docs]
    sections.sort(key=lambda s: (int(s.get("order") or 0), str(s.get("sectionKey") or "")))
    return sections


def _snapshot_rollback(db: Any) -> None:
    bundle_ref = db.collection("home_cms").document("bundle")
    snap = bundle_ref.get()
    if snap.exists:
        db.collection("home_cms").document("rollback").set(snap.to_dict() or {})


def _write_bundle(db: Any, updated_by: str = "dashboard") -> dict[str, Any]:
    posters = _load_posters(db)
    sections = _load_sections(db)
    assert_exposure_caps(posters, sections)
    bundle = {
        "schemaVersion": SCHEMA_VERSION,
        "updatedAt": _now().isoformat(),
        "updatedBy": updated_by,
        "posters": posters,
        "sections": sections,
    }
    db.collection("home_cms").document("bundle").set(bundle)
    db.collection("home_cms").document("meta").set(
        {
            "schemaVersion": SCHEMA_VERSION,
            "updatedAt": _now(),
            "updatedBy": updated_by,
        },
        merge=True,
    )
    return bundle


def _id_list(raw: Any) -> list[str]:
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        s = str(item or "").strip()
        if not s or s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out


def _recipe_summary(recipe_id: str, data: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": recipe_id,
        "title": recipe_title(data) or recipe_id,
        "status": data.get("status"),
        "isHidden": data.get("isHidden") is True,
        "thumbnailUrl": _recipe_thumb(data),
    }


def _recipe_thumb(data: dict[str, Any]) -> str:
    nested = data.get("recipe") if isinstance(data.get("recipe"), dict) else {}
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    for value in (
        data.get("thumbnailUrlCropped"),
        data.get("thumbnailUrlLarge"),
        data.get("thumbnailUrl"),
        data.get("thumbnail_url"),
        nested.get("thumbnailUrl"),
        nested.get("thumbnail_url"),
        source.get("thumbnail"),
        source.get("thumbnail_url"),
    ):
        url = str(value or "").strip()
        if url.startswith("http"):
            return url
    return ""


def _cards_for_key(db: Any, key: str, limit: int) -> dict[str, Any]:
    snap = db.collection("home_section_index").document(key).get()
    ids = _id_list((snap.to_dict() or {}).get("recipeIds") if snap.exists else [])
    take = ids[: max(1, min(int(limit), 12))]
    cards: list[dict[str, Any]] = []
    if take:
        refs = [db.collection("recipes").document(rid) for rid in take]
        by_id = {snap.id: snap for snap in db.get_all(refs) if snap.exists}
        for rid in take:
            rsnap = by_id.get(rid)
            if rsnap is None:
                continue
            data = rsnap.to_dict() or {}
            cards.append(_recipe_summary(rid, data))
    return {"sectionKey": key, "count": len(ids), "recipes": cards}


@app.get("/")
def index() -> FileResponse:
    page = STATIC_DIR / "index.html"
    if not page.exists():
        raise HTTPException(status_code=500, detail="missing_index")
    return FileResponse(page)


@app.get("/api/bundle")
def api_bundle() -> dict[str, Any]:
    db = get_db()
    snap = db.collection("home_cms").document("bundle").get()
    if not snap.exists:
        return {"ok": True, "bundle": None, "empty": True}
    return {"ok": True, "bundle": _serialize(snap.to_dict() or {})}


@app.get("/api/local-asset")
def api_local_asset(path: str = "") -> FileResponse:
    rel = path.replace("\\", "/").lstrip("/")
    if not _LOCAL_ASSET_RE.match(rel):
        raise HTTPException(status_code=404, detail="not_found")
    file_path = (FRONTEND_ASSETS / rel).resolve()
    root = FRONTEND_ASSETS.resolve()
    if root not in file_path.parents and file_path != root:
        raise HTTPException(status_code=404, detail="not_found")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="not_found")
    return FileResponse(file_path)


@app.get("/api/preview/section")
def api_preview_section(section_key: str = "", limit: int = 8) -> dict[str, Any]:
    key = sanitize_key(section_key)
    if not key:
        return {"ok": True, "sectionKey": "", "count": 0, "recipes": []}
    return {"ok": True, **_cards_for_key(get_db(), key, limit)}


@app.get("/api/posters")
def api_posters() -> dict[str, Any]:
    return {"ok": True, "posters": _load_posters(get_db())}
def api_posters() -> dict[str, Any]:
    return {"ok": True, "posters": _load_posters(get_db())}


@app.post("/api/posters")
def api_create_poster(payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    poster_id = require_poster_id(payload.get("id"))
    ref = db.collection("home_cms_posters").document(poster_id)
    if ref.get().exists:
        raise HTTPException(status_code=409, detail="poster_exists")
    doc = normalize_poster(payload, poster_id)
    posters = _load_posters(db) + [doc]
    sections = _load_sections(db)
    assert_exposure_caps(posters, sections)
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "poster": doc, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.put("/api/posters/{poster_id}")
def api_update_poster(poster_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    pid = require_poster_id(poster_id)
    ref = db.collection("home_cms_posters").document(pid)
    if not ref.get().exists:
        raise HTTPException(status_code=404, detail="poster_not_found")
    payload = {**payload, "id": pid}
    doc = normalize_poster(payload, pid)
    posters = [p for p in _load_posters(db) if p.get("id") != pid] + [doc]
    assert_exposure_caps(posters, _load_sections(db))
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "poster": doc, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.delete("/api/posters/{poster_id}")
def api_delete_poster(poster_id: str) -> dict[str, Any]:
    db = get_db()
    pid = require_poster_id(poster_id)
    ref = db.collection("home_cms_posters").document(pid)
    if not ref.get().exists:
        raise HTTPException(status_code=404, detail="poster_not_found")
    posters = [p for p in _load_posters(db) if p.get("id") != pid]
    assert_exposure_caps(posters, _load_sections(db))
    _snapshot_rollback(db)
    ref.delete()
    bundle = _write_bundle(db)
    return {"ok": True, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.post("/api/posters/{poster_id}/image")
async def api_upload_poster_image(poster_id: str, file: UploadFile = File(...)) -> dict[str, Any]:
    db = get_db()
    pid = require_poster_id(poster_id)
    ref = db.collection("home_cms_posters").document(pid)
    snap = ref.get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="poster_not_found")
    raw = await file.read()
    if len(raw) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail="image_too_large")
    content_type = (file.content_type or "image/jpeg").split(";")[0]
    if not content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="not_an_image")
    ext = "jpg"
    if "png" in content_type:
        ext = "png"
    elif "webp" in content_type:
        ext = "webp"
    path = f"home_cms/posters/{pid}/{uuid.uuid4().hex}.{ext}"
    token = uuid.uuid4().hex
    bucket = get_bucket()
    blob = bucket.blob(path)
    blob.metadata = {"firebaseStorageDownloadTokens": token}
    blob.upload_from_string(raw, content_type=content_type)
    bucket_name = bucket.name
    image_url = (
        f"https://firebasestorage.googleapis.com/v0/b/{bucket_name}/o/"
        f"{quote(path, safe='')}?alt=media&token={token}"
    )
    data = snap.to_dict() or {}
    data["imageUrl"] = image_url
    doc = normalize_poster(data, pid)
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "imageUrl": image_url, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.get("/api/sections")
def api_sections() -> dict[str, Any]:
    return {"ok": True, "sections": _load_sections(get_db())}


@app.post("/api/sections")
def api_create_section(payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = require_section_key(payload.get("sectionKey") or payload.get("id"))
    ref = db.collection("home_cms_sections").document(key)
    if ref.get().exists:
        raise HTTPException(status_code=409, detail="section_exists")
    doc = normalize_section(payload, key)
    sections = _load_sections(db) + [doc]
    assert_exposure_caps(_load_posters(db), sections)
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "section": doc, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.put("/api/sections/{section_key}")
def api_update_section(section_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = require_section_key(section_key)
    ref = db.collection("home_cms_sections").document(key)
    if not ref.get().exists:
        raise HTTPException(status_code=404, detail="section_not_found")
    payload = {**payload, "sectionKey": key}
    doc = normalize_section(payload, key)
    sections = [s for s in _load_sections(db) if s.get("sectionKey") != key] + [doc]
    assert_exposure_caps(_load_posters(db), sections)
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "section": doc, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.delete("/api/sections/{section_key}")
def api_delete_section(section_key: str) -> dict[str, Any]:
    db = get_db()
    key = require_section_key(section_key)
    ref = db.collection("home_cms_sections").document(key)
    if not ref.get().exists:
        raise HTTPException(status_code=404, detail="section_not_found")
    data = ref.get().to_dict() or {}
    data["enabled"] = False
    doc = normalize_section(data, key)
    _snapshot_rollback(db)
    ref.set(doc)
    bundle = _write_bundle(db)
    return {"ok": True, "section": doc, "softDeleted": True, "bundleUpdatedAt": bundle.get("updatedAt")}


@app.get("/api/indexes/{section_key}")
def api_index(section_key: str) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    index_snap = db.collection("home_section_index").document(key).get()
    override_snap = db.collection("home_section_overrides").document(key).get()
    index_data = index_snap.to_dict() if index_snap.exists else {}
    override_data = override_snap.to_dict() if override_snap.exists else {}
    ids = _id_list((index_data or {}).get("recipeIds"))
    titles: dict[str, str] = {}
    thumbs: dict[str, str] = {}
    preview_ids = ids[:40]
    if preview_ids:
        refs = [db.collection("recipes").document(rid) for rid in preview_ids]
        by_id = {snap.id: snap for snap in db.get_all(refs) if snap.exists}
        for rid in preview_ids:
            rsnap = by_id.get(rid)
            if rsnap is None:
                continue
            data = rsnap.to_dict() or {}
            titles[rid] = recipe_title(data) or rid
            thumbs[rid] = _recipe_thumb(data)
    return {
        "ok": True,
        "sectionKey": key,
        "recipeIds": ids,
        "count": len(ids),
        "titles": titles,
        "thumbnails": thumbs,
        "overrides": {
            "pinnedIds": _id_list((override_data or {}).get("pinnedIds")),
            "blockedIds": _id_list((override_data or {}).get("blockedIds")),
        },
    }


def _mutate_index_ids(
    db: Any,
    key: str,
    mutator,
    *,
    pin: Optional[str] = None,
    unpin: Optional[str] = None,
    block: Optional[str] = None,
    unblock: Optional[str] = None,
) -> dict[str, Any]:
    index_ref = db.collection("home_section_index").document(key)
    override_ref = db.collection("home_section_overrides").document(key)
    index_snap = index_ref.get()
    override_snap = override_ref.get()
    ids = _id_list((index_snap.to_dict() or {}).get("recipeIds") if index_snap.exists else [])
    pinned = _id_list((override_snap.to_dict() or {}).get("pinnedIds") if override_snap.exists else [])
    blocked = _id_list((override_snap.to_dict() or {}).get("blockedIds") if override_snap.exists else [])
    ids, pinned, blocked = mutator(ids, pinned, blocked)
    index_ref.set(
        {
            "sectionKey": key,
            "recipeIds": ids,
            "count": len(ids),
            "updatedAt": _now(),
            "updatedBy": "cms_dashboard",
        },
        merge=True,
    )
    override_ref.set(
        {
            "sectionKey": key,
            "pinnedIds": pinned,
            "blockedIds": blocked,
            "updatedAt": _now(),
            "updatedBy": "cms_dashboard",
        },
        merge=True,
    )
    return {"recipeIds": ids, "pinnedIds": pinned, "blockedIds": blocked, "count": len(ids)}


@app.post("/api/indexes/{section_key}/add")
def api_index_add(section_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    recipe_id = sanitize_key(payload.get("recipeId"))
    if not recipe_id:
        raise HTTPException(status_code=400, detail="invalid_recipe_id")
    rsnap = db.collection("recipes").document(recipe_id).get()
    if not rsnap.exists:
        raise HTTPException(status_code=404, detail="recipe_not_found")

    def mutator(ids, pinned, blocked):
        blocked = [x for x in blocked if x != recipe_id]
        if recipe_id not in pinned:
            pinned = [*pinned, recipe_id]
        ids = [recipe_id, *[x for x in ids if x != recipe_id]]
        return ids, pinned, blocked

    result = _mutate_index_ids(db, key, mutator)
    return {"ok": True, **result}


@app.post("/api/indexes/{section_key}/remove")
def api_index_remove(section_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    recipe_id = sanitize_key(payload.get("recipeId"))
    if not recipe_id:
        raise HTTPException(status_code=400, detail="invalid_recipe_id")

    def mutator(ids, pinned, blocked):
        pinned = [x for x in pinned if x != recipe_id]
        if recipe_id not in blocked:
            blocked = [*blocked, recipe_id]
        ids = [x for x in ids if x != recipe_id]
        return ids, pinned, blocked

    result = _mutate_index_ids(db, key, mutator)
    return {"ok": True, **result}


@app.post("/api/indexes/{section_key}/unpin")
def api_index_unpin(section_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    recipe_id = sanitize_key(payload.get("recipeId"))

    def mutator(ids, pinned, blocked):
        pinned = [x for x in pinned if x != recipe_id]
        return ids, pinned, blocked

    return {"ok": True, **_mutate_index_ids(db, key, mutator)}


@app.post("/api/indexes/{section_key}/unblock")
def api_index_unblock(section_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    recipe_id = sanitize_key(payload.get("recipeId"))

    def mutator(ids, pinned, blocked):
        blocked = [x for x in blocked if x != recipe_id]
        if recipe_id and recipe_id not in ids:
            ids = [*ids, recipe_id]
        return ids, pinned, blocked

    return {"ok": True, **_mutate_index_ids(db, key, mutator)}


@app.post("/api/indexes/{section_key}/rebuild")
def api_rebuild(section_key: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    db = get_db()
    key = sanitize_key(section_key)
    confirm = bool((payload or {}).get("confirm"))
    if not confirm:
        raise HTTPException(status_code=400, detail="confirm_required")
    section_snap = db.collection("home_cms_sections").document(key).get()
    match_rules = {}
    if section_snap.exists:
        match_rules = (section_snap.to_dict() or {}).get("matchRules") or {}
    if not match_rules:
        raise HTTPException(
            status_code=400,
            detail="manual_index_use_add_remove",
        )
    override_snap = db.collection("home_section_overrides").document(key).get()
    pinned = _id_list((override_snap.to_dict() or {}).get("pinnedIds") if override_snap.exists else [])
    blocked = set(
        _id_list((override_snap.to_dict() or {}).get("blockedIds") if override_snap.exists else [])
    )
    matched: list[str] = []
    scanned = 0
    last = None
    while scanned < REBUILD_SCAN_CAP:
        query = db.collection("recipes").order_by("__name__").limit(300)
        if last is not None:
            query = query.start_after(last)
        snaps = list(query.stream())
        if not snaps:
            break
        for snap in snaps:
            scanned += 1
            data = snap.to_dict() or {}
            if not is_visible_completed(data):
                continue
            if snap.id in blocked or snap.id in pinned:
                continue
            if matches_rule(data, match_rules):
                matched.append(snap.id)
        last = snaps[-1]
        if len(snaps) < 300:
            break
    ids = [*[p for p in pinned if p not in blocked], *[m for m in matched if m not in blocked]]
    # 중복 제거, 상한 200
    seen: set[str] = set()
    unique: list[str] = []
    for rid in ids:
        if rid in seen:
            continue
        seen.add(rid)
        unique.append(rid)
        if len(unique) >= 200:
            break
    db.collection("home_section_index").document(key).set(
        {
            "sectionKey": key,
            "recipeIds": unique,
            "count": len(unique),
            "updatedAt": _now(),
            "updatedBy": "cms_dashboard_rebuild",
        },
        merge=True,
    )
    return {"ok": True, "sectionKey": key, "count": len(unique), "scanned": scanned}


@app.get("/api/recipes/search")
def api_recipe_search(q: str = "", section_key: str = "") -> dict[str, Any]:
    query = (q or "").strip()
    if len(query) < 2:
        return {"ok": True, "recipes": []}
    db = get_db()
    hits: list[dict[str, Any]] = []
    seen: set[str] = set()

    def _add(rid: str, data: dict[str, Any]) -> None:
        if rid in seen:
            return
        seen.add(rid)
        hits.append(_recipe_summary(rid, data))

    if len(query) >= 16 and " " not in query:
        snap = db.collection("recipes").document(query).get()
        if snap.exists:
            return {"ok": True, "recipes": [_recipe_summary(snap.id, snap.to_dict() or {})]}

    key = sanitize_key(section_key)
    if key:
        index_snap = db.collection("home_section_index").document(key).get()
        ids = _id_list((index_snap.to_dict() or {}).get("recipeIds") if index_snap.exists else [])
        needle = query.lower()
        refs = [db.collection("recipes").document(rid) for rid in ids[:120]]
        if refs:
            for rsnap in db.get_all(refs):
                if not rsnap.exists:
                    continue
                data = rsnap.to_dict() or {}
                title = recipe_title(data)
                if needle in title.lower() or needle == rsnap.id.lower():
                    _add(rsnap.id, data)
                if len(hits) >= 20:
                    return {"ok": True, "recipes": hits, "scoped": True}

    scanned = 0
    needle = query.lower()
    last = None
    while scanned < SEARCH_SCAN_CAP and len(hits) < 20:
        ref = db.collection("recipes").order_by("__name__").limit(80)
        if last is not None:
            ref = ref.start_after(last)
        snaps = list(ref.stream())
        if not snaps:
            break
        for snap in snaps:
            scanned += 1
            data = snap.to_dict() or {}
            if not is_visible_completed(data):
                continue
            title = recipe_title(data)
            if needle in title.lower() or needle == snap.id.lower():
                _add(snap.id, data)
                if len(hits) >= 20:
                    break
        last = snaps[-1]
        if len(snaps) < 80:
            break
    return {"ok": True, "recipes": hits, "scanned": scanned}


@app.post("/api/rollback")
def api_rollback() -> dict[str, Any]:
    db = get_db()
    rollback = db.collection("home_cms").document("rollback").get()
    if not rollback.exists:
        raise HTTPException(status_code=404, detail="no_rollback")
    data = rollback.to_dict() or {}
    current = db.collection("home_cms").document("bundle").get()
    if current.exists:
        db.collection("home_cms").document("rollback").set(current.to_dict() or {})
    posters = data.get("posters") if isinstance(data.get("posters"), list) else []
    sections = data.get("sections") if isinstance(data.get("sections"), list) else []
    batch = db.batch()
    for poster in posters:
        if not isinstance(poster, dict) or not poster.get("id"):
            continue
        batch.set(db.collection("home_cms_posters").document(str(poster["id"])), poster)
    for section in sections:
        if not isinstance(section, dict):
            continue
        key = str(section.get("sectionKey") or "")
        if not key:
            continue
        batch.set(db.collection("home_cms_sections").document(key), section)
    batch.commit()
    bundle = _write_bundle(db, updated_by="rollback")
    return {"ok": True, "bundleUpdatedAt": bundle.get("updatedAt")}


def main() -> None:
    import uvicorn

    uvicorn.run(
        "app:app",
        host=HOST,
        port=PORT,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
