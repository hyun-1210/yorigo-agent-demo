#!/usr/bin/env python3
"""Firestore Query/Usage Insights를 서비스 계정으로 조회한다.

콘솔의 '쿼리 통계 / 사용량 인사이트'와 같은 내부 Admin API를 호출한다.
공식 public discovery에는 없지만, SA + cloud-platform 스코프로 동작한다.

사용:
  python analytics/fetch_firestore_insights.py
  python analytics/fetch_firestore_insights.py --hours 24
  python analytics/fetch_firestore_insights.py --days 7 --out analytics/firestore_insights.json
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import google.auth.transport.requests
from google.oauth2 import service_account

DEFAULT_PROJECT = "yorigo-f7408"
DEFAULT_SA = Path(__file__).resolve().parents[1] / "backend" / "firebase-service-account.json"
DEFAULT_OUT = Path(__file__).resolve().parent / "firestore_insights_snapshot.json"

# google.firestore.admin.v1.DataType — 숫자 enum (discovery 미공개)
DATA_TYPE_QUERY_INSIGHTS = 1  # 콘솔 쿼리 통계(Query Insights)
DATA_TYPE_USAGE_INSIGHTS = 2  # 콘솔 사용량 인사이트(컬렉션별)

SCOPES = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/datastore",
]


def _session(sa_path: Path) -> tuple[google.auth.transport.requests.AuthorizedSession, str]:
    if not sa_path.is_file():
        raise SystemExit(f"서비스 계정 파일 없음: {sa_path}")
    info = json.loads(sa_path.read_text(encoding="utf-8"))
    project = str(info.get("project_id") or DEFAULT_PROJECT)
    creds = service_account.Credentials.from_service_account_file(
        str(sa_path), scopes=SCOPES
    )
    return google.auth.transport.requests.AuthorizedSession(creds), project


def _interval(hours: Optional[int], days: Optional[int]) -> Dict[str, str]:
    end = datetime.now(timezone.utc)
    if hours is not None:
        start = end - timedelta(hours=hours)
    else:
        start = end - timedelta(days=days or 1)
    return {
        "startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def fetch_aggregated_insights(
    session: google.auth.transport.requests.AuthorizedSession,
    project: str,
    interval: Dict[str, str],
    data_type: int,
) -> Dict[str, Any]:
    """콘솔 Insights aggregated API를 호출한다."""
    url = (
        f"https://firestore.googleapis.com/v1/projects/{project}/"
        f"databases/(default):queryTopAggregatedInsightsData"
    )
    resp = session.post(
        url,
        json={"interval": interval, "type": data_type},
        timeout=60,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"insights API {resp.status_code}: {resp.text[:800]}")
    return resp.json()


def _to_int(v: Any) -> Optional[int]:
    if v is None:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _to_float(v: Any) -> Optional[float]:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def normalize_queries(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Query Insights 응답을 분석용 행으로 정규화한다."""
    queries = (
        (payload.get("topQueries") or {}).get("queries")
        or payload.get("queries")
        or []
    )
    rows: List[Dict[str, Any]] = []
    for q in queries:
        if not isinstance(q, dict):
            continue
        exec_count = _to_int(q.get("execCount")) or 0
        total_reads = _to_int(q.get("totalReadOperations")) or 0
        avg_docs = _to_float(q.get("avgDocumentsScanned"))
        rows.append(
            {
                "id": q.get("id"),
                "text": q.get("text"),
                "exec_count": exec_count,
                "total_read_operations": total_reads,
                "avg_execution_duration": q.get("avgExecutionDuration"),
                "avg_results_returned": _to_float(q.get("avgResultsReturned")),
                "avg_documents_scanned": avg_docs,
                "avg_index_entries_scanned": _to_float(q.get("avgIndexEntriesScanned")),
                "estimated_docs_scanned_total": (
                    round(avg_docs * exec_count) if avg_docs is not None else None
                ),
                "api": q.get("api"),
                "query_json": q.get("queryJson"),
            }
        )
    rows.sort(
        key=lambda r: (
            r.get("total_read_operations") or 0,
            r.get("estimated_docs_scanned_total") or 0,
        ),
        reverse=True,
    )
    return rows


def normalize_usage(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Usage Insights(컬렉션별) 응답을 정규화한다."""
    usage = (payload.get("usageInsights") or {}).get("usageData") or []
    rows: List[Dict[str, Any]] = []
    for item in usage:
        if not isinstance(item, dict):
            continue
        rows.append(
            {
                "collection": item.get("collectionId")
                or item.get("collectionGroupId")
                or item.get("name")
                or item.get("dimensionValue"),
                "total_read_operations": _to_int(item.get("totalReadOperationCount")),
                "total_write_operations": _to_int(item.get("totalWriteOperationCount")),
                "total_read_bytes": _to_int(item.get("totalReadBytes")),
                "total_scanned_entities": _to_int(item.get("totalScannedEntityCount")),
                "total_scanned_index_entries": _to_int(
                    item.get("totalScannedIndexEntryCount")
                ),
                "raw": item,
            }
        )
    rows.sort(key=lambda r: r.get("total_read_operations") or 0, reverse=True)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Firestore Query/Usage Insights 조회")
    parser.add_argument("--sa", type=Path, default=DEFAULT_SA)
    parser.add_argument("--hours", type=int, default=None)
    parser.add_argument("--days", type=int, default=1)
    parser.add_argument(
        "--mode",
        choices=("query", "usage", "both"),
        default="both",
        help="query=쿼리 통계, usage=컬렉션별 사용량, both=둘 다",
    )
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()

    session, project = _session(args.sa)
    interval = _interval(args.hours, args.days)
    print(f"[insights] project={project} interval={interval} mode={args.mode}")

    out: Dict[str, Any] = {
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "project": project,
        "database": "(default)",
        "interval": interval,
        "mode": args.mode,
    }

    if args.mode in ("query", "both"):
        raw_q = fetch_aggregated_insights(
            session, project, interval, DATA_TYPE_QUERY_INSIGHTS
        )
        rows_q = normalize_queries(raw_q)
        out["queries"] = rows_q[: max(1, args.top)]
        out["query_count"] = len(rows_q)
        print(f"[insights] query fingerprints={len(rows_q)}")
        for i, row in enumerate(rows_q[: min(15, args.top)], 1):
            print(
                f"  Q{i:02d}. reads={row['total_read_operations']:>10,}  "
                f"exec={row['exec_count']:>5}  "
                f"avgDocs={row['avg_documents_scanned']}  "
                f"{row['text']}"
            )

    if args.mode in ("usage", "both"):
        raw_u = fetch_aggregated_insights(
            session, project, interval, DATA_TYPE_USAGE_INSIGHTS
        )
        rows_u = normalize_usage(raw_u)
        out["usage_by_collection"] = rows_u[: max(1, args.top)]
        out["usage_count"] = len(rows_u)
        print(f"[insights] usage collections={len(rows_u)}")
        for i, row in enumerate(rows_u[: min(15, args.top)], 1):
            print(
                f"  U{i:02d}. reads={row['total_read_operations'] or 0:>10,}  "
                f"writes={row['total_write_operations'] or 0:>8,}  "
                f"{row['collection']}"
            )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"[out] {args.out}")


if __name__ == "__main__":
    main()
