/// 레시피 상세 하단 연관 레일: 주재료/계열 라벨 고르기와 레일 간 중복 제거.

class RelatedRecipeRail {
  const RelatedRecipeRail({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.recipes,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<Map<String, dynamic>> recipes;

  bool get isVisible => recipes.isNotEmpty;
}

const Set<String> kRelatedBroadIngredientCategories = {
  '육류',
  '해산물',
  '채소',
  '과일',
  '유제품',
  '곡물',
  '기타',
  '조미료',
  '가공식품',
  '견과',
  '난류',
  '콩/두부',
};

const Set<String> kRelatedSeasoningIngredients = {
  '소금',
  '설탕',
  '간장',
  '물',
  '식용유',
  '올리브유',
  '참기름',
  '후추',
  '후춧가루',
  '맛소금',
  '올리고당',
  '물엿',
  '식초',
  '미림',
  '청주',
  '맛술',
  '고춧가루',
  '고추장',
  '된장',
  '쌈장',
  '케첩',
  '마요네즈',
  '다진마늘',
};

const Set<String> kRelatedCookingStyleTypes = {
  '볶음',
  '찜',
  '조림',
  '구이',
  '튀김',
  '무침',
  '면',
  '국',
  '탕',
  '찌개',
  '밥',
  '샐러드',
  '디저트',
  '빵',
  '전',
  '볶음밥',
  '국수',
  '파스타',
  '찌개/전골',
  '전골',
  '비빔',
  '샐러드/샐러드',
};

String? pickRelatedMainIngredient({
  List<String> mainIngredientSub = const [],
  List<String> mainIngredient = const [],
  List<String> ingredientItems = const [],
}) {
  for (final raw in [...mainIngredientSub, ...mainIngredient]) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (kRelatedBroadIngredientCategories.contains(name)) continue;
    return name;
  }
  for (final raw in ingredientItems) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (kRelatedSeasoningIngredients.contains(name)) continue;
    if (kRelatedBroadIngredientCategories.contains(name)) continue;
    return name;
  }
  return null;
}

String? pickRelatedMenuType({
  List<String> menuTypes = const [],
  String dishName = '',
}) {
  final dish = dishName.replaceAll(RegExp(r'\s+'), '');
  for (final raw in menuTypes) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (_labelOverlapsDish(name, dish)) continue;
    return name;
  }
  return null;
}

bool _labelOverlapsDish(String label, String dishCompact) {
  if (dishCompact.isEmpty) return false;
  final compact = label.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return false;
  if (compact == dishCompact) return true;
  final shorter = compact.length <= dishCompact.length ? compact : dishCompact;
  final longer = compact.length <= dishCompact.length ? dishCompact : compact;
  // '찜'처럼 짧은 계열명은 요리명에 포함돼도 계열 레일로 쓴다.
  if (shorter.length < 3) return false;
  return longer.contains(shorter);
}

String relatedSimilarRailTitle(String dishName) {
  final name = _shortDishLabel(dishName);
  if (name.isEmpty) return '비슷한 레시피 찾고 계신가요?';
  return '$name${_andParticleWaGwa(name)} 비슷한 레시피 찾고 계신가요?';
}

String relatedIngredientRailTitle(String ingredient) {
  final name = ingredient.trim();
  if (name.isEmpty) return '이 주재료로 만든 다른 레시피 찾고 계신가요?';
  return '$name${_objectParticleRo(name)} 만든 다른 레시피 찾고 계신가요?';
}

/// 받침 없음 → 와, 받침 있음 → 과.
String _andParticleWaGwa(String word) {
  if (word.isEmpty) return '와';
  final last = word.runes.last;
  if (last >= 0xAC00 && last <= 0xD7A3) {
    final jong = (last - 0xAC00) % 28;
    return jong == 0 ? '와' : '과';
  }
  return '와';
}

/// 받침 없음·ㄹ → 로, 그 외 받침 → 으로.
String _objectParticleRo(String word) {
  if (word.isEmpty) return '로';
  final last = word.runes.last;
  if (last >= 0xAC00 && last <= 0xD7A3) {
    final jong = (last - 0xAC00) % 28;
    if (jong == 0 || jong == 8) return '로';
    return '으로';
  }
  return '로';
}

String relatedMenuRailTitle(String menuType) {
  final name = menuType.trim();
  if (name.isEmpty) return '비슷한 요리 계열 찾고 계신가요?';
  if (kRelatedCookingStyleTypes.contains(name) ||
      (name.length <= 6 &&
          kRelatedCookingStyleTypes.any((style) => name.contains(style)))) {
    return '$name 계열 레시피 찾고 계신가요?';
  }
  return '$name 레시피 찾고 계신가요?';
}

const String relatedPopularRailTitle = '요즘 많이 요리한 레시피 찾고 계신가요?';

String _shortDishLabel(String raw) {
  var name = raw.trim().replaceAll('_', ' ');
  name = name.replaceAll(RegExp(r'\s+'), ' ');
  if (name.isEmpty || name.length > 14) return '';
  return name;
}

String recipeIdOf(Map<String, dynamic> recipe) {
  return (recipe['id'] ?? recipe['recipeId'] ?? '').toString().trim();
}

List<Map<String, dynamic>> excludeRecipeIds(
  List<Map<String, dynamic>> recipes,
  Set<String> excludeIds,
) {
  if (excludeIds.isEmpty) return List<Map<String, dynamic>>.from(recipes);
  return [
    for (final recipe in recipes)
      if (!excludeIds.contains(recipeIdOf(recipe))) recipe,
  ];
}

/// 앞 레일이 가져간 레시피는 뒤 레일에서 빼서, 같은 카드가 반복되지 않게 한다.
List<RelatedRecipeRail> dedupRelatedRecipeRails(List<RelatedRecipeRail> rails) {
  final used = <String>{};
  final out = <RelatedRecipeRail>[];
  for (final rail in rails) {
    final unique = <Map<String, dynamic>>[];
    for (final recipe in rail.recipes) {
      final id = recipeIdOf(recipe);
      if (id.isEmpty || used.contains(id)) continue;
      used.add(id);
      unique.add(recipe);
    }
    if (unique.isEmpty) continue;
    out.add(
      RelatedRecipeRail(
        id: rail.id,
        title: rail.title,
        subtitle: rail.subtitle,
        recipes: unique,
      ),
    );
  }
  return out;
}
