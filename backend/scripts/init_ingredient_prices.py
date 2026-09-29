"""
인터넷 검색으로 수집한 재료별 단위당 평균 가격을 Firebase에 저장하는 스크립트
"""
import sys
import os
from datetime import datetime
from typing import Dict, Any

# 경로 설정
current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
sys.path.insert(0, parent_dir)

# .env 로드 (backend 디렉터리의 .env 사용)
try:
    from dotenv import load_dotenv
    env_path = os.path.join(parent_dir, '.env')
    load_dotenv(dotenv_path=env_path)
except ImportError:
    pass

from services.firebase_service import get_firebase_service
from services.product_service import INGREDIENT_MAPPING
from firebase_admin import firestore
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _load_all_scraping_ingredient_names():
    """스크래핑 재료 전체 목록 로드 (updated_ingredients.py와 동기화)."""
    try:
        from scripts.updated_ingredients import ALL_INGREDIENTS_WITH_FREQ
        return list(dict.fromkeys(name for name, _ in ALL_INGREDIENTS_WITH_FREQ))
    except Exception:
        pass
    # 폴백: 같은 디렉터리의 updated_ingredients.py 파일에서 파싱
    import ast
    path = os.path.join(current_dir, "updated_ingredients.py")
    if not os.path.isfile(path):
        return list(INGREDIENT_PRICES.keys())
    with open(path, "r", encoding="utf-8") as f:
        tree = ast.parse(f.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "ALL_INGREDIENTS_WITH_FREQ":
                    names = []
                    if isinstance(node.value, ast.List):
                        for tup in node.value.elts:
                            if isinstance(tup, ast.Tuple) and len(tup.elts) >= 1:
                                elt0 = tup.elts[0]
                                if isinstance(elt0, ast.Constant) and isinstance(elt0.value, str):
                                    names.append(elt0.value)
                    return list(dict.fromkeys(names))
    return list(INGREDIENT_PRICES.keys())


# 스크래핑 전체 재료명 (INGREDIENT_PRICES 정의 후 초기화됨)
ALL_SCRAPING_INGREDIENT_NAMES = None

# 카테고리별 기본 단가 (수동 데이터 없을 때 사용). (unitPrice, baseUnit)
# 각 카테고리의 원래 단위 유지 (g, ml, 개)
DEFAULT_UNIT_PRICE_BY_CATEGORY = {
    "GRAIN": (2, "g"),  # 2원/g
    "POWDER_SEASONING": (10, "g"),  # 10원/g
    "NOODLE": (3, "g"),  # 3원/g
    "VEG_WEIGHT": (2, "g"),  # 2원/g
    "VEG_COUNT": (1000, "개"),  # 1000원/개
    "MEAT": (40, "g"),  # 40원/g
    "SEAFOOD": (30, "g"),  # 30원/g
    "LIQUID": (10, "ml"),  # 10원/ml
    "PROCESSED_COUNT": (2000, "개"),  # 2000원/개
    "EGG": (200, "개"),  # 200원/개
}


# 인터넷 검색으로 수집한 재료별 단위당 평균 가격 데이터
# 형식: {재료명: {"unitPrice": 가격, "baseUnit": 단위}}
# 각 재료의 원래 단위 유지 (g, ml, 개) - 프론트엔드에서 요구 단위에 맞춰 변환
INGREDIENT_PRICES = {
    # GRAIN (곡물) - 1g당 가격
    "쌀": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "현미": {"unitPrice": 2.5, "baseUnit": "g"},  # 2500원/1kg → 2.5원/g
    "밀가루": {"unitPrice": 1.5, "baseUnit": "g"},  # 1500원/1kg → 1.5원/g
    "찹쌀": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    "잡곡": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "오트밀": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    
    # POWDER_SEASONING (조미료) - 1g당 가격
    "고추장": {"unitPrice": 8, "baseUnit": "g"},  # 4000원/500g → 8원/g
    "된장": {"unitPrice": 6, "baseUnit": "g"},  # 6000원/1kg → 6원/g
    "쌈장": {"unitPrice": 10, "baseUnit": "g"},  # 10000원/1kg → 10원/g
    "설탕": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "소금": {"unitPrice": 0.5, "baseUnit": "g"},  # 500원/1kg → 0.5원/g
    "고춧가루": {"unitPrice": 15, "baseUnit": "g"},  # 7500원/500g → 15원/g
    "후추": {"unitPrice": 50, "baseUnit": "g"},  # 5000원/100g → 50원/g
    "다시다": {"unitPrice": 20, "baseUnit": "g"},
    "미원": {"unitPrice": 30, "baseUnit": "g"},
    "통깨": {"unitPrice": 20, "baseUnit": "g"},
    "파슬리": {"unitPrice": 100, "baseUnit": "g"},
    "카레가루": {"unitPrice": 10, "baseUnit": "g"},
    "전분": {"unitPrice": 2, "baseUnit": "g"},
    "빵가루": {"unitPrice": 3, "baseUnit": "g"},
    "계피가루": {"unitPrice": 100, "baseUnit": "g"},
    "이스트": {"unitPrice": 50, "baseUnit": "g"},
    "베이킹파우더": {"unitPrice": 100, "baseUnit": "g"},
    "코코아파우더": {"unitPrice": 50, "baseUnit": "g"},
    
    # NOODLE (면류) - 1g당 가격
    "소면": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "파스타면": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    "당면": {"unitPrice": 4, "baseUnit": "g"},  # 4000원/1kg → 4원/g
    "칼국수면": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "메밀면": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    "쫄면": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "우동면": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    
    # VEG_WEIGHT (중량 단위 채소) - 1g당 가격
    "대파": {"unitPrice": 20, "baseUnit": "g"},  # 20000원/1kg → 20원/g
    "다진 마늘": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "마늘": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "당근": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "콩나물": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "숙주": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "시금치": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    "깻잎": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "상추": {"unitPrice": 3, "baseUnit": "g"},  # 3000원/1kg → 3원/g
    "양파": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "배추": {"unitPrice": 0.8, "baseUnit": "g"},  # 800원/1kg → 0.8원/g
    "무": {"unitPrice": 0.5, "baseUnit": "g"},  # 500원/1kg → 0.5원/g
    "감자": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "양배추": {"unitPrice": 1, "baseUnit": "g"},  # 1000원/1kg → 1원/g
    "고구마": {"unitPrice": 1.5, "baseUnit": "g"},  # 1500원/1kg → 1.5원/g
    "연근": {"unitPrice": 10, "baseUnit": "g"},  # 10000원/1kg → 10원/g
    "우엉": {"unitPrice": 5, "baseUnit": "g"},  # 5000원/1kg → 5원/g
    "미나리": {"unitPrice": 20, "baseUnit": "g"},  # 20000원/1kg → 20원/g
    "부추": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "쪽파": {"unitPrice": 40, "baseUnit": "g"},  # 40000원/1kg → 40원/g
    "청경채": {"unitPrice": 2, "baseUnit": "g"},  # 2000원/1kg → 2원/g
    "미역": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "다시마": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "생강": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "바질": {"unitPrice": 100, "baseUnit": "g"},  # 100000원/1kg → 100원/g
    "로즈마리": {"unitPrice": 150, "baseUnit": "g"},  # 150000원/1kg → 150원/g
    "월계수잎": {"unitPrice": 100, "baseUnit": "g"},  # 100000원/1kg → 100원/g
    
    # VEG_COUNT (개수 단위 채소) - 1개당 가격
    "애호박": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개 (약 350g)
    "오이": {"unitPrice": 500, "baseUnit": "개"},  # 500원/개
    "가지": {"unitPrice": 800, "baseUnit": "개"},  # 800원/개
    "파프리카": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개
    "아보카도": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "브로콜리": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개 (약 350g)
    "단호박": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "레몬": {"unitPrice": 1000, "baseUnit": "개"},  # 1000원/개
    "토마토": {"unitPrice": 800, "baseUnit": "개"},  # 800원/개
    "방울토마토": {"unitPrice": 500, "baseUnit": "개"},  # 500원/개
    "팽이버섯": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개(팩)
    "표고버섯": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "새송이버섯": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개
    "청양고추": {"unitPrice": 300, "baseUnit": "개"},  # 300원/개 (약 12g)
    "버섯": {"unitPrice": 12, "baseUnit": "g"},  # generic mushroom fallback, 12원/g
    
    # MEAT (육류) - 1g당 가격
    "돼지고기 삼겹살": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "돼지고기 목살": {"unitPrice": 40, "baseUnit": "g"},  # 40000원/1kg → 40원/g
    "돼지고기 앞다리살": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "소고기 국거리": {"unitPrice": 80, "baseUnit": "g"},  # 80000원/1kg → 80원/g
    "소고기 구이용": {"unitPrice": 150, "baseUnit": "g"},  # 150000원/1kg → 150원/g
    "닭고기": {"unitPrice": 20, "baseUnit": "g"},  # 20000원/1kg → 20원/g
    "닭가슴살": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "베이컨": {"unitPrice": 80, "baseUnit": "g"},  # 80000원/1kg → 80원/g
    
    # SEAFOOD (수산물) - 1g당 가격
    "고등어": {"unitPrice": 20, "baseUnit": "g"},  # 20000원/1kg → 20원/g
    "갈치": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "오징어": {"unitPrice": 40, "baseUnit": "g"},  # 40000원/1kg → 40원/g
    "낙지": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "쭈꾸미": {"unitPrice": 40, "baseUnit": "g"},  # 40000원/1kg → 40원/g
    "꽃게": {"unitPrice": 60, "baseUnit": "g"},  # 60000원/1kg → 60원/g
    "냉동새우": {"unitPrice": 50, "baseUnit": "g"},  # 50000원/1kg → 50원/g
    "새우": {"unitPrice": 60, "baseUnit": "g"},  # 60000원/1kg → 60원/g
    "바지락": {"unitPrice": 10, "baseUnit": "g"},  # 10000원/1kg → 10원/g
    "홍합": {"unitPrice": 20, "baseUnit": "g"},  # 20000원/1kg → 20원/g
    "전복": {"unitPrice": 200, "baseUnit": "g"},  # 200000원/1kg → 200원/g
    "굴": {"unitPrice": 30, "baseUnit": "g"},  # 30000원/1kg → 30원/g
    "멸치": {"unitPrice": 10, "baseUnit": "g"},  # 10000원/1kg → 10원/g
    "명란젓": {"unitPrice": 100, "baseUnit": "g"},  # 100000원/1kg → 100원/g
    
    # LIQUID (액체류) - 1ml당 가격
    "진간장": {"unitPrice": 8, "baseUnit": "ml"},  # 4000원/500ml → 8원/ml
    "국간장": {"unitPrice": 6, "baseUnit": "ml"},  # 6000원/1L → 6원/ml
    "간장": {"unitPrice": 7, "baseUnit": "ml"},  # 7000원/1L → 7원/ml
    "식용유": {"unitPrice": 2, "baseUnit": "ml"},  # 1800원/900ml → 2원/ml
    "참기름": {"unitPrice": 50, "baseUnit": "ml"},  # 10000원/200ml → 50원/ml
    "올리브유": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "식초": {"unitPrice": 3, "baseUnit": "ml"},  # 3000원/1L → 3원/ml
    "맛술": {"unitPrice": 10, "baseUnit": "ml"},  # 10000원/1L → 10원/ml
    "케첩": {"unitPrice": 10, "baseUnit": "ml"},  # 10000원/1L → 10원/ml
    "마요네즈": {"unitPrice": 15, "baseUnit": "ml"},  # 15000원/1L → 15원/ml
    "우유": {"unitPrice": 2, "baseUnit": "ml"},  # 2000원/1L → 2원/ml
    "굴소스": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "액젓": {"unitPrice": 8, "baseUnit": "ml"},  # 8000원/1L → 8원/ml
    "올리고당": {"unitPrice": 15, "baseUnit": "ml"},  # 15000원/1L → 15원/ml
    "매실청": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "새우젓": {"unitPrice": 10, "baseUnit": "ml"},  # 10000원/1L → 10원/ml
    "생크림": {"unitPrice": 10, "baseUnit": "ml"},  # 10000원/1L → 10원/ml
    "휘핑크림": {"unitPrice": 12, "baseUnit": "ml"},  # 12000원/1L → 12원/ml
    "요거트": {"unitPrice": 3, "baseUnit": "ml"},  # 3000원/1L → 3원/ml
    "돈가스소스": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "데리야끼소스": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "칠리소스": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "머스터드": {"unitPrice": 30, "baseUnit": "ml"},  # 30000원/1L → 30원/ml
    "땅콩버터": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "바닐라익스트랙": {"unitPrice": 500, "baseUnit": "ml"},  # 500000원/1L → 500원/ml
    "마라소스": {"unitPrice": 20, "baseUnit": "ml"},  # 20000원/1L → 20원/ml
    "두반장": {"unitPrice": 15, "baseUnit": "ml"},  # 15000원/1L → 15원/ml
    "춘장": {"unitPrice": 10, "baseUnit": "ml"},  # 10000원/1L → 10원/ml
    "와사비": {"unitPrice": 100, "baseUnit": "ml"},  # 100000원/1L → 100원/ml
    
    # PROCESSED_COUNT (가공식품) - 1개당 가격
    "두부": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개
    "치즈": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개(팩)
    "모짜렐라": {"unitPrice": 4000, "baseUnit": "개"},  # 4000원/개
    "체다": {"unitPrice": 3500, "baseUnit": "개"},  # 3500원/개(팩)
    "버터": {"unitPrice": 5000, "baseUnit": "개"},  # 5000원/개
    "김": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개(팩)
    "참치캔": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "스팸": {"unitPrice": 4000, "baseUnit": "개"},  # 4000원/개
    "라면": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개
    "냉동만두": {"unitPrice": 5000, "baseUnit": "개"},  # 5000원/개
    "어묵": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "비엔나소시지": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "프랑크소시지": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "맛살": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "베이크드빈": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "옥수수콘": {"unitPrice": 1500, "baseUnit": "개"},  # 1500원/개
    "순대": {"unitPrice": 5000, "baseUnit": "개"},  # 5000원/개
    "쌈무": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "김치": {"unitPrice": 5, "baseUnit": "g"},  # generic kimchi fallback, 5원/g
    "라이스페이퍼": {"unitPrice": 3000, "baseUnit": "개"},  # 3000원/개
    "시리얼": {"unitPrice": 5000, "baseUnit": "개"},  # 5000원/개
    "떡국떡": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "떡볶이떡": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    "초콜릿": {"unitPrice": 2000, "baseUnit": "개"},  # 2000원/개
    
    # EGG (계란) - 1개당 가격
    "달걀": {"unitPrice": 200, "baseUnit": "개"},  # 200원/개
    "계란": {"unitPrice": 200, "baseUnit": "개"},  # 200원/개
}

# 스크래핑 전체 재료명 로드 (updated_ingredients.py 기준)
ALL_SCRAPING_INGREDIENT_NAMES = _load_all_scraping_ingredient_names()


def build_full_ingredient_prices():
    """스크래핑 전체 재료에 대해 수동 가격 또는 카테고리 기본가를 반환."""
    default_cat = "VEG_WEIGHT"
    default_price, default_unit = DEFAULT_UNIT_PRICE_BY_CATEGORY[default_cat]
    result = []
    for name in ALL_SCRAPING_INGREDIENT_NAMES:
        if name in INGREDIENT_PRICES:
            data = INGREDIENT_PRICES[name].copy()
            data["source"] = "manual_search"
        else:
            category = INGREDIENT_MAPPING.get(name, default_cat)
            unit_price, base_unit = DEFAULT_UNIT_PRICE_BY_CATEGORY.get(
                category, (default_price, default_unit)
            )
            data = {
                "unitPrice": unit_price,
                "baseUnit": base_unit,
                "source": "category_default",
            }
        result.append((name, data))
    return result


def save_ingredient_prices_to_firebase():
    """재료별 단위 가격을 Firebase에 저장"""
    firebase_service = get_firebase_service()
    
    if not firebase_service.is_available():
        logger.error("Firebase가 사용 불가능합니다.")
        return
    
    try:
        db = firebase_service.db
        if not db:
            logger.error("Firestore 클라이언트가 없습니다.")
            return
        
        collection_ref = db.collection("ingredient_unit_prices")
        full_prices = build_full_ingredient_prices()
        
        success_count = 0
        fail_count = 0
        manual_count = sum(1 for _, d in full_prices if d.get("source") == "manual_search")
        default_count = len(full_prices) - manual_count
        logger.info(f"저장 대상: 총 {len(full_prices)}개 (수동 {manual_count}개, 기본가 {default_count}개)")
        
        for ingredient_name, price_data in full_prices:
            try:
                doc_ref = collection_ref.document(ingredient_name)
                
                doc_ref.set({
                    "ingredientName": ingredient_name,
                    "baseUnit": price_data["baseUnit"],
                    "unitPrice": price_data["unitPrice"],
                    "source": price_data.get("source", "manual_search"),
                    "lastUpdated": firestore.SERVER_TIMESTAMP,
                }, merge=True)
                
                success_count += 1
                if price_data.get("source") == "category_default":
                    logger.debug(f"  {ingredient_name}: {price_data['unitPrice']}원/{price_data['baseUnit']} (기본가)")
                else:
                    logger.info(f"✅ {ingredient_name}: {price_data['unitPrice']}원/{price_data['baseUnit']}")
                
            except Exception as e:
                fail_count += 1
                logger.error(f"❌ {ingredient_name} 저장 실패: {e}")
        
        logger.info(f"\n완료: 성공 {success_count}개, 실패 {fail_count}개")
        
    except Exception as e:
        logger.error(f"Firebase 저장 중 오류: {e}", exc_info=True)


if __name__ == "__main__":
    save_ingredient_prices_to_firebase()





