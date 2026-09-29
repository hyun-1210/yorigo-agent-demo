import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/yorigo_level.dart';

void main() {
  group('yorigoExpRequiredForLevel', () {
    test('matches the shared curve used by Cloud Functions and Python', () {
      expect(yorigoExpRequiredForLevel(1), 0);
      expect(yorigoExpRequiredForLevel(2), 50);
      expect(yorigoExpRequiredForLevel(3), 130);
      expect(yorigoExpRequiredForLevel(4), 228);
      expect(yorigoExpRequiredForLevel(5), 339);
      expect(yorigoExpRequiredForLevel(6), 461);
      expect(yorigoExpRequiredForLevel(7), 593);
      expect(yorigoExpRequiredForLevel(8), 733);
      expect(yorigoExpRequiredForLevel(9), 882);
      expect(yorigoExpRequiredForLevel(10), 1037);
    });
  });

  group('yorigoLevelFromExp', () {
    test('stays at 1 until the first photo-review threshold', () {
      expect(yorigoLevelFromExp(0), 1);
      expect(yorigoLevelFromExp(49), 1);
      expect(yorigoLevelFromExp(50), 2);
    });

    test('uses inclusive thresholds', () {
      expect(yorigoLevelFromExp(129), 2);
      expect(yorigoLevelFromExp(130), 3);
      expect(yorigoLevelFromExp(227), 3);
      expect(yorigoLevelFromExp(228), 4);
    });
  });

  group('yorigoLevelFromUserData', () {
    test('prefers expTotal over a stored review-count level', () {
      expect(
        yorigoLevelFromUserData({'expTotal': 50, 'level': 9}),
        2,
      );
    });

    test('falls back to stored level when exp has not been written yet', () {
      expect(yorigoLevelFromUserData({'level': 4}), 4);
      expect(yorigoLevelFromUserData({}), 1);
    });
  });

  group('yorigoLevelSpoonName', () {
    test('keeps the last name from level 10 upward', () {
      expect(yorigoLevelSpoonName(1), '흑수저');
      expect(yorigoLevelSpoonName(10), '요리고수저');
      expect(yorigoLevelSpoonName(12), '요리고수저');
    });
  });
}
