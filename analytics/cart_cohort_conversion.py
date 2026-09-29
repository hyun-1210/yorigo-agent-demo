"""Pull signup cohort → cart add / purchase conversion from Mixpanel."""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import date
from typing import Any, Dict, List

MP = [sys.executable, "-m", "mixpanel_headless"]
FROM = "2026-05-01"
TO = date.today().isoformat()


def run_mp(*args: str) -> Any:
    r = subprocess.run([*MP, *args], capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise RuntimeError(f"mixpanel failed: {args}\n{r.stderr}")
    return json.loads(r.stdout)


def retention(born: str, return_evt: str, unit: str = "week", intervals: int = 4) -> dict:
    return run_mp(
        "query",
        "retention",
        "--born",
        born,
        "--return",
        return_evt,
        "--from",
        FROM,
        "--to",
        TO,
        "--unit",
        unit,
        "--intervals",
        str(intervals),
        "-f",
        "json",
    )


def event_unique_monthly(events: List[str]) -> Dict[str, Dict[str, int]]:
    data = run_mp(
        "query",
        "event-counts",
        "--events",
        ",".join(events),
        "--from",
        FROM,
        "--to",
        TO,
        "--type",
        "unique",
        "--unit",
        "week",
        "-f",
        "json",
    )
    return data.get("series", {})


def cohort_rows(data: dict, max_week: int = 0) -> List[dict]:
    rows = []
    for c in data.get("cohorts", []):
        size = int(c.get("size") or 0)
        if size <= 0:
            continue
        ret = c.get("retention") or []
        w0 = float(ret[max_week] if len(ret) > max_week else 0.0)
        rows.append(
            {
                "cohort_week": c.get("date", "")[:10],
                "cohort_size": size,
                "converted_users": round(size * w0),
                "rate_pct": round(w0 * 100, 2),
            }
        )
    return rows


def sum_unique(series: Dict[str, int]) -> int:
    return sum(series.values())


def main() -> None:
    cart_events = [
        "recipe_cart_add_footer_clicked",
        "recipe_ingredient_add_clicked",
        "cart_purchase_completed",
        "ingredient_purchase_checked",
        "cart_majority_checked",
    ]
    signup_weekly = event_unique_monthly(["sign_up"] + cart_events)

    ret_cart_add = retention("sign_up", "recipe_cart_add_footer_clicked")
    ret_ing_add = retention("sign_up", "recipe_ingredient_add_clicked")
    ret_purchase = retention("sign_up", "cart_purchase_completed")
    ret_checked = retention("sign_up", "ingredient_purchase_checked")

    # Cart add → purchase (users who added then purchased, week 0)
    ret_add_to_purchase = retention(
        "recipe_cart_add_footer_clicked", "cart_purchase_completed", intervals=2
    )

    out = {
        "generated_at": date.today().isoformat(),
        "from_date": FROM,
        "to_date": TO,
        "weekly_unique_users": {
            e: signup_weekly.get(e, {}) for e in ["sign_up"] + cart_events
        },
        "cohort_signup_to_cart_footer_click_w0": cohort_rows(ret_cart_add, 0),
        "cohort_signup_to_ingredient_add_click_w0": cohort_rows(ret_ing_add, 0),
        "cohort_signup_to_purchase_w0": cohort_rows(ret_purchase, 0),
        "cohort_signup_to_ingredient_checked_w0": cohort_rows(ret_checked, 0),
        "cohort_cart_add_to_purchase_w0": cohort_rows(ret_add_to_purchase, 0),
    }

    path = "analytics/cart_cohort_conversion.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print("=== Weekly unique users (sign_up + cart events) ===")
    weeks = sorted(signup_weekly.get("sign_up", {}).keys())
    for w in weeks:
        su = signup_weekly.get("sign_up", {}).get(w, 0)
        ca = signup_weekly.get("recipe_cart_add_footer_clicked", {}).get(w, 0)
        pu = signup_weekly.get("cart_purchase_completed", {}).get(w, 0)
        ch = signup_weekly.get("ingredient_purchase_checked", {}).get(w, 0)
        print(f"  {w}: signups={su} cart_add={ca} purchase={pu} ing_checked={ch}")

    print("\n=== Signup cohort → cart add (week 0) ===")
    for row in out["cohort_signup_to_cart_footer_click_w0"]:
        print(
            f"  {row['cohort_week']}: {row['cohort_size']} signups → "
            f"{row['converted_users']} cart add ({row['rate_pct']}%)"
        )

    print("\n=== Signup cohort → purchase (week 0) ===")
    for row in out["cohort_signup_to_purchase_w0"]:
        print(
            f"  {row['cohort_week']}: {row['cohort_size']} signups → "
            f"{row['converted_users']} purchase ({row['rate_pct']}%)"
        )

    print("\n=== Signup cohort → ingredient checked (week 0) ===")
    for row in out["cohort_signup_to_ingredient_checked_w0"]:
        print(
            f"  {row['cohort_week']}: {row['cohort_size']} signups → "
            f"{row['converted_users']} checked ({row['rate_pct']}%)"
        )

    print(f"\nSaved: {path}")


if __name__ == "__main__":
    main()
