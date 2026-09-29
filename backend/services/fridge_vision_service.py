"""
냉장고 사진/영수증 스캔 서비스

사용자가 촬영한 영수증 또는 냉장고/식재료 사진을 Gemini 멀티모달 비전 모델에
단일 호출로 전달해 구조화된 재료 목록(JSON)을 얻어냅니다.

설계 근거 (Phase 1 = 영수증 스캔):
- 영수증은 인쇄된 한국어 텍스트가 조밀하므로 "OCR → LLM 정규화" 2단계 대신
  Gemini 비전 1콜로 처리한다. Gemini의 한국어 OCR 품질은 이미 요리 영상
  프레임 텍스트 추출(llm_service.gemini_v2_extract_onscreen_text)에서
  프로덕션 검증되었으므로 별도 OCR 스택(RapidOCR)을 새로 튜닝할 필요가 없다.
- 응답은 response_mime_type="application/json"으로 강제해 마크다운 펜스/
  잡담 섞임 문제를 원천적으로 줄인다.
- 6개 재료 카테고리 taxonomy는 llm_service.py의 레시피 파싱 프롬프트와
  동일한 규칙을 사용해 프론트 IngredientCategoryUnifier와 분류가 어긋나지
  않게 한다.
"""

import io
import json
import os
import re
import time
from datetime import date
from typing import Any, Dict, List, Optional, Tuple

from google import genai
from google.genai import types

from models import FridgeScanItem, FridgeScanResponse

# llm_service.py의 6-카테고리 분류 규칙과 동일하게 유지 (카테고리 드리프트 방지).
_CATEGORY_TAXONOMY_BLOCK = """
카테고리(category)는 반드시 아래 6개 중 하나를 사용하세요. 재료가 "무엇으로
만들어졌는지"가 아니라 "요리에서 어떤 역할을 하는지"로 분류합니다.

1. vegetables_fruits: 신선 채소·과일·향신재료(마늘, 다진마늘, 생강, 대파 포함)·
   버섯·두부류(두부, 순두부, 연두부, 유부, 부침두부)
2. meat_processed_egg: 정육·가공육 (돼지고기, 소고기, 닭고기, 베이컨, 햄, 소시지,
   스팸, 어묵, 맛살). 계란/두부는 여기 아님.
3. seafood: 생선·조개·새우·오징어 등 수산물, 건어물, 다시마·미역 (생물/원물).
   소스류(굴소스, 액젓)는 여기 아님.
4. dairy: 유제품(우유, 치즈, 버터, 요거트, 생크림) + 모든 계란류(계란, 달걀,
   메추리알).
5. grains: 쌀·면·파스타·떡·밀가루·빵.
6. seasonings_sauces: 간장·된장·고추장·식용유·식초·소금·후추·설탕·액젓·굴소스·
   김/김가루(조미김 포함)처럼 요리를 "맛내는" 데 쓰이는 모든 것.

CRITICAL:
- 마늘/다진마늘/생강/대파 → 항상 vegetables_fruits
- 두부/순두부/유부 → 항상 vegetables_fruits (meat_processed_egg 아님)
- 계란/달걀/메추리알 → 항상 dairy (meat_processed_egg 아님)
- 굴소스/멸치액젓/조미김/김가루 → 항상 seasonings_sauces (seafood 아님)
"""

_VALID_CATEGORIES = {
    "vegetables_fruits",
    "meat_processed_egg",
    "seafood",
    "dairy",
    "grains",
    "seasonings_sauces",
}

