import '../models/recipe_models.dart';
import '../services/coupang_service.dart';
import 'ingredient_category_unifier.dart';

/// 레시피 상세 최적 상품 레일 식별자 (GCS / Mixpanel).
const String kBestIngredientProductsSectionId = 'best_ingredient_products';

/// 제휴 클릭 `source_screen`. 장바구니와 구분해 CTR을 본다.
const String kBestIngredientProductsAffiliateSource =
    'recipe_detail_best_rail';

const String kBestIngredientProductsRailTitle = '최적의 재료를 추천합니다';
const String kBestIngredientProductsRailSubtitle =
    '재료마다 가장 잘 맞는 상품 1개씩만 골랐어요';
const String kBestIngredientProductsPriceDisclaimer =
    '표시된 가격은 실제와 다를 수 있어요.';
const String kBestIngredientProductsCoupangAffiliateDisclosure =
    '이 포스팅은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.';
const String kBestIngredientProductsKurlyAffiliateDisclosure =
    '이 포스팅은 마켓컬리 큐레이터 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.';
const String kBestIngredientProductsCompareCta =
    '필요한 재료만 골라 구매하기';

const int kBestIngredientProductMaxCards = 8;

/// 레일 기본 마켓. 온보딩 선호와 무관하게 쿠팡부터 보여 준다.
const String kDefaultPreviewMarketplace = 'coupang';
const List<String> kPreviewRailMarketplaces = ['coupang', 'kurly'];

const String kBestIngredientProductsEmptyMarketplace =
    '이 마켓에서 고른 상품이 없어요';

/// 상세 미리보기 로드 vs 구매 시트용 전체 로드.
enum RecipeRecoLoadMode { preview, full }

String previewRailMarketplaceLabel(String marketplace) {
  return marketplace == 'kurly' ? '컬리' : '쿠팡';
}

String previewRailAffiliateDisclosure(String marketplace) {
  return marketplace == 'kurly'
      ? kBestIngredientProductsKurlyAffiliateDisclosure
      : kBestIngredientProductsCoupangAffiliateDisclosure;
}

String previewRailMarketplaceIconAsset(String marketplace) {
  return marketplace == 'kurly'
      ? 'assets/marketplace/kurly_app_icon.png'
      : 'assets/marketplace/coupang_app_icon.png';
}

/// 집안에 있을 법한 재료. 레일에서는 빼고, 장바구니 전체 로드에는 남긴다.
const Set<String> kBestIngredientProductPantrySkipNames = {
  '물',
  '소금',
  '후추',
  '후춧가루',
  '식용유',
  '참기름',
  '들기름',
  '깨',
  '통깨',
  '맛술',
  '미림',
  '설탕',
};

class BestIngredientProductCard {
  const BestIngredientProductCard({
    required this.ingredientName,
    required this.product,
    required this.marketplace,
  });

  final String ingredientName;
  final CoupangProduct product;
  final String marketplace;
}

String recipeRecoCacheKey(String marketplace, String ingredient) =>
    '$marketplace:$ingredient';

bool recommendationHasUsableBestMatch(ProductRecommendation? reco) {
  final product = reco?.bestMatch;
  return product != null &&
      product.productId.isNotEmpty &&
      product.productName.isNotEmpty;
}

bool recommendationHasSeeMore(ProductRecommendation? reco) {
  if (reco == null) return false;
  return reco.seeMoreList.isNotEmpty || reco.allProducts.isNotEmpty;
}

/// 미리보기는 세션 안 재요청을 막고, 장바구니는 slim 미리보기(see_more 없음)를 다시 친다.
bool shouldSkipRecommendationFetch({
  required ProductRecommendation? cached,
  required bool isPreview,
  required bool attemptedEmpty,
  double? neededQty,
}) {
  if (cached == null) return attemptedEmpty;
  if (isPreview) return true;
  final cachedQty = cached.neededQty;
  if (neededQty != null &&
      cachedQty != null &&
      (cachedQty - neededQty).abs() > 0.05) {
    return false;
  }
  if (!recommendationHasUsableBestMatch(cached) &&
      !recommendationHasSeeMore(cached)) {
    return true;
  }
  return recommendationHasSeeMore(cached);
}

bool shouldPersistRecommendation(ProductRecommendation reco) {
  return recommendationHasUsableBestMatch(reco) ||
      recommendationHasSeeMore(reco);
}

/// 미리보기 slim 응답이 장바구니 풀 캐시를 덮어쓰지 않게 한다.
ProductRecommendation? mergeIncomingRecommendation({
  required ProductRecommendation? existing,
  required ProductRecommendation incoming,
}) {
  if (!shouldPersistRecommendation(incoming)) return existing;
  if (existing != null &&
      recommendationHasSeeMore(existing) &&
      !recommendationHasSeeMore(incoming)) {
    return existing;
  }
  return incoming;
}

/// 온보딩 선호 마켓 정규화. 레일 기본값은 [kDefaultPreviewMarketplace].
String previewMarketplaceOf(String? preferredMarketplace) {
  final value = (preferredMarketplace ?? '').trim().toLowerCase();
  if (value == 'kurly' ||
      value == 'marketkurly' ||
      value == 'market_kurly') {
    return 'kurly';
  }
  return kDefaultPreviewMarketplace;
}

String otherPreviewMarketplace(String marketplace) {
  return marketplace == 'kurly' ? 'coupang' : 'kurly';
}

bool isPreviewRailMarketplace(String marketplace) {
  return kPreviewRailMarketplaces.contains(marketplace);
}

