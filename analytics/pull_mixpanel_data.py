"""Pull Mixpanel metrics for investor report. Run: python analytics/pull_mixpanel_data.py"""

import json
import subprocess
import sys
from datetime import date
from typing import Any

MP_CLI = [sys.executable, "-m", "mixpanel_headless"]
FROM_DATE = "2024-01-01"
TO_DATE = date.today().isoformat()


def run_mp(*args: str) -> Any:
    cmd = [*MP_CLI, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        print(f"ERROR: {' '.join(args)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    raw = result.stdout.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def event_counts_unique(events: list[str], unit: str = "day") -> dict[str, dict[str, int]]:
    data = run_mp(
        "query",
        "event-counts",
        "--events",
        ",".join(events),
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
        "--type",
        "unique",
        "--unit",
        unit,
        "-f",
        "json",
    )
    return data.get("series", {})


def event_counts_total(events: list[str], unit: str = "day") -> dict[str, dict[str, int]]:
    data = run_mp(
        "query",
        "event-counts",
        "--events",
        ",".join(events),
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
        "--type",
        "general",
        "--unit",
        unit,
        "-f",
        "json",
    )
    return data.get("series", {})


def retention(born: str, return_event: str, unit: str = "week", intervals: int = 8) -> dict:
    return run_mp(
        "query",
        "retention",
        "--born",
        born,
        "--return",
        return_event,
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
        "--unit",
        unit,
        "--intervals",
        str(intervals),
        "-f",
        "json",
    )


def segmentation_unique(event: str, unit: str = "day", where: str | None = None) -> dict:
    args = [
        "query",
        "segmentation",
        "-e",
        event,
        "--from",
        FROM_DATE,
        "--to",
        TO_DATE,
        "--unit",
        unit,
        "-f",
        "json",
    ]
    if where:
        args.extend(["-w", where])
    return run_mp(*args)


def sum_series(series: dict[str, int]) -> int:
    return sum(series.values())


def last_n_keys(series: dict[str, int], n: int) -> list[str]:
    return sorted(series.keys())[-n:]


def main() -> None:
    report: dict[str, Any] = {
        "generated_at": date.today().isoformat(),
        "from_date": FROM_DATE,
        "to_date": TO_DATE,
        "events_in_project": run_mp("inspect", "events", "-f", "json"),
    }

    # DAU / WAU
    dau_events = [
        "yorigo_active_user",
        "screen_view",
        "sign_up",
        "app_first_open",
        "parsing_request_started",
        "recipe_parsing_completed",
    ]
    dau_unique = event_counts_unique(dau_events, "day")
    wau_unique = event_counts_unique(["yorigo_active_user", "screen_view"], "week")

    report["dau_unique_daily"] = {
        k: {d: dau_unique[k].get(d, 0) for d in last_n_keys(dau_unique.get("yorigo_active_user", {}), 60)}
        for k in dau_events
        if k in dau_unique
    }
    report["wau_unique_weekly"] = {
        k: {d: wau_unique[k].get(d, 0) for d in last_n_keys(wau_unique.get("yorigo_active_user", {}), 16)}
        for k in wau_unique
    }

    # Summary stats
    report["summary"] = {
        "total_unique_sign_ups": sum_series(dau_unique.get("sign_up", {})),
        "total_unique_app_first_opens": sum_series(dau_unique.get("app_first_open", {})),
        "total_unique_parsing_completed": sum_series(
            dau_unique.get("recipe_parsing_completed", {})
        ),
        "peak_dau_registered": max(dau_unique.get("yorigo_active_user", {}).values() or [0]),
        "peak_dau_all_screen_view": max(dau_unique.get("screen_view", {}).values() or [0]),
        "latest_dau_registered": dau_unique.get("yorigo_active_user", {}).get(
            last_n_keys(dau_unique.get("yorigo_active_user", {}), 1)[0]
            if dau_unique.get("yorigo_active_user")
            else "",
            0,
        ),
        "latest_dau_screen_view": dau_unique.get("screen_view", {}).get(
            last_n_keys(dau_unique.get("screen_view", {}), 1)[0]
            if dau_unique.get("screen_view")
            else "",
            0,
        ),
    }

    # Key funnel events totals (unique users ever)
    funnel_events = [
        "recipe_bookmarked",
        "affiliate_link_clicked",
        "cart_majority_checked",
        "cart_purchase_completed",
        "purchase_button_clicked",
        "ingredient_purchased",
        "review_created",
        "recipe_parsing_failed",
        "ingredient_purchase_checked",
        "recipe_cart_add_footer_clicked",
        "recipe_ingredient_add_clicked",
    ]
    funnel_unique = event_counts_unique(funnel_events, "month")
    report["funnel_unique_users_by_month"] = funnel_unique
    report["funnel_total_unique_users"] = {
        e: sum_series(funnel_unique.get(e, {})) for e in funnel_events
    }

    # Parsing by platform
    try:
        platform_seg = run_mp(
            "query",
            "segmentation",
            "-e",
            "recipe_parsing_completed",
            "--from",
            FROM_DATE,
            "--to",
            TO_DATE,
            "--unit",
            "month",
            "-o",
            "platform",
            "-f",
            "json",
        )
        report["parsing_completed_by_platform_monthly"] = platform_seg
    except SystemExit:
        report["parsing_completed_by_platform_monthly"] = {}

    # Auth vs non-auth parsing
    try:
        auth_seg = run_mp(
            "query",
            "segmentation",
            "-e",
            "parsing_request_started",
            "--from",
            FROM_DATE,
            "--to",
            TO_DATE,
            "--unit",
            "month",
            "-o",
            "is_authenticated",
            "-f",
            "json",
        )
        report["parsing_requests_auth_vs_guest_monthly"] = auth_seg
    except SystemExit:
        report["parsing_requests_auth_vs_guest_monthly"] = {}

    # Retention cohorts
    retention_pairs = [
        ("sign_up", "yorigo_active_user", "signup_to_active_user"),
        ("sign_up", "recipe_parsing_completed", "signup_to_parse"),
        ("sign_up", "recipe_bookmarked", "signup_to_bookmark"),
        ("sign_up", "affiliate_link_clicked", "signup_to_affiliate_click"),
        ("sign_up", "cart_purchase_completed", "signup_to_purchase"),
        ("sign_up", "cart_majority_checked", "signup_to_cart_majority"),
        ("recipe_parsing_completed", "recipe_parsing_completed", "parse_to_reparse"),
        ("app_first_open", "sign_up", "first_open_to_signup"),
        ("app_first_open", "recipe_parsing_completed", "first_open_to_parse"),
    ]
    report["retention_weekly"] = {}
    for born, ret, label in retention_pairs:
        try:
            report["retention_weekly"][label] = retention(born, ret, "week", 8)
        except SystemExit:
            report["retention_weekly"][label] = {"error": "query failed"}

    out_path = "analytics/mixpanel_investor_data.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    print(f"Written {out_path}")


if __name__ == "__main__":
    main()
