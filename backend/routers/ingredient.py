"""
Ingredient preprocessing and categorization endpoints
"""

from fastapi import APIRouter
from models import (
    PreprocessIngredientsRequest,
    PreprocessIngredientsResponse,
    CategorizeIngredientRequest,
    CategorizeIngredientResponse,
    ReclassifyIngredientRequest,
    ReclassifyIngredientResponse,
)
from services.ingredient_service import IngredientService, get_ingredient_service
from services.mixpanel_service import get_mixpanel_service

# 이 라우터의 엔드포인트들은 Firebase 인증을 요구하지 않아 요청자 uid를 알 수 없다.
# Mixpanel distinct_id로 쓸 고정 시스템 식별자.
_ANON_DISTINCT_ID = "anonymous_ingredient_api"


def _track_llm_usage(event: str, usage_tokens, **extra) -> None:
    """(input, output, thinking) 토큰 튜플을 Mixpanel 이벤트로 fire-and-forget 전송.
    LLM 호출이 없었으면(usage_tokens == (0, 0, 0)) 전송하지 않는다."""
    inp, out, think = usage_tokens or (0, 0, 0)
    if not (inp or out or think):
        return
    get_mixpanel_service().track(_ANON_DISTINCT_ID, event, {
        "llm_input_tokens": inp,
        "llm_output_tokens": out,
        "llm_thinking_tokens": think,
        "llm_total_tokens": inp + out + think,
        **extra,
    })


def create_ingredient_router(ingredient_service: IngredientService = None):
    """Create ingredient router with service injected. If service is None, it will be lazily loaded."""
    router = APIRouter(prefix="", tags=["ingredient"])
    
    def get_service() -> IngredientService:
        """Get ingredient service, lazy loading if needed"""
        if ingredient_service is not None:
            return ingredient_service
        return get_ingredient_service()
    
    @router.post("/preprocess_ingredients", response_model=PreprocessIngredientsResponse)
    def preprocess_ingredients(req: PreprocessIngredientsRequest):
        """Preprocess ingredient names for search"""
        service = get_service()
        result = service.preprocess_ingredients(req.ingredients)
        _track_llm_usage(
            "llm_ingredient_preprocess",
            getattr(service, "last_usage_tokens", None),
            ingredient_count=len(req.ingredients or []),
        )
        return PreprocessIngredientsResponse(preprocessed=result)
    
    @router.post("/categorize_ingredient", response_model=CategorizeIngredientResponse)
    def categorize_ingredient(req: CategorizeIngredientRequest):
        """Categorize an ingredient"""
        service = get_service()
        result = service.categorize_ingredient(
            req.ingredient_name,
            req.original_category
        )
        _track_llm_usage(
            "llm_ingredient_categorize_ondemand",
            getattr(service, "last_usage_tokens", None),
            endpoint="categorize_ingredient",
            category=result.get("category"),
        )
        return CategorizeIngredientResponse(
            category=result["category"],
            confidence=result.get("confidence")
        )
    
    @router.post("/reclassify_ingredient", response_model=ReclassifyIngredientResponse)
    def reclassify_ingredient(req: ReclassifyIngredientRequest):
        """Reclassify ingredient to new category system"""
        service = get_service()
        result = service.reclassify_ingredient(
            req.ingredient_name,
            req.old_category
        )
        _track_llm_usage(
            "llm_ingredient_categorize_ondemand",
            getattr(service, "last_usage_tokens", None),
            endpoint="reclassify_ingredient",
            category=result.get("category"),
        )
        return ReclassifyIngredientResponse(
            category=result["category"],
            confidence=result.get("confidence")
        )
    
    return router

