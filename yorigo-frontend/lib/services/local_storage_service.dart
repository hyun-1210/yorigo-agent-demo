import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recipe_models.dart' as models;
import '../utils/recipe_overlay.dart';
import '../utils/recipebook_sync.dart';
import 'analytics_service.dart';

/// 레시피북 카테고리가 로컬에서 변경될 때마다 값이 증가하는 전역 신호.
/// 서로 다른 화면(홈/레시피 상세 등)이 같은 카테고리 목록을 보도록 동기화에 사용.
final ValueNotifier<int> recipebookCategoriesRevision = ValueNotifier<int>(0);

/// Local storage service for unauthenticated users
/// Recipes are saved locally and will be lost if the app is deleted
class LocalStorageService {
  static const String _recipesKey = 'local_recipes';
  static const String _recipesMetadataKey = 'local_recipes_metadata';

  // ─── 레시피북 카테고리 (유저별 로컬 캐시; 원본은 Firestore users/{uid}) ─
  static const String _legacyRecipebookCategoriesKey = 'recipebook_categories';
  static const String _legacyRecipebookRecipeCategoryMapKey =
      'recipebook_recipe_category_map';

  String _recipebookCategoriesKey(String uid) =>
      'recipebook_categories_$uid';
  String _recipebookRecipeCategoryMapKey(String uid) =>
      'recipebook_recipe_category_map_$uid';
  String _recipebookDirtyKey(String uid) => 'recipebook_dirty_$uid';
  String _recipebookLocalUpdatedAtKey(String uid) =>
      'recipebook_local_updated_at_$uid';

  // 기본 카테고리는 '자주 해먹는' 하나만 제공하고, 나머지는 유저가 직접 추가한다.
  static const List<Map<String, String>> _defaultCategoryTemplates = [
    {'id': 'default_often', 'name': '자주 해먹는', 'iconKey': 'heart'},
  ];

