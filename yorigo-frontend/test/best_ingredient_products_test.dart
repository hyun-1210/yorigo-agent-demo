import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/models/recipe_models.dart';
import 'package:yorigo/services/coupang_service.dart';
import 'package:yorigo/utils/best_ingredient_products.dart';

CoupangProduct _product({
  required String id,
  required String name,
  int price = 3900,
  double? rating = 4.6,
  int? reviews = 1280,
}) {
  return CoupangProduct(
    productId: id,
    productName: name,
    productPrice: price,
    productImage: '',
    productUrl: 'https://example.com/$id',
    rating: rating,
    reviews: reviews,
  );
}

ProductRecommendation _reco({CoupangProduct? best, List<CoupangProduct>? seeMore}) {
  return ProductRecommendation(
    ingredient: 'x',
    bestMatch: best,
    seeMoreList: seeMore ?? const [],
    allProducts: seeMore ?? const [],
  );
}

void main() {
  group('previewMarketplaceOf', () {
    test('defaults to coupang', () {
      expect(previewMarketplaceOf(null), kDefaultPreviewMarketplace);
      expect(previewMarketplaceOf(''), kDefaultPreviewMarketplace);
      expect(previewMarketplaceOf('oasis'), kDefaultPreviewMarketplace);
      expect(previewMarketplaceOf('ssg'), kDefaultPreviewMarketplace);
      expect(kDefaultPreviewMarketplace, 'coupang');
    });

    test('uses kurly only when preferred', () {
      expect(previewMarketplaceOf('kurly'), 'kurly');
      expect(previewMarketplaceOf('Kurly'), 'kurly');
      expect(previewMarketplaceOf('market_kurly'), 'kurly');
    });

    test('otherPreviewMarketplace flips coupang and kurly', () {
      expect(otherPreviewMarketplace('coupang'), 'kurly');
      expect(otherPreviewMarketplace('kurly'), 'coupang');
    });

    test('affiliate disclosure follows the visible marketplace', () {
      expect(
        previewRailAffiliateDisclosure('coupang'),
        kBestIngredientProductsCoupangAffiliateDisclosure,
      );
      expect(
        previewRailAffiliateDisclosure('kurly'),
        kBestIngredientProductsKurlyAffiliateDisclosure,
      );
    });
  });

  group('selectPreviewIngredients', () {
    test('skips pantry staples and empty names', () {
      final selected = selectPreviewIngredients([
        Ingredient(item: '소금', qty: 1, unit: '작은술'),
        Ingredient(item: '물', qty: 200, unit: 'ml'),
        Ingredient(item: '돼지고기', qty: 200, unit: 'g'),
        Ingredient(item: '양파', qty: 1, unit: '개'),
      ]);
      expect(selected.map((e) => e.item), ['돼지고기', '양파']);
    });

    test('dedupes by name and caps at max', () {
      final selected = selectPreviewIngredients(
        [
          Ingredient(item: '돼지고기', qty: 100, unit: 'g'),
          Ingredient(item: '돼지고기', qty: 50, unit: 'g'),
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 1, unit: '대'),
        ],
        max: 2,
      );
      expect(selected.map((e) => e.item), ['돼지고기', '양파']);
    });

    test('returns empty when only pantry items exist', () {
      expect(
        selectPreviewIngredients([
          Ingredient(item: '소금'),
          Ingredient(item: '설탕'),
        ]),
        isEmpty,
      );
    });
  });

  group('mapBestMatchCards', () {
    test('uses best_match only and hides missing recos', () {
      final seeMore = _product(id: 'alt', name: '다른 양파');
      final cards = mapBestMatchCards(
        previewIngredients: [
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 1, unit: '대'),
          Ingredient(item: '마늘', qty: 10, unit: 'g'),
        ],
        recommendations: {
          'coupang:양파': _reco(
            best: _product(id: 'onion', name: '양파 1kg'),
            seeMore: [seeMore],
          ),
          'coupang:대파': _reco(best: null, seeMore: [seeMore]),
          'kurly:마늘': _reco(best: _product(id: 'garlic', name: '마늘')),
        },
        marketplace: 'coupang',
      );
      expect(cards, hasLength(1));
      expect(cards.single.ingredientName, '양파');
      expect(cards.single.product.productId, 'onion');
      expect(cards.map((c) => c.product.productId), isNot(contains('alt')));
    });

    test('does not mix the other marketplace into the selected rail', () {
      final cards = mapBestMatchCards(
        previewIngredients: [
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 1, unit: '대'),
          Ingredient(item: '마늘', qty: 10, unit: 'g'),
        ],
        recommendations: {
          'coupang:양파': _reco(best: _product(id: 'onion', name: '양파 1kg')),
          'kurly:양파': _reco(best: _product(id: 'kurly-onion', name: '컬리 양파')),
          'kurly:대파': _reco(best: _product(id: 'kurly-green', name: '컬리 대파')),
        },
        marketplace: 'coupang',
      );
      expect(cards.map((c) => c.ingredientName), ['양파']);
      expect(cards.map((c) => c.marketplace), ['coupang']);
      expect(cards.single.product.productId, 'onion');

      final kurlyCards = mapBestMatchCards(
        previewIngredients: [
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 1, unit: '대'),
          Ingredient(item: '마늘', qty: 10, unit: 'g'),
        ],
        recommendations: {
          'coupang:양파': _reco(best: _product(id: 'onion', name: '양파 1kg')),
          'kurly:양파': _reco(best: _product(id: 'kurly-onion', name: '컬리 양파')),
          'kurly:대파': _reco(best: _product(id: 'kurly-green', name: '컬리 대파')),
        },
        marketplace: 'kurly',
      );
      expect(kurlyCards.map((c) => c.ingredientName), ['양파', '대파']);
      expect(kurlyCards.map((c) => c.marketplace), ['kurly', 'kurly']);
      expect(
        kurlyCards.map((c) => c.product.productId),
        ['kurly-onion', 'kurly-green'],
      );
    });
  });

  group('buildRecommendationStreamItems', () {
    test('preview items set record_cart_hit false and skip loaded keys', () {
      final items = buildRecommendationStreamItems(
        ingredients: [
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 0.5, unit: '대'),
        ],
        marketplaces: const ['coupang'],
        scaledQtyOf: (ing) => (ing.qty ?? 0) * 2,
        alreadyLoaded: (mp, name, qty) => name == '양파',
        recordCartHit: false,
        includeSeeMore: false,
      );
      expect(items, hasLength(1));
      expect(items.single['ingredient_name'], '대파');
      expect(items.single['needed_qty'], 1.0);
      expect(items.single['marketplace'], 'coupang');
      expect(items.single['record_cart_hit'], isFalse);
      expect(items.single['include_see_more'], isFalse);
    });

    test('full items hit both marketplaces with cart_hit and see_more on', () {
      final items = buildRecommendationStreamItems(
        ingredients: [Ingredient(item: '양파', qty: 1, unit: '개')],
        marketplaces: const ['coupang', 'kurly'],
        scaledQtyOf: (ing) => ing.qty ?? 0,
        alreadyLoaded: (mp, name, qty) => false,
        recordCartHit: true,
        includeSeeMore: true,
      );
      expect(items.map((e) => e['marketplace']), ['coupang', 'kurly']);
      expect(items.every((e) => e['record_cart_hit'] == true), isTrue);
      expect(items.every((e) => e['include_see_more'] == true), isTrue);
    });

    test('preview can request both marketplaces independently', () {
      final items = buildRecommendationStreamItems(
        ingredients: [
          Ingredient(item: '양파', qty: 1, unit: '개'),
          Ingredient(item: '대파', qty: 1, unit: '대'),
        ],
        marketplaces: const ['kurly'],
        scaledQtyOf: (ing) => ing.qty ?? 0,
        alreadyLoaded: (mp, name, qty) => false,
        recordCartHit: false,
        includeSeeMore: false,
      );
      expect(items, hasLength(2));
      expect(items.map((e) => e['ingredient_name']), ['양파', '대파']);
      expect(items.every((e) => e['marketplace'] == 'kurly'), isTrue);
      expect(items.every((e) => e['record_cart_hit'] == false), isTrue);
    });
  });

  group('recommendation cache policy', () {
    test('preview skips any cached key and session-empty misses', () {
      expect(
        shouldSkipRecommendationFetch(
          cached: null,
          isPreview: true,
          attemptedEmpty: true,
        ),
        isTrue,
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: _reco(best: _product(id: 'onion', name: '양파')),
          isPreview: true,
          attemptedEmpty: false,
        ),
        isTrue,
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: null,
          isPreview: true,
          attemptedEmpty: false,
        ),
        isFalse,
      );
    });

    test('preview rail labels stay coupang then kurly', () {
      expect(previewRailMarketplaceLabel('coupang'), '쿠팡');
      expect(previewRailMarketplaceLabel('kurly'), '컬리');
      expect(
        previewRailMarketplaceIconAsset('coupang'),
        'assets/marketplace/coupang_app_icon.png',
      );
      expect(
        previewRailMarketplaceIconAsset('kurly'),
        'assets/marketplace/kurly_app_icon.png',
      );
      expect(kPreviewRailMarketplaces, ['coupang', 'kurly']);
      expect(isPreviewRailMarketplace('oasis'), isFalse);
    });

    test('hides rail only when both marketplaces finished empty', () {
      final onion = [
        BestIngredientProductCard(
          ingredientName: '양파',
          product: _product(id: 'onion', name: '양파'),
          marketplace: 'coupang',
        ),
      ];
      expect(
        shouldHidePreviewRail(
          hasPreviewTargets: false,
          cardsByMarketplace: const {},
          finishedMarketplaces: const {},
        ),
        isTrue,
      );
      expect(
        isPreviewMarketplaceLoading(
          marketplace: 'coupang',
          finishedMarketplaces: const {},
          hasCards: false,
        ),
        isTrue,
      );
      expect(
        isPreviewMarketplaceLoading(
          marketplace: 'coupang',
          finishedMarketplaces: const {},
          hasCards: true,
        ),
        isFalse,
      );
      expect(
        shouldHidePreviewRail(
          hasPreviewTargets: true,
          cardsByMarketplace: {
            'coupang': const [],
            'kurly': onion,
          },
          finishedMarketplaces: {'coupang'},
        ),
        isFalse,
      );
      expect(
        shouldHidePreviewRail(
          hasPreviewTargets: true,
          cardsByMarketplace: {
            'coupang': const [],
            'kurly': const [],
          },
          finishedMarketplaces: {'coupang', 'kurly'},
        ),
        isTrue,
      );
    });

    test('retries preview only when the stream emitted nothing', () {
      expect(
        shouldRetryPreviewStream(requestedCount: 8, receivedCount: 0),
        isTrue,
      );
      expect(
        shouldRetryPreviewStream(requestedCount: 8, receivedCount: 3),
        isFalse,
      );
      expect(
        shouldRetryPreviewStream(requestedCount: 0, receivedCount: 0),
        isFalse,
      );
      expect(
        unreceivedRecommendationKeys(
          batchItems: [
            {'marketplace': 'coupang', 'ingredient_name': '양파'},
            {'marketplace': 'coupang', 'ingredient_name': '대파'},
          ],
          receivedIndices: {0},
        ),
        ['coupang:대파'],
      );
    });

    test('full refetches slim preview but skips see_more and empty', () {
      final slim = _reco(best: _product(id: 'onion', name: '양파'));
      final full = _reco(
        best: _product(id: 'onion', name: '양파'),
        seeMore: [_product(id: 'alt', name: '다른 양파')],
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: slim,
          isPreview: false,
          attemptedEmpty: false,
        ),
        isFalse,
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: full,
          isPreview: false,
          attemptedEmpty: false,
        ),
        isTrue,
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: null,
          isPreview: false,
          attemptedEmpty: true,
        ),
        isTrue,
      );
    });

    test('full refetches when portion qty drifted', () {
      final cached = ProductRecommendation(
        ingredient: '양파',
        neededQty: 1.0,
        bestMatch: _product(id: 'onion', name: '양파'),
        seeMoreList: [_product(id: 'alt', name: '다른 양파')],
      );
      expect(
        shouldSkipRecommendationFetch(
          cached: cached,
          isPreview: false,
          attemptedEmpty: false,
          neededQty: 4,
        ),
        isFalse,
      );
    });

    test('merge keeps full cache over slim preview', () {
      final existing = _reco(
        best: _product(id: 'onion', name: '양파'),
        seeMore: [_product(id: 'alt', name: '다른 양파')],
      );
      final slim = _reco(best: _product(id: 'onion2', name: '새 양파'));
      expect(
        mergeIncomingRecommendation(existing: existing, incoming: slim),
        same(existing),
      );
      expect(
        mergeIncomingRecommendation(existing: slim, incoming: existing),
        same(existing),
      );
      expect(
        mergeIncomingRecommendation(existing: existing, incoming: _reco()),
        same(existing),
      );
      expect(
        shouldPersistRecommendation(_reco()),
        isFalse,
      );
    });
  });

  group('format helpers', () {
    test('formats price and review counts with commas', () {
      expect(formatWonPrice(12800), '12,800');
      expect(formatReviewCount(1280), '1,280');
    });
  });
}
