double? _parseDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Firestore/LLM may store fractional servings (e.g. 2.5).
double? _parseServings(dynamic v) {
  if (v == null) return null;
  final d = v is int ? v.toDouble() : _parseDouble(v);
  if (d == null || d <= 0) return null;
  return d;
}

/// e.g. [2.5] → "2.5인분", [3.0] → "3인분"
String formatServingsLabel(num servings) {
  final d = servings.toDouble();
  if (d <= 0) return '1인분';
  if (d == d.roundToDouble()) return '${d.round()}인분';
  var text = d.toStringAsFixed(1);
  if (text.endsWith('.0')) {
    text = text.substring(0, text.length - 2);
  }
  return '${text}인분';
}

double portionStepForBase(double baseServings) {
  return baseServings.truncateToDouble() == baseServings ? 1.0 : 0.5;
}

/// Gemini / JSON sometimes emit "true" or 1 instead of a bool.
bool _parseBoolLoose(dynamic v) {
  if (v == true) return true;
  if (v == false || v == null) return false;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase().trim();
    return s == 'true' || s == '1' || s == 'yes';
  }
  return false;
}

List<String>? _parseStringList(dynamic v) {
  if (v == null) return null;
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String) return [v];
  return null;
}

/// YouTube/OCR sometimes yields unit "t" / "T" (tablespoon). Map to 큰술 — never SI ton in this app.
String? _normalizeTbspLetterAlias(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s == 't' || s == 'T') return '큰술';
  return raw;
}

class Ingredient {
  final double? qty;
  final String? unit;
  final double? qtyConventional;
  final String? unitConventional;
  final String item;
  final String? notes;
  final String? category;
  final bool estimated;

  Ingredient({
    this.qty,
    this.unit,
    this.qtyConventional,
    this.unitConventional,
    required this.item,
    this.notes,
    this.category,
    this.estimated = false,
  });

  factory Ingredient.fromJson(dynamic json) {
    if (json is! Map) return Ingredient(item: '');

    return Ingredient(
      qty: _parseDouble(json['qty']),
      unit: _normalizeTbspLetterAlias(json['unit']?.toString()),
      qtyConventional: _parseDouble(json['qty_conventional']),
      unitConventional:
          _normalizeTbspLetterAlias(json['unit_conventional']?.toString()),
      item: json['item']?.toString() ?? '',
      notes: json['notes']?.toString(),
      category: json['category']?.toString(),
      estimated: _parseBoolLoose(json['estimated']),
    );
  }

  /// Shape written to Firestore / local cache — must include every field [Ingredient.fromJson] reads.
  Map<String, dynamic> toRecipeStorageMap() => {
        'qty': qty,
        'unit': unit,
        'qty_conventional': qtyConventional ?? qty,
        'unit_conventional': unitConventional ?? unit,
        'item': item,
        'notes': notes,
        'category': category,
        'estimated': estimated,
      };
}

class Step {
  final int order;
  final String instruction;
  final String? tip;
  final List<String>? stepIngredients;
  final int? estMinutes;
  final List<String>? tools;
  final int? startSec;

  Step({
    required this.order,
    required this.instruction,
    this.tip,
    this.stepIngredients,
    this.estMinutes,
    this.tools,
    this.startSec,
  });

  factory Step.fromJson(dynamic json) {
    if (json is! Map) return Step(order: 0, instruction: '');

    return Step(
      order: json['order'] ?? 0,
      instruction: json['instruction']?.toString() ?? '',
      tip: json['tip']?.toString(),
      stepIngredients: _parseStringList(json['step_ingredients']),
      estMinutes: json['est_minutes'] != null
          ? (json['est_minutes'] as num).toInt()
          : null,
      tools: _parseStringList(json['tools']),
      startSec: json['start_sec'] != null
          ? (json['start_sec'] as num).toInt()
          : null,
    );
  }

  Step copyWith({int? startSec}) => Step(
        order: order,
        instruction: instruction,
        tip: tip,
        stepIngredients: stepIngredients,
        estMinutes: estMinutes,
        tools: tools,
        startSec: startSec ?? this.startSec,
      );

  Map<String, dynamic> toStorageMap() => {
        'order': order,
        'instruction': instruction,
        'tip': tip,
        'step_ingredients': stepIngredients,
        'est_minutes': estMinutes,
        'tools': tools,
        if (startSec != null) 'start_sec': startSec,
      };
}

class Recipe {
  final String? name;
  final double? servings;
  final List<Ingredient> ingredients;
  final List<Step> steps;
  final List<String>? equipment;
  final List<String>? notes;

  Recipe({
    this.name,
    this.servings,
    required this.ingredients,
    required this.steps,
    this.equipment,
    this.notes,
  });

