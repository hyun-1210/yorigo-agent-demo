"""
Pydantic models for API requests and responses
"""

from typing import List, Optional, Dict, Any
from pydantic import BaseModel, HttpUrl, Field, model_validator


# Recipe Parsing Models
class ParseRequest(BaseModel):
    url: HttpUrl
    prefer_lang: Optional[str] = "ko"


# Manual paste 입력 제한
_CONTENT_TEXT_MAX_LEN = 50_000
_CONTENT_MAX_IMAGES = 5


class ContentParseRequest(BaseModel):
    """
    Manual paste 입력 — 텍스트와/또는 스크린샷에서 레시피를 추출한다.

    images: base64-encoded image bytes (data URI prefix는 허용; 라우터에서 strip).
            각 이미지는 4MB 이하(라우터에서 검증), 최대 5장.
    text  : 사용자가 paste한 자유 텍스트, 50KB 이하.
    둘 중 최소 하나는 비어있지 않아야 한다.
    """

    text: Optional[str] = Field(default=None, max_length=_CONTENT_TEXT_MAX_LEN)
    images: Optional[List[str]] = Field(default=None, max_length=_CONTENT_MAX_IMAGES)
    prefer_lang: Optional[str] = "ko"

    @model_validator(mode="after")
    def _ensure_at_least_one_source(self) -> "ContentParseRequest":
        text_ok = self.text is not None and self.text.strip() != ""
        images_ok = self.images is not None and len(self.images) > 0
        if not text_ok and not images_ok:
            raise ValueError("text 또는 images 중 최소 하나는 제공해야 합니다.")
        return self


class Ingredient(BaseModel):
    qty: Optional[float] = None
    unit: Optional[str] = None
    qty_conventional: Optional[float] = None
    unit_conventional: Optional[str] = None
    item: str
    notes: Optional[str] = None
    category: Optional[str] = None
    estimated: Optional[bool] = False


class Step(BaseModel):
    order: int
    instruction: str
    tip: Optional[str] = None
    step_ingredients: Optional[List[str]] = None
    est_minutes: Optional[int] = None
    tools: Optional[List[str]] = None


class Recipe(BaseModel):
    name: Optional[str] = None
    servings: Optional[int] = None
    ingredients: List[Ingredient]
    steps: List[Step]
    equipment: Optional[List[str]] = None
    notes: Optional[List[str]] = None


class NutritionLLM(BaseModel):
    """Nutrition info calculated by LLM from ingredients"""
    calories_per_serving: float
    protein_g: float
    fat_g: float
    carbs_g: float
    sodium_mg: float
    sugar_g: float = 0.0
    cholesterol_mg: float = 0.0
    fiber_g: float = 0.0


class Nutrition(BaseModel):
    per_serving: Dict[str, float]
    assumptions: List[str]
    llm_estimate: Optional[NutritionLLM] = None


class ParseResponse(BaseModel):
    source: Dict[str, Any]
    recipe: Recipe
    nutrition: Nutrition
    debug: Dict[str, Any]


# Product Search Models
class ProductSearchRequest(BaseModel):
    ingredient_name: str
    original_ingredient_name: Optional[str] = None  # 원본 재료명 (전처리 전) - 필터링에 사용
    needed_qty: Optional[float] = None
    needed_unit: Optional[str] = None
    limit: Optional[int] = 10
    marketplace: Optional[str] = "coupang"  # "coupang" | "kurly" - 추천 소스
    # 레시피 상세 미리보기는 장바구니 수요가 아니므로 스크래핑 우선순위 기록을 끈다.
    record_cart_hit: bool = True
    # False면 best_match만 반환. 미리보기 레일은 see_more 딥링크/페이로드가 필요 없다.
    include_see_more: bool = True


