import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yorigo/services/coupang_service.dart';
import 'package:yorigo/utils/best_ingredient_products.dart';
import 'package:yorigo/widgets/best_ingredient_products_rail.dart';

CoupangProduct _product() {
  return CoupangProduct(
    productId: 'p1',
    productName: '국내산 양파 1kg',
    productPrice: 3980,
    productImage: '',
    productUrl: 'https://example.com/p1',
    rating: 4.7,
    reviews: 1280,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('hides when not loading and there are no cards', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BestIngredientProductsRail(
          cards: const [],
          loading: false,
        ),
      ),
    );
    expect(find.text(kBestIngredientProductsRailTitle), findsNothing);
  });

  testWidgets('shows title and skeletons while loading', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BestIngredientProductsRail(
          cards: const [],
          loading: true,
          skeletonCount: 3,
        ),
      ),
    );
    expect(find.text(kBestIngredientProductsRailTitle), findsOneWidget);
    expect(find.text(kBestIngredientProductsRailSubtitle), findsOneWidget);
    expect(find.text(kBestIngredientProductsCompareCta), findsNothing);
  });

  testWidgets('shows price rating reviews without compare CTA', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BestIngredientProductsRail(
          cards: [
            BestIngredientProductCard(
              ingredientName: '양파',
              product: _product(),
              marketplace: 'coupang',
            ),
          ],
          loading: false,
        ),
      ),
    );

    expect(find.text(kBestIngredientProductsRailTitle), findsOneWidget);
    expect(find.text('양파'), findsOneWidget);
    expect(find.text('국내산 양파 1kg'), findsOneWidget);
    expect(find.text('3,980원'), findsOneWidget);
    expect(find.text('4.7'), findsOneWidget);
    expect(find.text('(1,280)'), findsOneWidget);
    expect(find.text(kBestIngredientProductsCompareCta), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows coupang/kurly toggle and keeps chrome when empty', (
    tester,
  ) async {
    var selected = 'coupang';
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return BestIngredientProductsRail(
              cards: const [],
              loading: false,
              marketplace: selected,
              onMarketplaceChanged: (value) => setState(() => selected = value),
            );
          },
        ),
      ),
    );

    expect(find.text(kBestIngredientProductsRailTitle), findsOneWidget);
    expect(find.text('쿠팡'), findsOneWidget);
    expect(find.text('컬리'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text(kBestIngredientProductsEmptyMarketplace), findsOneWidget);
    expect(find.text(kBestIngredientProductsCompareCta), findsNothing);

    await tester.tap(find.text('컬리'));
    await tester.pump();
    expect(find.text('컬리'), findsOneWidget);
    expect(
      find.text(kBestIngredientProductsKurlyAffiliateDisclosure),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('open-cart CTA sits under the disclosure', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      _wrap(
        BestIngredientProductsRail(
          cards: [
            BestIngredientProductCard(
              ingredientName: '양파',
              product: _product(),
              marketplace: 'coupang',
            ),
          ],
          loading: false,
          marketplace: 'coupang',
          onMarketplaceChanged: (_) {},
          onOpenCart: () => opened = true,
        ),
      ),
    );

    expect(find.text(kBestIngredientProductsCompareCta), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('best_ingredient_open_cart')));
    await tester.pump();
    expect(opened, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows price info bubble and marketplace disclosure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BestIngredientProductsRail(
          cards: [
            BestIngredientProductCard(
              ingredientName: '양파',
              product: _product(),
              marketplace: 'coupang',
            ),
          ],
          loading: false,
          marketplace: 'coupang',
          onMarketplaceChanged: (_) {},
        ),
      ),
    );

    expect(
      find.text(kBestIngredientProductsCoupangAffiliateDisclosure),
      findsOneWidget,
    );
    expect(find.text(kBestIngredientProductsPriceDisclaimer), findsNothing);

    await tester.tap(find.byKey(const ValueKey('best_ingredient_price_info')));
    await tester.pumpAndSettle();
    expect(find.text(kBestIngredientProductsPriceDisclaimer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
