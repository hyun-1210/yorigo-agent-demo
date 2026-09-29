/// Signup onboarding answers. Stored under `users.onboarding` plus a few
/// top-level fields (`name`, `gender`, `preferredMarketplace`) for queries.
class OnboardingChoice {
  const OnboardingChoice({
    required this.id,
    required this.label,
    this.caption,
    this.emoji = '',
    this.iconAsset,
  });

  final String id;
  final String label;
  final String? caption;
  final String emoji;
  final String? iconAsset;
}

class OnboardingPersona {
  const OnboardingPersona({
    required this.id,
    required this.emoji,
    required this.title,
    required this.caption,
    required this.body,
    required this.keywords,
  });

  final String id;
  final String emoji;
  final String title;
  final String caption;
  final String body;
  final List<String> keywords;
}

class OnboardingProfile {
  OnboardingProfile({
    this.displayName,
    this.handle,
    this.gender,
    this.ageGroup,
    this.cookingFrequency,
    this.cookingSkill,
    this.householdSize,
    this.cooksForChild,
    List<String>? goals,
    List<String>? favoriteCuisines,
    List<String>? avoidedIngredients,
    List<String>? dietRestrictions,
    List<String>? recipeSources,
    List<String>? preferredMarketplaces,
    this.preferredMarketplace,
    this.shoppingStyle,
    this.avoidedOther,
    this.dietOther,
    List<String>? shoppingPriorities,
  })  : goals = List<String>.from(goals ?? const []),
        favoriteCuisines = List<String>.from(favoriteCuisines ?? const []),
        avoidedIngredients = List<String>.from(avoidedIngredients ?? const []),
        dietRestrictions = List<String>.from(dietRestrictions ?? const []),
        recipeSources = List<String>.from(recipeSources ?? const []),
        preferredMarketplaces = List<String>.from(
          preferredMarketplaces ??
              (preferredMarketplace == null
                  ? const []
                  : <String>[preferredMarketplace]),
        ),
        shoppingPriorities = List<String>.from(shoppingPriorities ?? const []) {
    if (this.preferredMarketplace == null &&
        this.preferredMarketplaces.isNotEmpty) {
      this.preferredMarketplace = this.preferredMarketplaces.first;
    }
  }

  String? displayName;
  String? handle;
  String? gender;
  String? ageGroup;
  String? cookingFrequency;
  String? cookingSkill;
  String? householdSize;
  bool? cooksForChild;
  List<String> goals;
  List<String> favoriteCuisines;
  List<String> avoidedIngredients;
  List<String> dietRestrictions;
  List<String> recipeSources;
  List<String> preferredMarketplaces;
  String? preferredMarketplace;
  String? shoppingStyle;
  String? avoidedOther;
  String? dietOther;
  List<String> shoppingPriorities;

  static const genderChoices = [
    OnboardingChoice(id: 'female', label: '여성'),
    OnboardingChoice(id: 'male', label: '남성'),
  ];

  static const ageGroupChoices = [
    OnboardingChoice(id: '14_17', label: '18세 미만'),
    OnboardingChoice(id: '18_24', label: '18~24'),
    OnboardingChoice(id: '25_34', label: '25~34'),
    OnboardingChoice(id: '35_44', label: '35~44'),
    OnboardingChoice(id: '45_54', label: '45~54'),
    OnboardingChoice(id: '55_64', label: '55~64'),
    OnboardingChoice(id: '65_plus', label: '65세 이상'),
  ];

  static const recipeGoalChoices = [
    OnboardingChoice(id: 'organize', label: 'SNS 레시피들\n한곳에 모으기'),
    OnboardingChoice(id: 'variety', label: '새로운 레시피 발견하기'),
  ];

  static const livingGoalChoices = [
    OnboardingChoice(id: 'decide_today', label: '오늘 뭐 먹을지\n쉽게 정하기'),
    OnboardingChoice(id: 'leftovers', label: '남은 재료 활용하기'),
    OnboardingChoice(id: 'shop_easier', label: '장보기 편하게 끝내기'),
    OnboardingChoice(id: 'save_money', label: '식비·배달비 줄이기'),
    OnboardingChoice(id: 'share_cook', label: '요리 기록하고 다른 사람과 공유하기'),
  ];

