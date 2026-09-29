import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_social_counts.dart';

void main() {
  test('seedSaveCount is deterministic and in 1-20', () {
    expect(RecipeSocialCounts.seedSaveCount('abc123'),
        RecipeSocialCounts.seedSaveCount('abc123'));
    expect(RecipeSocialCounts.seedSaveCount('abc123'), 2);
  });

  test('seedSaveCount varies across recipe ids', () {
    final values = {
      for (var i = 0; i < 80; i++) RecipeSocialCounts.seedSaveCount('recipe-$i'),
    };
    expect(values.length, greaterThanOrEqualTo(8));
    expect(values.every((v) => v >= 1 && v <= 8), isTrue);
  });
}
