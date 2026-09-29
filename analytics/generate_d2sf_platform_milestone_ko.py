"""요리GO 플랫폼 확장 기능 마일스톤 (D2SF, 압축판 3~6p)."""

from __future__ import annotations

import json
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
from reportlab.platypus import (
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
PDF_OUT = ROOT / "yorigo_d2sf_platform_milestone_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "yorigo_d2sf_platform_milestone_ko.pdf"
SNAP = ROOT / "d2sf_baseline_snapshot.json"

FONT, FONT_B = "Malgun", "MalgunBold"
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


def load_snap() -> dict[str, Any]:
    if SNAP.is_file():
        return json.loads(SNAP.read_text(encoding="utf-8"))
    return {}


def S() -> dict[str, ParagraphStyle]:
    return {
        "cover": ParagraphStyle(
            "cover", fontName=FONT_B, fontSize=15, leading=20,
            alignment=TA_CENTER, textColor=NAVY, spaceAfter=2,
        ),
        "sub": ParagraphStyle(
            "sub", fontName=FONT, fontSize=8.8, leading=12,
            alignment=TA_CENTER, textColor=colors.HexColor("#334155"), spaceAfter=2,
        ),
        "meta": ParagraphStyle(
            "meta", fontName=FONT, fontSize=7.2, leading=9.5,
            alignment=TA_CENTER, textColor=MUTED, spaceAfter=4,
        ),
        "h1": ParagraphStyle(
            "h1", fontName=FONT_B, fontSize=11, leading=14,
            spaceBefore=1, spaceAfter=3.5, textColor=NAVY,
        ),
        "h2": ParagraphStyle(
            "h2", fontName=FONT_B, fontSize=9, leading=12,
            spaceBefore=4, spaceAfter=2, textColor=PURPLE,
        ),
        "body": ParagraphStyle(
            "body", fontName=FONT, fontSize=8.2, leading=11.2,
            spaceAfter=2.5, alignment=TA_JUSTIFY, textColor=NAVY,
        ),
        "bullet": ParagraphStyle(
            "bullet", fontName=FONT, fontSize=7.8, leading=10.5, textColor=NAVY,
        ),
        "cell": ParagraphStyle(
            "cell", fontName=FONT, fontSize=7, leading=9.3, textColor=NAVY,
        ),
        "cell_b": ParagraphStyle(
            "cell_b", fontName=FONT_B, fontSize=7, leading=9.3, textColor=colors.white,
        ),
        "box_b": ParagraphStyle(
            "box_b", fontName=FONT_B, fontSize=7.8, leading=10.5, textColor=NAVY,
        ),
        "box": ParagraphStyle(
            "box", fontName=FONT, fontSize=7.6, leading=10.3, textColor=NAVY,
        ),
        "phase": ParagraphStyle(
            "phase", fontName=FONT_B, fontSize=8.3, leading=11, textColor=colors.white,
        ),
        "phase_s": ParagraphStyle(
            "phase_s", fontName=FONT, fontSize=7, leading=9.5,
            textColor=colors.HexColor("#ecfdf5"),
        ),
    }


def tbl(rows: list[list[str]], widths: list[float], s: dict[str, ParagraphStyle]) -> Table:
    data = []
    for i, row in enumerate(rows):
        st = s["cell_b"] if i == 0 else s["cell"]
        data.append([Paragraph(c.replace("\n", "<br/>"), st) for c in row])
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), HDR),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.3, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 2.5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 2.5),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, ROW]),
    ]))
    return t


def box(title: str, body: str, s: dict[str, ParagraphStyle], bg=TEAL_BG, border=TEAL) -> Table:
    t = Table([[Paragraph(title, s["box_b"])], [Paragraph(body, s["box"])]], colWidths=[182 * mm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 0.7, border),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def phase(text: str, sub: str, s: dict[str, ParagraphStyle], bg=TEAL) -> Table:
    t = Table([[Paragraph(text, s["phase"])], [Paragraph(sub, s["phase_s"])]], colWidths=[182 * mm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (0, 0), 3.5),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 3.5),
        ("TOPPADDING", (0, 1), (-1, 1), 0),
    ]))
    return t


