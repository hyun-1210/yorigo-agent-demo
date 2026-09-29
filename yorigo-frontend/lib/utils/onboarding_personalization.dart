/// 온보딩 답을 홈 레일 순서·홈 숨김·나라 칩·상품 순위에 연결한다.
/// 검색 화면은 이 모듈을 쓰지 않는다.
library;

import '../models/onboarding_profile.dart';
import '../services/coupang_service.dart';
import 'home_agent_intent.dart';
import 'recipe_signal_snapshot.dart';

const Map<String, String> kOnboardingCuisineToCountryLabel = {
  'korean': '한식',
  'chinese': '중식',
  'japanese': '일식',
  'western': '양식',
};

const Map<String, List<String>> kCuisineHomeSectionBoosts = {
  'home': ['comfort_bowl', 'moment_dinner'],
  'korean': ['comfort_bowl', 'moment_dinner'],
  'simple': ['quick_10min', 'ingredients_5', 'moment_solo'],
  'healthy': ['lean_strong'],
  'diet': ['lean_strong'],
  'high_protein': ['high_protein'],
  'soup': ['comfort_bowl'],
  'late_night': ['moment_late_night'],
  'dessert': ['dessert'],
  'baking': ['dessert'],
  'spicy': ['world_cup'],
};

String? onboardingCountrySectionKey(String cuisineId) {
  if (!kOnboardingCuisineToCountryLabel.containsKey(cuisineId)) return null;
  return 'onboarding_country_$cuisineId';
}

const List<String> _porkNeedles = [
  '돼지고기',
  '돼지',
  '삼겹',
  '목살',
  '제육',
  '항정',
  '돈가스',
  '돈까스',
  '베이컨',
  '햄',
  '소시지',
  '소세지',
  '족발',
  '앞다리살',
  '뒷다리살',
];

const List<String> _beefNeedles = [
  '소고기',
  '한우',
  '우삼겹',
  '차돌',
  '소갈비',
  '소불고기',
  '육회',
  '육사시미',
  '양지',
  '사태',
];

const List<String> _poultryNeedles = [
  '닭고기',
  '닭가슴',
  '닭다리',
  '닭봉',
  '치킨',
  '오리고기',
  '훈제오리',
];

const List<String> _seafoodNeedles = [
  '생선',
  '고등어',
  '갈치',
  '연어',
  '참치',
  '명태',
  '오징어',
  '낙지',
  '문어',
  '새우',
  '멸치',
  '액젓',
  '까나리',
];

const List<String> _eggNeedles = ['계란', '달걀', '메추리알', '난류'];

const List<String> _dairyNeedles = ['우유', '치즈', '버터', '생크림', '요거트', '밀크'];

const Map<String, List<String>> _allergenNeedles = {
  'crustacean': ['새우', '게살', '게장', '꽃게', '대게', '랍스터', '가재', '크랩', '대하'],
  'egg': _eggNeedles,
  'milk': _dairyNeedles,
  'nuts': ['땅콩', '아몬드', '호두', '캐슈', '피스타치오', '견과'],
  'wheat': ['밀가루', '강력분', '박력분', '소맥', '통밀'],
  'soy': ['대두', '두유', '콩고기', '대두단백'],
  'fish': ['생선', '고등어', '갈치', '연어', '참치', '명태', '멸치'],
  'peach': ['복숭아', '피치'],
};

/// 홈에서 위로 올릴 섹션 키. 앞에 있을수록 우선.
List<String> boostedHomeSectionKeys(OnboardingProfile profile) {
  final keys = <String>[];
  void addAll(Iterable<String> next) {
    for (final key in next) {
      if (!keys.contains(key)) keys.add(key);
    }
  }

  if (profile.cooksForChild == true) {
    addAll(const ['baby_food']);
  }
  for (final cuisine in profile.favoriteCuisines) {
    final countryKey = onboardingCountrySectionKey(cuisine);
    if (countryKey != null) addAll([countryKey]);
    addAll(kCuisineHomeSectionBoosts[cuisine] ?? const <String>[]);
  }
  return keys;
}

