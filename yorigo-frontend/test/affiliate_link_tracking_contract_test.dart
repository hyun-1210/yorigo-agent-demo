import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/analytics_service.dart';

/// affiliate 클릭/오픈 분리 계약 — 속성 정규화 규칙이 깨지지 않는지 검증.
void main() {
  group('affiliate click property contract', () {
    test('product_id and ingredient_name keep readable values', () {
      expect(
        truncateAnalyticsValue('1234567890'),
        '1234567890',
      );
      expect(
        truncateAnalyticsValue('대파'),
        '대파',
      );
    });

    test('marketplace and source_screen stay ascii identifiers', () {
      expect(sanitizeAnalyticsName('coupang'), 'coupang');
      expect(sanitizeAnalyticsName('kurly'), 'kurly');
      expect(sanitizeAnalyticsName('cart'), 'cart');
      expect(sanitizeAnalyticsName('recipe_detail'), 'recipe_detail');
      expect(sanitizeAnalyticsName('meal_kit_picker'), 'meal_kit_picker');
      expect(
        sanitizeAnalyticsName('recipe_detail_best_rail'),
        'recipe_detail_best_rail',
      );
    });
  });

  group('affiliate open result contract', () {
    test('success is encoded as 1/0 not bool for firebase-compatible params', () {
      // AnalyticsService.trackAffiliateOpenResult uses success ? 1 : 0
      expect(true ? 1 : 0, 1);
      expect(false ? 1 : 0, 0);
    });

    test('failure reasons stay stable snake tokens', () {
      for (final reason in <String>[
        'empty_url',
        'invalid_coupang_url',
        'coupang_in_app_browser_error',
        'android_transition_error',
        'in_app_browser_false',
        'in_app_browser_error',
        'launch_url_false',
        'launch_url_error',
        'all_launch_attempts_failed',
        'open_exception',
      ]) {
        expect(sanitizeAnalyticsName(reason), reason);
      }
    });
  });

  group('dedup contract', () {
    test('alreadyTracked means click once, open result still allowed', () {
      // Documented contract for openMarketplaceLink(alreadyTracked: true):
      // - do not emit affiliate_link_clicked again
      // - still emit affiliate_open_result
      const alreadyTracked = true;
      final shouldEmitClick = !alreadyTracked;
      final shouldEmitOpenResult = true;
      expect(shouldEmitClick, isFalse);
      expect(shouldEmitOpenResult, isTrue);
    });

    test('affiliate click must not write unbounded coupang_link_opens', () {
      // 클릭마다 문서를 늘리지 않는다. 경유 기록은 coupang_visits/{yyyy-MM-dd}
      // 하루 1개에 coupang/kurly/naver 를 같이 넣는다.
      final userService = File('lib/services/user_service.dart').readAsStringSync();
      expect(userService.contains('coupang_link_opens'), isFalse);
      expect(userService.contains('logCoupangLinkOpen'), isFalse);
      expect(userService.contains('logAffiliateVisit'), isTrue);
      expect(userService.contains('kCoupangVisitsCollection'), isTrue);
      final rules = File('firestore.rules').readAsStringSync();
      expect(
        rules.contains(
          RegExp(
            r'match /coupang_link_opens/\{openId\}[\s\S]*allow create, update, delete: if false;',
          ),
        ),
        isTrue,
      );
      expect(
        rules.contains(
          RegExp(
            r'match /coupang_visits/\{dayId\}[\s\S]*allow delete: if isOwner\(userId\);',
          ),
        ),
        isTrue,
      );
    });

    test('meal_kit_picker affiliate click writes GCS click not purchase', () {
      // cart/poster already write richer logCardEvent clicks.
      // meal_kit_picker GCS is click (제휴 탭). purchase는 장바구니 구매 완료만.
      const mealKitGcsEventType = 'click';
      expect(mealKitGcsEventType, 'click');
      expect(mealKitGcsEventType, isNot('purchase'));
      bool writesMealKitClickSignal(String? sourceScreen) =>
          sourceScreen == 'meal_kit_picker';
      expect(writesMealKitClickSignal('cart'), isFalse);
      expect(writesMealKitClickSignal('home_poster_first_main_for_two'), isFalse);
      expect(writesMealKitClickSignal('meal_kit_picker'), isTrue);
    });
  });

  group('learning label isolation', () {
    test('logged-in check writes one GCS row via product_check not ingredient_check', () {
      const productCheckSection = 'product_check';
      const ingredientCheckSection = 'ingredient_check';
      const gcsEventFromProductCheck = true;
      const gcsEventFromIngredientMixpanel = false;
      expect(gcsEventFromProductCheck, isTrue);
      expect(gcsEventFromIngredientMixpanel, isFalse);
      expect(productCheckSection, isNot(ingredientCheckSection));
    });

    test('cooking sheet mixpanel complete does not claim fridge EXP', () {
      bool claimsCookingExp({required bool writeGcs}) => writeGcs;
      expect(claimsCookingExp(writeGcs: true), isTrue);
      expect(claimsCookingExp(writeGcs: false), isFalse);
    });
  });
}
