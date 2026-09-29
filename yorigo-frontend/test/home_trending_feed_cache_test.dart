import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yorigo/services/local_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStorageService localStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    localStorage = LocalStorageService();
  });

  Map<String, dynamic> minimalPayload() => {
    'allRecipes': [
      {
        'id': 'r1',
        'status': 'completed',
        'title': '테스트',
        'source': {'platform': 'youtube'},
      },
    ],
    'seasonalIndexedIds': [],
    'hasMore': true,
    'displayedSections': {
      '실시간 인기 레시피': [
        {
          'id': 'r1',
          'status': 'completed',
          'title': '테스트',
        },
      ],
    },
    'displayedSeasonal': [],
  };

  group('LocalStorageService home trending cache', () {
    test('save writes at key and payload key separately', () async {
      final at = DateTime.now();
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: at,
        payload: minimalPayload(),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('home_trending_feed_cache_at_v1'), isNotNull);
      expect(prefs.getString('home_trending_feed_cache_v1'), isNotNull);
      expect(
        prefs.getString('home_trending_feed_cache_v1')!.contains('"snapshot"'),
        isFalse,
      );
    });

    test('loadHomeTrendingFeedCacheCachedAt reads at key without payload decode',
        () async {
      final at = DateTime(2026, 6, 4, 12, 0, 0);
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: at,
        payload: minimalPayload(),
      );
      final loaded = await localStorage.loadHomeTrendingFeedCacheCachedAt();
      expect(loaded, at);
    });

    test('legacy wrapped payload still exposes cachedAt via meta loader', () async {
      final at = DateTime(2026, 6, 4, 10, 0, 0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'home_trending_feed_cache_v1',
        jsonEncode({
          'cachedAt': at.toIso8601String(),
          'snapshot': minimalPayload(),
        }),
      );
      final loaded = await localStorage.loadHomeTrendingFeedCacheCachedAt();
      expect(loaded, at);
    });

    test('payload round-trip preserves section titles', () async {
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: DateTime.now(),
        payload: minimalPayload(),
      );
      final payload = await localStorage.loadHomeTrendingFeedCachePayload();
      expect(payload, isNotNull);
      final sections = payload!['displayedSections'] as Map;
      expect(sections['실시간 인기 레시피'], isA<List>());
      expect((sections['실시간 인기 레시피'] as List).length, 1);
    });

    test('clear removes at and payload keys', () async {
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: DateTime.now(),
        payload: minimalPayload(),
      );
      await localStorage.clearHomeTrendingFeedCache();
      expect(await localStorage.loadHomeTrendingFeedCacheCachedAt(), isNull);
      expect(await localStorage.hasHomeTrendingFeedCachePayload(), isFalse);
    });
  });

  group('home trending TTL (matches RecipeService _exploreCacheTtl)', () {
    const exploreCacheTtl = Duration(hours: 1);

    bool isFresh(DateTime cachedAt) =>
        DateTime.now().difference(cachedAt) <= exploreCacheTtl;

    test('fresh within one hour', () async {
      final at = DateTime.now().subtract(const Duration(minutes: 30));
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: at,
        payload: minimalPayload(),
      );
      final loaded = await localStorage.loadHomeTrendingFeedCacheCachedAt();
      expect(loaded, isNotNull);
      expect(isFresh(loaded!), isTrue);
    });

    test('expired after one hour — meta still readable, TTL false', () async {
      final at = DateTime.now().subtract(const Duration(hours: 2));
      await localStorage.saveHomeTrendingFeedCache(
        cachedAt: at,
        payload: minimalPayload(),
      );
      final loaded = await localStorage.loadHomeTrendingFeedCacheCachedAt();
      expect(loaded, isNotNull);
      expect(isFresh(loaded!), isFalse);
    });

    test('meta-only read is faster than loading expired legacy blob', () async {
      final huge = List.generate(
        80,
        (i) => {
          'id': 'id_$i',
          'status': 'completed',
          'title': 'recipe $i',
          'source': {'platform': 'youtube'},
          'recipe': {'ingredients': List.filled(20, {'name': 'a'})},
        },
      );
      final legacyBlob = jsonEncode({
        'cachedAt': DateTime.now()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
        'snapshot': {
          'allRecipes': huge,
          'naverRecipes': huge,
          'seasonalIndexedIds': [],
          'hasMore': true,
          'naverHasMore': true,
          'displayedSections': {},
          'displayedSeasonal': [],
        },
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('home_trending_feed_cache_v1', legacyBlob);

      final sw = Stopwatch()..start();
      final at = await localStorage.loadHomeTrendingFeedCacheCachedAt();
      sw.stop();
      expect(at, isNotNull);
      expect(
        sw.elapsedMilliseconds,
        lessThan(50),
        reason: 'meta read should not jsonDecode the legacy blob',
      );

      final fullSw = Stopwatch()..start();
      jsonDecode(legacyBlob);
      fullSw.stop();
      expect(
        sw.elapsedMilliseconds,
        lessThan(fullSw.elapsedMilliseconds ~/ 2),
        reason: 'meta path should be much faster than full decode',
      );
    });
  });
}