def recommendation_payload_lists(
    include_see_more: bool,
    sorted_products: List[Any],
    best_match: Any,
    see_more_cap: int = 0,
) -> tuple[List[Any], List[Any]]:
    """see_more 포함 여부에 따라 (see_more_list, enrich_targets)를 고른다."""
    if not include_see_more:
        enrich = [best_match] if best_match is not None else []
        return [], enrich
    see_more_list = (
        sorted_products[:see_more_cap]
        if see_more_cap and see_more_cap > 0
        else list(sorted_products)
    )
    combined: List[Any] = ([best_match] if best_match else []) + see_more_list
    return see_more_list, combined


class CoupangProduct(BaseModel):
    product_id: str
    product_name: str
    product_price: int
    product_image: str
    product_url: str
    original_url: Optional[str] = None
    deeplink_url: Optional[str] = None
    landing_url: Optional[str] = None
    is_rocket: bool = False
    is_free_shipping: bool = False
    unit_price: Optional[float] = None
    package_size: Optional[float] = None
    package_unit: Optional[str] = None
    match_score: Optional[float] = None
    tag: Optional[str] = None
    sales_rank: Optional[int] = None
    # New fields from scraping
    original_price: Optional[int] = None  # Original price before discount
    discount_rate: Optional[float] = None  # Discount rate (%)
    rating: Optional[float] = None  # Product rating (0.0 ~ 5.0)
    reviews: Optional[int] = None  # Number of reviews
    arrival_info: Optional[str] = None  # Arrival information
    delivery_text_raw: Optional[str] = None  # Original scraped delivery text (preserved)
    delivery_eta_days: Optional[int] = None  # Days until delivery from scrape date (scraped_at + raw only)
    volume_g: Optional[float] = None  # Normalized package volume in base unit (g/ml)
    bayesian_rating: Optional[float] = None  # Bayesian adjusted rating
    value_score: Optional[float] = None  # Value score based on rating and unit price


class ProductRecommendationResponse(BaseModel):
    ingredient: str
    display_name: Optional[str] = None
    needed_qty: Optional[float] = None
    needed_unit: Optional[str] = None
    best_match: Optional[CoupangProduct] = None
    see_more_list: List[CoupangProduct] = []
    all_products: List[CoupangProduct] = []


class BatchProductSearchRequest(BaseModel):
    items: List[ProductSearchRequest]


class BatchProductRecommendationResponse(BaseModel):
    items: List[ProductRecommendationResponse] = []


class AdminExcludeProductRequest(BaseModel):
    product_id: str = Field(..., description="전역 제외할 상품 ID")
    reason: Optional[str] = Field(None, description="제외 사유")


class AdminExcludedProductItem(BaseModel):
    productId: str
    reason: Optional[str] = None
    active: bool = True
    createdBy: Optional[str] = None
    createdAt: Optional[str] = None


class AdminExcludedProductListResponse(BaseModel):
    items: List[AdminExcludedProductItem] = []


class ProductSearchResult(BaseModel):
    product_id: str
    product_name: str
    product_price: int
    product_image: str
    product_url: str
    is_rocket: bool = False
    is_free_shipping: bool = False
    package_size: Optional[float] = None
    package_unit: Optional[str] = None
    unit_price: Optional[float] = None
    amount_match_score: float = 0.0
    total_match_score: float = 0.0


class AdvancedProductSearchResponse(BaseModel):
    ingredient: str
    needed_qty: Optional[float] = None
    needed_unit: Optional[str] = None
    best_amount_match: Optional[ProductSearchResult] = None
    cheapest_same_amount: Optional[ProductSearchResult] = None
    cheapest_overall: Optional[ProductSearchResult] = None
    all_products: List[ProductSearchResult] = []


# Recipe Recommendation Models
# Ingredient Models
class PreprocessIngredientsRequest(BaseModel):
    ingredients: List[str]


class PreprocessIngredientsResponse(BaseModel):
    preprocessed: Dict[str, str]


class CategorizeIngredientRequest(BaseModel):
    ingredient_name: str
    category: Optional[str] = None


