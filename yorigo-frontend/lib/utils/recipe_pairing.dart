/// 레시피 상세 페어링: 지금 메뉴에 곁들이면 좋은 반찬·국·밥·음료·술.

class PairingSip {
  const PairingSip({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;

  /// beer | soju | wine | makgeolli | highball | sake | coffee | tea |
  /// cola | cider | barley | milk
  final String icon;
}

class PairingLane {
  const PairingLane({
    required this.id,
    required this.label,
    this.categoryValue,
    this.accept,
    this.sips = const [],
  });

  final String id;
  final String label;
  final String? categoryValue;
  final bool Function(Map<String, dynamic> recipe)? accept;
  final List<PairingSip> sips;

  bool get isSipLane => categoryValue == null;
}

class PairingPlan {
  const PairingPlan({
    required this.lanes,
  });

  final List<PairingLane> lanes;
  bool get isEmpty => lanes.isEmpty;
}

class LoadedPairingLane {
  const LoadedPairingLane({
    required this.id,
    required this.label,
    this.recipes = const [],
    this.sips = const [],
  });

  final String id;
  final String label;
  final List<Map<String, dynamic>> recipes;
  final List<PairingSip> sips;

  bool get isEmpty => recipes.isEmpty && sips.isEmpty;
}

const String kPairingMenuSide = '반찬';
const String kPairingMenuDessert = '디저트';
const String kPairingMenuDrink = '음료 / 소스 / 양념';
const String kPairingMenuSalad = '샐러드 / 가벼운 식사';

const List<String> kPairingDrinkTitleHints = [
  '음료',
  '주스',
  '스무디',
  '에이드',
  '커피',
  '라떼',
  '아메리카노',
  '밀크티',
  '아이스티',
  '버블티',
  '녹차',
  '홍차',
  '보리차',
  '허브티',
  '식혜',
  '수정과',
  '콤부차',
  '칵테일',
  '모히또',
  '하이볼',
  '쉐이크',
  '스무디',
  '레몬에이드',
];

const List<String> kPairingSauceTitleHints = [
  '소스',
  '드레싱',
  '양념',
  '쌈장',
  '딥소스',
  '시즈닝',
];

const List<String> kPairingAnjuTitleHints = [
  '치킨',
  '후라이드',
  '닭강정',
  '윙',
  '감자튀김',
  '치즈스틱',
  '나초',
  '꼬치',
  '닭발',
  '똥집',
  '쥐포',
  '노가리',
  '먹태',
  '육포',
  '감바스',
  '곱창',
  '막창',
  '골뱅이',
  '파전',
  '김치전',
  '부침개',
  '두부김치',
  '어묵',
  '떡볶이',
  '핫도그',
  '피자',
  '안주',
];

const List<String> kPairingBabyHints = [
  '이유식',
  '유아식',
  '아기',
  '애기',
  '아가',
  '베이비',
];

PairingPlan resolvePairingPlan({
  required String dishName,
  List<String> menuTypes = const [],
  List<String> tags = const [],
  List<String> country = const [],
}) {
  final blob = _compact([dishName, ...menuTypes, ...tags, ...country]);
  if (blob.isEmpty) return const PairingPlan(lanes: []);
  if (_hasAny(blob, kPairingBabyHints)) {
    return const PairingPlan(lanes: []);
  }

  final role = _roleOf(
    blob: blob,
    menuTypes: menuTypes,
    tags: tags,
  );
  final cuisine = _cuisineOf(blob);

  switch (role) {
    case _PairingRole.dessert:
      return PairingPlan(
        lanes: [
          PairingLane(
            id: 'drink',
            label: '음료',
            categoryValue: kPairingMenuDrink,
            accept: isPairingDrinkRecipe,
            sips: const [
              PairingSip(id: 'coffee', label: '커피', icon: 'coffee'),
              PairingSip(id: 'tea', label: '홍차', icon: 'tea'),
              PairingSip(id: 'milk', label: '우유', icon: 'milk'),
            ],
          ),
        ],
      );
    case _PairingRole.salad:
      return PairingPlan(
        lanes: [
          PairingLane(
            id: 'drink',
            label: '음료',
            categoryValue: kPairingMenuDrink,
            accept: isPairingDrinkRecipe,
            sips: const [
              PairingSip(id: 'tea', label: '아이스티', icon: 'tea'),
              PairingSip(id: 'cider', label: '에이드', icon: 'cider'),
              PairingSip(id: 'barley', label: '보리차', icon: 'barley'),
            ],
          ),
        ],
      );
    case _PairingRole.drink:
      return const PairingPlan(
        lanes: [
          PairingLane(
            id: 'anju',
            label: '안주',
            categoryValue: kPairingMenuSide,
            accept: isPairingAnjuRecipe,
          ),
          PairingLane(
            id: 'dessert',
            label: '디저트',
            categoryValue: kPairingMenuDessert,
          ),
        ],
      );
    case _PairingRole.side:
      return const PairingPlan(lanes: []);
    case _PairingRole.soup:
      return PairingPlan(
        lanes: [
          const PairingLane(
            id: 'side',
            label: '반찬',
            categoryValue: kPairingMenuSide,
          ),
          PairingLane(
            id: 'alcohol',
            label: '주류',
            sips: _alcoholFor(cuisine, blob),
          ),
        ],
      );
    case _PairingRole.rice:
      return PairingPlan(
        lanes: [
          const PairingLane(
            id: 'side',
            label: '반찬',
            categoryValue: kPairingMenuSide,
          ),
          PairingLane(
            id: 'alcohol',
            label: '주류',
            sips: _alcoholFor(cuisine, blob),
          ),
        ],
      );
    case _PairingRole.anju:
      return PairingPlan(
        lanes: [
          PairingLane(
            id: 'alcohol',
            label: '주류',
            sips: _alcoholFor(cuisine, blob),
          ),
          PairingLane(
            id: 'drink',
            label: '음료',
            categoryValue: kPairingMenuDrink,
            accept: isPairingDrinkRecipe,
            sips: const [
              PairingSip(id: 'cola', label: '콜라', icon: 'cola'),
              PairingSip(id: 'cider', label: '사이다', icon: 'cider'),
            ],
          ),
        ],
      );
    case _PairingRole.noodle:
    case _PairingRole.savory:
      return PairingPlan(
        lanes: [
          PairingLane(
            id: 'side',
            label: '반찬',
            categoryValue: cuisine == _PairingCuisine.western
                ? kPairingMenuSalad
                : kPairingMenuSide,
          ),
          PairingLane(
            id: 'alcohol',
            label: '주류',
            sips: _alcoholFor(cuisine, blob),
          ),
          PairingLane(
            id: 'drink',
            label: '음료',
            categoryValue: kPairingMenuDrink,
            accept: isPairingDrinkRecipe,
            sips: _softDrinksFor(blob),
          ),
        ],
      );
  }
}

bool isPairingDrinkRecipe(Map<String, dynamic> recipe) {
  final blob = _recipeSearchBlob(recipe);
  if (blob.isEmpty) return false;
  if (_hasAny(blob, kPairingDrinkTitleHints)) return true;
  if (_hasAny(blob, kPairingSauceTitleHints)) return false;
  return false;
}

bool isPairingAnjuRecipe(Map<String, dynamic> recipe) {
  final blob = _recipeSearchBlob(recipe);
  if (blob.isEmpty) return false;
  if (_hasAny(blob, ['밥', '죽', '찌개', '국밥', '라면', '이유식'])) {
    return false;
  }
  return _hasAny(blob, kPairingAnjuTitleHints);
}

String _recipeSearchBlob(Map<String, dynamic> recipe) {
  final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
  final source = recipe['source'] as Map<String, dynamic>? ?? const {};
  final title = [
    recipe['title'],
    recipeData['title'],
    recipeData['name'],
  ].map((e) => e?.toString() ?? '').join(' ');
  final tags = <String>[];
  for (final raw in [recipe['tags'], source['tags']]) {
    if (raw is List) {
      tags.addAll(raw.map((e) => e.toString()));
    }
  }
  return _compact([title, ...tags]);
}

enum _PairingRole { dessert, drink, salad, side, soup, rice, noodle, anju, savory }

enum _PairingCuisine { korean, western, japanese, chinese }

_PairingRole _roleOf({
  required String blob,
  required List<String> menuTypes,
  required List<String> tags,
}) {
  final menus = menuTypes.map(_compact).where((e) => e.isNotEmpty).toList();
  bool menuHas(String key) => menus.any((m) => m.contains(_compact(key)));

  if (menuHas('디저트') ||
      _hasAny(blob, ['케이크', '쿠키', '마카롱', '푸딩', '티라미수', '아이스크림', '빙수'])) {
    return _PairingRole.dessert;
  }
  if (menuHas('음료') ||
      _hasAny(blob, ['주스', '스무디', '에이드', '칵테일', '커피', '라떼'])) {
    return _PairingRole.drink;
  }
  if (menuHas('샐러드') || _hasAny(blob, ['샐러드', 'salad'])) {
    return _PairingRole.salad;
  }
  if (menuHas('반찬') || _hasAny(blob, ['밑반찬', '장아찌', '김치볶음'])) {
    return _PairingRole.side;
  }
  if (menuHas('국 / 찌개 / 탕') ||
      _hasAny(blob, ['찌개', '전골', '탕', '국밥', '해장국'])) {
    return _PairingRole.soup;
  }
  if (menuHas('면') ||
      _hasAny(blob, ['면', '국수', '라면', '파스타', '스파게티', '우동', '소바'])) {
    return _PairingRole.noodle;
  }
  if (menuHas('밥') ||
      _hasAny(blob, ['덮밥', '볶음밥', '비빔밥', '초밥', '김밥', '리조또'])) {
    return _PairingRole.rice;
  }
  if (tags.any((t) => _hasAny(_compact(t), ['안주', '술안주', '맥주안주'])) ||
      _hasAny(blob, kPairingAnjuTitleHints)) {
    return _PairingRole.anju;
  }
  return _PairingRole.savory;
}

_PairingCuisine _cuisineOf(String blob) {
  if (_hasAny(blob, ['양식', '이탈리아', '프랑스', '파스타', '스테이크', '리조또', '피자'])) {
    return _PairingCuisine.western;
  }
  if (_hasAny(blob, ['일식', '초밥', '사시미', '라멘', '돈카츠', '오마카세'])) {
    return _PairingCuisine.japanese;
  }
  if (_hasAny(blob, ['중식', '짜장', '짬뽕', '마라', '탕수육', '딤섬'])) {
    return _PairingCuisine.chinese;
  }
  return _PairingCuisine.korean;
}

List<PairingSip> _alcoholFor(_PairingCuisine cuisine, String blob) {
  switch (cuisine) {
    case _PairingCuisine.western:
      return const [
        PairingSip(id: 'wine', label: '와인', icon: 'wine'),
        PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
      ];
    case _PairingCuisine.japanese:
      return const [
        PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
        PairingSip(id: 'sake', label: '사케', icon: 'sake'),
      ];
    case _PairingCuisine.chinese:
      return const [
        PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
        PairingSip(id: 'highball', label: '하이볼', icon: 'highball'),
      ];
    case _PairingCuisine.korean:
      if (_hasAny(blob, ['튀김', '치킨', '후라이드', '피자', '감자튀김'])) {
        return const [
          PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
          PairingSip(id: 'highball', label: '하이볼', icon: 'highball'),
        ];
      }
      if (_hasAny(blob, ['매콤', '매운', '김치', '찌개', '불고기', '삼겹', '구이'])) {
        return const [
          PairingSip(id: 'soju', label: '소주', icon: 'soju'),
          PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
          PairingSip(id: 'makgeolli', label: '막걸리', icon: 'makgeolli'),
        ];
      }
      return const [
        PairingSip(id: 'beer', label: '맥주', icon: 'beer'),
        PairingSip(id: 'soju', label: '소주', icon: 'soju'),
      ];
  }
}

List<PairingSip> _softDrinksFor(String blob) {
  if (_hasAny(blob, ['매콤', '매운', '김치찌개', '떡볶이'])) {
    return const [
      PairingSip(id: 'milk', label: '우유', icon: 'milk'),
      PairingSip(id: 'barley', label: '보리차', icon: 'barley'),
    ];
  }
  if (_hasAny(blob, ['튀김', '치킨', '피자', '버거'])) {
    return const [
      PairingSip(id: 'cola', label: '콜라', icon: 'cola'),
      PairingSip(id: 'cider', label: '사이다', icon: 'cider'),
    ];
  }
  return const [
    PairingSip(id: 'barley', label: '보리차', icon: 'barley'),
    PairingSip(id: 'cider', label: '사이다', icon: 'cider'),
  ];
}

String _compact(Object raw) {
  if (raw is List) {
    return raw
        .map((e) => e.toString().replaceAll(RegExp(r'\s+'), ''))
        .where((e) => e.isNotEmpty)
        .join();
  }
  return raw.toString().replaceAll(RegExp(r'\s+'), '');
}

bool _hasAny(String blob, List<String> needles) {
  for (final raw in needles) {
    final n = _compact(raw);
    if (n.isNotEmpty && blob.contains(n)) return true;
  }
  return false;
}
