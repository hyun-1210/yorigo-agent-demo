import 'product_amount_parser.dart' show dedupeDuplicateMassTokensInProductName;

import 'ingredient_conversion_gap_ledger.dart';

class ConvertedAmount {
  const ConvertedAmount({
    required this.qty,
    required this.unit,
    this.approx = false,
    this.note,
  });

  final double qty;
  final String unit; // commerce-friendly base unit: g/ml/개
  final bool approx;
  final String? note;
}

/// Result of parsing a product's actual package amount from its name / metadata.
/// [label] is the human-friendly display string (e.g. "1.5kg", "300g").
/// [rawAmount] / [rawUnit] are in normalised base units (g / ml / 개 …).
class ParsedProductAmount {
  const ParsedProductAmount({required this.label, this.rawAmount, this.rawUnit});
  final String label;
  final double? rawAmount;
  final String? rawUnit;
}

class IngredientUnitConverter {
  // Fallback when no specific keyword match exists.
  // Used ONLY for internal shopping aggregation (comparing recipe 개 counts
  // against product package sizes). Never shown in the UI without a keyword match.
  static const double _defaultOneCountInGram = 120.0;
  static const double _tbspMl = 15.0;
  static const double _cupMl = 200.0;
  static const double _pinchGram = 0.5;
  static const double _handfulGram = 30.0;

  // Average weight per 1개 / 1장 / 1대 in grams — Korean market research.
  // Sources: 국가표준식품성분표, 농촌진흥청, 쿠팡/마켓컬리 상품 규격 기준.
  // These values drive both shopping aggregation AND the "사용" approx display.
  // Only ingredients listed here will show "(약 Xg)" in the fridge 사용 column.
  static const Map<String, double> _countToGramByKeyword = {
    // ── 채소 ─────────────────────────────────────────────────────────────────
    '양파':        200.0, // 중간 크기 양파 1개 ≈ 200 g
    '대파':        100.0, // 대파/흙대파 1대 ≈ 100 g (흰 뿌리 포함)
    '쪽파':         15.0, // 쪽파 1대 ≈ 15 g
    '마늘':          4.0, // 마늘 1쪽 ≈ 4 g (한국산 마늘은 서양보다 작음)
    '통마늘':        60.0, // 통마늘 1통 ≈ 60 g
    '감자':        150.0, // 감자 1개 ≈ 150 g
    '고구마':       150.0, // 고구마 1개 ≈ 150 g
    '토마토':       180.0, // 완숙 토마토 1개 ≈ 180 g
    '방울토마토':     15.0, // 방울토마토 1개 ≈ 15 g
    '오이':        200.0, // 한국 오이 1개 ≈ 200 g (서양보다 가늘고 길어서 더 가벼움)
    '당근':        150.0, // 당근 1개 ≈ 150 g
    '애호박':       350.0, // 애호박 1개 ≈ 350 g
    '주키니':       350.0, // 주키니호박 1개 ≈ 350 g
    '파프리카':      170.0, // 파프리카 1개 ≈ 170 g
    '피망':        120.0, // 피망 1개 ≈ 120 g
    '고추':         18.0, // 일반 청·홍고추 1개 ≈ 18 g
    '청양고추':      12.0, // 청양고추 1개 ≈ 12 g (작고 매운 품종)
    '가지':        200.0, // 한국 가지 1개 ≈ 200 g
    '브로콜리':      350.0, // 브로콜리 1개 ≈ 350 g
    '콜리플라워':     600.0, // 콜리플라워 1개 ≈ 600 g
    '양배추':      1200.0, // 양배추 1통 ≈ 1200 g
    '배추':       2500.0, // 배추 1포기 ≈ 2500 g (김장용 중간 크기)
    '상추':          5.0, // 상추 1장 ≈ 5 g
    '깻잎':          2.0, // 깻잎 1장 ≈ 2 g
    '무':          800.0, // 무 1개 ≈ 800 g (중간 크기)
    '표고버섯':       15.0, // 표고버섯 1개 ≈ 15 g
    '느타리버섯':      10.0, // 느타리버섯 1개 ≈ 10 g (날것)
    '양송이':        20.0, // 양송이버섯 1개 ≈ 20 g
    '새송이':        50.0, // 새송이버섯 1개 ≈ 50 g
    '아스파라거스':    20.0, // 아스파라거스 1대 ≈ 20 g

    // ── 과일 ─────────────────────────────────────────────────────────────────
    '사과':        250.0, // 부사 사과 1개 ≈ 250 g
    '배':          600.0, // 신고 배 1개 ≈ 600 g (한국 배는 서양 배보다 큼)
    '레몬':        120.0, // 레몬 1개 ≈ 120 g
    '라임':         70.0, // 라임 1개 ≈ 70 g
    '바나나':       100.0, // 바나나 1개 ≈ 100 g (껍질 포함)
    '귤':          100.0, // 귤 1개 ≈ 100 g
    '딸기':         15.0, // 딸기 1개 ≈ 15 g

    // ── 단백질 / 가공품 ────────────────────────────────────────────────────────
    '계란':         60.0, // 계란 1개 ≈ 60 g (왕란 기준 68 g, 중란 60 g 사용)
    '달걀':         60.0,
    '두부':        300.0, // 두부 1모 ≈ 300 g (보통 300 g 한 모)
    '순두부':       350.0, // 순두부 1봉 ≈ 350 g
    '참치캔':       135.0, // 참치캔 1개 ≈ 135 g (동원 등 표준 캔)
    '소시지':        50.0, // 소시지 1개 ≈ 50 g
    '베이컨':        20.0, // 베이컨 1장 ≈ 20 g
    '버터':         10.0, // 버터 1개 (1큰술 분량) ≈ 10 g — 개별 포장 기준
  };

