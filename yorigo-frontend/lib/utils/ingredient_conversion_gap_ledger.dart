import 'package:flutter/foundation.dart';

/// Why a recipe→shopping conversion is weak or missing — drives the "needs fix" queue.
enum IngredientConversionGapKind {
  /// [IngredientUnitConverter] used the generic 120 g / count fallback (no keyword map).
  defaultGramPerCountFallback,

  /// Recipe unit is left as a pass-through shopping unit (often mismatches g/ml packs).
  passThroughShoppingUnit,

  /// Two cart lines for the same ingredient normalized to different shopping units;
  /// the later line was not merged (data loss risk).
  cartAggregationUnitMismatch,
}

/// One item to triage: add researched mapping in [IngredientUnitConverter] (or backend parser).
@immutable
class IngredientConversionGap {
  IngredientConversionGap({
    required this.kind,
    required this.ingredientName,
    this.recipeUnit,
    this.shoppingUnit,
    this.detail,
    DateTime? recordedAt,
  }) : recordedAt = recordedAt ?? DateTime.now();

  final IngredientConversionGapKind kind;
  final String ingredientName;
  final String? recipeUnit;
  final String? shoppingUnit;
  final String? detail;
  final DateTime recordedAt;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'ingredientName': ingredientName,
        'recipeUnit': recipeUnit,
        'shoppingUnit': shoppingUnit,
        'detail': detail,
        'recordedAt': recordedAt.toIso8601String(),
      };
}

/// In-memory "needs research" list. Wire [onGap] to Analytics / Firestore / file export.
///
/// Workflow: run app → reproduce cart → [snapshot] / export JSON → add conversion
/// in `ingredient_unit_converter.dart` (or product size rules) → ship.
class IngredientConversionGapLedger {
  IngredientConversionGapLedger._();

  static const int maxEntries = 250;

  static final List<IngredientConversionGap> _entries = [];

  /// Optional sink (e.g. `FirebaseAnalytics.logEvent`, Crashlytics log, or HTTP to admin API).
  static void Function(IngredientConversionGap gap)? onGap;

  static void report(IngredientConversionGap gap) {
    if (_entries.length >= maxEntries) {
      _entries.removeAt(0);
    }
    _entries.add(gap);
    onGap?.call(gap);
    if (kDebugMode) {
      debugPrint('[ConversionGap] ${gap.kind.name} ${gap.ingredientName} '
          'recipeUnit=${gap.recipeUnit} shoppingUnit=${gap.shoppingUnit} ${gap.detail ?? ''}');
    }
  }

  static List<IngredientConversionGap> snapshot() =>
      List<IngredientConversionGap>.unmodifiable(_entries);

  static List<Map<String, Object?>> snapshotJson() =>
      _entries.map((e) => e.toJson()).toList();

  static void clear() => _entries.clear();
}
