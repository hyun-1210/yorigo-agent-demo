import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/cart_screen.dart'
    show ShoppingMarketplace, openMarketplaceLink;
import '../services/coupang_service.dart';
import '../services/user_service.dart';
import '../utils/coupang_subparam.dart';
import 'app_network_image.dart';

class MealKitPickerSheet extends StatefulWidget {
  const MealKitPickerSheet({
    super.key,
    required this.recipeName,
    this.recipeId,
    this.onEmptySearch,
  });

  final String recipeName;
  final String? recipeId;
  final VoidCallback? onEmptySearch;

  static const heroAsset = 'assets/images/meal_kit_hero.png';

  @override
  State<MealKitPickerSheet> createState() => _MealKitPickerSheetState();
}

class _MealKitPickerSheetState extends State<MealKitPickerSheet> {
  static const _filters = [
    '전체',
    '혼밥용',
    '2~3인',
    '할인중',
    '로켓배송',
    '최저가',
  ];

  final _coupang = CoupangService();
  final List<CoupangProduct> _products = [];
  final Map<String, ShoppingMarketplace> _productMarket = {};
  bool _loading = true;
  String _filter = '전체';

  String get _dishName => widget.recipeName.trim();
  String get _query => '$_dishName 밀키트';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _coupang.searchMealKitProducts(_query, marketplace: 'coupang'),
      _coupang.searchMealKitProducts(_query, marketplace: 'kurly'),
    ]);
    var coupang = results[0];
    if (coupang.isEmpty) {
      coupang = await _coupang.searchMealKitProducts(
        '$_dishName 밀키트 키트',
        marketplace: 'coupang',
      );
    }
    if (!mounted) return;
    _productMarket.clear();
    final merged = <CoupangProduct>[];
    final seen = <String>{};
    void addAll(List<CoupangProduct> items, ShoppingMarketplace market) {
      for (final p in items) {
        if (p.productId.isEmpty || !seen.add(p.productId)) continue;
        merged.add(p);
        _productMarket[p.productId] = market;
      }
    }
    addAll(coupang, ShoppingMarketplace.coupang);
    addAll(results[1], ShoppingMarketplace.marketKurly);
    setState(() {
      _products
        ..clear()
        ..addAll(merged);
      _loading = false;
    });
  }

  bool _isDiscounted(CoupangProduct p) {
    return p.originalPrice != null &&
        p.originalPrice! > p.productPrice &&
        p.productPrice > 0;
  }

  bool _nameHas(CoupangProduct p, List<String> tokens) {
    final name = p.productName.replaceAll(' ', '');
    return tokens.any(name.contains);
  }

  List<CoupangProduct> get _visible {
    var list = List<CoupangProduct>.from(_products);
    switch (_filter) {
      case '로켓배송':
        list = list.where((p) => p.isRocket).toList();
        break;
      case '혼밥용':
        list = list
            .where((p) => _nameHas(p, const ['1인', '혼밥', '1인용', '1인분']))
            .toList();
        break;
      case '2~3인':
        list = list
            .where((p) =>
                _nameHas(p, const ['2인', '3인', '2~3', '2-3', '2인분', '3인분']))
            .toList();
        break;
      case '할인중':
        list = list.where(_isDiscounted).toList();
        break;
    }
    list.sort((a, b) {
      if (_filter == '최저가' || _filter == '로켓배송' || _filter == '할인중') {
        if (a.productPrice <= 0) return 1;
        if (b.productPrice <= 0) return -1;
        return a.productPrice.compareTo(b.productPrice);
      }
      final ar = a.reviews ?? 0;
      final br = b.reviews ?? 0;
      if (ar != br) return br.compareTo(ar);
      if (a.isRocket != b.isRocket) return a.isRocket ? -1 : 1;
      if (a.productPrice <= 0) return 1;
      if (b.productPrice <= 0) return -1;
      return a.productPrice.compareTo(b.productPrice);
    });
    return list;
  }

  String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  String _formatReviews(int n) {
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(n >= 100000 ? 0 : 1)}만';
    }
    final digits = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  Future<void> _buy(CoupangProduct product) async {
    if (product.productUrl.isEmpty) return;
    final marketplace =
        _productMarket[product.productId] ?? ShoppingMarketplace.coupang;
    // 컬리 경로는 기존처럼 단축/상품 URL만 연다.
    final isCoupang = marketplace == ShoppingMarketplace.coupang;
    final subparam =
        isCoupang ? await UserService().getCurrentCoupangSubparam() : null;
    final args = coupangMarketplaceLinkArgs(
      landingUrl: product.landingUrl,
      deeplinkUrl: product.deeplinkUrl,
      productUrl: product.productUrl,
      originalUrl: product.originalUrl,
      subparam: subparam,
      attachTracking: isCoupang,
    );
    if (!mounted) return;
    if (isCoupang || marketplace == ShoppingMarketplace.marketKurly) {
      unawaited(
        UserService().logAffiliateVisit(
          marketplace: isCoupang ? 'coupang' : 'kurly',
          sourceScreen: 'meal_kit_picker',
          productId: product.productId,
          ingredientName: _query,
        ),
      );
    }
    await openMarketplaceLink(
      context,
      deepLinkUrl: args.deepLinkUrl,
      httpsUrl: args.httpsUrl,
      marketplace: marketplace,
      ingredientName: _query,
      recipeId: widget.recipeId,
      productId: product.productId,
      sourceScreen: 'meal_kit_picker',
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    const heroHeight = 272.0;
    const sheetOverlap = 28.0;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: Material(
        color: const Color(0xFFEDE8DF),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.94,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: heroHeight,
                child: _HeroHeader(
                  dishName: _dishName,
                  imageAsset: MealKitPickerSheet.heroAsset,
                ),
              ),
              Positioned(
                top: heroHeight - sheetOverlap,
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x33E85D04),
                        blurRadius: 28,
                        offset: Offset(0, -6),
                      ),
                      BoxShadow(
                        color: Color(0x1A1A1714),
                        blurRadius: 16,
                        offset: Offset(0, -2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    child: Column(
                      children: [
                        _FilterBar(
                          filter: _filter,
                          filters: _filters,
                          onFilter: (v) => setState(() => _filter = v),
                        ),
                        Expanded(
                          child: ColoredBox(
                            color: Colors.white,
                            child: _buildBody(bottom),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(double bottom) {
    final loading = _loading;
    final products = _visible;

    if (loading && products.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 28 + bottom),
        children: const [
          _PremiumSkeleton(height: 312),
          SizedBox(height: 18),
          _PremiumSkeleton(height: 104),
          SizedBox(height: 12),
          _PremiumSkeleton(height: 104),
        ],
      );
    }

    if (products.isEmpty) {
      return _QuietEmpty(onSearch: widget.onEmptySearch);
    }

    final featured = products.first;
    final rest = products.skip(1).toList();

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
      children: [
        const SizedBox(height: 12),
        _SectionLabel(
          title: '오늘 저녁, 이 구성',
          caption: '${products.length}개의 밀키트',
        ),
        const SizedBox(height: 14),
        _EditorialCard(
          product: featured,
          marketplaceLabel:
              (_productMarket[featured.productId] ==
                      ShoppingMarketplace.marketKurly)
                  ? '마켓컬리'
                  : '쿠팡',
          formatPrice: _formatPrice,
          formatReviews: _formatReviews,
          onBuy: () => _buy(featured),
        ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 28),
          const _SectionLabel(
            title: '다른 구성',
            caption: '취향에 맞게 골라보세요',
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < rest.length; i++) ...[
            _QuietRow(
              product: rest[i],
              formatPrice: _formatPrice,
              onBuy: () => _buy(rest[i]),
            ),
            if (i < rest.length - 1) const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.dishName,
    required this.imageAsset,
  });

  final String dishName;
  final String imageAsset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: double.infinity,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFEDE8DF)),
          Image.asset(
            imageAsset,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              final ready = wasSynchronouslyLoaded || frame != null;
              if (!ready) return const SizedBox.shrink();
              return Stack(
                fit: StackFit.expand,
                children: [
                  child,
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x0083C26F),
                          Color(0x0083C26F),
                          Color(0x4D83C26F),
                          Color(0xA683C26F),
                        ],
                        stops: [0.0, 0.58, 0.82, 1.0],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  'MEAL KIT  ·  HMR',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                    color: Color(0xB31A1714),
                    height: 1,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  strutStyle: StrutStyle(
                    fontSize: 11,
                    height: 1,
                    forceStrutHeight: true,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  dishName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'HakgyoansimJiugae',
                    fontSize: 28,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF1A1714),
                    height: 1,
                    letterSpacing: -0.4,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  strutStyle: const StrutStyle(
                    fontSize: 28,
                    height: 1,
                    forceStrutHeight: true,
                  ),
                ),
                const SizedBox(height: 13),
                const Text(
                  '손질 없이, 한끼 식사를 그대로 완성하세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xCC1A1714),
                    letterSpacing: -0.2,
                    height: 1,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  strutStyle: StrutStyle(
                    fontSize: 13.5,
                    height: 1,
                    forceStrutHeight: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.filters,
    required this.onFilter,
  });

  final String filter;
  final List<String> filters;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0x0F1A1714))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            for (var i = 0; i < filters.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _QuietFilter(
                label: filters[i],
                selected: filter == filters[i],
                onTap: () => onFilter(filters[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuietFilter extends StatelessWidget {
  const _QuietFilter({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFF1A1714) : const Color(0xFFE5E5E5),
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? const Color(0xFF1A1714) : const Color(0xFF555555),
            letterSpacing: -0.15,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.caption});

  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1714),
              letterSpacing: -0.4,
              height: 1.2,
            ),
          ),
        ),
        Text(
          caption,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFF8A837C),
            letterSpacing: -0.1,
          ),
        ),
      ],
    );
  }
}

