import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/chef_tag_utils.dart';

void main() {
  tearDown(ChefTagRegistry.debugReset);

  group('isChefDisplayTag', () {
    test('rainbow only for allowlisted chef names', () {
      ChefTagRegistry.debugSetAllowlist({'백종원', '이연복'});
      expect(isChefDisplayTag('백종원'), isTrue);
      expect(isChefDisplayTag(' 이연복 '), isTrue);
      expect(isChefDisplayTag('한식'), isFalse);
      expect(isChefDisplayTag('저녁'), isFalse);
      expect(isChefDisplayTag('혼밥'), isFalse);
      expect(isChefDisplayTag('매콤한'), isFalse);
      expect(isChefDisplayTag('회사'), isFalse);
    });

    test('unloaded allowlist is never a chef tag', () {
      ChefTagRegistry.debugReset();
      expect(isChefDisplayTag('백종원'), isFalse);
      expect(isChefDisplayTag('한식'), isFalse);
    });
  });

  group('chef rainbow call sites', () {
    test('screens use allowlist helper instead of hangul heuristic', () {
      const paths = [
        'lib/screens/recipe_detail_screen.dart',
        'lib/screens/home_screen.dart',
        'lib/widgets/home_style_recipe_card.dart',
        'lib/screens/old_community_screen.dart',
      ];
      for (final path in paths) {
        final text = File(path).readAsStringSync();
        expect(text.contains('isChefDisplayTag'), isTrue, reason: path);
        expect(text.contains(r'^[가-힣]{2,6}$'), isFalse, reason: path);
      }
    });
  });
}
