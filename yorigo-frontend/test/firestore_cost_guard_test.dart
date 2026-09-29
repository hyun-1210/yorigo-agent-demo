import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/recipe_service.dart';

void main() {
  group('firestore cost guards', () {
    test('legacy recommendation search catalog is capped', () {
      expect(kRecipeSearchCatalogReadLimit, 80);
      expect(kRecipeSearchCatalogReadLimit, lessThan(500));
    });
  });
}
