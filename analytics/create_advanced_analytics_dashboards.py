"""
Create advanced Yorigo Mixpanel dashboards for product analytics.

Requires: pip install mixpanel-headless
Auth:     existing ~/.mp OAuth account, or:
          export MP_USERNAME=... MP_SECRET=... MP_PROJECT_ID=4016163 MP_REGION=us

Usage:    python analytics/create_advanced_analytics_dashboards.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

MP_CLI = [sys.executable, "-m", "mixpanel_headless"]

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
os.environ.setdefault("MP_SKIP_PERMISSION_CHECK", "1")
os.environ.setdefault("MP_PROJECT_ID", "4016163")


class MixpanelCliError(RuntimeError):
    pass


def run_mp(*args: str) -> dict | list | str:
    cmd = [*MP_CLI, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        print(f"  ERROR running: {' '.join(args[:6])}...", file=sys.stderr)
        print(f"  stderr: {result.stderr.strip()[-800:]}", file=sys.stderr)
        raise MixpanelCliError(result.stderr.strip())
    raw = result.stdout.strip()
    # Drop pandas/other warnings that may precede JSON.
    for i, ch in enumerate(raw):
        if ch in "[{":
            raw = raw[i:]
            break
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
) -> int | None:
    try:
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
    except MixpanelCliError as exc:
        print(f"  SKIPPED report '{name}': {exc}", file=sys.stderr)
        return None
    report_id = data.get("id") if isinstance(data, dict) else None
    if not report_id:
        print(f"  Could not parse report ID from: {data}", file=sys.stderr)
        return None
    print(f"  Created {bookmark_type} report '{name}' -> ID {report_id}")
    return int(report_id)


def _event_behavior(event: str) -> dict:
    return {
        "id": None,
        "type": "event",
        "name": event,
        "filters": [],
        "filtersDeterminer": "all",
    }


def _insights_params(
    event: str,
    *,
    unit: str = "day",
    window: int = 30,
    math: str = "total",
    chart_type: str = "line",
    group_by: str | None = None,
) -> dict:
    group = []
    if group_by:
        group = [
            {
                "dataset": "$mixpanel",
                "value": group_by,
                "resourceType": "event",
                "propertyType": "string",
            }
        ]
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
                        "behaviors": [_event_behavior(event)],
                    },
                    "measurement": {
                        "math": math,
                        "perUserAggregation": None,
                        "rolling": None,
                        "cumulative": False,
                        "property": None,
                    },
                    "isHidden": False,
                }
            ],
            "filter": [],
            "group": group,
            "formula": [],
            "time": [
                {
                    "dateRangeType": "in the last",
                    "window": {"unit": unit, "value": window},
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
            "primaryYAxisOptions": {"min": 0, "useSoftMinMax": True},
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
                "sortBy": "column",
                "colSortAttrs": [
                    {"sortBy": "value", "sortOrder": "desc"}
                ],
            },
            "pie": {
                "sortBy": "column",
                "colSortAttrs": [
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "totalValue",
                    }
                ],
            },
        },
    }


def _funnel_params(
    events: list[str],
    *,
    unit: str = "day",
    window: int = 30,
    conversion_window_days: int = 7,
) -> dict:
    behaviors = [_event_behavior(e) for e in events]
    return {
        "sections": {
            "show": [
                {
                    "type": "metric",
                    "behavior": {
                        "type": "funnel",
                        "resourceType": "events",
                        "conversionWindowDuration": conversion_window_days,
                        "conversionWindowUnit": "day",
                        "funnelOrder": "loose",
                        "funnelReentryMode": "basic",
                        "exclusions": [],
                        "aggregateBy": [],
                        "dataGroupId": None,
                        "dataset": "$mixpanel",
                        "filter": [],
                        "behaviors": behaviors,
                    },
                    "measurement": {
                        "math": "conversion_rate_unique",
                        "stepIndex": None,
                        "rolling": None,
                        "property": None,
                    },
                    "isExpanded": True,
                }
            ],
            "filter": [],
            "group": [],
            "formula": [],
            "time": [
                {
                    "dateRangeType": "in the last",
                    "window": {"unit": unit, "value": window},
                    "unit": unit,
                }
            ],
            "cohorts": [],
        },
        "displayOptions": {
            "chartType": "funnel-steps",
            "plotStyle": "standard",
            "analysis": "linear",
            "value": "absolute",
            "funnelStepsSelectedTableColumns": {
                "conv-first-step": True,
                "conv-prev-step": True,
                "count": True,
                "stat-sig": True,
                "time-first-step": False,
                "time-prev-step": True,
            },
        },
        "columnWidths": {"bar": {}},
        "sorting": {"funnel-steps": {"colSortAttrs": [], "sortBy": "column"}},
    }


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
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "averageValue",
                    }
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
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "totalValue",
                    }
                ],
            },
            "pie": {
                "sortBy": "column",
                "colSortAttrs": [
                    {
                        "sortBy": "value",
                        "sortOrder": "desc",
                        "valueField": "totalValue",
                    }
                ],
            },
            "funnel-steps": {"colSortAttrs": [], "sortBy": "column"},
        },
    }


def build_overview(dashboard_id: int) -> None:
    print("\n--- Product Overview charts ---\n")
    create_report(
        "DAU (yorigo_active_user)",
        "insights",
        _insights_params("yorigo_active_user", math="unique", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Daily Sign-ups",
        "insights",
        _insights_params("sign_up", math="unique", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Daily Logins",
        "insights",
        _insights_params("login", math="unique", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Daily Recipe Views",
        "insights",
        _insights_params("recipe_viewed", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Daily Parse Completions",
        "insights",
        _insights_params("recipe_parsing_completed", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Daily Purchase Completions",
        "insights",
        _insights_params("cart_purchase_completed", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Main Tab Usage (unique)",
        "insights",
        _insights_params(
            "main_tab_selected",
            math="unique",
            unit="day",
            window=30,
            group_by="tab_name",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Screen Views by Screen",
        "insights",
        _insights_params(
            "screen_view",
            math="total",
            unit="day",
            window=14,
            group_by="screen_name",
            chart_type="bar",
        ),
        dashboard_id,
    )


def build_acquisition(dashboard_id: int) -> None:
    print("\n--- Acquisition & Auth charts ---\n")
    create_report(
        "Sign-ups by Method",
        "insights",
        _insights_params(
            "sign_up",
            math="total",
            unit="week",
            window=12,
            group_by="sign_up_method",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Logins by Method",
        "insights",
        _insights_params(
            "login",
            math="total",
            unit="week",
            window=12,
            group_by="login_method",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "First Open → Sign-up Funnel",
        "funnels",
        _funnel_params(
            ["app_first_open", "sign_up"],
            conversion_window_days=7,
        ),
        dashboard_id,
    )
    create_report(
        "Sign-up → First Parse Funnel",
        "funnels",
        _funnel_params(
            ["sign_up", "parsing_request_started", "recipe_parsing_completed"],
            conversion_window_days=7,
        ),
        dashboard_id,
    )
    create_report(
        "Weekly First Opens",
        "insights",
        _insights_params("app_first_open", math="total", unit="week", window=12),
        dashboard_id,
    )
    create_report(
        "Password Resets & Account Deletions",
        "insights",
        _insights_params("password_reset_requested", math="total", unit="week", window=12),
        dashboard_id,
    )
    create_report(
        "Account Deletions",
        "insights",
        _insights_params("account_deleted", math="total", unit="week", window=12),
        dashboard_id,
    )
    create_report(
        "Weekly Logouts",
        "insights",
        _insights_params("logout", math="total", unit="week", window=12),
        dashboard_id,
    )


def build_recipe_engagement(dashboard_id: int) -> None:
    print("\n--- Recipe Engagement charts ---\n")
    create_report(
        "View → Bookmark → Cook → Review Funnel",
        "funnels",
        _funnel_params(
            [
                "recipe_viewed",
                "recipe_bookmarked",
                "cooking_started",
                "review_created",
            ],
            conversion_window_days=14,
        ),
        dashboard_id,
    )
    create_report(
        "Parse → View → Cart Add Funnel",
        "funnels",
        _funnel_params(
            [
                "recipe_parsing_completed",
                "recipe_viewed",
                "recipe_cart_add_footer_clicked",
            ],
            conversion_window_days=7,
        ),
        dashboard_id,
    )
    create_report(
        "Recipe Views by Platform",
        "insights",
        _insights_params(
            "recipe_viewed",
            math="total",
            unit="week",
            window=12,
            group_by="platform",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Parse Completions by Platform",
        "insights",
        _insights_params(
            "recipe_parsing_completed",
            math="total",
            unit="week",
            window=12,
            group_by="platform",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Parse Failures by Type",
        "insights",
        _insights_params(
            "recipe_parsing_failed",
            math="total",
            unit="week",
            window=12,
            group_by="error_type",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Add Recipe Opens",
        "insights",
        _insights_params("add_recipe_opened", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Share Extension Opens",
        "insights",
        _insights_params("share_extension_opened", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Cooking Started vs Completed",
        "insights",
        _insights_params("cooking_started", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Cooking Completed (Fridge)",
        "insights",
        _insights_params("cooking_completed", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Reviews Created",
        "insights",
        _insights_params("review_created", math="total", unit="week", window=12),
        dashboard_id,
    )
    create_report(
        "Search Opens",
        "insights",
        _insights_params("search_opened", math="total", unit="day", window=30),
        dashboard_id,
    )


def build_purchase(dashboard_id: int) -> None:
    print("\n--- Purchase Funnel charts ---\n")
    create_report(
        "Recipe → Cart → Affiliate → Purchase Funnel",
        "funnels",
        _funnel_params(
            [
                "recipe_viewed",
                "recipe_cart_add_footer_clicked",
                "affiliate_link_clicked",
                "cart_purchase_completed",
            ],
            conversion_window_days=14,
        ),
        dashboard_id,
    )
    create_report(
        "Cart Check → Majority → Complete Funnel",
        "funnels",
        _funnel_params(
            [
                "ingredient_purchase_checked",
                "cart_majority_checked",
                "purchase_button_clicked",
                "cart_purchase_completed",
            ],
            conversion_window_days=7,
        ),
        dashboard_id,
    )
    create_report(
        "Affiliate Clicks by Marketplace",
        "insights",
        _insights_params(
            "affiliate_link_clicked",
            math="total",
            unit="week",
            window=12,
            group_by="marketplace",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Ingredients Purchased by Marketplace",
        "insights",
        _insights_params(
            "ingredient_purchased",
            math="total",
            unit="week",
            window=12,
            group_by="marketplace",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Purchase Spend (sum of total_expenditure)",
        "insights",
        {
            **_insights_params(
                "cart_purchase_completed",
                math="total",
                unit="day",
                window=30,
            ),
            "sections": {
                **_insights_params(
                    "cart_purchase_completed",
                    math="total",
                    unit="day",
                    window=30,
                )["sections"],
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
                                _event_behavior("cart_purchase_completed")
                            ],
                        },
                        "measurement": {
                            "math": "total",
                            "perUserAggregation": None,
                            "rolling": None,
                            "cumulative": False,
                            "property": {
                                "dataset": "$mixpanel",
                                "defaultType": "number",
                                "name": "total_expenditure",
                                "resourceType": "event",
                                "type": "number",
                                "unit": None,
                            },
                        },
                        "isHidden": False,
                    }
                ],
            },
        },
        dashboard_id,
    )
    create_report(
        "Purchase Button Clicks",
        "insights",
        _insights_params("purchase_button_clicked", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Cart Majority Checked",
        "insights",
        _insights_params("cart_majority_checked", math="total", unit="day", window=30),
        dashboard_id,
    )


def build_engagement_retention(dashboard_id: int) -> None:
    print("\n--- Engagement & Retention charts ---\n")
    create_report(
        "Weekly Active User Retention",
        "retention",
        _retention_params("yorigo_active_user", "yorigo_active_user", unit="week"),
        dashboard_id,
    )
    create_report(
        "Sign-up → Active User Retention",
        "retention",
        _retention_params("sign_up", "yorigo_active_user", unit="week"),
        dashboard_id,
    )
    create_report(
        "Sign-up → Purchase Retention",
        "retention",
        _retention_params("sign_up", "cart_purchase_completed", unit="week"),
        dashboard_id,
    )
    create_report(
        "Parse → Return Parse Retention",
        "retention",
        _retention_params(
            "recipe_parsing_completed",
            "recipe_parsing_completed",
            unit="week",
        ),
        dashboard_id,
    )
    create_report(
        "Notifications Opened",
        "insights",
        _insights_params("notifications_opened", math="unique", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Notification Taps by Type",
        "insights",
        _insights_params(
            "notification_tapped",
            math="total",
            unit="week",
            window=12,
            group_by="notification_type",
            chart_type="bar",
        ),
        dashboard_id,
    )
    create_report(
        "Follows Created",
        "insights",
        _insights_params("user_followed", math="total", unit="week", window=12),
        dashboard_id,
    )
    create_report(
        "Fridge Ingredients Added",
        "insights",
        _insights_params("fridge_ingredient_added", math="total", unit="day", window=30),
        dashboard_id,
    )
    create_report(
        "Meal Calendar Opens",
        "insights",
        _insights_params("meal_calendar_opened", math="total", unit="day", window=30),
        dashboard_id,
    )


def main() -> None:
    print("=== Creating Advanced Yorigo Mixpanel Dashboards ===\n")

    # Resume-friendly: pass existing dashboard IDs via env to avoid duplicates.
    overview_id = int(os.environ.get("MP_DASH_OVERVIEW", "0")) or create_dashboard(
        "Yorigo Product Overview",
        "North-star daily/weekly metrics: DAU, auth, recipe views, parses, purchases, navigation.",
    )
    if not os.environ.get("MP_DASH_OVERVIEW"):
        build_overview(overview_id)
    else:
        print(f"  Reusing Product Overview dashboard {overview_id}")

    acquisition_id = int(os.environ.get("MP_DASH_ACQUISITION", "0")) or create_dashboard(
        "Yorigo Acquisition & Auth",
        "Sign-up/login methods, first-open conversion, password reset and churn signals.",
    )
    build_acquisition(acquisition_id)

    recipe_id = create_dashboard(
        "Yorigo Recipe Engagement",
        "Recipe view → bookmark → cook → review funnels, parse quality, search & share.",
    )
    build_recipe_engagement(recipe_id)

    purchase_id = create_dashboard(
        "Yorigo Purchase Funnel",
        "Cart and affiliate conversion, marketplace mix, and purchase spend.",
    )
    build_purchase(purchase_id)

    retention_id = create_dashboard(
        "Yorigo Engagement & Retention",
        "Cohort retention, notifications, social follows, fridge and meal calendar usage.",
    )
    build_engagement_retention(retention_id)

    print("\n=== Done ===")
    print(f"Product Overview:           dashboard id {overview_id}")
    print(f"Acquisition & Auth:         dashboard id {acquisition_id}")
    print(f"Recipe Engagement:          dashboard id {recipe_id}")
    print(f"Purchase Funnel:            dashboard id {purchase_id}")
    print(f"Engagement & Retention:     dashboard id {retention_id}")
    print("\nOpen Mixpanel → Dashboards to view all charts.")


if __name__ == "__main__":
    main()