class _EditorialCard extends StatelessWidget {
  const _EditorialCard({
    required this.product,
    required this.marketplaceLabel,
    required this.formatPrice,
    required this.formatReviews,
    required this.onBuy,
  });

  final CoupangProduct product;
  final String marketplaceLabel;
  final String Function(int) formatPrice;
  final String Function(int) formatReviews;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final price = product.productPrice > 0
        ? '${formatPrice(product.productPrice)}원'
        : '가격 확인';
    final hasDiscount = product.originalPrice != null &&
        product.originalPrice! > product.productPrice &&
        product.productPrice > 0;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1AE85D04),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
          BoxShadow(
            color: Color(0x0A1A1714),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 210,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  product.productImage.isNotEmpty
                      ? AppNetworkImage(
                          imageUrl: product.productImage,
                          fit: BoxFit.cover,
                          memCacheWidth: 1000,
                          memCacheHeight: 700,
                        )
                      : const ColoredBox(color: Color(0xFFF0EBE4)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0x33000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    top: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Editor’s pick',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1714),
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.productName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1714),
                      height: 1.4,
                      letterSpacing: -0.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (product.rating != null && product.rating! > 0) ...[
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: Color(0xFF1A1714),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          product.rating!.toStringAsFixed(1),
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1714),
                          ),
                        ),
                        if (product.reviews != null && product.reviews! > 0)
                          Text(
                            '  ${formatReviews(product.reviews!)} reviews',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF8A837C),
                            ),
                          ),
                      ] else
                        const Text(
                          '바로 끓여 먹는 구성',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF8A837C),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (hasDiscount)
                        Padding(
                          padding: const EdgeInsets.only(right: 6, bottom: 1),
                          child: Text(
                            '${product.discountRate?.toStringAsFixed(0) ?? ''}%',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFE85D04),
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                      Text(
                        price,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1714),
                          letterSpacing: -0.7,
                          height: 1,
                        ),
                      ),
                      if (hasDiscount) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${formatPrice(product.originalPrice!)}원',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFB0A8A0),
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: onBuy,
                    child: Container(
                      width: double.infinity,
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1714),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Text(
                        '$marketplaceLabel에서 구매하기',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.25,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuietRow extends StatelessWidget {
  const _QuietRow({
    required this.product,
    required this.formatPrice,
    required this.onBuy,
  });

  final CoupangProduct product;
  final String Function(int) formatPrice;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final price = product.productPrice > 0
        ? '${formatPrice(product.productPrice)}원'
        : '가격 확인';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onBuy,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 78,
                  height: 78,
                  child: product.productImage.isNotEmpty
                      ? AppNetworkImage(
                          imageUrl: product.productImage,
                          width: 78,
                          height: 78,
                          fit: BoxFit.cover,
                          memCacheWidth: 240,
                          memCacheHeight: 240,
                        )
                      : const ColoredBox(color: Color(0xFFF0EBE4)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1714),
                        height: 1.35,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      price,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1714),
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Color(0xFFF6F3EE),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_outward_rounded,
                  size: 16,
                  color: Color(0xFF1A1714),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuietEmpty extends StatelessWidget {
  const _QuietEmpty({this.onSearch});

  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '딱 맞는 밀키트를 못 찾았어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1714),
                letterSpacing: -0.3,
              ),
            ),
            if (onSearch != null) ...[
              const SizedBox(height: 20),
              GestureDetector(
                onTap: onSearch,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1714),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '밀키트 찾아보기',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PremiumSkeleton extends StatelessWidget {
  const _PremiumSkeleton({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
    );
  }
}
