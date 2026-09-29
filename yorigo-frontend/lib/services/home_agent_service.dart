import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';

class HomeAgentPick {
  HomeAgentPick({required this.recipeId, required this.reason});
  final String recipeId;
  final String reason;
}

class HomeAgentTurnResult {
  HomeAgentTurnResult({
    required this.onTopic,
    required this.reply,
    required this.usedLlm,
    required this.usedRanker,
    required this.retrieve,
    required this.recipeIds,
    required this.q,
    required this.spiceLow,
    required this.spiceHigh,
    required this.sectionKey,
    required this.followupChips,
    required this.warnings,
    required this.engine,
    required this.picks,
  });

  final bool onTopic;
  final String reply;
  final bool usedLlm;
  final bool usedRanker;
  final String retrieve;
  final List<String> recipeIds;
  final String q;
  final bool spiceLow;
  final bool spiceHigh;
  final String sectionKey;
  final List<String> followupChips;
  final List<String> warnings;
  final String engine;
  final List<HomeAgentPick> picks;
}

class HomeAgentException implements Exception {
  HomeAgentException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

class HomeAgentService {
  HomeAgentService._();
  static final HomeAgentService instance = HomeAgentService._();

  /// 이 챗에서 넣은 홈 검색 도우미. false면 UI·API 호출을 하지 않는다.
  static const bool enabled = false;

  Future<HomeAgentTurnResult> turn({
    String? chipId,
    String? message,
    String? focusIngredient,
    List<Map<String, String>>? history,
  }) async {
    if (!enabled) {
      throw HomeAgentException('disabled', statusCode: 503);
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw HomeAgentException('login_required', statusCode: 401);
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw HomeAgentException('login_required', statusCode: 401);
    }
    final body = <String, dynamic>{
      if (chipId != null && chipId.trim().isNotEmpty) 'chip_id': chipId.trim(),
      if (message != null && message.trim().isNotEmpty)
        'message': message.trim(),
      if (focusIngredient != null && focusIngredient.trim().isNotEmpty)
        'focus_ingredient': focusIngredient.trim(),
      if (history != null && history.isNotEmpty) 'history': history,
    };
    final response = await http
        .post(
          Uri.parse('${EnvironmentConfig.baseUrl}/home_agent/turn'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401) {
      throw HomeAgentException('login_required', statusCode: 401);
    }
    if (response.statusCode == 429) {
      throw HomeAgentException('rate_limited', statusCode: 429);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HomeAgentException(
        'agent_unavailable',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw HomeAgentException('agent_unavailable');
    }
    final map = Map<String, dynamic>.from(decoded);
    final ids = <String>[];
    final rawIds = map['recipe_ids'];
    if (rawIds is List) {
      for (final id in rawIds) {
        final tokenId = id.toString().trim();
        if (tokenId.isNotEmpty) ids.add(tokenId);
      }
    }
    final chips = <String>[];
    final chipsRaw = map['followup_chips'];
    if (chipsRaw is List) {
      for (final c in chipsRaw) {
        final chip = c.toString().trim();
        if (chip.isNotEmpty) chips.add(chip);
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
    final picks = <HomeAgentPick>[];
    final picksRaw = map['picks'];
    if (picksRaw is List) {
      for (final row in picksRaw) {
        if (row is! Map) continue;
        final rid = (row['recipe_id'] ?? '').toString().trim();
        if (rid.isEmpty) continue;
        picks.add(
          HomeAgentPick(
            recipeId: rid,
            reason: (row['reason'] ?? '').toString().trim(),
          ),
        );
      }
    }
    var recipeIds = ids.take(8).toList();
    if (recipeIds.isEmpty && picks.isNotEmpty) {
      recipeIds = picks.map((p) => p.recipeId).take(8).toList();
    }
    return HomeAgentTurnResult(
      onTopic: map['on_topic'] == true,
      reply: (map['reply'] as String?)?.trim() ?? '',
      usedLlm: map['used_llm'] == true,
      usedRanker: map['used_ranker'] == true,
      retrieve: (map['retrieve'] as String?)?.trim() ?? '',
      recipeIds: recipeIds,
      q: (map['q'] as String?)?.trim() ?? '',
      spiceLow: map['spice_low'] == true,
      spiceHigh: map['spice_high'] == true,
      sectionKey: (map['section_key'] as String?)?.trim() ?? '',
      followupChips: chips,
      warnings: warnings,
      engine: (map['engine'] as String?)?.trim() ?? '',
      picks: picks.take(8).toList(),
    );
  }
}
