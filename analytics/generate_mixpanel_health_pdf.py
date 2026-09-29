"""Mixpanel 이벤트 헬스체크 → PDF 리포트 생성.

backend/.env 의 MIXPANEL_API_SECRET 을 사용해 Query API로 조회한다.
"""

from __future__ import annotations

import base64
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / "backend" / ".env"
OUT_DIR = Path(__file__).resolve().parent
JSON_OUT = OUT_DIR / "mixpanel_health_snapshot.json"
PDF_OUT = OUT_DIR / "mixpanel_health_report.pdf"

# 코드베이스에 정의된 이벤트 (이전 인벤토리)
CODE_CLIENT_DUAL: list[str] = [
    "app_first_open",
    "sign_up",
    "login",
    "logout",
    "password_reset_requested",
    "account_deleted",
    "screen_view",
    "screen_stay",
    "main_tab_selected",
    "share_extension_opened",
    "add_recipe_opened",
    "parsing_request_started",
    "recipe_dedup_found",
    "recipe_parsing_completed",
    "recipe_parsing_failed",
    "recipe_viewed",
    "recipe_detail_tab_selected",
    "cooking_started",
    "cooking_completed",
    "search_opened",
    "meal_calendar_opened",
    "notifications_opened",
    "notification_tapped",
    "fridge_ingredient_added",
    "user_followed",
    "user_unfollowed",
    "recipe_bookmarked",
    "review_created",
    "recipe_cart_add_footer_clicked",
    "recipe_ingredient_add_clicked",
    "affiliate_link_clicked",
    "ingredient_purchase_checked",
    "cart_majority_checked",
    "purchase_button_clicked",
    "cart_purchase_completed",
    "ingredient_purchased",
    "recipe_saved_from_feed",  # unwired in code
]

CODE_CLIENT_MP_ONLY: list[str] = ["yorigo_active_user"]

CODE_SERVER_MP: list[str] = [
    "server_parse_completed",
    "server_parse_failed",
    "server_parse_dedup",
    "daily_recipe_db_snapshot",
]

CODE_ALL: list[str] = CODE_CLIENT_DUAL + CODE_CLIENT_MP_ONLY + CODE_SERVER_MP

WORKFLOWS: dict[str, list[str]] = {
    "앱 라이프사이클": [
        "app_first_open",
        "screen_view",
        "screen_stay",
        "main_tab_selected",
        "share_extension_opened",
        "yorigo_active_user",
    ],
    "인증": [
        "sign_up",
        "login",
        "logout",
        "password_reset_requested",
        "account_deleted",
    ],
    "파싱(클라이언트)": [
        "add_recipe_opened",
        "parsing_request_started",
        "recipe_dedup_found",
        "recipe_parsing_completed",
        "recipe_parsing_failed",
    ],
    "파싱(서버)": [
        "server_parse_completed",
        "server_parse_failed",
        "server_parse_dedup",
        "daily_recipe_db_snapshot",
    ],
    "레시피 참여": [
        "recipe_viewed",
        "recipe_detail_tab_selected",
        "cooking_started",
        "cooking_completed",
        "search_opened",
        "meal_calendar_opened",
        "notifications_opened",
        "notification_tapped",
        "fridge_ingredient_added",
        "user_followed",
        "user_unfollowed",
        "recipe_bookmarked",
        "review_created",
        "recipe_saved_from_feed",
    ],
    "장바구니/구매": [
        "recipe_cart_add_footer_clicked",
        "recipe_ingredient_add_clicked",
        "affiliate_link_clicked",
        "ingredient_purchase_checked",
        "cart_majority_checked",
        "purchase_button_clicked",
        "cart_purchase_completed",
        "ingredient_purchased",
    ],
}


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def mp_get(secret: str, path: str, params: dict[str, Any] | None = None) -> Any:
    query = urllib.parse.urlencode(params or {}, doseq=True)
    url = f"https://mixpanel.com/api/2.0/{path}"
    if query:
        url = f"{url}?{query}"
    auth = base64.b64encode(f"{secret}:".encode()).decode()
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Basic {auth}",
            "Accept": "application/json",
        },
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=120, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_event_names(secret: str) -> list[str]:
    data = mp_get(secret, "events/names", {"type": "general"})
    if isinstance(data, list):
        return sorted(str(x) for x in data)
    return []


