import 'package:flutter/material.dart';

/// Ingredient grouping unifier for UI consistency across:
/// - 레시피 상세(재료 탭)
/// - 장바구니
/// - 냉장고
///
/// New backend categories (vegetables_fruits, meat_processed_egg, seafood,
/// dairy, grains, seasonings_sauces) map 1:1 to UI groups.
/// Keyword fallbacks are retained for legacy recipes parsed under the old
/// 5-category system (protein, room_temperature, etc.).
class IngredientCategoryUnifier {
  // UI group keys (stable internal identifiers for grouping + icons).
  static const String vegFruit = 'veg_fruit';
  static const String meatProcessedEgg = 'meat_processed_egg';
  static const String seafood = 'seafood';
  static const String dairy = 'dairy';
  static const String grains = 'grains';
  static const String seasoningsSauces = 'seasonings_sauces';

  static const List<String> groupOrder = <String>[
    meatProcessedEgg,
    seafood,
    vegFruit,
    dairy,
    grains,
    seasoningsSauces,
  ];

  static String titleFromKey(String key) {
    switch (key) {
      case vegFruit:
        return '채소·과일·두부';
      case meatProcessedEgg:
        return '정육·가공육';
      case seafood:
        return '수산·해산·건어물';
      case dairy:
        return '유제품·달걀';
      case grains:
        return '쌀·면·곡물';
      case seasoningsSauces:
        return '양념·소스·가루';
      default:
        return '양념·소스·가루';
    }
  }

  /// Emoji used to represent each ingredient group. Emojis read more naturally
  /// for food/produce categories than Material Icons.
  static String emojiFromKey(String key) {
    switch (key) {
      case meatProcessedEgg:
        return '🥩';
      case seafood:
        return '🐟';
      case vegFruit:
        return '🥬';
      case dairy:
        return '🥚';
      case grains:
        return '🌾';
      case seasoningsSauces:
        return '🍶';
      default:
        return '🥣';
    }
  }

  /// Returns a fallback Material icon and accent color for each group. The
  /// [color] is the canonical badge accent color and is still used by the UI
  /// even when rendering emoji.
  static (IconData, Color) iconFromKey(String key) {
    switch (key) {
      case meatProcessedEgg:
        return (Icons.outdoor_grill, const Color(0xFFB85450));
      case vegFruit:
        return (Icons.eco, const Color(0xFF6B9B6B));
      case seafood:
        return (Icons.set_meal, const Color(0xFF3B82F6));
      case dairy:
        return (Icons.egg_alt, const Color(0xFFE8B84A));
      case grains:
        return (Icons.rice_bowl, const Color(0xFF9A7B4F));
      case seasoningsSauces:
        return (Icons.water_drop, const Color(0xFF8D6E63));
      default:
        return (Icons.category, const Color(0xFF757575));
    }
  }

  /// Returns the accent color for a given category group. Used for badge
  /// backgrounds, text tints, etc.
  static Color colorFromKey(String key) => iconFromKey(key).$2;

