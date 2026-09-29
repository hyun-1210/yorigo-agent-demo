"""
Create the "Parse Efficiency & Cost Leverage" dashboard in Mixpanel.

Derived parse-cost metrics: requests per active user, new-recipe yield,
dedup avoided-cost rate, retry/failure pressure, and token usage per audience.

Requires: pip install mixpanel-headless
Auth:     python -m mixpanel_headless login

Usage:    python analytics/create_parse_efficiency_dashboard.py
"""

import argparse
import json
import os
import subprocess
import sys
from typing import Any

MP_CLI = [sys.executable, "-m", "mixpanel_headless"]

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
os.environ.setdefault("MP_SKIP_PERMISSION_CHECK", "1")


def run_mp(*args: str) -> dict | list | str:
    cmd = [*MP_CLI, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        print(f"  ERROR running: {' '.join(args)}", file=sys.stderr)
        print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        print(f"  stdout: {result.stdout.strip()}", file=sys.stderr)
        sys.exit(1)
    raw = result.stdout.strip()
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return raw


def create_dashboard(title: str, description: str = "") -> int:
    args = ["dashboards", "create", "--title", title, "-f", "json"]
    if description:
        args += ["--description", description]
    data = run_mp(*args)
    dashboard_id = data.get("id") if isinstance(data, dict) else None
    if not dashboard_id:
        print(f"  Could not parse dashboard ID from: {data}", file=sys.stderr)
        sys.exit(1)
    print(f"  Created dashboard '{title}' -> ID {dashboard_id}")
    return int(dashboard_id)


def create_report(
    name: str,
    bookmark_type: str,
    params: dict,
    dashboard_id: int,
) -> int:
    data = run_mp(
        "reports",
        "create",
        "--name",
        name,
        "--type",
        bookmark_type,
        "--params",
        json.dumps(params),
        "--dashboard-id",
        str(dashboard_id),
        "-f",
        "json",
    )
    report_id = data.get("id") if isinstance(data, dict) else None
    if not report_id:
        print(f"  Could not parse report ID from: {data}", file=sys.stderr)
        sys.exit(1)
    print(f"  Created {bookmark_type} report '{name}' -> ID {report_id}")
    return int(report_id)


def _event_filter_eq(property_name: str, value: Any) -> dict:
    return {
        "filterType": "string",
        "propertyObjectKey": None,
        "resourceType": "events",
        "propertyName": property_name,
        "comparator": "is equal to",
        "filterValue": [value],
    }


def _metric(
    event: str,
    *,
    math: str = "total",
    property_name: str | None = None,
    filters: list[dict] | None = None,
    hidden: bool = False,
) -> dict:
    measurement: dict[str, Any] = {
        "math": math,
        "perUserAggregation": None,
        "rolling": None,
        "cumulative": False,
    }
    if property_name:
        measurement["property"] = {
            "name": property_name,
            "resourceType": "events",
            "type": "number",
        }
    return {
        "type": "metric",
        "behavior": {
            "type": "simple",
            "resourceType": "events",
            "dataGroupId": None,
            "filters": [],
            "filtersDeterminer": "all",
            "behaviors": [
                {
                    "id": None,
                    "type": "event",
                    "name": event,
                    "filters": filters or [],
                    "filtersDeterminer": "all",
                }
            ],
        },
        "measurement": measurement,
        "isHidden": hidden,
    }


def _base_params(
    *,
    show: list[dict],
    unit: str,
    window_value: int,
    chart_type: str = "line",
    formula: str | None = None,
) -> dict:
    sections: dict[str, Any] = {
        "show": show,
        "filter": [],
        "group": [],
        # Mixpanel v2 accepts formula definitions here, then migrates them into
        # hidden metrics + a visible formula metric on save.
        "formula": [{"value": formula}] if formula else [],
        "time": [
            {
                "dateRangeType": "in the last",
                "window": {"unit": unit, "value": window_value},
                "unit": unit,
            }
        ],
        "cohorts": [],
        "metricLevelDataGroups": True,
    }
    return {
        "sections": sections,
        "displayOptions": {
            "chartType": chart_type,
            "plotStyle": "standard",
            "analysis": "linear",
            "value": "absolute",
        },
        "columnWidths": {},
        "sorting": {
            "line": {
                "sortBy": "value",
                "sortOrder": "desc",
                "valueField": "averageValue",
                "colSortAttrs": [
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "averageValue",
                    }
                ],
            },
            "bar": {
                "colSortAttrs": [
                    {"sortBy": "value", "sortOrder": "desc", "valueField": "totalValue"}
                ],
                "sortBy": "column",
            },
        },
    }


def _formula_params(
    metrics: list[dict],
    formula: str,
    *,
    unit: str,
    window_value: int,
    chart_type: str = "line",
) -> dict:
    hidden_metrics = [{**metric, "isHidden": True} for metric in metrics]
    return _base_params(
        show=hidden_metrics,
        unit=unit,
        window_value=window_value,
        chart_type=chart_type,
        formula=formula,
    )


