"""홈 CMS 시드 — 현 Dart 상수 + home_section_rules.json 과 동기."""

from __future__ import annotations

from typing import Any

SCHEMA_VERSION = 1
MAX_ENABLED_POSTERS = 8
MAX_ENABLED_TREND_SECTIONS = 16

# (sectionKey, label, kind, order, members_only)
SECTION_UI: list[tuple[str, str, str, int, bool]] = [
    ("program_pyeonstorang", "편스토랑", "program", 0, False),
    ("program_fridge", "냉장고를 부탁해", "program", 1, False),
    ("program_best_cooking", "최고의 요리비결", "program", 2, False),
    ("program_culinary_class_wars", "흑백요리사", "program", 3, False),
    ("program_street_restaurant_fighter", "스트릿 레스토랑 파이터", "program", 4, False),
    ("program_bake_your_dream", "천하제빵", "program", 5, False),
    ("program_altoran", "알토란", "program", 6, False),
    ("program_sumi_side_dishes", "수미네 반찬", "program", 7, False),
    ("program_home_food_baek", "집밥 백선생", "program", 8, False),
    ("program_korean_food_battle", "한식대첩", "program", 9, False),
    ("sauce", "만들어두면 든든한 소스·양념", "trend", 10, False),
    ("dessert", "달콤한 디저트 한 입", "trend", 11, False),
    ("baby_food", "우리 아기 이유식·유아식", "trend", 20, True),
    ("moment_late_night", "출출한 밤, 야식 한 입", "moment", 21, True),
    ("moment_morning", "든든한 아침 집밥 한 끼", "moment", 22, True),
    ("moment_guest", "손님 부르는 날, 그럴듯한 한 상", "moment", 23, True),
    ("moment_solo", "혼밥인데 대충 안 하고 싶을 때", "moment", 24, True),
    ("moment_dinner", "오늘 저녁 집밥 뭐 만들지", "moment", 25, True),
    ("world_cup", "맥주 곁들이는 안주 한 상", "trend", 26, True),
    ("quick_10min", "10분 완성 레시피", "trend", 30, True),
    ("ingredients_5", "5가지 재료로 끝", "trend", 31, True),
    ("comfort_bowl", "뜨끈한 국물 한 그릇", "trend", 32, True),
    ("high_protein", "단백질 많은", "trend", 33, True),
    ("lean_strong", "고단백 저지방", "trend", 34, True),
]

_LOW_SUGAR = [
    "알룰로스", "저당", "무설탕", "제로슈거", "제로 슈거",
    "마이노멀", "설탕없이", "설탕 없이", "당질오프", "저칼로리",
]


