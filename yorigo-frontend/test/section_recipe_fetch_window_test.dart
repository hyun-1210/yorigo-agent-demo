import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/section_recipe_fetch_window.dart';

void main() {
  group('SectionRecipeFetchWindow.nextIds', () {
    test('초기 fetch 5개', () {
      final ids = List.generate(12, (i) => 'r$i');
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: ids,
          fetchedCount: 0,
          extra: 5,
        ),
        ['r0', 'r1', 'r2', 'r3', 'r4'],
      );
    });

    test('append 4개', () {
      final ids = List.generate(12, (i) => 'r$i');
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: ids,
          fetchedCount: 5,
          extra: 4,
        ),
        ['r5', 'r6', 'r7', 'r8'],
      );
    });

    test('남은 개수가 extra 보다 적으면 남은 것만', () {
      final ids = ['a', 'b', 'c'];
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: ids,
          fetchedCount: 2,
          extra: 4,
        ),
        ['c'],
      );
    });

    test('소진 후 빈 리스트', () {
      final ids = ['a', 'b'];
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: ids,
          fetchedCount: 2,
          extra: 4,
        ),
        isEmpty,
      );
    });

    test('빈 인덱스 / extra<=0 은 빈 리스트', () {
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: const [],
          fetchedCount: 0,
          extra: 5,
        ),
        isEmpty,
      );
      expect(
        SectionRecipeFetchWindow.nextIds(
          indexedIds: const ['a'],
          fetchedCount: 0,
          extra: 0,
        ),
        isEmpty,
      );
    });
  });

  group('SectionRecipeFetchWindow.isExhausted', () {
    test('total 0 이면 exhausted', () {
      expect(
        SectionRecipeFetchWindow.isExhausted(fetchedCount: 0, totalIds: 0),
        isTrue,
      );
    });

    test('fetched >= total 이면 exhausted', () {
      expect(
        SectionRecipeFetchWindow.isExhausted(fetchedCount: 5, totalIds: 5),
        isTrue,
      );
    });

    test('아직 남으면 false', () {
      expect(
        SectionRecipeFetchWindow.isExhausted(fetchedCount: 4, totalIds: 5),
        isFalse,
      );
    });
  });
}