_RECEIPT_PROMPT = (
    _CATEGORY_TAXONOMY_BLOCK
    + """
당신은 한국 마트/편의점 영수증 이미지를 읽고 "식재료 구매 목록"을 구조화하는
비전 모델입니다.

작업 순서:
1. 영수증의 각 줄을 읽고 "식재료"로 볼 수 있는 라인만 추출하세요.
2. 의미 정규화는 당신이 수행하세요. (후처리는 P접두·용량 등 잡음 제거만 합니다.)
   마트 줄임말/브랜드 상품명을 냉장고에 넣을 식재료 일반명으로 바꾸세요.
   예: "돈삼겹500" → name="삼겹살", qty=500, unit="g"
       "무항생제계란" / "풀무원 통통 신선란" → name="계란"
       "자연실록 12호" → name="닭고기"  (자연실록=하림 닭고기, 계란 아님)
       "굿모닝우유 900ML" / "서울우유 1L" → name="우유"
       "동원참치" → name="참치"
       "고추장"은 name="고추장" (고추로 줄이지 마세요)
       "배추김치"는 name="김치" (배추로 줄이지 마세요)
3. 다음은 반드시 제외하거나, 불가피하게 읽혔다면 items에 넣되 is_food=false 로 두세요:
   - 카드 승인/할부 정보, 포인트 적립/사용, 봉투·비닐값
   - 합계/부가세/거스름돈 등 결제 메타 라인 (상품명에 "할인"이 들어간 식재료는 포함)
   - 비식품(세제, 휴지, 생활용품, 담배, 잡지, 건전지, 샴푸 등)
   가능하면 비식품·메타 라인은 items에 넣지 마세요.
4. 수량/무게가 영수증에 표기돼 있으면 그대로 사용하고, 표기가 없으면
   qty=1, unit="개"로 두세요. 가격을 수량으로 착각하지 마세요.
5. price에는 해당 라인에 실제로 결제된 금액(원)을 숫자로 넣으세요. 영수증에
   금액이 없거나 읽을 수 없으면 null로 두세요.
6. raw_line에는 해당 항목의 영수증 원문 텍스트를 최대한 그대로 넣어 사용자가
   원문과 대조할 수 있게 하세요.
7. 글자가 흐리거나 품명이 불확실하면 confidence를 낮게 주세요. 확신이 없는
   항목을 억지로 추가하지 마세요 (개수를 부풀리지 마세요).
8. store_name에는 영수증 상단에 인쇄된 매장 상호명만 넣으세요.
   예: "농협", "이마트", "홈플러스". 확실하지 않으면 null.
9. store_branch에는 지점명만 넣으세요 (상호명과 분리).
   예: "신도림점", "의정부농협". 지점이 없으면 null.
10. store_address에는 영수증에 인쇄된 **매장 사업장 주소**를 넣으세요.
    도로명·지번이 보이면 가능한 한 그대로(시/도·시군구·도로명/동·번지).
    주소가 없거나 불확실하면 null.
11. region_sido / region_sigungu에는 주소에서 뽑은 행정구역만 넣으세요.
    예: region_sido="경기도", region_sigungu="의정부시"
    주소가 "경기 의정부시 …"처럼 축약돼 있어도 표준형으로 풀어 쓰세요
    (경기→경기도, 서울→서울특별시, 부산→부산광역시 등).
12. purchased_at에는 영수증에 인쇄된 구매 날짜를 "YYYY-MM-DD" 형식으로 넣으세요
    (시간은 제외). 날짜가 없거나 불확실하면 null로 두세요.
13. 영수증에서 식재료를 하나도 찾지 못했다면 items를 빈 배열로 반환하세요.

민감정보 절대 금지 (매우 중요):
- 카드번호(마스킹 포함), 승인번호, 포인트/멤버십 번호, 고객 이름,
  직원/캐셔 이름, 개인 휴대전화(010 등)는 어떤 필드에도 넣지 마세요.
- 매장 유선전화·사업자등록번호도 저장하지 마세요 (매칭은 주소로 합니다).
- store_name / store_branch / store_address / region_* 에는 위 금지 정보를
  섞지 말고, 매장 위치 식별에 필요한 상호·지점·주소·행정구역만 넣으세요.
- raw_line에는 품명 원문만 넣고 카드/전화/멤버십 줄을 넣지 마세요.

출력 형식 (JSON 객체 1개, 다른 설명·마크다운·주석 절대 금지):
{
  "store_name": str|null,
  "store_branch": str|null,
  "store_address": str|null,
  "region_sido": str|null,
  "region_sigungu": str|null,
  "purchased_at": str|null,
  "items": [
    {"name": str, "category": str, "qty": number, "unit": str,
     "confidence": number(0~1), "raw_line": str, "price": number|null,
     "is_food": bool}
  ]
}
"""
)

