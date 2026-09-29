import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/source_creator_utils.dart';

void main() {
  group('isNumericCreatorInternalId', () {
    test('숫자 PK 감지', () {
      expect(isNumericCreatorInternalId('123456789'), isTrue);
      expect(isNumericCreatorInternalId('@987654321'), isTrue);
      expect(isNumericCreatorInternalId('jian_home'), isFalse);
      expect(isNumericCreatorInternalId('@chef'), isFalse);
      expect(isNumericCreatorInternalId(null), isFalse);
      expect(isNumericCreatorInternalId(''), isFalse);
    });
  });

  group('resolveCreatorHandle', () {
    test('YouTube: uploader_id 핸들 우선', () {
      expect(
        resolveCreatorHandle(
          platform: 'youtube',
          uploader: 'display name',
          uploaderId: 'jian_home',
        ),
        '@jian_home',
      );
    });

    test('YouTube: 숫자 uploader_id면 uploader fallback', () {
      expect(
        resolveCreatorHandle(
          platform: 'youtube',
          uploader: 'real_channel',
          uploaderId: '12345',
        ),
        '@real_channel',
      );
    });

    test('Instagram: uploader username 사용 (PK 무시)', () {
      expect(
        resolveCreatorHandle(
          platform: 'instagram',
          uploader: 'foodie_kr',
          uploaderId: '17841400000000000',
        ),
        '@foodie_kr',
      );
    });

    test('TikTok: uploader username 사용', () {
      expect(
        resolveCreatorHandle(
          platform: 'tiktok',
          uploader: 'cooktok',
          uploaderId: '999888777',
        ),
        '@cooktok',
      );
    });

    test('빈 값이면 fallback', () {
      expect(
        resolveCreatorHandle(platform: 'youtube'),
        '@Chef',
      );
      expect(
        resolveCreatorHandle(
          platform: 'youtube',
          fallback: '@ChefAntoine',
        ),
        '@ChefAntoine',
      );
    });
  });
}
