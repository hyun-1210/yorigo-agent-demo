"""요리GO 플랫폼 성장 기능 6개월 마일스톤 PDF (마일스톤 2)."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

ROOT = Path(__file__).resolve().parent
PDF_OUT = ROOT / "yorigo_platform_milestone_6m_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "yorigo_platform_milestone_6m_ko.pdf"

FONT = "Malgun"
FONT_B = "MalgunBold"
pdfmetrics.registerFont(TTFont(FONT, r"C:\Windows\Fonts\malgun.ttf"))
pdfmetrics.registerFont(TTFont(FONT_B, r"C:\Windows\Fonts\malgunbd.ttf"))

NAVY = colors.HexColor("#0f172a")
MUTED = colors.HexColor("#64748b")
LINE = colors.HexColor("#cbd5e1")
ROW = colors.HexColor("#f8fafc")
HDR = colors.HexColor("#1e293b")
TEAL = colors.HexColor("#0f766e")
TEAL_BG = colors.HexColor("#f0fdfa")
BLUE = colors.HexColor("#1d4ed8")
BLUE_BG = colors.HexColor("#eff6ff")
ORG = colors.HexColor("#c2410c")
ORG_BG = colors.HexColor("#fff7ed")
PURPLE = colors.HexColor("#6d28d9")


def S() -> dict[str, ParagraphStyle]:
    return {
        "cover": ParagraphStyle(
            "cover", fontName=FONT_B, fontSize=15.5, leading=21,
            alignment=TA_CENTER, textColor=NAVY, spaceAfter=3,
        ),
        "sub": ParagraphStyle(
            "sub", fontName=FONT, fontSize=9, leading=12.5,
            alignment=TA_CENTER, textColor=colors.HexColor("#334155"), spaceAfter=2,
        ),
        "meta": ParagraphStyle(
            "meta", fontName=FONT, fontSize=7.5, leading=10,
            alignment=TA_CENTER, textColor=MUTED, spaceAfter=5,
        ),
        "h1": ParagraphStyle(
            "h1", fontName=FONT_B, fontSize=11, leading=14,
            spaceBefore=1, spaceAfter=4, textColor=NAVY,
        ),
        "h2": ParagraphStyle(
            "h2", fontName=FONT_B, fontSize=9, leading=12,
            spaceBefore=4, spaceAfter=2, textColor=TEAL,
        ),
        "body": ParagraphStyle(
            "body", fontName=FONT, fontSize=8.2, leading=11.5,
            spaceAfter=2.5, alignment=TA_JUSTIFY, textColor=NAVY,
        ),
        "cell": ParagraphStyle(
            "cell", fontName=FONT, fontSize=7, leading=9.5, textColor=NAVY,
        ),
        "cell_b": ParagraphStyle(
            "cell_b", fontName=FONT_B, fontSize=7, leading=9.5, textColor=colors.white,
        ),
        "box": ParagraphStyle(
            "box", fontName=FONT, fontSize=7.8, leading=10.5, textColor=NAVY,
        ),
        "box_b": ParagraphStyle(
            "box_b", fontName=FONT_B, fontSize=7.8, leading=10.5, textColor=NAVY,
        ),
        "phase": ParagraphStyle(
            "phase", fontName=FONT_B, fontSize=8.5, leading=11,
            textColor=colors.white,
        ),
        "phase_s": ParagraphStyle(
            "phase_s", fontName=FONT, fontSize=7, leading=9.5,
            textColor=colors.HexColor("#ecfdf5"),
        ),
    }


def tstyle() -> TableStyle:
    return TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), HDR),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, -1), FONT),
        ("GRID", (0, 0), (-1, -1), 0.3, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 2.5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 2.5),
        ("TOPPADDING", (0, 0), (-1, -1), 2.2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2.2),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, ROW]),
    ])


def tbl(rows: list[list[str]], widths: list[float], s: dict[str, ParagraphStyle]) -> Table:
    data = []
    for i, row in enumerate(rows):
        st = s["cell_b"] if i == 0 else s["cell"]
        data.append([Paragraph(c.replace("\n", "<br/>"), st) for c in row])
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(tstyle())
    return t


def box(title: str, body: str, s: dict[str, ParagraphStyle], bg: Any = TEAL_BG, border: Any = TEAL) -> Table:
    t = Table(
        [[Paragraph(title, s["box_b"])], [Paragraph(body, s["box"])]],
        colWidths=[182 * mm],
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 0.75, border),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 3.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
    ]))
    return t


def phase_bar(text: str, sub: str, s: dict[str, ParagraphStyle], bg: Any = TEAL) -> Table:
    t = Table(
        [[Paragraph(text, s["phase"])], [Paragraph(sub, s["phase_s"])]],
        colWidths=[182 * mm],
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (0, 0), 4),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 4),
        ("TOPPADDING", (0, 1), (-1, 1), 0),
    ]))
    return t


def footer(canvas: Any, doc: Any) -> None:
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.35)
    y = 7.5 * mm
    canvas.line(12 * mm, y + 3.5, A4[0] - 12 * mm, y + 3.5)
    canvas.setFont(FONT, 7)
    canvas.setFillColor(MUTED)
    canvas.drawString(12 * mm, y, "요리GO · 플랫폼 성장 기능 6개월 마일스톤 (마일스톤 2)")
    canvas.drawRightString(A4[0] - 12 * mm, y, f"{doc.page}")
    canvas.restoreState()


def build(s: dict[str, ParagraphStyle]) -> list[Any]:
    story: list[Any] = []
    today = date.today().isoformat()
    mw = [18 * mm, 38 * mm, 68 * mm, 58 * mm]

    # PAGE 1
    story.append(Paragraph("요리GO 플랫폼 성장", s["cover"]))
    story.append(Paragraph("마일스톤 2 · 6개월 기능 로드맵", s["cover"]))
    story.append(Spacer(1, 1.5 * mm))
    story.append(Paragraph(
        "앱을 더 자주·편리하게 쓰게 만드는 기능으로<br/>"
        "리텐션 → 커머스 → 크리에이터 → 광고 플랫폼 순으로 확장한다.",
        s["sub"],
    ))
    story.append(Paragraph(
        f"제출용 요약 &nbsp;|&nbsp; {today} &nbsp;|&nbsp; "
        "마일스톤 1(데이터 플랫폼)과 병행·연동",
        s["meta"],
    ))

    story.append(box(
        "마일스톤 1과의 관계",
        "마일스톤 1 = 데이터·추천·웨어하우스·벡터. "
        "마일스톤 2 = 사용 빈도·결제·크리에이터·광고 등 <b>제품·플랫폼 기능</b>. "
        "광고 대시보드·전환 측정은 마일스톤 1의 시그널/웨어하우스가 받쳐줄 때 효과가 크므로 "
        "전반은 ‘자주 쓰게’, 후반은 ‘돈·생태계’로 배치한다.",
        s, BLUE_BG, BLUE,
    ))
    story.append(Spacer(1, 2.5 * mm))

    story.append(Paragraph("1. 후보 기능과 우선순위 분석", s["h1"]))
    story.append(Paragraph(
        "현재: 쿠팡·컬리 제휴 장바구니(앱 밖 결제), 냉장고 수동/구매연동, 리뷰 사진 업로드, "
        "외부 URL 파싱 재생. 없음: 인앱 결제, 영수증·냉장고 사진, 자체 영상 업로드/스트리밍, "
        "광고주 대시보드, SSG·배민·쿠팡이츠 실연동(일부 UI 자리만).",
        s["body"],
    ))
    story.append(tbl(
        [
            ["우선", "기능", "왜 이 순위인가", "난이도·의존"],
            [
                "1",
                "사진→냉장고\n(영수증·냉장고)",
                "매일 쓰는 습관 루프. 기존 냉장고·OCR 기반 확장.\n리텐션에 가장 직접적.",
                "중 / 독자 진행 가능",
            ],
            [
                "2",
                "음식 사진\n성분·영양 분석",
                "헬스케어 차별점. 다만 의료 표현은 조심.\n‘영양 추정’으로 1차 출시.",
                "중 / 비전·LLM",
            ],
            [
                "3",
                "기존 커머스 확대\n(SSG·롯데 등)",
                "장바구니 UI에 자리 있음. 제휴 모델 재사용.\n선택지↑ = 구매 편의↑.",
                "중 / 제휴·API",
            ],
            [
                "4",
                "인앱 결제\n(장바구니·광고)",
                "수수료·광고비 회수의 전제.\n광고 플랫폼·크리에이터 정산의 다리.",
                "상 / PG·약관",
            ],
            [
                "5",
                "신속 배송 연동\n(이츠·B마트 등)",
                "‘지금 필요한 재료’ 빈도↑.\n제휴 일정에 민감 → 결제 다음.",
                "상 / 파트너",
            ],
            [
                "6",
                "크리에이터\n영상 업로드",
                "UGC·체류시간. CDN·검수 부담.\n스트리밍보다 업로드 먼저.",
                "상 / 스토리지",
            ],
            [
                "7",
                "영상 스트리밍\n고도화",
                "업로드·재생이 안정된 뒤.\n라이브는 6개월 내 선택.",
                "최상 / 인프라",
            ],
            [
                "8",
                "비즈니스 광고\n대시보드",
                "메타 광고형 ROAS. 전환 데이터(MS1)+\n결제·인벤토리 필요 → 후반.",
                "최상 / MS1 연동",
            ],
        ],
        [14 * mm, 36 * mm, 78 * mm, 54 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(box(
        "우선순위 한 줄",
        "자주 열리게(사진·냉장고) → 사기 쉽게(마켓 확대·인앱결제·신속배송) → "
        "콘텐츠가 돌게(크리에이터) → 돈이 돌게(광고 대시보드).",
        s, ORG_BG, ORG,
    ))

    story.append(PageBreak())

    # PAGE 2
    story.append(Paragraph("2. 6개월 로드맵 한눈에", s["h1"]))
    story.append(tbl(
        [
            ["기간", "이름", "초점", "끝나면"],
            [
                "1~3개월\nPhase A",
                "습관 + 커머스 레일",
                "사진 냉장고·영양 추정\n마켓 확대·인앱 결제",
                "매일 쓰는 이유 + 앱 안 결제 가능",
            ],
            [
                "4~6개월\nPhase B",
                "생태계 + 수익 플랫폼",
                "신속배송·크리에이터\n광고주 대시보드",
                "공급(콘텐츠·상품)·수요·광고가 맞물림",
            ],
        ],
        [28 * mm, 36 * mm, 60 * mm, 58 * mm],
        s,
    ))

    story.append(Spacer(1, 2.5 * mm))
    story.append(phase_bar(
        "Phase A  ·  1~3개월  ·  습관 루프 + 커머스 레일",
        "편의 기능으로 방문 빈도를 올리고, 결제로 수익 파이프를 연다",
        s, TEAL,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(tbl(
        [
            ["월", "목표", "핵심 작업", "완료 기준"],
            [
                "1개월",
                "사진→냉장고",
                "냉장고/영수증 사진 촬영·업로드\n품목 인식 → 냉장고 탭 자동 추가\n사용자 확인·수정 UX",
                "사진 1장으로 재료가 냉장고에\n들어가고 수정·저장까지 가능",
            ],
            [
                "2개월",
                "영양 추정 +\n마켓 확대",
                "음식 사진 → 성분/영양 추정(헬스케어 톤 주의)\nSSG·롯데 등 1곳 이상 실연동\n(제휴 되는 곳부터)",
                "음식 사진 분석 결과 표시\n장바구니에서 신규 마켓으로 구매 흐름",
            ],
            [
                "3개월",
                "인앱 결제",
                "장바구니 인앱 결제(PG/토스 등)\n주문·영수증·환불 기본\n광고/상품 결제 스키마 준비",
                "앱 안에서 장바구니 결제 완료\n(또는 명확한 결제 성공 트래킹)",
            ],
        ],
        mw,
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(box(
        "1~3개월 Must-have",
        "① 사진으로 냉장고가 채워진다  ② 살 수 있는 마켓이 늘어난다  "
        "③ 결제가 앱 밖으로만 나가지 않는다. → ‘정리 앱’에서 ‘매일 쓰는 장보기·냉장고 앱’으로.",
        s,
    ))

    story.append(Spacer(1, 3 * mm))
    story.append(phase_bar(
        "Phase B  ·  4~6개월  ·  생태계 + 수익 플랫폼",
        "신속 충족 · 크리에이터 공급 · 광고주가 돈을 쓰는 구조",
        s, PURPLE,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(tbl(
        [
            ["월", "목표", "핵심 작업", "완료 기준"],
            [
                "4개월",
                "신속 플랫폼",
                "쿠팡이츠 / 배민 B마트 등\n1개 우선 연동(제휴 가능 순)\n‘지금 필요한 재료’ 숏컷",
                "레시피/냉장고에서 신속 구매\n동선이 실제로 열림",
            ],
            [
                "5개월",
                "크리에이터\n이코노미 1차",
                "앱 내 영상 업로드·재생\n크리에이터 프로필·내 레시피 연결\n기본 검수·신고 (스트리밍은 MVP 재생 후)",
                "유저가 올린 영상이 피드/상세에서\n재생되고 레시피와 연결됨",
            ],
            [
                "6개월",
                "비즈니스\n광고 플랫폼",
                "광고주용 대시보드(캠페인·예산)\n레시피/피드 커머스 광고 노출\n소진액·전환·ROAS 표시\n(MS1 전환 데이터 연동)\n스트리밍/라이브는 여력 시",
                "광고주가 예산 집행·성과\n(전환·비용)를 대시보드에서 확인",
            ],
        ],
        mw,
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(box(
        "스트리밍 위치",
        "‘영상 업로드+재생’은 5개월 필수, ‘라이브 스트리밍’은 인프라·운영 부담이 커서 "
        "5~6개월 선택(Stretch)으로 둔다. 크리에이터 이코노미의 핵심은 먼저 "
        "<b>올리고 → 레시피와 붙고 → 조회·구매로 이어지는지</b>를 증명하는 것이다.",
        s, ORG_BG, ORG,
    ))

    story.append(PageBreak())

    # PAGE 3
    story.append(Paragraph("3. 기능별 가치와 의존 관계", s["h1"]))
    story.append(tbl(
        [
            ["기능", "유저에게", "비즈니스에", "앞서 필요한 것"],
            [
                "사진 냉장고·영수증",
                "입력 마찰↓, 매일 방문",
                "냉장고·추천 데이터↑",
                "기존 냉장고 탭",
            ],
            [
                "음식 성분 분석",
                "건강·안심 정보",
                "헬스케어 포지션",
                "사진 파이프라인",
            ],
            [
                "마켓 확대",
                "원하는 곳에서 구매",
                "제휴 매출 다각화",
                "기존 장바구니",
            ],
            [
                "인앱 결제",
                "이탈 없는 구매",
                "수수료·광고 과금",
                "PG·약관",
            ],
            [
                "신속 배송",
                "당장 요리 가능",
                "고빈도 커머스",
                "결제·제휴",
            ],
            [
                "크리에이터 영상",
                "볼거리·커뮤니티",
                "콘텐츠 공급 해자",
                "업로드·검수",
            ],
            [
                "광고 대시보드",
                "(간접) 더 나은 제안",
                "광고 매출·ROAS 상품",
                "결제 + MS1 전환 데이터",
            ],
        ],
        [36 * mm, 42 * mm, 48 * mm, 56 * mm],
        s,
    ))

    story.append(Paragraph("4. 성공 기준 · 리스크", s["h1"]))
    story.append(tbl(
        [
            ["시점", "성공으로 보는 상태"],
            [
                "3개월 말",
                "사진→냉장고 주간 사용 · 신규 마켓 1+ · 인앱 결제 성공 거래 발생",
            ],
            [
                "6개월 말",
                "신속 구매 동선 · 크리에이터 업로드 콘텐츠 라이브 · "
                "광고주 대시보드에서 비용·전환 확인 가능",
            ],
        ],
        [28 * mm, 154 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(tbl(
        [
            ["리스크", "대응"],
            [
                "제휴(SSG·배민·이츠) 일정 지연",
                "UI·데이터 모델 먼저, 연동은 계약된 곳부터. 월 목표는 ‘1곳 이상’",
            ],
            [
                "인앱 결제 법무·심사",
                "3개월 버퍼에 PG 선정·약관 병행. 실패 시 웹결제+딥링크로 폴백",
            ],
            [
                "헬스케어 과대 표현",
                "‘의료/진단’ 금지, 영양·성분 추정·참고 정보로 한정",
            ],
            [
                "크리에이터 CDN·비용 급증",
                "짧은 영상·해상도 제한·검수 큐. 스트리밍은 Stretch",
            ],
            [
                "광고 대시보드가 데이터 없이 빈 껍데기",
                "마일스톤 1 전환 시그널을 게이트로. 6개월차 ROAS는 필수 연동",
            ],
            [
                "기능만 늘고 사용 안 함",
                "월별 북스타: 냉장고 사진 사용률 → 결제 전환 → 업로드 수 → 광고 소진액",
            ],
        ],
        [58 * mm, 124 * mm],
        s,
    ))

    story.append(Spacer(1, 2.5 * mm))
    story.append(Paragraph("5. 두 마일스톤을 같이 보면", s["h1"]))
    story.append(tbl(
        [
            ["", "마일스톤 1 데이터", "마일스톤 2 플랫폼 기능"],
            [
                "전반\n1~3M",
                "수집·웨어하우스·개인화·벡터",
                "사진 냉장고·영양·마켓·인앱결제",
            ],
            [
                "후반\n4~6M",
                "인사이트·커머스 의도·집계 자산",
                "신속배송·크리에이터·광고 대시보드",
            ],
            [
                "결합 지점",
                "전환·취향·수요 데이터",
                "결제·광고 ROAS·크리에이터 성과",
            ],
        ],
        [24 * mm, 79 * mm, 79 * mm],
        s,
    ))

    story.append(Spacer(1, 2.5 * mm))
    story.append(box(
        "제출용 한 문단",
        "마일스톤 2는 6개월간 요리GO를 ‘파싱·장보기 도구’에서 "
        "<b>매일 쓰는 냉장고·결제·콘텐츠·광고 플랫폼</b>으로 키운다. "
        "1~3개월: 사진 기반 냉장고/영수증·음식 영양 추정, 마켓 확대, 인앱 결제로 "
        "사용 빈도와 수익 레일을 만든다. "
        "4~6개월: 신속 배송 연동, 크리에이터 영상 업로드(재생), "
        "메타 광고형 비즈니스 대시보드(소진·전환·ROAS)로 생태계와 광고 매출 기반을 만든다. "
        "라이브 스트리밍은 업로드 안정화 후 선택적으로 추진한다.",
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(Paragraph(
        "한 줄: 사진으로 채워지고 → 앱에서 사고 → 크리에이터가 올리고 → 광고주가 성과를 본다.",
        s["meta"],
    ))
    return story


def main() -> None:
    s = S()
    doc = SimpleDocTemplate(
        str(PDF_OUT),
        pagesize=A4,
        leftMargin=12 * mm,
        rightMargin=12 * mm,
        topMargin=9 * mm,
        bottomMargin=11 * mm,
        title="요리GO 플랫폼 성장 기능 6개월 마일스톤",
        author="요리GO",
    )
    doc.build(build(s), onFirstPage=footer, onLaterPages=footer)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"Wrote: {PDF_OUT}")
    print(f"Copied: {DOWNLOADS}")


if __name__ == "__main__":
    main()
