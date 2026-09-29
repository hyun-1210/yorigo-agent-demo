import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/models/onboarding_profile.dart';
import 'package:yorigo/services/coupang_service.dart';
import 'package:yorigo/utils/onboarding_personalization.dart';

Map<String, dynamic> _recipe({
  String title = '김치찌개',
  List<String> tags = const [],
  List<String> ingredients = const [],
  List<String>? main,
  List<String>? sub,
}) {
  return <String, dynamic>{
    'id': title,
    'title': title,
    'tags': tags,
    'categories': {
      if (main != null) 'main_ingredient': main,
      if (sub != null) 'main_ingredient_sub': sub,
    },
    'recipe': {
      'title': title,
      'ingredients': [
        for (final item in ingredients) <String, dynamic>{'item': item},
      ],
    },
  };
}

CoupangProduct _product({
  required String id,
  String tag = '',
  bool rocket = false,
  double? volume,
  double? unitPrice,
  int price = 5000,
  int reviews = 10,
  double? valueScore,
}) {
  return CoupangProduct(
    productId: id,
    productName: id,
    productPrice: price,
    productImage: '',
    productUrl: '',
    isRocket: rocket,
    tag: tag,
    volumeG: volume,
    unitPrice: unitPrice,
    reviews: reviews,
    valueScore: valueScore,
  );
}

