import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/home_poster_curations.dart';
import '../main.dart' show mainNavigatorKey;
import '../services/analytics_service.dart';
import '../services/home_cms_service.dart';
import '../services/recipe_service.dart';
import '../theme/app_colors.dart';
import '../utils/home_poster_recipe_session_cache.dart';
import '../utils/nav_guard.dart';
import '../utils/recipe_media_aspect.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../widgets/recipe_signal_impression.dart';
import '../widgets/app_network_image.dart';
import '../widgets/recipe_card_social_row.dart';
import '../widgets/recipe_platform_icon.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';
import '../utils/naver_brandconnect_link.dart';
import '../utils/coupang_subparam.dart';
import '../services/user_service.dart';
import 'cart_screen.dart'
    show
        launchMarketplaceHttpsInAppBrowser,
        openMarketplaceLink,
        ShoppingMarketplace;

const Color _kPosterMuted = Color(0xFF6A7282);
const Color _kPosterChipIdleBg = Color(0xFFF2F4F6);
const Color _kPosterChipIdleFg = Color(0xFF4A5565);
const Color _kPosterBorder = Color(0xFFF3F4F6);
const Color _kPosterSkeleton = Color(0xFFEBECF0);

IconData _productPlaceholderIcon(String badge) {
  switch (badge) {
    case '알룰로스':
      return Icons.water_drop_outlined;
    case '마요네즈':
    case '드레싱':
      return Icons.soup_kitchen_outlined;
    case '고추장':
      return Icons.local_fire_department_outlined;
    case '땅콩버터':
    case '딸기잼':
      return Icons.breakfast_dining_outlined;
    case '간식':
      return Icons.cookie_outlined;
    default:
      return Icons.eco_outlined;
  }
}

/// 홈 포스터 탭 → 큐레이션 랜딩.
/// 히어로 · 카피 · (상품) · 칩 · (팁) · 레시피 그리드.
class HomePosterCurationScreen extends StatefulWidget {
  const HomePosterCurationScreen({super.key, required this.curation});

  final HomePosterCuration curation;

  @override
  State<HomePosterCurationScreen> createState() =>
      _HomePosterCurationScreenState();
}

class _HomePosterCurationScreenState extends State<HomePosterCurationScreen> {
  final RecipeService _recipeService = RecipeService();
  final HomePosterRecipeSessionCache _sessionCache =
      HomePosterRecipeSessionCache.instance;

  int _chipIndex = 0;
  int _productFilterIndex = 0;
  bool _loading = true;
  List<Map<String, dynamic>> _recipes = const <Map<String, dynamic>>[];

  HomePosterCuration get _c => widget.curation;

  String _chipCacheKey(HomePosterChip chip, int index) {
    final key = chip.sectionKey?.trim();
    if (key != null && key.isNotEmpty) return '${_c.id}::$key';
    return '${_c.id}::${chip.label}_$index';
  }

  /// 상품이 있는 큐레이션은 칩 라벨로 상품·레시피를 같이 필터한다.
  bool get _syncRecipesToProducts => _c.products.isNotEmpty;

  List<String> get _productFilters =>
      _c.chips.map((c) => c.label).toList(growable: false);

  List<HomePosterProduct> get _filteredProducts {
    final all = _c.products;
    if (!_syncRecipesToProducts) return all;
    if (_productFilterIndex <= 0 ||
        _productFilterIndex >= _productFilters.length) {
      return all;
    }
    final badge = _productFilters[_productFilterIndex];
    return all.where((p) => p.badge == badge).toList(growable: false);
  }