  // Density-like multipliers for volume-to-gram on common non-liquid pantry items.
  // Source: 식품의약품안전처 영양성분 데이터베이스 + 요리 계량 기준.
  static const Map<String, double> _tbspToGramByKeyword = {
    '고춧가루':   7.0,
    '고추가루':   7.0,
    '밀가루':     8.0,
    '부침가루':   8.0,
    '튀김가루':   8.0,
    '전분':       8.0,
    '녹말':       8.0,
    '설탕':      12.0,
    '소금':      18.0,
    '후추':       6.0,
    '깨':         9.0,
    '참깨':       9.0,
    '들깨':       9.0,
    '간장':      15.0,
    '식초':      15.0,
    '올리브유':   14.0,
    '식용유':    14.0,
    '참기름':    14.0,
    '들기름':    14.0,
    '미림':      15.0,
    '맛술':      15.0,
    '물엿':      20.0,
    '올리고당':   20.0,
    '꿀':        21.0,
    '고추장':    18.0,
    '된장':      17.0,
    '쌈장':      17.0,
    '케첩':      15.0,
    '마요네즈':   14.0,
    '굴소스':    18.0,
    '토마토페이스트': 17.0,
    '파슬리':     2.0, // dried parsley flakes
    '파슬리가루':  2.0,
    '바질':       2.0,
    '오레가노':    2.0,
    '허브':       2.0,
    '생크림':    15.0, // 1큰술 ≈ 15 ml ≈ 15 g
    '버터':      14.0, // 버터 1큰술 ≈ 14 g
    '파마산':     5.0, // 파마산 치즈 가루 1큰술 ≈ 5 g
    '치즈가루':    5.0,
  };

  static const Set<String> _mlLikeLiquids = {
    '물',
    '우유',
    '생크림',
    '휘핑크림',
    '크림',
    '두유',
    '요거트',
    '요구르트',
    '간장',
    '식초',
    '오일',
    '기름',
    '주스',
    '육수',
    '와인',
    '맥주',
    '소주',
    '막걸리',
    '미림',
    '맛술',
    '청주',
  };

  static String normalizeUnit(String? raw) {
    final source = (raw ?? '').trim();
    if (source.isEmpty) return '';
    final parsed = RegExp(
      r'^\s*\d+(?:\.\d+)?\s*(g|kg|ml|l|리터|그램|킬로그램|밀리리터|개|구|알|봉|봉지|팩|통|캔|병|묶음|단|판)\s*$',
      caseSensitive: false,
    ).firstMatch(source);
    final normalizedSource = parsed != null ? parsed.group(1)! : source;
    final u = normalizedSource.toLowerCase();
    if (u.isEmpty) return '';
    if (u == '그램' || u == 'gram' || u == 'grams') return 'g';
    if (u == '킬로그램' || u == 'kg' || u == 'kilogram') return 'kg';
    if (u == '밀리리터' || u == 'ml' || u == 'milliliter') return 'ml';
    if (u == '리터' || u == 'l' || u == 'liter') return 'l';
    if (u == '테이블스푼' || u == 'tbsp') return '큰술';
    if (u == '티스푼' || u == 'tsp') return '작은술';
    if (u == 'cup' || u == 'cups') return '컵';
    if (u == 'ea') return '개';
    return normalizedSource;
  }

  /// Returns true when [ingredientName] has a specific, researched entry in
  /// [_countToGramByKeyword].  Only these ingredients will show "(약 Xg)" in
  /// the fridge 사용 column when their recipe unit is count-like (개, 장, 대…).
  static bool hasSpecificCountMapping(String ingredientName) {
    return _lookupByKeyword(ingredientName, _countToGramByKeyword) != null;
  }

