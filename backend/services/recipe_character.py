"""카드 칩·한줄소개·상황 태그 가드.

RecipeService 믹스인. 영양 추정은 다루지 않고, 이미 계산된 nutrition을 칩 가드에만 읽는다.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait as futures_wait
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

_ENRICH_SEM: Optional[threading.Semaphore] = None
_ENRICH_POOL: Optional[ThreadPoolExecutor] = None
_ENRICH_SEM_LOCK = threading.Lock()
_PLACEHOLDER_TITLES = {"", "레시피", "분석 중..", "분석 중...", "분석중..", "분석중"}


def salvage_character_payload(text: str) -> Dict[str, Any]:
    """JSON이 깨져도 tags/tagline만이라도 건진다. 가드는 pad가 채운다."""
    raw = text or ""
    tags: List[str] = []
    m = re.search(r'"tags"\s*:\s*\[(.*?)\]', raw, re.S)
    if m:
        tags = [t for t in re.findall(r'"([^"\\]{1,12})"', m.group(1)) if t]
    occ: List[str] = []
    om = re.search(r'"occasion_tags"\s*:\s*\[(.*?)\]', raw, re.S)
    if om:
        occ = [t for t in re.findall(r'"([^"\\]{1,16})"', om.group(1)) if t]
    tm = re.search(r'"tagline"\s*:\s*"([^"]{0,80})"', raw)
    return {
        "tagline": (tm.group(1) if tm else "").strip(),
        "mentioned_products": [],
        "tags": tags[:6],
        "tag_evidence": [],
        "occasion_tags": occ[:6],
        "nutrition_rating": "A",
    }


def _enrich_semaphore() -> threading.Semaphore:
    global _ENRICH_SEM
    with _ENRICH_SEM_LOCK:
        if _ENRICH_SEM is None:
            limit = max(1, int(os.getenv("TAG_ENRICH_MAX_CONCURRENT", "8")))
            _ENRICH_SEM = threading.Semaphore(limit)
        return _ENRICH_SEM


def _enrich_pool() -> ThreadPoolExecutor:
    """칩/한줄 HTTP 전용 풀. 파싱 blocking_pool 과 분리해 데드락을 피한다."""
    global _ENRICH_POOL
    with _ENRICH_SEM_LOCK:
        if _ENRICH_POOL is None:
            workers = max(2, int(os.getenv("TAG_ENRICH_MAX_CONCURRENT", "8")) * 2)
            _ENRICH_POOL = ThreadPoolExecutor(
                max_workers=workers,
                thread_name_prefix="tag-enrich",
            )
        return _ENRICH_POOL


def _character_enrich_enabled() -> bool:
    return os.getenv("TAG_CHARACTER_ENRICH", "1").strip().lower() not in {"0", "false", "no", "off"}


def _recipe_has_character_source(
    recipe: Dict[str, Any],
    title: str,
    description: str,
    transcript: str,
) -> bool:
    """빈 껍데기·실패 문서에 LLM을 쓰지 않는다."""
    rec = recipe or {}
    ings = rec.get("ingredients") if isinstance(rec.get("ingredients"), list) else []
    steps = rec.get("steps") if isinstance(rec.get("steps"), list) else []
    if ings or steps:
        return True
    name = str(rec.get("name") or title or "").strip()
    if name and name not in _PLACEHOLDER_TITLES:
        return True
    if (description or "").strip() or (transcript or "").strip():
        return True
    return False


class RecipeCharacterMixin:
    """칩/원라이너/상황 태그 정규화와 전용 LLM 호출."""

    TAG_PIPELINE_VERSION = "chips_v2"

    TAG_FORMAT = {
        "원팬", "에어프라이어", "전자레인지", "오븐", "밥솥", "압력솥",
        "초간편", "10분컷", "노밀가루",
    }
    TAG_GOAL = {
        "다이어트", "저칼로리", "고단백", "저당식", "무설탕", "키토", "저탄수",
        "비건식", "저염", "저지방", "헬식", "가성비", "아이용",
    }
    TAG_OCCASION = {
        "밑반찬", "남은재료", "대용량",
        "만능양념", "한그릇", "냉동보관",
    }
    TAG_TASTE = {
        "단짠단짠", "매콤한", "얼큰한", "달달한", "진한맛", "속편한", "시원한",
        "고소한", "새콤한", "향긋한", "크리미한", "짭짤한", "구수한",
    }
    TAG_TEXTURE = {"겉바속촉", "바삭한", "쫄깃한", "촉촉한", "꾸덕한", "자작한"}
    TAG_APPLIANCE = {
        "에어프라이어", "오븐", "전자레인지", "밥솥", "압력솥",
    }
    # 맛·식감 칩: 캡션에 이 말이 있거나, 아래 정규와 겹칠 때만.
    TAG_TASTE_SAID = {
        "매콤한": r"매콤|매운|맵고|맵다|불닭|(?<![가-힣])마라",
        "얼큰한": r"얼큰|칼칼",
        "달달한": r"달달|달콤|단맛|밀키한|(?<![가-힣])밀키(?!트)",
        "진한맛": r"진한\s*(?:맛|육수|국물)|진해서|진해진|진득|뽀얀",
        "고소한": r"고소|꼬수",
        "새콤한": r"새콤|시큼",
        "향긋한": r"향긋",
        "크리미한": r"크리미|(?<!아이스)크림",
        "짭짤한": r"짭짤|짭조름",
        "구수한": r"구수",
        "속편한": (
            r"속편한|속\s*편|자극\s*없이|자극\s*없는|부담\s*없|"
            r"편안한\s*(?:집밥|한\s*끼|맛|국물|식사)|"
            r"깔끔.{0,4}담백|담백.{0,4}깔끔"
        ),
        "단짠단짠": r"단짠",
        "시원한": r"시원",
        "겉바속촉": r"겉바속촉|겉은\s*바삭.{0,16}속은\s*촉촉|속은\s*촉촉.{0,16}겉은\s*바삭",
        "바삭한": r"바삭",
        "쫄깃한": r"쫄깃|탱글",
        "촉촉한": r"촉촉",
        "꾸덕한": r"꾸덕",
        "자작한": r"자작한|자작하|자작하게\s*(?:끓|졸|익)",
    }
    # Still displayable on old recipes; do not prefer for new parses.
    TAG_LEGACY = {
        "집밥용", "혼밥용", "한끼용", "건강식", "균형식", "담백한", "깔끔한",
        "순한맛", "저자극", "채소가득", "부들부들", "손님용", "자취", "파티용",
    }
    STATIC_ALLOWED_TAGS = (
        TAG_FORMAT | TAG_GOAL | TAG_OCCASION | TAG_TASTE | TAG_TEXTURE | TAG_LEGACY
    )
    TAG_ALIAS_MAP = {
        "칼칼한": "얼큰한",
        "얼근한": "얼큰한",
        "순한": "속편한",
        "잡밥용": "집밥용",
        "원팟": "원팬",
        "원팬요리": "원팬",
        "에어후라이어": "에어프라이어",
        "에어후라이": "에어프라이어",
        "전자렌지": "전자레인지",
        "안주": "술안주",
        "술안주용": "술안주",
        "다이어트식": "다이어트",
        "저칼로리식": "저칼로리",
        "저열량": "저칼로리",
        "가성비갑": "가성비",
        "저당": "저당식",
        "비건": "비건식",
        "채식": "비건식",
        "아기반찬": "아이용",
        "유아식": "아이용",
        "유아용": "아이용",
        "키즈반찬": "아이용",
        "아이과자": "아이용",
        "아기과자": "아이용",
        "유아간식": "아이용",
        "아이간식": "아이용",
        "아이반찬": "아이용",
        "이유식": "아이용",
        "간식": "간식용",
        "간식거리": "간식용",
        "밀프렙용": "밀프렙",
        "도시락용": "도시락",
        "자취생": "자취",
        "자취요리": "자취",
        "케토": "키토",
        "저탄고지": "키토",
        "무가당": "무설탕",
        "제로슈가": "무설탕",
        "운동식": "헬식",
        "헬창": "헬식",
        "밥솥요리": "밥솥",
        "전기밥솥": "밥솥",
        "인스턴트팟": "압력솥",
        "인팟": "압력솥",
        "캠핑요리": "캠핑",
        "밑반찬용": "밑반찬",
        "남은거": "남은재료",
        "냉장고파먹기": "남은재료",
        "대량": "대용량",
        "저지방식": "저지방",
        "저탄": "저탄수",
        "노밀": "노밀가루",
        "밀가루없이": "노밀가루",
        "만능장": "만능양념",
        "만능소스": "만능양념",
        "만능간장": "만능양념",
        "한 그릇": "한그릇",
        "야들야들한": "야들한",
    }
    # Vocabulary buckets for the chip word bank. Not exclusive slots.
    TAG_PICK_GROUPS = (
        TAG_FORMAT, TAG_GOAL, TAG_OCCASION, TAG_TASTE, TAG_TEXTURE,
    )
    # Stripped from LLM tag output before normalization (common title junk, never valid tags).
    TAG_NEVER_EMIT = {
        "회사", "직장", "오늘", "우리", "노오븐", "손님용", "자취",
        "집밥용", "혼밥용", "한끼용", "파티용", "건강식", "균형식", "담백한", "깔끔한",
        "맛있는", "쉬운", "좋은", "간단한", "특별한", "완벽한", "추천", "필수",
        "건강한", "훌륭한", "괜찮은", "예쁜", "이쁜", "간편한",
    }
    # 카드 3칸을 채울 때 쓰지 않는 칩. 진짜 밑반찬 요리만 shape fill로 예외.
    TAG_PAD_NEVER = {
        "밑반찬", "다이어트", "저염", "저지방", "키토", "저탄수", "헬식",
        "캠핑", "밀프렙", "비건식", "대용량", "무설탕",
        "집밥용", "혼밥용", "한끼용", "건강식", "균형식",
        "아침용", "간식용", "술안주", "해장각", "야식각", "도시락",
        "아이간식", "아이반찬", "이유식",
    }
    TAG_PAD_PRIORITY = [
        "원팬", "에어프라이어", "전자레인지", "오븐", "밥솥", "압력솥",
        "초간편", "10분컷", "노밀가루",
        "매콤한", "얼큰한", "달달한", "단짠단짠", "진한맛", "속편한", "시원한",
        "겉바속촉", "바삭한", "쫄깃한", "촉촉한", "꾸덕한", "자작한",
        "한그릇", "가성비", "아이용",
    ]
    TAG_OCCASION_BUCKETS: Dict[str, Tuple[str, ...]] = {
        "weather": ("비오는날", "더운날", "추운날", "환절기", "봄나물"),
        "social": (
            "데이트", "생일상", "손님상", "홈파티", "집들이", "명절",
            "기념일", "크리스마스", "어버이날", "어린이날", "발렌타인",
            "할로윈", "새해", "제사상", "수능",
        ),
        "meal": (
            "아침", "브런치", "저녁", "야식", "간식", "디저트",
            "도시락", "밀프렙", "급할때", "냉장고털이",
        ),
        "who": ("혼밥", "가족"),
        "drink": ("안주", "혼술", "술자리", "반주", "해장", "불금"),
        "outdoor": ("캠핑", "차박", "피크닉", "등산"),
        "care": (
            "보양", "몸살", "김장", "운동후", "산후조리",
            "어르신상", "입맛없을때",
        ),
        "snack": ("홈카페", "영화볼때", "치팅데이"),
    }
    # 카드 칩으로 쓰지 않고 상황으로만 보낸다. 아침용+아침밥 같은 겹침을 없앤다.
    TAG_USAGE_AS_OCCASION = {
        "아침용": "아침",
        "아침밥": "아침",
        "아침식사": "아침",
        "모닝": "아침",
        "브런치": "브런치",
        "간식용": "간식",
        "간식": "간식",
        "티타임": "간식",
        "디저트": "디저트",
        "후식": "디저트",
        "술안주": "안주",
        "야식각": "야식",
        "해장각": "해장",
        "도시락": "도시락",
        "캠핑": "캠핑",
        "밀프렙": "밀프렙",
        "아이도시락": "도시락",
        "혼밥용": "혼밥",
        "자취저녁": ("혼밥", "저녁"),
        "가족저녁": ("가족", "저녁"),
    }

    @classmethod
    def _usage_occasion_ids(cls, tag: str, mapped: Any = None) -> List[str]:
        """카드 쓰임 칩을 상황 태그 목록으로 펼친다. 가족저녁 → 가족+저녁."""
        if mapped is None:
            mapped = cls.TAG_USAGE_AS_OCCASION.get(tag)
        if mapped is None:
            return []
        if isinstance(mapped, (list, tuple)):
            return [str(x) for x in mapped if str(x).strip()]
        return [str(mapped)]
    TAG_CARD_TO_OCCASION = {
        "남은재료": "냉장고털이",
        "헬식": "운동후",
        "고단백": "운동후",
    }
    # 요리명 토큰을 whisper/OCR에 그대로 대조하면 오탐이 난다. 도구만 blob에서 본다.
    TAG_OCCASION_INFER_BLOB_OK = {"캠핑", "차박", "밀프렙"}
    # 팬케이크는 생일 케이크가 아니다. 토큰 바로 앞에 오면 정체성이 달라지는 접두어.
    _OCCASION_TOKEN_PREFIX_DENY: Dict[str, str] = {
        "케이크": r"(?:팬|핫|머그)$",
    }
    _ADDED_SUGAR_RE = re.compile(
        r"설탕|시럽|물엿|올리고당|흑설탕|백설탕|메이플|콘시럽|물엿"
    )
    _SUGAR_ALT_RE = re.compile(r"알룰로스|스테비아|에리스리톨|수크랄로스|나한과")
    _STAPLE_RE = re.compile(r"계란|달걀|김치|참치|스팸|라면|두부|콩나물")
    _LUXURY_RE = re.compile(r"한우|랍스터|트러플|캐비아|전복|송로|차돌|꽃등심")
    # LLM이 고른 상황 태그는 키워드 근거 없이도 유지한다 (캠핑·발렌타인만 캡션 필요).
    TAG_OCCASION_LLM_NEEDS_EVIDENCE = {
        "캠핑", "차박", "등산", "어버이날", "크리스마스",
        "김장", "기념일", "불금", "반주",
        "어린이날", "발렌타인", "할로윈", "수능",
        "산후조리", "어르신상", "급할때", "냉장고털이",
    }
    TAG_OCCASION_EXTRA: set = set()
    TAG_OCCASION_INFER: Dict[str, List[str]] = {}
    TAG_OCCASION_INFER_NOT: Dict[str, List[str]] = {}
    TAG_OCCASION_SOURCE: Dict[str, List[str]] = {}
    _OCCASION_ID_ORDER: List[str] = []
    TAG_OCCASION_ALIAS = {
        "손님용": "손님상",
        "손님초대": "손님상",
        "초대상": "손님상",
        "집들이음식": "집들이",
        "생일파티": "생일상",
        "생일": "생일상",
        "비오는 날": "비오는날",
        "비오는날음식": "비오는날",
        "더운 날": "더운날",
        "추운 날": "추운날",
        "명절상": "명절",
        "설날": "명절",
        "추석": "명절",
        "술안주": "안주",
        "혼술안주": "혼술",
        "데이트메뉴": "데이트",
        "데이트밤": "데이트",
        "홈디너": "데이트",
        "홈데이트": "데이트",
        "야식각": "야식",
        "해장각": "해장",
        "해장음식": "해장",
        "캠핑요리": "캠핑",
        "차박음식": "차박",
        "글램핑": "캠핑",
        "도시락용": "도시락",
        "소풍": "피크닉",
        "소풍도시락": "피크닉",
        "나들이": "피크닉",
        "자취": "혼밥",
        "자취생": "혼밥",
        "자취저녁": "혼밥",
        "아침용": "아침",
        "아침밥": "아침",
        "아침식사": "아침",
        "모닝": "아침",
        "브런치메뉴": "브런치",
        "가족식사": "가족",
        "가족저녁": "가족",
        "아이간식": "간식",
        "아이도시락": "도시락",
        "초복": "보양",
        "중복": "보양",
        "말복": "보양",
        "보양식": "보양",
        "효도상": "어버이날",
        "어버이": "어버이날",
        "홈이자카야": "혼술",
        "혼맥": "혼술",
        "치맥": "술자리",
        "회식": "술자리",
        "성탄": "크리스마스",
        "성탄절": "크리스마스",
        "산행": "등산",
        "김장날": "김장",
        "불금야식": "불금",
        "연말파티": "홈파티",
        "파티": "홈파티",
        "파티용": "홈파티",
        "혼밥용": "혼밥",
        "혼자먹기": "혼밥",
        "혼자먹": "혼밥",
        "1인용": "혼밥",
        "겨울": "추운날",
        "한파": "추운날",
        "여름": "더운날",
        "폭염": "더운날",
        "야근": "야식",
        "디저트타임": "간식",
        "커피타임": "간식",
        "홈베이킹": "간식",
        "티타임": "간식",
        "간식용": "간식",
        "후식": "디저트",
        "카페음료": "홈카페",
        "홈카페음료": "홈카페",
        "넷플릭스": "영화볼때",
        "영화": "영화볼때",
        "집콕": "영화볼때",
        "폭식": "치팅데이",
        "치팅": "치팅데이",
        "먹부림": "치팅데이",
        "어린이 날": "어린이날",
        "키즈파티": "어린이날",
        "발렌타인데이": "발렌타인",
        "화이트데이": "발렌타인",
        "빼빼로데이": "발렌타인",
        "핼러윈": "할로윈",
        "핼로윈": "할로윈",
        "신정": "새해",
        "정월": "새해",
        "제사": "제사상",
        "차례상": "제사상",
        "시험기간": "수능",
        "수험생": "수능",
        "운동": "운동후",
        "헬스후": "운동후",
        "운동뒤": "운동후",
        "산모": "산후조리",
        "산모용": "산후조리",
        "산후": "산후조리",
        "어르신": "어르신상",
        "연화식": "어르신상",
        "부모님상": "어르신상",
        "입맛없을 때": "입맛없을때",
        "입맛돋우기": "입맛없을때",
        "목감기": "환절기",
        "일교차": "환절기",
        "봄제철": "봄나물",
        "제철나물": "봄나물",
        "바쁠때": "급할때",
        "시간없을때": "급할때",
        "냉털": "냉장고털이",
        "냉장고파먹기": "냉장고털이",
    }
    _MAIN_DISH_TITLE_RE = re.compile(
        r"찌개|전골|국밥|덮밥|볶음밥|비빔밥|라면|국수|우동|파스타|리조또|"
        r"스테이크|오므라이스|수제비|칼국수|라멘|스파게티|짬뽕|짜장|"
        r"볶음면|쌀국수|피자|버거|볶음탕|갈비찜|김치찜|"
        r"(?:국|탕|면)(?:$|\s)"
    )
    # "반찬이 필요 없어요" = 이 요리면 충분. 밑반찬(저장 반찬)의 반대.
    _BANCHAN_MEANS_COMPLETE_RE = re.compile(
        r"반찬이\s*필요(?:가)?\s*없|다른\s*반찬\s*(?:이\s*)?필요(?:가)?\s*없|"
        r"반찬\s*필요(?:가)?\s*없|반찬\s*없이도|이거면\s*(?:반찬\s*)?끝|"
        r"반찬\s*걱정\s*없"
    )
    # 밥/면이 요리 자체. 찌개·국은 밥이랑 따로 먹는다.
    _VESSEL_NAME_RE = re.compile(
        r"덮밥|국밥|컵밥|비빔밥|볶음밥|계란밥|콩나물밥|나물밥|오차즈케|"
        r"타코라이스|카레라이스|오므라이스|간계밥|"
        r"토리동|규동|가츠동|가쓰동|오야코동|텐동|카츠동|돈부리|동부리|"
        r"국수|라면|라멘|우동|쌀국수|파스타|리조또|알리오|올리오|스파게티|"
        r"칼국수|잔치국수|막국수|밀면|냉면|콩국수|쫄면|비빔면|볶음면|탕면|"
        r"야끼소바|야키소바|두부면|라자냐|라쟈냐|짬뽕|"
        r"짜볶이|라볶이|떡볶이"
    )
    # 요리명만으로 상황을 붙이면 자막 한 단어와 같은 오탐이 난다. 캡션 근거 필요.
    TAG_OCCASION_NEEDS_CAPTION = {
        "캠핑", "차박", "등산", "어버이날", "크리스마스",
        "김장", "기념일", "불금", "밀프렙",
        "어린이날", "발렌타인", "할로윈", "수능",
        "산후조리", "어르신상", "급할때", "냉장고털이",
    }
    # 흔한 단어(겨울/아침/입맛)는 Whisper·OCR이 아니라 쓴 캡션에서만.
    TAG_OCCASION_SOURCE_CAPTION = {
        "추운날", "더운날", "비오는날", "반주", "야식",
        "브런치", "도시락", "아침", "가족", "저녁", "간식",
        "입맛없을때", "홈카페",
    }
    _KID_SNACK_RE = re.compile(
        r"아이\s*간식|아기\s*간식|유아\s*간식|아기\s*과자|유아\s*과자|키즈\s*간식|"
        r"엄마표\s*간식|아기치즈|유아용|어린이\s*간식|"
        r"아기\s*쿠키|아가\s*간식|"
        r"키즈쿠키|유아쿠키|아기빵|아가빵|애기빵|아기\s*빵"
    )
    _CONDIMENT_NAME_RE = re.compile(
        r"소스|드레싱|잼|와사비장|양념장"
    )
    # 저장 반찬 정체성. 갈비찜·등갈비찜은 메인이라 제외.
    _BANCHAN_NAME_RE = re.compile(
        r"(?<![갈비등])조림|장아찌|콩자반|멸치볶음|진미채|어묵볶음|마늘쫑"
    )
    _ANJU_NAME_RE = re.compile(r"술찜|감바스")
    _TEN_MIN_RE = re.compile(
        r"10분컷|10분이면|10분\s*(?:만에|이내|컷)|[1-9]분\s*컷",
    )
    _MEAL_NOT_SNACK_RE = re.compile(
        r"찌개|전골|짜글이|샐러드|덮밥|볶음밥|콩나물밥|국수|파스타|우동|라면|"
        r"라멘|라자냐|라쟈냐|탕(?!수)|죽|국(?!수)",
    )
    _KID_BANCHAN_RE = re.compile(
        r"아이반찬|유아식|어린이집|키즈반찬|"
        r"아이\s*등교|아이\s*도시락|"
        r"아기\s*반찬|아가\s*반찬|아이\s*반찬"
    )
    _SNACK_INCIDENTAL_RE = re.compile(
        r"간식\s*먹|간식먹고|밥먹고.{0,12}간식",
    )
    _TEA_DRINK_RE = re.compile(r"밀크티|버블티|찻잎|홍차|녹차|우롱|아쌈|말차라떼")
    _STEW_RICH_RE = re.compile(
        r"찌개|탕|전골|된장|사골|돈코츠|곰탕|설렁탕|도가니|해장국|육수"
    )
    _OPEN_DESCRIPTOR_RE = re.compile(r"^[가-힣]{2,3}[한용각맛]$")
    # 카드 칩은 한 단어. 슬래시·두 단어 금지. 글자 수는 보통 3–4.
    TAG_CHIP_LONG_OK = {"전자레인지", "에어프라이어"}
    # 카드에 올려도 음식을 설명하지 않는 형용사.
    TAG_OPEN_DENY = {
        "맛있는", "쉬운", "좋은", "간단한", "특별한", "완벽한", "간편한",
        "건강한", "훌륭한", "괜찮은", "예쁜", "이쁜", "담백한", "깔끔한",
        "든든한", "편리한", "최고의", "최고의맛",
        "아침용", "간식용",
    }
    _OPTIONAL_ING_RE = re.compile(r"선택|기호|생략|취향|있어도\s*되고|없어도")
    _SPICY_CLAIM_RE = re.compile(
        r"매콤|매운|맵고|맵다|불닭|(?<![가-힣])마라|얼큰|칼칼"
    )
    _HEAT_HEDGE_RE = re.compile(
        r"매콤하게\s*드(?:시)?려면|매콤한\s*맛(?:을)?\s*원하면|"
        r"매콤함을\s*원하|매콤하게\s*(?:드시|먹)려면"
    )
    # 원문이 "순한맛으로", "깔끔 담백"이라고 못박으면 재료 추정으로 매운맛을 붙이지 않는다.
    _MILD_CLAIM_RE = re.compile(
        r"순한\s*맛|안\s*매(?:운|워|움)|안맵|맵지\s*않|덜\s*맵|맵찔이|"
        r"맵지도\s*않|깔끔\s*담백|깔끔하고\s*담백|담백하고\s*깔끔"
    )
    # 이탈리아 페퍼·후추는 한식 매운맛 양념이 아니다.
    _HEAT_IGNORE_RE = re.compile(
        r"페퍼론치노|페페론치노|페페론치니|후추|후춧|파프리카|레드\s*페퍼|페퍼론치니",
    )
    _EOLKEUN_NAME_RE = re.compile(
        r"김치찌개|김치찜|김치국|김치콩나물|순두부찌개|순두부\s*김치|육개장|매운탕|"
        r"알탕|짬뽕|대구탕|부대찌개|김치전골|짜글이|감자탕|바쿠테|등갈비탕"
    )
    _MACOM_NAME_RE = re.compile(
        r"불닭|마라|떡볶이|짜볶이|라볶이|닭볶음탕|제육|닭갈비|오징어볶음|쭈꾸미|낙곱새|"
        r"신라면|열라면|고추장찌개|골뱅이|양념치킨|닭강정|매콤|칠리오일"
    )
    _MILD_STEW_NAME_RE = re.compile(
        r"된장찌개|된장국|청국장|미역국|(?<!김치)콩나물국|북어국|북엇국|황태국|사골\s*미역",
    )
    _RICH_NAME_RE = re.compile(
        r"된장찌개|된장\s*덮밥|강된장|청국장|곰탕|설렁탕|사골|돈코츠|도가니|"
        r"삼계탕|닭백숙|오리백숙|닭곰탕|추어탕|감자탕|등갈비탕|바쿠테",
    )
    # 브런치 정체성. 상황은 브런치, 카드에는 올리지 않는다.
    _BRUNCH_NAME_RE = re.compile(
        r"베이글|팬케이크|핫케이크|프렌치토스트|에그베네|"
        r"오믈렛|아보카도토스트|와플|모닝빵|토스트",
    )
    _FROZEN_SWEET_RE = re.compile(
        r"젤라또|젤라토|아이스크림|아이스바|소프트콘|셔벗|소르베|파르페|선데"
    )
    _SNACK_NAME_RE = re.compile(
        r"쿠키|케이크|슈(?!크림)|마들렌|브라우니|푸딩|머핀|스콘|꽃빵|"
        r"파이|타르트|츄러스|휘낭시에|쏘낭시에|밀크티|식빵|과자|초코|스낵|오나오|브레드|피타|베이글|피자|"
        r"치아바타|소보로|모찌|모치|인절미|찹쌀떡|"
        r"젤라또|젤라토|아이스크림|아이스바|소프트콘|셔벗|소르베|파르페|"
        r"(?:무화과|바나나|딸기|초코|녹차).{0,6}우유",
    )
    _SWEET_NAME_RE = re.compile(
        r"쿠키|케이크|마들렌|브라우니|슈(?!크림)|푸딩|머핀|스콘|마카롱|약과|양갱|"
        r"티라미수|밀크티|버블티|츄러스|휘낭시에|쏘낭시에|파이|타르트|라떼|빙수|우유\s*식빵|"
        r"과자|초코|잼|복숭아|무화과|맛탕|꿀치즈|"
        r"젤라또|젤라토|아이스크림|아이스바|소프트콘|셔벗|소르베|파르페|"
        r"모찌|모치|인절미|찹쌀떡|꿀고구마|벌꿀고구마"
    )
    _SWEET_SALTY_NAME_RE = re.compile(
        r"양념갈비|떡볶이|짜볶이|라볶이|닭강정|양념치킨|돈테키|돈까스|돈가스|돈까쓰|"
        r"찜닭|토리동|데리야키",
    )
    _COOL_NAME_RE = re.compile(r"냉면|콩국수|냉국|물회|열무국수|밀면|백김치|빙수|스무디")
    _CRISP_NAME_RE = re.compile(
        r"파전|감자전|김치전|부침개|튀김|돈가스|돈까스|돈테키|치킨|강정|감자칩|"
        r"후자오빙|군만두",
    )
    # Keyword proof for a chip. drop=True → strip in production if no match.
    TAG_EVIDENCE_RULES: Dict[str, Dict[str, Any]] = {
        "원팬": {
            "any": [r"원팬", r"원팟", r"팬\s*하나", r"프라이팬\s*하나", r"냄비\s*하나", r"팬\s*하나로"],
            "drop": True,
        },
        "에어프라이어": {
            "any": [r"에어프라이어", r"에어후라이", r"에어프(?:라이어)?"],
            "drop": True,
        },
        "전자레인지": {
            "any": [r"전자레인지", r"전자렌지", r"렌지\s*(?:돌|돌리|1분|2분|3분)"],
            "drop": True,
        },
        "오븐": {
            "any": [r"오븐"],
            "forbid": [r"노오븐", r"오븐\s*없이"],
            "drop": True,
        },
        "밥솥": {
            "any": [r"밥솥", r"전기밥솥", r"밥통", r"쿠쿠"],
            "drop": True,
        },
        "압력솥": {
            "any": [r"압력솥", r"인스턴트팟", r"인팟", r"압력냄비"],
            "drop": True,
        },
        "초간편": {
            "any": [r"초간편", r"초간단", r"초초간단"],
            "drop": True,
        },
        "10분컷": {
            "any": [
                r"10분컷", r"10분이면", r"10분\s*(?:만에|이내|컷)",
                r"[1-9]분컷",
            ],
            "drop": True,
        },
        "노밀가루": {
            "any": [r"노밀가루", r"밀가루\s*없이", r"밀가루를\s*안"],
            "drop": True,
        },
        "다이어트": {
            "any": [r"다이어트", r"저칼로리", r"살빼", r"다이어터", r"칼로리\s*낮"],
            "drop": True,
        },
        "고단백": {
            "any": [r"고단백", r"단백질"],
            "drop": True,
        },
        "저당식": {
            "any": [r"저당", r"당질", r"당뇨식"],
            "drop": True,
        },
        "무설탕": {
            "any": [r"무설탕", r"제로슈가", r"설탕\s*없이", r"알룰로스", r"스테비아", r"무가당"],
            "drop": True,
        },
        "키토": {
            "any": [r"키토", r"케토", r"저탄고지"],
            "drop": True,
        },
        "저탄수": {
            "any": [r"저탄수", r"탄수화물\s*(?:낮|적|없이)", r"키토", r"케토"],
            "drop": True,
        },
        "비건식": {
            "any": [r"비건", r"채식", r"동물성\s*없이"],
            "drop": True,
            "vegan_check": True,
        },
        "저염": {
            "any": [r"저염", r"소금\s*(?:적|없이|최소)", r"나트륨\s*낮"],
            "drop": True,
        },
        "저지방": {
            "any": [r"저지방", r"기름\s*(?:없이|최소|적게)", r"팻\s*프리"],
            "drop": True,
        },
        "헬식": {
            "any": [r"헬식", r"운동\s*(?:후|식|전)", r"벌크업", r"헬스식"],
            "drop": True,
        },
        "저칼로리": {
            "any": [r"저칼로리", r"칼로리\s*낮", r"라이트식"],
            "drop": False,
        },
        "가성비": {
            "any": [r"가성비", r"저렴", r"만원대", r"가성\s*비"],
            "drop": True,
        },
        "아이반찬": {
            "any": [r"아이반찬", r"아이\s*반찬", r"유아식", r"유아용", r"어린이집", r"키즈반찬"],
            "drop": True,
        },
        "이유식": {
            "any": [r"이유식", r"초기이유", r"중기이유", r"후기이유", r"보틀이유"],
            "drop": True,
        },
        "아이간식": {
            "any": [r"아이간식", r"아기과자", r"유아간식", r"아기\s*(?:수박|쿠키|케이크|휘낭시에|빵)"],
            "drop": True,
        },
        "도시락": {"any": [r"도시락", r"런치박스"]},
        "밀프렙": {"any": [r"밀프렙", r"meal\s*prep", r"미리\s*만들"]},
        "술안주": {
            "any": [r"안주", r"혼술", r"맥주안주", r"소주안주", r"파전", r"부침개", r"감바스", r"골뱅이"],
            "drop": True,
        },
        "해장각": {"any": [r"해장", r"콩나물국", r"북엇국", r"북어국", r"황태국", r"해장국"], "drop": True},
        "야식각": {
            "any": [r"야식", r"밤참", r"라면", r"떡볶이", r"족발", r"불닭"],
            "forbid": [r"샐러드", r"타코", r"랩"],
            "drop": True,
        },
        "간식용": {
            "any": [
                r"간식", r"쿠키", r"케이크", r"마들렌", r"브라우니",
                r"슈크림", r"쿠키슈", r"머핀", r"스콘", r"소금빵",
                r"꽃빵", r"치즈빵", r"마카롱", r"푸딩",
            ],
            "drop": True,
        },
        "캠핑": {"any": [r"캠핑", r"차박", r"글램핑"], "drop": True},
        "밑반찬": {
            "any": [r"밑반찬", r"저장반찬"],
            "forbid": [
                r"반찬이\s*필요(?:가)?\s*없",
                r"다른\s*반찬\s*(?:이\s*)?필요(?:가)?\s*없",
                r"반찬\s*없이도",
            ],
            "drop": True,
        },
        "남은재료": {"any": [r"남은\s*재료", r"냉장고\s*파먹", r"남은거"]},
        "대용량": {"any": [r"대용량", r"대량", r"많이\s*만들"]},
        "만능양념": {"any": [r"만능양념", r"만능장", r"만능간장", r"만능소스", r"만능\s*양념"]},
        "한그릇": {
            "any": [
                r"한그릇\s*(?:요리|레시피|식사)",
                r"한\s*그릇\s*(?:요리|식사|완성)",
                r"덮밥", r"국밥", r"컵밥",
                r"찌개", r"전골", r"라면", r"라멘", r"국수", r"파스타",
                r"리조또", r"볶음밥", r"비빔밥", r"우동", r"쌀국수",
            ],
            "forbid": [r"말아", r"한\s*그릇\s*드세"],
            "drop": True,
        },
        "냉동보관": {"any": [r"냉동보관", r"냉동실", r"얼려", r"냉동\s*가능"]},
        "아침용": {"any": [r"아침", r"브런치", r"모닝"]},
        "단짠단짠": {"any": [r"단짠"], "drop": True},
        "매콤한": {"any": [r"매콤", r"매운", r"맵고", r"맵다", r"불닭"], "drop": True},
        "얼큰한": {"any": [r"얼큰", r"칼칼"], "drop": True},
        "달달한": {"any": [r"달달", r"달콤"], "drop": True},
        "진한맛": {"any": [r"진한", r"진득"], "drop": True},
        "속편한": {"any": [r"속편한", r"자극\s*없이"], "drop": True},
        "시원한": {"any": [r"시원한", r"시원하게", r"시원한\s*국물", r"개운"], "drop": True},
        "겉바속촉": {"any": [r"겉바속촉", r"겉은\s*바삭", r"속은\s*촉촉"], "drop": True},
        "바삭한": {"any": [r"바삭"], "drop": True},
        "쫄깃한": {"any": [r"쫄깃"], "drop": True},
        "촉촉한": {"any": [r"촉촉", r"속촉"], "drop": True},
        "꾸덕한": {"any": [r"꾸덕"], "drop": True},
        "자작한": {"any": [r"자작"], "drop": True},
    }
    _ANIMAL_ING_RE = re.compile(
        r"돼지|소고기|한우|닭|계란|달걀|우유|버터|치즈|멸치|액젓|젓갈|참치|새우|"
        r"꿀|마요|베이컨|햄|소시지|오징어|낙지|문어|조개|홍합|연어|고등어|멸치육수"
    )

    @staticmethod
    def _normalize_tag_string(tag: str) -> str:
        return re.sub(r"[\u200B-\u200D\uFEFF]", "", (tag or "").strip())

    def _load_chef_tags(self) -> List[str]:
        return []

    def _save_chef_tags(self, chefs: List[str]) -> None:
        return None

    def _verify_chef_with_llm(self, candidate: str) -> bool:
        return False

    def _detect_chef_tag(self, *args: Any, **kwargs: Any) -> Optional[str]:
        return None

    @classmethod
    def _expand_raw_tag(cls, tag: str) -> List[str]:
        """슬래시·쉼표로 붙은 두 단어를 칩 두 개로 쪼갠다. '고소한/새콤한' 금지."""
        raw = cls._normalize_tag_string(tag)
        if not raw:
            return []
        parts = re.split(r"[\s/,|·•~]+", raw)
        out: List[str] = []
        for part in parts:
            p = part.strip()
            if not p or p in {"및", "그리고", "with", "&"}:
                continue
            out.append(p)
        return out

    @classmethod
    def _tag_chip_shape_ok(cls, tag: str) -> bool:
        """한 단어. 보통 3–4자. 전자레인지·에어프라이어만 더 길어도 된다."""
        t = cls._normalize_tag_string(tag)
        if not t or re.search(r"[\s/,|·•~]", t):
            return False
        if t in cls.TAG_CHIP_LONG_OK or t in cls.STATIC_ALLOWED_TAGS:
            return True
        if not re.fullmatch(r"[가-힣0-9]+", t):
            return False
        n = len(re.findall(r"[가-힣0-9]", t))
        if cls._is_open_descriptor(t):
            return 3 <= n <= 4
        if re.fullmatch(r"[가-힣]{2,4}", t):
            return True
        return 3 <= n <= 4


    def _normalize_mentioned_products(self, raw_products: Any) -> List[Dict[str, Any]]:
        """브랜드 SKU 목록 정규화."""
        if not isinstance(raw_products, list):
            return []
        out: List[Dict[str, Any]] = []
        seen: set[str] = set()
        for item in raw_products:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "").strip()
            generic = str(item.get("generic") or "").strip()
            if not name:
                continue
            key = name.casefold()
            if key in seen:
                continue
            seen.add(key)
            required = item.get("required_for_dish")
            if isinstance(required, str):
                required = required.strip().lower() in {"true", "1", "yes"}
            else:
                required = bool(required)
            out.append({
                "name": name,
                "generic": generic or name,
                "required_for_dish": required,
            })
        return out[:12]

    @classmethod
    def _evidence_blob(
        cls,
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]] = None,
    ) -> str:
        """제목/캡션/전사/재료/도구를 한 덩어리로 합친다."""
        parts = [title or "", description or "", transcript or ""]
        rec = recipe if isinstance(recipe, dict) else {}
        parts.append(str(rec.get("name") or ""))
        for ing in rec.get("ingredients") or []:
            if isinstance(ing, dict):
                parts.append(str(ing.get("item") or ""))
                parts.append(str(ing.get("notes") or ""))
            elif isinstance(ing, str):
                parts.append(ing)
        for step in rec.get("steps") or []:
            if isinstance(step, dict):
                parts.append(str(step.get("instruction") or ""))
                parts.append(str(step.get("tip") or ""))
        for tool in rec.get("equipment") or []:
            parts.append(str(tool or ""))
        notes = rec.get("notes") or []
        if isinstance(notes, list):
            parts.extend(str(n) for n in notes[:8])
        return "\n".join(p for p in parts if p)

    @classmethod
    def _ensure_occasion_catalog(cls) -> None:
        """상세용 상황 태그 + 요리명 infer 데이터셋을 JSON에서 읽는다."""
        if cls.TAG_OCCASION_EXTRA and cls.TAG_OCCASION_INFER:
            return
        path = Path(__file__).resolve().parents[1] / "data" / "occasion_tags_ko.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, TypeError) as exc:
            print(f"[Tags] occasion catalog load failed: {exc}")
            payload = {}
        ids: List[str] = []
        infer: Dict[str, List[str]] = {}
        infer_not: Dict[str, List[str]] = {}
        source: Dict[str, List[str]] = {}
        for row in payload.get("tags") or []:
            if isinstance(row, str) and row.strip():
                ids.append(row.strip())
                continue
            if not isinstance(row, dict) or not row.get("id"):
                continue
            tag_id = str(row["id"]).strip()
            ids.append(tag_id)
            toks = [
                str(x).strip()
                for x in (row.get("infer") or [])
                if str(x).strip()
            ]
            toks.sort(key=len, reverse=True)
            infer[tag_id] = toks
            infer_not[tag_id] = [
                str(x).strip()
                for x in (row.get("infer_not") or row.get("infer_not") or [])
                if str(x).strip()
            ]
            source[tag_id] = [
                str(x).strip()
                for x in (row.get("source") or [])
                if str(x).strip()
            ]
        cls.TAG_OCCASION_EXTRA = set(ids)
        cls.TAG_OCCASION_INFER = infer
        cls.TAG_OCCASION_INFER_NOT = infer_not
        cls.TAG_OCCASION_SOURCE = source
        cls._OCCASION_ID_ORDER = ids

    @classmethod
    def occasion_catalog_prompt(cls) -> str:
        """LLM에 넣는 상황 태그 설명."""
        path = Path(__file__).resolve().parents[1] / "data" / "occasion_tags_ko.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, TypeError):
            return ""
        lines = []
        for row in payload.get("tags") or []:
            if not isinstance(row, dict):
                continue
            tag_id = str(row.get("id") or "").strip()
            foods = str(row.get("foods") or "").strip()
            when = str(row.get("when") or "").strip()
            if not tag_id:
                continue
            extra = " / ".join(p for p in (foods, when) if p)
            lines.append(f"- {tag_id}: {extra}" if extra else f"- {tag_id}")
        return "\n".join(lines)

    @classmethod
    def _per_serving_macros(cls, nutrition: Any) -> Dict[str, float]:
        """표시용 1인분 매크로. 테이블이 있으면 테이블, 없으면 LLM."""
        per: Dict[str, Any] = {}
        llm: Dict[str, Any] = {}
        if nutrition is None:
            return {}
        if hasattr(nutrition, "per_serving"):
            raw_per = getattr(nutrition, "per_serving", None)
            if isinstance(raw_per, dict):
                per = raw_per
            est = getattr(nutrition, "llm_estimate", None)
            if est is not None:
                llm = {
                    "kcal": getattr(est, "calories_per_serving", 0),
                    "protein_g": getattr(est, "protein_g", 0),
                    "fat_g": getattr(est, "fat_g", 0),
                    "carb_g": getattr(est, "carbs_g", 0) or getattr(est, "carb_g", 0),
                    "sodium_mg": getattr(est, "sodium_mg", 0),
                    "sugar_g": getattr(est, "sugar_g", 0),
                }
        elif isinstance(nutrition, dict):
            if isinstance(nutrition.get("per_serving"), dict):
                per = nutrition.get("per_serving") or {}
            est = nutrition.get("llm_estimate")
            if isinstance(est, dict):
                llm = {
                    "kcal": est.get("calories_per_serving") or est.get("kcal"),
                    "protein_g": est.get("protein_g"),
                    "fat_g": est.get("fat_g"),
                    "carb_g": est.get("carbs_g") or est.get("carb_g"),
                    "sodium_mg": est.get("sodium_mg"),
                    "sugar_g": est.get("sugar_g"),
                }
            elif not per:
                per = nutrition
        def _f(src: Dict[str, Any], *keys: str) -> float:
            for k in keys:
                try:
                    v = float(src.get(k) or 0)
                except (TypeError, ValueError):
                    continue
                if v:
                    return v
            return 0.0
        kcal = _f(per, "kcal", "calories_per_serving") or _f(llm, "kcal", "calories_per_serving")
        return {
            "kcal": kcal,
            "protein_g": _f(per, "protein_g") or _f(llm, "protein_g"),
            "fat_g": _f(per, "fat_g") or _f(llm, "fat_g"),
            "carb_g": _f(per, "carb_g", "carbs_g") or _f(llm, "carb_g", "carbs_g"),
            "sodium_mg": _f(per, "sodium_mg") or _f(llm, "sodium_mg"),
            "sugar_g": _f(per, "sugar_g") or _f(llm, "sugar_g"),
        }

    @classmethod
    def _ingredient_is_optional(cls, ing: Dict[str, Any]) -> bool:
        blob = f"{ing.get('item') or ''} {ing.get('notes') or ''}"
        return bool(cls._OPTIONAL_ING_RE.search(blob))

    @classmethod
    def _spicy_claim_blob(
        cls,
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]],
    ) -> str:
        """선택 재료 메모의 '매콤하게'는 제외하고 매운맛 주장을 본다."""
        rec = recipe if isinstance(recipe, dict) else {}
        parts = [title or "", description or "", transcript or "", str(rec.get("name") or "")]
        for ing in rec.get("ingredients") or []:
            if not isinstance(ing, dict) or cls._ingredient_is_optional(ing):
                continue
            parts.append(str(ing.get("item") or ""))
            parts.append(str(ing.get("notes") or ""))
        for step in rec.get("steps") or []:
            if isinstance(step, dict):
                parts.append(str(step.get("instruction") or ""))
                parts.append(str(step.get("tip") or ""))
        return "\n".join(p for p in parts if p)

    @classmethod
    def _spicy_tag_allowed(
        cls,
        recipe: Optional[Dict[str, Any]],
        title: str = "",
        description: str = "",
        transcript: str = "",
        blob: str = "",
    ) -> bool:
        """선택 청양 1개 / 양념 고춧가루만으로 매콤한을 주지 않는다."""
        claim_blob = cls._spicy_claim_blob(title, description, transcript, recipe)
        if not claim_blob:
            claim_blob = blob or ""
        if cls._SPICY_CLAIM_RE.search(claim_blob):
            return True
        return cls._heat_from_bill(recipe)

    @classmethod
    def _heat_denied_by_source(cls, claim: str, name: str) -> bool:
        """원문이 순한맛·깔끔담백이라고 말하면 매운맛 칩을 막는다.

        불닭·마라처럼 이름 자체가 매운 요리면 예외.
        """
        if not cls._MILD_CLAIM_RE.search(claim or ""):
            return False
        return not cls._MACOM_NAME_RE.search(name or "")

    @classmethod
    def _heat_from_bill(cls, recipe: Optional[Dict[str, Any]]) -> bool:
        """고추장·고춧가루·청양이 양념으로 쓰였는지. 페퍼론치노·후추는 무시."""
        rec = recipe if isinstance(recipe, dict) else {}
        pepper_count = 0.0
        chili_powder_g = 0.0
        paste_g = 0.0
        for ing in rec.get("ingredients") or []:
            if not isinstance(ing, dict) or cls._ingredient_is_optional(ing):
                continue
            item = str(ing.get("item") or "")
            if cls._HEAT_IGNORE_RE.search(item):
                continue
            try:
                qty = float(ing.get("qty") or 0)
            except (TypeError, ValueError):
                qty = 0.0
            unit = str(ing.get("unit") or "")
            if any(tok in item for tok in ("청양", "홍고추", "할라피뇨")):
                pepper_count += qty if unit in {"개", "대", ""} else (
                    qty / 8.0 if unit in {"g", "그램"} else 0
                )
            if "고춧가루" in item or "고추가루" in item:
                chili_powder_g += qty if unit in {"g", "그램"} else qty * (
                    8.0 if unit in {"큰술", "스푼"} else 0
                )
            if "고추장" in item or "불닭" in item or "마라" in item:
                paste_g += qty if unit in {"g", "그램"} else qty * (
                    18.0 if unit in {"큰술", "스푼"} else 0
                )
        return pepper_count >= 2 or chili_powder_g >= 15 or paste_g >= 30

    _BRAISE_NAME_RE = re.compile(r"조림|볶음|강정|찜닭|장조림|데리야키|불고기")
    _SALTY_BASE_RE = re.compile(r"간장|굴소스|된장|쌈장|피시소스|맛간장")
    _SWEETENER_RE = re.compile(r"물엿|조청|올리고당|설탕|흑설탕|꿀|메이플|시럽|매실청|알룰로스")

    @classmethod
    def _sweet_salty_from_bill(cls, name: str, recipe: Optional[Dict[str, Any]]) -> bool:
        """간장·굴소스에 물엿·설탕을 같이 넣고 졸이면 단짠이다."""
        if not cls._BRAISE_NAME_RE.search(name or ""):
            return False
        rec = recipe if isinstance(recipe, dict) else {}
        salty = False
        sweet = False
        for ing in rec.get("ingredients") or []:
            if not isinstance(ing, dict) or cls._ingredient_is_optional(ing):
                continue
            item = str(ing.get("item") or "")
            salty = salty or bool(cls._SALTY_BASE_RE.search(item))
            sweet = sweet or bool(cls._SWEETENER_RE.search(item))
        return salty and sweet

    @classmethod
    def _korean_chili_seasoning(cls, recipe: Optional[Dict[str, Any]]) -> bool:
        """고추장·고춧가루·청양이 재료에 있는지. 페퍼론치노·후추는 무시."""
        rec = recipe if isinstance(recipe, dict) else {}
        for ing in rec.get("ingredients") or []:
            if not isinstance(ing, dict) or cls._ingredient_is_optional(ing):
                continue
            item = str(ing.get("item") or "")
            if cls._HEAT_IGNORE_RE.search(item):
                continue
            if any(
                tok in item
                for tok in (
                    "청양", "홍고추", "고춧가루", "고추가루", "고추장",
                    "불닭", "마라", "할라피뇨", "스리라차", "시라차", "sriracha",
                )
            ):
                return True
        return False

    @classmethod
    def _open_stem_in_source(cls, tag: str, blob: str) -> bool:
        """열린 형용사는 어간이 원문에 있어야 한다. 아삭한 ← 아삭."""
        t = cls._normalize_tag_string(tag)
        if not t or len(t) < 2:
            return False
        stem = t[:-1] if t[-1] in "한용각맛" else t
        if len(stem) < 2:
            return False
        compact = re.sub(r"\s+", "", blob or "")
        return stem in compact

    def _taste_authorized(
        self,
        tag: str,
        title: str,
        recipe: Optional[Dict[str, Any]],
        claim: str,
        food_taste: set,
    ) -> bool:
        """맛·식감은 요리 정체성·재료·말한 감각만. LLM 추정만으로는 불가."""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        if tag in {"매콤한", "매운맛", "얼큰한"} and self._heat_denied_by_source(claim, name):
            return False
        said_pat = self.TAG_TASTE_SAID.get(tag)
        claim_for_said = self._HEAT_HEDGE_RE.sub("", claim or "") if tag in {
            "매콤한", "매운맛", "얼큰한",
        } else (claim or "")
        if said_pat and re.search(said_pat, claim_for_said):
            if tag == "시원한" and not (
                self._COOL_NAME_RE.search(name)
                or re.search(r"빙수|스무디|냉우동|냉파스타|냉국수", name)
            ):
                return False
            if tag == "진한맛":
                if self._TEA_DRINK_RE.search(name) and not self._RICH_NAME_RE.search(name):
                    return False
                return bool(
                    self._RICH_NAME_RE.search(name)
                    or re.search(r"(?:국|탕|찌개|전골)", name)
                )
            if tag == "자작한" and re.search(r"믹서|블렌더|퓨레|갈아", f"{name}\n{claim}"):
                return False
            return True
        if tag in food_taste:
            return True
        if tag in {"매콤한", "매운맛"}:
            return self._korean_chili_seasoning(rec)
        if tag == "얼큰한":
            if self._MILD_STEW_NAME_RE.search(name):
                return False
            return bool(
                re.search(r"찌개|전골|탕|짜글이", name)
                and self._korean_chili_seasoning(rec)
                and not self._vessel_name_ok(name, rec)
            )
        if tag == "진한맛":
            if self._TEA_DRINK_RE.search(name) and not self._RICH_NAME_RE.search(name):
                return False
            return bool(self._RICH_NAME_RE.search(name))
        if tag == "구수한":
            return bool(re.search(r"된장|청국장|해장국", name))
        if tag == "쫄깃한":
            return bool(re.search(r"만두|떡|쌀국수|쫄면", name))
        if tag == "꾸덕한":
            return bool(re.search(r"리조또|크림", name))
        return False

    @classmethod
    def _food_character_tags(
        cls,
        title: str,
        recipe: Optional[Dict[str, Any]],
    ) -> List[str]:
        """요리명·재료로 알 수 있는 맛·식감. 전통/집밥은 넣지 않는다."""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        ing_blob = " ".join(
            str(ing.get("item") or "")
            for ing in (rec.get("ingredients") or [])
            if isinstance(ing, dict)
        )
        hay = f"{name}\n{ing_blob}"
        out: List[str] = []
        heat_bill = cls._heat_from_bill(rec)
        chili = cls._korean_chili_seasoning(rec)
        mild = bool(cls._MILD_STEW_NAME_RE.search(name))
        cream_name = bool(re.search(
            r"크림|투움바|카르보나라|까르보나라|알프레도|부라타|리조또|"
            r"보스카이올라|카르보",
            name,
        )) and not re.search(r"아이스크림", name)
        lasagna = bool(re.search(r"라자냐|라쟈냐", name))
        dairy = bool(re.search(
            r"치즈|생크림|크림치즈|리코타|베샤멜|모짜렐라|파마산", hay,
        ))
        if cream_name or (lasagna and dairy):
            out.append("크리미한")
        if re.search(r"콘치즈", name) and re.search(r"우유|생크림|치즈", hay):
            out.append("크리미한")
        stew_skip_heat = bool(re.search(r"수육|보쌈", name)) and not re.search(
            r"매콤|매운", name,
        )
        if cls._EOLKEUN_NAME_RE.search(name):
            out.append("얼큰한")
        elif stew_skip_heat:
            pass
        elif cls._MACOM_NAME_RE.search(name) or ((chili or heat_bill) and not mild):
            creamy_pasta = bool(re.search(
                r"크림|투움바|카르보나라|까르보나라|알프레도", name,
            )) and not re.search(r"매콤|불닭|(?<![가-힣])마라|칠리", name)
            if creamy_pasta and not cls._MACOM_NAME_RE.search(name):
                pass
            elif (
                re.search(r"찌개|탕|전골|(?:국)(?:$|\s)", name)
                and not cls._vessel_name_ok(name, rec)
                and not cls._MACOM_NAME_RE.search(name)
            ):
                out.append("얼큰한")
            else:
                out.append("매콤한")
        if cls._RICH_NAME_RE.search(name):
            out.append("진한맛")
        if cls._SWEET_NAME_RE.search(name):
            out.append("달달한")
        if cls._SWEET_SALTY_NAME_RE.search(name) and "콩나물" not in name:
            out.append("단짠단짠")
        elif cls._sweet_salty_from_bill(name, rec):
            out.append("단짠단짠")
        if cls._COOL_NAME_RE.search(name) and not re.search(r"라면|라멘|찌개", name):
            out.append("시원한")
        if cls._CRISP_NAME_RE.search(name) and "꽃빵" not in name:
            out.append("바삭한")
        nutty_identity = bool(re.search(
            r"치즈볼|아몬드|땅콩버터|땅콩잼|(?<![가-힣])땅콩|참깨|들깨|깨소금|고소|"
            r"아이올리|알리올리|페스토|마요|마요네즈|"
            r"삼겹|목살|대패|베이컨|관찰레|판체타",
            hay,
        ))
        nutty_garnish = bool(re.search(
            r"들기름|참기름|(?<![가-힣])깨(?![가-힣])", hay,
        ))
        soup_or_namul = bool(re.search(r"(?:국|탕|찌개|전골|생채|겉절이)", name))
        if nutty_identity or (nutty_garnish and not soup_or_namul):
            out.append("고소한")
        if re.search(r"부라타", hay) and not re.search(r"아이스크림", name):
            out.append("크리미한")
        if re.search(r"모닝빵|토스트|베이글", name) and re.search(r"치즈|계란|에그", hay):
            out.append("고소한")
        if re.search(r"샐러드|라페|콜슬로|생채|겉절이", name) and re.search(
            r"레몬|식초|비네|유자|매실|새콤|발사믹", hay,
        ):
            out.append("새콤한")
        if re.search(r"레몬", name) and re.search(r"파이|타르트|샐러드|라페|에이드", name):
            out.append("새콤한")
        if re.search(r"샐러드", name) and re.search(
            r"치즈|페타|참깨|들깨|견과|올리브", hay,
        ):
            out.append("고소한")
        if re.search(r"발사믹", name):
            out.append("새콤한")
        if re.search(r"냉면|물회", name) and not re.search(r"라면|라멘", name):
            out.append("새콤한")
        if (
            re.search(r"미역국|황태국|북어국|북엇국|뭇국|무국|해장국|된장죽|미역죽", name)
            and not cls._RICH_NAME_RE.search(name)
        ):
            out.append("구수한")
        if re.search(r"된장|청국장", name) and re.search(r"죽|국(?!수)|찌개", name):
            out.append("구수한")
        if re.search(r"깻잎|미나리|세발나물|방아잎", name):
            out.append("향긋한")
        if re.search(r"명란|시오콘부", name):
            out.append("짭짤한")
        if (
            re.search(r"주먹밥|김밥", name)
            and re.search(r"설탕", hay)
            and re.search(r"간장", hay)
        ):
            out.append("단짠단짠")
        if re.search(r"버터", name) and re.search(r"우동|파스타|볶음밥|빵|쿠키", name):
            out.append("고소한")
        if re.search(r"샌드위치", name) and re.search(r"발사믹|레몬|식초", hay):
            out.append("새콤한")
        if re.search(r"샌드위치", name) and re.search(
            r"페스토|브리|치즈", hay,
        ) and not re.search(r"부라타|크림", hay):
            out.append("고소한")
        if re.search(r"만두|후자오빙|호교병", name):
            out.append("쫄깃한")
        if re.search(r"후자오빙|호교병|후추", name):
            out.append("짭짤한")
        if re.search(r"비빔밥|생채|겉절이", name) and re.search(
            r"식초|매실|레몬|유자", hay,
        ):
            out.append("새콤한")
        seen: set = set()
        uniq: List[str] = []
        for tag in out:
            if tag in seen:
                continue
            seen.add(tag)
            uniq.append(tag)
        return uniq

    @classmethod
    def _is_main_dish(cls, title: str, recipe: Optional[Dict[str, Any]], categories: Any) -> bool:
        """찌개/면/덮밥처럼 한 끼 메인인지. 밑반찬 오탐 방지."""
        name = f"{title or ''} {(recipe or {}).get('name') or ''}"
        if cls._MAIN_DISH_TITLE_RE.search(name):
            return True
        cats = categories if isinstance(categories, dict) else {}
        menus = cats.get("menu_type") or cats.get("메뉴 분류") or []
        if isinstance(menus, str):
            menus = [menus]
        main_menus = {"국", "찌개", "탕", "면", "밥", "일품", "메인", "덮밥", "면요리"}
        return any(str(m) in main_menus for m in menus)

    @classmethod
    def _goal_tag_nutrition_ok(cls, tag: str, macros: Dict[str, float], blob: str) -> bool:
        """다이어트/고단백 등은 영상 근거와 1인분 숫자가 같이 맞아야 한다."""
        kcal = macros.get("kcal") or 0.0
        protein = macros.get("protein_g") or 0.0
        fat = macros.get("fat_g") or 0.0
        carb = macros.get("carb_g") or 0.0
        sodium = macros.get("sodium_mg") or 0.0
        sugar = macros.get("sugar_g") or 0.0
        claimed_diet = bool(re.search(r"다이어트|저칼로리|살빼|다이어터|헬식", blob or ""))
        claimed_protein = bool(re.search(r"고단백|단백질", blob or ""))
        if tag == "다이어트":
            if not claimed_diet:
                return False
            if kcal >= 650:
                return False
            return True
        if tag == "저칼로리":
            claimed = bool(re.search(r"저칼로리|다이어트|살빼|라이트식", blob or ""))
            return claimed and 0 < kcal <= 350
        if tag == "고단백":
            if protein < 15:
                return False
            return claimed_protein or protein >= 25
        if tag == "저염":
            if sodium >= 1800:
                return False
            return bool(re.search(r"저염|나트륨\s*낮", blob or "")) and sodium <= 1200
        if tag == "저지방":
            if fat >= 22:
                return False
            return bool(re.search(r"저지방|기름\s*(?:없이|최소)", blob or ""))
        if tag == "저당식":
            dessert = bool(re.search(r"쿠키|케이크|푸딩|음료|스무디|디저트|빵", blob or ""))
            claimed_sugar = bool(re.search(r"저당|당질|알룰로스|당뇨", blob or ""))
            return (claimed_sugar or dessert) and sugar <= 12
        if tag == "무설탕":
            claimed_zero = bool(re.search(r"무설탕|무가당|제로슈가|설탕\s*없이", blob or ""))
            return (not cls._has_added_sugar(blob)) or (claimed_zero and sugar <= 2)
        if tag == "키토":
            if carb >= 15:
                return False
            return bool(re.search(r"키토|케토|저탄고지", blob or ""))
        if tag == "저탄수":
            if carb >= 35:
                return False
            return bool(re.search(r"저탄수|키토|케토", blob or ""))
        if tag == "헬식":
            if protein < 25:
                return False
            return bool(re.search(r"헬식|운동\s*(?:후|식)|벌크업|헬스식", blob or ""))
        if tag == "비건식":
            return not cls._ANIMAL_ING_RE.search(blob or "")
        return True

    @classmethod
    def _has_added_sugar(cls, blob: str) -> bool:
        text = blob or ""
        # "설탕 없이/빼고/대신"은 첨가당 증거가 아니다.
        cleaned = re.sub(r"설탕\s*(?:없이|빼고|대신|말고)|무설탕|무가당", " ", text)
        if not cls._ADDED_SUGAR_RE.search(cleaned):
            return False
        if cls._SUGAR_ALT_RE.search(cleaned) and not re.search(r"설탕|물엿|올리고당|시럽", cleaned):
            return False
        return True

    @classmethod
    def _is_meal_sized(
        cls,
        title: str,
        recipe: Optional[Dict[str, Any]],
        categories: Any,
    ) -> bool:
        if cls._is_main_dish(title, recipe, categories):
            return True
        name = f"{title or ''} {(recipe or {}).get('name') or ''}"
        return bool(re.search(r"샐러드|덮밥|볶음밥|국수|파스타|스테이크|리조또", name))

    @classmethod
    def _usage_shape_ok(
        cls,
        tag: str,
        title: str,
        recipe: Optional[Dict[str, Any]],
        blob: str,
        categories: Any,
        macros: Optional[Dict[str, float]] = None,
    ) -> bool:
        """키워드가 없어도 형태·영양으로 참인 사용/목표 칩."""
        rec = recipe if isinstance(recipe, dict) else {}
        ings = [ing for ing in (rec.get("ingredients") or []) if isinstance(ing, dict)]
        steps = rec.get("steps") or []
        ing_blob = " ".join(str(ing.get("item") or "") for ing in ings)
        combined = f"{blob or ''}\n{ing_blob}"
        macros = macros or {}
        if tag == "초간편":
            head = f"{title or ''}\n{(blob or '')[:280]}"
            rec = recipe if isinstance(recipe, dict) else {}
            return (
                cls._written_easy_ok(head, title)
                or cls._lazy_no_cook_dessert_ok(title, rec, blob or "")
            )
        if tag == "원팬":
            return cls._one_pan_shape_ok(title, rec, blob)
        if tag == "한그릇":
            name = f"{title or ''} {rec.get('name') or ''}"
            return cls._vessel_name_ok(name, rec)
        if tag == "10분컷":
            return cls._written_ten_min_ok(blob or "")
        if tag == "가성비":
            return bool(re.search(r"가성비|만원대", blob or ""))
        if tag == "저칼로리":
            return cls._is_meal_sized(title, rec, categories) and cls._goal_tag_nutrition_ok(
                tag, macros, combined
            )
        if tag == "무설탕":
            return cls._goal_tag_nutrition_ok(tag, macros, combined)
        if tag == "비건식":
            return not cls._ANIMAL_ING_RE.search(ing_blob)
        if tag == "고단백":
            return cls._goal_tag_nutrition_ok(tag, macros, combined)
        return False

    @classmethod
    def _is_condiment_name(cls, name: str) -> bool:
        """소스·잼·장은 간식이 아니다."""
        return bool(cls._CONDIMENT_NAME_RE.search(name or ""))

    @classmethod
    def _banchan_name_ok(cls, name: str) -> bool:
        """조림·장아찌 저장 반찬. 갈비찜은 메인."""
        if re.search(r"갈비찜|찜닭|닭볶음탕|갈비조림", name or ""):
            return False
        return bool(cls._BANCHAN_NAME_RE.search(name or ""))

    @classmethod
    def _strip_hashtags(cls, text: str) -> str:
        """해시태그 덤프는 초간편·간식 증거가 아니다."""
        return re.sub(r"#\S+", " ", text or "")

    @classmethod
    def _written_easy_ok(cls, text: str, title: str = "") -> bool:
        """본문에 초간단/초간편. #초간단요리·다른 레시피 초간단은 안 친다."""
        body = cls._strip_hashtags(text)
        name = re.sub(r"\s+", "", title or "")

        def _other_dish(match: re.Match) -> str:
            dish = match.group(1) or ""
            if dish in {
                "요리", "레시피", "버전", "한끼", "저녁", "점심", "아침", "야식",
                "방학", "간식", "메뉴", "완성", "방법", "꿀팁", "재료", "만들기",
            }:
                return match.group(0)
            if name and dish in name:
                return match.group(0)
            return " "

        body = re.sub(r"초간(?:단|편)\s*([가-힣]{2,12})", _other_dish, body)
        if re.search(r"레이지", title or ""):
            return True
        return bool(re.search(r"초간단|초간편", body))

    _APPLIANCE_ALT_RE = re.compile(
        r"또는\s*(?:광파)?오븐|또는\s*전자렌|또는\s*에어프라이|"
        r"(?:광파)?오븐\s*또는|전자렌지?\s*또는|에어프라이어?\s*또는|"
        r"전자레인지\s*\([^)]{0,24}오븐|"
        r"오븐\s*\([^)]{0,24}전자렌|"
        r"(?:에어프라이어|오븐|전자레인지)로도|"
        r"에어프라이어도|오븐도\s*가능|렌지로도|"
        r"(?:오븐|전자레인지|에어프라이어|광파오븐)\s*(?:나|/|혹은)\s*"
        r"(?:오븐|전자레인지|에어프라이어|광파)"
    )

    @classmethod
    def _heat_appliances_named(cls, eq: str, written: str) -> Set[str]:
        """오븐·렌지·에어프라이어 중 실제로 거론된 것. 광파오븐은 둘 다."""
        blob = f"{eq or ''}\n{written or ''}"
        found: Set[str] = set()
        if re.search(r"에어프라이어|에어후라이", blob):
            found.add("에어프라이어")
        if re.search(r"전자레인지|전자렌지", blob):
            found.add("전자레인지")
        if re.search(r"광파오븐", blob):
            found.add("전자레인지")
            found.add("오븐")
        elif re.search(r"오븐", blob) and not re.search(r"노오븐|오븐\s*없이", blob):
            found.add("오븐")
        return found

    @classmethod
    def _appliance_chip_ok(cls, tag: str, eq: str, written: str) -> bool:
        """그 가전이 요리의 유일한 방법일 때만. '또는 오븐'이면 붙이지 않는다."""
        if tag not in cls.TAG_APPLIANCE:
            return False
        if cls._APPLIANCE_ALT_RE.search(written or "") or cls._APPLIANCE_ALT_RE.search(eq or ""):
            return False
        found = cls._heat_appliances_named(eq, written)
        heat = {"오븐", "전자레인지", "에어프라이어"}
        if tag in heat:
            if len(found & heat) != 1 or tag not in found:
                return False
        if tag == "에어프라이어":
            if re.search(
                r"빵은\s*에어프라이어|식빵을?\s*에어프라이어|"
                r"빵.{0,8}에어프라이어에\s*\d",
                written or "",
            ):
                return False
            return "에어프라이어" in found
        if tag == "오븐":
            if re.search(r"노오븐", written or ""):
                return False
            return "오븐" in found
        if tag == "전자레인지":
            if re.search(r"팬|웍|냄비|솥|뚝배기", eq or ""):
                return False
            if re.search(
                r"전자레인지.{0,20}(?:초콜릿|초코|해동)|(?:초콜릿|초코).{0,16}전자레인지",
                written or "",
            ) and not re.search(
                r"전자레인지로\s*만|전자렌지\s*\d+\s*분|렌지\s*\d+\s*분",
                written or "",
            ):
                return False
            return "전자레인지" in found
        if tag == "밥솥":
            return bool(re.search(r"밥솥|쿠쿠", eq or ""))
        if tag == "압력솥":
            return "압력솥" in (eq or "")
        return False

    @classmethod
    def _lazy_no_cook_dessert_ok(
        cls,
        title: str,
        recipe: Optional[Dict[str, Any]],
        blob: str = "",
    ) -> bool:
        """찬밥 갈아 얼리기처럼 불·오븐 없이 섞어 끝내는 냉동 디저트."""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        if not cls._FROZEN_SWEET_RE.search(name):
            return False
        hay = blob or ""
        if re.search(r"오븐|에어프라이|튀기|끓이|볶아|구워", hay):
            return False
        return bool(re.search(r"찬밥|남은\s*밥|믹서|블렌더|갈아|휘핑|올리면\s*끝", hay))

    @classmethod
    def _written_ten_min_ok(cls, text: str) -> bool:
        """시작부터 10분. 에어프라이어 10분 구우면 완성은 조리 시간이다."""
        t = cls._strip_hashtags(text)
        if cls._TEN_MIN_RE.search(t):
            return True
        for match in re.finditer(r"10분(.{0,24})완성", t):
            gap = match.group(1) or ""
            if re.search(r"구워|구우|에어|오븐", gap):
                continue
            return True
        return False

    @classmethod
    def _snack_word_is_claim(cls, text: str, title: str = "") -> bool:
        """간식먹고 추억·팔로우 CTA는 간식용이 아니다."""
        if re.search(r"간식", title or ""):
            return True
        body = cls._strip_hashtags(text)
        if not re.search(r"간식", body):
            return False
        cleaned = cls._SNACK_INCIDENTAL_RE.sub(" ", body)
        return bool(re.search(r"간식", cleaned))

    @classmethod
    def _ingredient_text(cls, recipe: Optional[Dict[str, Any]]) -> str:
        rec = recipe if isinstance(recipe, dict) else {}
        return " ".join(
            str(ing.get("item") or "")
            for ing in (rec.get("ingredients") or [])
            if isinstance(ing, dict)
        )

    @classmethod
    def _vessel_name_ok(cls, name: str, recipe: Optional[Dict[str, Any]] = None) -> bool:
        """밥·면이 요리 자체일 때만. 파스타 소스/퓨레는 재료에 면이 없다."""
        if not cls._VESSEL_NAME_RE.search(name or ""):
            return False
        if re.search(r"계란죽|김치죽|미역죽|라면.{0,8}죽|(?<![가-힣])죽(?:$|\s)", name or ""):
            return False
        if re.search(r"파스타|스파게티|리조또|라자냐|라쟈냐", name or ""):
            ings = cls._ingredient_text(recipe)
            if ings and not re.search(r"파스타|스파게티|면|리조또|쌀|라자냐", ings):
                return False
        return True

    @classmethod
    def _written_bowl_ok(
        cls,
        name: str,
        written: str,
        recipe: Optional[Dict[str, Any]],
    ) -> bool:
        """제목에 파스타가 없어도 캡션·재료가 면 요리면 한그릇."""
        if re.search(
            r"계란죽|김치죽|미역죽|라면.{0,8}죽|(?<![가-힣])죽(?:$|\s)",
            name or "",
        ):
            return False
        if cls._vessel_name_ok(name, recipe):
            return True
        hay = f"{name or ''}\n{written or ''}"
        if not re.search(
            r"파스타|스파게티|라자냐|딸리아텔레|탈리아텔레|우동|라면", hay,
        ):
            return False
        ings = cls._ingredient_text(recipe)
        return bool(re.search(
            r"파스타|스파게티|우동|(?<![가-힣])라면|라자냐|딸리아|탈리아",
            ings,
        ))

    @classmethod
    def _kid_snack_claimed(cls, title: str, description: str, quote: str = "") -> bool:
        blob = cls._strip_hashtags(f"{title or ''}\n{description or ''}\n{quote or ''}")
        if not cls._KID_SNACK_RE.search(blob):
            return False
        name = title or ""
        # 라자냐·파스타 본편에 "간식으로도"는 아이간식이 아니다.
        if re.search(r"라자냐|파스타|찌개|전골|우동|라면", name) and re.search(
            r"간식(?:으로도|로도)", blob,
        ) and not re.search(r"아이\s*간식|아기\s*간식", title or ""):
            return False
        # "아이들 간식이나 아침으로도"는 어른 요리 겸용. 정체성이 아이 음식이 아니다.
        if re.search(r"아이들\s*간식(?:이나|으로도|로도)|애들\s*간식(?:이나|으로도)", blob):
            if not re.search(r"아기|아가|유아|이유식|키즈|어린이", title or ""):
                return False
        return True

    @classmethod
    def _kid_banchan_claimed(cls, title: str, description: str, quote: str = "") -> bool:
        blob = f"{title or ''}\n{description or ''}\n{quote or ''}"
        return bool(cls._KID_BANCHAN_RE.search(blob))

    @classmethod
    def _kid_food_claimed(cls, title: str, description: str, quote: str = "") -> bool:
        """아기 어묵처럼 제목이 아이 음식. '아이들이 거부감'만으로는 안 된다."""
        if cls._kid_snack_claimed(title, description, quote):
            return True
        if cls._kid_banchan_claimed(title, description, quote):
            return True
        blob = f"{title or ''}\n{description or ''}\n{quote or ''}"
        if re.search(r"아기|아가|유아|이유식|키즈|어린이", title or ""):
            return True
        if re.search(r"#(?:유아식|아기간식|아이반찬|이유식)", description or ""):
            return True
        if re.search(
            r"밥\s*잘\s*안\s*먹는\s*아이|아이를\s*위한|아이\s*위한|"
            r"캐릭터\s*김밥|키즈\s*김밥|유아\s*김밥",
            blob,
        ):
            return True
        return bool(re.search(r"(?<![가-힣])(?:유아식|이유식)(?![가-힣])", blob))

    @classmethod
    def _is_open_descriptor(cls, tag: str) -> bool:
        """카탈로그에 없는 2–4자 형용사. 셰프명·필러 아님."""
        t = cls._normalize_tag_string(tag)
        if not t or t in cls.TAG_NEVER_EMIT or t in cls.TAG_LEGACY:
            return False
        if t in cls.TAG_OPEN_DENY:
            return False
        if t in cls.STATIC_ALLOWED_TAGS:
            return False
        if t in cls.CHEF_STOPWORDS:
            return False
        return bool(cls._OPEN_DESCRIPTOR_RE.fullmatch(t))

    @classmethod
    def _quote_in_source(cls, quote: str, blob: str) -> bool:
        q = re.sub(r"\s+", "", quote or "")
        b = re.sub(r"\s+", "", blob or "")
        return bool(q) and q in b

    @classmethod
    def _quote_sense_ok(
        cls,
        tag: str,
        quote: str,
        title: str,
        blob: str,
        recipe: Optional[Dict[str, Any]],
    ) -> bool:
        """인용문이 그 칩의 뜻으로 쓰였는지. 동음이의·페어링·재료 팁은 거부."""
        q = quote or ""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        if tag == "밑반찬":
            if cls._BANCHAN_MEANS_COMPLETE_RE.search(q) or cls._BANCHAN_MEANS_COMPLETE_RE.search(
                blob or "",
            ):
                return False
            return bool(re.search(r"밑반찬|저장반찬", q))
        if tag == "한그릇":
            if re.search(r"말아|한\s*그릇\s*드세", q):
                return False
            return cls._vessel_name_ok(name, rec)
        if tag == "바삭한":
            if re.search(r"바삭.{0,20}빵|빵.{0,20}바삭", q) and not re.search(
                r"빵|토스트|크루통|샌드위치|베이글|브레드|치아바타|바게트",
                name,
            ):
                return False
            return bool(re.search(r"바삭|crispy", q, re.I))
        if tag == "시원한":
            if re.search(r"라면|라멘|찌개", name):
                return False
            if re.search(r"매콤\s*시원|시원\s*매콤", q):
                return False
            return bool(re.search(r"시원", q) or re.search(
                r"냉면|냉국|백김치|물김치", name,
            ))
        if tag == "자작한":
            if re.search(r"자작하게\s*붓", q) or re.search(r"자작하게\s*붓", blob or ""):
                return False
            if re.search(r"믹서|블렌더|퓨레|갈아", f"{name}\n{q}\n{blob or ''}"):
                return False
            return bool(re.search(r"자작", q))
        if tag == "가성비":
            return bool(re.search(r"가성비|만원대", q))
        if tag == "쫄깃한":
            if re.search(r"찌개|전골|(?:국|탕)(?:$|\s)", name):
                return bool(re.search(r"쫄깃|탱글", q))
            return bool(re.search(r"쫄깃|탱글|찰진", q))
        if tag == "야식각":
            return bool(re.search(r"야식|밤참|심야", q) or re.search(
                r"떡볶이|족발|불닭볶음면", name,
            ))
        if tag == "술안주":
            return bool(
                re.search(r"안주|맥주|혼술|막걸리", q)
                or cls._ANJU_NAME_RE.search(name)
            )
        if tag in {"매콤한", "매운맛"}:
            if cls._HEAT_HEDGE_RE.search(q) or cls._HEAT_HEDGE_RE.search(blob or ""):
                if not re.search(r"매콤|매운|불닭|(?<![가-힣])마라", re.sub(cls._HEAT_HEDGE_RE, "", q + blob)):
                    return False
            return bool(re.search(r"매콤|매운|(?<![가-힣])마라|불닭|얼큰|칼칼", q))
        if tag == "초간편":
            return cls._written_easy_ok(q, title)
        if tag == "10분컷":
            return cls._written_ten_min_ok(q)
        if tag == "진한맛":
            if cls._TEA_DRINK_RE.search(name) and not cls._STEW_RICH_RE.search(name):
                return False
            return bool(re.search(r"진한|진해|진득|뽀얀", q) or cls._STEW_RICH_RE.search(name))
        if tag == "아이간식":
            return bool(cls._KID_SNACK_RE.search(f"{q}\n{name}\n{blob[:800]}"))
        if tag == "아이반찬":
            return bool(cls._KID_BANCHAN_RE.search(f"{q}\n{name}\n{blob[:800]}"))
        if tag == "간식용":
            if cls._KID_SNACK_RE.search(q) and not re.search(r"간식", name):
                return True
            return bool(re.search(r"간식", q) or re.search(
                r"쿠키|케이크|파이|츄러스|휘낭시에|빵|슈|푸딩", name,
            ))
        return True

    @classmethod
    def _one_pan_shape_ok(
        cls,
        title: str,
        recipe: Optional[Dict[str, Any]],
        blob: str = "",
    ) -> bool:
        """원팬: 원문이 원팬이거나, 팬/냄비 1개 + 볶음/덮밥/파스타. 전·탕 제외."""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        if re.search(r"원팬", blob or ""):
            return True
        if re.search(r"전(?:$|\s)|파전|부침개|찌개|전골|볶음탕|(?:국|탕)(?:$|\s)", name):
            return False
        cookware_n = len([
            x for x in (rec.get("equipment") or [])
            if isinstance(x, str) and re.search(r"팬|웍|냄비|솥", x)
        ])
        if cookware_n != 1:
            return False
        if re.search(r"파스타|스파게티|알리오|올리오", name):
            return cls._vessel_name_ok(name, rec)
        return bool(re.search(r"볶음|덮밥|불고기|제육", name))

    @classmethod
    def audit_recipe_tags(
        cls,
        tags: List[str],
        *,
        title: str = "",
        description: str = "",
        transcript: str = "",
        recipe: Optional[Dict[str, Any]] = None,
        quotes: Optional[Dict[str, str]] = None,
    ) -> List[Dict[str, Any]]:
        """태그마다 supported / weak / unsupported 판정. QA 스크립트와 파싱이 공유한다."""
        blob = cls._evidence_blob(title, description, transcript, recipe)
        quotes = quotes or {}
        rec = recipe if isinstance(recipe, dict) else {}
        ing_blob = " ".join(
            str(ing.get("item") or "") if isinstance(ing, dict) else str(ing)
            for ing in (rec.get("ingredients") or [])
        )
        out: List[Dict[str, Any]] = []
        for raw in tags:
            tag = cls.TAG_ALIAS_MAP.get(str(raw).strip(), str(raw).strip())
            quote = str(quotes.get(tag) or quotes.get(raw) or "").strip()
            rule = cls.TAG_EVIDENCE_RULES.get(tag)
            hit_pat = ""
            forbid_hit = False
            if rule:
                for pat in rule.get("forbid") or []:
                    if re.search(pat, blob, re.IGNORECASE):
                        forbid_hit = True
                        break
                if not forbid_hit:
                    for pat in rule.get("any") or []:
                        m = re.search(pat, blob, re.IGNORECASE)
                        if m:
                            hit_pat = m.group(0)
                            break
            quote_in_blob = bool(quote) and (re.sub(r"\s+", "", quote) in re.sub(r"\s+", "", blob))
            vegan_fail = bool(rule and rule.get("vegan_check") and cls._ANIMAL_ING_RE.search(ing_blob))
            if tag not in cls.STATIC_ALLOWED_TAGS:
                verdict = "chef_or_other"
                reason = "chef or non-catalog"
            elif forbid_hit or vegan_fail:
                verdict = "unsupported"
                reason = "forbidden pattern or animal ingredients for vegan"
            elif hit_pat:
                verdict = "supported" if (not quote or quote_in_blob) else "weak"
                reason = f"matched {hit_pat}" + ("" if quote_in_blob or not quote else "; quote not in source")
            elif quote_in_blob:
                verdict = "weak"
                reason = "quote found but no keyword rule hit"
            else:
                verdict = "unsupported"
                reason = "no keyword in title/caption/ingredients/steps"
            out.append({
                "tag": tag,
                "quote": quote,
                "quote_in_source": quote_in_blob,
                "matched": hit_pat,
                "verdict": verdict,
                "reason": reason,
                "drop": bool(rule and rule.get("drop") and verdict == "unsupported"),
            })
        return out

    def _tag_passes_guards(
        self,
        tag: str,
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]],
        quotes: Optional[Dict[str, str]],
        nutrition: Any,
        categories: Any,
    ) -> bool:
        """거짓 뜻만 막는다. 맛·식감은 LLM 요리 지식을 허용하고, 인용 히트만으로 통과시키지 않는다."""
        if not tag or tag in self.TAG_NEVER_EMIT:
            return False
        if not self._tag_chip_shape_ok(tag):
            return False
        rec = recipe if isinstance(recipe, dict) else {}
        blob = self._evidence_blob(title, description, transcript, rec)
        written = f"{title or ''}\n{description or ''}"
        macros = self._per_serving_macros(nutrition)
        name = f"{title or ''} {rec.get('name') or ''}"
        quote = str((quotes or {}).get(tag) or "").strip()
        quote_ok = self._quote_in_source(quote, written) if quote else False
        if quote and quote_ok and not self._quote_sense_ok(
            tag, quote, title, blob, rec,
        ):
            return False
        # 제목·글 캡션만. Whisper 인용은 가성비·매콤 환각을 만든다.
        claim = written
        if quote_ok:
            claim = f"{claim}\n{quote}"
        eq = " ".join(str(x) for x in (rec.get("equipment") or []) if x)
        if tag == "한그릇":
            if self._is_condiment_name(name):
                return False
            return self._written_bowl_ok(name, written, rec)
        if tag == "에어프라이어":
            return self._appliance_chip_ok(tag, eq, f"{written}\n{transcript or ''}")
        if tag == "오븐":
            return self._appliance_chip_ok(tag, eq, f"{written}\n{transcript or ''}")
        if tag == "전자레인지":
            return self._appliance_chip_ok(tag, eq, f"{written}\n{transcript or ''}")
        if tag == "밥솥":
            return bool(re.search(r"밥솥|쿠쿠", eq))
        if tag == "압력솥":
            return "압력솥" in eq
        if tag == "원팬":
            return self._one_pan_shape_ok(title, rec, blob)
        food_taste = set(self._food_character_tags(title, rec))
        kid_quote = quote if quote_ok else ""
        if tag == "아이간식":
            return self._kid_snack_claimed(title, description, kid_quote)
        if tag == "아이반찬":
            return self._kid_banchan_claimed(title, description, kid_quote)
        if tag == "아이용":
            return self._kid_food_claimed(title, description, kid_quote)
        if tag == "이유식":
            return bool(re.search(r"이유식", claim))
        if tag == "밑반찬":
            if self._BANCHAN_MEANS_COMPLETE_RE.search(blob or ""):
                return False
            if self._banchan_name_ok(name):
                return True
            if (
                re.search(r"반찬", name)
                and re.search(r"반찬통|숙성|밑반찬", written)
                and not re.search(r"찜|찌개|전골", name)
            ):
                return True
            quote_in_blob = bool(quote) and self._quote_in_source(quote, blob)
            if not quote_in_blob:
                return False
            return self._quote_sense_ok(tag, quote, title, blob, rec)
        if tag in {"매콤한", "매운맛", "얼큰한"} and self._heat_denied_by_source(claim, name):
            return False
        if tag in {"매콤한", "매운맛"}:
            if self._HEAT_HEDGE_RE.search(claim or ""):
                claim_wo = self._HEAT_HEDGE_RE.sub("", claim or "")
                said_heat = bool(re.search(r"매콤|매운|불닭|(?<![가-힣])마라|얼큰|칼칼", claim_wo))
            else:
                said_heat = bool(re.search(r"매콤|매운|불닭|(?<![가-힣])마라|얼큰|칼칼", claim))
            if self._MILD_STEW_NAME_RE.search(name) and not said_heat:
                return False
            if said_heat or tag in food_taste or "매콤한" in food_taste:
                return True
            if re.search(r"크림|투움바|카르보나라|까르보나라|알프레도", name) and not re.search(
                r"매콤|불닭|(?<![가-힣])마라|칠리", name,
            ):
                return False
            return self._korean_chili_seasoning(rec)
        if tag == "진한맛":
            if self._TEA_DRINK_RE.search(name) and not self._STEW_RICH_RE.search(name):
                return False
            return self._taste_authorized(tag, title, rec, claim, food_taste)
        if tag == "시원한":
            return self._taste_authorized(tag, title, rec, claim, food_taste)
        if tag == "초간편":
            return (
                self._written_easy_ok(claim, title)
                or self._lazy_no_cook_dessert_ok(title, rec, claim)
            )
        if tag == "10분컷":
            return self._written_ten_min_ok(claim)
        if tag == "술안주":
            return bool(
                re.search(r"안주|맥주|혼술|막걸리", claim)
                or self._ANJU_NAME_RE.search(name)
            )
        if tag == "가성비":
            return bool(re.search(r"가성비|만원대", claim))
        if tag == "노밀가루":
            return bool(re.search(
                r"노밀가루|NO\s*밀가루|밀가루.{0,20}(?:없이|없어도|빼고|대신)",
                claim,
                re.I,
            ))
        if tag == "아침용":
            # 해시태그 덤프(#브런치)는 아침 근거가 아니다.
            plain = self._strip_hashtags(claim)
            if re.search(r"아침|브런치|모닝", plain):
                return True
            if not self._BRUNCH_NAME_RE.search(name):
                return False
            # 토스트라도 글이 오후 간식이라고 못박으면 아침용이 아니다.
            return not self._snack_word_is_claim(plain, title or "")
        if tag == "캠핑":
            return bool(re.search(r"캠핑|차박", f"{title or ''}\n{description or ''}"))
        if tag == "야식각":
            return bool(re.search(r"야식|밤참|심야", claim))
        if tag == "밀프렙":
            return bool(re.search(r"밀프렙|meal\s*prep|미리\s*만들", claim, re.I))
        if tag == "남은재료":
            return bool(re.search(r"남은\s*재료|냉장고\s*파먹|남은거|냉털", claim))
        if tag == "대용량":
            return bool(re.search(r"대용량|대량", claim))
        if tag == "만능양념":
            return bool(re.search(r"만능양념|만능장|만능소스|만능간장", claim))
        if tag == "냉동보관":
            return bool(re.search(r"냉동보관|냉동실|얼려", claim))
        if tag == "저칼로리" and not self._is_meal_sized(title, rec, categories):
            return False
        if tag in self.TAG_GOAL and tag not in {"아이간식", "아이반찬", "이유식", "가성비"}:
            if tag == "저당식" and not re.search(r"저당|당질|알룰로스|당뇨", written):
                return False
            if not self._goal_tag_nutrition_ok(tag, macros, blob):
                return False
            return True
        if self._is_open_descriptor(tag):
            return self._open_stem_in_source(
                tag, f"{title or ''}\n{description or ''}\n{transcript or ''}",
            )
        if tag in (self.TAG_TASTE | self.TAG_TEXTURE):
            return self._taste_authorized(tag, title, rec, claim, food_taste)
        if tag in self.STATIC_ALLOWED_TAGS:
            if tag in food_taste:
                return True
            if tag in {"해장각"} and re.search(
                r"콩나물국|북어국|북엇국|황태국|해장국|순댓국", name,
            ):
                return True
            if tag == "도시락" and re.search(r"김밥|주먹밥", name):
                return True
            if tag == "간식용":
                if self._is_condiment_name(name):
                    return False
                if self._MEAL_NOT_SNACK_RE.search(name) and not re.search(
                    r"간식", title or "",
                ):
                    return False
                snack_claim = self._snack_word_is_claim(claim, title or "")
                if (
                    self._BRUNCH_NAME_RE.search(name)
                    and not re.search(r"베이글", name)
                    and not snack_claim
                ):
                    return False
                return bool(
                    snack_claim
                    or self._SNACK_NAME_RE.search(name)
                    or re.search(r"빵", name)
                )
            return False
        return True

    @classmethod
    def _shape_fill_tags(
        cls,
        title: str,
        recipe: Optional[Dict[str, Any]],
        blob: str,
        categories: Any = None,
    ) -> List[str]:
        """이름·재료로 확실한 구조·맛 칩. 집밥/전통/상황 국룰은 넣지 않는다."""
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        out: List[str] = list(cls._food_character_tags(title, rec))
        if cls._vessel_name_ok(name, rec) or cls._written_bowl_ok(
            name, f"{title or ''}", rec,
        ):
            out.append("한그릇")
        seen = set()
        uniq: List[str] = []
        for tag in out:
            if tag in seen:
                continue
            seen.add(tag)
            uniq.append(tag)
        return uniq

    @classmethod
    def _taste_tags_from_written(
        cls,
        title: str,
        description: str,
        recipe: Optional[Dict[str, Any]],
    ) -> List[str]:
        """글 캡션이 말한 맛·식감. Whisper는 보지 않는다."""
        written = f"{title or ''}\n{description or ''}"
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        out: List[str] = []
        for tag, pat in cls.TAG_TASTE_SAID.items():
            if not re.search(pat, written):
                continue
            if tag == "시원한" and not (
                cls._COOL_NAME_RE.search(name)
                or re.search(r"빙수|스무디|냉우동|냉파스타|냉국수", name)
            ):
                continue
            if tag == "자작한" and re.search(r"자작하게\s*붓", written):
                continue
            if tag == "진한맛":
                if cls._TEA_DRINK_RE.search(name) and not cls._RICH_NAME_RE.search(name):
                    continue
                if not cls._RICH_NAME_RE.search(name) and not re.search(
                    r"(?:국|탕|찌개|전골)", name,
                ):
                    continue
            if not cls._quote_sense_ok(tag, written, title, written, rec):
                continue
            out.append(tag)
        return out

    def _card_tag_bucket(self, tag: str, chef_tag: str = "", title_line: str = "") -> int:
        """카드 3칸 순위. 낮을수록 앞. 셰프 → 맛 → 초간편 → 쓰임 → 목표 → 원팬 → 가전."""
        if chef_tag and tag == chef_tag:
            return 0
        if (
            tag not in self.STATIC_ALLOWED_TAGS
            and not self._is_open_descriptor(tag)
            and tag not in self.CHEF_STOPWORDS
            and re.fullmatch(r"[가-힣]{2,6}", tag or "")
        ):
            return 0
        if tag in (self.TAG_TASTE | self.TAG_TEXTURE) or self._is_open_descriptor(tag):
            return 1
        if tag in {
            "한그릇", "원팬", "노밀가루", "밑반찬", "아이용",
        }:
            return 2
        if tag in self.TAG_GOAL and title_line and tag in title_line:
            return 2
        if tag in {"초간편", "10분컷"}:
            return 3
        if tag in {
            "가성비", "냉동보관", "남은재료",
        }:
            return 4
        if tag in self.TAG_GOAL:
            return 5
        if tag in self.TAG_APPLIANCE:
            return 7
        return 8

    _CARD_BUCKET2_ORDER = {
        "한그릇": 3,
        "밑반찬": 3,
        "노밀가루": 3,
        "원팬": 6,
    }
    # 말한 맛끼리 칸이 부족하면 고소/향긋보다 매콤·새콤·단맛을 남긴다.
    _TASTE_TIE_ORDER = {
        "매콤한": 0, "매운맛": 0, "얼큰한": 0,
        "달달한": 1, "단짠단짠": 1, "새콤한": 1, "진한맛": 1, "짭짤한": 1,
        "크리미한": 2, "시원한": 2, "겉바속촉": 2,
        "바삭한": 3, "쫄깃한": 3, "촉촉한": 3, "꾸덕한": 3, "자작한": 3,
        "고소한": 4, "구수한": 4, "향긋한": 4, "속편한": 5,
    }

    def _rank_card_tags(
        self,
        tags: List[str],
        chef_tag: str = "",
        written: str = "",
    ) -> List[str]:
        title_line = (written or "").split("\n", 1)[0]
        head_lines = [ln for ln in (written or "").split("\n") if ln.strip()]
        claim_head = "\n".join(head_lines[:6])[:400]

        def buck(tag: str) -> int:
            return self._card_tag_bucket(tag, chef_tag, claim_head)

        def bucket2(tag: str) -> int:
            if tag in self.TAG_GOAL and claim_head and tag in claim_head:
                return -1
            return self._CARD_BUCKET2_ORDER.get(tag, 9)

        indexed = list(enumerate(tags))
        indexed.sort(key=lambda iv: (
            buck(iv[1]),
            self._TASTE_TIE_ORDER.get(iv[1], 3) if buck(iv[1]) == 1 else 0,
            bucket2(iv[1]),
            iv[0],
        ))
        identity = {"한그릇", "원팬", "밑반찬"}
        id_n = sum(1 for t in tags if t in identity)
        said_taste_n = 0
        for t in tags:
            if buck(t) != 1:
                continue
            pat = self.TAG_TASTE_SAID.get(t)
            if pat and written and re.search(pat, written):
                said_taste_n += 1
            elif self._is_open_descriptor(t) and self._open_stem_in_source(t, written):
                said_taste_n += 1
        has_chef = any(
            buck(t) == 0
            and t not in (self.TAG_TASTE | self.TAG_TEXTURE)
            and not self._is_open_descriptor(t)
            for t in tags
        )
        has_title_goal = any(
            t in self.TAG_GOAL and t in claim_head for t in tags
        )
        use_waiting = any(buck(t) in {2, 4} for t in tags)
        if has_chef and "한그릇" in tags:
            taste_cap = 1
        elif has_title_goal:
            # 제목 다이어트/키토가 촉촉한·달달한에 밀리지 않게 맛 1칸만.
            taste_cap = 1
        elif id_n >= 2:
            # 캡션이 맛 둘을 말하면(매콤새콤) 한그릇+원팬이 하나를 지우지 않는다.
            taste_cap = 2 if said_taste_n >= 2 else 1
        elif use_waiting:
            taste_cap = 2
        else:
            taste_cap = 3
        name_heat_and_cream = bool(
            re.search(r"크림|투움바|카르보나라|까르보나라|알프레도", title_line)
            and re.search(r"매콤|칠리|불닭|(?<![가-힣])마라", title_line)
        )
        if name_heat_and_cream:
            taste_cap = max(taste_cap, 2)
        out: List[str] = []
        appliance_used = False
        taste_n = 0
        for _, tag in indexed:
            bucket = buck(tag)
            if bucket == 1:
                if taste_n >= taste_cap:
                    continue
                taste_n += 1
            if tag in self.TAG_APPLIANCE:
                if appliance_used:
                    continue
                appliance_used = True
            out.append(tag)
            if len(out) >= 3:
                break
        return out

    def _pad_display_tags(
        self,
        kept: List[str],
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]],
        quotes: Optional[Dict[str, str]],
        nutrition: Any,
        categories: Any,
    ) -> List[str]:
        """글 캡션 맛 + 요리 정체성 + vessel + 장비. 빈 칸을 거짓 칩으로 채우지 않는다."""
        rec = recipe if isinstance(recipe, dict) else {}
        blob = self._evidence_blob(title, description, transcript, rec)
        written = f"{title or ''}\n{description or ''}"
        name = f"{title or ''} {rec.get('name') or ''}"
        eq_blob = " ".join(str(x) for x in (rec.get("equipment") or []) if x)
        macros = self._per_serving_macros(nutrition)
        extras: List[str] = []
        extras.extend(self._taste_tags_from_written(title, description, rec))
        extras.extend(self._food_character_tags(title, rec))
        if re.search(r"다이어트", written) and self._goal_tag_nutrition_ok(
            "다이어트", macros, written,
        ):
            extras.append("다이어트")
        if self._written_bowl_ok(name, written, rec):
            extras.append("한그릇")
        if self._written_easy_ok(written, title) or self._lazy_no_cook_dessert_ok(
            title, rec, blob,
        ):
            extras.append("초간편")
        if self._written_ten_min_ok(written):
            extras.append("10분컷")
        if re.search(
            r"노밀가루|NO\s*밀가루|밀가루.{0,20}(?:없이|없어도|빼고|대신)",
            written,
            re.I,
        ):
            extras.append("노밀가루")
        if re.search(r"남은\s*재료|냉장고\s*파먹|남은거|냉털", written):
            extras.append("남은재료")
        if re.search(r"냉동보관|냉동실|얼려|냉동해요|냉동\s*가능", written):
            extras.append("냉동보관")
        if self._banchan_name_ok(name) and not self._BANCHAN_MEANS_COMPLETE_RE.search(written):
            extras.append("밑반찬")
        elif (
            re.search(r"반찬", name)
            and re.search(r"반찬통|숙성|밑반찬", written)
            and not re.search(r"찜|찌개|전골", name)
            and not self._BANCHAN_MEANS_COMPLETE_RE.search(written)
        ):
            extras.append("밑반찬")
        note_txt = ""
        notes = rec.get("notes") or []
        if isinstance(notes, list):
            note_txt = " ".join(str(n) for n in notes[:8])
        open_src = f"{written}\n{transcript or ''}\n{note_txt}"
        for open_tag in ("아삭한", "쫀득한", "야들한", "폭신한", "말랑한", "달큰한"):
            if self._open_stem_in_source(open_tag, open_src):
                extras.append(open_tag)
        if self._kid_food_claimed(title, description):
            extras.append("아이용")
        for app_tag in ("에어프라이어", "오븐", "전자레인지", "압력솥", "밥솥"):
            if self._appliance_chip_ok(app_tag, eq_blob, f"{written}\n{transcript or ''}"):
                extras.append(app_tag)
                break
        if self._one_pan_shape_ok(title, rec, blob):
            extras.append("원팬")
        seen = set(kept)
        merged = list(kept)
        for tag in extras:
            if not tag or tag in seen or tag in self.TAG_NEVER_EMIT:
                continue
            if not self._tag_chip_shape_ok(tag):
                continue
            seen.add(tag)
            merged.append(tag)
        return merged

    def _filter_tags_by_evidence(
        self,
        tags: List[str],
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]],
        quotes: Optional[Dict[str, str]] = None,
        nutrition: Any = None,
        categories: Any = None,
        chef_tag: str = "",
    ) -> List[str]:
        """통과한 LLM 칩을 전부 모은 뒤 캡션·정체성으로 보강하고 3개로 순위."""
        kept: List[str] = []
        expanded: List[str] = []
        for tag in tags:
            expanded.extend(self._expand_raw_tag(str(tag or "")))
        for t in expanded:
            t = self.TAG_ALIAS_MAP.get(t, t)
            if not t or t in kept:
                continue
            if not self._tag_passes_guards(
                t, title, description, transcript, recipe, quotes, nutrition, categories,
            ):
                print(f"[Tags] drop '{t}'")
                continue
            kept.append(t)
        padded = self._pad_display_tags(
            kept, title, description, transcript, recipe, quotes, nutrition, categories,
        )
        if "아이간식" in padded or "아이용" in padded:
            padded = [t for t in padded if t != "간식용"]
        if "술안주" in padded:
            padded = [t for t in padded if t != "간식용"]
        if "크리미한" in padded:
            padded = [t for t in padded if t != "고소한"]
        if "쫀득한" in padded:
            padded = [t for t in padded if t != "쫄깃한"]
        # 단짠단짠은 단맛·짠맛을 이미 담는다. 같은 맛을 두 칸 쓰지 않는다.
        if "단짠단짠" in padded:
            padded = [t for t in padded if t not in {"달달한", "짭짤한"}]
        if "달큰한" in padded:
            padded = [t for t in padded if t != "달달한"]
        padded = [
            t for t in padded
            if t not in self.TAG_USAGE_AS_OCCASION and self._tag_chip_shape_ok(t)
        ]
        rec = recipe if isinstance(recipe, dict) else {}
        name = f"{title or ''} {rec.get('name') or ''}"
        food_now = set(self._food_character_tags(title, rec))
        written = f"{title or ''}\n{description or ''}"
        if (
            "고소한" in padded
            and "고소한" not in food_now
            and not re.search(r"고소", written)
            and re.search(r"(?:국|탕|찌개|전골|생채|겉절이)", name)
        ):
            padded = [t for t in padded if t != "고소한"]
        if "얼큰한" in padded:
            padded = [t for t in padded if t not in {"매콤한", "매운맛"}]
        if "시원한" in padded:
            padded = [t for t in padded if t not in {"얼큰한", "매콤한", "매운맛"}]
        written = f"{title or ''}\n{description or ''}"
        written_heat = bool(re.search(
            r"매콤|매운|얼큰|칼칼|불닭|(?<![가-힣])마라", written,
        )) and not self._HEAT_HEDGE_RE.search(written)
        written_other = bool(re.search(r"구수|고소|달달|단짠|새콤|향긋|속\s*편", written))
        if written_other and not written_heat:
            padded = [t for t in padded if t not in {"매콤한", "매운맛", "얼큰한"}]
        # 순한맛 라면, 깔끔 담백한 육수처럼 원문이 부정하면 재료 추정을 이긴다.
        if self._heat_denied_by_source(written, name):
            padded = [t for t in padded if t not in {"매콤한", "매운맛", "얼큰한"}]
        ranked = self._rank_card_tags(padded, chef_tag, written)
        if len(ranked) < 3:
            print(f"[Tags] still {len(ranked)} chips after pad: {ranked}")
        return ranked[:3]

    @classmethod
    def _map_occasion_id(cls, raw: str) -> str:
        """카드용 별칭이 상황 id를 덮어쓰지 않게 한다."""
        t = cls._normalize_tag_string(raw)
        if not t:
            return ""
        t = cls.TAG_OCCASION_ALIAS.get(t, t)
        if t in cls.TAG_OCCASION_EXTRA:
            return t
        aliased = cls.TAG_ALIAS_MAP.get(t, t)
        return cls.TAG_OCCASION_ALIAS.get(aliased, aliased)

    @classmethod
    def _token_hit_in_dish(cls, tok: str, dish: str) -> bool:
        """요리명에서 토큰을 찾되, 정체성을 바꾸는 접두어가 붙으면 무시한다."""
        deny = cls._OCCASION_TOKEN_PREFIX_DENY.get(tok)
        start = 0
        while True:
            idx = dish.find(tok, start)
            if idx < 0:
                return False
            if not deny or not re.search(deny, dish[:idx]):
                return True
            start = idx + 1

    @classmethod
    def _occasion_dish_match(cls, tag: str, name: str) -> bool:
        """요리명 데이터셋으로 상황 태그를 붙일 수 있는지."""
        dish = name or ""
        if not dish or not tag:
            return False
        for blocked in cls.TAG_OCCASION_INFER_NOT.get(tag) or []:
            if blocked and blocked in dish:
                return False
        for tok in cls.TAG_OCCASION_INFER.get(tag) or []:
            if not tok:
                continue
            if len(tok) <= 1:
                if dish.endswith(tok) or f"{tok} " in dish:
                    return True
                continue
            if cls._token_hit_in_dish(tok, dish):
                return True
        return False

    @classmethod
    def _occasion_infer_in_blob(cls, tag: str, blob: str, name: str) -> bool:
        """캠핑 코펠처럼 도구 토큰만 blob에서 본다. 요리명 토큰은 제목에 한정."""
        if not tag:
            return False
        for blocked in cls.TAG_OCCASION_INFER_NOT.get(tag) or []:
            if blocked and blocked in (name or ""):
                return False
        haystack = f"{name or ''}\n{blob or ''}" if tag in cls.TAG_OCCASION_INFER_BLOB_OK else (name or "")
        if not haystack:
            return False
        for tok in cls.TAG_OCCASION_INFER.get(tag) or []:
            if tok and cls._token_hit_in_dish(tok, haystack):
                return True
        return False

    @classmethod
    def _occasion_source_match(cls, tag: str, blob: str) -> bool:
        src = blob or ""
        if not src or not tag:
            return False
        if tag == "반주" and re.search(r"반죽|반주기", src):
            return bool(re.search(r"반주(?![죽기])", src))
        for tok in cls.TAG_OCCASION_SOURCE.get(tag) or []:
            if tok and tok in src:
                return True
        return False

    @classmethod
    def _occasion_tag_allowed(
        cls,
        tag: str,
        blob: str,
        name: str,
        recipe: Optional[Dict[str, Any]],
        caption: str = "",
    ) -> bool:
        """캡션이 그 상황을 말하거나, 해장국·김밥처럼 요리 정체성일 때만."""
        servings = 0.0
        try:
            servings = float((recipe or {}).get("servings") or 0)
        except (TypeError, ValueError):
            servings = 0.0
        hay = caption or blob
        if tag == "생일상":
            if re.search(r"산모용", hay) and not re.search(r"생일|생신|칠순|팔순", hay):
                return False
            if re.search(r"다이어트|감량|직원식", hay) and not re.search(
                r"생일|생신|칠순|팔순", hay,
            ):
                return False
        if tag == "비오는날":
            if re.search(r"습도|눅눅", hay) and not re.search(r"비\s*오|비오는날", hay):
                return False
        if tag == "불금":
            if re.search(r"금요일까지|까지\s*금요일", hay) and not re.search(
                r"불금|금요일\s*밤|금요일저녁", hay,
            ):
                return False
        # 구움과자·스낵은 캡션에 가족이 있어도 가족이 아님.
        if tag == "가족" and cls._SNACK_NAME_RE.search(name or hay):
            return False
        if tag in cls.TAG_OCCASION_NEEDS_CAPTION:
            return cls._occasion_source_match(tag, hay)
        if cls._occasion_dish_match(tag, name):
            if tag == "혼술" and servings > 2:
                return False
            if tag == "술자리" and servings == 1:
                return False
            return True
        return cls._occasion_infer_in_blob(tag, blob, name)

    _BABY_FOOD_RE = re.compile(r"이유식|유아식|아기|아가|돌\s*아기|아이\s*밥")
    # 어른 음주·데이트 상황과 안 맞는 태그.
    _OCCASION_NOT_FOR_BABY = {
        "데이트", "안주", "혼술", "술자리", "반주", "해장", "야식", "치팅데이", "불금",
    }
    # 디저트·음료 자리. 식사류에는 붙이지 않는다.
    _OCCASION_SNACK_ONLY = {"간식", "디저트", "홈카페", "영화볼때"}
    # 상 차림 상황. 요리명 국룰이나 캡션 언급이 있어야 한다.
    _OCCASION_MEAL_AXIS = ("아침", "브런치", "저녁", "야식", "간식", "디저트")
    _OCCASION_WHO_AXIS = ("혼밥", "가족")
    _OCCASION_TABLE_EVENT = {
        "생일상", "손님상", "홈파티", "집들이", "제사상", "명절", "새해",
    }
    _MEAL_DISH_NAME_RE = re.compile(
        r"김밥|주먹밥|덮밥|비빔밥|볶음밥|쌈밥|찌개|전골|국수|파스타|우동|라면|"
        r"수제비|칼국수|탕(?!수)|찜|조림|무침|구이",
    )

    @classmethod
    def _occasion_conflicts_dish(
        cls,
        tag: str,
        name: str,
        caption: str,
        recipe: Optional[Dict[str, Any]],
        display_tags: List[str],
    ) -> bool:
        """요리 종류와 상황이 모순되면 LLM이 골라도 막는다."""
        tags = set(display_tags or [])
        baby = bool(cls._BABY_FOOD_RE.search(f"{name}\n{caption}"))
        if baby and tag in cls._OCCASION_NOT_FOR_BABY:
            return True
        if tag in cls._OCCASION_SNACK_ONLY:
            # 한우소보로김밥의 '소보로'처럼, 식사 이름이면 간식 토큰이 이기지 못한다.
            if cls._MEAL_DISH_NAME_RE.search(name):
                return True
            if cls._occasion_dish_match(tag, name):
                return False
            snack = bool(
                cls._SNACK_NAME_RE.search(name)
                or cls._SWEET_NAME_RE.search(name)
                or {"간식용", "아이간식", "아이용"} & tags
                or re.search(r"티타임|디저트|커피|차\s*한\s*잔|홈카페|영화|간식", caption)
            )
            if not snack:
                return True
        if tag in cls._OCCASION_TABLE_EVENT:
            if cls._occasion_dish_match(tag, name):
                return False
            return not cls._occasion_source_match(tag, caption)
        if tag in {"아침", "브런치"}:
            # 글이 "오후 간식"이라고 못박으면 아침이 아니다. 해시태그는 근거가 아니다.
            plain = cls._strip_hashtags(caption)
            if re.search(r"아침|브런치|모닝", plain):
                return False
            return cls._snack_word_is_claim(plain, name)
        if tag in {"간식", "디저트"} and cls._BRUNCH_NAME_RE.search(name or ""):
            return True
        if tag == "운동후":
            if cls._occasion_dish_match("운동후", name):
                return False
            if {"고단백", "헬식", "다이어트", "저탄수"} & tags:
                return False
            return not re.search(r"단백질|고단백|운동|헬스|벌크|프로틴", caption or "")
        if tag == "혼밥":
            if cls._is_condiment_name(name) or "밑반찬" in tags:
                return True
            if (
                cls._SNACK_NAME_RE.search(name)
                or cls._SWEET_NAME_RE.search(name)
                or cls._FROZEN_SWEET_RE.search(name)
            ):
                return True
            try:
                servings = float((recipe or {}).get("servings") or 0)
            except (TypeError, ValueError):
                servings = 0.0
            if servings >= 3:
                return True
        if tag == "가족" and "밑반찬" in tags:
            return True
        return False

    def _normalize_occasion_tags(
        self,
        raw: Any,
        display_tags: List[str],
        title: str,
        description: str,
        transcript: str,
        recipe: Optional[Dict[str, Any]],
    ) -> List[str]:
        """상세용 상황 태그. LLM 판단이 우선. 캡션 단어 매칭으로 넣지 않음. 최대 4개."""
        self._ensure_occasion_catalog()
        blob = self._evidence_blob(title, description, transcript, recipe)
        caption = f"{title or ''}\n{(description or '')[:1200]}"
        caption = re.sub(r"#\S+", " ", caption)
        name = f"{title or ''} {(recipe or {}).get('name') or ''}"
        cleaned: List[str] = []
        seen = set()

        def _axis_taken(tag: str) -> bool:
            if tag in self._OCCASION_MEAL_AXIS:
                return any(x in seen for x in self._OCCASION_MEAL_AXIS)
            if tag in self._OCCASION_WHO_AXIS:
                return any(x in seen for x in self._OCCASION_WHO_AXIS)
            return False

        def _try_add(tag: str, from_llm: bool = False) -> None:
            if len(cleaned) >= 4:
                return
            t = tag
            if t not in self.TAG_OCCASION_EXTRA or t in seen:
                return
            if _axis_taken(t):
                return
            for blocked in self.TAG_OCCASION_INFER_NOT.get(t) or []:
                if blocked and blocked in name:
                    return
            if t == "아이용":
                return
            if t in {"가족", "혼밥"} and (
                self._SNACK_NAME_RE.search(name)
                or self._SWEET_NAME_RE.search(name)
                or self._FROZEN_SWEET_RE.search(name)
            ):
                return
            if self._occasion_conflicts_dish(
                t, name, caption, recipe, display_tags or [],
            ):
                return
            if from_llm:
                servings = 0.0
                try:
                    servings = float((recipe or {}).get("servings") or 0)
                except (TypeError, ValueError):
                    servings = 0.0
                if t == "혼술" and servings > 2:
                    return
                if t == "술자리" and servings == 1:
                    return
                # 캠핑·발렌타인만 캡션이 그 상황을 말해야 함. 가족/아침 같은 단어는 근거가 아님.
                if t in self.TAG_OCCASION_NEEDS_CAPTION:
                    if not self._occasion_source_match(t, caption):
                        return
            elif not self._occasion_tag_allowed(t, blob, name, recipe, caption):
                return
            seen.add(t)
            cleaned.append(t)

        values = raw if isinstance(raw, list) else []
        for item in values:
            if not isinstance(item, str):
                continue
            raw_n = self._normalize_tag_string(item)
            mapped = self._map_occasion_id(item)
            _try_add(mapped, from_llm=True)
            # 가족저녁 → 가족 + 저녁, 자취저녁 → 혼밥 + 저녁
            if raw_n in {"가족저녁", "자취저녁"}:
                _try_add("저녁", from_llm=True)
            if raw_n == "아이도시락":
                _try_add("도시락", from_llm=True)

        # 유아식은 카드 칩 아이용. 상황 태그로 다시 넣지 않는다.

        # 캡션이 그 상황 자체를 말한 경우만 (캠핑, 발렌타인, 산모용…).
        for tag_id in self._OCCASION_ID_ORDER:
            if tag_id not in self.TAG_OCCASION_NEEDS_CAPTION:
                continue
            if self._occasion_source_match(tag_id, caption):
                _try_add(tag_id)

        # 요리명 국룰 (감자탕→가족+저녁). 캡션 substring은 여기 없음.
        for tag_id in self._OCCASION_ID_ORDER:
            if (
                self._occasion_dish_match(tag_id, name)
                or self._occasion_infer_in_blob(tag_id, blob, name)
            ):
                _try_add(tag_id)

        def _bucket_of(tag: str) -> str:
            for bname, ids in self.TAG_OCCASION_BUCKETS.items():
                if tag in ids:
                    return bname
            return "other"

        used_buckets = {_bucket_of(t) for t in cleaned}
        # 카드 칩 → 상황 태그 (술안주→안주). 검색용이라 카드와 같이 둬도 된다.
        for card, occ in self.TAG_CARD_TO_OCCASION.items():
            if len(cleaned) >= 4:
                break
            if card not in (display_tags or []):
                continue
            bucket = _bucket_of(occ)
            if bucket in used_buckets and occ not in cleaned:
                continue
            before = len(cleaned)
            _try_add(occ, from_llm=True)
            if len(cleaned) > before:
                used_buckets.add(bucket)
        # 4개 미만이면 요리명 국룰로만 채운다. 캡션 단어로 채우지 않음.
        precious = {
            "데이트", "캠핑", "기념일", "크리스마스", "어버이날",
            "명절", "불금", "차박", "등산", "김장",
            "어린이날", "발렌타인", "할로윈", "수능", "새해",
            "산후조리", "어르신상", "제사상",
        }
        if len(cleaned) < 4:
            for tag_id in self._OCCASION_ID_ORDER:
                if len(cleaned) >= 4:
                    break
                if tag_id in precious:
                    continue
                bucket = _bucket_of(tag_id)
                if bucket in used_buckets:
                    continue
                if (
                    self._occasion_dish_match(tag_id, name)
                    or self._occasion_infer_in_blob(tag_id, blob, name)
                ):
                    before = len(cleaned)
                    _try_add(tag_id)
                    if len(cleaned) > before:
                        used_buckets.add(bucket)
        if "추운날" in cleaned and "더운날" in cleaned:
            cold_ok = self._occasion_dish_match("추운날", name)
            hot_ok = self._occasion_dish_match("더운날", name)
            if cold_ok and not hot_ok:
                cleaned = [t for t in cleaned if t != "더운날"]
            elif hot_ok and not cold_ok:
                cleaned = [t for t in cleaned if t != "추운날"]
            else:
                cleaned = [t for t in cleaned if t not in {"추운날", "더운날"}]
        # 아이스크림·젤라또는 티타임 간식이 아니라 디저트.
        if (
            self._FROZEN_SWEET_RE.search(name)
            or self._occasion_dish_match("디저트", name)
        ):
            if "간식" in cleaned:
                cleaned = ["디저트" if t == "간식" else t for t in cleaned]
            elif (
                "디저트" not in cleaned
                and "디저트" in self.TAG_OCCASION_EXTRA
                and not any(x in cleaned for x in self._OCCASION_MEAL_AXIS)
            ):
                cleaned.append("디저트")
        return cleaned

    # 한줄에서 이 요리를 다른 요리와 구분해 주지 않는 빈 단어.
    _TAGLINE_EMPTY_WORD_RE = re.compile(r"감칠맛|깊은\s*맛|풍미|특별한|완벽한|맛있는")
    # SKU를 바꾸면 다른 요리가 되는 제품. 한줄에 남긴다.
    _TAGLINE_KEEP_BRAND_RE = re.compile(
        r"신라면|불닭|짜파게티|진라면|안성탕면|너구리|짜파구리|오레오|"
        r"스팸|첵스|빼빼로|초코파이|약과",
    )

    def _clean_tagline(
        self,
        tagline: str,
        uploader: str,
        channel: str,
        products: Optional[List[Dict[str, Any]]] = None,
        title: str = "",
    ) -> str:
        """대체 가능한 식재료 브랜드와 계정 이름을 뗀다.

        '이랑온 채소 육수'→'채소 육수'. 캡션이 이름 붙인 표현('유유댁 황금비율')은
        소유격이 아니므로 그대로 둔다.
        """
        line = (tagline or "").strip()
        if not line:
            return ""
        # 공구·광고 브랜드는 요리를 바꾸지 않는다. 제목이나 킵 목록에 없으면 일반명으로.
        for prod in products or []:
            if not isinstance(prod, dict):
                continue
            brand = str(prod.get("name") or "").strip()
            generic = str(prod.get("generic") or "").strip()
            if len(brand) < 2 or not generic or brand == generic:
                continue
            if self._TAGLINE_KEEP_BRAND_RE.search(brand) or brand in (title or ""):
                continue
            line = line.replace(brand, generic)
        known = set(self._load_chef_tags())
        handles = {
            str(channel or "").split("|")[0].split("/")[0].strip().split(" ")[0],
            str(uploader or "").strip(),
        }
        for handle in handles:
            if len(handle) < 2 or handle in known:
                continue
            line = re.sub(
                rf"^{re.escape(handle)}(?:의|이|가)?\s*",
                "",
                line,
            ).strip()
        line = self._TAGLINE_EMPTY_WORD_RE.sub("", line)
        line = re.sub(r"\s{2,}", " ", line).strip(" ,·/-")
        if len(line) < 6:
            return ""
        return line

    def _enrich_recipe_character(
        self,
        recipe: Dict[str, Any],
        title: str,
        description: str,
        transcript: str,
        tags_raw: List[Any],
        uploader: str = "",
        channel: str = "",
        nutrition: Any = None,
        categories: Any = None,
    ) -> Dict[str, Any]:
        """extract 이후 전용 호출: 카드 태그 3개 + 원문 한줄소개 + 상황 태그."""
        if isinstance(tags_raw, str):
            tags_raw = [tags_raw]
        if not isinstance(tags_raw, list):
            tags_raw = []
        tagline = ""
        products: List[Dict[str, Any]] = []
        llm_tags: List[Any] = list(tags_raw)
        occasion_raw: List[Any] = []
        rating = "A"
        quotes: Dict[str, str] = {}
        macros = self._per_serving_macros(nutrition)
        chip_source = {
            "title": (title or "")[:200],
            "description": (description or "")[:1500],
            "captions": (transcript or "")[:1500],
            "uploader": uploader or "",
            "channel": channel or "",
            "categories": categories or {},
            "nutrition_per_serving": macros,
            "servings": (recipe or {}).get("servings"),
            "equipment": ((recipe or {}).get("equipment") or [])[:12],
        }
        line_source = {
            **chip_source,
            "description": (description or "")[:2200],
            "captions": (transcript or "")[:2200],
        }
        char: Dict[str, Any] = {}
        line_pack: Dict[str, Any] = {}
        llm_calls = 0
        timeout_s = float(os.getenv("TAG_CHARACTER_TIMEOUT_SECONDS", "12"))
        if (
            _character_enrich_enabled()
            and getattr(self, "llm_service", None) is not None
            and _recipe_has_character_source(recipe or {}, title, description, transcript)
        ):
            def _select_chips() -> Dict[str, Any]:
                return self.llm_service.select_recipe_character(
                    recipe=recipe or {},
                    ingredients=(recipe or {}).get("ingredients") or [],
                    source_text=chip_source,
                    occasion_catalog=self.occasion_catalog_prompt(),
                )

            def _write_line() -> Dict[str, Any]:
                return self.llm_service.write_recipe_tagline(
                    recipe=recipe or {},
                    ingredients=(recipe or {}).get("ingredients") or [],
                    source_text=line_source,
                )

            def _finished_result(fut: Any, label: str) -> Dict[str, Any]:
                if fut is None or not fut.done():
                    print(f"[character] {label} timeout — skip that call")
                    return {}
                try:
                    val = fut.result(timeout=0)
                    return val if isinstance(val, dict) else {}
                except Exception as exc:
                    print(f"[character] {label} failed ({exc}) — skip that call")
                    return {}

            sem = _enrich_semaphore()
            acquired = False
            # 바쁜 슬롯에 13초 서지 않는다. 파싱 완료가 칩보다 우선.
            acquired = sem.acquire(timeout=min(1.0, max(0.05, timeout_s)))
            try:
                if acquired:
                    llm_calls = 2
                    pool = _enrich_pool()
                    f_chips = pool.submit(_select_chips)
                    f_line = pool.submit(_write_line)
                    futures_wait(
                        {f_chips, f_line},
                        timeout=max(0.05, timeout_s),
                    )
                    char = _finished_result(f_chips, "select_character")
                    line_pack = _finished_result(f_line, "write_tagline")
                else:
                    print("[character] enrich semaphore busy — fallback extract tags")
            except Exception as exc:
                print(f"[character] dedicated select failed ({exc}) — fallback extract tags")
            finally:
                if acquired:
                    sem.release()
            tagline = str(line_pack.get("tagline") or char.get("tagline") or "").strip()[:80]
            products = self._normalize_mentioned_products(
                line_pack.get("mentioned_products") or char.get("mentioned_products")
            )
            tagline = self._clean_tagline(tagline, uploader, channel, products, title)
            if isinstance(char.get("tags"), list) and char.get("tags"):
                llm_tags = list(char["tags"]) + list(tags_raw)
            if isinstance(char.get("occasion_tags"), list):
                occasion_raw = list(char.get("occasion_tags") or [])
            rating = str(char.get("nutrition_rating") or "A")
            if rating not in {"A", "B", "C"}:
                rating = "A"
            for ev in char.get("tag_evidence") or []:
                if not isinstance(ev, dict):
                    continue
                q_tag = str(ev.get("tag") or "").strip()
                q_text = str(ev.get("quote") or "").strip()
                if q_tag and q_text:
                    quotes[self.TAG_ALIAS_MAP.get(q_tag, q_tag)] = q_text
        usage_from_chips: List[str] = []
        tags = self._normalize_and_limit_tags(
            tags_raw=llm_tags,
            title=title,
            description=description,
            transcript=transcript,
            uploader=uploader,
            channel=channel,
            usage_out=usage_from_chips,
        )
        tags = self._filter_tags_by_evidence(
            tags,
            title,
            description,
            transcript,
            recipe,
            quotes,
            nutrition=nutrition,
            categories=categories,
        )
        extra_use: List[str] = []
        kept_chips: List[str] = []
        for t in tags:
            mapped = self.TAG_USAGE_AS_OCCASION.get(t)
            if mapped:
                extra_use.extend(self._usage_occasion_ids(t, mapped))
            else:
                kept_chips.append(t)
        tags = kept_chips
        occasion_tags = self._normalize_occasion_tags(
            list(occasion_raw) + usage_from_chips + extra_use,
            tags, title, description, transcript, recipe,
        )
        return {
            "tags": tags,
            "nutrition_rating": rating,
            "tagline": tagline,
            "mentioned_products": products,
            "occasion_tags": occasion_tags,
            "llm_calls": llm_calls,
        }

    def _character_source_fields(self, char: Dict[str, Any]) -> Dict[str, Any]:
        """source dict에 넣을 칩/한줄/상황 필드. 빈 상품 목록은 생략."""
        fields: Dict[str, Any] = {
            "tags": char.get("tags") or [],
            "nutrition_rating": char.get("nutrition_rating") or "A",
            "tagline": char.get("tagline") or "",
            "occasionTags": char.get("occasion_tags") or [],
        }
        products = char.get("mentioned_products") or []
        if products:
            fields["mentionedProducts"] = products
        return fields

    def _normalize_and_limit_tags(
        self,
        tags_raw: List[Any],
        title: str,
        description: str,
        transcript: str,
        uploader: str = "",
        channel: str = "",
        usage_out: Optional[List[str]] = None,
    ) -> List[str]:
        """태그 정규화. 필터·순위 전 최대 12개. 셰프가 있으면 맨 앞.
        아침용·아이간식 같은 쓰임은 카드에 안 올리고 usage_out으로 넘긴다.
        """
        cleaned: List[str] = []
        seen_cleaned = set()
        usage_occasions: List[str] = []
        for tag in tags_raw:
            if not isinstance(tag, str):
                continue
            for piece in self._expand_raw_tag(tag):
                t = self.TAG_ALIAS_MAP.get(piece, piece)
                if not t:
                    continue
                if not re.search(r"[가-힣a-zA-Z0-9]", t):
                    continue
                mapped_use = self.TAG_USAGE_AS_OCCASION.get(t)
                if mapped_use:
                    if t == "아이간식" and not self._kid_snack_claimed(
                        title, description, "",
                    ):
                        mapped_use = "간식"
                    if t == "아이반찬" and not self._kid_banchan_claimed(
                        title, description, "",
                    ):
                        continue
                    for occ in self._usage_occasion_ids(t, mapped_use):
                        if occ not in usage_occasions:
                            usage_occasions.append(occ)
                    continue
                if not self._tag_chip_shape_ok(t):
                    continue
                if t in self.TAG_NEVER_EMIT:
                    continue
                self._ensure_occasion_catalog()
                card_vocab = (
                    self.TAG_FORMAT | self.TAG_GOAL | self.TAG_TASTE | self.TAG_TEXTURE
                    | self.TAG_OCCASION
                )
                if t in (self.TAG_OCCASION_EXTRA - self.TAG_OCCASION) and t not in card_vocab:
                    occ = self._map_occasion_id(t)
                    if occ and occ not in usage_occasions:
                        usage_occasions.append(occ)
                    continue
                if t in seen_cleaned:
                    continue
                seen_cleaned.add(t)
                cleaned.append(t)

        known_chefs = self._load_chef_tags()
        chef_tag = self._detect_chef_tag(
            title, description, transcript, known_chefs,
            uploader=uploader, channel=channel,
        )

        # Accept LLM-proposed chef names — STRICT:
        #   (a) if already in our curated DB, use it; or
        #   (b) only auto-learn a NEW name when ALL hold:
        #       - 2-6 한글, not a descriptor/stopword
        #       - NOT the channel/uploader name
        #       - LLM verification confirms it's a real famous chef
        if not chef_tag:
            for t in cleaned:
                if t in known_chefs and t not in self.STATIC_ALLOWED_TAGS:
                    chef_tag = t
                    break
                if t in self.STATIC_ALLOWED_TAGS or t in self.CHEF_STOPWORDS:
                    continue
                if self._is_open_descriptor(t):
                    continue
                if not re.fullmatch(r"[가-힣]{2,6}", t):
                    continue
                if not self._verify_chef_with_llm(t):
                    continue
                known_chefs.append(t)
                self._save_chef_tags(known_chefs)
                print(f"[Tags] Added new chef tag from LLM: {t}")
                chef_tag = t
                break

        preferred = (
            self.TAG_FORMAT | self.TAG_GOAL | self.TAG_OCCASION | self.TAG_TASTE | self.TAG_TEXTURE
        )
        result: List[str] = []
        if chef_tag:
            result.append(chef_tag)
        for t in cleaned:
            if len(result) >= 12:
                break
            if t == chef_tag:
                continue
            if t in self.TAG_NEVER_EMIT or t in self.TAG_LEGACY:
                continue
            if t in preferred or self._is_open_descriptor(t):
                result.append(t)

        if not result:
            merged = f"{title or ''}\n{description or ''}"
            fallback_hits = [
                (r"원팬|원팟|팬\s*하나", "원팬"),
                (r"에어프라이어|에어후라이", "에어프라이어"),
                (r"전자레인지|전자렌지", "전자레인지"),
                (r"압력솥|인스턴트팟", "압력솥"),
                (r"노밀가루|밀가루\s*없이", "노밀가루"),
                (r"고단백|단백질", "고단백"),
                (r"만능양념|만능장|만능간장", "만능양념"),
                (r"한그릇|덮밥|국밥", "한그릇"),
                (r"겉바속촉", "겉바속촉"),
                (r"10분컷|초간편|초간단", "10분컷"),
            ]
            for pat, tag in fallback_hits:
                if len(result) >= 12:
                    break
                if tag not in result and re.search(pat, merged):
                    result.append(tag)

        if usage_out is not None:
            for occ in usage_occasions:
                if occ not in usage_out:
                    usage_out.append(occ)
        return result[:12]

