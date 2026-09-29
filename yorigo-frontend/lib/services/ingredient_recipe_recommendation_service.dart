import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../utils/ingredient_index_key.dart';

/// Firestore 추천 조회 시간 초과.
class IngredientRecipeRecommendationTimeoutException implements Exception {
  const IngredientRecipeRecommendationTimeoutException();

  @override
  String toString() =>
      '추천 조회 시간이 초과됐어요. 네트워크를 확인하고 잠시 후 다시 시도해주세요.';
}

/// 냉장고 남은 재료 기반 레시피 추천 (Firestore `ingredient_recipe_index` 직접 조회).
class IngredientRecipeRecommendationResult {
  const IngredientRecipeRecommendationResult({
    required this.recipeId,
    required this.title,
    required this.thumbnailUrl,
    required this.matchPercent,
    required this.reasonSummary,
    required this.matchedNames,
    required this.matchedCount,
    required this.recipeMap,
  });

  final String recipeId;
  final String title;
  final String thumbnailUrl;
  final double matchPercent;
  final String reasonSummary;
  final List<String> matchedNames;
  final int matchedCount;

  /// [HomeStyleRecipeCard.fromRecipeMap] 렌더링용 원본 레시피 맵.
  final Map<String, dynamic> recipeMap;
}

class IngredientRecipeRecommendationService {
  IngredientRecipeRecommendationService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const int _defaultTopK = 12;
  static const int _maxCandidateIds = 40;

  /// Firestore 직접 조회 전체 타임아웃 (백엔드 API 45초보다 짧게).
  static const Duration recommendTimeout = Duration(seconds: 30);

  /// 선택 재료 목록으로 추천 레시피를 조회한다.
  Future<List<IngredientRecipeRecommendationResult>> recommend({
    required List<String> ingredientNames,
    int topK = _defaultTopK,
  }) {
    return _recommendImpl(
      ingredientNames: ingredientNames,
      topK: topK,
    ).timeout(
      recommendTimeout,
      onTimeout: () {
        throw const IngredientRecipeRecommendationTimeoutException();
      },
    );
  }

  Future<List<IngredientRecipeRecommendationResult>> _recommendImpl({
    required List<String> ingredientNames,
    int topK = _defaultTopK,
  }) async {
    final picked = ingredientNames
        .map(IngredientIndexKey.normalize)
        .where((name) => name.isNotEmpty)
        .toList();
    if (picked.isEmpty) return const [];

    final indexHits = await _loadIndexHits(picked);
    if (indexHits.isEmpty) return const [];

    final rankedIds = _rankCandidateIds(indexHits, picked);
    if (rankedIds.isEmpty) return const [];

    final candidateIds = rankedIds.take(_maxCandidateIds).toList();
    final recipeDocs = await _fetchRecipeDocs(candidateIds);

    final results = <IngredientRecipeRecommendationResult>[];
    for (final recipeId in candidateIds) {
      final data = recipeDocs[recipeId];
      if (data == null) continue;

      final recipeIngredients = _extractRecipeIngredientNames(data);
      final matchedNames = _matchUserIngredients(
        userIngredients: picked,
        recipeIngredients: recipeIngredients,
      );
      if (matchedNames.isEmpty) continue;

      final matchPercent =
          (matchedNames.length / picked.length * 100).clamp(0.0, 100.0);
      results.add(
        IngredientRecipeRecommendationResult(
          recipeId: recipeId,
          title: _pickTitle(data),
          thumbnailUrl: _pickThumbnail(data),
          matchPercent: matchPercent,
          reasonSummary:
              '${matchedNames.length}개 재료가 매칭되었고, '
              '남은 재료 커버리지 ${matchPercent.toStringAsFixed(1)}%',
          matchedNames: matchedNames,
          matchedCount: matchedNames.length,
          recipeMap: {...data, 'id': recipeId, 'recipeId': recipeId},
        ),
      );
    }

    results.sort((a, b) {
      final byMatch = b.matchedCount.compareTo(a.matchedCount);
      if (byMatch != 0) return byMatch;
      return b.matchPercent.compareTo(a.matchPercent);
    });

    return results.take(topK.clamp(1, 20)).toList();
  }

