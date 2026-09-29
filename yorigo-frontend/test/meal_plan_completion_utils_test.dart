import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/meal_plan_completion_utils.dart';

void main() {
  group('formatMealCompletedLabel', () {
    test('returns generic label when completedAt is null', () {
      expect(formatMealCompletedLabel(null), '요리 완료');
    });
  });

  group('reindexCompletedSlotAtAfterRemoval', () {
    test('shifts completion keys after removing earlier slot', () {
      final next = reindexCompletedSlotAtAfterRemoval(
        completedSlotAt: {
          'lunch_0': 'ts0',
          'lunch_1': 'ts1',
          'breakfast_0': 'ts2',
        },
        mealTime: 'lunch',
        removedIndex: 0,
      );
      expect(next['breakfast_0'], 'ts2');
      expect(next['lunch_0'], 'ts1');
      expect(next.containsKey('lunch_1'), isFalse);
    });
  });

  group('resolveMealPlanSlotStatus', () {
    test('reads completedSlotAt timestamp', () {
      final at = DateTime(2026, 3, 10, 18, 30);
      final status = resolveMealPlanSlotStatus(
        plan: {
          'meals': {'dinner': ['abc']},
          'completedSlotAt': {'dinner_0': at},
        },
        mealTime: 'dinner',
        slotIndex: 0,
      );
      expect(status.completed, isTrue);
      expect(status.completedAt, at);
    });
  });
}
