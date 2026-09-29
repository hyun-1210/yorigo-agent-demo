"""Generate markdown tables from daily retention JSON files."""

import json
import os
from pathlib import Path

ANALYTICS = Path(__file__).parent


def load_json(name: str) -> dict:
    path = ANALYTICS / name
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8-sig")
    return json.loads(text)


def cohort_table(
    data: dict,
    label: str,
    min_size: int = 15,
    last_n: int = 15,
    include_dates: list[str] | None = None,
) -> str:
    cohorts_by_date = {c["date"][:10]: c for c in data.get("cohorts", [])}
    selected: list[dict] = []
    if include_dates:
        for d in include_dates:
            c = cohorts_by_date.get(d)
            if c and c.get("size", 0) > 0:
                selected.append(c)
    recent = [c for c in data.get("cohorts", []) if c.get("size", 0) >= min_size]
    if last_n > 0:
        recent = recent[-last_n:]
    else:
        recent = []
    seen = {c["date"][:10] for c in selected}
    for c in recent:
        d = c["date"][:10]
        if d not in seen:
            selected.append(c)
    selected.sort(key=lambda c: c["date"][:10])
    cohorts = selected
    if not cohorts:
        return f"### {label}\n\n_No cohorts with size >= {min_size}._\n\n"

    lines = [
        f"### {label}",
        "",
        "| Cohort date | Size | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |",
        "|-------------|------|----|----|----|----|----|----|----|----|",
    ]
    for c in cohorts:
        d = c["date"][:10]
        size = c["size"]
        r = c.get("retention", [])
        cells = []
        for i in range(8):
            if i < len(r):
                cells.append(f"{r[i] * 100:.0f}%")
            else:
                cells.append("-")
        lines.append(f"| {d} | {size} | " + " | ".join(cells) + " |")
    lines.append("")
    return "\n".join(lines)


def avg_retention_row(data: dict, min_size: int = 50) -> str:
    """Average D0-D7 across cohorts with size >= min_size."""
    cohorts = [c for c in data.get("cohorts", []) if c.get("size", 0) >= min_size]
    if not cohorts:
        return ""
    lines = [
        "",
        f"**Average across cohorts (size ≥ {min_size}, n={len(cohorts)}):**",
        "",
        "| Day | Avg retention |",
        "|-----|---------------|",
    ]
    for day in range(8):
        vals = [
            c["retention"][day]
            for c in cohorts
            if day < len(c.get("retention", []))
        ]
        if vals:
            avg = sum(vals) / len(vals)
            lines.append(f"| D{day} | {avg * 100:.1f}% |")
    lines.append("")
    return "\n".join(lines)


PAIRS = [
    ("retention_daily_signup_active.json", "Sign-up → Active user (`yorigo_active_user`)"),
    ("retention_daily_signup_parse.json", "Sign-up → Parse completed"),
    ("retention_daily_signup_bookmark.json", "Sign-up → Recipe bookmarked"),
    ("retention_daily_firstopen_signup.json", "First open → Sign-up"),
    ("retention_daily_firstopen_active.json", "First open → Active user"),
    ("retention_daily_cartadd_purchase.json", "Cart add (footer click) → Purchase completed"),
    ("retention_daily_cartadd_affiliate.json", "Cart add (footer click) → Affiliate link clicked"),
    ("retention_daily_ingadd_purchase.json", "Ingredient add click → Purchase completed"),
    (
        "retention_daily_checked_purchase.json",
        "Ingredient checked in cart → Purchase completed",
    ),
    (
        "retention_daily_checked_affiliate.json",
        "Ingredient checked in cart → Affiliate link clicked",
    ),
]

LAUNCH_COHORTS = [
    "2026-05-28",
    "2026-05-29",
    "2026-05-30",
    "2026-05-31",
    "2026-06-01",
]

out = [
    "## Daily cohort retention (first 7 days)\n",
    "D0 = same calendar day as birth event. D7 = 7 days after cohort date.\n",
    "",
    "### Launch cohorts (May 28 spike)\n",
    "Sign-up cohorts from the main growth spike; daily return as active user.\n",
]
launch_data = load_json("retention_daily_signup_active.json")
out.append(
    cohort_table(
        launch_data,
        "Sign-up → Active user (launch week cohorts)",
        include_dates=LAUNCH_COHORTS,
        last_n=0,
    )
)
out.append(avg_retention_row(launch_data, min_size=100))
out.append("")
for fname, label in PAIRS:
    data = load_json(fname)
    out.append(cohort_table(data, label, min_size=15))
    if fname == "retention_daily_signup_active.json":
        out.append(avg_retention_row(data, min_size=100))

Path(ANALYTICS / "retention_daily_tables.md").write_text("\n".join(out), encoding="utf-8")
print("Written retention_daily_tables.md")
