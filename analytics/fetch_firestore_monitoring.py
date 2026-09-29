#!/usr/bin/env python3
"""Firestore Cloud Monitoring 메트릭을 서비스 계정으로 조회한다.

gcloud 없이 google-cloud-monitoring + firebase-service-account.json 사용.
컬렉션별 breakdown은 Monitoring API에 없을 수 있어, 전체 billable/document
카운트와 사용 가능한 metric descriptor를 먼저 확인한다.

사용:
  python analytics/fetch_firestore_monitoring.py
  python analytics/fetch_firestore_monitoring.py --days 45 --list-metrics-only
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from google.cloud import monitoring_v3
from google.oauth2 import service_account
from google.protobuf.timestamp_pb2 import Timestamp


DEFAULT_PROJECT = "yorigo-f7408"
DEFAULT_SA = Path(__file__).resolve().parents[1] / "backend" / "firebase-service-account.json"

CANDIDATE_METRICS: List[str] = [
    "firestore.googleapis.com/document/read_count",
    "firestore.googleapis.com/document/write_count",
    "firestore.googleapis.com/document/delete_count",
    "firestore.googleapis.com/document/read_ops_count",
    "firestore.googleapis.com/document/write_ops_count",
    "firestore.googleapis.com/api/request_count",
    "firestore.googleapis.com/api/billable_read_units",
    "firestore.googleapis.com/api/billable_write_units",
    "firestore.googleapis.com/query_stat/per_query/scanned_documents_counts",
    "firestore.googleapis.com/query_stat/per_query/scanned_index_entries_counts",
    "firestore.googleapis.com/network/snapshot_listeners",
]


def load_credentials(sa_path: Path) -> Tuple[service_account.Credentials, str]:
    if not sa_path.is_file():
        raise SystemExit(f"서비스 계정 파일 없음: {sa_path}")
    with sa_path.open(encoding="utf-8") as f:
        info = json.load(f)
    project = str(info.get("project_id") or DEFAULT_PROJECT)
    creds = service_account.Credentials.from_service_account_file(
        str(sa_path),
        scopes=["https://www.googleapis.com/auth/monitoring.read"],
    )
    return creds, project


def list_firestore_metric_types(
    client: monitoring_v3.MetricServiceClient,
    project: str,
) -> List[Dict[str, Any]]:
    name = f"projects/{project}"
    out: List[Dict[str, Any]] = []
    for desc in client.list_metric_descriptors(
        request={
            "name": name,
            "filter": 'metric.type = starts_with("firestore.googleapis.com/")',
        }
    ):
        labels = []
        for label in desc.labels:
            try:
                vt = label.value_type.name  # type: ignore[attr-defined]
            except Exception:
                vt = str(label.value_type)
            labels.append(
                {
                    "key": label.key,
                    "description": label.description,
                    "value_type": vt,
                }
            )
        try:
            metric_kind = desc.metric_kind.name  # type: ignore[attr-defined]
        except Exception:
            metric_kind = str(desc.metric_kind)
        try:
            value_type = desc.value_type.name  # type: ignore[attr-defined]
        except Exception:
            value_type = str(desc.value_type)
        out.append(
            {
                "type": desc.type,
                "display_name": desc.display_name,
                "metric_kind": metric_kind,
                "value_type": value_type,
                "labels": labels,
            }
        )
    return sorted(out, key=lambda x: x["type"])


def _point_number(point: Any) -> Optional[float]:
    value = point.value
    pb = getattr(value, "_pb", None)
    if pb is not None:
        which = pb.WhichOneof("value")
        if which == "int64_value":
            return float(pb.int64_value)
        if which == "double_value":
            return float(pb.double_value)
        if which == "distribution_value":
            # distribution은 count를 사용
            try:
                return float(pb.distribution_value.count)
            except Exception:
                return None
        return None
    # fallback
    try:
        return float(value.int64_value)
    except Exception:
        pass
    try:
        return float(value.double_value)
    except Exception:
        return None


def fetch_aligned_sum(
    client: monitoring_v3.MetricServiceClient,
    project: str,
    metric_type: str,
    start: datetime,
    end: datetime,
    alignment_seconds: int = 86400,
    group_by_fields: Optional[List[str]] = None,
) -> Dict[str, Any]:
    project_name = f"projects/{project}"
    interval = monitoring_v3.TimeInterval(
        {
            "start_time": Timestamp(seconds=int(start.timestamp())),
            "end_time": Timestamp(seconds=int(end.timestamp())),
        }
    )
    aggregation = monitoring_v3.Aggregation(
        {
            "alignment_period": {"seconds": alignment_seconds},
            "per_series_aligner": monitoring_v3.Aggregation.Aligner.ALIGN_SUM,
            "cross_series_reducer": monitoring_v3.Aggregation.Reducer.REDUCE_SUM,
            "group_by_fields": group_by_fields or [],
        }
    )
    request = monitoring_v3.ListTimeSeriesRequest(
        {
            "name": project_name,
            "filter": f'metric.type = "{metric_type}"',
            "interval": interval,
            "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
            "aggregation": aggregation,
        }
    )

    daily: Dict[str, float] = {}
    total = 0.0
    series_count = 0
    label_totals: Dict[str, float] = {}

    for ts in client.list_time_series(request=request):
        series_count += 1
        label_key = ",".join(
            f"{k}={v}" for k, v in sorted((ts.metric.labels or {}).items())
        ) or "(no_metric_labels)"
        series_sum = 0.0
        for point in ts.points:
            num = _point_number(point)
            if num is None:
                continue
            end_time = point.interval.end_time
            if hasattr(end_time, "timestamp"):
                day = datetime.fromtimestamp(
                    end_time.timestamp(), tz=timezone.utc
                ).strftime("%Y-%m-%d")
            else:
                day = str(end_time)[:10]
            daily[day] = daily.get(day, 0.0) + num
            total += num
            series_sum += num
        label_totals[label_key] = label_totals.get(label_key, 0.0) + series_sum

    return {
        "total": total,
        "series_count": series_count,
        "daily": [{"date": d, "value": daily[d]} for d in sorted(daily)],
        "by_metric_labels": [
            {"labels": k, "total": v}
            for k, v in sorted(label_totals.items(), key=lambda x: -x[1])[:50]
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=os.getenv("GCP_PROJECT_ID", DEFAULT_PROJECT))
    parser.add_argument(
        "--sa",
        default=os.getenv("GOOGLE_APPLICATION_CREDENTIALS", str(DEFAULT_SA)),
    )
    parser.add_argument("--days", type=int, default=45)
    parser.add_argument("--list-metrics-only", action="store_true")
    parser.add_argument(
        "--out",
        default=str(Path(__file__).with_name("firestore_monitoring_snapshot.json")),
    )
    args = parser.parse_args()

    creds, sa_project = load_credentials(Path(args.sa))
    project = args.project or sa_project
    client = monitoring_v3.MetricServiceClient(credentials=creds)

    print(f"[ok] project={project}")
    print(f"[ok] sa={args.sa}")

    try:
        metrics = list_firestore_metric_types(client, project)
    except Exception as e:
        print(f"[error] list_metric_descriptors failed: {e}")
        print(
            "서비스 계정에 roles/monitoring.viewer 가 없을 수 있습니다.\n"
            "GCP Console → IAM → firebase-adminsdk... 에 Monitoring Viewer 추가 후 재실행하세요."
        )
        return 1

    print(f"[metrics] {len(metrics)} firestore descriptors")
    for m in metrics:
        label_keys = ",".join(l["key"] for l in m["labels"]) or "-"
        print(f"  - {m['type']}  labels=[{label_keys}]")

    payload: Dict[str, Any] = {
        "project": project,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "available_firestore_metrics": metrics,
        "series": {},
    }

    if args.list_metrics_only:
        Path(args.out).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"[out] {args.out}")
        return 0

    end = datetime.now(timezone.utc)
    start = end - timedelta(days=args.days)
    payload["window"] = {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "days": args.days,
    }

    available_types = {m["type"] for m in metrics}
    targets = [m for m in CANDIDATE_METRICS if m in available_types] or [
        m["type"]
        for m in metrics
        if any(k in m["type"] for k in ("read", "write", "request"))
    ]

    # request_count 는 op 라벨로 그룹하면 유용할 수 있음
    for metric in targets:
        print(f"\n[fetch] {metric}")
        try:
            data = fetch_aligned_sum(client, project, metric, start, end)
            payload["series"][metric] = data
            print(f"  total={data['total']:,.0f}  days={len(data['daily'])}")
            for row in data["daily"][-7:]:
                print(f"    {row['date']}: {row['value']:,.0f}")
            if data["by_metric_labels"] and data["by_metric_labels"][0]["labels"] != "(no_metric_labels)":
                print("  top labels:")
                for row in data["by_metric_labels"][:8]:
                    print(f"    {row['labels']}: {row['total']:,.0f}")
        except Exception as e:
            payload["series"][metric] = {"error": str(e)}
            print(f"  ERROR: {e}")

    # api/request_count 가 있으면 type/op 라벨 분해 추가 시도
    if "firestore.googleapis.com/api/request_count" in available_types:
        print("\n[fetch] api/request_count grouped by metric.labels")
        try:
            # group_by metric label keys if present
            req_meta = next(
                m for m in metrics if m["type"] == "firestore.googleapis.com/api/request_count"
            )
            group_fields = [f"metric.labels.{l['key']}" for l in req_meta["labels"]]
            if group_fields:
                grouped = fetch_aligned_sum(
                    client,
                    project,
                    "firestore.googleapis.com/api/request_count",
                    start,
                    end,
                    group_by_fields=group_fields,
                )
                payload["series"]["firestore.googleapis.com/api/request_count__grouped"] = grouped
                print(f"  grouped total={grouped['total']:,.0f}")
                for row in grouped["by_metric_labels"][:15]:
                    print(f"    {row['labels']}: {row['total']:,.0f}")
        except Exception as e:
            print(f"  grouped ERROR: {e}")

    Path(args.out).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n[out] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
