import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/analytics_service.dart';

void main() {
  group('cart marketplace selected contract', () {
    test('method tokens are stable ascii ids', () {
      expect(sanitizeAnalyticsName('tab'), 'tab');
      expect(sanitizeAnalyticsName('swipe'), 'swipe');
      expect(sanitizeAnalyticsName('coupang'), 'coupang');
      expect(sanitizeAnalyticsName('kurly'), 'kurly');
    });
  });

  group('cart alternative products contract', () {
    test('ingredient labels keep korean via truncate', () {
      expect(truncateAnalyticsValue('대파'), '대파');
      expect(truncateAnalyticsValue('딱 필요한 양'), '딱 필요한 양');
    });

    test('sort tokens are sanitized identifiers', () {
      expect(sanitizeAnalyticsName('price'), 'price');
      expect(sanitizeAnalyticsName('recommend'), 'recommend');
    });

    test('filter chip labels keep korean', () {
      expect(truncateAnalyticsValue('전체'), '전체');
      expect(truncateAnalyticsValue('가성비'), '가성비');
    });
  });

  group('cart product buy clicked contract', () {
    test('source tokens are stable', () {
      expect(sanitizeAnalyticsName('main_card'), 'main_card');
      expect(sanitizeAnalyticsName('alt_sheet'), 'alt_sheet');
    });

    test('recipe_id stays as a raw document id', () {
      expect(
        truncateAnalyticsValue('JkyKwbagKquuoboncVGK'),
        'JkyKwbagKquuoboncVGK',
      );
    });
  });

  group('recipe cart ingredients added contract', () {
    test('source and ingredient labels stay queryable', () {
      expect(sanitizeAnalyticsName('recipe_detail'), 'recipe_detail');
      expect(sanitizeAnalyticsName('meal_plan'), 'meal_plan');
      expect(sanitizeAnalyticsName('kurly'), 'kurly');
      expect(truncateAnalyticsValue('목살'), '목살');
    });
  });

  group('fridge ingest from cart contract', () {
    test('method and section ids stay ascii join keys', () {
      expect(sanitizeAnalyticsName('cart'), 'cart');
      expect(sanitizeAnalyticsName('manual'), 'manual');
      expect(sanitizeAnalyticsName('manual_batch'), 'manual_batch');
      expect(sanitizeAnalyticsName('fridge_add'), 'fridge_add');
      expect(sanitizeAnalyticsName('purchase_complete'), 'purchase_complete');
      expect(
        sanitizeAnalyticsName('ingredient_purchased'),
        'ingredient_purchased',
      );
    });

    test('ingredient and recipe ids stay queryable', () {
      expect(truncateAnalyticsValue('목살'), '목살');
      expect(
        truncateAnalyticsValue('JkyKwbagKquuoboncVGK'),
        'JkyKwbagKquuoboncVGK',
      );
    });
  });
}
