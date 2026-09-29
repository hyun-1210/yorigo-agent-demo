"""
Firestore users 컬렉션에서 연령 검증 상태를 점검하는 운영 스크립트.

사용 예:
python backend/tools/audit_underage_accounts.py --limit 200
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from typing import Optional
from zoneinfo import ZoneInfo
import argparse
import json

from services.firebase_service import get_firebase_service

KST = ZoneInfo("Asia/Seoul")
MIN_SIGNUP_AGE = 14


@dataclass
class AuditSummary:
    scanned: int = 0
    missing_birth_date: int = 0
    missing_verified_flag: int = 0
    under_14: int = 0


def _calculate_age_in_kst(birth_date: date) -> int:
    today = datetime.now(KST).date()
    return today.year - birth_date.year - ((today.month, today.day) < (birth_date.month, birth_date.day))


def _parse_birth_date(raw_value: object) -> Optional[date]:
    if not isinstance(raw_value, str):
        return None
    try:
        return date.fromisoformat(raw_value.strip())
    except ValueError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit underage or unverified user accounts")
    parser.add_argument("--limit", type=int, default=500, help="최대 조회 사용자 수")
    args = parser.parse_args()

    firebase_service = get_firebase_service()
    if not firebase_service.is_available() or firebase_service.db is None:
        raise RuntimeError("Firebase service is not available")

    db = firebase_service.db
    summary = AuditSummary()
    issues: list[dict] = []

    docs = db.collection("users").limit(args.limit).stream()
    for doc in docs:
        summary.scanned += 1
        data = doc.to_dict() or {}
        birth_date_raw = data.get("birthDate")
        parsed_birth_date = _parse_birth_date(birth_date_raw)
        is_verified = data.get("isAgeVerified14Plus") is True

        if parsed_birth_date is None:
            summary.missing_birth_date += 1
            issues.append(
                {
                    "uid": doc.id,
                    "issue": "missing_birth_date",
                    "signupProvider": data.get("signupProvider"),
                }
            )
            continue

        if not is_verified:
            summary.missing_verified_flag += 1
            issues.append(
                {
                    "uid": doc.id,
                    "issue": "missing_verified_flag",
                    "birthDate": parsed_birth_date.isoformat(),
                    "signupProvider": data.get("signupProvider"),
                }
            )

        age = _calculate_age_in_kst(parsed_birth_date)
        if age < MIN_SIGNUP_AGE:
            summary.under_14 += 1
            issues.append(
                {
                    "uid": doc.id,
                    "issue": "under_14",
                    "age": age,
                    "birthDate": parsed_birth_date.isoformat(),
                    "signupProvider": data.get("signupProvider"),
                }
            )

    payload = {
        "summary": {
            "scanned": summary.scanned,
            "missing_birth_date": summary.missing_birth_date,
            "missing_verified_flag": summary.missing_verified_flag,
            "under_14": summary.under_14,
        },
        "issues": issues,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
