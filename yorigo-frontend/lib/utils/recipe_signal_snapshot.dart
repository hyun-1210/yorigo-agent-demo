/// 레시피 raw map(recipe list item 또는 상세 parseResponse)에서 행동 시그널
/// 이벤트(impression/click 등)에 실어 보낼 "그 순간의" 속성 스냅샷을 추출한다.
///
/// 화면마다 recipe map의 중첩 구조가 조금씩 다르다(목록 화면은 `categories`/`tags`가
/// 최상위로 평탄화돼 있고, 상세 화면은 `source.categories`처럼 중첩돼 있음) — 그래서
/// 양쪽 경로를 모두 확인해서 값이 있는 쪽을 사용한다. 홈/검색/레시피상세 3개 화면에서
/// 공통으로 재사용해 필드 추출 로직이 화면마다 어긋나지 않도록 한다.
class RecipeSignalSnapshot {
  const RecipeSignalSnapshot({
    this.cuisineType,
    this.timeCategory,
    this.menuType,
    this.mainIngredient,
    this.mainIngredientSub,
    this.tags,
    this.nutritionRating,
    this.ingredientCategories,
    this.sourcePlatform,
    this.servings,
  });

  final List<String>? cuisineType;
  final List<String>? timeCategory;
  final List<String>? menuType;
  final List<String>? mainIngredient;
  final List<String>? mainIngredientSub;
  final List<String>? tags;
  final String? nutritionRating;
  final List<String>? ingredientCategories;
  final String? sourcePlatform;
  final int? servings;

  static List<String>? _asStrList(dynamic v) {
    if (v is List) {
      final list = v
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      return list.isEmpty ? null : list;
    }
    if (v is String && v.trim().isNotEmpty) return <String>[v.trim()];
    return null;
  }

  static String? _asStr(dynamic v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  factory RecipeSignalSnapshot.fromRecipeMap(Map<String, dynamic> recipe) {
    final Map source = (recipe['source'] as Map?) ?? const {};
    final Map recipeData = (recipe['recipe'] as Map?) ?? const {};
    // 목록 화면(홈/검색)은 categories/tags가 최상위로 평탄화돼 있고,
    // 상세 화면은 source 아래 중첩돼 있음 — 둘 다 확인.
    final Map categories = (recipe['categories'] as Map?) ??
        (source['categories'] as Map?) ??
        const {};
    final dynamic tagsRaw = recipe['tags'] ?? source['tags'];

    final Set<String> ingredientCategories = <String>{};
    final List ingredients = (recipeData['ingredients'] as List?) ?? const [];
    for (final ing in ingredients) {
      if (ing is Map) {
        final String? cat = _asStr(ing['category']);
        if (cat != null) ingredientCategories.add(cat);
      }
    }

    return RecipeSignalSnapshot(
      cuisineType: _asStrList(categories['cuisine_type']),
      timeCategory: _asStrList(categories['time_category']),
      menuType: _asStrList(categories['menu_type']),
      mainIngredient: _asStrList(categories['main_ingredient']),
      mainIngredientSub: _asStrList(categories['main_ingredient_sub']),
      tags: _asStrList(tagsRaw),
      nutritionRating: _asStr(recipe['nutrition_rating'] ?? source['nutrition_rating']),
      ingredientCategories:
          ingredientCategories.isEmpty ? null : ingredientCategories.toList(),
      sourcePlatform: _asStr(source['platform']),
      servings: _asInt(recipe['servings'] ?? recipeData['servings']),
    );
  }
}
