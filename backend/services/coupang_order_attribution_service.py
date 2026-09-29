"""쿠팡 파트너스 주문 리포트를 subparam → uid로 붙인다."""

from __future__ import annotations

import logging
import os
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import urlencode

import requests

logger = logging.getLogger(__name__)

ORDERS_COLLECTION = "coupang_attributed_orders"
USER_ORDERS_SUBCOLLECTION = "coupang_orders"
REPORT_PAGE_SIZE = 1000
_YORIGO_SUBPARAM_RE = re.compile(r"^yr_[A-Za-z0-9]{10,16}$")

ReportFetcher = Callable[[str, str, str, int], List[Dict[str, Any]]]


class OrderSyncStats:
    def __init__(self) -> None:
        self.fetched = 0
        self.upserted = 0
        self.matched = 0
        self.unmatched = 0
        self.no_subparam = 0
        self.cancelled = 0
        self.lookback_days = 0

    def as_dict(self) -> Dict[str, int]:
        return {
            "fetched": self.fetched,
            "upserted": self.upserted,
            "matched": self.matched,
            "unmatched": self.unmatched,
            "no_subparam": self.no_subparam,
            "cancelled": self.cancelled,
            "lookback_days": self.lookback_days,
        }


def extract_report_subparam(row: Dict[str, Any]) -> str:
    """주문/광고 리포트 한 행에서 subParam을 꺼낸다."""
    for key in ("subParam", "subparam", "sub_param"):
        text = str(row.get(key) or "").strip()
        if text:
            return text
    return ""


def is_yorigo_subparam(value: Optional[str]) -> bool:
    token = (value or "").strip()
    return bool(_YORIGO_SUBPARAM_RE.match(token))


def attributed_order_doc_id(row: Dict[str, Any]) -> str:
    date = str(row.get("date") or "unknown")
    order_id = str(row.get("orderId") or row.get("order_id") or "unknown")
    product_id = str(row.get("productId") or row.get("product_id") or "na")
    return f"{date}_{order_id}_{product_id}"


