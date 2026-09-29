import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/auto_meal_plan_service.dart';

void main() {
  final service = AutoMealPlanService();

  Map<String, Map<String, dynamic>> plansWith({
    required String dateKey,
    required String mealTime,
    required List<String> recipeIds,
  }) {
    return {
      dateKey: {
        'meals': {mealTime: recipeIds},
      },
    };
  }

  test('빈 슬롯만 채우고 기존 식단은 덮어쓰지 않는다', () {
    final start = DateTime(2026, 8, 10);
    final suggestions = service.generate(
      startDate: start,
      days: 1,
      existingPlans: plansWith(
        dateKey: '2026-08-10',
        mealTime: 'lunch',
        recipeIds: const ['existing_lunch'],
      ),
      fridgeRecipes: const [
        {'recipeId': 'fridge_a', 'recipeName': '냉장고 A'},
        {'recipeId': 'fridge_b', 'recipeName': '냉장고 B'},
      ],
      savedRecipes: const [],
      reviews: const [],
      mealTimes: const ['lunch', 'dinner'],
    );

    expect(suggestions, hasLength(1));
    expect(suggestions.single.mealTime, 'dinner');
    expect(suggestions.single.recipeId, isNot('existing_lunch'));
  });

  test('요청한 기간·끼니 스냅샷만큼만 제안한다', () {
    final start = DateTime(2026, 8, 10);
    final suggestions = service.generate(
      startDate: start,
      days: 3,
      existingPlans: const {},
      fridgeRecipes: [
        for (var i = 0; i < 10; i++)
          {'recipeId': 'r$i', 'recipeName': '레시피 $i'},
      ],
      savedRecipes: const [],
      reviews: const [],
      mealTimes: const ['dinner'],
    );

    expect(suggestions, hasLength(3));
    expect(suggestions.every((s) => s.mealTime == 'dinner'), isTrue);
    expect(
      suggestions.map((s) => s.date.day).toList(),
      [10, 11, 12],
    );
  });

  test('배치 안에서 같은 레시피를 중복 추천하지 않는다', () {
    final suggestions = service.generate(
      startDate: DateTime(2026, 8, 10),
      days: 3,
      existingPlans: const {},
      fridgeRecipes: const [
        {'recipeId': 'only_one', 'recipeName': '하나뿐'},
      ],
      savedRecipes: const [
        {'id': 'saved_a', 'title': '저장 A', 'status': 'completed'},
        {'id': 'saved_b', 'title': '저장 B', 'status': 'completed'},
      ],
      reviews: const [],
      mealTimes: const ['dinner'],
    );

    final ids = suggestions.map((s) => s.recipeId).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });
}