# Phase 2(냉장고/식재료 사진 인식)용 프롬프트. 아직 프론트에는 노출하지 않지만
# 백엔드 계약을 미리 완성해 둔다 (photo_type="fridge_interior").
_FRIDGE_INTERIOR_PROMPT = (
    _CATEGORY_TAXONOMY_BLOCK
    + """
당신은 한국 가정의 냉장고 내부 또는 식재료 사진을 보고 식재료를 인식하는
비전 모델입니다.

작업:
1. 사진에서 식별 가능한 "식재료"만 나열하세요. 그릇, 용기, 포장재, 브랜드
   로고 자체는 무시하고 그 안의 식재료만 인식하세요.
2. name은 브랜드명이 아닌 한국어 일반명으로 쓰세요.
   예: "서울우유 1L" → name="우유"
3. qty/unit은 눈으로 추정한 값입니다. 정확한 무게를 알 수 없으면 qty=1,
   unit="개"로 두고 confidence를 낮추세요. 포장에 가려 일부만 보이는
   경우에도 confidence를 낮추세요.
4. 같은 식재료가 여러 개 겹쳐 보이면 하나의 항목으로 합치고 qty로 개수를
   표현하세요.
5. 확실히 식재료가 아닌 것(그릭요거트 뚜껑, 빈 병, 조미료 짜개 등 쓰레기)은
   포함하지 마세요.

각 항목의 형식:
{"name": str, "category": str, "qty": number, "unit": str,
 "confidence": number(0~1)}

JSON 배열만 반환하세요. 다른 설명, 마크다운, 주석은 절대 포함하지 마세요.
"""
)

_PROMPTS_BY_TYPE = {
    "receipt": _RECEIPT_PROMPT,
    "fridge_interior": _FRIDGE_INTERIOR_PROMPT,
}

# 프롬프트로 카드번호/전화번호/사업자번호 등을 제외하라고 지시하지만, LLM 출력을
# 100% 신뢰할 수 없으므로 저장 직전 한 번 더 방어적으로 걸러낸다(2차 방어선).
# store_name/raw_line처럼 자유 텍스트가 들어가는 필드에만 적용한다.
_PII_PATTERNS = (
    re.compile(r"\d{2,4}[-\s]?\d{3,4}[-\s]?\d{4}"),  # 전화번호류(010-1234-5678 등)
    re.compile(r"\d[\d\-\*\s]{9,}\d"),  # 마스킹 카드번호("1234-56**-****-7890") 등
    re.compile(r"\d{10,}"),  # 사업자등록번호/승인번호 등 10자리+ 연속 숫자
)


def _contains_pii(text: str) -> bool:
    return any(p.search(text) for p in _PII_PATTERNS)


# ---------------------------------------------------------------------------
# 후처리: 의미 정규화는 비전 AI에 맡기고, 여기선 기계적 정리 + 비식품 휴리스틱만.
# (contains 기반 동의어표는 고추장→고추 같은 과교정을 만들므로 쓰지 않는다.)
# ---------------------------------------------------------------------------

_KNOWN_BRAND_PREFIXES = (
    "풀무원",
    "서울우유",
    "매일유업",
    "매일",
    "남양유업",
    "남양",
    "빙그레",
    "동원",
    "오뚜기",
    "청정원",
    "샘표",
    "대상",
    "CJ",
    "cj",
    "비비고",
    "햇반",
    "농심",
    "삼양",
    "팔도",
    "하림",
    "목우촌",
    "롯데",
    "오리온",
    "해태",
    "크라운",
    "사조",
    "사조대림",
    "대림",
    "한성",
    "종가집",
    "이마트",
    "노브랜드",
    "피코크",
    "트레이더스",
    "홈플러스",
    "쿠팡",
    "곰표",
    "굿모닝",
    "하선정",
)

# 생활용품 등 — 품명/원문에 있으면 비식품.
_NON_FOOD_PRODUCT_KEYWORDS = (
    "세제",
    "세탁",
    "섬유유연",
    "표백",
    "락스",
    "클리너",
    "세정제",
    "주방세제",
    "설거지",
    "휴지",
    "화장지",
    "물티슈",
    "키친타올",
    "키친타월",
    "키친타워",
    "비닐봉투",
    "쓰레기봉투",
    "종량제",
    "쿠킹랩",
    "위생랩",
    "식품랩",
    "호일",
    "호일지",
    "알루미늄호일",
    "건전지",
    "배터리",
    "샴푸",
    "린스",
    "컨디셔너",
    "바디워시",
    "바디로션",
    "치약",
    "칫솔",
    "비누",
    "방향제",
    "탈취제",
    "살충제",
    "담배",
    "라이터",
    "잡지",
    "신문",
    "문구",
    "볼펜",
    "테이프",
    "고무장갑",
    "수세미",
    "행주",
    "스펀지",
    "생리대",
    "기저귀",
    "반창고",
    "밴드에이드",
    "마스크팩",
    "화장품",
    "로션",
    "크림팩",
)

