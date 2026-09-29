import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../screens/cart_screen.dart'
    show openMarketplaceLink, ShoppingMarketplace;
import '../services/analytics_service.dart';
import '../services/user_service.dart';
import '../utils/best_ingredient_products.dart';
import '../utils/coupang_subparam.dart';
import 'app_network_image.dart';
import 'home_section_chrome.dart';

final Set<String> _bestIngredientProductImpressionFired = <String>{};

/// 레시피 상세 후기 위: 재료당 best_match 1장 가로 레일.
class BestIngredientProductsRail extends StatelessWidget {
  const BestIngredientProductsRail({
    super.key,
    required this.cards,
    required this.loading,
    this.recipeId,
    this.skeletonCount = 4,
    this.marketplace = kDefaultPreviewMarketplace,
    this.onMarketplaceChanged,
    this.onOpenCart,
  });

  final List<BestIngredientProductCard> cards;
  final bool loading;
  final String? recipeId;
  final int skeletonCount;
  final String marketplace;
  final ValueChanged<String>? onMarketplaceChanged;
  final VoidCallback? onOpenCart;

  static const double cardWidth = 148;
  static const double cardImageSize = 148;
  static const double cardCaptionHeight = 74;
  static const double cardRadius = 18;
  static const double cardGap = 12;
  static const double headerToCards = 16;
  static const Color _border = Color(0xFFF3F4F6);
  static const Color _skeleton = Color(0xFFEBECF0);
  static const Color _star = Color(0xFFFFC107);

  static double get carouselHeight => cardImageSize + 8 + cardCaptionHeight;

  @override
  Widget build(BuildContext context) {
    final showToggle = onMarketplaceChanged != null;
    if (!loading && cards.isEmpty && !showToggle) {
      return const SizedBox.shrink();
    }

    final showSkeletons = loading && cards.isEmpty;
    final itemCount = showSkeletons
        ? skeletonCount.clamp(1, kBestIngredientProductMaxCards)
        : cards.length;

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          homeSectionRule(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          kBestIngredientProductsRailTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textHeightBehavior: TextHeightBehavior(
                            applyHeightToFirstAscent: false,
                            applyHeightToLastDescent: false,
                          ),
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111111),
                            letterSpacing: -0.4,
                            height: 1.0,
                          ),
                        ),
                      ),
                      SizedBox(width: 5),
                      _RailPriceInfoButton(),
                    ],
                  ),
                ),
                if (showToggle) ...[
                  const SizedBox(width: 8),
                  _PreviewMarketplaceToggle(
                    marketplace: marketplace,
                    onChanged: onMarketplaceChanged!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
              kBestIngredientProductsRailSubtitle,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF8B95A1),
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: headerToCards),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.topLeft,
                children: <Widget>[
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.045, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: (showSkeletons || cards.isNotEmpty)
                ? SizedBox(
                    key: ValueKey<String>('best-ingredient-rail-$marketplace'),
                    height: carouselHeight,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      physics: const BouncingScrollPhysics(),
                      itemCount: itemCount,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: cardGap),
                      itemBuilder: (context, index) {
                        if (showSkeletons) {
                          return const _BestIngredientProductSkeleton();
                        }
                        final card = cards[index];
                        return _BestIngredientProductCardView(
                          card: card,
                          recipeId: recipeId,
                          position: index,
                        );
                      },
                    ),
                  )
                : Padding(
                    key: ValueKey<String>(
                      'best-ingredient-empty-$marketplace',
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: const Text(
                      kBestIngredientProductsEmptyMarketplace,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8B95A1),
                        letterSpacing: -0.2,
                        height: 1.35,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  previewRailAffiliateDisclosure(marketplace),
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFFB0B8C1),
                    height: 1.2,
                    letterSpacing: -0.35,
                  ),
                ),
              ),
            ),
          ),
          if (onOpenCart != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: InkWell(
                key: const ValueKey<String>('best_ingredient_open_cart'),
                onTap: onOpenCart,
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Text(
                        kBestIngredientProductsCompareCta,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6B7684),
                          letterSpacing: -0.25,
                          height: 1.2,
                        ),
                      ),
                      SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: Color(0xFF6B7684),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
  }
}

class _RailPriceInfoButton extends StatefulWidget {
  const _RailPriceInfoButton();

  @override
  State<_RailPriceInfoButton> createState() => _RailPriceInfoButtonState();
}