def fetch_event_totals(
    secret: str,
    events: list[str],
    from_date: str,
    to_date: str,
    unit: str = "month",
) -> dict[str, int]:
    """기간 내 이벤트 total count 합산."""
    if not events:
        return {}
    # Mixpanel events endpoint는 한 번에 너무 많은 이벤트를 받기 어려울 수 있어 청크
    totals: dict[str, int] = defaultdict(int)
    chunk_size = 15
    for i in range(0, len(events), chunk_size):
        chunk = events[i : i + chunk_size]
        data = mp_get(
            secret,
            "events",
            {
                "from_date": from_date,
                "to_date": to_date,
                "event": json.dumps(chunk),
                "type": "general",
                "unit": unit,
            },
        )
        series = data.get("data", {}).get("values", {}) if isinstance(data, dict) else {}
        # shape: {event_name: {date: count}}
        for event_name, by_date in series.items():
            if isinstance(by_date, dict):
                totals[event_name] += sum(int(v) for v in by_date.values())
            else:
                totals[event_name] += int(by_date or 0)
    return dict(totals)


def fetch_event_uniques(
    secret: str,
    events: list[str],
    from_date: str,
    to_date: str,
    unit: str = "month",
) -> dict[str, int]:
    totals: dict[str, int] = defaultdict(int)
    chunk_size = 15
    for i in range(0, len(events), chunk_size):
        chunk = events[i : i + chunk_size]
        data = mp_get(
            secret,
            "events",
            {
                "from_date": from_date,
                "to_date": to_date,
                "event": json.dumps(chunk),
                "type": "unique",
                "unit": unit,
            },
        )
        series = data.get("data", {}).get("values", {}) if isinstance(data, dict) else {}
        for event_name, by_date in series.items():
            if isinstance(by_date, dict):
                # unique는 월 단위 합이 중복될 수 있어 max 사용 (대략)
                totals[event_name] = max(
                    totals[event_name],
                    max((int(v) for v in by_date.values()), default=0),
                )
            else:
                totals[event_name] = max(totals[event_name], int(by_date or 0))
    return dict(totals)


def build_report(secret: str) -> dict[str, Any]:
    today = date.today()
    from_90 = (today - timedelta(days=90)).isoformat()
    from_30 = (today - timedelta(days=30)).isoformat()
    to_date = today.isoformat()

    live_names = fetch_event_names(secret)
    live_set = set(live_names)
    code_set = set(CODE_ALL)

    in_code_and_live = sorted(code_set & live_set)
    in_code_not_live = sorted(code_set - live_set)
    in_live_not_code = sorted(live_set - code_set)

    # 코드 이벤트 + 라이브 orphan 상위 후보 전체 카운트
    interest = sorted(set(CODE_ALL) | set(in_live_not_code))
    totals_90 = fetch_event_totals(secret, interest, from_90, to_date, unit="month")
    totals_30 = fetch_event_totals(secret, interest, from_30, to_date, unit="day")
    uniques_30 = fetch_event_uniques(secret, interest, from_30, to_date, unit="day")

    # zero / low volume among code events
    zero_90 = sorted(e for e in CODE_ALL if totals_90.get(e, 0) == 0)
    low_30 = sorted(
        e for e in CODE_ALL if 0 < totals_30.get(e, 0) < 5
    )

    workflow_stats: dict[str, Any] = {}
    for name, events in WORKFLOWS.items():
        workflow_stats[name] = {
            "events": [
                {
                    "name": e,
                    "in_live_catalog": e in live_set,
                    "count_90d": totals_90.get(e, 0),
                    "count_30d": totals_30.get(e, 0),
                    "unique_peak_day_30d": uniques_30.get(e, 0),
                    "status": (
                        "missing_in_mixpanel"
                        if e not in live_set
                        else (
                            "no_data_90d"
                            if totals_90.get(e, 0) == 0
                            else (
                                "low_volume_30d"
                                if totals_30.get(e, 0) < 5
                                else "healthy"
                            )
                        )
                    ),
                }
                for e in events
            ]
        }

    top_live = sorted(
        ((e, totals_90.get(e, 0)) for e in live_names),
        key=lambda x: x[1],
        reverse=True,
    )[:40]

    return {
        "generated_at": today.isoformat(),
        "project_note": "Queried via Mixpanel Query API (API Secret from backend/.env). MCP server not attached in this Cursor session.",
        "window": {
            "from_90d": from_90,
            "from_30d": from_30,
            "to": to_date,
        },
        "summary": {
            "live_event_names": len(live_names),
            "code_events": len(CODE_ALL),
            "in_code_and_live": len(in_code_and_live),
            "in_code_not_live": len(in_code_not_live),
            "in_live_not_code": len(in_live_not_code),
            "zero_volume_90d_code_events": len(zero_90),
            "low_volume_30d_code_events": len(low_30),
        },
        "in_code_not_live": in_code_not_live,
        "in_live_not_code": in_live_not_code,
        "zero_90": zero_90,
        "low_30": low_30,
        "totals_90": totals_90,
        "totals_30": totals_30,
        "uniques_30": uniques_30,
        "workflows": workflow_stats,
        "top_live_90d": top_live,
        "live_names": live_names,
        "notes": [
            "recipe_saved_from_feed: 코드에 정의만 있고 호출처 없음 (의도적 dead event 가능)",
            "yorigo_active_user: Mixpanel + Firestore only (Firebase Analytics 미전송)",
            "서버 이벤트(server_parse_*, daily_recipe_db_snapshot): Mixpanel only",
            "Firebase Analytics 실데이터는 이 리포트에 포함되지 않음",
        ],
    }