# 영수증 메타 줄. 품명 자체에만 적용 ("할인삼겹살" 오탐 방지).
_RECEIPT_META_MARKERS = (
    "합계",
    "총액",
    "부가세",
    "거스름돈",
    "거스름",
    "카드승인",
    "할부",
    "봉사료",
    "배달팁",
    "배송비",
    "과세물품",
    "면세물품",
    "받을금액",
    "받은금액",
    "포인트사용",
    "포인트적립",
    "할인금액",
)

_SIZE_SUFFIX_RE = re.compile(
    r"[\d.,]+\s*(kg|g|ml|l|L|입|개입|팩|봉|매|장|병|캔|포|구)?$",
    re.IGNORECASE,
)

# "001 P 양파 ." / "P굿모닝우유" 같은 영수증 잡음
_LEADING_LINE_NOISE_RE = re.compile(r"^(?:\d{1,3}\s*)?P\s*", re.IGNORECASE)


def _compact_ko(text: str) -> str:
    return re.sub(r"\s+", "", (text or "").strip())


def _strip_receipt_noise(name: str) -> str:
    s = re.sub(r"\s+", " ", (name or "").strip())
    if not s:
        return s
    s = _LEADING_LINE_NOISE_RE.sub("", s)
    s = re.sub(r"[.]+$", "", s).strip()
    return s.strip(" -_/·")


def _strip_brand_and_size(name: str) -> str:
    s = _strip_receipt_noise(name)
    if not s:
        return s
    changed = True
    while changed:
        changed = False
        for brand in _KNOWN_BRAND_PREFIXES:
            if s.startswith(brand):
                s = s[len(brand) :].lstrip(" -_/·")
                changed = True
                break
    s = _SIZE_SUFFIX_RE.sub("", s).strip(" -_/·")
    for fluff in ("통통", "신선한", "무항생제", "유기농", "친환경", "프리미엄"):
        s = s.replace(fluff, "")
    cleaned = re.sub(r"\s+", " ", s).strip(" -_/·")
    return cleaned or _strip_receipt_noise(name)


def normalize_receipt_ingredient_name(
    name: str, raw_line: Optional[str] = None
) -> str:
    """AI가 준 품명을 기계적으로만 정리한다. 의미 변환은 하지 않는다.

    예: 'P굿모닝우유 900ML' → '우유' (브랜드·용량 제거 후 카탈로그 매칭용)
    raw_line은 호환을 위해 받지만 의미 추론에는 쓰지 않는다.
    """
    _ = raw_line  # 의미 보정에 쓰지 않음 (카탈로그 매처가 별도 참고)
    original = (name or "").strip()
    if not original:
        return original
    stripped = _strip_brand_and_size(original)
    out = stripped or _strip_receipt_noise(original) or original
    return out[:60]


def _looks_like_receipt_meta_line(compact_name: str) -> bool:
    if not compact_name:
        return False
    for kw in _RECEIPT_META_MARKERS:
        if compact_name == kw:
            return True
        if compact_name.startswith(kw) and len(compact_name) <= len(kw) + 4:
            return True
    return False


def is_likely_food_ingredient(name: str, raw_line: Optional[str] = None) -> bool:
    """휴리스틱으로 식재료 여부를 판별. False면 프론트에서 회색/비선택."""
    name_compact = _compact_ko(name)
    if not name_compact:
        return False
    if _looks_like_receipt_meta_line(name_compact):
        return False
    hay = name_compact
    if raw_line:
        hay += _compact_ko(str(raw_line))
    for kw in _NON_FOOD_PRODUCT_KEYWORDS:
        if kw in hay:
            return False
    return True

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _parse_store_name(data: Any) -> Optional[str]:
    if not isinstance(data, dict):
        return None
    raw = data.get("store_name")
    if not raw:
        return None
    s = str(raw).strip()
    if not s or _contains_pii(s):
        return None
    return s[:40]


