"""D2SF 보고서용 최신 Mixpanel + Firestore 베이스라인 스냅샷.

Mixpanel: backend/.env MIXPANEL_API_SECRET + Query API 2.0
Firestore: Monitoring 스냅샷 + aggregate count()

Run: python analytics/pull_d2sf_baseline.py
"""

from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / "backend" / ".env"
OUT = ROOT / "analytics" / "d2sf_baseline_snapshot.json"
FS_MON = ROOT / "analytics" / "firestore_monitoring_snapshot.json"


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def mp_get(secret: str, path: str, params: dict[str, Any] | None = None) -> Any:
    query = urllib.parse.urlencode(params or {}, doseq=True)
    url = f"https://mixpanel.com/api/2.0/{path}"
    if query:
        url = f"{url}?{query}"
    auth = base64.b64encode(f"{secret}:".encode()).decode()
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Basic {auth}", "Accept": "application/json"},
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=120, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_uniques(
    secret: str, events: list[str], from_date: str, to_date: str, unit: str = "day"
) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    for i in range(0, len(events), 10):
        chunk = events[i : i + 10]
        data = mp_get(
            secret,
            "events",
            {
                "from_date": from_date,
                "to_date": to_date,
                "event": json.dumps(chunk),
                "type": "unique",
                "unit": unit,
            },
        )
        values = data.get("data", {}).get("values", {}) if isinstance(data, dict) else {}
        for name, by_date in values.items():
            if isinstance(by_date, dict):
                out[name] = {k: int(v) for k, v in by_date.items()}
    return out


def sum_series(series: dict[str, int]) -> int:
    return sum(series.values())


def avg_nonzero(series: dict[str, int]) -> float:
    vals = [v for v in series.values() if v > 0]
    return round(sum(vals) / len(vals), 1) if vals else 0.0


def firestore_counts() -> dict[str, Any]:
    backend = ROOT / "backend"
    sys.path.insert(0, str(backend))
    os.chdir(backend)
    from firebase_admin import firestore
    from services.firebase_service import get_firebase_service

    get_firebase_service()
    db = firestore.client()

    def count(q: Any) -> int:
        return int(q.count().get()[0][0].value)

    recipes = db.collection("recipes")
    users = db.collection("users")
    return {
        "recipes_total": count(recipes),
        "recipes_completed": count(recipes.where("status", "==", "completed")),
        "recipes_completed_visible": count(
            recipes.where("status", "==", "completed").where("isHidden", "==", False)
        ),
        "users_total": count(users),
        "reviews_total": count(db.collection("reviews")),
    }


def monitoring_summary() -> dict[str, Any]:
    if not FS_MON.is_file():
        return {}
    d = json.loads(FS_MON.read_text(encoding="utf-8"))
    series = d.get("series", {})
    out: dict[str, Any] = {
        "fetched_at": d.get("fetched_at"),
        "window": d.get("window"),
    }
    for key, short in [
        ("firestore.googleapis.com/document/read_count", "reads"),
        ("firestore.googleapis.com/document/write_count", "writes"),
        ("firestore.googleapis.com/api/request_count", "api_requests"),
    ]:
        block = series.get(key) or {}
        daily = block.get("daily") or []
        out[short] = {
            "total_45d": int(block.get("total") or 0),
            "last3": [
                {"date": x["date"], "value": int(x["value"])}
                for x in daily[-3:]
            ],
            "latest": int(daily[-1]["value"]) if daily else 0,
            "avg_last7": round(
                sum(int(x["value"]) for x in daily[-7:]) / max(len(daily[-7:]), 1),
                0,
            )
            if daily
            else 0,
        }
    return out


