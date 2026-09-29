"""로컬 오류 관찰 대시보드 서버 (Admin SDK, 무인증, 127.0.0.1 전용).

Run:
  python analytics/error_dashboard/server.py
→ http://127.0.0.1:8765/
"""

from __future__ import annotations

import base64
import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

import firebase_admin
from firebase_admin import credentials, firestore
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from google.cloud.firestore_v1.base_query import FieldFilter
from google.cloud.firestore_v1.document import DocumentSnapshot

ROOT = Path(__file__).resolve().parents[2]
CRED = ROOT / "backend" / "firebase-service-account.json"
STATIC_DIR = Path(__file__).resolve().parent
PAGE_DEFAULT = 50
PAGE_MAX = 100
SAMPLE_LIMIT = 500
# equality + orderBy 복합 인덱스 회피용 스캔 상한 (로컬 대시보드)
SCAN_CAP = 10000
KST = timezone(timedelta(hours=9))

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("error_dashboard")

app = FastAPI(title="Yorigo Error Dashboard", docs_url=None, redoc_url=None)

# 탭별 기기 필드 (없으면 기기 필터 무시)
DEVICE_FIELD_BY_COLLECTION: dict[str, Optional[str]] = {
    "recipes": "appPlatform",
    "parsing_failures": "appPlatform",
    "recipe_reports": None,
    "reports": None,
    "app_feedback": "platform",
    "fridge_scan_reports": "appPlatform",
    "ingredient_price_issue_reports": None,
    "moderation_alerts": None,
    "purchase_verification_queue": None,
}


def get_db():
    if not firebase_admin._apps:
        if not CRED.exists():
            raise RuntimeError(f"Missing service account: {CRED}")
        firebase_admin.initialize_app(credentials.Certificate(str(CRED)))
    return firestore.client()