def _parse_store_branch(data: Any) -> Optional[str]:
    if not isinstance(data, dict):
        return None
    raw = data.get("store_branch")
    if not raw:
        return None
    s = str(raw).strip()
    if not s or _contains_pii(s):
        return None
    return s[:40]


def _scrub_store_address(text: str) -> Optional[str]:
    """매장 주소만 남기고 전화·카드류 토큰은 제거한다."""
    s = str(text or "").strip()
    if not s:
        return None
    # 주소 줄에 전화가 붙는 경우가 많아 번호 토큰만 제거 후 재검사.
    s = re.sub(r"\d{2,4}[-\s]?\d{3,4}[-\s]?\d{4}", " ", s)
    s = re.sub(r"\d[\d\-\*\s]{9,}\d", " ", s)
    s = re.sub(r"\s+", " ", s).strip(" ,/")
    if not s or _contains_pii(s):
        return None
    # 한글/숫자/기본 주소 기호만 허용 (너무 짧은 잡음 거부).
    if len(re.sub(r"\s+", "", s)) < 4:
        return None
    return s[:120]


def _parse_store_address(data: Any) -> Optional[str]:
    if not isinstance(data, dict):
        return None
    return _scrub_store_address(str(data.get("store_address") or ""))


def _normalize_sido(raw: str) -> Optional[str]:
    s = re.sub(r"\s+", "", str(raw or "").strip())
    if not s:
        return None
    aliases = {
        "서울": "서울특별시",
        "서울시": "서울특별시",
        "서울특별시": "서울특별시",
        "부산": "부산광역시",
        "부산시": "부산광역시",
        "부산광역시": "부산광역시",
        "대구": "대구광역시",
        "대구시": "대구광역시",
        "대구광역시": "대구광역시",
        "인천": "인천광역시",
        "인천시": "인천광역시",
        "인천광역시": "인천광역시",
        "광주": "광주광역시",
        "광주시": "광주광역시",
        "광주광역시": "광주광역시",
        "대전": "대전광역시",
        "대전시": "대전광역시",
        "대전광역시": "대전광역시",
        "울산": "울산광역시",
        "울산시": "울산광역시",
        "울산광역시": "울산광역시",
        "세종": "세종특별자치시",
        "세종시": "세종특별자치시",
        "세종특별자치시": "세종특별자치시",
        "경기": "경기도",
        "경기도": "경기도",
        "강원": "강원특별자치도",
        "강원도": "강원특별자치도",
        "강원특별자치도": "강원특별자치도",
        "충북": "충청북도",
        "충청북도": "충청북도",
        "충남": "충청남도",
        "충청남도": "충청남도",
        "전북": "전북특별자치도",
        "전라북도": "전북특별자치도",
        "전북특별자치도": "전북특별자치도",
        "전남": "전라남도",
        "전라남도": "전라남도",
        "경북": "경상북도",
        "경상북도": "경상북도",
        "경남": "경상남도",
        "경상남도": "경상남도",
        "제주": "제주특별자치도",
        "제주도": "제주특별자치도",
        "제주특별자치도": "제주특별자치도",
    }
    return aliases.get(s)


def _parse_region_sido(data: Any) -> Optional[str]:
    if not isinstance(data, dict):
        return None
    raw = data.get("region_sido")
    if not raw:
        return None
    s = str(raw).strip()
    if not s or _contains_pii(s):
        return None
    return _normalize_sido(s) or (s[:20] if len(s) <= 20 else None)


def _parse_region_sigungu(data: Any) -> Optional[str]:
    if not isinstance(data, dict):
        return None
    raw = data.get("region_sigungu")
    if not raw:
        return None
    s = re.sub(r"\s+", "", str(raw).strip())
    if not s or _contains_pii(s):
        return None
    # 시/군/구로 끝나는 값만 신뢰.
    if not re.search(r"(시|군|구)$", s):
        return None
    return s[:20]


