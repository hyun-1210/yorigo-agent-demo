import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_pairing.dart';

void main() {
  group('resolvePairingPlan', () {
    test('김치찌개 gets side and soju-beer-makgeolli', () {
      final plan = resolvePairingPlan(
        dishName: '김치찌개',
        menuTypes: ['국 / 찌개 / 탕'],
        tags: ['매콤한'],
        country: ['한식'],
      );
      expect(plan.lanes.map((e) => e.id).toList(), ['side', 'alcohol']);
      expect(
        plan.lanes.last.sips.map((e) => e.id).toList(),
        ['soju', 'beer', 'makgeolli'],
      );
    });

    test('밑반찬 hides heavy rice and soup pairings', () {
      final plan = resolvePairingPlan(
        dishName: '멸치볶음',
        menuTypes: ['반찬'],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('케이크 gets drink pairings and no alcohol', () {
      final plan = resolvePairingPlan(
        dishName: '치즈케이크',
        menuTypes: ['디저트'],
      );
      expect(plan.lanes.map((e) => e.id).toList(), ['drink']);
      expect(plan.lanes.first.sips.map((e) => e.id), contains('coffee'));
    });

    test('치킨 안주 gets beer and a drink lane', () {
      final plan = resolvePairingPlan(
        dishName: '양념치킨',
        tags: ['술안주'],
      );
      expect(plan.lanes.map((e) => e.id).toList(), ['alcohol', 'drink']);
      expect(plan.lanes.first.sips.map((e) => e.id).toList(), ['beer', 'highball']);
    });

    test('파스타 gets salad and wine', () {
      final plan = resolvePairingPlan(
        dishName: '크림파스타',
        menuTypes: ['면'],
        country: ['양식'],
      );
      expect(plan.lanes.first.categoryValue, kPairingMenuSalad);
      expect(plan.lanes.map((e) => e.id), containsAll(['side', 'alcohol']));
      expect(plan.lanes.firstWhere((e) => e.id == 'alcohol').sips.map((e) => e.id), [
        'wine',
        'beer',
      ]);
    });

    test('샐러드 gets drinks only', () {
      final plan = resolvePairingPlan(
        dishName: '리코타 샐러드',
        menuTypes: ['샐러드 / 가벼운 식사'],
      );
      expect(plan.lanes.map((e) => e.id).toList(), ['drink']);
      expect(plan.lanes.first.sips, isNotEmpty);
    });

    test('이유식 is hidden', () {
      final plan = resolvePairingPlan(
        dishName: '소고기 이유식',
        tags: ['이유식'],
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('isPairingDrinkRecipe', () {
    test('keeps iced latte and drops soy dressing', () {
      expect(
        isPairingDrinkRecipe({
          'title': '바닐라 아이스라떼',
          'tags': ['음료'],
        }),
        isTrue,
      );
      expect(
        isPairingDrinkRecipe({
          'title': '만능 간장 소스',
          'tags': ['양념'],
        }),
        isFalse,
      );
    });
  });
}
