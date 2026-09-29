"""
Firebase ingredient_unit_prices 이상치 점검/보정 스크립트.

기본은 dry-run이며, --apply를 주면 보정 가능한 항목을 실제 반영합니다.
"""

import argparse
import json
import os
import sys
from collections import Counter
from typing import Any, Dict, List, Optional

from firebase_admin import credentials, firestore
import firebase_admin

# backend 경로 기준 import 보장
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(CURRENT_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from utils.ingredient_price_validation import validate_and_adjust_unit_price


def _to_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _init_db() -> firestore.Client:
    cred_path = os.path.join(BACKEND_DIR, "firebase.json")
    with open(cred_path, "r", encoding="utf-8") as f:
        cred_dict = json.load(f)
    app = firebase_admin.initialize_app(credentials.Certificate(cred_dict), name="audit-fix-unit-price")
    return firestore.client(app=app)


def run_audit(apply: bool = False) -> Dict[str, Any]:
    db = _init_db()
    docs = list(db.collection("ingredient_unit_prices").stream())

    summary = {
        "docs_total": len(docs),
        "docs_with_units": 0,
        "unit_docs_total": 0,
        "blocked_candidates": 0,
        "adjusted_candidates": 0,
        "applied_updates": 0,
    }

    blocked_rows: List[Dict[str, Any]] = []
    adjusted_rows: List[Dict[str, Any]] = []
    same_unit_mismatch_rows: List[Dict[str, Any]] = []
    weird_price_rows: List[Dict[str, Any]] = []
    top_source_counts: Counter = Counter()

    for d in docs:
        top = d.to_dict() or {}
        ingredient_name = d.id
        top_source_counts[str(top.get("source") or "unknown")] += 1

        top_unit = str(top.get("baseUnit") or "").strip().lower()
        top_price = _to_float(top.get("unitPrice"))

        # 일반 단가 이상치(상위 문서 기준)도 같이 수집
        if top_price is not None:
            if top_unit == "g" and top_price >= 100:
                weird_price_rows.append(
                    {
                        "ingredient": ingredient_name,
                        "baseUnit": "g",
                        "unitPrice": top_price,
                        "source": top.get("source"),
                        "reason": "high_price_per_g",
                    }
                )
            elif top_unit == "ml" and top_price >= 200:
                weird_price_rows.append(
                    {
                        "ingredient": ingredient_name,
                        "baseUnit": "ml",
                        "unitPrice": top_price,
                        "source": top.get("source"),
                        "reason": "high_price_per_ml",
                    }
                )
            elif top_unit == "개" and top_price <= 100:
                weird_price_rows.append(
                    {
                        "ingredient": ingredient_name,
                        "baseUnit": "개",
                        "unitPrice": top_price,
                        "source": top.get("source"),
                        "reason": "too_low_price_per_piece",
                    }
                )

        unit_docs = list(d.reference.collection("units").stream())
        if unit_docs:
            summary["docs_with_units"] += 1
        summary["unit_docs_total"] += len(unit_docs)

        for unit_doc in unit_docs:
            unit_key = unit_doc.id
            unit_data = unit_doc.to_dict() or {}
            unit_price = _to_float(unit_data.get("unitPrice"))
            unit_base = str(unit_data.get("baseUnit") or "").strip().lower()

            # same-unit mismatch 수집
            if (
                top_price is not None
                and unit_price is not None
                and top_unit
                and unit_base == top_unit
                and top_price > 0
            ):
                ratio = unit_price / top_price
                if ratio > 1.2 or ratio < 0.8:
                    same_unit_mismatch_rows.append(
                        {
                            "ingredient": ingredient_name,
                            "baseUnit": top_unit,
                            "topPrice": top_price,
                            "unitPrice": unit_price,
                            "ratio": round(ratio, 2),
                            "topSource": top.get("source"),
                            "unitSource": unit_data.get("source"),
                        }
                    )

            validation = validate_and_adjust_unit_price(
                ingredient_name=ingredient_name,
                unit_key=unit_key,
                top_price_doc=top,
                price_data=unit_data,
            )
            if not validation.ok:
                summary["blocked_candidates"] += 1
                blocked_rows.append(
                    {
                        "ingredient": ingredient_name,
                        "unitKey": unit_key,
                        "unitPrice": unit_price,
                        "baseUnit": unit_base,
                        "reason": validation.reason,
                    }
                )
                continue

            adjusted_price = _to_float(validation.adjusted_price_data.get("unitPrice"))
            if adjusted_price is not None and unit_price is not None and abs(adjusted_price - unit_price) > 1e-9:
                summary["adjusted_candidates"] += 1
                adjusted_rows.append(
                    {
                        "ingredient": ingredient_name,
                        "unitKey": unit_key,
                        "beforePrice": unit_price,
                        "afterPrice": adjusted_price,
                        "beforeSource": unit_data.get("source"),
                        "afterSource": validation.adjusted_price_data.get("source"),
                        "reasoning": validation.adjusted_price_data.get("reasoning"),
                    }
                )
                if apply:
                    payload = dict(validation.adjusted_price_data)
                    payload["ingredientName"] = ingredient_name
                    payload["lastUpdated"] = firestore.SERVER_TIMESTAMP
                    unit_doc.reference.set(payload, merge=True)
                    summary["applied_updates"] += 1

    report = {
        "summary": {
            **summary,
            "top_source_counts": dict(top_source_counts),
        },
        "blocked_examples": blocked_rows[:100],
        "adjusted_examples": adjusted_rows[:100],
        "same_unit_mismatch_examples": same_unit_mismatch_rows[:100],
        "weird_top_price_examples": weird_price_rows[:150],
    }
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit/fix ingredient unit prices in Firebase")
    parser.add_argument("--apply", action="store_true", help="Apply corrective updates to Firebase")
    args = parser.parse_args()

    report = run_audit(apply=args.apply)
    print(json.dumps(report, ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    main()