  List<Map<String, dynamic>> _buildDefaultCategories() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _defaultCategoryTemplates.asMap().entries.map((entry) {
      return <String, dynamic>{
        'id': entry.value['id'],
        'name': entry.value['name'],
        'iconKey': entry.value['iconKey'] ?? 'folder',
        'isDefault': true,
        'order': entry.key,
        'createdAt': now,
        'updatedAt': now,
      };
    }).toList();
  }

  /// 옛 기기 전역 키 → 유저별 키로 1회 이전.
  Future<void> _migrateLegacyRecipebookKeysIfNeeded(String uid) async {
    if (uid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final scopedCats = prefs.getString(_recipebookCategoriesKey(uid));
    final legacyCats = prefs.getString(_legacyRecipebookCategoriesKey);
    if ((scopedCats == null || scopedCats.isEmpty) &&
        legacyCats != null &&
        legacyCats.isNotEmpty) {
      await prefs.setString(_recipebookCategoriesKey(uid), legacyCats);
      await prefs.remove(_legacyRecipebookCategoriesKey);
    }
    final scopedMap = prefs.getString(_recipebookRecipeCategoryMapKey(uid));
    final legacyMap = prefs.getString(_legacyRecipebookRecipeCategoryMapKey);
    if ((scopedMap == null || scopedMap.isEmpty) &&
        legacyMap != null &&
        legacyMap.isNotEmpty) {
      await prefs.setString(_recipebookRecipeCategoryMapKey(uid), legacyMap);
      await prefs.remove(_legacyRecipebookRecipeCategoryMapKey);
    }
  }

  /// [seedIfEmpty]가 true 면 로컬이 비었을 때 「자주 해먹는」을 즉시 만든다.
  /// 클라우드 동기화 전에는 false 로 호출해야 새 기기가 빈 기본값을
  /// 공식 데이터처럼 올리지 않는다.
  Future<List<Map<String, dynamic>>> getRecipebookCategories(
    String uid, {
    bool seedIfEmpty = true,
  }) async {
    await _migrateLegacyRecipebookKeysIfNeeded(uid);
    final prefs = await SharedPreferences.getInstance();
    final key = _recipebookCategoriesKey(uid);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      if (!seedIfEmpty) return const [];
      final defaults = _buildDefaultCategories();
      await _saveCategories(uid, defaults, markDirty: false);
      return defaults;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      if (!seedIfEmpty) return const [];
      final defaults = _buildDefaultCategories();
      await _saveCategories(uid, defaults, markDirty: false);
      return defaults;
    }
    final list = decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    // 마이그레이션: 더 이상 제공하지 않는 옛 기본 카테고리(도전 예정/가족 인기/재도전)는
    // 자동 제거한다. 단, 유저가 이미 해당 카테고리로 분류해 둔 레시피가 있으면
    // 분류를 보존하기 위해 그대로 둔다. 유저가 추가한 카테고리(isDefault==false)도 유지.
    final allowedDefaultIds =
        _defaultCategoryTemplates.map((t) => t['id']).toSet();
    final usedCategoryIds = <String>{};
    final mapRaw = prefs.getString(_recipebookRecipeCategoryMapKey(uid));
    if (mapRaw != null && mapRaw.isNotEmpty) {
      try {
        final mapDecoded = jsonDecode(mapRaw);
        if (mapDecoded is Map) {
          for (final v in mapDecoded.values) {
            if (v is List) {
              for (final id in v) {
                final s = id?.toString().trim() ?? '';
                if (s.isNotEmpty) usedCategoryIds.add(s);
              }
            } else if (v is String && v.trim().isNotEmpty) {
              usedCategoryIds.add(v.trim());
            }
          }
        }
      } catch (_) {}
    }
    final cleaned = list.where((c) {
      if (c['isDefault'] != true) return true; // 유저 추가 카테고리 유지
      final id = (c['id'] as String?) ?? '';
      if (allowedDefaultIds.contains(id)) return true; // 현재 기본(자주 해먹는)
      return usedCategoryIds.contains(id); // 분류된 레시피가 있으면 보존
    }).toList();
    if (cleaned.isEmpty) {
      if (!seedIfEmpty) return const [];
      final defaults = _buildDefaultCategories();
      await _saveCategories(uid, defaults, markDirty: false);
      return defaults;
    }
    if (cleaned.length != list.length) {
      for (var i = 0; i < cleaned.length; i++) {
        cleaned[i]['order'] = i;
      }
      await _saveCategories(uid, cleaned, markDirty: false);
    }
    return cleaned;
  }

  /// 레시피북 카테고리 매핑: `recipeId → [categoryId, ...]`.
  /// 한 레시피는 여러 카테고리에 동시에 들어갈 수 있다.
  ///
  /// 과거(단일 카테고리) 포맷 `{recipeId: "categoryId"}` 도 그대로
  /// 읽어내서 1개짜리 리스트로 자동 마이그레이션한다. 별도 마이그레이션
  /// 스크립트 없이 첫 read 시점에 처리.
  Future<Map<String, List<String>>> getRecipebookRecipeCategoryMap(
    String uid,
  ) async {
    await _migrateLegacyRecipebookKeysIfNeeded(uid);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recipebookRecipeCategoryMapKey(uid));
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final result = <String, List<String>>{};
    decoded.forEach((k, v) {
      final key = k.toString();
      if (key.isEmpty) return;
      if (v is List) {
        final ids = v
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList();
        if (ids.isNotEmpty) result[key] = ids;
      } else if (v is String) {
        final trimmed = v.trim();
        if (trimmed.isNotEmpty) result[key] = [trimmed];
      }
    });
    return result;
  }

  /// Firestore/동기화 결과로 로컬 캐시를 통째로 교체한다.
  /// 클라우드에서 내려온 값이므로 dirty 로 표시하지 않는다.
  Future<void> replaceRecipebookCategories(
    String uid,
    List<Map<String, dynamic>> categories,
  ) async {
    await _saveCategories(uid, categories, markDirty: false);
  }

  Future<void> replaceRecipebookRecipeCategoryMap(
    String uid,
    Map<String, List<String>> mapping,
  ) async {
    await _saveCategoryMap(uid, mapping, markDirty: false);
  }

  Future<List<Map<String, dynamic>>> seedDefaultCategoriesIfEmpty(
    String uid,
  ) async {
    final existing = await getRecipebookCategories(uid, seedIfEmpty: false);
    if (existing.isNotEmpty) return existing;
    final defaults = _buildDefaultCategories();
    await _saveCategories(uid, defaults, markDirty: false);
    return defaults;
  }

  Future<bool> isRecipebookDirty(String uid) async {
    if (uid.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_recipebookDirtyKey(uid)) ?? false;
  }

  Future<DateTime?> getRecipebookLocalUpdatedAt(String uid) async {
    if (uid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_recipebookLocalUpdatedAtKey(uid));
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> markRecipebookClean(
    String uid, {
    DateTime? remoteUpdatedAt,
  }) async {
    if (uid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recipebookDirtyKey(uid));
    if (remoteUpdatedAt != null) {
      await prefs.setInt(
        _recipebookLocalUpdatedAtKey(uid),
        remoteUpdatedAt.millisecondsSinceEpoch,
      );
    }
  }

  /// 레시피 ID 가 바뀌면 분류 매핑 키도 옮긴다. 변경이 있으면 true.
  Future<bool> remapRecipebookRecipeId({
    required String uid,
    required String fromRecipeId,
    required String toRecipeId,
  }) async {
    final mapping = await getRecipebookRecipeCategoryMap(uid);
    final next = RecipebookSync.remapRecipeId(
      mapping: mapping,
      fromId: fromRecipeId,
      toId: toRecipeId,
    );
    if (_recipeCategoryMapsEqual(mapping, next)) return false;
    await _saveCategoryMap(uid, next);
    return true;
  }

  static bool _recipeCategoryMapsEqual(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || other.length != e.value.length) return false;
      for (var i = 0; i < e.value.length; i++) {
        if (other[i] != e.value[i]) return false;
      }
    }
    return true;
  }

  Future<Map<String, dynamic>> addRecipebookCategory(
    String uid,
    String name, {
    String iconKey = 'folder',
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw Exception('카테고리 이름을 입력해 주세요.');
    final categories = await getRecipebookCategories(uid);
    final duplicate = categories.any(
      (c) => ((c['name'] as String?) ?? '').trim() == trimmed,
    );
    if (duplicate) throw Exception('같은 이름의 카테고리가 이미 있어요.');
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(90000) + 10000}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final category = <String, dynamic>{
      'id': id,
      'name': trimmed,
      'iconKey': iconKey.trim().isNotEmpty ? iconKey.trim() : 'folder',
      'isDefault': false,
      'order': categories.length,
      'createdAt': now,
      'updatedAt': now,
    };
    categories.add(category);
    await _saveCategories(uid, categories);
    return category;
  }

  Future<void> renameRecipebookCategory(
    String uid, {
    required String categoryId,
    required String newName,
  }) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw Exception('카테고리 이름을 입력해 주세요.');
    final categories = await getRecipebookCategories(uid);
    final duplicate = categories.any(
      (c) =>
          ((c['id'] as String?) ?? '') != categoryId &&
          ((c['name'] as String?) ?? '').trim() == trimmed,
    );
    if (duplicate) throw Exception('같은 이름의 카테고리가 이미 있어요.');
    var found = false;
    for (final c in categories) {
      if ((c['id'] as String?) != categoryId) continue;
      c['name'] = trimmed;
      c['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      found = true;
      break;
    }
    if (!found) throw Exception('카테고리를 찾을 수 없어요.');
    await _saveCategories(uid, categories);
  }

  Future<void> deleteRecipebookCategory(String uid, String categoryId) async {
    final categories = await getRecipebookCategories(uid);
    final category = categories.firstWhere(
      (c) => (c['id'] as String?) == categoryId,
      orElse: () => <String, dynamic>{},
    );
    if (category.isEmpty) return;
    if (category['isDefault'] == true) {
      throw Exception('기본 카테고리는 삭제할 수 없어요.');
    }
    categories.removeWhere((c) => (c['id'] as String?) == categoryId);
    for (var i = 0; i < categories.length; i++) {
      categories[i]['order'] = i;
    }
    await _saveCategories(uid, categories);
    final mapping = await getRecipebookRecipeCategoryMap(uid);
    var changed = false;
    mapping.forEach((key, ids) {
      if (ids.remove(categoryId)) changed = true;
    });
    mapping.removeWhere((_, ids) => ids.isEmpty);
    if (changed) await _saveCategoryMap(uid, mapping);
  }

  /// 한 레시피에 대해 카테고리 ID 리스트를 통째로 설정한다.
  /// 빈 리스트면 해당 레시피의 매핑이 제거된다.
  Future<void> setRecipebookCategoriesForRecipe({
    required String uid,
    required String recipeId,
    required List<String> categoryIds,
  }) async {
    if (recipeId.trim().isEmpty) return;
    final mapping = await getRecipebookRecipeCategoryMap(uid);
    final cleaned = categoryIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (cleaned.isEmpty) {
      mapping.remove(recipeId);
    } else {
      mapping[recipeId] = cleaned;
    }
    await _saveCategoryMap(uid, mapping);
  }

  Future<void> removeRecipeCategoryMapping(String uid, String recipeId) async {
    final mapping = await getRecipebookRecipeCategoryMap(uid);
    if (mapping.remove(recipeId) != null) {
      await _saveCategoryMap(uid, mapping);
    }
  }

  Future<void> _saveCategories(
    String uid,
    List<Map<String, dynamic>> categories, {
    bool markDirty = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recipebookCategoriesKey(uid),
      jsonEncode(_jsonSafeCategoryList(categories)),
    );
    if (markDirty) {
      await _markRecipebookMutation(uid, prefs);
    }
    // 다른 화면들이 최신 목록을 다시 읽도록 신호.
    recipebookCategoriesRevision.value++;
  }

  Future<void> _saveCategoryMap(
    String uid,
    Map<String, List<String>> mapping, {
    bool markDirty = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recipebookRecipeCategoryMapKey(uid),
      jsonEncode(mapping),
    );
    if (markDirty) {
      await _markRecipebookMutation(uid, prefs);
    }
    recipebookCategoriesRevision.value++;
  }

  Future<void> _markRecipebookMutation(
    String uid,
    SharedPreferences prefs,
  ) async {
    if (uid.isEmpty) return;
    await prefs.setBool(_recipebookDirtyKey(uid), true);
    await prefs.setInt(
      _recipebookLocalUpdatedAtKey(uid),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static List<Map<String, dynamic>> _jsonSafeCategoryList(
    List<Map<String, dynamic>> categories,
  ) {
    return categories.map(_jsonSafeCategory).toList();
  }

  static Map<String, dynamic> _jsonSafeCategory(Map<String, dynamic> raw) {
    final out = <String, dynamic>{};
    raw.forEach((key, value) {
      if (value == null || value is num || value is bool || value is String) {
        out[key] = value;
        return;
      }
      if (value is DateTime) {
        out[key] = value.millisecondsSinceEpoch;
        return;
      }
      try {
        final millis = (value as dynamic).millisecondsSinceEpoch;
        if (millis is int) {
          out[key] = millis;
          return;
        }
      } catch (_) {}
    });
    return out;
  }

  /// 네이버 블로그 본문(재료/단계/영양) 디바이스 로컬 저장소.
  /// 저작권 회피 목적으로 Firestore 가 아닌 본인 디바이스에만 보관한다.
  /// 키: recipeId (Firestore `recipes/{id}` 와 동일한 ID 사용).
  static const String _naverBodiesKey = 'naver_private_bodies';

  /// 사용자가 레시피별로 디바이스에 직접 보관하는 메모/편집 오버레이.
  /// Firestore 의 공용 `recipes/{id}` 문서는 절대 수정하지 않고, 렌더 시 머지한다.
  /// 키: sourceUrl (recipeId 가 늦게 결정되어도 안정적인 식별자).
  static const String _userOverlayKey = 'recipe_user_overlay';

  static const String _homeTrendingFeedCacheKey = 'home_trending_feed_cache_v1';
  static const String _homeTrendingFeedCacheAtKey =
      'home_trending_feed_cache_at_v1';

  String _savedRecipesCacheKey(String uid) => 'saved_recipes_cache_$uid';
  String _cartCacheKey(String uid) => 'cart_cache_$uid';
  String _recommendationCacheKey(String uid) =>
      'cart_recommendation_cache_v2_$uid';
  String _recipeRecommendationCacheKey(String recipeId) =>
      'recipe_recommendation_cache_$recipeId';

  static const Duration recommendationCacheTtl = Duration(hours: 6);
  static const Duration recipeRecommendationCacheTtl = Duration(hours: 12);

  /// Save a recipe locally for unauthenticated users
  Future<String> saveRecipeLocally({
    required models.ParseResponse parseResponse,
    String? sourceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Generate a unique ID for this recipe
    final recipeId = 'local_${DateTime.now().millisecondsSinceEpoch}';

    // Get existing recipes
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    // Check if recipe with same source URL already exists
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      final existingRecipe = recipes.entries.firstWhere(
        (entry) => entry.value['sourceUrl'] == sourceUrl,
        orElse: () => MapEntry('', {}),
      );
      if (existingRecipe.key.isNotEmpty) {
        throw Exception('이미 저장된 레시피입니다');
      }
    }

    final recipe = parseResponse.recipe;
    final nutrition = parseResponse.nutrition;

    // Create recipe data structure (similar to Firebase)
    final recipeData = {
      'id': recipeId,
      'title': recipe.name ?? parseResponse.source['title'] ?? '레시피',
      'sourceUrl': sourceUrl,
      'thumbnailUrl': parseResponse.source['thumbnail'] ?? '',
      'source': parseResponse.source,
      'categories': parseResponse.source['categories'] ?? {},
      'tags': parseResponse.source['tags'] ?? [],
      'nutrition_rating': parseResponse.source['nutrition_rating'] ?? 'A',
      'recipe': {
        'name': recipe.name,
        'servings': recipe.servings,
        'ingredients':
            recipe.ingredients.map((ing) => ing.toRecipeStorageMap()).toList(),
        'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
        'equipment': recipe.equipment,
        'notes': recipe.notes,
      },
      'nutrition': {
        'per_serving': nutrition.perServing,
        'assumptions': nutrition.assumptions,
        'llm_estimate': nutrition.llmEstimate != null
            ? {
                'calories_per_serving':
                    nutrition.llmEstimate!.caloriesPerServing,
                'protein_g': nutrition.llmEstimate!.proteinG,
                'fat_g': nutrition.llmEstimate!.fatG,
                'carbs_g': nutrition.llmEstimate!.carbsG,
                'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                'sugar_g': nutrition.llmEstimate!.sugarG,
                'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                'fiber_g': nutrition.llmEstimate!.fiberG,
              }
            : null,
      },
      'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'isLocal': true, // Flag to indicate this is a local recipe
    };

    // Save recipe
    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));

    // Update metadata
    await _updateMetadata();

    print('[LocalStorage] Recipe saved locally with ID: $recipeId');
    return recipeId;
  }

  /// Get all locally stored recipes
  Future<List<Map<String, dynamic>>> getLocalRecipes() async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    // Convert to list and sort by creation date (newest first)
    final recipeList = recipes.values
        .map((recipe) => Map<String, dynamic>.from(recipe))
        .toList();

    recipeList.sort((a, b) {
      final aDate = DateTime.parse(a['createdAt'] as String);
      final bDate = DateTime.parse(b['createdAt'] as String);
      return bDate.compareTo(aDate);
    });

    return recipeList;
  }

  /// Get a single local recipe by ID
  Future<Map<String, dynamic>?> getLocalRecipe(String recipeId) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    if (recipes.containsKey(recipeId)) {
      return Map<String, dynamic>.from(recipes[recipeId]);
    }
    return null;
  }

  /// Delete a local recipe
  Future<void> deleteLocalRecipe(String recipeId) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    recipes.remove(recipeId);
    await prefs.setString(_recipesKey, jsonEncode(recipes));
    await _updateMetadata();

    print('[LocalStorage] Recipe deleted: $recipeId');
  }

  /// Mark a local recipe as user-cancelled (slot reusable on same URL re-parse).
  Future<void> markLocalRecipeCancelled(String recipeId) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));
    if (!recipes.containsKey(recipeId)) return;

    final recipeData = Map<String, dynamic>.from(recipes[recipeId] as Map);
    recipeData['status'] = 'cancelled';
    recipeData['cancelReason'] = 'user';
    recipeData['parseCancelledAt'] = DateTime.now().toIso8601String();
    recipeData['stage'] = '취소됨';
    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
    await _updateMetadata();
  }

  /// Revive a reusable cancelled local recipe for a new parse attempt.
  Future<void> reviveLocalParsingRecipe({
    required String recipeId,
    required String sourceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));
    if (!recipes.containsKey(recipeId)) {
      await createLocalParsingRecipe(recipeId: recipeId, sourceUrl: sourceUrl);
      return;
    }

    final existing = Map<String, dynamic>.from(recipes[recipeId] as Map);
    final gen = (existing['parsingGeneration'] as num?)?.toInt() ?? 1;
    final now = DateTime.now();
    existing['status'] = 'parsing';
    existing['progress'] = 0.0;
    existing['stage'] = '시작 중...';
    existing['parsingGeneration'] = gen + 1;
    existing['parsingStartedAt'] = now.toIso8601String();
    existing['parseCancelledAt'] = null;
    existing['cancelReason'] = null;
    existing['error'] = null;
    existing['errorType'] = null;
    existing['isTemporary'] = true;
    existing['recipe'] = {'title': '분석 중..'};
    recipes[recipeId] = existing;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
    await _updateMetadata();
  }

  /// Delete a local recipe
  Future<int> getLocalRecipeCount() async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));
    return recipes.length;
  }

  /// Clear all local recipes
  Future<void> clearAllLocalRecipes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recipesKey);
    await prefs.remove(_recipesMetadataKey);
    print('[LocalStorage] All local recipes cleared');
  }

  // ===== Disk cache for logged-in user home recipe list =====
  Future<void> saveSavedRecipesCache({
    required String uid,
    required DateTime cachedAt,
    required List<Map<String, dynamic>> recipes,
    required int totalCount,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'cachedAt': cachedAt.toIso8601String(),
      'totalCount': totalCount,
      'recipes': recipes,
    };
    await prefs.setString(
      _savedRecipesCacheKey(uid),
      jsonEncode(payload),
    );
  }

  Future<Map<String, dynamic>?> loadSavedRecipesCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedRecipesCacheKey(uid));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSavedRecipesCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedRecipesCacheKey(uid));
  }

  /// 홈 트렌드/카테고리 캐러셀 — 메모리 회수 후에도 1시간 재사용.
  Future<void> saveHomeTrendingFeedCache({
    required DateTime cachedAt,
    required Map<String, dynamic> payload,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _homeTrendingFeedCacheAtKey,
      cachedAt.toIso8601String(),
    );
    await prefs.setString(_homeTrendingFeedCacheKey, jsonEncode(payload));
  }

  /// 만료 여부만 판단 — 큰 payload jsonDecode 없이 cachedAt만 읽는다.
  Future<DateTime?> loadHomeTrendingFeedCacheCachedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final atOnly = prefs.getString(_homeTrendingFeedCacheAtKey);
    if (atOnly != null) {
      return DateTime.tryParse(atOnly);
    }
    // Legacy single-key { cachedAt, snapshot } — meta만 추출 (전체 파싱은 피함).
    final raw = prefs.getString(_homeTrendingFeedCacheKey);
    if (raw == null || raw.length < 24) return null;
    final cachedAtMatch = RegExp(
      r'"cachedAt"\s*:\s*"([^"]+)"',
    ).firstMatch(raw);
    if (cachedAtMatch == null) return null;
    return DateTime.tryParse(cachedAtMatch.group(1)!);
  }

  Future<bool> hasHomeTrendingFeedCachePayload() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_homeTrendingFeedCacheKey);
  }

  Future<Map<String, dynamic>?> loadHomeTrendingFeedCachePayload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_homeTrendingFeedCacheKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        if (decoded.containsKey('snapshot')) {
          final snap = decoded['snapshot'];
          if (snap is Map<String, dynamic>) return snap;
          if (snap is Map) return Map<String, dynamic>.from(snap);
        }
        return decoded;
      }
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        if (map.containsKey('snapshot')) {
          final snap = map['snapshot'];
          if (snap is Map<String, dynamic>) return snap;
          if (snap is Map) return Map<String, dynamic>.from(snap);
        }
        return map;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearHomeTrendingFeedCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_homeTrendingFeedCacheKey);
    await prefs.remove(_homeTrendingFeedCacheAtKey);
  }

  Future<void> saveCartCache({
    required String uid,
    required DateTime cachedAt,
    required List<dynamic> cartItems,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'cachedAt': cachedAt.toIso8601String(),
      'cartItems': cartItems,
    };
    await prefs.setString(_cartCacheKey(uid), jsonEncode(payload));
  }

  Future<Map<String, dynamic>?> loadCartCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cartCacheKey(uid));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCartCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cartCacheKey(uid));
  }

  Future<void> saveRecommendationCache({
    required String uid,
    required DateTime cachedAt,
    required Map<String, Map<String, dynamic>> entries,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'cachedAt': cachedAt.toIso8601String(),
      'entries': entries,
    };
    try {
      await prefs.setString(
        _recommendationCacheKey(uid),
        jsonEncode(payload),
      );
    } catch (_) {
      // Serialization failure — drop silently; in-memory cache is authoritative.
    }
  }

  Future<Map<String, Map<String, dynamic>>?> loadRecommendationCache(
    String uid,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recommendationCacheKey(uid));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final cachedAtRaw = decoded['cachedAt']?.toString();
      final cachedAt =
          cachedAtRaw != null ? DateTime.tryParse(cachedAtRaw) : null;
      if (cachedAt == null) return null;
      if (DateTime.now().difference(cachedAt) > recommendationCacheTtl) {
        return null;
      }
      final entries = decoded['entries'];
      if (entries is! Map) return null;
      final result = <String, Map<String, dynamic>>{};
      entries.forEach((key, value) {
        if (key is String && value is Map) {
          result[key] = Map<String, dynamic>.from(value);
        }
      });
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearRecommendationCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recommendationCacheKey(uid));
  }

  /// Save product recommendations for a specific recipe (per-recipe cache).
  Future<void> saveRecipeRecommendationCache({
    required String recipeId,
    required Map<String, Map<String, dynamic>> entries,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'cachedAt': DateTime.now().toIso8601String(),
      'entries': entries,
    };
    try {
      await prefs.setString(
        _recipeRecommendationCacheKey(recipeId),
        jsonEncode(payload),
      );
    } catch (_) {}
  }

  /// Load cached product recommendations for a recipe. Returns null if expired or missing.
  Future<Map<String, Map<String, dynamic>>?> loadRecipeRecommendationCache(
    String recipeId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recipeRecommendationCacheKey(recipeId));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final cachedAtRaw = decoded['cachedAt']?.toString();
      final cachedAt =
          cachedAtRaw != null ? DateTime.tryParse(cachedAtRaw) : null;
      if (cachedAt == null) return null;
      if (DateTime.now().difference(cachedAt) > recipeRecommendationCacheTtl) {
        return null;
      }
      final entries = decoded['entries'];
      if (entries is! Map) return null;
      final result = <String, Map<String, dynamic>>{};
      entries.forEach((key, value) {
        if (key is String && value is Map) {
          result[key] = Map<String, dynamic>.from(value);
        }
      });
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Migrate local recipes to Firebase when user logs in
  Future<Map<String, String>> migrateToFirebase({
    required Future<String?> Function(models.ParseResponse, String?)
    saveToFirebase,
  }) async {
    final localRecipes = await getLocalRecipes();
    final migrationMap = <String, String>{}; // local ID -> Firebase ID

    print(
      '[LocalStorage] Migrating ${localRecipes.length} recipes to Firebase',
    );

    for (final recipeData in localRecipes) {
      try {
        // Reconstruct ParseResponse from stored data
        final parseResponse = _reconstructParseResponse(recipeData);
        final sourceUrl = recipeData['sourceUrl'] as String?;

        // Save to Firebase (returns null if duplicate)
        final firebaseId = await saveToFirebase(parseResponse, sourceUrl);
        final localId = recipeData['id'] as String;

        if (firebaseId != null) {
          // Only add to migration map if successfully saved (not duplicate)
          migrationMap[localId] = firebaseId;
          print('[LocalStorage] Migrated $localId → $firebaseId');
        } else {
          // Recipe already exists in Firebase, skip it
          print(
            '[LocalStorage] Recipe already exists in Firebase, skipping: $localId',
          );
        }
      } catch (e) {
        print('[LocalStorage] Failed to migrate recipe: $e');
        // Continue with other recipes even if one fails
      }
    }

    // Keep local recipes after migration for offline access and backup
    // Local recipes serve as a backup and can be accessed offline
    print('[LocalStorage] Migration complete, local recipes kept for offline access');

    return migrationMap;
  }

  /// Update metadata (count, last updated, etc.)
  Future<void> _updateMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    final count = await getLocalRecipeCount();

    final metadata = {
      'count': count,
      'lastUpdated': DateTime.now().toIso8601String(),
    };

    await prefs.setString(_recipesMetadataKey, jsonEncode(metadata));
  }

  /// Reconstruct ParseResponse from stored data
  models.ParseResponse _reconstructParseResponse(
    Map<String, dynamic> recipeData,
  ) {
    final recipeMap = Map<String, dynamic>.from(recipeData['recipe']);
    final nutritionMap = Map<String, dynamic>.from(recipeData['nutrition']);

    return models.ParseResponse(
      source: Map<String, dynamic>.from(recipeData['source']),
      debug: {}, // Empty debug info when reconstructing
      recipe: models.Recipe(
        name: recipeMap['name'] as String?,
        servings: (recipeMap['servings'] as num?)?.toDouble(),
        ingredients: (recipeMap['ingredients'] as List)
            .map(
              (ing) => models.Ingredient(
                qty: ing['qty'] as double?,
                unit: ing['unit'] as String?,
                item: (ing['item'] as String?) ?? '',
                notes: ing['notes'] as String?,
                category: ing['category'] as String?,
              ),
            )
            .toList(),
        steps: (recipeMap['steps'] as List)
            .map(
              (step) => models.Step(
                order: (step['order'] as int?) ?? 0,
                instruction: (step['instruction'] as String?) ?? '',
                estMinutes: step['est_minutes'] as int?,
                tools: step['tools'] != null
                    ? List<String>.from(step['tools'])
                    : null,
              ),
            )
            .toList(),
        equipment: recipeMap['equipment'] != null
            ? List<String>.from(recipeMap['equipment'])
            : null,
        notes: recipeMap['notes'] != null
            ? List<String>.from(recipeMap['notes'])
            : null,
      ),
      nutrition: models.Nutrition(
        perServing: nutritionMap['per_serving'] is Map
            ? Map<String, double>.from(nutritionMap['per_serving'])
            : <String, double>{},
        assumptions: nutritionMap['assumptions'] is List
            ? List<String>.from(nutritionMap['assumptions'])
            : <String>[],
        llmEstimate: nutritionMap['llm_estimate'] != null
            ? models.NutritionLLM(
                caloriesPerServing:
                    (nutritionMap['llm_estimate']['calories_per_serving'] ?? 0)
                        .toDouble(),
                proteinG: (nutritionMap['llm_estimate']['protein_g'] ?? 0)
                    .toDouble(),
                fatG: (nutritionMap['llm_estimate']['fat_g'] ?? 0).toDouble(),
                carbsG: (nutritionMap['llm_estimate']['carbs_g'] ?? 0)
                    .toDouble(),
                sodiumMg: (nutritionMap['llm_estimate']['sodium_mg'] ?? 0)
                    .toDouble(),
                sugarG: (nutritionMap['llm_estimate']['sugar_g'] ?? 0)
                  .toDouble(),
                cholesterolMg: (nutritionMap['llm_estimate']['cholesterol_mg'] ?? 0)
                  .toDouble(),
                fiberG: (nutritionMap['llm_estimate']['fiber_g'] ?? 0)
                  .toDouble(),
              )
            : null,
      ),
    );
  }

  /// Check if a recipe with this source URL exists locally
  Future<String?> getLocalRecipeIdBySourceUrl(String sourceUrl) async {
    final recipes = await getLocalRecipes();
    for (final recipe in recipes) {
      if (recipe['sourceUrl'] == sourceUrl) {
        return recipe['id'] as String;
      }
    }
    return null;
  }

  /// Create a temporary parsing recipe in local storage
  /// Structure matches Firestore structure for consistency
  Future<void> createLocalParsingRecipe({
    required String recipeId,
    required String sourceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    final now = DateTime.now();
    // Match Firestore structure: no top-level 'title' during parsing, only 'recipe.title'
    final recipeData = {
      'id': recipeId,
      'sourceUrl': sourceUrl,
      'status': 'parsing',
      'progress': 0.0,
      'stage': '시작 중...',
      'recipe': {
        'title': '분석 중..', // 임시 제목 (Firestore와 동일)
      },
      'source': {
        'url': sourceUrl,
        'platform': _extractPlatform(sourceUrl),
      },
      'createdAt': now.toIso8601String(),
      'parsingStartedAt': now.toIso8601String(),
      'isTemporary': true,
      'isLocal': true, // Additional flag for local recipes
      'parsingGeneration': 1,
    };

    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
    await _updateMetadata();
  }

  /// Update parsing progress for a local recipe
  /// Matches Firestore update structure: updates 'recipe.title' not top-level 'title'
  Future<void> updateLocalParsingProgress({
    required String recipeId,
    double? progress,
    String? stage,
    String? subStage,
    String? title,
    String? thumbnailUrl,
    String? uploader,
    String? channel,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    if (!recipes.containsKey(recipeId)) {
      return; // Recipe doesn't exist
    }

    final recipeData = Map<String, dynamic>.from(recipes[recipeId]);
    
    if (progress != null) {
      recipeData['progress'] = progress;
    }
    if (stage != null) {
      recipeData['stage'] = stage;
    }
    if (subStage != null) {
      recipeData['sub_stage'] = subStage;
    }
    // Update recipe.title (not top-level title) to match Firestore structure
    if (title != null && title.isNotEmpty) {
      if (recipeData['recipe'] is Map) {
        (recipeData['recipe'] as Map)['title'] = title;
      } else {
        recipeData['recipe'] = {'title': title};
      }
    }
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      recipeData['thumbnailUrl'] = thumbnailUrl;
      if (recipeData['recipe'] is Map) {
        (recipeData['recipe'] as Map)['thumbnailUrl'] = thumbnailUrl;
      }
    }
    if (uploader != null && uploader.isNotEmpty) {
      recipeData['uploader'] = uploader;
      if (recipeData['source'] is Map) {
        (recipeData['source'] as Map)['uploader'] = uploader;
      } else {
        recipeData['source'] = {
          'url': recipeData['sourceUrl'] ?? '',
          'platform': _extractPlatform(
            (recipeData['sourceUrl'] as String?) ?? '',
          ),
          'uploader': uploader,
        };
      }
    }
    if (channel != null && channel.isNotEmpty) {
      recipeData['channel'] = channel;
      if (recipeData['source'] is Map) {
        (recipeData['source'] as Map)['channel'] = channel;
      }
    }

    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
  }

  /// Update a local recipe with completed parsing result
  /// Structure matches Firestore _completeParsing structure for consistency
  Future<void> updateLocalRecipeWithResult({
    required String recipeId,
    required models.ParseResponse parseResponse,
    required String sourceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    if (!recipes.containsKey(recipeId)) {
      // Cancelled/deleted — do not recreate from a late SSE completion.
      return;
    }

    final recipe = parseResponse.recipe;
    final nutrition = parseResponse.nutrition;
    final existingRecipe = recipes[recipeId] as Map<String, dynamic>;
    final now = DateTime.now();

    // Match Firestore _completeParsing structure exactly
    final recipeData = {
      'id': recipeId,
      'status': 'completed',
      'progress': 100.0,
      'stage': '완료',
      'isTemporary': false,
      'title': recipe.name ?? parseResponse.source['title'] ?? '레시피',
      'sourceUrl': sourceUrl,
      'recipe': {
        'name': recipe.name,
        'servings': recipe.servings,
        'ingredients':
            recipe.ingredients.map((ing) => ing.toRecipeStorageMap()).toList(),
        'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
        'equipment': recipe.equipment,
        'notes': recipe.notes,
      },
      'source': parseResponse.source,
      'nutrition': {
        'per_serving': nutrition.perServing,
        'assumptions': nutrition.assumptions,
        'llm_estimate': nutrition.llmEstimate != null
            ? {
                'calories_per_serving':
                    nutrition.llmEstimate!.caloriesPerServing,
                'protein_g': nutrition.llmEstimate!.proteinG,
                'fat_g': nutrition.llmEstimate!.fatG,
                'carbs_g': nutrition.llmEstimate!.carbsG,
                'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                'sugar_g': nutrition.llmEstimate!.sugarG,
                'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                'fiber_g': nutrition.llmEstimate!.fiberG,
              }
            : null,
      },
      'thumbnailUrl': parseResponse.source['thumbnail'] ?? '',
      'categories': parseResponse.source['categories'] ?? {},
      'tags': parseResponse.source['tags'] ?? [],
      'nutrition_rating': parseResponse.source['nutrition_rating'] ?? 'A',
      'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
      'createdAt': existingRecipe['createdAt'], // Keep original creation date
      'parsingStartedAt': existingRecipe['parsingStartedAt'], // Keep parsing start time
      'completedAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'isLocal': true, // Additional flag for local recipes
    };

    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
    await _updateMetadata();
  }

  /// Mark a local recipe as error
  Future<void> markLocalRecipeError({
    required String recipeId,
    required String error,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));

    if (!recipes.containsKey(recipeId)) {
      return;
    }

    final recipeData = Map<String, dynamic>.from(recipes[recipeId]);
    recipeData['status'] = 'error';
    recipeData['error'] = error;
    recipeData['updatedAt'] = DateTime.now().toIso8601String();

    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
  }

  /// error → parsing 재시도용 로컬 레시피 초기화.
  Future<void> resetLocalRecipeForRetry({required String recipeId}) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));
    if (!recipes.containsKey(recipeId)) {
      await createLocalParsingRecipe(recipeId: recipeId, sourceUrl: '');
      return;
    }

    final recipeData = Map<String, dynamic>.from(recipes[recipeId]);
    recipeData['status'] = 'parsing';
    recipeData['progress'] = 0.0;
    recipeData['stage'] = '시작 중...';
    recipeData['recipe'] = {'title': '분석 중..'};
    recipeData['parsingStartedAt'] = DateTime.now().toIso8601String();
    recipeData['isTemporary'] = true;
    recipeData.remove('error');
    recipeData.remove('errorType');
    recipeData['updatedAt'] = DateTime.now().toIso8601String();

    recipes[recipeId] = recipeData;
    await prefs.setString(_recipesKey, jsonEncode(recipes));
  }

  /// Extract platform from URL
  String _extractPlatform(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return 'youtube';
    } else if (lower.contains('instagram.com') || lower.contains('instagr.am')) {
      return 'instagram';
    } else if (lower.contains('tiktok.com')) {
      return 'tiktok';
    }
    return 'unknown';
  }

  // ===== Naver blog body store (device-local only) =====
  //
  // 네이버 블로그 레시피의 본문(재료/단계/영양)은 저작권 위험을 최소화하기 위해
  // Firestore 가 아닌 본인 디바이스에만 저장한다. 공용 `recipes/{id}` 에는
  // URL/제목/작성자/og_image 등 메타만 들어간다.
  //
  // 키: recipeId — Firestore `recipes/{id}` 와 동일한 ID 사용.
  // 값: { recipe, nutrition, sourceUrl, savedAt }

  Map<String, dynamic> _buildNaverBodyMap({
    required models.ParseResponse parseResponse,
    required String sourceUrl,
  }) {
    final recipe = parseResponse.recipe;
    final nutrition = parseResponse.nutrition;
    final source = parseResponse.source;
    // og:image URL 은 §30 사적복제 안전구간 내에서만 사용. 본인 디바이스에만 보관.
    final ogImageUrl =
        (source['og_image_url'] as String?)?.trim() ??
        (source['og_image'] as String?)?.trim() ??
        (source['thumbnail'] as String?)?.trim() ??
        '';
    return {
      'recipe': {
        'name': recipe.name,
        'servings': recipe.servings,
        'ingredients':
            recipe.ingredients.map((ing) => ing.toRecipeStorageMap()).toList(),
        'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
        'equipment': recipe.equipment,
        'notes': recipe.notes,
      },
      'nutrition': {
        'per_serving': nutrition.perServing,
        'assumptions': nutrition.assumptions,
        'llm_estimate': nutrition.llmEstimate != null
            ? {
                'calories_per_serving':
                    nutrition.llmEstimate!.caloriesPerServing,
                'protein_g': nutrition.llmEstimate!.proteinG,
                'fat_g': nutrition.llmEstimate!.fatG,
                'carbs_g': nutrition.llmEstimate!.carbsG,
                'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                'sugar_g': nutrition.llmEstimate!.sugarG,
                'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                'fiber_g': nutrition.llmEstimate!.fiberG,
              }
            : null,
      },
      'sourceUrl': sourceUrl,
      'ogImageUrl': ogImageUrl,
      'savedAt': DateTime.now().toIso8601String(),
    };
  }

  /// 네이버 블로그 본문 1건 저장. 동일 recipeId 가 있으면 덮어쓴다.
  Future<void> setNaverBody({
    required String recipeId,
    required models.ParseResponse parseResponse,
    required String sourceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_naverBodiesKey) ?? '{}';
    final bodies = Map<String, dynamic>.from(jsonDecode(raw));
    bodies[recipeId] = _buildNaverBodyMap(
      parseResponse: parseResponse,
      sourceUrl: sourceUrl,
    );
    await prefs.setString(_naverBodiesKey, jsonEncode(bodies));
  }

  /// recipeId 로 저장된 네이버 블로그 본문 조회. 없으면 null.
  Future<Map<String, dynamic>?> getNaverBody(String recipeId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_naverBodiesKey);
    if (raw == null) return null;
    try {
      final bodies = Map<String, dynamic>.from(jsonDecode(raw));
      final body = bodies[recipeId];
      if (body is Map) return Map<String, dynamic>.from(body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 여러 recipeId 의 네이버 본문을 한 번에 조회. 없는 ID 는 결과에서 빠진다.
  Future<Map<String, Map<String, dynamic>>> getNaverBodies(
    Iterable<String> recipeIds,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_naverBodiesKey);
    if (raw == null) return <String, Map<String, dynamic>>{};
    try {
      final all = Map<String, dynamic>.from(jsonDecode(raw));
      final result = <String, Map<String, dynamic>>{};
      for (final id in recipeIds) {
        final body = all[id];
        if (body is Map) result[id] = Map<String, dynamic>.from(body);
      }
      return result;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  /// recipeId 로 저장된 네이버 본문 삭제.
  Future<void> deleteNaverBody(String recipeId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_naverBodiesKey);
    if (raw == null) return;
    try {
      final bodies = Map<String, dynamic>.from(jsonDecode(raw));
      if (bodies.remove(recipeId) != null) {
        await prefs.setString(_naverBodiesKey, jsonEncode(bodies));
      }
    } catch (_) {
      // ignore
    }
  }

  /// 모든 네이버 본문 삭제 (로그아웃/계정 전환 시 사용 가능).
  Future<void> clearAllNaverBodies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_naverBodiesKey);
  }

  /// Merge step timestamps into a locally-stored recipe.
  Future<void> mergeStepTimestamps(String recipeId, List<int?> timestamps) async {
    final prefs = await SharedPreferences.getInstance();
    final recipesJson = prefs.getString(_recipesKey) ?? '{}';
    final recipes = Map<String, dynamic>.from(jsonDecode(recipesJson));
    final existing = recipes[recipeId] as Map<String, dynamic>?;
    if (existing == null) return;
    final recipeMap = existing['recipe'] as Map<String, dynamic>?;
    if (recipeMap == null) return;
    final steps = recipeMap['steps'] as List<dynamic>? ?? [];
    for (int i = 0; i < timestamps.length && i < steps.length; i++) {
      if (timestamps[i] != null && steps[i] is Map) {
        (steps[i] as Map<String, dynamic>)['start_sec'] = timestamps[i];
      }
    }
    await prefs.setString(_recipesKey, jsonEncode(recipes));
  }

  // ===== User overlay (memos + ingredient/step edits, device-local only) =====
  //
  // Firestore 의 공용 레시피 문서는 절대 수정하지 않는다. 사용자별 메모/편집은
  // SharedPreferences 에 별도 저장 후 렌더 시 머지(applyOverlay) 한다.
  //
  // 키 규칙:
  //   - 쓰기: uid::recipeId (없으면 uid::sourceUrl). 계정 간 내 버전 섞임 방지.
  //   - 읽기: 새 키 → 옛 sourceUrl → recipeId 순 폴백. 옛 키 히트 시 새 키로 복사.
  //   - 재료 edits 키: ingredient.item (원본 재료명, 불변)
  //   - 스텝 edits 키: step.order 의 문자열 (예: "3")
  //   - added 항목은 id 로 식별 (us_<ms>_<rand>)

  static String overlayPrimaryKey({
    String? uid,
    String? recipeId,
    String? sourceUrl,
  }) {
    final u = uid?.trim() ?? '';
    final id = recipeId?.trim() ?? '';
    final url = sourceUrl?.trim() ?? '';
    if (u.isNotEmpty && id.isNotEmpty) return '$u::$id';
    if (u.isNotEmpty && url.isNotEmpty) return '$u::$url';
    if (url.isNotEmpty) return url;
    return id;
  }

  /// uid::recipeId 키에서 분석용 recipeId를 꺼낸다. URL 키는 제외.
  @visibleForTesting
  static String? overlayRecipeIdForAnalytics(String recipeKey) {
    final key = recipeKey.trim();
    if (key.isEmpty) return null;
    final sep = key.indexOf('::');
    final id = sep >= 0 ? key.substring(sep + 2).trim() : key;
    if (id.isEmpty) return null;
    if (id.startsWith('http://') || id.startsWith('https://')) return null;
    return id;
  }

  void _trackOverlayEdited(String recipeKey, String editType) {
    final recipeId = overlayRecipeIdForAnalytics(recipeKey);
    if (recipeId == null) return;
    unawaited(
      AnalyticsService().trackRecipeOverlayEdited(
        recipeId: recipeId,
        editType: editType,
      ),
    );
  }

  static List<String> overlayReadKeys({
    String? uid,
    String? recipeId,
    String? sourceUrl,
  }) {
    final keys = <String>[];
    void add(String value) {
      final v = value.trim();
      if (v.isNotEmpty && !keys.contains(v)) keys.add(v);
    }

    add(overlayPrimaryKey(uid: uid, recipeId: recipeId, sourceUrl: sourceUrl));
    add(sourceUrl ?? '');
    add(recipeId ?? '');
    return keys;
  }

  Future<Map<String, dynamic>> getRecipeOverlay(String recipeKey) async {
    if (recipeKey.isEmpty) return <String, dynamic>{};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userOverlayKey);
    if (raw == null) return <String, dynamic>{};
    try {
      final all = Map<String, dynamic>.from(jsonDecode(raw));
      final entry = all[recipeKey];
      if (entry is Map) return Map<String, dynamic>.from(entry);
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 새 키 우선, 옛 sourceUrl 키 폴백. 옛 키면 새 키로 복사한다.
  Future<Map<String, dynamic>> getRecipeOverlayWithFallback({
    String? uid,
    String? recipeId,
    String? sourceUrl,
  }) async {
    final primary = overlayPrimaryKey(
      uid: uid,
      recipeId: recipeId,
      sourceUrl: sourceUrl,
    );
    final keys = overlayReadKeys(
      uid: uid,
      recipeId: recipeId,
      sourceUrl: sourceUrl,
    );
    for (final key in keys) {
      final overlay = await getRecipeOverlay(key);
      if (overlay.isEmpty) continue;
      if (primary.isNotEmpty && key != primary) {
        await _writeOverlay(primary, overlay);
      }
      return overlay;
    }
    return <String, dynamic>{};
  }

  /// 에이전트 패치를 한 번 읽어 한 번 쓴다 (부분 반영 방지).
  Future<void> applyOverlayPatches({
    required String recipeKey,
    required List<Map<String, dynamic>> patches,
  }) async {
    if (recipeKey.isEmpty || patches.isEmpty) return;
    final overlay = await getRecipeOverlay(recipeKey);
    final next = applyPatchesToOverlay(overlay, patches);
    await _writeOverlay(recipeKey, next);
  }

  Future<Map<String, dynamic>> _readAllOverlays() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userOverlayKey);
    if (raw == null) return <String, dynamic>{};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeOverlay(
    String recipeKey,
    Map<String, dynamic> overlay,
  ) async {
    if (recipeKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await _readAllOverlays();
    final isEmpty = _isOverlayEmpty(overlay);
    if (isEmpty) {
      all.remove(recipeKey);
    } else {
      overlay['updatedAt'] = DateTime.now().toIso8601String();
      all[recipeKey] = overlay;
    }
    await prefs.setString(_userOverlayKey, jsonEncode(all));
  }

  /// 오버레이 전체가 빈 상태인지(키 자체를 제거해도 되는지) 판정.
  bool _isOverlayEmpty(Map<String, dynamic> overlay) {
    final memo = (overlay['recipeMemo'] as String?)?.trim();
    if (memo != null && memo.isNotEmpty) return false;
    final ing = overlay['ingredients'] as Map?;
    if (ing != null) {
      final edits = ing['edits'] as Map?;
      if (edits != null && edits.isNotEmpty) return false;
      final removed = ing['removed'] as List?;
      if (removed != null && removed.isNotEmpty) return false;
      final added = ing['added'] as List?;
      if (added != null && added.isNotEmpty) return false;
    }
    final steps = overlay['steps'] as Map?;
    if (steps != null) {
      final edits = steps['edits'] as Map?;
      if (edits != null && edits.isNotEmpty) return false;
      final removed = steps['removed'] as List?;
      if (removed != null && removed.isNotEmpty) return false;
      final added = steps['added'] as List?;
      if (added != null && added.isNotEmpty) return false;
    }
    return true;
  }

  /// 레시피 전체 메모 저장. 빈 문자열이면 키 제거.
  Future<void> saveRecipeMemo(String recipeKey, String memo) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final previous = (overlay['recipeMemo'] as String?)?.trim() ?? '';
    final trimmed = memo.trim();
    if (trimmed.isEmpty) {
      overlay.remove('recipeMemo');
    } else {
      overlay['recipeMemo'] = trimmed;
    }
    await _writeOverlay(recipeKey, overlay);
    if (previous != trimmed) {
      _trackOverlayEdited(recipeKey, 'memo');
    }
  }

  /// 원본 재료의 qty/unit/메모를 부분적으로 덮어씀. 모든 인자가 비어있으면 키 제거.
  Future<void> setIngredientEdit({
    required String recipeKey,
    required String item,
    double? qty,
    String? unit,
    String? memo,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final edits = Map<String, dynamic>.from(
      (ingredients['edits'] as Map?) ?? const {},
    );

    final entry = <String, dynamic>{};
    if (qty != null) entry['qty'] = qty;
    final trimmedUnit = unit?.trim();
    if (trimmedUnit != null && trimmedUnit.isNotEmpty) {
      entry['unit'] = trimmedUnit;
    }
    final trimmedMemo = memo?.trim();
    if (trimmedMemo != null && trimmedMemo.isNotEmpty) {
      entry['memo'] = trimmedMemo;
    }

    if (entry.isEmpty) {
      edits.remove(item);
    } else {
      edits[item] = entry;
    }

    if (edits.isEmpty) {
      ingredients.remove('edits');
    } else {
      ingredients['edits'] = edits;
    }
    if (ingredients.isEmpty) {
      overlay.remove('ingredients');
    } else {
      overlay['ingredients'] = ingredients;
    }
    await _writeOverlay(recipeKey, overlay);
    _trackOverlayEdited(recipeKey, 'ingredient');
  }

  /// 원본 재료를 삭제 표시(렌더 시 제외). 동일 항목이 added 에 있으면 영향 없음.
  Future<void> removeIngredient({
    required String recipeKey,
    required String item,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final removed = List<String>.from(
      (ingredients['removed'] as List?)?.cast<String>() ?? const <String>[],
    );
    if (!removed.contains(item)) removed.add(item);
    ingredients['removed'] = removed;
    overlay['ingredients'] = ingredients;
    await _writeOverlay(recipeKey, overlay);
  }

  /// 삭제 표시된 원본 재료를 복원.
  Future<void> restoreIngredient({
    required String recipeKey,
    required String item,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final removed = List<String>.from(
      (ingredients['removed'] as List?)?.cast<String>() ?? const <String>[],
    );
    removed.remove(item);
    if (removed.isEmpty) {
      ingredients.remove('removed');
    } else {
      ingredients['removed'] = removed;
    }
    if (ingredients.isEmpty) {
      overlay.remove('ingredients');
    } else {
      overlay['ingredients'] = ingredients;
    }
    await _writeOverlay(recipeKey, overlay);
  }

  /// 사용자 정의 재료 추가. id 는 호출자가 생성(또는 자동 생성).
  /// 반환값: 생성된 id.
  Future<String> addCustomIngredient({
    required String recipeKey,
    required String item,
    double? qty,
    String? unit,
    String? category,
    String? memo,
    String? id,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((ingredients['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    final newId = id ?? _newAddedId('u');
    final entry = <String, dynamic>{
      'id': newId,
      'item': item.trim(),
      if (qty != null) 'qty': qty,
      if (unit != null && unit.trim().isNotEmpty) 'unit': unit.trim(),
      if (category != null && category.trim().isNotEmpty)
        'category': category.trim(),
      if (memo != null && memo.trim().isNotEmpty) 'memo': memo.trim(),
    };
    added.add(entry);
    ingredients['added'] = added;
    overlay['ingredients'] = ingredients;
    await _writeOverlay(recipeKey, overlay);
    return newId;
  }

  /// 사용자가 추가했던 재료를 수정.
  Future<void> updateCustomIngredient({
    required String recipeKey,
    required String id,
    String? item,
    double? qty,
    String? unit,
    String? category,
    String? memo,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((ingredients['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    final idx = added.indexWhere((e) => e['id'] == id);
    if (idx < 0) return;
    final entry = Map<String, dynamic>.from(added[idx]);
    if (item != null && item.trim().isNotEmpty) entry['item'] = item.trim();
    if (qty != null) entry['qty'] = qty;
    if (unit != null) {
      final t = unit.trim();
      if (t.isEmpty) {
        entry.remove('unit');
      } else {
        entry['unit'] = t;
      }
    }
    if (category != null) {
      final t = category.trim();
      if (t.isEmpty) {
        entry.remove('category');
      } else {
        entry['category'] = t;
      }
    }
    if (memo != null) {
      final t = memo.trim();
      if (t.isEmpty) {
        entry.remove('memo');
      } else {
        entry['memo'] = t;
      }
    }
    added[idx] = entry;
    ingredients['added'] = added;
    overlay['ingredients'] = ingredients;
    await _writeOverlay(recipeKey, overlay);
  }

  /// 사용자가 추가한 재료를 완전 제거(삭제 표시가 아니라 added 배열에서 제거).
  Future<void> deleteCustomIngredient({
    required String recipeKey,
    required String id,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final ingredients = Map<String, dynamic>.from(
      (overlay['ingredients'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((ingredients['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    added.removeWhere((e) => e['id'] == id);
    if (added.isEmpty) {
      ingredients.remove('added');
    } else {
      ingredients['added'] = added;
    }
    if (ingredients.isEmpty) {
      overlay.remove('ingredients');
    } else {
      overlay['ingredients'] = ingredients;
    }
    await _writeOverlay(recipeKey, overlay);
  }

  /// 원본 스텝(`step.order`)의 instruction/memo 를 부분적으로 덮어씀.
  Future<void> setStepEdit({
    required String recipeKey,
    required int order,
    String? instruction,
    String? memo,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final edits = Map<String, dynamic>.from(
      (steps['edits'] as Map?) ?? const {},
    );
    final key = order.toString();
    final entry = <String, dynamic>{};
    final trimmedInstr = instruction?.trim();
    if (trimmedInstr != null && trimmedInstr.isNotEmpty) {
      entry['instruction'] = trimmedInstr;
    }
    final trimmedMemo = memo?.trim();
    if (trimmedMemo != null && trimmedMemo.isNotEmpty) {
      entry['memo'] = trimmedMemo;
    }
    if (entry.isEmpty) {
      edits.remove(key);
    } else {
      edits[key] = entry;
    }
    if (edits.isEmpty) {
      steps.remove('edits');
    } else {
      steps['edits'] = edits;
    }
    if (steps.isEmpty) {
      overlay.remove('steps');
    } else {
      overlay['steps'] = steps;
    }
    await _writeOverlay(recipeKey, overlay);
    _trackOverlayEdited(recipeKey, 'step');
  }

  Future<void> removeStep({
    required String recipeKey,
    required int order,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final removed = List<int>.from(
      (steps['removed'] as List?)?.cast<int>() ?? const <int>[],
    );
    if (!removed.contains(order)) removed.add(order);
    steps['removed'] = removed;
    overlay['steps'] = steps;
    await _writeOverlay(recipeKey, overlay);
  }

  Future<void> restoreStep({
    required String recipeKey,
    required int order,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final removed = List<int>.from(
      (steps['removed'] as List?)?.cast<int>() ?? const <int>[],
    );
    removed.remove(order);
    if (removed.isEmpty) {
      steps.remove('removed');
    } else {
      steps['removed'] = removed;
    }
    if (steps.isEmpty) {
      overlay.remove('steps');
    } else {
      overlay['steps'] = steps;
    }
    await _writeOverlay(recipeKey, overlay);
  }

  /// 사용자 정의 스텝 추가.
  /// [anchor] 는 `{ "type": "start" | "end" | "afterOriginal" | "afterAdded",
  /// "value": <int|String|null> }` 형태.
  Future<String> addCustomStep({
    required String recipeKey,
    required String instruction,
    String? memo,
    Map<String, dynamic>? anchor,
    String? id,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((steps['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    final newId = id ?? _newAddedId('us');
    final entry = <String, dynamic>{
      'id': newId,
      'instruction': instruction.trim(),
      if (memo != null && memo.trim().isNotEmpty) 'memo': memo.trim(),
      'anchor': anchor ?? <String, dynamic>{'type': 'end'},
    };
    added.add(entry);
    steps['added'] = added;
    overlay['steps'] = steps;
    await _writeOverlay(recipeKey, overlay);
    return newId;
  }

  Future<void> updateCustomStep({
    required String recipeKey,
    required String id,
    String? instruction,
    String? memo,
    Map<String, dynamic>? anchor,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((steps['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    final idx = added.indexWhere((e) => e['id'] == id);
    if (idx < 0) return;
    final entry = Map<String, dynamic>.from(added[idx]);
    if (instruction != null && instruction.trim().isNotEmpty) {
      entry['instruction'] = instruction.trim();
    }
    if (memo != null) {
      final t = memo.trim();
      if (t.isEmpty) {
        entry.remove('memo');
      } else {
        entry['memo'] = t;
      }
    }
    if (anchor != null) {
      entry['anchor'] = anchor;
    }
    added[idx] = entry;
    steps['added'] = added;
    overlay['steps'] = steps;
    await _writeOverlay(recipeKey, overlay);
  }

  Future<void> deleteCustomStep({
    required String recipeKey,
    required String id,
  }) async {
    final overlay = await getRecipeOverlay(recipeKey);
    final steps = Map<String, dynamic>.from(
      (overlay['steps'] as Map?) ?? const {},
    );
    final added = List<Map<String, dynamic>>.from(
      ((steps['added'] as List?) ?? const [])
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
    );
    added.removeWhere((e) => e['id'] == id);
    if (added.isEmpty) {
      steps.remove('added');
    } else {
      steps['added'] = added;
    }
    if (steps.isEmpty) {
      overlay.remove('steps');
    } else {
      overlay['steps'] = steps;
    }
    await _writeOverlay(recipeKey, overlay);
  }

  /// 모든 유저 오버레이 삭제 (디버그/계정 전환 등에서 사용).
  Future<void> clearAllUserOverlays() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userOverlayKey);
  }

  // ─── 내 프로필 캐시 (stale-while-revalidate) ───────────────────────────
  static const String _ownProfileCacheKey = 'own_profile_cache_v1';
  static const Duration profileCacheTtl = Duration(hours: 24);

  Future<void> saveOwnProfileCache({
    required String uid,
    required Map<String, dynamic> data,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'uid': uid,
      'cachedAt': DateTime.now().toIso8601String(),
      ...data,
    };
    try {
      await prefs.setString(_ownProfileCacheKey, jsonEncode(payload));
    } catch (_) {
      // Serialization failure — in-memory state is authoritative.
    }
  }

  Future<Map<String, dynamic>?> loadOwnProfileCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_ownProfileCacheKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final cachedAtRaw = map['cachedAt']?.toString();
      final cachedAt =
          cachedAtRaw != null ? DateTime.tryParse(cachedAtRaw) : null;
      if (cachedAt == null) return null;
      if (DateTime.now().difference(cachedAt) > profileCacheTtl) {
        return null;
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearOwnProfileCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ownProfileCacheKey);
  }

  /// 추가 항목 식별자: 충돌 회피 위해 ms 타임스탬프 + 짧은 랜덤 문자열.
  String _newAddedId(String prefix) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = (ts ^ identityHashCode(this)).toRadixString(16).substring(0, 4);
    return '${prefix}_${ts}_$rand';
  }
}