  /// Builds the visual icon widget for a category. All groups now use a food
  /// emoji from [emojiFromKey] for a consistent friendly tone.
  static Widget buildCategoryIcon({
    required String key,
    required double size,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          emojiFromKey(key),
          style: TextStyle(fontSize: size * 0.95, height: 1.0),
        ),
      ),
    );
  }

  static bool _containsAny(String text, List<String> keywords) {
    for (final k in keywords) {
      if (text.contains(k)) return true;
    }
    return false;
  }

  // Direct mapping from new backend 6-group categories to UI group keys.
  static const _directMap = <String, String>{
    'vegetables_fruits': vegFruit,
    'meat_processed_egg': meatProcessedEgg,
    'seafood': seafood,
    'dairy': dairy,
    'grains': grains,
    'seasonings_sauces': seasoningsSauces,
  };

  // Legacy backend categories → best UI group.
  static const _legacyMap = <String, String>{
    'protein': meatProcessedEgg,
    'main': meatProcessedEgg,
    'sub': vegFruit,
    'sauce_msg': seasoningsSauces,
    'seasonings': seasoningsSauces,
    'dairy_eggs_refrigerated': dairy,
    'room_temperature': grains,
  };

  // Keyword lists for fallback heuristics (legacy data without aligned category).
  static const _eggKw = <String>['달걀', '계란', '메추리알', '에그'];
  static const _seafoodKw = <String>[
    '생선', '연어', '참치', '고등어', '새우', '오징어', '문어', '조개', '굴',
    '홍합', '게', '랍스터', '전복', '꽃게', '대구', '갈치', '삼치', '광어',
    '우럭', '멸치', '회', '낙지', '꼬막', '바지락', '소라', '성게',
    '건새우', '건어물', '마른새우', '북어', '황태', '쥐포',
    '다시마', '미역', '어묵', '장어',
  ];
  static const _dairyKw = <String>[
    '우유', '치즈', '요거트', '크림', '생크림', '버터', '마가린', '유제품',
    '케피어', '크림치즈',
    '달걀', '계란', '메추리알', '에그',
  ];
  static const _grainKw = <String>[
    '쌀', '밥', '현미', '흑미', '보리', '귀리', '기장', '밀가루',
    '면', '국수', '라면', '우동', '당면', '스파게티', '파스타', '메밀',
    '떡', '옥수수', '쌀국수', '소바',
  ];
  static const _seasonKw = <String>[
    '간장', '된장', '고추장', '쌈장', '굴소스', '참기름', '식초',
    '마요네즈', '케첩', '토마토소스', '소스', '양념', '고춧가루', '후추',
    '소금', '설탕', '다시다', '액젓', '물엿', '올리브유', '포도씨유',
    '김가루', '조미김', '김밥김',
  ];
  static const _tofuKw = <String>[
    '두부', '순두부', '연두부', '유부', '부침두부',
  ];
  static const _meatKw = <String>[
    '고기', '육', '돼지고기', '소고기', '닭', '오리', '양고기', '베이컨',
    '햄', '소시지', '스테이크', '갈비', '훈제', '차돌', '불고기', '육회',
    '제육', '수육', '삼겹', '목살', '닭가슴살',
  ];

  static String groupKeyFromIngredient({
    required String? internalCategory,
    required String ingredientName,
  }) {
    final name = ingredientName.trim().toLowerCase();
    if (name.isEmpty) return seasoningsSauces;

    final internal = (internalCategory ?? '').trim().toLowerCase();

    // 1) Direct match for new 6-group categories (most new recipes).
    final direct = _directMap[internal];
    if (direct != null) return direct;

    // 2) Legacy category mapping with keyword overrides.
    if (_legacyMap.containsKey(internal)) {
      // Even with a legacy category, egg/seafood keywords override.
      if (_containsAny(name, _eggKw)) return dairy;
      if (_containsAny(name, _seafoodKw)) return seafood;

      if (internal == 'room_temperature') {
        if (_containsAny(name, _grainKw)) return grains;
        if (_containsAny(name, _seasonKw)) return seasoningsSauces;
        if (_containsAny(name, _dairyKw)) return dairy;
        if (_containsAny(name, _meatKw)) return meatProcessedEgg;
        return grains;
      }

      return _legacyMap[internal]!;
    }

    // 3) No recognized category — pure keyword fallback.
    // 김 exact match → seasoning (garnish), but 김치 is vegetable so we can't use substring.
    if (name == '김') return seasoningsSauces;
    if (_containsAny(name, _tofuKw)) return vegFruit;
    if (_containsAny(name, _eggKw)) return dairy;
    if (_containsAny(name, _seafoodKw)) return seafood;
    if (_containsAny(name, _grainKw)) return grains;
    if (_containsAny(name, _seasonKw)) return seasoningsSauces;
    if (_containsAny(name, _dairyKw)) return dairy;
    if (_containsAny(name, _meatKw)) return meatProcessedEgg;

    return vegFruit;
  }
}