  static const goalChoices = [
    ...recipeGoalChoices,
    ...livingGoalChoices,
  ];

  static const cookingFrequencyChoices = [
    OnboardingChoice(id: 'rarely', label: '주 0–1회'),
    OnboardingChoice(id: 'few_times_week', label: '주 2–4회'),
    OnboardingChoice(id: 'daily', label: '주 5–7회'),
  ];

  static const cookingSkillChoices = [
    OnboardingChoice(id: 'beginner', label: '이제 시작해요'),
    OnboardingChoice(id: 'learning', label: '간단한 건 해요'),
    OnboardingChoice(id: 'confident', label: '웬만한 요리는 해요'),
    OnboardingChoice(id: 'enthusiast', label: '어려운 요리도 자신 있어요'),
  ];

  static const recipeSourceChoices = [
    OnboardingChoice(
      id: 'youtube',
      label: '유튜브',
      iconAsset: 'lib/assets/youtube-app-icon-hd.png',
    ),
    OnboardingChoice(
      id: 'instagram',
      label: '인스타그램',
      iconAsset: 'lib/assets/instagram-app-icon-hd.png',
    ),
    OnboardingChoice(
      id: 'tiktok',
      label: '틱톡',
      iconAsset: 'lib/assets/tiktok-app-icon-hd.png',
    ),
    OnboardingChoice(
      id: 'naver_blog',
      label: '네이버 블로그',
      iconAsset: 'assets/icons/naver_blog_icon.png',
    ),
    OnboardingChoice(id: 'mango', label: '만개의레시피'),
    OnboardingChoice(id: 'website', label: '기타 요리 사이트'),
    OnboardingChoice(id: 'cookbook', label: '요리책'),
    OnboardingChoice(id: 'friend', label: '지인 추천'),
  ];

  static const householdSizeChoices = [
    OnboardingChoice(id: '1', label: '1인분'),
    OnboardingChoice(id: '2', label: '2인분'),
    OnboardingChoice(id: '3_4', label: '3~4인분'),
    OnboardingChoice(id: '5_plus', label: '5인분 이상'),
  ];

  static const childMealYesNoChoices = [
    OnboardingChoice(id: 'yes', label: '예'),
    OnboardingChoice(id: 'no', label: '아니요'),
  ];

  static bool offersChildMealFollowUp(String? householdSize) {
    return householdSize == '2' ||
        householdSize == '3_4' ||
        householdSize == '5_plus';
  }

  static const cuisineChoices = [
    OnboardingChoice(id: 'home', label: '집밥'),
    OnboardingChoice(id: 'korean', label: '한식'),
    OnboardingChoice(id: 'western', label: '양식'),
    OnboardingChoice(id: 'chinese', label: '중식'),
    OnboardingChoice(id: 'japanese', label: '일식'),
    OnboardingChoice(id: 'simple', label: '간편식'),
    OnboardingChoice(id: 'healthy', label: '건강식'),
    OnboardingChoice(id: 'diet', label: '다이어트'),
    OnboardingChoice(id: 'high_protein', label: '고단백'),
    OnboardingChoice(id: 'soup', label: '국물·찌개'),
    OnboardingChoice(id: 'spicy', label: '자극적인'),
    OnboardingChoice(id: 'light', label: '담백한'),
    OnboardingChoice(id: 'late_night', label: '야식'),
    OnboardingChoice(id: 'dessert', label: '디저트'),
    OnboardingChoice(id: 'baking', label: '베이킹'),
  ];

  static const avoidedIngredientChoices = [
    OnboardingChoice(id: 'none', label: '해당 없음'),
    OnboardingChoice(id: 'crustacean', label: '갑각류', emoji: '🦐'),
    OnboardingChoice(id: 'egg', label: '달걀', emoji: '🥚'),
    OnboardingChoice(id: 'milk', label: '우유', emoji: '🥛'),
    OnboardingChoice(id: 'nuts', label: '견과류', emoji: '🥜'),
    OnboardingChoice(id: 'wheat', label: '밀', emoji: '🌾'),
    OnboardingChoice(id: 'soy', label: '대두', emoji: '🫘'),
    OnboardingChoice(id: 'fish', label: '생선', emoji: '🐟'),
    OnboardingChoice(id: 'peach', label: '복숭아', emoji: '🍑'),
    OnboardingChoice(id: 'other', label: '기타'),
  ];

