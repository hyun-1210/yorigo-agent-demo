#!/usr/bin/env python3
"""Firestore 일일 가드: 7일 배수 + 핑거프린트 규칙 → 리포트 (자동 수정 없음).

사용:
  python analytics/firestore_daily_guard.py
  python analytics/firestore_daily_guard.py --offline \\
      --monitoring-json analytics/firestore_monitoring_post_ec2_stop_14d.json \\
      --insights-json analytics/firestore_insights_post_ec2_12h.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

ANALYTICS_DIR = Path(__file__).resolve().parent
REPO_ROOT = ANALYTICS_DIR.parent
DEFAULT_SA = REPO_ROOT / "backend" / "firebase-service-account.json"
DEFAULT_THRESHOLDS = ANALYTICS_DIR / "firestore_guard_thresholds.json"

METRIC_SOURCES = {
    "document_reads": "firestore.googleapis.com/document/read_count",
    "document_writes": "firestore.googleapis.com/document/write_count",
    "api_requests": "firestore.googleapis.com/api/request_count",
}

EXIT_OK = 0
EXIT_WARNING = 10
EXIT_CRITICAL = 20


def load_thresholds(path: Path) -> Dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        "warning_median_ratio": float(data.get("warning_median_ratio", 1.5)),
        "critical_median_ratio": float(data.get("critical_median_ratio", 2.0)),
        "underage_exec_warning": int(data.get("underage_exec_warning", 3)),
        "coupang_full_scan_min_avg_docs": float(
            data.get("coupang_full_scan_min_avg_docs", 1000)
        ),
        "metrics": list(data.get("metrics") or list(METRIC_SOURCES.keys())),
    }


def daily_map_from_series(daily_rows: Sequence[Dict[str, Any]]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    for row in daily_rows:
        date = str(row.get("date") or "")[:10]
        if not date:
            continue
        try:
            out[date] = float(row.get("value") or 0.0)
        except (TypeError, ValueError):
            continue
    return out


def pick_complete_day(
    daily: Dict[str, float],
    now_utc: Optional[datetime] = None,
) -> Optional[str]:
    """전일(complete UTC day) 날짜 키. 오늘 부분일은 제외.

    Monitoring ALIGN_SUM 버킷 라벨이 하루 어긋날 수 있어, 캘린더 전일을
    우선 사용하고 없을 때만 series 상 최신 complete day로 폴백한다.
    """
    now = now_utc or datetime.now(timezone.utc)
    today = now.date()
    calendar_yesterday = (today - timedelta(days=1)).isoformat()
    if calendar_yesterday in daily:
        return calendar_yesterday
    candidates = sorted(d for d in daily if d < today.isoformat())
    if not candidates:
        return None
    return candidates[-1]


def baseline_window(daily: Dict[str, float], target_day: str, days: int = 7) -> List[float]:
    """target_day 직전 `days`개의 값 (있는 날만, 최대 days개)."""
    prior = sorted(d for d in daily if d < target_day)
    window_days = prior[-days:]
    return [daily[d] for d in window_days]


def ratio(value: float, baseline: float) -> Optional[float]:
    if baseline <= 0:
        return None if value <= 0 else float("inf")
    return value / baseline


def evaluate_metric_spike(
    daily: Dict[str, float],
    *,
    warning_ratio: float,
    critical_ratio: float,
    now_utc: Optional[datetime] = None,
    baseline_days: int = 7,
) -> Dict[str, Any]:
    target = pick_complete_day(daily, now_utc=now_utc)
    if target is None:
        return {
            "status": "insufficient_data",
            "target_day": None,
            "yesterday": None,
            "baseline_values": [],
            "median": None,
            "mean": None,
            "ratio_median": None,
            "ratio_mean": None,
            "verdict": "OK",
        }

    yesterday = float(daily.get(target, 0.0))
    baseline_values = baseline_window(daily, target, days=baseline_days)
    if len(baseline_values) < 3:
        return {
            "status": "insufficient_baseline",
            "target_day": target,
            "yesterday": yesterday,
            "baseline_values": baseline_values,
            "median": None,
            "mean": None,
            "ratio_median": None,
            "ratio_mean": None,
            "verdict": "OK",
        }

    med = float(statistics.median(baseline_values))
    mean = float(statistics.fmean(baseline_values))
    r_med = ratio(yesterday, med)
    r_mean = ratio(yesterday, mean)

    verdict = "OK"
    if r_med is not None and r_med > critical_ratio:
        verdict = "CRITICAL"
    elif r_med is not None and r_med > warning_ratio:
        verdict = "WARNING"

    return {
        "status": "ok",
        "target_day": target,
        "yesterday": yesterday,
        "baseline_values": baseline_values,
        "baseline_count": len(baseline_values),
        "median": med,
        "mean": mean,
        "ratio_median": r_med,
        "ratio_mean": r_mean,
        "verdict": verdict,
    }


def _query_text(row: Dict[str, Any]) -> str:
    return str(row.get("text") or "")


def evaluate_fingerprints(
    queries: Sequence[Dict[str, Any]],
    *,
    underage_exec_warning: int,
    coupang_full_scan_min_avg_docs: float,
) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []

    for row in queries:
        text = _query_text(row)
        exec_count = int(row.get("exec_count") or 0)
        reads = int(row.get("total_read_operations") or 0)
        avg_docs = row.get("avg_documents_scanned")
        try:
            avg_docs_f = float(avg_docs) if avg_docs is not None else None
        except (TypeError, ValueError):
            avg_docs_f = None

        if "coupang_products SELECT __name__" in text and exec_count >= 1:
            findings.append(
                {
                    "id": "GHOST_COUPANG_SELECT_NAME",
                    "severity": "WARNING",
                    "exec_count": exec_count,
                    "reads": reads,
                    "text": text,
                    "evidence": f"exec={exec_count}, reads={reads}",
                }
            )
        elif (
            text.strip() == "COLLECTION /coupang_products"
            and exec_count >= 1
            and avg_docs_f is not None
            and avg_docs_f >= coupang_full_scan_min_avg_docs
        ):
            findings.append(
                {
                    "id": "GHOST_COUPANG_FULL_SCAN",
                    "severity": "WARNING",
                    "exec_count": exec_count,
                    "reads": reads,
                    "text": text,
                    "evidence": f"exec={exec_count}, avgDocs={avg_docs_f}, reads={reads}",
                }
            )
        elif "users LIMIT 1000" in text and exec_count >= underage_exec_warning:
            findings.append(
                {
                    "id": "UNDERAGE_OVERFREQ",
                    "severity": "WARNING",
                    "exec_count": exec_count,
                    "reads": reads,
                    "text": text,
                    "evidence": f"exec={exec_count} (>= {underage_exec_warning}), reads={reads}",
                }
            )
        elif (
            "recipe.ingredients" in text
            and "LIMIT 300" in text
            and "START_AFTER" in text
            and exec_count >= 1
        ) or (
            "SELECT ingredients" in text
            and "LIMIT 300" in text
            and "START_AFTER" in text
            and exec_count >= 1
        ):
            findings.append(
                {
                    "id": "RECIPES_INGREDIENTS_WALK",
                    "severity": "WARNING",
                    "exec_count": exec_count,
                    "reads": reads,
                    "text": text,
                    "evidence": f"exec={exec_count}, reads={reads}",
                }
            )
        elif (
            "recipes SELECT userId, status" in text
            or text.strip() == "COLLECTION /recipes SELECT userId, status"
            or "users SELECT savedRecipes" in text
        ) and exec_count >= 1 and (avg_docs_f or 0) >= 1000:
            findings.append(
                {
                    "id": "SHEETS_EXPORT_FINGERPRINT",
                    "severity": "WARNING",
                    "exec_count": exec_count,
                    "reads": reads,
                    "text": text,
                    "evidence": f"exec={exec_count}, avgDocs={avg_docs_f}, reads={reads}",
                }
            )

    # dedupe by id keeping highest reads
    by_id: Dict[str, Dict[str, Any]] = {}
    for f in findings:
        prev = by_id.get(f["id"])
        if prev is None or int(f["reads"]) >= int(prev["reads"]):
            by_id[f["id"]] = f
    return list(by_id.values())


def overall_verdict(
    metric_results: Dict[str, Dict[str, Any]],
    fingerprints: Sequence[Dict[str, Any]],
) -> str:
    rank = {"OK": 0, "WARNING": 1, "CRITICAL": 2}
    best = "OK"
    for result in metric_results.values():
        v = str(result.get("verdict") or "OK")
        if rank.get(v, 0) > rank[best]:
            best = v
    # fingerprints alone escalate at most to WARNING unless a metric is already CRITICAL
    if fingerprints and best == "OK":
        best = "WARNING"
    return best


def max_median_ratio(metric_results: Dict[str, Dict[str, Any]]) -> Optional[float]:
    ratios: List[float] = []
    for result in metric_results.values():
        r = result.get("ratio_median")
        if r is None:
            continue
        try:
            ratios.append(float(r))
        except (TypeError, ValueError):
            continue
    if not ratios:
        return None
    return max(ratios)


def build_report(
    *,
    fetched_at: str,
    project: str,
    thresholds: Dict[str, Any],
    metric_results: Dict[str, Dict[str, Any]],
    fingerprints: List[Dict[str, Any]],
    top_queries: List[Dict[str, Any]],
    insights_interval: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    verdict = overall_verdict(metric_results, fingerprints)
    max_ratio = max_median_ratio(metric_results)
    return {
        "fetched_at": fetched_at,
        "project": project,
        "verdict": verdict,
        "max_ratio_median": max_ratio,
        "thresholds": {
            "warning_median_ratio": thresholds["warning_median_ratio"],
            "critical_median_ratio": thresholds["critical_median_ratio"],
        },
        "insights_interval": insights_interval,
        "metrics": metric_results,
        "fingerprints": fingerprints,
        "top_queries": top_queries[:10],
        "auto_remediation": False,
        "note": "Email-only digest. No code or infra changes are applied by this job.",
    }


def format_markdown(report: Dict[str, Any]) -> str:
    verdict = report["verdict"]
    max_r = report.get("max_ratio_median")
    max_r_s = f"{max_r:.2f}x" if isinstance(max_r, (int, float)) and max_r != float("inf") else "n/a"
    lines = [
        f"# Firestore daily digest - {verdict}",
        "",
        f"- fetched_at: {report.get('fetched_at')}",
        f"- project: {report.get('project')}",
        f"- max ratio (median): {max_r_s}",
        f"- auto_remediation: {report.get('auto_remediation')}",
        "",
        "## 7-day ratio (primary)",
        "",
        "| Metric | Yesterday | 7d median | 7d mean | x median | x mean | Verdict |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for name, result in (report.get("metrics") or {}).items():
        def fmt(v: Any) -> str:
            if v is None:
                return "n/a"
            if isinstance(v, float):
                if v == float("inf"):
                    return "inf"
                if v >= 1000:
                    return f"{v:,.0f}"
                return f"{v:.2f}"
            return str(v)

        r_med = result.get("ratio_median")
        r_mean = result.get("ratio_mean")
        lines.append(
            "| {name} | {y} | {med} | {mean} | {rm} | {rn} | {v} |".format(
                name=name,
                y=fmt(result.get("yesterday")),
                med=fmt(result.get("median")),
                mean=fmt(result.get("mean")),
                rm=fmt(r_med) + ("x" if r_med is not None else ""),
                rn=fmt(r_mean) + ("x" if r_mean is not None else ""),
                v=result.get("verdict") or "OK",
            )
        )

    lines.extend(["", "## Fingerprints (secondary)", ""])
    fps = report.get("fingerprints") or []
    if not fps:
        lines.append("none")
    else:
        for f in fps:
            lines.append(
                f"- **{f['id']}** [{f['severity']}]: {f.get('evidence')} - `{f.get('text')}`"
            )

    lines.extend(["", "## Top queries", ""])
    for i, q in enumerate(report.get("top_queries") or [], 1):
        lines.append(
            f"{i}. reads={q.get('total_read_operations')} exec={q.get('exec_count')} "
            f"{q.get('text')}"
        )

    lines.extend(
        [
            "",
            "## Note",
            "",
            str(report.get("note") or ""),
            "",
        ]
    )
    return "\n".join(lines)


def email_subject(report: Dict[str, Any], day: Optional[str] = None) -> str:
    verdict = report.get("verdict") or "OK"
    max_r = report.get("max_ratio_median")
    if isinstance(max_r, (int, float)) and max_r != float("inf"):
        ratio_part = f"{max_r:.2f}x median"
    else:
        ratio_part = "n/a"
    date_s = day or datetime.now(timezone.utc).date().isoformat()
    return f"[Firestore {verdict}] {date_s} | max {ratio_part}"


def evaluate_from_monitoring_payload(
    monitoring: Dict[str, Any],
    queries: Sequence[Dict[str, Any]],
    thresholds: Dict[str, Any],
    *,
    now_utc: Optional[datetime] = None,
    project: str = "yorigo-f7408",
    insights_interval: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    series = monitoring.get("series") or {}
    metric_results: Dict[str, Dict[str, Any]] = {}
    for metric_name in thresholds["metrics"]:
        source = METRIC_SOURCES.get(metric_name)
        if not source:
            continue
        block = series.get(source) or {}
        if isinstance(block, dict) and block.get("error"):
            metric_results[metric_name] = {
                "status": "error",
                "error": block.get("error"),
                "verdict": "OK",
                "yesterday": None,
                "median": None,
                "mean": None,
                "ratio_median": None,
                "ratio_mean": None,
            }
            continue
        daily = daily_map_from_series(block.get("daily") or [])
        metric_results[metric_name] = evaluate_metric_spike(
            daily,
            warning_ratio=thresholds["warning_median_ratio"],
            critical_ratio=thresholds["critical_median_ratio"],
            now_utc=now_utc,
        )

    fingerprints = evaluate_fingerprints(
        queries,
        underage_exec_warning=thresholds["underage_exec_warning"],
        coupang_full_scan_min_avg_docs=thresholds["coupang_full_scan_min_avg_docs"],
    )
    # If any metric CRITICAL and fingerprint present, keep fingerprints as WARNING
    # (overall already CRITICAL from metrics).
    top = sorted(
        list(queries),
        key=lambda r: int(r.get("total_read_operations") or 0),
        reverse=True,
    )[:10]

    return build_report(
        fetched_at=datetime.now(timezone.utc).isoformat(),
        project=project,
        thresholds=thresholds,
        metric_results=metric_results,
        fingerprints=fingerprints,
        top_queries=top,
        insights_interval=insights_interval,
    )


def fetch_live(
    sa_path: Path,
    *,
    monitoring_days: int = 14,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """Live Monitoring + Insights. Heavy imports deferred."""
    from fetch_firestore_insights import (
        DATA_TYPE_QUERY_INSIGHTS,
        _interval,
        _session,
        fetch_aggregated_insights,
        normalize_queries,
    )
    from fetch_firestore_monitoring import (
        DEFAULT_PROJECT,
        fetch_aligned_sum,
        load_credentials,
    )
    from google.cloud import monitoring_v3

    creds, sa_project = load_credentials(sa_path)
    project = sa_project or DEFAULT_PROJECT
    client = monitoring_v3.MetricServiceClient(credentials=creds)
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=monitoring_days)

    series: Dict[str, Any] = {}
    for metric_type in METRIC_SOURCES.values():
        series[metric_type] = fetch_aligned_sum(
            client, project, metric_type, start, end
        )

    monitoring = {
        "project": project,
        "fetched_at": end.isoformat(),
        "window": {"start": start.isoformat(), "end": end.isoformat(), "days": monitoring_days},
        "series": series,
    }

    session, _ = _session(sa_path)
    interval = _interval(hours=24, days=None)
    raw_q = fetch_aggregated_insights(
        session, project, interval, DATA_TYPE_QUERY_INSIGHTS
    )
    insights = {
        "project": project,
        "interval": interval,
        "queries": normalize_queries(raw_q),
    }
    return monitoring, insights


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Firestore daily guard (email-only)")
    parser.add_argument("--sa", type=Path, default=DEFAULT_SA)
    parser.add_argument("--thresholds", type=Path, default=DEFAULT_THRESHOLDS)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--monitoring-json", type=Path, default=None)
    parser.add_argument("--insights-json", type=Path, default=None)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=ANALYTICS_DIR / "reports",
    )
    parser.add_argument("--as-of", type=str, default=None, help="UTC YYYY-MM-DD for tests")
    args = parser.parse_args(list(argv) if argv is not None else None)

    thresholds = load_thresholds(args.thresholds)
    now_utc = datetime.now(timezone.utc)
    if args.as_of:
        now_utc = datetime.fromisoformat(args.as_of).replace(tzinfo=timezone.utc) + timedelta(
            hours=12
        )

    if args.offline:
        if not args.monitoring_json or not args.insights_json:
            print("--offline requires --monitoring-json and --insights-json", file=sys.stderr)
            return 2
        monitoring = json.loads(args.monitoring_json.read_text(encoding="utf-8"))
        insights = json.loads(args.insights_json.read_text(encoding="utf-8"))
        queries = insights.get("queries") or []
        project = str(monitoring.get("project") or insights.get("project") or "yorigo-f7408")
        interval = insights.get("interval")
    else:
        monitoring, insights = fetch_live(args.sa)
        queries = insights.get("queries") or []
        project = str(monitoring.get("project") or "yorigo-f7408")
        interval = insights.get("interval")

    report = evaluate_from_monitoring_payload(
        monitoring,
        queries,
        thresholds,
        now_utc=now_utc,
        project=project,
        insights_interval=interval,
    )

    target_day = None
    for result in (report.get("metrics") or {}).values():
        if result.get("target_day"):
            target_day = result["target_day"]
            break

    day_dir = args.out_dir / (target_day or now_utc.date().isoformat())
    day_dir.mkdir(parents=True, exist_ok=True)
    json_path = day_dir / "report.json"
    md_path = day_dir / "report.md"
    subject_path = day_dir / "email_subject.txt"

    md = format_markdown(report)
    subject = email_subject(report, day=target_day)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    md_path.write_text(md, encoding="utf-8")
    subject_path.write_text(subject + "\n", encoding="utf-8")

    def _safe_print(text: str) -> None:
        try:
            print(text)
        except UnicodeEncodeError:
            enc = getattr(sys.stdout, "encoding", None) or "utf-8"
            sys.stdout.buffer.write((text + "\n").encode(enc, errors="replace"))

    _safe_print(subject)
    _safe_print(md)
    _safe_print(f"[out] {json_path}")
    _safe_print(f"[out] {md_path}")

    verdict = report["verdict"]
    if verdict == "CRITICAL":
        return EXIT_CRITICAL
    if verdict == "WARNING":
        return EXIT_WARNING
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
