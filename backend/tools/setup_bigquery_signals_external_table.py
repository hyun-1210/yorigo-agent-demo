"""BigQuery 외부 테이블(yorigo_signals.raw_events) 생성/갱신 스크립트.

`signals/processed/dt={yyyy-MM-dd}/events.jsonl.gz` (Firebase Storage, Hive
파티션 레이아웃)를 BigQuery에서 직접 조회할 수 있도록 외부 테이블을 만든다.
데이터를 BigQuery로 별도 로드/복사하지 않으므로 스토리지 비용이 중복되지
않고, GCS에 파일이 추가되는 즉시(스케줄러가 갱신한 직후) 쿼리에 반영된다.

사전 준비:
  1. 이 스크립트를 실행할 서비스 계정에 BigQuery IAM 역할 부여 필요:
     - roles/bigquery.dataEditor (데이터셋/테이블 생성)
     - roles/bigquery.jobUser (쿼리/작업 실행)
     기본값은 backend/firebase-service-account.json 재사용 — Firebase 콘솔이
     아니라 GCP IAM 콘솔(https://console.cloud.google.com/iam-admin/iam)에서
     해당 서비스 계정 이메일에 위 역할을 추가해야 한다. 별도 키를 쓰려면
     BIGQUERY_SERVICE_ACCOUNT_JSON 환경변수로 경로/JSON을 지정한다.
  2. GCP 프로젝트에서 BigQuery API가 활성화돼 있어야 한다
     (https://console.cloud.google.com/apis/library/bigquery.googleapis.com).

사용 예:
  python backend/tools/setup_bigquery_signals_external_table.py
  python backend/tools/setup_bigquery_signals_external_table.py --dry-run
  python backend/tools/setup_bigquery_signals_external_table.py --location asia-northeast3

멱등성: 이미 데이터셋/테이블이 있으면 external_data_configuration만
최신 스키마로 갱신한다(존재 여부와 무관하게 여러 번 실행해도 안전).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

BACKEND_DIR = Path(__file__).resolve().parents[1]

DATASET_ID = "yorigo_signals"
TABLE_ID = "raw_events"
DEFAULT_LOCATION = "asia-northeast3"  # Seoul — 한국 사용자 기반 서비스 기본 리전
PROCESSED_PREFIX = "signals/processed"

# analytics_service.dart의 logCardEvent()가 실어 보내는 필드와 1:1 대응.
# 명시적 스키마를 쓰는 이유: JSON autodetect는 필드 순서·null 배치에 따라
# 타입을 잘못 추론할 수 있어 프로덕션 쿼리에서 예측 가능한 타입이 더 중요하다.
EVENT_SCHEMA_FIELDS: list[tuple[str, str, str]] = [
    ("eventId", "STRING", "NULLABLE"),
    ("eventType", "STRING", "NULLABLE"),
    ("clientTs", "TIMESTAMP", "NULLABLE"),
    ("userId", "STRING", "NULLABLE"),
    ("sessionId", "STRING", "NULLABLE"),
    ("deviceId", "STRING", "NULLABLE"),
    ("appVersion", "STRING", "NULLABLE"),
    ("platform", "STRING", "NULLABLE"),
    ("screen", "STRING", "NULLABLE"),
    ("sectionId", "STRING", "NULLABLE"),
    ("posterId", "STRING", "NULLABLE"),
    ("chipSectionKey", "STRING", "NULLABLE"),
    ("cardId", "STRING", "NULLABLE"),
    ("contentType", "STRING", "NULLABLE"),
    ("recipeId", "STRING", "NULLABLE"),
    ("position", "INTEGER", "NULLABLE"),
    ("recipeCuisineType", "STRING", "REPEATED"),
    ("recipeTimeCategory", "STRING", "REPEATED"),
    ("recipeMenuType", "STRING", "REPEATED"),
    ("recipeMainIngredient", "STRING", "REPEATED"),
    ("recipeMainIngredientSub", "STRING", "REPEATED"),
    ("recipeTags", "STRING", "REPEATED"),
    ("recipeNutritionRating", "STRING", "NULLABLE"),
    ("recipeIngredientCategories", "STRING", "REPEATED"),
    ("recipeSourcePlatform", "STRING", "NULLABLE"),
    ("recipeServings", "INTEGER", "NULLABLE"),
    ("marketplace", "STRING", "NULLABLE"),
    ("productId", "STRING", "NULLABLE"),
    ("ingredientName", "STRING", "NULLABLE"),
    ("price", "INTEGER", "NULLABLE"),
    ("productRating", "FLOAT", "NULLABLE"),
    ("productReviewCount", "INTEGER", "NULLABLE"),
    ("productBayesianRating", "FLOAT", "NULLABLE"),
    ("productValueScore", "FLOAT", "NULLABLE"),
    ("productIsRocket", "BOOLEAN", "NULLABLE"),
    ("productIsFreeShipping", "BOOLEAN", "NULLABLE"),
    ("productDiscountRate", "FLOAT", "NULLABLE"),
    ("productUnitPrice", "FLOAT", "NULLABLE"),
    ("productPackageSize", "FLOAT", "NULLABLE"),
    ("productPackageUnit", "STRING", "NULLABLE"),
    ("productSalesRank", "INTEGER", "NULLABLE"),
]


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


def _load_service_account_info() -> dict:
    """BIGQUERY_SERVICE_ACCOUNT_JSON 우선, 없으면 FIREBASE_SERVICE_ACCOUNT_JSON 재사용."""
    _load_env()
    raw = (
        os.getenv("BIGQUERY_SERVICE_ACCOUNT_JSON", "").strip()
        or os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    )
    if not raw:
        # 파일명 규칙(firebase-service-account.json)도 백업으로 탐색.
        candidate = BACKEND_DIR / "firebase-service-account.json"
        if candidate.exists():
            raw = str(candidate)
        else:
            raise RuntimeError(
                "서비스 계정 JSON을 찾을 수 없습니다. BIGQUERY_SERVICE_ACCOUNT_JSON "
                "또는 FIREBASE_SERVICE_ACCOUNT_JSON 환경변수를 설정하거나 "
                "backend/firebase-service-account.json 파일을 두세요."
            )
    path = Path(raw)
    if not path.is_absolute():
        path = BACKEND_DIR / raw
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return json.loads(raw)


def _resolve_bucket_name(project_id: str) -> str:
    env_bucket = os.getenv("FIREBASE_STORAGE_BUCKET", "").strip()
    if env_bucket:
        return env_bucket
    return f"{project_id}.firebasestorage.app"


def _build_external_config(bucket_name: str):
    from google.cloud import bigquery

    schema = [
        bigquery.SchemaField(name, field_type, mode=mode)
        for name, field_type, mode in EVENT_SCHEMA_FIELDS
    ]

    external_config = bigquery.ExternalConfig("NEWLINE_DELIMITED_JSON")
    external_config.source_uris = [f"gs://{bucket_name}/{PROCESSED_PREFIX}/*"]
    external_config.schema = schema
    external_config.ignore_unknown_values = True
    # gzip 압축 파일 그대로 읽음 — 압축 해제/재업로드 불필요.
    external_config.compression = "GZIP"

    hive_partitioning = bigquery.HivePartitioningOptions()
    hive_partitioning.mode = "AUTO"
    hive_partitioning.source_uri_prefix = f"gs://{bucket_name}/{PROCESSED_PREFIX}/"
    # True로 강제: dt 필터 없는 쿼리를 차단해 실수로 전체 히스토리를 풀스캔하는
    # 사고(=쿼리 바이트 과금 폭탄)를 원천 차단한다. AUTO 모드라 dt는 DATE 타입으로
    # 추론되므로 필터는 'dt = CURRENT_DATE()' 처럼 DATE 리터럴/함수로 비교해야 한다
    # (FORMAT_DATE(...)로 만든 STRING과 비교하면 타입 불일치 오류가 난다).
    hive_partitioning.require_partition_filter = True
    external_config.hive_partitioning = hive_partitioning

    return external_config


def setup(
    *,
    location: str = DEFAULT_LOCATION,
    dry_run: bool = False,
) -> None:
    info = _load_service_account_info()
    project_id: Optional[str] = info.get("project_id") or os.getenv(
        "FIREBASE_PROJECT_ID", ""
    ).strip()
    if not project_id:
        raise RuntimeError("서비스 계정 JSON에 project_id가 없습니다.")

    bucket_name = _resolve_bucket_name(project_id)
    source_uri = f"gs://{bucket_name}/{PROCESSED_PREFIX}/*"

    print(f"[Setup] project_id={project_id}")
    print(f"[Setup] dataset={DATASET_ID}, table={TABLE_ID}, location={location}")
    print(f"[Setup] source_uris={source_uri}")
    print(f"[Setup] hive_partitioning: dt=YYYY-MM-DD (from {PROCESSED_PREFIX}/)")
    print(f"[Setup] schema fields: {len(EVENT_SCHEMA_FIELDS)}개")

    if dry_run:
        print("[Setup] --dry-run 지정: 실제 BigQuery 호출은 생략합니다.")
        return

    from google.cloud import bigquery
    from google.cloud.exceptions import NotFound
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_info(info)
    client = bigquery.Client(project=project_id, credentials=credentials)

    dataset_ref = bigquery.DatasetReference(project_id, DATASET_ID)
    try:
        client.get_dataset(dataset_ref)
        print(f"[Setup] 데이터셋 {DATASET_ID} 이미 존재")
    except NotFound:
        dataset = bigquery.Dataset(dataset_ref)
        dataset.location = location
        client.create_dataset(dataset)
        print(f"[Setup] 데이터셋 {DATASET_ID} 생성 완료 (location={location})")

    external_config = _build_external_config(bucket_name)
    table_ref = dataset_ref.table(TABLE_ID)
    table = bigquery.Table(table_ref)
    table.external_data_configuration = external_config

    try:
        client.get_table(table_ref)
        table_exists = True
    except NotFound:
        table_exists = False

    if not table_exists:
        client.create_table(table)
        print(f"[Setup] 외부 테이블 {DATASET_ID}.{TABLE_ID} 생성 완료")
    else:
        try:
            client.update_table(table, ["external_data_configuration"])
            print(f"[Setup] 외부 테이블 {DATASET_ID}.{TABLE_ID} 스키마/설정 갱신 완료")
        except Exception as e:
            # hive_partitioning 옵션(require_partition_filter 등) 변경은 PATCH가
            # 거부될 수 있음: 외부 테이블은 데이터 자체가 아니라 메타데이터일
            # 뿐이므로 안전하게 삭제 후 재생성한다(BigQuery 저장 데이터 없음,
            # GCS 원본은 그대로라 데이터 유실 없음).
            print(f"[Setup] 부분 갱신 실패({e}): 삭제 후 재생성으로 폴백")
            client.delete_table(table_ref)
            client.create_table(table)
            print(f"[Setup] 외부 테이블 {DATASET_ID}.{TABLE_ID} 재생성 완료")

    print(
        "[Setup] 완료. 예시 쿼리(dt는 DATE 타입, require_partition_filter=True라 "
        "dt 필터 없이는 쿼리 자체가 거부됨):\n"
        f"  SELECT eventType, COUNT(*) FROM `{project_id}.{DATASET_ID}.{TABLE_ID}`\n"
        "  WHERE dt = DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)\n"
        "  GROUP BY eventType\n"
        "  -- 날짜 범위 조회: WHERE dt BETWEEN '2026-01-01' AND '2026-01-31'"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--location",
        default=DEFAULT_LOCATION,
        help=f"BigQuery 데이터셋 리전 (기본값: {DEFAULT_LOCATION})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="실제 API 호출 없이 설정 내용만 출력",
    )
    args = parser.parse_args()

    try:
        setup(location=args.location, dry_run=args.dry_run)
    except Exception as e:
        print(f"[Setup] 실패: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