  Future<void> _openProduct(HomePosterProduct product) async {
    final direct = product.productUrl?.trim() ?? '';
    final query = (product.searchQuery ?? product.name).trim();
    final sourceScreen = 'home_poster_${_c.id}';
    unawaited(
      AnalyticsService().logCardEvent(
        'click',
        screen: 'home_poster_curation',
        sectionId: 'poster_${_c.id}',
        cardId: product.id,
        contentType: 'product',
        productId: product.id,
        ingredientName: product.name,
        posterId: _c.id,
      ),
    );

    // BrandConnect 제휴는 쿠팡 인앱 WebView를 타면 안 됨.
    // naver.me를 외부 앱으로 열면 네이버 앱이 단축링크를 가로채 제휴 JS가 안 돈다.
    // 랜딩(brandconnect.naver.com/affiliates/...)을 Custom Tabs에서 연다.
    if (direct.isNotEmpty && isNaverBrandConnectAffiliateUrl(direct)) {
      final analytics = AnalyticsService();
      unawaited(
        analytics.trackAffiliateLinkClicked(
          marketplace: 'naver',
          ingredientName: product.name,
          productId: product.id,
          sourceScreen: sourceScreen,
        ),
      );
      unawaited(
        UserService().logAffiliateVisit(
          marketplace: 'naver',
          sourceScreen: sourceScreen,
          productId: product.id,
          ingredientName: product.name,
        ),
      );
      final parsed = Uri.tryParse(direct);
      if (parsed == null) return;
      try {
        final launchUri = await resolveBrandConnectLaunchUri(parsed);
        final ok = await launchMarketplaceHttpsInAppBrowser(launchUri);
        unawaited(
          analytics.trackAffiliateOpenResult(
            marketplace: 'naver',
            success: ok,
            productId: product.id,
            ingredientName: product.name,
            sourceScreen: sourceScreen,
            failureReason: ok ? null : 'in_app_browser_false',
          ),
        );
      } catch (_) {
        unawaited(
          analytics.trackAffiliateOpenResult(
            marketplace: 'naver',
            success: false,
            productId: product.id,
            ingredientName: product.name,
            sourceScreen: sourceScreen,
            failureReason: 'in_app_browser_error',
          ),
        );
      }
      return;
    }

    final subparam = await UserService().getCurrentCoupangSubparam();
    if (!mounted) return;
    final args = homePosterCoupangLinkArgs(
      productUrl: direct.isNotEmpty ? direct : null,
      landingUrl: product.landingUrl,
      deeplinkUrl: product.deeplinkUrl,
      searchQuery: query,
      fallbackName: product.name,
      subparam: subparam,
    );
    unawaited(
      UserService().logAffiliateVisit(
        marketplace: 'coupang',
        sourceScreen: sourceScreen,
        productId: product.id,
        ingredientName: product.name,
      ),
    );
    await openMarketplaceLink(
      context,
      deepLinkUrl: args.deepLinkUrl,
      httpsUrl: args.httpsUrl,
      marketplace: ShoppingMarketplace.coupang,
      ingredientName: product.name,
      productId: product.id,
      sourceScreen: sourceScreen,
    );
  }

  void _onProductFilterSelected(int index) {
    if (_productFilterIndex == index && _chipIndex == index) return;
    setState(() => _productFilterIndex = index);
    if (index >= 0 && index < _c.chips.length) {
      final chip = _c.chips[index];
      unawaited(
        AnalyticsService().trackHomeCategoryClicked(
          source: 'poster_chip',
          categoryId: (chip.sectionKey != null &&
                  chip.sectionKey!.trim().isNotEmpty)
              ? chip.sectionKey
              : 'poster_${_c.id}',
          categoryName: chip.label,
          position: index,
          posterId: _c.id,
          cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
        ),
      );
    }
    unawaited(_loadChip(index));
  }

  @override
  void initState() {
    super.initState();
    // 세션 캐시가 있으면 첫 프레임부터 스켈레톤 없이 표시
    if (_c.chips.isNotEmpty) {
      final warm = _sessionCache.get(_chipCacheKey(_c.chips.first, 0));
      if (warm != null) {
        _recipes = warm;
        _loading = false;
        _chipIndex = 0;
      }
    }
    unawaited(_loadChip(0));
    unawaited(
      AnalyticsService().trackScreen(
        'home_poster_curation',
        screenClass: 'HomePosterCurationScreen',
      ),
    );
    unawaited(
      AnalyticsService().trackHomeSectionImpression(
        sectionId: 'poster_${_c.id}',
        sectionName: _c.pageTitle,
        chipSectionKey: _selectedChipSectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
  }

  Future<void> _loadChip(int index) async {
    if (index < 0 || index >= _c.chips.length) return;
    final chip = _c.chips[index];
    final cacheKey = _chipCacheKey(chip, index);
    final cached = _sessionCache.get(cacheKey);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _chipIndex = index;
        _recipes = cached;
        _loading = false;
      });
      return;
    }

