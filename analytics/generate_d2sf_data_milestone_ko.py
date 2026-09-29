"""요리GO 데이터·추천 플랫폼 마일스톤 (D2SF, 압축판 3~6p)."""

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
PDF_OUT = ROOT / "yorigo_d2sf_data_milestone_ko.pdf"
DOWNLOADS = Path.home() / "Downloads" / "yorigo_d2sf_data_milestone_ko.pdf"
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
            spaceBefore=4, spaceAfter=2, textColor=TEAL,
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


def bullets(items: list[str], s: dict[str, ParagraphStyle]) -> ListFlowable:
    return ListFlowable(
        [ListItem(Paragraph(x, s["bullet"]), leftIndent=3, value="•") for x in items],
        bulletType="bullet", start="•", leftIndent=5,
        bulletFontName=FONT, bulletFontSize=7.5, spaceBefore=0, spaceAfter=1.5,
    )


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
    canvas.drawString(12 * mm, y, "요리GO · 데이터·추천 플랫폼 마일스톤 (D2SF)")
    canvas.drawRightString(A4[0] - 12 * mm, y, f"{doc.page}")
    canvas.restoreState()


def build(s: dict[str, ParagraphStyle]) -> list[Any]:
    snap = load_snap()
    mp = (snap.get("mixpanel") or {}).get("summary") or {}
    fs = (snap.get("firestore") or {}).get("counts") or {}
    mon = (snap.get("firestore") or {}).get("monitoring") or {}
    as_of = snap.get("as_of_date") or date.today().isoformat()
    story: list[Any] = []

    story.append(Paragraph("NAVER D2SF · 기술 마일스톤 1", s["meta"]))
    story.append(Paragraph("요리GO 데이터·추천 플랫폼", s["cover"]))
    story.append(Paragraph("6개월 마일스톤 (3개월 기반 구축 · 3개월 고도화·가치화)", s["sub"]))
    story.append(Paragraph(
        f"작성일 {date.today().isoformat()} · 베이스라인 기준일 {as_of} · "
        "Mixpanel Query API + Firestore 실측",
        s["meta"],
    ))
    story.append(box(
        "한 문장 비전",
        "레시피 발견→선택→요리→구매 전 과정의 행동 데이터를 자사 웨어하우스에 축적하고, "
        "개인화 추천·벡터 유사 검색·데이터 인사이트로 전환하는 푸드 버티컬 데이터 플랫폼을 구축한다.",
        s, BLUE_BG, BLUE,
    ))
    story.append(Spacer(1, 2 * mm))

    # 1
    story.append(Paragraph("1. 왜 이 작업인가", s["h1"]))
    story.append(Paragraph(
        "유튜브·구글형 추천은 노출·행동·전환 로그 위의 <b>후보생성→랭킹</b> 구조다. "
        "요리GO는 레시피 메타·규칙형 홈·장바구니 밴딧은 있으나, 노출 단위 시그널·자사 웨어하우스·"
        "벡터 검색이 없어 학습·자산화가 불가능하다. Mixpanel은 관찰용이며 서빙·소유·재가공의 본진이 될 수 없다. "
        "지금 규모에서 파이프라인을 깔면 비용이 낮고, 메타·저장·구매 이력을 즉시 백필할 수 있다.",
        s["body"],
    ))

    # 2 what data / why
    story.append(Paragraph("2. 어떤 데이터를 남기고, 왜 남기는가", s["h1"]))
    story.append(Paragraph(
        "'요리 의도 데이터'를 가장 먼저, 가장 깊게 쌓는다. 레시피 탐색부터 장보기까지 이어지는 행동 흐름 속에서 "
        "유저의 의도·취향·구매 맥락을 4개 축으로 나눠 하나의 데이터 체계로 축적한다.",
        s["body"],
    ))
    story.append(tbl(
        [
            ["USER · 누가·언제·왜", "CONTENT · 무엇을 보고 저장·요리하는가",
             "COMMERCE · 어떤 맥락에서 구매로 이어지는가", "AD · 어떤 상품이 누구에게 반응을 얻는가"],
            [
                "· 식사 목적(1인/가족/다이어트)\n· 요리 시간·빈도, 필요 인분\n· 생활 패턴·조리 성향",
                "· 저장하고 다시 찾는 레시피\n· 선호 메뉴·식단·재료·난이도\n· 콘텐츠 소비→실제 요리 전환",
                "· 발견 시점부터 장보기까지 전환\n· 함께 선택되는 재료·상품\n· 메뉴·상황·시점별 구매행동",
                "· 유저·콘텐츠·구매 맥락 결합 타겟팅\n· 상품별 노출·클릭·구매 반응\n· 신상품·프로모션 기획 지원",
            ],
        ],
        [45 * mm, 45 * mm, 46 * mm, 46 * mm],
        s,
    ))
    story.append(Spacer(1, 1 * mm))
    story.append(box(
        "핵심 포지셔닝",
        "요리GO 앱은 콘텐츠 소비·요리 의도·장보기 행동·광고 반응이 한 흐름 안에서 연결되는 푸드 버티컬 데이터 플랫폼이다. "
        "각 축의 원시 이벤트는 §5의 시그널 스키마 하나로 수집되고, 아래 보상표에 따라 취향 프로필·추천·인사이트로 전환된다.",
        s, ORG_BG, ORG,
    ))

    # 3 baseline
    story.append(Paragraph("3. 현재 트랙션 · 기술 베이스라인 (실측)", s["h1"]))
    story.append(Paragraph("3.1 Mixpanel (누적 유니크 유저)", s["h2"]))
    story.append(tbl(
        [
            ["지표", "값", "지표", "값"],
            ["가입(sign_up)", fmt(mp.get("total_unique_sign_ups")), "앱 최초 실행", fmt(mp.get("total_unique_app_first_open"))],
            ["파싱 완료", fmt(mp.get("total_unique_parse_completed")), "북마크", fmt(mp.get("total_unique_bookmarked"))],
            ["재료 구매체크", fmt(mp.get("total_unique_ingredient_checked")), "제휴 클릭", fmt(mp.get("total_unique_affiliate_click"))],
            ["장바구니 구매완료", fmt(mp.get("total_unique_purchase_completed")), "리뷰 작성", fmt(mp.get("total_unique_review"))],
            ["피크 DAU(가입)", fmt(mp.get("peak_dau_registered")), "피크 DAU(전체)", fmt(mp.get("peak_dau_screen_view"))],
            ["평균 DAU 30일(가입)", fmt(mp.get("avg_dau_registered_30d")), "평균 DAU 7일(가입)", fmt(mp.get("avg_dau_registered_7d"))],
            [
                "MAU(가입, 최신월)",
                f"{fmt(mp.get('mau_registered_latest_month'))}\n({mp.get('mau_registered_latest_month_key','')})",
                "MAU(전체화면, 최신월)",
                f"{fmt(mp.get('mau_screen_view_latest_month'))}\n({mp.get('mau_screen_view_latest_month_key','')})",
            ],
        ],
        [40 * mm, 51 * mm, 40 * mm, 51 * mm],
        s,
    ))
    story.append(Paragraph("3.2 Firestore (문서 수 · Monitoring)", s["h2"]))
    reads = mon.get("reads") or {}
    writes = mon.get("writes") or {}
    story.append(tbl(
        [
            ["지표", "값", "지표", "값"],
            ["users", fmt(fs.get("users_total")), "recipes(전체)", fmt(fs.get("recipes_total"))],
            ["recipes(completed)", fmt(fs.get("recipes_completed")), "completed+공개", fmt(fs.get("recipes_completed_visible"))],
            ["reviews", fmt(fs.get("reviews_total")), "일평균 읽기(7일)", f"{fmt(reads.get('avg_last7'))}건"],
            ["일평균 쓰기(7일)", f"{fmt(writes.get('avg_last7'))}건", "당일 읽기/쓰기", f"{fmt(reads.get('latest'))} / {fmt(writes.get('latest'))}"],
        ],
        [40 * mm, 51 * mm, 40 * mm, 51 * mm],
        s,
    ))
    story.append(Paragraph(
        "이미 있는 자산: 레시피 카테고리·태그·재료·canonicalDish, 저장/장바구니/냉장고/식단, "
        "홈 역색인(CF), 장바구니 RerankBandit(Thompson sampling). "
        "없는 것: 카드 노출 시그널, GCS/BigQuery 원천 자산, 취향 프로필 영구 저장, 벡터 DB.",
        s["body"],
    ))

    # 4 goals
    story.append(Paragraph("4. 6개월 목표 · 정량 KPI", s["h1"]))
    story.append(tbl(
        [
            ["영역", "현재", "6개월 후"],
            ["데이터", "Firestore+Mixpanel(관찰)", "Firestore(핫)+GCS/BigQuery(콜드 자산)"],
            ["추천", "규칙 홈+장바구니 밴딧", "개인화 홈+취향 사전계산 추천"],
            ["검색", "키워드 substring", "임베딩+벡터DB 의미 검색"],
            ["학습", "노출 계측 없음", "imp→cook/purchase 라벨 학습셋"],
        ],
        [28 * mm, 72 * mm, 82 * mm],
        s,
    ))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["KPI", "3개월", "6개월"],
            ["일일 웨어하우스 적재 성공률", "≥95%", "≥99%"],
            ["홈·검색 노출 계측 커버리지", "주요 화면 100%", "전 화면+자동검증"],
            ["활성유저 취향 프로필 커버리지", "최근30일 ≥50%", "≥70%"],
            ["개인화 섹션 vs 대조군 저장전환", "+5%p", "+15%p"],
            ["벡터 유사검색 P95", "≤500ms (MVP)", "≤200ms"],
            ["임베딩 레시피 커버리지", "≥80%", "≥95%"],
        ],
        [70 * mm, 56 * mm, 56 * mm],
        s,
    ))
    story.append(PageBreak())

    # 5 architecture
    story.append(Paragraph("5. 기술 아키텍처 (요약)", s["h1"]))
    story.append(Paragraph(
        "앱 SignalCollector → Firestore signal_batches(세션 배치) → 일일 Export → GCS JSONL.gz → "
        "BigQuery → 야간 프로필/추천 사전계산 → user_recs 1문서 서빙. "
        "벡터: text-embedding-3-small(256d) → <b>pgvector</b>(5개월 도입), 규모 확장 시 관리형 전환.",
        s["body"],
    ))
    story.append(tbl(
        [
            ["계층", "저장소", "역할"],
            ["핫", "Firestore (batches/profiles/recs/stats)", "수집 버퍼·실시간 서빙 (배치 35일 TTL)"],
            ["콜드", "GCS + BigQuery", "원천 자산·집계·학습셋 (영구)"],
            ["벡터", "pgvector (Cloud SQL)", "유사 레시피·의미 검색"],
            ["관찰", "Mixpanel", "DAU·퍼널·리텐션 (자산 본진 아님)"],
        ],
        [28 * mm, 70 * mm, 84 * mm],
        s,
    ))
    story.append(Paragraph(
        "설계 원칙: 세션 배치 쓰기 · 사전계산 읽기 · PII는 Firestore만(BQ는 HMAC subject_id) · "
        "성공 지표=요리완료+구매. 현재 DAU·쓰기 규모에서 추가 인프라비는 월 소액(배치 쓰기+소형 pgvector) 수준.",
        s["body"],
    ))
    story.append(Paragraph("5.1 시그널·보상 전체표 — 어떤 행동에 왜 이 점수를 주는가", s["h2"]))
    story.append(tbl(
        [
            ["신호", "행동/데이터 기준", "보상", "의미"],
            ["imp", "카드가 화면에 노출됨(섹션·포지션 로그)", "0.00", "학습 분모·negative sampling 전용(필수)"],
            ["click", "카드 클릭 → 상세 진입", "0.10", "관심 시작"],
            ["dwell", "상세 화면 20초 이상 체류", "0.20", "단순 클릭보다 신뢰도 높은 실질 관심"],
            ["step_scroll", "조리 단계(스텝)까지 스크롤", "0.25", "조리 의도 강화"],
            ["save", "북마크/저장", "0.60", "선호 확정"],
            ["cart_add", "장바구니에 재료·상품 추가", "0.70", "구매 의도 확정"],
            ["cook_start", "'요리 시작' 액션", "0.80", "실행 시작"],
            ["cook_done", "'요리 완료' 액션", "1.00", "성공 정의 ① 콘텐츠→실제 행동 전환"],
            ["purchase", "장바구니 구매 완료(결제)", "1.00", "성공 정의 ② 실제 지출 발생"],
            ["review", "요리 후 리뷰 작성", "1.00", "성공 정의 ③ 완료 후 피드백 도달"],
            ["skip", "노출됐지만 클릭 없이 지나침", "−0.05", "약한 무관심 신호"],
            ["unsave", "저장 취소", "−0.50", "선호 철회"],
            ["hide", "레시피/카테고리 숨기기", "−0.80", "명시적 비선호"],
            ["report", "신고", "−1.00", "강한 거부·품질 문제"],
        ],
        [22 * mm, 62 * mm, 16 * mm, 82 * mm],
        s,
    ))
    story.append(Paragraph(
        "원칙: 점수는 '클릭'이 아니라 <b>cook_done·purchase·review(=1.00)</b>에 몰려 있다. "
        "랭커·프로필이 이 정의를 학습 목표로 공유해야 클릭 최적화·필터버블로 흐르지 않는다.",
        s["body"],
    ))
    story.append(PageBreak())

    # 6 milestones
    story.append(Paragraph("6. 월별 마일스톤", s["h1"]))
    story.append(phase("Phase A · 1~3개월 · 기반 구축", "수집 → 웨어하우스 → 개인화 → 벡터 MVP", s, TEAL))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["월", "목표", "작업", "완료 기준"],
            ["1", "시그널 수집", "카드 imp·세션 배치·create-only rules·저장/식단/구매 이력 백필", "주요 화면 신호 누락 없이 적재"],
            ["2", "웨어하우스", "GCS/BQ 일일 적재·집계 테이블·동의·삭제 전파", "전일 데이터 익일 조회·삭제 반영"],
            ["3", "개인화+벡터", "취향 프로필·user_recs·개인화 홈 A/B·pgvector 유사 API", "홈 노출·유사요리 응답"],
        ],
        [12 * mm, 28 * mm, 88 * mm, 54 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(phase("Phase B · 4~6개월 · 고도화·가치화", "랭킹 정밀화 · 벡터 안정화 · 인사이트 자산", s, PURPLE))
    story.append(Spacer(1, 1.5 * mm))
    story.append(tbl(
        [
            ["월", "목표", "작업", "완료 기준"],
            ["4", "랭킹·A/B", "학습 랭커+밴딧 홈 확장·의미검색 확대", "저장/요리완료 대조군 대비 개선"],
            ["5", "벡터 정식화", "임베딩 자동갱신·유저 임베딩·수요 대시보드", "P95≤200ms, 주간 인사이트"],
            ["6", "자산 가치화", "전환·수요 리포트·익명 집계 템플릿·차기 로드맵", "주간 인사이트+외부 공유 가능 집계 1종"],
        ],
        [12 * mm, 28 * mm, 88 * mm, 54 * mm],
        s,
    ))

    # 7 eval risk feasibility
    story.append(Paragraph("7. 평가 · 리스크 · 실행 근거", s["h1"]))
    story.append(tbl(
        [
            ["항목", "내용"],
            ["평가", "오프라인 NDCG@10 → 온라인 A/B(CTR·저장·요리완료). 성공정의=cook_done+purchase (클릭 최적화 금지)"],
            ["리스크", "imp 지연=전체 정지(1M 게이트) · 동의/삭제 미비=자산화 불가(2M 필수) · 클릭편향 금지 · pgvector로 비용 통제 후 규모 시 관리형 전환"],
            [
                "실행 근거",
                f"실측: 가입 {fmt(mp.get('total_unique_sign_ups'))}·MAU {fmt(mp.get('mau_registered_latest_month'))}·"
                f"completed 레시피 {fmt(fs.get('recipes_completed'))}·일평균 읽기 ~{fmt(reads.get('avg_last7'))}. "
                "다중 플랫폼 파싱·밴딧 추천·CF 역색인·배치 스케줄러 운영 중 → 수집·웨어하우스·벡터는 확장이지 전면 교체가 아님.",
            ],
            ["충분성", "6개월에 수집·자산·서빙·벡터·A/B·인사이트까지 닫히는 최소 완결 루프. 실시간 스트리밍 처리는 6개월 이후로 명시적 이연."],
        ],
        [24 * mm, 158 * mm],
        s,
    ))
    story.append(Spacer(1, 2 * mm))
    story.append(box(
        "제출용 한 문단",
        "요리GO는 6개월간 행동 시그널 수집→BigQuery 웨어하우스→취향 기반 개인화→임베딩·pgvector 벡터 검색→"
        "추천 고도화·집계 인사이트 순으로 데이터·추천 플랫폼을 구축한다. "
        "목표는 분석 도구가 아니라, 요리 의도가 행동·구매로 이어지는 과정을 자산화하는 것이다. "
        f"(베이스라인 {as_of}: Mixpanel 가입 {fmt(mp.get('total_unique_sign_ups'))}명, "
        f"최신월 MAU {fmt(mp.get('mau_registered_latest_month'))}, Firestore completed 레시피 "
        f"{fmt(fs.get('recipes_completed'))}건.)",
        s,
    ))
    story.append(Paragraph(
        "상세 스키마·보상·API 계약은 내부 기술 문서. 본 문서는 D2SF 제출용 요약본.",
        s["meta"],
    ))
    return story


def main() -> None:
    s = S()
    doc = SimpleDocTemplate(
        str(PDF_OUT), pagesize=A4,
        leftMargin=12 * mm, rightMargin=12 * mm,
        topMargin=9 * mm, bottomMargin=11 * mm,
        title="요리GO 데이터·추천 플랫폼 마일스톤 (D2SF)",
        author="요리GO",
    )
    doc.build(build(s), onFirstPage=footer, onLaterPages=footer)
    DOWNLOADS.write_bytes(PDF_OUT.read_bytes())
    print(f"Wrote {PDF_OUT} / {DOWNLOADS}")


if __name__ == "__main__":
    main()
