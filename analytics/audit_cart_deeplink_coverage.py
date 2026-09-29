#!/usr/bin/env python3
"""장바구니/구매체크 경로에서 실제 URL이 Partners 딥링크인지 Firestore로 점검한다.

점검 대상:
1) coupang_products.products[].deeplinkUrl 커버리지
2) users/*/product_check_events 의 productUrl / deeplinkUrl / originalUrl
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

import firebase_admin
from firebase_admin import credentials, firestore

ROOT = Path(__file__).resolve().parents[1]
SA_PATH = ROOT / "backend" / "firebase-service-account.json"
OUT_PATH = Path(__file__).resolve().parent / "cart_deeplink_audit_snapshot.json"

COUPANG_PARTNER_HOSTS = {
    "link.coupang.com",
    "coupa.ng",
    "coupang.com",  # landingUrl이 www 없이 올 수도 있어 host 세부 판별은 아래에서
}
RAW_COUPANG_HOSTS = {"www.coupang.com", "m.coupang.com", "coupang.com"}


def init_db() -> Any:
    if not SA_PATH.is_file():
        raise SystemExit(f"서비스 계정 없음: {SA_PATH}")
    if not firebase_admin._apps:
        cred = credentials.Certificate(str(SA_PATH))
        firebase_admin.initialize_app(cred)
    return firestore.client()


def classify_url(url: str) -> str:
    u = (url or "").strip()
    if not u:
        return "empty"
    try:
        p = urlparse(u)
    except Exception:
        return "invalid"
    host = (p.netloc or "").lower()
    path = p.path or ""
    qs = p.query or ""

    if host in {"link.coupang.com", "coupa.ng"}:
        return "coupang_partner_deeplink"
    if "link.coupang.com" in u or "coupa.ng/" in u:
        return "coupang_partner_deeplink"
    if host.endswith("kurly.com") or host.endswith("kurlycorp.com"):
        if "affiliate" in u.lower() or "tracking" in qs.lower() or "af_" in qs:
            return "kurly_affiliate"
        return "kurly_link"
    if host in RAW_COUPANG_HOSTS or host.endswith(".coupang.com"):
        if "subId=" in qs or "sub_id=" in qs:
            return "coupang_raw_with_subid"
        if re.search(r"/[vn]p/products/\d+", path):
            return "coupang_raw_product"
        return "coupang_other"
    if host.startswith("http") or "://" in u:
        return "other_http"
    return "other"


def is_partner_deeplink(url: str) -> bool:
    return classify_url(url) == "coupang_partner_deeplink"


def audit_coupang_products(db: Any, max_docs: int = 400) -> Dict[str, Any]:
    col = db.collection("coupang_products")
    docs = list(col.limit(max_docs).stream())
    total_products = 0
    with_deeplink_field = 0
    partner_deeplink = 0
    deeplink_eq_raw = 0
    empty_deeplink = 0
    raw_only = 0
    samples_missing: List[Dict[str, str]] = []
    samples_ok: List[Dict[str, str]] = []
    class_counter: Counter[str] = Counter()

    for doc in docs:
        data = doc.to_dict() or {}
        products = data.get("products") or []
        if not isinstance(products, list):
            continue
        for p in products:
            if not isinstance(p, dict):
                continue
            total_products += 1
            link = str(p.get("link") or p.get("productUrl") or "").strip()
            deeplink = str(p.get("deeplinkUrl") or "").strip()
            if deeplink:
                with_deeplink_field += 1
            else:
                empty_deeplink += 1
            cls = classify_url(deeplink or link)
            class_counter[cls] += 1
            if is_partner_deeplink(deeplink):
                partner_deeplink += 1
                if len(samples_ok) < 8:
                    samples_ok.append(
                        {
                            "keyword": doc.id,
                            "productName": str(p.get("productName") or "")[:80],
                            "deeplinkUrl": deeplink[:180],
                            "link": link[:180],
                        }
                    )
            else:
                if deeplink and link and deeplink == link:
                    deeplink_eq_raw += 1
                if not is_partner_deeplink(deeplink) and link:
                    raw_only += 1
                if len(samples_missing) < 12:
                    samples_missing.append(
                        {
                            "keyword": doc.id,
                            "productName": str(p.get("productName") or "")[:80],
                            "deeplinkUrl": deeplink[:180],
                            "link": link[:180],
                            "class": classify_url(deeplink or link),
                        }
                    )

    return {
        "docs_scanned": len(docs),
        "products_scanned": total_products,
        "with_deeplink_field": with_deeplink_field,
        "empty_deeplink": empty_deeplink,
        "partner_deeplink_count": partner_deeplink,
        "partner_deeplink_rate": round(partner_deeplink / total_products, 4) if total_products else 0,
        "deeplink_equals_raw_count": deeplink_eq_raw,
        "non_partner_count": total_products - partner_deeplink,
        "class_counter": dict(class_counter),
        "samples_ok": samples_ok,
        "samples_missing_or_raw": samples_missing,
    }


def _to_dt(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value
    return None


def audit_product_check_events(db: Any, days: int = 30, max_events: int = 3000) -> Dict[str, Any]:
    since = datetime.now(timezone.utc) - timedelta(days=days)
    q = (
        db.collection_group("product_check_events")
        .order_by("createdAt", direction=firestore.Query.DESCENDING)
        .limit(max_events)
    )
    events: List[Dict[str, Any]] = []
    try:
        for snap in q.stream():
            data = snap.to_dict() or {}
            created = _to_dt(data.get("createdAt") or data.get("timestamp") or data.get("checkedAt"))
            if created is not None and created < since:
                # ordered desc; can stop early once older than window
                if len(events) > 50:
                    break
                continue
            events.append(
                {
                    "path": snap.reference.path,
                    "marketplace": str(data.get("marketplace") or ""),
                    "ingredientName": str(data.get("ingredientName") or ""),
                    "productUrl": str(data.get("productUrl") or "").strip(),
                    "originalUrl": str(data.get("originalUrl") or "").strip(),
                    "deeplinkUrl": str(data.get("deeplinkUrl") or "").strip(),
                    "productId": str(data.get("productId") or ""),
                    "createdAt": created.isoformat() if created else None,
                }
            )
    except Exception as exc:
        # createdAt 인덱스/필드 없을 수 있음 → 전체 limit 폴백
        print(f"[WARN] ordered query failed: {exc}")
        for snap in db.collection_group("product_check_events").limit(max_events).stream():
            data = snap.to_dict() or {}
            created = _to_dt(data.get("createdAt") or data.get("timestamp") or data.get("checkedAt"))
            events.append(
                {
                    "path": snap.reference.path,
                    "marketplace": str(data.get("marketplace") or ""),
                    "ingredientName": str(data.get("ingredientName") or ""),
                    "productUrl": str(data.get("productUrl") or "").strip(),
                    "originalUrl": str(data.get("originalUrl") or "").strip(),
                    "deeplinkUrl": str(data.get("deeplinkUrl") or "").strip(),
                    "productId": str(data.get("productId") or ""),
                    "createdAt": created.isoformat() if created else None,
                }
            )

    product_class = Counter()
    deeplink_class = Counter()
    opened_effective_class = Counter()  # productUrl 우선 (체크 시점 스냅샷)
    marketplace_counter = Counter()
    coupang_partner = 0
    coupang_raw = 0
    coupang_total = 0
    samples_raw: List[Dict[str, str]] = []
    samples_partner: List[Dict[str, str]] = []
    mismatch: List[Dict[str, str]] = []

    for e in events:
        mp = (e["marketplace"] or "unknown").lower()
        marketplace_counter[mp] += 1
        pu = e["productUrl"]
        du = e["deeplinkUrl"]
        ou = e["originalUrl"]
        product_class[classify_url(pu)] += 1
        deeplink_class[classify_url(du)] += 1

        # 앱이 실제로 여는 우선순위와 동일: deeplink → product → original
        effective = du or pu or ou
        eff_cls = classify_url(effective)
        opened_effective_class[eff_cls] += 1

        if mp in {"", "coupang", "unknown"} or "coupang" in (pu + du + ou).lower():
            if mp in {"", "coupang", "unknown"} or "coupang.com" in (pu + du + ou) or "coupa.ng" in (pu + du + ou):
                if "kurly" not in mp:
                    coupang_total += 1
                    if is_partner_deeplink(effective):
                        coupang_partner += 1
                        if len(samples_partner) < 10:
                            samples_partner.append(
                                {
                                    "ingredient": e["ingredientName"][:40],
                                    "effective": effective[:200],
                                    "productUrl": pu[:160],
                                    "deeplinkUrl": du[:160],
                                    "createdAt": e["createdAt"] or "",
                                }
                            )
                    elif classify_url(effective).startswith("coupang_raw"):
                        coupang_raw += 1
                        if len(samples_raw) < 15:
                            samples_raw.append(
                                {
                                    "ingredient": e["ingredientName"][:40],
                                    "effective": effective[:200],
                                    "productUrl": pu[:160],
                                    "deeplinkUrl": du[:160],
                                    "originalUrl": ou[:160],
                                    "class": eff_cls,
                                    "createdAt": e["createdAt"] or "",
                                    "path": e["path"],
                                }
                            )

        # productUrl이 raw인데 deeplinkUrl이 partner인 경우 (enrich 전 스냅샷 가능)
        if classify_url(pu).startswith("coupang_raw") and is_partner_deeplink(du):
            if len(mismatch) < 10:
                mismatch.append(
                    {
                        "ingredient": e["ingredientName"][:40],
                        "productUrl": pu[:160],
                        "deeplinkUrl": du[:160],
                        "note": "productUrl raw but deeplink partner; click uses deeplink first",
                    }
                )

    return {
        "days": days,
        "events_scanned": len(events),
        "marketplace_counter": dict(marketplace_counter),
        "productUrl_class": dict(product_class),
        "deeplinkUrl_class": dict(deeplink_class),
        "effective_open_class": dict(opened_effective_class),
        "coupang_events_approx": coupang_total,
        "coupang_partner_effective": coupang_partner,
        "coupang_raw_effective": coupang_raw,
        "coupang_partner_rate": round(coupang_partner / coupang_total, 4) if coupang_total else 0,
        "samples_partner": samples_partner,
        "samples_raw_or_non_partner": samples_raw,
        "product_raw_but_deeplink_partner": mismatch,
        "newest_createdAt": events[0]["createdAt"] if events else None,
        "oldest_in_sample": events[-1]["createdAt"] if events else None,
    }


def audit_kurly_products(db: Any, max_docs: int = 100) -> Dict[str, Any]:
    try:
        docs = list(db.collection("kurly_products").limit(max_docs).stream())
    except Exception as exc:
        return {"error": str(exc)}
    total = 0
    classes: Counter[str] = Counter()
    samples: List[Dict[str, str]] = []
    for doc in docs:
        data = doc.to_dict() or {}
        for p in data.get("products") or []:
            if not isinstance(p, dict):
                continue
            total += 1
            link = str(p.get("link") or "").strip()
            cls = classify_url(link)
            classes[cls] += 1
            if len(samples) < 8:
                samples.append({"keyword": doc.id, "link": link[:200], "class": cls})
    return {
        "docs_scanned": len(docs),
        "products_scanned": total,
        "class_counter": dict(classes),
        "samples": samples,
    }


def main() -> None:
    db = init_db()
    print("=== coupang_products deeplink coverage ===")
    coupang = audit_coupang_products(db)
    print(json.dumps({k: v for k, v in coupang.items() if not k.startswith("samples")}, ensure_ascii=False, indent=2))

    print("\n=== product_check_events (recent) ===")
    events = audit_product_check_events(db, days=45, max_events=4000)
    print(json.dumps({k: v for k, v in events.items() if not k.startswith("samples") and k != "product_raw_but_deeplink_partner"}, ensure_ascii=False, indent=2))

    print("\n=== kurly_products link sample ===")
    kurly = audit_kurly_products(db)
    print(json.dumps({k: v for k, v in kurly.items() if k != "samples"}, ensure_ascii=False, indent=2))

    out = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "coupang_products": coupang,
        "product_check_events": events,
        "kurly_products": kurly,
        "notes": [
            "cartItems에는 상품 URL이 없고 recommend API 응답의 deeplink/product/original을 탭 시 연다.",
            "effective = deeplinkUrl || productUrl || originalUrl (프론트 우선순위와 동일).",
            "coupang_partner_deeplink = link.coupang.com / coupa.ng",
        ],
    }
    OUT_PATH.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nWrote {OUT_PATH}")

    # 요약 판정
    rate = events.get("coupang_partner_rate", 0)
    cache_rate = coupang.get("partner_deeplink_rate", 0)
    print("\n======== VERDICT ========")
    print(f"Firestore coupang_products partner deeplink rate: {cache_rate:.1%}")
    print(f"product_check_events coupang effective partner rate: {rate:.1%}")
    if events.get("coupang_raw_effective", 0) > 0:
        print(f"RAW/non-partner effective opens found: {events['coupang_raw_effective']}")
        for s in events.get("samples_raw_or_non_partner", [])[:5]:
            print(f"  - {s.get('ingredient')}: {s.get('effective')}")
    else:
        print("No raw coupang effective URLs in sampled check events.")


if __name__ == "__main__":
    main()
