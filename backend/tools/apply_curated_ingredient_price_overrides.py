"""
사용자 검토 기반의 curated ingredient_unit_prices 보정 스크립트.

원칙:
- 현재 파싱/가격 계산 호환성을 위해 top 단위는 가능한 한 기존 구조를 유지
- 자주 쓰이는 g 가격은 명시적으로 정합화
- 모호하거나 위험한 단위 문서는 삭제
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List

import firebase_admin
from firebase_admin import credentials, firestore


CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(CURRENT_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)


CURATED_TOP_OVERRIDES: Dict[str, Dict[str, Any]] = {
    # 파싱 호환성상 count-like top 유지가 안전한 항목
    "두부": {"unitPrice": 1500.0, "baseUnit": "개"},
    "버터": {"unitPrice": 5000.0, "baseUnit": "개"},
    "스팸": {"unitPrice": 4000.0, "baseUnit": "개"},
    "참치캔": {"unitPrice": 3000.0, "baseUnit": "개"},
    "브로콜리": {"unitPrice": 2000.0, "baseUnit": "개"},
    "애호박": {"unitPrice": 2000.0, "baseUnit": "개"},
    # 파싱 결과가 주로 g로 정규화되는 항목
    "김치": {"unitPrice": 5.0, "baseUnit": "g"},
    "마늘": {"unitPrice": 30.0, "baseUnit": "g"},
    "버섯": {"unitPrice": 12.0, "baseUnit": "g"},
    # 보류 항목이지만 기존 500원/g는 명백히 잘못되어 환산값으로만 정합화
    "청양고추": {"unitPrice": 300.0, "baseUnit": "개"},
}


CURATED_UNIT_OVERRIDES: Dict[str, Dict[str, Dict[str, Any]]] = {
    "두부": {
        "g": {"unitPrice": 5.0, "baseUnit": "g"},
    },
    "버터": {
        "g": {"unitPrice": 11.0, "baseUnit": "g"},
    },
    "스팸": {
        "g": {"unitPrice": 20.0, "baseUnit": "g"},
        "캔": {"unitPrice": 4000.0, "baseUnit": "캔"},
    },
    # 기존 프론트 표준 환산(1캔 ≈ 135g)에 맞춰 22.22원/g로 맞춤
    "참치캔": {
        "g": {"unitPrice": 22.22, "baseUnit": "g"},
        "캔": {"unitPrice": 3000.0, "baseUnit": "캔"},
    },
    # 기존 프론트 환산(1개 ≈ 350g)에 맞춰 정합화
    "브로콜리": {
        "g": {"unitPrice": 5.71, "baseUnit": "g"},
    },
    "애호박": {
        "g": {"unitPrice": 5.71, "baseUnit": "g"},
    },
    "김치": {
        "g": {"unitPrice": 5.0, "baseUnit": "g"},
    },
    "마늘": {
        "알": {"unitPrice": 120.0, "baseUnit": "알"},
        "쪽": {"unitPrice": 120.0, "baseUnit": "쪽"},
    },
    "버섯": {
        "g": {"unitPrice": 12.0, "baseUnit": "g"},
        "팩": {"unitPrice": 1500.0, "baseUnit": "팩"},
    },
    "청양고추": {
        "g": {"unitPrice": 25.0, "baseUnit": "g"},
    },
}


CURATED_UNIT_DELETES: Dict[str, List[str]] = {
    "마늘": ["개"],
    "청양고추": ["개"],
}


def _init_db() -> firestore.Client:
    cred_path = os.path.join(BACKEND_DIR, "firebase.json")
    with open(cred_path, "r", encoding="utf-8") as f:
        cred_dict = json.load(f)
    app = firebase_admin.initialize_app(
        credentials.Certificate(cred_dict),
        name="apply-curated-ingredient-price-overrides",
    )
    return firestore.client(app=app)


def _merge_payload(ingredient_name: str, payload: Dict[str, Any], source_note: str) -> Dict[str, Any]:
    return {
        "ingredientName": ingredient_name,
        "unitPrice": payload["unitPrice"],
        "baseUnit": payload["baseUnit"],
        "source": "curated_override",
        "reasoning": source_note,
        "lastUpdated": firestore.SERVER_TIMESTAMP,
    }


def main() -> None:
    db = _init_db()
    report: Dict[str, Any] = {
        "top_updates": [],
        "unit_updates": [],
        "unit_deletes": [],
    }

    for ingredient_name, payload in CURATED_TOP_OVERRIDES.items():
        doc_ref = db.collection("ingredient_unit_prices").document(ingredient_name)
        reason = f"Curated override applied for {ingredient_name} top price"
        doc_ref.set(_merge_payload(ingredient_name, payload, reason), merge=True)
        report["top_updates"].append(
            {
                "ingredient": ingredient_name,
                "unitPrice": payload["unitPrice"],
                "baseUnit": payload["baseUnit"],
            }
        )

    for ingredient_name, units in CURATED_UNIT_OVERRIDES.items():
        for unit_key, payload in units.items():
            unit_ref = (
                db.collection("ingredient_unit_prices")
                .document(ingredient_name)
                .collection("units")
                .document(unit_key)
            )
            reason = f"Curated override applied for {ingredient_name}/{unit_key}"
            unit_ref.set(_merge_payload(ingredient_name, payload, reason), merge=True)
            report["unit_updates"].append(
                {
                    "ingredient": ingredient_name,
                    "unitKey": unit_key,
                    "unitPrice": payload["unitPrice"],
                    "baseUnit": payload["baseUnit"],
                }
            )

    for ingredient_name, unit_keys in CURATED_UNIT_DELETES.items():
        for unit_key in unit_keys:
            unit_ref = (
                db.collection("ingredient_unit_prices")
                .document(ingredient_name)
                .collection("units")
                .document(unit_key)
            )
            unit_ref.delete()
            report["unit_deletes"].append(
                {
                    "ingredient": ingredient_name,
                    "unitKey": unit_key,
                }
            )

    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
