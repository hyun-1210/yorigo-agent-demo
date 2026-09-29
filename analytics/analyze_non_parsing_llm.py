"""파싱 외 LLM 사용처(재료 단가 추정, 유통기한/환산갭 리서치, 캐노니컬라이즈, 리뷰/신고 모더레이션,
추천 폴백) 실제 볼륨을 Firestore에서 집계.

Run: python analytics/analyze_non_parsing_llm.py
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, firestore

ROOT = Path(__file__).resolve().parents[1]
CRED_PATH = ROOT / "backend" / "firebase-service-account.json"
OUT = ROOT / "analytics" / "non_parsing_llm_snapshot.json"

cred = credentials.Certificate(str(CRED_PATH))
firebase_admin.initialize_app(cred)
db = firestore.client()

report: dict = {"generated_at": datetime.now(timezone.utc).isoformat()}

now = datetime.now(timezone.utc)
d30 = now - timedelta(days=30)
d7 = now - timedelta(days=7)


def count_all(coll: str) -> int:
    return sum(1 for _ in db.collection(coll).select([]).stream())


def count_since(coll: str, field: str, since: datetime) -> int:
    try:
        q = db.collection(coll).where(field, ">=", since).select([])
        return sum(1 for _ in q.stream())
    except Exception as e:
        return f"ERROR: {e}"  # type: ignore


# ---------------------------------------------------------------------------
# 1) 재료 단가 큐 (config docs)
# ---------------------------------------------------------------------------
config_docs = [
    "pending_unit_price_ingredients",
    "pending_unit_price_recheck_ingredients",
    "pending_scraping_ingredients",
    "extra_scraping_ingredients",
    "priority_scraping_ingredients",
]
queues: dict = {}
for doc_id in config_docs:
    try:
        doc = db.collection("config").document(doc_id).get()
        data = doc.to_dict() or {}
        names = data.get("names") or data.get("ingredients") or []
        if not isinstance(names, list):
            names = []
        queues[doc_id] = {"queue_len": len(names), "raw_keys": list(data.keys())}
    except Exception as e:
        queues[doc_id] = {"error": str(e)}
report["config_queues"] = queues

# ---------------------------------------------------------------------------
# 2) ingredient_unit_prices (top-level 문서 수 = LLM 추정된 재료 종류 수, 단가 스케줄러 산출물)
# ---------------------------------------------------------------------------
try:
    unit_price_docs = list(db.collection("ingredient_unit_prices").select([]).stream())
    report["ingredient_unit_prices_total_docs"] = len(unit_price_docs)
except Exception as e:
    report["ingredient_unit_prices_total_docs"] = f"ERROR: {e}"

# updatedAt 기준 최근 생성/갱신 건수 (스케줄러가 24h마다 도는 유량 추정)
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    try:
        q = db.collection("ingredient_unit_prices").where("lastUpdated", ">=", since).select([])
        report[f"ingredient_unit_prices_updated_{label}"] = sum(1 for _ in q.stream())
    except Exception as e:
        report[f"ingredient_unit_prices_updated_{label}"] = f"ERROR: {e}"

# 2b) on-demand baseUnit 요청 (request_unit_price 엔드포인트) → units 서브컬렉션 collection_group
try:
    units_total = sum(1 for _ in db.collection_group("units").select([]).stream())
    report["ingredient_unit_prices_units_subcoll_total"] = units_total
except Exception as e:
    report["ingredient_unit_prices_units_subcoll_total"] = f"ERROR: {e}"
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    try:
        q = db.collection_group("units").where("lastUpdated", ">=", since).select([])
        report[f"ingredient_unit_prices_units_subcoll_{label}"] = sum(1 for _ in q.stream())
    except Exception as e:
        report[f"ingredient_unit_prices_units_subcoll_{label}"] = f"ERROR: {e}"

# ---------------------------------------------------------------------------
# 3) ingredient_shelf_life (관리자 수동 배치 리서치 산출물)
# ---------------------------------------------------------------------------
try:
    report["ingredient_shelf_life_total_docs"] = count_all("ingredient_shelf_life")
except Exception as e:
    report["ingredient_shelf_life_total_docs"] = f"ERROR: {e}"
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    report[f"ingredient_shelf_life_updated_{label}"] = count_since(
        "ingredient_shelf_life", "updatedAt", since
    )

# ---------------------------------------------------------------------------
# 4) conversion_gap_research_runs (관리자 수동 배치 감사 로그)
# ---------------------------------------------------------------------------
try:
    report["conversion_gap_research_runs_total"] = count_all("conversion_gap_research_runs")
except Exception as e:
    report["conversion_gap_research_runs_total"] = f"ERROR: {e}"
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    report[f"conversion_gap_research_runs_{label}"] = count_since(
        "conversion_gap_research_runs", "createdAt", since
    )

# ---------------------------------------------------------------------------
# 5) recipe_group_aliases (캐노니컬라이즈 LLM 캐시: 문서 1개 = LLM 호출 1회, 이후 영구 캐시)
# ---------------------------------------------------------------------------
try:
    alias_docs = list(db.collection("recipe_group_aliases").select(["miss", "updatedAt"]).stream())
    report["recipe_group_aliases_total"] = len(alias_docs)
    misses = sum(1 for d in alias_docs if (d.to_dict() or {}).get("miss") is True)
    report["recipe_group_aliases_miss"] = misses
    report["recipe_group_aliases_hit_name"] = len(alias_docs) - misses
except Exception as e:
    report["recipe_group_aliases_total"] = f"ERROR: {e}"
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    report[f"recipe_group_aliases_new_{label}"] = count_since(
        "recipe_group_aliases", "updatedAt", since
    )

# recipes 총 문서 수 (분모 비교용)
try:
    report["recipes_total_docs"] = count_all("recipes")
except Exception as e:
    report["recipes_total_docs"] = f"ERROR: {e}"

# ---------------------------------------------------------------------------
# 6) reviews (매 생성 시 OpenAI 모더레이션 1회 호출)
# ---------------------------------------------------------------------------
try:
    report["reviews_total_docs"] = count_all("reviews")
except Exception as e:
    report["reviews_total_docs"] = f"ERROR: {e}"
for label, since in [("last_7d", d7), ("last_30d", d30)]:
    report[f"reviews_created_{label}"] = count_since("reviews", "createdAt", since)

# isHidden true 건수 (LLM auto-hide 결과 근사)
try:
    q = db.collection("reviews").where("isHidden", "==", True).select([])
    report["reviews_isHidden_true_total"] = sum(1 for _ in q.stream())
except Exception as e:
    report["reviews_isHidden_true_total"] = f"ERROR: {e}"

# ---------------------------------------------------------------------------
# 7) reports (매 생성 시 OpenAI 모더레이션 1회 호출)
# ---------------------------------------------------------------------------
try:
    report["reports_total_docs"] = count_all("reports")
except Exception as e:
    report["reports_total_docs"] = f"ERROR: {e}"
for field in ["createdAt", "reportedAt", "timestamp"]:
    val = count_since("reports", field, d30)
    if not (isinstance(val, str) and val.startswith("ERROR")):
        report["reports_created_last_30d"] = val
        report["reports_created_last_30d_field"] = field
        break

# ---------------------------------------------------------------------------
# 8) developer_moderation_alerts / moderation_alerts (자동 조치 결과 로그)
# ---------------------------------------------------------------------------
for coll in ["developer_moderation_alerts", "moderation_alerts"]:
    try:
        docs = list(db.collection(coll).select(["eventType", "createdAt"]).stream())
        report[f"{coll}_total"] = len(docs)
        from collections import Counter

        et_counter = Counter((d.to_dict() or {}).get("eventType", "unknown") for d in docs)
        report[f"{coll}_by_eventType"] = dict(et_counter)
        recent30 = sum(
            1
            for d in docs
            if (d.to_dict() or {}).get("createdAt")
            and getattr((d.to_dict() or {}).get("createdAt"), "replace", None)
            and (d.to_dict() or {}).get("createdAt").astimezone(timezone.utc) >= d30
        )
        report[f"{coll}_last_30d"] = recent30
    except Exception as e:
        report[f"{coll}_total"] = f"ERROR: {e}"

# ---------------------------------------------------------------------------
# 9) recommendation_feedback_events: policy_type 분포로 llm_fallback 비중 근사
# ---------------------------------------------------------------------------
try:
    from collections import Counter

    fb_docs = list(
        db.collection("recommendation_feedback_events").select(["policy_type", "createdAt"]).stream()
    )
    report["recommendation_feedback_events_total"] = len(fb_docs)
    pt_counter = Counter((d.to_dict() or {}).get("policy_type") or "unknown" for d in fb_docs)
    report["recommendation_feedback_events_by_policy_type"] = dict(pt_counter)

    def _parse_iso(s):
        try:
            return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        except Exception:
            return None

    recent = [d for d in fb_docs if (_parse_iso((d.to_dict() or {}).get("createdAt")) or now.replace(year=1970)) >= d30]
    report["recommendation_feedback_events_last_30d"] = len(recent)
    report["recommendation_feedback_events_last_30d_by_policy_type"] = dict(
        Counter((d.to_dict() or {}).get("policy_type") or "unknown" for d in recent)
    )
except Exception as e:
    report["recommendation_feedback_events_total"] = f"ERROR: {e}"

OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False, indent=2, default=str))
print(f"\n[OK] wrote {OUT}")