def _try_import_reportlab() -> Any:
    try:
        from reportlab.lib import colors
        from reportlab.lib.enums import TA_CENTER, TA_LEFT
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
        from reportlab.lib.units import mm
        from reportlab.platypus import (
            PageBreak,
            Paragraph,
            SimpleDocTemplate,
            Spacer,
            Table,
            TableStyle,
        )

        return {
            "colors": colors,
            "TA_CENTER": TA_CENTER,
            "TA_LEFT": TA_LEFT,
            "A4": A4,
            "ParagraphStyle": ParagraphStyle,
            "getSampleStyleSheet": getSampleStyleSheet,
            "mm": mm,
            "PageBreak": PageBreak,
            "Paragraph": Paragraph,
            "SimpleDocTemplate": SimpleDocTemplate,
            "Spacer": Spacer,
            "Table": Table,
            "TableStyle": TableStyle,
        }
    except ImportError:
        return None


def write_pdf(report: dict[str, Any], path: Path) -> None:
    rl = _try_import_reportlab()
    if rl is None:
        raise RuntimeError("reportlab not installed")

    colors = rl["colors"]
    A4 = rl["A4"]
    ParagraphStyle = rl["ParagraphStyle"]
    getSampleStyleSheet = rl["getSampleStyleSheet"]
    mm = rl["mm"]
    PageBreak = rl["PageBreak"]
    Paragraph = rl["Paragraph"]
    SimpleDocTemplate = rl["SimpleDocTemplate"]
    Spacer = rl["Spacer"]
    Table = rl["Table"]
    TableStyle = rl["TableStyle"]

    doc = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        leftMargin=16 * mm,
        rightMargin=16 * mm,
        topMargin=14 * mm,
        bottomMargin=14 * mm,
        title="Yorigo Mixpanel Health Report",
    )
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "TitleKR",
        parent=styles["Title"],
        fontSize=18,
        spaceAfter=8,
        alignment=rl["TA_CENTER"],
    )
    h1 = ParagraphStyle(
        "H1KR",
        parent=styles["Heading1"],
        fontSize=13,
        spaceBefore=10,
        spaceAfter=6,
    )
    h2 = ParagraphStyle(
        "H2KR",
        parent=styles["Heading2"],
        fontSize=11,
        spaceBefore=8,
        spaceAfter=4,
    )
    body = ParagraphStyle(
        "BodyKR",
        parent=styles["Normal"],
        fontSize=9,
        leading=12,
        spaceAfter=4,
    )
    small = ParagraphStyle(
        "SmallKR",
        parent=styles["Normal"],
        fontSize=8,
        leading=10,
    )
    cell = ParagraphStyle(
        "CellKR",
        parent=styles["Normal"],
        fontSize=7.5,
        leading=9,
    )

    story: list[Any] = []
    s = report["summary"]
    story.append(Paragraph("Yorigo Mixpanel Analytics Health Report", title_style))
    story.append(
        Paragraph(
            f"Generated: {report['generated_at']} &nbsp;|&nbsp; "
            f"Window: {report['window']['from_90d']} ~ {report['window']['to']}",
            body,
        )
    )
    story.append(Paragraph(report["project_note"], small))
    story.append(Spacer(1, 6))

    story.append(Paragraph("1. Executive Summary", h1))
    summary_rows = [
        ["Metric", "Value"],
        ["Live Mixpanel event names", str(s["live_event_names"])],
        ["Code-defined events", str(s["code_events"])],
        ["In code AND live catalog", str(s["in_code_and_live"])],
        ["In code but NOT in live catalog", str(s["in_code_not_live"])],
        ["In live but NOT in code", str(s["in_live_not_code"])],
        ["Code events with 0 volume (90d)", str(s["zero_volume_90d_code_events"])],
        ["Code events with low volume (<5 in 30d)", str(s["low_volume_30d_code_events"])],
    ]
    t = Table(summary_rows, colWidths=[110 * mm, 60 * mm])
    t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f2937")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.Color(0.95, 0.95, 0.97)]),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 4),
                ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    story.append(t)
    story.append(Spacer(1, 8))

    story.append(Paragraph("Notes / Caveats", h2))
    for note in report["notes"]:
        story.append(Paragraph(f"• {note}", body))

    story.append(Paragraph("2. Gaps: Code vs Mixpanel Catalog", h1))
    story.append(Paragraph("2.1 In code but missing from Mixpanel event catalog", h2))
    if report["in_code_not_live"]:
        for e in report["in_code_not_live"]:
            story.append(Paragraph(f"• <font color='red'>{e}</font>", small))
    else:
        story.append(Paragraph("None — all code events appear in Mixpanel catalog.", body))

    story.append(Paragraph("2.2 Code events with zero volume (90d)", h2))
    if report["zero_90"]:
        for e in report["zero_90"]:
            story.append(Paragraph(f"• {e}", small))
    else:
        story.append(Paragraph("None.", body))

    story.append(Paragraph("2.3 Live events not referenced in current code inventory", h2))
    if report["in_live_not_code"]:
        for e in report["in_live_not_code"]:
            cnt = report["totals_90"].get(e, 0)
            story.append(Paragraph(f"• {e} (90d total ≈ {cnt})", small))
    else:
        story.append(Paragraph("None.", body))

    story.append(PageBreak())
    story.append(Paragraph("3. Workflow Breakdown", h1))

    status_color = {
        "healthy": "#166534",
        "low_volume_30d": "#a16207",
        "no_data_90d": "#b91c1c",
        "missing_in_mixpanel": "#7f1d1d",
    }

    for wf_name, wf in report["workflows"].items():
        story.append(Paragraph(wf_name, h2))
        rows = [
            [
                Paragraph("Event", cell),
                Paragraph("90d", cell),
                Paragraph("30d", cell),
                Paragraph("Status", cell),
            ]
        ]
        for item in wf["events"]:
            sc = status_color.get(item["status"], "#111")
            rows.append(
                [
                    Paragraph(item["name"], cell),
                    Paragraph(str(item["count_90d"]), cell),
                    Paragraph(str(item["count_30d"]), cell),
                    Paragraph(
                        f"<font color='{sc}'>{item['status']}</font>",
                        cell,
                    ),
                ]
            )
        wt = Table(rows, colWidths=[85 * mm, 25 * mm, 25 * mm, 35 * mm])
        wt.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#334155")),
                    ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                    ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 3),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 3),
                    ("TOPPADDING", (0, 0), (-1, -1), 2),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                    (
                        "ROWBACKGROUNDS",
                        (0, 1),
                        (-1, -1),
                        [colors.white, colors.HexColor("#f8fafc")],
                    ),
                ]
            )
        )
        story.append(wt)
        story.append(Spacer(1, 6))

    story.append(PageBreak())
    story.append(Paragraph("4. Top Live Events (90d totals)", h1))
    top_rows = [
        [
            Paragraph("#", cell),
            Paragraph("Event", cell),
            Paragraph("90d total", cell),
            Paragraph("In code?", cell),
        ]
    ]
    code_set = set(CODE_ALL)
    for idx, (name, cnt) in enumerate(report["top_live_90d"], start=1):
        top_rows.append(
            [
                Paragraph(str(idx), cell),
                Paragraph(name, cell),
                Paragraph(f"{cnt:,}", cell),
                Paragraph("Y" if name in code_set else "N", cell),
            ]
        )
    top_t = Table(top_rows, colWidths=[12 * mm, 100 * mm, 30 * mm, 28 * mm])
    top_t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f2937")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
                ("FONTSIZE", (0, 0), (-1, -1), 7.5),
                (
                    "ROWBACKGROUNDS",
                    (0, 1),
                    (-1, -1),
                    [colors.white, colors.HexColor("#f1f5f9")],
                ),
            ]
        )
    )
    story.append(top_t)

    story.append(Spacer(1, 10))
    story.append(Paragraph("5. Management Assessment", h1))
    healthy = 0
    warn = 0
    bad = 0
    for wf in report["workflows"].values():
        for item in wf["events"]:
            st = item["status"]
            if st == "healthy":
                healthy += 1
            elif st == "low_volume_30d":
                warn += 1
            else:
                bad += 1
    story.append(
        Paragraph(
            f"Across workflow-tracked events: "
            f"<b>{healthy}</b> healthy, <b>{warn}</b> low-volume, "
            f"<b>{bad}</b> missing/no-data.",
            body,
        )
    )
    story.append(
        Paragraph(
            "Interpretation guide: healthy = catalog present and ≥5 events in last 30d; "
            "low_volume_30d = some traffic but sparse; no_data_90d / missing_in_mixpanel "
            "need investigation (instrumentation gap, token mismatch, or unused feature).",
            body,
        )
    )
    story.append(Spacer(1, 6))
    story.append(
        Paragraph(
            "This PDF was generated from Mixpanel Query API using credentials in "
            "backend/.env. Mixpanel MCP was not available in the agent session; "
            "credentials from .cursor/mcp.json match the same project pattern.",
            small,
        )
    )

    doc.build(story)