class CategorizeIngredientResponse(BaseModel):
    category: str
    confidence: Optional[str] = None


class ReclassifyIngredientRequest(BaseModel):
    ingredient_name: str
    old_category: Optional[str] = None


class ReclassifyIngredientResponse(BaseModel):
    category: str
    confidence: Optional[str] = None


# Fridge photo/receipt scan models (POST /fridge/scan_photo)
class FridgeScanItem(BaseModel):
    """사진/영수증에서 인식된 재료 1건."""
    name: str
    category: str  # vegetables_fruits|meat_processed_egg|seafood|dairy|grains|seasonings_sauces
    qty: float
    unit: str
    confidence: float = Field(ge=0.0, le=1.0)
    raw_line: Optional[str] = Field(
        default=None,
        description="영수증 원문 라인 (사용자가 원문과 대조할 수 있도록 그대로 전달)",
    )
    price: Optional[int] = Field(
        default=None,
        description="영수증에 표기된 해당 라인의 결제 금액(원). 냉장고 재고에는 쓰지 않고 "
        "구매 이력 저장용으로만 사용.",
    )
    is_food: bool = Field(
        default=True,
        description="식재료로 판단되면 true. false면 프론트에서 회색/비선택 섹션으로 분리.",
    )


class FridgeScanResponse(BaseModel):
    photo_type: str  # "receipt" | "fridge_interior"
    items: List[FridgeScanItem] = Field(default_factory=list)
    warning: Optional[str] = Field(
        default=None,
        description="인식 실패/부분 실패 시 사용자에게 보여줄 안내 문구",
    )
    store_name: Optional[str] = Field(
        default=None,
        description="영수증 상단 매장 상호명 (photo_type=receipt일 때만).",
    )
    store_branch: Optional[str] = Field(
        default=None,
        description="지점명 (예: 신도림점). 없으면 null.",
    )
    store_address: Optional[str] = Field(
        default=None,
        description="영수증에 인쇄된 매장 사업장 주소. 이후 장소 매칭용.",
    )
    region_sido: Optional[str] = Field(
        default=None,
        description="매장 시/도 (예: 경기도).",
    )
    region_sigungu: Optional[str] = Field(
        default=None,
        description="매장 시/군/구 (예: 의정부시).",
    )
    purchased_at: Optional[str] = Field(
        default=None,
        description="영수증에 표기된 구매 날짜(YYYY-MM-DD), 없으면 null.",
    )


# Kakao Authentication Models
class KakaoTokenRequest(BaseModel):
    """카카오 access token을 받아서 Firebase Custom Token을 생성하는 요청"""
    access_token: str = Field(..., description="카카오 access token")


class KakaoTokenResponse(BaseModel):
    """Firebase Custom Token과 카카오 사용자 정보를 반환하는 응답"""
    custom_token: str = Field(..., description="Firebase Custom Token")
    kakao_id: str = Field(..., description="카카오 사용자 ID")
    email: str = Field(..., description="카카오 이메일")
    display_name: str = Field(..., description="카카오 닉네임 또는 이름")
    birth_date: Optional[str] = Field(
        default=None,
        description="카카오에서 제공한 생년월일(YYYY-MM-DD, 제공 시)",
    )
    requires_profile_completion: bool = Field(
        default=False,
        description="프로필/연령 보완이 필요한 상태인지 여부",
    )


class KakaoLinkRequest(BaseModel):
    """
    현재 로그인된 Firebase 유저에 카카오 계정을 연결(link)하기 위한 요청.
    - access_token: 카카오 access token
    - firebase_id_token: 현재 앱 로그인 상태의 Firebase ID token
    """
    access_token: str = Field(..., description="카카오 access token")
    firebase_id_token: str = Field(..., description="Firebase ID token")


class KakaoLinkResponse(BaseModel):
    """카카오 연결 결과"""
    kakao_id: str
    uid: str
    linked: bool = True


