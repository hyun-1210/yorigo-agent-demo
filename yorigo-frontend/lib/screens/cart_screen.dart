import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_colors.dart';
import '../services/rewards_service.dart';
import '../widgets/app_header.dart';
import '../widgets/guest_locked_preview_backdrop.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_toast.dart';
import '../services/user_service.dart';
import '../services/coupang_service.dart';
import '../services/recipe_service.dart';
import '../services/meal_plan_service.dart';
import '../services/analytics_service.dart';
import '../services/coupang_commission_browser_service.dart';
import '../services/auth_service.dart';
import '../utils/auth_session_ready.dart';
import '../services/admin_service.dart';
import '../services/local_storage_service.dart';
import '../utils/ingredient_unit_converter.dart';
import '../utils/haptics.dart';
import '../utils/close_amount_tag.dart';
import '../utils/ingredient_category_unifier.dart';
import '../utils/ingredient_conversion_gap_ledger.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/coupang_subparam.dart';
import '../utils/onboarding_personalization.dart';
import '../services/ingredient_shelf_life_service.dart';
import '../utils/shelf_life_research_uploader.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';
import '../widgets/ingredient_select_sheet.dart';
import '../widgets/cart_add_ingredient_sheet.dart';
import '../main.dart';

const Color _cartAccentOrange = Color(0xFFFF6B35);

/// Cyan-700 — used for 딱 필요한 양 (recipe vs pack closeness); distinct from orange/green/rose/blue/purple tags.
const Color _closeAmountTagColor = Color(0xFF0E7490);

/// Selected marketplace for shopping list product listings.
enum ShoppingMarketplace { coupang, marketKurly, oasis }

/// Asset path for Coupang rocket logo (in yorigo-frontend/assets/marketplace/).
/// Add marketkurly_logo.png and oasis_logo.png to assets/marketplace/ and pubspec to show their logos.
const String _assetCoupangLogo = 'assets/marketplace/coupang_logo.png';
const String _assetCoupangAppLogo = 'assets/marketplace/coupang_app_logo.png';
const String _assetMarketkurlyLogo = 'assets/marketplace/marketkurly_logo.png';
const String _assetOasisLogo = 'assets/marketplace/oasis_logo.png';

/// Opens a Coupang commission URL with auto-close.
///
/// iOS uses a native WKWebView (see `CoupangCommissionBrowser.swift`) so URL and
/// lifecycle signals are handled on the platform side without premature dismissals.
Future<void> _launchCoupangInAppBrowserWithAutoClose(
  BuildContext context,
  Uri uri,
) async {
  if (kIsWeb) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return;
  }

  if (CoupangCommissionBrowserService.isSupported) {
    await CoupangCommissionBrowserService.openCommissionLink(uri);
    return;
  }

  await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

/// HTTPS 마켓 링크를 Chrome Custom Tabs(또는 외부 브라우저)로 연다.
/// 컬리 lounge / 네이버 BrandConnect 제휴 랜딩은 네이티브 앱이 단축 URL을
/// 가로채면 제휴 JS가 안 돌므로 Custom Tabs가 안전하다.
Future<bool> launchMarketplaceHttpsInAppBrowser(Uri uri) async {
  if (kIsWeb) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (launched) return true;
  } catch (_) {}
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

String? _firstHttpMarketplaceUrl(Iterable<String?> urls) {
  for (final url in urls) {
    if (url == null || url.isEmpty) continue;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
  }
  return null;
}

String _marketplaceAnalyticsName(ShoppingMarketplace marketplace) {
  if (marketplace == ShoppingMarketplace.coupang) return 'coupang';
  if (marketplace == ShoppingMarketplace.marketKurly) return 'kurly';
  return 'oasis';
}

String _openPlatformAnalyticsName() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name.toLowerCase();
}

/// Opens a marketplace link. Coupang uses the commission in-app browser.
/// Android Kurly/Oasis HTTPS uses Chrome Custom Tabs (lounge.kurly.com/link
/// fails inside the hidden WebView + intent:// path). iOS uses platform default.
///
/// [alreadyTracked]이 true면 클릭 이벤트를 다시 보내지 않는다.
/// (장바구니 `_openCoupangLink`가 이미 문맥과 함께 전송한 경우)
Future<void> openMarketplaceLink(
  BuildContext context, {
  String? deepLinkUrl,
  String? httpsUrl,
  ShoppingMarketplace marketplace = ShoppingMarketplace.coupang,
  String? ingredientName,
  String? recipeId,
  String? productId,
  String? sourceScreen,
  bool alreadyTracked = false,
}) async {
  final marketplaceName = _marketplaceAnalyticsName(marketplace);
  final analytics = AnalyticsService();
  if (!alreadyTracked) {
    unawaited(analytics.trackAffiliateLinkClicked(
      marketplace: marketplaceName,
      ingredientName: ingredientName,
      recipeId: recipeId,
      productId: productId,
      sourceScreen: sourceScreen,
    ));
  }

  void trackOpenResult({
    required bool success,
    String? failureReason,
  }) {
    unawaited(analytics.trackAffiliateOpenResult(
      marketplace: marketplaceName,
      success: success,
      productId: productId,
      ingredientName: ingredientName,
      recipeId: recipeId,
      sourceScreen: sourceScreen,
      failureReason: failureReason,
      platform: _openPlatformAnalyticsName(),
    ));
  }

  String? normalizedDeepLink = deepLinkUrl?.trim();
  if (normalizedDeepLink != null && normalizedDeepLink.isNotEmpty) {
    final hasScheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
    ).hasMatch(normalizedDeepLink);
    if (!hasScheme &&
        !normalizedDeepLink.startsWith('http://') &&
        !normalizedDeepLink.startsWith('https://')) {
      normalizedDeepLink = 'https://$normalizedDeepLink';
    }
  } else {
    normalizedDeepLink = null;
  }

  String? normalizedHttps = httpsUrl?.trim();
  if (normalizedHttps != null && normalizedHttps.isNotEmpty) {
    final hasScheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
    ).hasMatch(normalizedHttps);
    if (!hasScheme &&
        !normalizedHttps.startsWith('http://') &&
        !normalizedHttps.startsWith('https://')) {
      normalizedHttps = 'https://$normalizedHttps';
    }
  } else {
    normalizedHttps = null;
  }

  if (marketplace == ShoppingMarketplace.coupang) {
    final commissionWebUrl = <String?>[
      normalizedDeepLink,
      normalizedHttps,
    ].whereType<String>().firstWhere(
      (v) => v.startsWith('http://') || v.startsWith('https://'),
      orElse: () => '',
    );
    if (commissionWebUrl.isNotEmpty) {
      try {
        await _launchCoupangInAppBrowserWithAutoClose(
          context,
          Uri.parse(commissionWebUrl),
        );
        trackOpenResult(success: true);
      } catch (e) {
        trackOpenResult(
          success: false,
          failureReason: 'coupang_in_app_browser_error',
        );
      }
      return;
    }
  }

  final bestUrl = normalizedDeepLink ?? normalizedHttps;
  if (bestUrl == null || bestUrl.isEmpty) {
    trackOpenResult(success: false, failureReason: 'empty_url');
    return;
  }

  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  if (isAndroid) {
    final customTabUrl = _firstHttpMarketplaceUrl([
      normalizedHttps,
      normalizedDeepLink,
    ]);
    if (customTabUrl != null) {
      try {
        final launched = await launchMarketplaceHttpsInAppBrowser(
          Uri.parse(customTabUrl),
        );
        trackOpenResult(
          success: launched,
          failureReason: launched ? null : 'in_app_browser_false',
        );
      } catch (e) {
        trackOpenResult(
          success: false,
          failureReason: 'in_app_browser_error',
        );
      }
      return;
    }

    try {
      final launched = await launchUrl(
        Uri.parse(bestUrl),
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (launched) {
        trackOpenResult(success: true);
        return;
      }
      final external = await launchUrl(
        Uri.parse(bestUrl),
        mode: LaunchMode.externalApplication,
      );
      trackOpenResult(
        success: external,
        failureReason: external ? null : 'launch_url_false',
      );
    } catch (e) {
      trackOpenResult(success: false, failureReason: 'launch_url_error');
    }
    return;
  }

  try {
    final launched = await launchUrl(Uri.parse(bestUrl));
    trackOpenResult(
      success: launched,
      failureReason: launched ? null : 'launch_url_false',
    );
  } catch (e) {
    trackOpenResult(success: false, failureReason: 'launch_url_error');
  }
}

/// Buy button colors per marketplace.
const Color _marketplaceCoupangCyan = Color(0xFF64C9E7);
const Color _marketplaceKurlyPurple = Color(0xFF5F0080);
const Color _marketplaceOasisGreen = Color(0xFF286C0A);
const MethodChannel _nativeShareChannel = MethodChannel('yorigo.app/share');

Map<String, double>? _parseRecipeQtyByUnitField(dynamic raw) {
  if (raw == null) return null;
  if (raw is! Map) return null;
  final out = <String, double>{};
  for (final e in raw.entries) {
    final k = e.key?.toString() ?? '';
    final v = e.value;
    final q = v is num
        ? v.toDouble()
        : (double.tryParse(v?.toString() ?? '') ?? 0.0);
    if (q > 0) out[k] = (out[k] ?? 0) + q;
  }
  return out.isEmpty ? null : out;
}

/// Rebuilds raw recipe unit totals for [ingredientName] from cart lines (fallback
/// when [recipeQtyByUnit] is not stored on the aggregated map).
Map<String, double> _recipeQtyByUnitFromCart(
  List<dynamic> cartItems,
  String ingredientName,
) {
  Map<String, double>? acc;
  for (final item in cartItems) {
    final cartItem = item as Map<String, dynamic>;
    final ingredients = cartItem['ingredients'] as List? ?? [];
    for (final ingredient in ingredients) {
      final ing = ingredient as Map<String, dynamic>;
      final name = ing['item']?.toString() ?? '';
      if (name != ingredientName) continue;
      final rawQty = ing['qty'];
      final qty = rawQty is num
          ? rawQty.toDouble()
          : (rawQty is String ? double.tryParse(rawQty) : null);
      final unit = ing['unit']?.toString() ?? '';
      if (qty == null || qty <= 0) continue;
      acc = IngredientUnitConverter.mergeRecipeQtyByUnit(acc, unit, qty);
    }
  }
  return acc ?? const <String, double>{};
}

String _formatCartIngredientNeedLabel(
  String ingredientName,
  Map<String, dynamic> ingredientData,
  List<dynamic>? cartItems,
) {
  final totalQty = (ingredientData['totalQty'] as num?)?.toDouble() ?? 0.0;
  final unit = ingredientData['unit']?.toString() ?? '개';
  var recipeMap = _parseRecipeQtyByUnitField(ingredientData['recipeQtyByUnit']);
  if ((recipeMap == null || recipeMap.isEmpty) && cartItems != null) {
    final fromCart = _recipeQtyByUnitFromCart(cartItems, ingredientName);
    recipeMap = fromCart.isEmpty ? null : fromCart;
  }
  return IngredientUnitConverter.formatCartNeedLabel(
    ingredientName: ingredientName,
    shoppingQty: totalQty,
    shoppingUnit: unit,
    recipeQtyByUnit: recipeMap,
  );
}

/// Legacy rows may still store 두부 as `모` while the pack is in g — scale once for math.
double _cartNeededForPackageMath({
  required String ingredientName,
  required String unit,
  required double recipeNeeded,
  required String? packageUnit,
}) {
  final n = ingredientName.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (!n.contains('두부') || n.contains('순두부')) return recipeNeeded;
  final u = unit.trim().toLowerCase();
  if (u != '모') return recipeNeeded;
  final pu = (packageUnit ?? '').trim().toLowerCase();
  final treatAsMass =
      pu == 'g' || pu == 'gram' || pu == 'grams' || pu == 'ml' || pu.isEmpty;
  if (treatAsMass) {
    return recipeNeeded * 300.0;
  }
  return recipeNeeded;
}

// --- Shimmer: same style as home (thin band, smooth purple→blue, white card) ---
const _shimmerGradient = LinearGradient(
  colors: [
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
    Color(0xFFF6F2FF), // subtle lavender
    Color(0xFFF2F6FF), // subtle blue
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
  ],
  stops: [0.0, 0.44, 0.48, 0.52, 0.56, 1.0],
  begin: Alignment(-1.0, -1.0),
  end: Alignment(1.0, 1.0),
  tileMode: TileMode.clamp,
);

class _SlidingDiagonalGradientTransform extends GradientTransform {
  const _SlidingDiagonalGradientTransform({required this.slidePercent});
  final double slidePercent;
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * slidePercent,
      bounds.height * slidePercent,
      0.0,
    );
  }
}

class _RecommendationFetchTask {
  _RecommendationFetchTask({
    required this.marketplace,
    required this.marketplaceStr,
    required this.ingredientName,
    required this.ingredientData,
    required this.totalQty,
    required this.unit,
    required this.cacheKey,
  });

  final ShoppingMarketplace marketplace;
  final String marketplaceStr;
  final String ingredientName;
  final Map<String, dynamic> ingredientData;
  final double totalQty;
  final String? unit;
  final String cacheKey;
}

class _ShimmerScope extends StatefulWidget {
  static _ShimmerScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ShimmerScopeState>();
  const _ShimmerScope({required this.linearGradient, this.child});
  final LinearGradient linearGradient;
  final Widget? child;
  @override
  _ShimmerScopeState createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<_ShimmerScope>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController.unbounded(vsync: this)
      ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1400));
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
    colors: widget.linearGradient.colors,
    stops: widget.linearGradient.stops,
    begin: widget.linearGradient.begin,
    end: widget.linearGradient.end,
    transform: _SlidingDiagonalGradientTransform(
      slidePercent: _shimmerController.value,
    ),
  );
  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;
  Size get size => (context.findRenderObject() as RenderBox).size;
  Offset getDescendantOffset({
    required RenderBox descendant,
    Offset offset = Offset.zero,
  }) {
    final shimmerBox = context.findRenderObject() as RenderBox?;
    return descendant.localToGlobal(offset, ancestor: shimmerBox);
  }

  Listenable get shimmerChanges => _shimmerController;
  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}

class _ShimmerLoading extends StatefulWidget {
  const _ShimmerLoading({required this.isLoading, required this.child});
  final bool isLoading;
  final Widget child;
  @override
  State<_ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<_ShimmerLoading> {
  Listenable? _shimmerChanges;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shimmerChanges?.removeListener(_onShimmerChange);
    _shimmerChanges = _ShimmerScope.of(context)?.shimmerChanges;
    _shimmerChanges?.addListener(_onShimmerChange);
  }

  @override
  void dispose() {
    _shimmerChanges?.removeListener(_onShimmerChange);
    super.dispose();
  }

  void _onShimmerChange() {
    if (widget.isLoading) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;
    final shimmer = _ShimmerScope.of(context);
    if (shimmer == null || !shimmer.isSized) return const SizedBox.shrink();
    final gradient = shimmer.gradient;
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return widget.child;
    // Use card's own bounds so gradient slides within each card (per-card shimmer)
    final childBounds = Rect.fromLTWH(0, 0, ro.size.width, ro.size.height);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => gradient.createShader(childBounds),
      child: widget.child,
    );
  }
}

/// Placeholder blocks in shimmer skeleton; matches home screen image placeholder tone.
const _shimmerSkeletonColor = Color(0xFFEBECF0);