class _RailPriceInfoButtonState extends State<_RailPriceInfoButton> {
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context, info) {
        final padding = MediaQuery.paddingOf(context);
        final origin = MatrixUtils.transformPoint(
          info.childPaintTransform,
          Offset.zero,
        );
        final iconRect = origin & info.childSize;
        final target = iconRect.center;
        final overlay = info.overlaySize;
        final margin = EdgeInsets.fromLTRB(
          10,
          math.max(10.0, padding.top + 6),
          10,
          math.max(10.0, padding.bottom + 6),
        );
        final preferBelow =
            iconRect.top - margin.top < _PriceDisclaimerCalloutDelegate.estimatedHeight;
        final ax = ((target.dx / overlay.width) * 2 - 1).clamp(-1.0, 1.0);
        final ay = ((target.dy / overlay.height) * 2 - 1).clamp(-1.0, 1.0);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _portal.hide,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) {
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, (preferBelow ? -4.0 : 4.0) * (1 - t)),
                        child: Transform.scale(
                          alignment: Alignment(ax, ay),
                          scale: 0.94 + (0.06 * t),
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: CustomMultiChildLayout(
                    delegate: _PriceDisclaimerCalloutDelegate(
                      anchor: iconRect,
                      margin: margin,
                      preferBelow: preferBelow,
                    ),
                    children: [
                      LayoutId(
                        id: _CalloutSlot.body,
                        child: const _PriceDisclaimerBody(),
                      ),
                      LayoutId(
                        id: _CalloutSlot.caret,
                        child: CustomPaint(
                          painter: _PriceDisclaimerCaretPainter(
                            color: _PriceDisclaimerBody.fill,
                            pointDown: !preferBelow,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: InkWell(
        key: const ValueKey<String>('best_ingredient_price_info'),
        onTap: () {
          if (_portal.isShowing) {
            _portal.hide();
          } else {
            _portal.show();
          }
        },
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 17,
          height: 17,
          child: Transform.translate(
            offset: const Offset(0, -0.8),
            child: const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: Color(0xFFB0B8C1),
            ),
          ),
        ),
      ),
    );
  }
}

enum _CalloutSlot { body, caret }

class _PriceDisclaimerCalloutDelegate extends MultiChildLayoutDelegate {
  _PriceDisclaimerCalloutDelegate({
    required this.anchor,
    required this.margin,
    required this.preferBelow,
  });

  final Rect anchor;
  final EdgeInsets margin;
  final bool preferBelow;

  static const Size caretSize = Size(14, 7);
  static const double overlap = 1;
  static const double gap = 8;
  static const double radius = 8;
  static const double estimatedHeight = 52;
  static const double maxBodyWidth = 228;

  @override
  void performLayout(Size size) {
    final maxWidth = math.max(
      0.0,
      math.min(maxBodyWidth, size.width - margin.horizontal),
    );
    final bodySize = layoutChild(
      _CalloutSlot.body,
      BoxConstraints(maxWidth: maxWidth),
    );
    layoutChild(
      _CalloutSlot.caret,
      BoxConstraints.tight(caretSize),
    );

    final totalHeight = bodySize.height + caretSize.height - overlap;
    final minX = margin.left;
    final maxX = math.max(minX, size.width - margin.right - bodySize.width);
    final targetX = anchor.center.dx;
    final bubbleX = (targetX - bodySize.width / 2).clamp(minX, maxX);

    final minY = margin.top;
    final maxY = math.max(minY, size.height - margin.bottom - totalHeight);

    final double bodyY;
    final double caretY;
    if (preferBelow) {
      caretY = (anchor.bottom + gap).clamp(minY, maxY);
      bodyY = caretY + caretSize.height - overlap;
    } else {
      bodyY = (anchor.top - gap - totalHeight).clamp(minY, maxY);
      caretY = bodyY + bodySize.height - overlap;
    }

    final caretMinX = bubbleX + radius;
    final caretMaxX = math.max(
      caretMinX,
      bubbleX + bodySize.width - radius - caretSize.width,
    );
    final caretX = (targetX - caretSize.width / 2).clamp(caretMinX, caretMaxX);

    positionChild(_CalloutSlot.body, Offset(bubbleX, bodyY));
    positionChild(_CalloutSlot.caret, Offset(caretX, caretY));
  }

  @override
  bool shouldRelayout(covariant _PriceDisclaimerCalloutDelegate oldDelegate) {
    return anchor != oldDelegate.anchor ||
        margin != oldDelegate.margin ||
        preferBelow != oldDelegate.preferBelow;
  }
}

class _PriceDisclaimerBody extends StatelessWidget {
  const _PriceDisclaimerBody();

  static const Color fill = Color(0xE62C3038);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(
            _PriceDisclaimerCalloutDelegate.radius,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: const Text(
          kBestIngredientProductsPriceDisclaimer,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFFF7F8FA),
            height: 1.35,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}

class _PriceDisclaimerCaretPainter extends CustomPainter {
  const _PriceDisclaimerCaretPainter({
    required this.color,
    required this.pointDown,
  });

  final Color color;
  final bool pointDown;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointDown) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width, 0);
    } else {
      path
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _PriceDisclaimerCaretPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.pointDown != pointDown;
  }
}

