/// Tags that must never be shown on recipe cards or detail UI (LLM / parse noise).
/// Add entries here when the backend or model emits a token that is not a valid tag.
const Set<String> kBlockedRecipeDisplayTags = {
  '회사',
  '직장',
  '오늘',
  '우리',
};

/// Firestore chips_v2 원라이너 키. notes/description 폴백은 쓰지 않는다.
const List<String> kRecipeTaglineKeys = [
  'tagline',
  'hook',
  'aura',
  'one_liner',
  'oneLiner',
];

final _whitespaceRuns = RegExp(r'[\r\n]+');
final _visibleChar = RegExp(r'[가-힣a-zA-Z0-9]');
final _invisibleChars = RegExp(r'[\s\u200B-\u200D\uFEFF]');

/// Strips zero-width / BOM so blocklist matches Firestore strings like "회사\u200b".
String normalizeRecipeTagToken(String raw) {
  return raw
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .trim();
}

bool isBlockedRecipeDisplayTag(String tag) {
  final n = normalizeRecipeTagToken(tag);
  if (n.isEmpty) return false;
  return kBlockedRecipeDisplayTags.contains(n);
}

/// Normalizes and drops blocked tags. Preserves order.
List<String> filterRecipeTagsForDisplay(Iterable<dynamic>? raw) {
  if (raw == null) return [];
  final out = <String>[];
  for (final e in raw) {
    final s = normalizeRecipeTagToken(e?.toString() ?? '');
    if (s.isEmpty) continue;
    if (kBlockedRecipeDisplayTags.contains(s)) continue;
    out.add(s);
  }
  return out;
}

String? _firstNonEmptyKeyedString(
  Map<dynamic, dynamic>? map,
  List<String> keys,
) {
  if (map == null) return null;
  for (final key in keys) {
    final raw = map[key];
    if (raw is! String) continue;
    final text = raw.replaceAll(_whitespaceRuns, ' ').trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// 상세 제목 아래 한 줄. 필드가 없거나 너무 짧으면 빈 문자열.
String recipeTaglineForDisplay({
  Map<String, dynamic>? source,
  Map<String, dynamic>? recipeDoc,
  int minLength = 6,
  int maxLength = 72,
}) {
  final raw = _firstNonEmptyKeyedString(recipeDoc, kRecipeTaglineKeys) ??
      _firstNonEmptyKeyedString(source, kRecipeTaglineKeys);
  if (raw == null || raw.length < minLength) return '';
  if (raw.length > maxLength) {
    return '${raw.substring(0, maxLength).trimRight()}…';
  }
  return raw;
}

/// 이미 읽은 레시피 문서의 tagline/occasionTags를 source에 복사. 추가 읽기 없음.
void hydrateRecipeDisplayMeta(
  Map<String, dynamic> source,
  Map<String, dynamic> recipeDoc,
) {
  final tagline = _firstNonEmptyKeyedString(recipeDoc, kRecipeTaglineKeys) ??
      _firstNonEmptyKeyedString(source, kRecipeTaglineKeys);
  if (tagline != null) {
    source['tagline'] = tagline;
  }
  final occasion = recipeDoc['occasionTags'];
  if (occasion is List && occasion.isNotEmpty) {
    source['occasionTags'] = List<dynamic>.from(occasion);
  }
}

/// 파서가 값을 줄 때만 저장. 빈 값으로 기존 백필을 덮어쓰지 않는다.
Map<String, dynamic> recipeDisplayMetaWriteFields(Map<String, dynamic> source) {
  final out = <String, dynamic>{};
  final tagline = _firstNonEmptyKeyedString(source, kRecipeTaglineKeys);
  if (tagline != null) {
    out['tagline'] = tagline;
  }
  final occasion = source['occasionTags'];
  if (occasion is List && occasion.isNotEmpty) {
    out['occasionTags'] = List<dynamic>.from(occasion);
  }
  return out;
}

/// 카드/상세에 쓸 태그. 빈 값·비가시 문자·차단 토큰 제거.
List<String> sanitizeRecipeTagList(Iterable<dynamic>? raw) {
  if (raw == null) return [];
  final tags = <String>[];
  for (final tag in raw) {
    if (tag == null) continue;
    final tagStr = tag.toString().trim();
    if (tagStr.isEmpty) continue;
    if (!_visibleChar.hasMatch(tagStr)) continue;
    final withoutInvisible = tagStr.replaceAll(_invisibleChars, '');
    if (withoutInvisible.isEmpty || !_visibleChar.hasMatch(withoutInvisible)) {
      continue;
    }
    tags.add(tagStr);
  }
  return filterRecipeTagsForDisplay(tags);
}

/// 맛/텍스처 태그 뒤에 상황 태그를 붙여 상세 필에 보여 준다.
List<String> recipeIdentityDisplayTags({
  Iterable<dynamic>? tags,
  Iterable<dynamic>? occasionTags,
}) {
  final out = sanitizeRecipeTagList(tags);
  final seen = out.map(normalizeRecipeTagToken).toSet();
  for (final tag in sanitizeRecipeTagList(occasionTags)) {
    final n = normalizeRecipeTagToken(tag);
    if (n.isEmpty || !seen.add(n)) continue;
    out.add(tag);
  }
  return out;
}

Map<String, dynamic> _asStringKeyedMap(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, dynamic>{};
}

/// 섹션 매칭·검색용 토큰. top-level + source, tags + occasionTags.
List<String> recipeMatchTagTokens(Map<String, dynamic> recipe) {
  final source = _asStringKeyedMap(recipe['source']);
  final chunks = <dynamic>[
    recipe['tags'],
    recipe['occasionTags'],
    source['tags'],
    source['occasionTags'],
  ];
  final seen = <String>{};
  final out = <String>[];
  for (final raw in chunks) {
    if (raw is! List) continue;
    for (final t in raw) {
      final token = normalizeRecipeTagToken(t?.toString() ?? '').toLowerCase();
      if (token.isEmpty || !seen.add(token)) continue;
      out.add(token);
    }
  }
  return out;
}

bool recipeMatchesAnyTag(Map<String, dynamic> recipe, List<String> allowed) {
  if (allowed.isEmpty) return false;
  final allowedSet = allowed
      .map((s) => normalizeRecipeTagToken(s).toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (allowedSet.isEmpty) return false;
  for (final token in recipeMatchTagTokens(recipe)) {
    if (allowedSet.contains(token)) return true;
  }
  return false;
}

/// 검색어가 태그·상황태그·원라이너에 포함되면 true.
bool recipeTagOrTaglineContains(Map<String, dynamic> recipe, String queryLower) {
  if (queryLower.isEmpty) return false;
  for (final token in recipeMatchTagTokens(recipe)) {
    if (token.contains(queryLower)) return true;
  }
  final source = _asStringKeyedMap(recipe['source']);
  final tagline = (_firstNonEmptyKeyedString(recipe, kRecipeTaglineKeys) ??
          _firstNonEmptyKeyedString(source, kRecipeTaglineKeys) ??
          '')
      .toLowerCase();
  return tagline.contains(queryLower);
}