def main() -> None:
    env = load_env(ENV_PATH)
    secret = env.get("MIXPANEL_API_SECRET", "").strip()
    if not secret:
        raise SystemExit("MIXPANEL_API_SECRET missing")

    today = date.today()
    from_all = "2024-01-01"
    to = today.isoformat()
    from_30 = (today - timedelta(days=30)).isoformat()
    from_7 = (today - timedelta(days=7)).isoformat()

    events = [
        "sign_up",
        "app_first_open",
        "yorigo_active_user",
        "screen_view",
        "recipe_parsing_completed",
        "parsing_request_started",
        "recipe_bookmarked",
        "cart_purchase_completed",
        "affiliate_link_clicked",
        "ingredient_purchase_checked",
        "review_created",
        "cooking_completed",
        "recipe_viewed",
    ]

    print("Fetching Mixpanel uniques (day)...")
    daily = fetch_uniques(secret, events, from_all, to, "day")
    print("Fetching Mixpanel uniques (month)...")
    monthly = fetch_uniques(secret, events, from_all, to, "month")

    # recent windows
    daily_30 = {
        e: {d: v for d, v in (daily.get(e) or {}).items() if d >= from_30}
        for e in events
    }
    daily_7 = {
        e: {d: v for d, v in (daily.get(e) or {}).items() if d >= from_7}
        for e in events
    }

    active = daily.get("yorigo_active_user") or {}
    screen = daily.get("screen_view") or {}

    summary = {
        "total_unique_sign_ups": sum_series(daily.get("sign_up") or {}),
        "total_unique_app_first_open": sum_series(daily.get("app_first_open") or {}),
        "total_unique_parse_completed": sum_series(
            daily.get("recipe_parsing_completed") or {}
        ),
        "total_unique_bookmarked": sum_series(daily.get("recipe_bookmarked") or {}),
        "total_unique_purchase_completed": sum_series(
            daily.get("cart_purchase_completed") or {}
        ),
        "total_unique_affiliate_click": sum_series(
            daily.get("affiliate_link_clicked") or {}
        ),
        "total_unique_ingredient_checked": sum_series(
            daily.get("ingredient_purchase_checked") or {}
        ),
        "total_unique_review": sum_series(daily.get("review_created") or {}),
        "peak_dau_registered": max(active.values() or [0]),
        "peak_dau_screen_view": max(screen.values() or [0]),
        "avg_dau_registered_30d": avg_nonzero(daily_30.get("yorigo_active_user") or {}),
        "avg_dau_screen_view_30d": avg_nonzero(daily_30.get("screen_view") or {}),
        "avg_dau_registered_7d": avg_nonzero(daily_7.get("yorigo_active_user") or {}),
        "avg_dau_screen_view_7d": avg_nonzero(daily_7.get("screen_view") or {}),
        "latest_dau_registered": (list(active.items())[-1][1] if active else 0),
        "latest_dau_date": (list(active.keys())[-1] if active else ""),
        "mau_registered_current_month": sum_series(
            {
                k: v
                for k, v in (monthly.get("yorigo_active_user") or {}).items()
                if k.startswith(today.strftime("%Y-%m"))
            }
        )
        or max((monthly.get("yorigo_active_user") or {}).values() or [0]),
    }

    # Fix MAU: monthly unique for current month key
    mau_series = monthly.get("yorigo_active_user") or {}
    # Mixpanel month keys can be YYYY-MM-01
    month_keys = sorted(mau_series.keys())
    if month_keys:
        summary["mau_registered_latest_month"] = mau_series[month_keys[-1]]
        summary["mau_registered_latest_month_key"] = month_keys[-1]
    mau_sv = monthly.get("screen_view") or {}
    if mau_sv:
        mk = sorted(mau_sv.keys())[-1]
        summary["mau_screen_view_latest_month"] = mau_sv[mk]
        summary["mau_screen_view_latest_month_key"] = mk

    print("Fetching Firestore aggregate counts...")
    try:
        fs_counts = firestore_counts()
    except Exception as e:
        print(f"Firestore counts failed: {e}")
        fs_counts = {"error": str(e)}

    mon = monitoring_summary()

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "as_of_date": to,
        "mixpanel": {
            "summary": summary,
            "monthly_unique_totals": {
                e: sum_series(monthly.get(e) or {}) for e in events
            },
        },
        "firestore": {
            "counts": fs_counts,
            "monitoring": mon,
        },
    }
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report["mixpanel"]["summary"], ensure_ascii=False, indent=2))
    print(json.dumps(report["firestore"], ensure_ascii=False, indent=2)[:2000])
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
