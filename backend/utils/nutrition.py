"""
Nutrition calculation utilities

Functions for estimating nutrition information from ingredients.
"""

import re
from typing import List, Dict, Any, Optional
from rapidfuzz import process, fuzz

# Nutrition lookup table (per 100g unless noted)
# Sources: Korean Food Composition Database (농촌진흥청), USDA FoodData Central
NUTRITION_TABLE = {
    # ── Vegetables ──
    "무": {"kcal": 18, "protein_g": 0.7, "fat_g": 0.1, "carb_g": 4.1, "sodium_mg": 21, "sugar_g": 2.5, "cholesterol_mg": 0, "fiber_g": 1.4},
    "양파": {"kcal": 40, "protein_g": 1.1, "fat_g": 0.1, "carb_g": 9.3, "sodium_mg": 4, "sugar_g": 4.2, "cholesterol_mg": 0, "fiber_g": 1.7},
    "대파": {"kcal": 34, "protein_g": 1.8, "fat_g": 0.3, "carb_g": 7.3, "sodium_mg": 5, "sugar_g": 2.3, "cholesterol_mg": 0, "fiber_g": 2.6},
    "쪽파": {"kcal": 32, "protein_g": 1.8, "fat_g": 0.2, "carb_g": 6.5, "sodium_mg": 4, "sugar_g": 2.0, "cholesterol_mg": 0, "fiber_g": 2.4},
    "마늘": {"kcal": 149, "protein_g": 6.4, "fat_g": 0.5, "carb_g": 33.1, "sodium_mg": 17, "sugar_g": 1.0, "cholesterol_mg": 0, "fiber_g": 2.1},
    "다진마늘": {"kcal": 149, "protein_g": 6.4, "fat_g": 0.5, "carb_g": 33.1, "sodium_mg": 17, "sugar_g": 1.0, "cholesterol_mg": 0, "fiber_g": 2.1},
    "다진 마늘": {"kcal": 149, "protein_g": 6.4, "fat_g": 0.5, "carb_g": 33.1, "sodium_mg": 17, "sugar_g": 1.0, "cholesterol_mg": 0, "fiber_g": 2.1},
    "생강": {"kcal": 80, "protein_g": 1.8, "fat_g": 0.8, "carb_g": 17.8, "sodium_mg": 13, "sugar_g": 1.7, "cholesterol_mg": 0, "fiber_g": 2.0},
    "당근": {"kcal": 41, "protein_g": 0.9, "fat_g": 0.2, "carb_g": 9.6, "sodium_mg": 69, "sugar_g": 4.7, "cholesterol_mg": 0, "fiber_g": 2.8},
    "감자": {"kcal": 77, "protein_g": 2.0, "fat_g": 0.1, "carb_g": 17.5, "sodium_mg": 6, "sugar_g": 0.8, "cholesterol_mg": 0, "fiber_g": 2.2},
    "고구마": {"kcal": 86, "protein_g": 1.6, "fat_g": 0.1, "carb_g": 20.1, "sodium_mg": 55, "sugar_g": 4.2, "cholesterol_mg": 0, "fiber_g": 3.0},
    "호박": {"kcal": 17, "protein_g": 0.6, "fat_g": 0.1, "carb_g": 3.7, "sodium_mg": 1, "sugar_g": 2.2, "cholesterol_mg": 0, "fiber_g": 0.5},
    "양배추": {"kcal": 25, "protein_g": 1.3, "fat_g": 0.1, "carb_g": 5.8, "sodium_mg": 18, "sugar_g": 3.2, "cholesterol_mg": 0, "fiber_g": 2.5},
    "배추": {"kcal": 13, "protein_g": 1.5, "fat_g": 0.2, "carb_g": 2.2, "sodium_mg": 65, "sugar_g": 1.2, "cholesterol_mg": 0, "fiber_g": 1.0},
    "시금치": {"kcal": 23, "protein_g": 2.9, "fat_g": 0.4, "carb_g": 3.6, "sodium_mg": 79, "sugar_g": 0.4, "cholesterol_mg": 0, "fiber_g": 2.2},
    "오이": {"kcal": 15, "protein_g": 0.7, "fat_g": 0.1, "carb_g": 3.6, "sodium_mg": 2, "sugar_g": 1.7, "cholesterol_mg": 0, "fiber_g": 0.5},
    "가지": {"kcal": 25, "protein_g": 1.0, "fat_g": 0.2, "carb_g": 5.9, "sodium_mg": 2, "sugar_g": 3.5, "cholesterol_mg": 0, "fiber_g": 3.0},
    "깻잎": {"kcal": 37, "protein_g": 3.7, "fat_g": 0.6, "carb_g": 7.0, "sodium_mg": 5, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 4.2},
    "브로콜리": {"kcal": 34, "protein_g": 2.8, "fat_g": 0.4, "carb_g": 6.6, "sodium_mg": 33, "sugar_g": 1.7, "cholesterol_mg": 0, "fiber_g": 2.6},
    "토마토": {"kcal": 18, "protein_g": 0.9, "fat_g": 0.2, "carb_g": 3.9, "sodium_mg": 5, "sugar_g": 2.6, "cholesterol_mg": 0, "fiber_g": 1.2},
    "고추": {"kcal": 40, "protein_g": 1.9, "fat_g": 0.4, "carb_g": 8.8, "sodium_mg": 9, "sugar_g": 5.3, "cholesterol_mg": 0, "fiber_g": 1.5},
    "청양고추": {"kcal": 40, "protein_g": 1.9, "fat_g": 0.4, "carb_g": 8.8, "sodium_mg": 9, "sugar_g": 5.3, "cholesterol_mg": 0, "fiber_g": 1.5},
    "콩나물": {"kcal": 30, "protein_g": 3.0, "fat_g": 0.2, "carb_g": 5.9, "sodium_mg": 15, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 1.8},
    "숙주": {"kcal": 31, "protein_g": 3.0, "fat_g": 0.2, "carb_g": 6.2, "sodium_mg": 6, "sugar_g": 4.1, "cholesterol_mg": 0, "fiber_g": 1.8},
    # ── Mushrooms ──
    "팽이버섯": {"kcal": 37, "protein_g": 2.7, "fat_g": 0.3, "carb_g": 7.8, "sodium_mg": 3, "sugar_g": 0.2, "cholesterol_mg": 0, "fiber_g": 2.7},
    "새송이버섯": {"kcal": 35, "protein_g": 3.3, "fat_g": 0.4, "carb_g": 6.1, "sodium_mg": 18, "sugar_g": 2.0, "cholesterol_mg": 0, "fiber_g": 2.2},
    "표고버섯": {"kcal": 34, "protein_g": 2.2, "fat_g": 0.5, "carb_g": 6.8, "sodium_mg": 9, "sugar_g": 2.4, "cholesterol_mg": 0, "fiber_g": 2.5},
    "양송이버섯": {"kcal": 22, "protein_g": 3.1, "fat_g": 0.3, "carb_g": 3.3, "sodium_mg": 5, "sugar_g": 2.0, "cholesterol_mg": 0, "fiber_g": 1.0},
    # ── Tofu / Soy ──
    "두부": {"kcal": 76, "protein_g": 8.0, "fat_g": 4.8, "carb_g": 1.9, "sodium_mg": 7, "sugar_g": 0.3, "cholesterol_mg": 0, "fiber_g": 0.3},
    "순두부": {"kcal": 47, "protein_g": 5.0, "fat_g": 2.7, "carb_g": 1.5, "sodium_mg": 5, "sugar_g": 0.2, "cholesterol_mg": 0, "fiber_g": 0.1},
    "연두부": {"kcal": 50, "protein_g": 5.0, "fat_g": 3.0, "carb_g": 1.5, "sodium_mg": 6, "sugar_g": 0.2, "cholesterol_mg": 0, "fiber_g": 0.1},
    "유부": {"kcal": 230, "protein_g": 18.6, "fat_g": 17.2, "carb_g": 0.3, "sodium_mg": 12, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0.8},
    # ── Eggs ──
    "계란": {"kcal": 143, "protein_g": 12.6, "fat_g": 9.9, "carb_g": 0.7, "sodium_mg": 142, "sugar_g": 0.4, "cholesterol_mg": 372, "fiber_g": 0},
    "달걀": {"kcal": 143, "protein_g": 12.6, "fat_g": 9.9, "carb_g": 0.7, "sodium_mg": 142, "sugar_g": 0.4, "cholesterol_mg": 372, "fiber_g": 0},
    "메추리알": {"kcal": 158, "protein_g": 13.0, "fat_g": 11.1, "carb_g": 0.4, "sodium_mg": 141, "sugar_g": 0.0, "cholesterol_mg": 844, "fiber_g": 0},
    # ── Grains / Noodles ──
    "밥": {"kcal": 165, "protein_g": 2.7, "fat_g": 0.3, "carb_g": 36.0, "sodium_mg": 1, "sugar_g": 0.1, "cholesterol_mg": 0, "fiber_g": 0.4},
    "쌀": {"kcal": 365, "protein_g": 7.1, "fat_g": 0.7, "carb_g": 80.0, "sodium_mg": 1, "sugar_g": 0.1, "cholesterol_mg": 0, "fiber_g": 1.3},
    "현미밥": {"kcal": 170, "protein_g": 3.5, "fat_g": 1.0, "carb_g": 35.0, "sodium_mg": 2, "sugar_g": 0.3, "cholesterol_mg": 0, "fiber_g": 1.8},
    "소면": {"kcal": 356, "protein_g": 11.0, "fat_g": 1.3, "carb_g": 75.0, "sodium_mg": 5, "sugar_g": 0.5, "cholesterol_mg": 0, "fiber_g": 2.7},
    "중화면": {"kcal": 356, "protein_g": 11.0, "fat_g": 1.3, "carb_g": 75.0, "sodium_mg": 5, "sugar_g": 0.5, "cholesterol_mg": 0, "fiber_g": 2.7},
    "우동면": {"kcal": 130, "protein_g": 3.5, "fat_g": 0.5, "carb_g": 28.0, "sodium_mg": 200, "sugar_g": 0.5, "cholesterol_mg": 0, "fiber_g": 1.2},
    "파스타": {"kcal": 360, "protein_g": 12.5, "fat_g": 1.5, "carb_g": 72.0, "sodium_mg": 6, "sugar_g": 2.7, "cholesterol_mg": 0, "fiber_g": 3.2},
    "스파게티": {"kcal": 360, "protein_g": 12.5, "fat_g": 1.5, "carb_g": 72.0, "sodium_mg": 6, "sugar_g": 2.7, "cholesterol_mg": 0, "fiber_g": 3.2},
    "당면": {"kcal": 332, "protein_g": 0.1, "fat_g": 0.1, "carb_g": 82.0, "sodium_mg": 10, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0.5},
    "떡볶이떡": {"kcal": 230, "protein_g": 4.0, "fat_g": 0.5, "carb_g": 52.0, "sodium_mg": 5, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0.8},
    "식빵": {"kcal": 265, "protein_g": 9.0, "fat_g": 3.2, "carb_g": 49.0, "sodium_mg": 491, "sugar_g": 5.0, "cholesterol_mg": 0, "fiber_g": 2.7},
    "밀가루": {"kcal": 364, "protein_g": 10.3, "fat_g": 1.0, "carb_g": 76.3, "sodium_mg": 2, "sugar_g": 0.3, "cholesterol_mg": 0, "fiber_g": 2.7},
    # ── Meat ──
    "삼겹살": {"kcal": 518, "protein_g": 9.3, "fat_g": 53.0, "carb_g": 0.0, "sodium_mg": 73, "sugar_g": 0.0, "cholesterol_mg": 95, "fiber_g": 0},
    "목살": {"kcal": 240, "protein_g": 18.0, "fat_g": 18.5, "carb_g": 0.0, "sodium_mg": 60, "sugar_g": 0.0, "cholesterol_mg": 80, "fiber_g": 0},
    "돼지고기": {"kcal": 242, "protein_g": 17.0, "fat_g": 19.0, "carb_g": 0.0, "sodium_mg": 62, "sugar_g": 0.0, "cholesterol_mg": 80, "fiber_g": 0},
    "소고기": {"kcal": 250, "protein_g": 26.0, "fat_g": 15.0, "carb_g": 0.0, "sodium_mg": 72, "sugar_g": 0.0, "cholesterol_mg": 90, "fiber_g": 0},
    "닭고기": {"kcal": 239, "protein_g": 27.3, "fat_g": 13.6, "carb_g": 0.0, "sodium_mg": 82, "sugar_g": 0.0, "cholesterol_mg": 88, "fiber_g": 0},
    "닭가슴살": {"kcal": 109, "protein_g": 23.1, "fat_g": 1.2, "carb_g": 0.0, "sodium_mg": 74, "sugar_g": 0.0, "cholesterol_mg": 64, "fiber_g": 0},
    "닭다리": {"kcal": 209, "protein_g": 16.0, "fat_g": 15.7, "carb_g": 0.0, "sodium_mg": 77, "sugar_g": 0.0, "cholesterol_mg": 93, "fiber_g": 0},
    "베이컨": {"kcal": 541, "protein_g": 12.0, "fat_g": 54.0, "carb_g": 0.0, "sodium_mg": 1717, "sugar_g": 0.0, "cholesterol_mg": 110, "fiber_g": 0},
    "햄": {"kcal": 180, "protein_g": 16.5, "fat_g": 12.0, "carb_g": 2.0, "sodium_mg": 1200, "sugar_g": 1.5, "cholesterol_mg": 60, "fiber_g": 0},
    "소시지": {"kcal": 301, "protein_g": 12.0, "fat_g": 27.0, "carb_g": 2.0, "sodium_mg": 900, "sugar_g": 1.5, "cholesterol_mg": 70, "fiber_g": 0},
    "스팸": {"kcal": 315, "protein_g": 13.0, "fat_g": 28.0, "carb_g": 3.0, "sodium_mg": 1300, "sugar_g": 0.5, "cholesterol_mg": 80, "fiber_g": 0},
    # ── Seafood ──
    "참치캔": {"kcal": 200, "protein_g": 25.5, "fat_g": 10.5, "carb_g": 0.0, "sodium_mg": 400, "sugar_g": 0.0, "cholesterol_mg": 55, "fiber_g": 0},
    "참치": {"kcal": 200, "protein_g": 25.5, "fat_g": 10.5, "carb_g": 0.0, "sodium_mg": 400, "sugar_g": 0.0, "cholesterol_mg": 55, "fiber_g": 0},
    "새우": {"kcal": 85, "protein_g": 20.1, "fat_g": 0.5, "carb_g": 0.0, "sodium_mg": 566, "sugar_g": 0.0, "cholesterol_mg": 189, "fiber_g": 0},
    "오징어": {"kcal": 80, "protein_g": 17.9, "fat_g": 0.8, "carb_g": 0.0, "sodium_mg": 246, "sugar_g": 0.0, "cholesterol_mg": 233, "fiber_g": 0},
    "연어": {"kcal": 208, "protein_g": 20.4, "fat_g": 13.4, "carb_g": 0.0, "sodium_mg": 59, "sugar_g": 0.0, "cholesterol_mg": 55, "fiber_g": 0},
    "고등어": {"kcal": 205, "protein_g": 18.6, "fat_g": 13.9, "carb_g": 0.0, "sodium_mg": 90, "sugar_g": 0.0, "cholesterol_mg": 70, "fiber_g": 0},
    "멸치": {"kcal": 131, "protein_g": 25.4, "fat_g": 2.6, "carb_g": 0.0, "sodium_mg": 3668, "sugar_g": 0.0, "cholesterol_mg": 70, "fiber_g": 0},
    "어묵": {"kcal": 113, "protein_g": 12.0, "fat_g": 1.6, "carb_g": 13.0, "sodium_mg": 700, "sugar_g": 3.0, "cholesterol_mg": 30, "fiber_g": 0},
    "맛살": {"kcal": 95, "protein_g": 8.0, "fat_g": 0.5, "carb_g": 15.0, "sodium_mg": 800, "sugar_g": 5.0, "cholesterol_mg": 20, "fiber_g": 0},
    # ── Dairy ──
    "우유": {"kcal": 61, "protein_g": 3.2, "fat_g": 3.3, "carb_g": 4.8, "sodium_mg": 43, "sugar_g": 5.0, "cholesterol_mg": 10, "fiber_g": 0},
    "버터": {"kcal": 717, "protein_g": 0.9, "fat_g": 81.1, "carb_g": 0.1, "sodium_mg": 643, "sugar_g": 0.1, "cholesterol_mg": 215, "fiber_g": 0},
    "생크림": {"kcal": 345, "protein_g": 2.1, "fat_g": 37.0, "carb_g": 2.8, "sodium_mg": 38, "sugar_g": 2.9, "cholesterol_mg": 137, "fiber_g": 0},
    "모짜렐라": {"kcal": 280, "protein_g": 28.0, "fat_g": 17.0, "carb_g": 3.1, "sodium_mg": 627, "sugar_g": 1.0, "cholesterol_mg": 79, "fiber_g": 0},
    "체다치즈": {"kcal": 403, "protein_g": 25.0, "fat_g": 33.1, "carb_g": 1.3, "sodium_mg": 621, "sugar_g": 0.5, "cholesterol_mg": 105, "fiber_g": 0},
    "크림치즈": {"kcal": 342, "protein_g": 5.9, "fat_g": 34.2, "carb_g": 4.1, "sodium_mg": 321, "sugar_g": 3.2, "cholesterol_mg": 110, "fiber_g": 0},
    "파마산": {"kcal": 431, "protein_g": 38.5, "fat_g": 29.0, "carb_g": 4.1, "sodium_mg": 1529, "sugar_g": 0.8, "cholesterol_mg": 88, "fiber_g": 0},
    # ── Seasonings / Sauces (per 100g or 100ml) ──
    "간장": {"kcal": 53, "protein_g": 5.6, "fat_g": 0.0, "carb_g": 5.6, "sodium_mg": 5800, "sugar_g": 0.8, "cholesterol_mg": 0, "fiber_g": 0},
    "진간장": {"kcal": 53, "protein_g": 5.6, "fat_g": 0.0, "carb_g": 5.6, "sodium_mg": 5800, "sugar_g": 0.8, "cholesterol_mg": 0, "fiber_g": 0},
    "국간장": {"kcal": 40, "protein_g": 5.0, "fat_g": 0.0, "carb_g": 4.0, "sodium_mg": 7200, "sugar_g": 0.5, "cholesterol_mg": 0, "fiber_g": 0},
    "된장": {"kcal": 170, "protein_g": 12.0, "fat_g": 5.4, "carb_g": 18.0, "sodium_mg": 6000, "sugar_g": 6.0, "cholesterol_mg": 0, "fiber_g": 5.0},
    "고추장": {"kcal": 208, "protein_g": 3.7, "fat_g": 3.5, "carb_g": 43.0, "sodium_mg": 4500, "sugar_g": 24.0, "cholesterol_mg": 0, "fiber_g": 2.0},
    "쌈장": {"kcal": 185, "protein_g": 7.5, "fat_g": 5.0, "carb_g": 27.0, "sodium_mg": 5000, "sugar_g": 12.0, "cholesterol_mg": 0, "fiber_g": 3.0},
    "굴소스": {"kcal": 60, "protein_g": 1.0, "fat_g": 0.1, "carb_g": 13.5, "sodium_mg": 3400, "sugar_g": 6.0, "cholesterol_mg": 0, "fiber_g": 0},
    "액젓": {"kcal": 50, "protein_g": 8.0, "fat_g": 0.0, "carb_g": 4.0, "sodium_mg": 7500, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "멸치액젓": {"kcal": 50, "protein_g": 8.0, "fat_g": 0.0, "carb_g": 4.0, "sodium_mg": 7500, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "설탕": {"kcal": 387, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 100.0, "sodium_mg": 0, "sugar_g": 100.0, "cholesterol_mg": 0, "fiber_g": 0},
    "소금": {"kcal": 0, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 0.0, "sodium_mg": 38758, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "참기름": {"kcal": 884, "protein_g": 0.0, "fat_g": 100.0, "carb_g": 0.0, "sodium_mg": 0, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "들기름": {"kcal": 884, "protein_g": 0.0, "fat_g": 100.0, "carb_g": 0.0, "sodium_mg": 0, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "식용유": {"kcal": 884, "protein_g": 0.0, "fat_g": 100.0, "carb_g": 0.0, "sodium_mg": 0, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "올리브유": {"kcal": 884, "protein_g": 0.0, "fat_g": 100.0, "carb_g": 0.0, "sodium_mg": 2, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    "고춧가루": {"kcal": 281, "protein_g": 12.0, "fat_g": 5.7, "carb_g": 49.7, "sodium_mg": 30, "sugar_g": 10.3, "cholesterol_mg": 0, "fiber_g": 34.8},
    "후추": {"kcal": 251, "protein_g": 10.4, "fat_g": 3.3, "carb_g": 63.9, "sodium_mg": 20, "sugar_g": 0.6, "cholesterol_mg": 0, "fiber_g": 25.3},
    "식초": {"kcal": 21, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 0.9, "sodium_mg": 2, "sugar_g": 0.4, "cholesterol_mg": 0, "fiber_g": 0},
    "맛술": {"kcal": 76, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 7.8, "sodium_mg": 3, "sugar_g": 6.5, "cholesterol_mg": 0, "fiber_g": 0},
    "미림": {"kcal": 76, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 7.8, "sodium_mg": 3, "sugar_g": 6.5, "cholesterol_mg": 0, "fiber_g": 0},
    "케첩": {"kcal": 112, "protein_g": 1.7, "fat_g": 0.1, "carb_g": 25.8, "sodium_mg": 907, "sugar_g": 22.8, "cholesterol_mg": 0, "fiber_g": 0.3},
    "마요네즈": {"kcal": 680, "protein_g": 1.0, "fat_g": 75.0, "carb_g": 0.6, "sodium_mg": 635, "sugar_g": 0.6, "cholesterol_mg": 42, "fiber_g": 0},
    "꿀": {"kcal": 304, "protein_g": 0.3, "fat_g": 0.0, "carb_g": 82.4, "sodium_mg": 4, "sugar_g": 82.1, "cholesterol_mg": 0, "fiber_g": 0.2},
    "올리고당": {"kcal": 280, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 70.0, "sodium_mg": 10, "sugar_g": 30.0, "cholesterol_mg": 0, "fiber_g": 0},
    "물엿": {"kcal": 316, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 79.0, "sodium_mg": 20, "sugar_g": 40.0, "cholesterol_mg": 0, "fiber_g": 0},
    "다시다": {"kcal": 180, "protein_g": 12.0, "fat_g": 2.0, "carb_g": 28.0, "sodium_mg": 14000, "sugar_g": 3.0, "cholesterol_mg": 0, "fiber_g": 0},
    "토마토소스": {"kcal": 29, "protein_g": 1.3, "fat_g": 0.2, "carb_g": 5.6, "sodium_mg": 396, "sugar_g": 3.6, "cholesterol_mg": 0, "fiber_g": 1.5},
    "알룰로스": {"kcal": 16, "protein_g": 0.0, "fat_g": 0.0, "carb_g": 100.0, "sodium_mg": 0, "sugar_g": 0.0, "cholesterol_mg": 0, "fiber_g": 0},
    # ── Misc / Processed ──
    "라면": {"kcal": 450, "protein_g": 9.0, "fat_g": 16.0, "carb_g": 65.0, "sodium_mg": 1800, "sugar_g": 4.0, "cholesterol_mg": 0, "fiber_g": 2.0},
    "김": {"kcal": 180, "protein_g": 30.0, "fat_g": 1.6, "carb_g": 25.0, "sodium_mg": 480, "sugar_g": 0.5, "cholesterol_mg": 0, "fiber_g": 25.2},
    "김치": {"kcal": 15, "protein_g": 1.1, "fat_g": 0.5, "carb_g": 2.4, "sodium_mg": 498, "sugar_g": 1.1, "cholesterol_mg": 0, "fiber_g": 1.6},
}

# Unit conversion constants
UNIT_TO_G = {"g": 1, "kg": 1000}
UNIT_TO_ML = {"ml": 1, "l": 1000}
# Korean cooking units → grams (approximate)
UNIT_TO_G_COOKING = {
    "큰술": 15, "작은술": 5, "꼬집": 1, "컵": 200, "공기": 200,
    "스푼": 15, "티스푼": 5,
}


def _coerce_positive_servings(servings: Any) -> float:
    """LLM/JSON에서 servings가 str 등으로 올 수 있어 비교·나눗셈 전에 숫자로 고정한다."""
    if servings is None:
        return 1.0
    if isinstance(servings, bool):
        return 1.0
    if isinstance(servings, (int, float)):
        s = float(servings)
        return s if s > 0 else 1.0
    if isinstance(servings, str):
        raw = servings.strip().replace(",", "")
        if not raw:
            return 1.0
        try:
            s = float(raw)
            return s if s > 0 else 1.0
        except ValueError:
            pass
        m = re.search(r"(\d+(?:\.\d+)?)", raw)
        if m:
            s = float(m.group(1))
            return s if s > 0 else 1.0
        return 1.0
    return 1.0


def match_food(name: str) -> str:
    """
    Match ingredient name to canonical name in nutrition table.
    First tries exact substring match (Korean), then fuzzy match.
    """
    name_lower = name.strip().lower()
    # Exact key match first
    if name_lower in NUTRITION_TABLE:
        return name_lower
    # Substring match: if any table key is contained in the ingredient name
    for key in NUTRITION_TABLE:
        if key in name_lower:
            return key
    # Fuzzy match as fallback
    choices = list(NUTRITION_TABLE.keys())
    best, score, _ = process.extractOne(name_lower, choices, scorer=fuzz.WRatio)
    return best if score >= 75 else ""


def estimate_nutrition(
    ingredients: List[Dict[str, Any]],
    servings: Any,
    llm_nutrition: Optional[Dict[str, float]] = None,
    Nutrition=None,
    NutritionLLM=None
):
    """
    Estimate nutrition using lookup table as fallback, prioritize LLM calculation.
    
    Args:
        ingredients: List of ingredient dictionaries with 'item', 'qty', 'unit' keys
        servings: Number of servings (int/float/str 등 혼합 가능)
        llm_nutrition: Optional LLM-calculated nutrition data
        Nutrition: Nutrition Pydantic model class (passed from caller to avoid circular import)
        NutritionLLM: NutritionLLM Pydantic model class (passed from caller to avoid circular import)
        
    Returns:
        Nutrition object with per_serving, assumptions, and llm_estimate
    """
    if Nutrition is None or NutritionLLM is None:
        raise ValueError("Nutrition and NutritionLLM classes must be provided")
    
    total = {
        "kcal": 0.0,
        "protein_g": 0.0,
        "fat_g": 0.0,
        "carb_g": 0.0,
        "sodium_mg": 0.0,
        "sugar_g": 0.0,
        "cholesterol_mg": 0.0,
        "fiber_g": 0.0,
    }
    assumptions = []
    
    # Try to use LLM nutrition estimate first
    llm_estimate = None
    if llm_nutrition:
        try:
            llm_estimate = NutritionLLM(
                calories_per_serving=llm_nutrition.get("calories_per_serving", 0),
                protein_g=llm_nutrition.get("protein_g", 0),
                fat_g=llm_nutrition.get("fat_g", 0),
                carbs_g=llm_nutrition.get("carbs_g", 0),
                sodium_mg=llm_nutrition.get("sodium_mg", 0),
                sugar_g=llm_nutrition.get("sugar_g", 0),
                cholesterol_mg=llm_nutrition.get("cholesterol_mg", 0),
                fiber_g=llm_nutrition.get("fiber_g", 0)
            )
            assumptions.append("Nutrition calculated by LLM based on all ingredients and quantities")
        except Exception:
            pass
    
    # Use lookup table for known ingredients
    table_matched = 0
    for ing in ingredients:
        item = ing.get("item", "")
        qty = ing.get("qty")
        unit = (ing.get("unit") or "").strip().lower()
        canonical = match_food(item)
        if not canonical or canonical not in NUTRITION_TABLE or not qty:
            continue
        basis = NUTRITION_TABLE[canonical]
        grams = None
        if unit in UNIT_TO_G:
            grams = qty * UNIT_TO_G[unit]
        elif unit in UNIT_TO_ML:
            grams = qty * UNIT_TO_ML[unit]
        elif unit in UNIT_TO_G_COOKING:
            grams = qty * UNIT_TO_G_COOKING[unit]
        elif unit in ("개", "알", "봉", "팩", "캔"):
            # Count-based: use qty_conventional if available and in grams
            qc = ing.get("qty_conventional")
            uc = (ing.get("unit_conventional") or "").strip().lower()
            if qc and uc in UNIT_TO_G:
                grams = qc * UNIT_TO_G[uc]
            else:
                # Rough defaults per unit for common items
                grams = qty * 50  # ~50g per piece as rough estimate
        elif unit in ("대",):
            grams = qty * 60  # 1대 of green onion ≈ 60g
        elif unit in ("통",):
            grams = qty * 150
        elif unit in ("tbsp", "tsp", "t", "ts"):
            grams = qty * (15 if unit in ("tbsp", "t") else 5)
        if grams is None:
            continue
        factor = grams / 100.0
        for k in total:
            total[k] += basis.get(k, 0.0) * factor
        table_matched += 1
        assumptions.append(f"{canonical} {int(grams)}g at table values per 100g")
    
    servings_n = _coerce_positive_servings(servings)
    per_serving = {k: round(v / servings_n, 2) for k, v in total.items()}

    llm_per_serving = None
    if llm_estimate and llm_estimate.calories_per_serving > 0:
        llm_per_serving = {
            "kcal": round(llm_estimate.calories_per_serving, 2),
            "protein_g": round(llm_estimate.protein_g, 2),
            "fat_g": round(llm_estimate.fat_g, 2),
            "carb_g": round(llm_estimate.carbs_g, 2),
            "sodium_mg": round(llm_estimate.sodium_mg, 2),
            "sugar_g": round(llm_estimate.sugar_g, 2),
            "cholesterol_mg": round(llm_estimate.cholesterol_mg, 2),
            "fiber_g": round(llm_estimate.fiber_g, 2),
        }

    if per_serving.get("kcal", 0) == 0 and llm_per_serving:
        # No table matches — use LLM entirely
        per_serving = llm_per_serving
        if "Nutrition calculated by LLM based on all ingredients and quantities" not in assumptions:
            assumptions.append("Nutrition from LLM estimate (no lookup table matches)")
    elif per_serving.get("kcal", 0) > 0 and llm_per_serving:
        # Both have data — average them to smooth out errors from either side
        for k in per_serving:
            table_val = per_serving[k]
            llm_val = llm_per_serving.get(k, 0)
            if table_val > 0 and llm_val > 0:
                per_serving[k] = round((table_val + llm_val) / 2.0, 1)
            elif llm_val > 0 and table_val == 0:
                per_serving[k] = round(llm_val, 1)
        assumptions.append("Nutrition averaged from lookup table and LLM estimate")

    # Sanity-check: fix obvious zero fields based on ingredient contents.
    # The LLM sometimes returns 0 for fields that must be non-zero given
    # the ingredients (e.g., 간장 → sodium, 계란 → cholesterol).
    item_names = " ".join(
        (ing.get("item") or "") for ing in ingredients
    ).lower()

    _SODIUM_INGREDIENTS = (
        "간장", "된장", "쌈장", "고추장", "굴소스", "액젓", "소금",
        "다시다", "치킨스톡", "참치", "스팸", "햄", "소시지", "베이컨",
    )
    _CHOLESTEROL_INGREDIENTS = ("계란", "달걀", "메추리알", "버터", "생크림", "크림치즈")
    _SUGAR_INGREDIENTS = ("설탕", "알룰로스", "꿀", "올리고당", "물엿", "쌈장", "고추장", "케찹", "케첩")
    _FIBER_INGREDIENTS = ("버섯", "두부", "순두부", "양배추", "브로콜리", "시금치", "당근", "감자", "고구마")

    if per_serving.get("sodium_mg", 0) == 0 and any(kw in item_names for kw in _SODIUM_INGREDIENTS):
        soy_count = sum(1 for kw in ("간장", "된장", "쌈장", "고추장", "굴소스", "액젓", "소금") if kw in item_names)
        per_serving["sodium_mg"] = round(450.0 * max(soy_count, 1) / servings_n, 1)

    if per_serving.get("cholesterol_mg", 0) == 0 and any(kw in item_names for kw in _CHOLESTEROL_INGREDIENTS):
        egg_like = sum(1 for kw in ("계란", "달걀", "메추리알") if kw in item_names)
        per_serving["cholesterol_mg"] = round(186.0 * max(egg_like, 1) / servings_n, 1)

    if per_serving.get("sugar_g", 0) == 0 and any(kw in item_names for kw in _SUGAR_INGREDIENTS):
        per_serving["sugar_g"] = round(2.0 / servings_n, 1)

    if per_serving.get("fiber_g", 0) == 0 and any(kw in item_names for kw in _FIBER_INGREDIENTS):
        per_serving["fiber_g"] = round(1.5 / servings_n, 1)

    if not assumptions:
        assumptions = ["Nutrition primarily from LLM estimate" if llm_estimate else "Limited nutrition data available"]
    
    return Nutrition(
        per_serving=per_serving,
        assumptions=assumptions,
        llm_estimate=llm_estimate
    )