def _multi_params(
    metrics: list[dict],
    *,
    unit: str,
    window_value: int,
    chart_type: str = "line",
) -> dict:
    return _base_params(
        show=metrics,
        unit=unit,
        window_value=window_value,
        chart_type=chart_type,
    )


def _create_common_reports(
    *,
    prefix: str,
    label: str,
    unit: str,
    window_value: int,
    dashboard_id: int,
) -> None:
    request_metric = _metric("parsing_request_started")
    active_metric = _metric("yorigo_active_user", math="unique")
    completed_metric = _metric("server_parse_completed")
    failed_metric = _metric("server_parse_failed")
    client_dedup_metric = _metric("recipe_dedup_found")
    server_dedup_metric = _metric("server_parse_dedup")
    retry_metric = _metric(
        "parsing_request_started",
        filters=[_event_filter_eq("is_retry", 1)],
    )
    completed_tokens_metric = _metric(
        "server_parse_completed",
        math="total",
        property_name="llm_total_tokens",
    )
    failed_tokens_metric = _metric(
        "server_parse_failed",
        math="total",
        property_name="llm_total_tokens",
    )

    create_report(
        f"{prefix}1: {label} Parse Requests per Active User",
        "insights",
        _formula_params(
            [request_metric, active_metric],
            "A/B",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}2: {label} Parse Requests per 100 Active Users",
        "insights",
        _formula_params(
            [request_metric, active_metric],
            "(A/B)*100",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}3: {label} New Recipe Yield (Completed / Requests)",
        "insights",
        _formula_params(
            [completed_metric, request_metric],
            "A/B",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}4: {label} Existing Video Dedup Rate",
        "insights",
        _formula_params(
            [client_dedup_metric, server_dedup_metric, request_metric],
            "(A+B)/C",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}5: {label} Expensive Parse Rate",
        "insights",
        _formula_params(
            [completed_metric, failed_metric, request_metric],
            "(A+B)/C",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}6: {label} Failure Rate",
        "insights",
        _formula_params(
            [failed_metric, request_metric],
            "A/B",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}7: {label} Retry Pressure",
        "insights",
        _formula_params(
            [retry_metric, request_metric],
            "A/B",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}8: {label} LLM Tokens per 100 Active Users",
        "insights",
        _formula_params(
            [completed_tokens_metric, failed_tokens_metric, active_metric],
            "((A+B)/C)*100",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}9: {label} LLM Tokens per New Recipe",
        "insights",
        _formula_params(
            [completed_tokens_metric, failed_tokens_metric, completed_metric],
            "(A+B)/C",
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )

    create_report(
        f"{prefix}10: {label} Dedup Hits vs Recipe DB Size",
        "insights",
        _multi_params(
            [
                _metric("recipe_dedup_found"),
                _metric("server_parse_dedup"),
                _metric(
                    "daily_recipe_db_snapshot",
                    math="max",
                    property_name="total_unique_recipes",
                ),
            ],
            unit=unit,
            window_value=window_value,
        ),
        dashboard_id,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create Parse Efficiency & Cost Leverage dashboard"
    )
    parser.add_argument(
        "--dashboard-id",
        type=int,
        default=None,
        help="Append reports to an existing dashboard instead of creating a new one",
    )
    parser.add_argument(
        "--daily-only",
        action="store_true",
        help="Create only daily reports",
    )
    parser.add_argument(
        "--weekly-only",
        action="store_true",
        help="Create only weekly reports",
    )
    args = parser.parse_args()

    print("=== Creating Parse Efficiency & Cost Leverage Dashboard ===\n")

    if args.dashboard_id:
        dashboard_id = args.dashboard_id
        print(f"  Using existing dashboard ID {dashboard_id}")
    else:
        dashboard_id = create_dashboard(
            "Parse Efficiency & Cost Leverage",
            "Derived parse-cost ratios: demand per active user, new-recipe yield, "
            "dedup avoided cost, retry/failure pressure, and token cost per audience.",
        )

    if not args.weekly_only:
        print("\n--- Daily Efficiency Charts ---\n")
        _create_common_reports(
            prefix="D",
            label="Daily",
            unit="day",
            window_value=30,
            dashboard_id=dashboard_id,
        )

    if not args.daily_only:
        print("\n--- Weekly Efficiency Charts ---\n")
        _create_common_reports(
            prefix="W",
            label="Weekly",
            unit="week",
            window_value=16,
            dashboard_id=dashboard_id,
        )

    print(f"\n=== Done! Dashboard ID: {dashboard_id} ===")
    print("Open Mixpanel and navigate to Dashboards to view it.")


if __name__ == "__main__":
    main()