bool wantsExtraLateNightSection(OnboardingProfile profile) {
  return profile.favoriteCuisines.contains('late_night');
}

/// 부스트 키는 리스트 맨 앞. 나머지(소스·디저트·실시간 포함)는 원래 상대 순서.
List<T> applyHomeSectionBoosts<T>({
  required List<T> sections,
  required OnboardingProfile? profile,
  required String? Function(T section) keyOf,
  T? extraLateNight,
}) {
  if (sections.isEmpty) return sections;
  final list = List<T>.from(sections);
  if (profile == null) return list;

  if (extraLateNight != null && wantsExtraLateNightSection(profile)) {
    final extraKey = keyOf(extraLateNight);
    final exists = extraKey != null &&
        list.any((section) => keyOf(section) == extraKey);
    if (!exists) {
      final momentIndex = list.indexWhere((section) {
        final key = keyOf(section) ?? '';
        return key.startsWith('moment_');
      });
      if (momentIndex >= 0) {
        list.insert(momentIndex + 1, extraLateNight);
      } else {
        list.add(extraLateNight);
      }
    }
  }

  final boosts = boostedHomeSectionKeys(profile);
  if (boosts.isEmpty) return list;

  final used = <int>{};
  final boosted = <T>[];
  for (final boost in boosts) {
    for (var i = 0; i < list.length; i++) {
      if (used.contains(i)) continue;
      if (keyOf(list[i]) == boost) {
        boosted.add(list[i]);
        used.add(i);
        break;
      }
    }
  }
  if (boosted.isEmpty) return list;

  final rest = <T>[];
  for (var i = 0; i < list.length; i++) {
    if (!used.contains(i)) rest.add(list[i]);
  }
  return [...boosted, ...rest];
}

List<Map<String, dynamic>> reorderCountryFilters(
  List<Map<String, dynamic>> filters,
  OnboardingProfile? profile,
) {
  if (profile == null || filters.isEmpty) return filters;
  final preferred = <String>[];
  for (final cuisine in profile.favoriteCuisines) {
    final label = kOnboardingCuisineToCountryLabel[cuisine];
    if (label != null && !preferred.contains(label)) preferred.add(label);
  }
  if (preferred.isEmpty) return filters;

  final byLabel = <String, Map<String, dynamic>>{
    for (final item in filters)
      if ((item['label'] as String?) != null) item['label'] as String: item,
  };
  final out = <Map<String, dynamic>>[];
  final used = <String>{};
  for (final label in preferred) {
    final item = byLabel[label];
    if (item == null) continue;
    out.add(item);
    used.add(label);
  }
  for (final item in filters) {
    final label = item['label'] as String? ?? '';
    if (used.contains(label)) continue;
    out.add(item);
  }
  return out;
}

bool affectsHomeRails(OnboardingProfile? profile) {
  if (profile == null) return false;
  return boostedHomeSectionKeys(profile).isNotEmpty ||
      wantsExtraLateNightSection(profile) ||
      hasHomeHideRules(profile);
}

String _hideFingerprint(OnboardingProfile profile) {
  final diets = [...profile.dietRestrictions]..sort();
  final avoided = [...profile.avoidedIngredients]..sort();
  return '${diets.join(',')}|${avoided.join(',')}';
}

String? _hideMemoFingerprint;
final Map<String, bool> _hideMemo = <String, bool>{};

bool recipeHiddenOnHome(
  Map<String, dynamic> recipe,
  OnboardingProfile? profile,
) {
  if (profile == null || !hasHomeHideRules(profile)) return false;

  final recipeId = recipe['id']?.toString() ?? '';
  final fingerprint = _hideFingerprint(profile);
  if (_hideMemoFingerprint != fingerprint) {
    _hideMemo.clear();
    _hideMemoFingerprint = fingerprint;
  }
  if (recipeId.isNotEmpty) {
    final cached = _hideMemo[recipeId];
    if (cached != null) return cached;
  }

  final hidden = _computeRecipeHiddenOnHome(recipe, profile);
  if (recipeId.isNotEmpty) {
    if (_hideMemo.length >= 800) {
      _hideMemo.remove(_hideMemo.keys.first);
    }
    _hideMemo[recipeId] = hidden;
  }
  return hidden;
}

