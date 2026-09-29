"""
Parse Cost Analysis 대시보드를 Mixpanel 에 생성한다.

일별 / 주별 파싱 비용 분석: DAU, 파싱 요청, 파싱 결과 분류,
Track A/B 비율, LLM 토큰 사용량(입력/출력/thinking), LLM 호출 수,
재시도 횟수, 레시피 DB 성장 추이.

Requires: pip install mixpanel-headless
Auth:     python -m mixpanel_headless login

Usage:    python analytics/create_parse_cost_dashboard.py
"""

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


# ── Report parameter builders ──


def _simple_event_params(
    event: str,
    unit: str = "day",
    chart_type: str = "line",
    math: str = "total",
    window_value: int = 30,
    *,
    group_by_property: str | None = None,
    filters: list[dict] | None = None,
    property_name: str | None = None,
) -> dict:
    """단일 이벤트 인사이트 리포트 파라미터."""
    behavior: dict[str, Any] = {
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
    }

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

    sections: dict[str, Any] = {
        "show": [
            {
                "type": "metric",
                "behavior": behavior,
                "measurement": measurement,
                "isHidden": False,
            }
        ],
        "filter": [],
        "group": [],
        "formula": [],
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

    if group_by_property:
        sections["group"] = [
            {
                "type": "property",
                "value": group_by_property,
                "resourceType": "events",
                "typeCast": None,
                "propertyObjectKey": None,
                "filterLabelOverride": None,
            }
        ]

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


def _multi_event_params(
    events: list[dict],
    unit: str = "day",
    chart_type: str = "line",
    window_value: int = 30,
) -> dict:
    """여러 이벤트를 하나의 차트에 겹쳐 보여주는 인사이트 리포트."""
    show = []
    for ev in events:
        show.append(
            {
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
                            "name": ev["name"],
                            "filters": ev.get("filters", []),
                            "filtersDeterminer": "all",
                        }
                    ],
                },
                "measurement": {
                    "math": ev.get("math", "total"),
                    "perUserAggregation": None,
                    "rolling": None,
                    "cumulative": False,
                    **(
                        {
                            "property": {
                                "name": ev["property"],
                                "resourceType": "events",
                                "type": "number",
                            }
                        }
                        if ev.get("property")
                        else {}
                    ),
                },
                "isHidden": False,
            }
        )

    return {
        "sections": {
            "show": show,
            "filter": [],
            "group": [],
            "formula": [],
            "time": [
                {
                    "dateRangeType": "in the last",
                    "window": {"unit": unit, "value": window_value},
                    "unit": unit,
                }
            ],
            "cohorts": [],
            "metricLevelDataGroups": True,
        },
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
        },
    }


