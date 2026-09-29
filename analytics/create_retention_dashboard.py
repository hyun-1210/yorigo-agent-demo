"""
Create the "Yorigo Retention & Engagement" dashboard in Mixpanel
using the Mixpanel Headless SDK CLI.

Requires: pip install mixpanel-headless
Auth:     python -m mixpanel_headless login

Usage:    python analytics/create_retention_dashboard.py
"""

import json
import os
import subprocess
import sys

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


def _retention_params(
    born_event: str,
    return_event: str,
    unit: str = "week",
) -> dict:
    return {
        "sections": {
            "show": [
                {
                    "type": "metric",
                    "behavior": {
                        "type": "retention",
                        "resourceType": "events",
                        "behaviors": [
                            {
                                "type": "event",
                                "name": born_event,
                                "filters": [],
                                "filtersDeterminer": None,
                            },
                            {
                                "type": "event",
                                "name": return_event,
                                "filters": [],
                                "filtersDeterminer": None,
                            },
                        ],
                        "retentionUnit": unit,
                        "retentionAlignmentType": "birth",
                        "retentionUnboundedMode": "carry_back",
                    },
                    "isExpanded": True,
                    "measurement": {
                        "retentionSegmentationEvent": None,
                        "math": "retention_rate",
                        "dataGroupId": None,
                    },
                }
            ],
            "filter": [],
            "group": [],
            "formula": [],
            "time": [
                {
                    "dateRangeType": "in the last",
                    "window": {"unit": unit, "value": 12},
                    "unit": unit,
                }
            ],
            "cohorts": [],
            "metricLevelDataGroups": True,
        },
        "displayOptions": {"chartType": "retention-curve"},
        "columnWidths": {"bar": {}},
        "sorting": {
            "bar": {"colSortAttrs": [], "sortBy": "column"},
            "line": {
                "sortBy": "column",
                "colSortAttrs": [
                    {"sortBy": "value", "sortOrder": "desc", "valueField": "averageValue"}
                ],
            },
            "table": {
                "sortBy": "column",
                "colSortAttrs": [
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "cohortSize",
                        "viewNLimit": 12,
                    }
                ],
            },
            "insights-metric": {
                "sortBy": "column",
                "colSortAttrs": [
                    {"sortBy": "value", "sortOrder": "desc", "valueField": "totalValue"}
                ],
            },
            "pie": {
                "sortBy": "column",
                "colSortAttrs": [
                    {"sortBy": "value", "sortOrder": "desc", "valueField": "totalValue"}
                ],
            },
            "funnel-steps": {"colSortAttrs": [], "sortBy": "column"},
        },
    }


def _insights_params(event: str, unit: str = "week") -> dict:
    return {
        "sections": {
            "show": [
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
                                "name": event,
                                "filters": [],
                                "filtersDeterminer": "all",
                            }
                        ],
                    },
                    "measurement": {
                        "math": "total",
                        "perUserAggregation": None,
                        "rolling": None,
                        "cumulative": False,
                        "property": None,
                    },
                    "isHidden": False,
                }
            ],
            "filter": [],
            "group": [],
            "formula": [],
            "time": [
                {
                    "dateRangeType": "in the last",
                    "window": {"unit": unit, "value": 12},
                    "unit": unit,
                }
            ],
            "cohorts": [],
            "metricLevelDataGroups": True,
        },
        "displayOptions": {
            "chartType": "line",
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
            }
        },
    }


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


def main() -> None:
    print("=== Creating Yorigo Retention & Engagement Dashboard ===\n")

    dashboard_id = create_dashboard(
        "Yorigo Retention & Engagement",
        "Cohort retention grids + weekly trend charts for user journey tracking.",
    )

    print("\n--- Retention Charts (weekly cohort grids) ---\n")

    # Weekly recipe parsing retention: users who parsed → come back to parse again
    create_report(
        "Weekly Recipe Parsing Retention",
        "retention",
        _retention_params("recipe_parsing_completed", "recipe_parsing_completed"),
        dashboard_id,
    )

    # R2: Sign-up → save recipe to cart
    create_report(
        "R2: Recipe Saved to Cart",
        "retention",
        _retention_params("sign_up", "recipe_bookmarked"),
        dashboard_id,
    )

    # R3: Sign-up → click affiliate link
    create_report(
        "R3: Affiliate Link Clicked",
        "retention",
        _retention_params("sign_up", "affiliate_link_clicked"),
        dashboard_id,
    )

    # R4: Sign-up → complete cart purchase
    create_report(
        "R4: Cart Purchase Completed",
        "retention",
        _retention_params("sign_up", "cart_purchase_completed"),
        dashboard_id,
    )

    # R5: Sign-up → check 50%+ products in cart
    create_report(
        "R5: Cart 50%+ Products Checked",
        "retention",
        _retention_params("sign_up", "cart_majority_checked"),
        dashboard_id,
    )

    print("\n--- Weekly Trend Charts ---\n")

    # T1: Weekly parse attempts
    create_report(
        "T1: Weekly Parse Attempts",
        "insights",
        _insights_params("parsing_request_started"),
        dashboard_id,
    )

    # T2: Weekly recipe saves
    create_report(
        "T2: Weekly Recipe Saves",
        "insights",
        _insights_params("recipe_bookmarked"),
        dashboard_id,
    )

    print(f"\n=== Done! Dashboard ID: {dashboard_id} ===")
    print("Open Mixpanel and navigate to Dashboards to view it.")


if __name__ == "__main__":
    main()
