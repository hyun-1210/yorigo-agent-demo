import '../services/coupang_service.dart';
import 'product_amount_parser.dart';

/// Effective package/unit/unitPrice for display. When backend does not provide
/// (e.g. Kurly), these are derived from product name so UI matches Coupang.
extension CartProductExtension on CoupangProduct {
  /// Package size from API or parsed from product name.
  double? get effectivePackageSize {
    if (packageSize != null && packageSize! > 0) return packageSize;
    final parsed = parsePackageSizeFromName(productName);
    return parsed.size;
  }

  /// Package unit from API or parsed from product name.
  String? get effectivePackageUnit {
    if (packageUnit != null && packageUnit!.isNotEmpty) return packageUnit;
    final parsed = parsePackageSizeFromName(productName);
    return parsed.unit;
  }

  /// Unit price for display (per 100g for g/ml, per 1 unit otherwise).
  /// Returns null if cannot be computed.
  double? effectiveUnitPriceForDisplay(String? neededUnit) {
    if (unitPrice != null && unitPrice! > 0) return unitPrice;
    final size = effectivePackageSize;
    if (size == null || size <= 0 || productPrice <= 0) return null;
    final pricePerUnit = productPrice / size;
    final isGram = neededUnit == 'g' ||
        (neededUnit?.toLowerCase() == 'gram') ||
        (neededUnit?.toLowerCase() == 'grams');
    final isMl = neededUnit == 'ml' ||
        (neededUnit?.toLowerCase() == 'ml') ||
        (neededUnit?.toLowerCase() == '밀리리터');
    if (isGram || isMl) return pricePerUnit * 100;
    return pricePerUnit;
  }
}