class KakaoUnlinkRequest(BaseModel):
    """현재 로그인된 Firebase 유저의 카카오 연결을 해제하기 위한 요청"""
    firebase_id_token: str = Field(..., description="Firebase ID token")


class KakaoUnlinkResponse(BaseModel):
    kakao_id: str
    uid: str
    unlinked: bool = True


class AccountDeletionRequest(BaseModel):
    """서버 주도 계정 삭제 요청"""
    firebase_id_token: str = Field(..., description="Firebase ID token")


class AccountDeletionResponse(BaseModel):
    """서버 주도 계정 삭제 결과"""
    uid: str
    deleted: bool
    legal_hold_applied: bool = False
    deleted_counts: Dict[str, int] = Field(default_factory=dict)
    message: str


class AgeVerificationRequest(BaseModel):
    """가입 전 연령 검증 요청"""
    birth_date: Optional[str] = Field(
        default=None,
        description="검증 대상 생년월일 (YYYY-MM-DD)",
    )
    verification_method: str = Field(
        default="self_reported",
        description="self_reported | social_profile | pass | sms",
    )
    provider: Optional[str] = Field(
        default=None,
        description="가입 경로 (kakao | google | email 등)",
    )


class AgeVerificationResponse(BaseModel):
    """가입 연령 검증 결과"""
    allowed: bool = Field(..., description="가입 허용 여부")
    is_under_14: bool = Field(..., description="만 14세 미만 여부")
    requires_additional_verification: bool = Field(
        default=False,
        description="추가 본인인증 필요 여부",
    )
    recommended_verification_method: Optional[str] = Field(
        default=None,
        description="추천 추가 인증 방식(pass | sms)",
    )
    available_verification_methods: List[str] = Field(
        default_factory=list,
        description="선택 가능한 추가 인증 방식 목록",
    )
    computed_age: Optional[int] = Field(default=None, description="서버 계산 만 나이")
    reason: str = Field(..., description="판정 사유 코드")


class PassVerificationRequest(BaseModel):
    """PASS 인증 토큰 검증 요청"""
    verification_token: str = Field(..., description="PASS SDK에서 발급된 검증 토큰")
    request_id: Optional[str] = Field(default=None, description="클라이언트 요청 추적 ID")
    provider: Optional[str] = Field(
        default=None,
        description="가입 경로 (kakao | google | email 등)",
    )
    retry_count: int = Field(
        default=0,
        ge=0,
        le=5,
        description="클라이언트에서 관리하는 재시도 횟수",
    )


class PassVerificationResponse(BaseModel):
    """PASS 인증 토큰 검증 결과"""
    verified: bool = Field(..., description="PASS 검증 성공 여부")
    birth_date: Optional[str] = Field(
        default=None,
        description="검증된 생년월일 (YYYY-MM-DD)",
    )
    verification_method: str = Field(default="pass", description="항상 pass")
    reason: str = Field(..., description="결과 코드")
    retryable: bool = Field(default=False, description="재시도 가능 여부")
    max_retry_count: int = Field(default=3, description="권장 최대 재시도 횟수")
    reference_id: Optional[str] = Field(default=None, description="검증 트랜잭션 식별자")
    message: Optional[str] = Field(default=None, description="사용자 안내 메시지")


class NicePassInitRequest(BaseModel):
    provider: Optional[str] = Field(
        default=None,
        description="가입 경로 (kakao | google | email 등)",
    )


class NicePassInitResponse(BaseModel):
    request_id: str = Field(..., description="NICE 인증 세션 식별자")
    auth_action_url: str = Field(..., description="NICE 인증창 전송 URL")
    token_version_id: str = Field(..., description="NICE 토큰 버전 ID")
    enc_data: str = Field(..., description="NICE 요청 암호문")
    integrity_value: str = Field(..., description="요청 무결성 값")
    method_type: str = Field(default="get", description="NICE 응답 전달 방식")