def _as_optional_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _as_optional_number(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _as_optional_int(value: Any) -> Optional[int]:
    number = _as_optional_number(value)
    if number is None:
        return None
    return int(number)


def _server_timestamp() -> Any:
    try:
        from firebase_admin import firestore as admin_firestore

        return admin_firestore.SERVER_TIMESTAMP
    except Exception:
        return "server_timestamp"


def _query_desc() -> Any:
    from firebase_admin import firestore as admin_firestore

    return admin_firestore.Query.DESCENDING


def lookback_date_range(lookback_days: int, now: Optional[datetime] = None) -> tuple[str, str]:
    current = now or datetime.now(timezone.utc)
    end = current.date()
    start = end - timedelta(days=max(1, lookback_days) - 1)
    return start.strftime("%Y%m%d"), end.strftime("%Y%m%d")


def fetch_partner_report_page(
    report_path: str,
    start_date: str,
    end_date: str,
    page: int,
    *,
    access_key: str,
    secret_key: str,
    sub_id: str = "",
    timeout_seconds: float = 30.0,
) -> List[Dict[str, Any]]:
    """파트너스 리포트 한 페이지를 조회한다."""
    query: Dict[str, Any] = {
        "startDate": start_date,
        "endDate": end_date,
        "page": page,
    }
    if sub_id:
        query["subId"] = sub_id
    qs = urlencode(query)
    api_url = (
        "https://api-gateway.coupang.com/v2/providers/affiliate_open_api"
        f"/apis/openapi/v1/{report_path}?{qs}"
    )
    from services.coupang_service import generate_coupang_hmac

    authorization = generate_coupang_hmac("GET", api_url, secret_key, access_key)
    response = requests.get(
        api_url,
        headers={
            "Authorization": authorization,
            "Content-Type": "application/json",
        },
        timeout=timeout_seconds,
    )
    if response.status_code != 200:
        raise RuntimeError(
            f"coupang report HTTP {response.status_code} path={report_path}"
        )
    payload = response.json()
    if str(payload.get("rCode")) != "0":
        raise RuntimeError(
            f"coupang report rCode={payload.get('rCode')} "
            f"rMessage={payload.get('rMessage')} path={report_path}"
        )
    data = payload.get("data") or []
    if not isinstance(data, list):
        return []
    return [row for row in data if isinstance(row, dict)]


class CoupangOrderAttributionService:
    """주문/취소 리포트를 읽어 계정에 매칭한다."""

    def __init__(
        self,
        db: Any,
        *,
        access_key: Optional[str] = None,
        secret_key: Optional[str] = None,
        sub_id: Optional[str] = None,
        report_fetcher: Optional[ReportFetcher] = None,
    ) -> None:
        self.db = db
        self.access_key = (access_key if access_key is not None else os.getenv("COUPANG_ACCESS_KEY", "")).strip()
        self.secret_key = (secret_key if secret_key is not None else os.getenv("COUPANG_SECRET_KEY", "")).strip()
        self.sub_id = (
            sub_id
            if sub_id is not None
            else os.getenv("COUPANG_PARTNER_SUBID", "YorigoMobile")
        ).strip()
        self._report_fetcher = report_fetcher
        self._uid_cache: Dict[str, Optional[str]] = {}

    def has_credentials(self) -> bool:
        return bool(self.access_key and self.secret_key and self.db is not None)

    def sync_recent_window(self, lookback_days: Optional[int] = None) -> OrderSyncStats:
        days = lookback_days
        if days is None:
            days = int(os.getenv("COUPANG_ORDER_SYNC_LOOKBACK_DAYS", "7"))
        days = max(1, min(days, 30))
        start_date, end_date = lookback_date_range(days)
        stats = OrderSyncStats()
        stats.lookback_days = days
        if not self.has_credentials():
            logger.warning("[CoupangOrderSync] 키 또는 Firestore가 없어 건너뜀")
            return stats

        rows: List[Dict[str, Any]] = []
        for path, source, cancelled in (
            ("reports/orders", "orders", False),
            ("reports/ads/orders", "ads_orders", False),
            ("reports/cancels", "cancels", True),
        ):
            try:
                fetched = self._fetch_all_pages(path, start_date, end_date)
            except Exception:
                logger.exception("[CoupangOrderSync] %s 조회 실패", path)
                continue
            for row in fetched:
                row = dict(row)
                row["_source"] = source
                row["_cancelled"] = cancelled
                rows.append(row)

        stats.fetched = len(rows)
        for row in rows:
            self._upsert_row(row, stats)
        logger.info("[CoupangOrderSync] 완료 %s", stats.as_dict())
        return stats

    def list_user_orders(self, uid: str, limit: int = 50) -> List[Dict[str, Any]]:
        if self.db is None or not uid:
            return []
        snaps = (
            self.db.collection("users")
            .document(uid)
            .collection(USER_ORDERS_SUBCOLLECTION)
            .order_by("date", direction=_query_desc())
            .limit(max(1, min(limit, 100)))
            .stream()
        )
        items: List[Dict[str, Any]] = []
        for snap in snaps:
            data = snap.to_dict() or {}
            data["order_id"] = str(data.get("orderId") or snap.id)
            items.append(data)
        return items

    def list_recent_orders(self, limit: int = 50) -> List[Dict[str, Any]]:
        if self.db is None:
            return []
        snaps = (
            self.db.collection(ORDERS_COLLECTION)
            .order_by("date", direction=_query_desc())
            .limit(max(1, min(limit, 100)))
            .stream()
        )
        items: List[Dict[str, Any]] = []
        for snap in snaps:
            data = snap.to_dict() or {}
            data["order_id"] = str(data.get("orderId") or snap.id)
            items.append(data)
        return items

    def _fetch_all_pages(
        self,
        report_path: str,
        start_date: str,
        end_date: str,
    ) -> List[Dict[str, Any]]:
        rows: List[Dict[str, Any]] = []
        page = 0
        while page < 20:
            if self._report_fetcher is not None:
                chunk = self._report_fetcher(report_path, start_date, end_date, page)
            else:
                chunk = fetch_partner_report_page(
                    report_path,
                    start_date,
                    end_date,
                    page,
                    access_key=self.access_key,
                    secret_key=self.secret_key,
                    sub_id=self.sub_id,
                )
            rows.extend(chunk)
            if len(chunk) < REPORT_PAGE_SIZE:
                break
            page += 1
            time.sleep(0.2)
        return rows

    def _lookup_uid(self, subparam: str) -> Optional[str]:
        if subparam in self._uid_cache:
            return self._uid_cache[subparam]
        uid: Optional[str] = None
        try:
            snaps = (
                self.db.collection("users")
                .where("coupangSubparam", "==", subparam)
                .limit(1)
                .stream()
            )
            for snap in snaps:
                uid = snap.id
                break
        except Exception:
            logger.exception("[CoupangOrderSync] subparam 조회 실패 token=%s", subparam)
        self._uid_cache[subparam] = uid
        return uid

    def _upsert_row(self, row: Dict[str, Any], stats: OrderSyncStats) -> None:
        doc_id = attributed_order_doc_id(row)
        subparam = extract_report_subparam(row)
        cancelled = bool(row.get("_cancelled"))
        source = str(row.get("_source") or "orders")
        uid: Optional[str] = None
        if is_yorigo_subparam(subparam):
            uid = self._lookup_uid(subparam)
            match_status = "matched" if uid else "unmatched"
        elif subparam:
            match_status = "unmatched"
        else:
            match_status = "no_subparam"

        payload: Dict[str, Any] = {
            "orderId": _as_optional_str(row.get("orderId") or row.get("order_id")),
            "productId": _as_optional_str(row.get("productId") or row.get("product_id")),
            "productName": _as_optional_str(row.get("productName") or row.get("product_name")),
            "quantity": _as_optional_int(row.get("quantity")),
            "gmv": _as_optional_number(row.get("gmv")),
            "commission": _as_optional_number(row.get("commission")),
            "commissionRate": _as_optional_number(row.get("commissionRate")),
            "categoryName": _as_optional_str(row.get("categoryName")),
            "date": _as_optional_str(row.get("date")),
            "subId": _as_optional_str(row.get("subId") or row.get("subid")),
            "subparam": subparam or None,
            "uid": uid,
            "matchStatus": match_status,
            "cancelled": cancelled,
            "source": source,
            "syncedAt": _server_timestamp(),
        }
        self.db.collection(ORDERS_COLLECTION).document(doc_id).set(payload, merge=True)
        if uid:
            user_payload = dict(payload)
            self.db.collection("users").document(uid).collection(
                USER_ORDERS_SUBCOLLECTION
            ).document(doc_id).set(user_payload, merge=True)

        stats.upserted += 1
        if cancelled:
            stats.cancelled += 1
        if match_status == "matched":
            stats.matched += 1
        elif match_status == "unmatched":
            stats.unmatched += 1
        else:
            stats.no_subparam += 1


def row_to_api_item(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "order_id": str(row.get("orderId") or row.get("order_id") or ""),
        "product_id": row.get("productId"),
        "product_name": row.get("productName"),
        "quantity": row.get("quantity"),
        "gmv": row.get("gmv"),
        "commission": row.get("commission"),
        "date": row.get("date"),
        "subparam": row.get("subparam"),
        "uid": row.get("uid"),
        "match_status": row.get("matchStatus") or "unmatched",
        "cancelled": bool(row.get("cancelled")),
        "source": row.get("source"),
    }


_service: Optional[CoupangOrderAttributionService] = None


def get_coupang_order_attribution_service() -> CoupangOrderAttributionService:
    global _service
    if _service is None:
        from services.firebase_service import get_firebase_service

        firebase = get_firebase_service()
        _service = CoupangOrderAttributionService(firebase.db if firebase else None)
    return _service