def build_store_match_query(
    *,
    store_name: Optional[str],
    store_branch: Optional[str],
    store_address: Optional[str],
    region_sido: Optional[str],
    region_sigungu: Optional[str],
) -> Optional[str]:
    """나중에 장소 API에 넣을 검색 쿼리 문자열을 조립한다 (호출은 하지 않음)."""
    parts: List[str] = []
    if store_name:
        parts.append(store_name)
    if store_branch and store_branch not in (store_name or ""):
        parts.append(store_branch)
    if store_address:
        parts.append(store_address)
    else:
        region = " ".join(p for p in (region_sido, region_sigungu) if p)
        if region:
            parts.append(region)
    query = " ".join(parts).strip()
    return query[:160] if query else None


def _parse_purchased_at(data: Any) -> Optional[str]:
    """YYYY-MM-DD 형식만 신뢰하고, 미래 날짜 등 모델 환각으로 보이는 값은 버린다."""
    if not isinstance(data, dict):
        return None
    raw = data.get("purchased_at")
    if not raw:
        return None
    s = str(raw).strip()
    if not _DATE_RE.match(s):
        return None
    try:
        y, m, d = (int(part) for part in s.split("-"))
        parsed = date(y, m, d)
    except ValueError:
        return None
    if parsed > date.today():
        return None
    return s


_MAX_ITEMS = int(os.getenv("FRIDGE_SCAN_MAX_ITEMS", "40"))
_MAX_IMAGE_DIMENSION = int(os.getenv("FRIDGE_SCAN_MAX_IMAGE_DIMENSION", "1600"))
# 사용자가 화면 앞에서 기다리는 동기 호출이라 재시도 총 지연을 짧게 유지한다
# (기본 1회 재시도 = 최대 2회 호출). 프론트의 요청 타임아웃과 맞춰서 조정할 것.
_MAX_RETRIES = int(os.getenv("FRIDGE_SCAN_MAX_RETRIES", "1"))