class SmsVerificationRequest(BaseModel):
    """SMS 본인인증 토큰 검증 요청"""
    verification_token: str = Field(..., description="SMS 본인인증 검증 토큰")
    request_id: Optional[str] = Field(default=None, description="클라이언트 요청 추적 ID")
    provider: Optional[str] = Field(
        default=None,
        description="가입 경로 (kakao | google | email 등)",
    )
    retry_count: int = Field(
        default=0,
        ge=0,
        le=5,
        description="클라이언트에서 관리하는 재시도 횟수",
    )


class SmsVerificationResponse(BaseModel):
    """SMS 본인인증 토큰 검증 결과"""
    verified: bool = Field(..., description="SMS 검증 성공 여부")
    birth_date: Optional[str] = Field(
        default=None,
        description="검증된 생년월일 (YYYY-MM-DD)",
    )
    verification_method: str = Field(default="sms", description="항상 sms")
    reason: str = Field(..., description="결과 코드")
    retryable: bool = Field(default=False, description="재시도 가능 여부")
    max_retry_count: int = Field(default=3, description="권장 최대 재시도 횟수")
    reference_id: Optional[str] = Field(default=None, description="검증 트랜잭션 식별자")
    message: Optional[str] = Field(default=None, description="사용자 안내 메시지")


class NiceSmsInitRequest(BaseModel):
    provider: Optional[str] = Field(
        default=None,
        description="가입 경로 (kakao | google | email 등)",
    )


class NiceSmsInitResponse(BaseModel):
    request_id: str = Field(..., description="NICE 인증 세션 식별자")
    auth_action_url: str = Field(..., description="NICE 인증창 전송 URL")
    token_version_id: str = Field(..., description="NICE 토큰 버전 ID")
    enc_data: str = Field(..., description="NICE 요청 암호문")
    integrity_value: str = Field(..., description="요청 무결성 값")
    method_type: str = Field(default="get", description="NICE 응답 전달 방식")


class ReportMissingIngredientPricesRequest(BaseModel):
    """레시피 디테일에서 ingredient_unit_prices에 없는 재료명 보고"""
    names: List[str] = Field(..., min_length=1, description="정규화 전 재료명 목록")


class ReportMissingIngredientPricesResponse(BaseModel):
    accepted: int = Field(..., description="큐에 반영된 고유 재료명 개수")
    skipped: int = Field(0, description="비어 있거나 중복 등으로 무시된 개수")


# Ingredient unit price (baseUnit) request (on-demand)
class RequestIngredientUnitPriceRequest(BaseModel):
    ingredient_name: str = Field(..., description="재료명 (예: '계란')")
    requested_base_unit: str = Field(
        ...,
        description="요청 단위 (예: 'g', 'ml', '개', '큰술' 등). Firestore 문서 ID 정규화는 서버에서 수행.",
    )


class RequestIngredientUnitPriceResponse(BaseModel):
    ingredientName: str
    unitPrice: float
    baseUnit: str
    confidence: Optional[float] = None
    source: str = "ai_estimate"
    reasoning: Optional[str] = None


class ReportIngredientPriceIssueRequest(BaseModel):
    """재료 단가가 부정확해 보일 때 사용자 보고 (재조사 큐 적재)."""
    ingredient_names: List[str] = Field(
        ...,
        min_length=1,
        description="문제가 있다고 느낀 재료명 목록",
    )
    message: Optional[str] = Field(
        None,
        max_length=500,
        description="추가 설명 (선택)",
    )
    recipe_id: Optional[str] = Field(None, max_length=128)
    recipe_title: Optional[str] = Field(None, max_length=200)


class ReportIngredientPriceIssueResponse(BaseModel):
    accepted: int = Field(..., description="재조사 큐에 반영된 고유 재료명 개수")
    skipped: int = Field(0, description="비어 있거나 길이 초과 등으로 무시된 개수")


