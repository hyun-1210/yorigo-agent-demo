import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_section_keys.dart';

void main() {
  group('HomeSectionKeys.keyForTitle', () {
    test('maps exact curated titles to stable keys', () {
      expect(
        HomeSectionKeys.keyForTitle('단백질 많은'),
        HomeSectionKeys.labelByKey.containsKey('high_protein')
            ? 'high_protein'
            : isNot(equals('unknown')),
      );
      expect(HomeSectionKeys.keyForTitle('단백질 많은'), 'high_protein');
      expect(HomeSectionKeys.keyForTitle('실시간 인기 레시피'), 'trending_now');
      expect(HomeSectionKeys.keyForTitle('10분 완성 레시피'), 'quick_10min');
      expect(HomeSectionKeys.keyForTitle('TV에서 본 그 레시피'), 'tv_programs');
      expect(HomeSectionKeys.keyForTitle('편스토랑'), 'program_pyeonstorang');
      expect(HomeSectionKeys.keyForTitle('냉장고를 부탁해'), 'program_fridge');
      expect(
        HomeSectionKeys.keyForTitle('흑백요리사'),
        'program_culinary_class_wars',
      );
    });

    test('absorbs emoji / decorative suffixes via startsWith', () {
      expect(HomeSectionKeys.keyForTitle('실시간 인기 레시피 🔥'), 'trending_now');
      expect(HomeSectionKeys.keyForTitle('지금 뜨는 레시피'), 'trending_now');
      expect(HomeSectionKeys.keyForTitle('단백질 많은 💪'), 'high_protein');
    });

    test('maps seasonal and chef variants', () {
      expect(HomeSectionKeys.keyForTitle('7월 제철'), 'seasonal');
      expect(HomeSectionKeys.keyForTitle('제철 재료'), 'seasonal');
      expect(HomeSectionKeys.keyForTitle('셰프 · 백종원'), 'chef');
      expect(HomeSectionKeys.keyForTitle('셰프'), 'chef');
    });

    test('returns unknown for empty or korean-only unmatched', () {
      expect(HomeSectionKeys.keyForTitle(''), 'unknown');
      expect(HomeSectionKeys.keyForTitle('   '), 'unknown');
      expect(HomeSectionKeys.keyForTitle('알 수 없는 섹션명'), 'unknown');
    });

    test('keeps ascii-ish fallback for unmatched latin titles', () {
      expect(
        HomeSectionKeys.keyForTitle('My Custom Section'),
        'my_custom_section',
      );
    });
  });

  group('HomeSectionKeys.curationKeys', () {
    test('keeps program keys and drops tv_programs fake key', () {
      expect(HomeSectionKeys.curationKeys.contains('tv_programs'), isFalse);
      expect(
        HomeSectionKeys.curationKeys.contains('program_altoran'),
        isTrue,
      );
    });
  });
}