def poster_seeds() -> list[dict[str, Any]]:
    """홈 포스터 3장 (home_poster_curations.dart 와 동일)."""
    return [
        {
            "id": "first_main_for_two",
            "order": 0,
            "enabled": True,
            "assetPath": "assets/images/home_poster_1.png",
            "imageUrl": None,
            "posterTitle": "더위야,\n물러가라",
            "subtitle": "더운 날 둘이 먹기 좋은 시원한 메뉴",
            "eyebrow": "여름 메뉴 큐레이션",
            "pageTitle": "더위야, 물러가라",
            "body": "불 앞에 오래 서지 않아도 괜찮아요.\n더위를 식혀 줄 시원한 메뉴만 골랐어요.",
            "chips": [
                {"label": "전체", "sectionKey": "poster_summer_all", "matchKeywords": []},
                {"label": "냉면·밀면", "sectionKey": "poster_summer_cold_noodle", "matchKeywords": []},
                {"label": "국수·소바", "sectionKey": "poster_summer_guksu", "matchKeywords": []},
                {"label": "냉국·묵", "sectionKey": "poster_summer_cold_soup", "matchKeywords": []},
                {"label": "냉채·샐러드", "sectionKey": "poster_summer_salad", "matchKeywords": []},
            ],
            "poolSectionKeys": [],
            "tips": [],
            "products": [],
            "recipeSectionTitle": "레시피 고르기",
            "productsSectionTitle": "추천 상품",
            "showFridgeCta": False,
            "strictKeywordMatch": False,
            "imageAlignment": "centerRight",
        },
        {
            "id": "mynormal_low_sugar",
            "order": 1,
            "enabled": True,
            "assetPath": "assets/images/home_poster_2.png",
            "imageUrl": None,
            "posterTitle": "설탕은 빼고,\n맛은 그대로",
            "subtitle": "마이노멀로 완성하는 저당 저녁",
            "eyebrow": "마이노멀 저당 큐레이션",
            "pageTitle": "설탕은 빼고, 맛은 그대로",
            "body": (
                "마이노멀은 저당 식품을 만드는 브랜드예요.\n"
                "아래에서 가장 잘 나가는 베스트 제품을 먼저 보고, "
                "그다음 어울리는 저당 레시피를 골라보세요."
            ),
            "poolSectionKeys": ["ingredients_5", "quick_10min", "moment_dinner"],
            "strictKeywordMatch": True,
            "productsSectionTitle": "마이노멀 베스트",
            "recipeSectionTitle": "저당 레시피 고르기",
            "tips": [
                {
                    "title": "알룰로스가 뭔가요?",
                    "body": "설탕과 비슷한 단맛이지만 칼로리·혈당 부담이 적은 대체당이에요.",
                    "icon": "science_outlined",
                },
                {
                    "title": "마이노멀로 바꾸는 법",
                    "body": "평소 쓰는 마요네즈·잼·고추장·땅콩버터만 마이노멀로 바꿔도 저녁이 가벼워져요.",
                    "icon": "swap_horiz_rounded",
                },
                {
                    "title": "저당 저녁 팁",
                    "body": "단맛이 필요한 소스·드레싱에만 쓰고, 짠맛·감칠맛은 간장·마늘로 잡으세요.",
                    "icon": "restaurant_outlined",
                },
            ],
            "products": [
                {
                    "id": "mn_mayo",
                    "name": "엑스트라버진 올리브오일 마요네즈",
                    "subtitle": "260g · 샐러드·샌드위치에 바로",
                    "badge": "마요네즈",
                    "priceLabel": "10,900원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20260121_257/1768973950609ouoXs_JPEG/96008292651474770_326431765.jpg",
                    "productUrl": "https://naver.me/GgUvK4ub",
                    "searchQuery": "마이노멀 올리브오일 마요네즈",
                },
                {
                    "id": "mn_dressing",
                    "name": "저당 유자 드레싱",
                    "subtitle": "샐러드용 저당 소스",
                    "badge": "드레싱",
                    "priceLabel": "7,980원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20241113_67/1731459529295r9Np8_JPEG/16416114346796182_1574435118.jpg",
                    "productUrl": "https://naver.me/Ge7JQf5q",
                    "searchQuery": "마이노멀 저당 드레싱",
                },
                {
                    "id": "mn_peanut_butter",
                    "name": "무가당 땅콩버터 100%",
                    "subtitle": "크런치·크리미 선택",
                    "badge": "땅콩버터",
                    "priceLabel": "11,900원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20260123_248/17691465198310Lclx_JPEG/98508137355100628_669714175.jpg",
                    "productUrl": "https://naver.me/GVVHKrU8",
                    "searchQuery": "마이노멀 무가당 땅콩버터",
                },
                {
                    "id": "mn_strawberry_jam",
                    "name": "저당 저칼로리 딸기잼 320g",
                    "subtitle": "토스트·요거트용 베스트",
                    "badge": "딸기잼",
                    "priceLabel": "12,900원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20230202_74/1675327151659RIn30_JPEG/76462935375317573_16105138.jpg",
                    "productUrl": "https://naver.me/xsZHLtSl",
                    "searchQuery": "마이노멀 저당 딸기잼",
                },
                {
                    "id": "mn_allulose_907",
                    "name": "대용량 알룰로스 1.2kg",
                    "subtitle": "설탕 대신 쓰는 대용량",
                    "badge": "알룰로스",
                    "priceLabel": "15,800원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20250723_26/1753261731153R55Ji_PNG/16506502958274265_1674444752.png",
                    "productUrl": "https://naver.me/xG0ejV3u",
                    "searchQuery": "마이노멀 알룰로스 1.2kg",
                },
                {
                    "id": "mn_gochujang",
                    "name": "국산 저당 태양초 고추장",
                    "subtitle": "230g · 볶음·비빔용",
                    "badge": "고추장",
                    "priceLabel": "12,900원",
                    "imageUrl": "https://shop-phinf.pstatic.net/20241112_279/1731374434612foMbR_JPEG/62096963489895494_1725665745.jpg",
                    "productUrl": "https://naver.me/F1a1d3fa",
                    "searchQuery": "마이노멀 저당 고추장",
                },
            ],
            "chips": [
                {"label": "전체", "sectionKey": None, "matchKeywords": list(_LOW_SUGAR)},
                {"label": "알룰로스", "sectionKey": None, "matchKeywords": ["알룰로스", "allulose", "저당", "무설탕", "제로슈거"]},
                {"label": "마요네즈", "sectionKey": None, "matchKeywords": ["마요", "마요네즈", "감자샐러드", "샌드위치", "샐러드"]},
                {"label": "드레싱", "sectionKey": None, "matchKeywords": ["드레싱", "샐러드", "유자", "시저"]},
                {"label": "고추장", "sectionKey": None, "matchKeywords": ["고추장", "제육", "비빔밥", "떡볶이"]},
                {"label": "땅콩버터", "sectionKey": None, "matchKeywords": ["땅콩버터", "피넛버터", "땅콩", "토스트"]},
                {"label": "딸기잼", "sectionKey": None, "matchKeywords": ["딸기잼", "잼", "토스트", "요거트", "딸기"]},
                {"label": "간식", "sectionKey": None, "matchKeywords": ["초콜릿", "초코", "쿠키", "저당", "디저트"]},
            ],
            "showFridgeCta": False,
            "imageAlignment": "centerRight",
        },
        {
            "id": "newlywed_kitchen_starter",
            "order": 2,
            "enabled": True,
            "assetPath": "assets/images/home_poster_3.png",
            "imageUrl": None,
            "posterTitle": "서툴러도 괜찮아,\n오늘도 한 그릇 완성",
            "subtitle": "요리가 처음인 우리를 위한 쉬운 저녁",
            "eyebrow": "초보 키친 가이드",
            "pageTitle": "서툴러도 괜찮아, 오늘도 한 그릇 완성",
            "body": "완벽한 요리보다, 오늘 한 그릇이면 충분해요.\n실패 적은 쉬운 저녁만 골랐어요.",
            "poolSectionKeys": [],
            "tips": [
                {
                    "title": "재료는 5개 안쪽",
                    "body": "재료가 적을수록 실패도 줄어요. 오늘 쓸 재료만 꺼내 두세요.",
                    "icon": "shopping_basket_outlined",
                },
                {
                    "title": "팬 하나만 쓰기",
                    "body": "중형 프라이팬 하나면 대부분 집밥이 가능해요.",
                    "icon": "soup_kitchen_outlined",
                },
                {
                    "title": "양념은 계량부터",
                    "body": "간장·기름·고춧가루 비율만 맞춰도 맛이 안정돼요.",
                    "icon": "scale_outlined",
                },
            ],
            "products": [],
            "recipeSectionTitle": "쉬운 저녁 고르기",
            "productsSectionTitle": "추천 상품",
            "chips": [
                {"label": "전체", "sectionKey": "poster_beginner_10min", "matchKeywords": []},
                {"label": "10분", "sectionKey": "poster_beginner_10min", "matchKeywords": []},
                {"label": "재료 적게", "sectionKey": "ingredients_5", "matchKeywords": []},
                {"label": "한 그릇", "sectionKey": "poster_beginner_one_bowl", "matchKeywords": []},
                {
                    "label": "계란부터",
                    "sectionKey": "quick_10min",
                    "matchKeywords": ["계란", "달걀", "스크램블", "오므라이스", "계란말이"],
                },
            ],
            "showFridgeCta": False,
            "strictKeywordMatch": False,
            "imageAlignment": "centerRight",
        },
    ]


def poster_pool_section_keys() -> list[str]:
    keys: list[str] = []
    seen: set[str] = set()
    for poster in poster_seeds():
        for chip in poster.get("chips") or []:
            sk = (chip.get("sectionKey") or "").strip()
            if sk.startswith("poster_") and sk not in seen:
                seen.add(sk)
                keys.append(sk)
    return keys
