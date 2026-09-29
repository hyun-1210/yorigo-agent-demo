"""요리GO 푸드 버티컬 데이터 플랫폼 — 추적 데이터 · 기능 · 기술 구현 PDF 보고서."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    KeepTogether,
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parent
PDF_OUT = ROOT / "yorigo_data_platform_report_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "yorigo_data_platform_report_ko.pdf"

FONT = "Malgun"
FONT_B = "MalgunBold"
pdfmetrics.registerFont(TTFont(FONT, r"C:\Windows\Fonts\malgun.ttf"))
pdfmetrics.registerFont(TTFont(FONT_B, r"C:\Windows\Fonts\malgunbd.ttf"))

NAVY = colors.HexColor("#0f172a")
SLATE = colors.HexColor("#334155")
MUTED = colors.HexColor("#64748b")
LINE = colors.HexColor("#cbd5e1")
ROW_ALT = colors.HexColor("#f8fafc")
HEADER_BG = colors.HexColor("#1e293b")
ACCENT = colors.HexColor("#0f766e")
BOX_BG = colors.HexColor("#f0fdfa")
WARN_BG = colors.HexColor("#fff7ed")


def make_styles() -> dict[str, ParagraphStyle]:
    return {
        "cover_title": ParagraphStyle(
            "cover_title",
            fontName=FONT_B,
            fontSize=18,
            leading=26,
            alignment=TA_CENTER,
            textColor=NAVY,
            spaceAfter=6,
        ),
        "cover_sub": ParagraphStyle(
            "cover_sub",
            fontName=FONT,
            fontSize=10,
            leading=15,
            alignment=TA_CENTER,
            textColor=SLATE,
            spaceAfter=4,
        ),
        "meta": ParagraphStyle(
            "meta",
            fontName=FONT,
            fontSize=8,
            leading=11,
            alignment=TA_CENTER,
            textColor=MUTED,
            spaceAfter=10,
        ),
        "h1": ParagraphStyle(
            "h1",
            fontName=FONT_B,
            fontSize=13,
            leading=18,
            spaceBefore=4,
            spaceAfter=8,
            textColor=NAVY,
        ),
        "h2": ParagraphStyle(
            "h2",
            fontName=FONT_B,
            fontSize=10.5,
            leading=15,
            spaceBefore=10,
            spaceAfter=5,
            textColor=colors.HexColor("#134e4a"),
        ),
        "h3": ParagraphStyle(
            "h3",
            fontName=FONT_B,
            fontSize=9.5,
            leading=13,
            spaceBefore=7,
            spaceAfter=3,
            textColor=SLATE,
        ),
        "body": ParagraphStyle(
            "body",
            fontName=FONT,
            fontSize=9,
            leading=13.5,
            spaceAfter=5,
            alignment=TA_JUSTIFY,
            textColor=NAVY,
        ),
        "bullet": ParagraphStyle(
            "bullet",
            fontName=FONT,
            fontSize=8.5,
            leading=12.5,
            leftIndent=2,
            textColor=NAVY,
        ),
        "callout": ParagraphStyle(
            "callout",
            fontName=FONT,
            fontSize=8.5,
            leading=12.5,
            textColor=colors.HexColor("#115e59"),
            alignment=TA_LEFT,
        ),
        "callout_b": ParagraphStyle(
            "callout_b",
            fontName=FONT_B,
            fontSize=8.5,
            leading=12.5,
            textColor=colors.HexColor("#115e59"),
        ),
        "small": ParagraphStyle(
            "small",
            fontName=FONT,
            fontSize=8,
            leading=11,
            textColor=MUTED,
            spaceAfter=3,
        ),
        "cell": ParagraphStyle(
            "cell",
            fontName=FONT,
            fontSize=7.5,
            leading=10.5,
            textColor=NAVY,
        ),
        "cell_b": ParagraphStyle(
            "cell_b",
            fontName=FONT_B,
            fontSize=7.5,
            leading=10.5,
            textColor=colors.white,
        ),
        "footer": ParagraphStyle(
            "footer",
            fontName=FONT,
            fontSize=7.5,
            leading=9,
            textColor=MUTED,
            alignment=TA_CENTER,
        ),
        "toc": ParagraphStyle(
            "toc",
            fontName=FONT,
            fontSize=9.5,
            leading=16,
            textColor=NAVY,
            leftIndent=4,
        ),
    }


def header_style() -> TableStyle:
    return TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, 0), HEADER_BG),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, -1), FONT),
            ("FONTSIZE", (0, 0), (-1, -1), 7.5),
            ("GRID", (0, 0), (-1, -1), 0.35, LINE),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 3.5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3.5),
            ("TOPPADDING", (0, 0), (-1, -1), 3.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, ROW_ALT]),
        ]
    )


def accent_box(title: str, body: str, styles: dict[str, ParagraphStyle]) -> Table:
    inner = [
        [Paragraph(title, styles["callout_b"])],
        [Paragraph(body, styles["callout"])],
    ]
    t = Table(inner, colWidths=[182 * mm])
    t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), BOX_BG),
                ("BOX", (0, 0), (-1, -1), 0.8, ACCENT),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ]
        )
    )
    return t


def warn_box(title: str, body: str, styles: dict[str, ParagraphStyle]) -> Table:
    inner = [
        [Paragraph(title, styles["callout_b"])],
        [Paragraph(body, styles["callout"])],
    ]
    t = Table(inner, colWidths=[182 * mm])
    t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), WARN_BG),
                ("BOX", (0, 0), (-1, -1), 0.8, colors.HexColor("#c2410c")),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    return t


def p_cells(rows: list[list[str]], styles: dict[str, ParagraphStyle]) -> list[list[Any]]:
    out: list[list[Any]] = []
    for i, row in enumerate(rows):
        cells: list[Any] = []
        for j, text in enumerate(row):
            style = styles["cell_b"] if i == 0 else styles["cell"]
            cells.append(Paragraph(text.replace("\n", "<br/>"), style))
        out.append(cells)
    return out


def make_table(
    rows: list[list[str]],
    col_widths: list[float],
    styles: dict[str, ParagraphStyle],
) -> Table:
    t = Table(p_cells(rows, styles), colWidths=col_widths, repeatRows=1)
    t.setStyle(header_style())
    return t


def bullets(items: list[str], styles: dict[str, ParagraphStyle]) -> ListFlowable:
    return ListFlowable(
        [ListItem(Paragraph(x, styles["bullet"]), leftIndent=8, value="•") for x in items],
        bulletType="bullet",
        start="•",
        leftIndent=10,
        bulletFontName=FONT,
        bulletFontSize=8,
        spaceBefore=1,
        spaceAfter=4,
    )


def add_footer(canvas: Any, doc: Any) -> None:
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.4)
    y = 10 * mm
    canvas.line(14 * mm, y + 5, A4[0] - 14 * mm, y + 5)
    canvas.setFont(FONT, 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(14 * mm, y, "요리GO · 푸드 버티컬 데이터 플랫폼 기술 보고서")
    canvas.drawRightString(A4[0] - 14 * mm, y, f"{doc.page}")
    canvas.restoreState()


def build_story(styles: dict[str, ParagraphStyle]) -> list[Any]:
    story: list[Any] = []
    today = date.today().isoformat()

    # ── Cover ──
    story.append(Spacer(1, 18 * mm))
    story.append(Paragraph("요리GO", styles["cover_title"]))
    story.append(
        Paragraph(
            "푸드 버티컬 데이터 플랫폼<br/>추적 데이터 · 제공 기능 · 기술 구현 계획",
            styles["cover_title"],
        )
    )
    story.append(Spacer(1, 6 * mm))
    story.append(
        Paragraph(
            "레시피 콘텐츠에서 시작된 요리 의도가<br/>"
            "실제 행동·구매로 이어지는 전 과정을 연결하고<br/>"
            "그 과정에서 발생하는 데이터를 자사 자산으로 축적한다.",
            styles["cover_sub"],
        )
    )
    story.append(Spacer(1, 8 * mm))
    story.append(
        Paragraph(
            f"문서 유형: 내부 기술·전략 보고서 &nbsp;|&nbsp; 작성일: {today}<br/>"
            "범위: 데이터 수집 설계 · 추천/자산화 아키텍처 · 단계별 구현 로드맵",
            styles["meta"],
        )
    )
    story.append(
        accent_box(
            "한 문장 정의",
            "요리GO는 레시피 콘텐츠에서 시작된 사용자의 요리 의도가 실제 행동과 구매로 "
            "이어지는 전 과정을 연결하고, 그 과정에서 발생하는 데이터를 축적하는 "
            "푸드 버티컬 데이터 플랫폼입니다.",
            styles,
        )
    )
    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph("목차", styles["h1"]))
    toc = [
        "1. 왜 이 데이터가 해자인가",
        "2. 추적하는 데이터 전체 지도 (4대 축)",
        "3. 이 데이터로 제공하는 기능과 가치",
        "4. 기술 아키텍처 (2계층 파이프라인)",
        "5. 시그널 계약 · 보상 · 프로필 스키마",
        "6. 수집·적재·서빙 구현 방식",
        "7. 추천·학습 파이프라인",
        "8. 비용 · 거버넌스 · 단계별 로드맵",
        "9. 현재 상태와 다음에 할 일",
    ]
    for line in toc:
        story.append(Paragraph(line, styles["toc"]))
    story.append(PageBreak())

    # ── 1 ──
    story.append(Paragraph("1. 왜 이 데이터가 해자인가", styles["h1"]))
    story.append(
        Paragraph(
            "B2C가 장기적으로 살아남고 투자 가치를 인정받으려면, 사용자 수만이 아니라 "
            "기존에 파악하기 어려웠던 사용자의 의도를 발견하고 데이터로 축적해야 합니다. "
            "요리GO의 경쟁력은 레시피 정리나 장보기 기능 자체가 아닙니다. "
            "사용자가 요리를 <b>발견 → 선택 → 실행 → 구매</b>하는 전 과정을 "
            "한 플랫폼 안에서 연결할 때 생기는 <b>버티컬하고 유기적인 데이터</b>에 있습니다.",
            styles["body"],
        )
    )
    story.append(Paragraph("데이터 플라이휠", styles["h2"]))
    story.append(
        Paragraph(
            "요리 의도 파악 → 선호 콘텐츠·취향 분석 → 필요 상품·구매 시점 예측 → "
            "맞춤 상품·광고 제안 → 실제 반응·구매 수집 → 추천 정확도 향상 → "
            "(사용 증가로 다시 데이터 축적)",
            styles["body"],
        )
    )
    story.append(
        Paragraph(
            "이 구조는 ‘사용자가 많아서’가 아니라, <b>요리라는 특정 행동</b>을 중심으로 "
            "사용자·콘텐츠·커머스·광고 반응이 동시에 연결되기 때문에 만들어지는 해자입니다.",
            styles["body"],
        )
    )
    story.append(
        warn_box(
            "Mixpanel과의 역할 구분",
            "현재 Mixpanel은 제품 분석(DAU·퍼널·리텐션)용 ‘거울’입니다. "
            "추천 서빙·모델 학습·장기 자산화의 ‘금고+공장’은 자사 시그널 파이프라인"
            "(Firestore 핫 계층 + GCS/BigQuery 콜드 계층)으로 별도 구축합니다.",
            styles,
        )
    )
    story.append(PageBreak())

    # ── 2 ──
    story.append(Paragraph("2. 추적하는 데이터 전체 지도", styles["h1"]))
    story.append(
        Paragraph(
            "네 가지 축이 하나의 흐름(user–recipe–product) 위에서 동시에 쌓입니다. "
            "아래는 ‘무엇을 왜 추적하는가’와 ‘기술적으로 어떤 신호로 남기는가’를 함께 정리한 것입니다.",
            styles["body"],
        )
    )

    story.append(Paragraph("2.1 사용자 데이터 — 생활 맥락과 요리 의도", styles["h2"]))
    story.append(
        make_table(
            [
                ["추적 항목", "파악하려는 의도", "기술 시그널 / 저장"],
                [
                    "시점·주기",
                    "언제 요리하는가",
                    "식단 캘린더, cookingDays, 이벤트 타임스탬프·요일·시간대",
                ],
                [
                    "대상·규모",
                    "누구를 위해, 몇 인분",
                    "servings, mealPlans 슬롯, (명시) 요리 대상 필드",
                ],
                [
                    "요리 방식",
                    "빠르기/정성, 냉장고 활용",
                    "cook_time 카테고리, fridgeData, cook_start→cook_done",
                ],
                [
                    "취향",
                    "재료·조리법·메뉴 선호",
                    "취향 프로필 cuisine/menu/ing/chef 가중치",
                ],
                [
                    "가치관",
                    "건강·가격·편의 중 우선순위",
                    "온보딩 명시 + 행동 추론(영양·단가·소요시간)",
                ],
                [
                    "의도 강도",
                    "저장만 vs 실제 실행",
                    "save vs cook_done / purchase 보상 차이",
                ],
            ],
            [32 * mm, 48 * mm, 102 * mm],
            styles,
        )
    )

    story.append(Paragraph("2.2 콘텐츠 데이터 — 취향과 전환 품질", styles["h2"]))
    story.append(
        make_table(
            [
                ["추적 항목", "파악하려는 것", "기술 시그널 / 저장"],
                [
                    "선호 메뉴",
                    "자주 고르는 음식·메뉴군",
                    "canonicalDish, groupKey, categories",
                ],
                [
                    "재료·방식",
                    "자주 쓰는 재료·조리법",
                    "ingredients[], tags, chefTag, platform",
                ],
                [
                    "생산자",
                    "선호 채널·셰프",
                    "source.uploader / chef_affinity",
                ],
                [
                    "저장 vs 실행",
                    "저장만 되는 콘텐츠 vs 행동 전환",
                    "save_rate vs cook_rate / purchase_rate",
                ],
                [
                    "성과",
                    "실제 행동을 만드는 콘텐츠",
                    "recipe_stats (CTR, 저장·완주·구매율)",
                ],
            ],
            [32 * mm, 48 * mm, 102 * mm],
            styles,
        )
    )

    story.append(Paragraph("2.3 커머스 데이터 — 왜 그 상품이 필요해졌는가", styles["h2"]))
    story.append(
        make_table(
            [
                ["추적 항목", "파악하려는 것", "기술 시그널 / 저장"],
                [
                    "상황·경로",
                    "어떤 레시피 뒤 장바구니/구매가 열렸는지",
                    "cart_add, recipe_id 컨텍스트, source_screen",
                ],
                [
                    "상품 선택",
                    "어떤 상품·마켓·가격대",
                    "affiliate_*, product_check_events, marketplace",
                ],
                [
                    "구매 시점",
                    "언제 구매를 결정하는지",
                    "cart_purchase_completed, 세션·시간대",
                ],
                [
                    "원인 연결",
                    "어떤 요리를 위해 필요했는지",
                    "recipe_id ↔ ingredient ↔ product_id 조인",
                ],
            ],
            [32 * mm, 48 * mm, 102 * mm],
            styles,
        )
    )
    story.append(
        Paragraph(
            "일반 커머스가 ‘무엇을 샀는가’ 중심이라면, 요리GO는 그보다 앞선 "
            "‘왜 그 상품이 필요해졌는가’까지 같은 키로 연결합니다.",
            styles["small"],
        )
    )

    story.append(Paragraph("2.4 광고·상품 반응 데이터", styles["h2"]))
    story.append(
        make_table(
            [
                ["추적 항목", "파악하려는 것", "기술 시그널 / 저장"],
                [
                    "타깃·맥락",
                    "누구에게, 어떤 메뉴·상황에서",
                    "취향 프로필 + recipe 컨텍스트 + 제안 이벤트",
                ],
                [
                    "제안 방식",
                    "어떤 상품·메시지·포맷",
                    "ad_imp / ad_click / offer_type (광고 기능 시점)",
                ],
                [
                    "반응",
                    "관심·담기·구매",
                    "click → cart_add → purchase 동일 보상 체계",
                ],
                [
                    "재학습",
                    "반응이 추천·광고에 반영",
                    "training_ranker + bandit 피드백 루프",
                ],
            ],
            [32 * mm, 48 * mm, 102 * mm],
            styles,
        )
    )
    story.append(
        Paragraph(
            "광고 UI가 없어도 1~3축이 쌓이면 타깃·메시지용 집계 자산의 기반이 됩니다. "
            "집행 단계에서는 노출·클릭·전환 시그널을 같은 스키마에 얹습니다.",
            styles["small"],
        )
    )

    story.append(Paragraph("2.5 핵심 행동 시그널 사전 (추천·학습 공통)", styles["h2"]))
    story.append(
        make_table(
            [
                ["시그널", "의미", "보상", "역할"],
                ["imp", "카드 노출", "0.0", "CTR·학습 분모 (필수)"],
                ["click", "카드 클릭", "0.10", "관심"],
                ["dwell", "상세 체류(≥20s)", "0.20", "강한 관심"],
                ["step_scroll", "조리 단계 스크롤", "0.25", "요리 의도"],
                ["save / unsave", "북마크 / 해제", "+0.60 / −0.5", "선호·부정"],
                ["cart_add", "장바구니 담기", "0.70", "구매·조리 의도"],
                ["cook_start", "요리 시작", "0.80", "실행 시작"],
                ["cook_done", "요리 완료", "1.00", "성공 정의"],
                ["review", "후기 작성", "1.00", "만족"],
                ["purchase", "재료 구매", "1.00", "성공 정의"],
                ["skip / hide / report", "무시·숨김·신고", "−0.05~−1.0", "부정 신호"],
            ],
            [36 * mm, 42 * mm, 28 * mm, 76 * mm],
            styles,
        )
    )
    story.append(
        accent_box(
            "성공 정의 (고정)",
            "모델과 제품 KPI의 정답은 cook_done + purchase 입니다. "
            "클릭만 최적화하면 자산 가치가 떨어집니다.",
            styles,
        )
    )
    story.append(PageBreak())

    # ── 3 ──
    story.append(Paragraph("3. 이 데이터로 제공하는 기능과 가치", styles["h1"]))
    story.append(Paragraph("3.1 제품 기능 (B2C)", styles["h2"]))
    story.append(
        make_table(
            [
                ["기능", "설명", "의존 데이터"],
                [
                    "개인화 홈 섹션",
                    "취향·상황에 맞는 ‘당신 추천’ 섹션 (기존 제철/셰프와 A/B)",
                    "취향 프로필 + user_recs",
                ],
                [
                    "피드/추천 품질",
                    "저장·요리·구매까지 반영한 순위",
                    "시그널 + recipe_stats + 랭커",
                ],
                [
                    "의미 검색 (후반)",
                    "키워드가 아닌 비슷한 요리·재료 검색",
                    "레시피 임베딩",
                ],
                [
                    "장바구니·냉장고 추천",
                    "기존 밴딧 추천을 취향 프로필과 통합",
                    "cart/fridge + 프로필",
                ],
            ],
            [40 * mm, 78 * mm, 64 * mm],
            styles,
        )
    )

    story.append(Paragraph("3.2 이해관계자별 가치 (B2B·파트너)", styles["h2"]))
    story.append(
        make_table(
            [
                ["대상", "제공 가치"],
                [
                    "콘텐츠 생산자",
                    "조회·저장이 아닌 요리·구매 전환으로 본 콘텐츠 영향력·전환 가치",
                ],
                [
                    "식품·커머스",
                    "이미 요리 의도가 생긴 순간의 수요·상품 적합도 (높은 전환 가능성)",
                ],
                [
                    "광고주·브랜드",
                    "누구에게 / 어떤 메뉴·상황에서 / 어떤 제안이 효과적인지",
                ],
                [
                    "데이터 산업 (장기)",
                    "익명·집계 인사이트, 시장 리포트, 브랜드 대시보드, 타깃 분석",
                ],
            ],
            [40 * mm, 142 * mm],
            styles,
        )
    )
    story.append(
        Paragraph(
            "외부 판매 대상은 유저 프로필이 아니라 <b>동의·익명·집계된 시장 시그널</b>입니다.",
            styles["body"],
        )
    )
    story.append(PageBreak())

    # ── 4 ──
    story.append(Paragraph("4. 기술 아키텍처 (2계층 파이프라인)", styles["h1"]))
    story.append(
        Paragraph(
            "Firestore는 실시간 서빙용 <b>핫 계층</b>, GCS+BigQuery는 장기 소유·재가공용 "
            "<b>콜드 자산 계층</b>입니다. Mixpanel은 제품 분석 전용으로 유지합니다.",
            styles["body"],
        )
    )
    story.append(
        Paragraph(
            "Flutter SignalCollector → Firestore signal_batches (세션 배치 쓰기)<br/>"
            "→ 일일 Export → GCS JSONL.gz → BigQuery events / agg_* / training_*<br/>"
            "→ Nightly Profile Builder → user_taste_profiles · recipe_stats · user_recs<br/>"
            "→ 앱은 user_recs 1문서 조회로 개인화 피드 수신",
            styles["body"],
        )
    )

    story.append(Paragraph("계층별 역할", styles["h2"]))
    story.append(
        make_table(
            [
                ["계층", "저장소", "보관", "역할"],
                [
                    "핫",
                    "Firestore\nsignal_batches / user_taste_profiles\nuser_recs / recipe_stats",
                    "배치 35일 TTL\n프로필·추천 상시",
                    "수집 버퍼·실시간 서빙",
                ],
                [
                    "콜드",
                    "GCS signals/dt=…/*.jsonl.gz\nBigQuery yorigo_signals.*",
                    "영구(append-only)",
                    "원천 자산·집계·학습셋",
                ],
                [
                    "분석",
                    "Mixpanel (기존)",
                    "제품 정책에 따름",
                    "DAU·퍼널·리텐션 관찰",
                ],
            ],
            [22 * mm, 70 * mm, 40 * mm, 50 * mm],
            styles,
        )
    )

    story.append(Paragraph("설계 원칙 4가지", styles["h2"]))
    story.append(
        bullets(
            [
                "<b>쓰기는 배치로</b>: 이벤트 1건=1 write가 아니라 세션 플러시당 1문서 → 쓰기 비용 비선형화",
                "<b>읽기는 사전계산으로</b>: 홈이 recipes를 스캔하지 않고 user_recs/{uid} 1~2건 읽기",
                "<b>Firestore는 핫만, 원천은 GCS/BQ</b>: 영구 자산은 웨어하우스에만",
                "<b>벡터 DB 비도입(초기)</b>: 레시피 규모에서 numpy 전수 유사도로 충분 (월 고정비 $0)",
            ],
            styles,
        )
    )

    story.append(Paragraph("기존 인프라와의 관계", styles["h2"]))
    story.append(
        bullets(
            [
                "운영 DB: Firebase Firestore (유저·레시피·장바구니·식단 등 현행 유지)",
                "백엔드: FastAPI on Railway — 배치 스케줄러·추천 API 추가",
                "홈 규칙 섹션: Cloud Functions 역색인(home_section / seasonal / chef) 유지 → 개인화 섹션과 병행",
                "기존 장바구니 RecommendationService(RerankBandit)는 홈 피드·취향 프로필과 단계적으로 통합",
            ],
            styles,
        )
    )
    story.append(PageBreak())

    # ── 5 ──
    story.append(Paragraph("5. 시그널 계약 · 프로필 스키마", styles["h1"]))
    story.append(Paragraph("5.1 signal_batches (세션 조각 1문서)", styles["h2"]))
    story.append(
        Paragraph(
            "클라이언트 버퍼가 50건 또는 30초 또는 앱 백그라운드/탭 이탈 시 플러시합니다. "
            "필드 예: v, uid, aid(익명기기), sid(세션), dt, st(서버시각), app, "
            "ev[{t, e, ik, it, ctx, val}]. create-only 규칙으로 위변조를 막습니다.",
            styles["body"],
        )
    )
    story.append(
        Paragraph(
            '예: {"e":"imp","ik":"recipe","it":"&lt;recipeId&gt;",'
            '"ctx":{"sc":"home","sec":"trending_now","pos":3}}',
            styles["small"],
        )
    )

    story.append(Paragraph("5.2 user_taste_profiles/{uid}", styles["h2"]))
    story.append(
        bullets(
            [
                "cuisine_w / menu_w / main_ing_w / time_w — 해석 가능한 카테고리 가중치",
                "ing_affinity / chef_affinity / platform_pref",
                "recent_items / negatives — 단기 맥락·부정 목록",
                "emb (P3 이후) — 256차원 취향 벡터",
                "지수 감쇠: 단기 half-life 21일 / 장기 180일 분리",
            ],
            styles,
        )
    )

    story.append(Paragraph("5.3 recipe_stats/{recipeId}", styles["h2"]))
    story.append(
        Paragraph(
            "impressions, clicks, ctr, save_rate, cook_rate, wilson_lower_bound, "
            "trending_score(시간감쇠). 레시피 본문 문서에 카운터를 계속 붙이지 않고 "
            "통계 컬렉션을 분리해 경합·인덱스 비용을 줄입니다.",
            styles["body"],
        )
    )

    story.append(Paragraph("5.4 콜드 자산 · 의사식별", styles["h2"]))
    story.append(
        bullets(
            [
                "GCS: gs://&lt;bucket&gt;/signals/dt=YYYY-MM-DD/part-*.jsonl.gz (append-only)",
                "BigQuery: events (dt 파티션) + agg_dish_demand / agg_ingredient_demand / "
                "agg_search_gap / training_ranker_v1",
                "웨어하우스 subject_id = HMAC_SHA256(uid, ASSET_SALT) — PII는 Firestore에만",
                "users.dataConsent: analytics / personalization / aggregate_insights",
            ],
            styles,
        )
    )
    story.append(PageBreak())

    # ── 6 ──
    story.append(Paragraph("6. 수집·적재·서빙 구현 방식", styles["h1"]))
    story.append(Paragraph("6.1 클라이언트 수집 (Flutter)", styles["h2"]))
    story.append(
        make_table(
            [
                ["구성요소", "구현"],
                [
                    "SignalCollectorService",
                    "신규 서비스. 링버퍼 + 오프라인 로컬 큐. Mixpanel AnalyticsService와 분리",
                ],
                [
                    "카드 단위 impression",
                    "홈·탐색·검색 카드 뷰포트 진입 시 imp (section, position). "
                    "기존 section impression을 카드 단위로 확장 — 랭킹 학습의 전제조건",
                ],
                [
                    "플러시 조건",
                    "50건 / 30초 / 앱 백그라운드 / 탭 이탈",
                ],
                [
                    "보안 규칙",
                    "signal_batches: create-only, uid 일치, update/delete 금지, 필드 화이트리스트",
                ],
            ],
            [42 * mm, 140 * mm],
            styles,
        )
    )

    story.append(Paragraph("6.2 백필 (1일차 개인화)", styles["h2"]))
    story.append(
        Paragraph(
            "신규 계측을 기다리지 않고, 기존 Firestore 데이터를 과거 시그널로 변환해 "
            "취향 프로필을 시딩합니다: savedRecipes/savedAt, cookingDays, mealPlans, "
            "product_check_events, reviews.",
            styles["body"],
        )
    )

    story.append(Paragraph("6.3 일일 Export (콜드 적재)", styles["h2"]))
    story.append(
        Paragraph(
            "backend/services/signal_export_scheduler.py — 기존 recipe_snapshot_scheduler와 "
            "동일한 데몬 스레드 패턴. 전일 signal_batches 조회 → 평탄화 → subject_id 치환 → "
            "JSONL.gz → GCS 업로드 → 완료 마커. backend.py startup에 등록.",
            styles["body"],
        )
    )

    story.append(Paragraph("6.4 사전계산 서빙", styles["h2"]))
    story.append(
        bullets(
            [
                "taste_profile_builder.py (야간): 활성 유저(최근 30일)만 프로필·통계 갱신",
                "feed_ranking_service.py: 후보 생성 → 가중 스코어 → 다양성 제약 → "
                "user_recs/{uid}에 상위 200 미니카드 denormalize",
                "후보 소스: 저장/카트/냉장고 재료 오버랩 + canonicalDish 그룹 + "
                "home_section_index + 인기/신규 (+ P3 이후 임베딩 유사)",
                "홈은 user_recs 1문서 조회로 개인화 섹션 렌더 (기존 규칙 섹션은 폴백·대조군)",
            ],
            styles,
        )
    )
    story.append(PageBreak())

    # ── 7 ──
    story.append(Paragraph("7. 추천·학습 파이프라인", styles["h1"]))
    story.append(Paragraph("7.1 2단계 추천 (대형 앱과 동일한 골격)", styles["h2"]))
    story.append(
        make_table(
            [
                ["단계", "내용", "요리GO 구현"],
                [
                    "Candidate Generation",
                    "전체 중 수백 개 후보만 추출",
                    "재료·그룹·섹션·인기·(후)임베딩 ANN",
                ],
                [
                    "Ranking",
                    "후보를 정밀 점수화",
                    "취향 가중 + recipe_stats + (후)학습 랭커",
                ],
                [
                    "정책·다양성",
                    "필터·탐색·연속 노출 제한",
                    "본 것 제외, 동일 셰프/그룹 제한, 탐색 10~15%",
                ],
            ],
            [40 * mm, 58 * mm, 84 * mm],
            styles,
        )
    )

    story.append(Paragraph("7.2 임베딩 (P3)", styles["h2"]))
    story.append(
        bullets(
            [
                "모델: text-embedding-3-small, dimensions=256",
                "입력: 제목 + 카테고리 + 태그 + 재료 + 스텝 요약",
                "저장: recipes에는 emb_version/hash만, 벡터는 GCS embeddings/recipes-v1.npy",
                "서빙: 백엔드 기동 시 메모리 로드, numpy 내적 전수 검색 (5만×256 ≈ 51MB)",
                "유저 벡터: 상호작용 레시피 임베딩의 보상 가중·감쇠 평균",
            ],
            styles,
        )
    )

    story.append(Paragraph("7.3 학습 랭커 · 밴딧 (P4)", styles["h2"]))
    story.append(
        bullets(
            [
                "BQ training_ranker_v1: (impression, features, label=cook_done/purchase)",
                "LightGBM 또는 로지스틱 랭커 → 오프라인 NDCG@10·저장률 평가 후 배포",
                "기존 RerankBanditAgent(Thompson sampling)를 홈 피드로 확장, "
                "상태를 user_taste_profiles와 통합",
            ],
            styles,
        )
    )
    story.append(PageBreak())

    # ── 8 ──
    story.append(Paragraph("8. 비용 · 거버넌스 · 단계별 로드맵", styles["h1"]))
    story.append(Paragraph("8.1 비용 (현재 규모 기준)", styles["h2"]))
    story.append(
        Paragraph(
            "가정: DAU 약 500(피크 ~2,200), 유저당 일 150 시그널. "
            "현재 Firestore 읽기 ~121만/일, 쓰기 ~5.3만/일 수준.",
            styles["small"],
        )
    )
    story.append(
        make_table(
            [
                ["항목", "방식", "예상 비용"],
                [
                    "시그널 쓰기",
                    "세션 배치 (유저당 2~3 플러시/일)",
                    "약 1,500 write/일 → 월 $0.1 미만",
                ],
                [
                    "개별 write (비채택)",
                    "이벤트당 1문서",
                    "약 7.5만 write/일 → 월 ~$4, 트래픽에 선형 증가",
                ],
                ["Firestore 핫 보관", "35일 TTL", "상시 ~0.5GB, 월 $0.1 미만"],
                ["GCS 아카이브", "gzip JSONL", "연 ~1GB, 월 $0.02 수준"],
                ["BigQuery", "외부테이블+스케줄쿼리", "무료 티어 내 수년 실질 무료"],
                [
                    "임베딩",
                    "5만 레시피 × ~300토큰",
                    "일회성 약 $0.3, 증분 무시 가능",
                ],
                [
                    "서빙 읽기",
                    "user_recs 사전계산",
                    "홈 RunQuery 감소로 순비용 상쇄 가능",
                ],
            ],
            [36 * mm, 70 * mm, 76 * mm],
            styles,
        )
    )
    story.append(
        accent_box(
            "결론",
            "추가 인프라 비용은 월 $5 미만으로 설계합니다. 진짜 비용은 서버비가 아니라 "
            "카드 노출 계측·백필·동의/삭제 전파 엔지니어링 시간입니다.",
            styles,
        )
    )

    story.append(Paragraph("8.2 거버넌스 (자산이 되려면 필수)", styles["h2"]))
    story.append(
        bullets(
            [
                "동의: users.dataConsent — aggregate_insights 미동의는 집계 테이블 제외",
                "삭제 전파: compliance_service 계정 삭제 시 웨어하우스 tombstone + 파티션 재작성",
                "PII 분리: BQ/GCS에는 HMAC subject_id만",
                "signal_batches create-only + 필드 화이트리스트",
            ],
            styles,
        )
    )

    story.append(Paragraph("8.3 단계별 로드맵", styles["h2"]))
    story.append(
        make_table(
            [
                ["단계", "목표", "주요 산출물"],
                [
                    "P0",
                    "시그널 계약·수집",
                    "SignalCollector, 카드 imp, rules/index, 백필",
                ],
                [
                    "P1",
                    "콜드 자산화·거버넌스",
                    "GCS export, BQ agg, 동의, 삭제 전파, TTL",
                ],
                [
                    "P2",
                    "프로필·사전계산 서빙",
                    "taste_profile_builder, feed_ranking, 개인화 홈 A/B",
                ],
                [
                    "P3",
                    "임베딩",
                    "recipe embedding, 인메모리 유사도, 의미 검색 기반",
                ],
                [
                    "P4",
                    "학습 랭커·밴딧",
                    "training_ranker, NDCG 평가, 홈 밴딧+탐색 슬롯",
                ],
                [
                    "P5",
                    "자산 상품화",
                    "내부 인사이트 → 익명 집계 리포트·대시보드",
                ],
            ],
            [18 * mm, 48 * mm, 116 * mm],
            styles,
        )
    )
    story.append(
        Paragraph(
            "순서를 지키는 이유: 카드 노출(P0) 없이 랭커(P4)는 학습 불가. "
            "동의·삭제(P1) 없이 쌓으면 자산화 시점에 전량 폐기 리스크. "
            "임베딩(P3)보다 카테고리 프로필 서빙(P2)이 비용 대비 효과가 큼.",
            styles["small"],
        )
    )
    story.append(PageBreak())

    # ── 9 ──
    story.append(Paragraph("9. 현재 상태와 다음에 할 일", styles["h1"]))
    story.append(Paragraph("이미 있는 것", styles["h2"]))
    story.append(
        bullets(
            [
                "레시피 메타: categories(이중키), tags, chefTag, ingredients, canonicalDish/groupKey",
                "유저 상태: savedRecipes, cartItems, fridgeData, mealPlans, cookingDays, reviews",
                "커머스 흔적: product_check_events, cart_purchase_completed, affiliate 이벤트",
                "홈 규칙 기반 discovery + 장바구니 밴딧 추천",
                "Mixpanel 제품 분석 계측",
            ],
            styles,
        )
    )
    story.append(Paragraph("없는 것 (이번 계획으로 채움)", styles["h2"]))
    story.append(
        bullets(
            [
                "카드 단위 impression (학습 분모)",
                "자사 시그널 스토어 + GCS/BQ 원천 자산",
                "유저 취향 프로필 영구 저장·사전계산 추천 서빙",
                "임베딩·학습 랭커",
                "광고 반응 이벤트 (광고 기능 시점)",
                "‘누구를 위해/가치관(건강·가격·편의)’ 표준 필드",
            ],
            styles,
        )
    )

    story.append(Paragraph("구현 착수 시 우선순위", styles["h2"]))
    story.append(
        make_table(
            [
                ["순서", "작업"],
                ["1", "시그널 스키마·보상 가중치 코드 상수화 + SignalCollectorService"],
                ["2", "홈/탐색 카드 impression 계측"],
                ["3", "firestore.rules / indexes + 백필 스크립트"],
                ["4", "signal_export_scheduler → GCS + BQ 외부 테이블"],
                ["5", "동의 UI + compliance 삭제 전파"],
                ["6", "야간 프로필 빌더 + user_recs + 개인화 홈 섹션 A/B"],
            ],
            [18 * mm, 164 * mm],
            styles,
        )
    )

    story.append(Spacer(1, 6 * mm))
    story.append(
        accent_box(
            "마무리",
            "요리GO의 해자는 하나의 데이터에 있지 않습니다. "
            "사용자를 이해하는 데이터, 콘텐츠 취향 데이터, 구매 행동 데이터, "
            "상품·광고 반응 데이터가 하나의 흐름 안에서 동시에 쌓이고 서로를 강화하는 것 — "
            "그것이 푸드 버티컬 데이터 플랫폼으로서의 차별점입니다. "
            "기술적으로는 ‘세션 배치 수집 → 콜드 자산화 → 사전계산 개인화 → "
            "임베딩·학습 랭커’ 순으로, 비용을 낮게 유지하며 복리로 자산을 쌓습니다.",
            styles,
        )
    )
    story.append(Spacer(1, 8 * mm))
    story.append(
        Paragraph(
            "본 문서는 내부 기획·구현 정렬용입니다. 스키마 필드명·컬렉션명은 구현 단계에서 "
            "코드 상수와 동기화하며 버전(v) 필드로 호환을 관리합니다.",
            styles["meta"],
        )
    )
    return story


def main() -> None:
    styles = make_styles()
    doc = SimpleDocTemplate(
        str(PDF_OUT),
        pagesize=A4,
        leftMargin=14 * mm,
        rightMargin=14 * mm,
        topMargin=14 * mm,
        bottomMargin=16 * mm,
        title="요리GO 푸드 버티컬 데이터 플랫폼 기술 보고서",
        author="요리GO",
    )
    story = build_story(styles)
    doc.build(story, onFirstPage=add_footer, onLaterPages=add_footer)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"Wrote: {PDF_OUT}")
    print(f"Copied: {DOWNLOADS}")


if __name__ == "__main__":
    main()
