import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_poster_curations.dart';

void main() {
  tearDown(HomePosterCurations.debugResetOpenCooldown);

  test('byId resolves known poster ids and legacy alias', () {
    expect(HomePosterCurations.byId('first_main_for_two'), isNotNull);
    expect(HomePosterCurations.byId('mynormal_low_sugar'), isNotNull);
    expect(HomePosterCurations.byId('newlywed_kitchen_starter'), isNotNull);
    expect(
      HomePosterCurations.byId('fridge_three_ingredients')?.id,
      'mynormal_low_sugar',
    );
    expect(HomePosterCurations.byId('missing_id'), isNull);
  });

  test('open cooldown blocks rapid double consume then allows after TTL', () {
    final t0 = DateTime(2026, 8, 10, 12, 0, 0);
    expect(HomePosterCurations.tryConsumeOpenCooldown(now: t0), isTrue);
    expect(
      HomePosterCurations.tryConsumeOpenCooldown(
        now: t0.add(const Duration(milliseconds: 300)),
      ),
      isFalse,
    );
    expect(
      HomePosterCurations.tryConsumeOpenCooldown(
        now: t0.add(HomePosterCurations.openCooldown),
      ),
      isTrue,
    );
  });
}