  static const dietRestrictionChoices = [
    OnboardingChoice(id: 'none', label: '해당 없음'),
    OnboardingChoice(id: 'pork', label: '돼지고기'),
    OnboardingChoice(id: 'beef', label: '소고기'),
    OnboardingChoice(id: 'vegetarian', label: '육류'),
    OnboardingChoice(id: 'vegan', label: '동물성 식품'),
    OnboardingChoice(id: 'mild_spice', label: '매운 음식'),
    OnboardingChoice(id: 'other', label: '기타'),
  ];

  static const marketplaceChoices = [
    OnboardingChoice(
      id: 'coupang',
      label: '쿠팡',
      iconAsset: 'assets/marketplace/coupang_app_icon.png',
    ),
    OnboardingChoice(
      id: 'kurly',
      label: '컬리',
      iconAsset: 'assets/marketplace/kurly_app_icon.png',
    ),
    OnboardingChoice(
      id: 'oasis',
      label: '오아시스',
      iconAsset: 'assets/marketplace/oasis_logo.png',
    ),
    OnboardingChoice(
      id: 'ssg',
      label: 'SSG',
      iconAsset: 'assets/ssg_logo.png',
    ),
    OnboardingChoice(
      id: 'emart',
      label: '이마트몰',
      iconAsset: 'assets/emart_logo.png',
    ),
    OnboardingChoice(id: 'uglyus', label: '어글리어스'),
    OnboardingChoice(id: 'naver_shopping', label: '네이버스토어'),
    OnboardingChoice(id: 'costco', label: '코스트코'),
    OnboardingChoice(id: 'offline', label: '오프라인 장보기'),
  ];

  static const shoppingStyleChoices = [
    OnboardingChoice(id: 'bulk', label: '한 번에 왕창', emoji: '🛍️'),
    OnboardingChoice(id: 'as_needed', label: '필요할 때', emoji: '🧺'),
    OnboardingChoice(id: 'value', label: '가성비 위주', emoji: '🏷️'),
  ];

  static const shoppingPriorityChoices = [
    OnboardingChoice(id: 'price', label: '가격'),
    OnboardingChoice(id: 'fast_delivery', label: '배송 속도'),
    OnboardingChoice(id: 'freshness', label: '품질·신선도'),
    OnboardingChoice(id: 'small_qty', label: '소량 구매'),
    OnboardingChoice(id: 'reviews', label: '상품 후기'),
    OnboardingChoice(id: 'brand', label: '익숙한 브랜드'),
  ];

  static const _allowedGenders = {'female', 'male', 'other', 'prefer_not'};
  static const _allowedAgeGroups = {
    '14_17',
    '18_24',
    '25_34',
    '35_44',
    '45_54',
    '55_64',
    '65_plus',
    // 예전 10대 단위 구간. 이미 저장된 값만 유지한다.
    'teens',
    'twenties',
    'thirties',
    'forties',
    'fifties',
    'sixties_plus',
  };
  static const _allowedFrequencies = {
    'daily',
    'few_times_week',
    'weekends',
    'rarely',
  };
  static const _allowedHouseholds = {'1', '2', '3_4', '5_plus', 'child'};
  static const _allowedGoals = {
    'cook_more',
    'meal_plan',
    'find_recipes',
    'organize',
    'save_money',
    'shop_easier',
    'save_time',
    'health',
    'skill',
    'variety',
    'enjoy',
    'decide_today',
    'leftovers',
    'share_cook',
  };
  static const _allowedCuisines = {
    'korean',
    'chinese',
    'japanese',
    'western',
    'simple',
    'healthy',
    'spicy',
    'home',
    'diet',
    'baking',
    'soup',
    'dessert',
    'high_protein',
    'late_night',
    'light',
  };
  static const _allowedAvoided = {
    'none',
    'crustacean',
    'egg',
    'milk',
    'nuts',
    'wheat',
    'soy',
    'fish',
    'peach',
    'other',
  };
  static const _allowedDietRestrictions = {
    'none',
    'pork',
    'beef',
    'vegetarian',
    'vegan',
    'mild_spice',
    'other',
  };
  static const _allowedMarketplaces = {
    'coupang',
    'kurly',
    'ssg',
    'emart',
    'uglyus',
    'homeplus',
    'costco',
    'naver_shopping',
    'oasis',
    'offline',
    'any',
  };
  static const _allowedShoppingStyles = {'bulk', 'as_needed', 'value'};
  static const _allowedShoppingPriorities = {
    'price',
    'fast_delivery',
    'freshness',
    'small_qty',
    'brand',
    'reviews',
    'healthy',
    'usual_shop',
  };
  static const _allowedCookingSkills = {
    'beginner',
    'learning',
    'confident',
    'enthusiast',
  };
  static const _allowedRecipeSources = {
    'youtube',
    'instagram',
    'tiktok',
    'facebook',
    'naver_blog',
    'pinterest',
    'mango',
    'friend',
    'cookbook',
    'website',
    'notes',
    'screenshot',
    'safari',
    'threads',
    'self_dm',
    'friend_dm',
  };

