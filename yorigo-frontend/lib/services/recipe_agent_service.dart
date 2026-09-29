import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';
import '../models/recipe_models.dart' as models;

class RecipeAgentPatch {
  RecipeAgentPatch({
    required this.action,
    this.item,
    this.qty,
    this.unit,
    this.memo,
    this.category,
    this.order,
    this.instruction,
  });

  factory RecipeAgentPatch.fromJson(Map<String, dynamic> json) {
    return RecipeAgentPatch(
      action: (json['action'] as String?)?.trim() ?? '',
      item: (json['item'] as String?)?.trim(),
      qty: json['qty'] is num ? (json['qty'] as num).toDouble() : null,
      unit: (json['unit'] as String?)?.trim(),
      memo: (json['memo'] as String?)?.trim(),
      category: (json['category'] as String?)?.trim(),
      order: json['order'] is int
          ? json['order'] as int
          : int.tryParse('${json['order'] ?? ''}'),
      instruction: (json['instruction'] as String?)?.trim(),
    );
  }

  final String action;
  final String? item;
  final double? qty;
  final String? unit;
  final String? memo;
  final String? category;
  final int? order;
  final String? instruction;

  Map<String, dynamic> toOverlayMap() {
    return <String, dynamic>{
      'action': action,
      if (item != null) 'item': item,
      if (qty != null) 'qty': qty,
      if (unit != null && unit!.isNotEmpty) 'unit': unit,
      if (memo != null && memo!.isNotEmpty) 'memo': memo,
      if (category != null && category!.isNotEmpty) 'category': category,
      if (order != null) 'order': order,
      if (instruction != null && instruction!.isNotEmpty)
        'instruction': instruction,
    };
  }

  String get diffLabel {
    switch (action) {
      case 'ingredient.remove':
        return '${item ?? ''} 빼기';
      case 'ingredient.add':
        return '${item ?? ''} 넣기';
      case 'ingredient.edit':
        return '${item ?? ''} 수정';
      case 'ingredient.restore':
        return '${item ?? ''} 복원';
      case 'step.edit':
        return '${order ?? ''}번 단계 수정';
      default:
        return action;
    }
  }
}

class RecipeAgentTurnResult {
  RecipeAgentTurnResult({
    required this.onTopic,
    required this.reply,
    required this.followupChips,
    required this.patches,
    required this.warnings,
    required this.engine,
    this.awaitingConfirm = false,
  });

  final bool onTopic;
  final String reply;
  final List<String> followupChips;
  final List<RecipeAgentPatch> patches;
  final List<String> warnings;
  final String engine;
  final bool awaitingConfirm;
}

class RecipeAgentException implements Exception {
  RecipeAgentException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

class RecipeAgentService {
  RecipeAgentService._();
  static final RecipeAgentService instance = RecipeAgentService._();

  /// 상세 레시피 도우미. 기본 꺼짐.
  /// QA: `flutter run --dart-define=RECIPE_AGENT_ENABLED=true`
  static const bool enabled = bool.fromEnvironment(
    'RECIPE_AGENT_ENABLED',
    defaultValue: false,
  );

  static Map<String, dynamic> compactSnapshot(models.Recipe recipe) {
    final ingredients = recipe.ingredients.take(40).map((ing) {
      return <String, dynamic>{
        'item': ing.item,
        if (ing.qty != null) 'qty': ing.qty,
        if (ing.unit != null && ing.unit!.isNotEmpty) 'unit': ing.unit,
      };
    }).toList();
    final steps = recipe.steps.take(30).map((step) {
      var instruction = step.instruction;
      if (instruction.length > 200) {
        instruction = instruction.substring(0, 200);
      }
      return <String, dynamic>{
        'order': step.order,
        'instruction': instruction,
      };
    }).toList();
    return <String, dynamic>{
      'name': recipe.name ?? '',
      'servings': recipe.servings ?? 2,
      'ingredients': ingredients,
      'steps': steps,
    };
  }

  Future<RecipeAgentTurnResult> turn({
    String? recipeId,
    String? chipId,
    String? message,
    String? focusIngredient,
    Map<String, dynamic>? overlay,
    Map<String, dynamic>? clientSnapshot,
    List<Map<String, String>>? history,
    List<Map<String, dynamic>>? pendingPatches,
  }) async {
    if (!enabled) {
      throw RecipeAgentException('disabled', statusCode: 503);
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw RecipeAgentException('login_required', statusCode: 401);
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw RecipeAgentException('login_required', statusCode: 401);
    }
    final body = <String, dynamic>{
      if (recipeId != null && recipeId.trim().isNotEmpty)
        'recipe_id': recipeId.trim(),
      if (chipId != null && chipId.trim().isNotEmpty) 'chip_id': chipId.trim(),
      if (message != null && message.trim().isNotEmpty)
        'message': message.trim(),
      if (focusIngredient != null && focusIngredient.trim().isNotEmpty)
        'focus_ingredient': focusIngredient.trim(),
      if (overlay != null && overlay.isNotEmpty) 'overlay': overlay,
      if ((recipeId == null || recipeId.trim().isEmpty) &&
          clientSnapshot != null)
        'client_snapshot': clientSnapshot,
      if (history != null && history.isNotEmpty) 'history': history,
      if (pendingPatches != null && pendingPatches.isNotEmpty)
        'pending_patches': pendingPatches,
    };
    final response = await http
        .post(
          Uri.parse('${EnvironmentConfig.baseUrl}/recipe_agent/turn'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401) {
      throw RecipeAgentException('login_required', statusCode: 401);
    }
    if (response.statusCode == 429) {
      throw RecipeAgentException('rate_limited', statusCode: 429);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RecipeAgentException(
        'agent_unavailable',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw RecipeAgentException('agent_unavailable');
    }
    final map = Map<String, dynamic>.from(decoded);
    final patchesRaw = map['proposed_patches'];
    final patches = <RecipeAgentPatch>[];
    if (patchesRaw is List) {
      for (final raw in patchesRaw) {
        if (raw is Map) {
          patches.add(
            RecipeAgentPatch.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }
    final chips = <String>[];
    final chipsRaw = map['followup_chips'];
    if (chipsRaw is List) {
      for (final c in chipsRaw) {
        final tokenChip = c.toString().trim();
        if (tokenChip.isNotEmpty) chips.add(tokenChip);
      }
    }
    final warnings = <String>[];
    final warnRaw = map['warnings'];
    if (warnRaw is List) {
      for (final w in warnRaw) {
        final text = w.toString().trim();
        if (text.isNotEmpty) warnings.add(text);
      }
    }
    return RecipeAgentTurnResult(
      onTopic: map['on_topic'] == true,
      reply: (map['reply'] as String?)?.trim() ?? '',
      followupChips: chips,
      patches: patches,
      warnings: warnings,
      engine: (map['engine'] as String?)?.trim() ?? '',
      awaitingConfirm: map.containsKey('awaiting_confirm')
          ? map['awaiting_confirm'] == true
          : patches.isNotEmpty,
    );
  }
}
