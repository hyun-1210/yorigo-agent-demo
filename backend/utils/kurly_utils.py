"""
Kurly (마켓컬리) scraping utilities
마켓컬리 크롤링 유틸리티 함수들
"""
from typing import List
from utils.coupang_utils import get_ingredients_list, _fallback_list


# Re-export: same tier logic as coupang_utils
__all__ = ["get_ingredients_list"]
