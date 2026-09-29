import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/user_service.dart';

void main() {
  group('UserService.looksLikeEmail', () {
    test('accepts normal emails', () {
      expect(UserService.looksLikeEmail('tiff1115any@naver.com'), isTrue);
      expect(UserService.looksLikeEmail('  user@gmail.com  '), isTrue);
      expect(UserService.looksLikeEmail('a.b+c@mail.co.kr'), isTrue);
    });

    test('rejects empty and invalid', () {
      expect(UserService.looksLikeEmail(''), isFalse);
      expect(UserService.looksLikeEmail('   '), isFalse);
      expect(UserService.looksLikeEmail('not-an-email'), isFalse);
      expect(UserService.looksLikeEmail('@naver.com'), isFalse);
      expect(UserService.looksLikeEmail('user@'), isFalse);
      expect(UserService.looksLikeEmail('user @naver.com'), isFalse);
    });
  });

  group('UserService.resolvePersistableEmail', () {
    test('prefers pending Kakao email over null Auth email', () {
      expect(
        UserService.resolvePersistableEmail(
          pendingSocialEmail: 'kakao@naver.com',
          formEmail: '',
          authEmail: null,
        ),
        'kakao@naver.com',
      );
    });

    test('falls back to Auth email for Google', () {
      expect(
        UserService.resolvePersistableEmail(
          pendingSocialEmail: null,
          formEmail: '',
          authEmail: 'user@gmail.com',
        ),
        'user@gmail.com',
      );
    });

    test('ignores invalid pending and uses next valid', () {
      expect(
        UserService.resolvePersistableEmail(
          pendingSocialEmail: 'not-email',
          formEmail: 'form@test.com',
          authEmail: 'auth@test.com',
        ),
        'form@test.com',
      );
    });

    test('returns null when nothing valid', () {
      expect(
        UserService.resolvePersistableEmail(
          pendingSocialEmail: null,
          formEmail: ' ',
          authEmail: '',
        ),
        isNull,
      );
    });
  });
}