  static ConvertedAmount toShoppingUnit({
    required String ingredientName,
    required double qty,
    required String unit,
  }) {
    final normalizedUnit = normalizeUnit(unit);
    if (qty <= 0) {
      return ConvertedAmount(qty: 0, unit: normalizedUnit.isEmpty ? '개' : normalizedUnit);
    }

    // Already commerce-friendly base units.
    if (normalizedUnit == 'g' || normalizedUnit == 'ml') {
      return ConvertedAmount(qty: qty, unit: normalizedUnit);
    }
    if (normalizedUnit == 'kg') {
      return ConvertedAmount(qty: qty * 1000, unit: 'g');
    }
    if (normalizedUnit == 'l') {
      return ConvertedAmount(qty: qty * 1000, unit: 'ml');
    }

    if (normalizedUnit == '큰술' || normalizedUnit == '작은술' || normalizedUnit == '컵') {
      return _spoonOrCupToShopping(
        ingredientName: ingredientName,
        qty: qty,
        unit: normalizedUnit,
      );
    }

    if (normalizedUnit == '꼬집') {
      return const ConvertedAmount(qty: _pinchGram, unit: 'g', approx: true);
    }
    if (normalizedUnit == '줌') {
      return ConvertedAmount(qty: qty * _handfulGram, unit: 'g', approx: true);
    }

    // Recipe-only stalk / sheet / block units → grams when we have a researched
    // per-unit mass (same sources as [_countToGramByKeyword]).
    if (normalizedUnit == '대') {
      final per = _gramsPerDaUnit(ingredientName);
      if (per != null && per > 0) {
        return ConvertedAmount(qty: qty * per, unit: 'g', approx: true);
      }
    }
    if (normalizedUnit == '장') {
      final per = _gramsPerJangUnit(ingredientName);
      if (per != null && per > 0) {
        return ConvertedAmount(qty: qty * per, unit: 'g', approx: true);
      }
    }
    if (normalizedUnit == '모') {
      if (_isBlockTofuName(ingredientName)) {
        return ConvertedAmount(qty: qty * 300.0, unit: 'g', approx: true);
      }
    }

    // 순두부 retail packs are almost always ~350 g / 봉 (쿠팡·컬리 상품명 기준).
    if ((normalizedUnit == '봉' || normalizedUnit == '봉지') &&
        ingredientName.toLowerCase().contains('순두부')) {
      return ConvertedAmount(qty: qty * 350.0, unit: 'g', approx: true);
    }

    if (normalizedUnit == '개' ||
        normalizedUnit == '구' ||
        normalizedUnit == '알' ||
        normalizedUnit == '송이' ||
        normalizedUnit == '토막' ||
        normalizedUnit == '줄기') {
      if (_isEggLike(ingredientName)) {
        return ConvertedAmount(qty: qty, unit: '구');
      }
      final specificGram = _lookupByKeyword(ingredientName, _countToGramByKeyword);
      final g = _countToGram(ingredientName) * qty;
      if (specificGram == null) {
        IngredientConversionGapLedger.report(
          IngredientConversionGap(
            kind: IngredientConversionGapKind.defaultGramPerCountFallback,
            ingredientName: ingredientName,
            recipeUnit: normalizedUnit,
            shoppingUnit: 'g',
            detail: 'used ${_defaultOneCountInGram}g × $qty',
          ),
        );
      }
      return ConvertedAmount(qty: g, unit: 'g', approx: true);
    }

    // Pack-like units: keep count for shopping if not convertible.
    if (normalizedUnit == '봉' ||
        normalizedUnit == '봉지' ||
        normalizedUnit == '팩' ||
        normalizedUnit == '통' ||
        normalizedUnit == '캔' ||
        normalizedUnit == '병' ||
        normalizedUnit == '묶음' ||
        normalizedUnit == '단' ||
        normalizedUnit == '판') {
      return ConvertedAmount(qty: qty, unit: '개', approx: true);
    }

    final shoppingOut = normalizedUnit.isEmpty ? '개' : normalizedUnit;
    if (_passThroughUnitsToReport.contains(shoppingOut)) {
      IngredientConversionGapLedger.report(
        IngredientConversionGap(
          kind: IngredientConversionGapKind.passThroughShoppingUnit,
          ingredientName: ingredientName,
          recipeUnit: unit,
          shoppingUnit: shoppingOut,
          detail: 'qty=$qty',
        ),
      );
    }
    return ConvertedAmount(qty: qty, unit: shoppingOut, approx: true);
  }