/// 선택한 마켓에 카드가 없고 아직 로드가 끝나지 않았으면 스켈레톤.
bool isPreviewMarketplaceLoading({
  required String marketplace,
  required Set<String> finishedMarketplaces,
  required bool hasCards,
}) {
  return !finishedMarketplaces.contains(marketplace) && !hasCards;
}

/// 미리보기 대상이 없거나, 쿠팡·컬리 모두 끝났는데 카드가 없으면 레일을 숨긴다.
bool shouldHidePreviewRail({
  required bool hasPreviewTargets,
  required Map<String, List<BestIngredientProductCard>> cardsByMarketplace,
  required Set<String> finishedMarketplaces,
}) {
  if (!hasPreviewTargets) return true;
  return kPreviewRailMarketplaces.every((marketplace) {
    final cards = cardsByMarketplace[marketplace];
    return finishedMarketplaces.contains(marketplace) &&
        (cards == null || cards.isEmpty);
  });
}

/// 요청은 있었는데 한 줄도 안 오면 HTTP 실패로 보고 한 번 더 친다.
bool shouldRetryPreviewStream({
  required int requestedCount,
  required int receivedCount,
}) {
  return requestedCount > 0 && receivedCount <= 0;
}

/// 스트림이 안 준 index는 세션 동안 재요청하지 않는다.
List<String> unreceivedRecommendationKeys({
  required List<Map<String, dynamic>> batchItems,
  required Set<int> receivedIndices,
}) {
  final keys = <String>[];
  for (var i = 0; i < batchItems.length; i++) {
    if (receivedIndices.contains(i)) continue;
    final marketplace = (batchItems[i]['marketplace'] as String? ?? '').trim();
    final name = (batchItems[i]['ingredient_name'] as String? ?? '').trim();
    if (marketplace.isEmpty || name.isEmpty) continue;
    keys.add(recipeRecoCacheKey(marketplace, name));
  }
  return keys;
}

bool isPantrySkipIngredient(String name) {
  return kBestIngredientProductPantrySkipNames.contains(name.trim());
}

/// 재료 탭 그룹 순서와 같게, 팬트리 제외·이름 중복 제거 후 [max]개.
List<Ingredient> selectPreviewIngredients(
  List<Ingredient> ingredients, {
  int max = kBestIngredientProductMaxCards,
}) {
  if (ingredients.isEmpty || max <= 0) return const [];

  final byGroup = <String, List<Ingredient>>{};
  for (final ingredient in ingredients) {
    final name = ingredient.item.trim();
    if (name.isEmpty) continue;
    final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: ingredient.category,
      ingredientName: name,
    );
    byGroup.putIfAbsent(groupKey, () => <Ingredient>[]).add(ingredient);
  }

  final seen = <String>{};
  final selected = <Ingredient>[];
  for (final key in IngredientCategoryUnifier.groupOrder) {
    for (final ingredient in byGroup[key] ?? const <Ingredient>[]) {
      final name = ingredient.item.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      if (isPantrySkipIngredient(name)) continue;
      selected.add(ingredient);
      if (selected.length >= max) return selected;
    }
  }
  return selected;
}

BestIngredientProductCard? _cardFromReco({
  required String ingredientName,
  required String marketplace,
  required ProductRecommendation? reco,
}) {
  final product = reco?.bestMatch;
  if (product == null ||
      product.productId.isEmpty ||
      product.productName.isEmpty) {
    return null;
  }
  return BestIngredientProductCard(
    ingredientName: ingredientName,
    product: product,
    marketplace: marketplace,
  );
}

/// 캐시의 `best_match`만 사용. see_more / all_products 는 장바구니 몫.
/// 마켓을 섞지 않고 [marketplace] 카드만 만든다.
List<BestIngredientProductCard> mapBestMatchCards({
  required List<Ingredient> previewIngredients,
  required Map<String, ProductRecommendation> recommendations,
  required String marketplace,
}) {
  final cards = <BestIngredientProductCard>[];
  for (final ingredient in previewIngredients) {
    final name = ingredient.item.trim();
    if (name.isEmpty) continue;
    final card = _cardFromReco(
      ingredientName: name,
      marketplace: marketplace,
      reco: recommendations[recipeRecoCacheKey(marketplace, name)],
    );
    if (card != null) cards.add(card);
  }
  return cards;
}

String formatWonPrice(int price) {
  return price.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
    (Match m) => '${m[1]},',
  );
}

String formatReviewCount(int count) {
  return count.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
    (Match m) => '${m[1]},',
  );
}

/// `/recommend_products_stream` items 배열. 미리보기는 cart_hit/see_more 를 끈다.
List<Map<String, dynamic>> buildRecommendationStreamItems({
  required List<Ingredient> ingredients,
  required List<String> marketplaces,
  required double Function(Ingredient ingredient) scaledQtyOf,
  required bool Function(
    String marketplace,
    String ingredientName,
    double neededQty,
  ) alreadyLoaded,
  required bool recordCartHit,
  bool includeSeeMore = true,
  int limit = 10,
}) {
  final items = <Map<String, dynamic>>[];
  for (final ingredient in ingredients) {
    final name = ingredient.item.trim();
    if (name.isEmpty) continue;
    for (final marketplace in marketplaces) {
      final neededQty = scaledQtyOf(ingredient);
      if (alreadyLoaded(marketplace, name, neededQty)) continue;
      items.add({
        'ingredient_name': name,
        'original_ingredient_name': name,
        'needed_qty': neededQty,
        'needed_unit': (ingredient.unit ?? '').trim(),
        'limit': limit,
        'marketplace': marketplace,
        'record_cart_hit': recordCartHit,
        'include_see_more': includeSeeMore,
      });
    }
  }
  return items;
}
