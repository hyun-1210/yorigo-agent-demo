import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';
import '../constants/home_section_keys.dart';
import 'admin_service.dart';
import 'recipe_service.dart';

/// 관리자 홈 섹션 pin/block API (Cloud Functions HTTP).
class HomeSectionCurationService {
  HomeSectionCurationService._();
  static final HomeSectionCurationService instance =
      HomeSectionCurationService._();

  Future<Map<String, dynamic>?> getSectionState({
    required String sectionKey,
  }) async {
    return _post(action: 'get', sectionKey: sectionKey);
  }

  Future<bool> pinRecipe({
    required String sectionKey,
    required String recipeId,
  }) async {
    final res = await _post(
      action: 'pin',
      sectionKey: sectionKey,
      recipeId: recipeId,
    );
    return res != null && res['ok'] == true;
  }

  Future<bool> unpinRecipe({
    required String sectionKey,
    required String recipeId,
  }) async {
    final res = await _post(
      action: 'unpin',
      sectionKey: sectionKey,
      recipeId: recipeId,
    );
    return res != null && res['ok'] == true;
  }

  Future<bool> blockRecipe({
    required String sectionKey,
    required String recipeId,
  }) async {
    final res = await _post(
      action: 'block',
      sectionKey: sectionKey,
      recipeId: recipeId,
    );
    return res != null && res['ok'] == true;
  }

  Future<bool> unblockRecipe({
    required String sectionKey,
    required String recipeId,
  }) async {
    final res = await _post(
      action: 'unblock',
      sectionKey: sectionKey,
      recipeId: recipeId,
    );
    return res != null && res['ok'] == true;
  }

  Future<Map<String, int>?> rebuildSection({String? sectionKey}) async {
    final res = await _post(
      action: 'rebuild',
      sectionKey: sectionKey,
    );
    if (res == null || res['ok'] != true) return null;
    final counts = res['counts'];
    if (counts is! Map) return {};
    return counts.map(
      (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
    );
  }

  /// 레시피가 섹션 overrides 에서 어떤 상태인지.
  HomeSectionCurationStatus statusForRecipe({
    required List<String> pinnedIds,
    required List<String> blockedIds,
    required String recipeId,
  }) {
    if (pinnedIds.contains(recipeId)) {
      return HomeSectionCurationStatus.pinned;
    }
    if (blockedIds.contains(recipeId)) {
      return HomeSectionCurationStatus.blocked;
    }
    return HomeSectionCurationStatus.none;
  }

  Future<Map<String, dynamic>?> _post({
    required String action,
    String? sectionKey,
    String? recipeId,
  }) async {
    if (!await AdminService.instance.isAdmin()) {
      if (kDebugMode) {
        debugPrint('[HomeSectionCuration] not admin');
      }
      return null;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return null;

    final body = <String, dynamic>{'action': action};
    if (sectionKey != null && sectionKey.isNotEmpty) {
      body['sectionKey'] = sectionKey;
    }
    if (recipeId != null && recipeId.isNotEmpty) {
      body['recipeId'] = recipeId;
    }

    try {
      final response = await http.post(
        Uri.parse(EnvironmentConfig.adminHomeSectionCurationUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
            '[HomeSectionCuration] $action failed: ${response.statusCode} ${response.body}',
          );
        }
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        RecipeService.shared.invalidateExploreCaches();
        return decoded;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HomeSectionCuration] $action exception: $e');
      }
      return null;
    }
  }
}