  /// Units that often need a researched g/ml (or pack) mapping when they reach
  /// the pass-through [toShoppingUnit] tail — see [IngredientConversionGapLedger].
  static const Set<String> _passThroughUnitsToReport = {
    '장', '대', '모', '포기', '입', '근', '마리', '쪽', '움큼',
  };

  /// Merge raw recipe lines into a single map: normalized recipe unit → summed qty.
  /// Used by the cart so the UI can show `레시피 합계 (쇼핑 환산)`.
  static Map<String, double> mergeRecipeQtyByUnit(
    Map<String, double>? existing,
    String rawUnit,
    double rawQty,
  ) {
    if (rawQty <= 0) return Map<String, double>.from(existing ?? {});
    final out = Map<String, double>.from(existing ?? {});
    final k = normalizeUnit(rawUnit);
    out[k.isEmpty ? '' : k] = (out[k.isEmpty ? '' : k] ?? 0) + rawQty;
    return out;
  }

  /// Cart "필요량": `레시피에서 쓴 단위 합` + `(쇼핑/매칭에 쓰는 환산)` when they differ.
  static String formatCartNeedLabel({
    required String ingredientName,
    required double shoppingQty,
    required String shoppingUnit,
    Map<String, double>? recipeQtyByUnit,
  }) {
    Map<String, double>? raw;
    if (recipeQtyByUnit != null && recipeQtyByUnit.isNotEmpty) {
      raw = Map<String, double>.from(recipeQtyByUnit);
      raw.removeWhere((_, v) => v <= 0);
      if (raw.isEmpty) raw = null;
    }

    if (raw == null) {
      return _formatCartShoppingFallback(ingredientName, shoppingQty, shoppingUnit);
    }

    final recipePart = _formatMergedRecipeUnits(raw);
    if (_recipeMapMatchesShoppingSingle(raw, shoppingQty, shoppingUnit)) {
      return recipePart;
    }

    final paren = _formatCartShoppingParenContent(
      ingredientName,
      shoppingQty,
      shoppingUnit,
      raw,
    );
    return '$recipePart ($paren)';
  }

  static const List<String> _recipeUnitSortKeys = [
    '모', '장', '대', '봉', '봉지', '팩', '통', '캔', '병', '묶음', '단', '판',
    '개', '구', '알', '송이', '토막', '줄기',
    '큰술', '작은술', '컵', '꼬집', '줌',
    'kg', 'g', 'l', 'ml',
  ];

  static bool _isBlockTofuName(String ingredientName) {
    final n = ingredientName.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return n.contains('두부') && !n.contains('순두부');
  }

  static double? _gramsPerDaUnit(String ingredientName) {
    final n = ingredientName.toLowerCase();
    if (n.contains('대파')) return _countToGramByKeyword['대파'];
    if (n.contains('쪽파')) return _countToGramByKeyword['쪽파'];
    if (n.contains('아스파라거스')) {
      return _countToGramByKeyword['아스파라거스'];
    }
    return null;
  }

  static double? _gramsPerJangUnit(String ingredientName) {
    final n = ingredientName.toLowerCase();
    if (n.contains('상추')) return _countToGramByKeyword['상추'];
    if (n.contains('깻잎')) return _countToGramByKeyword['깻잎'];
    if (n.contains('베이컨')) return _countToGramByKeyword['베이컨'];
    return null;
  }

  static String _formatMergedRecipeUnits(Map<String, double> recipeQtyByUnit) {
    final keys = recipeQtyByUnit.keys.toList();
    int orderOf(String k) {
      final nk = normalizeUnit(k);
      final i = _recipeUnitSortKeys.indexOf(nk);
      if (i >= 0) return i;
      return 1000 + nk.hashCode;
    }

    keys.sort((a, b) {
      final c = orderOf(a).compareTo(orderOf(b));
      if (c != 0) return c;
      return a.compareTo(b);
    });

    final parts = <String>[];
    for (final k in keys) {
      final v = recipeQtyByUnit[k]!;
      final nk = normalizeUnit(k);
      if (nk.isEmpty) {
        parts.add(_fmtNum(v));
      } else {
        parts.add(_fmtQty(v, nk));
      }
    }
    return parts.join(' + ');
  }

  static bool _recipeMapMatchesShoppingSingle(
    Map<String, double> recipeQtyByUnit,
    double shoppingQty,
    String shoppingUnit,
  ) {
    if (recipeQtyByUnit.length != 1) return false;
    final e = recipeQtyByUnit.entries.first;
    final nk = normalizeUnit(e.key);
    final su = normalizeUnit(shoppingUnit);
    if (nk != su) return false;
    return (e.value - shoppingQty).abs() < 1e-6;
  }

