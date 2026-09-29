import 'dart:math' as math;

import '../services/coupang_service.dart';
import 'ingredient_unit_converter.dart';

/// Client-side "딱 필요한 양" (aligned with backend `product_service` tagging).
class CloseAmountTag {
  CloseAmountTag._();

  /// R = recipe need and V = product pack amount in the same base ([g] or [ml]).
  ///
  /// For [r] ≤ 300, surplus allowance is **at least 300** (scaled up as [r] drops so
  /// 50–150g recipes can match common 300–600g packs). Tiny needs get an extra cap.
  static bool isCloseAmount(double r, double v) {
    if (r <= 0 || v <= 0) return false;
    if (v < r) return false;
    final diff = v - r;
    var absLimit = math.max(r, 0.5 * r + 200.0);
    if (r <= 300.0) {
      // "At least 300" slack for low recipe amounts, more when [r] is smaller.
      final lowNeedFloor = 300.0 + 0.65 * (300.0 - r);
      absLimit = math.max(absLimit, lowNeedFloor);
      if (r < 100.0) {
        // Very small [r]: retail mins are huge vs R; cap extra slack sensibly.
        absLimit = math.max(absLimit, math.min(580.0, 12.0 * r));
      }
    }
    if (diff > absLimit) return false;
    final maxMultiple = r < 200.0 ? 12.0 : (r <= 300.0 ? 6.5 : 2.75);
    if (v > maxMultiple * r) return false;
    return true;
  }

  /// Recipe need in g/ml only (excludes count/pack units we cannot align to [volume_g]).
  static ConvertedAmount? requiredBaseForCloseAmount({
    required String ingredientName,
    required double? neededQty,
    required String? neededUnit,
  }) {
    if (neededQty == null || neededQty <= 0) return null;
    if (neededUnit == null || neededUnit.trim().isEmpty) return null;
    final c = IngredientUnitConverter.toShoppingUnit(
      ingredientName: ingredientName,
      qty: neededQty,
      unit: neededUnit,
    );
    if (c.unit != 'g' && c.unit != 'ml') return null;
    if (c.qty <= 0) return null;
    return c;
  }

  /// Parsed pack total in g/ml (same basis as cart "담은 양" / [volume_g]).
  static ({double amount, String unit})? productBaseForCloseAmount(CoupangProduct product) {
    final parsed = IngredientUnitConverter.parseProductAmount(
      productName: product.productName,
      packageSize: product.packageSize,
      packageUnit: product.packageUnit,
      fallbackLabel: '',
    );
    if (parsed.rawAmount != null && parsed.rawAmount! > 0 && parsed.rawUnit != null) {
      final ru = IngredientUnitConverter.normalizeUnit(parsed.rawUnit!);
      if (ru == 'g' || ru == 'ml') {
        return (amount: parsed.rawAmount!, unit: ru);
      }
    }

    final v = product.volumeG;
    if (v != null && v > 0) {
      final nu = IngredientUnitConverter.normalizeUnit(product.packageUnit ?? '');
      if (nu == 'g' || nu == 'kg') return (amount: v, unit: 'g');
      if (nu == 'ml' || nu == 'l') return (amount: v, unit: 'ml');
    }
    return null;
  }

  static bool productMatchesCloseAmount({
    required String ingredientName,
    required double? neededQty,
    required String? neededUnit,
    required CoupangProduct product,
  }) {
    final req = requiredBaseForCloseAmount(
      ingredientName: ingredientName,
      neededQty: neededQty,
      neededUnit: neededUnit,
    );
    final pkg = productBaseForCloseAmount(product);
    if (req == null || pkg == null) return false;
    if (req.unit != pkg.unit) return false;
    return isCloseAmount(req.qty, pkg.amount);
  }
}