# Conversion gap research (admin + LLM, batch of 1–3)
class ConversionGapItem(BaseModel):
    """One row from the app [IngredientConversionGapLedger]."""

    kind: str = Field(..., description="defaultGramPerCountFallback | passThroughShoppingUnit | cartAggregationUnitMismatch")
    ingredientName: str = Field(..., description="식재료명")
    recipeUnit: Optional[str] = None
    shoppingUnit: Optional[str] = None
    detail: Optional[str] = None
    recordedAt: Optional[str] = None


class ConversionGapResearchRequest(BaseModel):
    gaps: List[ConversionGapItem] = Field(
        ...,
        min_length=1,
        max_length=3,
        description="Exactly 1–3 gaps per request (rate limit / one Gemini call).",
    )


class ConversionGapResearchResponse(BaseModel):
    ok: bool = True
    model: Dict[str, Any] = Field(default_factory=dict, description="Parsed JSON object from Gemini")
    reference_search_urls: List[List[str]] = Field(
        default_factory=list,
        description="Per gap: 3 Google search URLs embedded in the prompt",
    )


# Ingredient shelf-life research (admin + LLM)
class ShelfLifeResearchRequest(BaseModel):
    ingredient_names: List[str] = Field(
        ...,
        min_length=1,
        max_length=10,
        description="1–10 ingredient names to research shelf life for",
    )


class ShelfLifeEntry(BaseModel):
    ingredientName: str
    storageType: str = Field(..., description="frozen | refrigerated | room_temp")
    shelfLifeDays: int = Field(..., ge=1, le=3650)
    notes: Optional[str] = None


class ShelfLifeResearchResponse(BaseModel):
    ok: bool = True
    results: List[ShelfLifeEntry] = Field(default_factory=list)


# ─── 구매완료 사진 인증 (온라인 주문확인 스크린샷) ──────────────────────
# EXP/포인트 일반 청구(claim)는 Firebase Cloud Functions(yorigo-frontend/functions/rewards.js)로
# 이전됨 — Firestore와 같은 프로젝트라 Railway 백엔드 왕복보다 빠르고 저렴하다.
# 이 백엔드는 Gemini Vision 분석이 필요한 구매완료 사진 인증만 담당한다.
# 기존 냉장고 영수증 스캔(photo_type=receipt)과는 완전히 별도의 플로우.


class PurchaseVerificationSubmitResponse(BaseModel):
    verificationId: str
    status: str = Field(..., description="approved | pending | rejected")
    pointsAwarded: int = 0
    marketplace: Optional[str] = None
    extractedAmount: Optional[int] = None
    extractedOrderNumber: Optional[str] = None
    reason: Optional[str] = None


class PurchaseVerificationStatusResponse(BaseModel):
    verificationId: str
    status: str
    pointsAwarded: int = 0
    marketplace: Optional[str] = None
    createdAt: Optional[str] = None


class PurchaseVerificationReviewRequest(BaseModel):
    action: str = Field(..., description="approve | reject")
    note: Optional[str] = Field(default=None, max_length=500)


class RecipeAgentHistoryTurn(BaseModel):
    role: str = Field(..., description="user | assistant")
    text: str = Field(default="", max_length=200)


class RecipeAgentPatch(BaseModel):
    action: str
    item: Optional[str] = None
    qty: Optional[float] = None
    unit: Optional[str] = None
    memo: Optional[str] = None
    category: Optional[str] = None
    order: Optional[int] = None
    instruction: Optional[str] = None