  static bool _recipeMapOnlyNonMassUnits(Map<String, double> recipeQtyByUnit) {
    for (final k in recipeQtyByUnit.keys) {
      final nk = normalizeUnit(k);
      if (nk == 'g' || nk == 'ml' || nk == 'kg' || nk == 'l') return false;
    }
    return recipeQtyByUnit.isNotEmpty;
  }

  static bool _isMassShoppingUnit(String unit) {
    final u = normalizeUnit(unit).toLowerCase();
    return u == 'g' || u == 'gram' || u == 'grams' || u == 'kg';
  }

  static bool _isMlShoppingUnit(String unit) {
    final u = normalizeUnit(unit).toLowerCase();
    return u == 'ml' || u == 'l' || u == 'liter';
  }

  /// When the cart has no merged recipe map (legacy rows), keep eggs / 두부 readable.
  static String _formatCartShoppingFallback(
    String ingredientName,
    double shoppingQty,
    String shoppingUnit,
  ) {
    final u = shoppingUnit.trim();
    final uNorm = normalizeUnit(u);
    if (_isEggLike(ingredientName) &&
        (uNorm == '개' || uNorm == '알' || u == '개' || u == '알')) {
      return '${_fmtNum(shoppingQty)}구';
    }
    if (_isBlockTofuName(ingredientName) && _isMassShoppingUnit(shoppingUnit)) {
      final moQty = shoppingQty / 300.0;
      final approxG = shoppingQty.round();
      final moPart = moQty % 1 == 0
          ? '${moQty.toInt()}모'
          : moQty.toStringAsFixed(1);
      return '$moPart (대략 ${approxG}g)';
    }
    return _fmtQty(shoppingQty, shoppingUnit);
  }

  static String _formatCartShoppingParenContent(
    String ingredientName,
    double shoppingQty,
    String shoppingUnit,
    Map<String, double> recipeQtyByUnit,
  ) {
    final su = normalizeUnit(shoppingUnit);

    if (_isEggLike(ingredientName) && su == '구') {
      return _fmtQty(shoppingQty, '구');
    }

    final blockTofu = _isBlockTofuName(ingredientName);
    final sundubu = ingredientName.toLowerCase().contains('순두부');
    if (blockTofu && _isMassShoppingUnit(shoppingUnit)) {
      return '대략 ${_fmtQty(shoppingQty, 'g')}';
    }
    if (sundubu && _isMassShoppingUnit(shoppingUnit)) {
      return '대략 ${_fmtQty(shoppingQty, 'g')}';
    }

    if (_recipeMapOnlyNonMassUnits(recipeQtyByUnit) &&
        _isMassShoppingUnit(shoppingUnit)) {
      return '약 ${_fmtQty(shoppingQty, 'g')}';
    }
    if (_recipeMapOnlyNonMassUnits(recipeQtyByUnit) && _isMlShoppingUnit(shoppingUnit)) {
      return '약 ${_fmtQty(shoppingQty, shoppingUnit)}';
    }

    return _fmtQty(shoppingQty, shoppingUnit);
  }

  /// Formats the cooking quantity with a shopping-unit approximation in
  /// parentheses, e.g. "1개 (약 200g) 사용".
  ///
  /// The parenthetical is ONLY appended when:
  ///   • the cooking unit differs from the shopping unit, AND
  ///   • the ingredient has a specific, researched entry in [_countToGramByKeyword]
  ///     (so arbitrary 120g-default fallbacks are never shown).
  static String formatCookingWithShoppingApprox({
    required String ingredientName,
    required double cookingQty,
    required String cookingUnit,
    required String shoppingUnit,
    int decimals = 1,
  }) {
    final cookStr = _fmt(cookingQty, cookingUnit, decimals: decimals);
    final normalizedCooking = normalizeUnit(cookingUnit);
    final normalizedShopping = normalizeUnit(shoppingUnit);

    // Units already the same — no conversion needed.
    if (normalizedCooking == normalizedShopping) {
      return '$cookStr 사용';
    }

    // For count-like cooking units only show approx when we have a trusted mapping.
    final isCountLike = normalizedCooking == '개' ||
        normalizedCooking == '구' ||
        normalizedCooking == '알' ||
        normalizedCooking == '장' ||
        normalizedCooking == '대' ||
        normalizedCooking == '송이' ||
        normalizedCooking == '토막' ||
        normalizedCooking == '줄기';
    if (isCountLike && !hasSpecificCountMapping(ingredientName)) {
      return '$cookStr 사용';
    }

    final converted = toShoppingUnit(
      ingredientName: ingredientName,
      qty: cookingQty,
      unit: cookingUnit,
    );
    if (converted.qty <= 0) return '$cookStr 사용';

    final shoppingStr = _fmtQty(converted.qty, converted.unit, decimals: decimals);
    return '$cookStr (약 $shoppingStr) 사용';
  }

