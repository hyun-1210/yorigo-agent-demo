"""기존 mixpanel_health_snapshot.json 을 한글 PDF로 재생성."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parent
SNAPSHOT = ROOT / "mixpanel_health_snapshot.json"
PDF_OUT = ROOT / "mixpanel_health_report_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "mixpanel_health_report_ko.pdf"

FONT = "Malgun"
FONT_B = "MalgunBold"
pdfmetrics.registerFont(TTFont(FONT, r"C:\Windows\Fonts\malgun.ttf"))
pdfmetrics.registerFont(TTFont(FONT_B, r"C:\Windows\Fonts\malgunbd.ttf"))

EVENT_KO: dict[str, str] = {
    "app_first_open": "앱 최초 실행",
    "sign_up": "회원가입",
    "login": "로그인",
    "logout": "로그아웃",
    "password_reset_requested": "비밀번호 재설정 요청",
    "account_deleted": "계정 삭제",
    "screen_view": "화면 조회",
    "screen_stay": "화면 체류",
    "main_tab_selected": "하단 탭 선택",
    "share_extension_opened": "공유 확장 열림",
    "add_recipe_opened": "레시피 추가 시트 열림",
    "parsing_request_started": "파싱 요청 시작",
    "recipe_dedup_found": "클라이언트 중복 레시피 발견",
    "recipe_parsing_completed": "파싱 완료(클라)",
    "recipe_parsing_failed": "파싱 실패(클라)",
    "recipe_viewed": "레시피 상세 조회",
    "recipe_detail_tab_selected": "레시피 상세 탭 전환",
    "cooking_started": "요리 시작",
    "cooking_completed": "요리 완료",
    "search_opened": "검색 열림",
    "meal_calendar_opened": "식단 캘린더 열림",
    "notifications_opened": "알림 목록 열림",
    "notification_tapped": "알림 탭(딥링크)",
    "fridge_ingredient_added": "냉장고 재료 추가",
    "user_followed": "팔로우",
    "user_unfollowed": "언팔로우",
    "recipe_bookmarked": "레시피 북마크/저장",
    "review_created": "리뷰 작성",
    "recipe_cart_add_footer_clicked": "상세 푸터 장바구니 담기",
    "recipe_ingredient_add_clicked": "재료 행 '담기' 클릭",
    "affiliate_link_clicked": "제휴(마켓) 링크 클릭",
    "ingredient_purchase_checked": "장바구니 재료 체크",
    "cart_majority_checked": "장바구니 과반 체크",
    "purchase_button_clicked": "구매 버튼 클릭",
    "cart_purchase_completed": "장바구니 구매 완료",
    "ingredient_purchased": "재료별 구매 완료",
    "recipe_saved_from_feed": "피드에서 저장(미연결)",
    "yorigo_active_user": "활성 사용자(일/주/월)",
    "server_parse_completed": "서버 파싱 완료",
    "server_parse_failed": "서버 파싱 실패",
    "server_parse_dedup": "서버 파싱 중복 처리",
    "daily_recipe_db_snapshot": "일일 레시피 DB 스냅샷",
}

STATUS_KO: dict[str, str] = {
    "healthy": "정상",
    "low_volume_30d": "최근 저조",
    "no_data_90d": "90일 무실적",
    "missing_in_mixpanel": "MP 미등록",
}

STATUS_COLOR: dict[str, str] = {
    "healthy": "#166534",
    "low_volume_30d": "#a16207",
    "no_data_90d": "#b91c1c",
    "missing_in_mixpanel": "#7f1d1d",
}

GAP_EXPLAIN: dict[str, str] = {
    "cooking_completed": "요리 완료 경로에서 이벤트가 한 번도 안 들어옴. cooking_started(22)와 대비되어 완료 트래킹 누락/미도달 가능성.",
    "password_reset_requested": "비밀번호 재설정 요청이 거의 없거나, 해당 화면에서 트래킹이 안 탈 수 있음.",
    "recipe_dedup_found": "클라이언트 dedup 경로 미발화. 서버 server_parse_dedup은 정상 유입 중.",
    "recipe_saved_from_feed": "코드에 함수만 있고 호출처 없음(dead event).",
    "user_unfollowed": "언팔로우가 거의 없거나 트래킹 미도달. user_followed도 저조.",
}


def event_label(name: str) -> str:
    ko = EVENT_KO.get(name, "")
    return f"{name}<br/><font size='7' color='#64748b'>{ko}</font>" if ko else name


def make_styles() -> dict[str, ParagraphStyle]:
    return {
        "title": ParagraphStyle(
            "title",
            fontName=FONT_B,
            fontSize=16,
            leading=22,
            alignment=TA_CENTER,
            spaceAfter=8,
        ),
        "h1": ParagraphStyle(
            "h1",
            fontName=FONT_B,
            fontSize=12,
            leading=16,
            spaceBefore=10,
            spaceAfter=6,
            textColor=colors.HexColor("#0f172a"),
        ),
        "h2": ParagraphStyle(
            "h2",
            fontName=FONT_B,
            fontSize=10,
            leading=14,
            spaceBefore=8,
            spaceAfter=4,
            textColor=colors.HexColor("#1e293b"),
        ),
        "body": ParagraphStyle(
            "body",
            fontName=FONT,
            fontSize=9,
            leading=13,
            spaceAfter=4,
            alignment=TA_LEFT,
        ),
        "small": ParagraphStyle(
            "small",
            fontName=FONT,
            fontSize=8,
            leading=11,
            textColor=colors.HexColor("#475569"),
            spaceAfter=3,
        ),
        "cell": ParagraphStyle(
            "cell",
            fontName=FONT,
            fontSize=7.5,
            leading=10,
        ),
        "cell_b": ParagraphStyle(
            "cell_b",
            fontName=FONT_B,
            fontSize=7.5,
            leading=10,
            textColor=colors.white,
        ),
    }


def table_style_header() -> TableStyle:
    return TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f2937")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, -1), FONT),
            ("FONTSIZE", (0, 0), (-1, -1), 8),
            ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#cbd5e1")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 3),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            (
                "ROWBACKGROUNDS",
                (0, 1),
                (-1, -1),
                [colors.white, colors.HexColor("#f8fafc")],
            ),
        ]
    )


def build_pdf(report: dict[str, Any], path: Path) -> None:
    styles = make_styles()
    doc = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        leftMargin=14 * mm,
        rightMargin=14 * mm,
        topMargin=12 * mm,
        bottomMargin=12 * mm,
        title="요리GO Mixpanel 애널리틱스 헬스 리포트",
    )
    story: list[Any] = []
    s = report["summary"]
    w = report["window"]

    story.append(Paragraph("요리GO Mixpanel 애널리틱스 헬스 리포트", styles["title"]))
    story.append(
        Paragraph(
            f"생성일: {report['generated_at']} &nbsp;|&nbsp; "
            f"분석 기간: {w['from_90d']} ~ {w['to']} (90일) / 최근 30일: {w['from_30d']}~",
            styles["body"],
        )
    )
    story.append(
        Paragraph(
            "데이터 출처: Mixpanel Query API (backend/.env API Secret). "
            "이 Cursor 세션에는 Mixpanel MCP가 연결되어 있지 않아 API로 동일 프로젝트를 조회했습니다. "
            "Firebase Analytics 실데이터는 포함되지 않습니다.",
            styles["small"],
        )
    )

    # 1. 요약
    story.append(Paragraph("1. 한눈에 보는 요약", styles["h1"]))
    story.append(
        Paragraph(
            "코드에 정의된 이벤트와 Mixpanel에 실제로 쌓인 이벤트를 대조한 결과입니다. "
            "‘정상’은 Mixpanel 카탈로그에 있고 최근 30일 발생 횟수가 5회 이상인 경우입니다.",
            styles["body"],
        )
    )
    summary_rows = [
        [
            Paragraph("항목", styles["cell_b"]),
            Paragraph("값", styles["cell_b"]),
            Paragraph("설명", styles["cell_b"]),
        ],
        [
            Paragraph("Mixpanel 라이브 이벤트 수", styles["cell"]),
            Paragraph(str(s["live_event_names"]), styles["cell"]),
            Paragraph("프로젝트에 등록·수집된 이벤트 이름 개수", styles["cell"]),
        ],
        [
            Paragraph("코드에 정의된 이벤트 수", styles["cell"]),
            Paragraph(str(s["code_events"]), styles["cell"]),
            Paragraph("앱/서버 AnalyticsService·MixpanelService 기준", styles["cell"]),
        ],
        [
            Paragraph("코드∩라이브 일치", styles["cell"]),
            Paragraph(str(s["in_code_and_live"]), styles["cell"]),
            Paragraph("양쪽 모두에 존재하는 이벤트", styles["cell"]),
        ],
        [
            Paragraph("코드에만 있음 (라이브 없음)", styles["cell"]),
            Paragraph(str(s["in_code_not_live"]), styles["cell"]),
            Paragraph("심어뒀지만 Mixpanel에 안 보이거나 한 번도 안 들어온 이벤트", styles["cell"]),
        ],
        [
            Paragraph("라이브에만 있음 (코드 없음)", styles["cell"]),
            Paragraph(str(s["in_live_not_code"]), styles["cell"]),
            Paragraph("구버전·삭제된 계측이거나 문서화 누락 후보", styles["cell"]),
        ],
        [
            Paragraph("90일 볼륨 0 (코드 이벤트)", styles["cell"]),
            Paragraph(str(s["zero_volume_90d_code_events"]), styles["cell"]),
            Paragraph("최근 90일 동안 발생 횟수 0", styles["cell"]),
        ],
        [
            Paragraph("30일 저조 (&lt;5회)", styles["cell"]),
            Paragraph(str(s["low_volume_30d_code_events"]), styles["cell"]),
            Paragraph("아예 없진 않지만 매우 드문 이벤트", styles["cell"]),
        ],
    ]
    t = Table(summary_rows, colWidths=[48 * mm, 18 * mm, 104 * mm])
    t.setStyle(table_style_header())
    story.append(t)

    # 종합 평가
    healthy = warn = bad = 0
    for wf in report["workflows"].values():
        for item in wf["events"]:
            st = item["status"]
            if st == "healthy":
                healthy += 1
            elif st == "low_volume_30d":
                warn += 1
            else:
                bad += 1
    story.append(Paragraph("종합 평가", styles["h2"]))
    story.append(
        Paragraph(
            f"워크플로우 추적 이벤트 기준: "
            f"<font color='#166534'><b>정상 {healthy}개</b></font>, "
            f"<font color='#a16207'><b>최근 저조 {warn}개</b></font>, "
            f"<font color='#b91c1c'><b>문제(미등록/무실적) {bad}개</b></font>.",
            styles["body"],
        )
    )
    story.append(
        Paragraph(
            "전체적으로 핵심 퍼널(앱 오픈·파싱·화면·북마크·장바구니 체크)은 Mixpanel에 잘 쌓이고 있습니다. "
            "다만 요리 완료·클라이언트 dedup·피드 저장·언팔로우 등 일부 이벤트는 사실상 관리되지 않는 상태입니다. "
            "또한 파싱 요청 수가 완료 수보다 훨씬 커서(재시도/중복 카운트) 해석 시 주의가 필요합니다.",
            styles["body"],
        )
    )

    # 2. 갭
    story.append(Paragraph("2. 코드 vs Mixpanel 갭 (조치 필요)", styles["h1"]))
    story.append(
        Paragraph(
            "아래 이벤트는 코드에는 있으나 Mixpanel 카탈로그/90일 실적이 없습니다. "
            "계측 누락, 호출 경로 미도달, 또는 의도적 dead code일 수 있습니다.",
            styles["body"],
        )
    )
    gap_rows = [
        [
            Paragraph("이벤트", styles["cell_b"]),
            Paragraph("설명 / 추정 원인", styles["cell_b"]),
        ]
    ]
    for e in report["in_code_not_live"]:
        gap_rows.append(
            [
                Paragraph(event_label(e), styles["cell"]),
                Paragraph(GAP_EXPLAIN.get(e, "원인 미상 — 호출 경로 점검 필요"), styles["cell"]),
            ]
        )
    gt = Table(gap_rows, colWidths=[55 * mm, 115 * mm])
    gt.setStyle(table_style_header())
    story.append(gt)

    story.append(Paragraph("최근 30일 발생이 매우 적은 이벤트", styles["h2"]))
    for e in report["low_30"]:
        c30 = report["totals_30"].get(e, 0)
        story.append(
            Paragraph(
                f"• <b>{e}</b> ({EVENT_KO.get(e, '')}) — 30일 {c30}회. "
                "기능 자체가 드물거나 CTA 트래킹이 거의 안 탈 수 있음.",
                styles["small"],
            )
        )

    orphan_text = (
        "없음 (정리 상태 양호)"
        if not report["in_live_not_code"]
        else ", ".join(report["in_live_not_code"])
    )
    story.append(
        Paragraph(
            f"라이브에만 있고 현재 코드 인벤토리에 없는 이벤트: {orphan_text}",
            styles["body"],
        )
    )

    # 3. 워크플로우
    story.append(PageBreak())
    story.append(Paragraph("3. 워크플로우별 상세", styles["h1"]))
    story.append(
        Paragraph(
            "상태 기준 — 정상: 카탈로그 존재 + 30일 ≥5회 / 최근 저조: 30일 1~4회 / "
            "90일 무실적·MP 미등록: 점검 대상.",
            styles["small"],
        )
    )

    for wf_name, wf in report["workflows"].items():
        block: list[Any] = [Paragraph(wf_name, styles["h2"])]
        rows = [
            [
                Paragraph("이벤트", styles["cell_b"]),
                Paragraph("90일", styles["cell_b"]),
                Paragraph("30일", styles["cell_b"]),
                Paragraph("상태", styles["cell_b"]),
            ]
        ]
        for item in wf["events"]:
            st = item["status"]
            sc = STATUS_COLOR.get(st, "#111")
            rows.append(
                [
                    Paragraph(event_label(item["name"]), styles["cell"]),
                    Paragraph(f"{item['count_90d']:,}", styles["cell"]),
                    Paragraph(f"{item['count_30d']:,}", styles["cell"]),
                    Paragraph(
                        f"<font color='{sc}'><b>{STATUS_KO.get(st, st)}</b></font>",
                        styles["cell"],
                    ),
                ]
            )
        wt = Table(rows, colWidths=[85 * mm, 25 * mm, 25 * mm, 35 * mm])
        wt.setStyle(table_style_header())
        block.append(wt)
        block.append(Spacer(1, 4))
        story.append(KeepTogether(block))

    # 4. Top
    story.append(PageBreak())
    story.append(Paragraph("4. Mixpanel 상위 이벤트 (90일 합계)", styles["h1"]))
    story.append(
        Paragraph(
            "발생량이 많은 이벤트일수록 대시보드·리텐션 분석의 핵심 지표로 쓰기 좋습니다. "
            "‘코드’ 열은 현재 코드베이스 인벤토리 포함 여부입니다.",
            styles["body"],
        )
    )
    import sys

    sys.path.insert(0, str(ROOT))
    from generate_mixpanel_health_pdf import CODE_ALL

    code_set = set(CODE_ALL)

    top_rows = [
        [
            Paragraph("#", styles["cell_b"]),
            Paragraph("이벤트", styles["cell_b"]),
            Paragraph("90일 합계", styles["cell_b"]),
            Paragraph("코드", styles["cell_b"]),
        ]
    ]
    for idx, (name, cnt) in enumerate(report["top_live_90d"], start=1):
        top_rows.append(
            [
                Paragraph(str(idx), styles["cell"]),
                Paragraph(event_label(name), styles["cell"]),
                Paragraph(f"{cnt:,}", styles["cell"]),
                Paragraph("예" if name in code_set else "아니오", styles["cell"]),
            ]
        )
    top_t = Table(top_rows, colWidths=[12 * mm, 100 * mm, 30 * mm, 28 * mm])
    top_t.setStyle(table_style_header())
    story.append(top_t)

    # 5. 인사이트
    story.append(Paragraph("5. 해석 포인트 (운영 관점)", styles["h1"]))
    insights = [
        (
            "파싱 퍼널",
            "parsing_request_started가 recipe_parsing_completed보다 훨씬 많습니다. "
            "재시도·중복 요청이 합산됐을 가능성이 있어, 성공률은 서버 이벤트"
            "(server_parse_completed / failed / dedup)와 함께 보는 것이 안전합니다.",
        ),
        (
            "요리 퍼널",
            "cooking_started는 들어오지만 cooking_completed는 0입니다. "
            "냉장고 완료 UX 또는 트래킹 호출 위치를 점검할 가치가 큽니다.",
        ),
        (
            "구매 퍼널",
            "ingredient_purchase_checked·affiliate_link_clicked는 활발한데 "
            "purchase_button_clicked는 거의 없습니다. CTA 이벤트 정의/발화 시점과 "
            "실제 구매 완료(cart_purchase_completed) 매핑을 재확인하세요.",
        ),
        (
            "중복 처리",
            "클라이언트 recipe_dedup_found는 0인 반면 서버 server_parse_dedup은 활발합니다. "
            "중복 절감 KPI는 서버 이벤트 기준으로 잡는 편이 맞습니다.",
        ),
        (
            "정리 상태",
            "라이브 orphan(코드에 없는) 이벤트가 0개라, 과거에 쌓인 유령 이벤트는 "
            "비교적 잘 정리된 편입니다. dead event(recipe_saved_from_feed)는 제거하거나 연결하세요.",
        ),
    ]
    for title, text in insights:
        story.append(Paragraph(f"• <b>{title}</b> — {text}", styles["body"]))

    story.append(Spacer(1, 8))
    story.append(
        Paragraph(
            "참고: 클라이언트 대부분 이벤트는 Firebase Analytics와 Mixpanel에 이중 전송됩니다. "
            "서버 파싱·일일 스냅샷·yorigo_active_user는 Mixpanel(및 일부 Firestore) 전용입니다.",
            styles["small"],
        )
    )

    doc.build(story)


def main() -> None:
    report = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    build_pdf(report, PDF_OUT)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"PDF: {PDF_OUT}")
    print(f"Downloads: {DOWNLOADS}")


if __name__ == "__main__":
    main()
