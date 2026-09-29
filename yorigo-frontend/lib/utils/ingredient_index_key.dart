import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Firestore `ingredient_recipe_index` doc id 생성용 재료명 정규화.
class IngredientIndexKey {
  IngredientIndexKey._();

  /// 재료명 비교·인덱스 키용 정규화 (백엔드 `_normalize_ingredient_text`와 동일).
  static String normalize(String name) {
    final trimmed = name.trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// 정규화된 재료명 → Firestore document id.
  static String docId(String normalizedKey) {
    if (normalizedKey.isEmpty) return '';
    var id = normalizedKey.replaceAll('/', '__').replaceAll('..', '_');
    if (id.length > 500) {
      final digest = sha256.convert(utf8.encode(normalizedKey));
      return 'h_${digest.toString().substring(0, 40)}';
    }
    return id;
  }

  static String docIdFromName(String ingredientName) {
    return docId(normalize(ingredientName));
  }
}