  static String formatQty(double qty, String unit, {int decimals = 1}) {
    return _fmt(qty, unit, decimals: decimals);
  }

  static ConvertedAmount _spoonOrCupToShopping({
    required String ingredientName,
    required double qty,
    required String unit,
  }) {
    double tbspEquivalent;
    if (unit == '큰술') {
      tbspEquivalent = qty;
    } else if (unit == '작은술') {
      tbspEquivalent = qty / 3.0;
    } else {
      // 컵
      final ml = qty * _cupMl;
      if (_looksLiquid(ingredientName)) {
        return ConvertedAmount(qty: ml, unit: 'ml', approx: true);
      }
      final gFromMl = ml; // 1ml≈1g fallback
      return ConvertedAmount(qty: gFromMl, unit: 'g', approx: true);
    }

    final keywordGram = _lookupByKeyword(ingredientName, _tbspToGramByKeyword);
    if (keywordGram != null) {
      return ConvertedAmount(qty: tbspEquivalent * keywordGram, unit: 'g', approx: true);
    }
    if (_looksLiquid(ingredientName)) {
      return ConvertedAmount(qty: tbspEquivalent * _tbspMl, unit: 'ml', approx: true);
    }
    // Unknown powder/solid: 1 큰술 ~= 10g fallback.
    return ConvertedAmount(qty: tbspEquivalent * 10.0, unit: 'g', approx: true);
  }

  static double _countToGram(String ingredientName) {
    final specific = _lookupByKeyword(ingredientName, _countToGramByKeyword);
    return specific ?? _defaultOneCountInGram;
  }

  static bool _looksLiquid(String ingredientName) {
    final n = ingredientName.toLowerCase();
    for (final k in _mlLikeLiquids) {
      if (n.contains(k)) return true;
    }
    return false;
  }

  static bool _isEggLike(String ingredientName) {
    final n = ingredientName.toLowerCase();
    return n.contains('계란') || n.contains('달걀') || n.contains('에그');
  }

  /// Product **title** (commerce listing) — broader than [_isEggLike] for parsing.
  static bool _looksLikeEggProductTitle(String name) {
    final lower = name.toLowerCase();
    return lower.contains('계란') ||
        lower.contains('달걀') ||
        lower.contains('무항생') ||
        lower.contains('특란') ||
        lower.contains('왕란') ||
        lower.contains('에그') ||
        lower.contains('식용란') ||
        lower.contains('egg');
  }

  /// Eggs: total = N알 × M개 (e.g. 30 × 2 = 60). Only when both tokens exist.
  static ParsedProductAmount? _tryParseEggPackProductAmount(String name) {
    if (!_looksLikeEggProductTitle(name)) return null;

    // Try 알 or 구 count patterns (e.g. "30알", "30구")
    final alMatch = RegExp(r'(\d+(?:\.\d+)?)\s*알(?!이)').firstMatch(name);
    final guMatch = RegExp(r'(\d+(?:\.\d+)?)\s*구(?![매입])').firstMatch(name);
    final countMatch = alMatch ?? guMatch;
    final countUnit = alMatch != null ? '구' : '구';

    final packMatch = RegExp(r'(\d+)\s*개(?!입)').firstMatch(name);

    if (countMatch != null) {
      final countN = double.tryParse(countMatch.group(1)!);
      if (countN == null || countN <= 0) return null;
      final packN = (packMatch != null)
          ? (int.tryParse(packMatch.group(1)!) ?? 1)
          : 1;
      final total = countN * packN;
      final str = total % 1 == 0
          ? '${total.toInt()}'
          : total.toStringAsFixed(1);
      return ParsedProductAmount(
        label: '$str$countUnit',
        rawAmount: total,
        rawUnit: normalizeUnit(countUnit),
      );
    }

    return null;
  }

  static double? _lookupByKeyword(String ingredientName, Map<String, double> table) {
    final n = ingredientName.toLowerCase();
    for (final e in table.entries) {
      if (n.contains(e.key.toLowerCase())) return e.value;
    }
    return null;
  }

  static String _fmt(double qty, String unit, {int decimals = 1}) {
    return '${_fmtNum(qty, decimals: decimals)}$unit';
  }

  static String _fmtQty(double qty, String unit, {int decimals = 1}) {
    // Auto-scale g→kg, ml→L for display.
    if (unit == 'g' && qty >= 1000) {
      final kg = qty / 1000;
      return '${_fmtNum(kg, decimals: decimals)}kg';
    }
    if (unit == 'ml' && qty >= 1000) {
      final l = qty / 1000;
      return '${_fmtNum(l, decimals: decimals)}L';
    }
    return '${_fmtNum(qty, decimals: decimals)}$unit';
  }

