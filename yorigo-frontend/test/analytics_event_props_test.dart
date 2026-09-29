import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/analytics_service.dart';
import 'package:yorigo/services/local_storage_service.dart';

void main() {
  group('sanitizeAnalyticsName', () {
    test('keeps ascii identifiers', () {
      expect(sanitizeAnalyticsName('coupang'), 'coupang');
      expect(sanitizeAnalyticsName('Cart_Tab'), 'cart_tab');
    });

    test('strips korean so ids stay ascii-safe', () {
      expect(sanitizeAnalyticsName('단백질 많은'), 'unknown');
      expect(sanitizeAnalyticsName('홈_section'), 'section');
    });

    test('collapses separators and truncates length', () {
      expect(sanitizeAnalyticsName('  a--b__c  '), 'a_b_c');
      final long = 'a' * 80;
      expect(sanitizeAnalyticsName(long).length, 40);
    });
  });

  group('truncateAnalyticsValue', () {
    test('preserves korean labels for category/section names', () {
      expect(
        truncateAnalyticsValue('단백질 많은'),
        '단백질 많은',
      );
      expect(
        truncateAnalyticsValue('맥주 곁들이는 안주 한 상'),
        '맥주 곁들이는 안주 한 상',
      );
    });

    test('falls back on empty and truncates over 100 chars', () {
      expect(truncateAnalyticsValue('   '), 'unknown');
      final long = '한' * 120;
      expect(truncateAnalyticsValue(long).length, 100);
    });
  });

  group('stableAnalyticsId', () {
    test('maps home primary filter korean labels to joinable ascii ids', () {
      expect(kHomePrimaryFilterIds['전체'], 'all');
      expect(stableAnalyticsId('전체'), 'all');
      expect(stableAnalyticsId('메뉴별'), 'menu');
      expect(stableAnalyticsId('나라별'), 'country');
      expect(stableAnalyticsId('재료별'), 'ingredient');
      expect(stableAnalyticsId('시간'), 'time');
    });

    test('keeps ascii keys and does not collapse korean to unknown', () {
      expect(stableAnalyticsId('high_protein'), 'high_protein');
      expect(stableAnalyticsId('단백질 많은'), isNot('unknown'));
      expect(stableAnalyticsId('단백질 많은'), startsWith('k_'));
      expect(stableAnalyticsId('단백질 많은'), stableAnalyticsId('단백질 많은'));
    });

    test('empty falls back', () {
      expect(stableAnalyticsId('   '), 'unknown');
    });
  });

  group('resolveRecipeViewSource', () {
    test('uses pending card screen when fallback is recipe_detail', () {
      expect(
        resolveRecipeViewSource(
          fallback: 'recipe_detail',
          recipeId: 'abc',
          pendingRecipeId: 'abc',
          pendingScreen: 'home',
        ),
        'home',
      );
    });

    test('keeps explicit non-detail fallback', () {
      expect(
        resolveRecipeViewSource(
          fallback: 'fridge',
          recipeId: 'abc',
          pendingRecipeId: 'abc',
          pendingScreen: 'home',
        ),
        'fridge',
      );
    });

    test('ignores pending source for a different recipe', () {
      expect(
        resolveRecipeViewSource(
          fallback: 'recipe_detail',
          recipeId: 'abc',
          pendingRecipeId: 'other',
          pendingScreen: 'home',
        ),
        'recipe_detail',
      );
    });
  });

  group('label vs id contract', () {
    test('home section uses sanitize for id and truncate for name', () {
      const label = '단백질 많은';
      const key = 'high_protein';
      expect(sanitizeAnalyticsName(key), 'high_protein');
      expect(truncateAnalyticsValue(label), label);
      expect(sanitizeAnalyticsName(label), 'unknown');
      expect(stableAnalyticsId(label), isNot('unknown'));
    });
  });

  group('overlay recipe id for analytics', () {
    test('reads recipeId from uid::recipeId keys and skips urls', () {
      expect(
        LocalStorageService.overlayRecipeIdForAnalytics('uid123::recipe_abc'),
        'recipe_abc',
      );
      expect(
        LocalStorageService.overlayRecipeIdForAnalytics(
          'uid123::https://youtu.be/xyz',
        ),
        isNull,
      );
      expect(
        LocalStorageService.overlayRecipeIdForAnalytics('plain_recipe_id'),
        'plain_recipe_id',
      );
    });
  });
}