  factory Recipe.fromJson(Map<String, dynamic> json) {
    final rawSteps =
        (json['steps'] as List<dynamic>?)
            ?.map((e) => Step.fromJson(e))
            .toList() ??
        [];

    // Sort steps chronologically by timestamp when available.
    // Steps without a timestamp keep their original relative order at the end.
    if (rawSteps.length > 1 &&
        rawSteps.any((s) => s.startSec != null)) {
      final withTs = <MapEntry<int, Step>>[];
      final withoutTs = <MapEntry<int, Step>>[];
      for (var i = 0; i < rawSteps.length; i++) {
        if (rawSteps[i].startSec != null) {
          withTs.add(MapEntry(i, rawSteps[i]));
        } else {
          withoutTs.add(MapEntry(i, rawSteps[i]));
        }
      }
      withTs.sort((a, b) => a.value.startSec!.compareTo(b.value.startSec!));
      final sorted = [...withTs.map((e) => e.value), ...withoutTs.map((e) => e.value)];
      for (var i = 0; i < sorted.length; i++) {
        sorted[i] = Step(
          order: i + 1,
          instruction: sorted[i].instruction,
          tip: sorted[i].tip,
          stepIngredients: sorted[i].stepIngredients,
          estMinutes: sorted[i].estMinutes,
          tools: sorted[i].tools,
          startSec: sorted[i].startSec,
        );
      }
      return Recipe(
        name: json['name']?.toString(),
        servings: _parseServings(json['servings']),
        ingredients:
            (json['ingredients'] as List<dynamic>?)
                ?.map((e) => Ingredient.fromJson(e))
                .toList() ??
            [],
        steps: sorted,
        equipment: _parseStringList(json['equipment']),
        notes: _parseStringList(json['notes']),
      );
    }

    return Recipe(
      name: json['name']?.toString(),
      servings: _parseServings(json['servings']),
      ingredients:
          (json['ingredients'] as List<dynamic>?)
              ?.map((e) => Ingredient.fromJson(e))
              .toList() ??
          [],
      steps: rawSteps,
      equipment: _parseStringList(json['equipment']),
      notes: _parseStringList(json['notes']),
    );
  }
}

class NutritionLLM {
  final double caloriesPerServing;
  final double proteinG;
  final double fatG;
  final double carbsG;
  final double sodiumMg;
  final double sugarG;
  final double cholesterolMg;
  final double fiberG;

  NutritionLLM({
    required this.caloriesPerServing,
    required this.proteinG,
    required this.fatG,
    required this.carbsG,
    required this.sodiumMg,
    required this.sugarG,
    required this.cholesterolMg,
    required this.fiberG,
  });

  factory NutritionLLM.fromJson(Map<String, dynamic> json) {
    return NutritionLLM(
      caloriesPerServing: _parseDouble(json['calories_per_serving']) ?? 0,
      proteinG: _parseDouble(json['protein_g']) ?? 0,
      fatG: _parseDouble(json['fat_g']) ?? 0,
      carbsG: _parseDouble(json['carbs_g']) ?? 0,
      sodiumMg: _parseDouble(json['sodium_mg']) ?? 0,
      sugarG: _parseDouble(json['sugar_g']) ?? 0,
      cholesterolMg: _parseDouble(json['cholesterol_mg']) ?? 0,
      fiberG: _parseDouble(json['fiber_g']) ?? 0,
    );
  }
}

class Nutrition {
  final Map<String, double> perServing;
  final List<String> assumptions;
  final NutritionLLM? llmEstimate;

  Nutrition({
    required this.perServing,
    required this.assumptions,
    this.llmEstimate,
  });

  factory Nutrition.fromJson(Map<String, dynamic> json) {
    // Handle Firestore _Map<dynamic, dynamic> types
    Map<String, double> parsePerServing(dynamic data) {
      if (data == null) return {};
      if (data is Map) {
        final Map<String, double> result = {};
        data.forEach((key, value) {
          if (value != null) {
            result[key.toString()] = _parseDouble(value) ?? 0;
          }
        });
        return result;
      }
      return {};
    }

    Map<String, dynamic> convertMap(dynamic data) {
      if (data == null) return {};
      if (data is Map) {
        final Map<String, dynamic> result = {};
        data.forEach((key, value) {
          result[key.toString()] = value;
        });
        return result;
      }
      return {};
    }

    return Nutrition(
      perServing: parsePerServing(json['per_serving']),
      assumptions: _parseStringList(json['assumptions']) ?? [],
      llmEstimate: json['llm_estimate'] != null
          ? NutritionLLM.fromJson(convertMap(json['llm_estimate']))
          : null,
    );
  }
}

class ParseResponse {
  final Map<String, dynamic> source;
  final Recipe recipe;
  final Nutrition nutrition;
  final Map<String, dynamic> debug;
  /// Average of all review ratings for this recipe (from Firestore). Null if no reviews.
  final double? averageRating;
  /// Number of reviews for this recipe (from Firestore). Null if not set.
  final int? reviewCount;

  ParseResponse({
    required this.source,
    required this.recipe,
    required this.nutrition,
    required this.debug,
    this.averageRating,
    this.reviewCount,
  });

  factory ParseResponse.fromJson(Map<String, dynamic> json) {
    // Helper to safely convert to Map<String, dynamic>
    Map<String, dynamic> convertMap(dynamic data) {
      if (data == null) return {};
      if (data is Map<String, dynamic>) return data;
      if (data is Map) {
        final Map<String, dynamic> result = {};
        data.forEach((key, value) {
          result[key.toString()] = value;
        });
        return result;
      }
      return {};
    }

    return ParseResponse(
      source: convertMap(json['source']),
      recipe: Recipe.fromJson(convertMap(json['recipe'])),
      nutrition: Nutrition.fromJson(convertMap(json['nutrition'])),
      debug: convertMap(json['debug']),
      averageRating: _parseDouble(json['averageRating']),
      reviewCount: json['reviewCount'] is num ? (json['reviewCount'] as num).toInt() : int.tryParse(json['reviewCount']?.toString() ?? ''),
    );
  }
}
