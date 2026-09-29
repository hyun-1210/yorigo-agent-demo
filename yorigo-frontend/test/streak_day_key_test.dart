import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/user_service.dart';

void main() {
  group('UserService.streakDayKey', () {
    test('uses KST calendar day, not device-local alone', () {
      // 2026-08-02 15:30 UTC == 2026-08-03 00:30 KST
      final justAfterKstMidnight = DateTime.utc(2026, 8, 2, 15, 30);
      expect(UserService.streakDayKey(justAfterKstMidnight), '2026-08-03');

      // 2026-08-02 14:30 UTC == 2026-08-02 23:30 KST
      final justBeforeKstMidnight = DateTime.utc(2026, 8, 2, 14, 30);
      expect(UserService.streakDayKey(justBeforeKstMidnight), '2026-08-02');
    });

    test('normalizeStreakDayKey pads values', () {
      expect(UserService.normalizeStreakDayKey('2026-8-3'), '2026-08-03');
      expect(UserService.normalizeStreakDayKey('nope'), isNull);
    });
  });
}
