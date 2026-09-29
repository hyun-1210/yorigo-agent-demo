/// 홈 트렌드 섹션 키 ↔ UI 라벨 (home_section_rules.json / home_section_index 와 동기).
class HomeSectionKeys {
  HomeSectionKeys._();

  static const String trendingNow = 'trending_now';
  static const String seasonal = 'seasonal';
  static const String chef = 'chef';
  static const String tvPrograms = 'tv_programs';

  static const Map<String, String> labelByKey = {
    tvPrograms: 'TV에서 본 그 레시피',
    'program_pyeonstorang': '편스토랑',
    'program_fridge': '냉장고를 부탁해',
    'program_best_cooking': '최고의 요리비결',
    'program_culinary_class_wars': '흑백요리사',
    'program_street_restaurant_fighter': '스트릿 레스토랑 파이터',
    'program_bake_your_dream': '천하제빵',
    'program_altoran': '알토란',
    'program_sumi_side_dishes': '수미네 반찬',
    'program_home_food_baek': '집밥 백선생',
    'program_korean_food_battle': '한식대첩',
    'world_cup': '맥주 곁들이는 안주 한 상',
    'baby_food': '우리 아기 이유식·유아식',
    'dessert': '달콤한 디저트 한 입',
    'sauce': '만들어두면 든든한 소스·양념',
    'quick_10min': '10분 완성 레시피',
    'ingredients_5': '5가지 재료로 끝',
    'comfort_bowl': '뜨끈한 국물 한 그릇',
    'high_protein': '단백질 많은',
    'lean_strong': '고단백 저지방',
    'moment_late_night': '출출한 밤, 야식 한 입',
    'moment_morning': '든든한 아침 집밥 한 끼',
    'moment_guest': '손님 부르는 날, 그럴듯한 한 상',
    'moment_solo': '혼밥인데 대충 안 하고 싶을 때',
    'moment_dinner': '오늘 저녁 집밥 뭐 만들지',
    trendingNow: '실시간 인기 레시피',
    seasonal: '제철',
    chef: '셰프',
  };

  static List<String> get allKeys => labelByKey.keys.toList(growable: false);

  /// Admin pin/block/rebuild 대상.
  /// `home_section_index` / `home_section_rules.json` 에 실제 존재하는 키만.
  /// (`tv_programs`, `trending_now`, `seasonal`, `chef` 는 라벨/분석용 가짜 키)
  static const Set<String> _nonCurationKeys = {
    tvPrograms,
    trendingNow,
    seasonal,
    chef,
  };

  static List<String> get curationKeys => labelByKey.keys
      .where((key) => !_nonCurationKeys.contains(key))
      .toList(growable: false);

  static String labelFor(String sectionKey) =>
      labelByKey[sectionKey] ?? sectionKey;

  /// UI title → analytics section_id. 이모지/장식 접미사는 startsWith로 흡수.
  static String keyForTitle(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return 'unknown';
    for (final entry in labelByKey.entries) {
      if (trimmed == entry.value || trimmed.startsWith(entry.value)) {
        return entry.key;
      }
    }
    if (trimmed.contains('지금 뜨는') || trimmed.contains('실시간')) {
      return trendingNow;
    }
    if (trimmed.contains('제철')) return seasonal;
    if (trimmed.contains('셰프') || trimmed.toLowerCase().contains('chef')) {
      return chef;
    }
    // 최후: 영문/숫자만 남긴 식별자 (한글만이면 unknown)
    final ascii = trimmed
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return ascii.isEmpty ? 'unknown' : ascii;
  }
}

enum HomeSectionCurationStatus { none, pinned, blocked }