void main() {
  group('home section boosts', () {
    test('child meal and protein move matching rails first', () {
      final profile = OnboardingProfile(
        cooksForChild: true,
        householdSize: '3_4',
        favoriteCuisines: ['high_protein', 'dessert'],
      );
      expect(boostedHomeSectionKeys(profile), [
        'baby_food',
        'high_protein',
        'dessert',
      ]);

      const order = [
        'sauce',
        'dessert',
        'baby_food',
        'quick_10min',
        'high_protein',
      ];
      final boosted = applyHomeSectionBoosts<String>(
        sections: order,
        profile: profile,
        keyOf: (key) => key,
      );
      expect(boosted, [
        'baby_food',
        'high_protein',
        'dessert',
        'sauce',
        'quick_10min',
      ]);
    });

    test('child plus chinese western raise those rails first', () {
      final profile = OnboardingProfile(
        cooksForChild: true,
        householdSize: '3_4',
        favoriteCuisines: ['chinese', 'western'],
      );
      expect(boostedHomeSectionKeys(profile), [
        'baby_food',
        'onboarding_country_chinese',
        'onboarding_country_western',
      ]);
      final boosted = applyHomeSectionBoosts<String>(
        sections: const [
          'sauce',
          'dessert',
          'baby_food',
          'onboarding_country_chinese',
          'onboarding_country_western',
        ],
        profile: profile,
        keyOf: (key) => key,
      );
      expect(boosted, [
        'baby_food',
        'onboarding_country_chinese',
        'onboarding_country_western',
        'sauce',
        'dessert',
      ]);
    });

    test('late night inserts a second moment row', () {
      final profile = OnboardingProfile(favoriteCuisines: ['late_night']);
      expect(wantsExtraLateNightSection(profile), isTrue);
      final boosted = applyHomeSectionBoosts<String>(
        sections: const ['sauce', 'moment_dinner', 'comfort_bowl'],
        profile: profile,
        keyOf: (key) => key,
        extraLateNight: 'moment_late_night',
      );
      expect(boosted, [
        'moment_late_night',
        'sauce',
        'moment_dinner',
        'comfort_bowl',
      ]);
      expect(boosted, contains('moment_dinner'));
    });

    test('korean boost moves soup rail first and keeps dessert', () {
      final profile = OnboardingProfile(favoriteCuisines: ['korean']);
      final boosted = applyHomeSectionBoosts<String>(
        sections: const ['dessert', 'comfort_bowl', 'world_cup'],
        profile: profile,
        keyOf: (key) => key,
      );
      expect(boosted, ['comfort_bowl', 'dessert', 'world_cup']);
    });

    test('spicy boosts anju rail after pinned dessert', () {
      final profile = OnboardingProfile(favoriteCuisines: ['spicy']);
      expect(boostedHomeSectionKeys(profile), ['world_cup']);
      final boosted = applyHomeSectionBoosts<String>(
        sections: const ['sauce', 'dessert', 'baby_food', 'world_cup'],
        profile: profile,
        keyOf: (key) => key,
      );
      expect(boosted, ['world_cup', 'sauce', 'dessert', 'baby_food']);
    });

    test('korean soup rail moves ahead of pinned trending', () {
      final profile = OnboardingProfile(favoriteCuisines: ['korean']);
      final boosted = applyHomeSectionBoosts<String>(
        sections: const [
          'sauce',
          'dessert',
          'trending_now',
          'baby_food',
          'quick_10min',
          'comfort_bowl',
        ],
        profile: profile,
        keyOf: (key) => key,
      );
      expect(boosted, [
        'comfort_bowl',
        'sauce',
        'dessert',
        'trending_now',
        'baby_food',
        'quick_10min',
      ]);
    });
  });

  group('country chips', () {
    test('favorite countries move to the front', () {
      final filters = [
        {'label': '한식'},
        {'label': '양식'},
        {'label': '일식'},
        {'label': '중식'},
      ];
      final profile = OnboardingProfile(
        favoriteCuisines: ['japanese', 'western'],
      );
      expect(
        reorderCountryFilters(filters, profile).map((e) => e['label']),
        ['일식', '양식', '한식', '중식'],
      );
    });
  });

  group('home hide', () {
    test('pork stew is hidden but stays identifiable for search callers', () {
      final profile = OnboardingProfile(dietRestrictions: ['pork']);
      final stew = _recipe(title: '돼지고기김치찌개', ingredients: ['돼지고기', '김치']);
      expect(recipeHiddenOnHome(stew, profile), isTrue);
      expect(recipeHiddenOnHome(_recipe(title: '두부김치찌개'), profile), isFalse);
    });

    test('육류 restriction keeps seafood', () {
      final profile = OnboardingProfile(dietRestrictions: ['vegetarian']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '치킨무', ingredients: ['닭고기'], main: ['육류']),
          profile,
        ),
        isTrue,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '새우볶음', ingredients: ['새우'], main: ['해산물']),
          profile,
        ),
        isFalse,
      );
    });

    test('동물성 restriction drops egg and milk', () {
      final profile = OnboardingProfile(dietRestrictions: ['vegan']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '계란말이', ingredients: ['계란']),
          profile,
        ),
        isTrue,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '두부조림', ingredients: ['두부', '간장']),
          profile,
        ),
        isFalse,
      );
    });

    test('mild spice uses existing cheongyang rule', () {
      final profile = OnboardingProfile(dietRestrictions: ['mild_spice']);
      expect(
        recipeHiddenOnHome(
          _recipe(
            title: '매운짜글이',
            tags: ['매콤'],
            ingredients: ['청양고추'],
          ),
          profile,
        ),
        isTrue,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '된장찌개', ingredients: ['된장']),
          profile,
        ),
        isFalse,
      );
    });

    test('allergen needles hide shrimp from home', () {
      final profile = OnboardingProfile(avoidedIngredients: ['crustacean']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '감바스', ingredients: ['새우', '마늘']),
          profile,
        ),
        isTrue,
      );
    });

    test('mini docs hide pork and egg from categories only', () {
      final porkProfile = OnboardingProfile(dietRestrictions: ['pork']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '김치찌개', sub: ['돼지고기']),
          porkProfile,
        ),
        isTrue,
      );
      final eggProfile = OnboardingProfile(avoidedIngredients: ['egg']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '이유식', main: ['난류']),
          eggProfile,
        ),
        isTrue,
      );
    });

    test('milk restriction keeps soy milk', () {
      final profile = OnboardingProfile(avoidedIngredients: ['milk']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '두유라떼', ingredients: ['두유']),
          profile,
        ),
        isFalse,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '우유죽', ingredients: ['우유']),
          profile,
        ),
        isTrue,
      );
    });

    test('pork restriction does not hide hamburger by ham substring', () {
      final profile = OnboardingProfile(dietRestrictions: ['pork']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '햄버거스테이크', ingredients: ['소고기']),
          profile,
        ),
        isFalse,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '햄김치볶음', ingredients: ['햄', '김치']),
          profile,
        ),
        isTrue,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '항정살구이', ingredients: ['항정살']),
          profile,
        ),
        isTrue,
      );
    });

    test('pork restriction keeps potato with 돼지 substring', () {
      final profile = OnboardingProfile(dietRestrictions: ['pork']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '돼지감자볶음', ingredients: ['돼지감자']),
          profile,
        ),
        isFalse,
      );
    });

    test('milk restriction keeps plant milks', () {
      final profile = OnboardingProfile(avoidedIngredients: ['milk']);
      expect(
        recipeHiddenOnHome(
          _recipe(title: '코코넛밀크커리', ingredients: ['코코넛밀크']),
          profile,
        ),
        isFalse,
      );
      expect(
        recipeHiddenOnHome(
          _recipe(title: '밀크티', ingredients: ['밀크', '홍차']),
          profile,
        ),
        isTrue,
      );
    });
  });

  group('product ranking', () {
    test('rocket beats unit-price tag when delivery is first', () {
      final profile = OnboardingProfile(shoppingPriorities: ['fast_delivery']);
      final slowCheap = _product(
        id: 'cheap',
        tag: '단가 낮은, 가성비 최고',
        unitPrice: 100,
        valueScore: 0.04,
      );
      final rocket = _product(
        id: 'rocket',
        tag: '가성비 최고',
        rocket: true,
        unitPrice: 180,
        valueScore: 0.02,
      );
      final sorted = sortProductsForOnboarding([slowCheap, rocket], profile);
      expect(sorted.first.productId, 'rocket');
    });

    test('1인분 demotes bulk packs', () {
      final profile = OnboardingProfile(householdSize: '1');
      final bulk = _product(
        id: 'bulk',
        tag: '대용량, 가성비 최고',
        volume: 2000,
      );
      final small = _product(
        id: 'small',
        tag: '딱 필요한 양',
        volume: 200,
      );
      final sorted = sortProductsForOnboarding([bulk, small], profile);
      expect(sorted.first.productId, 'small');
    });

    test('household 1 wins over bulk shopping style', () {
      final profile = OnboardingProfile(
        householdSize: '1',
        shoppingStyle: 'bulk',
      );
      expect(shouldRerankProductBestMatch(profile), isTrue);
      final bulk = _product(id: 'bulk', tag: '대용량', volume: 3000);
      final close = _product(id: 'close', tag: '딱 필요한 양', volume: 250);
      final sorted = sortProductsForOnboarding([bulk, close], profile);
      expect(sorted.first.productId, 'close');
    });

    test('price-only ranks sticker price ahead of close-amount tag', () {
      final profile = OnboardingProfile(shoppingPriorities: ['price']);
      final close = _product(id: 'close', price: 9000, tag: '딱 필요한 양');
      final cheap = _product(id: 'cheap', price: 2000, tag: '단가 낮은');
      final sorted = sortProductsForOnboarding([close, cheap], profile);
      expect(sorted.first.productId, 'cheap');
    });

    test('bulk style promotes large packs over close-amount', () {
      final profile = OnboardingProfile(
        householdSize: '5_plus',
        shoppingStyle: 'bulk',
      );
      final bulk = _product(id: 'bulk', tag: '대용량', volume: 3000);
      final close = _product(id: 'close', tag: '딱 필요한 양', volume: 250);
      final sorted = sortProductsForOnboarding([bulk, close], profile);
      expect(sorted.first.productId, 'bulk');
    });

    test('price-only does not replace coupang best match', () {
      final profile = OnboardingProfile(shoppingPriorities: ['price']);
      expect(hasProductPersonalization(profile), isTrue);
      expect(shouldRerankProductBestMatch(profile), isFalse);

      final cheap = _product(id: 'cheap', price: 2000, tag: '단가 낮은');
      final close = _product(id: 'close', price: 9000, tag: '딱 필요한 양');
      final rec = ProductRecommendation(
        ingredient: '양파',
        bestMatch: cheap,
        seeMoreList: [cheap, close],
      );
      final applied = applyOnboardingToRecommendation(
        rec,
        profile: profile,
        isCoupang: true,
      );
      expect(applied.bestMatch?.productId, 'cheap');
    });

    test('kurly best match follows personalized list', () {
      final profile = OnboardingProfile(shoppingPriorities: ['reviews']);
      final quiet = _product(id: 'quiet', reviews: 2, tag: '가성비 최고');
      final popular = _product(id: 'popular', reviews: 800, tag: '많이 산');
      final rec = ProductRecommendation(
        ingredient: '우유',
        bestMatch: quiet,
        seeMoreList: [quiet, popular],
      );
      final applied = applyOnboardingToRecommendation(
        rec,
        profile: profile,
        isCoupang: false,
      );
      expect(applied.bestMatch?.productId, 'popular');
    });
  });
}