_REPORT_ORDER = [
    "D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8", "D9", "D10",
    "W1", "W2", "W3", "W4", "W5", "W6",
]


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Create Parse Cost Analysis dashboard")
    parser.add_argument(
        "--dashboard-id",
        type=int,
        default=None,
        help="Append reports to an existing dashboard instead of creating a new one",
    )
    parser.add_argument(
        "--from-report",
        type=str,
        default=None,
        help="Start from this report id prefix (e.g. D3) when appending",
    )
    parser.add_argument(
        "--through-report",
        type=str,
        default=None,
        help="Stop after this report id prefix (e.g. D10) when appending",
    )
    args = parser.parse_args()

    print("=== Creating Parse Cost Analysis Dashboard ===\n")

    if args.dashboard_id:
        dashboard_id = args.dashboard_id
        print(f"  Using existing dashboard ID {dashboard_id}")
    else:
        dashboard_id = create_dashboard(
            "Parse Cost Analysis",
            "일별/주별 파싱 비용 분석: DAU, 파싱 요청 · 결과 분류, Track A/B, "
            "LLM 토큰 사용량, LLM 호출 수, 재시도, 레시피 DB 성장 추이.",
        )

    start_from = (args.from_report or "").upper()
    through = (args.through_report or "").upper()

    def _should_run(prefix: str) -> bool:
        if prefix not in _REPORT_ORDER:
            return True
        idx = _REPORT_ORDER.index(prefix)
        if start_from:
            if start_from not in _REPORT_ORDER:
                return prefix >= start_from
            if idx < _REPORT_ORDER.index(start_from):
                return False
        if through:
            if through not in _REPORT_ORDER:
                return prefix <= through
            if idx > _REPORT_ORDER.index(through):
                return False
        return True

    # ── Daily Charts ──
    print("\n--- Daily Charts ---\n")

    if _should_run("D1"):
        create_report(
            "D1: DAU Overview (Total + Signed-In)",
            "insights",
            _multi_event_params(
                [
                    {"name": "yorigo_active_user", "math": "unique"},
                    {"name": "sign_up", "math": "total"},
                ],
                unit="day",
                chart_type="line",
            ),
            dashboard_id,
        )

    if _should_run("D2"):
        create_report(
            "D2: Daily Parse Requests",
            "insights",
            _simple_event_params("parsing_request_started", unit="day"),
            dashboard_id,
        )

    if _should_run("D3"):
        create_report(
            "D3: Parse Outcome Breakdown",
            "insights",
            _multi_event_params(
                [
                    {"name": "recipe_dedup_found"},
                    {"name": "server_parse_completed"},
                    {"name": "server_parse_failed"},
                    {"name": "server_parse_dedup"},
                ],
                unit="day",
                chart_type="column",
            ),
            dashboard_id,
        )

    if _should_run("D4"):
        create_report(
            "D4: Parse Track Distribution (A / B / A-to-B)",
            "insights",
            _simple_event_params(
                "server_parse_completed",
                unit="day",
                chart_type="column",
                group_by_property="track",
            ),
            dashboard_id,
        )

    if _should_run("D5"):
        create_report(
            "D5: Parse Failures by Error Type",
            "insights",
            _simple_event_params(
                "server_parse_failed",
                unit="day",
                chart_type="column",
                group_by_property="error_type",
            ),
            dashboard_id,
        )

    if _should_run("D6"):
        create_report(
            "D6: Daily Retry Attempts",
            "insights",
            _simple_event_params(
                "parsing_request_started",
                unit="day",
                chart_type="line",
                filters=[
                    {
                        "filterType": "string",
                        "propertyObjectKey": None,
                        "resourceType": "events",
                        "propertyName": "is_retry",
                        "comparator": "is equal to",
                        "filterValue": [1],
                    }
                ],
            ),
            dashboard_id,
        )

    if _should_run("D7"):
        create_report(
            "D7: Daily LLM Token Usage (Input / Output / Thinking)",
            "insights",
            _multi_event_params(
                [
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_input_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_output_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_thinking_tokens",
                    },
                ],
                unit="day",
                chart_type="line",
            ),
            dashboard_id,
        )

    if _should_run("D8"):
        create_report(
            "D8: Recipe DB Size (Unique Recipes)",
            "insights",
            _simple_event_params(
                "daily_recipe_db_snapshot",
                unit="day",
                chart_type="line",
                math="max",
                property_name="total_unique_recipes",
            ),
            dashboard_id,
        )

    if _should_run("D9"):
        create_report(
            "D9: Daily Avg Tokens per Parse",
            "insights",
            _multi_event_params(
                [
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_input_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_output_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_thinking_tokens",
                    },
                ],
                unit="day",
                chart_type="line",
            ),
            dashboard_id,
        )

    if _should_run("D10"):
        create_report(
            "D10: Daily LLM Call Count",
            "insights",
            _simple_event_params(
                "server_parse_completed",
                unit="day",
                chart_type="line",
                math="total",
                property_name="llm_call_count",
            ),
            dashboard_id,
        )

    # ── Weekly Charts ──
    print("\n--- Weekly Charts ---\n")

    if _should_run("W1"):
        create_report(
            "W1: Weekly Parse Volume",
            "insights",
            _multi_event_params(
                [
                    {"name": "parsing_request_started"},
                    {"name": "server_parse_completed"},
                    {"name": "server_parse_failed"},
                    {"name": "server_parse_dedup"},
                    {"name": "recipe_dedup_found"},
                ],
                unit="week",
                chart_type="line",
                window_value=16,
            ),
            dashboard_id,
        )

    if _should_run("W2"):
        create_report(
            "W2: Weekly New vs Existing (Stacked)",
            "insights",
            _multi_event_params(
                [
                    {"name": "server_parse_completed"},
                    {"name": "recipe_dedup_found"},
                    {"name": "server_parse_dedup"},
                ],
                unit="week",
                chart_type="column",
                window_value=16,
            ),
            dashboard_id,
        )

    if _should_run("W3"):
        create_report(
            "W3: Weekly Parses by Platform",
            "insights",
            _simple_event_params(
                "server_parse_completed",
                unit="week",
                chart_type="column",
                window_value=16,
                group_by_property="platform",
            ),
            dashboard_id,
        )

    if _should_run("W4"):
        create_report(
            "W4: Weekly LLM Token Usage (Input / Output / Thinking)",
            "insights",
            _multi_event_params(
                [
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_input_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_output_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "total",
                        "property": "llm_thinking_tokens",
                    },
                ],
                unit="week",
                chart_type="line",
                window_value=16,
            ),
            dashboard_id,
        )

    if _should_run("W5"):
        create_report(
            "W5: Weekly Avg Tokens per Parse",
            "insights",
            _multi_event_params(
                [
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_input_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_output_tokens",
                    },
                    {
                        "name": "server_parse_completed",
                        "math": "average",
                        "property": "llm_thinking_tokens",
                    },
                ],
                unit="week",
                chart_type="line",
                window_value=16,
            ),
            dashboard_id,
        )

    if _should_run("W6"):
        create_report(
            "W6: Weekly LLM Call Count",
            "insights",
            _simple_event_params(
                "server_parse_completed",
                unit="week",
                chart_type="line",
                math="total",
                property_name="llm_call_count",
                window_value=16,
            ),
            dashboard_id,
        )

    print(f"\n=== Done! Dashboard ID: {dashboard_id} ===")
    print("Open Mixpanel and navigate to Dashboards to view it.")


if __name__ == "__main__":
    main()
