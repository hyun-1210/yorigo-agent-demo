import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/models/onboarding_profile.dart';

void main() {
  group('OnboardingProfile.fromMap', () {
    test('reads nested onboarding and top-level name', () {
      final profile = OnboardingProfile.fromMap({
        'name': '민지',
        'gender': 'female',
        'onboarding': {
          'ageGroup': 'twenties',
          'cookingFrequency': 'few_times_week',
          'householdSize': '2',
          'favoriteCuisines': ['home', 'simple', 'unknown_drop'],
          'avoidedIngredients': ['none', 'unknown'],
          'recipeSources': ['youtube', 'notes', 'unknown'],
          'preferredMarketplaces': ['coupang', 'ssg'],
          'shoppingStyle': 'value',
        },
      });

      expect(profile.displayName, '민지');
      expect(profile.gender, 'female');
      expect(profile.ageGroup, 'twenties');
      expect(profile.cookingFrequency, 'few_times_week');
      expect(profile.householdSize, '2');
      expect(profile.favoriteCuisines, ['home', 'simple']);
      expect(profile.avoidedIngredients, ['none']);
      expect(profile.recipeSources, ['youtube', 'notes']);
      expect(profile.preferredMarketplaces, ['coupang', 'ssg']);
      expect(profile.preferredMarketplace, 'coupang');
      expect(profile.shoppingStyle, 'value');
      expect(profile.cooksForChild, isNull);
    });

    test('migrates old child household to family plus child meal', () {
      final profile = OnboardingProfile.fromMap({
        'householdSize': 'child',
      });
      expect(profile.householdSize, '3_4');
      expect(profile.cooksForChild, isTrue);
    });

    test('keeps child meal only for family-sized households', () {
      final profile = OnboardingProfile.fromMap({
        'householdSize': '1',
        'cooksForChild': true,
      });
      expect(profile.householdSize, '1');
      expect(profile.cooksForChild, isFalse);
    });

    test('allows child meal follow-up for two servings', () {
      expect(OnboardingProfile.offersChildMealFollowUp('2'), isTrue);
      final profile = OnboardingProfile.fromMap({
        'householdSize': '2',
        'cooksForChild': true,
      });
      expect(profile.cooksForChild, isTrue);
    });

    test('persists shopping priorities', () {
      final profile = OnboardingProfile.fromMap({
        'shoppingPriorities': ['price', 'freshness', 'unknown'],
      });
      expect(profile.shoppingPriorities, ['price', 'freshness']);
      expect(
        OnboardingProfile.fromMap(profile.toMap()).shoppingPriorities,
        ['price', 'freshness'],
      );
    });

    test('persists diet other text', () {
      final profile = OnboardingProfile.fromMap({
        'dietRestrictions': ['other'],
        'dietOther': '양파, 고수',
      });
      expect(profile.dietRestrictions, ['other']);
      expect(profile.dietOther, '양파, 고수');
      expect(OnboardingProfile.fromMap(profile.toMap()).dietOther, '양파, 고수');
    });

    test('falls back to single marketplace', () {
      final profile = OnboardingProfile.fromMap({
        'preferredMarketplace': 'kurly',
      });
      expect(profile.preferredMarketplaces, ['kurly']);
      expect(profile.preferredMarketplace, 'kurly');
    });

    test('accepts bracket age groups', () {
      final profile = OnboardingProfile.fromMap({'ageGroup': '14_17'});
      expect(profile.ageGroup, '14_17');
      expect(
        OnboardingProfile.fromMap({'ageGroup': '65_plus'}).ageGroup,
        '65_plus',
      );
    });

    test('drops invalid ids and empty name', () {
      final profile = OnboardingProfile.fromMap({
        'displayName': '   ',
        'gender': 'alien',
        'ageGroup': '100대',
        'favoriteCuisines': ['한식', 'home', 'home'],
      });

      expect(profile.displayName, isNull);
      expect(profile.gender, isNull);
      expect(profile.ageGroup, isNull);
      expect(profile.favoriteCuisines, ['home']);
    });
  });

  group('OnboardingProfile persistence', () {
    test('toUserDocUpdates denormalizes name gender marketplace', () {
      final profile = OnboardingProfile(
        displayName: '준호',
        gender: 'male',
        preferredMarketplaces: ['kurly', 'oasis'],
        favoriteCuisines: ['home'],
      );

      final updates = profile.toUserDocUpdates();
      expect(updates['name'], '준호');
      expect(updates['gender'], 'male');
      expect(updates['preferredMarketplace'], 'kurly');
      expect(updates.containsKey('handle'), isFalse);
      expect(updates['onboarding'], isA<Map<String, dynamic>>());
      expect((updates['onboarding'] as Map)['displayName'], '준호');
      expect((updates['onboarding'] as Map)['preferredMarketplaces'], [
        'kurly',
        'oasis',
      ]);
    });

    test('round-trips through toMap', () {
      final original = OnboardingProfile(
        displayName: '하늘',
        handle: 'sweet_ramen831',
        ageGroup: 'thirties',
        cookingFrequency: 'daily',
        householdSize: '5_plus',
        cooksForChild: true,
        favoriteCuisines: ['baking', 'healthy'],
        avoidedIngredients: ['milk', 'nuts'],
        recipeSources: ['instagram', 'screenshot'],
        preferredMarketplaces: ['offline'],
        shoppingPriorities: ['price', 'brand'],
      );
      final restored = OnboardingProfile.fromMap(original.toMap());
      expect(restored.displayName, '하늘');
      expect(restored.handle, 'sweet_ramen831');
      expect(restored.ageGroup, 'thirties');
      expect(restored.cookingFrequency, 'daily');
      expect(restored.householdSize, '5_plus');
      expect(restored.cooksForChild, isTrue);
      expect(restored.favoriteCuisines, ['baking', 'healthy']);
      expect(restored.avoidedIngredients, ['milk', 'nuts']);
      expect(restored.recipeSources, ['instagram', 'screenshot']);
      expect(restored.preferredMarketplaces, ['offline']);
      expect(restored.shoppingPriorities, ['price', 'brand']);
    });

    test('persistHandle writes handle and household to the user doc', () {
      final profile = OnboardingProfile(
        displayName: '하늘',
        handle: 'sweet_ramen831',
        householdSize: '3_4',
        cooksForChild: true,
      );
      final updates = profile.toUserDocUpdates(persistHandle: true);
      expect(updates['handle'], 'sweet_ramen831');
      expect(updates['householdSize'], '3_4');
      expect(updates['cooksForChild'], isTrue);
      expect(profile.householdServings, 4);
    });
  });

  group('OnboardingProfile guide copy', () {
    test('personalizes titles from answers', () {
      final profile = OnboardingProfile(
        displayName: '수아',
        cookingFrequency: 'few_times_week',
        householdSize: '2',
        favoriteCuisines: ['home', 'spicy'],
        recipeSources: ['youtube'],
        preferredMarketplaces: ['coupang'],
        shoppingStyle: 'bulk',
        goals: ['save_money'],
      );

      expect(profile.greetingName, '수아님');
      expect(profile.profileGuideTitle(), contains('수아님'));
      expect(profile.cookingGuideTitle(), contains('주 2–4회'));
      expect(profile.cookingGuideTitle(), contains('2인분'));
      expect(profile.tasteGuideTitle(), contains('집밥'));
      expect(profile.commerceGuideTitle(), contains('쿠팡'));
      expect(profile.answeredCount, 8);
      expect(profile.persona.id, 'smart_shopper');
    });

    test('uses fallback copy when unanswered', () {
      final empty = OnboardingProfile();
      expect(empty.profileGuideTitle(), '이제 요리고를 맞춰둘게요');
      expect(empty.tasteGuideTitle(), '취향은 쓰면서 더 정확해져요');
      expect(empty.answeredCount, 0);
      expect(empty.persona.id, 'curious_eater');
    });

    test('keeps legacy goal ids readable', () {
      final profile = OnboardingProfile.fromMap({
        'goals': ['meal_plan', 'enjoy', 'organize'],
      });
      expect(profile.goals, ['meal_plan', 'enjoy', 'organize']);
    });

    test('omits greeting when name is empty', () {
      expect(OnboardingProfile().greetingName, isEmpty);
    });

    test('reads goals and derives planner persona', () {
      final profile = OnboardingProfile.fromMap({
        'goals': ['save_time', 'unknown'],
        'cookingFrequency': 'daily',
      });
      expect(profile.goals, ['save_time']);
      expect(profile.persona.id, 'home_planner');
      expect(profile.answeredCount, 2);
    });
  });

  group('OnboardingProfile choices', () {
    test('keeps gender to female and male', () {
      expect(
        OnboardingProfile.genderChoices.map((c) => c.id).toList(),
        ['female', 'male'],
      );
    });

    test('exposes grouped question catalogs', () {
      expect(OnboardingProfile.ageGroupChoices.map((c) => c.id), [
        '14_17',
        '18_24',
        '25_34',
        '35_44',
        '45_54',
        '55_64',
        '65_plus',
      ]);
      expect(OnboardingProfile.ageGroupChoices.map((c) => c.label), [
        '18세 미만',
        '18~24',
        '25~34',
        '35~44',
        '45~54',
        '55~64',
        '65세 이상',
      ]);
      expect(OnboardingProfile.householdSizeChoices.map((c) => c.id), [
        '1',
        '2',
        '3_4',
        '5_plus',
      ]);
      expect(OnboardingProfile.childMealYesNoChoices.map((c) => c.id), [
        'yes',
        'no',
      ]);
      expect(OnboardingProfile.householdSizeChoices.map((c) => c.label), [
        '1인분',
        '2인분',
        '3~4인분',
        '5인분 이상',
      ]);
      expect(OnboardingProfile.cuisineChoices.map((c) => c.id), [
        'home',
        'korean',
        'western',
        'chinese',
        'japanese',
        'simple',
        'healthy',
        'diet',
        'high_protein',
        'soup',
        'spicy',
        'light',
        'late_night',
        'dessert',
        'baking',
      ]);
      expect(OnboardingProfile.avoidedIngredientChoices.first.id, 'none');
      expect(
        OnboardingProfile.avoidedIngredientChoices.map((c) => c.id),
        contains('other'),
      );
      expect(OnboardingProfile.dietRestrictionChoices.map((c) => c.label), [
        '해당 없음',
        '돼지고기',
        '소고기',
        '육류',
        '동물성 식품',
        '매운 음식',
        '기타',
      ]);
      expect(OnboardingProfile.dietRestrictionChoices.map((c) => c.id), [
        'none',
        'pork',
        'beef',
        'vegetarian',
        'vegan',
        'mild_spice',
        'other',
      ]);
      expect(OnboardingProfile.marketplaceChoices.map((c) => c.id), [
        'coupang',
        'kurly',
        'oasis',
        'ssg',
        'emart',
        'uglyus',
        'naver_shopping',
        'costco',
        'offline',
      ]);
      expect(OnboardingProfile.goalChoices.map((c) => c.id), [
        'organize',
        'variety',
        'decide_today',
        'leftovers',
        'shop_easier',
        'save_money',
        'share_cook',
      ]);
      expect(OnboardingProfile.recipeGoalChoices.map((c) => c.id), [
        'organize',
        'variety',
      ]);
      expect(OnboardingProfile.livingGoalChoices.map((c) => c.id), [
        'decide_today',
        'leftovers',
        'shop_easier',
        'save_money',
        'share_cook',
      ]);
      expect(OnboardingProfile.shoppingPriorityChoices.map((c) => c.id), [
        'price',
        'fast_delivery',
        'freshness',
        'small_qty',
        'reviews',
        'brand',
      ]);
      expect(OnboardingProfile.shoppingPriorityChoices.map((c) => c.label), [
        '가격',
        '배송 속도',
        '품질·신선도',
        '소량 구매',
        '상품 후기',
        '익숙한 브랜드',
      ]);
      expect(OnboardingProfile.cookingFrequencyChoices.map((c) => c.label), [
        '주 0–1회',
        '주 2–4회',
        '주 5–7회',
      ]);
      expect(OnboardingProfile.cookingSkillChoices.map((c) => c.id), [
        'beginner',
        'learning',
        'confident',
        'enthusiast',
      ]);
      expect(OnboardingProfile.cookingSkillChoices.map((c) => c.label), [
        '이제 시작해요',
        '간단한 건 해요',
        '웬만한 요리는 해요',
        '어려운 요리도 자신 있어요',
      ]);
      expect(OnboardingProfile.recipeSourceChoices.map((c) => c.id), [
        'youtube',
        'instagram',
        'tiktok',
        'naver_blog',
        'mango',
        'website',
        'cookbook',
        'friend',
      ]);
      expect(
        OnboardingProfile.labelFor('website', OnboardingProfile.recipeSourceChoices),
        '기타 요리 사이트',
      );
      expect(
        OnboardingProfile.labelFor('friend', OnboardingProfile.recipeSourceChoices),
        '지인 추천',
      );
    });
  });

  group('OnboardingDecision', () {
    test('hides onboarding after it has been completed', () {
      expect(
        OnboardingDecision.needsOnboarding({
          'onboardingCompletedAt': '2026-09-15',
          'name': '민지',
          'handle': 'minji',
        }),
        isFalse,
      );
    });

    test('shows onboarding to a just-signed-up user', () {
      expect(
        OnboardingDecision.needsOnboarding({
          'onboardingRequired': true,
          'name': '귀여운감자',
          'handle': 'cute_potato',
        }),
        isTrue,
      );
      expect(
        OnboardingDecision.skipNickname({
          'onboardingRequired': true,
          'name': '귀여운감자',
        }),
        isFalse,
      );
    });

    test('shows remaining onboarding to existing members without nickname', () {
      expect(
        OnboardingDecision.needsOnboarding({
          'name': '수아',
          'handle': 'sua_kim',
        }),
        isTrue,
      );
      expect(
        OnboardingDecision.skipNickname({
          'name': '수아',
          'handle': 'sua_kim',
        }),
        isTrue,
      );
    });

    test('does not trap incomplete signups', () {
      expect(OnboardingDecision.needsOnboarding(null), isFalse);
      expect(
        OnboardingDecision.needsOnboarding({'name': '임시'}),
        isFalse,
      );
      expect(OnboardingDecision.skipNickname({'name': ''}), isFalse);
    });

    test('stamps onboardingRequired only for new signups', () {
      expect(
        OnboardingDecision.shouldStampOnboardingRequired(
          isSocialSignup: false,
          isNewUser: false,
        ),
        isTrue,
      );
      expect(
        OnboardingDecision.shouldStampOnboardingRequired(
          isSocialSignup: true,
          isNewUser: true,
        ),
        isTrue,
      );
      expect(
        OnboardingDecision.shouldStampOnboardingRequired(
          isSocialSignup: true,
          isNewUser: false,
        ),
        isFalse,
      );
    });

    test('resumes the saved step and falls back when nickname is skipped', () {
      const steps = [
        'nickname',
        'profile',
        'goals',
        'taste',
      ];
      expect(
        OnboardingDecision.restoreStepIndex(
          stepNames: steps,
          savedStepId: 'taste',
        ),
        3,
      );
      expect(
        OnboardingDecision.restoreStepIndex(
          stepNames: ['profile', 'goals', 'taste'],
          savedStepId: 'nickname',
        ),
        0,
      );
      expect(
        OnboardingDecision.restoreStepIndex(
          stepNames: steps,
          savedStepId: null,
        ),
        0,
      );
    });
  });
}
