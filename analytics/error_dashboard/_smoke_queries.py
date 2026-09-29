"""오류 대시보드가 쓰는 Firestore 쿼리 스모크 테스트 (Admin SDK).

대시보드 UI의 클라이언트 쿼리와 동일한 where/orderBy/limit 패턴이
인덱스·데이터 측면에서 동작하는지 검증한다.

Run:
  python analytics/error_dashboard/_smoke_queries.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud.firestore_v1.base_query import FieldFilter

ROOT = Path(__file__).resolve().parents[2]
CRED = ROOT / "backend" / "firebase-service-account.json"

PAGE = 50


def _count(q) -> int:
    # aggregation count if available
    try:
        return q.count().get()[0][0].value
    except Exception:
        return sum(1 for _ in q.select([]).stream())


def main() -> int:
    if not CRED.exists():
        print(f"FAIL: missing cred {CRED}")
        return 1

    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(str(CRED)))
    db = firestore.client()

    report: dict = {"ok": True, "checks": []}

    def check(name: str, fn) -> None:
        try:
            detail = fn()
            report["checks"].append({"name": name, "ok": True, **detail})
            print(f"OK  {name}: {detail}")
        except Exception as e:
            report["ok"] = False
            report["checks"].append({"name": name, "ok": False, "error": str(e)})
            print(f"FAIL {name}: {e}")

    check(
        "recipes_status_error_page",
        lambda: {
            "n": len(
                list(
                    db.collection("recipes")
                    .where(filter=FieldFilter("status", "==", "error"))
                    .order_by("updatedAt", direction=firestore.Query.DESCENDING)
                    .limit(PAGE)
                    .stream()
                )
            )
        },
    )

    check(
        "recipes_status_error_count",
        lambda: {
            "count": _count(
                db.collection("recipes").where(filter=FieldFilter("status", "==", "error"))
            )
        },
    )

    check(
        "parsing_failures_page",
        lambda: {
            "n": len(
                list(
                    db.collection("parsing_failures")
                    .order_by("createdAt", direction=firestore.Query.DESCENDING)
                    .limit(PAGE)
                    .stream()
                )
            )
        },
    )

    check(
        "parsing_failures_open_count",
        lambda: {
            "count": _count(
                db.collection("parsing_failures").where(
                    filter=FieldFilter("status", "==", "open")
                )
            )
        },
    )

    for coll, order in [
        ("recipe_reports", "createdAt"),
        ("reports", "createdAt"),
        ("app_feedback", "createdAt"),
        ("fridge_scan_reports", "createdAt"),
        ("ingredient_price_issue_reports", "createdAt"),
        ("moderation_alerts", "createdAt"),
        ("purchase_verification_queue", "createdAt"),
    ]:
        check(
            f"{coll}_page",
            lambda c=coll, o=order: {
                "n": len(
                    list(
                        db.collection(c)
                        .order_by(o, direction=firestore.Query.DESCENDING)
                        .limit(PAGE)
                        .stream()
                    )
                )
            },
        )

    # static assets exist
    dash = Path(__file__).resolve().parent
    for rel in [
        "index.html",
        "styles.css",
        "js/app.js",
        "js/auth.js",
        "js/queries.js",
        "js/ui.js",
        "js/firebase-config.js",
    ]:
        check(f"asset_{rel}", lambda r=rel: {"exists": (dash / r).exists()})

    # firestore.rules contain new matches
    rules = (ROOT / "yorigo-frontend" / "firestore.rules").read_text(encoding="utf-8")
    check(
        "rules_ingredient_price_issue_reports",
        lambda: {"present": "match /ingredient_price_issue_reports/{reportId}" in rules},
    )
    check(
        "rules_moderation_alerts",
        lambda: {"present": "match /moderation_alerts/{alertId}" in rules},
    )

    out = dash / "_smoke_queries_result.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nWrote {out}")
    return 0 if report["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