class FridgeVisionService:
    """냉장고/영수증 사진 → 구조화된 재료 목록 서비스."""

    def __init__(self) -> None:
        # gemini-2.5-flash-lite로 교체하면 지연/비용이 ~3배 줄지만(실측 4.7s vs
        # 12~17s, out 토큰도 절반), 실제 영수증 2장으로 비교한 결과 브랜드명→
        # 정규화 실패("동원참치"를 그대로 반환, "자연실록"을 닭고기로 정규화 못함),
        # 카테고리 규칙 위반(어묵→seafood로 오분류, 정답은 meat_processed_egg),
        # 비식품 항목 환각(다이소 영수증에서 "마스킹테이프"를 식재료로 생성)이
        # 발생해 채택하지 않음. 속도/비용보다 신뢰도가 우선이라 flash를 유지한다.
        self._model = os.getenv(
            "FRIDGE_SCAN_GEMINI_MODEL", os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
        )
        self._last_usage_tokens: Tuple[int, int, int] = (0, 0, 0)
        self._client: Optional["genai.Client"] = None

    @property
    def last_usage_tokens(self) -> Tuple[int, int, int]:
        """가장 최근 analyze_photo 호출의 (input, output, thinking) 토큰 수."""
        return self._last_usage_tokens

    def _get_gemini_client(self) -> "genai.Client":
        # FridgeVisionService 자체가 프로세스 전역 싱글톤(get_fridge_vision_service)
        # 이므로 genai.Client도 요청마다 새로 만들지 않고 1회만 생성해 재사용한다.
        if self._client is not None:
            return self._client
        key = os.getenv("GEMINI_API_KEY")
        if not key:
            raise ValueError("GEMINI_API_KEY not found in environment")
        # 사진 1장짜리 단일 콜이라 영상 파이프라인보다 훨씬 짧은 타임아웃으로 충분.
        timeout_ms = int(os.getenv("FRIDGE_SCAN_HTTP_TIMEOUT_SECONDS", "60")) * 1000
        self._client = genai.Client(api_key=key, http_options={"timeout": timeout_ms})
        return self._client

    @staticmethod
    def _downscale_image(image_bytes: bytes) -> bytes:
        """토큰비/속도를 위해 긴 변 기준 _MAX_IMAGE_DIMENSION으로 축소하고
        JPEG로 재인코딩한다. 실패하면 원본을 그대로 반환한다."""
        try:
            from PIL import Image
        except ImportError:
            return image_bytes

        try:
            img = Image.open(io.BytesIO(image_bytes))
            img = img.convert("RGB")
        except Exception:
            return image_bytes

        w, h = img.size
        if max(w, h) > _MAX_IMAGE_DIMENSION:
            scale = _MAX_IMAGE_DIMENSION / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

        try:
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=88)
            return buf.getvalue()
        except Exception:
            return image_bytes

    @staticmethod
    def _extract_gemini_usage(resp: Any) -> Tuple[int, int, int]:
        um = getattr(resp, "usage_metadata", None)
        if um is None:
            return 0, 0, 0
        inp = int(getattr(um, "prompt_token_count", None) or 0)
        out = int(getattr(um, "candidates_token_count", None) or 0)
        think = int(getattr(um, "thoughts_token_count", None) or 0)
        return inp, out, think

    @staticmethod
    def _strip_md_fences(text: str) -> str:
        s = text.strip()
        if s.startswith("```"):
            nl = s.find("\n")
            s = s[nl + 1 :] if nl != -1 else s[3:]
            if s.rstrip().endswith("```"):
                s = s.rstrip()[:-3].rstrip()
        return s

    def _parse_items(self, data: Any) -> List[FridgeScanItem]:
        if isinstance(data, dict):
            raw_items = data.get("items")
        else:
            raw_items = data
        if not isinstance(raw_items, list):
            return []

        parsed: List[FridgeScanItem] = []
        for raw in raw_items[:_MAX_ITEMS]:
            if not isinstance(raw, dict):
                continue
            name = str(raw.get("name") or "").strip()
            if not name:
                continue

            raw_line = raw.get("raw_line")
            raw_line_str = str(raw_line).strip()[:200] if raw_line else None
            # 2차 방어선: raw_line에 카드번호/전화번호류가 섞여 나오면 통째로 버린다.
            if raw_line_str and _contains_pii(raw_line_str):
                raw_line_str = None

            name = normalize_receipt_ingredient_name(name, raw_line_str)

            is_food_raw = raw.get("is_food")
            if isinstance(is_food_raw, bool):
                is_food = is_food_raw and is_likely_food_ingredient(
                    name, raw_line_str
                )
            else:
                is_food = is_likely_food_ingredient(name, raw_line_str)

            category = str(raw.get("category") or "").strip()
            if category not in _VALID_CATEGORIES:
                category = "seasonings_sauces"
            # 계란류는 taxonomy상 항상 dairy
            if name in ("계란", "달걀", "메추리알"):
                category = "dairy"

            try:
                qty = float(raw.get("qty"))
            except (TypeError, ValueError):
                qty = 1.0
            if qty <= 0:
                qty = 1.0

            unit = str(raw.get("unit") or "개").strip() or "개"

            try:
                confidence = float(raw.get("confidence"))
            except (TypeError, ValueError):
                confidence = 0.5
            confidence = max(0.0, min(1.0, confidence))

            price: Optional[int] = None
            price_raw = raw.get("price")
            if price_raw is not None:
                try:
                    price_val = round(float(price_raw))
                    # 0원/음수/비정상적으로 큰 값(모델 환각)은 버린다.
                    if 0 < price_val <= 10_000_000:
                        price = int(price_val)
                except (TypeError, ValueError):
                    price = None

            parsed.append(
                FridgeScanItem(
                    name=name[:60],
                    category=category,
                    qty=qty,
                    unit=unit[:20],
                    confidence=confidence,
                    raw_line=raw_line_str or None,
                    price=price,
                    is_food=is_food,
                )
            )
        return parsed

    def analyze_photo(self, image_bytes: bytes, photo_type: str) -> FridgeScanResponse:
        """사진 1장을 분석해 구조화된 재료 목록을 반환한다.

        실패해도 예외를 던지지 않고 warning이 채워진 빈 결과를 반환한다 —
        호출자(라우터)는 이를 그대로 프론트에 전달해 수동 추가로 자연스럽게
        디그레이드시킨다.
        """
        prompt = _PROMPTS_BY_TYPE.get(photo_type)
        if prompt is None:
            raise ValueError(f"invalid photo_type: {photo_type!r}")

        resized = self._downscale_image(image_bytes)

        try:
            client = self._get_gemini_client()
        except Exception as e:
            print(f"[FridgeVisionService] Gemini client unavailable: {e}", flush=True)
            return FridgeScanResponse(
                photo_type=photo_type,
                items=[],
                warning="지금은 사진 인식을 사용할 수 없어요. 직접 추가해주세요.",
            )

        parts = [
            types.Part.from_text(text=prompt),
            types.Part.from_bytes(data=resized, mime_type="image/jpeg"),
        ]

        # 단순 추출/분류 작업이라 다단계 추론이 필요 없음 — thinking을 꺼서
        # 지연/출력토큰 낭비를 방지한다 (llm_service.py와 동일한 관례).
        # 일부 google-genai SDK 버전엔 ThinkingConfig가 없어 방어적으로 체크.
        config_kwargs: Dict[str, Any] = {
            "response_mime_type": "application/json",
            "temperature": 0.1,
        }
        if hasattr(types, "ThinkingConfig"):
            config_kwargs["thinking_config"] = types.ThinkingConfig(
                thinking_budget=0
            )

        last_err: Optional[Exception] = None
        for attempt in range(_MAX_RETRIES + 1):
            try:
                resp = client.models.generate_content(
                    model=self._model,
                    contents=[types.Content(role="user", parts=parts)],
                    config=types.GenerateContentConfig(**config_kwargs),
                )
                self._last_usage_tokens = self._extract_gemini_usage(resp)
                raw = (getattr(resp, "text", None) or "").strip()
                if not raw:
                    raise ValueError("Empty response from Gemini")
                cleaned = self._strip_md_fences(raw)
                data = json.loads(cleaned)
                items = self._parse_items(data)
                store_name = None
                store_branch = None
                store_address = None
                region_sido = None
                region_sigungu = None
                purchased_at = None
                if photo_type == "receipt":
                    store_name = _parse_store_name(data)
                    store_branch = _parse_store_branch(data)
                    store_address = _parse_store_address(data)
                    region_sido = _parse_region_sido(data)
                    region_sigungu = _parse_region_sigungu(data)
                    purchased_at = _parse_purchased_at(data)
                    # 행정구역이 비었는데 주소가 있으면 주소 앞부분에서 보조 추출.
                    if store_address and (not region_sido or not region_sigungu):
                        sido_m = re.match(
                            r"^\s*([가-힣]+(?:특별시|광역시|특별자치시|특별자치도|도)?)",
                            store_address,
                        )
                        if sido_m and not region_sido:
                            region_sido = _normalize_sido(sido_m.group(1))
                        sigungu_m = re.search(
                            r"([가-힣]+(?:시|군|구))",
                            store_address,
                        )
                        if sigungu_m and not region_sigungu:
                            # 시/도 명칭에 붙은 '시'와 혼동되지 않게 시군구만.
                            cand = sigungu_m.group(1)
                            if cand not in {
                                "서울특별시",
                                "세종특별자치시",
                                "광역시",
                            } and not cand.endswith("도"):
                                region_sigungu = cand
                print(
                    f"[FridgeVisionService] analyze_photo({photo_type}) -> "
                    f"{len(items)} items (attempt {attempt + 1})",
                    flush=True,
                )
                return FridgeScanResponse(
                    photo_type=photo_type,
                    items=items,
                    store_name=store_name,
                    store_branch=store_branch,
                    store_address=store_address,
                    region_sido=region_sido,
                    region_sigungu=region_sigungu,
                    purchased_at=purchased_at,
                )
            except Exception as e:
                last_err = e
                if attempt < _MAX_RETRIES:
                    time.sleep(1.0 * (attempt + 1))
                    continue
                break

        print(
            f"[FridgeVisionService] analyze_photo({photo_type}) failed after "
            f"{_MAX_RETRIES + 1} attempts: {last_err}",
            flush=True,
        )
        return FridgeScanResponse(
            photo_type=photo_type,
            items=[],
            warning="사진에서 재료를 인식하지 못했어요. 직접 추가해주세요.",
        )


_fridge_vision_service: Optional[FridgeVisionService] = None


def get_fridge_vision_service() -> FridgeVisionService:
    """싱글톤 FridgeVisionService 인스턴스를 반환한다."""
    global _fridge_vision_service
    if _fridge_vision_service is None:
        _fridge_vision_service = FridgeVisionService()
    return _fridge_vision_service
