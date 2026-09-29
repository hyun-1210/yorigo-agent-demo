import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/widgets/program_curation_section.dart';

void main() {
  const all = ProgramCurationSection.fallbackPrograms;

  group('filterProgramsWithIndexCount', () {
    test('keeps only programs with count > 0 and preserves order', () {
      final visible = filterProgramsWithIndexCount(all, {
        'program_pyeonstorang': 47,
        'program_fridge': 7,
        'program_best_cooking': 0,
        'program_culinary_class_wars': 4,
        'program_street_restaurant_fighter': 0,
        'program_bake_your_dream': 0,
        'program_altoran': 2,
        'program_sumi_side_dishes': 0,
        'program_home_food_baek': 0,
        'program_korean_food_battle': 0,
      });

      expect(
        visible.map((p) => p.sectionKey).toList(),
        [
          'program_pyeonstorang',
          'program_fridge',
          'program_culinary_class_wars',
          'program_altoran',
        ],
      );
      expect(visible.map((p) => p.label).toList(), [
        '편스토랑',
        '냉장고를 부탁해',
        '흑백요리사',
        '알토란',
      ]);
    });

    test('treats missing keys as zero', () {
      final visible = filterProgramsWithIndexCount(all, {
        'program_altoran': 1,
      });
      expect(visible, hasLength(1));
      expect(visible.single.sectionKey, 'program_altoran');
    });

    test('returns empty when every program has zero recipes', () {
      final counts = {
        for (final p in all) p.sectionKey: 0,
      };
      expect(filterProgramsWithIndexCount(all, counts), isEmpty);
    });

    test('does not show empty-state pills for zero-count programs', () {
      // 백필 결과와 동일한 분포: 0인 카테고리 pill 이 결과에 없어야 한다.
      final visible = filterProgramsWithIndexCount(all, {
        'program_pyeonstorang': 47,
        'program_fridge': 7,
        'program_culinary_class_wars': 4,
        'program_altoran': 2,
      });
      final hiddenLabels = {
        '최고의 요리비결',
        '스트릿 레스토랑 파이터',
        '천하제빵',
        '수미네 반찬',
        '집밥 백선생',
        '한식대첩',
      };
      final visibleLabels = visible.map((p) => p.label).toSet();
      expect(visibleLabels.intersection(hiddenLabels), isEmpty);
      expect(visibleLabels, containsAll(['편스토랑', '냉장고를 부탁해', '흑백요리사', '알토란']));
    });
  });
}