class _PreviewMarketplaceToggle extends StatelessWidget {
  const _PreviewMarketplaceToggle({
    required this.marketplace,
    required this.onChanged,
  });

  final String marketplace;
  final ValueChanged<String> onChanged;

  static const Duration _duration = Duration(milliseconds: 280);
  static const Curve _curve = Curves.easeInOutCubic;
  static const double _chipWidth = 62;
  static const double _chipHeight = 24;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = marketplace == 'kurly' ? 1 : 0;
    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: SizedBox(
        width: _chipWidth * kPreviewRailMarketplaces.length,
        height: _chipHeight,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: _duration,
              curve: _curve,
              alignment: selectedIndex == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: Container(
                width: _chipWidth,
                height: _chipHeight,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 6,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                for (final value in kPreviewRailMarketplaces)
                  SizedBox(
                    width: _chipWidth,
                    height: _chipHeight,
                    child: _PreviewMarketplaceToggleChip(
                      marketplace: value,
                      selected: marketplace == value,
                      onTap: marketplace == value
                          ? null
                          : () => onChanged(value),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewMarketplaceToggleChip extends StatelessWidget {
  const _PreviewMarketplaceToggleChip({
    required this.marketplace,
    required this.selected,
    required this.onTap,
  });

  final String marketplace;
  final bool selected;
  final VoidCallback? onTap;

  static const double _iconSize = 14;

  @override
  Widget build(BuildContext context) {
    final label = previewRailMarketplaceLabel(marketplace);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(
                previewRailMarketplaceIconAsset(marketplace),
                width: _iconSize,
                height: _iconSize,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, __, ___) => const SizedBox(
                  width: _iconSize,
                  height: _iconSize,
                ),
              ),
            ),
            const SizedBox(width: 4),
            AnimatedDefaultTextStyle(
              duration: _PreviewMarketplaceToggle._duration,
              curve: _PreviewMarketplaceToggle._curve,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: selected
                    ? const Color(0xFF191F28)
                    : const Color(0xFF8B95A1),
                letterSpacing: -0.2,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

class _BestIngredientProductSkeleton extends StatelessWidget {
  const _BestIngredientProductSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: BestIngredientProductsRail.cardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: BestIngredientProductsRail.cardImageSize,
            height: BestIngredientProductsRail.cardImageSize,
            decoration: BoxDecoration(
              color: BestIngredientProductsRail._skeleton,
              borderRadius: BorderRadius.circular(
                BestIngredientProductsRail.cardRadius,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 64,
            height: 12,
            decoration: BoxDecoration(
              color: BestIngredientProductsRail._skeleton,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 120,
            height: 12,
            decoration: BoxDecoration(
              color: BestIngredientProductsRail._skeleton,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

class _BestIngredientProductCardView extends StatelessWidget {
  const _BestIngredientProductCardView({
    required this.card,
    required this.position,
    this.recipeId,
  });

  final BestIngredientProductCard card;
  final int position;
  final String? recipeId;

  @override
  Widget build(BuildContext context) {
    final product = card.product;
    final child = GestureDetector(
      onTap: () => _onTap(context),
      child: SizedBox(
        width: BestIngredientProductsRail.cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: BestIngredientProductsRail.cardImageSize,
              height: BestIngredientProductsRail.cardImageSize,
              decoration: BoxDecoration(
                color: BestIngredientProductsRail._border,
                borderRadius: BorderRadius.circular(
                  BestIngredientProductsRail.cardRadius,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: product.productImage.isEmpty
                  ? const ColoredBox(
                      color: BestIngredientProductsRail._skeleton,
                    )
                  : AppNetworkImage(
                      imageUrl: product.productImage,
                      fit: BoxFit.cover,
                      width: BestIngredientProductsRail.cardImageSize,
                      height: BestIngredientProductsRail.cardImageSize,
                      memCacheWidth: AppNetworkImage.listThumbCacheSize,
                      memCacheHeight: AppNetworkImage.listThumbCacheSize,
                      placeholder: const ColoredBox(
                        color: BestIngredientProductsRail._skeleton,
                      ),
                      errorWidget: const ColoredBox(
                        color: BestIngredientProductsRail._skeleton,
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              card.ingredientName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111111),
                letterSpacing: -0.33,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              product.productName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B7280),
                letterSpacing: -0.2,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${formatWonPrice(product.productPrice)}원',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111111),
                letterSpacing: -0.4,
                height: 1.1,
              ),
            ),
            if (product.rating != null && product.rating! > 0) ...[
              const SizedBox(height: 3),
              Row(
                children: [
                  const Icon(
                    Icons.star_rounded,
                    size: 13,
                    color: BestIngredientProductsRail._star,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    product.rating!.toStringAsFixed(1),
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111111),
                    ),
                  ),
                  if (product.reviews != null && product.reviews! > 0) ...[
                    const SizedBox(width: 2),
                    Text(
                      '(${formatReviewCount(product.reviews!)})',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );

    if (product.productId.isEmpty) return child;
    final dedupKey =
        '${card.marketplace}::${card.ingredientName}::${product.productId}';
    return VisibilityDetector(
      key: Key('best_ingredient_product_impression_$dedupKey'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (_bestIngredientProductImpressionFired.contains(dedupKey)) return;
        _bestIngredientProductImpressionFired.add(dedupKey);
        unawaited(_logProductEvent('impression', position: position));
      },
      child: child,
    );
  }

  Future<void> _logProductEvent(String eventType, {required int position}) async {
    try {
      final product = card.product;
      await AnalyticsService().logCardEvent(
      eventType,
      screen: 'recipe_detail',
      sectionId: kBestIngredientProductsSectionId,
      cardId: product.productId,
      contentType: 'product',
      recipeId: recipeId,
      position: position,
      marketplace: card.marketplace,
      productId: product.productId,
      ingredientName: card.ingredientName,
      price: product.productPrice,
      productRating: product.rating,
      productReviewCount: product.reviews,
      productBayesianRating: product.bayesianRating,
      productValueScore: product.valueScore,
      productIsRocket: product.isRocket,
      productIsFreeShipping: product.isFreeShipping,
      productDiscountRate: product.discountRate,
      productUnitPrice: product.unitPrice,
      productPackageSize: product.packageSize,
      productPackageUnit: product.packageUnit,
      productSalesRank: product.salesRank,
      sourceScreen: kBestIngredientProductsAffiliateSource,
      );
    } catch (_) {}
  }

  Future<void> _onTap(BuildContext context) async {
    unawaited(_logProductEvent('click', position: position));
    final product = card.product;
    final marketplace = card.marketplace == 'kurly'
        ? ShoppingMarketplace.marketKurly
        : ShoppingMarketplace.coupang;
    final marketplaceName =
        marketplace == ShoppingMarketplace.marketKurly ? 'kurly' : 'coupang';

    String? deepLinkUrl;
    String? httpsUrl;
    if (marketplace == ShoppingMarketplace.coupang) {
      final subparam = await UserService().getCurrentCoupangSubparam();
      final args = coupangMarketplaceLinkArgs(
        landingUrl: product.landingUrl,
        deeplinkUrl: product.deeplinkUrl,
        productUrl: product.productUrl,
        originalUrl: product.originalUrl,
        subparam: subparam,
      );
      deepLinkUrl = args.deepLinkUrl;
      httpsUrl = args.httpsUrl;
    } else {
      deepLinkUrl = product.deeplinkUrl;
      httpsUrl = (product.landingUrl ?? '').trim().isNotEmpty
          ? product.landingUrl
          : ((product.productUrl).trim().isNotEmpty
              ? product.productUrl
              : product.originalUrl);
    }

    if (!context.mounted) return;
    unawaited(
      UserService().logAffiliateVisit(
        marketplace: marketplaceName,
        sourceScreen: kBestIngredientProductsAffiliateSource,
        productId: product.productId,
        ingredientName: card.ingredientName,
      ),
    );
    await openMarketplaceLink(
      context,
      deepLinkUrl: deepLinkUrl,
      httpsUrl: httpsUrl,
      marketplace: marketplace,
      ingredientName: card.ingredientName,
      recipeId: recipeId,
      productId: product.productId,
      sourceScreen: kBestIngredientProductsAffiliateSource,
    );
  }
}
