/// 방송 프로그램 섹션 키 ↔ 소스 매칭 키워드.
///
/// Cloud Functions `home_section_rules.json` 의 `sourceKeywords` 와 동기화한다.
/// CF 인덱스 매칭과 동일한 기준으로 판정한다(클라 explore 폴백 스캔은 사용하지 않음).
class ProgramSectionKeywords {
  ProgramSectionKeywords._();

  static const Map<String, List<String>> keywordsByKey = {
    'program_pyeonstorang': [
      '신상출시 편스토랑',
      '편스토랑',
      'fun-staurant',
      'fun staurant',
    ],
    'program_fridge': ['냉장고를 부탁해', '냉부해', '냉부'],
    'program_best_cooking': ['최고의 요리비결', '최요비', 'best cooking secrets'],
    'program_culinary_class_wars': ['흑백요리사', '요리 계급 전쟁', 'culinary class wars'],
    'program_street_restaurant_fighter': [
      '스트릿 레스토랑 파이터',
      'street restaurant fighter',
    ],
    'program_bake_your_dream': ['천하제빵', '베이크 유어 드림', 'bake your dream'],
    'program_altoran': ['알토란'],
    'program_sumi_side_dishes': ['수미네 반찬'],
    'program_home_food_baek': ['집밥 백선생', '집밥백선생'],
    'program_korean_food_battle': ['한식대첩'],
  };

  static List<String> forKey(String sectionKey) =>
      keywordsByKey[sectionKey] ?? const <String>[];

  /// Cloud Functions `homeSectionRules._sourceText` 와 동일하게 넉넉히 본다.
  /// source.title/uploader/channel + recipe.title + sourceUrl
  static bool matchesRecipe(
    Map<String, dynamic> recipe,
    List<String> keywords,
  ) {
    if (keywords.isEmpty) return false;
    final source = recipe['source'];
    final sourceMap = source is Map
        ? Map<String, dynamic>.from(source)
        : const <String, dynamic>{};
    final nested = recipe['recipe'];
    final nestedMap = nested is Map
        ? Map<String, dynamic>.from(nested)
        : const <String, dynamic>{};
    final haystack = [
      sourceMap['title'],
      sourceMap['uploader'],
      sourceMap['channel'],
      recipe['uploader'],
      recipe['channel'],
      nestedMap['title'] ?? recipe['title'] ?? nestedMap['name'] ?? recipe['name'],
      recipe['sourceUrl'] ?? sourceMap['url'] ?? sourceMap['sourceUrl'],
    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
    if (haystack.trim().isEmpty) return false;
    for (final keyword in keywords) {
      final k = keyword.toLowerCase().trim();
      if (k.isNotEmpty && haystack.contains(k)) return true;
    }
    return false;
  }
}
