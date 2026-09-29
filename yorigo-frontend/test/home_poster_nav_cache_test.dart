import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/home_poster_recipe_session_cache.dart';
import 'package:yorigo/utils/nav_guard.dart';

void main() {
  group('NavGuard', () {
    setUp(NavGuard.debugReset);
    tearDown(NavGuard.debugReset);

    test('blocks concurrent once while awaited action is running', () async {
      var started = 0;
      var finished = 0;

      final first = NavGuard.once(() async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        finished++;
      });
      final second = NavGuard.once(() async {
        started++;
        finished++;
      });

      first();
      second();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, 1);
      expect(finished, 0);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finished, 1);

      second();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, 2);
      expect(finished, 2);
    });

    test('releases immediately when action does not await navigation', () async {
      var secondRan = false;

      NavGuard.once(() async {
        // 홈/포스터 권장 패턴: push 를 await 하지 않음
        // ignore: unawaited_futures
        Future<void>.delayed(const Duration(seconds: 5));
      })();

      await Future<void>.value();
      NavGuard.once(() async {
        secondRan = true;
      })();
      await Future<void>.value();

      expect(secondRan, isTrue);
    });

    test('awaiting a long-lived future keeps guard locked (anti-pattern)',
        () async {
      var nestedRan = false;
      final done = Future<void>.delayed(const Duration(milliseconds: 60));

      NavGuard.once(() async {
        await done; // 포스터 open 의 구 버그 패턴
      })();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      NavGuard.once(() async {
        nestedRan = true;
      })();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(nestedRan, isFalse);

      await done;
      await Future<void>.value();
      NavGuard.once(() async {
        nestedRan = true;
      })();
      await Future<void>.value();
      expect(nestedRan, isTrue);
    });
  });

  group('HomePosterRecipeSessionCache', () {
    test('returns recipes within TTL and expires after TTL', () {
      final cache = HomePosterRecipeSessionCache(
        ttl: const Duration(milliseconds: 30),
      );
      final recipes = [
        {'id': 'a'},
        {'id': 'b'},
      ];
      cache.set('poster::chip_0', recipes);

      expect(cache.get('poster::chip_0'), isNotNull);
      expect(cache.get('poster::chip_0')!.length, 2);
      expect(cache.get('missing'), isNull);

      cache.debugSetWithCachedAt(
        'poster::chip_0',
        recipes,
        DateTime.now().subtract(const Duration(milliseconds: 50)),
      );
      expect(cache.get('poster::chip_0'), isNull);
      expect(cache.length, 0);
    });

    test('set stores an unmodifiable copy', () {
      final cache = HomePosterRecipeSessionCache();
      final recipes = <Map<String, dynamic>>[
        {'id': 'a'},
      ];
      cache.set('k', recipes);
      recipes.add({'id': 'b'});

      final cached = cache.get('k')!;
      expect(cached.length, 1);
      expect(() => cached.add({'id': 'c'}), throwsUnsupportedError);
    });

    test('clear removes all entries', () {
      final cache = HomePosterRecipeSessionCache();
      cache.set('a', [
        {'id': '1'},
      ]);
      cache.set('b', [
        {'id': '2'},
      ]);
      expect(cache.length, 2);
      cache.clear();
      expect(cache.length, 0);
      expect(cache.get('a'), isNull);
    });
  });
}