def fmt(n: Any) -> str:
    try:
        return f"{int(n):,}"
    except Exception:
        return str(n)


def footer(canvas: Any, doc: Any) -> None:
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.3)
    y = 7 * mm
    canvas.line(12 * mm, y + 3, A4[0] - 12 * mm, y + 3)
    canvas.setFont(FONT, 6.8)
    canvas.setFillColor(MUTED)
    canvas.drawString(12 * mm, y, "요리GO · 플랫폼 확장 기능 마일스톤 (D2SF)")
    canvas.drawRightString(A4[0] - 12 * mm, y, f"{doc.page}")
    canvas.restoreState()


def build(s: dict[str, ParagraphStyle]) -> list[Any]:
    snap = load_snap()
    mp = (snap.get("mixpanel") or {}).get("summary") or {}
    fs = (snap.get("firestore") or {}).get("counts") or {}
    as_of = snap.get("as_of_date") or date.today().isoformat()
    story: list[Any] = []

    story.append(Paragraph("NAVER D2SF · 기능 마일스톤 2", s["meta"]))
    story.append(Paragraph("요리GO 플랫폼 확장 기능", s["cover"]))
    story.append(Paragraph(
        "6개월 마일스톤 — 습관·결제 레일(1~3M) · 생태계·수익화(4~6M)<br/>"
        "마일스톤 1(데이터·추천)과 병행",
        s["sub"],
    ))
    story.append(Paragraph(
        f"작성일 {date.today().isoformat()} · 베이스라인 {as_of} · Mixpanel/Firestore 실측",
        s["meta"],
    ))
    story.append(box(
        "한 문장 비전",
        "촬영 한 장으로 냉장고가 채워지고, 앱 안에서 구매가 끝나며, 크리에이터와 광고주가 "
        "성과를 공유하는 순환형 푸드 플랫폼으로 확장한다.",
        s, BLUE_BG, BLUE,
    ))
    story.append(Spacer(1, 2 * mm))

    story.append(Paragraph("1. 왜 이 기능들인가", s["h1"]))
    story.append(Paragraph(
        "현재 요리GO는 외부 숏폼 파싱·쿠팡/컬리 제휴 장보기까지는 연결돼 있으나 "
        "(1) 재료 입력이 수동·구매연동에 의존하고 (2) 결제가 앱 밖으로 이탈하며 "
        "(3) 콘텐츠·광고 공급이 외부에만 의존한다. "
        "플랫폼 성장 순서는 <b>자주 열리게→사기 쉽게→콘텐츠가 돌게→돈이 돌게</b>다. "
        "광고 ROAS 대시보드는 마일스톤 1의 전환 시그널·웨어하우스가 없으면 형식만 남는다.",
        s["body"],
    ))

    story.append(Paragraph("2. 현재 제품·트랙션 베이스라인 (실측)", s["h1"]))
    story.append(tbl(
        [
            ["영역", "현재", "부재"],
            ["냉장고", "수동/구매연동 fridgeData 운영", "사진·영수증 자동 인식"],
            ["커머스", "쿠팡·컬리 제휴·딥링크 운영", "SSG·롯데·이츠·B마트, 인앱결제"],
            ["미디어", "리뷰 사진·외부 URL 재생", "자체 영상 업로드·스트리밍"],
            ["광고", "Mixpanel·제휴 클릭 추적", "광고주 캠페인·소진·ROAS 대시보드"],
        ],
        [28 * mm, 78 * mm, 76 * mm],
        s,
    ))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["커머스·사용 실측 (Mixpanel 유니크)", "값", "Firestore", "값"],
            ["가입", fmt(mp.get("total_unique_sign_ups")), "users", fmt(fs.get("users_total"))],
            ["재료 구매체크", fmt(mp.get("total_unique_ingredient_checked")), "공개 completed 레시피", fmt(fs.get("recipes_completed_visible"))],
            ["제휴 클릭", fmt(mp.get("total_unique_affiliate_click")), "reviews", fmt(fs.get("reviews_total"))],
            ["장바구니 구매완료", fmt(mp.get("total_unique_purchase_completed")), "MAU(가입, 최신월)", fmt(mp.get("mau_registered_latest_month"))],
            ["북마크", fmt(mp.get("total_unique_bookmarked")), "평균 DAU 30일", fmt(mp.get("avg_dau_registered_30d"))],
        ],
        [48 * mm, 28 * mm, 58 * mm, 48 * mm],
        s,
    ))
    story.append(Paragraph(
        f"구매완료 유저는 {fmt(mp.get('total_unique_purchase_completed'))}명으로 초기 단계이나, "
        f"재료 체크 {fmt(mp.get('total_unique_ingredient_checked'))}·제휴 클릭 "
        f"{fmt(mp.get('total_unique_affiliate_click'))}이 있어 결제 내부화·마켓 확대의 수요 신호가 있다.",
        s["body"],
    ))

    story.append(Paragraph("3. 우선순위 · 6개월 KPI", s["h1"]))
    story.append(tbl(
        [
            ["순위", "기능", "선정 이유"],
            ["1", "사진→냉장고/영수증", "매일 습관, 기존 냉장고·OCR 확장"],
            ["2", "음식 사진 영양 추정", "차별점(의료표현 금지·참고 정보)"],
            ["3", "마켓 확대(SSG·롯데 등)", "UI 스텁 존재, 제휴 모델 재사용"],
            ["4", "인앱 결제", "수수료·광고·정산 전제"],
            ["5", "신속배송(이츠·B마트)", "결제·제휴 후, 즉시 요리 빈도↑"],
            ["6", "크리에이터 업로드", "UGC, 스트리밍보다 업로드·재생 먼저"],
            ["7", "스트리밍/라이브", "Stretch — 업로드 안정 후"],
            ["8", "광고주 대시보드", "결제+MS1 전환데이터 필요 → 후반"],
        ],
        [14 * mm, 48 * mm, 120 * mm],
        s,
    ))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["KPI", "3개월", "6개월"],
            ["사진 냉장고/영수증 핵심 인식률", "≥70%", "≥80% + 보정 UX"],
            ["활성유저 중 사진기능 주간 사용", "≥20%", "≥35%"],
            ["신규 마켓 연동", "≥1곳", "≥2곳"],
            ["인앱 결제", "파일럿 거래 발생", "월간 거래 안정"],
            ["크리에이터 업로드", "-", "파일럿 콘텐츠 라이브"],
            ["광고 대시보드", "-", "파일럿 캠페인 1건+ 소진·전환 표시"],
        ],
        [70 * mm, 56 * mm, 56 * mm],
        s,
    ))
    story.append(PageBreak())

    story.append(Paragraph("4. 기능별 기술 요지", s["h1"]))
    story.append(tbl(
        [
            ["기능", "기술 요지"],
            ["사진 냉장고·영수증", "업로드→OCR(기존 RapidOCR)+비전/LLM 구조화→확인 UI→fridgeData"],
            ["영양 추정", "음식 이미지→영양 매핑, 참고용 고지(의료·진단 표현 금지)"],
            ["마켓·신속배송", "제휴 API/기존 상품매칭 파이프라인 재사용, 계약된 채널부터"],
            ["인앱 결제", "국내 PG(웹결제 우선)+정책 시 IAP, 결제 이벤트를 MS1 시그널에 편입"],
            ["크리에이터 업로드", "Storage+트랜스코딩(HLS)+CDN+검수 큐+레시피 연결"],
            ["광고 대시보드", "캠페인 모델+피드/레시피 슬롯+MS1 웨어하우스 전환 조인→소진·ROAS"],
        ],
        [40 * mm, 142 * mm],
        s,
    ))

    story.append(PageBreak())
    story.append(Paragraph("5. 월별 마일스톤", s["h1"]))
    story.append(phase("Phase A · 1~3개월 · 습관 + 커머스 레일", "사진·마켓·인앱결제로 방문·구매 마찰 제거", s, TEAL))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["월", "목표", "작업", "완료 기준"],
            ["1", "사진→냉장고", "촬영·OCR/비전 구조화·확인 UI·fridgeData 반영", "핵심 품목 반영·수정 가능"],
            ["2", "영양+마켓", "음식 영양 추정(참고 고지)·SSG/롯데 등 1곳+ 실연동", "영양 표시+신규 마켓 구매 완결"],
            ["3", "인앱 결제", "PG 연동·주문/환불·결제 이벤트를 MS1 시그널 편입", "앱 내 결제 완결·성공/실패 추적"],
        ],
        [12 * mm, 28 * mm, 88 * mm, 54 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(phase("Phase B · 4~6개월 · 생태계 + 수익화", "신속배송·크리에이터·광고 대시보드", s, PURPLE))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["월", "목표", "작업", "완료 기준"],
            ["4", "신속 배송", "이츠/B마트 등 1곳+ · 레시피/냉장고 숏컷", "신속 구매 동선 동작"],
            ["5", "크리에이터", "업로드·트랜스코딩·CDN·검수·레시피 연결 (라이브 Stretch)", "피드/상세 재생·레시피 연결"],
            ["6", "광고 대시보드", "캠페인·노출 슬롯·MS1 전환 조인·소진/ROAS", "파일럿 1건+ 대시보드 표시"],
        ],
        [12 * mm, 28 * mm, 88 * mm, 54 * mm],
        s,
    ))

    story.append(Paragraph("6. 리스크 · MS1 연계 · 실행 근거", s["h1"]))
    story.append(tbl(
        [
            ["항목", "내용"],
            ["리스크", "제휴 지연→계약된 곳부터 · PG심사→웹결제 폴백 · 헬스클레임 금지 · CDN비용→길이/해상도 제한 · 광고는 MS1 전환연동을 출시조건"],
            ["MS1 연계", "1~3M: 데이터수집∥사진·결제 / 4~6M: 인사이트∥신속·크리에이터·광고. 광고 ROAS=MS1 웨어하우스 필수"],
            [
                "실행 근거",
                "OCR·LLM 파싱·쿠팡/컬리 제휴·리뷰 Storage·배치 스케줄러 운영 중. "
                f"실측: 구매체크 {fmt(mp.get('total_unique_ingredient_checked'))}·제휴클릭 "
                f"{fmt(mp.get('total_unique_affiliate_click'))}·공개 레시피 "
                f"{fmt(fs.get('recipes_completed_visible'))}. "
                "신규 코어는 PG·영상 트랜스코딩·캠페인 관리로 한정.",
            ],
            ["충분성", "6개월에 습관·결제·공급·광고 파일럿까지 닫힘. 라이브 스트리밍·다채널 동시 연동은 Stretch로 분리해 일정 과적을 방지."],
        ],
        [24 * mm, 158 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(box(
        "제출용 한 문단",
        "마일스톤 2는 6개월간 사진 기반 냉장고/영수증·영양 추정, 마켓 확대, 인앱 결제로 "
        "사용 빈도와 구매 레일을 만들고, 이후 신속 배송·크리에이터 업로드·메타형 광고 대시보드로 "
        "생태계와 수익화를 연다. 라이브 스트리밍은 업로드 안정화 후 선택 추진한다. "
        f"(베이스라인 {as_of}: MAU {fmt(mp.get('mau_registered_latest_month'))}, "
        f"구매완료 {fmt(mp.get('total_unique_purchase_completed'))}명.)",
        s,
    ))
    story.append(Paragraph(
        "본 문서는 D2SF 제출용 요약본. 화면·API·법무 세부사항은 내부 문서로 관리.",
        s["meta"],
    ))
    return story


def main() -> None:
    s = S()
    doc = SimpleDocTemplate(
        str(PDF_OUT), pagesize=A4,
        leftMargin=12 * mm, rightMargin=12 * mm,
        topMargin=9 * mm, bottomMargin=11 * mm,
        title="요리GO 플랫폼 확장 기능 마일스톤 (D2SF)",
        author="요리GO",
    )
    doc.build(build(s), onFirstPage=footer, onLaterPages=footer)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"Wrote {PDF_OUT} / {DOWNLOADS}")


if __name__ == "__main__":
    main()
