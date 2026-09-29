import 'dart:convert';

import 'package:flutter/services.dart';

import 'recipe_tag_filters.dart';

/// 백엔드 `chef_tags_ko.json`과 동기화된 셰프 allowlist.
/// 홈 「셰프별 인기 레시피」 섹션에서 tags[0]/chefTag 판별에 사용.
class ChefTagRegistry {
  ChefTagRegistry._();

  static Set<String>? _allowlist;

  /// assets에서 셰프 목록을 1회 로드한다.
  static Future<void> ensureLoaded() async {
    if (_allowlist != null) return;
    try {
      final raw = await rootBundle.loadString('assets/data/chef_tags_ko.json');
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _allowlist = {};
        return;
      }
      _allowlist = decoded
          .map((e) => normalizeRecipeTagToken(e?.toString() ?? ''))
          .where((e) => e.isNotEmpty)
          .toSet();
    } catch (_) {
      _allowlist = {};
    }
  }

  static bool get isLoaded => _allowlist != null;

  /// allowlist에 있는 셰프 이름이면 true. 로드 전이면 false.
  static bool contains(String tag) {
    final key = normalizeRecipeTagToken(tag);
    if (key.isEmpty) return false;
    return _allowlist?.contains(key) ?? false;
  }

  /// 테스트에서 에셋 로드 없이 allowlist를 심는다.
  static void debugSetAllowlist(Set<String> names) {
    _allowlist = names
        .map(normalizeRecipeTagToken)
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  static void debugReset() {
    _allowlist = null;
  }

  /// 레시피 문서에서 known chef 태그 1개 추출. 없으면 null.
  static String? extractFromRecipe(Map<String, dynamic> recipe) {
    final allowlist = _allowlist;
    if (allowlist == null || allowlist.isEmpty) return null;

    final direct = normalizeRecipeTagToken(recipe['chefTag']?.toString() ?? '');
    if (direct.isNotEmpty && allowlist.contains(direct)) return direct;

    final tags = recipe['tags'];
    if (tags is! List || tags.isEmpty) return null;
    final first = normalizeRecipeTagToken(tags.first?.toString() ?? '');
    if (first.isNotEmpty && allowlist.contains(first)) return first;
    return null;
  }
}

/// 무지개 칩은 셰프 allowlist 이름에만 쓴다. 한식/저녁 같은 일반 태그는 해당 없음.
bool isChefDisplayTag(String tag) {
  if (isBlockedRecipeDisplayTag(tag)) return false;
  return ChefTagRegistry.contains(tag);
}
