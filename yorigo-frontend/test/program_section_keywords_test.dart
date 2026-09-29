import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_section_keys.dart';
import 'package:yorigo/constants/program_section_keywords.dart';

void main() {
  group('ProgramSectionKeywords', () {
    test('matches source title and channel aliases', () {
      expect(
        ProgramSectionKeywords.matchesRecipe({
          'source': {'title': '[신상출시 편스토랑] 류수영 닭볶음탕'},
        }, ProgramSectionKeywords.forKey('program_pyeonstorang')),
        isTrue,
      );
      expect(
        ProgramSectionKeywords.matchesRecipe({
          'source': {'title': '흑백요리사 요리 계급 전쟁'},
        }, ProgramSectionKeywords.forKey('program_culinary_class_wars')),
        isTrue,
      );
    });

    test('also matches recipe title and sourceUrl (generous CF parity)', () {
      expect(
        ProgramSectionKeywords.matchesRecipe({
          'title': '편스토랑 따라잡기 파스타',
          'source': {'title': '집밥 레시피'},
        }, ProgramSectionKeywords.forKey('program_pyeonstorang')),
        isTrue,
      );
      expect(
        ProgramSectionKeywords.matchesRecipe({
          'sourceUrl': 'https://youtu.be/fun-staurant-episode',
          'source': {'title': '일반 영상'},
        }, ProgramSectionKeywords.forKey('program_pyeonstorang')),
        isTrue,
      );
      expect(
        ProgramSectionKeywords.matchesRecipe({
          'title': '일반 파스타',
          'source': {'title': '집밥 레시피'},
        }, ProgramSectionKeywords.forKey('program_pyeonstorang')),
        isFalse,
      );
    });
  });

  group('HomeSectionKeys.curationKeys', () {
    test('excludes analytics-only fake keys', () {
      expect(HomeSectionKeys.curationKeys, isNot(contains('tv_programs')));
      expect(HomeSectionKeys.curationKeys, contains('program_pyeonstorang'));
    });
  });
}
