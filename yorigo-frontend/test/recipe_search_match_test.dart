import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_search_match.dart';

Map<String, dynamic> _recipe({
  required String title,
  String? groupKey,
  List<String> ingredients = const [],
  List<String> tags = const [],
}) {
  return <String, dynamic>{
    'id': title,
    'title': title,
    if (groupKey != null) 'groupKey': groupKey,
    'tags': tags,
    'recipe': {
      'title': title,
      'ingredients': [
        for (final item in ingredients) <String, dynamic>{'item': item},
      ],
    },
  };
}

void main() {
  group('compactSearchText', () {
    test('strips spaces so spaced dish names match', () {
      expect(compactSearchText('두부 부침'), '두부부침');
      expect(compactSearchText('두부부침'), '두부부침');
    });
  });

  group('dishGroupKeysForQuery', () {
    test('includes compact and underscored keys for the query itself', () {
      expect(dishGroupKeysForQuery('두부부침'), contains('두부부침'));
      expect(dishGroupKeysForQuery('두부 부침'), containsAll(['두부부침', '두부_부침']));
    });
  });

  group('recipeMatchesSearchQuery', () {
    test('matches 두부부침 against 두부 부침 title', () {
      expect(
        recipeMatchesSearchQuery(_recipe(title: '들기름 두부 부침'), '두부부침'),
        isTrue,
      );
    });

    test('does not treat 두부전 as 두부부침', () {
      expect(
        recipeMatchesSearchQuery(_recipe(title: '간단 두부전 만들기'), '두부부침'),
        isFalse,
      );
    });

    test('matches groupKey when title has spaces', () {
      expect(
        recipeMatchesSearchQuery(
          _recipe(title: '노릇한 두부 부침', groupKey: '두부부침'),
          '두부부침',
        ),
        isTrue,
      );
    });

    test('does not match unrelated tofu stew', () {
      expect(
        recipeMatchesSearchQuery(
          _recipe(title: '된장찌개', ingredients: ['두부', '된장']),
          '두부부침',
        ),
        isFalse,
      );
    });

    test('spaced dish query does not match every tofu recipe via ingredients', () {
      expect(
        recipeMatchesSearchQuery(
          _recipe(title: '된장찌개', ingredients: ['두부', '된장']),
          '두부 부침',
        ),
        isFalse,
      );
    });

    test('title match still outranks ingredient match', () {
      expect(
        recipeSearchMatchPriority(
          _recipe(title: '두부부침', ingredients: ['두부']),
          '두부부침',
        ),
        3,
      );
    });
  });
}