    setState(() {
      _chipIndex = index;
      _loading = true;
    });

    try {
      final recipes = await _fetchForChip(chip);
      _sessionCache.set(cacheKey, recipes);
      if (!mounted) return;
      setState(() {
        _recipes = recipes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recipes = const <Map<String, dynamic>>[];
        _loading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _fetchForChip(HomePosterChip chip) async {
    // sectionKey 가 있으면 해당 인덱스만 사용 (풀 병합·키워드 재필터 없음).
    // 정적 포스터 인덱스(poster_*)는 일회성 스크립트로 분류된 ID만 담는다.
    final sectionKey = chip.sectionKey?.trim() ?? '';
    final keys = <String>{
      if (sectionKey.isNotEmpty) sectionKey,
      if (sectionKey.isEmpty) ..._c.poolSectionKeys,
    };
    if (keys.isEmpty) return const <Map<String, dynamic>>[];

    final idLimit = sectionKey.startsWith('poster_')
        ? 200
        : (_c.strictKeywordMatch ? 120 : 60);

    final idOrder = <String>[];
    final seen = <String>{};
    for (final key in keys) {
      final ids = await _recipeService.getHomeSectionRecipeIds(
        sectionKey: key,
        limit: idLimit,
      );
      for (final id in ids) {
        if (id.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        idOrder.add(id);
      }
    }
    if (idOrder.isEmpty) return const <Map<String, dynamic>>[];

    final fetchLimit = sectionKey.startsWith('poster_')
        ? 200
        : (_c.strictKeywordMatch ? 120 : 48);
    final fetched = await _recipeService.getExploreRecipesByIds(
      idOrder.take(fetchLimit).toList(growable: false),
      limit: fetchLimit,
    );

    // 인덱스 순서 유지
    final byId = <String, Map<String, dynamic>>{
      for (final r in fetched)
        if ((r['id']?.toString() ?? '').isNotEmpty) r['id'].toString(): r,
    };
    var ordered = <Map<String, dynamic>>[
      for (final id in idOrder.take(fetchLimit))
        if (byId[id] != null) byId[id]!,
    ];

    // 전용 정적 인덱스(poster_*)는 이미 분류돼 있으므로 키워드 재필터 생략.
    // 그 외(예: quick_10min + 계란 키워드)는 인덱스 풀 위에서 키워드 필터.
    final skipKeywordFilter = sectionKey.startsWith('poster_');
    if (!skipKeywordFilter && chip.matchKeywords.isNotEmpty) {
      final filtered = ordered
          .where((r) => _matchesKeywords(r, chip.matchKeywords))
          .toList(growable: false);
      if (_c.strictKeywordMatch || filtered.isNotEmpty) {
        ordered = filtered;
      }
    }
    return ordered;
  }

  bool _matchesKeywords(Map<String, dynamic> recipe, List<String> keywords) {
    if (keywords.isEmpty) return true;
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
    final ingredients = recipeData['ingredients'] ?? recipe['ingredients'];
    final ingredientText = ingredients is List
        ? ingredients.map((e) => e.toString()).join(' ')
        : ingredients?.toString() ?? '';
    final haystack = [
      recipe['title'],
      recipeData['title'],
      recipeData['name'],
      ingredientText,
      recipeData['category'],
      recipe['tags'],
    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
    for (final keyword in keywords) {
      final k = keyword.toLowerCase().trim();
      if (k.isNotEmpty && haystack.contains(k)) return true;
    }
    return false;
  }

  String get _recipeAnalyticsSectionId => 'poster_${_c.id}';

  String? get _selectedChipSectionKey {
    if (_chipIndex < 0 || _chipIndex >= _c.chips.length) return null;
    final key = _c.chips[_chipIndex].sectionKey?.trim();
    return (key == null || key.isEmpty) ? null : key;
  }

  void _onRecipeTap(Map<String, dynamic> recipe, int index) {
    final recipeId = recipe['id']?.toString() ?? '';
    if (recipeId.isEmpty) return;
    final sectionId = _recipeAnalyticsSectionId;
    unawaited(
      AnalyticsService().trackHomeRecipeClicked(
        recipeId: recipeId,
        sectionId: sectionId,
        sectionName: _c.pageTitle,
        cardIndex: index,
        posterId: _c.id,
        chipSectionKey: _selectedChipSectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
        sourceScreen: 'home_poster_curation',
      ),
    );
    unawaited(
      AnalyticsService().logRecipeMapEvent(
        'click',
        screen: 'home_poster_curation',
        recipe: recipe,
        sectionId: sectionId,
        position: index,
        posterId: _c.id,
        chipSectionKey: _selectedChipSectionKey,
      ),
    );
    NavGuard.once(() async {
      final parseResponse = await _recipeService.getRecipeById(recipeId);
      if (parseResponse == null || !mounted) return;
      Navigator.pushNamed(
        context,
        '/recipe-detail',
        arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
      );
    })();
  }

  void _openFridge() {
    Navigator.of(context).maybePop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mainNavigatorKey.currentState?.navigateToFridge();
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);
    final textPrimary = AppColors.getTextPrimary(brightness);
    final topInset = MediaQuery.of(context).padding.top;
    final heroHeight = MediaQuery.of(context).size.width * 0.92;
    const sheetOverlap = 28.0;

    return Scaffold(
      backgroundColor: bg,
      body: CustomScrollView(
        // 상단으로 당겨지는 오버스크롤(바운스) 방지
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        slivers: [
          // 이미지는 Stack 맨 뒤, 흰 시트·뱃지가 그 위에 올라감
          SliverToBoxAdapter(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 1) 히어로 이미지 — 맨 뒤
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: heroHeight,
                  child: _HeroBackground(
                    assetPath: _c.assetPath,
                    imageUrl: _c.imageUrl,
                    alignment: _c.imageAlignment,
                  ),
                ),
                // 2) 레이아웃 + 흰 시트 — 이미지 위로 겹침
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: heroHeight - sheetOverlap),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 18,
                            offset: Offset(0, -2),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.only(top: 20, bottom: 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    _c.eyebrow,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.15,
                                      color: Color(0xFF475467),
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _c.pageTitle.replaceAll('\n', ' '),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.8,
                                      height: 1.2,
                                      color: textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _c.body,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -0.2,
                                    height: 1.65,
                                    color: Color(0xFF667085),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_c.tips.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            if ((_c.tipsSectionTitle ?? '').isNotEmpty) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 20),
                                child: Text(
                                  _c.tipsSectionTitle!,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.35,
                                    color: textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            _TipCarousel(tips: _c.tips),
                          ],
                          if (_c.showFridgeCta) ...[
                            const SizedBox(height: 18),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              child: SizedBox(
                                width: double.infinity,
                                height: 48,
                                child: FilledButton(
                                  onPressed: _openFridge,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF1A1A1A),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    textStyle: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  child: Text(
                                    _c.fridgeCtaLabel ?? '내 냉장고 열기',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                // 3) 뒤로가기 — 맨 앞
                Positioned(
                  top: topInset + 8,
                  left: 8,
                  child: Material(
                    color: const Color(0x66000000),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 마이노멀 베스트 상품 + 칩 (선택 시 아래 레시피도 같이 변경)
          if (_c.products.isNotEmpty)
            SliverToBoxAdapter(
              child: _ProductCurationSection(
                title: _c.productsSectionTitle,
                filters: _productFilters,
                selectedFilterIndex: _productFilterIndex,
                products: _filteredProducts,
                onFilterSelected: _onProductFilterSelected,
                onProductTap: _openProduct,
              ),
            ),
          // 레시피 고르기 — 상품 칩이 있으면 레시피 칩은 숨기고 연동
          if (_syncRecipesToProducts)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _c.recipeSectionTitle,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _productFilterIndex <= 0
                          ? '위 카테고리에 맞춰 저당 레시피를 보여드려요'
                          : '${_productFilters[_productFilterIndex]}에 맞춰 고른 레시피',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.15,
                        color: _kPosterMuted,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Text(
                  _c.recipeSectionTitle,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: textPrimary,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _ChipRow(
                  chips: _c.chips,
                  selectedIndex: _chipIndex,
                  onSelected: (i) => unawaited(_loadChip(i)),
                ),
              ),
            ),
          ],
          if (_loading)
            const SliverToBoxAdapter(child: _RecipeGridSkeleton())
          else if (_recipes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                child: Text(
                  '이 조건에 맞는 레시피를 아직 모으고 있어요.\n다른 카테고리를 눌러보세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                    color: AppColors.getTextTertiary(brightness),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                36 + MediaQuery.of(context).padding.bottom,
              ),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.62,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final recipe = _recipes[index];
                    return RecipeSignalImpression(
                      screen: 'home_poster_curation',
                      sectionId: _recipeAnalyticsSectionId,
                      position: index,
                      posterId: _c.id,
                      chipSectionKey: _selectedChipSectionKey,
                      recipe: recipe,
                      child: _CurationRecipeCard(
                        recipe: recipe,
                        brightness: brightness,
                        onTap: () => _onRecipeTap(recipe, index),
                      ),
                    );
                  },
                  childCount: _recipes.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroBackground extends StatelessWidget {
  const _HeroBackground({
    required this.assetPath,
    this.imageUrl,
    this.alignment = Alignment.centerRight,
  });

  final String assetPath;
  final String? imageUrl;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    final image = url.startsWith('http')
        ? AppNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: const ColoredBox(color: Color(0xFF2A2A2A)),
          )
        : Image.asset(
            assetPath,
            fit: BoxFit.cover,
            alignment: alignment,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: Color(0xFF2A2A2A),
            ),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x66000000),
                Color(0x00000000),
                Color(0x44000000),
              ],
              stops: [0.0, 0.4, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _TipCarousel extends StatefulWidget {
  const _TipCarousel({required this.tips});

  final List<HomePosterTip> tips;

  /// 패딩 12×2 + 아이콘 32 + 간격 8 + 본문 3줄(12.5×1.4×3)
  static const double cardHeight = 118;

  @override
  State<_TipCarousel> createState() => _TipCarouselState();
}

class _TipCarouselState extends State<_TipCarousel> {
  late final PageController _controller;
  Timer? _autoTimer;
  int _index = 0;
  bool _userDragging = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.9);
    _startAutoPlay();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoTimer?.cancel();
    if (widget.tips.length < 2) return;
    _autoTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _userDragging || !_controller.hasClients) return;
      final next = (_index + 1) % widget.tips.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tips = widget.tips;
    if (tips.isEmpty) return const SizedBox.shrink();
    if (tips.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
          height: _TipCarousel.cardHeight,
          child: _TipCard(tip: tips.first),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: _TipCarousel.cardHeight,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                _userDragging = true;
              } else if (n is ScrollEndNotification) {
                _userDragging = false;
                _startAutoPlay();
              }
              return false;
            },
            child: PageView.builder(
              controller: _controller,
              padEnds: true,
              itemCount: tips.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: _TipCard(tip: tips[i]),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(tips.length, (i) {
            final active = i == _index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? 14 : 5,
              height: 5,
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFF1A1A1A)
                    : const Color(0xFFD0D5DD),
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.tip});

  final HomePosterTip tip;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEEF0F3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFFE8EAED)),
                  ),
                  child: Icon(
                    tip.icon,
                    size: 16,
                    color: const Color(0xFF222222),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tip.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      height: 1.2,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  tip.body,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.2,
                    height: 1.4,
                    color: Color(0xFF667085),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductCurationSection extends StatelessWidget {
  const _ProductCurationSection({
    required this.title,
    required this.filters,
    required this.selectedFilterIndex,
    required this.products,
    required this.onFilterSelected,
    required this.onProductTap,
  });

  final String title;
  final List<String> filters;
  final int selectedFilterIndex;
  final List<HomePosterProduct> products;
  final ValueChanged<int> onFilterSelected;
  final ValueChanged<HomePosterProduct> onProductTap;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(Theme.of(context).brightness);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              title,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 36,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final selected = i == selectedFilterIndex;
                return GestureDetector(
                  onTap: () => onFilterSelected(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF1A1A1A)
                          : _kPosterChipIdleBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      filters[i],
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        letterSpacing: -0.2,
                        color: selected ? Colors.white : _kPosterChipIdleFg,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          if (products.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                '이 조건의 상품을 준비하고 있어요.',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _kPosterMuted,
                ),
              ),
            )
          else
            SizedBox(
              height: 232,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: products.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final product = products[i];
                  return _PosterProductCard(
                    product: product,
                    onTap: () => onProductTap(product),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PosterProductCard extends StatelessWidget {
  const _PosterProductCard({
    required this.product,
    required this.onTap,
  });

  final HomePosterProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imageUrl = product.imageUrl?.trim() ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 148,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (imageUrl.isNotEmpty)
                        AppNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                        )
                      else
                        ColoredBox(
                          color: const Color(0xFFF3F5F7),
                          child: Center(
                            child: Icon(
                              _productPlaceholderIcon(product.badge),
                              size: 34,
                              color: const Color(0xFF98A2B3),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xE6111827),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            product.badge,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.25,
                  height: 1.25,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                product.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.15,
                  color: _kPosterMuted,
                ),
              ),
              if ((product.priceLabel ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  product.priceLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: Color(0xFF344054),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.chips,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<HomePosterChip> chips;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        // 좌우 패딩을 리스트에 둬서 마지막 칩이 화면 끝에 잘리지 않게
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        clipBehavior: Clip.none,
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = i == selectedIndex;
          return GestureDetector(
            onTap: () => onSelected(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF1A1A1A)
                    : _kPosterChipIdleBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                chips[i].label,
                softWrap: false,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: -0.2,
                  color: selected ? Colors.white : _kPosterChipIdleFg,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RecipeGridSkeleton extends StatelessWidget {
  const _RecipeGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 4,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 12,
          childAspectRatio: 0.68,
        ),
        itemBuilder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _kPosterSkeleton,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: 12,
              width: double.infinity,
              color: _kPosterSkeleton,
            ),
            const SizedBox(height: 6),
            Container(
              height: 10,
              width: 72,
              color: _kPosterSkeleton,
            ),
          ],
        ),
      ),
    );
  }
}

class _CurationRecipeCard extends StatelessWidget {
  const _CurationRecipeCard({
    required this.recipe,
    required this.brightness,
    required this.onTap,
  });

  final Map<String, dynamic> recipe;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
    final source = recipe['source'] as Map<String, dynamic>? ?? const {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    final platform = RecipeMediaAspect.platformOf(recipe);
    final sourceUrl = RecipeMediaAspect.sourceUrlOf(recipe);
    final isLandscape = RecipeMediaAspect.isLandscape(recipe);

    var creator = '';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    }

    Widget image = AppNetworkImage(
      imageUrl: thumbnailUrl,
      fit: BoxFit.cover,
      memCacheWidth: AppNetworkImage.carouselThumbMemCacheWidth,
      memCacheHeight: AppNetworkImage.carouselThumbMemCacheHeight,
      brightness: brightness,
      placeholder: const ColoredBox(color: _kPosterSkeleton),
      errorWidget: const ColoredBox(color: _kPosterSkeleton),
    );
    if (!isLandscape) {
      image = ThumbnailLetterboxMitigation(
        platform: platform,
        imageUrl: thumbnailUrl,
        sourceUrl: sourceUrl,
        child: image,
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ColoredBox(
                color: _kPosterBorder,
                child: thumbnailUrl.isEmpty
                    ? const ColoredBox(color: _kPosterSkeleton)
                    : image,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.3,
              color: AppColors.getTextPrimary(brightness),
            ),
          ),
          if (creator.isNotEmpty ||
              RecipePlatformIcon.assetPathFor(platform) != null) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                if (RecipePlatformIcon.assetPathFor(platform) != null) ...[
                  RecipePlatformIcon(
                    platform: platform,
                    size: 16,
                    fallbackColor: _kPosterMuted,
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    creator,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                      color: _kPosterMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 3),
          RecipeCardSocialRow(
            recipe: recipe,
            color: _kPosterMuted,
          ),
        ],
      ),
    );
  }
}
