/// 홈 검색 도우미 의도 판별·맵기 로컬 필터.
/// 서버가 레시피를 고르지 않을 때 클라가 쓰는 닫힌 규칙.
library;

const List<String> kHomeAgentIntentMarkers = <String>[
  '추천',
  '뭐 먹',
  '뭐먹',
  '해먹',
  '단백질',
  '고단백',
  '덜 맵',
  '안 맵',
  '매운',
  '해장',
  '빨리',
  '분 안',
  '남은',
  '없이',
  '저염',
  '칼로리',
  '야식',
  '이유식',
  '달달',
  '디저트',
  '손님',
  '혼자',
  '혼밥',
  '아침',
  '간식',
  '국물',
  '채식',
  '비건',
  '캠핑',
  '건강',
  '술안주',
  '안주',
  '데이트',
  '에어프라이',
  '전자레인지',
  '냄비',
];

const List<String> kHomeAgentSpiceTagBlock = <String>[
  '매운맛',
  '매콤',
  '불닭',
  '매운',
];

bool looksLikeHomeAgentIntent(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  for (final marker in kHomeAgentIntentMarkers) {
    if (text.contains(marker)) return true;
  }
  return false;
}

bool recipeFailsSpiceLow(Map<String, dynamic> recipe) {
  final recipeData = recipe['recipe'];
  final ingredients = recipeData is Map ? recipeData['ingredients'] : null;
  for (final ing in (ingredients is List ? ingredients : const [])) {
    final item = ing is Map
        ? (ing['item']?.toString() ?? '').trim()
        : ing.toString().trim();
    if (item.contains('청양')) return true;
  }
  for (final t in (recipe['tags'] as List? ?? const [])) {
    final tag = t.toString();
    for (final blocked in kHomeAgentSpiceTagBlock) {
      if (tag.contains(blocked)) return true;
    }
  }
  return false;
}

List<Map<String, dynamic>> applySpiceLowFilter(
  List<Map<String, dynamic>> recipes,
) {
  return recipes.where((r) => !recipeFailsSpiceLow(r)).toList(growable: false);
}