  Future<Map<String, Set<String>>> _loadIndexHits(
    List<String> normalizedIngredients,
  ) async {
    final hits = <String, Set<String>>{};
    final futures = <Future<void>>[];

    for (final ingredient in normalizedIngredients) {
      futures.add(() async {
        final docId = IngredientIndexKey.docId(ingredient);
        if (docId.isEmpty) return;
        try {
          final snap = await _firestore
              .collection('ingredient_recipe_index')
              .doc(docId)
              .get();
          if (!snap.exists) return;
          final data = snap.data() ?? {};
          final rawIds = data['recipeIds'];
          if (rawIds is! List) return;
          hits[ingredient] = rawIds
              .map((id) => id?.toString().trim() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet();
        } catch (e) {
          debugPrint('[IngredientRecipeRecommendation] index read failed: $e');
        }
      }());
    }

    await Future.wait(futures);
    return hits;
  }

  List<String> _rankCandidateIds(
    Map<String, Set<String>> indexHits,
    List<String> picked,
  ) {
    final scoreByRecipe = <String, int>{};
    for (final ingredient in picked) {
      final ids = indexHits[ingredient];
      if (ids == null || ids.isEmpty) continue;
      for (final recipeId in ids) {
        scoreByRecipe[recipeId] = (scoreByRecipe[recipeId] ?? 0) + 1;
      }
    }

    final entries = scoreByRecipe.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => e.key).toList();
  }

  Future<Map<String, Map<String, dynamic>>> _fetchRecipeDocs(
    List<String> recipeIds,
  ) async {
    final out = <String, Map<String, dynamic>>{};
    const chunkSize = 30;

    for (var i = 0; i < recipeIds.length; i += chunkSize) {
      final chunk = recipeIds.skip(i).take(chunkSize).toList();
      final futures = chunk.map((recipeId) async {
        try {
          final snap = await _firestore.collection('recipes').doc(recipeId).get();
          if (!snap.exists) return;
          final data = snap.data();
          if (data == null || !_isVisibleCompleted(data)) return;
          out[snap.id] = Map<String, dynamic>.from(data);
        } catch (_) {}
      });
      await Future.wait(futures);
    }

    return out;
  }

  bool _isVisibleCompleted(Map<String, dynamic> data) {
    if (data['isHidden'] == true) return false;
    final status = (data['status'] as String?)?.trim().toLowerCase() ?? '';
    return status.isEmpty || status == 'completed';
  }

  List<String> _extractRecipeIngredientNames(Map<String, dynamic> data) {
    final recipe = data['recipe'];
    if (recipe is! Map) return const [];
    final ingredients = recipe['ingredients'];
    if (ingredients is! List) return const [];

    final names = <String>[];
    for (final raw in ingredients) {
      if (raw is! Map) continue;
      final name = IngredientIndexKey.normalize(
        (raw['item'] ?? '').toString(),
      );
      if (name.isNotEmpty) names.add(name);
    }
    return names;
  }

  List<String> _matchUserIngredients({
    required List<String> userIngredients,
    required List<String> recipeIngredients,
  }) {
    final matched = <String>[];
    for (final user in userIngredients) {
      for (final recipe in recipeIngredients) {
        if (_ingredientsMatch(user, recipe)) {
          matched.add(user);
          break;
        }
      }
    }
    return matched;
  }

  bool _ingredientsMatch(String user, String recipe) {
    if (user.isEmpty || recipe.isEmpty) return false;
    if (user == recipe) return true;
    if (user.contains(recipe) || recipe.contains(user)) return true;
    return false;
  }

  String _pickTitle(Map<String, dynamic> data) {
    final recipe = data['recipe'];
    if (recipe is Map) {
      final nested = (recipe['name'] ?? recipe['title'] ?? '').toString().trim();
      if (nested.isNotEmpty) return nested;
    }
    return (data['title'] ?? data['name'] ?? '레시피').toString();
  }

  String _pickThumbnail(Map<String, dynamic> data) {
    final source = data['source'];
    if (source is Map) {
      final thumb = (source['thumbnail'] ?? source['thumbnailUrl'] ?? '')
          .toString()
          .trim();
      if (thumb.isNotEmpty) return thumb;
    }
    return '';
  }
}