  static String? labelFor(String? id, List<OnboardingChoice> choices) {
    if (id == null || id.isEmpty) return null;
    for (final choice in choices) {
      if (choice.id == id) return choice.label;
    }
    return null;
  }

  static String? _pickAllowed(String? raw, Set<String> allowed) {
    final value = raw?.trim();
    if (value == null || value.isEmpty || !allowed.contains(value)) {
      return null;
    }
    return value;
  }

  static String? _optionalText(dynamic raw) {
    final value = raw?.toString().trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static List<String> _pickList(dynamic raw, Set<String> allowed) {
    final values = <String>[];
    if (raw is! List) return values;
    for (final item in raw) {
      final id = _pickAllowed(item?.toString(), allowed);
      if (id != null && !values.contains(id)) values.add(id);
    }
    return values;
  }

  factory OnboardingProfile.fromMap(Map<String, dynamic>? raw) {
    if (raw == null) return OnboardingProfile();
    final nested = raw['onboarding'];
    final source = nested is Map
        ? <String, dynamic>{...raw, ...Map<String, dynamic>.from(nested)}
        : raw;

    final name = (source['displayName'] ?? source['name'])?.toString().trim();
    final handle = (source['handle'] ?? source['userId'])?.toString().trim();
    final marketplaces = _pickList(
      source['preferredMarketplaces'],
      _allowedMarketplaces,
    );
    final singleMarket = _pickAllowed(
      source['preferredMarketplace']?.toString(),
      _allowedMarketplaces,
    );
    final rawHousehold = _pickAllowed(
      source['householdSize']?.toString(),
      _allowedHouseholds,
    );
    final householdSize = rawHousehold == 'child' ? '3_4' : rawHousehold;
    return OnboardingProfile(
      displayName: (name == null || name.isEmpty) ? null : name,
      handle: (handle == null || handle.isEmpty) ? null : handle,
      gender: _pickAllowed(source['gender']?.toString(), _allowedGenders),
      ageGroup: _pickAllowed(source['ageGroup']?.toString(), _allowedAgeGroups),
      cookingFrequency: _pickAllowed(
        source['cookingFrequency']?.toString(),
        _allowedFrequencies,
      ),
      householdSize: householdSize,
      cooksForChild: () {
        if (!offersChildMealFollowUp(householdSize)) return false;
        if (rawHousehold == 'child' || source['cooksForChild'] == true) {
          return true;
        }
        if (source['cooksForChild'] == false) return false;
        return null;
      }(),
      cookingSkill: _pickAllowed(
        source['cookingSkill']?.toString(),
        _allowedCookingSkills,
      ),
      goals: _pickList(source['goals'], _allowedGoals),
      favoriteCuisines: _pickList(source['favoriteCuisines'], _allowedCuisines),
      avoidedIngredients: _pickList(
        source['avoidedIngredients'],
        _allowedAvoided,
      ),
      dietRestrictions: _pickList(
        source['dietRestrictions'],
        _allowedDietRestrictions,
      ),
      recipeSources: _pickList(source['recipeSources'], _allowedRecipeSources),
      preferredMarketplaces: marketplaces.isNotEmpty
          ? marketplaces
          : (singleMarket == null ? const [] : <String>[singleMarket]),
      preferredMarketplace: singleMarket,
      shoppingStyle: _pickAllowed(
        source['shoppingStyle']?.toString(),
        _allowedShoppingStyles,
      ),
      shoppingPriorities: _pickList(
        source['shoppingPriorities'],
        _allowedShoppingPriorities,
      ),
      avoidedOther: _optionalText(source['avoidedOther']),
      dietOther: _optionalText(source['dietOther']),
    );
  }

  Map<String, dynamic> toMap() {
    final markets = preferredMarketplaces.isNotEmpty
        ? preferredMarketplaces
        : (preferredMarketplace == null
            ? const <String>[]
            : <String>[preferredMarketplace!]);
    final primaryMarket =
        preferredMarketplace ?? (markets.isEmpty ? null : markets.first);
    return <String, dynamic>{
      if (displayName != null && displayName!.trim().isNotEmpty)
        'displayName': displayName!.trim(),
      if (handle != null && handle!.trim().isNotEmpty) 'handle': handle!.trim(),
      if (gender != null) 'gender': gender,
      if (ageGroup != null) 'ageGroup': ageGroup,
      if (cookingFrequency != null) 'cookingFrequency': cookingFrequency,
      if (cookingSkill != null) 'cookingSkill': cookingSkill,
      if (householdSize != null) 'householdSize': householdSize,
      if (cooksForChild != null) 'cooksForChild': cooksForChild,
      if (goals.isNotEmpty) 'goals': goals,
      if (favoriteCuisines.isNotEmpty) 'favoriteCuisines': favoriteCuisines,
      if (avoidedIngredients.isNotEmpty)
        'avoidedIngredients': avoidedIngredients,
      if (avoidedOther != null && avoidedOther!.trim().isNotEmpty)
        'avoidedOther': avoidedOther!.trim(),
      if (dietRestrictions.isNotEmpty) 'dietRestrictions': dietRestrictions,
      if (dietOther != null && dietOther!.trim().isNotEmpty)
        'dietOther': dietOther!.trim(),
      if (recipeSources.isNotEmpty) 'recipeSources': recipeSources,
      if (markets.isNotEmpty) 'preferredMarketplaces': markets,
      if (primaryMarket != null) 'preferredMarketplace': primaryMarket,
      if (shoppingStyle != null) 'shoppingStyle': shoppingStyle,
      if (shoppingPriorities.isNotEmpty) 'shoppingPriorities': shoppingPriorities,
      'personaId': persona.id,
    };
  }

  /// Nested `onboarding` plus denormalized fields used elsewhere.
  ///
  /// [persistHandle]는 신규 가입 온보딩에서만 true. 기존 회원 핸들을 덮지 않는다.
  Map<String, dynamic> toUserDocUpdates({bool persistHandle = false}) {
    final nested = toMap();
    final handleValue = handle?.trim() ?? '';
    return <String, dynamic>{
      'onboarding': nested,
      if (displayName != null && displayName!.trim().isNotEmpty)
        'name': displayName!.trim(),
      if (persistHandle && handleValue.isNotEmpty) 'handle': handleValue,
      if (gender != null) 'gender': gender,
      if (ageGroup != null) 'ageGroup': ageGroup,
      if (householdSize != null) 'householdSize': householdSize,
      if (cooksForChild != null) 'cooksForChild': cooksForChild,
      if (nested['preferredMarketplace'] != null)
        'preferredMarketplace': nested['preferredMarketplace'],
    };
  }

  /// 레시피 인분 기본값으로 쓸 숫자. GCS `recipeServings`와 맞춘다.
  int? get householdServings {
    switch (householdSize) {
      case '1':
        return 1;
      case '2':
        return 2;
      case '3_4':
        return 4;
      case '5_plus':
        return 5;
      default:
        return null;
    }
  }

  int get answeredCount {
    var count = 0;
    if (displayName != null && displayName!.trim().isNotEmpty) count++;
    if (gender != null) count++;
    if (ageGroup != null) count++;
    if (goals.isNotEmpty) count++;
    if (cookingFrequency != null) count++;
    if (cookingSkill != null) count++;
    if (householdSize != null) count++;
    if (cooksForChild == true) count++;
    if (favoriteCuisines.isNotEmpty) count++;
    if (avoidedIngredients.isNotEmpty) count++;
    if (dietRestrictions.isNotEmpty) count++;
    if (recipeSources.isNotEmpty) count++;
    if (preferredMarketplaces.isNotEmpty || preferredMarketplace != null) {
      count++;
    }
    if (shoppingStyle != null) count++;
    if (shoppingPriorities.isNotEmpty) count++;
    return count;
  }

  String get greetingName {
    final name = displayName?.trim() ?? '';
    if (name.isEmpty) return '';
    return name.endsWith('님') ? name : '$name님';
  }

  OnboardingPersona get persona {
    final shopHeavy =
        goals.contains('save_money') ||
        goals.contains('shop_easier') ||
        shoppingStyle == 'bulk' ||
        shoppingStyle == 'value';
    final planner =
        goals.contains('meal_plan') ||
        goals.contains('save_time') ||
        cookingFrequency == 'daily';
    final soloSimple =
        householdSize == '1' || favoriteCuisines.contains('simple');
    final homeCook =
        favoriteCuisines.contains('home') ||
        favoriteCuisines.contains('korean') ||
        goals.contains('cook_more') ||
        goals.contains('enjoy') ||
        goals.contains('skill');

    if (shopHeavy && !planner) {
      return const OnboardingPersona(
        id: 'smart_shopper',
        emoji: '🛒',
        title: '한 번에 담는 장보기 고수',
        caption: '이건 다 내 장바구니야',
        body: '레시피 재료를 바로 담고, 자주 쓰는 마켓에서 가격까지 비교하는 타입이에요.',
        keywords: ['장보기', '가성비', '한 번에'],
      );
    }
    if (planner) {
      return const OnboardingPersona(
        id: 'home_planner',
        emoji: '📅',
        title: '한 주를 미리 그리는 식단러',
        caption: '오늘 저녁은 이미 정해져 있어요',
        body: '식단 캘린더에 한 주를 담아두고, 요리한 날까지 자연스럽게 이어가는 타입이에요.',
        keywords: ['식단', '루틴', '미리'],
      );
    }
    if (soloSimple && !homeCook) {
      return const OnboardingPersona(
        id: 'solo_minimal',
        emoji: '🥄',
        title: '1인분 맞춤 미니멀 셰프',
        caption: '필요한 만큼만, 정확하게',
        body: '분량을 맞추고 있는 재료로 오늘 메뉴를 고르는, 군더더기 없는 타입이에요.',
        keywords: ['1인분', '간단', '냉장고'],
      );
    }
    if (homeCook) {
      return const OnboardingPersona(
        id: 'home_routine',
        emoji: '🏡',
        title: '집밥 루틴러',
        caption: '손이 가는 맛이 제일 좋아요',
        body: '집밥 취향을 홈 추천의 시작점으로 두고, 냉장고에 있는 재료로 오늘 메뉴를 정하는 타입이에요.',
        keywords: ['집밥', '추천', '오늘 메뉴'],
      );
    }
    return const OnboardingPersona(
      id: 'curious_eater',
      emoji: '✨',
      title: '메뉴 탐험가',
      caption: '오늘은 뭐가 당길까',
      body: '링크만 넣어도 레시피가 정리되고, 쓰다 보면 취향이 더 선명해지는 타입이에요.',
      keywords: ['탐색', '링크', '취향'],
    );
  }

  String profileGuideTitle() {
    final name = greetingName;
    if (name.isEmpty) return '이제 요리고를 맞춰둘게요';
    return '$name, 이렇게 불러드릴게요';
  }

  String profileGuideBody() {
    final genderLabel = labelFor(gender, genderChoices);
    if (genderLabel != null && gender != 'prefer_not') {
      return '홈에서 이 이름으로 인사하고, 비슷한 취향의 레시피를 먼저 보여드릴게요.';
    }
    return '홈 상단에서 이 이름으로 인사해요. 나중에 프로필에서 언제든 바꿀 수 있어요.';
  }

  String cookingGuideTitle() {
    final frequency = labelFor(cookingFrequency, cookingFrequencyChoices);
    final household = labelFor(householdSize, householdSizeChoices);
    if (frequency != null && household != null) {
      return '$frequency, $household 기준으로 맞춰둘게요';
    }
    if (household != null) {
      return '$household 분량으로 재료를 계산할게요';
    }
    if (frequency != null) {
      return '$frequency 요리에 맞춰 식단을 제안할게요';
    }
    return '식단과 분량은 나중에 맞춰도 돼요';
  }

  String cookingGuideBody() {
    return '식단 캘린더에 한 주를 미리 담고, 레시피 인분을 고른 인원에 맞게 바꿔드려요.';
  }

  String tasteGuideTitle() {
    final labels = favoriteCuisines
        .map((id) => labelFor(id, cuisineChoices))
        .whereType<String>()
        .toList();
    if (labels.isEmpty) return '취향은 쓰면서 더 정확해져요';
    if (labels.length == 1) return '${labels.first}부터 보여드릴게요';
    return '${labels.take(2).join('·')}을 시작점으로 둘게요';
  }

  String tasteGuideBody() {
    if (favoriteCuisines.isEmpty) {
      return '냉장고에 있는 재료로 오늘 메뉴를 고르면, 그 선택이 다음 추천에 반영돼요.';
    }
    return '홈 추천과 냉장고 메뉴에서 고른 취향을 먼저 보여드려요.';
  }

  String commerceGuideTitle() {
    final market = labelFor(preferredMarketplace, marketplaceChoices);
    if (preferredMarketplaces.length > 1) {
      return '${preferredMarketplaces.length}곳 장보기 기준으로 맞춰둘게요';
    }
    if (market != null) {
      return '재료는 $market에서 바로 담을 수 있어요';
    }
    return '레시피 재료를 바로 장바구니에 담아요';
  }

  String commerceGuideBody() {
    return '레시피에서 재료를 담으면 자주 쓰는 마켓에서 이어서 살 수 있어요. 가격 비교도 그 자리에서 해요.';
  }

  List<String> get linkableSourceLabels {
    const linkable = {
      'youtube',
      'instagram',
      'tiktok',
      'naver_blog',
      'mango',
      'website',
    };
    return recipeSources
        .where(linkable.contains)
        .map((id) => labelFor(id, recipeSourceChoices))
        .whereType<String>()
        .toList();
  }

  List<String> get favoriteCuisineLabels {
    return favoriteCuisines
        .map((id) => labelFor(id, cuisineChoices))
        .whereType<String>()
        .toList();
  }
}

/// 온보딩을 열지/닉네임을 건너뛸지. Firestore 읽기 없이 문서 map만으로 판정한다.
class OnboardingDecision {
  OnboardingDecision._();

