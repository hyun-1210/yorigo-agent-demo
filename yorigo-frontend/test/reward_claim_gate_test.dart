import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/reward_claim_gate.dart';

void main() {
  group('RewardClaimGate', () {
    test('skips duplicate idempotency keys after a granted claim', () {
      final gate = RewardClaimGate(
        clock: () => DateTime.utc(2026, 8, 22, 3),
      );
      expect(gate.skipReason('exp_like', 'exp_like:post1:uid'), isNull);
      gate.record(
        action: 'exp_like',
        idempotencyKey: 'exp_like:post1:uid',
        granted: true,
      );
      expect(
        gate.skipReason('exp_like', 'exp_like:post1:uid'),
        'duplicate',
      );
    });

    test('stops calling after the daily limit is reached', () {
      final gate = RewardClaimGate(
        clock: () => DateTime.utc(2026, 8, 22, 3),
        dailyLimits: const {'exp_search': 2},
      );
      gate.record(
        action: 'exp_search',
        idempotencyKey: 'exp_search:1',
        granted: true,
      );
      gate.record(
        action: 'exp_search',
        idempotencyKey: 'exp_search:2',
        granted: true,
      );
      expect(
        gate.skipReason('exp_search', 'exp_search:3'),
        'daily_limit_reached',
      );
    });

    test('treats a server daily-limit response as exhausted', () {
      final gate = RewardClaimGate(
        clock: () => DateTime.utc(2026, 8, 22, 3),
        dailyLimits: const {'exp_recipe_viewed': 20},
      );
      gate.record(
        action: 'exp_recipe_viewed',
        idempotencyKey: 'exp_recipe_viewed:r1:2026-08-22',
        granted: false,
        reason: 'daily_limit_reached',
      );
      expect(
        gate.skipReason('exp_recipe_viewed', 'exp_recipe_viewed:r2:2026-08-22'),
        'daily_limit_reached',
      );
    });

    test('sanitizes slash the same way as Cloud Functions', () {
      final gate = RewardClaimGate(
        clock: () => DateTime.utc(2026, 8, 22, 3),
      );
      expect(
        gate.safeIdempotencyKey('exp_like:reviews/abc:uid'),
        'exp_like:reviews_abc:uid',
      );
    });

    test('does not lock a key on transport error so the client can retry', () {
      final gate = RewardClaimGate(
        clock: () => DateTime.utc(2026, 8, 22, 3),
      );
      gate.record(
        action: 'exp_attendance',
        idempotencyKey: 'exp_attendance:uid:2026-08-22',
        granted: false,
        reason: 'error',
      );
      expect(
        gate.skipReason('exp_attendance', 'exp_attendance:uid:2026-08-22'),
        isNull,
      );
    });
  });
}
