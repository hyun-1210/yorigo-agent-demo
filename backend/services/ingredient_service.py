"""
Ingredient service for ingredient processing and categorization

Handles ingredient preprocessing, categorization, and matching.
"""

import os
from contextvars import ContextVar
from typing import Dict, Any, List, Optional, Tuple
from google import genai
from google.genai import types

# IngredientService는 프로세스 전역 싱글톤(get_ingredient_service())으로 쓰이므로,
# 최근 호출의 토큰 사용량을 인스턴스 속성으로 저장하면 동시 요청 간 경쟁 조건이
# 생긴다. ContextVar는 스레드/비동기 태스크별로 격리되어 안전하다
# (llm_service._parse_usage_ctx와 동일한 패턴).
_ingredient_llm_usage_ctx: ContextVar[Tuple[int, int, int]] = ContextVar(
    "ingredient_llm_usage", default=(0, 0, 0)
)


class IngredientService:
    """Service for ingredient-related operations"""
    
    def __init__(self, api_key: Optional[str] = None):
        """
        Initialize ingredient service.
        
        Args:
            api_key: OpenAI API key (defaults to OPENAI_API_KEY env var)
        """
        self._gemini_api_key = os.getenv("GEMINI_API_KEY")
        self._gemini_model = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

    @property
    def last_usage_tokens(self) -> Tuple[int, int, int]:
        """가장 최근 _gemini_generate_text 호출의 (input, output, thinking) 토큰 수
        (현재 스레드/태스크 기준, 호출 없었으면 (0, 0, 0))."""
        return _ingredient_llm_usage_ctx.get()

    @last_usage_tokens.setter
    def last_usage_tokens(self, value: Tuple[int, int, int]) -> None:
        _ingredient_llm_usage_ctx.set(value)
    
    def _get_gemini_client(self) -> "genai.Client":
        """Get configured Gemini client (requires GEMINI_API_KEY)."""
        key = os.getenv("GEMINI_API_KEY") or self._gemini_api_key
        if not key:
            raise ValueError("GEMINI_API_KEY not found in environment")
        # Google GenAI HttpOptions.timeout is milliseconds, not seconds.
        timeout_ms = int(os.getenv("GEMINI_HTTP_TIMEOUT_SECONDS", "330")) * 1000
        return genai.Client(api_key=key, http_options={"timeout": timeout_ms})

    @staticmethod
    def _extract_gemini_usage(resp: Any) -> tuple[int, int, int]:
        """Gemini 응답 usage_metadata 에서 (input, output, thinking) 토큰 수 추출.

        llm_service.LLMService._extract_gemini_usage 와 동일 로직 (의존성 최소화를 위해 별도 유지).
        """
        um = getattr(resp, "usage_metadata", None)
        if um is None:
            return 0, 0, 0
        inp = int(
            getattr(um, "prompt_token_count", None)
            or getattr(um, "input_token_count", None)
            or 0
        )
        out = int(
            getattr(um, "candidates_token_count", None)
            or getattr(um, "output_token_count", None)
            or 0
        )
        think = int(getattr(um, "thoughts_token_count", None) or 0)
        return inp, out, think

    def _gemini_generate_text(
        self,
        *,
        system: str,
        user: str,
        model: Optional[str] = None,
        record_parse_call_type: Optional[str] = None,
    ) -> str:
        """Gemini 텍스트 생성 결과를 문자열로 반환합니다.

        record_parse_call_type: 지정하면 이 호출의 토큰 사용량을
        llm_service의 활성 파싱 usage tracker(_parse_usage_ctx)에도 합류시킵니다.
        (파싱 도중 호출되는 categorize_ingredients_batch용 — 파싱 컨텍스트가
        없으면 llm_service 쪽에서 조용히 무시됩니다.)
        호출 후 self.last_usage_tokens 에 (input, output, thinking) 토큰 수가 남습니다.
        """
        client = self._get_gemini_client()
        model_name = model or os.getenv("GEMINI_MODEL", self._gemini_model)
        resp = client.models.generate_content(
            model=model_name,
            contents=user,
            config=types.GenerateContentConfig(system_instruction=system),
        )
        self.last_usage_tokens = self._extract_gemini_usage(resp)
        if record_parse_call_type:
            try:
                from services.llm_service import get_llm_service

                get_llm_service()._record_parse_usage(resp, record_parse_call_type)
            except Exception as e:
                print(f"[IngredientService] parse usage 합류 실패(무시): {e}")
        return (getattr(resp, "text", None) or "").strip()

    def _llm_generate_text(
        self,
        *,
        system: str,
        user: str,
        primary: str = "deepseek",
        primary_model: Optional[str] = None,
        record_parse_call_type: Optional[str] = None,
    ) -> str:
        """Gap A/B용: 벤치 우승 모델 1차 → 실패 시 Gemini 폴백.

        primary: deepseek (기본) | openai | gemini
        """
        from services.llm_service import get_llm_service, _last_call_usage_ctx

        llm = get_llm_service()
        text, engine = llm.generate_text_primary_then_gemini(
            system=system,
            user=user,
            primary=primary,
            primary_model=primary_model,
            call_type=record_parse_call_type,
            max_retries=2,
            gemini_thinking_budget=0,
        )
        # DeepSeek/OpenAI 경로의 사용량을 IngredientService 컨텍스트에도 반영
        self.last_usage_tokens = _last_call_usage_ctx.get()
        print(f"[IngredientService] llm engine={engine}", flush=True)
        return text

    def preprocess_ingredients(self, ingredients: List[str]) -> Dict[str, str]:
        """
        Preprocess ingredient names using LLM to simplify them for better shopping search results.

        Gap A 벤치 iter2: flat JSON + DeepSeek V4 Flash 1차, Gemini 폴백.
        """
        if not ingredients:
            return {}

        self.last_usage_tokens = (0, 0, 0)
        try:
            ingredients_list = "\n".join(
                f"{i + 1}. {ing}" for i, ing in enumerate(ingredients)
            )

            system_prompt = """You simplify Korean ingredient strings into Coupang/Kurly search queries.

Goal: each input → short product name a shopper would type.

STRIP: prep (다진/썬/채친/송송/깐), egg parts (노른자/흰자→계란), qty/units, parentheticals.

KEEP product-defining forms (do not over-strip):
- 청양고추/청양고춧가루, 홍고추, 흑설탕/황설탕, 국간장/진간장
- 생강가루/생강청, 굴소스/멸치액젓/참치액, 파마산 치즈/크림치즈
- Brands: 신라면, 포카리스웨트, 뉴슈가, 알룰로스
- Juice/sauce forms: 레몬즙/레몬주스 → 레몬즙 (NOT bare 레몬); 참치액 stays 참치액

Hard cases (class rules from prior failures):
- 청고추/풋고추 → 고추 (do NOT invent 청양고추)
- 김칫국물/김치국물 → 김치
- 쌀밥 → 밥 (not 쌀); 즉석밥 may stay 즉석밥
- Specialty names you are unsure of → copy as-is (오르조→오르조, 제피가루→제피가루). Never invent similar-sounding brands (no 오리오).
- 달걀→계란; 올리브오일→올리브유; 참치캔→참치; 파르미지아노 레지아노→파마산 치즈

Output (critical — keep compact to save tokens):
1. Return ONLY a flat JSON object. No markdown, no commentary, no "items" array.
2. Shape: {"<exact input>":"<shopping name>", ...}
3. Keys MUST be every input string verbatim. Values = short Korean search names.
4. Preserve normal spaces inside values (파마산 치즈).
"""

            user_prompt = (
                "Map each ingredient to a shopping search name.\n"
                'Return ONLY a flat JSON object: {"<exact input>":"<out>", ...}\n'
                "Include every input as a key, copied verbatim.\n\n"
                f"{ingredients_list}"
            )

            primary_model = os.getenv("PREPROCESS_PRIMARY_MODEL", "deepseek-v4-flash")
            simplified_text = self._llm_generate_text(
                system=system_prompt,
                user=user_prompt,
                primary=os.getenv("PREPROCESS_PRIMARY_PROVIDER", "deepseek"),
                primary_model=primary_model,
            )

            # Flat JSON map 파싱 (iter2). 실패 시 구 line-list 호환.
            preprocessed: Dict[str, str] = {}
            mapping: Dict[str, str] = {}
            raw = (simplified_text or "").strip()
            if raw.startswith("```"):
                raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
            try:
                import json

                start = raw.find("{")
                end = raw.rfind("}") + 1
                if start != -1 and end > start:
                    obj = json.loads(raw[start:end])
                    if isinstance(obj, dict):
                        mapping = {str(k): str(v).strip() for k, v in obj.items() if v is not None}
            except Exception:
                mapping = {}

            if mapping:
                for original in ingredients:
                    simp = mapping.get(original) or mapping.get(original.strip())
                    if simp:
                        preprocessed[original] = simp
                    else:
                        preprocessed[original] = original
            else:
                simplified_list = [
                    line.strip() for line in simplified_text.split("\n") if line.strip()
                ]
                for i, original in enumerate(ingredients):
                    if i < len(simplified_list):
                        simplified = simplified_list[i].strip()
                        if simplified.startswith("- "):
                            simplified = simplified[2:].strip()
                        # "1. name" / '"key": "val"' 형태 잔여 정리
                        if simplified[:1].isdigit() and ". " in simplified[:4]:
                            simplified = simplified.split(". ", 1)[-1].strip()
                        preprocessed[original] = simplified or original
                    else:
                        preprocessed[original] = original

            print(f"[Preprocess] Successfully simplified {len(preprocessed)} ingredients")
            for orig, simp in preprocessed.items():
                if orig != simp:
                    print(f"[Preprocess]   '{orig}' → '{simp}'")

            return preprocessed

        except Exception as e:
            print(f"[ERROR] Ingredient preprocessing failed: {e}")
            # Fallback: return original ingredients
            return {ing: ing for ing in ingredients}
    
    def categorize_ingredient(self, ingredient_name: str, original_category: Optional[str] = None) -> Dict[str, Any]:
        """
        Categorize a single ingredient using pattern matching + LLM fallback.
        Returns one of the 6 cooking-role categories.
        """
        ingredient_name = ingredient_name.strip()
        self.last_usage_tokens = (0, 0, 0)
        if not ingredient_name:
            return {"category": "seasonings_sauces", "confidence": "low"}

        matched = self._pattern_match_category(ingredient_name)
        if matched:
            return matched

        try:
            system = (
                "You categorize Korean cooking ingredients by COOKING ROLE.\n"
                "Return ONLY one of these 6 values, nothing else:\n"
                "vegetables_fruits, meat_processed_egg, seafood, dairy, grains, seasonings_sauces\n"
                "Key rule: cooking role trumps origin (굴소스→seasonings_sauces, not seafood).\n"
                "마늘/대파/생강 = always vegetables_fruits. 두부/순두부/유부 = always vegetables_fruits."
            )
            user = f"Categorize: {ingredient_name}"
            primary_model = os.getenv("CATEGORIZE_PRIMARY_MODEL", "deepseek-v4-flash")
            result = self._llm_generate_text(
                system=system,
                user=user,
                primary=os.getenv("CATEGORIZE_PRIMARY_PROVIDER", "deepseek"),
                primary_model=primary_model,
            ).strip().lower()
            if result in self._VALID_6_CATEGORIES:
                return {"category": result, "confidence": "medium"}
            for cat in self._VALID_6_CATEGORIES:
                if cat in result:
                    return {"category": cat, "confidence": "low"}
            return {"category": "seasonings_sauces", "confidence": "low"}
        except Exception as e:
            print(f"[ERROR] LLM categorization failed for '{ingredient_name}': {e}")
            return {"category": "seasonings_sauces", "confidence": "low"}
    
    def _pattern_match_category(self, ingredient_name: str) -> Optional[Dict[str, Any]]:
        """Pattern-only categorization (Gap B iter4 / v3 compound-role rules).

        Priority: cooking ROLE compounds before origin substrings.
        Returns result dict or None if no match.
        """
        name_lower = (ingredient_name or "").strip().lower()
        if not name_lower:
            return {"category": "seasonings_sauces", "confidence": "low"}

        def hit(cat: str) -> Dict[str, Any]:
            return {"category": cat, "confidence": "high"}

        compact = name_lower.replace(" ", "")

        # ── 1) Seasoning-role compounds (before noodles / seafood / veg) ──
        if "소스" in name_lower:
            return hit("seasonings_sauces")
        if "스프" in name_lower:
            return hit("seasonings_sauces")

        if "육수용" not in name_lower and (
            any(k in name_lower for k in ["육수가루", "가루육수", "분말육수", "육수파우더"])
            or (
                "육수" in name_lower
                and any(k in name_lower for k in ["분말", "가루", "파우더", "큐브", "코인"])
            )
            or (
                "스톡" in name_lower
                and any(k in name_lower for k in ["분말", "가루", "파우더"])
            )
        ):
            return hit("seasonings_sauces")
        if "육수용" not in name_lower and "육수" in name_lower:
            return hit("seasonings_sauces")

        if "버터" in name_lower and any(
            n in name_lower for n in ["땅콩", "아몬드", "캐슈", "호두", "피스타치오", "해바라기"]
        ):
            return hit("seasonings_sauces")

        if any(k in name_lower for k in ["즙", "주스"]) and any(
            k in name_lower for k in ["레몬", "라임", "오렌지", "유자", "매실"]
        ):
            return hit("seasonings_sauces")

        if any(
            k in name_lower
            for k in ["페이스트", "아이올리", "마요네즈", "케첩", "케찹", "생강청", "생강분"]
        ):
            return hit("seasonings_sauces")

        if any(k == name_lower or name_lower.startswith(k) for k in ["김가루", "조미김", "김밥김"]):
            return hit("seasonings_sauces")
        if name_lower == "김" or name_lower.endswith("용 김") or compact.endswith("용김"):
            return hit("seasonings_sauces")
        if "김밥용" in name_lower and name_lower.rstrip().endswith("김"):
            return hit("seasonings_sauces")

        if "김밥용" in name_lower and any(
            k in name_lower for k in ["단무지", "우엉", "오이", "당근", "시금치"]
        ):
            return hit("vegetables_fruits")

        if any(
            k in name_lower
            for k in [
                "카레", "미원", "다시다", "치킨스톡", "빙초산", "와사비", "두반장", "라유",
                "알룰로스", "뉴슈가", "스테비아", "아스파탐", "자일리톨",
                "사이다", "포카리", "게토레이", "이온음료",
            ]
        ):
            return hit("seasonings_sauces")

        if any(k in name_lower for k in ["참깨", "흑깨", "흰깨", "깨가루", "통깨", "깨소금"]):
            return hit("seasonings_sauces")

        if any(k in name_lower for k in ["강력분", "박력분", "중력분"]):
            return hit("grains")

        # ── 2) *가루 / 전분 BEFORE fresh-herb / veg origin matches ──
        if "전분" in name_lower:
            return hit("grains")
        if "가루" in name_lower:
            grain_powders = [
                "밀가루", "쌀가루", "옥수수가루", "감자가루", "전분가루",
                "부침가루", "튀김가루", "핫케이크", "빵가루", "녹말",
                "찹쌀가루", "찹쌀 가루", "오트밀가루",
                "아몬드가루", "아몬드 가루", "아몬드파우더",
            ]
            if any(k in name_lower for k in grain_powders):
                return hit("grains")
            return hit("seasonings_sauces")

        if any(
            k in name_lower
            for k in ["파슬리", "바질", "로즈마리", "타임", "딜", "고수", "미나리", "쑥갓"]
        ):
            return hit("vegetables_fruits")

        # ── 3) Core seasonings ──
        if any(
            k in name_lower
            for k in [
                "간장", "된장", "고추장", "쌈장", "춘장",
                "참기름", "들기름", "식용유", "올리브유", "포도씨유", "카놀라유", "오일",
                "식초", "맛술", "미림", "청주", "와인",
                "소금", "설탕", "후추", "고춧가루",
                "물엿", "올리고당", "꿀", "조청",
                "액젓", "참치액", "쯔유", "마가린",
            ]
        ):
            return hit("seasonings_sauces")

        if "버터" in name_lower:
            return hit("dairy")

        if any(k in name_lower for k in ["계란", "달걀", "메추리알", "에그", "오리알", "흰자", "노른자"]):
            return hit("dairy")

        if any(
            k in name_lower
            for k in [
                "우유", "두유", "치즈", "요거트", "요구르트", "크림", "생크림",
                "모짜렐라", "파마산", "체다", "크림치즈", "케피어", "리코타", "사워크림",
            ]
        ):
            return hit("dairy")

        # ── 4) Grains / noodles ──
        if any(
            k in name_lower
            for k in [
                "파스타", "스파게티", "오르조", "펜네", "링귀니", "엔젤헤어",
                "국수", "라면", "우동", "당면", "소면", "소바", "메밀", "칼국수",
                "퀴노아", "쿠스쿠스",
            ]
        ):
            return hit("grains")

        if "김밥" not in name_lower and (
            name_lower in ("밥", "쌀밥", "즉석밥", "햇반")
            or name_lower.endswith("밥")
            or any(k in name_lower for k in ["쌀", "현미", "보리", "귀리", "잡곡"])
        ):
            return hit("grains")

        if any(k in name_lower for k in ["떡", "빵", "식빵", "바게트"]):
            return hit("grains")
        if "면" in name_lower and "김밥" not in name_lower:
            return hit("grains")

        # ── 5) Processed meat / tofu / kimchi / seafood ──
        if any(k in name_lower for k in ["맛살", "게맛살", "크래미", "어묵", "순대"]):
            return hit("meat_processed_egg")
        if any(k in name_lower for k in ["김치", "묵은지"]):
            return hit("vegetables_fruits")

        if any(
            k in name_lower
            for k in [
                "새우", "오징어", "문어", "주꾸미", "조개", "굴", "홍합", "꽃게",
                "생선", "고등어", "연어", "참치", "대구", "갈치", "삼치", "광어", "우럭",
                "멸치", "낙지", "꼬막", "바지락", "소라", "전복", "성게", "랍스터",
                "건새우", "건어물", "마른새우", "북어", "황태", "쥐포",
                "다시마", "미역", "장어", "회",
                "가다랑어", "가쓰오", "가츠오", "관자", "가리비",
            ]
        ):
            return hit("seafood")
        if name_lower == "게" or name_lower.startswith("게 ") or "게살" in name_lower:
            return hit("seafood")

        if any(
            k in name_lower
            for k in [
                "고기", "돼지", "소고기", "닭", "오리", "양고기",
                "삼겹", "목살", "갈비", "안심", "등심", "차돌", "차슈",
                "베이컨", "햄", "소시지", "스팸", "치킨",
            ]
        ):
            return hit("meat_processed_egg")

        if any(k in name_lower for k in ["두부", "순두부", "연두부", "유부", "부침두부"]):
            return hit("vegetables_fruits")

        if any(
            k in name_lower
            for k in [
                "배추", "양파", "당근", "오이", "토마토", "상추", "시금치", "브로콜리",
                "양배추", "마늘", "생강", "고추", "피망", "버섯", "가지", "호박",
                "무", "깻잎", "감자", "고구마", "부추", "콩나물", "숙주", "채소", "콩",
                "사과", "배", "딸기", "레몬", "라임", "아보카도",
                "대파", "쪽파", "청경채", "케일", "아스파라거스", "단무지", "쌈무",
            ]
        ):
            return hit("vegetables_fruits")
        if name_lower in ("파", "파 흰부분", "파흰부분") or name_lower.startswith("파 "):
            return hit("vegetables_fruits")
        if "대파" in name_lower or "흰부분" in name_lower or "파란 부분" in name_lower:
            return hit("vegetables_fruits")

        return None

    _VALID_6_CATEGORIES = [
        "vegetables_fruits", "meat_processed_egg", "seafood",
        "dairy", "grains", "seasonings_sauces",
    ]

    def categorize_ingredients_batch(self, ingredient_names: List[str]) -> List[Dict[str, Any]]:
        """
        Categorize multiple ingredients using 6 cooking-role groups.
        Pattern matching first, then a single LLM call for the rest.
        Returns list of {"category": "<6-group key>", "confidence": "high"|"medium"|"low"}.
        """
        self.last_usage_tokens = (0, 0, 0)
        results: List[Dict[str, Any]] = []
        need_llm: List[int] = []
        for i, name in enumerate(ingredient_names):
            name = (name or "").strip()
            if not name:
                results.append({"category": "seasonings_sauces", "confidence": "low"})
                continue
            matched = self._pattern_match_category(name)
            if matched:
                results.append(matched)
            else:
                results.append({"category": "seasonings_sauces", "confidence": "low"})
                need_llm.append(i)
        if not need_llm:
            return results
        names_for_llm = [ingredient_names[i] for i in need_llm]
        try:
            system = (
                "You categorize Korean cooking ingredients into 6 groups based on COOKING ROLE.\n"
                "Return a JSON array of objects with keys \"ingredient\" and \"category\".\n"
                "Valid categories (pick exactly one per ingredient):\n"
                "  vegetables_fruits — fresh produce, aromatics, tofu/bean products (마늘, 대파, 생강, 두부, 순두부, 유부 = always here)\n"
                "  meat_processed_egg — meat, processed meat (스팸, 어묵). NO eggs, NO tofu here.\n"
                "  seafood — raw fish, shellfish, dried seafood, seaweed (NOT sauces: 굴소스→seasonings_sauces)\n"
                "  dairy — milk, cheese, cream, butter, yogurt, AND eggs (계란, 달걀, 메추리알)\n"
                "  grains — rice, noodles, pasta, flour, bread, rice cakes\n"
                "  seasonings_sauces — sauces, oils, pastes, spices, vinegar, sweeteners. Cooking role trumps origin.\n"
            )
            user = "Categorize (return JSON array only):\n" + "\n".join(f"- {n}" for n in names_for_llm)
            primary_model = os.getenv("CATEGORIZE_PRIMARY_MODEL", "deepseek-v4-flash")
            raw = self._llm_generate_text(
                system=system,
                user=user,
                primary=os.getenv("CATEGORIZE_PRIMARY_PROVIDER", "deepseek"),
                primary_model=primary_model,
                record_parse_call_type="ingredient_categorize",
            )
            if raw.startswith("```"):
                raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
            import json
            start = raw.find("[")
            end = raw.rfind("]") + 1
            arr = json.loads(raw[start:end]) if start != -1 and end > start else []
            for k, idx in enumerate(need_llm):
                cat = "seasonings_sauces"
                if k < len(arr):
                    obj = arr[k]
                    if isinstance(obj, dict):
                        cat = (obj.get("category") or "").strip()
                    elif isinstance(obj, str) and obj in self._VALID_6_CATEGORIES:
                        cat = obj
                if cat not in self._VALID_6_CATEGORIES:
                    cat = "seasonings_sauces"
                results[idx] = {"category": cat, "confidence": "medium"}
        except Exception as e:
            print(f"[ERROR] Batch LLM categorization failed: {e}")
            for idx in need_llm:
                results[idx] = {"category": "seasonings_sauces", "confidence": "low"}
        return results
    
    # Maps legacy category keys to the best 6-group equivalent.
    _LEGACY_TO_6 = {
        "main": "meat_processed_egg",
        "sub": "vegetables_fruits",
        "sauce_msg": "seasonings_sauces",
        "protein": "meat_processed_egg",
        "seasonings": "seasonings_sauces",
        "dairy_eggs_refrigerated": "dairy",
        "room_temperature": "grains",
    }

    def reclassify_ingredient(self, ingredient_name: str, old_category: Optional[str] = None) -> Dict[str, Any]:
        """
        Reclassify an ingredient from any old category system to the 6-group system.
        Uses pattern matching first, then LLM fallback.
        """
        ingredient_name = ingredient_name.strip()
        self.last_usage_tokens = (0, 0, 0)
        if not ingredient_name:
            fallback = self._LEGACY_TO_6.get(old_category, "seasonings_sauces")
            return {"category": fallback, "confidence": "low"}

        matched = self._pattern_match_category(ingredient_name)
        if matched:
            return matched

        try:
            system = (
                "You categorize Korean cooking ingredients by COOKING ROLE.\n"
                "Return ONLY one of these 6 values, nothing else:\n"
                "vegetables_fruits, meat_processed_egg, seafood, dairy, grains, seasonings_sauces\n"
                "Key rule: cooking role trumps origin (굴소스→seasonings_sauces, not seafood).\n"
                "마늘/대파/생강 = always vegetables_fruits. 두부/순두부/유부 = always vegetables_fruits. 계란/달걀 = dairy."
            )
            user = f"Categorize: {ingredient_name}"
            primary_model = os.getenv("CATEGORIZE_PRIMARY_MODEL", "deepseek-v4-flash")
            result = self._llm_generate_text(
                system=system,
                user=user,
                primary=os.getenv("CATEGORIZE_PRIMARY_PROVIDER", "deepseek"),
                primary_model=primary_model,
            ).strip().lower()
            if result in self._VALID_6_CATEGORIES:
                return {"category": result, "confidence": "medium"}
            for cat in self._VALID_6_CATEGORIES:
                if cat in result:
                    return {"category": cat, "confidence": "low"}
            fallback = self._LEGACY_TO_6.get(old_category, "seasonings_sauces")
            return {"category": fallback, "confidence": "low"}
        except Exception as e:
            print(f"[ERROR] LLM reclassification failed for '{ingredient_name}': {e}")
            fallback = self._LEGACY_TO_6.get(old_category, "seasonings_sauces")
            return {"category": fallback, "confidence": "low"}
    
    def extract_main_ingredients(self, cart_recipes: List[Dict[str, Any]]) -> Dict[str, float]:
        """
        Extract protein/main ingredients from cart recipes and aggregate quantities.
        Returns dict: {ingredient_name: total_qty}
        
        Uses new category system: "protein" (or old "main" for backward compatibility).
        If no ingredients have 'category' field, treats all ingredients as protein (backwards compatibility).
        
        Args:
            cart_recipes: List of recipe dictionaries from cart
            
        Returns:
            Dictionary mapping ingredient names to total quantities
        """
        main_ingredients = {}
        has_any_categories = False
        
        # First pass: check if any ingredients have categories
        for cart_recipe in cart_recipes:
            recipe_data = cart_recipe.get('recipe', {})
            ingredients = recipe_data.get('ingredients', [])
            for ing in ingredients:
                if 'category' in ing and ing.get('category'):
                    has_any_categories = True
                    break
            if has_any_categories:
                break
        
        print(f"[DEBUG] Has categorized ingredients: {has_any_categories}")
        
        for cart_recipe in cart_recipes:
            recipe_data = cart_recipe.get('recipe', {})
            ingredients = recipe_data.get('ingredients', [])
            servings = cart_recipe.get('servings', 1)
            base_servings = recipe_data.get('servings', 1)
            scale_factor = servings / base_servings if base_servings > 0 else 1
            
            print(f"[DEBUG] Processing recipe: {recipe_data.get('name', 'Unknown')}, ingredients: {len(ingredients)}")
            
            for ingredient in ingredients:
                category = ingredient.get('category', '')
                # New category system: "protein" is main ingredient
                # Old category system: "main" is main ingredient
                # If no categories exist, treat all as protein/main
                is_main = False
                if has_any_categories:
                    is_main = (category == 'protein' or category == 'main')
                else:
                    is_main = True  # Backward compatibility: treat all as main if no categories
                
                if is_main:
                    item = ingredient.get('item', '').strip()
                    qty = ingredient.get('qty', 0) or 0
                    
                    print(f"[DEBUG]   - Main ingredient: {item}, qty: {qty}, category: '{category}'")
                    
                    if item:
                        scaled_qty = qty * scale_factor
                        if item in main_ingredients:
                            main_ingredients[item] += scaled_qty
                        else:
                            main_ingredients[item] = scaled_qty
        
        print(f"[DEBUG] Extracted main ingredients: {list(main_ingredients.keys())}")
        return main_ingredients
    
    def extract_user_preferences(
        self,
        cart_recipes: List[Dict[str, Any]],
        explicit_preferences: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        """
        Extract user taste preferences from cart recipes and explicit preferences.
        
        Args:
            cart_recipes: List of recipe dictionaries from cart
            explicit_preferences: Optional explicit user preferences
            
        Returns:
            Dictionary with tags, categories, and other preferences
        """
        preferences = {
            'tags': [],
            'categories': {
                'country': [],
                'cook_time': [],
                'menu_type': [],
                'main_ingredient': [],
                'main_ingredient_sub': [],
                # Backward compatibility with existing recommendation prompts/data
                'meat_type': [],
                'cuisine_type': [],
                'meal_time': [],
                'ingredient_type': [],
                'time_category': []
            }
        }
        
        # Extract from cart recipes
        for cart_recipe in cart_recipes:
            source = cart_recipe.get('source', {})
            
            # Tags
            tags = source.get('tags', [])
            if tags:
                preferences['tags'].extend(tags)
            
            # Categories
            categories = source.get('categories', {})
            for cat_type in preferences['categories'].keys():
                cat_values = categories.get(cat_type, [])
                if cat_values:
                    preferences['categories'][cat_type].extend(cat_values)
        
        # Remove duplicates
        preferences['tags'] = list(set(preferences['tags']))
        for cat_type in preferences['categories']:
            preferences['categories'][cat_type] = list(set(preferences['categories'][cat_type]))
        
        # Merge with explicit preferences if provided
        if explicit_preferences:
            if 'tags' in explicit_preferences:
                preferences['tags'].extend(explicit_preferences['tags'])
                preferences['tags'] = list(set(preferences['tags']))
            
            if 'categories' in explicit_preferences:
                for cat_type, cat_values in explicit_preferences['categories'].items():
                    if cat_values:
                        preferences['categories'][cat_type].extend(cat_values)
                        preferences['categories'][cat_type] = list(set(preferences['categories'][cat_type]))
        
        return preferences
    
    def normalize_ingredient_name(self, name: str) -> str:
        """
        Normalize ingredient names for better matching.
        Removes common suffixes and normalizes pasta/noodle names.
        
        Args:
            name: Ingredient name to normalize
            
        Returns:
            Normalized ingredient name
        """
        if not name:
            return ""
        
        # Convert to lowercase for comparison
        normalized = name.lower().strip()
        
        # Remove common suffixes
        suffixes = ['면', ' noodles', ' noodle', ' 파스타', ' pasta']
        for suffix in suffixes:
            if normalized.endswith(suffix):
                normalized = normalized[:-len(suffix)].strip()
        
        return normalized
    
    def are_ingredients_similar(self, ing1: str, ing2: str) -> bool:
        """
        Check if two ingredients are similar (same category).
        Handles pasta/noodle variations, fuzzy matching, etc.
        
        Args:
            ing1: First ingredient name
            ing2: Second ingredient name
            
        Returns:
            True if ingredients are similar, False otherwise
        """
        if not ing1 or not ing2:
            return False
        
        # Normalize both names
        norm1 = self.normalize_ingredient_name(ing1)
        norm2 = self.normalize_ingredient_name(ing2)
        
        # Exact match after normalization
        if norm1 == norm2:
            return True
        
        # Check if one contains the other (handles "스파게티 면" vs "스파게티")
        if norm1 in norm2 or norm2 in norm1:
            return True
        
        # Fuzzy match using rapidfuzz
        from rapidfuzz import fuzz
        similarity = fuzz.ratio(norm1, norm2) / 100.0
        return similarity >= 0.85


# Global instance (for backward compatibility during migration)
_ingredient_service: Optional[IngredientService] = None


def get_ingredient_service() -> IngredientService:
    """Get or create global ingredient service instance"""
    global _ingredient_service
    if _ingredient_service is None:
        _ingredient_service = IngredientService()
    return _ingredient_service

