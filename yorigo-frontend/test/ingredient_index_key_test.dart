import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/ingredient_index_key.dart';

void main() {
  group('IngredientIndexKey', () {
    test('normalize trims, lowercases, collapses spaces', () {
      expect(IngredientIndexKey.normalize('  양파  '), '양파');
      expect(IngredientIndexKey.normalize('대파   1줄'), '대파 1줄');
    });

    test('docId replaces slash and matches python backfill', () {
      expect(IngredientIndexKey.docId('양파'), '양파');
      expect(IngredientIndexKey.docId('a/b'), 'a__b');
    });

    test('docIdFromName uses normalized name', () {
      expect(
        IngredientIndexKey.docIdFromName('  계란 '),
        IngredientIndexKey.docId('계란'),
      );
    });
  });
}