bool _computeRecipeHiddenOnHome(
  Map<String, dynamic> recipe,
  OnboardingProfile profile,
) {
  final blob = _recipeHideBlob(recipe);
  final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
  final mains = <String>[
    ...?snapshot.mainIngredient,
    ...?snapshot.mainIngredientSub,
    ...?snapshot.ingredientCategories,
  ].join(' ');
  final haystack = '$blob $mains';

  final diets = profile.dietRestrictions;
  if (diets.contains('pork') && _containsNeedle(haystack, _porkNeedles)) {
    return true;
  }
  if (diets.contains('beef') && _containsNeedle(haystack, _beefNeedles)) {
    return true;
  }
  if (diets.contains('vegetarian') && _isMeatRecipe(haystack, mains)) {
    return true;
  }
  if (diets.contains('vegan') && _isAnimalRecipe(haystack, mains)) {
    return true;
  }
  if (diets.contains('mild_spice') && recipeFailsSpiceLow(recipe)) {
    return true;
  }

  for (final id in profile.avoidedIngredients) {
    if (id == 'none' || id == 'other') continue;
    final needles = _allergenNeedles[id];
    if (needles == null) continue;
    if (_containsNeedle(haystack, needles)) return true;
  }
  return false;
}

List<Map<String, dynamic>> hideRecipesOnHome(
  Iterable<Map<String, dynamic>> recipes,
  OnboardingProfile? profile,
) {
  if (profile == null || !hasHomeHideRules(profile)) {
    return List<Map<String, dynamic>>.from(recipes);
  }
  return recipes
      .where((recipe) => !recipeHiddenOnHome(recipe, profile))
      .toList(growable: false);
}

bool hasHomeHideRules(OnboardingProfile profile) {
  return profile.dietRestrictions.any((id) => id != 'none' && id != 'other') ||
      profile.avoidedIngredients.any((id) => id != 'none' && id != 'other');
}

bool _isMeatRecipe(String haystack, String mains) {
  if (_containsNeedle(haystack, _porkNeedles) ||
      _containsNeedle(haystack, _beefNeedles) ||
      _containsNeedle(haystack, _poultryNeedles)) {
    return true;
  }
  return mains.contains('육류') || mains.contains('가금');
}

bool _isAnimalRecipe(String haystack, String mains) {
  if (_isMeatRecipe(haystack, mains)) return true;
  if (_containsNeedle(haystack, _eggNeedles) ||
      _containsNeedle(haystack, _dairyNeedles) ||
      _containsNeedle(haystack, _seafoodNeedles)) {
    return true;
  }
  return mains.contains('해산물') ||
      mains.contains('난류') ||
      mains.contains('유제품');
}

bool _containsNeedle(String haystack, List<String> needles) {
  for (final needle in needles) {
    var from = 0;
    while (true) {
      final index = haystack.indexOf(needle, from);
      if (index < 0) break;
      if (_isFalsePositiveHit(haystack, needle, index)) {
        from = index + needle.length;
        continue;
      }
      return true;
    }
  }
  return false;
}

bool _isFalsePositiveHit(String haystack, String needle, int index) {
  if (needle == '우유' &&
      index > 0 &&
      haystack.substring(index - 1, index + needle.length) == '두유') {
    return true;
  }
  if (needle == '버터' &&
      index >= 2 &&
      haystack.substring(index - 2, index + needle.length) == '땅콩버터') {
    return true;
  }
  if (needle == '햄' && haystack.startsWith('햄버거', index)) {
    return true;
  }
  if (needle == '돼지' && haystack.startsWith('돼지감자', index)) {
    return true;
  }
  if (needle == '밀크') {
    const plantPrefixes = ['코코넛', '아몬드', '오트', '라이스', '소이', '쌀'];
    for (final prefix in plantPrefixes) {
      if (index >= prefix.length &&
          haystack.startsWith('$prefix$needle', index - prefix.length)) {
        return true;
      }
    }
  }
  return false;
}

