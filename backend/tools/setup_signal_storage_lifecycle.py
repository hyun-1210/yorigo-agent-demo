"""signals/raw/ 원본 배치 파일 자동 삭제(Storage lifecycle rule) 설정 스크립트.

`signal_export_scheduler`가 매일 최근 N일치 raw 파일을 다시 훑어
`signals/processed/dt=.../events.jsonl.gz`로 합치지만, raw 원본 자체는
코드에서 직접 삭제하지 않는다(재처리/디버깅 여지를 남기기 위함). 대신 이
스크립트로 버킷 레벨 lifecycle 규칙을 걸어 `signals/raw/` 하위 객체가
N일(기본 14일)이 지나면 GCS가 자동으로 지우도록 한다 — 이벤트가 아무리
쌓여도 raw 스토리지 비용이 무한정 커지지 않게 캡핑한다.
`signals/processed/`(gzip 취합본)는 대상이 아니므로 계속 보존된다.

한 번만 실행하면 되는 버킷 설정이라 스케줄러가 아니라 수동 실행 스크립트로
둔다(버킷 설정은 매우 드물게 바뀜).

사용 예:
  python backend/tools/setup_signal_storage_lifecycle.py
  python backend/tools/setup_signal_storage_lifecycle.py --raw-retention-days 7
  python backend/tools/setup_signal_storage_lifecycle.py --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
RAW_PREFIX = "signals/raw/"
DEFAULT_RETENTION_DAYS = 14


def _load_env() -> None:
    env_path = BACKEND_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k, v = k.strip(), v.strip()
        if k and k not in os.environ:
            os.environ[k] = v


def _init_app():
    import firebase_admin
    from firebase_admin import credentials

    if firebase_admin._apps:
        return firebase_admin.get_app()

    _load_env()
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    bucket_env = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    options = {"storageBucket": bucket_env} if bucket_env else {}

    path = Path(service_account_json) if service_account_json else (
        BACKEND_DIR / "firebase-service-account.json"
    )
    if not path.is_absolute():
        path = BACKEND_DIR / path
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            cred_dict = json.load(f)
        return firebase_admin.initialize_app(
            credentials.Certificate(cred_dict), options or None
        )
    if service_account_json:
        cred_dict = json.loads(service_account_json)
        return firebase_admin.initialize_app(
            credentials.Certificate(cred_dict), options or None
        )
    raise RuntimeError(
        "Firebase 서비스 계정을 찾을 수 없습니다 (FIREBASE_SERVICE_ACCOUNT_JSON "
        "또는 backend/firebase-service-account.json 필요)."
    )


def _default_bucket_name(app) -> str:
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    project_id = app.project_id
    if not project_id:
        raise RuntimeError("project_id를 확인할 수 없습니다.")
    return f"{project_id}.firebasestorage.app"


def setup(*, retention_days: int, dry_run: bool) -> None:
    from firebase_admin import storage

    app = _init_app()
    bucket_name = _default_bucket_name(app)
    print(f"[Lifecycle] bucket={bucket_name}")
    print(
        f"[Lifecycle] rule: delete objects under '{RAW_PREFIX}' "
        f"older than {retention_days} days"
    )

    if dry_run:
        print("[Lifecycle] --dry-run 지정: 실제 API 호출은 생략합니다.")
        return

    bucket = storage.bucket(bucket_name, app=app)
    existing_rules = list(bucket.lifecycle_rules or [])

    # 같은 prefix를 대상으로 한 기존 규칙은 교체(중복 누적 방지).
    def _is_signal_raw_rule(rule: dict) -> bool:
        condition = rule.get("condition", {})
        prefixes = condition.get("matchesPrefix") or condition.get("matches_prefix")
        return bool(prefixes) and RAW_PREFIX in prefixes

    kept_rules = [r for r in existing_rules if not _is_signal_raw_rule(r)]
    new_rule = {
        "action": {"type": "Delete"},
        "condition": {
            "age": retention_days,
            "matchesPrefix": [RAW_PREFIX],
        },
    }
    bucket.lifecycle_rules = kept_rules + [new_rule]
    bucket.patch()
    print(
        f"[Lifecycle] 적용 완료: 총 {len(kept_rules) + 1}개 규칙 "
        f"(기존 다른 규칙 {len(kept_rules)}개 유지)"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--raw-retention-days",
        type=int,
        default=DEFAULT_RETENTION_DAYS,
        help=f"signals/raw/ 보관 기간(일), 기본값 {DEFAULT_RETENTION_DAYS}",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        setup(retention_days=args.raw_retention_days, dry_run=args.dry_run)
    except Exception as e:
        print(f"[Lifecycle] 실패: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
