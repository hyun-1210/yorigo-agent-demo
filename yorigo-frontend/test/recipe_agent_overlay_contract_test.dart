import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_overlay.dart';
import 'package:yorigo/models/recipe_models.dart' as models;
import 'package:yorigo/services/local_storage_service.dart';

void main() {
  test('applyPatchesToOverlay substitutes pork with tofu without renaming original item', () {
    final overlay = applyPatchesToOverlay(
      <String, dynamic>{},
      <Map<String, dynamic>>[
        {'action': 'ingredient.remove', 'item': '돼지고기'},
        {
          'action': 'ingredient.add',
          'item': '두부',
          'qty': 200,
          'unit': 'g',
          'memo': '돼지고기 대체',
        },
        {
          'action': 'step.edit',
          'order': 1,
          'instruction': '두부를 볶는다.',
        },
      ],
    );
    final removed = List<String>.from(
      ((overlay['ingredients'] as Map)['removed'] as List),
    );
    final added = List<Map>.from(
      ((overlay['ingredients'] as Map)['added'] as List),
    );
    expect(removed, contains('돼지고기'));
    expect(added.first['item'], '두부');

    final base = models.Recipe(
      name: '김치찌개',
      servings: 2,
      ingredients: [
        models.Ingredient(item: '돼지고기', qty: 200, unit: 'g'),
        models.Ingredient(item: '김치', qty: 200, unit: 'g'),
      ],
      steps: [
        models.Step(order: 1, instruction: '돼지고기를 볶는다.'),
      ],
    );
    final merged = applyOverlay(base, overlay);
    final items = merged.recipe.ingredients.map((e) => e.item).toList();
    expect(items, isNot(contains('돼지고기')));
    expect(items, contains('두부'));
    expect(merged.recipe.steps.first.instruction, '두부를 볶는다.');
  });

  test('added ingredient can be removed and qty-edited', () {
    var overlay = applyPatchesToOverlay(
      <String, dynamic>{},
      <Map<String, dynamic>>[
        {
          'action': 'ingredient.add',
          'item': '새우',
          'qty': 8,
          'unit': '마리',
        },
      ],
    );
    final base = models.Recipe(
      name: '김치찌개',
      servings: 2,
      ingredients: [
        models.Ingredient(item: '돼지고기', qty: 200, unit: 'g'),
      ],
      steps: [
        models.Step(order: 1, instruction: '볶는다.'),
      ],
    );
    var merged = applyOverlay(base, overlay);
    expect(merged.recipe.ingredients.map((e) => e.item), contains('새우'));

    overlay = applyPatchesToOverlay(
      overlay,
      <Map<String, dynamic>>[
        {'action': 'ingredient.edit', 'item': '새우', 'qty': 4, 'unit': '마리'},
      ],
    );
    merged = applyOverlay(base, overlay);
    final shrimp = merged.recipe.ingredients.firstWhere((e) => e.item == '새우');
    expect(shrimp.qty, 4);

    overlay = applyPatchesToOverlay(
      overlay,
      <Map<String, dynamic>>[
        {'action': 'ingredient.remove', 'item': '새우'},
      ],
    );
    merged = applyOverlay(base, overlay);
    expect(merged.recipe.ingredients.map((e) => e.item), isNot(contains('새우')));
    final added = List<Map>.from(
      (((overlay['ingredients'] as Map?)?['added'] as List?) ?? const []),
    );
    expect(added, isEmpty);
  });

  test('overlay primary key is uid-scoped', () {
    expect(
      LocalStorageService.overlayPrimaryKey(
        uid: 'u1',
        recipeId: 'r1',
        sourceUrl: 'https://youtu.be/x',
      ),
      'u1::r1',
    );
    expect(
      LocalStorageService.overlayReadKeys(
        uid: 'u1',
        recipeId: 'r1',
        sourceUrl: 'https://youtu.be/x',
      ),
      containsAll(<String>['u1::r1', 'https://youtu.be/x', 'r1']),
    );
  });
}
