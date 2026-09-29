import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/recipe_agent_service.dart';

void main() {
  test('recipe helper stays off without dart-define', () {
    expect(RecipeAgentService.enabled, isFalse);
  });
}
