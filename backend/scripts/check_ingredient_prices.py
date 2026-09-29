"""
Firebase에 저장된 재료별 단위 가격 데이터를 조회하는 스크립트
"""
import sys
import os
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
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def fetch_ingredient_prices_from_firebase():
    """Firebase에서 재료별 단위 가격 데이터를 조회"""
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
        
        # 모든 문서 조회
        logger.info("Firebase에서 재료 가격 데이터 조회 중...")
        docs = collection_ref.stream()
        
        prices = []
        for doc in docs:
            data = doc.to_dict()
            prices.append({
                'ingredientName': doc.id,
                'data': data
            })
        
        logger.info(f"\n총 {len(prices)}개의 재료 가격 데이터를 찾았습니다.\n")
        
        # 데이터 출력
        import sys
        try:
            sys.stdout.reconfigure(encoding='utf-8')
        except:
            pass
        
        print("=" * 80)
        print("재료별 단위 가격 데이터")
        print("=" * 80)
        
        # 샘플 데이터만 먼저 출력 (처음 10개)
        print("\n[샘플 데이터 - 처음 10개]")
        for price in sorted(prices, key=lambda x: x['ingredientName'])[:10]:
            ingredient_name = price['ingredientName']
            data = price['data']
            
            unit_price = data.get('unitPrice')
            base_unit = data.get('baseUnit')
            source = data.get('source', 'unknown')
            
            print(f"  {ingredient_name}: {unit_price}원/{base_unit} (출처: {source})")
        
        # 특정 재료 검색 (예: 돼지고기)
        print("\n[돼지고기 관련 재료 검색]")
        print("-" * 80)
        pork_related = [p for p in prices if '돼지' in p['ingredientName']]
        if pork_related:
            for price in pork_related:
                ingredient_name = price['ingredientName']
                data = price['data']
                unit_price = data.get('unitPrice')
                base_unit = data.get('baseUnit')
                print(f"  {ingredient_name}: {unit_price}원/{base_unit}")
        else:
            print("  돼지고기 관련 재료를 찾을 수 없습니다.")
        
        # 전체 데이터를 JSON 파일로 저장
        import json
        output_file = os.path.join(current_dir, 'ingredient_prices_output.json')
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(prices, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n전체 데이터가 {output_file}에 저장되었습니다.")
        
        return prices
        
    except Exception as e:
        logger.error(f"Firebase 조회 중 오류: {e}", exc_info=True)
        return None


if __name__ == "__main__":
    fetch_ingredient_prices_from_firebase()