String _recipeHideBlob(Map<String, dynamic> recipe) {
  final parts = <String>[];
  void add(dynamic raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isNotEmpty) parts.add(value);
  }

  add(recipe['title']);
  add(recipe['name']);
  final recipeData = recipe['recipe'];
  if (recipeData is Map) {
    add(recipeData['title']);
    add(recipeData['name']);
    _addIngredientParts(parts, recipeData['ingredients']);
  }
  _addIngredientParts(parts, recipe['ingredients']);
  void addTags(dynamic raw) {
    if (raw is! List) return;
    for (final tag in raw) {
      add(tag);
    }
  }

  addTags(recipe['tags']);
  final source = recipe['source'];
  if (source is Map) {
    addTags(source['tags']);
  }
  void addCategoryValues(dynamic raw) {
    if (raw is! Map) return;
    for (final value in raw.values) {
      if (value is List) {
        addTags(value);
      } else {
        add(value);
      }
    }
  }

  addCategoryValues(recipe['categories']);
  if (source is Map) {
    addCategoryValues(source['categories']);
  }
  return parts.join(' ');
}

void _addIngredientParts(List<String> parts, dynamic raw) {
  if (raw is! List) return;
  for (final ing in raw) {
    if (ing is Map) {
      final item = ing['item']?.toString().trim() ?? '';
      final name = ing['name']?.toString().trim() ?? '';
      if (item.isNotEmpty) parts.add(item);
      if (name.isNotEmpty) parts.add(name);
    } else {
      final value = ing?.toString().trim() ?? '';
      if (value.isNotEmpty) parts.add(value);
    }
  }
}

bool hasProductPersonalization(OnboardingProfile? profile) {
  if (profile == null) return false;
  if (profile.householdSize == '1') return true;
  if (profile.shoppingStyle == 'as_needed') return true;
  if (profile.shoppingStyle == 'bulk' && profile.householdSize != '1') {
    return true;
  }
  const relevant = {
    'small_qty',
    'fast_delivery',
    'freshness',
    'reviews',
    'price',
  };
  return profile.shoppingPriorities.any(relevant.contains);
}

/// 쿠팡 대표 카드는 원래 절대가 풀. 소량·로켓·후기·신선·대용량일 때만 덮는다.
bool shouldRerankProductBestMatch(OnboardingProfile? profile) {
  if (!hasProductPersonalization(profile)) return false;
  final prefs = profile!.shoppingPriorities.toSet();
  if (profile.householdSize == '1') return true;
  if (profile.shoppingStyle == 'as_needed') return true;
  if (profile.shoppingStyle == 'bulk' && profile.householdSize != '1') {
    return true;
  }
  return prefs.contains('small_qty') ||
      prefs.contains('fast_delivery') ||
      prefs.contains('freshness') ||
      prefs.contains('reviews');
}

Set<String> parseProductTags(CoupangProduct product) {
  final raw = product.tag?.trim() ?? '';
  if (raw.isEmpty) return <String>{};
  return raw
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet();
}