  static String _fmtNum(double qty, {int decimals = 1}) {
    if ((qty - qty.roundToDouble()).abs() < 1e-9) return qty.toInt().toString();
    return qty.toStringAsFixed(decimals);
  }

  /// Upper bound for a single mass token in the title (retail grocery).
  /// Filters bogus OCR/listings like "200kg" when "2kg" is the real net weight.
  static const double _maxSaneKgInTitle = 100.0;
  static const double _maxSaneGInTitle = 100000.0;
  static const double _maxSaneLInTitle = 50.0;
  static const double _maxSaneMlInTitle = 50000.0;

  /// Retail "담은 양" above this total (base g or ml) is treated as a parse error
  /// so we fall back to title-only / other paths (avoids 200kg from bad metadata).
  static const double _maxReasonablePackTotalGrams = 100000.0;

  /// Scan all `N개` / `N세트`; use the first [n] with 1 <= n <= 30.
  /// Skips marketing counts like "100개 판매" so a later "1개" or none can apply.
  static int _firstValidPackMultiplier(String name) {
    final re = RegExp(r'(\d+)\s*(?:개(?!입)|세트)', caseSensitive: false);
    for (final m in re.allMatches(name)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n >= 1 && n <= 30) return n;
    }
    return 1;
  }

  /// Collects plausible mass/volume tokens; picks the last-occurring match
  /// (product names list options first, actual variant toward the end).
  /// When both kg and g are present with a multiplier, checks if kg is already
  /// the pre-computed total (g × count ≈ kg × 1000) to avoid double-multiplying.
  /// Skips `…g당` (per-unit pricing) and absurd single-token weights.
  static ParsedProductAmount? _parsedFromTitleMassTimesPack(
    String name, {
    required int packMultiplier,
  }) {
    final re = RegExp(
      r'(\d+(?:\.\d+)?)\s*(g|kg|ml|L|l)(?!당)\b',
      caseSensitive: false,
    );

    // Collect all valid matches grouped by unit type
    final gMatches = <double>[];
    final kgMatches = <double>[];
    final mlMatches = <double>[];
    final lMatches = <double>[];

    for (final m in re.allMatches(name)) {
      final v = double.tryParse(m.group(1)!) ?? 0;
      if (v <= 0) continue;
      final u = m.group(2)!.toLowerCase();
      if (u == 'kg') {
        if (v > _maxSaneKgInTitle) continue;
        kgMatches.add(v);
      } else if (u == 'g') {
        if (v > _maxSaneGInTitle) continue;
        gMatches.add(v);
      } else if (u == 'l') {
        if (v > _maxSaneLInTitle) continue;
        lMatches.add(v);
      } else if (u == 'ml') {
        if (v > _maxSaneMlInTitle) continue;
        mlMatches.add(v);
      }
    }

    // Determine the best gram value
    double bestG = 0;
    if (kgMatches.isNotEmpty && gMatches.isNotEmpty) {
      // Both kg and g present: check if kg is already the total (g × pack ≈ kg × 1000)
      final kgVal = kgMatches.last;
      final gVal = gMatches.last;
      final kgAsGrams = kgVal * 1000;
      if (packMultiplier > 1 &&
          (gVal * packMultiplier - kgAsGrams).abs() / kgAsGrams < 0.15) {
        // kg IS the pre-computed total — use it directly without multiplying
        bestG = kgAsGrams;
        // Override packMultiplier to 1 since kg already accounts for it
        return _buildMassResult(bestG, 1);
      }
      // Otherwise use the last g value as per-unit
      bestG = gVal;
    } else if (kgMatches.isNotEmpty) {
      bestG = kgMatches.last * 1000;
    } else if (gMatches.isNotEmpty) {
      bestG = gMatches.last;
    }

    // Determine the best ml value
    double bestMl = 0;
    if (lMatches.isNotEmpty && mlMatches.isNotEmpty) {
      final lVal = lMatches.last;
      final mlVal = mlMatches.last;
      final lAsMl = lVal * 1000;
      if (packMultiplier > 1 &&
          (mlVal * packMultiplier - lAsMl).abs() / lAsMl < 0.15) {
        bestMl = lAsMl;
        return _buildLiquidResult(bestMl, 1);
      }
      bestMl = mlVal;
    } else if (lMatches.isNotEmpty) {
      bestMl = lMatches.last * 1000;
    } else if (mlMatches.isNotEmpty) {
      bestMl = mlMatches.last;
    }

    if (bestG <= 0 && bestMl <= 0) return null;

    // If both mass and volume appear, prefer weight (g/kg) as net product amount.
    final useLiquid = bestMl > 0 && bestG <= 0;
    if (useLiquid) {
      return _buildLiquidResult(bestMl, packMultiplier);
    }
    return _buildMassResult(bestG, packMultiplier);
  }

  static ParsedProductAmount _buildMassResult(double baseG, int packMultiplier) {
    final rawTotalBase = baseG * packMultiplier;
    var displayG = rawTotalBase;
    var displayUnit = 'g';
    if (displayG >= 1000) {
      displayG /= 1000;
      displayUnit = 'kg';
    }
    final str = displayG % 1 == 0
        ? '${displayG.toInt()}'
        : displayG.toStringAsFixed(1);
    return ParsedProductAmount(
      label: '$str$displayUnit',
      rawAmount: rawTotalBase,
      rawUnit: normalizeUnit('g'),
    );
  }

  static ParsedProductAmount _buildLiquidResult(double baseMl, int packMultiplier) {
    final rawTotalBase = baseMl * packMultiplier;
    var display = rawTotalBase;
    var displayUnit = 'ml';
    if (display >= 1000) {
      display /= 1000;
      displayUnit = 'L';
    }
    final str = display % 1 == 0
        ? '${display.toInt()}'
        : display.toStringAsFixed(1);
    return ParsedProductAmount(
      label: '$str$displayUnit',
      rawAmount: rawTotalBase,
      rawUnit: normalizeUnit('ml'),
    );
  }

  /// Parse the actual total package amount from a product's name and optional
  /// [packageSize]/[packageUnit] metadata.  This is the single source of truth
  /// for the "담은 양" value — used by both the shopping-cart card display and
  /// the fridge 구매 column.
  ///
  /// [productName] — the full product name string (e.g. "흙대파 300g, 1개")
  /// [packageSize] / [packageUnit] — optional structured metadata from backend
  /// [fallbackLabel] — string returned as [label] when nothing is parseable
  static ParsedProductAmount parseProductAmount({
    required String productName,
    double? packageSize,
    String? packageUnit,
    String fallbackLabel = '',
  }) {
    final name = dedupeDuplicateMassTokensInProductName(productName);

    final eggParsed = _tryParseEggPackProductAmount(name);
    if (eggParsed != null) return eggParsed;

    bool reasonableTotal(double? raw, String? rawU) {
      if (raw == null || raw <= 0) return false;
      final u = (rawU ?? '').toLowerCase();
      if (u == 'g' || u == 'ml') return raw <= _maxReasonablePackTotalGrams;
      return true;
    }

    // 1) Title: take the largest plausible mass/volume token (not the first
    // "200g" from "200g당"), skip absurd single-token kg like "200kg", multiply
    // by the first valid 1–30 개/세트 (scan all matches so "100개 … 1개" works).
    final packMult = _firstValidPackMultiplier(name);
    final fromTitle = _parsedFromTitleMassTimesPack(
      name,
      packMultiplier: packMult,
    );
    if (fromTitle != null &&
        reasonableTotal(fromTitle.rawAmount, fromTitle.rawUnit)) {
      return fromTitle;
    }

    // 2) Backend packageSize — only if title did not yield a sane amount.
    final pkgUnit = packageUnit ?? '개';
    if (packageSize != null && packageSize > 0) {
      final packCount = _firstValidPackMultiplier(name);
      final isKg = pkgUnit.toLowerCase() == 'kg';
      final isL = pkgUnit.toLowerCase() == 'l';
      final rawUnit = isKg ? 'g' : isL ? 'ml' : pkgUnit;
      final rawTotal = packageSize *
          packCount *
          (isKg ? 1000 : isL ? 1000 : 1);

      if (reasonableTotal(rawTotal, rawUnit)) {
        var displayTotal = rawTotal;
        var displayUnit = pkgUnit;
        if ((pkgUnit == 'g' || pkgUnit == 'G') && displayTotal >= 1000) {
          displayTotal /= 1000;
          displayUnit = 'kg';
        } else if ((pkgUnit == 'ml' || pkgUnit == 'ML' || pkgUnit == 'mL') &&
            displayTotal >= 1000) {
          displayTotal /= 1000;
          displayUnit = 'L';
        }
        final str = displayTotal % 1 == 0
            ? '${displayTotal.toInt()}'
            : displayTotal.toStringAsFixed(1);
        return ParsedProductAmount(
          label: '$str$displayUnit',
          rawAmount: rawTotal,
          rawUnit: normalizeUnit(rawUnit),
        );
      }
    }

    // 3) Title again without pack multiplier (metadata was wrong).
    final fromTitleNoPack = _parsedFromTitleMassTimesPack(
      name,
      packMultiplier: 1,
    );
    if (fromTitleNoPack != null) return fromTitleNoPack;

    return ParsedProductAmount(label: fallbackLabel);
  }
}
