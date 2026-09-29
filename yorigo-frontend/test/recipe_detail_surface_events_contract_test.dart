import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/analytics_service.dart';
import 'package:yorigo/utils/recipe_pairing.dart';

/// 레시피 상세 신규 표면(곁들임·연관 레일·밀키트·레시피북) 이벤트 키 계약.
void main() {
  group('pairing chip ids stay ascii join keys', () {
    test('lane ids are stable identifiers', () {
      for (final id in const ['side', 'drink', 'alcohol', 'dessert', 'anju']) {
        expect(sanitizeAnalyticsName(id), id);
      }
    });

    test('korean labels are preserved as display names only', () {
      expect(truncateAnalyticsValue('반찬'), '반찬');
      expect(truncateAnalyticsValue('음료'), '음료');
      expect(sanitizeAnalyticsName('반찬'), 'unknown');
    });

    test('resolvePairingPlan emits only ascii lane ids', () {
      final plan = resolvePairingPlan(
        dishName: '김치찌개',
        menuTypes: ['국 / 찌개 / 탕'],
        tags: ['매콤한'],
        country: ['한식'],
      );
      for (final lane in plan.lanes) {
        expect(lane.id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
        expect(sanitizeAnalyticsName(lane.id), lane.id);
      }
    });
  });

  group('related rail section ids', () {
    test('detail rails use stable ascii keys not korean titles', () {
      for (final id in const [
        'similar_recipes',
        'main_ingredient_recipes',
        'menu_type_recipes',
        'popular_cooked_recipes',
        'pairing_side',
        'pairing_drink',
        'pairing_alcohol',
        'pairing_chip',
        'meal_kit',
        'recipebook',
        'cart_confirm',
        'cart_add_footer',
        'fridge_add',
        'best_ingredient_products',
      ]) {
        expect(sanitizeAnalyticsName(id), id);
      }
    });

    test('compare CTA content type stays ascii', () {
      expect(sanitizeAnalyticsName('cart_compare_cta'), 'cart_compare_cta');
      expect(sanitizeAnalyticsName('product'), 'product');
    });

    test('best product rail sits before reviews with coupang/kurly toggle', () {
      final detail =
          File('lib/screens/recipe_detail_screen.dart').readAsStringSync();
      expect(detail.contains('BestIngredientProductsRail'), isTrue);
      expect(detail.contains('RecipeRecoLoadMode.preview'), isTrue);
      expect(detail.contains('RecipeRecoLoadMode.previewFallback'), isFalse);
      expect(detail.contains('recordCartHit: !isPreview'), isTrue);
      expect(detail.contains('includeSeeMore: !isPreview'), isTrue);
      expect(detail.contains('_startPreviewRecommendations()'), isTrue);
      expect(
        detail.contains("unawaited(_startPreviewRecommendations());"),
        isTrue,
      );
      expect(
        detail.contains('_hydrateRecipeRecommendationsFromDiskAndNotify'),
        isTrue,
      );
      expect(
        detail.contains('best_ingredient_preview_visible_'),
        isTrue,
      );
      expect(detail.contains('kDefaultPreviewMarketplace'), isTrue);
      expect(detail.contains('String _previewMarketplace()'), isFalse);
      expect(
        detail.contains('peekOnboardingProfile()?.preferredMarketplace'),
        isFalse,
      );
      expect(detail.contains('otherPreviewMarketplace('), isFalse);
      expect(detail.contains('shouldRetryPreviewStream'), isTrue);
      expect(detail.contains('shouldHidePreviewRail'), isTrue);
      final reviewIdx = detail.indexOf('_buildReviewSummaryCard(brightness)');
      final railIdx = detail.indexOf('_buildBestIngredientProductsRail()');
      final pairingIdx = detail.indexOf('_buildPairingSection(brightness)');
      expect(railIdx, greaterThan(0));
      expect(reviewIdx, greaterThan(railIdx));
      expect(pairingIdx, greaterThan(reviewIdx));
      final util =
          File('lib/utils/best_ingredient_products.dart').readAsStringSync();
      expect(util.contains('recipe_detail_best_rail'), isTrue);
      expect(util.contains('best_ingredient_products'), isTrue);
      expect(util.contains('include_see_more'), isTrue);
      expect(util.contains('shouldSkipPreviewFallbackFetch'), isFalse);
      expect(util.contains('kDefaultPreviewMarketplace'), isTrue);
      expect(util.contains('otherPreviewMarketplace'), isTrue);
    });
  });

  group('meal kit affiliate source', () {
    test('meal_kit_picker stays an ascii source_screen', () {
      expect(sanitizeAnalyticsName('meal_kit_picker'), 'meal_kit_picker');
      expect(sanitizeAnalyticsName('recipe_detail'), 'recipe_detail');
    });
  });

  group('recipebook click contract', () {
    test('view mode tokens stay ascii', () {
      expect(sanitizeAnalyticsName('grid'), 'grid');
      expect(sanitizeAnalyticsName('list'), 'list');
    });
  });

  group('recipe agent chip and section ids', () {
    test('preset chips stay ascii join keys', () {
      for (final id in const [
        'missing_ingredient',
        'less_spicy',
        'air_fryer',
        'easier_step',
        'freeform',
        'recipe_agent',
        'recipe_agent_turn',
        'recipe_agent_apply',
        'recipe_agent_dismiss',
      ]) {
        expect(sanitizeAnalyticsName(id), id);
      }
    });
  });

  group('video play/dwell platform contract', () {
    test('watch-ended callers must pass source platform not default youtube', () {
      const defaultPlatform = 'youtube';
      String resolvedPlatform(String? raw) {
        final platform = (raw ?? '').trim();
        return platform.isEmpty ? 'unknown' : platform;
      }

      expect(resolvedPlatform('instagram'), isNot(defaultPlatform));
      expect(resolvedPlatform('instagramweb'), 'instagramweb');
      expect(resolvedPlatform('tiktok'), 'tiktok');
      expect(resolvedPlatform('youtube'), 'youtube');
      expect(resolvedPlatform(''), 'unknown');
      expect(resolvedPlatform(null), 'unknown');
    });

    test('instagram player exposes first-play and watch-ended hooks', () {
      final text =
          File('lib/widgets/instagram_player_widget.dart').readAsStringSync();
      expect(text.contains('onFirstPlay'), isTrue);
      expect(text.contains('onWatchEnded'), isTrue);
      expect(text.contains('_flushWatchEnded'), isTrue);
    });

    test('recipe detail instagram wires play and dwell', () {
      final text =
          File('lib/screens/recipe_detail_screen.dart').readAsStringSync();
      expect(
        RegExp(
          r'InstagramPlayerWidget\([\s\S]*?onFirstPlay: _trackRecipeVideoPlay',
        ).hasMatch(text),
        isTrue,
      );
      expect(
        RegExp(
          r'InstagramPlayerWidget\([\s\S]*?onWatchEnded: _trackRecipeVideoWatchEnded',
        ).hasMatch(text),
        isTrue,
      );
      expect(
        text.contains('onUserPlayedInPlayer: _trackRecipeVideoPlay'),
        isFalse,
      );
    });

    test('cooking sheet instagram wires play and dwell with source platform', () {
      final text =
          File('lib/widgets/cooking_instruction_sheet.dart').readAsStringSync();
      expect(
        RegExp(
          r'InstagramPlayerWidget\([\s\S]*?onFirstPlay: _trackCookingVideoPlay',
        ).hasMatch(text),
        isTrue,
      );
      expect(
        RegExp(
          r'InstagramPlayerWidget\([\s\S]*?onWatchEnded: _trackCookingVideoWatchEnded',
        ).hasMatch(text),
        isTrue,
      );
      expect(text.contains("platform: _cookingVideoPlatform()"), isTrue);
    });
  });
}
