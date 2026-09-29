import 'recipe_tag_filters.dart';

/// 검색어/제목 비교용으로 공백을 없앤다. "두부 부침" == "두부부침".
String compactSearchText(String raw) {
  return raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

/// 쿼리에 대응하는 groupKey 후보 (원문, 공백→_, compact).
List<String> dishGroupKeysForQuery(String query) {
  final compact = compactSearchText(query);
  if (compact.length < 2) return const <String>[];
  final keys = <String>[];
  final seen = <String>{};

  void addKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    for (final key in <String>[
      trimmed,
      trimmed.replaceAll(RegExp(r'\s+'), '_'),
      compactSearchText(trimmed),
    ]) {
      if (key.length < 2 || !seen.add(key)) continue;
      keys.add(key);
    }
  }

  addKey(query);
  addKey(compact);
  return keys;
}

Set<String> searchNeedlesForQuery(String query) {
  final compact = compactSearchText(query);
  if (compact.isEmpty) return const <String>{};
  final needles = <String>{compact};
  final trimmed = query.toLowerCase().trim();
  if (trimmed.length >= 2) needles.add(trimmed);
  return needles.where((n) => n.length >= 2).toSet();
}

bool _compactContainsAny(String haystack, Set<String> needles) {
  final compact = compactSearchText(haystack);
  if (compact.isEmpty) return false;
  for (final needle in needles) {
    if (compact.contains(needle)) return true;
  }
  return false;
}

String recipeSearchTitle(Map<String, dynamic> recipe) {
  final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
  return '${recipe['title'] ?? recipeData['title'] ?? recipeData['name'] ?? ''}';
}

String recipeSearchGroupKey(Map<String, dynamic> recipe) {
  final source = recipe['source'] as Map<String, dynamic>? ?? {};
  return '${recipe['groupKey'] ?? recipe['canonicalDish'] ?? source['canonical_dish_seed'] ?? ''}';
}

bool _ingredientsMatchNeedles(
  Map<String, dynamic> recipe,
  String queryLower,
  Set<String> needles,
) {
  final compact = compactSearchText(queryLower);
  // "두부 부침"을 재료 '두부'로 쪼개면 두부 요리 전체가 걸린다.
  final allowSpaceSplit =
      !queryLower.contains(RegExp(r'\s+')) || compact.length < 4;
  final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
  for (final ing in (recipeData['ingredients'] as List? ?? [])) {
    final item = ing is Map
        ? (ing['item']?.toString() ?? '').trim()
        : ing.toString().trim();
    if (item.isEmpty) continue;
    if (_compactContainsAny(item, needles)) return true;
    final lower = item.toLowerCase();
    if (lower.contains(queryLower)) return true;
    if (!allowSpaceSplit) continue;
    for (final part in queryLower.split(RegExp(r'\s+'))) {
      if (part.length >= 2 && lower.contains(part)) return true;
    }
  }
  return false;
}

bool _categoriesMatchNeedles(
  Map<String, dynamic> recipe,
  Set<String> needles,
) {
  final categories = recipe['categories'] as Map<String, dynamic>? ?? {};
  for (final v in categories.values) {
    if (v is! List) continue;
    for (final c in v) {
      if (_compactContainsAny(c.toString(), needles)) return true;
    }
  }
  return false;
}

/// 검색 우선순위: -1 없음, 1 재료/카테고리, 2 태그, 3 제목/groupKey.
int recipeSearchMatchPriority(Map<String, dynamic> recipe, String query) {
  if (query.trim().isEmpty) return 0;
  final queryLower = query.toLowerCase().trim();
  final needles = searchNeedlesForQuery(query);
  if (needles.isEmpty) return -1;

  final title = recipeSearchTitle(recipe);
  if (_compactContainsAny(title, needles)) return 3;
  if (_compactContainsAny(recipeSearchGroupKey(recipe), needles)) return 3;
  if (recipeTagOrTaglineContains(recipe, queryLower)) return 2;
  for (final needle in needles) {
    if (recipeTagOrTaglineContains(recipe, needle)) return 2;
  }
  if (_categoriesMatchNeedles(recipe, needles)) return 1;
  if (_ingredientsMatchNeedles(recipe, queryLower, needles)) return 1;
  return -1;
}

bool recipeMatchesSearchQuery(Map<String, dynamic> recipe, String query) {
  if (query.trim().isEmpty) return true;
  return recipeSearchMatchPriority(recipe, query) != -1;
}