  /// 가입을 마친 유저가 아직 온보딩을 끝내지 않았으면 true.
  /// 가입 도중(문서 없음·핸들 없음)에는 끼어들지 않는다.
  static bool needsOnboarding(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (data['onboardingCompletedAt'] != null) return false;
    if (data['onboardingRequired'] == true) return true;
    final name = (data['name'] ?? '').toString().trim();
    final handle = (data['handle'] ?? '').toString().trim();
    return name.isNotEmpty && handle.isNotEmpty;
  }

  /// 기존 회원(가입 플래그 없음, 닉네임 있음)은 닉네임 단계를 건너뛴다.
  /// 신규 가입은 `onboardingRequired`가 있어 닉네임을 다시 고른다.
  /// 기존 회원은 프로필에서 닉네임을 바꾸면 되므로 이 단계를 건너뛴다.
  static bool skipNickname(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (data['onboardingRequired'] == true) return false;
    final name = (data['name'] ?? '').toString().trim();
    return name.isNotEmpty;
  }

  /// 가입 화면에 `onboardingRequired`를 찍을지.
  /// 이메일 가입과 소셜 신규만 true. 기존 회원 생년월일 보완은 false.
  static bool shouldStampOnboardingRequired({
    required bool isSocialSignup,
    required bool isNewUser,
  }) {
    if (!isSocialSignup) return true;
    return isNewUser;
  }

  /// 로컬 초안의 단계 id를 현재 스텝 목록(닉네임 생략 반영)에 맞춘다.
  static int restoreStepIndex({
    required Iterable<String> stepNames,
    String? savedStepId,
  }) {
    final names = stepNames.toList(growable: false);
    if (names.isEmpty) return 0;
    final id = savedStepId?.trim() ?? '';
    if (id.isEmpty) return 0;
    final restored = names.indexOf(id);
    if (restored < 0) return 0;
    return restored;
  }
}
