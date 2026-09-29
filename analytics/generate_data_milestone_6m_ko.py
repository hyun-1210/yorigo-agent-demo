"""요리GO 데이터 플랫폼 6개월 마일스톤 PDF (3개월 구축 + 3개월 가치화, 압축판)."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
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
PDF_OUT = ROOT / "yorigo_data_milestone_6m_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "yorigo_data_milestone_6m_ko.pdf"

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
PURPLE_BG = colors.HexColor("#f5f3ff")


def S() -> dict[str, ParagraphStyle]:
    return {
        "cover": ParagraphStyle(
            "cover", fontName=FONT_B, fontSize=16, leading=22,
            alignment=TA_CENTER, textColor=NAVY, spaceAfter=4,
        ),
        "sub": ParagraphStyle(
            "sub", fontName=FONT, fontSize=9.5, leading=13,
            alignment=TA_CENTER, textColor=colors.HexColor("#334155"), spaceAfter=3,
        ),
        "meta": ParagraphStyle(
            "meta", fontName=FONT, fontSize=7.5, leading=10,
            alignment=TA_CENTER, textColor=MUTED, spaceAfter=6,
        ),
        "h1": ParagraphStyle(
            "h1", fontName=FONT_B, fontSize=11.5, leading=15,
            spaceBefore=2, spaceAfter=5, textColor=NAVY,
        ),
        "h2": ParagraphStyle(
            "h2", fontName=FONT_B, fontSize=9.5, leading=12,
            spaceBefore=5, spaceAfter=3, textColor=TEAL,
        ),
        "body": ParagraphStyle(
            "body", fontName=FONT, fontSize=8.5, leading=12,
            spaceAfter=3, alignment=TA_JUSTIFY, textColor=NAVY,
        ),
        "bullet": ParagraphStyle(
            "bullet", fontName=FONT, fontSize=8, leading=11, textColor=NAVY,
        ),
        "cell": ParagraphStyle(
            "cell", fontName=FONT, fontSize=7.2, leading=10, textColor=NAVY,
        ),
        "cell_b": ParagraphStyle(
            "cell_b", fontName=FONT_B, fontSize=7.2, leading=10, textColor=colors.white,
        ),
        "box": ParagraphStyle(
            "box", fontName=FONT, fontSize=8, leading=11, textColor=NAVY,
        ),
        "box_b": ParagraphStyle(
            "box_b", fontName=FONT_B, fontSize=8, leading=11, textColor=NAVY,
        ),
        "phase": ParagraphStyle(
            "phase", fontName=FONT_B, fontSize=9, leading=12,
            textColor=colors.white, alignment=TA_LEFT,
        ),
        "phase_s": ParagraphStyle(
            "phase_s", fontName=FONT, fontSize=7.5, leading=10,
            textColor=colors.HexColor("#ecfdf5"),
        ),
    }


def tstyle() -> TableStyle:
    return TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), HDR),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, -1), FONT),
        ("FONTSIZE", (0, 0), (-1, -1), 7.2),
        ("GRID", (0, 0), (-1, -1), 0.3, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING", (0, 0), (-1, -1), 2.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
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


def box(
    title: str, body: str, s: dict[str, ParagraphStyle],
    bg: Any = TEAL_BG, border: Any = TEAL,
) -> Table:
    t = Table(
        [[Paragraph(title, s["box_b"])], [Paragraph(body, s["box"])]],
        colWidths=[182 * mm],
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 0.8, border),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def phase_bar(text: str, sub: str, s: dict[str, ParagraphStyle], bg: Any = TEAL) -> Table:
    t = Table(
        [[Paragraph(text, s["phase"])], [Paragraph(sub, s["phase_s"])]],
        colWidths=[182 * mm],
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (0, 0), 5),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 5),
        ("TOPPADDING", (0, 1), (-1, 1), 0),
    ]))
    return t


def bullets(items: list[str], s: dict[str, ParagraphStyle]) -> ListFlowable:
    return ListFlowable(
        [ListItem(Paragraph(x, s["bullet"]), leftIndent=4, value="•") for x in items],
        bulletType="bullet", start="•", leftIndent=6,
        bulletFontName=FONT, bulletFontSize=8, spaceBefore=0, spaceAfter=2,
    )


def footer(canvas: Any, doc: Any) -> None:
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.35)
    y = 8 * mm
    canvas.line(12 * mm, y + 4, A4[0] - 12 * mm, y + 4)
    canvas.setFont(FONT, 7)
    canvas.setFillColor(MUTED)
    canvas.drawString(12 * mm, y, "요리GO · 데이터 플랫폼 6개월 마일스톤 (압축판)")
    canvas.drawRightString(A4[0] - 12 * mm, y, f"{doc.page}")
    canvas.restoreState()


def build(s: dict[str, ParagraphStyle]) -> list[Any]:
    story: list[Any] = []
    today = date.today().isoformat()
    w = [22 * mm, 40 * mm, 50 * mm, 70 * mm]

    # ── PAGE 1: cover + why + overview ──
    story.append(Paragraph("요리GO 데이터 플랫폼", s["cover"]))
    story.append(Paragraph("6개월 마일스톤 — 3개월 구축 · 3개월 가치화", s["cover"]))
    story.append(Spacer(1, 2 * mm))
    story.append(Paragraph(
        "핵심 인프라를 전반 3개월에 압축 구축하고,<br/>"
        "후반 3개월은 데이터로 제품·파트너 가치를 만드는 데 집중한다.",
        s["sub"],
    ))
    story.append(Paragraph(
        f"제출용 요약본 &nbsp;|&nbsp; {today} &nbsp;|&nbsp; "
        "상세 스키마·API는 기술 보고서 참조",
        s["meta"],
    ))

    story.append(box(
        "왜 3+3으로 나누나",
        "현재 등록 MAU 약 1,700·DAU 수백 규모이고, 레시피 메타·저장·장바구니·구매 체크·홈 규칙 인덱스가 "
        "이미 있습니다. 수집·웨어하우스·1차 개인화는 병렬로 밀어 3개월 안에 끝낼 수 있습니다. "
        "벡터 DB·인사이트 상품·커머스/광고 실험은 ‘데이터가 쌓인 뒤’가 효과가 커서 "
        "후반 3개월에 두는 편이 비용·성과 모두에 유리합니다.",
        s, BLUE_BG, BLUE,
    ))
    story.append(Spacer(1, 3 * mm))

    story.append(Paragraph("1. 한눈에 보는 구조", s["h1"]))
    story.append(tbl(
        [
            ["기간", "이름", "하는 일", "끝나면"],
            [
                "1~3개월\nPhase A",
                "기반 구축",
                "시그널 수집 → BigQuery 웨어하우스\n→ 취향 프로필 → 개인화 추천\n→ 임베딩·벡터 DB 1차",
                "데이터가 자사 자산으로 쌓이고\n홈에서 개인화·유사 요리가 동작",
            ],
            [
                "4~6개월\nPhase B",
                "가치화·고도화",
                "의미 검색 강화 · 전환 인사이트\n· 수요/커머스 리포트\n· 상품 제안 실험 · 파트너 자산",
                "추천이 정교해지고\n데이터로 내부·외부 가치가 나온다",
            ],
        ],
        [28 * mm, 28 * mm, 68 * mm, 58 * mm],
        s,
    ))
    story.append(Spacer(1, 2.5 * mm))
    story.append(Paragraph("핵심 용어 (이 문서에서 쓰는 수준)", s["h2"]))
    story.append(tbl(
        [
            ["용어", "쉽게", "역할"],
            ["웨어하우스(BigQuery)", "분석·학습용 데이터 창고", "자사 데이터 자산 본진"],
            ["GCS", "원본 파일 보관소", "일별 로그 원본"],
            ["취향 프로필", "유저 취향 요약", "개인화 추천 입력"],
            ["벡터 DB", "비슷한 요리를 빨리 찾는 DB", "유사 레시피·의미 검색"],
            ["Mixpanel", "제품 지표 도구", "DAU·퍼널 관찰 (자산 본진 아님)"],
        ],
        [40 * mm, 62 * mm, 80 * mm],
        s,
    ))

    story.append(PageBreak())

    # ── PAGE 2: Phase A months 1-3 ──
    story.append(phase_bar(
        "Phase A  ·  1~3개월  ·  기반 구축 (압축)",
        "예전 6개월 핵심을 3개월로 당김 — 수집·창고·추천·벡터를 끝까지 연결",
        s, TEAL,
    ))
    story.append(Spacer(1, 2.5 * mm))
    story.append(Paragraph(
        "압축이 가능한 이유: (1) 레시피 카테고리·재료·그룹 메타가 이미 있음 "
        "(2) 저장·식단·장바구니·구매 체크를 백필해 처음부터 취향을 만들 수 있음 "
        "(3) 트래픽이 작아 BigQuery·벡터 비용이 매우 낮음 "
        "(4) 홈 규칙 섹션·장바구니 밴딧이 있어 개인화를 ‘추가’만 하면 됨.",
        s["body"],
    ))

    story.append(Paragraph("월별 마일스톤 — Phase A", s["h2"]))
    story.append(tbl(
        [
            ["월", "목표", "핵심 작업", "완료 기준"],
            [
                "1개월",
                "수집 + 웨어하우스 착수",
                "행동 시그널 수집기·카드 노출 계측\n일일 GCS→BigQuery 적재 시작\n동의·익명 ID 기본 규칙",
                "노출~구매 신호가 자사 DB에 쌓이고\n어제 데이터가 BQ에서 조회됨",
            ],
            [
                "2개월",
                "취향 + 개인화 홈",
                "유저 취향 프로필·레시피 성과 집계\n추천 목록 사전계산\n개인화 홈 섹션 베타 출시",
                "로그인 홈에 ‘당신 추천’ 노출\n클릭·저장 측정 가능",
            ],
            [
                "3개월",
                "랭킹 개선 + 벡터 DB",
                "요리완료·구매 기준 순위 개선·A/B\n레시피 임베딩 생성\n벡터 DB 연동·유사 레시피 API",
                "개인화가 대조군 대비 개선\n‘비슷한 요리’가 서비스에서 동작",
            ],
        ],
        w,
        s,
    ))
    story.append(Spacer(1, 2.5 * mm))
    story.append(box(
        "1~3개월 끝 상태 (Must-have)",
        "앱 행동 → Firestore(핫) → GCS/BigQuery(웨어하우스) → 취향 프로필 → 개인화 홈 → "
        "임베딩·벡터 DB 유사 검색까지 <b>한 줄로 연결</b>되어 있다. "
        "Mixpanel은 DAU·퍼널 관찰용으로만 남는다.",
        s,
    ))

    story.append(Spacer(1, 3.5 * mm))
    story.append(phase_bar(
        "Phase B  ·  4~6개월  ·  가치화 · 고도화",
        "인프라를 늘리기보다, 쌓인 데이터로 제품·파트너·수익 가능성을 만든다",
        s, PURPLE,
    ))
    story.append(Spacer(1, 2.5 * mm))
    story.append(Paragraph(
        "후반의 핵심 질문: <b>이 데이터로 무엇을 더 잘하고, 무엇을 팔 수 있는가?</b> "
        "기술 고도화(더 빠른 검색·더 정확한 랭킹)와 가치 창출(인사이트·제안·파트너 리포트)을 같이 갑니다.",
        s["body"],
    ))

    story.append(Paragraph("월별 마일스톤 — Phase B", s["h2"]))
    story.append(tbl(
        [
            ["월", "목표", "핵심 작업", "완료 기준"],
            [
                "4개월",
                "제품 고도화\n+ 내부 인사이트",
                "의미 검색을 메인 검색에 적용\n저장→요리→구매 전환 대시보드\n콘텐츠(생산자) 전환 리포트",
                "검색 품질 개선이 체감되고\n주간 전환·수요 인사이트가 자동 생성",
            ],
            [
                "5개월",
                "커머스·의도\n기반 제안",
                "‘이 요리에 필요한 상품’ 맥락 제안 실험\n재료·메뉴 수요 예측 리포트\n프로필 갱신 주기 단축(더 빠른 반영)",
                "레시피 맥락 제안의 클릭·담기 측정\n수요 리포트가 운영/파트너 논의에 쓰임",
            ],
            [
                "6개월",
                "외부 가치\n+ 플라이휠 고정",
                "익명·집계 파트너 리포트 템플릿\n광고/제안 반응 데이터 모델\n전체 KPI 보드·다음 6개월 계획",
                "외부 공유 가능한 집계 자산 1종 이상\n수집→추천→인사이트 루프가 상시 가동",
            ],
        ],
        w,
        s,
    ))

    story.append(PageBreak())

    # ── PAGE 3: value map + success + risks ──
    story.append(Paragraph("2. 후반 3개월이 만드는 가치 (면밀 정리)", s["h1"]))
    story.append(Paragraph(
        "전반이 ‘파이프를 깔는 일’이라면, 후반은 파이프 위 물이 가치를 만드는 구간입니다. "
        "네 축 데이터가 동시에 쌓이므로 아래를 <b>병행</b>할 수 있습니다.",
        s["body"],
    ))
    story.append(tbl(
        [
            ["가치 축", "무엇을 만드나", "누구에게", "데이터 근거"],
            [
                "더 좋은 제품",
                "의미 검색·유사 추천\n빠른 취향 반영",
                "유저",
                "시그널 + 벡터 DB\n+ 취향 프로필",
            ],
            [
                "콘텐츠 전환 인텔",
                "저장만 vs 요리·구매로\n이어진 콘텐츠 구분",
                "크리에이터·내부 수급",
                "콘텐츠×행동 조인\n(BigQuery 집계)",
            ],
            [
                "수요·커머스 인텔",
                "메뉴·재료 수요 트렌드\n‘왜 샀는지’ 경로",
                "식품·커머스·내부",
                "레시피→재료→구매\n연결 데이터",
            ],
            [
                "제안·광고 기반",
                "누구에게·어떤 메뉴 상황에서\n무엇을 제안할지",
                "브랜드·광고 (준비)",
                "프로필×맥락×반응\n(6개월차 모델)",
            ],
        ],
        [32 * mm, 50 * mm, 42 * mm, 58 * mm],
        s,
    ))
    story.append(Spacer(1, 2.5 * mm))
    story.append(box(
        "투자·파트너 관점 한 줄",
        "요리GO는 조회수가 아니라 <b>요리 의도→실행→구매</b>가 한 플랫폼에 붙는 데이터 해자를 쌓습니다. "
        "전반 3개월에 그 파이프를 완성하고, 후반 3개월에 추천 고도화와 집계 인사이트·제안 실험으로 "
        "제품과 비즈니스 양쪽에 가치를 증명합니다.",
        s, ORG_BG, ORG,
    ))

    story.append(Paragraph("3. 성공 기준 · 리스크", s["h1"]))
    story.append(tbl(
        [
            ["시점", "성공으로 보는 상태"],
            ["3개월 말", "웨어하우스 일일 적재 · 개인화 홈 라이브 · 벡터 유사 요리 동작 · 동의/삭제 기본 반영"],
            ["6개월 말", "전환·수요 주간 인사이트 · 맥락 상품 제안 실험 결과 · 익명 집계 리포트 템플릿 · KPI 보드"],
        ],
        [28 * mm, 154 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(tbl(
        [
            ["리스크", "대응"],
            ["수집이 밀리면 후반이 공회전", "1개월을 고정 게이트. 노출(imp) 없이 2개월 추천 착수 금지"],
            ["3개월에 벡터까지 무리", "유사 검색 MVP(필수) / 검색 UX 고도화는 4개월로 이월 가능"],
            ["클릭만 쫓는 추천", "성공 지표 = 요리 완료 + 구매 (고정)"],
            ["개인정보·동의 미비", "2개월 전 익명화·삭제 전파를 출시 조건으로"],
            ["후반이 기능만 늘고 가치 부재", "4~6개월마다 ‘내부 사용 리포트 1종’ 필수 산출"],
        ],
        [55 * mm, 127 * mm],
        s,
    ))

    story.append(Spacer(1, 3 * mm))
    story.append(Paragraph("4. 제출용 요약", s["h1"]))
    story.append(box(
        "6개월 한 문단",
        "요리GO는 6개월을 <b>3개월 기반 구축 + 3개월 가치화</b>로 운영합니다. "
        "1~3개월: 행동 시그널 수집, BigQuery 웨어하우스, 취향 기반 개인화 추천, 임베딩·벡터 DB까지 연결합니다. "
        "4~6개월: 의미 검색·추천을 고도화하고, 콘텐츠 전환·재료/메뉴 수요·맥락 상품 제안·익명 집계 리포트로 "
        "데이터 자산의 제품·파트너 가치를 만듭니다. "
        "목표는 분석 도구가 아니라, 요리 의도가 행동과 구매로 이어지는 과정을 자산화하는 푸드 버티컬 데이터 플랫폼입니다.",
        s,
    ))
    story.append(Spacer(1, 3 * mm))
    story.append(Paragraph(
        "로드맵 한 줄: "
        "수집 → 웨어하우스 → 개인화 → 벡터DB → 인사이트 → 커머스 제안 → 파트너 자산",
        s["meta"],
    ))
    story.append(Paragraph(
        "상세 기술(스키마·보상·비용·컬렉션)은 "
        "『푸드 버티컬 데이터 플랫폼 기술 보고서』 및 내부 구현 계획 참고.",
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
        topMargin=10 * mm,
        bottomMargin=12 * mm,
        title="요리GO 데이터 플랫폼 6개월 마일스톤 (3+3)",
        author="요리GO",
    )
    doc.build(build(s), onFirstPage=footer, onLaterPages=footer)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"Wrote: {PDF_OUT}")
    print(f"Copied: {DOWNLOADS}")


if __name__ == "__main__":
    main()
