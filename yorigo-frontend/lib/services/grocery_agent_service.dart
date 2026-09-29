import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';

class GroceryMealSlot {
  GroceryMealSlot({
    required this.day,
    required this.recipeId,
    required this.recipeName,
    required this.servings,
    required this.note,
  });

  final String day;
  final String recipeId;
  final String recipeName;
  final int servings;
  final String note;

  factory GroceryMealSlot.fromJson(Map<String, dynamic> json) {
    return GroceryMealSlot(
      day: json['day']?.toString() ?? '',
      recipeId: json['recipe_id']?.toString() ?? '',
      recipeName: json['recipe_name']?.toString() ?? '',
      servings: (json['servings'] as num?)?.toInt() ?? 2,
      note: json['note']?.toString() ?? '',
    );
  }
}

class GroceryGapItem {
  GroceryGapItem({
    required this.name,
    required this.needed,
    required this.action,
    required this.note,
  });

  final String name;
  final String needed;
  final String action;
  final String note;

  factory GroceryGapItem.fromJson(Map<String, dynamic> json) {
    return GroceryGapItem(
      name: json['name']?.toString() ?? '',
      needed: json['needed']?.toString() ?? '',
      action: json['action']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
    );
  }
}

class GroceryBasketLine {
  GroceryBasketLine({
    required this.name,
    required this.productName,
    required this.pack,
    required this.price,
    required this.wastePct,
    required this.reason,
    required this.image,
    required this.rating,
    required this.reviews,
    required this.channel,
  });

  final String name;
  final String productName;
  final String pack;
  final int price;
  final int wastePct;
  final String reason;
  final String image;
  final double rating;
  final int reviews;
  final String channel;

  factory GroceryBasketLine.fromJson(Map<String, dynamic> json) {
    return GroceryBasketLine(
      name: json['name']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      pack: json['pack']?.toString() ?? '',
      price: (json['price'] as num?)?.toInt() ?? 0,
      wastePct: (json['waste_pct'] as num?)?.toInt() ?? 0,
      reason: json['reason']?.toString() ?? '',
      image: json['image']?.toString() ?? '',
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      reviews: (json['reviews'] as num?)?.toInt() ?? 0,
      channel: json['channel']?.toString() ?? '',
    );
  }
}

class GroceryAgentTurnResult {
  GroceryAgentTurnResult({
    required this.onTopic,
    required this.reply,
    required this.phase,
    required this.skillsLoaded,
    required this.policyDecision,
    required this.usedLlm,
    required this.engine,
    required this.solver,
    required this.meals,
    required this.gap,
    required this.basket,
    required this.totalPrice,
    required this.budget,
    required this.chips,
    required this.warnings,
  });

  final bool onTopic;
  final String reply;
  final String phase;
  final List<String> skillsLoaded;
  final String policyDecision;
  final bool usedLlm;
  final String engine;
  final String solver;
  final List<GroceryMealSlot> meals;
  final List<GroceryGapItem> gap;
  final List<GroceryBasketLine> basket;
  final int totalPrice;
  final int budget;
  final List<String> chips;
  final List<String> warnings;

  factory GroceryAgentTurnResult.fromJson(Map<String, dynamic> json) {
    List<T> mapList<T>(String key, T Function(Map<String, dynamic>) build) {
      final raw = json[key];
      if (raw is! List) return <T>[];
      return raw
          .whereType<Map>()
          .map((item) => build(Map<String, dynamic>.from(item)))
          .toList();
    }

    List<String> strings(String key) {
      final raw = json[key];
      if (raw is! List) return <String>[];
      return raw.map((item) => item.toString()).toList();
    }

    return GroceryAgentTurnResult(
      onTopic: json['on_topic'] == true,
      reply: json['reply']?.toString() ?? '',
      phase: json['phase']?.toString() ?? '',
      skillsLoaded: strings('skills_loaded'),
      policyDecision: json['policy_decision']?.toString() ?? '',
      usedLlm: json['used_llm'] == true,
      engine: json['engine']?.toString() ?? '',
      solver: json['solver']?.toString() ?? '',
      meals: mapList('meals', GroceryMealSlot.fromJson),
      gap: mapList('gap', GroceryGapItem.fromJson),
      basket: mapList('basket', GroceryBasketLine.fromJson),
      totalPrice: (json['total_price'] as num?)?.toInt() ?? 0,
      budget: (json['budget'] as num?)?.toInt() ?? 0,
      chips: strings('chips'),
      warnings: strings('warnings'),
    );
  }
}

class GroceryAgentException implements Exception {
  GroceryAgentException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

class GroceryAgentService {
  GroceryAgentService._();
  static final GroceryAgentService instance = GroceryAgentService._();

  /// 이 데모 레포에서는 홈 진입을 기본으로 켠다.
  static const bool enabled = bool.fromEnvironment(
    'GROCERY_AGENT_ENABLED',
    defaultValue: true,
  );

  Future<GroceryAgentTurnResult> turn({
    String? message,
    String? chipId,
  }) async {
    if (!enabled) {
      throw GroceryAgentException('disabled', statusCode: 503);
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw GroceryAgentException('login_required', statusCode: 401);
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw GroceryAgentException('login_required', statusCode: 401);
    }
    final response = await http.post(
      Uri.parse('${EnvironmentConfig.baseUrl}/grocery_agent/turn'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
        if (chipId != null && chipId.trim().isNotEmpty) 'chip_id': chipId.trim(),
      }),
    );
    if (response.statusCode != 200) {
      throw GroceryAgentException(
        'agent_${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw GroceryAgentException('bad_payload');
    }
    return GroceryAgentTurnResult.fromJson(Map<String, dynamic>.from(decoded));
  }
}