class RecipeAgentTurnRequest(BaseModel):
    recipe_id: Optional[str] = Field(default=None, max_length=128)
    chip_id: Optional[str] = Field(default=None, max_length=40)
    message: Optional[str] = Field(default=None, max_length=500)
    focus_ingredient: Optional[str] = Field(default=None, max_length=80)
    overlay: Optional[Dict[str, Any]] = None
    client_snapshot: Optional[Dict[str, Any]] = None
    history: Optional[List[RecipeAgentHistoryTurn]] = Field(default=None, max_length=4)
    pending_patches: Optional[List[RecipeAgentPatch]] = Field(
        default=None,
        max_length=8,
        description="직전 턴에서 제안된 패치. 네/아니오 확인 때 다시 보낸다.",
    )


class RecipeAgentTurnResponse(BaseModel):
    on_topic: bool
    reply: str
    followup_chips: List[str] = []
    proposed_patches: List[RecipeAgentPatch] = []
    warnings: List[str] = []
    engine: str = ""
    awaiting_confirm: bool = False


class HomeAgentTurnRequest(BaseModel):
    chip_id: Optional[str] = Field(default=None, max_length=40)
    message: Optional[str] = Field(default=None, max_length=500)
    focus_ingredient: Optional[str] = Field(default=None, max_length=80)
    history: Optional[List[RecipeAgentHistoryTurn]] = Field(default=None, max_length=4)


class HomeAgentPick(BaseModel):
    recipe_id: str = Field(max_length=80)
    reason: str = Field(max_length=200)
    name: str = Field(default="", max_length=80)


class GroceryAgentTurnRequest(BaseModel):
    message: Optional[str] = Field(default=None, max_length=500)
    chip_id: Optional[str] = Field(default=None, max_length=40)
    history: Optional[List[RecipeAgentHistoryTurn]] = Field(default=None, max_length=6)


class GroceryMealSlot(BaseModel):
    day: str = ""
    recipe_id: str = ""
    recipe_name: str = ""
    servings: int = 2
    note: str = ""


class GroceryGapItem(BaseModel):
    name: str = ""
    needed: str = ""
    action: str = ""
    note: str = ""


class GroceryBasketLine(BaseModel):
    name: str = ""
    product_name: str = ""
    pack: str = ""
    price: int = 0
    needed_g: int = 0
    pack_g: int = 0
    waste_pct: int = 0
    reason: str = ""


class GroceryAgentTurnResponse(BaseModel):
    on_topic: bool
    reply: str = ""
    phase: str = ""
    skills_loaded: List[str] = []
    policy_decision: str = ""
    used_llm: bool = False
    engine: str = ""
    solver: str = ""
    meals: List[GroceryMealSlot] = []
    gap: List[GroceryGapItem] = []
    basket: List[GroceryBasketLine] = []
    total_price: int = 0
    budget: int = 0
    chips: List[str] = []
    warnings: List[str] = []
    run_id: str = ""


class HomeAgentTurnResponse(BaseModel):
    on_topic: bool
    reply: str = Field(default="", max_length=400)
    used_llm: bool = False
    used_ranker: bool = False
    retrieve: str = ""
    recipe_ids: List[str] = []
    q: str = ""
    spice_low: bool = False
    spice_high: bool = False
    section_key: str = ""
    followup_chips: List[str] = []
    warnings: List[str] = []
    engine: str = Field(default="", max_length=80)
    picks: List[HomeAgentPick] = []


class CoupangAttributedOrder(BaseModel):
    order_id: str
    product_id: Optional[str] = None
    product_name: Optional[str] = None
    quantity: Optional[int] = None
    gmv: Optional[float] = None
    commission: Optional[float] = None
    date: Optional[str] = None
    subparam: Optional[str] = None
    uid: Optional[str] = None
    match_status: str
    cancelled: bool = False
    source: Optional[str] = None


class CoupangOrderSyncResponse(BaseModel):
    fetched: int = 0
    upserted: int = 0
    matched: int = 0
    unmatched: int = 0
    no_subparam: int = 0
    cancelled: int = 0
    lookback_days: int = 0


class CoupangAttributedOrderListResponse(BaseModel):
    items: List[CoupangAttributedOrder] = []

