import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/related_recipe_rails.dart';

void main() {
  group('pickRelatedMainIngredient', () {
    test('prefers specific sub ingredient over broad category', () {
      expect(
        pickRelatedMainIngredient(
          mainIngredientSub: ['닭다리살'],
          mainIngredient: ['육류'],
          ingredientItems: ['소금', '간장'],
        ),
        '닭다리살',
      );
    });

    test('skips seasoning and falls back to first real ingredient', () {
      expect(
        pickRelatedMainIngredient(
          ingredientItems: ['소금', '간장', '두부'],
        ),
        '두부',
      );
    });
  });

  group('pickRelatedMenuType', () {
    test('skips a menu type that is just the current dish name', () {
      expect(
        pickRelatedMenuType(
          menuTypes: ['안동찜닭', '찜'],
          dishName: '순살 안동찜닭',
        ),
        '찜',
      );
    });

    test('keeps a short style type even if the dish name contains it', () {
      expect(
        pickRelatedMenuType(menuTypes: ['찜'], dishName: '순살 안동찜닭'),
        '찜',
      );
    });
  });

  group('rail titles', () {
    test('ingredient title uses 로/으로 by batchim', () {
      expect(
        relatedIngredientRailTitle('닭다리살'),
        '닭다리살로 만든 다른 레시피 찾고 계신가요?',
      );
      expect(
        relatedIngredientRailTitle('치킨'),
        '치킨으로 만든 다른 레시피 찾고 계신가요?',
      );
    });

    test('style menu types get 계열 suffix', () {
      expect(relatedMenuRailTitle('찜'), '찜 계열 레시피 찾고 계신가요?');
      expect(relatedMenuRailTitle('팟타이'), '팟타이 레시피 찾고 계신가요?');
    });

    test('similar title uses 와/과 비슷한', () {
      expect(
        relatedSimilarRailTitle('대패짜장파스타'),
        '대패짜장파스타와 비슷한 레시피 찾고 계신가요?',
      );
      expect(
        relatedSimilarRailTitle('순살 안동찜닭'),
        '순살 안동찜닭과 비슷한 레시피 찾고 계신가요?',
      );
      expect(
        relatedSimilarRailTitle('김지훈표 단백질 폭탄 두부면 팟타이'),
        '비슷한 레시피 찾고 계신가요?',
      );
    });
  });

  group('dedupRelatedRecipeRails', () {
    test('keeps first rail copy and drops later duplicates', () {
      final a = {'id': 'a', 'title': 'A'};
      final b = {'id': 'b', 'title': 'B'};
      final rails = dedupRelatedRecipeRails([
        RelatedRecipeRail(
          id: 'similar',
          title: '비슷한 레시피',
          subtitle: '',
          recipes: [a, b],
        ),
        RelatedRecipeRail(
          id: 'popular',
          title: '인기',
          subtitle: '',
          recipes: [b, {'id': 'c', 'title': 'C'}],
        ),
      ]);

      expect(rails, hasLength(2));
      expect(rails[0].recipes.map(recipeIdOf), ['a', 'b']);
      expect(rails[1].recipes.map(recipeIdOf), ['c']);
    });

    test('hides a rail that becomes empty after dedup', () {
      final a = {'id': 'a'};
      final rails = dedupRelatedRecipeRails([
        RelatedRecipeRail(
          id: 'similar',
          title: '비슷한 레시피',
          subtitle: '',
          recipes: [a],
        ),
        RelatedRecipeRail(
          id: 'popular',
          title: '인기',
          subtitle: '',
          recipes: [a],
        ),
      ]);
      expect(rails, hasLength(1));
      expect(rails.first.id, 'similar');
    });
  });
}
