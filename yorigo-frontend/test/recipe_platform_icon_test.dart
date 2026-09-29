import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/widgets/recipe_platform_icon.dart';

void main() {
  group('RecipePlatformIcon.assetPathFor', () {
    test('maps youtube / instagram / tiktok variants', () {
      expect(
        RecipePlatformIcon.assetPathFor('youtube'),
        'lib/assets/youtube-app-icon-hd.png',
      );
      expect(
        RecipePlatformIcon.assetPathFor('InstagramWeb'),
        'lib/assets/instagram-app-icon-hd.png',
      );
      expect(
        RecipePlatformIcon.assetPathFor('tiktokweb'),
        'lib/assets/tiktok-app-icon-hd.png',
      );
    });

    test('returns null for unknown or empty platforms', () {
      expect(RecipePlatformIcon.assetPathFor(''), isNull);
      expect(RecipePlatformIcon.assetPathFor('naver_blog'), isNull);
    });
  });
}