def write_fallback_html_pdf(report: dict[str, Any], path: Path) -> None:
    """reportlab 없을 때 HTML 저장 후 안내. (PDF 대체용 HTML)"""
    html_path = path.with_suffix(".html")
    s = report["summary"]
    rows = []
    for wf_name, wf in report["workflows"].items():
        rows.append(f"<h3>{wf_name}</h3><table border='1' cellpadding='4' cellspacing='0'>")
        rows.append(
            "<tr><th>Event</th><th>90d</th><th>30d</th><th>Status</th></tr>"
        )
        for item in wf["events"]:
            rows.append(
                "<tr>"
                f"<td>{item['name']}</td>"
                f"<td>{item['count_90d']}</td>"
                f"<td>{item['count_30d']}</td>"
                f"<td>{item['status']}</td>"
                "</tr>"
            )
        rows.append("</table>")

    html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Mixpanel Health</title>
<style>
body {{ font-family: Arial, sans-serif; margin: 24px; font-size: 13px; }}
table {{ border-collapse: collapse; margin-bottom: 16px; width: 100%; }}
th {{ background: #1f2937; color: #fff; }}
td, th {{ border: 1px solid #ccc; padding: 4px 6px; }}
</style></head><body>
<h1>Yorigo Mixpanel Analytics Health Report</h1>
<p>Generated: {report['generated_at']}</p>
<p>{report['project_note']}</p>
<ul>
<li>Live events: {s['live_event_names']}</li>
<li>Code events: {s['code_events']}</li>
<li>Code not live: {s['in_code_not_live']}</li>
<li>Live not code: {s['in_live_not_code']}</li>
<li>Zero volume 90d: {s['zero_volume_90d_code_events']}</li>
</ul>
{''.join(rows)}
</body></html>"""
    html_path.write_text(html, encoding="utf-8")
    print(f"Wrote HTML fallback: {html_path}")


def main() -> None:
    env = load_env(ENV_PATH)
    secret = env.get("MIXPANEL_API_SECRET", "").strip()
    if not secret:
        raise SystemExit("MIXPANEL_API_SECRET missing in backend/.env")

    print("Fetching Mixpanel data...")
    try:
        report = build_report(secret)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Mixpanel API HTTP {e.code}: {body[:500]}") from e

    JSON_OUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Wrote snapshot: {JSON_OUT}")
    print("Summary:", json.dumps(report["summary"], ensure_ascii=False))

    try:
        import reportlab  # noqa: F401
    except ImportError:
        print("Installing reportlab...")
        import subprocess
        import sys

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "reportlab", "-q"]
        )

    try:
        write_pdf(report, PDF_OUT)
        print(f"Wrote PDF: {PDF_OUT}")
    except Exception as e:
        print(f"PDF failed ({e}), writing HTML fallback...")
        write_fallback_html_pdf(report, PDF_OUT)


if __name__ == "__main__":
    main()