/// Skeleton shapes matching the ingredient product card layout exactly (size, roundness, padding).
class _IngredientCardShimmerSkeleton extends StatelessWidget {
  const _IngredientCardShimmerSkeleton({this.isFirstInSection = false});
  final bool isFirstInSection;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: isFirstInSection ? 0 : 4,
        bottom: 4,
      ),
      child: Container(
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.black.withOpacity(0.07), width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x07000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 12,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          // Match the loaded card: pill centered inside a
                          // 90px-wide box (same width as the image), so the
                          // left column width is fixed at 90 and the right
                          // Expanded column doesn't shift on transition.
                          SizedBox(
                            width: 90,
                            child: Center(
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 60,
                                  maxWidth: 100,
                                ),
                                height: 26,
                                decoration: BoxDecoration(
                                  color: _shimmerSkeletonColor,
                                  borderRadius: BorderRadius.circular(100),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              color: _shimmerSkeletonColor,
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Delete (28x28) + 구매확인 pill (~76x28) row.
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: _shimmerSkeletonColor,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  width: 76,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: _shimmerSkeletonColor,
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            // Product name placeholder: 2 lines of the
                            // loaded Text(fontSize:13, height:1.33) render
                            // at ~17.29px each, so 2 lines ≈ 34.58px. Use
                            // two 15-tall bars with a 5px gap (total ~35)
                            // to match worst-case height exactly.
                            Container(
                              width: double.infinity,
                              height: 15,
                              decoration: BoxDecoration(
                                color: _shimmerSkeletonColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Container(
                              width: 180,
                              height: 15,
                              decoration: BoxDecoration(
                                color: _shimmerSkeletonColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 5),
                            // Package tag + price + per-unit price row
                            // (loaded row is ~21px tall; `end` alignment
                            // keeps the tag bottom-aligned with price).
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  width: 40,
                                  height: 21,
                                  decoration: BoxDecoration(
                                    color: _shimmerSkeletonColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  width: 60,
                                  height: 19,
                                  decoration: BoxDecoration(
                                    color: _shimmerSkeletonColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  width: 46,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: _shimmerSkeletonColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            // Rating line (star + rating + reviews) — loaded
                            // uses fontSize 9.5 so ~12px tall.
                            Container(
                              width: 64,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _shimmerSkeletonColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 3),
                            // Delivery ETA line — same typography as rating
                            // (fontSize 9.5), placeholder ~12px tall.
                            Container(
                              width: 96,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _shimmerSkeletonColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Container(
                    width: double.infinity,
                    // Match loaded 담은 양 bar: vertical padding 8+8 +
                    // thumbnails 20px (common case) + 0.667px border ×2
                    // ≈ 37px. (Loaded row height is dominated by the 20×20
                    // recipe thumbnail circles, with the chevron 16 and
                    // text fs:11 (~13) both shorter.)
                    height: 37,
                    decoration: BoxDecoration(
                      color: _shimmerSkeletonColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 15, right: 15, top: 10),
                  child: Container(height: 1, color: _shimmerSkeletonColor),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 42,
                          decoration: BoxDecoration(
                            color: _shimmerSkeletonColor,
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // "대체상품 보기" button in the loaded card: padding
                      // horizontal 14 + text fontSize 12.5 w800 → ~110px.
                      Container(
                        width: 110,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _shimmerSkeletonColor,
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                    ],
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

/// Thin progress line at top of cart bottom bar; animates fill to the right based on fraction.
class _CartProgressLine extends StatefulWidget {
  const _CartProgressLine({required this.fraction, required this.brightness});

  final double fraction;
  final Brightness brightness;

  @override
  State<_CartProgressLine> createState() => _CartProgressLineState();
}

class _CartProgressLineState extends State<_CartProgressLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _animation = Tween<double>(
      begin: 0,
      end: widget.fraction,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void didUpdateWidget(_CartProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fraction != widget.fraction) {
      // Animate from previous target to new target (controller.value is 1 after completion, so use oldWidget.fraction)
      _animation = Tween<double>(
        begin: oldWidget.fraction,
        end: widget.fraction,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
      _controller.reset();
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lineColor = widget.brightness == Brightness.dark
        ? const Color(0xFF3C3C3C)
        : const Color(0xFFE8E8E8);
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return SizedBox(
              height: 3,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(height: 3, width: w, color: lineColor),
                  Container(
                    height: 3,
                    width: w * _animation.value,
                    decoration: const BoxDecoration(color: _cartAccentOrange),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Shared outer shell for cart fridge status pills (progress + complete).
/// Progress sizes intrinsically; complete expands to that same footprint.
class _CartFridgeStatusShell extends StatelessWidget {
  const _CartFridgeStatusShell({
    required this.borderColor,
    required this.child,
    this.shadowColor,
    this.expand = false,
  });

  static const double height = 54;

  final Color borderColor;
  final Color? shadowColor;
  final Widget child;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: expand ? double.infinity : null,
      height: expand ? double.infinity : height,
      padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white,
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          if (shadowColor != null)
            BoxShadow(
              color: shadowColor!,
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
        ],
      ),
      child: child,
    );
  }
}

/// Progress → complete: ring fill and icy CTA morph run together (overlapped).
class _CartFridgeStatusTransition extends StatefulWidget {
  const _CartFridgeStatusTransition({
    required this.allComplete,
    required this.purchased,
    required this.total,
    required this.fraction,
    required this.onPurchaseComplete,
  });

  final bool allComplete;
  final int purchased;
  final int total;
  final double fraction;
  final VoidCallback? onPurchaseComplete;

  @override
  State<_CartFridgeStatusTransition> createState() =>
      _CartFridgeStatusTransitionState();
}

class _CartFridgeStatusTransitionState extends State<_CartFridgeStatusTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph;

  static const Duration _morphInDuration = Duration(milliseconds: 280);
  static const Duration _morphOutDuration = Duration(milliseconds: 360);

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(
      vsync: this,
      duration: _morphInDuration,
      reverseDuration: _morphOutDuration,
    );
    if (widget.allComplete) {
      _morph.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant _CartFridgeStatusTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.allComplete && !oldWidget.allComplete) {
      // Ring fill (via fraction→1) and CTA morph start in the same frame.
      _morph.forward();
    } else if (!widget.allComplete && oldWidget.allComplete) {
      // Soft reverse morph back to the in-progress pill.
      _morph.reverse();
    }
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the progress badge in a stable slot so its ring tween continues
    // while the icy CTA crossfades — both directions share the same morph.
    return AnimatedBuilder(
      animation: _morph,
      builder: (context, _) {
        final raw = _morph.value;
        final t = widget.allComplete
            ? Curves.easeOutCubic.transform(raw)
            : Curves.easeInOutCubic.transform(raw);
        final showCompleteLayer = raw > 0.001;
        // While morphing to complete, keep ring full; on the way back, show
        // the live cart fraction so the ring eases down with the crossfade.
        final useCompleteStats = widget.allComplete;
        return Stack(
          alignment: Alignment.centerRight,
          clipBehavior: Clip.none,
          children: [
            IgnorePointer(
              ignoring: t > 0.45,
              child: Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 1 - 0.04 * t,
                  alignment: Alignment.centerRight,
                  child: _CartFridgeProgressBadge(
                    key: const ValueKey('purchase-progress-badge'),
                    purchased:
                        useCompleteStats ? widget.total : widget.purchased,
                    total: widget.total,
                    fraction: useCompleteStats ? 1.0 : widget.fraction,
                  ),
                ),
              ),
            ),
            if (showCompleteLayer)
              IgnorePointer(
                ignoring: !widget.allComplete || t < 0.55,
                child: Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.96 + 0.04 * t,
                    alignment: Alignment.centerRight,
                    child: Transform.translate(
                      offset: Offset(6 * (1 - t), 0),
                      child: _CartCompletePulseButton(
                        key: const ValueKey('purchase-complete-button'),
                        onTap: widget.onPurchaseComplete,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// In-progress fridge destination badge: ring + remaining count + destination copy.
class _CartFridgeProgressBadge extends StatelessWidget {
  const _CartFridgeProgressBadge({
    super.key,
    required this.purchased,
    required this.total,
    required this.fraction,
  });

  final int purchased;
  final int total;
  final double fraction;

  static const Color _accent = Color(0xFFFF6422);
  static const Color _ink = Color(0xFF191F28);

  static const TextStyle _statusStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 12.5,
    fontWeight: FontWeight.w900,
    color: _ink,
    letterSpacing: -0.55,
    height: 1.05,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle _countStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 10,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.3,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle _destStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 10,
    fontWeight: FontWeight.w700,
    color: Color(0x6B191F28), // _ink @ 0.42
    letterSpacing: -0.25,
    height: 1,
  );

  @override
  Widget build(BuildContext context) {
    final remaining = (total - purchased).clamp(0, total);
    final statusLine = remaining == 0
        ? '준비 완료'
        : remaining == total
            ? '구매 시작'
            : '$remaining개 남음';
    // Reserve only as wide as this cart needs (not a global "99개").
    final statusProbes = <String>[
      '구매 시작',
      '준비 완료',
      for (var i = 1; i <= total.clamp(1, 99); i++) '$i개 남음',
    ];
    final countProbe = '$total/$total';

    return _CartFridgeStatusShell(
      borderColor: const Color(0xFFFFDCC8),
      shadowColor: _accent.withValues(alpha: 0.07),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 38,
                  height: 38,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: fraction.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeInOutCubic,
                    builder: (context, value, _) {
                      return CustomPaint(
                        painter: _FridgeProgressRingPainter(
                          progress: value,
                          trackColor: const Color(0xFFFFE0CC),
                          progressColor: _accent,
                          strokeWidth: 3.2,
                        ),
                      );
                    },
                  ),
                ),
                const Icon(
                  Icons.kitchen_rounded,
                  size: 16,
                  color: _accent,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  for (final probe in statusProbes)
                    Opacity(
                      opacity: 0,
                      child: Text(probe, style: _statusStyle, maxLines: 1),
                    ),
                  Text(statusLine, style: _statusStyle, maxLines: 1),
                ],
              ),
              const SizedBox(height: 2),
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Opacity(
                    opacity: 0,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: countProbe, style: _countStyle),
                          const TextSpan(text: ' · 냉장고로', style: _destStyle),
                        ],
                      ),
                      maxLines: 1,
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$purchased/$total',
                          style: _countStyle.copyWith(
                            color: _accent.withValues(alpha: 0.90),
                          ),
                        ),
                        const TextSpan(text: ' · 냉장고로', style: _destStyle),
                      ],
                    ),
                    maxLines: 1,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FridgeProgressRingPainter extends CustomPainter {
  const _FridgeProgressRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) return;

    final progressPaint = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: [
          progressColor.withValues(alpha: 0.75),
          progressColor,
          const Color(0xFFFF8A4C),
        ],
        stops: const [0.0, 0.55, 1.0],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _FridgeProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Complete CTA — pressable icy button matching progress pill geometry.
class _CartCompletePulseButton extends StatefulWidget {
  const _CartCompletePulseButton({super.key, required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_CartCompletePulseButton> createState() =>
      _CartCompletePulseButtonState();
}

class _CartCompletePulseButtonState extends State<_CartCompletePulseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shineController;
  bool _pressed = false;

  static const Color _ice = Color(0xFF2F8FFF);

  @override
  void initState() {
    super.initState();
    // Same shine cadence as the old orange "구매 완료" pulse button.
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _shineController.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
        onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
        // InkWell과 TapGestureRecognizer를 같이 쓰면 부모 recognizer가
        // 이겨 onTap이 삼켜진다. 실제 탭은 여기서만 처리한다.
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedBuilder(
            animation: _shineController,
            builder: (context, child) {
              // Linear 0→1 like the original orange button (no easeInOut).
              final shineT = _shineController.value;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOutCubic,
                height: _CartFridgeStatusShell.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0xFF7EC8FF),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1A7FE8)
                          .withValues(alpha: _pressed ? 0.16 : 0.26),
                      blurRadius: _pressed ? 7 : 14,
                      offset: Offset(0, _pressed ? 2 : 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  clipBehavior: Clip.antiAlias,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: null,
                      splashColor: Colors.white.withValues(alpha: 0.18),
                      highlightColor: Colors.white.withValues(alpha: 0.08),
                      child: Ink(
                        decoration: const BoxDecoration(
                          // Freezer door: cool sky → frosted pale
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Color(0xFF2F8FFF),
                              Color(0xFF5BB8FF),
                              Color(0xFF93D4FF),
                              Color(0xFFC9EBFF),
                            ],
                            stops: [0.0, 0.30, 0.66, 1.0],
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Frosted glass glaze
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Padding(
                                  padding: const EdgeInsets.all(1),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(999),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Colors.white.withValues(alpha: 0.42),
                                          Colors.white.withValues(alpha: 0.06),
                                          const Color(0xFFB8E8FF)
                                              .withValues(alpha: 0.22),
                                        ],
                                        stops: const [0.0, 0.48, 1.0],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Cold edge along the bottom (freezer lip)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.white.withValues(alpha: 0.0),
                                        const Color(0xFF1E7AE0)
                                            .withValues(alpha: 0.10),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Same shine band as the old orange "구매 완료" button:
                            // vertical strip sweeping left → right, white @ 0.32.
                            Positioned.fill(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final w = constraints.maxWidth;
                                  // Original used Offset(-52 + 104 * t) on a 48px circle.
                                  // Scale travel to this pill width the same way.
                                  final halfTravel = w / 2 + 16;
                                  return IgnorePointer(
                                    child: ClipRect(
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Transform.translate(
                                            offset: Offset(
                                              -halfTravel +
                                                  2 * halfTravel * shineT,
                                              0,
                                            ),
                                            child: Container(
                                              width: 16,
                                              height: constraints.maxHeight + 16,
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.centerLeft,
                                                  end: Alignment.centerRight,
                                                  colors: [
                                                    Colors.white
                                                        .withValues(alpha: 0),
                                                    Colors.white
                                                        .withValues(alpha: 0.32),
                                                    Colors.white
                                                        .withValues(alpha: 0),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              child: child,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.kitchen_rounded,
                  size: 20,
                  color: Colors.white,
                ),
                SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '냉장고에서 관리',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF191F28),
                        letterSpacing: -0.45,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '탭해서 담기',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF191F28),
                        letterSpacing: -0.2,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Caches the user document stream so StreamBuilder doesn't resubscribe on parent rebuilds
/// (e.g. checkbox toggle), avoiding blank screen + loading + scroll reset.
class _CartDocumentStream extends StatefulWidget {
  const _CartDocumentStream({
    required this.user,
    required this.userService,
    required this.brightness,
    required this.buildContent,
  });

  final User user;
  final UserService userService;
  final Brightness brightness;
  final Widget Function(
    BuildContext context,
    AsyncSnapshot<DocumentSnapshot> snapshot,
  )
  buildContent;

  @override
  State<_CartDocumentStream> createState() => _CartDocumentStreamState();
}

class _CartDocumentStreamState extends State<_CartDocumentStream> {
  Stream<DocumentSnapshot>? _stream;

  @override
  void initState() {
    super.initState();
    _stream = widget.userService.getUserStream(widget.user.uid);
  }

  @override
  void didUpdateWidget(_CartDocumentStream oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) {
      _stream = widget.userService.getUserStream(widget.user.uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _stream,
      builder: widget.buildContent,
    );
  }
}

/// Signature for storing undo data (fridge + cart) before 구매 완료.
typedef StoreUndoDataCallback =
    void Function(Map<String, dynamic>? fridgeData, List<dynamic> cartItems);

/// Returns global offset of fridge nav icon center (optional, e.g. for future use).
typedef GetFridgeNavOffsetCallback = Offset? Function();

/// Popup content for quantity detail: total and recipe breakdown.
class _QuantityDetailPopupContent extends StatefulWidget {
  const _QuantityDetailPopupContent({
    required this.ingredientName,
    required this.unit,
    required this.recipeTotalQty,
    required this.breakdown,
    required this.thumbnailByRecipeId,
    this.platformByRecipeId = const {},
    this.sourceUrlByRecipeId = const {},
    this.recipeQtyByUnit,
  });

  final String ingredientName;
  final String unit;
  final double recipeTotalQty;
  final List<({String recipeId, String recipeName, double qty, String unit})>
  breakdown;
  final Map<String, String> thumbnailByRecipeId;
  final Map<String, String> platformByRecipeId;
  final Map<String, String> sourceUrlByRecipeId;

  /// Raw recipe units merged across cart lines (same as aggregated map field).
  final Map<String, double>? recipeQtyByUnit;

  @override
  State<_QuantityDetailPopupContent> createState() =>
      _QuantityDetailPopupContentState();
}

class _QuantityDetailPopupContentState
    extends State<_QuantityDetailPopupContent> {
  late List<({String recipeId, String recipeName, double qty, String unit})>
  _rows;

  @override
  void initState() {
    super.initState();
    _rows =
        List<
          ({String recipeId, String recipeName, double qty, String unit})
        >.from(widget.breakdown);
  }

  String _fmtQtyForRow(double qty, String unit) {
    final conv = IngredientUnitConverter.toShoppingUnit(
      ingredientName: widget.ingredientName,
      qty: qty,
      unit: unit,
    );
    final rowRecipe = IngredientUnitConverter.mergeRecipeQtyByUnit(
      null,
      unit,
      qty,
    );
    return IngredientUnitConverter.formatCartNeedLabel(
      ingredientName: widget.ingredientName,
      shoppingQty: conv.qty,
      shoppingUnit: conv.unit,
      recipeQtyByUnit: rowRecipe,
    );
  }

  String get _totalFormatted => IngredientUnitConverter.formatCartNeedLabel(
    ingredientName: widget.ingredientName,
    shoppingQty: widget.recipeTotalQty,
    shoppingUnit: widget.unit,
    recipeQtyByUnit: widget.recipeQtyByUnit,
  );

  @override
  Widget build(BuildContext context) {
    const textDark = Color(0xFF1A1A1A);
    const textTertiary = Color(0xFFAEAEB2);
    const lineSoft = Color(0xFFF2F2F4);
    const sheetBg = Colors.white;
    const accent = Color(0xFFFF6422);
    final screenSize = MediaQuery.of(context).size;
    final visibleRows = math.max(1, math.min(_rows.length, 3));
    final dialogWidth = math.min(screenSize.width - 36, 420.0);
    final sheetHeight = math.min(
      screenSize.height * 0.62,
      162.0 + visibleRows * 62.0,
    );

    return Container(
      width: dialogWidth,
      height: sheetHeight,
      decoration: const BoxDecoration(
        color: sheetBg,
        borderRadius: BorderRadius.all(Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x2D000000),
            blurRadius: 40,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.ingredientName} 필요량',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          height: 1.25,
                          letterSpacing: -0.5,
                          color: textDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '레시피별로 필요한 양을 한눈에 확인해요',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          letterSpacing: -0.1,
                          color: textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF2F2F6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Color(0xFF9A9AA0),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 18),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF5EF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFFE1D3), width: 1),
            ),
            child: Row(
                children: [
                Container(
                  width: 4,
                  height: 24,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '총 필요량',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: Color(0xFF6E737B),
                  ),
                ),
                const Spacer(),
                Text(
                  _totalFormatted,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                    letterSpacing: -0.6,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Text(
                  '레시피별 사용량',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: Color(0xFF7C828C),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Container(height: 1, color: lineSoft)),
              ],
            ),
          ),
                  Expanded(
                    child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                      itemCount: _rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final row = _rows[index];
                final thumb = widget.thumbnailByRecipeId[row.recipeId] ?? '';
                return Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFB),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFEDEEF2)),
                  ),
                          child: Row(
                            children: [
                              Container(
                        width: 36,
                        height: 36,
                                decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(11),
                                  boxShadow: const [
                                    BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 7,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                                  child: thumb.isNotEmpty
                                      ? ThumbnailLetterboxMitigation(
                                          platform:
                                      widget.platformByRecipeId[row.recipeId] ??
                                              '',
                                          imageUrl: thumb,
                                          sourceUrl:
                                              widget.sourceUrlByRecipeId[row
                                                  .recipeId] ??
                                              '',
                                          child: AppNetworkImage(
                                            imageUrl: thumb,
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            height: double.infinity,
                                    memCacheWidth:
                                        AppNetworkImage.listThumbCacheSize,
                                    memCacheHeight:
                                        AppNetworkImage.listThumbCacheSize,
                                  ),
                                )
                              : Container(color: const Color(0xFFF2F2F6)),
                        ),
                      ),
                      const SizedBox(width: 10),
                              Expanded(
                        child: Text(
                                      row.recipeName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.35,
                                        color: textDark,
                                      ),
                                    ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xFFFFD9C6)),
                        ),
                                    child: Text(
                                      _fmtQtyForRow(row.qty, row.unit),
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                            fontSize: 14,
                                        fontWeight: FontWeight.w900,
                            height: 1,
                            letterSpacing: -0.45,
                                        color: accent,
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        );
                      },
            ),
          ),
        ],
      ),
    );
  }
}

class CartScreen extends StatefulWidget {
  const CartScreen({
    super.key,
    this.onStoreUndoData,
    this.getFridgeNavOffset,
    this.onPurchaseComplete,
    this.onFridgeIconBounceRequested,
  });

  /// Store fridge + cart state before purchase so "구매 완료 취소" can restore.
  final StoreUndoDataCallback? onStoreUndoData;
  final GetFridgeNavOffsetCallback? getFridgeNavOffset;

  /// Called after 구매 완료; navigates to fridge tab.
  final VoidCallback? onPurchaseComplete;

  /// Called after 구매 완료; can trigger fridge icon bounce.
  final VoidCallback? onFridgeIconBounceRequested;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  static const String _snackbarSuppressedEmail = 'joonseokkang0531@gmail.com';
  static const Duration _productSearchTimeout = Duration(seconds: 30);
  /// Inter-event watchdog for the NDJSON recommend stream: if the backend
  /// goes silent for this long (no item completes), treat it as stuck.
  /// Backend hard-caps total batch processing at ~25s
  /// (RECOMMEND_BATCH_TIMEOUT_SECONDS) and always emits something for every
  /// item before closing, so 45s leaves ample margin for network overhead.
  static const Duration _productSearchStreamTimeout = Duration(seconds: 45);
  static const Duration _cartCacheTtl = Duration(hours: 24);
  static const Duration _thumbnailOneShotRefreshDelay = Duration(seconds: 3);
  static const String _cartHasHeldRecipeKeyPrefix = 'cart_has_held_recipe_';
  static const String _defaultCartRecipeId =
      'default_samgyeopsal_garlic_steam_preview';
  static const String _defaultCartRecipeDismissedKeyPrefix =
      'default_cart_recipe_dismissed_';

  static bool _isEggIngredient(String name) {
    final lower = name.toLowerCase();
    return lower.contains('계란') ||
        lower.contains('달걀') ||
        lower.contains('egg');
  }

  bool _affiliateDisclosureDismissed = false;

  final UserService _userService = UserService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final AuthService _authService = AuthService();
  final CoupangService _coupangService = CoupangService();
  final RecipeService _recipeService = RecipeService.shared;
  final MealPlanService _mealPlanService = MealPlanService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final LocalStorageService _localStorageService = LocalStorageService();

  /// One stream instance so nested StreamBuilders do not create duplicate Firestore listeners.
  late final Stream<SavedRecipesResult> _cartUserRecipesStream = _recipeService
      .getUserRecipes();

  // Cache for product recommendations (recommend_products API). Key: marketplace:ingredientName (e.g. coupang:대파, kurly:대파)
  final Map<String, ProductRecommendation> _productRecommendationCache = {};

  String _recommendationCacheKey(
    ShoppingMarketplace m,
    String ingredientName,
  ) => '${m.name}:$ingredientName';

  ProductRecommendation? _getCachedRecommendation(String ingredientName) =>
      _productRecommendationCache[_recommendationCacheKey(
        _selectedMarketplace,
        ingredientName,
      )];

  ProductRecommendation? _getCachedRecommendationByMarketplace(
    String ingredientName,
    ShoppingMarketplace marketplace,
  ) =>
      _productRecommendationCache[_recommendationCacheKey(
        marketplace,
        ingredientName,
      )];

  // Cache for ingredient categorization (from previous sessions, now unused but kept for compatibility)
  final Map<String, String> _ingredientCategoryCache = {};

  // Store current cart items for async operations
  List<dynamic>? _currentCartItems;
  List<dynamic>? _cachedCartItems;
  String? _cachedCartUid;
  String _cachedCartSignature = '';
  StreamSubscription<User?>? _authStateSubscription;
  Timer? _authNullDebounceTimer;

  // Loading states
  bool _isSearchingProducts = false;
  bool _hasCompletedInitialSearch = false;
  bool _hasBeenVisible = false; // Track if cart screen has been visible to user
  bool _isCartVisibleNow = false;
  /// [UserService.addToCart] 직후에만 true. 탭에 없어도 changedTargets 검색 허용.
  bool _allowSearchAfterCartAdd = false;
  StreamSubscription<void>? _cartItemAddedSubscription;
  bool _hasUsedCartWithRecipeBefore = false;
  bool _defaultCartRecipeDismissed = false;
  bool _isEnsuringDefaultCartRecipe = false;
  bool _cartMajorityCheckedFired = false;
  bool _productSearchFailed = false;
  String _productSearchFailureMessage = '';
  Map<String, Map<String, dynamic>> _lastAggregatedIngredientsForRetry = {};
  final Map<String, bool> _ingredientLoadingStates = {};
  final Map<String, String> _lastRequestedSignatureByCacheKey = {};
  final Set<String> _missingRecommendationKeys = {};
  Set<String>? _collapsedIngredientDetailKeys;

  Set<String> get _collapsedIngredientDetailKeySet =>
      _collapsedIngredientDetailKeys ??= <String>{};

  final Map<String, String> _preprocessedNameCache = {};

  Timer? _recommendationCacheSaveTimer;
  static const Duration _recommendationCacheSaveDebounce = Duration(
    milliseconds: 500,
  );

  // Meal plans map: recipeId -> date
  Map<String, DateTime> _recipeDates = {};
  Map<String, String> _recipeThumbnailById = {};
  Map<String, String> _recipePlatformById = {};
  Map<String, String> _recipeSourceUrlById = {};
  bool _isLoadingMealPlans = false;
  bool _isLoadingRecipeThumbnails = false;
  String _lastRecipeIdsHash = '';
  String _lastThumbnailLookupHash = '';
  String _thumbnailOneShotRefreshHash = '';
  Timer? _thumbnailOneShotRefreshTimer;

  // Selected marketplace (only Coupang has product data for now).
  ShoppingMarketplace _selectedMarketplace = ShoppingMarketplace.coupang;
  /// 메모장(체크리스트) 모드 — 상품 추천을 접고 구매확인만 하는 장보기 목록.
  bool _isManualShoppingMode = false;
  /// 구매 완료 연타로 fridge append가 중복되지 않게 막는 가드.
  bool _isPurchaseCompleting = false;
  bool _isSubmittingPurchaseVerification = false;
  /// 상단 배너를 X로 닫으면 true — 상품 목록 맨 아래 섹션으로 이동.
  bool _purchaseVerificationPinnedToBottom = false;
  /// 인증 완료/하단 섹션 X — 완전히 숨김.
  bool _purchaseVerificationHidden = false;
  final ImagePicker _purchaseVerifyImagePicker = ImagePicker();

  static const List<ShoppingMarketplace> _swipeableMarketplaces = [
    ShoppingMarketplace.coupang,
    ShoppingMarketplace.marketKurly,
  ];

  // Purchased ingredients are tracked per marketplace so checks don't bleed across tabs.
  final Map<ShoppingMarketplace, Set<String>>
  _purchasedIngredientKeysByMarketplace = {
    for (final marketplace in ShoppingMarketplace.values)
      marketplace: <String>{},
  };
  final Map<String, ShoppingMarketplace> _purchasedMarketplaceByIngredient = {};
  /// 상품 카드 impression 중복 로깅 방지 — 화면 생존 기간 동안 유지.
  final Set<String> _impressedProductCardKeys = <String>{};

  /// 재료별 상품 추천 카드를 VisibilityDetector로 감싸 impression 계측.
  /// [_buildIngredientProductCard] 내부는 early return이 많아 직접 계측하기보다
  /// 호출부에서 감싸는 편이 안전하다(내부 분기 전부를 계측 대상으로 다룰 필요 없음 —
  /// 실제 상품 카드가 렌더된 케이스만 impression 대상으로 삼는다).
  Widget _wrapProductCardImpression({
    required String ingredientName,
    required ShoppingMarketplace marketplace,
    required int position,
    required Widget child,
  }) {
    final recommendation =
        _getCachedRecommendationByMarketplace(ingredientName, marketplace) ??
        _getCachedRecommendation(ingredientName);
    final bestMatch = recommendation?.bestMatch;
    if (bestMatch == null) {
      // 상품 매칭 전(로딩/미매칭) 상태 — 계측 대상 아님.
      return child;
    }
    final String marketplaceLabel = _marketplaceForAnalytics(marketplace);
    final String dedupKey =
        '$marketplaceLabel::$ingredientName::${bestMatch.productId}';
    return VisibilityDetector(
      key: Key('cart_product_card_impression_$dedupKey'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (_impressedProductCardKeys.contains(dedupKey)) return;
        _impressedProductCardKeys.add(dedupKey);
        unawaited(
          _analyticsService.logCardEvent(
            'impression',
            screen: 'cart',
            sectionId: 'ingredient_product_list',
            cardId: bestMatch.productId,
            contentType: 'product',
            position: position,
            marketplace: marketplaceLabel,
            productId: bestMatch.productId,
            recipeId: _analyticsRecipeIdForIngredient(ingredientName),
            ingredientName: ingredientName,
            price: bestMatch.productPrice,
            productRating: bestMatch.rating,
            productReviewCount: bestMatch.reviews,
            productBayesianRating: bestMatch.bayesianRating,
            productValueScore: bestMatch.valueScore,
            productIsRocket: bestMatch.isRocket,
            productIsFreeShipping: bestMatch.isFreeShipping,
            productDiscountRate: bestMatch.discountRate,
            productUnitPrice: bestMatch.unitPrice,
            productPackageSize: bestMatch.packageSize,
            productPackageUnit: bestMatch.packageUnit,
            productSalesRank: bestMatch.salesRank,
          ),
        );
      },
      child: child,
    );
  }

  Set<String> get _purchasedIngredientKeys {
    final purchased = <String>{};
    for (final purchasedKeys in _purchasedIngredientKeysByMarketplace.values) {
      purchased.addAll(purchasedKeys);
    }
    return purchased;
  }

  int _recommendationPriceForMarketplace(
    String ingredientName,
    ShoppingMarketplace marketplace,
  ) {
    final recommendation =
        _getCachedRecommendationByMarketplace(ingredientName, marketplace) ??
        _getCachedRecommendation(ingredientName);
    final bestMatch = recommendation?.bestMatch;
    return (bestMatch?.productPrice ?? 0).clamp(0, 1 << 31);
  }

  ({int totalDelta, int coupangDelta, int kurlyDelta}) _spendDeltaByMarketplace(
    ShoppingMarketplace marketplace,
    int price,
    bool isAdd,
  ) {
    final int signed = isAdd ? price : -price;
    if (marketplace == ShoppingMarketplace.coupang) {
      return (totalDelta: signed, coupangDelta: signed, kurlyDelta: 0);
    }
    if (marketplace == ShoppingMarketplace.marketKurly) {
      return (totalDelta: signed, coupangDelta: 0, kurlyDelta: signed);
    }
    return (totalDelta: signed, coupangDelta: 0, kurlyDelta: 0);
  }

  String _marketplaceForAnalytics(ShoppingMarketplace marketplace) {
    if (marketplace == ShoppingMarketplace.coupang) {
      return 'coupang';
    }
    if (marketplace == ShoppingMarketplace.marketKurly) {
      return 'kurly';
    }
    return marketplace.name;
  }

  String? _analyticsRecipeIdForIngredient(String ingredientName) {
    final items = _cachedCartItems ?? _currentCartItems;
    if (items == null) return null;
    String? found;
    final recipeIds = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final cartItem = Map<String, dynamic>.from(item);
      final recipeId = cartItem['recipeId']?.toString().trim() ?? '';
      if (recipeId.isEmpty) continue;
      recipeIds.add(recipeId);
      final ingredients = cartItem['ingredients'] as List? ?? const [];
      for (final ingredient in ingredients) {
        if (ingredient is! Map) continue;
        final name = ingredient['item']?.toString() ?? '';
        if (name != ingredientName) continue;
        found ??= recipeId;
        break;
      }
    }
    if (found != null && found.isNotEmpty) return found;
    // 재료명 매칭이 실패해도 장바구니에 레시피가 하나면 그 id를 쓴다.
    if (recipeIds.length == 1) return recipeIds.first;
    return null;
  }

  void _markIngredientPurchased(
    String ingredientName, {
    ShoppingMarketplace? marketplace,
    String? category,
    int? productPrice,
  }) {
    Haptics.light();
    final targetMarketplace = marketplace ?? _selectedMarketplace;
    final wasPurchasedAnywhere = _purchasedIngredientKeys.contains(
      ingredientName,
    );
    final purchasedKeys = _purchasedIngredientKeysByMarketplace.putIfAbsent(
      targetMarketplace,
      () => <String>{},
    );
    final bool inserted = purchasedKeys.add(ingredientName);
    _purchasedMarketplaceByIngredient[ingredientName] = targetMarketplace;
    unawaited(
      _analyticsService.trackIngredientPurchaseChecked(
        ingredientName: ingredientName,
        isChecked: true,
        category: category,
        marketplace: _marketplaceForAnalytics(targetMarketplace),
        recipeId: _analyticsRecipeIdForIngredient(ingredientName),
      ),
    );

    final recommendation =
        _getCachedRecommendationByMarketplace(
          ingredientName,
          targetMarketplace,
        ) ??
        _getCachedRecommendation(ingredientName);
    final bestMatch = recommendation?.bestMatch;
    final user = _auth.currentUser;
    if (user != null) {
      final resolvedPrice = (productPrice ?? bestMatch?.productPrice ?? 0)
          .clamp(0, 1 << 31)
          .toInt();
      unawaited(
        _analyticsService.trackProductCheckEvent(
          userId: user.uid,
          ingredientName: ingredientName,
          isChecked: true,
          marketplace: _marketplaceForAnalytics(targetMarketplace),
          category: category,
          recipeId: _analyticsRecipeIdForIngredient(ingredientName),
          platformProductName: bestMatch?.productName,
          price: resolvedPrice > 0 ? resolvedPrice : null,
          productId: bestMatch?.productId,
          productUrl: bestMatch?.productUrl,
          originalUrl: bestMatch?.originalUrl,
          deeplinkUrl: bestMatch?.deeplinkUrl,
          packageSize: bestMatch?.packageSize,
          packageUnit: bestMatch?.packageUnit,
          unitPrice: bestMatch?.unitPrice,
          rating: bestMatch?.rating,
          reviews: bestMatch?.reviews,
          matchScore: bestMatch?.matchScore,
        ),
      );
    }

    if (inserted && !wasPurchasedAnywhere) {
      _checkCartMajorityThreshold();
    }

    if (!inserted || wasPurchasedAnywhere) {
      return;
    }

    if (user == null) return;
    final int price =
        (productPrice ??
                _recommendationPriceForMarketplace(
                  ingredientName,
                  targetMarketplace,
                ))
            .clamp(0, 1 << 31);
    if (price <= 0) return;
    final delta = _spendDeltaByMarketplace(targetMarketplace, price, true);
    unawaited(
      _analyticsService.trackPurchaseSpendDeltaForUser(
        user.uid,
        totalDelta: delta.totalDelta,
        coupangDelta: delta.coupangDelta,
        kurlyDelta: delta.kurlyDelta,
      ),
    );
  }

  void _checkCartMajorityThreshold() {
    if (_cartMajorityCheckedFired) return;
    final aggregated = _lastAggregatedIngredientsForRetry;
    if (aggregated.isEmpty) return;
    final totalIngredients = aggregated.length;
    final threshold = (totalIngredients / 2).ceil();
    final checkedCount =
        _purchasedIngredientKeys
            .where((k) => aggregated.containsKey(k))
            .length;
    if (checkedCount >= threshold) {
      _cartMajorityCheckedFired = true;
      final cartItems = _cachedCartItems;
      final recipeName = cartItems != null && cartItems.isNotEmpty
          ? (cartItems.first as Map<String, dynamic>)['title']?.toString() ??
              'cart'
          : 'cart';
      final recipeId = cartItems != null && cartItems.isNotEmpty
          ? (cartItems.first as Map<String, dynamic>)['recipeId']?.toString() ??
              ''
          : '';
      unawaited(_analyticsService.trackCartMajorityChecked(
        recipeId: recipeId,
        recipeName: recipeName,
        totalIngredients: totalIngredients,
        checkedCount: checkedCount,
        threshold: threshold,
      ));
    }
  }

  void _unmarkIngredientPurchased(
    String ingredientName, {
    String? category,
    ShoppingMarketplace? marketplace,
  }) {
    final removedMarketplaces = <ShoppingMarketplace>{};
    if (marketplace != null) {
      final removed =
          _purchasedIngredientKeysByMarketplace[marketplace]?.remove(
            ingredientName,
          ) ??
          false;
      if (removed) {
        removedMarketplaces.add(marketplace);
      }
    } else {
      for (final entry in _purchasedIngredientKeysByMarketplace.entries) {
        final removed = entry.value.remove(ingredientName);
        if (removed) {
          removedMarketplaces.add(entry.key);
        }
      }
    }
    final isStillPurchased = _purchasedIngredientKeysByMarketplace.values.any(
      (purchasedKeys) => purchasedKeys.contains(ingredientName),
    );
    if (!isStillPurchased) {
      _purchasedMarketplaceByIngredient.remove(ingredientName);
    } else {
      for (final entry in _purchasedIngredientKeysByMarketplace.entries) {
        if (entry.value.contains(ingredientName)) {
          _purchasedMarketplaceByIngredient[ingredientName] = entry.key;
          break;
        }
      }
    }
    unawaited(
      _analyticsService.trackIngredientPurchaseChecked(
        ingredientName: ingredientName,
        isChecked: false,
        category: category,
        marketplace: _marketplaceForAnalytics(
          marketplace ?? _selectedMarketplace,
        ),
        recipeId: _analyticsRecipeIdForIngredient(ingredientName),
      ),
    );

    if (removedMarketplaces.isEmpty) {
      return;
    }
    final user = _auth.currentUser;
    if (user == null) return;

    for (final removedMarketplace in removedMarketplaces) {
      final recommendation =
          _getCachedRecommendationByMarketplace(
            ingredientName,
            removedMarketplace,
          ) ??
          _getCachedRecommendation(ingredientName);
      final bestMatch = recommendation?.bestMatch;
      unawaited(
        _analyticsService.trackProductCheckEvent(
          userId: user.uid,
          ingredientName: ingredientName,
          isChecked: false,
          marketplace: _marketplaceForAnalytics(removedMarketplace),
          category: category,
          recipeId: _analyticsRecipeIdForIngredient(ingredientName),
          platformProductName: bestMatch?.productName,
          price: bestMatch != null && bestMatch.productPrice > 0
              ? bestMatch.productPrice
              : null,
          productId: bestMatch?.productId,
          productUrl: bestMatch?.productUrl,
          originalUrl: bestMatch?.originalUrl,
          deeplinkUrl: bestMatch?.deeplinkUrl,
          packageSize: bestMatch?.packageSize,
          packageUnit: bestMatch?.packageUnit,
          unitPrice: bestMatch?.unitPrice,
          rating: bestMatch?.rating,
          reviews: bestMatch?.reviews,
          matchScore: bestMatch?.matchScore,
        ),
      );
    }

    int totalDelta = 0;
    int coupangDelta = 0;
    int kurlyDelta = 0;
    for (final removedMarketplace in removedMarketplaces) {
      final int price = _recommendationPriceForMarketplace(
        ingredientName,
        removedMarketplace,
      );
      if (price <= 0) continue;
      final delta = _spendDeltaByMarketplace(removedMarketplace, price, false);
      totalDelta += delta.totalDelta;
      coupangDelta += delta.coupangDelta;
      kurlyDelta += delta.kurlyDelta;
    }

    if (totalDelta == 0 && coupangDelta == 0 && kurlyDelta == 0) {
      return;
    }
    unawaited(
      _analyticsService.trackPurchaseSpendDeltaForUser(
        user.uid,
        totalDelta: totalDelta,
        coupangDelta: coupangDelta,
        kurlyDelta: kurlyDelta,
      ),
    );
  }

  // ignore: unused_element
  String? _purchasedMarketplaceBadgeText(String ingredientName) {
    final inCoupang =
        _purchasedIngredientKeysByMarketplace[ShoppingMarketplace.coupang]
            ?.contains(ingredientName) ??
        false;
    final inKurly =
        _purchasedIngredientKeysByMarketplace[ShoppingMarketplace.marketKurly]
            ?.contains(ingredientName) ??
        false;
    if (inCoupang && inKurly) return '쿠팡+컬리';
    if (inCoupang) return '쿠팡';
    if (inKurly) return '컬리';
    return null;
  }

  /// Keeps scroll position when setState runs (e.g. checkbox toggle).
  final ScrollController _cartScrollController = ScrollController();

  bool get _shouldSuppressBottomNotifications {
    final email = _auth.currentUser?.email?.trim().toLowerCase();
    return email == _snackbarSuppressedEmail;
  }

  void _showBottomNotification(SnackBar snackBar) {
    if (!mounted || _shouldSuppressBottomNotifications) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(snackBar);
  }

  void _maybeShowCartAddTip() {
    if (!mounted || !UserService.pendingCartAddTip) return;
    UserService.pendingCartAddTip = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.success(
        context,
        '여러 레시피 재료를, 필요한 수량만큼 한 번에 편하게 구매할 수 있어요',
        title: '장바구니 담기 완료',
        duration: const Duration(milliseconds: 4200),
      );
    });
  }

  void _retryProductSearch() {
    if (_isSearchingProducts) return;
    if (_lastAggregatedIngredientsForRetry.isEmpty) return;
    final marketplaces = _activeAutoSearchMarketplaces();
    final targets = _buildRetryTargets(
      _lastAggregatedIngredientsForRetry,
      marketplaces: marketplaces,
    );
    if (targets.isEmpty) return;
    _searchProductsForIngredients(
      _lastAggregatedIngredientsForRetry,
      marketplacesToFetch: marketplaces,
      targetCacheKeys: targets,
      forceRefresh: true,
    );
  }

  /// 실패 카드의 [재시도] — 누른 그 재료만, 찾을 확률을 높여 다시 검색.
  ///
  /// 기존 `_retryProductSearch` 는 missing 전체·같은 전처리 쿼리를 그대로
  /// 다시 쳐서 "또 실패"가 반복되기 쉽다. 여기서는:
  /// 1) 해당 재료의 로컬 추천/전처리 캐시를 비우고
  /// 2) 쿠팡·컬리 각각 원본명 + 재전처리명 + 축약명 후보를 함께 스트림 요청한다.
  void _retryProductSearchForIngredient(String ingredientName) {
    if (_isSearchingProducts) return;
    final ingredientData =
        _lastAggregatedIngredientsForRetry[ingredientName];
    if (ingredientData == null) return;

    final marketplaces = _activeAutoSearchMarketplaces();
    final targets = <String>{
      for (final marketplace in marketplaces)
        _recommendationCacheKey(marketplace, ingredientName),
    };
    if (targets.isEmpty) return;

    _preprocessedNameCache.remove(ingredientName);
    for (final key in targets) {
      _productRecommendationCache.remove(key);
      _missingRecommendationKeys.remove(key);
      _lastRequestedSignatureByCacheKey.remove(key);
    }

    if (kDebugMode) {
      print(
        '[CartScreen] manual retry boost for "$ingredientName" '
        'targets=${targets.length}',
      );
    }

    _searchProductsForIngredients(
      {ingredientName: ingredientData},
      marketplacesToFetch: marketplaces,
      targetCacheKeys: targets,
      forceRefresh: true,
      manualRetryBoost: true,
    );
  }

  /// 수동 재시도용 축약 쿼리 — 수식어를 떼 스크래핑/컬리 매칭 확률을 높인다.
  String? _retryAlternateIngredientName(String ingredientName) {
    var name = ingredientName.trim();
    if (name.isEmpty) return null;
    const prefixes = <String>[
      '냉동',
      '냉장',
      '생물',
      '손질',
      '다진',
      '슬라이스',
      '유기농',
      '무농약',
      '특급',
      '국내산',
      '수입산',
    ];
    for (final prefix in prefixes) {
      if (name.startsWith(prefix)) {
        final rest = name.substring(prefix.length).trim();
        if (rest.length >= 2) return rest;
      }
    }
    final parts = name
        .split(RegExp(r'[\s,/·]+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      final last = parts.last.trim();
      if (last.length >= 2 && last != name) return last;
    }
    return null;
  }

  Future<void> _confirmAndRemoveIngredientFromCart(
    String ingredientName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$ingredientName을 제거할까요?',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.45,
                        color: Color(0xFF191F28),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '장보기 목록에서 해당 재료가 제거됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: -0.35,
                        color: Color(0xFF4E5968),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 55.167,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Color(0xFFF2F4F6),
                      width: 0.667,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(false),
                        child: const Center(
                          child: Text(
                            '취소',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: Color(0xFF4E5968),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 0.667,
                      height: double.infinity,
                      color: const Color(0xFFF2F4F6),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(true),
                        child: const Center(
                          child: Text(
                            '제거',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final user = _auth.currentUser;
    if (user == null) return;
    _unmarkIngredientPurchased(ingredientName);
    setState(() {});
    try {
      await _userService.removeIngredientFromCart(user.uid, ingredientName);
    } catch (e) {
      if (!mounted) return;
      _showBottomNotification(
        SnackBar(
          content: Text('삭제 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildProductSearchFailureBanner(Brightness brightness) {
    if (!_productSearchFailed || _isSearchingProducts) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3F0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD6CC)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: Color(0xFFD9480F)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _productSearchFailureMessage.isNotEmpty
                    ? _productSearchFailureMessage
                    : '상품 검색에 실패했어요. 다시 시도해주세요.',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.getTextPrimary(brightness),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _retryProductSearch,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                '재시도',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFFF6B00),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 구매완료 사진 인증(온라인 주문확인 스크린샷).
  /// [asBottomSection]=false: 상단 배너 / true: 상품 목록 맨 아래 섹션.
  Widget _buildPurchaseVerificationBanner(
    Brightness brightness, {
    bool asBottomSection = false,
  }) {
    if (_authService.currentUser == null || _purchaseVerificationHidden) {
      return const SizedBox.shrink();
    }
    if (asBottomSection) {
      if (!_purchaseVerificationPinnedToBottom) {
        return const SizedBox.shrink();
      }
    } else if (_purchaseVerificationPinnedToBottom) {
      return const SizedBox.shrink();
    }

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFE1A8)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('🧾', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '주문확인 스크린샷 인증하고 1,500P 받기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '쿠팡·컬리 주문완료 화면 캡처만 올리면 끝',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    color: Color(0xFF9A7B3F),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _isSubmittingPurchaseVerification
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: _handlePurchaseVerificationTap,
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B00),
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    '인증하기',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
          IconButton(
            onPressed: _isSubmittingPurchaseVerification
                ? null
                : () => setState(() {
                      if (asBottomSection) {
                        _purchaseVerificationHidden = true;
                      } else {
                        _purchaseVerificationPinnedToBottom = true;
                      }
                    }),
            icon: const Icon(Icons.close, size: 16, color: Color(0xFF9A7B3F)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );

    if (asBottomSection) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '구매 인증',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1A1A1A),
                letterSpacing: -0.4,
                height: 24 / 18,
              ),
            ),
            const SizedBox(height: 10),
            card,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: card,
    );
  }

  Future<void> _handlePurchaseVerificationTap() async {
    if (_isSubmittingPurchaseVerification) return;
    final picked = await _purchaseVerifyImagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;

    setState(() => _isSubmittingPurchaseVerification = true);
    try {
      final bytes = await picked.readAsBytes();
      final result = await RewardsService.instance.submitPurchaseVerification(
        bytes,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (result == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('인증 처리에 실패했어요. 잠시 후 다시 시도해주세요.')),
        );
      } else if (result.isApproved) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('인증 완료! +${result.pointsAwarded}P 적립됐어요 🎉'),
            backgroundColor: const Color(0xFFFF6B00),
          ),
        );
        setState(() => _purchaseVerificationHidden = true);
      } else if (result.isPending) {
        messenger.showSnackBar(
          const SnackBar(content: Text('확인 중이에요. 검토 후 포인트가 지급될 수 있어요.')),
        );
        setState(() => _purchaseVerificationHidden = true);
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.reason?.isNotEmpty == true
                  ? '인증에 실패했어요: ${result.reason}'
                  : '주문확인 화면을 다시 확인해주세요.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('인증 처리 중 오류가 발생했어요.')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmittingPurchaseVerification = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _authStateSubscription = _authService.authStateChanges.listen(
      _handleAuthStateChanged,
    );
    _handleAuthStateChanged(_auth.currentUser);
    // 담기 직후(비가시) 검색 허용. 앱 재진입·기존 재료 경로는 visibility 게이트 유지.
    if (UserService.pendingCartAddSearch) {
      _allowSearchAfterCartAdd = true;
    }
    _cartItemAddedSubscription = UserService.cartItemAddedStream.listen((_) {
      if (!mounted) return;
      setState(() {
        _allowSearchAfterCartAdd = true;
      });
      _maybeShowCartAddTip();
    });
    if (UserService.pendingCartAddTip) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeShowCartAddTip();
      });
    }
    if (UserService.peekOnboardingProfile() == null) {
      unawaited(_applyOnboardingWhenProfileReady());
    }
  }

  Future<void> _applyOnboardingWhenProfileReady() async {
    final uid = _auth.currentUser?.uid;
    final profile = await _userService.loadOnboardingProfile();
    if (!mounted || profile == null) return;
    if (_auth.currentUser?.uid != uid) return;
    if (!hasProductPersonalization(profile)) return;
    if (_productRecommendationCache.isEmpty) return;
    setState(() {
      for (final key in _productRecommendationCache.keys.toList()) {
        final current = _productRecommendationCache[key];
        if (current == null) continue;
        _productRecommendationCache[key] = applyOnboardingToRecommendation(
          current,
          profile: profile,
          isCoupang:
              _marketplaceFromCacheKey(key) == ShoppingMarketplace.coupang,
        );
      }
    });
  }

  String _cartHasHeldRecipeKey(String uid) =>
      '$_cartHasHeldRecipeKeyPrefix$uid';

  String _defaultCartRecipeDismissedKey(String uid) =>
      '$_defaultCartRecipeDismissedKeyPrefix$uid';

  Future<void> _loadCartUsageStateForUser(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasUsedCart = prefs.getBool(_cartHasHeldRecipeKey(uid)) ?? false;
      final defaultDismissed =
          prefs.getBool(_defaultCartRecipeDismissedKey(uid)) ?? false;
      if (!mounted || _cachedCartUid != uid) return;
      setState(() {
        _hasUsedCartWithRecipeBefore = hasUsedCart;
        _defaultCartRecipeDismissed = defaultDismissed;
      });
    } catch (_) {
      // If local storage is unavailable, keep the first-use guide visible.
    }
  }

  Future<void> _rememberCartHasHeldRecipe(String uid) async {
    if (_hasUsedCartWithRecipeBefore) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_cartHasHeldRecipeKey(uid), true);
      if (!mounted || _cachedCartUid != uid) return;
      setState(() {
        _hasUsedCartWithRecipeBefore = true;
      });
    } catch (_) {
      // Non-critical preference; cart functionality should continue normally.
    }
  }

  Future<void> _rememberDefaultCartRecipeDismissed() async {
    final uid = _cachedCartUid ?? _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_defaultCartRecipeDismissedKey(uid), true);
    } catch (_) {
      // Non-critical preference; the current session still hides it.
    }
    if (!mounted || _cachedCartUid != uid) return;
    setState(() {
      _defaultCartRecipeDismissed = true;
    });
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    _cartItemAddedSubscription?.cancel();
    _authNullDebounceTimer?.cancel();
    _thumbnailOneShotRefreshTimer?.cancel();
    if (_recommendationCacheSaveTimer?.isActive ?? false) {
      _recommendationCacheSaveTimer?.cancel();
      _recommendationCacheSaveTimer = null;
      unawaited(_saveRecommendationCacheNow());
    } else {
      _recommendationCacheSaveTimer?.cancel();
      _recommendationCacheSaveTimer = null;
    }
    _cartScrollController.dispose();
    super.dispose();
  }

  Future<void> _handleAuthStateChanged(User? user) async {
    _authNullDebounceTimer?.cancel();

    if (user == null) {
      _authNullDebounceTimer = Timer(const Duration(milliseconds: 800), () {
        unawaited(_applySignedOutAuthState());
      });
      return;
    }

    await _applySignedInAuthState(user);
  }

  Future<void> _applySignedOutAuthState() async {
    if (!mounted) return;
    if (_auth.currentUser != null) return;

    final previousUid = _cachedCartUid;
    if (previousUid != null) {
      await _localStorageService.clearCartCache(previousUid);
      await _localStorageService.clearRecommendationCache(previousUid);
    }
    if (!mounted) return;
    setState(() {
      _cachedCartUid = null;
      _cachedCartItems = null;
      _cachedCartSignature = '';
      _hasUsedCartWithRecipeBefore = false;
      _defaultCartRecipeDismissed = false;
      _isEnsuringDefaultCartRecipe = false;
      _lastThumbnailLookupHash = '';
      _thumbnailOneShotRefreshHash = '';
      _productRecommendationCache.clear();
      _lastRequestedSignatureByCacheKey.clear();
      _missingRecommendationKeys.clear();
      _preprocessedNameCache.clear();
    });
    _thumbnailOneShotRefreshTimer?.cancel();
    _thumbnailOneShotRefreshTimer = null;
    _recommendationCacheSaveTimer?.cancel();
    _recommendationCacheSaveTimer = null;
  }

  Future<void> _applySignedInAuthState(User user) async {
    final previousUid = _cachedCartUid;
    final nextUid = user.uid;
    if (previousUid == nextUid) {
      return;
    }

    if (previousUid != null && previousUid != user.uid) {
      await _localStorageService.clearCartCache(previousUid);
      await _localStorageService.clearRecommendationCache(previousUid);
    }

    if (!mounted) return;
    setState(() {
      _cachedCartUid = user.uid;
      _cachedCartItems = null;
      _cachedCartSignature = '';
      _hasUsedCartWithRecipeBefore = false;
      _defaultCartRecipeDismissed = false;
      _isEnsuringDefaultCartRecipe = false;
      _lastThumbnailLookupHash = '';
      _thumbnailOneShotRefreshHash = '';
    });
    _thumbnailOneShotRefreshTimer?.cancel();
    _thumbnailOneShotRefreshTimer = null;
    await Future.wait<void>([
      _loadCartUsageStateForUser(user.uid),
      _loadCartCacheForUser(user.uid),
      _loadRecommendationCacheForUser(user.uid),
    ]);
  }

  Future<void> _loadCartCacheForUser(String uid) async {
    final payload = await _localStorageService.loadCartCache(uid);
    if (!mounted || _cachedCartUid != uid || payload == null) return;
    final cachedAtRaw = payload['cachedAt']?.toString();
    final cachedAt = cachedAtRaw != null
        ? DateTime.tryParse(cachedAtRaw)
        : null;
    if (cachedAt == null) return;
    if (DateTime.now().difference(cachedAt) > _cartCacheTtl) return;

    final rawItems = payload['cartItems'];
    if (rawItems is! List) return;
    final cartItems = List<dynamic>.from(rawItems);
    final signature = _cartItemsSignature(cartItems);
    if (cartItems.isNotEmpty) {
      unawaited(_rememberCartHasHeldRecipe(uid));
    }

    setState(() {
      _cachedCartItems = cartItems;
      _cachedCartSignature = signature;
    });
  }

  Future<void> _loadRecommendationCacheForUser(String uid) async {
    final entries = await _localStorageService.loadRecommendationCache(uid);
    if (!mounted ||
        _cachedCartUid != uid ||
        entries == null ||
        entries.isEmpty) {
      return;
    }
    final restored = <String, ProductRecommendation>{};
    final restoredSignatures = <String, String>{};
    entries.forEach((cacheKey, json) {
      try {
        final rec = ProductRecommendation.fromJson(json);
        restored[cacheKey] = rec;
        // 실패(bestMatch 없음) 서명까지 복원하면 삭제 후 재담기 때도
        // changedTargets=0 이 되어 재검색이 영구히 스킵된다.
        if (rec.bestMatch != null) {
          restoredSignatures[cacheKey] =
              '${rec.neededQty ?? ''}:${rec.neededUnit ?? ''}';
        }
      } catch (_) {
        // Skip corrupt entries; live fetch will refill them.
      }
    });
    if (restored.isEmpty) return;
    setState(() {
      restored.forEach((key, value) {
        _productRecommendationCache.putIfAbsent(
          key,
          () => _applyRecommendedPick(
            value,
            marketplace: _marketplaceFromCacheKey(key),
          ),
        );
      });
      restoredSignatures.forEach((key, value) {
        _lastRequestedSignatureByCacheKey.putIfAbsent(key, () => value);
      });
    });
  }

  void _scheduleRecommendationCacheSave() {
    _recommendationCacheSaveTimer?.cancel();
    _recommendationCacheSaveTimer = Timer(_recommendationCacheSaveDebounce, () {
      if (!mounted) return;
      unawaited(_saveRecommendationCacheNow());
    });
  }

  Future<void> _saveRecommendationCacheNow() async {
    final uid = _cachedCartUid;
    if (uid == null) return;
    final snapshot = <String, Map<String, dynamic>>{};
    _productRecommendationCache.forEach((key, value) {
      try {
        snapshot[key] = value.toJson();
      } catch (_) {}
    });
    if (snapshot.isEmpty) {
      await _localStorageService.clearRecommendationCache(uid);
      return;
    }
    await _localStorageService.saveRecommendationCache(
      uid: uid,
      cachedAt: DateTime.now(),
      entries: snapshot,
    );
  }

  Future<void> _saveCartCache(String uid, List<dynamic> cartItems) async {
    final signature = _cartItemsSignature(cartItems);
    if (_cachedCartUid == uid && _cachedCartSignature == signature) {
      return;
    }
    try {
      await _localStorageService.saveCartCache(
        uid: uid,
        cachedAt: DateTime.now(),
        cartItems: List<dynamic>.from(cartItems),
      );
    } catch (_) {
      return;
    }
    if (!mounted || _cachedCartUid != uid) return;
    setState(() {
      _cachedCartItems = List<dynamic>.from(cartItems);
      _cachedCartSignature = signature;
    });
  }

  String _cartItemsSignature(List<dynamic> cartItems) {
    try {
      return jsonEncode(cartItems);
    } catch (_) {
      return cartItems.toString();
    }
  }

  void _trackInProgressSessionIfThresholdMet(
    List<dynamic> cartItems,
    Map<String, Map<String, dynamic>> aggregatedIngredients,
  ) {
    final user = _auth.currentUser;
    if (user == null) return;
    if (cartItems.isEmpty || aggregatedIngredients.isEmpty) return;

    final providedIngredientKeys = aggregatedIngredients.keys.where((name) {
      final recommendation = _getCachedRecommendation(name);
      return recommendation?.bestMatch != null;
    }).toList();
    final int totalProvidedIngredients = providedIngredientKeys.length;
    if (totalProvidedIngredients <= 0) return;

    final int purchasedProvidedCount = providedIngredientKeys
        .where((k) => _purchasedIngredientKeys.contains(k))
        .length;
    final String cartSignature = _cartItemsSignature(cartItems);
    unawaited(
      _analyticsService.trackInProgressPurchaseSessionForUser(
        user.uid,
        cartSignature: cartSignature,
        purchasedCount: purchasedProvidedCount,
        totalCount: totalProvidedIngredients,
        thresholdRatio: 0.25,
      ),
    );
  }

  Future<void> _clearCurrentUserCartCache() async {
    final uid = _cachedCartUid;
    if (uid == null) return;
    await _localStorageService.clearCartCache(uid);
    if (!mounted || _cachedCartUid != uid) return;
    setState(() {
      _cachedCartItems = null;
      _cachedCartSignature = '';
    });
  }

  Widget _buildCachedCartHint(Brightness brightness) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.getBackgroundSecondary(brightness),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '임시 저장된 장바구니를 먼저 표시하고 있어요',
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.getTextSecondary(brightness),
        ),
      ),
    );
  }

  Widget _buildCachedCartContent(
    List<dynamic> cartItems,
    Brightness brightness,
  ) {
    final visibleCartItems = _visibleCartItems(cartItems);
    if (visibleCartItems.isEmpty) {
      return _buildDefaultRemovedEmptyState(brightness);
    }
    return Column(
      children: [
        _buildCachedCartHint(brightness),
        Expanded(child: _buildCartContent(visibleCartItems, brightness)),
      ],
    );
  }

  bool _containsDefaultCartRecipe(List<dynamic> cartItems) {
    return cartItems.any((item) {
      if (item is! Map) return false;
      return item['recipeId']?.toString() == _defaultCartRecipeId;
    });
  }

  /// Hide legacy seeded preview recipe (삼겹살마늘찜) — no longer auto-added.
  List<dynamic> _visibleCartItems(List<dynamic> cartItems) {
    return cartItems.where((item) {
      if (item is! Map) return true;
      return item['recipeId']?.toString() != _defaultCartRecipeId;
    }).toList();
  }

  Widget _buildEmptyCartContentForUser(String uid, Brightness brightness) {
    return _buildDefaultRemovedEmptyState(brightness);
  }

  Future<void> _ensureDefaultCartRecipeStored(String uid) async {
    // Default preview seeding removed — keep as no-op for call-site safety.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check if cart screen is actually visible (not just built by IndexedStack)
    // IndexedStack builds all screens but only shows the current one (index 2 for cart)
    if (kDebugMode) {
      print('[CartScreen] didChangeDependencies() called');
    }

    // Check visibility immediately and in post-frame callback for reliability
    _checkAndUpdateVisibility();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _checkAndUpdateVisibility();
      }
    });
  }

  void _checkAndUpdateVisibility() {
    final mainNavigator = MainNavigator.of(context);
    if (mainNavigator != null) {
      final isCartVisible = mainNavigator.currentIndex == 2;
      if (kDebugMode) {
        print(
          '[CartScreen] _checkAndUpdateVisibility: MainNavigator.currentIndex = ${mainNavigator.currentIndex}, isCartVisible = $isCartVisible, _hasBeenVisible = $_hasBeenVisible',
        );
      }
      if (isCartVisible) {
        if (!_isCartVisibleNow || !_hasBeenVisible) {
        if (kDebugMode) {
          print(
              '[CartScreen] _checkAndUpdateVisibility: cart tab visible',
          );
        }
        setState(() {
          _hasBeenVisible = true;
          _isCartVisibleNow = true;
        });
        }
        _maybeShowCartAddTip();
      } else if (_isCartVisibleNow) {
        setState(() {
          _isCartVisibleNow = false;
        });
      }
    } else {
      if (kDebugMode) {
        print(
          '[CartScreen] _checkAndUpdateVisibility: MainNavigator.of(context) returned null',
        );
      }
    }
  }

  List<ShoppingMarketplace> _activeAutoSearchMarketplaces() {
    return const [ShoppingMarketplace.coupang, ShoppingMarketplace.marketKurly];
  }

  String _ingredientSearchSignature(Map<String, dynamic> ingredientData) {
    final totalQty = (ingredientData['totalQty'] as num?)?.toDouble();
    final unit = ingredientData['unit']?.toString() ?? '';
    return '${totalQty ?? ''}:$unit';
  }

  Set<String> _computeChangedTargets(
    Map<String, Map<String, dynamic>> ingredients, {
    required List<ShoppingMarketplace> marketplaces,
  }) {
    final targets = <String>{};
    for (final marketplace in marketplaces) {
      for (final entry in ingredients.entries) {
        final ingredientName = entry.key;
        final cacheKey = _recommendationCacheKey(marketplace, ingredientName);
        final signature = _ingredientSearchSignature(entry.value);
        // Auto-search only when qty/unit changed (or never fetched). Missing
        // bestMatch is retried only when the user taps 재시도 — not every
        // rebuild, or failed ingredients hammer recommend_products_batch.
        if (_lastRequestedSignatureByCacheKey[cacheKey] != signature) {
          targets.add(cacheKey);
        }
      }
    }
    return targets;
  }

  Set<String> _buildRetryTargets(
    Map<String, Map<String, dynamic>> ingredients, {
    required List<ShoppingMarketplace> marketplaces,
  }) {
    final targets = <String>{};
    for (final marketplace in marketplaces) {
      for (final entry in ingredients.entries) {
        final ingredientName = entry.key;
        final cacheKey = _recommendationCacheKey(marketplace, ingredientName);
        final recommendation = _productRecommendationCache[cacheKey];
        final hasBestMatch = recommendation?.bestMatch != null;
        if (!hasBestMatch || _missingRecommendationKeys.contains(cacheKey)) {
          targets.add(cacheKey);
        }
      }
    }
    return targets;
  }

  void _pruneSearchTracking(
    Map<String, Map<String, dynamic>> ingredients, {
    required List<ShoppingMarketplace> marketplaces,
  }) {
    final validKeys = <String>{};
    for (final marketplace in marketplaces) {
      for (final ingredientName in ingredients.keys) {
        validKeys.add(_recommendationCacheKey(marketplace, ingredientName));
      }
    }
    _lastRequestedSignatureByCacheKey.removeWhere(
      (key, _) => !validKeys.contains(key),
    );
    _missingRecommendationKeys.removeWhere((key) => !validKeys.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return DefaultTextStyle.merge(
      style: const TextStyle(fontFamily: 'Pretendard'),
      child: Scaffold(
        backgroundColor: AppColors.getBackground(brightness),
        // 하단 inset은 MainNavigator bottom nav가 소유한다.
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              AppHeader(showCalendarIcon: true, showNotificationIcon: true),
              // [임시 비활성] 구매인증(포인트) 상단 배너
              // _buildPurchaseVerificationBanner(brightness),
              Expanded(
                child: Container(
                  color: AppColors.getBackground(brightness),
                  child: StreamBuilder<User?>(
                    stream: _authService.authStateChanges,
                    initialData: _authService.currentUser,
                    builder: (context, authSnapshot) {
                      final user = authSnapshot.data;

                      if (user == null &&
                          (authSnapshot.connectionState ==
                                  ConnectionState.waiting ||
                              shouldIgnoreTransientAuthNull())) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }

                      if (user == null) {
                        return _buildLoginPrompt(brightness);
                      }

                      final hasCachedCart =
                          _cachedCartUid == user.uid &&
                          _cachedCartItems != null;
                      final cachedCartItems = hasCachedCart
                          ? List<dynamic>.from(_cachedCartItems!)
                          : const <dynamic>[];

                      return _CartDocumentStream(
                        user: user,
                        userService: _userService,
                        brightness: brightness,
                        buildContent: (context, snapshot) {
                          if (snapshot.hasError && hasCachedCart) {
                            return _buildCachedCartContent(
                              cachedCartItems,
                              brightness,
                            );
                          }

                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            if (hasCachedCart) {
                              return _buildCachedCartContent(
                                cachedCartItems,
                                brightness,
                              );
                            }
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          if (!snapshot.hasData || !snapshot.data!.exists) {
                            if (hasCachedCart) {
                              return _buildCachedCartContent(
                                cachedCartItems,
                                brightness,
                              );
                            }
                            return _buildEmptyCartContentForUser(
                              user.uid,
                              brightness,
                            );
                          }

                          final userData =
                              snapshot.data!.data() as Map<String, dynamic>?;
                          final rawCartItems =
                              userData?['cartItems'] as List? ?? [];
                          // Purge legacy default preview if still in the cart.
                          if (_containsDefaultCartRecipe(rawCartItems)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              unawaited(
                                _userService.removeCartItemsByRecipeId(
                                  user.uid,
                                  _defaultCartRecipeId,
                                ),
                              );
                            });
                          }
                          final cartItems = _visibleCartItems(rawCartItems);
                          unawaited(_saveCartCache(user.uid, cartItems));

                          if (cartItems.isEmpty) {
                            return _buildEmptyCartContentForUser(
                              user.uid,
                              brightness,
                            );
                          }

                          unawaited(_rememberCartHasHeldRecipe(user.uid));
                          return _buildCartContent(cartItems, brightness);
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        // COMMENTED OUT: Floating action button moved to bottom bar
        // floatingActionButton: user != null
        //     ? FloatingActionButton.extended(
        //         onPressed: () async {
        //           const url = 'https://link.coupang.com/a/dBdJyP';
        //           final uri = Uri.parse(url);
        //           if (await canLaunchUrl(uri)) {
        //             await launchUrl(uri, mode: LaunchMode.externalApplication);
        //           } else {
        //             if (mounted) {
        //               ScaffoldMessenger.of(context).showSnackBar(
        //                 const SnackBar(
        //                   content: Text('링크를 열 수 없습니다'),
        //                   backgroundColor: Colors.red,
        //                 ),
        //               );
        //             }
        //           }
        //         },
        //         backgroundColor: AppColors.primary,
        //         icon: const Icon(Icons.shopping_bag, color: Colors.white),
        //         label: const Text(
        //           '쿠팡으로 가기',
        //           style: TextStyle(
        //             color: Colors.white,
        //             fontWeight: FontWeight.bold,
        //           ),
        //         ),
        //       )
        //     : null,
        // floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  Future<void> _showEditCartItemDialog({
    required String recipeId,
    required String recipeName,
    required List<Map<String, dynamic>> cartItems,
    required double servings,
  }) async {
    final existingIngredientNames = <String>{};
    for (final item in cartItems) {
      final ings =
          (item['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isNotEmpty) existingIngredientNames.add(name);
      }
    }

    // Fetch recipe data first
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (!mounted || parseResponse == null) return;
    final recipe = parseResponse.recipe;
    final baseServings = recipe.servings ?? 2;
    final groups = groupIngredientsByCategory(recipe.ingredients);

    // Pre-select ingredients that are already in the cart
    final preSelected = <String>{};
    for (var i = 0; i < recipe.ingredients.length; i++) {
      if (existingIngredientNames.contains(recipe.ingredients[i].item)) {
        preSelected.add(i.toString());
      }
    }

    if (!mounted) return;
    final result =
        await showModalBottomSheet<({Set<String> selected, double portionCount})?>(
          context: context,
          isScrollControlled: true,
          useSafeArea: false,
          backgroundColor: Colors.transparent,
          builder: (_) => IngredientSelectSheet(
            ingredients: recipe.ingredients,
            groups: groups,
            initialSelected: preSelected,
            initialPortionCount: servings,
            baseServings: baseServings,
            ctaLabel: '저장',
          ),
        );

    if (result == null || !mounted) return;
    final user = _auth.currentUser;
    if (user == null) return;

    final selected = result.selected;
    final portionCount = result.portionCount;
    final scaleFactor = portionCount / baseServings;

    final selectedIngredients = recipe.ingredients
        .asMap()
        .entries
        .where((e) => selected.contains(e.key.toString()))
        .map((e) {
          final ing = e.value;
          final scaledQty = ing.qty != null ? (ing.qty! * scaleFactor) : null;
          final scaledConventionalQty = (ing.qtyConventional ?? ing.qty) != null
              ? ((ing.qtyConventional ?? ing.qty)! * scaleFactor)
              : null;
          return {
            'item': ing.item,
            'qty': scaledQty != null
                ? (scaledQty == scaledQty.roundToDouble()
                      ? scaledQty.toInt().toString()
                      : scaledQty.toStringAsFixed(1))
                : '',
            'unit': ing.unit ?? '',
            'qty_conventional': scaledConventionalQty != null
                ? (scaledConventionalQty ==
                          scaledConventionalQty.roundToDouble()
                      ? scaledConventionalQty.toInt().toString()
                      : scaledConventionalQty.toStringAsFixed(1))
                : '',
            'unit_conventional': (ing.unitConventional ?? ing.unit) ?? '',
            'category': ing.category,
          };
        })
        .toList();

    final newCartItem = {
      'recipeId': recipeId,
      'recipeName': recipe.name ?? recipeName,
      'servings': portionCount,
      'ingredients': selectedIngredients,
      'thumbnailUrl': _recipeThumbnailById[recipeId] ?? '',
      'platform': _recipePlatformById[recipeId] ?? '',
      'sourceUrl': _recipeSourceUrlById[recipeId] ?? '',
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    };

    await _userService.replaceCartItemsByRecipeId(
      user.uid,
      recipeId,
      newCartItem,
    );
    _showBottomNotification(
      const SnackBar(
        content: Text('장바구니가 수정되었습니다'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildLoginPrompt(Brightness brightness) {
    return Stack(
      children: [
        const GuestLockedPreviewBackdrop(asset: 'assets/cart_preview.png'),
        GuestLockedPromptAlign(
          child: Container(
            width: 272,
            padding: const EdgeInsets.all(27),
            decoration: ShapeDecoration(
              color: Colors.white.withValues(alpha: 0.80),
              shape: RoundedRectangleBorder(
                side: const BorderSide(width: 0.57, color: Colors.white),
                borderRadius: BorderRadius.circular(27),
              ),
              shadows: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 51,
                  offset: Offset(0, 20),
                  spreadRadius: -10,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: ShapeDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment(0.00, 1.00),
                      end: Alignment(1.00, 0.00),
                      colors: [Colors.white, Color(0xFFF9FAFB)],
                    ),
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(width: 0.57, color: Colors.white),
                      borderRadius: BorderRadius.circular(22369600),
                    ),
                    shadows: const [
                      BoxShadow(
                        color: Color(0x0C000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/icons/nav_cart.png',
                      width: 24,
                      height: 24,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '스마트한 장보기를 시작하세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 17,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                    letterSpacing: -0.42,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '레시피 재료를 한번에 비교하고\n최저가로 장바구니를 채워보세요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 11,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w500,
                    height: 1.60,
                    letterSpacing: -0.27,
                  ),
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/login'),
                  child: Container(
                    width: double.infinity,
                    height: 46,
                    decoration: ShapeDecoration(
                      color: const Color(0xFF111111),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      shadows: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 17,
                          offset: Offset(0, 7),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '3초 만에 로그인하기',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                        letterSpacing: -0.32,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Switch to the community tab and immediately surface the 인기 레시피 (TrendingAllPage).
  /// CategoryExploreScreen already pre-loads `_hotNewRecipes` on init, so the page
  /// opens with no perceptible delay.
  void _openTrendingRecipesPage() {
    mainNavigatorKey.currentState?.navigateToCommunityTrendingPage();
  }

  Widget _buildDefaultRemovedEmptyState(Brightness brightness) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEmptySectionHeader(title: '구매할 레시피'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
            child: _buildEmptySectionSlot(
              icon: Icons.restaurant_menu_rounded,
              label: '담긴 레시피가 없어요',
              guide: '레시피를 담으면 재료가 자동으로 모여요',
              brightness: brightness,
              onTap: _openTrendingRecipesPage,
            ),
          ),
          _buildEmptySectionHeader(title: '장보기 목록'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              children: [
                _buildEmptySectionSlot(
                  icon: Icons.shopping_cart_outlined,
                  label: '정리된 재료가 없어요',
                  guide: '레시피를 담거나, 아래에서 재료만 추가해보세요',
                  brightness: brightness,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: _showAddManualIngredientFlow,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text(
                      '재료 직접 추가',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.25,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF191F28),
                      side: const BorderSide(color: Color(0xFFE6E9EF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySectionHeader({
    required String title,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 12, bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A1A),
              letterSpacing: -0.4,
              height: 24 / 19,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: _cartAccentOrange,
              borderRadius: BorderRadius.circular(100),
            ),
            alignment: Alignment.center,
            child: const Text(
              '0',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                height: 16.5 / 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySectionSlot({
    required IconData icon,
    required String label,
    required Brightness brightness,
    String? guide,
    VoidCallback? onTap,
  }) {
    final tertiary = AppColors.getTextTertiary(brightness);
    final card = Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: guide == null ? 22 : 20,
        horizontal: 20,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.05),
          width: 0.67,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 24,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 22,
            color: tertiary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tertiary,
              letterSpacing: -0.25,
            ),
          ),
          if (guide != null) ...[
            const SizedBox(height: 4),
            Text(
              guide,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: tertiary.withValues(alpha: 0.78),
                letterSpacing: -0.2,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: card,
      ),
    );
  }

  List<Map<String, dynamic>> _defaultCartPreviewItems() {
    return [
      {
        'recipeId': _defaultCartRecipeId,
        'recipeName': '삼겹살마늘찜',
        'servings': 2,
        'thumbnailUrl':
            'https://firebasestorage.googleapis.com/v0/b/yorigo-f7408.firebasestorage.app/o/recipe_thumbnails%2Fcropped%2Fb0tuRieQkhPVsHK1kvzc_cropped.jpg?alt=media&token=6d09f644-b43c-41ed-8ef8-3df646442590',
        'platform': 'instagram',
        'sourceUrl': 'https://www.instagram.com/reel/DXMegnSk2QQ/',
        'ingredients': [
          {
            'item': '삼겹살',
            'qty': 600.0,
            'unit': 'g',
            'qty_conventional': 600.0,
            'unit_conventional': 'g',
            'category': '육류',
          },
          {
            'item': '다진 마늘',
            'qty': 3.0,
            'unit': '큰술',
            'qty_conventional': 3.0,
            'unit_conventional': '큰술',
            'category': '양념·소스',
          },
          {
            'item': '대파',
            'qty': 1.0,
            'unit': '대',
            'qty_conventional': 1.0,
            'unit_conventional': '대',
            'category': '채소',
          },
        ],
      },
    ];
  }

  Widget _buildCartContent(
    List<dynamic> cartItems,
    Brightness brightness, {
    bool isDefaultPreview = false,
  }) {
    // Store current cart items for async operations
    _currentCartItems = cartItems;

    // Group by recipe
    final Map<String, List<Map<String, dynamic>>> groupedByRecipe = {};
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final recipeId = cartItem['recipeId']?.toString() ?? 'unknown';
      if (!groupedByRecipe.containsKey(recipeId)) {
        groupedByRecipe[recipeId] = [];
      }
      groupedByRecipe[recipeId]!.add(cartItem);
    }

    // Load meal plans to get dates for recipes (only if not already loading and recipe list changed)
    final recipeIdsHash = groupedByRecipe.keys.join(',');
    if (recipeIdsHash != _lastRecipeIdsHash && !_isLoadingMealPlans) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isLoadingMealPlans) {
          _lastRecipeIdsHash = recipeIdsHash;
          _loadMealPlansForRecipes(groupedByRecipe.keys.toList());
        }
      });
    }
    final hasMissingThumb = groupedByRecipe.keys.any(
      (id) => (_recipeThumbnailById[id] ?? '').trim().isEmpty,
    );
    final shouldRefreshThumbLookup =
        recipeIdsHash != _lastThumbnailLookupHash || hasMissingThumb;
    if (shouldRefreshThumbLookup && !_isLoadingRecipeThumbnails) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isLoadingRecipeThumbnails) {
          _lastThumbnailLookupHash = recipeIdsHash;
          _loadRecipeThumbnailsForRecipes(groupedByRecipe.keys.toList());
        }
      });
    }
    if (recipeIdsHash != _thumbnailOneShotRefreshHash) {
      _thumbnailOneShotRefreshHash = recipeIdsHash;
      _thumbnailOneShotRefreshTimer?.cancel();
      _thumbnailOneShotRefreshTimer = null;
      if (groupedByRecipe.isNotEmpty) {
        final recipeIdsForOneShot = groupedByRecipe.keys.toList(
          growable: false,
        );
        _thumbnailOneShotRefreshTimer = Timer(
          _thumbnailOneShotRefreshDelay,
          () {
            if (!mounted || _isLoadingRecipeThumbnails) return;
            _loadRecipeThumbnailsForRecipes(recipeIdsForOneShot);
          },
        );
      }
    }

    // Aggregate ingredients across all recipes
    final aggregatedIngredients = _aggregateIngredients(cartItems);
    _lastAggregatedIngredientsForRetry = {
      for (final entry in aggregatedIngredients.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    };
    _cartMajorityCheckedFired = false;
    final marketplaces = _activeAutoSearchMarketplaces();
    _pruneSearchTracking(aggregatedIngredients, marketplaces: marketplaces);

    // Meal-plan dates + [scheduledDate] on cart rows (shown even when past the home calendar window).
    final carouselRecipeDates = _effectiveRecipeDatesForCart(cartItems);
    final cartRecipeThumbnails = _thumbnailMapFromCartItems(cartItems);
    final cartRecipePlatforms = _platformMapFromCartItems(cartItems);
    final cartRecipeSourceUrls = _sourceUrlMapFromCartItems(cartItems);

    // Keep purchased set in sync with current cart (remove keys for ingredients no longer in cart)
    for (final purchasedKeys in _purchasedIngredientKeysByMarketplace.values) {
      purchasedKeys.removeWhere((k) => !aggregatedIngredients.containsKey(k));
    }
    _purchasedMarketplaceByIngredient.removeWhere(
      (ingredientName, _) => !aggregatedIngredients.containsKey(ingredientName),
    );

    // Track visibility for UI shimmer purposes.
    if (!_hasBeenVisible) {
      final mainNavigator = MainNavigator.of(context);
      if (mainNavigator != null && mainNavigator.currentIndex == 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_hasBeenVisible) {
            setState(() {
              _hasBeenVisible = true;
              _isCartVisibleNow = true;
            });
          }
        });
      }
    }

    // Auto-search: only start loading when the cart tab is actually visible.
    final hasIngredients = aggregatedIngredients.isNotEmpty;
    final notSearching = !_isSearchingProducts;
    final changedTargets = _computeChangedTargets(
      aggregatedIngredients,
      marketplaces: marketplaces,
    );
    final shouldSearch = changedTargets.isNotEmpty;

    final allowSearchNow =
        _isCartVisibleNow ||
        _allowSearchAfterCartAdd ||
        UserService.pendingCartAddSearch;

    if (kDebugMode) {
      print('[CartScreen] Checking search conditions:');
      print(
        '[CartScreen]   - aggregatedIngredients.isNotEmpty: $hasIngredients',
      );
      print(
        '[CartScreen]   - Ingredients count: ${aggregatedIngredients.length}',
      );
      print('[CartScreen]   - _isSearchingProducts: $_isSearchingProducts');
      print('[CartScreen]   - changedTargets: ${changedTargets.length}');
      print('[CartScreen]   - _isCartVisibleNow: $_isCartVisibleNow');
      print(
        '[CartScreen]   - allowSearchAfterCartAdd: $_allowSearchAfterCartAdd',
      );
    }

    if (hasIngredients && notSearching && shouldSearch && allowSearchNow) {
      if (kDebugMode) {
        print(
          '[CartScreen] Changed targets detected. Search will run for changed items.',
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isSearchingProducts) {
          if (kDebugMode) {
            print('[CartScreen] Executing _searchProductsForIngredients()');
          }
          // 담기 신호는 검색 시작 시 소모 (앱 재진입 자동검색엔 영향 없음).
          _allowSearchAfterCartAdd = false;
          UserService.pendingCartAddSearch = false;
          _searchProductsForIngredients(
            aggregatedIngredients,
            marketplacesToFetch: marketplaces,
            targetCacheKeys: changedTargets,
          );
        }
      });
    } else if (hasIngredients &&
        notSearching &&
        !shouldSearch &&
        !_hasCompletedInitialSearch &&
        _isCartVisibleNow) {
      // Already attempted (incl. empty bestMatch) — stop shimmer without re-fetch.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasCompletedInitialSearch && !_isSearchingProducts) {
          setState(() => _hasCompletedInitialSearch = true);
        }
      });
    }

    return Column(
      children: [
        // Everything scrolls together (header + carousel + sections)
        Expanded(
          child: SingleChildScrollView(
            controller: _cartScrollController,
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Match HomeScreen header-line spacing (12px) for title alignment.
                  padding: const EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: 12,
                    bottom: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          children: [
                            const Text(
                              '구매할 레시피',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 19,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF1A1A1A),
                                letterSpacing: -0.4,
                                height: 24 / 19,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              height: 20,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _cartAccentOrange,
                                borderRadius: BorderRadius.circular(100),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${groupedByRecipe.length}',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  height: 16.5 / 11,
                                ),
                              ),
                            ),
                          ],
                      ),
                    ],
                  ),
                ),
                // Recipe carousel (Figma 117:33) — always same height (max size as with 4+ recipes)
                // Thumbnails: saved recipes (typical cart case) + user-created recipes not only in saved list.
                StreamBuilder<SavedRecipesResult>(
                  stream: _recipeService.getSavedRecipes(),
                  builder: (context, snapshotSaved) {
                    return StreamBuilder<SavedRecipesResult>(
                      stream: _cartUserRecipesStream,
                      builder: (context, snapshotUser) {
                        final recipeIdToThumbnail = _mergeRecipeThumbnailMaps(
                          snapshotSaved.data?.recipes ?? const [],
                          snapshotUser.data?.recipes ?? const [],
                        );
                        final mergedRecipeIdToThumbnail = <String, String>{
                          ...cartRecipeThumbnails,
                          ...recipeIdToThumbnail,
                        };
                        final recipeIdToPlatform = _mergeRecipePlatformMaps(
                          snapshotSaved.data?.recipes ?? const [],
                          snapshotUser.data?.recipes ?? const [],
                        );
                        final recipeIdToSourceUrl = _mergeRecipeSourceUrlMaps(
                          snapshotSaved.data?.recipes ?? const [],
                          snapshotUser.data?.recipes ?? const [],
                        );
                        final mergedRecipeIdToPlatform = <String, String>{
                          ...recipeIdToPlatform,
                          ...cartRecipePlatforms,
                        };
                        final mergedRecipeIdToSourceUrl = <String, String>{
                          ...recipeIdToSourceUrl,
                          ...cartRecipeSourceUrls,
                        };
                        // Keep state in sync so 장보기 cards and quantity popup use the same URLs as 담은 레시피.
                        if (!mapEquals(
                              _recipeThumbnailById,
                              mergedRecipeIdToThumbnail,
                            ) ||
                            !mapEquals(
                              _recipePlatformById,
                              mergedRecipeIdToPlatform,
                            ) ||
                            !mapEquals(
                              _recipeSourceUrlById,
                              mergedRecipeIdToSourceUrl,
                            )) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              setState(() {
                                _recipeThumbnailById =
                                    mergedRecipeIdToThumbnail;
                                _recipePlatformById = mergedRecipeIdToPlatform;
                                _recipeSourceUrlById =
                                    mergedRecipeIdToSourceUrl;
                              });
                            }
                          });
                        }
                        return _buildFigmaRecipeCarousel(
                          groupedByRecipe,
                          mergedRecipeIdToThumbnail,
                          mergedRecipeIdToPlatform,
                          mergedRecipeIdToSourceUrl,
                          carouselRecipeDates,
                          brightness,
                          isDefaultPreview: isDefaultPreview,
                        );
                      },
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: 16,
                    bottom: 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          children: [
                            const Text(
                              '장보기 목록',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                              fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF1A1A1A),
                              letterSpacing: -0.45,
                              height: 24 / 20,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                            height: 22,
                              padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              ),
                              decoration: BoxDecoration(
                                color: _cartAccentOrange,
                                borderRadius: BorderRadius.circular(100),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${aggregatedIngredients.length}',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  height: 16.5 / 11,
                                ),
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _showAddManualIngredientFlow,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                height: 32,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF2F4F6),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(0xFFE6E9EF),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.add_rounded,
                                      size: 16,
                                      color: Color(0xFF191F28),
                                    ),
                                    SizedBox(width: 2),
                                    Text(
                                      '재료 추가',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF191F28),
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Pull the selector up by 5px to absorb the new 6px
                      // top padding inside the scroller (keeps the gap to
                      // the "장보기 목록" title visually unchanged from before
                      // the shadow fix).
                      Transform.translate(
                        offset: const Offset(0, -5),
                        child: _buildMarketplacePillSelector(),
                      ),
                      if (!_affiliateDisclosureDismissed)
                        Transform.translate(
                          offset: const Offset(0, -5),
                          child: _buildAffiliateDisclosurePill(brightness),
                        ),
                      // Was 12; shrunk by the same 6px the selector added at
                      // the bottom for shadow breathing room.
                      const SizedBox(height: 6),
                        ],
                      ),
                    ),
                _buildMarketplacePageView(
                  cartItems: cartItems,
                  aggregatedIngredients: aggregatedIngredients,
                  brightness: brightness,
                  isDefaultPreview: isDefaultPreview,
                ),

                // [임시 비활성] 구매인증(포인트) 하단 섹션
                // if (!isDefaultPreview)
                //   _buildPurchaseVerificationBanner(
                //     brightness,
                //     asBottomSection: true,
                //   ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),

        if (!isDefaultPreview)
        // Bottom bar (stays when scrolling): total price, per serving, completion ratio
        _buildTotalPriceBar(
          cartItems,
          aggregatedIngredients,
          brightness,
          onPurchaseComplete: _isPurchaseCompleting
              ? null
              : () => _onPurchaseComplete(cartItems, aggregatedIngredients),
        ),
      ],
    );
  }

  /// When user taps 구매 완료: store undo, then save and navigate.
  Future<void> _onPurchaseComplete(
    List<dynamic> cartItems,
    Map<String, Map<String, dynamic>> aggregatedIngredients,
  ) async {
    if (_isPurchaseCompleting) return;
    final user = _auth.currentUser;
    if (kDebugMode) {
      print(
        '[CartScreen] _onPurchaseComplete start '
        'uid=${user?.uid} purchased=${_purchasedIngredientKeys.length} '
        'ingredients=${aggregatedIngredients.length}',
      );
    }
    if (user == null) return;

    setState(() => _isPurchaseCompleting = true);

    unawaited(
      _analyticsService.trackPurchaseButtonClicked(
        ingredientCount: _purchasedIngredientKeys.length,
        source: 'cart_complete',
      ),
    );
    unawaited(_analyticsService.trackPurchaseButtonClickForUser(user.uid));

    final isDefaultCartRecipePurchase = cartItems.any((item) {
      if (item is! Map) return false;
      return item['recipeId']?.toString() == _defaultCartRecipeId;
    });

    // 1) Store undo data so "구매 완료 취소" can restore fridge + cart
    final Map<String, dynamic>? previousFridge;
    try {
      previousFridge = await _userService.getFridgeData(user.uid);
    } catch (e) {
      if (mounted) {
        setState(() => _isPurchaseCompleting = false);
        _showBottomNotification(
          SnackBar(
            content: Text('냉장고 정보를 불러오지 못했어요: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    widget.onStoreUndoData?.call(previousFridge, List<dynamic>.from(cartItems));
    final purchaseBatchId =
        'cart_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(999999)}';

    // New ingredients from this purchase.
    // Persist the same "담은양" basis as cart cards so fridge 구매 matches cart.
    final newIngredients = <Map<String, dynamic>>[];
    final purchasedIngredientEvents = <Map<String, dynamic>>[];
    int sessionTotalExpenditure = 0;
    int sessionCoupangExpenditure = 0;
    int sessionKurlyExpenditure = 0;
    int sessionItemsBoughtCount = 0;
    for (final name in aggregatedIngredients.keys) {
      final data = aggregatedIngredients[name]!;
      final purchasedMarketplace =
          _purchasedMarketplaceByIngredient[name] ?? _selectedMarketplace;
      final recommendationForGate =
          _getCachedRecommendationByMarketplace(name, purchasedMarketplace) ??
          _getCachedRecommendation(name);
      final bool isMissingProduct = recommendationForGate?.bestMatch == null;
      // 추천 실패 재료는 구매확인을 할 수 없어 체크에서 빠진다.
      // 그대로 건너뛰면 장바구니만 비워지고 냉장고에도 안 담긴다.
      if (!_purchasedIngredientKeys.contains(name) && !isMissingProduct) {
        continue;
      }
      final needed = (data['totalQty'] as num?)?.toDouble() ?? 0.0;
      final unit = data['unit']?.toString() ?? '개';
      final recommendation = recommendationForGate;
      final bestMatch = recommendation?.bestMatch;
      final productImageUrl = bestMatch?.productImage ?? '';
      final productName = bestMatch?.productName ?? '';
      final productPrice = bestMatch?.productPrice ?? 0;

      if (productPrice > 0) {
        sessionTotalExpenditure += productPrice;
        if (purchasedMarketplace == ShoppingMarketplace.coupang) {
          sessionCoupangExpenditure += productPrice;
        } else if (purchasedMarketplace == ShoppingMarketplace.marketKurly) {
          sessionKurlyExpenditure += productPrice;
        }
      }
      sessionItemsBoughtCount += 1;
      final String marketplaceForAnalytics;
      if (purchasedMarketplace == ShoppingMarketplace.coupang) {
        marketplaceForAnalytics = 'coupang';
      } else if (purchasedMarketplace == ShoppingMarketplace.marketKurly) {
        marketplaceForAnalytics = 'kurly';
      } else {
        marketplaceForAnalytics = purchasedMarketplace.name;
      }
      purchasedIngredientEvents.add({
        'ingredientName': name,
        'category': data['category']?.toString(),
        'marketplace': marketplaceForAnalytics,
        'price': productPrice,
        'recipeId': _analyticsRecipeIdForIngredient(name),
      });

      // Derive the "담은양" from the product (same logic as the cart card display).
      final pkgParsed = bestMatch != null
          ? IngredientUnitConverter.parseProductAmount(
              productName: bestMatch.productName,
              packageSize: bestMatch.packageSize,
              packageUnit: bestMatch.packageUnit,
            )
          : null;
      double boughtQty;
      String boughtUnit;
      if (pkgParsed != null &&
          pkgParsed.rawAmount != null &&
          pkgParsed.rawAmount! > 0) {
        boughtQty = pkgParsed.rawAmount!;
        boughtUnit = pkgParsed.rawUnit ?? unit;
      } else {
        // No parseable product size — store the needed qty as-is.
        boughtQty = needed;
        boughtUnit = unit;
      }

      final shelfLifeService = IngredientShelfLifeService.instance;
      final shelfInfo = shelfLifeService.lookup(name);
      final now = DateTime.now();
      final purchasedAtStr = now.toIso8601String();

      newIngredients.add({
        'name': name,
        'productName': productName,
        'totalQty': boughtQty,
        'unit': boughtUnit,
        if (bestMatch?.packageSize != null)
          'packageSize': bestMatch!.packageSize,
        if (bestMatch?.packageUnit?.trim().isNotEmpty == true)
          'packageUnit': bestMatch!.packageUnit,
        'marketplace': purchasedMarketplace.name,
        'source': 'cart',
        'purchaseBatchId': purchaseBatchId,
        'category': data['category'],
        if (productImageUrl.isNotEmpty) 'productImageUrl': productImageUrl,
        if (shelfInfo != null)
          'expiryDate': shelfLifeService.computeExpiryDate(name, now),
        if (shelfInfo != null)
          'storageType': shelfInfo.storageType.firestoreValue,
        'purchasedAt': purchasedAtStr,
      });
    }

    // Keep this purchase as a separate fridge batch so purchase date / expiry
    // do not get mixed with older ingredients of the same name.
    final existingIngredients =
        (previousFridge?['ingredients'] as List?)
            ?.map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
            .toList() ??
        [];
    final ingredientsForSave = [
      ...existingIngredients,
      ...newIngredients.map((ing) => Map<String, dynamic>.from(ing)),
    ];

    // New recipes from this purchase.
    final recipeMap = <String, List<Map<String, dynamic>>>{};
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final recipeId = cartItem['recipeId']?.toString() ?? 'unknown';
      recipeMap.putIfAbsent(recipeId, () => []);
      recipeMap[recipeId]!.add(cartItem);
    }

    final newRecipes = <Map<String, dynamic>>[];
    for (final entry in recipeMap.entries) {
      final recipeId = entry.key;
      final items = entry.value;
      final first = items.first;
      final ings = first['ingredients'] as List? ?? [];
      final recipeIngredients = <Map<String, dynamic>>[];
      for (final ing in ings) {
        final i = ing as Map<String, dynamic>;
        final qty = i['qty'];
        final ingredientName = i['item']?.toString() ?? '';
        final qtyNum = qty is num
            ? qty.toDouble()
            : (qty is String ? double.tryParse(qty) : null) ?? 0.0;
        final rawUnit = i['unit']?.toString() ?? '개';
        final shoppingConverted = IngredientUnitConverter.toShoppingUnit(
          ingredientName: ingredientName,
          qty: qtyNum,
          unit: rawUnit,
        );
        final ingredientMarketplace =
            _purchasedMarketplaceByIngredient[ingredientName] ??
            _selectedMarketplace;
        final recommendation = ingredientName.isNotEmpty
            ? (_getCachedRecommendationByMarketplace(
                    ingredientName,
                    ingredientMarketplace,
                  ) ??
                  _getCachedRecommendation(ingredientName))
            : null;
        final bestMatch = recommendation?.bestMatch;
        final productImageUrl = bestMatch?.productImage ?? '';
        final productName = bestMatch?.productName ?? '';
        recipeIngredients.add({
          'item': i['item'],
          'name': i['item'],
          'qty': qty,
          'originalQty': qty,
          'unit': rawUnit, // cooking unit
          'qty_conventional': i['qty_conventional'] ?? qty,
          'unit_conventional': i['unit_conventional'] ?? rawUnit,
          'shoppingQty': shoppingConverted.qty,
          'shoppingUnit': shoppingConverted.unit,
          'productName': productName,
          if (productImageUrl.isNotEmpty) 'productImageUrl': productImageUrl,
        });
      }
      final date = _effectiveRecipeDatesForCart(cartItems)[recipeId];
      final recipeSourceUrl =
          (first['sourceUrl'] as String?)?.trim() ??
          (_recipeSourceUrlById[recipeId] ?? '').trim();
      final recipePlatform =
          (first['platform'] as String?)?.trim() ??
          (_recipePlatformById[recipeId] ?? '').trim();
      newRecipes.add({
        'recipeId': recipeId,
        'recipeName': first['recipeName']?.toString() ?? '레시피',
        'date': date == null
            ? null
            : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'servings': first['servings'] ?? 1,
        'sourceUrl': recipeSourceUrl,
        'platform': recipePlatform,
        'purchaseBatchId': purchaseBatchId,
        'ingredients': recipeIngredients,
      });
    }

    // Merge with existing fridge recipes: keep all existing, append new.
    final existingRecipes =
        (previousFridge?['recipes'] as List?)
            ?.map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
            .toList() ??
        [];
    final recipesForSave = <Map<String, dynamic>>[
      ...existingRecipes,
      ...newRecipes,
    ];
    final int sessionPurchasedRecipeServings = newRecipes.fold<int>(0, (
      sum,
      r,
    ) {
      final servings = (r['servings'] as num?)?.toInt() ?? 0;
      return sum + servings;
    });

    Future<void> doSaveAndNavigate() async {
      try {
        // 구매 완료 = 재료를 냉장고로. 요리 일정은 식단 캘린더에서 따로 잡는다.
        await _userService.saveFridgeDataAndClearCart(
          user.uid,
          ingredients: ingredientsForSave,
          recipes: recipesForSave,
        );

        // [임시 비활성] 구매완료 자가신고 포인트
        // final marketplacesInBatch = purchasedIngredientEvents
        //     .map((e) => e['marketplace']?.toString() ?? 'unknown')
        //     .toSet();
        // for (final marketplace in marketplacesInBatch) {
        //   unawaited(
        //     RewardsService.instance.claim(
        //       'points_purchase_self_report',
        //       idempotencyKey:
        //           'points_purchase_self_report:$purchaseBatchId:$marketplace',
        //       sourceRef: purchaseBatchId,
        //     ),
        //   );
        // }

        // 장바구니 비움 직후 UI가 빈 화면으로 갱신되기 전에 냉장고로 먼저 이동.
        if (!mounted) return;
        UserService.markPendingFridgePurchaseTip();
        widget.onPurchaseComplete?.call();

        // Trigger LLM research for any ingredients missing shelf-life data.
        ShelfLifeResearchUploader.checkAndQueue(
          ingredientsForSave
              .map((e) => e['name']?.toString() ?? '')
              .where((n) => n.isNotEmpty)
              .toList(),
        );

        // 직접 추가(manual_*)는 recipes 문서가 없음. 있는 레시피만 update.
        final firestore = FirebaseFirestore.instance;
        for (final recipe in newRecipes) {
          final recipeId = recipe['recipeId']?.toString() ?? '';
          if (recipeId.isEmpty ||
              recipeId == 'unknown' ||
              recipeId == _defaultCartRecipeId ||
              recipeId.startsWith('manual_')) {
            continue;
          }
          try {
            await firestore.collection('recipes').doc(recipeId).update({
              'purchaseOccasionCount': FieldValue.increment(1),
              'updatedAt': FieldValue.serverTimestamp(),
            });
          } catch (e) {
            debugPrint(
              'Purchase occasion count skipped for $recipeId: $e',
            );
          }
        }
        if (isDefaultCartRecipePurchase) {
          await _rememberDefaultCartRecipeDismissed();
        }
        unawaited(
          _analyticsService.trackPurchaseCompleted(
            ingredientCount: newIngredients.length,
            recipeCount: newRecipes.length,
            totalExpenditure: sessionTotalExpenditure,
            coupangExpenditure: sessionCoupangExpenditure,
            kurlyExpenditure: sessionKurlyExpenditure,
            recipeIds: [
              for (final recipe in newRecipes)
                recipe['recipeId']?.toString() ?? '',
            ],
          ),
        );
        unawaited(
          _analyticsService.trackFridgeIngredientAdded(
            itemCount: newIngredients.length,
            method: 'cart',
            ingredientNames: [
              for (final event in purchasedIngredientEvents)
                event['ingredientName'] as String? ?? '',
            ],
            recipeIds: [
              for (final event in purchasedIngredientEvents)
                event['recipeId'] as String?,
            ],
          ),
        );
        for (final event in purchasedIngredientEvents) {
          unawaited(
            _analyticsService.trackIngredientPurchased(
              ingredientName: event['ingredientName'] as String? ?? 'unknown',
              category: event['category'] as String?,
              marketplace: event['marketplace'] as String? ?? 'unknown',
              price: (event['price'] as num?)?.toInt() ?? 0,
              recipeId: event['recipeId'] as String?,
            ),
          );
        }
        unawaited(
          _analyticsService.trackPurchaseForUser(
            user.uid,
            itemsBoughtCount: sessionItemsBoughtCount,
            purchasedRecipeCount: newRecipes.length,
            purchasedRecipeServings: sessionPurchasedRecipeServings,
          ),
        );
        if (!mounted) return;
        setState(() {
          _isPurchaseCompleting = false;
          for (final purchasedKeys
              in _purchasedIngredientKeysByMarketplace.values) {
            purchasedKeys.clear();
          }
          _purchasedMarketplaceByIngredient.clear();
          _recipeDates.clear();
          _lastRecipeIdsHash = '';
          _lastThumbnailLookupHash = '';
          _thumbnailOneShotRefreshHash = '';
          _productRecommendationCache.clear();
          _lastRequestedSignatureByCacheKey.clear();
          _missingRecommendationKeys.clear();
          _ingredientCategoryCache.clear();
          _preprocessedNameCache.clear();
          _hasCompletedInitialSearch = false;
          _productSearchFailed = false;
          _productSearchFailureMessage = '';
        });
        _thumbnailOneShotRefreshTimer?.cancel();
        _thumbnailOneShotRefreshTimer = null;
        _recommendationCacheSaveTimer?.cancel();
        _recommendationCacheSaveTimer = null;
        unawaited(_clearCurrentUserCartCache());
        final uidForClear = _cachedCartUid;
        if (uidForClear != null) {
          unawaited(_localStorageService.clearRecommendationCache(uidForClear));
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isPurchaseCompleting = false);
          _showBottomNotification(
            SnackBar(content: Text('저장 실패: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted && _isPurchaseCompleting) {
          setState(() => _isPurchaseCompleting = false);
        } else {
          _isPurchaseCompleting = false;
        }
      }
    }

    widget.onFridgeIconBounceRequested?.call();
    unawaited(doSaveAndNavigate());
  }

  /// Async meal-plan dates plus [scheduledDate] on cart rows (earliest date per recipe).
  Map<String, DateTime> _effectiveRecipeDatesForCart(List<dynamic> cartItems) {
    final Map<String, DateTime> out = Map<String, DateTime>.from(_recipeDates);
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final rid = cartItem['recipeId']?.toString() ?? '';
      if (rid.isEmpty || rid == 'unknown') continue;
      final sd = cartItem['scheduledDate'];
      DateTime? cartDay;
      if (sd is int) {
        cartDay = DateTime.fromMillisecondsSinceEpoch(sd);
      } else if (sd is num) {
        cartDay = DateTime.fromMillisecondsSinceEpoch(sd.toInt());
      }
      if (cartDay == null) continue;
      cartDay = DateTime(cartDay.year, cartDay.month, cartDay.day);
      if (!out.containsKey(rid) || cartDay.isBefore(out[rid]!)) {
        out[rid] = cartDay;
      }
    }
    return out;
  }

  /// Saved-recipe thumbnails first; fill gaps from user-created (parsed) recipes.
  /// Saved 레시피의 platform 우선, 비어 있으면 user 생성 레시피에서 보강.
  Map<String, String> _mergeRecipePlatformMaps(
    List<Map<String, dynamic>> savedRecipes,
    List<Map<String, dynamic>> userCreatedRecipes,
  ) {
    String plat(Map<String, dynamic> r) {
      final src = r['source'];
      if (src is Map) return (src['platform'] as String?)?.trim() ?? '';
      return (r['platform'] as String?)?.trim() ?? '';
    }

    final map = <String, String>{};
    for (final r in savedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isNotEmpty) map[id] = plat(r);
    }
    for (final r in userCreatedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final p = plat(r);
      if (p.isEmpty) continue;
      if ((map[id] ?? '').isEmpty) map[id] = p;
    }
    return map;
  }

  Map<String, String> _mergeRecipeSourceUrlMaps(
    List<Map<String, dynamic>> savedRecipes,
    List<Map<String, dynamic>> userCreatedRecipes,
  ) {
    String srcUrl(Map<String, dynamic> r) {
      final top = (r['sourceUrl'] as String?)?.trim() ?? '';
      if (top.isNotEmpty) return top;
      final s = r['source'];
      if (s is Map) return (s['url'] as String?)?.trim() ?? '';
      return '';
    }

    final map = <String, String>{};
    for (final r in savedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isNotEmpty) map[id] = srcUrl(r);
    }
    for (final r in userCreatedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final u = srcUrl(r);
      if (u.isEmpty) continue;
      if ((map[id] ?? '').isEmpty) map[id] = u;
    }
    return map;
  }

  Map<String, String> _mergeRecipeThumbnailMaps(
    List<Map<String, dynamic>> savedRecipes,
    List<Map<String, dynamic>> userCreatedRecipes,
  ) {
    String thumbUrl(Map<String, dynamic> r) =>
        RecipeThumbnailResolver.resolve(r, preferCroppedForInstagram: true);

    final map = <String, String>{};
    for (final r in savedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isNotEmpty) map[id] = thumbUrl(r);
    }
    for (final r in userCreatedRecipes) {
      final id = r['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final url = thumbUrl(r);
      if (url.isEmpty) continue;
      if ((map[id] ?? '').isEmpty) map[id] = url;
    }
    return map;
  }

  Map<String, String> _thumbnailMapFromCartItems(List<dynamic> cartItems) {
    final out = <String, String>{};
    for (final raw in cartItems) {
      final item = raw as Map<String, dynamic>;
      final recipeId = item['recipeId']?.toString() ?? '';
      if (recipeId.isEmpty) continue;
      final direct = (item['thumbnailUrl'] as String?)?.trim() ?? '';
      if (direct.isNotEmpty) {
        out[recipeId] = direct;
      }
    }
    return out;
  }

  Map<String, String> _sourceUrlMapFromCartItems(List<dynamic> cartItems) {
    final out = <String, String>{};
    for (final raw in cartItems) {
      final item = raw as Map<String, dynamic>;
      final recipeId = item['recipeId']?.toString() ?? '';
      if (recipeId.isEmpty) continue;
      final direct = (item['sourceUrl'] as String?)?.trim() ?? '';
      if (direct.isNotEmpty) {
        out[recipeId] = direct;
      }
    }
    return out;
  }

  Map<String, String> _platformMapFromCartItems(List<dynamic> cartItems) {
    final out = <String, String>{};
    for (final raw in cartItems) {
      final item = raw as Map<String, dynamic>;
      final recipeId = item['recipeId']?.toString() ?? '';
      if (recipeId.isEmpty) continue;
      final direct = (item['platform'] as String?)?.trim() ?? '';
      if (direct.isNotEmpty) {
        out[recipeId] = direct;
      }
    }
    return out;
  }

  Future<void> _loadRecipeThumbnailsForRecipes(List<String> recipeIds) async {
    if (_isLoadingRecipeThumbnails || recipeIds.isEmpty) return;
    _isLoadingRecipeThumbnails = true;
    try {
      final meta = await _recipeService.getRecipeMetaForIds(recipeIds);
      if (!mounted) return;
      final mergedThumb = Map<String, String>.from(_recipeThumbnailById);
      final mergedPlatform = Map<String, String>.from(_recipePlatformById);
      final mergedSourceUrl = Map<String, String>.from(_recipeSourceUrlById);
      var changedThumb = false;
      var changedPlatform = false;
      var changedSourceUrl = false;
      for (final entry in meta.entries) {
        final thumb = (entry.value['thumbnailUrl'] as String?)?.trim() ?? '';
        final platform = (entry.value['platform'] as String?)?.trim() ?? '';
        final sourceUrl = (entry.value['sourceUrl'] as String?)?.trim() ?? '';
        if (thumb.isNotEmpty &&
            ((mergedThumb[entry.key] ?? '').isEmpty ||
                mergedThumb[entry.key] != thumb)) {
          mergedThumb[entry.key] = thumb;
          changedThumb = true;
        }
        if (platform.isNotEmpty &&
            ((mergedPlatform[entry.key] ?? '').isEmpty ||
                mergedPlatform[entry.key] != platform)) {
          mergedPlatform[entry.key] = platform;
          changedPlatform = true;
        }
        if (sourceUrl.isNotEmpty &&
            ((mergedSourceUrl[entry.key] ?? '').isEmpty ||
                mergedSourceUrl[entry.key] != sourceUrl)) {
          mergedSourceUrl[entry.key] = sourceUrl;
          changedSourceUrl = true;
        }
      }
      if ((changedThumb || changedPlatform || changedSourceUrl) && mounted) {
        setState(() {
          if (changedThumb) _recipeThumbnailById = mergedThumb;
          if (changedPlatform) _recipePlatformById = mergedPlatform;
          if (changedSourceUrl) _recipeSourceUrlById = mergedSourceUrl;
        });
      }
    } catch (_) {
      // Ignore thumbnail lookup failures; cart item thumbnails still act as fallback.
    } finally {
      _isLoadingRecipeThumbnails = false;
    }
  }

  // Load meal plans to get dates for recipes
  Future<void> _loadMealPlansForRecipes(List<String> recipeIds) async {
    if (_isLoadingMealPlans) return;

    final user = _auth.currentUser;
    if (user == null) return;

    _isLoadingMealPlans = true;

    // Include past meal-plan days so recipes planned before "today" still show their date in the cart.
    // (The 7-day home calendar only shows a window; Firestore may still hold older date docs.)
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDate = today.subtract(const Duration(days: 400));
    final endDate = today.add(const Duration(days: 30));

    try {
      final mealPlans = await _mealPlanService
          .getMealPlansForDateRange(startDate, endDate)
          .first;

      final Map<String, DateTime> recipeDates = {};

      for (final mealPlanEntry in mealPlans.entries) {
        final dateKey = mealPlanEntry.key;
        final mealPlan = mealPlanEntry.value;
        final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};

        // Parse date from dateKey
        final dateParts = dateKey.split('-');
        if (dateParts.length == 3) {
          final date = DateTime(
            int.parse(dateParts[0]),
            int.parse(dateParts[1]),
            int.parse(dateParts[2]),
          );

          // Check all meal times for recipes
          for (final mealTime in ['breakfast', 'lunch', 'dinner']) {
            final mealTimeRecipes = List<String>.from(meals[mealTime] ?? []);
            for (final recipeId in mealTimeRecipes) {
              if (recipeIds.contains(recipeId)) {
                // Use the earliest date if recipe appears multiple times
                if (!recipeDates.containsKey(recipeId) ||
                    date.isBefore(recipeDates[recipeId]!)) {
                  recipeDates[recipeId] = date;
                }
              }
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _recipeDates = recipeDates;
          _isLoadingMealPlans = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading meal plans: $e');
      }
      if (mounted) {
        setState(() {
          _isLoadingMealPlans = false;
        });
      }
    }
  }

  // Get Korean day of week
  String _getKoreanDayOfWeek(DateTime date) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[date.weekday - 1];
  }

  // Format date for display
  String _formatDate(DateTime date) {
    return '${date.month}.${date.day.toString().padLeft(2, '0')} ${_getKoreanDayOfWeek(date)}';
  }

  // Keep each word unbroken so Korean syllables don't split across lines.
  String _keepWordTogetherForWrap(String text) {
    return text.splitMapJoin(
      RegExp(r'\S+'),
      onMatch: (m) => m.group(0)!.split('').join('\u2060'),
      onNonMatch: (n) => n,
    );
  }

  String _categorizeIngredient(String ingredientName, String? category) {
    if (_ingredientCategoryCache.containsKey(ingredientName)) {
      return _ingredientCategoryCache[ingredientName]!;
    }
    final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: category,
      ingredientName: ingredientName,
    );
    final display = IngredientCategoryUnifier.titleFromKey(groupKey);
    _ingredientCategoryCache[ingredientName] = display;
    return display;
  }

  String _ingredientCategoryKeyFromTitle(String title) {
    for (final key in IngredientCategoryUnifier.groupOrder) {
      if (IngredientCategoryUnifier.titleFromKey(key) == title) return key;
    }
    return IngredientCategoryUnifier.seasoningsSauces;
  }

  //         total += bestMatch.productPrice;
  //       }
  //     }
  //   }
  //   return total;
  // }

  static String _marketplaceLabel(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return '쿠팡';
      case ShoppingMarketplace.marketKurly:
        return '마켓 컬리';
      case ShoppingMarketplace.oasis:
        return '오아시스';
    }
  }

  static String _affiliateDisclosureFullText(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return '이 포스팅은 쿠팡 파트너스 활동의 일환으로, 일정액의 수수료를 제공받습니다.';
      case ShoppingMarketplace.marketKurly:
        return '이 포스팅은 마켓컬리 큐레이터 활동의 일환으로, 일정액의 수수료를 제공받습니다.';
      case ShoppingMarketplace.oasis:
        return '이 포스팅은 쿠팡 파트너스 활동의 일환으로, 일정액의 수수료를 제공받습니다.';
    }
  }

  static String _marketplaceLogoAsset(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return _assetCoupangLogo;
      case ShoppingMarketplace.marketKurly:
        return _assetMarketkurlyLogo;
      case ShoppingMarketplace.oasis:
        return _assetOasisLogo;
    }
  }

  /// Logo image for a marketplace. Uses image assets from assets/marketplace/. Clipped with rounded corners.
  Widget _marketplaceLogo(ShoppingMarketplace m, {double size = 20}) {
    final String assetPath = _marketplaceLogoAsset(m);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.35),
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(
          Icons.store,
          size: size,
          color: AppColors.getTextSecondary(Theme.of(context).brightness),
        ),
      ),
    );
  }

  Widget _buildAffiliateDisclosurePill(Brightness brightness) {
    return Container(
      width: double.infinity,
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _affiliateDisclosureFullText(_selectedMarketplace),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.getTextTertiary(brightness),
                letterSpacing: -0.15,
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => setState(() => _affiliateDisclosureDismissed = true),
            behavior: HitTestBehavior.opaque,
            child: Icon(
              Icons.close_rounded,
              size: 12,
              color: AppColors.getTextTertiary(brightness),
            ),
          ),
        ],
      ),
    );
  }

  void _selectMarketplace(
    ShoppingMarketplace marketplace, {
    String method = 'tab',
  }) {
    if (!_isManualShoppingMode && _selectedMarketplace == marketplace) return;
    final previous = _selectedMarketplace;
    unawaited(
      _analyticsService.trackCartMarketplaceSelected(
        marketplace: _marketplaceForAnalytics(marketplace),
        method: method,
        previousMarketplace: _marketplaceForAnalytics(previous),
      ),
    );
    setState(() {
      _isManualShoppingMode = false;
      _affiliateDisclosureDismissed = false;
      _selectedMarketplace = marketplace;
      if (marketplace == ShoppingMarketplace.coupang ||
          marketplace == ShoppingMarketplace.marketKurly) {
        // Only reset search state if no cached recommendations exist for target
        // marketplace. This avoids shimmer flicker when swiping back to a tab
        // whose data was already loaded.
        final hasCachedData = _lastAggregatedIngredientsForRetry.keys.any(
          (name) =>
              _productRecommendationCache[_recommendationCacheKey(
                marketplace,
                name,
              )] !=
              null,
        );
        if (!hasCachedData) {
          _hasCompletedInitialSearch = false;
        }
        _productSearchFailed = false;
        _productSearchFailureMessage = '';
      }
    });
  }

  Future<void> _showAddManualIngredientFlow() async {
    final user = _auth.currentUser;
    if (user == null) {
      AppToast.info(context, '로그인 후 재료를 추가할 수 있어요');
      return;
    }

    Haptics.selection();
    final draft = await showCartAddIngredientSheet(context);
    if (!mounted || draft == null) return;

    try {
      final now = DateTime.now();
      final cartItem = <String, dynamic>{
        'recipeId': 'manual_${now.millisecondsSinceEpoch}',
        'recipeName': '직접 재료 추가',
        'servings': 1,
        'ingredients': [
          {
            'item': draft.name,
            'qty': draft.qty,
            'unit': draft.unit,
            'category': draft.categoryKey,
          },
        ],
        'addedAt': now.toIso8601String(),
      };
      await _userService.addToCart(user.uid, cartItem);
      if (!mounted) return;
      // 기본 탭은 항상 쿠팡.
      setState(() {
        _isManualShoppingMode = false;
        _selectedMarketplace = ShoppingMarketplace.coupang;
      });
      AppToast.success(
        context,
        '${draft.name}을(를) 장보기 목록에 추가했어요',
        title: '재료 추가 완료',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '재료 추가에 실패했어요');
    }
  }

  /// 쿠팡/마켓컬리 재료 목록 — 스와이프로 전환. pill 탭과 동기화.
  Widget _buildMarketplacePageView({
    required List<dynamic> cartItems,
    required Map<String, Map<String, dynamic>> aggregatedIngredients,
    required Brightness brightness,
    required bool isDefaultPreview,
  }) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (_isManualShoppingMode) return;
        if (details.primaryVelocity == null) return;
        final currentIndex = _swipeableMarketplaces.indexOf(
          _selectedMarketplace,
        );
        if (details.primaryVelocity! < -200 &&
            currentIndex < _swipeableMarketplaces.length - 1) {
          _selectMarketplace(
            _swipeableMarketplaces[currentIndex + 1],
            method: 'swipe',
          );
        } else if (details.primaryVelocity! > 200 && currentIndex > 0) {
          _selectMarketplace(
            _swipeableMarketplaces[currentIndex - 1],
            method: 'swipe',
          );
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          return FadeTransition(opacity: animation, child: child);
        },
        child: RepaintBoundary(
          key: ValueKey<ShoppingMarketplace>(_selectedMarketplace),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_isManualShoppingMode)
                _buildProductSearchFailureBanner(brightness),
              _buildIngredientSections(
                cartItems,
                aggregatedIngredients,
                brightness,
                marketplace: _selectedMarketplace,
                isDefaultPreview: isDefaultPreview,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarketplacePillSelector() {
    // `clipBehavior: Clip.none` + vertical padding so the selected pill's
    // soft drop shadow can render above/below the scroll viewport without
    // getting cropped at the pill's edge. The 6px padding gives the
    // ~10px blur enough breathing room; the surrounding Transform.translate
    // and SizedBox are tightened by the same amount so the overall section
    // height stays unchanged.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _buildMarketplacePill(
            marketplace: ShoppingMarketplace.coupang,
            label: '쿠팡',
          ),
          const SizedBox(width: 7),
          _buildMarketplacePill(
            marketplace: ShoppingMarketplace.marketKurly,
            label: '마켓컬리',
          ),
          const SizedBox(width: 7),
          _buildMarketplacePill(
            marketplace: ShoppingMarketplace.oasis,
            label: '오아시스',
            comingSoon: true,
          ),
          const SizedBox(width: 7),
          _buildExternalMarketplacePill(
            assetPath: 'assets/ssg_logo.png',
            label: 'SSG',
          ),
          const SizedBox(width: 7),
          _buildExternalMarketplacePill(
            assetPath: 'assets/emart_logo.png',
            label: '이마트몰',
          ),
        ],
      ),
    );
  }

  Widget _buildMarketplacePill({
    required ShoppingMarketplace marketplace,
    required String label,
    bool comingSoon = false,
  }) {
    final isSelected =
        !_isManualShoppingMode &&
        _selectedMarketplace == marketplace &&
        !comingSoon;
    return GestureDetector(
      onTap: comingSoon ? null : () => _selectMarketplace(marketplace),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 28,
        padding: const EdgeInsets.only(left: 8, right: 10),
          decoration: BoxDecoration(
          color: isSelected ? Colors.white : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(999),
          // Always a transparent 1px border so the pill's hit-box stays
          // the same dimension whether selected or not — prevents the
          // 1px layout twitch that the old peach border caused on toggle.
          border: Border.all(color: Colors.transparent, width: 1),
          // Selected state: drop the visible border, switch to a soft
          // two-layer shadow so the pill reads as a "lifted white card"
          // instead of an outlined chip. Matches the premium minimal
          // badge-card aesthetic used elsewhere in the cart UI.
          boxShadow: isSelected
              ? [
              BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 3,
                offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Opacity(
          opacity: comingSoon ? 0.48 : 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: _marketplaceLogo(marketplace, size: 15),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: isSelected
                      ? const Color(0xFF191F28)
                      : const Color(0xFF6B7684),
                  letterSpacing: -0.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExternalMarketplacePill({
    required String assetPath,
    required String label,
  }) {
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 8, right: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Opacity(
        opacity: 0.40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.asset(
                assetPath,
                width: 15,
                height: 15,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.storefront_rounded,
                  size: 15,
                  color: Color(0xFF8B95A1),
                ),
              ),
            ),
            const SizedBox(width: 5),
              Text(
              label,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF6B7684),
                letterSpacing: -0.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build category sections under 장보기 목록 (pill + name + count per section, no white box)
  static const _recipeThumbBorderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFC043),
      Color(0xFFFF7A32),
      Color(0xFFFF6B9D),
      Color(0xFFB794F4),
    ],
    stops: [0.0, 0.35, 0.7, 1.0],
  );

  /// 레시피 썸네일·직접추가 카드 공통 그라데이션 테두리.
  Widget _wrapRecipeThumbGradientBorder({required Widget child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: _recipeThumbBorderGradient,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10.4),
          child: child,
        ),
      ),
    );
  }

  /// 직접 추가 커버 — 흰 배경 + 검정 플러스 (테두리는 공통 래퍼).
  Widget _buildManualCartRecipeCover() {
    return const ColoredBox(
      color: Colors.white,
      child: Center(
        child: Icon(
          Icons.add_rounded,
          size: 34,
          color: Color(0xFF191F28),
        ),
      ),
    );
  }

  Widget _buildFigmaRecipeCarousel(
    Map<String, List<Map<String, dynamic>>> groupedByRecipe,
    Map<String, String> recipeIdToThumbnail,
    Map<String, String> recipeIdToPlatform,
    Map<String, String> recipeIdToSourceUrl,
    Map<String, DateTime> recipeDates,
    Brightness brightness, {
    bool isDefaultPreview = false,
  }) {
    const orange = Color(0xFFFF6422);
    const dateGrey = Color(0xFF888888);
    const dividerGrey = Color(0xFFD1D1D6);

    final sortedEntries = groupedByRecipe.entries.toList()
      ..sort((a, b) {
        final da = recipeDates[a.key];
        final db = recipeDates[b.key];
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });

    const double carouselHeight = 164;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: carouselHeight,
        width: double.infinity,
        child: Container(
          height: carouselHeight,
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(0, 13, 0, 13),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.05),
              width: 0.67,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 15),
                for (int i = 0; i < sortedEntries.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Builder(
                    builder: (context) {
                      final entry = sortedEntries[i];
                      final recipeId = entry.key;
                      final firstItem = entry.value.first;
                      final recipeName =
                          firstItem['recipeName']?.toString() ?? '레시피';
                      final servings = firstItem['servings'] ?? 1;
                      final date = recipeDates[recipeId];
                      final thumbnailUrl = recipeIdToThumbnail[recipeId] ?? '';
                      final platform = recipeIdToPlatform[recipeId] ?? '';
                      final sourceUrl = recipeIdToSourceUrl[recipeId] ?? '';
                      final isManualRecipe = recipeId.startsWith('manual_') ||
                          recipeName == '직접 재료 추가' ||
                          recipeName == '직접 추가';
                      final displayRecipeName =
                          isManualRecipe ? '직접 재료 추가' : recipeName;

                      return GestureDetector(
                        // NavGuard.once is global; awaiting a modal here would
                        // keep the guard locked for the entire dialog lifetime
                        // and silently swallow any NavGuard.once tap inside.
                        onTap: () {
                          if (isDefaultPreview) {
                            _openTrendingRecipesPage();
                            return;
                          }
                          _showEditCartItemDialog(
                            recipeId: recipeId,
                            recipeName: displayRecipeName,
                            cartItems: entry.value,
                            servings: servings is num
                                ? servings.toDouble()
                                : double.tryParse(servings.toString()) ?? 1.0,
                          );
                        },
                        child: SizedBox(
                          width: 88,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 88,
                                height: 110,
                                child: _wrapRecipeThumbGradientBorder(
                                  // 고정 88x110를 테두리 패딩 안에 넣으면 overflow가 나므로
                                  // 이미지는 남는 공간을 expand로만 채운다.
                                  child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    thumbnailUrl.isNotEmpty
                                        ? ThumbnailLetterboxMitigation(
                                            platform: platform,
                                            imageUrl: thumbnailUrl,
                                            sourceUrl: sourceUrl,
                                            child: AppNetworkImage(
                                              imageUrl: thumbnailUrl,
                                              fit: BoxFit.cover,
                                              memCacheWidth: AppNetworkImage
                                                  .listThumbCacheSize,
                                              memCacheHeight: AppNetworkImage
                                                  .listThumbCacheSize,
                                              errorWidget: const ColoredBox(
                                                color: Color(0xFFE0E0E0),
                                                child: Icon(
                                                  Icons.restaurant,
                                                  size: 28,
                                                  color: Color(0xFFBBBBBB),
                                                ),
                                              ),
                                            ),
                                          )
                                        : isManualRecipe
                                            ? _buildManualCartRecipeCover()
                                            : const ColoredBox(
                                                color: Color(0xFFE0E0E0),
                                                child: Icon(
                                                  Icons.restaurant,
                                                  size: 28,
                                                  color: Color(0xFFBBBBBB),
                                                ),
                                              ),
                                    if (!isManualRecipe)
                                      const Positioned.fill(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.transparent,
                                                Color(0x8C000000),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (!isDefaultPreview)
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: GestureDetector(
                                        onTap: () async {
                                          final confirmed = await showDialog<bool>(
                                            context: context,
                                            barrierColor: Colors.black
                                                .withValues(alpha: 0.35),
                                            builder: (ctx) {
                                              final cartItems =
                                                  _currentCartItems ?? [];
                                              final ingredientNamesForRecipe =
                                                  _getIngredientNamesForRecipe(
                                                    cartItems,
                                                    recipeId,
                                                  );
                                              final purchasedCount =
                                                  ingredientNamesForRecipe
                                                      .where(
                                                        (name) =>
                                                            _purchasedIngredientKeys
                                                                  .contains(
                                                                    name,
                                                                  ),
                                                      )
                                                      .length;
                                              final sortedNames =
                                                  ingredientNamesForRecipe
                                                      .toList()
                                                    ..sort();
                                              final namesPreview =
                                                  sortedNames.isEmpty
                                                  ? ''
                                                  : sortedNames.length <= 8
                                                  ? sortedNames.join(', ')
                                                  : '${sortedNames.take(8).join(', ')} 외 ${sortedNames.length - 8}개';
                                              final title = isManualRecipe
                                                  ? '직접 추가한 재료를 제거할까요?'
                                                  : '레시피를 제거할까요?';
                                              final String subtitle;
                                              if (isManualRecipe) {
                                                if (sortedNames.isEmpty) {
                                                  subtitle =
                                                      '장바구니에서 직접 추가한 재료가 삭제됩니다.';
                                                } else if (purchasedCount > 0) {
                                                  subtitle =
                                                      '삭제될 재료: $namesPreview\n이미 구매한 재료 $purchasedCount개가 있어요.';
                                                } else {
                                                  subtitle =
                                                      '삭제될 재료: $namesPreview';
                                                }
                                              } else {
                                                subtitle = purchasedCount > 0
                                                    ? '이미 구매한 재료 $purchasedCount개가 있어요.'
                                                    : '장바구니에서 해당 레시피가 삭제됩니다.';
                                              }
                                              return Dialog(
                                                backgroundColor:
                                                    Colors.transparent,
                                                elevation: 0,
                                                insetPadding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 27,
                                                    ),
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.white,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          24,
                                                        ),
                                                    boxShadow: const [
                                                      BoxShadow(
                                                        color: Color(
                                                          0x1F000000,
                                                        ),
                                                        blurRadius: 30,
                                                        offset: Offset(0, 8),
                                                      ),
                                                    ],
                                                  ),
                                                    clipBehavior:
                                                        Clip.antiAlias,
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.fromLTRB(
                                                              24,
                                                              24,
                                                              24,
                                                              20,
                                                            ),
                                                        child: Column(
                                                          mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                          children: [
                                                            Text(
                                                              title,
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              style: const TextStyle(
                                                                fontFamily:
                                                                    'Pretendard',
                                                                fontSize: 19,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                height: 1.5,
                                                                letterSpacing:
                                                                    -0.45,
                                                                color: Color(
                                                                  0xFF191F28,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              subtitle,
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                              style: TextStyle(
                                                                fontFamily:
                                                                    'Pretendard',
                                                                fontSize: 15,
                                                                fontWeight:
                                                                    purchasedCount >
                                                                            0 ||
                                                                        (isManualRecipe &&
                                                                            sortedNames
                                                                                .isNotEmpty)
                                                                    ? FontWeight
                                                                          .w700
                                                                    : FontWeight
                                                                          .w400,
                                                                height: 1.5,
                                                                letterSpacing:
                                                                    -0.35,
                                                                color:
                                                                    purchasedCount >
                                                                        0
                                                                    ? _cartAccentOrange
                                                                    : const Color(
                                                                        0xFF4E5968,
                                                                      ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      Container(
                                                        height: 55.167,
                                                        decoration:
                                                            const BoxDecoration(
                                                              border: Border(
                                                                top: BorderSide(
                                                                  color: Color(
                                                                    0xFFF2F4F6,
                                                                  ),
                                                                    width:
                                                                        0.667,
                                                                ),
                                                              ),
                                                            ),
                                                        child: Row(
                                                          children: [
                                                            Expanded(
                                                              child: InkWell(
                                                                onTap: () =>
                                                                    Navigator.of(
                                                                      ctx,
                                                                    ).pop(
                                                                      false,
                                                                    ),
                                                                child: Container(
                                                                  height: double
                                                                      .infinity,
                                                                  alignment:
                                                                      Alignment
                                                                          .center,
                                                                  decoration: const BoxDecoration(
                                                                    border: Border(
                                                                      right: BorderSide(
                                                                        color: Color(
                                                                          0xFFF2F4F6,
                                                                        ),
                                                                        width:
                                                                            0.667,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  child: const Text(
                                                                    '취소',
                                                                    style: TextStyle(
                                                                      fontFamily:
                                                                          'Pretendard',
                                                                      fontSize:
                                                                          16,
                                                                      fontWeight:
                                                                            FontWeight.w500,
                                                                      height:
                                                                          1.5,
                                                                      color: Color(
                                                                        0xFF4E5968,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            Expanded(
                                                              child: InkWell(
                                                                onTap: () =>
                                                                    Navigator.of(
                                                                      ctx,
                                                                      ).pop(
                                                                        true,
                                                                      ),
                                                                child: Container(
                                                                  height: double
                                                                      .infinity,
                                                                  alignment:
                                                                      Alignment
                                                                          .center,
                                                                  child: const Text(
                                                                    '삭제',
                                                                    style: TextStyle(
                                                                      fontFamily:
                                                                          'Pretendard',
                                                                      fontSize:
                                                                          16,
                                                                      fontWeight:
                                                                            FontWeight.w700,
                                                                      height:
                                                                          1.5,
                                                                      color: Color(
                                                                        0xFFEF4444,
                                                                      ),
                                                                    ),
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
                                            },
                                          );
                                          if (confirmed == true) {
                                            final user = _auth.currentUser;
                                            if (user != null) {
                                              final cartItems =
                                                  _currentCartItems ?? [];
                                              final ingredientNamesForRecipe =
                                                  _getIngredientNamesForRecipe(
                                                    cartItems,
                                                    recipeId,
                                                  );
                                              for (final name
                                                  in ingredientNamesForRecipe) {
                                                _unmarkIngredientPurchased(
                                                  name,
                                                );
                                              }
                                              if (mounted) setState(() {});
                                                if (recipeId ==
                                                    _defaultCartRecipeId) {
                                                  await _rememberDefaultCartRecipeDismissed();
                                                }
                                              try {
                                                await _mealPlanService
                                                    .removeRecipeFromAllMealPlans(
                                                      recipeId,
                                                    );
                                              } catch (e) {
                                                print(
                                                  'Error removing recipe $recipeId from meal plans: $e',
                                                );
                                              }
                                              await _userService
                                                  .removeCartItemsByRecipeId(
                                                    user.uid,
                                                    recipeId,
                                                  );
                                              unawaited(
                                                _analyticsService
                                                    .trackCartItemsRemoved(
                                                  recipeId: recipeId,
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          width: 24,
                                          height: 24,
                                          decoration: BoxDecoration(
                                            color: isManualRecipe
                                                ? const Color(0xFFF2F4F6)
                                                : const Color(0x80000000),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.close_rounded,
                                            size: 13,
                                            color: isManualRecipe
                                                ? const Color(0xFF6B7684)
                                                : Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (!isManualRecipe)
                                      Positioned(
                                        left: 8,
                                        bottom: 6,
                                        right: 8,
                                        child: Text(
                                          _keepWordTogetherForWrap(
                                            displayRecipeName,
                                          ),
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                            height: 13 / 10,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (isManualRecipe)
                                const Text(
                                  '직접 재료 추가',
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF4E5968),
                                    height: 1.25,
                                    letterSpacing: -0.2,
                                  ),
                                )
                              else
                                SizedBox(
                                  width: 88,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '$servings인분',
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 11,
                                            fontWeight: FontWeight.w400,
                                            color: dateGrey,
                                          ),
                                        ),
                                        if (date != null) ...[
                                          const SizedBox(width: 4),
                                          const Text(
                                            '·',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: dividerGrey,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _formatDate(date),
                                            style: const TextStyle(
                                              fontFamily: 'Pretendard',
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: orange,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(width: 15),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIngredientSections(
    List<dynamic> cartItems,
    Map<String, Map<String, dynamic>> aggregatedIngredients,
    Brightness brightness, {
    required ShoppingMarketplace marketplace,
    bool isDefaultPreview = false,
  }) {
    final categorizedIngredients =
        <String, Map<String, Map<String, dynamic>>>{};
    for (final groupKey in IngredientCategoryUnifier.groupOrder) {
      categorizedIngredients[IngredientCategoryUnifier.titleFromKey(groupKey)] =
          {};
    }

    for (final entry in aggregatedIngredients.entries) {
      final ingredientName = entry.key;
      final ingredientData = entry.value;
      final category = _categorizeIngredient(
        ingredientName,
        ingredientData['category']?.toString(),
      );
      categorizedIngredients[category]![ingredientName] = ingredientData;
    }

    final List<Widget> columnChildren = <Widget>[];

    for (final categoryEntry in categorizedIngredients.entries) {
      final entries = categoryEntry.value.entries.toList();
      if (entries.isEmpty) continue;
      columnChildren.add(
        _buildIngredientSectionTitle(
          cartItems: cartItems,
          aggregatedIngredients: aggregatedIngredients,
          categoryName: categoryEntry.key,
          count: entries.length,
          brightness: brightness,
          marketplace: marketplace,
          ingredientNames: entries.map((e) => e.key).toList(),
          isDefaultPreview: isDefaultPreview,
        ),
      );
      for (var i = 0; i < entries.length; i++) {
        final ingredientEntry = entries[i];
        final ingredientName = ingredientEntry.key;
        final isPurchasedInCurrentMarketplace =
            _purchasedIngredientKeysByMarketplace[marketplace]
                ?.contains(ingredientName) ??
            false;
        final purchasedMarketplace =
            _purchasedMarketplaceByIngredient[ingredientName];
        // TEMP: 구매확인 시 우측에 뜨던 마켓 배지(쿠팡/컬리)를 일단 숨김.
        // 데이터 자체는 그대로 두고 UI만 가린다 — 복구 시 아래 null을
        // _purchasedMarketplaceBadgeText(ingredientName)으로 되돌리면 끝.
        const String? purchasedMarketplaceBadgeText = null;
        columnChildren.add(
          _wrapProductCardImpression(
            ingredientName: ingredientName,
            marketplace: marketplace,
            position: i,
            child: _buildIngredientProductCard(
              cartItems: cartItems,
              ingredientName: ingredientName,
              ingredientData: ingredientEntry.value,
              brightness: brightness,
              marketplace: marketplace,
              isPurchasedInCurrentMarketplace: isPurchasedInCurrentMarketplace,
              purchasedMarketplace: purchasedMarketplace,
              purchasedMarketplaceBadgeText: purchasedMarketplaceBadgeText,
              isFirstInSection: i == 0,
              isDefaultPreview: isDefaultPreview,
            ),
          ),
        );
      }
    }

    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: columnChildren,
      ),
    );
  }

  Widget _buildIngredientSectionTitle({
    required List<dynamic> cartItems,
    required Map<String, Map<String, dynamic>> aggregatedIngredients,
    required String categoryName,
    required int count,
    required Brightness brightness,
    required ShoppingMarketplace marketplace,
    List<String> ingredientNames = const [],
    bool isDefaultPreview = false,
  }) {
    if (count == 0) return const SizedBox.shrink();
    final categoryKey = _ingredientCategoryKeyFromTitle(categoryName);
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 6, bottom: 7),
      child: Row(
        children: [
          IngredientCategoryUnifier.buildCategoryIcon(
            key: categoryKey,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            categoryName,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF333D4B),
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count개',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Color(0xFF6B7684),
                letterSpacing: 0.1,
              ),
            ),
          ),
          const Spacer(),
          if (!isDefaultPreview && ingredientNames.isNotEmpty)
            Builder(
              builder: (context) {
                final allNames = aggregatedIngredients.keys.toList();
                final allPurchased = allNames.every(
                  (name) => _purchasedIngredientKeys.contains(name),
                );
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (allPurchased) {
                        final currentSet =
                            _purchasedIngredientKeysByMarketplace[marketplace] ??
                            const <String>{};
                        for (final name in allNames) {
                          if (!currentSet.contains(name)) continue;
                          _unmarkIngredientPurchased(
                            name,
                            marketplace: marketplace,
                          );
                        }
                      } else {
                        for (final name in allNames) {
                          if (_purchasedIngredientKeys.contains(name)) continue;
                          _markIngredientPurchased(
                            name,
                            marketplace: marketplace,
                          );
                        }
                      }
                    });
                    _trackInProgressSessionIfThresholdMet(
                      cartItems,
                      aggregatedIngredients,
                    );
                  },
                  child: Text(
                    allPurchased ? '전체 해제' : '전체 구매확인',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF8B95A1),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// Product recommendation card template for each ingredient in 재료 리스트.
  /// 117px height × full width; left image 105×105 (~12px bigger diagonally). Product name limited to ~40% of card width then wraps; overflow shows ... after second line.
  /// 메모장 모드: 상품 추천 없이 재료명·필요량·구매확인만 보여주는 체크리스트 카드.
  Widget _buildManualShoppingIngredientCard({
    required List<dynamic> cartItems,
    required String ingredientName,
    required String displayIngredientName,
    required Map<String, dynamic> ingredientData,
    required String neededStr,
    required ShoppingMarketplace marketplace,
    required bool isPurchasedInCurrentMarketplace,
    required bool isPurchasedAnywhere,
    required bool isPurchasedOnOtherMarketplace,
    required bool isFirstInSection,
    required bool isDefaultPreview,
  }) {
    final recipeBreakdownRows = _getIngredientPerRecipeBreakdown(
      cartItems,
      ingredientName,
    );
    final recipeThumbUrlsForBar = <String>[];
    final seenRecipeIdsForBar = <String>{};
    for (final row in recipeBreakdownRows) {
      if (recipeThumbUrlsForBar.length >= 3) break;
      if (row.recipeId.isEmpty || row.recipeId == 'unknown') continue;
      if (seenRecipeIdsForBar.contains(row.recipeId)) continue;
      seenRecipeIdsForBar.add(row.recipeId);
      final url = _recipeThumbnailById[row.recipeId];
      if (url != null && url.isNotEmpty) recipeThumbUrlsForBar.add(url);
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: isFirstInSection ? 0 : 4,
        bottom: 4,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPurchasedAnywhere
                ? const [
                    Color(0xFFFFB020),
                    Color(0xFFFF7A32),
                    Color(0xFFFF6B35),
                    Color(0xFFFF5722),
                  ]
                : const [
                    Color(0xFFFFC043),
                    Color(0xFFFF7A32),
                    Color(0xFFFF6B9D),
                    Color(0xFFB794F4),
                  ],
            stops: const [0.0, 0.35, 0.7, 1.0],
          ),
          boxShadow: isPurchasedAnywhere
              ? const [
                  BoxShadow(
                    color: Color(0x38FF6B35),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
        ),
        padding: EdgeInsets.all(isPurchasedAnywhere ? 2 : 1.5),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: isPurchasedAnywhere
                ? const Color(0xFFFFF6F0)
                : Colors.white,
            borderRadius: BorderRadius.circular(18.5),
          ),
          child: ColoredBox(
            color: isPurchasedAnywhere
                ? const Color(0xFFFFE8DA)
                : const Color(0xFFF3F4F6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 78,
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFFFFF),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: const Color(0xFFE6E9EF),
                              width: 1,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x0D000000),
                                blurRadius: 8,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            displayIngredientName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2C2C2E),
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (!isDefaultPreview) ...[
                        GestureDetector(
                          onTap: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              barrierColor: Colors.black.withValues(alpha: 0.35),
                              builder: (ctx) {
                                return Dialog(
                                  backgroundColor: Colors.transparent,
                                  elevation: 0,
                                  insetPadding: const EdgeInsets.symmetric(
                                    horizontal: 27,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            24,
                                            24,
                                            24,
                                            20,
                                          ),
                                          child: Text(
                                            '$ingredientName을 제거할까요?',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              fontFamily: 'Pretendard',
                                              fontSize: 19,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF191F28),
                                            ),
                                          ),
                                        ),
                                        Container(
                                          height: 55,
                                          decoration: const BoxDecoration(
                                            border: Border(
                                              top: BorderSide(
                                                color: Color(0xFFF2F4F6),
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: InkWell(
                                                  onTap: () =>
                                                      Navigator.of(ctx).pop(false),
                                                  child: const Center(
                                                    child: Text(
                                                      '취소',
                                                      style: TextStyle(
                                                        fontFamily: 'Pretendard',
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        color: Color(0xFF4E5968),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Expanded(
                                                child: InkWell(
                                                  onTap: () =>
                                                      Navigator.of(ctx).pop(true),
                                                  child: const Center(
                                                    child: Text(
                                                      '제거',
                                                      style: TextStyle(
                                                        fontFamily: 'Pretendard',
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Color(0xFFEF4444),
                                                      ),
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
                              },
                            );
                            if (confirmed == true) {
                              final user = _auth.currentUser;
                              if (user != null) {
                                _unmarkIngredientPurchased(ingredientName);
                                if (mounted) setState(() {});
                                try {
                                  await _userService.removeIngredientFromCart(
                                    user.uid,
                                    ingredientName,
                                  );
                                } catch (e) {
                                  _showBottomNotification(
                                    SnackBar(
                                      content: Text('삭제 실패: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            }
                          },
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(
                                color: const Color(0xFFE6E9EF),
                              ),
                            ),
                            child: Center(
                              child: Image.asset(
                                'assets/icons/trash_icon.png',
                                width: 14,
                                height: 14,
                                color: const Color(0xFF8E96A3),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () {
                            if (isPurchasedOnOtherMarketplace) return;
                            final category =
                                ingredientData['category']?.toString();
                            setState(() {
                              if (isPurchasedInCurrentMarketplace) {
                                _unmarkIngredientPurchased(
                                  ingredientName,
                                  category: category,
                                  marketplace: marketplace,
                                );
                              } else {
                                _markIngredientPurchased(
                                  ingredientName,
                                  category: category,
                                  marketplace: marketplace,
                                );
                              }
                            });
                            _trackInProgressSessionIfThresholdMet(
                              cartItems,
                              _aggregateIngredients(cartItems),
                            );
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            decoration: BoxDecoration(
                              color: isPurchasedAnywhere
                                  ? null
                                  : Colors.white,
                              gradient: isPurchasedAnywhere
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFFFF8A4C),
                                        Color(0xFFFF6B35),
                                      ],
                                    )
                                  : null,
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(
                                color: isPurchasedAnywhere
                                    ? const Color(0xFFFF6B35)
                                    : const Color(0xFFE6E9EF),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: isPurchasedAnywhere
                                          ? Colors.white
                                          : const Color(0xFFE6E9EF),
                                    ),
                                  ),
                                  child: isPurchasedAnywhere
                                      ? const Icon(
                                          Icons.check,
                                          size: 10,
                                          color: _cartAccentOrange,
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '구매확인',
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: isPurchasedAnywhere
                                        ? Colors.white
                                        : const Color(0xFF737B88),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isPurchasedAnywhere
                            ? const Color(0xFFFFC7A8)
                            : const Color(0xFFE6E9EF),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Text(
                          '필요',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFFFF6B35),
                            letterSpacing: -0.2,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            neededStr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF191F28),
                              letterSpacing: -0.2,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (recipeThumbUrlsForBar.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _buildIngredientBarRecipeThumbnails(
                            recipeThumbUrlsForBar,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIngredientProductCard({
    required List<dynamic> cartItems,
    required String ingredientName,
    required Map<String, dynamic> ingredientData,
    required Brightness brightness,
    required ShoppingMarketplace marketplace,
    required bool isPurchasedInCurrentMarketplace,
    required ShoppingMarketplace? purchasedMarketplace,
    required String? purchasedMarketplaceBadgeText,
    bool isFirstInSection = false,
    bool isDefaultPreview = false,
  }) {
    // When Oasis is selected, show placeholder (only Coupang and Kurly are integrated)
    if (marketplace == ShoppingMarketplace.oasis) {
      final String marketplaceName = _marketplaceLabel(marketplace);
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: isFirstInSection ? 0 : 4,
          bottom: 4,
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.getBackground(brightness),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.getBorder(brightness),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    ingredientName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$marketplaceName 연동 준비 중',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Disabled buy button with marketplace color (마켓컬리 = purple, 오아시스 = green)
              _buildMarketplaceBuyButtonCompact(
                marketplace: marketplace,
                url: null,
                brightness: brightness,
              ),
            ],
          ),
        ),
      );
    }

    // 필요 (needed): recipe total only (no extra purchase quantity)
    final recipeTotalQty = (ingredientData['totalQty'] as double?) ?? 0.0;
    final totalQty = recipeTotalQty;
    final unit = ingredientData['unit']?.toString() ?? '개';

    final needed = totalQty;

    // Get actual product package size from recommendation if available (Coupang or Kurly cache)
    final isPurchasedAnywhere =
        purchasedMarketplaceBadgeText != null ||
        purchasedMarketplace != null ||
        _purchasedIngredientKeys.contains(ingredientName);
    // 다른 마켓플레이스에서만 구매 완료된 항목은 현재 탭에서 토글 잠금.
    // (예: 쿠팡에서 산 항목을 컬리 탭에서 풀거나 다시 체크하지 못함.)
    // 현재 탭의 세트에 이 항목이 들어있으면 토글은 정상 동작 (해제 가능).
    final isPurchasedOnOtherMarketplace =
        isPurchasedAnywhere && !isPurchasedInCurrentMarketplace;
    // 이미 구매된 항목은 시각적으로 그 마켓의 추천/버튼 스타일을 유지한다
    // (예: 쿠팡에서 산 항목은 컬리 탭으로 가도 "쿠팡에서 구매" 버튼 그대로 노출).
    final recommendationMarketplace =
        purchasedMarketplace ?? marketplace;
    final recommendation =
        _getCachedRecommendationByMarketplace(
          ingredientName,
          recommendationMarketplace,
        ) ??
        _getCachedRecommendation(ingredientName);
    final bestMatch = recommendation?.bestMatch;
    final displayIngredientName =
        recommendation?.effectiveDisplayName ?? ingredientName;

    // Calculate order quantity: buy the minimum number of packages that covers the needed amount.
    double orderQty;
    String orderUnit = unit;
    if (bestMatch != null &&
        bestMatch.packageSize != null &&
        bestMatch.packageSize! > 0) {
      final pkgSize = bestMatch.packageSize!;
      final neededForPkg = _cartNeededForPackageMath(
        ingredientName: ingredientName,
        unit: unit,
        recipeNeeded: needed,
        packageUnit: bestMatch.packageUnit,
      );
      final pkgCount = pkgSize >= neededForPkg
          ? 1
          : (neededForPkg / pkgSize).ceil();
      orderQty = pkgSize * pkgCount;
      orderUnit = bestMatch.packageUnit ?? unit;
    } else {
      // No product matched: show exactly the amount needed (no arbitrary buffer).
      orderQty = needed;
    }

    final neededStr = _formatCartIngredientNeedLabel(
      ingredientName,
      ingredientData,
      cartItems,
    );

    // 메모장: 상품 추천/검색 실패와 무관하게 재료 체크리스트만 보여준다.
    if (_isManualShoppingMode) {
      return _buildManualShoppingIngredientCard(
        cartItems: cartItems,
        ingredientName: ingredientName,
        displayIngredientName: displayIngredientName,
        ingredientData: ingredientData,
        neededStr: neededStr,
        marketplace: marketplace,
        isPurchasedInCurrentMarketplace: isPurchasedInCurrentMarketplace,
        isPurchasedAnywhere: isPurchasedAnywhere,
        isPurchasedOnOtherMarketplace: isPurchasedOnOtherMarketplace,
        isFirstInSection: isFirstInSection,
        isDefaultPreview: isDefaultPreview,
      );
    }

    String orderStr;
    if ((orderUnit == 'g' || orderUnit == '그램') && orderQty >= 1000) {
      final kg = orderQty / 1000;
      orderStr = kg == kg.truncateToDouble()
          ? '${kg.toInt()}kg'
          : '${kg.toStringAsFixed(1)}kg';
    } else if ((orderUnit == 'ml' || orderUnit == '밀리리터') && orderQty >= 1000) {
      final l = orderQty / 1000;
      orderStr = l == l.truncateToDouble()
          ? '${l.toInt()}L'
          : '${l.toStringAsFixed(1)}L';
    } else {
      orderStr = orderQty % 1 == 0
        ? '${orderQty.toInt()}$orderUnit'
        : '${orderQty.toStringAsFixed(1)}$orderUnit';
    }

    // bestMatch is already retrieved above for order quantity calculation

    // Calculate unit price from product data
    String unitPriceStr = '-';
    if (bestMatch != null) {
      final bool unitIsGram =
          unit == 'g' ||
          unit.toLowerCase() == 'gram' ||
          unit.toLowerCase() == 'grams';

      // Use unitPrice if available (already per 100g from backend), otherwise calculate from productPrice and packageSize
      double? pricePer100g;
      if (bestMatch.unitPrice != null) {
        // Backend already provides unitPrice as per 100g
        pricePer100g = bestMatch.unitPrice;
      } else if (bestMatch.packageSize != null &&
          bestMatch.packageSize! > 0 &&
          bestMatch.productPrice > 0) {
        // Calculate unit price from product price and package size
        final pricePerUnit = bestMatch.productPrice / bestMatch.packageSize!;
        if (unitIsGram) {
          // Convert to price per 100g
          pricePer100g = pricePerUnit * 100;
        } else {
          // For non-gram units, use price per unit
          pricePer100g = pricePerUnit;
        }
      }

      if (pricePer100g != null) {
        if (unitIsGram) {
          // Format with comma separator
          final pricePer100gRounded = pricePer100g.round();
          unitPriceStr =
              '₩${pricePer100gRounded.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}/100g';
        } else {
          // Price per unit
          final pricePerUnitRounded = pricePer100g.round();
          unitPriceStr =
              '₩${pricePerUnitRounded.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}/1$unit';
        }
      } else if (bestMatch.productPrice > 0) {
        // Fallback: show product price if unit price cannot be calculated
        unitPriceStr =
            '₩${bestMatch.productPrice.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
      }
    }

    // Show shimmer only while initial/retry search is actually running.
    final isCardLoading =
        (_ingredientLoadingStates[ingredientName] == true) ||
        (!_hasCompletedInitialSearch && recommendation == null) ||
        (_isSearchingProducts && recommendation == null);
    if (isCardLoading) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: const ValueKey('shimmer'),
          child: Stack(
            children: [
              _ShimmerLoading(
                isLoading: true,
                child: _IngredientCardShimmerSkeleton(
                  isFirstInSection: isFirstInSection,
                ),
              ),
              // Keep ingredient name visible even while the rest is shimmering.
              // Positioned to match the pill location in the loaded card
              // (top-left over image area). The Stack here is at the top of
              // the card's widget tree, so (0,0) == absolute top-left of the
              // card. The underlying pill sits inside:
              //   outer Padding(left:16, top: outerTop)
              //   > Container(border: 1)       // inset child by 1px
              //   > inner Padding(14, 9)       // left 14, top 9
              //   > SizedBox(width: 90) + Center + pill
              // So the SizedBox(w:90) that wraps the pill should start at
              // absolute (16 + 1 + 14, outerTop + 1 + 9) for it to align.
              Positioned(
                left: 16 + 1 + 14, // outer padding + border + inner padding
                top:
                    (isFirstInSection ? 0 : 4) +
                    1 +
                    9, // outer top padding + border + inner top
                child: SizedBox(
                  width: 90,
                  height: 26,
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 60,
                        maxWidth: 100,
                      ),
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(100),
                        border: Border.all(
                          color: Colors.black.withOpacity(0.08),
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
                      alignment: Alignment.center,
                      child: Text(
                        ingredientName,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2C2C2E),
                          letterSpacing: -0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Center(
                  child: Text(
                    '요리GO가 최적의 상품을 찾고 있습니다...',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF99A1AF).withOpacity(0.5),
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (bestMatch == null) {
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: isFirstInSection ? 0 : 4,
          bottom: 4,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF1F3F5)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.search_off_rounded,
                size: 18,
                color: Color(0xFF9AA1AF),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$displayIngredientName 추천 상품을 찾지 못했어요.',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    _confirmAndRemoveIngredientFromCart(ingredientName),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  '삭제',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF8B95A1),
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    _retryProductSearchForIngredient(ingredientName),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  '재시도',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFF6B00),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    const textDark = Color(0xFF1A1A1A);
    const textGray = Color(0xFF8E8E93);
    const greenDelivery = Color(0xFF34C759);
    const starColor = Color(0xFFFFC107);

    // Same thumbnail map as 담은 레시피 carousel (recipeId → thumbnailUrl).
    final recipeBreakdownRows = _getIngredientPerRecipeBreakdown(
      cartItems,
      ingredientName,
    );
    final recipeThumbUrlsForBar = <String>[];
    final seenRecipeIdsForBar = <String>{};
    for (final row in recipeBreakdownRows) {
      if (recipeThumbUrlsForBar.length >= 3) break;
      if (row.recipeId.isEmpty || row.recipeId == 'unknown') continue;
      if (seenRecipeIdsForBar.contains(row.recipeId)) continue;
      seenRecipeIdsForBar.add(row.recipeId);
      final url = _recipeThumbnailById[row.recipeId];
      if (url != null && url.isNotEmpty) recipeThumbUrlsForBar.add(url);
    }

    // Package quantity label — parse "N[unit], M개" from product name to compute total
    final pkgParsed = _parseProductAmount(
      bestMatch,
      orderStr,
      ingredientName: ingredientName,
    );
    final String pkgLabel = pkgParsed.label;

    final priceStr = bestMatch.productPrice > 0
        ? '${_formatPrice(bestMatch.productPrice)}원'
        : '가격 정보 없음';
    final perUnitLabel = unitPriceStr != '-' ? '($unitPriceStr)' : '';

    // Delivery ETA text (prefer deliveryEtaDays, fallback to arrivalInfo).
    final arrivalText = _formatDeliveryArrivalText(bestMatch);
    final showBestMatchTagLayer = _productTagLayerHasContent(
      product: bestMatch,
      ingredientName: ingredientName,
      neededQty: recipeTotalQty,
      neededUnit: unit,
    );
    final isDetailExpanded = !_isManualShoppingMode &&
        !_collapsedIngredientDetailKeySet.contains(
          ingredientName,
        );

    final cardContent = Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: isFirstInSection ? 0 : 4,
        bottom: 4,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPurchasedAnywhere
                ? const [
                    Color(0xFFFFB020),
                    Color(0xFFFF7A32),
                    Color(0xFFFF6B35),
                    Color(0xFFFF5722),
                  ]
                : const [
                    Color(0xFFFFC043),
                    Color(0xFFFF7A32),
                    Color(0xFFFF6B9D),
                    Color(0xFFB794F4),
                  ],
            stops: const [0.0, 0.35, 0.7, 1.0],
          ),
          boxShadow: isPurchasedAnywhere
              ? const [
                  BoxShadow(
                    color: Color(0x38FF6B35),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                  BoxShadow(
                    color: Color(0x1AFF6B35),
                    blurRadius: 28,
                    spreadRadius: 1,
                    offset: Offset(0, 2),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
        ),
        padding: EdgeInsets.all(isPurchasedAnywhere ? 2 : 1.5),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: isPurchasedAnywhere
                ? const Color(0xFFFFF6F0)
                : Colors.white,
            borderRadius: BorderRadius.circular(
              isPurchasedAnywhere ? 18 : 18.5,
            ),
          ),
          // Expand/collapse: clip the same detail subtree (heightFactor).
          // AnimatedSize + child swap removes content immediately and only
          // shrinks empty space — that reads as a jarring collapse.
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            tween: Tween<double>(end: isDetailExpanded ? 1.0 : 0.0),
            builder: (context, expandT, _) {
              final showExpandedChrome = expandT > 0.001;
              return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header: solid when collapsed; soft fade into white when expanded.
            // Drive chrome from expandT so it doesn't snap mid-animation.
            Container(
              decoration: BoxDecoration(
                color: showExpandedChrome
                    ? null
                    : (isPurchasedAnywhere
                          ? const Color(0xFFFFE8DA)
                          : const Color(0xFFF3F4F6)),
                gradient: showExpandedChrome
                    ? LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isPurchasedAnywhere
                            ? const [
                                Color(0xFFFFE8DA),
                                Color(0xFFFFE8DA),
                                Color(0xFFFFF0E6),
                                Color(0xFFFFF6F0),
                              ]
                            : const [
                                Color(0xFFF3F4F6),
                                Color(0xFFF3F4F6),
                                Color(0xFFF7F8FA),
                                Color(0xFFFFFFFF),
                              ],
                        stops: const [0.0, 0.55, 0.82, 1.0],
                      )
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: 재료명 + 삭제 + 구매확인 (same 28px height)
                    Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 78,
                          child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                            color: const Color(0xFFFFFFFF),
                              borderRadius: BorderRadius.circular(100),
                              border: Border.all(
                              color: const Color(0xFFE6E9EF),
                                width: 1,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                color: Color(0x0D000000),
                                blurRadius: 8,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Text(
                            displayIngredientName,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2C2C2E),
                                letterSpacing: -0.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (!isDefaultPreview)
                            GestureDetector(
                              onTap: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  barrierColor: Colors.black.withValues(
                                    alpha: 0.35,
                                  ),
                                  builder: (ctx) {
                                    return Dialog(
                                      backgroundColor: Colors.transparent,
                                      elevation: 0,
                                      insetPadding: const EdgeInsets.symmetric(
                                        horizontal: 27,
                                      ),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                      borderRadius: BorderRadius.circular(24),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x1F000000),
                                              blurRadius: 30,
                                              offset: Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                                    24,
                                                    24,
                                                    24,
                                                    20,
                                                  ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    '$ingredientName을 제거할까요?',
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontFamily: 'Pretendard',
                                                      fontSize: 19,
                                                  fontWeight: FontWeight.w700,
                                                      height: 1.5,
                                                      letterSpacing: -0.45,
                                                      color: Color(0xFF191F28),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  const Text(
                                                    '장보기 목록에서 해당 재료가 제거됩니다.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontFamily: 'Pretendard',
                                                      fontSize: 15,
                                                  fontWeight: FontWeight.w400,
                                                      height: 1.5,
                                                      letterSpacing: -0.35,
                                                      color: Color(0xFF4E5968),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              height: 55.167,
                                              decoration: const BoxDecoration(
                                                border: Border(
                                                  top: BorderSide(
                                                    color: Color(0xFFF2F4F6),
                                                    width: 0.667,
                                                  ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: InkWell(
                                                      onTap: () => Navigator.of(
                                                        ctx,
                                                      ).pop(false),
                                                      child: Container(
                                                        height: double.infinity,
                                                    alignment: Alignment.center,
                                                        decoration:
                                                            const BoxDecoration(
                                                              border: Border(
                                                                right: BorderSide(
                                                                  color: Color(
                                                                    0xFFF2F4F6,
                                                                  ),
                                                                  width: 0.667,
                                                                ),
                                                              ),
                                                            ),
                                                        child: const Text(
                                                          '취소',
                                                          style: TextStyle(
                                                            fontFamily:
                                                                'Pretendard',
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                            height: 1.5,
                                                            color: Color(
                                                              0xFF4E5968,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: InkWell(
                                                      onTap: () => Navigator.of(
                                                        ctx,
                                                      ).pop(true),
                                                      child: Container(
                                                        height: double.infinity,
                                                    alignment: Alignment.center,
                                                        child: const Text(
                                                          '제거',
                                                          style: TextStyle(
                                                            fontFamily:
                                                                'Pretendard',
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            height: 1.5,
                                                            color: Color(
                                                              0xFFEF4444,
                                                            ),
                                                          ),
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
                                  },
                                );
                                if (confirmed == true) {
                                  final user = _auth.currentUser;
                                  if (user != null) {
                                    _unmarkIngredientPurchased(ingredientName);
                                    if (mounted) setState(() {});
                                    try {
                                  await _userService.removeIngredientFromCart(
                                            user.uid,
                                            ingredientName,
                                          );
                                    } catch (e) {
                                      _showBottomNotification(
                                        SnackBar(
                                          content: Text('삭제 실패: $e'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                    }
                                  }
                                }
                              },
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFFFF),
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(
                                    color: const Color(0xFFE6E9EF),
                                    width: 1,
                                  ),
                                ),
                                child: Center(
                                  child: Image.asset(
                                    'assets/icons/trash_icon.png',
                                    width: 14,
                                    height: 14,
                                    color: const Color(0xFF8E96A3),
                                  ),
                                ),
                              ),
                            ),
                      if (!isDefaultPreview) const SizedBox(width: 6),
                      if (!isDefaultPreview)
                            GestureDetector(
                              onTap: () {
                                if (isPurchasedOnOtherMarketplace) return;
                                final category = ingredientData['category']
                                    ?.toString();
                                final wasPurchased =
                                    isPurchasedInCurrentMarketplace;
                                setState(() {
                                  if (wasPurchased) {
                                    _unmarkIngredientPurchased(
                                      ingredientName,
                                      category: category,
                                  marketplace: marketplace,
                                    );
                                  } else {
                                    _markIngredientPurchased(
                                      ingredientName,
                                      category: category,
                                  marketplace: marketplace,
                                      productPrice: bestMatch.productPrice,
                                    );
                                  }
                                });
                                _trackInProgressSessionIfThresholdMet(
                                  cartItems,
                                  _aggregateIngredients(cartItems),
                                );
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                height: 28,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: isPurchasedAnywhere
                                      ? null
                                      : const Color(0xFFFFFFFF),
                                  gradient: isPurchasedAnywhere
                                      ? const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Color(0xFFFF8A4C),
                                            Color(0xFFFF6B35),
                                          ],
                                        )
                                      : null,
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(
                                    color: isPurchasedAnywhere
                                        ? const Color(0xFFFF6B35)
                                        : const Color(0xFFE6E9EF),
                                    width: 1,
                                  ),
                                  boxShadow: isPurchasedAnywhere
                                      ? const [
                                          BoxShadow(
                                            color: Color(0x40FF6B35),
                                            blurRadius: 8,
                                            offset: Offset(0, 2),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 14,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: isPurchasedAnywhere
                                            ? Colors.white
                                            : const Color(0xFFFFFFFF),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: isPurchasedAnywhere
                                              ? Colors.white
                                              : const Color(0xFFE6E9EF),
                                          width: 1,
                                        ),
                                      ),
                                      child: isPurchasedAnywhere
                                          ? const Icon(
                                              Icons.check,
                                              size: 10,
                                              color: _cartAccentOrange,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '구매확인',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: isPurchasedAnywhere
                                            ? Colors.white
                                            : const Color(0xFF737B88),
                                        letterSpacing: -0.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (isPurchasedAnywhere &&
                                purchasedMarketplaceBadgeText != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFFFF),
                                  borderRadius: BorderRadius.circular(9),
                                  border: Border.all(
                                    color: const Color(0xFFE6E9EF),
                                    width: 1,
                                  ),
                                ),
                          alignment: Alignment.center,
                          child: Text(
                                      purchasedMarketplaceBadgeText,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF4B5563),
                                        letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            _showQuantityDetailPopup(
                              context: context,
                              ingredientName: ingredientName,
                              unit: unit,
                              recipeTotalQty: recipeTotalQty,
                              cartItems: cartItems,
                            );
                          },
                          child: Container(
                            // Match recipe-sourced height even without thumbs
                            // (thumb circle is 22px + padding ≈ 30).
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFFFFF),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isPurchasedAnywhere
                                    ? const Color(0xFFFFC7A8)
                                    : const Color(0xFFE6E9EF),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: isPurchasedAnywhere
                                      ? const Color(0x28FF6B35)
                                      : const Color(0x0D000000),
                                  blurRadius: isPurchasedAnywhere ? 10 : 8,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _buildNeedPackedBarLabels(
                                    neededStr: neededStr,
                                    pkgLabel: pkgLabel,
                                  ),
                                ),
                                if (recipeThumbUrlsForBar.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  _buildIngredientBarRecipeThumbnails(
                                    recipeThumbUrlsForBar,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (_isManualShoppingMode) {
                              // 메모장에서 펼치면 상품 추천 모드로 복귀.
                              _isManualShoppingMode = false;
                              _collapsedIngredientDetailKeySet.remove(
                                ingredientName,
                              );
                              return;
                            }
                            if (isDetailExpanded) {
                              _collapsedIngredientDetailKeySet.add(
                                ingredientName,
                              );
                            } else {
                              _collapsedIngredientDetailKeySet.remove(
                                ingredientName,
                              );
                            }
                          });
                        },
                        child: AnimatedRotation(
                          turns: isDetailExpanded ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFFFFF),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFE6E9EF),
                                width: 1,
                              ),
                            ),
                            child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: Color(0xFF7B8490),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  ],
                ),
              ),
            ),
            ClipRect(
              clipBehavior: Clip.hardEdge,
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: expandT.clamp(0.0, 1.0),
                child: (expandT <= 0.0 && !isDetailExpanded)
                    ? const SizedBox(width: double.infinity)
                    : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 1,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0x00E6E9EF),
                            Color(0xFFE6E9EF),
                            Color(0xFFE6E9EF),
                            Color(0x00E6E9EF),
                          ],
                          stops: [0.0, 0.12, 0.88, 1.0],
                        ),
                      ),
                    ),
                    if (showBestMatchTagLayer) ...[
                      const SizedBox(height: 8),
                      _buildProductTagLayer(
                        product: bestMatch,
                        ingredientName: ingredientName,
                        neededQty: recipeTotalQty,
                        neededUnit: unit,
                        ),
                        const SizedBox(height: 5),
                    ] else
                      const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 78,
                          height: 78,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x21000000),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(15),
                                child: AppNetworkImage(
                                  imageUrl: bestMatch.productImage.isNotEmpty
                                      ? bestMatch.productImage
                                      : 'https://via.placeholder.com/100',
                                  fit: BoxFit.cover,
                                  width: 78,
                                  height: 78,
                                  memCacheWidth:
                                      AppNetworkImage.listThumbCacheSize,
                                  memCacheHeight:
                                      AppNetworkImage.listThumbCacheSize,
                                  errorWidget: Container(
                                    color: const Color(0xFFF5F5F7),
                                    child: const Icon(
                                      Icons.image,
                                      color: Color(0xFFAEAEB2),
                                    ),
                                  ),
                                ),
                              ),
                              if (isPurchasedAnywhere)
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(15),
                                    color: Colors.white.withValues(alpha: 0.25),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                        Text(
                          bestMatch.productName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                                  fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: textDark,
                                  height: 1.28,
                            letterSpacing: -0.2,
                          ),
                        ),
                              const SizedBox(height: 4),
                        // Package size tag + price + unit price
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0xFFE8E8EC),
                                  width: 1.25,
                                ),
                              ),
                              child: Text(
                                pkgLabel,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: textGray,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              priceStr,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: textDark,
                                letterSpacing: -0.6,
                              ),
                            ),
                            if (perUnitLabel.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  perUnitLabel,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFAEAEB2),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                              const SizedBox(height: 2),
                        // Rating: 1 star + number + (reviews)
                              if (bestMatch.rating != null &&
                                  bestMatch.rating! > 0)
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                      size: 11,
                                color: starColor,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                bestMatch.rating!.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black,
                                ),
                              ),
                              if (bestMatch.reviews != null &&
                                  bestMatch.reviews! > 0) ...[
                                const SizedBox(width: 2),
                                Text(
                                  '(${_formatReviewCount(bestMatch.reviews!)})',
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w500,
                                    color: Color(0xFFC7C7CC),
                                  ),
                                ),
                              ],
                            ],
                          ),
                              if (bestMatch.rating != null &&
                                  bestMatch.rating! > 0)
                          const SizedBox(height: 3),
                        // Delivery
                        if (arrivalText.isNotEmpty)
                          Text(
                            arrivalText,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                              color: greenDelivery,
                              letterSpacing: -0.1,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                    ),
                  ],
                ),
              ),
              // Commerce action rail: primary buy + alternative products.
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: bestMatch.productUrl.isNotEmpty
                          ? () {
                              unawaited(
                                _openRecommendedProductLink(
                                  bestMatch: bestMatch,
                                  marketplace: recommendationMarketplace,
                                  ingredientName: ingredientName,
                                ),
                              );
                            }
                          : null,
                      child: Container(
                          height: 38,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: const Alignment(0, 0.5),
                            end: const Alignment(1, 0.5),
                            colors: _marketplaceButtonGradient(
                              recommendationMarketplace,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(13),
                          boxShadow: [
                            BoxShadow(
                              color: _marketplaceBuyStyle(
                                recommendationMarketplace,
                              ).$1.withOpacity(0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                  width: 22,
                                  height: 22,
                                child: _marketplaceLogo(
                                  recommendationMarketplace,
                                    size: 22,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _marketplaceBuyMainLabel(
                                recommendationMarketplace,
                              ),
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showOtherProductsDialog(
                      ingredientName: ingredientName,
                      productRecommendation: recommendation!,
                      brightness: brightness,
                    ),
                    child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7F9),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          // Coupang의 시안은 너무 밝아서 테두리에선 안 보임 →
                          // 같은 hue의 더 진한 파랑(sky-600)으로 교체.
                          color:
                              recommendationMarketplace ==
                                  ShoppingMarketplace.coupang
                              ? const Color(0xFF0284C7)
                              : _marketplaceBuyStyle(
                                  recommendationMarketplace,
                                ).$1,
                          width: 0.8,
                        ),
                      ),
                      alignment: Alignment.center,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.compare_arrows_rounded,
                              size: 16,
                              color: Color(0xFF3A3A3C),
                            ),
                            SizedBox(width: 4),
                            Text(
                        '대체상품 보기',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                                fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF3A3A3C),
                        ),
                            ),
                          ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
                      ],
                    ),
                  ),
            ),
          ],
        );
            },
          ),
        ),
      ),
    );

    // When purchased: card uses muted background + left accent; no overlay so trash, 구매확인, name stay visible and clickable
    return KeyedSubtree(
      key: ValueKey('card-$ingredientName'),
      child: cardContent,
    );
  }

  /// Shared "필요 … | 담김 …" labels — fixed size/weight (no FittedBox scaling)
  /// so recipe-added and manually-added cards look identical.
  Widget _buildNeedPackedBarLabels({
    required String neededStr,
    required String pkgLabel,
  }) {
    const base = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 11,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.2,
      height: 1.2,
    );
    return Row(
      children: [
        const Text(
          '필요',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: Color(0xFFFF6B35),
            letterSpacing: -0.2,
            height: 1.2,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            neededStr,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: const Color(0xFF191F28)),
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: 1,
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xFFDDE2EA),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          '담김',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: Color(0xFF8B95A1),
            letterSpacing: -0.2,
            height: 1.2,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            pkgLabel.isNotEmpty ? pkgLabel : '-',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: const Color(0xFF191F28)),
          ),
        ),
      ],
    );
  }

  /// Overlapping recipe circles for the 담은 양 / 필요량 row (URLs from [_recipeThumbnailById], same as 담은 레시피).
  Widget _buildIngredientBarRecipeThumbnails(List<String> imageUrls) {
    const double size = 22;
    const double step = 12;
    final n = imageUrls.length;
    if (n == 0) return const SizedBox.shrink();
    final w = size + (n - 1) * step;
    return SizedBox(
      width: w,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < n; i++)
            Positioned(
              left: i * step,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.25),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.18),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: AppNetworkImage(
                    imageUrl: imageUrls[i],
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    memCacheWidth: AppNetworkImage.avatarCacheSize,
                    memCacheHeight: AppNetworkImage.avatarCacheSize,
                    fadeInImmediately: true,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Build bottom bar (stays when scrolling): left = total/per-serving price,
  // right = purchase progress (fraction + "냉장고로") or icy "냉장고에서 관리" CTA when complete.
  // Fraction is derived from current cart ingredient cards only (checked = in both aggregatedIngredients and _purchasedIngredientKeys).
  static String _fmtPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  Widget _buildTotalPriceBar(
    List<dynamic> cartItems,
    Map<String, Map<String, dynamic>> aggregatedIngredients,
    Brightness brightness, {
    VoidCallback? onPurchaseComplete,
  }) {
    // --- Compute prices ---
    // 총 구매가: sum of productPrice for each ingredient (1 listing per ingredient)
    // 실질 사용가: sum of productPrice * (필요량 / 담은양) for each ingredient
    //   where 담은양 = actual total in the product listing (e.g. 1800g for "200g, 9개")
    // 실질 1인분: 실질 사용가 / totalServings
    // 잔여재료 cost: 총 구매가 - 실질 사용가
    int totalBuyPrice = 0;
    double actualUsageTotal = 0;

    for (final entry in aggregatedIngredients.entries) {
      final ingredientName = entry.key;
      final ingredientData = entry.value;
      final recipeTotal =
          (ingredientData['totalQty'] as num?)?.toDouble() ?? 0.0;
      final needed = recipeTotal;

      final recommendation = _getCachedRecommendation(ingredientName);
      final bestMatch = recommendation?.bestMatch;

      if (bestMatch == null || bestMatch.productPrice <= 0) continue;

      final itemCost = bestMatch.productPrice;
      totalBuyPrice += itemCost;

      // 담은양: reuse the same parsing as the product cards
      final actualAmount = _parseProductAmount(
        bestMatch,
        '',
        ingredientName: ingredientName,
      ).rawAmount;
      if (actualAmount != null && actualAmount > 0) {
        final ratio = (needed / actualAmount).clamp(0.0, 1.0);
        actualUsageTotal += itemCost * ratio;
      } else {
        actualUsageTotal += itemCost;
      }
    }

    // Total servings from unique recipes
    final Map<String, double> recipeServings = {};
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final recipeId = cartItem['recipeId']?.toString() ?? 'unknown';
      if (!recipeServings.containsKey(recipeId)) {
        recipeServings[recipeId] = (cartItem['servings'] as num?)?.toDouble() ?? 1.0;
      }
    }
    final totalServings = recipeServings.values.fold(0.0, (a, b) => a + b);
    final int perServingActual = totalServings > 0
        ? (actualUsageTotal / totalServings).round()
        : 0;
    final int leftoverCost = (totalBuyPrice - actualUsageTotal).round();

    // "구매 완료" 기준은 전체 재료가 아니라, 추천 상품을 제공할 수 있는 재료만 포함합니다.
    // (DB/추천 결과가 없는 재료는 완료 조건에서 제외)
    final providedIngredientKeys = aggregatedIngredients.keys.where((name) {
      final recommendation = _getCachedRecommendation(name);
      return recommendation?.bestMatch != null;
    }).toList();
    final int totalProvidedIngredients = providedIngredientKeys.length;
    final int purchasedProvidedCount = providedIngredientKeys
        .where((k) => _purchasedIngredientKeys.contains(k))
        .length;
    final bool allComplete =
        !_isSearchingProducts &&
        totalProvidedIngredients > 0 &&
        purchasedProvidedCount == totalProvidedIngredients;
    final double progressFraction = totalProvidedIngredients > 0
        ? (purchasedProvidedCount / totalProvidedIngredients).clamp(0.0, 1.0)
        : 0.0;

      return Padding(
      padding: EdgeInsets.only(
        bottom: IosLiquidGlassTabBar.overlayChromeInset(context),
      ),
      child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(
            color: Colors.black.withValues(alpha: 0.06),
            width: 0.667,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      padding: EdgeInsets.zero,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: double.infinity,
            // Pill sits on the right; a bit more right inset nudges it left slightly.
            padding: const EdgeInsets.fromLTRB(18, 8, 14, 7),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFFFFF7F2), Color(0xFFFFFFFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
            ),
            border: Border(
              bottom: BorderSide(
                  color: const Color(0xFFFFE4D6).withValues(alpha: 0.85),
                  width: 0.8,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        '총 구매가',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFF6422),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                    Text(
                        '₩${_fmtPrice(totalBuyPrice)}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                          fontSize: 20.5,
                        fontWeight: FontWeight.w900,
                          color: Color(0xFF191F28),
                          letterSpacing: -0.9,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                    Text(
                        '$totalServings인분 기준 · 1인분 실사용 ₩${_fmtPrice(perServingActual)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                          fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                          color: Color(0xFF8B95A1),
                          letterSpacing: -0.25,
                      ),
                    ),
                  ],
                ),
              ),
                const SizedBox(width: 10),
                _CartFridgeStatusTransition(
                  allComplete: allComplete,
                  purchased: purchasedProvidedCount,
                  total: totalProvidedIngredients,
                  fraction: progressFraction,
                  onPurchaseComplete: onPurchaseComplete,
                ),
            ],
          ),
        ),
        Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 7),
            color: const Color(0xFFF7F8FA),
          child: Row(
            children: [
                Icon(
                  allComplete ? Icons.kitchen_outlined : Icons.kitchen_rounded,
                  size: 14,
                  color: allComplete
                      ? const Color(0xFF3B9EFF)
                      : const Color(0xFF8B95A1),
                ),
                const SizedBox(width: 5),
                  Text(
                  allComplete
                      ? '탭하면 냉장고에서 재료 관리'
                      : '체크한 재료는 냉장고에서 관리',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: allComplete
                        ? const Color(0xFF3B9EFF)
                        : const Color(0xFF6B7280),
                    letterSpacing: -0.2,
                  ),
              ),
              const Spacer(),
                Text(
                  '₩${_fmtPrice(leftoverCost > 0 ? leftoverCost : 0)} 어치',
                  style: const TextStyle(
                      fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF3182F6),
                    letterSpacing: -0.3,
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

  /// Thin wrapper that delegates to the shared [IngredientUnitConverter.parseProductAmount].
  ({String label, double? rawAmount, String? rawUnit}) _parseProductAmount(
    CoupangProduct product,
    String fallback, {
    String? ingredientName,
  }) {
    // For egg ingredients, extract 구 count directly from product name.
    if (ingredientName != null && _isEggIngredient(ingredientName)) {
      final guMatch = RegExp(
        r'(\d+(?:\.\d+)?)\s*구',
      ).firstMatch(product.productName);
      if (guMatch != null) {
        final count = double.tryParse(guMatch.group(1)!) ?? 0;
        if (count > 0) {
          final str = count % 1 == 0
              ? '${count.toInt()}'
              : count.toStringAsFixed(1);
          return (label: '$str구', rawAmount: count, rawUnit: '구');
        }
      }
    }

    final parsed = IngredientUnitConverter.parseProductAmount(
      productName: product.productName,
      packageSize: product.packageSize,
      packageUnit: product.packageUnit,
      fallbackLabel: fallback,
    );
    return (
      label: parsed.label,
      rawAmount: parsed.rawAmount,
      rawUnit: parsed.rawUnit,
    );
  }

  // 헬퍼 함수: 가격 포맷팅
  String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  // 헬퍼 함수: 리뷰 수 포맷팅
  String _formatReviewCount(int count) {
    return count.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }

  /// `deliveryEtaDays` 우선, 없으면 arrivalInfo를 보수적으로 정리해 표시.
  String _formatDeliveryArrivalText(CoupangProduct product) {
    final etaDays = product.deliveryEtaDays;
    if (etaDays != null) {
      if (etaDays <= 0) return '당일 도착 예정';
      if (etaDays == 1) return '내일 도착 예정';
      if (etaDays == 2) return '모레 도착 예정';
      return '$etaDays일 후 도착 예정';
    }

    final raw = (product.arrivalInfo ?? '').replaceAll('보장', '예정').trim();
    if (raw.isEmpty) return '';
    if (raw.contains('도착')) return raw;
    if (raw.contains('오늘')) return '당일 도착 예정';
    if (raw.contains('내일')) return '내일 도착 예정';
    if (raw.contains('모레')) return '모레 도착 예정';
    return '';
  }

  /// Buy button background color and label per marketplace (Coupang = current; Kurly = purple; Oasis = green).
  /// Main card button label: "XXX에서 구매"
  static String _marketplaceBuyMainLabel(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return '쿠팡에서 구매';
      case ShoppingMarketplace.marketKurly:
        return '마켓컬리에서 구매';
      case ShoppingMarketplace.oasis:
        return '오아시스에서 구매';
    }
  }

  /// Gradient for main marketplace buy button (card)
  static List<Color> _marketplaceButtonGradient(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return [const Color(0xFF1565C0), const Color(0xFF1E88E5)];
      case ShoppingMarketplace.marketKurly:
        return [
          _marketplaceKurlyPurple,
          _marketplaceKurlyPurple.withValues(alpha: 0.85),
        ];
      case ShoppingMarketplace.oasis:
        return [
          _marketplaceOasisGreen,
          _marketplaceOasisGreen.withValues(alpha: 0.85),
        ];
    }
  }

  /// Compact / dialog "go" button label: "XXX로 가기"
  static (Color bg, String label) _marketplaceBuyStyle(ShoppingMarketplace m) {
    switch (m) {
      case ShoppingMarketplace.coupang:
        return (_marketplaceCoupangCyan, '쿠팡으로 가기');
      case ShoppingMarketplace.marketKurly:
        return (_marketplaceKurlyPurple, '마켓컬리로 가기');
      case ShoppingMarketplace.oasis:
        return (_marketplaceOasisGreen, '오아시스로 가기');
    }
  }

  /// Marketplace buy button (compact). Coupang uses current style; Kurly = purple, Oasis = green.
  Widget _buildMarketplaceBuyButtonCompact({
    required ShoppingMarketplace marketplace,
    required String? url,
    required Brightness brightness,
    VoidCallback? onPressed,
  }) {
    final (Color bg, String label) = _marketplaceBuyStyle(marketplace);
    final bool enabled = (url != null && url.isNotEmpty) || onPressed != null;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: enabled
            ? (onPressed ??
                  () => url != null
                      ? _openCoupangLink(url, marketplace: marketplace)
                      : null)
            : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          disabledBackgroundColor: bg.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white70,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          minimumSize: const Size(0, 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildProductTagLayer({
    required CoupangProduct product,
    String? ingredientName,
    double? neededQty,
    String? neededUnit,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
      final raw = product.tag?.trim() ?? '';
      final rawTags = raw.isEmpty
          ? <String>[]
          : raw
                .split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty && !_altSheetTagHiddenFromUi(t))
                .toList();

    final ing = ingredientName?.trim();
      final syntheticClose =
          ing != null &&
          ing.isNotEmpty &&
          CloseAmountTag.productMatchesCloseAmount(
            ingredientName: ing,
          neededQty: neededQty,
          neededUnit: neededUnit,
            product: product,
          ) &&
          !rawTags.any(_altSheetRawTagImpliesCloseAmount);

    final tagsForDisplay = <String>[...rawTags, if (syntheticClose) '딱 필요한 양'];
      if (tagsForDisplay.isEmpty) return const SizedBox.shrink();

      ({String text, Color color}) mapTag(String t) {
        switch (t) {
          case '최적':
          case 'Best':
          case '베스트':
            return (text: '딱 필요한 양', color: _closeAmountTagColor);
          case '추천':
          case 'Good':
          case '싸고 많은':
          case '가성비':
          case '가성비 최고':
            return (text: '가성비 최고', color: const Color(0xFF047857));
          case '단가 낮은':
          case '아주 싼':
          case '최저가':
          case 'Cheapest':
            return (text: '단가 낮은', color: const Color(0xFFBE123C));
          case '많이 산':
            return (text: '많이 산', color: const Color(0xFF1D4ED8));
          case '국내산':
          case '국산':
            return (text: '국내산', color: const Color(0xFFB45309));
          case '대용량':
            return (text: '대용량', color: const Color(0xFF6D28D9));
          case '딱 필요한 양':
            return (text: '딱 필요한 양', color: _closeAmountTagColor);
          case '로켓프레시':
          case '로켓 프레시':
          case 'RocketFresh':
            return (text: '로켓프레시', color: const Color(0xFF34C759));
          case '무료배송':
            return (text: '', color: const Color(0xFF3F3F47));
          default:
            return (text: t, color: const Color(0xFF3F3F47));
        }
      }

      Widget bubble(String text, Color color) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Pretendard',
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1,
                letterSpacing: -0.2,
              ),
            ),
          ),
        );
      }

      final tagBubbles = <Widget>[];
      for (final t in tagsForDisplay) {
        final mapped = mapTag(t);
        if (mapped.text.isEmpty) continue;
        if (tagBubbles.isNotEmpty) tagBubbles.add(const SizedBox(width: 6));
        tagBubbles.add(bubble(mapped.text, mapped.color));
      }
      if (tagBubbles.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: padding,
      child: IgnorePointer(
        child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Row(mainAxisSize: MainAxisSize.min, children: tagBubbles),
        ),
      ),
    );
  }

  bool _productTagLayerHasContent({
    required CoupangProduct product,
    String? ingredientName,
    double? neededQty,
    String? neededUnit,
  }) {
    final raw = product.tag?.trim() ?? '';
    final rawTags = raw.isEmpty
        ? <String>[]
        : raw
              .split(',')
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty && !_altSheetTagHiddenFromUi(t))
              .toList();

    final ing = ingredientName?.trim();
    final syntheticClose =
        ing != null &&
        ing.isNotEmpty &&
        CloseAmountTag.productMatchesCloseAmount(
          ingredientName: ing,
          neededQty: neededQty,
          neededUnit: neededUnit,
          product: product,
        ) &&
        !rawTags.any(_altSheetRawTagImpliesCloseAmount);

    return rawTags.isNotEmpty || syntheticClose;
  }

  // Cart-style product card for "대체상품 보기" list (no buy/qty buttons)
  Widget _buildCartStyleAltProductCard({
    required CoupangProduct product,
    required String unitPriceStr,
    required bool isSelected,
    required VoidCallback? onSelect,
    bool isAdmin = false,
    VoidCallback? onAdminRemove,
    String? altSheetIngredient,
    double? altSheetNeededQty,
    String? altSheetNeededUnit,
  }) {
    final priceStr = product.productPrice > 0
        ? '${_formatPrice(product.productPrice)}원'
        : '가격 정보 없음';
    final perUnitLabel = unitPriceStr != '-' ? '($unitPriceStr)' : '';

    // Delivery ETA text (prefer deliveryEtaDays, fallback to arrivalInfo).
    final arrivalText = _formatDeliveryArrivalText(product);

    final pkgLabel = _parseProductAmount(
      product,
      '',
      ingredientName: altSheetIngredient,
    ).label;

    Widget tagLayer() => _buildProductTagLayer(
      product: product,
      ingredientName: altSheetIngredient,
      neededQty: altSheetNeededQty,
      neededUnit: altSheetNeededUnit,
    );

    Widget actionButton() {
      final label = isSelected ? '현재 선택된 상품' : '이 상품으로 변경';
      final textColor = isSelected
          ? const Color(0xFF8B95A1)
          : Colors.white;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: isSelected ? null : onSelect,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: double.infinity,
              height: 40,
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFF7F8FA) : null,
                gradient: isSelected
                    ? null
                    : const LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(0xFFFF7A32),
                          Color(0xFFFF6B35),
                          Color(0xFFFF5722),
                        ],
                      ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFFE5E8EF)
                      : const Color(0xFFFF5722),
                  width: 1,
                ),
                boxShadow: isSelected
                    ? null
                    : const [
                        BoxShadow(
                          color: Color(0x33FF6B35),
                          blurRadius: 10,
                          offset: Offset(0, 3),
                        ),
                      ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isSelected ? Icons.check_rounded : Icons.swap_horiz_rounded,
                    size: 16,
                    color: textColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      letterSpacing: -0.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isAdmin && onAdminRemove != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 34,
              child: OutlinedButton(
                onPressed: onAdminRemove,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB91C1C),
                  side: const BorderSide(color: Color(0xFFFECACA), width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  '관리자 제외',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFB91C1C),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(0.07), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tag bubbles ABOVE the image row, but not width-limited to the image.
            // Left-aligned with the image edge, can extend into details area.
            Align(alignment: Alignment.centerLeft, child: tagLayer()),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Image (left alone)
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x21000000),
                        blurRadius: 12,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AppNetworkImage(
                      imageUrl: product.productImage.isNotEmpty
                          ? product.productImage
                          : 'https://via.placeholder.com/100',
                      fit: BoxFit.cover,
                      width: 90,
                      height: 90,
                      memCacheWidth: AppNetworkImage.listThumbCacheSize,
                      memCacheHeight: AppNetworkImage.listThumbCacheSize,
                      errorWidget: Container(
                        color: const Color(0xFFF5F5F7),
                        child: const Icon(
                          Icons.image,
                          color: Color(0xFFAEAEB2),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Details
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
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                          height: 1.33,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFFE8E8EC),
                                width: 1.25,
                              ),
                            ),
                            child: Text(
                              pkgLabel.isNotEmpty ? pkgLabel : '-',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF8E8E93),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            priceStr,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1A1A1A),
                              letterSpacing: -0.6,
                            ),
                          ),
                          if (perUnitLabel.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                perUnitLabel,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFAEAEB2),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (product.rating != null && product.rating! > 0)
                        Row(
                          children: [
                            const Icon(
                              Icons.star_rounded,
                              size: 11,
                              color: Color(0xFFFFC107),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              product.rating!.toStringAsFixed(1),
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                              ),
                            ),
                            if (product.reviews != null &&
                                product.reviews! > 0) ...[
                              const SizedBox(width: 2),
                              Text(
                                '(${_formatReviewCount(product.reviews!)})',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFFC7C7CC),
                                ),
                              ),
                            ],
                          ],
                        ),
                      if (arrivalText.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          arrivalText,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF34C759),
                            letterSpacing: -0.1,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            actionButton(),
          ],
        ),
      ),
    );
  }

  static const List<String> _altSheetFilterChips = [
    '전체',
    '딱 필요한 양',
    '가성비 최고',
    '많이 산',
    '국내산',
    '최저가',
  ];

  bool _altSheetRawTagImpliesCloseAmount(String t) {
    switch (t.trim()) {
      case '최적':
      case 'Best':
      case '베스트':
      case '딱 필요한 양':
        return true;
      default:
        return false;
    }
  }

  /// Tags we never show on substitute-product cards (still sent by other systems).
  bool _altSheetTagHiddenFromUi(String raw) {
    switch (raw.trim()) {
      case '무료배송':
        return true;
      default:
        return false;
    }
  }

  List<String> _altSheetRawTags(CoupangProduct p) {
    final raw = p.tag?.trim() ?? '';
    if (raw.isEmpty) return const [];
    return raw
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && !_altSheetTagHiddenFromUi(t))
        .toList();
  }

  /// Top picks for "레시피에 딱 필요한 양": score = [weightTags]×normalized tag count +
  /// [weightPrice]×normalized price (cheaper = higher). Defaults 0.55 / 0.45.
  static const double _altClosePickWeightTags = 0.55;
  static const double _altClosePickWeightPrice = 0.45;

  List<CoupangProduct> _altSheetPickTopCloseAmount(
    List<CoupangProduct> pool,
    String recipeIngredient,
    ProductRecommendation rec,
  ) {
    if (pool.isEmpty) return const [];

    final tagCounts = <int>[
      for (final p in pool)
        _altSheetEffectiveTagCount(
          p,
          recipeIngredient: recipeIngredient,
          recipeNeededQty: rec.neededQty,
          recipeNeededUnit: rec.neededUnit,
        ),
    ];
    final minT = tagCounts.reduce(math.min);
    final maxT = tagCounts.reduce(math.max);

    double tagNorm(int c) {
      if (maxT <= minT) return 1.0;
      return (c - minT) / (maxT - minT);
    }

    final validPrices = <int>[
      for (final p in pool)
        if (p.productPrice > 0) p.productPrice,
    ];
    final minP = validPrices.isEmpty ? 0 : validPrices.reduce(math.min);
    final maxP = validPrices.isEmpty ? 0 : validPrices.reduce(math.max);

    double priceNorm(int price) {
      if (price <= 0) return 0.0;
      if (maxP <= minP) return 1.0;
      return 1.0 - (price - minP) / (maxP - minP);
    }

    final scored = <({CoupangProduct p, double score})>[];
    for (var i = 0; i < pool.length; i++) {
      final p = pool[i];
      final tn = tagNorm(tagCounts[i]);
      final pn = priceNorm(p.productPrice);
      final s = _altClosePickWeightTags * tn + _altClosePickWeightPrice * pn;
      scored.add((p: p, score: s));
    }
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.p.productId.compareTo(b.p.productId);
    });
    return scored.take(3).map((e) => e.p).toList();
  }

  /// Maps backend/raw tag strings to filter chip labels (see [_altSheetFilterChips]).
  String? _altSheetFilterChipForRawTag(String raw) {
    switch (raw) {
      case '최적':
      case 'Best':
      case '베스트':
      case '딱 필요한 양':
        return '딱 필요한 양';
      case '추천':
      case 'Good':
      case '싸고 많은':
      case '가성비':
      case '가성비 최고':
        return '가성비 최고';
      case '많이 산':
        return '많이 산';
      case '국내산':
      case '국산':
        return '국내산';
      case '단가 낮은':
      case '아주 싼':
      case '최저가':
      case 'Cheapest':
        return '최저가';
      default:
        return null;
    }
  }

  Set<String> _altSheetFilterChipKeys(
    CoupangProduct p, {
    required String recipeIngredient,
    double? recipeNeededQty,
    String? recipeNeededUnit,
  }) {
    final out = <String>{};
    for (final t in _altSheetRawTags(p)) {
      final key = _altSheetFilterChipForRawTag(t);
      if (key != null) out.add(key);
    }
    if (CloseAmountTag.productMatchesCloseAmount(
      ingredientName: recipeIngredient,
      neededQty: recipeNeededQty,
      neededUnit: recipeNeededUnit,
      product: p,
    )) {
      out.add('딱 필요한 양');
    }
    return out;
  }

  int _altSheetEffectiveTagCount(
    CoupangProduct p, {
    required String recipeIngredient,
    double? recipeNeededQty,
    String? recipeNeededUnit,
  }) {
    final raw = _altSheetRawTags(p);
    var n = raw.length;
    if (CloseAmountTag.productMatchesCloseAmount(
          ingredientName: recipeIngredient,
          neededQty: recipeNeededQty,
          neededUnit: recipeNeededUnit,
          product: p,
        ) &&
        !raw.any(_altSheetRawTagImpliesCloseAmount)) {
      n += 1;
    }
    return n;
  }

  String _altSheetUnitPriceStr(CoupangProduct product, String? neededUnit) {
    if (neededUnit == null) return '-';
    final bool unitIsGram =
        neededUnit == 'g' ||
        neededUnit.toLowerCase() == 'gram' ||
        neededUnit.toLowerCase() == 'grams';
    double? pricePer100g;
    if (product.unitPrice != null) {
      pricePer100g = product.unitPrice;
    } else if (product.packageSize != null &&
        product.packageSize! > 0 &&
        product.productPrice > 0) {
      final pricePerUnit = product.productPrice / product.packageSize!;
      if (unitIsGram) {
        pricePer100g = pricePerUnit * 100;
      } else {
        pricePer100g = pricePerUnit;
      }
    }
    if (pricePer100g != null) {
      if (unitIsGram) {
        final pricePer100gRounded = pricePer100g.round();
        return '₩${pricePer100gRounded.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}/100g';
      }
      final pricePerUnitRounded = pricePer100g.round();
      return '₩${pricePerUnitRounded.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}/1$neededUnit';
    }
    if (product.productPrice > 0) {
      return '₩${product.productPrice.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
    }
    return '-';
  }

  ShoppingMarketplace? _marketplaceFromCacheKey(String key) {
    final split = key.indexOf(':');
    if (split <= 0) return null;
    switch (key.substring(0, split)) {
      case 'coupang':
        return ShoppingMarketplace.coupang;
      case 'marketKurly':
        return ShoppingMarketplace.marketKurly;
      case 'oasis':
        return ShoppingMarketplace.oasis;
      default:
        return null;
    }
  }

  /// Re-pick bestMatch using 많이 산 + weighted (tags × 0.6 + price × 0.4) logic.
  ProductRecommendation _applyRecommendedPick(
    ProductRecommendation pr, {
    ShoppingMarketplace? marketplace,
  }) {
    var picked = pr;
    final allCandidates = <CoupangProduct>[];
    if (pr.bestMatch != null) allCandidates.add(pr.bestMatch!);
    for (final p in pr.seeMoreList) {
      if (allCandidates.every((e) => e.productId != p.productId)) {
        allCandidates.add(p);
      }
    }
    if (allCandidates.length > 1) {
      final recommended = _pickRecommendedProduct(allCandidates);
      if (recommended != null &&
          recommended.productId != pr.bestMatch?.productId) {
        final newSeeMore = <CoupangProduct>[];
        if (pr.bestMatch != null) newSeeMore.add(pr.bestMatch!);
        for (final p in pr.seeMoreList) {
          if (p.productId != recommended.productId &&
              newSeeMore.every((e) => e.productId != p.productId)) {
            newSeeMore.add(p);
          }
        }
        picked = ProductRecommendation(
          ingredient: pr.ingredient,
          displayName: pr.displayName,
          neededQty: pr.neededQty,
          neededUnit: pr.neededUnit,
          bestMatch: recommended,
          seeMoreList: newSeeMore,
          allProducts: pr.allProducts,
        );
      }
    }
    final market = marketplace ?? _selectedMarketplace;
    return applyOnboardingToRecommendation(
      picked,
      profile: UserService.peekOnboardingProfile(),
      isCoupang: market == ShoppingMarketplace.coupang,
    );
  }

  /// Pick the 추천 product from a list:
  /// 1) Exactly one "많이 산" → that product.
  /// 2) Multiple "많이 산" → prefer those also with "딱 필요한 양", then most reviews → most tags → cheapest.
  /// 3) No "많이 산" → most reviews → most tags → cheapest.
  static CoupangProduct? _pickRecommendedProduct(
    List<CoupangProduct> products,
  ) {
    if (products.isEmpty) return null;
    if (products.length == 1) return products.first;

    List<String> parseTags(CoupangProduct p) {
      final raw = p.tag?.trim() ?? '';
      if (raw.isEmpty) return [];
      return raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
    }

    final manySold = products.where((p) {
      return parseTags(p).any((t) => t.trim() == '많이 산');
    }).toList();
    if (manySold.length == 1) return manySold.first;

    // If multiple have 많이 산, narrow to those
    final candidates = manySold.length > 1 ? manySold : products;

    // Among candidates, prefer those with both 많이 산 + 딱 필요한 양
    if (manySold.length > 1) {
      final withCloseAmount = candidates.where((p) {
        return parseTags(p).any((t) => t.trim() == '딱 필요한 양');
      }).toList();
      if (withCloseAmount.length == 1) return withCloseAmount.first;
      if (withCloseAmount.length > 1) {
        return _pickByReviewsThenTagsThenPrice(withCloseAmount, parseTags);
      }
    }

    return _pickByReviewsThenTagsThenPrice(candidates, parseTags);
  }

  static CoupangProduct _pickByReviewsThenTagsThenPrice(
    List<CoupangProduct> products,
    List<String> Function(CoupangProduct) parseTags,
  ) {
    if (products.length == 1) return products.first;

    final sorted = List<CoupangProduct>.from(products)
      ..sort((a, b) {
        // Reviews first (higher is better, only if >20% difference)
        final aReviews = a.reviews ?? 0;
        final bReviews = b.reviews ?? 0;
        final maxReviews = aReviews > bReviews ? aReviews : bReviews;
        if (maxReviews > 0) {
          final diff = (bReviews - aReviews).abs();
          if (diff / maxReviews > 0.2) return bReviews.compareTo(aReviews);
        }
        // Tags count (more is better)
        final tagDiff = parseTags(b).length.compareTo(parseTags(a).length);
        if (tagDiff != 0) return tagDiff;
        // Price (cheaper is better)
        if (a.productPrice > 0 && b.productPrice > 0) {
          return a.productPrice.compareTo(b.productPrice);
        }
        return 0;
      });

    return sorted.first;
  }

  /// Alt-product sheet order: selected (best) first, then see_more / all candidates.
  List<CoupangProduct> _seeMoreProductsForAltSheet(ProductRecommendation pr) {
    final baseProducts = pr.seeMoreList.isNotEmpty
        ? pr.seeMoreList
        : pr.allProducts;
    final bm = pr.bestMatch;
    final seen = <String>{};
    final out = <CoupangProduct>[];
    if (bm != null) {
      out.add(bm);
      seen.add(bm.productId);
    }
    for (final p in baseProducts) {
      if (!seen.contains(p.productId)) {
        out.add(p);
        seen.add(p.productId);
      }
    }
    return out;
  }

  // Show other products dialog
  void _showOtherProductsDialog({
    required String ingredientName,
    required ProductRecommendation productRecommendation,
    required Brightness brightness,
  }) async {
    final isAdminUser = await AdminService.instance.isAdmin();
    final seeMoreProducts = _seeMoreProductsForAltSheet(productRecommendation);

    if (seeMoreProducts.isEmpty) {
      _showBottomNotification(
        const SnackBar(
          content: Text('추가 상품이 없습니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    unawaited(
      _analyticsService.trackCartAlternativeProductsOpened(
        ingredientName: ingredientName,
        marketplace: _marketplaceForAnalytics(_selectedMarketplace),
        candidateCount: seeMoreProducts.length,
        recipeId: _analyticsRecipeIdForIngredient(ingredientName),
      ),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final liveRec = <ProductRecommendation>[productRecommendation];
        // Persist across sheet rebuilds — jump to "전체 상품" on open.
        final allProductsSectionKey = GlobalKey();
        final altListScrollController = ScrollController();
        var didScheduleAutoScroll = false;
        var listRevealed = false;
        VoidCallback? rebuildSheet;

        void scheduleScrollToAllProductsSection() {
          if (didScheduleAutoScroll) return;
          didScheduleAutoScroll = true;
          // Small breath between the sticky "필요/담김" pill and the section.
          const topBreathingRoom = 16.0;

          bool tryScroll() {
            final targetContext = allProductsSectionKey.currentContext;
            if (targetContext == null || !altListScrollController.hasClients) {
              return false;
            }

            Scrollable.ensureVisible(
              targetContext,
              alignment: 0.0,
              duration: Duration.zero,
              alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
            );
            final position = altListScrollController.position;
            // Still at top ⇒ target likely wasn't laid out yet (lazy list).
            if (position.pixels <= 1) {
              final probe = (position.maxScrollExtent * 0.55).clamp(
                240.0,
                position.maxScrollExtent,
              );
              if (probe > 1) {
                altListScrollController.jumpTo(probe);
              }
              return false;
            }
            final max = position.maxScrollExtent;
            final next = (position.pixels - topBreathingRoom).clamp(0.0, max);
            altListScrollController.jumpTo(next);
            return true;
          }

          Future<void> runHiddenScrollThenReveal() async {
            // Keep list invisible while we park on "전체 상품".
            for (var i = 0; i < 16; i++) {
              await Future<void>.delayed(
                Duration(milliseconds: i == 0 ? 1 : 24),
              );
              if (!altListScrollController.hasClients) continue;
              if (tryScroll()) break;
            }
            listRevealed = true;
            rebuildSheet?.call();
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(runHiddenScrollThenReveal());
          });
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            rebuildSheet = () => setSheetState(() {});
            final pr = liveRec[0];
            final seeMoreProducts = _seeMoreProductsForAltSheet(pr);
            final bestMatch = pr.bestMatch;
            final bottomInset = appSystemNavBottomInset(context);

            return AppMediaQueryMergeNavInsets(
              child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.8,
                color: AppColors.getBackground(brightness),
                child: Column(
                  children: [
                    // Header (Figma 314:225)
                    Builder(
                      builder: (context) {
                        final cartItems =
                            _currentCartItems ?? const <dynamic>[];
                        final unit =
                            (pr.neededUnit?.toString().isNotEmpty == true)
                            ? pr.neededUnit!.toString()
                            : '개';
                        final neededTotalQty = pr.neededQty ?? 0.0;
                        final recipeTotalQty = neededTotalQty < 0
                            ? 0.0
                            : neededTotalQty;

                        String fmtQty(double v) {
                          final agg = _aggregateIngredients(
                            cartItems,
                          )[ingredientName];
                          if (agg != null) {
                            final copy = Map<String, dynamic>.from(agg);
                            copy['totalQty'] = v;
                            copy['unit'] = unit;
                            return _formatCartIngredientNeedLabel(
                              ingredientName,
                              copy,
                              cartItems,
                            );
                          }
                          return IngredientUnitConverter.formatCartNeedLabel(
                            ingredientName: ingredientName,
                            shoppingQty: v,
                            shoppingUnit: unit,
                            recipeQtyByUnit: _recipeQtyByUnitFromCart(
                              cartItems,
                              ingredientName,
                            ),
                          );
                        }

                        final headerBest = pr.bestMatch;
                        final pkgLabel = headerBest != null
                            ? _parseProductAmount(
                                headerBest,
                                '',
                                ingredientName: ingredientName,
                              ).label
                            : '-';
                        final neededStr = fmtQty(neededTotalQty);
                        final recipeBreakdownRows =
                            _getIngredientPerRecipeBreakdown(
                              cartItems,
                              ingredientName,
                            );
                        final recipeThumbUrlsForBar = <String>[];
                        final seenRecipeIdsForBar = <String>{};
                        for (final row in recipeBreakdownRows) {
                          if (recipeThumbUrlsForBar.length >= 3) break;
                          if (row.recipeId.isEmpty ||
                              row.recipeId == 'unknown') {
                            continue;
                          }
                          if (seenRecipeIdsForBar.contains(row.recipeId)) {
                            continue;
                          }
                          seenRecipeIdsForBar.add(row.recipeId);
                          final url = _recipeThumbnailById[row.recipeId];
                          if (url != null && url.isNotEmpty) {
                            recipeThumbUrlsForBar.add(url);
                          }
                        }

                        final marketplaceShort = _marketplaceLabel(
                          _selectedMarketplace,
                        );

                        return Container(
                          width: double.infinity,
                          height: 116,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.95),
                            border: Border.all(
                              color: const Color(0xFFF4F4F5),
                              width: 1,
                            ),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(28),
                              topRight: Radius.circular(28),
                            ),
                          ),
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                top: 0,
                                right: 0,
                                child: Container(
                                  height: 22,
                                  padding: const EdgeInsets.only(top: 6),
                                  alignment: Alignment.topCenter,
                                  child: Container(
                                    width: 38,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE4E4E7),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 28,
                                child: Container(
                                  height: 30,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Transform.translate(
                                              offset: const Offset(0, -2),
                                              child: RichText(
                                                text: TextSpan(
                                                  style: const TextStyle(
                                                    fontFamily: 'Pretendard',
                                                    fontSize: 19,
                                                    fontWeight: FontWeight.w700,
                                                    height: 1,
                                                    letterSpacing: -0.47,
                                                  ),
                                                  children: [
                                                    TextSpan(
                                                      text: '$ingredientName ',
                                                      style: const TextStyle(
                                                        color:
                                                            _cartAccentOrange,
                                                      ),
                                                    ),
                                                    const TextSpan(
                                                      text: '대체상품',
                                                      style: TextStyle(
                                                        color: Color(
                                                          0xFF18181B,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Transform.translate(
                                              // Align pill vertically with the "대체상품" text line
                                              offset: const Offset(0, -2),
                                              child: Container(
                                                height: 26,
                                                padding: const EdgeInsets.only(
                                                  left: 9,
                                                  right: 11,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFFF7F8FA,
                                                  ),
                                                  border: Border.all(
                                                    color: const Color(
                                                      0xFFEDEFF3,
                                                    ),
                                                    width: 1,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    SizedBox(
                                                      width: 17,
                                                      height: 17,
                                                      child: Center(
                                                        child: _marketplaceLogo(
                                                          _selectedMarketplace,
                                                          size: 17,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 5),
                                                    Text(
                                                      marketplaceShort,
                                                      style: const TextStyle(
                                                        fontFamily:
                                                            'Pretendard',
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        height: 1.5,
                                                        letterSpacing: -0.25,
                                                        color: Color(
                                                          0xFF333D4B,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 20,
                                right: 20,
                                top: 68,
                                child: GestureDetector(
                                  onTap: () => _showQuantityDetailPopup(
                                    context: context,
                                    ingredientName: ingredientName,
                                    unit: unit,
                                    recipeTotalQty: recipeTotalQty,
                                    cartItems: cartItems,
                                  ),
                                  child: Container(
                                    height: 30,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF7F8FA),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: const Color(0xFFEDEFF3),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: _buildNeedPackedBarLabels(
                                            neededStr: neededStr,
                                            pkgLabel: pkgLabel,
                                          ),
                                        ),
                                        if (recipeThumbUrlsForBar
                                            .isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          _buildIngredientBarRecipeThumbnails(
                                            recipeThumbUrlsForBar,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    // Products: 선택 상품 → 섹션 제목 → 정렬/필터 → 나머지 상품
                    Expanded(
                      child: Builder(
                        builder: (modalContext) {
                          var selectedAltFilterChip = '전체';
                          var altSortByPrice = false;
                          final neededUnit = pr.neededUnit;

                          void onSelectProduct(
                            CoupangProduct product, {
                            int? rank,
                          }) {
                            final current = liveRec[0];
                            final candidates =
                                _seeMoreProductsForAltSheet(current);
                            final resolvedRank = rank ??
                                candidates.indexWhere(
                                  (p) => p.productId == product.productId,
                                );
                            unawaited(
                              _analyticsService
                                  .trackCartAlternativeProductSelected(
                                ingredientName: ingredientName,
                                marketplace: _marketplaceForAnalytics(
                                  _selectedMarketplace,
                                ),
                                productId: product.productId,
                                price: product.productPrice > 0
                                    ? product.productPrice
                                    : null,
                                rank: resolvedRank >= 0 ? resolvedRank : null,
                                filter: selectedAltFilterChip,
                                sort: altSortByPrice ? 'price' : 'recommend',
                                recipeId: _analyticsRecipeIdForIngredient(
                                  ingredientName,
                                ),
                              ),
                            );
                            final oldBestMatch = current.bestMatch;
                            final seenIds = <String>{product.productId};
                            final newSeeMoreList = <CoupangProduct>[];
                            if (oldBestMatch != null &&
                                !seenIds.contains(oldBestMatch.productId)) {
                              newSeeMoreList.add(oldBestMatch);
                              seenIds.add(oldBestMatch.productId);
                            }
                            for (final p in candidates) {
                              if (!seenIds.contains(p.productId)) {
                                newSeeMoreList.add(p);
                                seenIds.add(p.productId);
                              }
                            }
                            final newRecommendation = ProductRecommendation(
                              ingredient: ingredientName,
                              neededQty: current.neededQty,
                              neededUnit: current.neededUnit,
                              bestMatch: product,
                              seeMoreList: newSeeMoreList,
                              allProducts: current.allProducts,
                            );
                            if (mounted) {
                              setState(() {
                                _productRecommendationCache[_recommendationCacheKey(
                                      _selectedMarketplace,
                                      ingredientName,
                                    )] =
                                    newRecommendation;
                              });
                              Navigator.of(modalContext).pop();
                            }
                          }

                          Future<void> onAdminRemoveProduct(
                            CoupangProduct product,
                          ) async {
                            final shouldRemove = await AppConfirmDialog.show(
                              context: modalContext,
                              title: '이 상품을 전역 제외할까요?',
                              description:
                                  '${product.productName}\n\n재스크래핑 이후에도 노출되지 않아요.',
                              confirmLabel: '제외',
                              destructive: true,
                            );
                            if (shouldRemove != true) return;

                            final success = await _coupangService
                                .excludeProductGloballyForAdmin(
                                  productId: product.productId,
                                  reason: 'admin_removed_from_alt_popup',
                                );

                            if (!mounted) return;
                            if (!success) {
                              _showBottomNotification(
                                const SnackBar(
                                  content: Text(
                                    '상품 제외에 실패했어요. 잠시 후 다시 시도해주세요.',
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                              return;
                            }

                            final key = _recommendationCacheKey(
                              _selectedMarketplace,
                              ingredientName,
                            );
                            final current =
                                _getCachedRecommendation(ingredientName) ??
                                liveRec[0];

                            final filteredSeeMore = current.seeMoreList
                                .where((p) => p.productId != product.productId)
                                .toList();
                            final filteredAll = current.allProducts
                                .where((p) => p.productId != product.productId)
                                .toList();
                            final nextBest =
                                (current.bestMatch != null &&
                                    current.bestMatch!.productId ==
                                        product.productId)
                                ? (filteredSeeMore.isNotEmpty
                                      ? filteredSeeMore.first
                                      : null)
                                : current.bestMatch;

                            final updated = ProductRecommendation(
                              ingredient: current.ingredient,
                              neededQty: current.neededQty,
                              neededUnit: current.neededUnit,
                              bestMatch: nextBest,
                              seeMoreList: filteredSeeMore,
                              allProducts: filteredAll,
                            );

                            liveRec[0] = updated;
                            setState(() {
                              _productRecommendationCache[key] = updated;
                            });

                            final afterList = _seeMoreProductsForAltSheet(
                              updated,
                            );
                            if (afterList.isEmpty) {
                              Navigator.of(modalContext).pop();
                            } else {
                              setSheetState(() {});
                            }
                            _showBottomNotification(
                              const SnackBar(
                                content: Text('상품을 전역 제외했습니다.'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }

                          List<CoupangProduct> buildFilteredSorted() {
                            final baseCandidates = seeMoreProducts
                                .where(
                                  (p) =>
                                      bestMatch == null ||
                                      p.productId != bestMatch.productId,
                                )
                                .toList();
                            var list = selectedAltFilterChip == '전체'
                                ? List<CoupangProduct>.from(baseCandidates)
                                : baseCandidates
                                      .where(
                                        (p) => _altSheetFilterChipKeys(
                                          p,
                                          recipeIngredient: ingredientName,
                                          recipeNeededQty: pr.neededQty,
                                          recipeNeededUnit: pr.neededUnit,
                                        ).contains(selectedAltFilterChip),
                                      )
                                      .toList();

                            if (altSortByPrice) {
                              list.sort((a, b) {
                                final ap = a.productPrice;
                                final bp = b.productPrice;
                                if (ap <= 0 && bp <= 0) {
                                  return a.productId.compareTo(b.productId);
                                }
                                if (ap <= 0) return 1;
                                if (bp <= 0) return -1;
                                final c = ap.compareTo(bp);
                                if (c != 0) return c;
                                return a.productId.compareTo(b.productId);
                              });
                            } else {
                              list.sort((a, b) {
                                final ca = _altSheetEffectiveTagCount(
                                  a,
                                  recipeIngredient: ingredientName,
                                  recipeNeededQty: pr.neededQty,
                                  recipeNeededUnit: pr.neededUnit,
                                );
                                final cb = _altSheetEffectiveTagCount(
                                  b,
                                  recipeIngredient: ingredientName,
                                  recipeNeededQty: pr.neededQty,
                                  recipeNeededUnit: pr.neededUnit,
                                );
                                if (cb != ca) return cb.compareTo(ca);
                                return a.productId.compareTo(b.productId);
                              });
                            }
                            return list;
                          }

                          return StatefulBuilder(
                            builder: (ctx, setModalState) {
                              final baseCandidates = seeMoreProducts
                                  .where(
                                    (p) =>
                                        bestMatch == null ||
                                        p.productId != bestMatch.productId,
                                  )
                                  .toList();
                              final closeAmountPool = baseCandidates
                                  .where(
                                    (p) => _altSheetFilterChipKeys(
                                      p,
                                      recipeIngredient: ingredientName,
                                      recipeNeededQty: pr.neededQty,
                                      recipeNeededUnit: pr.neededUnit,
                                    ).contains('딱 필요한 양'),
                                  )
                                  .toList();
                              final top3Close = _altSheetPickTopCloseAmount(
                                closeAmountPool,
                                ingredientName,
                                pr,
                              );
                              final featuredCloseIds = {
                                for (final p in top3Close) p.productId,
                              };

                              final filtered = buildFilteredSorted()
                                  .where(
                                    (p) =>
                                        !featuredCloseIds.contains(p.productId),
                                  )
                                  .toList();

                              scheduleScrollToAllProductsSection();

                              // Hide until parked on "전체 상품" — no flash of selected product.
                              return IgnorePointer(
                                ignoring: !listRevealed,
                                child: Opacity(
                                opacity: listRevealed ? 1 : 0,
                                child: ListView(
                                controller: altListScrollController,
                                // Build far-down "전체 상품" so open-scroll can find it.
                                cacheExtent: 4000,
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  16 + bottomInset,
                                ),
                                children: [
                                  if (bestMatch != null) ...[
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 3,
                                          height: 15,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF27272A),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        const Text(
                                          '현재 선택된 상품',
                                          style: TextStyle(
                                            fontFamily: 'Pretendard',
                                            color: Color(0xFF18181B),
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            height: 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    _buildCartStyleAltProductCard(
                                      product: bestMatch,
                                      unitPriceStr: _altSheetUnitPriceStr(
                                        bestMatch,
                                        neededUnit,
                                      ),
                                      isSelected: true,
                                      onSelect: null,
                                      isAdmin: isAdminUser,
                                      onAdminRemove: isAdminUser
                                          ? () =>
                                                onAdminRemoveProduct(bestMatch)
                                          : null,
                                      altSheetIngredient: ingredientName,
                                      altSheetNeededQty: pr.neededQty,
                                      altSheetNeededUnit: pr.neededUnit,
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  const SizedBox(height: 8),
                                  if (top3Close.isNotEmpty) ...[
                                    IntrinsicHeight(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Container(
                                            width: 3,
                                            decoration: BoxDecoration(
                                              color: _closeAmountTagColor,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          const Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  '레시피에 딱 필요한 양',
                                                  style: TextStyle(
                                                    fontFamily: 'Pretendard',
                                                    color: Color(0xFF18181B),
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w800,
                                                    height: 1.25,
                                                    letterSpacing: -0.3,
                                                  ),
                                                ),
                                                SizedBox(height: 4),
                                                Text(
                                                  '남기지 않고 바로 쓸 수 있는 상품만 모았어요.',
                                                  style: TextStyle(
                                                    fontFamily: 'Pretendard',
                                                    color: Color(0xFF71717B),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    height: 1.4,
                                                    letterSpacing: -0.2,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    for (
                                      var i = 0;
                                      i < top3Close.length;
                                      i++
                                    ) ...[
                                      _buildCartStyleAltProductCard(
                                        product: top3Close[i],
                                        unitPriceStr: _altSheetUnitPriceStr(
                                          top3Close[i],
                                          neededUnit,
                                        ),
                                        isSelected: false,
                                        onSelect: () => onSelectProduct(
                                          top3Close[i],
                                          rank: i,
                                        ),
                                        isAdmin: isAdminUser,
                                        onAdminRemove: isAdminUser
                                            ? () => onAdminRemoveProduct(
                                                top3Close[i],
                                              )
                                            : null,
                                        altSheetIngredient: ingredientName,
                                        altSheetNeededQty: pr.neededQty,
                                        altSheetNeededUnit: pr.neededUnit,
                                      ),
                                      if (i < top3Close.length - 1)
                                        const SizedBox(height: 12),
                                    ],
                                    const SizedBox(height: 20),
                                  ],
                                  KeyedSubtree(
                                    key: allProductsSectionKey,
                                    child: SizedBox(
                                      height: 22.5,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Container(
                                                width: 3,
                                                height: 18.5,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFF6A00),
                                                  borderRadius:
                                                      BorderRadius.circular(999),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              const Text(
                                                '전체 상품',
                                                style: TextStyle(
                                                  fontFamily: 'Pretendard',
                                                  color: Color(0xFF18181B),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w700,
                                                  height: 1.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                          GestureDetector(
                                            onTap: () {
                                              altSortByPrice = !altSortByPrice;
                                              setModalState(() {});
                                            },
                                            behavior: HitTestBehavior.opaque,
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                const Icon(
                                                  Icons.swap_vert,
                                                  size: 12,
                                                  color: Color(0xFF18181B),
                                                ),
                                                const SizedBox(width: 7),
                                                Text(
                                                  altSortByPrice ? '가격순' : '추천순',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontFamily: 'Pretendard',
                                                    color: Color(0xFF18181B),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    height: 1.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    height: 36,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      physics: const ClampingScrollPhysics(),
                                      child: Row(
                                        children: [
                                          for (final label
                                              in _altSheetFilterChips) ...[
                                            Builder(
                                              builder: (context) {
                                                final selected =
                                                    selectedAltFilterChip ==
                                                        label;
                                                return GestureDetector(
                                                  onTap: () {
                                                    selectedAltFilterChip =
                                                        label;
                                                    setModalState(() {});
                                                  },
                                                  child: AnimatedContainer(
                                                    duration: const Duration(
                                                      milliseconds: 180,
                                                    ),
                                                    curve: Curves.easeOutCubic,
                                                    height: 36,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 14,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      gradient: selected
                                                          ? const LinearGradient(
                                                              begin: Alignment
                                                                  .topLeft,
                                                              end: Alignment
                                                                  .bottomRight,
                                                              colors: [
                                                                Color(
                                                                  0xFFFFF7F2,
                                                                ),
                                                                Color(
                                                                  0xFFFFE8DC,
                                                                ),
                                                              ],
                                                            )
                                                          : null,
                                                      color: selected
                                                          ? null
                                                          : Colors.white,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        999,
                                                      ),
                                                      border: Border.all(
                                                        color: selected
                                                            ? const Color(
                                                                0xFFFF8A55,
                                                              )
                                                            : const Color(
                                                                0xFFE5E5EA,
                                                              ),
                                                        width: selected
                                                            ? 1.2
                                                            : 1,
                                                      ),
                                                      boxShadow: selected
                                                          ? [
                                                              BoxShadow(
                                                                color:
                                                                    _cartAccentOrange
                                                                        .withValues(
                                                                  alpha: 0.18,
                                                                ),
                                                                blurRadius: 10,
                                                                offset:
                                                                    const Offset(
                                                                  0,
                                                                  3,
                                                                ),
                                                              ),
                                                              BoxShadow(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                  alpha: 0.8,
                                                                ),
                                                                blurRadius: 0,
                                                                offset:
                                                                    const Offset(
                                                                  0,
                                                                  -0.5,
                                                                ),
                                                              ),
                                                            ]
                                                          : [
                                                              BoxShadow(
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                  alpha: 0.03,
                                                                ),
                                                                blurRadius: 4,
                                                                offset:
                                                                    const Offset(
                                                                  0,
                                                                  1,
                                                                ),
                                                              ),
                                                            ],
                                                    ),
                                                    alignment: Alignment.center,
                                                    child: Text(
                                                      label,
                                                      style: TextStyle(
                                                        fontFamily:
                                                            'Pretendard',
                                                        fontSize: 12.5,
                                                        fontWeight: selected
                                                            ? FontWeight.w800
                                                            : FontWeight.w700,
                                                        color: selected
                                                            ? _cartAccentOrange
                                                            : const Color(
                                                                0xFF191F28,
                                                              ),
                                                        letterSpacing: -0.25,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  if (filtered.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 24,
                                      ),
                                      child: Center(
                                        child: Text(
                                          selectedAltFilterChip == '전체'
                                              ? '다른 상품이 없습니다'
                                              : '이 태그에 해당하는 상품이 없습니다',
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF71717B),
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    for (
                                      var i = 0;
                                      i < filtered.length;
                                      i++
                                    ) ...[
                                      _buildCartStyleAltProductCard(
                                        product: filtered[i],
                                        unitPriceStr: _altSheetUnitPriceStr(
                                          filtered[i],
                                          neededUnit,
                                        ),
                                        isSelected: false,
                                        onSelect: () => onSelectProduct(
                                          filtered[i],
                                          rank: i,
                                        ),
                                        isAdmin: isAdminUser,
                                        onAdminRemove: isAdminUser
                                            ? () => onAdminRemoveProduct(
                                                filtered[i],
                                              )
                                            : null,
                                        altSheetIngredient: ingredientName,
                                        altSheetNeededQty: pr.neededQty,
                                        altSheetNeededUnit: pr.neededUnit,
                                      ),
                                      if (i < filtered.length - 1)
                                        const SizedBox(height: 12),
                                    ],
                                ],
                              ),
                              ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            );
          },
        );
      },
    );
  }

  Map<String, Map<String, dynamic>> _aggregateIngredients(
    List<dynamic> cartItems,
  ) {
    final Map<String, Map<String, dynamic>> aggregated = {};

    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final ingredients = cartItem['ingredients'] as List? ?? [];

      for (final ingredient in ingredients) {
        final ing = ingredient as Map<String, dynamic>;
        final name = ing['item']?.toString() ?? '';
        if (name.isEmpty) continue;

        final rawQty = ing['qty'];
        final qty = rawQty is num
            ? rawQty.toDouble()
            : (rawQty is String ? double.tryParse(rawQty) : null);
        final unit = ing['unit']?.toString() ?? '';
        if (qty == null || qty <= 0) continue;
        final converted = IngredientUnitConverter.toShoppingUnit(
          ingredientName: name,
          qty: qty,
          unit: unit,
        );
        final normalizedQty = converted.qty;
        final normalizedUnit = converted.unit;

        if (aggregated.containsKey(name)) {
          // Add quantities if units match
          final existing = aggregated[name]!;
          final existingUnit = existing['unit']?.toString() ?? '';
          if (existingUnit == normalizedUnit) {
            final existingQty = existing['totalQty'] as double? ?? 0.0;
            aggregated[name]!['totalQty'] = existingQty + normalizedQty;
            aggregated[name]!['recipeQtyByUnit'] =
                IngredientUnitConverter.mergeRecipeQtyByUnit(
                  _parseRecipeQtyByUnitField(existing['recipeQtyByUnit']),
                  unit,
                  qty,
                );
          } else {
            IngredientConversionGapLedger.report(
              IngredientConversionGap(
                kind: IngredientConversionGapKind.cartAggregationUnitMismatch,
                ingredientName: name,
                recipeUnit: unit,
                shoppingUnit: normalizedUnit,
                detail: 'existingShoppingUnit=$existingUnit',
              ),
            );
          }
        } else {
          aggregated[name] = {
            'totalQty': normalizedQty,
            'unit': normalizedUnit,
            'notes': ing['notes'],
            'category': ing['category'],
            'recipeQtyByUnit': IngredientUnitConverter.mergeRecipeQtyByUnit(
              null,
              unit,
              qty,
            ),
          };
        }
      }
    }

    return aggregated;
  }

  /// Returns the set of ingredient names that belong to the given recipe (from cart items).
  Set<String> _getIngredientNamesForRecipe(
    List<dynamic> cartItems,
    String recipeId,
  ) {
    final Set<String> names = {};
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      if ((cartItem['recipeId']?.toString() ?? '') != recipeId) continue;
      final ingredients = cartItem['ingredients'] as List? ?? [];
      for (final ingredient in ingredients) {
        final ing = ingredient as Map<String, dynamic>;
        final name = ing['item']?.toString() ?? '';
        if (name.isNotEmpty) names.add(name);
      }
    }
    return names;
  }

  /// Per-recipe breakdown for an ingredient: [(recipeId, recipeName, qty, unit), ...], merged by recipeId.
  List<({String recipeId, String recipeName, double qty, String unit})>
  _getIngredientPerRecipeBreakdown(
    List<dynamic> cartItems,
    String ingredientName,
  ) {
    final Map<
      String,
      ({String recipeId, String recipeName, double qty, String unit})
    >
    byRecipe = {};
    for (final item in cartItems) {
      final cartItem = item as Map<String, dynamic>;
      final recipeId = cartItem['recipeId']?.toString() ?? 'unknown';
      final recipeName = cartItem['recipeName']?.toString() ?? '레시피';
      final ingredients = cartItem['ingredients'] as List? ?? [];
      for (final ingredient in ingredients) {
        final ing = ingredient as Map<String, dynamic>;
        final name = ing['item']?.toString() ?? '';
        if (name != ingredientName) continue;
        final rawQty2 = ing['qty'];
        final qty = rawQty2 is num
            ? rawQty2.toDouble()
            : (rawQty2 is String ? double.tryParse(rawQty2) : null);
        final unit = ing['unit']?.toString() ?? '개';
        if (qty != null && qty > 0) {
          final existing = byRecipe[recipeId];
          if (existing != null) {
            byRecipe[recipeId] = (
              recipeId: recipeId,
              recipeName: recipeName,
              qty: existing.qty + qty,
              unit: unit,
            );
          } else {
            byRecipe[recipeId] = (
              recipeId: recipeId,
              recipeName: recipeName,
              qty: qty,
              unit: unit,
            );
          }
          break;
        }
      }
    }
    return byRecipe.values.toList();
  }

  void _showQuantityDetailPopup({
    required BuildContext context,
    required String ingredientName,
    required String unit,
    required double recipeTotalQty,
    required List<dynamic> cartItems,
  }) {
    final breakdown = _getIngredientPerRecipeBreakdown(
      cartItems,
      ingredientName,
    );
    final aggregated = _aggregateIngredients(cartItems)[ingredientName];
    Map<String, double>? recipeQtyByUnit = aggregated != null
        ? _parseRecipeQtyByUnitField(aggregated['recipeQtyByUnit'])
        : null;
    if (recipeQtyByUnit == null || recipeQtyByUnit.isEmpty) {
      final fromCart = _recipeQtyByUnitFromCart(cartItems, ingredientName);
      recipeQtyByUnit = fromCart.isEmpty ? null : fromCart;
    }

    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.32),
      builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: _QuantityDetailPopupContent(
        ingredientName: ingredientName,
        unit: unit,
        recipeTotalQty: recipeTotalQty,
        breakdown: breakdown,
        thumbnailByRecipeId: _recipeThumbnailById,
        platformByRecipeId: _recipePlatformById,
        sourceUrlByRecipeId: _recipeSourceUrlById,
        recipeQtyByUnit: recipeQtyByUnit,
        ),
      ),
    );
  }

  Future<void> _searchProductsForIngredients(
    Map<String, Map<String, dynamic>> ingredients, {
    List<ShoppingMarketplace>? marketplacesToFetch,
    Set<String>? targetCacheKeys,
    bool forceRefresh = false,
    bool manualRetryBoost = false,
  }) async {
    if (!mounted) return;

    final marketplaces =
        marketplacesToFetch ??
        (_selectedMarketplace == ShoppingMarketplace.coupang ||
                _selectedMarketplace == ShoppingMarketplace.marketKurly
            ? [_selectedMarketplace]
            : <ShoppingMarketplace>[]);

    if (marketplaces.isEmpty) {
      if (mounted) {
        setState(() {
          _isSearchingProducts = false;
          _hasCompletedInitialSearch = true;
        });
      }
      return;
    }

    final searchSw = Stopwatch()..start();
    if (kDebugMode) {
      print('[CartScreen] _searchProductsForIngredients() called');
      print('[CartScreen]   - Total ingredients: ${ingredients.length}');
      print(
        '[CartScreen]   - Marketplaces: ${marketplaces.map((m) => m.name).toList()}',
      );
      print('[CartScreen]   - manualRetryBoost: $manualRetryBoost');
    }
    print(
      '[PERF][cart_search] start ingredients=${ingredients.length} '
      'markets=${marketplaces.map((m) => m.name).toList()} '
      'forceRefresh=$forceRefresh manualRetryBoost=$manualRetryBoost',
    );

    setState(() {
      _isSearchingProducts = true;
      _productSearchFailed = false;
      _productSearchFailureMessage = '';
    });

    final categoryOrder = IngredientCategoryUnifier.groupOrder
        .map(IngredientCategoryUnifier.titleFromKey)
        .toList();
    final Map<String, Map<String, Map<String, dynamic>>> categorized = {};
    for (final c in categoryOrder) {
      categorized[c] = {};
    }
    for (final entry in ingredients.entries) {
      final name = entry.key;
      final data = entry.value;
      final cat = _categorizeIngredient(name, data['category']?.toString());
      categorized[cat]![name] = data;
    }
    final List<String> orderedNames = [];
    for (final cat in categoryOrder) {
      for (final name in categorized[cat]!.keys) {
        if (!_purchasedIngredientKeys.contains(name)) orderedNames.add(name);
      }
    }
    for (final cat in categoryOrder) {
      for (final name in categorized[cat]!.keys) {
        if (_purchasedIngredientKeys.contains(name)) orderedNames.add(name);
      }
    }

    bool timedOutAny = false;

    // Collect pending tasks that actually need a fetch.
    final pending = <_RecommendationFetchTask>[];
    for (final marketplace in marketplaces) {
      final marketplaceStr = marketplace == ShoppingMarketplace.marketKurly
          ? 'kurly'
          : 'coupang';
      for (final ingredientName in orderedNames) {
        final ingredientData = ingredients[ingredientName]!;
        final totalQty = (ingredientData['totalQty'] as double?) ?? 0.0;
        final unit = ingredientData['unit']?.toString();
        final cacheKey = _recommendationCacheKey(marketplace, ingredientName);
        if (targetCacheKeys != null && !targetCacheKeys.contains(cacheKey)) {
          continue;
        }
        final cached = _productRecommendationCache[cacheKey];
        if (!forceRefresh &&
            cached != null &&
            cached.neededQty == totalQty &&
            cached.neededUnit == unit &&
            cached.bestMatch != null) {
          continue;
        }
        pending.add(
          _RecommendationFetchTask(
            marketplace: marketplace,
            marketplaceStr: marketplaceStr,
            ingredientName: ingredientName,
            ingredientData: ingredientData,
            totalQty: totalQty,
            unit: unit,
            cacheKey: cacheKey,
          ),
        );
      }
    }

    // Batch preprocess all Coupang ingredient names in one Gemini call.
    // 수동 재시도(boost)는 캐시를 비운 뒤라 여기서 재전처리되어 대체 쿼리가 생긴다.
    final needsPreprocess = <String>{};
    for (final task in pending) {
      if (task.marketplaceStr == 'kurly' && !manualRetryBoost) continue;
      if (_preprocessedNameCache.containsKey(task.ingredientName)) continue;
      needsPreprocess.add(task.ingredientName);
    }
    var preprocessMs = 0;
    if (needsPreprocess.isNotEmpty) {
      final preSw = Stopwatch()..start();
      try {
        if (kDebugMode) {
          print(
            '[CartScreen] Batch preprocessing ${needsPreprocess.length} ingredients',
          );
        }
        final batch = await _coupangService
            .preprocessIngredients(needsPreprocess.toList(growable: false))
            .timeout(_productSearchTimeout);
        if (!mounted) return;
        batch.forEach((original, simplified) {
          final value = simplified.isNotEmpty ? simplified : original;
          _preprocessedNameCache[original] = value;
        });
        for (final name in needsPreprocess) {
          _preprocessedNameCache.putIfAbsent(name, () => name);
        }
      } on TimeoutException {
        timedOutAny = true;
        for (final name in needsPreprocess) {
          _preprocessedNameCache.putIfAbsent(name, () => name);
        }
      } catch (e) {
        if (kDebugMode) {
          print('[CartScreen] Batch preprocess failed: $e');
        }
        for (final name in needsPreprocess) {
          _preprocessedNameCache.putIfAbsent(name, () => name);
        }
      }
      preprocessMs = preSw.elapsedMilliseconds;
      print(
        '[PERF][cart_search] preprocess_ms=$preprocessMs '
        'n=${needsPreprocess.length}',
      );
    } else {
      print('[PERF][cart_search] preprocess_ms=0 n=0 (cache_hit_or_kurly_only)');
    }

    if (pending.isEmpty) {
      if (mounted) {
        setState(() {
          for (final ingredientName in orderedNames) {
            _ingredientLoadingStates[ingredientName] = false;
          }
          _isSearchingProducts = false;
          _hasCompletedInitialSearch = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        for (final task in pending) {
          _ingredientLoadingStates[task.ingredientName] = true;
        }
      });
    }

    bool cacheDirty = false;

    // Streaming: single HTTP connection (NDJSON), each item is applied to the
    // UI the instant the backend finishes it — no waiting on chunk/batch
    // siblings like the old progressive-chunk approach.
    Map<String, dynamic> _streamItemFor(
      _RecommendationFetchTask task,
      String queryName,
    ) {
      return <String, dynamic>{
        'ingredient_name': queryName,
        'original_ingredient_name': task.ingredientName,
        'needed_qty': task.totalQty,
        'needed_unit': (task.unit ?? '').trim(),
        'limit': 10,
        'marketplace': task.marketplaceStr,
      };
    }

    final pendingWithItems =
        <({_RecommendationFetchTask task, Map<String, dynamic> item})>[];
    for (final task in pending) {
      if (!manualRetryBoost) {
        pendingWithItems.add((
          task: task,
          item: _streamItemFor(
            task,
            task.marketplaceStr == 'kurly'
                ? task.ingredientName
                : (_preprocessedNameCache[task.ingredientName] ??
                    task.ingredientName),
          ),
        ));
        continue;
      }

      // 수동 재시도: 같은 cacheKey에 대해 여러 쿼리 후보를 보내고
      // bestMatch 가 하나라도 나오면 성공으로 채택한다.
      final queryCandidates = <String>[];
      void addQuery(String? q) {
        final trimmed = q?.trim() ?? '';
        if (trimmed.isEmpty) return;
        if (queryCandidates.any((e) => e == trimmed)) return;
        queryCandidates.add(trimmed);
      }

      addQuery(task.ingredientName);
      addQuery(_preprocessedNameCache[task.ingredientName]);
      addQuery(_retryAlternateIngredientName(task.ingredientName));
      addQuery(
        _retryAlternateIngredientName(
          _preprocessedNameCache[task.ingredientName] ?? '',
        ),
      );

      if (queryCandidates.isEmpty) {
        addQuery(task.ingredientName);
      }
      if (kDebugMode) {
        print(
          '[CartScreen] retry boost queries '
          '${task.marketplaceStr}/${task.ingredientName}: $queryCandidates',
        );
      }
      for (final query in queryCandidates) {
        pendingWithItems.add((
          task: task,
          item: _streamItemFor(task, query),
        ));
      }
    }

    final streamItems = [for (final entry in pendingWithItems) entry.item];

    if (kDebugMode) {
      print(
        '[CartScreen] recommend_products_stream: ${pendingWithItems.length} items',
      );
    }

    void applyStreamResult(int index, ProductRecommendation? recommendation) {
      if (!mounted) return;
      if (index < 0 || index >= pendingWithItems.length) return;
      final task = pendingWithItems[index].task;

      setState(() {
        if (recommendation != null) {
          final picked = _applyRecommendedPick(
            recommendation,
            marketplace: task.marketplace,
          );
          final existing = _productRecommendationCache[task.cacheKey];
          // boost 시 여러 쿼리 중 하나라도 bestMatch 가 있으면 유지
          if (picked.bestMatch != null || existing?.bestMatch == null) {
            _productRecommendationCache[task.cacheKey] = picked;
            cacheDirty = true;
          }
        }
        final hasBestMatch =
            _productRecommendationCache[task.cacheKey]?.bestMatch != null;
        if (hasBestMatch) {
          _missingRecommendationKeys.remove(task.cacheKey);
        } else {
          _missingRecommendationKeys.add(task.cacheKey);
        }
        _lastRequestedSignatureByCacheKey[task.cacheKey] =
            _ingredientSearchSignature(task.ingredientData);
        _ingredientLoadingStates[task.ingredientName] = false;
      });
      if (recommendation?.bestMatch != null) {
        _scheduleRecommendationCacheSave();
      }
    }

    final receivedIndices = <int>{};
    final batchWallSw = Stopwatch()..start();
    try {
      await for (final entry in _coupangService
          .getProductRecommendationsStream(items: streamItems)
          .timeout(_productSearchStreamTimeout)) {
        receivedIndices.add(entry.key);
        applyStreamResult(entry.key, entry.value);
      }
    } on TimeoutException {
      timedOutAny = true;
      if (kDebugMode) {
        print('[CartScreen] recommend_products_stream timed out');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[CartScreen] recommend_products_stream failed: $e');
      }
    }

    // Anything the backend never emitted (dropped connection, crash, client
    // timeout, etc.) must still resolve out of the loading state.
    if (receivedIndices.length != pendingWithItems.length) {
      timedOutAny = true;
      for (var i = 0; i < pendingWithItems.length; i++) {
        if (!receivedIndices.contains(i)) {
          applyStreamResult(i, null);
        }
      }
    }

    final batchWallMs = batchWallSw.elapsedMilliseconds;
    print(
      '[PERF][cart_search] stream_wall_ms=$batchWallMs '
      'pending=${pendingWithItems.length} received=${receivedIndices.length} '
      'preprocess_ms=$preprocessMs total_ms=${searchSw.elapsedMilliseconds}',
    );

    if (!mounted) return;

    if (cacheDirty) {
      _scheduleRecommendationCacheSave();
    }

    bool hasAnyRecommendation = false;
    // 단일 재료 수동 재시도 시 orderedNames 만 보면 나머지 성공 재료를
    // 무시하고 전역 실패 배너가 떠버린다 → 장바구니 전체 캐시 기준으로 판단.
    final namesForSuccessCheck = manualRetryBoost
        ? _lastAggregatedIngredientsForRetry.keys
        : orderedNames;
    for (final marketplace in marketplaces) {
      for (final ingredientName in namesForSuccessCheck) {
        final cacheKey = _recommendationCacheKey(marketplace, ingredientName);
        final cached = _productRecommendationCache[cacheKey];
        if (cached?.bestMatch != null) {
          hasAnyRecommendation = true;
          break;
        }
      }
      if (hasAnyRecommendation) {
        break;
      }
    }

    if (mounted) {
      setState(() {
        for (final ingredientName in orderedNames) {
          _ingredientLoadingStates[ingredientName] = false;
        }
        _isSearchingProducts = false;
        _hasCompletedInitialSearch = true;
        if (manualRetryBoost) {
          // 한 재료 재시도 실패로 전역 배너를 켜지 않는다.
          if (hasAnyRecommendation && !timedOutAny) {
            _productSearchFailed = false;
            _productSearchFailureMessage = '';
          } else if (timedOutAny) {
            _productSearchFailed = true;
            _productSearchFailureMessage =
                '일부 재료 검색 시간이 초과되었어요. 다시 시도해주세요.';
          }
        } else {
          _productSearchFailed = timedOutAny || !hasAnyRecommendation;
          if (_productSearchFailed) {
            _productSearchFailureMessage = timedOutAny
                ? '일부 재료 검색 시간이 초과되었어요. 다시 시도해주세요.'
                : '추천 가능한 상품을 찾지 못했어요. 다시 시도해주세요.';
          } else {
            _productSearchFailureMessage = '';
          }
        }
      });
    }
  }

  /// 장바구니 상품 버튼. 쿠팡만 AFFSDP+subparam을 맨 앞에 둔다.
  Future<void> _openRecommendedProductLink({
    required CoupangProduct bestMatch,
    required ShoppingMarketplace marketplace,
    required String ingredientName,
  }) async {
    final deeplink = (bestMatch.deeplinkUrl ?? '').trim();
    final product = bestMatch.productUrl.trim();
    final original = (bestMatch.originalUrl ?? '').trim();

    List<String> candidates;
    if (marketplace == ShoppingMarketplace.coupang) {
      final subparam = await _userService.getCurrentCoupangSubparam();
      if (!mounted) return;
      candidates = coupangOpenUrlCandidates(
        landingUrl: bestMatch.landingUrl,
        deeplinkUrl: deeplink,
        productUrl: product,
        originalUrl: original,
        subparam: subparam,
      );
    } else {
      // 컬리/오아시스는 기존 단축 → productUrl → original 순서를 유지.
      candidates = <String>[
        if (deeplink.isNotEmpty) deeplink,
        if (product.isNotEmpty) product,
        if (original.isNotEmpty) original,
      ];
    }

    if (candidates.isEmpty) {
      _showBottomNotification(
        const SnackBar(
          content: Text('유효하지 않은 링크입니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final recipeId = _analyticsRecipeIdForIngredient(ingredientName);
    unawaited(
      _analyticsService.trackCartProductBuyClicked(
        ingredientName: ingredientName,
        marketplace: _marketplaceForAnalytics(marketplace),
        productId: bestMatch.productId,
        productName: bestMatch.productName,
        recipeId: recipeId,
        price: bestMatch.productPrice > 0 ? bestMatch.productPrice : null,
        source: 'main_card',
      ),
    );
    unawaited(
      _analyticsService.logCardEvent(
        'click',
        screen: 'cart',
        sectionId: 'ingredient_product_list',
        cardId: bestMatch.productId,
        contentType: 'product',
        marketplace: _marketplaceForAnalytics(marketplace),
        productId: bestMatch.productId,
        recipeId: recipeId,
        ingredientName: ingredientName,
        price: bestMatch.productPrice > 0 ? bestMatch.productPrice : null,
        productRating: bestMatch.rating,
        productReviewCount: bestMatch.reviews,
        productBayesianRating: bestMatch.bayesianRating,
        productValueScore: bestMatch.valueScore,
        productIsRocket: bestMatch.isRocket,
        productIsFreeShipping: bestMatch.isFreeShipping,
        productDiscountRate: bestMatch.discountRate,
        productUnitPrice: bestMatch.unitPrice,
        productPackageSize: bestMatch.packageSize,
        productPackageUnit: bestMatch.packageUnit,
        productSalesRank: bestMatch.salesRank,
      ),
    );
    await _openCoupangLink(
      candidates.first,
      marketplace: marketplace,
      fallbackUrls: candidates.skip(1).toList(),
      ingredientName: ingredientName,
      productId: bestMatch.productId,
      recipeId: recipeId,
    );
  }

  Future<void> _openCoupangLink(
    String url, {
    ShoppingMarketplace marketplace = ShoppingMarketplace.coupang,
    List<String> fallbackUrls = const [],
    String? ingredientName,
    String? productId,
    String? recipeId,
  }) async {
    final launchTargets = <String>[];
    final seen = <String>{};
    for (final candidate in <String>[url, ...fallbackUrls]) {
      final normalized = candidate.trim();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized)) {
        launchTargets.add(normalized);
      }
    }

    if (kDebugMode) {
      print(
        'Attempting to open marketplace link: marketplace=$marketplace launchTargets=$launchTargets',
      );
    }

    final marketplaceName = _marketplaceForAnalytics(marketplace);

    void trackOpenResult({
      required bool success,
      String? failureReason,
    }) {
      unawaited(_analyticsService.trackAffiliateOpenResult(
        marketplace: marketplaceName,
        success: success,
        productId: productId,
        ingredientName: ingredientName,
        recipeId: recipeId,
        sourceScreen: 'cart',
        failureReason: failureReason,
        platform: _openPlatformAnalyticsName(),
      ));
    }

    if (launchTargets.isEmpty) {
      unawaited(_analyticsService.trackAffiliateLinkClicked(
        marketplace: marketplaceName,
        ingredientName: ingredientName,
        recipeId: recipeId,
        productId: productId,
        sourceScreen: 'cart',
      ));
      trackOpenResult(success: false, failureReason: 'empty_url');
      _showBottomNotification(
        const SnackBar(
          content: Text('유효하지 않은 링크입니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (marketplace == ShoppingMarketplace.coupang ||
        marketplace == ShoppingMarketplace.marketKurly) {
      unawaited(
        _userService.logAffiliateVisit(
          marketplace: marketplaceName,
          sourceScreen: 'cart',
          productId: productId,
          ingredientName: ingredientName,
        ),
      );
    }

    // 클릭 이벤트는 여기서 1회만. Android 경유 openMarketplaceLink는 alreadyTracked.
    unawaited(_analyticsService.trackAffiliateLinkClicked(
      marketplace: marketplaceName,
      ingredientName: ingredientName,
      recipeId: recipeId,
      productId: productId,
      sourceScreen: 'cart',
    ));

    if (marketplace == ShoppingMarketplace.coupang) {
      String? commissionWebUrl;
      for (final launchTarget in launchTargets) {
        String finalUrl = launchTarget.trim();
        if (finalUrl.isEmpty) continue;
        final hasScheme = RegExp(
          r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
        ).hasMatch(finalUrl);
        if (!hasScheme &&
            !finalUrl.startsWith('http://') &&
            !finalUrl.startsWith('https://')) {
          finalUrl = 'https://$finalUrl';
        }
        if (finalUrl.startsWith('http://') || finalUrl.startsWith('https://')) {
          commissionWebUrl = finalUrl;
          break;
        }
      }

      if (commissionWebUrl == null || commissionWebUrl.isEmpty) {
        trackOpenResult(success: false, failureReason: 'invalid_coupang_url');
        _showBottomNotification(
          const SnackBar(
            content: Text('유효하지 않은 쿠팡 링크입니다'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      try {
        final uri = Uri.parse(commissionWebUrl);
        await _launchCoupangInAppBrowserWithAutoClose(context, uri);
        trackOpenResult(success: true);
      } catch (e) {
        if (kDebugMode) {
          print('Error opening Coupang commission url in-app: $e');
        }
        trackOpenResult(
          success: false,
          failureReason: 'coupang_in_app_browser_error',
        );
        _showBottomNotification(
          SnackBar(content: Text('링크 열기 오류: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    try {
      final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      final isAndroid =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      final isCoupangMarketplace = marketplace == ShoppingMarketplace.coupang;

      // Android path: HTTPS → Chrome Custom Tabs (Kurly lounge links fail in WebView).
      if (isAndroid) {
        String? deepLinkUrl;
        String? httpsUrl;
        for (final launchTarget in launchTargets) {
          String finalUrl = launchTarget;
          final hasScheme = RegExp(
            r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
          ).hasMatch(launchTarget);
          if (!hasScheme &&
              !launchTarget.startsWith('http://') &&
              !launchTarget.startsWith('https://')) {
            finalUrl = 'https://$launchTarget';
          }

          final isHttps =
              finalUrl.startsWith('http://') || finalUrl.startsWith('https://');
          if (isHttps) {
            httpsUrl ??= finalUrl;
          } else {
            deepLinkUrl ??= finalUrl;
          }
        }

        final bestUrl = deepLinkUrl ?? httpsUrl;
        if (bestUrl == null) {
          trackOpenResult(success: false, failureReason: 'empty_url');
          _showBottomNotification(
            const SnackBar(
              content: Text('유효하지 않은 링크입니다'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }

        if (!mounted) return;
        await openMarketplaceLink(
          context,
          deepLinkUrl: deepLinkUrl,
          httpsUrl: httpsUrl,
          marketplace: marketplace,
          ingredientName: ingredientName,
          recipeId: recipeId,
          productId: productId,
          sourceScreen: 'cart',
          alreadyTracked: true,
        );
        return;
      }

      final launchModes = <LaunchMode>[
        if (kIsWeb)
          LaunchMode.platformDefault
        else if (isCoupangMarketplace && (isIos || isAndroid)) ...[
          // Prefer direct app handoff with affiliate URL if the platform can route it.
          LaunchMode.externalNonBrowserApplication,
          LaunchMode.externalApplication,
          LaunchMode.inAppBrowserView,
        ] else
          LaunchMode.inAppBrowserView,
      ];

      List<Uri> iosCoupangProductSchemeUris = const [];
      Uri? iosCoupangProductUniversalUri;
      if (isIos && isCoupangMarketplace) {
        iosCoupangProductUniversalUri = _buildIosCoupangProductUniversalUri(
          launchTargets,
        );
        iosCoupangProductSchemeUris = _buildIosCoupangProductSchemeUris(
          launchTargets,
        );
      }

      for (final launchTarget in launchTargets) {
        if (launchTarget.startsWith('intent://')) {
          final launched = await _launchIntentUriNative(launchTarget);
          if (launched) {
            trackOpenResult(success: true);
            return;
          }
          continue;
        }

        // Ensure URL has proper scheme (do not override custom schemes like coupang://)
        String finalUrl = launchTarget;
        final hasExplicitScheme = RegExp(
          r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
        ).hasMatch(launchTarget);
        if (!hasExplicitScheme &&
            !launchTarget.startsWith('http://') &&
            !launchTarget.startsWith('https://')) {
          finalUrl = 'https://$launchTarget';
        }

        final uri = Uri.parse(finalUrl);
        if (kDebugMode) {
          print('Parsed URI: $uri');
        }

        if (isIos && isCoupangMarketplace) {
          // iOS Coupang: try canonical product universal link first.
          if (iosCoupangProductUniversalUri != null) {
            try {
              final universalLaunched = await launchUrl(
                iosCoupangProductUniversalUri,
                mode: LaunchMode.externalNonBrowserApplication,
              );
              if (kDebugMode) {
                print(
                  'iOS product universal link launched=$universalLaunched uri=$iosCoupangProductUniversalUri',
                );
              }
              if (universalLaunched) {
                trackOpenResult(success: true);
                return;
              }
            } catch (e) {
              if (kDebugMode) {
                print('iOS product universal link failed: $e');
              }
            } finally {
              // Do not retry same product URL for each fallback URL.
              iosCoupangProductUniversalUri = null;
            }
          }

          // iOS Coupang: try product-specific scheme variants.
          if (iosCoupangProductSchemeUris.isNotEmpty) {
            for (final schemeUri in iosCoupangProductSchemeUris) {
              try {
                final canLaunchScheme = await canLaunchUrl(schemeUri);
                if (kDebugMode) {
                  print(
                    'iOS product scheme canLaunch=$canLaunchScheme uri=$schemeUri',
                  );
                }
                if (canLaunchScheme) {
                  final schemeLaunched = await launchUrl(
                    schemeUri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (kDebugMode) {
                    print('iOS product scheme launched=$schemeLaunched');
                  }
                  if (schemeLaunched) {
                    trackOpenResult(success: true);
                    return;
                  }
                }
              } catch (e) {
                if (kDebugMode) {
                  print('iOS product scheme failed: $e');
                }
              }
            }
            // Do not retry same schemes for each fallback URL.
            iosCoupangProductSchemeUris = const [];
          }

          // Fall back to universal-link style launch only if scheme launch fails.
          try {
            final directLaunched = await launchUrl(
              uri,
              mode: LaunchMode.externalNonBrowserApplication,
            );
            if (kDebugMode) {
              print('Universal Link attempt: launched=$directLaunched');
            }
            if (directLaunched) {
              trackOpenResult(success: true);
              return;
            }
          } catch (e) {
            if (kDebugMode) {
              print('Universal Link failed (expected if app not installed): $e');
            }
          }
        }

        // Check if URL can be launched
        final canLaunch = await canLaunchUrl(uri);
        if (kDebugMode) {
          print('Can launch URL: $canLaunch');
        }
        if (!canLaunch) {
          continue;
        }

        for (final mode in launchModes) {
          final launched = await launchUrl(uri, mode: mode);
          if (kDebugMode) {
            print(
              'URL launch attempt: launched=$launched (target: $launchTarget, mode: $mode)',
            );
          }
          if (launched) {
            trackOpenResult(success: true);
            return;
          }
        }
      }

      trackOpenResult(success: false, failureReason: 'all_launch_attempts_failed');
      _showBottomNotification(
        const SnackBar(
          content: Text('링크를 열 수 없습니다'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error opening Coupang link: $e');
        print('Stack trace: $stackTrace');
      }
      trackOpenResult(success: false, failureReason: 'open_exception');
      _showBottomNotification(
        SnackBar(content: Text('링크 열기 오류: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<bool> _launchIntentUriNative(String intentUrl) async {
    try {
      final launched = await _nativeShareChannel.invokeMethod<bool>(
        'launchIntentUri',
        {'intentUri': intentUrl},
      );
      return launched ?? false;
    } catch (e, st) {
      if (kDebugMode) {
        print('[IntentNative] launch failed: $e');
        print(st);
      }
      return false;
    }
  }

  List<Uri> _buildIosCoupangProductSchemeUris(List<String> launchTargets) {
    final parsed = _extractCoupangProductParams(launchTargets);
    final pageKey = parsed['pageKey'] ?? '';
    if (pageKey.isEmpty) return const [];

    final queryParams = <String, String>{};
    for (final key in ['itemId', 'vendorItemId', 'lptag', 'traceid', 'subId']) {
      final value = parsed[key] ?? '';
      if (value.isNotEmpty) {
        queryParams[key] = value;
      }
    }

    final uris = <Uri>[];
    final seen = <String>{};

    void addUri(Uri uri) {
      final key = uri.toString();
      if (seen.add(key)) {
        uris.add(uri);
      }
    }

    final canonicalUniversal = _buildIosCoupangProductUniversalUri(launchTargets);
    if (canonicalUniversal != null) {
      addUri(
        Uri(
          scheme: 'coupang',
          host: 'open',
          queryParameters: <String, String>{
            'url': canonicalUniversal.toString(),
          },
        ),
      );
    }

    addUri(
      Uri(
        scheme: 'coupang',
        host: 'vp',
        path: '/products/$pageKey',
        queryParameters: queryParams.isEmpty ? null : queryParams,
      ),
    );

    addUri(
      Uri(
        scheme: 'coupang',
        host: 'products',
        path: '/$pageKey',
        queryParameters: queryParams.isEmpty ? null : queryParams,
      ),
    );

    return uris;
  }

  Uri? _buildIosCoupangProductUniversalUri(List<String> launchTargets) {
    final parsed = _extractCoupangProductParams(launchTargets);
    final pageKey = parsed['pageKey'] ?? '';
    if (pageKey.isEmpty) {
      return null;
    }

    final queryParams = <String, String>{};
    for (final key in ['itemId', 'vendorItemId', 'lptag', 'traceid', 'subId']) {
      final value = parsed[key] ?? '';
      if (value.isNotEmpty) {
        queryParams[key] = value;
      }
    }

    return Uri(
      scheme: 'https',
      host: 'www.coupang.com',
      path: '/vp/products/$pageKey',
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
  }

  Map<String, String> _extractCoupangProductParams(List<String> launchTargets) {
    String? pageKey;
    String? itemId;
    String? vendorItemId;
    String? lptag;
    String? traceid;
    String? subId;

    for (final raw in launchTargets) {
      Uri uri;
      try {
        uri = Uri.parse(raw.trim());
      } catch (_) {
        continue;
      }

      final query = uri.queryParameters;
      final pathSegments = uri.pathSegments;
      final productsIndex = pathSegments.indexOf('products');

      if ((pageKey == null || pageKey.isEmpty) &&
          productsIndex >= 0 &&
          productsIndex + 1 < pathSegments.length) {
        final candidate = pathSegments[productsIndex + 1].trim();
        if (candidate.isNotEmpty) pageKey = candidate;
      }

      final pageKeyFromQuery = (query['pageKey'] ?? '').trim();
      if ((pageKey == null || pageKey.isEmpty) && pageKeyFromQuery.isNotEmpty) {
        pageKey = pageKeyFromQuery;
      }

      final itemIdCandidate = (query['itemId'] ?? '').trim();
      if ((itemId == null || itemId.isEmpty) && itemIdCandidate.isNotEmpty) {
        itemId = itemIdCandidate;
      }

      final vendorItemIdCandidate = (query['vendorItemId'] ?? '').trim();
      if ((vendorItemId == null || vendorItemId.isEmpty) &&
          vendorItemIdCandidate.isNotEmpty) {
        vendorItemId = vendorItemIdCandidate;
      }

      final lptagCandidate = (query['lptag'] ?? '').trim();
      if ((lptag == null || lptag.isEmpty) && lptagCandidate.isNotEmpty) {
        lptag = lptagCandidate;
      }

      final traceidCandidate = (query['traceid'] ?? '').trim();
      if ((traceid == null || traceid.isEmpty) && traceidCandidate.isNotEmpty) {
        traceid = traceidCandidate;
      }

      final subIdCandidate = (query['subId'] ?? query['subid'] ?? '').trim();
      if ((subId == null || subId.isEmpty) && subIdCandidate.isNotEmpty) {
        subId = subIdCandidate;
      }
    }

    return <String, String>{
      'pageKey': pageKey ?? '',
      'itemId': itemId ?? '',
      'vendorItemId': vendorItemId ?? '',
      'lptag': lptag ?? '',
      'traceid': traceid ?? '',
      'subId': subId ?? '',
    };
  }
}

/// Android-only transition screen:
/// - If a deep link is available → shows transition, opens native app directly
/// - If only HTTPS URL → opens Chrome Custom Tab immediately
/// - When user returns → auto-pops back to cart
class _MarketplaceTransitionScreen extends StatefulWidget {
  const _MarketplaceTransitionScreen({
    this.deepLinkUrl,
    this.httpsUrl,
    required this.marketplace,
  });

  final String? deepLinkUrl;
  final String? httpsUrl;
  final ShoppingMarketplace marketplace;

  @override
  State<_MarketplaceTransitionScreen> createState() =>
      _MarketplaceTransitionScreenState();
}

class _MarketplaceTransitionScreenState
    extends State<_MarketplaceTransitionScreen> with WidgetsBindingObserver {
  WebViewController? _wvc;
  bool _nativeLaunched = false;
  bool _wentToBackground = false;
  bool _hasResumed = false;
  bool _webViewReady = false;
  bool _useWebView = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _launch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _wentToBackground = true;
    }
    // Pop back to cart on return — whether native launch was tracked or not
    if (state == AppLifecycleState.resumed &&
        _wentToBackground &&
        mounted &&
        !_hasResumed) {
      _hasResumed = true;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _launch() async {
    // Deep link available → launch native app directly (no WebView)
    if (widget.deepLinkUrl != null) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      try {
        final ok = await launchUrl(
          Uri.parse(widget.deepLinkUrl!),
          mode: LaunchMode.externalNonBrowserApplication,
        );
        if (ok) {
          _nativeLaunched = true;
          return;
        }
      } catch (_) {}
      // Deep link failed — fall through to HTTPS WebView if available
    }

    // HTTPS link → load in hidden WebView with JS interception
    if (widget.httpsUrl != null) {
      _useWebView = true;
      _initWebViewForHttps(widget.httpsUrl!);
      if (mounted) setState(() {});
      return;
    }

    // Nothing available
    if (mounted) Navigator.of(context).pop();
  }

  void _initWebViewForHttps(String url) {
    const chromeUA =
        'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/125.0.6422.113 Mobile Safari/537.36';

    _wvc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(chromeUA)
      ..addJavaScriptChannel('NativeLink', onMessageReceived: (msg) {
        _onDeepLinkDetected(msg.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final reqUrl = request.url;
          if (_isNativeScheme(reqUrl)) {
            _onDeepLinkDetected(reqUrl);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (_) => _onPageLoaded(),
      ))
      ..loadRequest(Uri.parse(url));
  }

  bool _isNativeScheme(String url) {
    return url.startsWith('intent://') ||
        url.startsWith('coupang://') ||
        url.startsWith('kurly://') ||
        url.startsWith('oasismarket://');
  }

  Uri? _parseIntent(String url) {
    if (!url.startsWith('intent://')) return null;
    final hashIdx = url.indexOf('#Intent;');
    if (hashIdx < 0) return null;
    final path = url.substring('intent://'.length, hashIdx);
    final params = url.substring(hashIdx + '#Intent;'.length);
    String? scheme;
    for (final part in params.split(';')) {
      if (part.startsWith('scheme=')) {
        scheme = part.substring('scheme='.length);
        break;
      }
    }
    if (scheme == null || scheme.isEmpty) return null;
    return Uri.tryParse('$scheme://$path');
  }

  Future<void> _onDeepLinkDetected(String url) async {
    if (_nativeLaunched) return;

    Uri? targetUri;
    if (url.startsWith('intent://')) {
      targetUri = _parseIntent(url);
    } else {
      targetUri = Uri.tryParse(url);
    }
    if (targetUri == null) return;
    if (kDebugMode) print('[Transition] native launch: $targetUri');

    // Clear WebView to free memory before going to background
    _wvc?.loadRequest(Uri.parse('about:blank'));

    try {
      final ok = await launchUrl(
        targetUri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (ok) {
        _nativeLaunched = true;
        return;
      }
    } catch (_) {}

    // Native app not installed — show WebView
    if (mounted && !_webViewReady) {
      setState(() => _webViewReady = true);
    }
  }

  void _onPageLoaded() {
    if (_nativeLaunched) return;

    // Inject JS that:
    // 1. Catches iframe/link deep link redirects
    // 2. Finds and clicks "앱 열기" / "앱에서 보기" buttons on the page
    _wvc?.runJavaScript(r'''
(function() {
  var sent = false;
  function send(url) {
    if (sent) return;
    sent = true;
    NativeLink.postMessage(url);
  }
  function check(url) {
    if (!url) return;
    if (url.indexOf('intent://') === 0 || url.indexOf('coupang://') === 0 ||
        url.indexOf('kurly://') === 0 || url.indexOf('oasismarket://') === 0) {
      send(url);
    }
  }

  // Scan existing iframes
  document.querySelectorAll('iframe').forEach(function(f) { check(f.src); });

  // Watch for new iframes
  new MutationObserver(function(muts) {
    muts.forEach(function(m) {
      m.addedNodes.forEach(function(n) {
        if (n.tagName === 'IFRAME') check(n.src);
        if (n.querySelectorAll) {
          n.querySelectorAll('iframe').forEach(function(f) { check(f.src); });
        }
      });
    });
  }).observe(document.documentElement, { childList: true, subtree: true });

  // Intercept link clicks
  document.addEventListener('click', function(e) {
    var t = e.target;
    while (t && t.tagName !== 'A') t = t.parentElement;
    if (t && t.href) check(t.href);
  }, true);

  // Find and click "앱 열기" / "앱에서 보기" / "Open App" buttons/banners
  setTimeout(function() {
    var selectors = [
      'a[href*="intent://"]',
      'a[href*="coupang://"]',
      '[class*="app-open"]',
      '[class*="appOpen"]',
      '[class*="open-app"]',
      '[class*="smart-banner"]',
      '[class*="smartbanner"]',
      '[id*="app-open"]',
      '[id*="appOpen"]',
    ];
    for (var i = 0; i < selectors.length; i++) {
      var el = document.querySelector(selectors[i]);
      if (el) {
        if (el.href) { check(el.href); return; }
        el.click();
        return;
      }
    }
    // Text-based search for Korean app buttons
    var allEls = document.querySelectorAll('a, button, [role="button"]');
    for (var j = 0; j < allEls.length; j++) {
      var txt = allEls[j].textContent || '';
      if (txt.indexOf('앱 열기') >= 0 || txt.indexOf('앱에서 보기') >= 0 ||
          txt.indexOf('앱으로 보기') >= 0 || txt.indexOf('앱에서 열기') >= 0) {
        if (allEls[j].href) { check(allEls[j].href); return; }
        allEls[j].click();
        return;
      }
    }
  }, 500);
})();
''');

    // Safety: if nothing found after 2s, show the WebView page
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_nativeLaunched && !_webViewReady) {
        setState(() => _webViewReady = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    String label;
    String logoAsset;
    switch (widget.marketplace) {
      case ShoppingMarketplace.coupang:
        label = '쿠팡';
        logoAsset = _assetCoupangAppLogo;
      case ShoppingMarketplace.marketKurly:
        label = '마켓컬리';
        logoAsset = _assetMarketkurlyLogo;
      case ShoppingMarketplace.oasis:
        label = '오아시스';
        logoAsset = _assetOasisLogo;
    }

    final showOverlay = !_webViewReady || _nativeLaunched || _wentToBackground;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: !showOverlay
          ? AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.black87),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                label,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : null,
      body: Stack(
        children: [
          if (_useWebView && _wvc != null)
            Positioned.fill(child: WebViewWidget(controller: _wvc!)),
          if (showOverlay)
            Container(
              color: Colors.white,
              width: double.infinity,
              height: double.infinity,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
                          borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                            'assets/icons/yorigo_app_icon.png',
                            width: 56,
                            height: 56,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 28,
                            color: Colors.grey.shade400,
                          ),
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(13),
                          child: Image.asset(logoAsset, width: 71, height: 71),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
            Text(
                      '$label 앱으로 이동중...',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade700,
                      ),
                    ),
          ],
        ),
      ),
            ),
        ],
      ),
    );
  }
}