List<num> productOnboardingSortKey(
  CoupangProduct product,
  OnboardingProfile profile,
) {
  final tags = parseProductTags(product);
  final hasClose = tags.contains('딱 필요한 양');
  final hasValue = tags.contains('가성비 최고');
  final hasUnit = tags.contains('단가 낮은');
  final hasPopular = tags.contains('많이 산');
  final hasDomestic = tags.contains('국내산');
  final hasLarge = tags.contains('대용량');
  final rocket = product.isRocket || tags.contains('로켓프레시');
  final volume = product.volumeG ?? product.packageSize ?? 1e12;
  final unitPrice = (product.unitPrice != null && product.unitPrice! > 0)
      ? product.unitPrice!
      : 1e12;
  final sticker = product.productPrice > 0
      ? product.productPrice.toDouble()
      : 1e12;
  final reviews = -(product.reviews ?? 0).toDouble();
  final valueScore = -(product.valueScore ?? 0);

  final prefs = profile.shoppingPriorities.toSet();
  final smallQty = prefs.contains('small_qty') ||
      profile.shoppingStyle == 'as_needed' ||
      profile.householdSize == '1';
  final bulk = profile.shoppingStyle == 'bulk' && !smallQty;
  final fast = prefs.contains('fast_delivery');
  final fresh = prefs.contains('freshness');
  final wantReviews = prefs.contains('reviews');
  final wantPrice = prefs.contains('price');

  final keys = <num>[];
  if (smallQty) {
    keys.add(hasClose ? 0 : 1);
    keys.add(hasLarge ? 1 : 0);
    keys.add(volume);
  } else if (bulk) {
    keys.add(hasLarge ? 0 : 1);
  }
  if (fast) keys.add(rocket ? 0 : 1);
  if (fresh) keys.add((hasDomestic || rocket) ? 0 : 1);
  if (wantReviews) {
    keys.add(hasPopular ? 0 : 1);
    keys.add(reviews);
  }
  if (wantPrice) {
    keys.add(hasUnit ? 0 : 1);
    keys.add(unitPrice);
    keys.add(sticker);
  } else {
    keys.add(hasValue ? 0 : 1);
    keys.add(hasUnit ? 0 : 1);
    keys.add(valueScore);
    keys.add(unitPrice);
  }
  if (!wantReviews) {
    keys.add(hasPopular ? 0 : 1);
    keys.add(reviews);
  }
  if (!fresh) keys.add(hasDomestic ? 0 : 1);
  if (!smallQty && !bulk) keys.add(hasLarge ? 0 : 1);
  return keys;
}

int compareProductOnboardingKeys(List<num> a, List<num> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final cmp = a[i].compareTo(b[i]);
    if (cmp != 0) return cmp;
  }
  return a.length.compareTo(b.length);
}

List<CoupangProduct> sortProductsForOnboarding(
  List<CoupangProduct> products,
  OnboardingProfile profile,
) {
  final ranked = List<CoupangProduct>.from(products);
  ranked.sort((a, b) {
    final cmp = compareProductOnboardingKeys(
      productOnboardingSortKey(a, profile),
      productOnboardingSortKey(b, profile),
    );
    if (cmp != 0) return cmp;
    return a.productId.compareTo(b.productId);
  });
  return ranked;
}

ProductRecommendation applyOnboardingToRecommendation(
  ProductRecommendation recommendation, {
  required OnboardingProfile? profile,
  required bool isCoupang,
}) {
  if (!hasProductPersonalization(profile)) return recommendation;
  final seen = <String>{};
  final candidates = <CoupangProduct>[];
  void add(CoupangProduct? product) {
    if (product == null) return;
    if (product.productId.isEmpty || seen.contains(product.productId)) return;
    seen.add(product.productId);
    candidates.add(product);
  }

  add(recommendation.bestMatch);
  for (final product in recommendation.seeMoreList) {
    add(product);
  }
  for (final product in recommendation.allProducts) {
    add(product);
  }
  if (candidates.isEmpty) return recommendation;

  final sorted = sortProductsForOnboarding(candidates, profile!);
  CoupangProduct? best = recommendation.bestMatch;
  if (!isCoupang || shouldRerankProductBestMatch(profile)) {
    best = sorted.first;
  }
  final seeMore = <CoupangProduct>[];
  for (final product in sorted) {
    if (best != null && product.productId == best.productId) continue;
    seeMore.add(product);
  }
  return ProductRecommendation(
    ingredient: recommendation.ingredient,
    displayName: recommendation.displayName,
    neededQty: recommendation.neededQty,
    neededUnit: recommendation.neededUnit,
    bestMatch: best,
    seeMoreList: seeMore,
    allProducts: recommendation.allProducts.isNotEmpty
        ? recommendation.allProducts
        : seeMore,
  );
}