def serialize_value(v: Any) -> Any:
    if v is None:
        return None
    if hasattr(v, "isoformat") and callable(getattr(v, "isoformat")) and not isinstance(v, str):
        try:
            if getattr(v, "tzinfo", None) is None:
                return v.replace(tzinfo=timezone.utc).isoformat()
            return v.isoformat()
        except Exception:
            return str(v)
    if hasattr(v, "timestamp") and hasattr(v, "to_datetime"):
        try:
            return v.isoformat()
        except Exception:
            pass
    if isinstance(v, dict):
        return {k: serialize_value(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [serialize_value(x) for x in v]
    if hasattr(v, "latitude") and hasattr(v, "longitude"):
        return {"lat": v.latitude, "lng": v.longitude}
    if hasattr(v, "path") and hasattr(v, "id"):
        try:
            return v.path
        except Exception:
            return str(v)
    return v


def serialize_doc(snap: DocumentSnapshot) -> dict[str, Any]:
    data = snap.to_dict() or {}
    out = {"id": snap.id}
    for k, v in data.items():
        out[k] = serialize_value(v)
    return out


def encode_cursor(snap: DocumentSnapshot, order_field: str) -> str:
    raw = snap.to_dict() or {}
    order_val = serialize_value(raw.get(order_field))
    payload = {"id": snap.id, "o": order_val}
    return base64.urlsafe_b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")


def decode_cursor(cursor: str) -> dict[str, Any]:
    try:
        return json.loads(base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8"))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"invalid cursor: {e}") from e


def parse_order_value(raw: Any):
    if raw is None:
        return None
    if isinstance(raw, str):
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except Exception:
            return raw
    return raw


def parse_date_bound(value: Optional[str], *, end: bool) -> Optional[datetime]:
    if not value:
        return None
    raw = value.strip()
    if not raw:
        return None
    try:
        day = datetime.strptime(raw[:10], "%Y-%m-%d").replace(tzinfo=KST)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"invalid date: {value}") from e
    if end:
        return day.replace(hour=23, minute=59, second=59, microsecond=999999)
    return day.replace(hour=0, minute=0, second=0, microsecond=0)


def normalize_device(device: Optional[str]) -> Optional[str]:
    if not device:
        return None
    d = device.strip().lower()
    if d in ("", "all", "전체"):
        return None
    if d in ("ios", "iphone", "ipad"):
        return "ios"
    if d in ("android", "andro"):
        return "android"
    raise HTTPException(status_code=400, detail="device must be ios|android|all")


def device_matches(stored: Any, want: str) -> bool:
    s = str(stored or "").strip().lower()
    if want == "ios":
        return s in ("ios", "iphone", "ipad") or s.startswith("ios")
    if want == "android":
        return s == "android" or s.startswith("android")
    return True


def enrich_recipe_app_platform(items: list[dict[str, Any]]) -> None:
    """과거 error recipes 는 appPlatform 이 없을 수 있어 parsing_failures 로 보강."""
    missing = [row for row in items if not str(row.get("appPlatform") or "").strip()]
    if not missing:
        return
    db = get_db()
    by_id: dict[str, str] = {}
    by_url: dict[str, str] = {}

    ids = [str(r.get("id") or "") for r in missing if r.get("id")]
    for i in range(0, len(ids), 30):
        chunk = [x for x in ids[i : i + 30] if x]
        if not chunk:
            continue
        try:
            for snap in (
                db.collection("parsing_failures")
                .where(filter=FieldFilter("recipeId", "in", chunk))
                .select(["recipeId", "appPlatform", "sourceUrl"])
                .stream()
            ):
                data = snap.to_dict() or {}
                plat = str(data.get("appPlatform") or "").strip()
                if not plat:
                    continue
                rid = str(data.get("recipeId") or "").strip()
                url = str(data.get("sourceUrl") or "").strip()
                if rid and rid not in by_id:
                    by_id[rid] = plat
                if url and url not in by_url:
                    by_url[url] = plat
        except Exception as e:
            logger.warning("enrich by recipeId failed: %s", e)

    still = []
    for row in missing:
        rid = str(row.get("id") or "")
        if rid in by_id:
            row["appPlatform"] = by_id[rid]
            row["_appPlatformSource"] = "parsing_failures"
            continue
        still.append(row)

    urls = []
    for row in still:
        url = str(row.get("sourceUrl") or "")
        if not url and isinstance(row.get("source"), dict):
            url = str(row["source"].get("url") or "")
        if url:
            urls.append(url)
    urls = list(dict.fromkeys(urls))
    for i in range(0, len(urls), 30):
        chunk = urls[i : i + 30]
        if not chunk:
            continue
        try:
            for snap in (
                db.collection("parsing_failures")
                .where(filter=FieldFilter("sourceUrl", "in", chunk))
                .select(["sourceUrl", "appPlatform"])
                .stream()
            ):
                data = snap.to_dict() or {}
                plat = str(data.get("appPlatform") or "").strip()
                url = str(data.get("sourceUrl") or "").strip()
                if plat and url and url not in by_url:
                    by_url[url] = plat
        except Exception as e:
            logger.warning("enrich by sourceUrl failed: %s", e)

    for row in still:
        url = str(row.get("sourceUrl") or "")
        if not url and isinstance(row.get("source"), dict):
            url = str(row["source"].get("url") or "")
        if url in by_url:
            row["appPlatform"] = by_url[url]
            row["_appPlatformSource"] = "parsing_failures"


def _coerce_dt(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value
    if hasattr(value, "timestamp") and callable(getattr(value, "timestamp", None)):
        try:
            # DatetimeWithNanoseconds
            return value.replace(tzinfo=getattr(value, "tzinfo", None) or timezone.utc)
        except Exception:
            pass
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except Exception:
            return None
    return None


def _in_date_range(value: Any, start_dt: Optional[datetime], end_dt: Optional[datetime]) -> bool:
    if start_dt is None and end_dt is None:
        return True
    dt = _coerce_dt(value)
    if dt is None:
        return False
    if start_dt is not None and dt < start_dt:
        return False
    if end_dt is not None and dt > end_dt:
        return False
    return True


def _sort_docs(
    docs: list[DocumentSnapshot],
    order_field: str,
    order_dir: str,
) -> list[DocumentSnapshot]:
    """order_field 기준 메모리 정렬. 값 없는 문서는 항상 뒤로."""

    def sort_key(doc: DocumentSnapshot) -> tuple[float, str]:
        data = doc.to_dict() or {}
        dt = _coerce_dt(data.get(order_field))
        if dt is None:
            sentinel = float("-inf") if order_dir == "desc" else float("inf")
            return (sentinel, doc.id)
        return (dt.timestamp(), doc.id)

    return sorted(docs, key=sort_key, reverse=(order_dir == "desc"))


def _apply_cursor(
    docs: list[DocumentSnapshot],
    cursor: Optional[str],
) -> list[DocumentSnapshot]:
    if not cursor or not docs:
        return docs
    try:
        c = decode_cursor(cursor)
        cid = str(c.get("id") or "")
    except Exception:
        return docs
    if not cid:
        return docs
    for i, doc in enumerate(docs):
        if doc.id == cid:
            return docs[i + 1 :]
    return docs


def run_page(
    collection_name: str,
    *,
    order_field: str = "createdAt",
    filters: Optional[list[tuple[str, str, Any]]] = None,
    limit: int = PAGE_DEFAULT,
    cursor: Optional[str] = None,
    order: str = "desc",
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    """페이지 조회.

    equality 필터 + orderBy 복합 인덱스가 없어도 되도록,
    필터가 있으면 Firestore에서는 where만 쓰고 정렬/날짜는 메모리에서 처리한다.
    (예: recipes status==error + updatedAt ASC 인덱스는 없음)
    """
    db = get_db()
    limit = max(1, min(int(limit), PAGE_MAX))
    order_dir = (order or "desc").strip().lower()
    if order_dir not in ("asc", "desc"):
        raise HTTPException(status_code=400, detail="order must be asc|desc")

    want_device = normalize_device(device)
    device_field = DEVICE_FIELD_BY_COLLECTION.get(collection_name)
    warnings: list[str] = []

    start_dt = parse_date_bound(date_from, end=False)
    end_dt = parse_date_bound(date_to, end=True)
    if start_dt and end_dt and start_dt > end_dt:
        raise HTTPException(status_code=400, detail="dateFrom must be <= dateTo")

    date_in_memory = start_dt is not None or end_dt is not None
    if date_in_memory:
        warnings.append("date_filter_in_memory")

    eq_filters = list(filters or [])
    enrich_then_filter = collection_name == "recipes" and want_device is not None
    device_client_filter = (
        want_device is not None and bool(device_field) and not enrich_then_filter
    )
    if want_device and not device_field and not enrich_then_filter:
        warnings.append("device_filter_not_supported")

    # equality where만 Firestore에 적용 → 단일 필드 자동 인덱스로 충분
    q = db.collection(collection_name)
    for field, op, value in eq_filters:
        q = q.where(filter=FieldFilter(field, op, value))

    # 필터/날짜/기기/정렬방향(ASC) 때문에 복합 인덱스가 필요할 수 있으면
    # orderBy 없이 스캔 후 메모리 정렬한다.
    needs_memory_sort = bool(eq_filters) or date_in_memory or device_client_filter or enrich_then_filter
    # ASC는 status+updatedAt DESC 인덱스와 안 맞으므로 equality 있을 때 항상 메모리 정렬
    if eq_filters:
        needs_memory_sort = True

    try:
        if needs_memory_sort:
            warnings.append("sort_in_memory")
            raw_docs = list(q.limit(SCAN_CAP).stream())
            if len(raw_docs) >= SCAN_CAP:
                warnings.append(f"scan_capped_{SCAN_CAP}")
        else:
            direction = (
                firestore.Query.ASCENDING
                if order_dir == "asc"
                else firestore.Query.DESCENDING
            )
            q_ordered = q.order_by(order_field, direction=direction)
            if cursor:
                c = decode_cursor(cursor)
                snap = db.collection(collection_name).document(str(c.get("id"))).get()
                if snap.exists:
                    q_ordered = q_ordered.start_after(snap)
            raw_docs = list(q_ordered.limit(limit).stream())
    except Exception as e:
        msg = str(e)
        logger.exception("Firestore query failed collection=%s", collection_name)
        if "requires an index" in msg or "FailedPrecondition" in type(e).__name__:
            # 최후 폴백: orderBy 제거 스캔
            warnings.append("index_fallback_scan")
            try:
                raw_docs = list(q.limit(SCAN_CAP).stream())
                needs_memory_sort = True
            except Exception as e2:
                raise HTTPException(
                    status_code=400,
                    detail=f"Firestore 조회 실패(인덱스/쿼리): {str(e2)[:300]}",
                ) from e2
        else:
            raise HTTPException(status_code=500, detail=f"query failed: {msg[:400]}") from e

    selected: list[DocumentSnapshot] = []
    for doc in raw_docs:
        data = doc.to_dict() or {}
        if date_in_memory and not _in_date_range(data.get(order_field), start_dt, end_dt):
            continue
        if device_client_filter and not device_matches(data.get(device_field), want_device or ""):
            continue
        selected.append(doc)

    if needs_memory_sort:
        selected = _sort_docs(selected, order_field, order_dir)
        selected = _apply_cursor(selected, cursor)

    next_cursor: Optional[str] = None

    if collection_name == "recipes":
        # 기기 필터 시 보강 매칭률이 낮을 수 있어 후보를 넉넉히 잡는다
        pool_n = min(len(selected), max(limit * 25, limit) if enrich_then_filter else limit)
        pool = selected[:pool_n]
        items = [serialize_doc(d) for d in pool]
        enrich_recipe_app_platform(items)
        if want_device:
            kept: list[dict[str, Any]] = []
            last_kept_id: Optional[str] = None
            for row in items:
                if device_matches(row.get("appPlatform"), want_device):
                    kept.append(row)
                    last_kept_id = row["id"]
                    if len(kept) >= limit:
                        break
            items = kept
            if len(items) >= limit and last_kept_id:
                last_idx = next((i for i, d in enumerate(selected) if d.id == last_kept_id), -1)
                if 0 <= last_idx < len(selected) - 1:
                    next_cursor = encode_cursor(selected[last_idx], order_field)
                elif pool_n < len(selected):
                    next_cursor = encode_cursor(pool[-1], order_field)
        else:
            items = items[:limit]
            if needs_memory_sort and len(selected) > limit:
                next_cursor = encode_cursor(selected[limit - 1], order_field)
            elif not needs_memory_sort and len(selected) >= limit:
                next_cursor = encode_cursor(selected[-1], order_field)
    else:
        page_docs = selected[:limit] if needs_memory_sort else selected
        items = [serialize_doc(d) for d in page_docs]
        if needs_memory_sort and len(selected) > limit:
            next_cursor = encode_cursor(selected[limit - 1], order_field)
        elif not needs_memory_sort and len(selected) >= limit:
            next_cursor = encode_cursor(selected[-1], order_field)

    return {
        "items": items,
        "nextCursor": next_cursor,
        "count": len(items),
        "order": order_dir,
        "dateFrom": date_from,
        "dateTo": date_to,
        "device": want_device or "all",
        "warnings": warnings,
    }


def safe_count(
    collection_name: str,
    filters: Optional[list[tuple[str, str, Any]]] = None,
    *,
    order_field: str = "createdAt",
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    """건수. 날짜/기기 필터는 인덱스 회피를 위해 샘플 스캔 후 메모리 필터(근사)."""
    db = get_db()
    want_device = normalize_device(device)
    device_field = DEVICE_FIELD_BY_COLLECTION.get(collection_name)
    start_dt = parse_date_bound(date_from, end=False)
    end_dt = parse_date_bound(date_to, end=True)
    needs_scan = bool(want_device or start_dt or end_dt)

    q = db.collection(collection_name)
    for field, op, value in filters or []:
        q = q.where(filter=FieldFilter(field, op, value))

    if not needs_scan:
        try:
            count = q.count().get()[0][0].value
            return {"count": int(count), "error": None}
        except Exception as e:
            try:
                n = sum(1 for _ in q.select([]).stream())
                return {"count": n, "error": None}
            except Exception as e2:
                return {"count": None, "error": f"{e}; fallback: {e2}"}

    if want_device and not device_field and collection_name != "recipes":
        return {"count": None, "error": None, "deviceIgnored": True}

    select_fields = [order_field]
    if device_field:
        select_fields.append(device_field)
    # recipes 기기 보강은 count에서 생략(비용). appPlatform 있는 문서만 기기 카운트.
    try:
        n = 0
        scanned = 0
        for snap in q.select(select_fields).limit(2000).stream():
            scanned += 1
            data = snap.to_dict() or {}
            if not _in_date_range(data.get(order_field), start_dt, end_dt):
                continue
            if want_device:
                plat = data.get(device_field) if device_field else None
                if not device_matches(plat, want_device):
                    continue
            n += 1
        return {
            "count": n,
            "error": None,
            "approx": scanned >= 2000,
            "scanned": scanned,
        }
    except Exception as e:
        return {"count": None, "error": str(e)}

def sample_dist(
    collection_name: str,
    field: str,
    *,
    order_field: str = "createdAt",
    sample_limit: int = SAMPLE_LIMIT,
    order: str = "desc",
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    page = run_page(
        collection_name,
        order_field=order_field,
        limit=min(sample_limit, PAGE_MAX),
        order=order,
        date_from=date_from,
        date_to=date_to,
        device=device,
    )
    dist: dict[str, int] = {}
    for row in page["items"]:
        key = row.get(field)
        if key is None or key == "":
            key = "(empty)"
        key = str(key)
        dist[key] = dist.get(key, 0) + 1
    return {
        "dist": dist,
        "sampleSize": len(page["items"]),
        "error": None,
        "warnings": page.get("warnings") or [],
    }


def common_list_params(
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Optional[str]]:
    return {
        "order": order,
        "date_from": dateFrom,
        "date_to": dateTo,
        "device": device,
    }


@app.on_event("startup")
def _startup() -> None:
    get_db()
    logger.info("Firebase Admin ready (local dashboard, no auth)")


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {"ok": True, "auth": False, "bind": "127.0.0.1"}


@app.get("/api/summary")
def summary(
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    kw = {"order": order, "date_from": dateFrom, "date_to": dateTo, "device": device}
    return {
        "filters": {
            "order": order,
            "dateFrom": dateFrom,
            "dateTo": dateTo,
            "device": normalize_device(device) or "all",
        },
        "errorRecipes": safe_count(
            "recipes",
            [("status", "==", "error")],
            order_field="updatedAt",
            date_from=dateFrom,
            date_to=dateTo,
            device=device,
        ),
        "parsingFailures": safe_count(
            "parsing_failures", date_from=dateFrom, date_to=dateTo, device=device
        ),
        "parsingOpen": safe_count(
            "parsing_failures",
            [("status", "==", "open")],
            date_from=dateFrom,
            date_to=dateTo,
            device=device,
        ),
        "recipeReports": safe_count(
            "recipe_reports", date_from=dateFrom, date_to=dateTo, device=device
        ),
        "reports": safe_count("reports", date_from=dateFrom, date_to=dateTo, device=device),
        "reportsPending": safe_count(
            "reports",
            [("status", "==", "pending")],
            date_from=dateFrom,
            date_to=dateTo,
            device=device,
        ),
        "appFeedback": safe_count(
            "app_feedback", date_from=dateFrom, date_to=dateTo, device=device
        ),
        "fridgeScan": safe_count(
            "fridge_scan_reports", date_from=dateFrom, date_to=dateTo, device=device
        ),
        "priceIssues": safe_count(
            "ingredient_price_issue_reports",
            date_from=dateFrom,
            date_to=dateTo,
            device=device,
        ),
        "moderation": safe_count(
            "moderation_alerts", date_from=dateFrom, date_to=dateTo, device=device
        ),
        "purchaseQueue": safe_count(
            "purchase_verification_queue",
            date_from=dateFrom,
            date_to=dateTo,
            device=device,
        ),
        "distributions": {
            "parsingReason": sample_dist("parsing_failures", "reason", **kw),
            "parsingPlatform": sample_dist("parsing_failures", "platform", **kw),
            "reportsType": sample_dist("reports", "type", **kw),
        },
    }


@app.get("/api/error-recipes")
def error_recipes(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    return run_page(
        "recipes",
        order_field="updatedAt",
        filters=[("status", "==", "error")],
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/parsing-failures")
def parsing_failures(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    status: Optional[str] = None,
    reason: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    filters: list[tuple[str, str, Any]] = []
    if status:
        filters.append(("status", "==", status))
    elif reason:
        filters.append(("reason", "==", reason))
    return run_page(
        "parsing_failures",
        order_field="createdAt",
        filters=filters,
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/recipe-reports")
def recipe_reports(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    return run_page(
        "recipe_reports",
        order_field="createdAt",
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/reports")
def reports(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    status: Optional[str] = None,
    type: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    filters: list[tuple[str, str, Any]] = []
    if status:
        filters.append(("status", "==", status))
    elif type:
        filters.append(("type", "==", type))
    return run_page(
        "reports",
        order_field="createdAt",
        filters=filters,
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/app-feedback")
def app_feedback(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    return run_page(
        "app_feedback",
        order_field="createdAt",
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/fridge-scan-reports")
def fridge_scan(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    status: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    filters: list[tuple[str, str, Any]] = []
    if status:
        filters.append(("status", "==", status))
    return run_page(
        "fridge_scan_reports",
        order_field="createdAt",
        filters=filters,
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/price-issues")
def price_issues(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    return run_page(
        "ingredient_price_issue_reports",
        order_field="createdAt",
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/moderation-alerts")
def moderation(
    limit: int = Query(PAGE_DEFAULT, ge=1, le=PAGE_MAX),
    cursor: Optional[str] = None,
    eventType: Optional[str] = None,
    order: str = Query("desc"),
    dateFrom: Optional[str] = None,
    dateTo: Optional[str] = None,
    device: Optional[str] = None,
) -> dict[str, Any]:
    filters: list[tuple[str, str, Any]] = []
    if eventType:
        filters.append(("eventType", "==", eventType))
    return run_page(
        "moderation_alerts",
        order_field="createdAt",
        filters=filters,
        limit=limit,
        cursor=cursor,
        order=order,
        date_from=dateFrom,
        date_to=dateTo,
        device=device,
    )


@app.get("/api/doc/{collection_name}/{doc_id}")
def get_doc(collection_name: str, doc_id: str) -> dict[str, Any]:
    allowed = {
        "recipes",
        "parsing_failures",
        "recipe_reports",
        "reports",
        "app_feedback",
        "fridge_scan_reports",
        "ingredient_price_issue_reports",
        "moderation_alerts",
        "purchase_verification_queue",
    }
    if collection_name not in allowed:
        raise HTTPException(status_code=400, detail="collection not allowed")
    snap = get_db().collection(collection_name).document(doc_id).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="not found")
    return serialize_doc(snap)


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/styles.css")
def styles() -> FileResponse:
    return FileResponse(STATIC_DIR / "styles.css")


@app.get("/js/{path:path}")
def js_files(path: str) -> FileResponse:
    target = (STATIC_DIR / "js" / path).resolve()
    if not str(target).startswith(str((STATIC_DIR / "js").resolve())):
        raise HTTPException(status_code=400, detail="bad path")
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    return FileResponse(target)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8765, reload=False)
