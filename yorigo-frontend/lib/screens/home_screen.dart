// =============================================================================
// HOME SCREEN
// Figma design (Weekly Plan, 이번 주 계획, 저장한 레시피).
// Fonts: Pretendard, Caveat. See lib/assets/font.
// =============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../widgets/app_toast.dart';
import '../widgets/grocery_agent_sheet.dart';
import '../services/grocery_agent_service.dart';
import '../utils/bounded_recipe_list.dart';
import '../utils/chef_tag_utils.dart';
import '../utils/perf_monitor.dart';
import 'package:flutter/physics.dart';
import '../main.dart' show MainNavigator, mainNavigatorKey;
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';
import '../services/auth_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../services/background_parsing_service.dart';
import '../services/analytics_service.dart';
import '../utils/parse_error_type.dart';
import '../utils/recipe_signal_snapshot.dart';
import '../services/parse_history_service.dart';
import '../services/parse_failure_report_service.dart';
import '../services/local_storage_service.dart';
import 'parse_history_screen.dart';
import '../utils/meal_calendar_launcher.dart';
import '../services/meal_plan_service.dart';
import '../widgets/home_poster_carousel.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';
import '../widgets/ios_liquid_glass_recipe_book.dart';
import '../widgets/home_poster_header.dart';
import '../widgets/app_confirm_dialog.dart';
import '../utils/nav_guard.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/recipe_search_match.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/section_recipe_fetch_window.dart';
import '../constants/home_section_keys.dart';
import '../models/onboarding_profile.dart';
import '../services/home_cms_service.dart';
import '../utils/home_scroll_metrics.dart';
import '../utils/onboarding_personalization.dart';
import '../utils/haptics.dart';
import '../widgets/app_header.dart';
import '../widgets/yorigo_header_logo.dart';
import '../widgets/parsing_animated_dots.dart';
import '../widgets/parsing_card_visuals.dart';
import '../widgets/parsing_ring_indicator.dart';
import '../widgets/home_section_chrome.dart';
import '../widgets/program_curation_section.dart';
import '../widgets/recipe_card_social_row.dart';
import 'add_recipe_screen.dart';
import 'category_explore_screen.dart' show HotGroupSheet;
import 'recipe_search_screen.dart';
import 'section_recipes_screen.dart';

// ---- From Figma / screen 2.txt ----
const Color _orange = Color(0xFFFF6B00);
const Color _textDark = Color(0xFF101828);
const Color _textGray2 = Color(0xFF6A7282);
const Color _placeholder = Color(0xFFD1D5DC);
const Color _border = Color(0xFFF3F4F6);
/// 홈 섹션 공통 크롬 별칭 — [home_section_chrome.dart]와 동일 비율.
const double _homeSectionRuleGap = homeSectionRuleGap;

Widget _homeSectionRule() => homeSectionRule();

TextStyle _homeSectionTitleStyle(Color color) => homeSectionTitleStyle(color);

Widget _homeSectionSeeAllArrow({
  required VoidCallback onTap,
  String semanticLabel = '전체보기',
}) =>
    homeSectionSeeAllArrow(onTap: onTap, semanticLabel: semanticLabel);

// --- Shimmer: thin band, smooth purple?blue transition ---
const _shimmerRecipeGradient = LinearGradient(
  colors: [
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
    Color(0xFFF6F2FF), // subtle lavender (single tint band)
    Color(0xFFF2F6FF), // subtle blue
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
  ],
  stops: [0.0, 0.44, 0.48, 0.52, 0.56, 1.0],
  begin: Alignment(-1.0, -1.0),
  end: Alignment(1.0, 1.0),
  tileMode: TileMode.clamp,
);

/// Slides the gradient diagonally (top-left to bottom-right) so the shimmer sweeps across.
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
    // Use this card's bounds so the gradient slides within each card (per-card shimmer)
    final childBounds = Rect.fromLTWH(0, 0, ro.size.width, ro.size.height);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => gradient.createShader(childBounds),
      child: widget.child,
    );
  }
}

/// Slightly darker than card white so the image area is visible; matches real card's placeholder tone.
const _shimmerImagePlaceholderColor = Color(0xFFEBECF0);

/// 인기 레시피 carousel — shared by real cards and shimmer placeholders.
const double _trendCarouselCardWidth = 140;
const double _trendCarouselImageHeight = 175;
const double _trendCarouselRadius = 18;
const int _trendCarouselShimmerItemCount = 8;

bool _isInstagramPlatformOrUrl(String platform, String sourceUrl) {
  final p = platform.toLowerCase().trim();
  if (p == 'instagram' || p == 'instagramweb' || p.contains('instagram')) {
    return true;
  }
  final s = sourceUrl.toLowerCase().trim();
  return s.contains('instagram.com') || s.contains('instagr.am');
}

BoxFit _trendCardImageFit(String platform, String sourceUrl) {
  if (_isInstagramPlatformOrUrl(platform, sourceUrl)) {
    // 실제 카드에서 contain + black 배경은 상/하 레터박스를 그대로 보여
    // 오히려 눌려 보이는 체감이 있어, 인스타도 cover로 처리한다.
    return BoxFit.cover;
  }
  return BoxFit.cover;
}

Color _trendCardImageBg(String platform, String sourceUrl) {
  if (_isInstagramPlatformOrUrl(platform, sourceUrl)) {
    return _border;
  }
  return _border;
}

/// Skeleton for [인기 레시피] horizontal carousel: same width, image height, radius, gap, and shadow as [_buildTrendCard].
class _TrendCarouselShimmerCard extends StatelessWidget {
  const _TrendCarouselShimmerCard();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _trendCarouselCardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _trendCarouselCardWidth,
            height: _trendCarouselImageHeight,
            decoration: BoxDecoration(
              color: _shimmerImagePlaceholderColor,
              borderRadius: BorderRadius.circular(_trendCarouselRadius),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 12,
            width: 108,
            decoration: BoxDecoration(
              color: _shimmerImagePlaceholderColor,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: _shimmerImagePlaceholderColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: _shimmerImagePlaceholderColor,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Skeleton: same colors and shape as recipe card (white card, 84?108 image area). Shimmer is applied on top.
class _RecipeCardShimmerSkeleton extends StatelessWidget {
  const _RecipeCardShimmerSkeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 133.33,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.67),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Rounded rect: same position, size (84?108), radius (14) as recipe card image; slightly darker so picture area is visible
            Container(
              width: 84,
              height: 108,
              decoration: BoxDecoration(
                color: _shimmerImagePlaceholderColor,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}

/// Pretendard (bundled) wherever Figma uses Inter. Caveat for "Weekly Plan" only.
TextStyle _tempTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w500,
  double? height,
  double? letterSpacing,
  required Color color,
}) => TextStyle(
  fontFamily: 'Pretendard',
  fontSize: fontSize,
  fontWeight: fontWeight,
  height: height ?? 1.50,
  letterSpacing: letterSpacing,
  color: color,
);

/// 카드 단위 impression 중복 로깅 방지용 — 앱 프로세스 생존 기간 동안 유지.
/// (섹션 재마운트/재스크롤 시 같은 카드를 반복 기록하지 않기 위함. 화면 State가 아니라
/// 파일 스코프에 두는 이유는 `_TrendRecipeCard`/`_SeasonalRecipeCard`가 StatelessWidget이라
/// 여러 섹션 위젯에서 공유되기 때문 — 매번 새 Set을 만들면 dedup이 무의미해짐.)
final Set<String> _homeCardImpressionFired = <String>{};

void _logHomeCardImpressionOnce({
  required String sectionId,
  required String cardKey,
  required String? recipeId,
  required int position,
  required Map<String, dynamic> recipe,
}) {
  final String dedupKey = '$sectionId::$cardKey';
  if (_homeCardImpressionFired.contains(dedupKey)) return;
  _homeCardImpressionFired.add(dedupKey);
  final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
  unawaited(
    AnalyticsService().logCardEvent(
      'impression',
      screen: 'home',
      sectionId: sectionId,
      cardId: recipeId,
      contentType: 'recipe',
      recipeId: recipeId,
      position: position,
      recipeCuisineType: snapshot.cuisineType,
      recipeTimeCategory: snapshot.timeCategory,
      recipeMenuType: snapshot.menuType,
      recipeMainIngredient: snapshot.mainIngredient,
      recipeMainIngredientSub: snapshot.mainIngredientSub,
      recipeTags: snapshot.tags,
      recipeNutritionRating: snapshot.nutritionRating,
      recipeIngredientCategories: snapshot.ingredientCategories,
      recipeSourcePlatform: snapshot.sourcePlatform,
      recipeServings: snapshot.servings,
    ),
  );
}

enum _RecipebookViewMode { list, grid }

/// 미니 레시피북 — 유리 구의 테두리·하이라이트.
class _GlassOrbPainter extends CustomPainter {
  const _GlassOrbPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 0.6;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..shader = SweepGradient(
        startAngle: -math.pi * 0.85,
        colors: const [
          Color(0xF2FFFFFF),
          Color(0x66FFFFFF),
          Color(0x33FFE4CC),
          Color(0x1AFFFFFF),
          Color(0xA6FFFFFF),
          Color(0xF2FFFFFF),
        ],
        stops: const [0.0, 0.18, 0.38, 0.62, 0.84, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, rim);

    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x59FFFFFF);
    canvas.drawCircle(center, radius - 2.4, inner);

    final specular = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.42));
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx - radius * 0.12, center.dy - radius * 0.42),
        width: radius * 1.15,
        height: radius * 0.55,
      ),
      specular,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// MainNavigator 하단 탭 index 0(홈) 활성 여부 — 이탈 시 스크롤 요약 flush.
  static final ValueNotifier<bool> _mainTabSelectedNotifier =
      ValueNotifier<bool>(true);

  static void setMainTabSelected(bool selected) {
    if (_mainTabSelectedNotifier.value == selected) return;
    _mainTabSelectedNotifier.value = selected;
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final RecipeService _recipeService = RecipeService.shared;
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final MealPlanService _mealPlanService = MealPlanService();
  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _recipebookSearchFocusNode = FocusNode();
  static const String _recipebookViewModePrefsKey = 'recipebook_view_mode';
  _RecipebookViewMode _recipebookViewMode = _RecipebookViewMode.list;
  final ScrollController _homeScrollController = ScrollController();
  final GlobalKey<_TrendingAllPageState> _trendingPageKey = GlobalKey();
  final ScrollController _recipebookScrollController = ScrollController();

  /// FAB pill collapses into a circular "+" button when scrolled past this offset.
  static const double _fabCollapseThreshold = 95.0;
  bool _fabCollapsed = false;

  /// 홈 세로 스크롤 깊이 요약 (탭 이탈/dispose 시 1회 전송).
  double _maxVerticalDepthPercent = 0;
  bool _verticalScrollSummaryFlushed = false;

  Stream<SavedRecipesResult>? _savedRecipesStream;
  String? _savedRecipesStreamUserId;
  SavedRecipesResult? _savedRecipesCache;
  StreamSubscription<SavedRecipesResult>? _savedRecipesCountSub;
  int _lastDockSavedCount = -1;

  StreamSubscription<User?>? _authStateSubscription;
  StreamSubscription<Map<String, dynamic>>? _parsingCompleteSub;
  OnboardingProfile? _onboardingProfile;

  final List<Map<String, dynamic>> _hotGroups = [];
  bool _hotGroupsLoading = true;
  StreamSubscription<List<Map<String, dynamic>>>? _hotGroupsSub;

  /// 0 = 추천, 1 = 인기
  int _homeFeedTabIndex = 0;
  late final AnimationController _recipebookSheetController;
  double _recipebookDragTravel = 1.0;
  static const double _homeHeaderHeight = 52.0;
  /// Soft top corners when the recipebook is fully open (book-cover feel).
  /// Larger than the collapsed pill so the open sheet eases in, not a sharp kink.
  static const double _recipebookExpandedTopRadius = 16.0;
  static const double _recipebookExpandedBottomRadius = 0.0;
  /// Open sheet is flush under the home header and flush to the nav.
  static const EdgeInsets _recipebookExpandedMargin = EdgeInsets.zero;
  static const double _recipebookCollapsedBottomGap = 0.0;
  /// Collapsed dock is flush to the nav: small top corners only, square bottom.
  static const double _recipebookCollapsedTopRadius = 16.0;
  static const double _recipebookSnapThreshold = 0.5;
  static const double _recipebookBackOpenThreshold = 0.08;
  static const double _recipebookCollapsedSnapThreshold = 0.32;
  static const double _recipebookCtaCollapseThreshold = 108.0;
  static const double _recipebookCtaExpandThreshold = 72.0;
  bool _recipebookDragging = false;
  bool _recipebookSheetWantsExpanded = false;
  /// iOS 네이티브 도크에서 연 전체 화면 레시피북. 설정 탭과 같이 셸을 가린다.
  bool _iosRecipebookPageOpen = false;
  final ValueNotifier<bool> _recipebookBackOpen = ValueNotifier<bool>(false);
  double _recipebookDragVelocityPx = 0;
  int _recipebookLastDragAtMs = 0;
  double _recipebookDragStartValue = 0;
  double _recipebookDragPixels = 0;
  double _recipebookDragRaw = 0;
  int _recipebookDetentSide = 0;
  Timer? _recipebookPointerUpSnapTimer;
  late final AnimationController _recipebookBottomCtaController;
  bool _recipebookBottomCtaCollapsed = false;
  /// 홈을 아래로 내리면 접힌 레시피북 도크가 원형 아이콘으로 줄어든다 (0=바, 1=원).
  late final AnimationController _recipebookMiniController;
  late final AnimationController _recipebookWindowFade;
  bool _recipebookMini = false;
  /// 이 오프셋 이상으로 내려가면 원형으로 접는다.
  static const double _recipebookMiniCollapseOffset = 140.0;
  /// 맨 위 근처로 돌아와야만 바 형태로 복원한다 (중간 상향 스크롤로는 안 뜸).
  static const double _recipebookMiniExpandOffset = 56.0;
  static const double _recipebookMiniSize = 54.0;
  /// Gap between the mini circle and the navbar — close, not flush.
  static const double _recipebookMiniBottomGap = 6.0;
  /// Collapsed dock bar content height — keep in sync with header Container.
  static const double _recipebookDockHeaderHeight = 56.0;
  /// 레시피북을 처음 펼치기 전까지 getSavedRecipes 구독을 시작하지 않는다.
  bool _recipebookStreamActivated = false;
  /// 펼친 뒤 한 번에 그리는 카드 수 — 스크롤 시 점진 확장.
  static const int _recipebookInitialVisibleCap = 40;
  static const int _recipebookVisibleCapStep = 30;
  int _recipebookVisibleCap = _recipebookInitialVisibleCap;

  String _selectedPrimaryCategory = '전체';
  String? _selectedSecondaryCategory;
  /// 재료 필터의 세 번째 단계 (예: 육류 → 돼지고기).
  String? _selectedTertiaryCategory;
  final Map<String, Set<String>> _ingredientSubTypeCache = {};
  List<Map<String, dynamic>> _recipebookCategories = const [];
  Map<String, List<String>> _recipebookRecipeCategoryMap = const {};
  String? _selectedRecipebookCategoryId;
  VoidCallback? _recipebookCategoriesListener;
  String _searchQuery = '';
  final Set<String> _optimisticallyDeletedIds = {};

  final Map<String, String> _parsingThumbnailCache = {};

  VoidCallback? _parsingProgressCacheListener;
  final ValueNotifier<int> _recipebookUiRevision = ValueNotifier<int>(0);

  String? _debugTokenPrintedUid;

  // 분석 실패 신고 + 멈춤(오래 걸림) 감지 상태
  static const Duration _kParsingStuckAfter = Duration(seconds: 180);
  static const Duration _kParsingCancelButtonAfter = Duration(minutes: 1);
  final Set<String> _reportedParseIds = {};
  final Map<String, DateTime> _parsingFirstSeen = {};
  final Set<String> _stuckKeepWaitingIds = {};
  Timer? _stuckCheckTimer;
  // 실패한 분석을 레시피북 대신 '분석 기록'으로 안내하기 위한 추적 상태.
  final Set<String> _seenErrorIds = {};
  bool _errorNotifInitialized = false;
  // 이 화면(세션)이 시작된 시각. 이전 세션에서 발생한 과거 파싱 실패가
  // 스트림 재emit(로컬 캐시→서버)으로 뒤늦게 들어와도 알림이 뜨지 않도록
  // "이번 세션 이후 실패"만 알리는 기준으로 사용한다.
  final DateTime _sessionStartedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    ParseHistoryService.instance.init();
    // 분석 취소(X) 노출·멈춤 카드 — 레시피북 도크만 갱신 (홈 피드 전체 setState 금지).
    _stuckCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _parsingFirstSeen.isNotEmpty) {
        _recipebookUiRevision.value++;
      }
    });
    _recipebookSheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 0,
    );
    _recipebookBottomCtaController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 0,
    );
    _recipebookMiniController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 0,
    );
    _recipebookWindowFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 0,
    );
    IosLiquidGlassRecipeBook.bindHandlers(
      onTap: () {
        unawaited(_openIosRecipebookPage());
      },
      onDragStart: _onRecipebookDragStart,
      onDragUpdate: _onRecipebookDragUpdate,
      onDragEnd: _onRecipebookDragEnd,
      onDragCancel: _onRecipebookDragCancel,
    );
    _recipebookSheetController.addListener(_onRecipebookSheetProgress);
    _recipebookSheetController.addStatusListener(_onRecipebookSheetStatus);
    _printAuthTokenForDebug(_authService.currentUser);
    _onboardingProfile = UserService.peekOnboardingProfile();
    unawaited(_loadOnboardingProfile());
    // 레시피북 스트림을 시작 시 즉시 바인딩 — 시트를 열 때 새로 로딩되는 대기를 없앤다.
    // (메모리 OOM의 진짜 원인은 Firestore 캐시였고 별도로 해결됨)
    _activateRecipebookStreamIfNeeded();
    _authStateSubscription = _authService.authStateChanges.listen((user) {
      if (_recipebookStreamActivated) {
        _bindSavedRecipesStreamForUser(user);
      }
      _printAuthTokenForDebug(user);
      unawaited(_loadOnboardingProfile());
      if (user != null && _hotGroups.isEmpty && !_hotGroupsLoading) {
        _loadHotGroups();
      }
    });
    _searchController.addListener(() {
      if (mounted) setState(() => _searchQuery = _searchController.text.trim());
    });
    // 레시피북 카테고리가 다른 화면(레시피 상세 등)에서 바뀌면 로컬에서 다시 읽어
    // 홈 pill과 항상 동일하게 유지한다.
    _recipebookCategoriesListener = () => _reloadRecipebookCategoriesFromLocal();
    recipebookCategoriesRevision.addListener(_recipebookCategoriesListener!);
    _reloadRecipebookCategoriesFromLocal();
    _parsingProgressCacheListener = () {
      if (mounted) _recipebookUiRevision.value++;
    };
    RecipeService.parsingProgressCache.addListener(
      _parsingProgressCacheListener!,
    );
    _backgroundParsingService.resumeIncompleteParsing();
    _parsingCompleteSub =
        _backgroundParsingService.onParsingComplete.listen((event) {
      if (!mounted) return;
      if (event['naverDedup'] != true) return;
      final status = event['status'] as String? ?? '';
      if (status != 'error') return;
      final recipeId = event['recipeId'] as String? ?? '';
      if (recipeId.isEmpty) return;
      _seenErrorIds.add(recipeId);
      final sourceUrl = event['sourceUrl'] as String? ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showParseFailedSnack(
          recipeId: recipeId,
          sourceUrl: sourceUrl,
          errorType: event['errorType'] as String?,
          errorMessage: event['error'] as String?,
        );
      });
    });
    // 공유 힌트 resolve 는 authStateChanges 첫 emit 에서만 수행
    // (init 과 중복 호출 시 limit(1) probe 가 두 번 나갈 수 있음).
    _loadHotGroupsOnBoot();
    _homeScrollController.addListener(_handleHomeScroll);
    IosLiquidGlassTabBar.bindHomeScrollHandler(_onNativeHomeScrollOffset);
    _recipebookScrollController.addListener(_onRecipebookScroll);
    HomeScreen._mainTabSelectedNotifier.addListener(_onHomeMainTabSelectionChanged);
    unawaited(_loadRecipebookViewModePref());
    // Precache platform icons (same assets as home) so saved-recipe cards don't jank when they appear.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      precacheImage(
        const AssetImage('lib/assets/youtube-app-icon-hd.png'),
        context,
      );
      precacheImage(
        const AssetImage('lib/assets/instagram-app-icon-hd.png'),
        context,
      );
      precacheImage(
        const AssetImage('lib/assets/tiktok-app-icon-hd.png'),
        context,
      );
      precacheImage(
        const AssetImage('assets/images/onboarding_ladle.png'),
        context,
      );
    });
  }

  Future<void> _printAuthTokenForDebug(User? user) async {
    if (!kDebugMode || user == null) return;
    if (_debugTokenPrintedUid == user.uid) return;
    _debugTokenPrintedUid = user.uid;
    try {
      final token = await user.getIdToken(true);
      if (token == null || token.isEmpty) {
        debugPrint('[Backfill][FirebaseIdToken][Error] token_is_empty');
        return;
      }
      debugPrint(
        '[Backfill][FirebaseIdToken] uid=${user.uid} token_length=${token.length}',
      );
      const chunkSize = 700;
      final totalChunks = (token.length / chunkSize).ceil();
      debugPrint(
        '[Backfill][FirebaseIdTokenChunks] totalChunks=$totalChunks tokenLength=${token.length}',
      );
      for (var i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = math.min(start + chunkSize, token.length);
        debugPrint('[Backfill][FirebaseIdTokenChunk ${i + 1}/$totalChunks]');
        debugPrint(token.substring(start, end));
      }
    } catch (e) {
      debugPrint('[Backfill][FirebaseIdToken][Error] $e');
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_iosRecipebookPageOpen) {
      _recipebookUiRevision.value++;
    }
  }

  @override
  void dispose() {
    if (_parsingProgressCacheListener != null) {
      RecipeService.parsingProgressCache.removeListener(
        _parsingProgressCacheListener!,
      );
    }
    if (_recipebookCategoriesListener != null) {
      recipebookCategoriesRevision.removeListener(
        _recipebookCategoriesListener!,
      );
    }
    _authStateSubscription?.cancel();
    _savedRecipesCountSub?.cancel();
    _parsingCompleteSub?.cancel();
    _hotGroupsSub?.cancel();
    _stuckCheckTimer?.cancel();
    _recipebookUiRevision.dispose();
    _recipebookBackOpen.dispose();
    _recipebookPointerUpSnapTimer?.cancel();
    _recipebookSheetController.removeListener(_onRecipebookSheetProgress);
    _recipebookSheetController.removeStatusListener(_onRecipebookSheetStatus);
    _recipebookSheetController.dispose();
    _recipebookBottomCtaController.dispose();
    _recipebookMiniController.dispose();
    _recipebookWindowFade.dispose();
    IosLiquidGlassRecipeBook.unbindHandlers();
    unawaited(
      IosLiquidGlassRecipeBook.sync(
        visible: false,
        mini: false,
        tabBarHeight: 0,
      ),
    );
    _searchController.dispose();
    _recipebookSearchFocusNode.dispose();
    HomeScreen._mainTabSelectedNotifier.removeListener(
      _onHomeMainTabSelectionChanged,
    );
    _flushHomeScrollSummaries();
    _homeScrollController.removeListener(_handleHomeScroll);
    IosLiquidGlassTabBar.unbindHomeScrollHandler();
    _homeScrollController.dispose();
    _recipebookScrollController.removeListener(_onRecipebookScroll);
    _recipebookScrollController.dispose();
    super.dispose();
  }

  void _onHomeMainTabSelectionChanged() {
    if (HomeScreen._mainTabSelectedNotifier.value) {
      _resetHomeScrollSummaries();
    } else {
      _flushHomeScrollSummaries();
      unawaited(
        IosLiquidGlassRecipeBook.sync(
          visible: false,
          mini: false,
          tabBarHeight: 0,
        ),
      );
    }
  }

  void _resetHomeScrollSummaries() {
    _maxVerticalDepthPercent = 0;
    _verticalScrollSummaryFlushed = false;
    _trendingPageKey.currentState?.resetScrollSummaries();
  }

  void _flushHomeScrollSummaries() {
    _trendingPageKey.currentState?.flushScrollSummaries();
    if (_verticalScrollSummaryFlushed) return;
    _verticalScrollSummaryFlushed = true;
    if (_maxVerticalDepthPercent <= 0) return;
    unawaited(
      AnalyticsService().trackHomeVerticalScrollSummary(
        maxDepthPercent: _maxVerticalDepthPercent,
      ),
    );
  }

  void _syncRecipebookBackOpen() {
    // 중간 펼침도 시스템 백으로 접을 수 있게 한다.
    final open = _recipebookSheetController.value > _recipebookBackOpenThreshold;
    if (_recipebookBackOpen.value != open) {
      _recipebookBackOpen.value = open;
    }
  }

  void _onRecipebookSheetProgress() {
    _syncRecipebookBackOpen();
    final v = _recipebookSheetController.value;
    if (v > 0.02) {
      _setRecipebookMini(false);
    } else if (!_recipebookDragging && !_recipebookSheetWantsExpanded) {
      if (_homeScrollController.hasClients) {
        _updateRecipebookMiniOnScroll(_homeScrollController.offset);
      }
    }
    if (_recipebookStreamActivated) return;
    if (v >= 0.06) {
      _activateRecipebookStreamIfNeeded();
    }
  }

  void _onRecipebookSheetStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    // animateWith always ticks "forward", so completed ≠ expanded. Snap to
    // the intended rest, otherwise a close animation jumps back open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _recipebookDragging) return;
      if (_recipebookSheetController.isAnimating) return;
      final target = _recipebookSheetWantsExpanded ? 1.0 : 0.0;
      if ((_recipebookSheetController.value - target).abs() > 0.0005) {
        _recipebookSheetController.value = target;
      }
    });
  }

  Future<void> _loadOnboardingProfile() async {
    final uid = _authService.currentUser?.uid;
    if (uid == null) {
      if (_onboardingProfile != null && mounted) {
        setState(() => _onboardingProfile = null);
      } else {
        _onboardingProfile = null;
      }
      return;
    }
    final profile = await _userService.loadOnboardingProfile();
    if (!mounted || _authService.currentUser?.uid != uid) return;
    if (identical(profile, _onboardingProfile)) return;
    setState(() => _onboardingProfile = profile);
  }

  void _activateRecipebookStreamIfNeeded() {
    if (_recipebookStreamActivated) return;
    _recipebookStreamActivated = true;
    _recipebookVisibleCap = _recipebookInitialVisibleCap;
    _bindSavedRecipesStreamForUser(_authService.currentUser, force: true);
  }

  void _bindSavedRecipesStreamForUser(User? user, {bool force = false}) {
    final uid = user?.uid;
    if (!force && uid == _savedRecipesStreamUserId) return;
    final switchedUser =
        _savedRecipesStreamUserId != null && uid != _savedRecipesStreamUserId;
    if (uid != null) {
      unawaited(
        _userService.ensureRecipebookCategoryDefaults(uid).then((_) {
          if (mounted) _reloadRecipebookCategoriesFromLocal();
        }),
      );
    }
    _savedRecipesStreamUserId = uid;
    _savedRecipesStream = uid != null
        ? _recipeService.getSavedRecipes()
        : _recipeService.getUserRecipes();
    // 워밍 스냅샷은 방금 연 스트림의 현재 유저 것만. 이전 계정 목록을
    // 배지/초기 화면에 남기지 않는다.
    _savedRecipesCache = uid != null
        ? _recipeService.warmSavedRecipesSnapshot
        : null;
    if (switchedUser) {
      _lastDockSavedCount = _savedRecipesCache == null ? 0 : -1;
      if (mounted) _recipebookUiRevision.value++;
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    _bindSavedRecipesCountListener();
  }

  /// 시트가 닫혀 있어도 도크 뱃지 숫자가 갱신되도록 브로드캐스트 스트림을 듣는다.
  void _bindSavedRecipesCountListener() {
    _savedRecipesCountSub?.cancel();
    final stream = _savedRecipesStream;
    if (stream == null) {
      _lastDockSavedCount = 0;
      if (mounted) _recipebookUiRevision.value++;
      return;
    }
    _savedRecipesCountSub = stream.listen((result) {
      if (!mounted) return;
      _savedRecipesCache = _mergeSavedRecipesCacheOnStreamUpdate(result);
      final count = _recipebookSavedCount();
      if (count == _lastDockSavedCount) return;
      _lastDockSavedCount = count;
      _recipebookUiRevision.value++;
    });
  }

  /// 레시피북에 저장된 레시피 수. 없으면 0.
  int _recipebookSavedCount() {
    final cache = _savedRecipesCache;
    if (cache == null) return 0;
    final visible = _filterRecipebookVisibleRecipes(cache.recipes).length;
    // 계정 전환 직후 빈 목록인데 totalCount만 이전 값이 남는 것을 막는다.
    if (visible <= 0) return 0;
    if (cache.totalCount > visible) return cache.totalCount;
    return visible;
  }

  void _handleHomeScroll() {
    if (!_homeScrollController.hasClients) return;
    if (_applyingNativeHomeScroll) return;
    final position = _homeScrollController.position;
    final depth = computeVerticalScrollDepthPercent(
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
    );
    if (depth > _maxVerticalDepthPercent) {
      _maxVerticalDepthPercent = depth;
    }
    final shouldCollapse = _homeScrollController.offset > _fabCollapseThreshold;
    if (shouldCollapse != _fabCollapsed) {
      setState(() => _fabCollapsed = shouldCollapse);
    }
    _updateRecipebookMiniOnScroll(position.pixels);
    if (IosLiquidGlassTabBar.overlayActive.value) {
      unawaited(
        IosLiquidGlassTabBar.syncHomeScroll(
          offset: position.pixels,
          maxExtent: position.maxScrollExtent,
        ),
      );
    }
  }

  bool _applyingNativeHomeScroll = false;

  /// 네이티브 홈 스크롤뷰가 공식 minimize를 탈 때 Flutter 리스트를 따라가게 한다.
  void _onNativeHomeScrollOffset(double offset) {
    if (!_homeScrollController.hasClients) return;
    final maxExtent = _homeScrollController.position.maxScrollExtent;
    final y = offset.clamp(0.0, maxExtent);
    if ((y - _homeScrollController.offset).abs() < 0.5) return;
    _applyingNativeHomeScroll = true;
    _homeScrollController.jumpTo(y);
    _applyingNativeHomeScroll = false;
    _updateRecipebookMiniOnScroll(y);
    final shouldCollapse = y > _fabCollapseThreshold;
    if (shouldCollapse != _fabCollapsed && mounted) {
      setState(() => _fabCollapsed = shouldCollapse);
    }
  }

  /// 내리면 원형으로 접고, 바 복원은 맨 위 근처에서만 한다.
  /// 중간에서 살짝 올려도 큰 바가 다시 떠서 피드를 가리지 않게 한다.
  void _updateRecipebookMiniOnScroll(double offset) {
    if (offset <= _recipebookMiniExpandOffset) {
      _setRecipebookMini(false);
    } else if (offset >= _recipebookMiniCollapseOffset) {
      _setRecipebookMini(true);
    }
    // 56~140 구간은 현재 상태 유지 (히스테리시스로 경계 깜빡임 방지).
  }

  void _setRecipebookMini(bool mini) {
    // iOS 26 시스템 탭바가 스크롤에 맞춰 접힌다. Flutter 미니 원은 쓰지 않는다.
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        IosLiquidGlassTabBar.overlayActive.value) {
      return;
    }
    // 시트가 열려 있는 동안에는 항상 펼친 형태를 유지한다.
    if (mini && _recipebookSheetController.value > 0.02) return;
    if (_recipebookMini == mini) return;
    _recipebookMini = mini;
    _recipebookMiniController.animateTo(
      mini ? 1.0 : 0.0,
      duration: Duration(milliseconds: mini ? 240 : 300),
      curve: Curves.easeOutCubic,
    );
  }

  bool get _recipebookHeaderExpandedState =>
      _recipebookSheetController.value > 0.55;
  bool get _recipebookBodyVisible => _recipebookSheetController.value > 0.22;

  /// iPhone 네이티브 도크는 설정처럼 푸시된 전체 화면으로 연다.
  bool get _iosRecipebookOpensAsPage {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    return _iosRecipebookPageOpen || IosLiquidGlassTabBar.overlayActive.value;
  }

  /// 예전 홈 위 창 오버레이. 네이티브 도크는 [_openIosRecipebookPage]를 쓴다.
  bool get _iosRecipebookWindowMode => false;

  Future<void> _openIosRecipebookPage() async {
    if (_iosRecipebookPageOpen || !mounted) return;
    _activateRecipebookStreamIfNeeded();
    _setRecipebookMini(false);
    _recipebookSearchFocusNode.unfocus();
    _iosRecipebookPageOpen = true;
    _recipebookUiRevision.value++;
    _setRecipebookBottomCtaCollapsed(false);
    Haptics.light();
    await Navigator.of(context).push<void>(
      CupertinoPageRoute<void>(
        settings: const RouteSettings(name: '/recipe-book'),
        builder: (_) => _IosRecipeBookPage(home: this),
      ),
    );
    if (!mounted) return;
    _iosRecipebookPageOpen = false;
    _recipebookSearchFocusNode.unfocus();
    _recipebookUiRevision.value++;
  }

  void _setRecipebookExpanded(bool expanded, {double velocity = 0}) {
    if (_iosRecipebookOpensAsPage) {
      if (expanded) unawaited(_openIosRecipebookPage());
      return;
    }
    _recipebookSheetWantsExpanded = expanded;
    if (expanded) {
      _activateRecipebookStreamIfNeeded();
      _setRecipebookMini(false);
    } else {
      // Collapse: drop keyboard/focus; keep query for the filter row field.
      _recipebookSearchFocusNode.unfocus();
    }
    final target = expanded ? 1.0 : 0.0;
    if ((_recipebookSheetController.value - target).abs() < 0.001) return;
    Haptics.light();
    // Opposite-direction leftover velocity makes the sheet bounce back.
    final towardTarget = expanded ? 1.0 : -1.0;
    final simVelocity =
        (velocity.sign == towardTarget.sign || velocity == 0)
            ? velocity * 1.15
            : 0.0;
    // 절반을 넘긴 뒤 나머지 거리를 빠르게 감아 붙인다.
    final spring = SpringDescription.withDampingRatio(
      mass: 0.78,
      stiffness: 1380,
      ratio: 0.86,
    );
    final simulation = SpringSimulation(
      spring,
      _recipebookSheetController.value,
      target,
      simVelocity,
    );
    _recipebookSheetController.animateWith(simulation);
  }

  double _recipebookDetentValue(double raw) {
    final v = raw.clamp(0.0, 1.0);
    // 0~0.5는 선형 — 미니에서 올릴 때 중간에 멈춘 것처럼 보이지 않게.
    if (v < 0.5) return v;
    final t = (v - 0.5) / 0.5;
    final eased = 1 - math.pow(1 - t, 3).toDouble();
    return 0.5 + 0.5 * eased;
  }

  void _onRecipebookDragStart() {
    if (_iosRecipebookOpensAsPage) {
      unawaited(_openIosRecipebookPage());
      return;
    }
    _setRecipebookMini(false);
    unawaited(
      IosLiquidGlassRecipeBook.sync(
        visible: false,
        mini: false,
        tabBarHeight: 0,
      ),
    );
    _recipebookDragging = true;
    _recipebookDragVelocityPx = 0;
    _recipebookLastDragAtMs = 0;
    _recipebookDragStartValue = _recipebookSheetController.value;
    _recipebookDragPixels = 0;
    _recipebookDragRaw = _recipebookDragStartValue;
    _recipebookDetentSide = _recipebookDragRaw >= 0.5 ? 1 : -1;
    _recipebookPointerUpSnapTimer?.cancel();
    // Interrupt any in-flight spring so the finger fully owns the sheet.
    if (_recipebookSheetController.isAnimating) {
      _recipebookSheetController.stop(canceled: true);
    }
  }

  void _onRecipebookDragUpdate(double delta) {
    if (_iosRecipebookOpensAsPage) return;
    if (!_recipebookDragging) _recipebookDragging = true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final dtMs = (_recipebookLastDragAtMs == 0)
        ? 16
        : (now - _recipebookLastDragAtMs).clamp(1, 48);
    _recipebookDragVelocityPx = delta / dtMs * 1000;
    _recipebookLastDragAtMs = now;
    _recipebookDragPixels += delta;
    _recipebookDragRaw =
        (_recipebookDragStartValue - _recipebookDragPixels / _recipebookDragTravel)
            .clamp(0.0, 1.0);
    final side = _recipebookDragRaw >= 0.5 ? 1 : -1;
    if (side != _recipebookDetentSide) {
      _recipebookDetentSide = side;
      Haptics.selection();
    }
    _recipebookSheetController.value = _recipebookDetentValue(_recipebookDragRaw);
  }

  bool _shouldExpandRecipebook({required double primaryVelocity}) {
    if (primaryVelocity.abs() > 260) {
      return primaryVelocity < 0;
    }
    final rest = _recipebookDragging || _recipebookDragPixels.abs() > 0.5
        ? _recipebookDragRaw
        : _recipebookSheetController.value;
    final fromCollapsed = _recipebookDragStartValue < 0.08;
    final threshold = fromCollapsed
        ? _recipebookCollapsedSnapThreshold
        : _recipebookSnapThreshold;
    return rest >= threshold;
  }

  /// Snap an abandoned mid-progress sheet (common when web drops drag-end).
  void _settleRecipebookSheetIfNeeded() {
    if (!mounted || _recipebookDragging) return;
    if (_recipebookSheetController.isAnimating) return;
    final v = _recipebookSheetController.value;
    if (v <= 0.02 || v >= 0.98) {
      final target = _recipebookSheetWantsExpanded ? 1.0 : 0.0;
      if ((v - target).abs() > 0.0005) {
        _recipebookSheetController.value = target;
      }
      return;
    }
    _setRecipebookExpanded(
      _shouldExpandRecipebook(primaryVelocity: _recipebookDragVelocityPx),
    );
  }

  void _scheduleRecipebookPointerUpSnap() {
    _recipebookPointerUpSnapTimer?.cancel();
    _recipebookPointerUpSnapTimer = Timer(const Duration(milliseconds: 24), () {
      if (!mounted) return;
      if (_recipebookDragging) {
        _recipebookDragging = false;
        final velocity = _recipebookDragVelocityPx;
        _setRecipebookExpanded(
          _shouldExpandRecipebook(primaryVelocity: velocity),
          velocity: -velocity / _recipebookDragTravel,
        );
        return;
      }
      // Gesture was dropped without dragEnd — still settle mid values.
      _settleRecipebookSheetIfNeeded();
    });
  }

  void _onRecipebookDragCancel() {
    _recipebookPointerUpSnapTimer?.cancel();
    _recipebookDragging = false;
    _setRecipebookExpanded(
      _shouldExpandRecipebook(primaryVelocity: _recipebookDragVelocityPx),
    );
  }

  void _onRecipebookDragEnd(double primaryVelocity) {
    _recipebookPointerUpSnapTimer?.cancel();
    _recipebookDragging = false;
    final unitVelocity = -primaryVelocity / _recipebookDragTravel;
    _setRecipebookExpanded(
      _shouldExpandRecipebook(primaryVelocity: primaryVelocity),
      velocity: unitVelocity,
    );
  }

  void _onRecipebookScroll() {
    if (!_recipebookScrollController.hasClients) return;
    final offset = _recipebookScrollController.offset;
    if (offset >= _recipebookCtaCollapseThreshold) {
      _setRecipebookBottomCtaCollapsed(true);
    } else if (offset <= _recipebookCtaExpandThreshold) {
      _setRecipebookBottomCtaCollapsed(false);
    }

    final pos = _recipebookScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 280) {
      final cacheCount = _savedRecipesCache?.recipes.length ?? 0;
      if (cacheCount > _recipebookVisibleCap) {
        final nextCap = math.min(
          _recipebookVisibleCap + _recipebookVisibleCapStep,
          cacheCount,
        );
        if (nextCap != _recipebookVisibleCap && mounted) {
          setState(() => _recipebookVisibleCap = nextCap);
        }
      }
    }
  }

  void _setRecipebookBottomCtaCollapsed(bool collapsed) {
    final target = collapsed ? 1.0 : 0.0;
    // 플래그만 바뀌고 value가 안 움직인 경우(푸시 라우트에서 ticker mute) 재시도한다.
    if (_recipebookBottomCtaCollapsed == collapsed &&
        (_recipebookBottomCtaController.value - target).abs() < 0.02) {
      return;
    }
    _recipebookBottomCtaCollapsed = collapsed;
    final spring = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 520,
      ratio: 0.78,
    );
    final simulation = SpringSimulation(
      spring,
      _recipebookBottomCtaController.value,
      target,
      0,
    );
    _recipebookBottomCtaController.animateWith(simulation);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    // Back should collapse an open recipebook before leaving the home route.
    // Listen to sheet + tab selection so IndexedStack off-tab state never traps
    // system back on community/cart/etc.
    return ListenableBuilder(
      listenable: Listenable.merge([
        _recipebookBackOpen,
        HomeScreen._mainTabSelectedNotifier,
      ]),
      builder: (context, child) {
        final homeSelected = HomeScreen._mainTabSelectedNotifier.value;
        final interceptBack = homeSelected && _recipebookBackOpen.value;
        return PopScope(
          canPop: !interceptBack,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (!HomeScreen._mainTabSelectedNotifier.value) return;
            if (_recipebookSheetController.value <= _recipebookBackOpenThreshold) {
              return;
            }
            _setRecipebookExpanded(false);
          },
          child: child!,
        );
      },
      child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: AppColors.getBackground(brightness),
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            floatingActionButton: GroceryAgentService.enabled
                ? StreamBuilder<User?>(
                    stream: _authService.authStateChanges,
                    initialData: _authService.currentUser,
                    builder: (context, snapshot) {
                      if (snapshot.data == null) return const SizedBox.shrink();
                      return GroceryAgentFab(
                        onPressed: () => GroceryAgentSheet.open(context),
                      );
                    },
                  )
                : null,
            // 하단 inset은 MainNavigator bottom nav가 소유한다.
            body: SafeArea(
              bottom: false,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Column(
                    children: [
                      StreamBuilder<User?>(
                        stream: _authService.authStateChanges,
                        initialData: _authService.currentUser,
                        builder: (context, snapshot) {
                          return _buildAppHeader(
                            brightness,
                            loggedIn: snapshot.data != null,
                          );
                        },
                      ),
                      Expanded(
                        child: AppRefreshIndicator(
                          onRefresh: _onHomePullRefresh,
                          child: StreamBuilder<User?>(
                            stream: _authService.authStateChanges,
                            initialData: _authService.currentUser,
                            builder: (context, snapshot) {
                              final loggedIn = snapshot.data != null;
                              final popularTab = _homeFeedTabIndex == 1;
                              return NotificationListener<ScrollMetricsNotification>(
                                onNotification: (notification) {
                                  if (!IosLiquidGlassTabBar.overlayActive.value) {
                                    return false;
                                  }
                                  // 가로 레일 메트릭이 들어오면 네이티브 contentSize가
                                  // 줄고, 접힌 탭바가 다시 펼쳐진다. 바깥 세로만 전달.
                                  if (notification.depth != 0) return false;
                                  final metrics = notification.metrics;
                                  if (metrics.axis != Axis.vertical) {
                                    return false;
                                  }
                                  unawaited(
                                    IosLiquidGlassTabBar.syncHomeScroll(
                                      offset: metrics.pixels,
                                      maxExtent: metrics.maxScrollExtent,
                                    ),
                                  );
                                  return false;
                                },
                                child: CustomScrollView(
                                controller: _homeScrollController,
                                physics: IosLiquidGlassTabBar.overlayActive.value
                                    ? const NeverScrollableScrollPhysics()
                                    : const AlwaysScrollableScrollPhysics(
                                        parent: ClampingScrollPhysics(),
                                      ),
                                // 화면 밖 섹션은 늦게 빌드해 세로 스크롤 부담을 줄인다.
                                cacheExtent: 280,
                                slivers: [
                                  SliverToBoxAdapter(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        HomePosterHeader(
                                          selectedTabIndex: _homeFeedTabIndex,
                                          onTabSelected: (i) {
                                            if (_homeFeedTabIndex == i) return;
                                            setState(
                                              () => _homeFeedTabIndex = i,
                                            );
                                            unawaited(
                                              AnalyticsService()
                                                  .trackHomeFeedTabSelected(
                                                tabIndex: i,
                                                tabName: i == 1
                                                    ? 'popular'
                                                    : 'recommend',
                                              ),
                                            );
                                            // 인기 탭으로 오면 상단으로 올려 섹션이 바로 보이게
                                            if (i == 1 &&
                                                _homeScrollController
                                                    .hasClients) {
                                              _homeScrollController.jumpTo(0);
                                            }
                                          },
                                        ),
                                        // 추천: 포스터→선 여백 = 탭→포스터(topGap) / 인기: 탭 직후 섹션
                                        if (!popularTab) ...[
                                          const SizedBox(
                                            height: HomePosterCarousel.topGap,
                                          ),
                                          const ColoredBox(
                                            color: Color(0xFFEDEFF2),
                                            child: SizedBox(
                                              width: double.infinity,
                                              height: 1,
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                        ],
                                      ],
                                    ),
                                  ),
                                  // 추천: 전체 섹션 / 인기: 셰프·요즘 인기 메뉴·실시간 인기
                                  TrendingAllPage(
                                    key: _trendingPageKey,
                                    allRecipes:
                                        const <Map<String, dynamic>>[],
                                    onRecipeTap: _onTrendRecipeTap,
                                    inline: true,
                                    showMembersOnlySections: loggedIn,
                                    popularOnly: popularTab,
                                    // 인기: 탭 밑줄 바로 아래 숨 쉴 여백만 (회색 구분선 대신)
                                    firstSectionTopPadding:
                                        popularTab ? _homeSectionRuleGap : 0,
                                    sequentialInlineBootstrap: !popularTab,
                                    showSequentialTailLoading: !popularTab,
                                    onFirstSectionReady:
                                        _onTrendingFirstSectionReady,
                                    waitForInlineLeadIn:
                                        _waitForHotGroupsLeadIn,
                                    inlineAfterBoosted: popularTab
                                        ? null
                                        : Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const ProgramCurationSection(),
                                              _homeSectionRule(),
                                            ],
                                          ),
                                    inlineAfterNowTrending:
                                        _buildHomeHotGroupsSection(
                                      brightness,
                                    ),
                                  ),
                                  SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: 140 +
                                          IosLiquidGlassTabBar
                                              .overlayChromeInset(context),
                                    ),
                                  ),
                                ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      _recipebookUiRevision,
                      IosLiquidGlassRecipeBook.overlayActive,
                      IosLiquidGlassTabBar.overlayActive,
                      HomeScreen._mainTabSelectedNotifier,
                      IosLiquidGlassTabBar.coveredByPushedRoute,
                    ]),
                    builder: (context, _) =>
                        _buildRecipebookDock(context, brightness),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildIosRecipebookScaffold(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: AppColors.getBackground(brightness),
        elevation: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '나의 레시피북',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_recipebookSavedCount() > 0) ...[
              const SizedBox(width: 8),
              _buildRecipebookCountBadge(),
            ],
          ],
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.getTextPrimary(brightness),
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _buildRecipebookInlineSearchField()),
                const SizedBox(width: 8),
                _buildRecipebookViewToggle(),
              ],
            ),
          ),
          _buildRecipebookCategoryPills(),
          if (_selectedRecipebookCategoryId == null) ...[
            _buildPrimaryFilterLayer(brightness),
            _buildSecondaryFilterLayer(brightness),
          ],
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _buildSavedRecipesSection(
                    context,
                    showInlineSearch: false,
                    scrollController: _recipebookScrollController,
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14 + bottomInset,
                  height: 56,
                  child: AnimatedBuilder(
                    animation: _recipebookBottomCtaController,
                    builder: (context, _) {
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final morph = _recipebookBottomCtaController.value;
                          final sizeT = Curves.easeInOutCubic.transform(morph);
                          final moveT = Curves.easeOutCubic.transform(morph);
                          final width = lerpDouble(
                            constraints.maxWidth,
                            56,
                            sizeT,
                          )!;
                          final alignment = Alignment.lerp(
                            Alignment.bottomCenter,
                            Alignment.bottomRight,
                            moveT,
                          )!;
                          return Align(
                            alignment: alignment,
                            child: SizedBox(
                              width: width,
                              height: 56,
                              child: _buildRecipebookBottomAddPill(
                                morph: morph,
                                currentWidth: width,
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
        ],
      ),
    );
  }

  Widget _buildRecipebookDock(BuildContext context, Brightness brightness) {
    final nativeDockOwner = IosLiquidGlassRecipeBook.shouldUse(context) &&
        HomeScreen._mainTabSelectedNotifier.value &&
        (IosLiquidGlassTabBar.overlayActive.value ||
            IosLiquidGlassTabBar.coveredByPushedRoute.value ||
            _iosRecipebookPageOpen);
    if (nativeDockOwner) {
      final showAccessory = IosLiquidGlassTabBar.overlayActive.value &&
          !IosLiquidGlassTabBar.coveredByPushedRoute.value &&
          !_iosRecipebookPageOpen;
      if (showAccessory) {
        unawaited(
          IosLiquidGlassRecipeBook.sync(
            visible: true,
            mini: false,
            tabBarHeight: IosLiquidGlassTabBar.overlayChromeInset(context),
            miniSize: _recipebookMiniSize,
            height: 50,
            bottomGap: 2,
            savedCount: _recipebookSavedCount(),
          ),
        );
      }
      // 네이티브 알약이 붙기 전에 Flutter 도크를 그리면 예전 레시피북 형상이
      // 한 프레임 떴다 사라진다. iPhone 네이티브 크롬이 소유할 때는 그리지 않는다.
      return const SizedBox.shrink();
    }
    // Collapsed pill docks above the bottom nav.
    const collapsedHeight = _recipebookDockHeaderHeight;
    return Positioned.fill(
      // 탭바 윗선과 맞물리게 2px 겹친다.
      bottom: IosLiquidGlassTabBar.overlayChromeInset(context) - 2,
      child: LayoutBuilder(
      builder: (context, constraints) {
          final availableHeight = constraints.maxHeight;
          final availableWidth = constraints.maxWidth;
          final expandedMargin = EdgeInsets.only(
            left: _recipebookExpandedMargin.left,
            right: _recipebookExpandedMargin.right,
            // 1px overlap hides the hairline under the home header.
            top: _homeHeaderHeight - 1 + _recipebookExpandedMargin.top,
            bottom: _recipebookExpandedMargin.bottom,
          );
          // Full-bleed like a mini-player; do not inset to match the floating nav.
          const collapsedHInset = 0.0;
          final collapsedTop =
              availableHeight - collapsedHeight - _recipebookCollapsedBottomGap;
          final collapsedMargin = EdgeInsets.fromLTRB(
            collapsedHInset,
            collapsedTop,
            collapsedHInset,
            _recipebookCollapsedBottomGap,
          );
          final travel = (collapsedTop - expandedMargin.top).clamp(
            1.0,
            double.infinity,
          );
          _recipebookDragTravel = travel;

          return AnimatedBuilder(
            animation: Listenable.merge([
              _recipebookSheetController,
              _recipebookMiniController,
              _recipebookWindowFade,
            ]),
            builder: (context, _) {
              final windowOpen = _iosRecipebookWindowMode &&
                  (_recipebookSheetWantsExpanded ||
                      _recipebookWindowFade.value > 0.01);
              final progress = windowOpen
                  ? 1.0
                  : _recipebookSheetController.value.clamp(0.0, 1.0);
              final collapsedAccent = (1 - progress).clamp(0.0, 1.0);
              // 시트가 조금이라도 열리면 미니 원을 끄고 바→시트만 쓴다.
              // 원↔시트를 섞으면 중간에서 거대한 사각 유리판이 피드를 가린다.
              final miniT = progress > 0.02
                  ? 0.0
                  : _recipebookMiniController.value.clamp(0.0, 1.0);
              final nativeChrome =
                  IosLiquidGlassRecipeBook.shouldUse(context) &&
                  IosLiquidGlassTabBar.overlayActive.value &&
                  HomeScreen._mainTabSelectedNotifier.value &&
                  !IosLiquidGlassTabBar.coveredByPushedRoute.value &&
                  progress < 0.02;
              unawaited(
                IosLiquidGlassRecipeBook.sync(
                  visible: nativeChrome,
                  mini: false,
                  tabBarHeight: IosLiquidGlassTabBar.overlayChromeInset(
                    context,
                  ),
                  miniSize: _recipebookMiniSize,
                  height: 50,
                  bottomGap: 2,
                  savedCount: _recipebookSavedCount(),
                ),
              );
              if (nativeChrome && IosLiquidGlassRecipeBook.overlayActive.value) {
                return const SizedBox.shrink();
              }
              final miniMove = Curves.easeInOutCubic.transform(miniT);
              final sheetMargin = EdgeInsets.lerp(
                collapsedMargin,
                expandedMargin,
                progress,
              )!;
              final barLeft = sheetMargin.left;
              final barRight = sheetMargin.right;
              final barTop = sheetMargin.top;
              final barHeight = (availableHeight -
                      sheetMargin.top -
                      sheetMargin.bottom)
                  .clamp(collapsedHeight, availableHeight);
              final contentWidth =
                  (availableWidth - barLeft - barRight).clamp(
                    1.0,
                    double.infinity,
                  );
              final miniSide =
                  ((availableWidth - _recipebookMiniSize) / 2).clamp(
                    0.0,
                    double.infinity,
                  );
              // 원이 도크에서 떨어져 보석처럼 살짝 떠 오르게 한다.
              // Sit closer to the nav than the pill, with a small remaining gap.
              final miniTop = availableHeight -
                  _recipebookMiniSize -
                  _recipebookMiniBottomGap;
              final left = lerpDouble(barLeft, miniSide, miniMove)!;
              final right = lerpDouble(barRight, miniSide, miniMove)!;
              final top = lerpDouble(barTop, miniTop, miniMove)!;
              final height = lerpDouble(
                barHeight,
                _recipebookMiniSize,
                miniMove,
              )!;
              // Collapsed: docked bar (square bottom). Expanded: rounded card.
              // Mini morph still goes full circle.
              final topRadius = lerpDouble(
                lerpDouble(
                  _recipebookCollapsedTopRadius,
                  _recipebookExpandedTopRadius,
                  progress,
                )!,
                _recipebookMiniSize / 2,
                miniMove,
              )!;
              final bottomRadius = lerpDouble(
                lerpDouble(
                  0,
                  _recipebookExpandedBottomRadius,
                  progress,
                )!,
                _recipebookMiniSize / 2,
                miniMove,
              )!;
              final barOpacity = (1 - miniT / 0.5).clamp(0.0, 1.0);
              final miniIconOpacity = ((miniT - 0.45) / 0.55).clamp(0.0, 1.0);

              return Stack(
                children: [
                  Positioned(
                    left: left,
                    right: right,
                    top: top,
                    height: height,
            child: Opacity(
              opacity: windowOpen ? _recipebookWindowFade.value : 1,
              child: Listener(
                      onPointerUp: miniT > 0.5
                          ? (_) => _scheduleRecipebookPointerUpSnap()
                          : null,
                      onPointerCancel: miniT > 0.5
                          ? (_) => _scheduleRecipebookPointerUpSnap()
                          : null,
                      child: GestureDetector(
              behavior: HitTestBehavior.opaque,
                      onTap: () => _setRecipebookExpanded(true),
                      // 미니 원 상태에서는 헤더 제스처가 꺼지므로 여기서 드래그를 받는다.
                      onVerticalDragStart: miniT > 0.5
                          ? (_) => _onRecipebookDragStart()
                          : null,
                      onVerticalDragUpdate: miniT > 0.5
                          ? (details) =>
                                _onRecipebookDragUpdate(details.primaryDelta ?? 0)
                          : null,
                      onVerticalDragCancel: miniT > 0.5
                          ? _onRecipebookDragCancel
                          : null,
                      onVerticalDragEnd: miniT > 0.5
                          ? (details) => _onRecipebookDragEnd(
                              details.primaryVelocity ?? 0,
                            )
                          : null,
                      child: Container(
                        // Shadow lives on the outer shell — ClipRRect below
                        // must not clip it (Container.clipBehavior would).
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(topRadius),
                            topRight: Radius.circular(topRadius),
                            bottomLeft: Radius.circular(bottomRadius),
                            bottomRight: Radius.circular(bottomRadius),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: lerpDouble(0.08, 0.10, progress)! *
                                    (1 - miniT),
                              ),
                              blurRadius: lerpDouble(16, 20, progress)!,
                              spreadRadius: lerpDouble(-1, -2, progress)!,
                              offset: Offset(
                                0,
                                lerpDouble(-4, -3, progress)!,
                              ),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: lerpDouble(0.04, 0.05, progress)! *
                                    (1 - miniT),
                              ),
                              blurRadius: 10,
                              offset: const Offset(0, -1),
                            ),
                            if (miniT > 0) ...[
                              BoxShadow(
                                color: const Color(0xFF191F28).withValues(
                                  alpha: 0.10 * miniT,
                                ),
                                blurRadius: 8 * miniT,
                                spreadRadius: -1 * miniT,
                                offset: Offset(0, 3 * miniT),
                              ),
                              BoxShadow(
                                color: const Color(0xFF191F28).withValues(
                                  alpha: 0.05 * miniT,
                                ),
                                blurRadius: 3 * miniT,
                                offset: Offset(0, 1 * miniT),
                              ),
                            ],
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(topRadius),
                            topRight: Radius.circular(topRadius),
                            bottomLeft: Radius.circular(bottomRadius),
                            bottomRight: Radius.circular(bottomRadius),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color.lerp(
                                    const Color(0xFFFFFFFF),
                                    const Color(0x00FFFFFF),
                                    miniT,
                                  )!,
                                  Color.lerp(
                                    Color.lerp(
                                      const Color(0xFFFFFFFF),
                                      const Color(0xFFF8FAFF),
                                      collapsedAccent * 0.9,
                                    )!,
                                    const Color(0x00FFFFFF),
                                    miniT,
                                  )!,
                                ],
                              ),
                              border: Border(
                                top: BorderSide(
                                  color: Color.lerp(
                                    const Color(0xFFE9EDF2),
                                    const Color(0x00FFFFFF),
                                    miniT,
                                  )!,
                                  width: lerpDouble(1, 0, miniT)!,
                                ),
                                left: BorderSide(
                                  color: Color.lerp(
                                    const Color(0xFFE9EDF2),
                                    const Color(0x00FFFFFF),
                                    miniT,
                                  )!,
                                  width: lerpDouble(1, 0, miniT)!,
                                ),
                                right: BorderSide(
                                  color: Color.lerp(
                                    const Color(0xFFE9EDF2),
                                    const Color(0x00FFFFFF),
                                    miniT,
                                  )!,
                                  width: lerpDouble(1, 0, miniT)!,
                                ),
                                // 접힌 도크는 탭바와 맞물리므로 하단 보더를 빼 틈을 없앤다.
                                bottom: (progress < 0.08 && miniT < 0.01)
                                    ? BorderSide.none
                                    : BorderSide(
                                        color: Color.lerp(
                                          const Color(0xFFE9EDF2),
                                          const Color(0x00FFFFFF),
                                          miniT,
                                        )!,
                                        width: lerpDouble(1, 0, miniT)!,
                                      ),
                              ),
                            ),
                            child: Stack(
                          children: [
                            // 미니 원으로 줄어드는 동안에도 내용은 원래 크기로
                            // 레이아웃해 두고 클립·페이드로만 감춘다.
                            Positioned.fill(
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                minWidth: contentWidth,
                                maxWidth: contentWidth,
                                minHeight: barHeight,
                                maxHeight: barHeight,
                                child: IgnorePointer(
                                  ignoring: barOpacity < 0.2,
                                  child: Opacity(
                                    opacity: barOpacity,
                                    child: Column(
                          children: [
                            _buildRecipebookExpandedTopBar(brightness),
                            Expanded(
                child: Stack(
                  children: [
                                  Positioned.fill(
                      child: IgnorePointer(
                                      ignoring: !_recipebookBodyVisible,
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        opacity: _recipebookBodyVisible ? 1 : 0,
                                        child: _buildSavedRecipesSection(
                                          context,
                                          showInlineSearch: false,
                                          scrollController:
                                              _recipebookScrollController,
                                        ),
                                      ),
                                    ),
                                  ),
                                  IgnorePointer(
                                    ignoring: !_recipebookBodyVisible,
                                    child: AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      opacity: _recipebookBodyVisible ? 1 : 0,
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          14,
                                        ),
                                        child: AnimatedBuilder(
                                          animation:
                                              _recipebookBottomCtaController,
                                          builder: (context, _) {
                                            return LayoutBuilder(
                                              builder: (context, constraints) {
                                                final morph =
                                                    _recipebookBottomCtaController
                                                        .value;
                                                final sizeT = Curves
                                                    .easeInOutCubic
                                                    .transform(morph);
                                                final moveT = Curves
                                                    .easeOutCubic
                                                    .transform(morph);
                                                final width = lerpDouble(
                                                  constraints.maxWidth,
                                                  56,
                                                  sizeT,
                                                )!;
                                                final height = lerpDouble(
                                                  56,
                                                  56,
                                                  sizeT,
                                                )!;
                                                final alignment =
                                                    Alignment.lerp(
                                                      Alignment.bottomCenter,
                                                      Alignment.bottomRight,
                                                      moveT,
                                                    )!;
                                                return Align(
                                                  alignment: alignment,
                                                  child: SizedBox(
                                                    width: width,
                                                    height: height,
                                                    child:
                                                        _buildRecipebookBottomAddPill(
                                                          morph: morph,
                                                          currentWidth: width,
                                                        ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
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
                                ),
                              ),
                            ),
                            if (miniIconOpacity > 0)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _buildRecipebookMiniJewel(
                                    intensity: miniIconOpacity,
                                  ),
                                ),
                              ),
                          ],
                        ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 접힌 레시피북 — 뒤가 비치는 유리 구.
  /// Opacity로 감싸면 BackdropFilter가 뒤 화면을 못 읽어서, 서리만 여기서 조절한다.
  Widget _buildRecipebookMiniJewel({required double intensity}) {
    final frost = (0.07 * intensity).clamp(0.0, 1.0);
    final sigma = 18.0 + 16.0 * intensity;
    return Stack(
      fit: StackFit.expand,
      children: [
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: ColoredBox(color: Color.fromRGBO(255, 255, 255, frost)),
        ),
        Opacity(
          opacity: intensity,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0x40FFFFFF),
                  Color(0x0AFFFFFF),
                  Color(0x12FFE8D4),
                ],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
        Opacity(
          opacity: intensity * 0.7,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.15, 0.55),
                radius: 0.9,
                colors: [
                  Color(0x0A000000),
                  Color(0x00000000),
                ],
              ),
            ),
          ),
        ),
        Opacity(
          opacity: intensity,
          child: const CustomPaint(painter: _GlassOrbPainter()),
        ),
        Opacity(
          opacity: intensity,
          child: Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: Image.asset(
                'assets/images/recipebook_3d_icon.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecipebookCountBadge() {
    final count = _recipebookSavedCount();
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: const BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _buildRecipebookDockHeader(Brightness brightness) {
    final expandedCopyVisible = _recipebookSheetController.value > 0.92;
    final addButtonRawT = (1 - (_recipebookSheetController.value / 0.45)).clamp(
      0.0,
      1.0,
    );
    final addButtonOpacity = Curves.easeOutCubic.transform(addButtonRawT);
    final addButtonScale = lerpDouble(0.86, 1.0, addButtonOpacity)!;
    final addButtonWidthT = addButtonRawT > 0.12
        ? 1.0
        : Curves.easeOutCubic.transform((addButtonRawT / 0.12).clamp(0.0, 1.0));
    final openIconT = Curves.easeInOutCubic.transform(
      ((_recipebookSheetController.value - 0.58) / 0.34).clamp(0.0, 1.0),
    );
    void toggleSheet() {
      if (_recipebookDragging) return;
      _setRecipebookExpanded(!_recipebookHeaderExpandedState);
    }

    // Drag stays on the whole header; tap-to-toggle only wraps non-action
    // areas so search/close buttons are never stolen by the sheet gesture.
    return Listener(
      onPointerUp: (_) => _scheduleRecipebookPointerUpSnap(),
      onPointerCancel: (_) => _scheduleRecipebookPointerUpSnap(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => _onRecipebookDragStart(),
        onVerticalDragUpdate: (details) =>
            _onRecipebookDragUpdate(details.primaryDelta ?? 0),
        onVerticalDragCancel: _onRecipebookDragCancel,
        onVerticalDragEnd: (details) =>
            _onRecipebookDragEnd(details.primaryVelocity ?? 0),
        child: SizedBox(
          height: _recipebookDockHeaderHeight,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggleSheet,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: 1 - openIconT,
                              child: Transform.scale(
                                scale: lerpDouble(1.0, 0.96, openIconT)!,
                                child: Image.asset(
                                  'assets/images/recipebook_3d_icon.png',
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            ),
                            Opacity(
                              opacity: openIconT,
                              child: Transform.scale(
                                scale: lerpDouble(0.96, 1.0, openIconT)!,
                                child: Image.asset(
                                  'assets/images/recipebook_open_3d_icon.png',
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            defaultTargetPlatform == TargetPlatform.iOS
                                ? Row(
                                    children: [
                                      const Flexible(
                                        child: Text(
                                          '나의 레시피북',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.25,
                                            color: Color(0xFF191F28),
                                            height: 1.15,
                                          ),
                                        ),
                                      ),
                                      if (_recipebookSavedCount() > 0) ...[
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Text(
                                            '·',
                                            style: TextStyle(
                                              fontFamily: 'Pretendard',
                                              fontSize: 15,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF191F28),
                                              height: 1,
                                            ),
                                          ),
                                        ),
                                        _buildRecipebookCountBadge(),
                                      ],
                                    ],
                                  )
                                : const Text(
                                    '나의 레시피북',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.25,
                                      color: Color(0xFF191F28),
                                      height: 1.15,
                                    ),
                                  ),
                            if (expandedCopyVisible ||
                                defaultTargetPlatform != TargetPlatform.iOS) ...[
                              const SizedBox(height: 2),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeOutCubic,
                                child: Text(
                                  expandedCopyVisible
                                      ? '아래로 쓸어 내려 홈으로 돌아가기'
                                      : '위로 쓸어 올려 내 레시피 보기',
                                  key: ValueKey<String>(
                                    expandedCopyVisible
                                        ? 'expanded'
                                        : 'collapsed',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF8B95A1),
                                    height: 1.15,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                widthFactor: addButtonWidthT,
                child: IgnorePointer(
                  ignoring: addButtonOpacity < 0.2,
                  child: Transform.scale(
                    scale: addButtonScale,
                    child: Opacity(
                      opacity: addButtonOpacity,
                      child: GestureDetector(
                        onTap: _openAddRecipeFromCollapsedRecipebook,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFFF7A32), Color(0xFFFF6317)],
                            ),
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFFFF6B00,
                                ).withValues(alpha: 0.22),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: toggleSheet,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Center(
                    child: Transform.rotate(
                      angle: _recipebookSheetController.value * math.pi,
                      child: const Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 18,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadRecipebookViewModePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recipebookViewModePrefsKey);
      final next = raw == 'grid'
          ? _RecipebookViewMode.grid
          : _RecipebookViewMode.list;
      if (!mounted || next == _recipebookViewMode) return;
      setState(() => _recipebookViewMode = next);
    } catch (_) {
      // Prefs are best-effort; default stays list.
    }
  }

  Future<void> _saveRecipebookViewModePref(_RecipebookViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _recipebookViewModePrefsKey,
        mode == _RecipebookViewMode.grid ? 'grid' : 'list',
      );
    } catch (_) {}
  }

  void _setRecipebookViewMode(_RecipebookViewMode mode) {
    if (_recipebookViewMode == mode) return;
    setState(() => _recipebookViewMode = mode);
    unawaited(_saveRecipebookViewModePref(mode));
  }

  /// Shared height so search + view toggle share one vertical center line.
  static const double _recipebookToolbarControlHeight = 32;

  Widget _buildRecipebookViewToggle() {
    final isGrid = _recipebookViewMode == _RecipebookViewMode.grid;
    return SizedBox(
      height: _recipebookToolbarControlHeight,
      child: Container(
        padding: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF0F1F3),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE7E8EB), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _recipebookViewToggleButton(
              icon: Icons.view_agenda_rounded,
              selected: !isGrid,
              onTap: () => _setRecipebookViewMode(_RecipebookViewMode.list),
              semanticLabel: '리스트 보기',
            ),
            _recipebookViewToggleButton(
              icon: Icons.grid_view_rounded,
              selected: isGrid,
              onTap: () => _setRecipebookViewMode(_RecipebookViewMode.grid),
              semanticLabel: '썸네일 보기',
            ),
          ],
        ),
      ),
    );
  }

  Widget _recipebookViewToggleButton({
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 28,
            // Outer 32 − border(~1.6) − padding(4).
            height: _recipebookToolbarControlHeight - 6,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF111827) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 14,
              color: selected ? Colors.white : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecipebookInlineSearchField() {
    final hasQuery = _searchQuery.isNotEmpty;
    return Container(
      height: _recipebookToolbarControlHeight,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
      ),
      padding: EdgeInsets.only(left: 12, right: hasQuery ? 6 : 12),
      child: Row(
        children: [
          const Icon(
            Icons.search_rounded,
            size: 16,
            color: Color(0xFF6B7280),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _recipebookSearchFocusNode,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.search,
              showCursor: true,
              decoration: const InputDecoration(
                hintText: '나의 레시피북에서 검색',
                hintStyle: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF99A1AF),
                  letterSpacing: -0.3,
                ),
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111111),
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (hasQuery)
            Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _searchController.clear(),
                child: const SizedBox(
                  width: 24,
                  height: 24,
                  child: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecipebookExpandedTopBar(Brightness brightness) {
    final revealT = Curves.easeOutCubic.transform(
      ((_recipebookSheetController.value - 0.10) / 0.34).clamp(0.0, 1.0),
    );
    // Sheet drag/toggle lives only on the dock header. Wrapping filters here
    // previously stole gestures and left the sheet stuck mid-progress.
    final filterBlock = Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search + view toggle above category pills.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _buildRecipebookInlineSearchField()),
                const SizedBox(width: 8),
                _buildRecipebookViewToggle(),
              ],
            ),
          ),
          _buildRecipebookCategoryPills(),
          if (_selectedRecipebookCategoryId == null) ...[
            _buildPrimaryFilterLayer(brightness),
            _buildSecondaryFilterLayer(brightness),
          ],
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildRecipebookDockHeader(brightness),
        // Clip only while revealing — a full-time ClipRect hard-cuts pill
        // shadows into a razor line above the recipe list.
        if (revealT >= 0.995)
          Opacity(opacity: revealT, child: filterBlock)
        else
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: revealT,
              child: Opacity(opacity: revealT, child: filterBlock),
            ),
          ),
      ],
    );
  }

  bool _recipebookMetaListsEqual(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i]['id'] as String?) != (b[i]['id'] as String?)) return false;
      if ((a[i]['name'] as String?) != (b[i]['name'] as String?)) return false;
    }
    return true;
  }

  bool _recipebookCategoryMapEqual(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i] != other[i]) return false;
      }
    }
    return true;
  }

  /// StreamBuilder는 본문만 rebuild한다. 상단 카테고리 칩은 형제 위젯이라
  /// 메타가 바뀌면 post-frame setState로 HomeScreen 전체를 한 번 더 그린다.
  void _scheduleRecipebookMetaRebuildIfNeeded(SavedRecipesResult data) {
    final newCategories = List<Map<String, dynamic>>.from(
      data.recipebookCategories,
    );
    final newMap = data.recipebookRecipeCategoryMap.map(
      (k, v) => MapEntry(k, List<String>.from(v)),
    );
    // 카테고리 pill 목록의 단일 진실 공급원은 로컬 저장소
    // (recipebookCategoriesRevision → _reloadRecipebookCategoriesFromLocal).
    // 저장 레시피 스트림은 파싱 폴링 때 오래된 _lastRecipebookCategories 를
    // 그대로 재emit 할 수 있어, 이미 로컬에서 채운 목록을 스트림으로 덮지 않는다.
    // (빈 초기 상태에서만 스트림으로 seed)
    final categoriesToApply = _recipebookCategories.isNotEmpty
        ? _recipebookCategories
        : newCategories;
    final mapToApply = newMap.isEmpty && _recipebookRecipeCategoryMap.isNotEmpty
        ? _recipebookRecipeCategoryMap
        : newMap;
    final changed =
        !_recipebookMetaListsEqual(categoriesToApply, _recipebookCategories) ||
        !_recipebookCategoryMapEqual(mapToApply, _recipebookRecipeCategoryMap);
    if (!changed) return;

    _recipebookCategories = categoriesToApply;
    _recipebookRecipeCategoryMap = mapToApply;
    if (_selectedRecipebookCategoryId != null &&
        _recipebookCategories.isNotEmpty &&
        !_recipebookCategories.any(
          (c) => (c['id'] as String?) == _selectedRecipebookCategoryId,
        )) {
      _selectedRecipebookCategoryId = null;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _selectRecipebookCategory(String? categoryId) async {
    final categoryName = categoryId == null
        ? '전체'
        : (_recipebookCategoryNameById(categoryId) ?? categoryId);
    unawaited(
      AnalyticsService().trackHomeCategoryClicked(
        source: 'recipebook',
        categoryId: categoryId ?? 'all',
        categoryName: categoryName,
      ),
    );
    try {
      final uid = _authService.currentUser?.uid;
      if (uid == null) {
        if (!mounted) return;
        setState(() {
          _selectedRecipebookCategoryId = categoryId;
          if (categoryId != null) {
            _selectedPrimaryCategory = '전체';
            _selectedSecondaryCategory = null;
            _selectedTertiaryCategory = null;
          }
        });
        return;
      }
      final map = await LocalStorageService().getRecipebookRecipeCategoryMap(
        uid,
      );
      if (!mounted) return;
      setState(() {
        _recipebookRecipeCategoryMap = map.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        );
        _selectedRecipebookCategoryId = categoryId;
        if (categoryId != null) {
          _selectedPrimaryCategory = '전체';
          _selectedSecondaryCategory = null;
          _selectedTertiaryCategory = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _selectedRecipebookCategoryId = categoryId;
        if (categoryId != null) {
          _selectedPrimaryCategory = '전체';
          _selectedSecondaryCategory = null;
          _selectedTertiaryCategory = null;
        }
      });
    }
  }

  Widget _buildRecipebookCategoryPills() {
    final chips = <Widget>[
      _buildRecipebookCategoryChip(
        label: '전체',
        selected: _selectedRecipebookCategoryId == null,
        onTap: () => _selectRecipebookCategory(null),
      ),
    ];
    for (final category in _recipebookCategories) {
      final categoryId = (category['id'] as String?) ?? '';
      final categoryName = (category['name'] as String?) ?? '';
      if (categoryId.isEmpty || categoryName.isEmpty) continue;
      chips.add(
        _buildRecipebookCategoryChip(
          label: categoryName,
          selected: _selectedRecipebookCategoryId == categoryId,
          // 탭=필터, 길게 누르기=이름변경/삭제
          onTap: () => _selectRecipebookCategory(categoryId),
          onLongPress: () => _showRecipebookCategoryManageSheet(category),
        ),
      );
    }
    chips.add(
      _buildRecipebookCategoryChip(
        label: '카테고리 추가',
        selected: false,
        isAddChip: true,
        leadingIcon: Icons.add_rounded,
        // 바로 만들기 창을 연다 (편집 모드를 거치지 않음).
        onTap: _handleAddRecipebookCategory,
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        // Small gap before taxonomy row — same sticky header group.
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
        child: Row(spacing: 8, children: chips),
      ),
    );
  }

  // Unified pill style — matches `_buildPrimaryFilterLayer` (the taxonomy
  // row directly underneath) so both pill rows inside the recipebook share
  // the same visual language: black-on-white selected, white-with-gray-
  // border unselected. Add-chip uses a subdued gray text with leading "+"
  // glyph but keeps the same shape so it doesn't feel like a separate
  // component.
  Widget _buildRecipebookCategoryChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool isAddChip = false,
    IconData? leadingIcon,
  }) {
    const selectedBg = Color(0xFF111111);
    const unselectedBorder = Color(0xFFE5E7EB);
    const unselectedText = Color(0xFF4B5563);
    const addChipText = Color(0xFF8B95A1);

    final bgColor = selected ? selectedBg : Colors.white;
    final borderColor = selected ? selectedBg : unselectedBorder;
    final textColor = selected
        ? Colors.white
        : (isAddChip ? addChipText : unselectedText);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
      decoration: BoxDecoration(
          color: bgColor,
        borderRadius: BorderRadius.circular(999),
          border: selected ? null : Border.all(color: borderColor, width: 1),
          // No drop shadow — clipped shadows were reading as a hard seam
          // above the recipe list.
          boxShadow: null,
        ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
            if (leadingIcon != null) ...[
              Icon(leadingIcon, size: 14, color: textColor),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: textColor,
                letterSpacing: -0.2,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 로컬 저장소(단일 진실 공급원)에서 카테고리·매핑을 다시 읽어 홈 pill/필터 동기화.
  Future<void> _reloadRecipebookCategoriesFromLocal() async {
    final user = _authService.currentUser;
    if (user == null) return;
    try {
      final cats = await _userService.getRecipebookCategories(user.uid);
      final map = await _userService.getRecipebookRecipeCategoryMap(user.uid);
      if (!mounted) return;
      // 현재 선택된 카테고리가 사라졌으면 전체로 되돌린다.
      final stillExists =
          _selectedRecipebookCategoryId == null ||
          cats.any((c) => (c['id'] as String?) == _selectedRecipebookCategoryId);
      setState(() {
        _recipebookCategories = cats;
        _recipebookRecipeCategoryMap = map.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        );
        if (!stillExists) _selectedRecipebookCategoryId = null;
      });
    } catch (_) {}
  }

  Future<void> _handleAddRecipebookCategory() async {
    final user = _authService.currentUser;
    if (user == null) {
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final createdInput = await _showRecipebookCategoryCreateDialog();
    final name = createdInput?['name'] ?? '';
    final iconKey = createdInput?['iconKey'] ?? 'folder';
    if (name.trim().isEmpty) return;
    try {
      final created = await _userService.addRecipebookCategory(
        user.uid,
        name,
        iconKey: iconKey,
      );
      if (!mounted) return;
      // Optimistically append so the pill appears immediately. Local revision
      // reload + notifyRecipesChanged keep RecipeService cache in sync; the
      // stream must not overwrite this list with a stale category snapshot.
      final createdId = (created['id'] as String?) ?? '';
      final alreadyPresent =
          createdId.isNotEmpty &&
          _recipebookCategories.any((c) => (c['id'] as String?) == createdId);
      setState(() {
        if (!alreadyPresent) {
          _recipebookCategories = [..._recipebookCategories, created];
        }
        // 추가 직후 새 카테고리를 바로 선택해 그 화면으로 이동.
        _selectedRecipebookCategoryId = createdId.isEmpty ? null : createdId;
      });
      showAppSnackBar(context, 
        SnackBar(
          content: Text("'${created['name']}' 카테고리가 추가되었어요"),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Map<String, String>?> _showRecipebookCategoryCreateDialog() async {
    final controller = TextEditingController();
    final iconOptions = <Map<String, dynamic>>[
      {'key': 'folder', 'icon': Icons.folder_rounded},
      {'key': 'rocket', 'icon': Icons.rocket_launch_rounded},
      {'key': 'heart', 'icon': Icons.favorite_rounded},
      {'key': 'group', 'icon': Icons.group_rounded},
      {'key': 'replay', 'icon': Icons.replay_rounded},
      {'key': 'flame', 'icon': Icons.local_fire_department_rounded},
      {'key': 'chef', 'icon': Icons.restaurant_menu_rounded},
      {'key': 'book', 'icon': Icons.menu_book_rounded},
      {'key': 'star', 'icon': Icons.star_rounded},
      {'key': 'check', 'icon': Icons.task_alt_rounded},
    ];
    var selectedIconKey = 'folder';
    final createdData = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) => Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              child: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '새 카테고리 만들기',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF191F28),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F6F8),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      maxLength: 16,
                      decoration: const InputDecoration(
                        hintText: '카테고리 이름',
                        counterText: '',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '아이콘 선택',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B7684),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: iconOptions.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          // 고정 행 높이로 두 줄이 항상 온전히 보이게 한다.
                          mainAxisExtent: 54,
                        ),
                    itemBuilder: (context, index) {
                        final option = iconOptions[index];
                        final key = option['key'] as String;
                        final icon = option['icon'] as IconData;
                        final selected = selectedIconKey == key;
                        return GestureDetector(
                          onTap: () {
                            setLocalState(() {
                              selectedIconKey = key;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            curve: Curves.easeOutCubic,
                            decoration: BoxDecoration(
                              // Monochrome Toss-style: selected = pure
                              // white tile with a crisp 1.5px ink ring
                              // and ink-dark glyph. Unselected stays in
                              // the soft neutral chip. No orange splat.
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFFF7F9FB),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected
                                    ? const Color(0xFF191F28)
                                    : const Color(0xFFE5EAF0),
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Icon(
                              icon,
                              size: 20,
                              color: selected
                                  ? const Color(0xFF191F28)
                                  : const Color(0xFF7B8794),
                            ),
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF6B7684),
                          ),
                          child: const Text('취소'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, {
                            'name': controller.text.trim(),
                            'iconKey': selectedIconKey,
                          }),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFF6B00),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('추가'),
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
      },
    );
    controller.dispose();
    return createdData;
  }

  Future<void> _showRecipebookCategoryManageSheet(
    Map<String, dynamic> category,
  ) async {
    final categoryId = (category['id'] as String?) ?? '';
    final categoryName = (category['name'] as String?) ?? '';
    if (categoryId.isEmpty || categoryName.isEmpty) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              categoryName,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: Color(0xFF4B5563)),
              title: const Text('이름 변경'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.red,
              ),
              title: const Text('카테고리 삭제'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      await _handleRenameRecipebookCategory(category);
    } else if (action == 'delete') {
      await _handleDeleteRecipebookCategory(categoryId, categoryName);
    }
  }

  Future<void> _handleRenameRecipebookCategory(
    Map<String, dynamic> category,
  ) async {
    final user = _authService.currentUser;
    if (user == null) return;
    final categoryId = (category['id'] as String?) ?? '';
    final currentName = (category['name'] as String?) ?? '';
    if (categoryId.isEmpty) return;
    final nextName = await _showRecipebookCategoryNameDialog(
      title: '카테고리 이름 변경',
      initialValue: currentName,
    );
    if (nextName == null || nextName.trim().isEmpty) return;
    try {
      await _userService.renameRecipebookCategory(
        user.uid,
        categoryId: categoryId,
        newName: nextName,
      );
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('카테고리 이름이 변경되었어요'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleDeleteRecipebookCategory(
    String categoryId,
    String categoryName,
  ) async {
    final user = _authService.currentUser;
    if (user == null) return;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '카테고리를 삭제할까요?',
      description: "'$categoryName'에 배정된 레시피는 미분류로 이동됩니다.",
      confirmLabel: '삭제',
    );
    if (confirmed != true || !mounted) return;
    try {
      await _userService.deleteRecipebookCategory(user.uid, categoryId);
      if (!mounted) return;
      setState(() {
        if (_selectedRecipebookCategoryId == categoryId) {
          _selectedRecipebookCategoryId = null;
        }
      });
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('카테고리를 삭제했어요'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<String?> _showRecipebookCategoryNameDialog({
    required String title,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(hintText: '카테고리 이름을 입력해 주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Widget _buildRecipebookBottomAddPill({
    required double morph,
    required double currentWidth,
  }) {
    final bgT = Curves.easeInOutCubic.transform(morph);
    final shadowT = Curves.easeOutCubic.transform(morph);
    final expandedReady = ((currentWidth - 304) / 26)
        .clamp(0.0, 1.0)
        .toDouble();
    final showExpandedLayout = expandedReady > 0.001;
    final expandedOpacity =
        Curves.easeOutCubic.transform((1 - morph).clamp(0.0, 1.0)) *
        expandedReady;
    final basePlusOpacity = Curves.easeInOutCubic.transform(
      ((morph - 0.22) / 0.78).clamp(0.0, 1.0),
    );
    final plusOpacity = basePlusOpacity > (1 - expandedReady)
        ? basePlusOpacity
        : (1 - expandedReady);
    final gradStart = Color.lerp(
      const Color(0xFFFFFFFF),
      const Color(0xFFFF7A32),
      bgT,
    )!;
    final gradEnd = Color.lerp(
      const Color(0xFFFFFFFF),
      const Color(0xFFFF6317),
      bgT,
    )!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openAddRecipeSheet(),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [gradStart, gradEnd],
          ),
          border: Border.all(
            color: Color.lerp(
              const Color(0xFFE5E7EB),
              const Color(0x00FF6B00),
              bgT,
            )!,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Color.lerp(
                Colors.black.withValues(alpha: 0.08),
                const Color(0xFFFF6B00).withValues(alpha: 0.22),
                shadowT,
              )!,
              blurRadius: lerpDouble(8, 18, shadowT)!,
              offset: Offset(0, lerpDouble(2, 6, shadowT)!),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (showExpandedLayout)
                Opacity(
                  opacity: expandedOpacity,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        const YorigoHeaderLogo(height: 17, maxWidth: 70),
          Container(
            width: 1,
            height: 16,
            color: const Color(0xFFE5E7EB),
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),
          const Expanded(
            child: Row(
              children: [
                              Icon(
                                Icons.link_rounded,
                                size: 16,
                                color: Color(0xFF99A1AF),
                              ),
                              SizedBox(width: 7),
                Text(
                  '링크 붙여넣기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF99A1AF),
                                  letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
                        const SizedBox(width: 6),
          Container(
            height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00),
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: const Text(
              '분석하기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                              letterSpacing: -0.25,
              ),
            ),
          ),
        ],
                    ),
                  ),
                ),
              Opacity(
                opacity: plusOpacity,
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAddRecipeFromCollapsedRecipebook() async {
    if (_recipebookSheetController.value < 0.96) {
      _setRecipebookExpanded(true);
      await _waitForRecipebookExpanded();
      if (!mounted) return;
    }
    _openAddRecipeSheet();
  }

  Future<void> _waitForRecipebookExpanded() {
    if (_recipebookSheetController.value >= 0.98) {
      return Future.value();
    }

    final completer = Completer<void>();
    Timer? timeout;
    late VoidCallback listener;

    void finish() {
      if (completer.isCompleted) return;
      timeout?.cancel();
      _recipebookSheetController.removeListener(listener);
      completer.complete();
    }

    listener = () {
      if (_recipebookSheetController.value >= 0.98) {
        finish();
      }
    };

    _recipebookSheetController.addListener(listener);
    timeout = Timer(const Duration(milliseconds: 520), finish);
    listener();

    return completer.future;
  }

  void _openAddRecipeSheet({String? initialUrl}) {
    mainNavigatorKey.currentState?.showAddRecipeSheet(initialUrl: initialUrl);
  }

  Widget _buildAppHeader(Brightness brightness, {required bool loggedIn}) {
    return AppHeader(
      onLoginPressed: () => Navigator.pushNamed(context, '/login'),
      showLoginButton: true,
      showSearchIcon: loggedIn,
      onSearchPressed: loggedIn
          ? () {
              unawaited(
                AnalyticsService().trackSearchOpened(sourceScreen: 'home'),
              );
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RecipeSearchScreen()),
              );
            }
          : null,
      showCalendarIcon: true,
      showNotificationIcon: true,
      onRewardsPressed: () => MainNavigator.of(context)?.navigateToProfile(),
    );
  }

  /// 인기 키워드는 첫 섹션(셰프) 공개 이후에 불러 RAM 피크를 분산한다.
  void _loadHotGroupsOnBoot() {
    _hotGroupsLoading = false;
  }

  void _onTrendingFirstSectionReady() {
    if (_hotGroups.isEmpty) {
      _loadHotGroups();
    }
  }

  /// 셰프 섹션 다음 인기 키워드가 자리 잡은 뒤 소스·디저트가 이어지도록 잠깐 기다린다.
  Future<void> _waitForHotGroupsLeadIn() async {
    if (_hotGroups.isNotEmpty) return;
    if (!_hotGroupsLoading) {
      _loadHotGroups();
    }
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (mounted &&
        _hotGroups.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      if (!_hotGroupsLoading) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 인기 키워드 — 1시간 in-memory 캐시 후 Firestore 재조회 (재진입 시 read 억제).
  void _loadHotGroups() {
    _hotGroupsSub?.cancel();
    _hotGroupsSub = null;
    unawaited(_refreshHotGroups());
  }

  Future<void> _refreshHotGroups() async {
    if (!mounted) return;
    if (_hotGroups.isEmpty) {
      setState(() => _hotGroupsLoading = true);
    }
    try {
      final groups = await _recipeService.getHotRecipeGroupsCached(limit: 30);
      if (!mounted) return;
      final filtered = groups
          .where((g) => ((g['count'] as num?)?.toInt() ?? 0) >= 5)
          .toList();
      filtered.sort((a, b) {
        final ca = (a['count'] as num?)?.toInt() ?? 0;
        final cb = (b['count'] as num?)?.toInt() ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        final ra = (a['recentCount'] as num?)?.toInt() ?? 0;
        final rb = (b['recentCount'] as num?)?.toInt() ?? 0;
        return rb.compareTo(ra);
      });
      setState(() {
        _hotGroups
          ..clear()
          ..addAll(filtered);
        _hotGroupsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _hotGroupsLoading = false);
    }
  }

  /// Pull-to-refresh: 1시간 explore 캐시 무효화 후 Firestore에서 다시 로드.
  Future<void> _onHomePullRefresh() async {
    _recipeService.invalidateExploreCaches();
    await Future.wait([
      _refreshHotGroups(),
      _trendingPageKey.currentState?.reloadFromNetwork() ?? Future.value(),
    ]);
  }

  /// 나의 레시피북 당겨서 새로고침 — 파싱 완료 후 UI 미갱신 등 수동 복구용.
  Future<void> _onRecipebookPullRefresh() async {
    try {
      final uid = _authService.currentUser?.uid;
      if (uid != null) {
        await _userService.ensureRecipebookCategoryDefaults(uid, force: true);
        final categories = await _userService.getRecipebookCategories(uid);
        final map = await _userService.getRecipebookRecipeCategoryMap(uid);
        if (mounted) {
          setState(() {
            _recipebookCategories = List<Map<String, dynamic>>.from(categories);
            _recipebookRecipeCategoryMap = map.map(
              (k, v) => MapEntry(k, List<String>.from(v)),
            );
          });
        }
      }
      await _recipeService.reloadSavedRecipesFromNetwork();
    } catch (_) {
      RecipeService.notifyRecipesChanged();
    }
  }

  Widget _buildHomeHotGroupsSection(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    if (_hotGroupsLoading && _hotGroups.isEmpty) {
      return _buildHomeHotGroupsLoadingSection(brightness, textPrimary);
    }
    if (_hotGroups.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '요즘 인기 메뉴',
                  style: _homeSectionTitleStyle(textPrimary),
                ),
              ],
            ),
          ),
          const SizedBox(height: _homeSectionRuleGap),
          SizedBox(
            // Top inset (8) for the badge that overflows above the circle
            // + diameter (62) + spacing (8) + name line (~18) + breathing
            // (~4) — sized for the compact "tag bubble" carousel.
            height: _hotGroupCircleSize + 40,
              child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
              clipBehavior: Clip.none,
              itemCount: _hotGroups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                return _buildHomeHotGroupCard(
                  _hotGroups[index],
                  brightness,
                  textPrimary,
                  );
                },
              ),
            ),
          _homeSectionRule(),
        ],
      ),
    );
  }

  Widget _buildHomeHotGroupsLoadingSection(
    Brightness brightness,
    Color textPrimary,
  ) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '요즘 인기 메뉴',
                  style: _homeSectionTitleStyle(textPrimary),
                ),
              ],
            ),
          ),
          const SizedBox(height: _homeSectionRuleGap),
          SizedBox(
            height: _hotGroupCircleSize + 40,
            child: _ShimmerScope(
              linearGradient: _shimmerRecipeGradient,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                clipBehavior: Clip.none,
                itemCount: 5,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, __) => _buildHomeHotGroupShimmerCard(),
              ),
            ),
          ),
          _homeSectionRule(),
        ],
      ),
    );
  }

  Widget _buildHomeHotGroupShimmerCard() {
    return SizedBox(
      width: _hotGroupCircleSize,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ShimmerLoading(
            isLoading: true,
            child: Container(
              width: _hotGroupCircleSize,
              height: _hotGroupCircleSize,
              decoration: const BoxDecoration(
                color: _shimmerImagePlaceholderColor,
                shape: BoxShape.circle,
                    ),
                  ),
                ),
          const SizedBox(height: 9),
          _ShimmerLoading(
            isLoading: true,
            child: Container(
              width: 46,
              height: 12,
              decoration: BoxDecoration(
                color: _shimmerImagePlaceholderColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Circular "핫한 레시피" thumbnail diameter. Compact size keeps the
  // section visually airy and reads as a "tag bubble" row rather than a
  // heavy card carousel.
  static const double _hotGroupCircleSize = 62;

  // 인기 키워드 탭 → 해당 해시태그 그룹의 레시피를 '전체 페이지'로 연다.
  // saveCount 순위(1·2·3등 메달) + "N명이 저장했어요" 카운트로 보여준다.
  void _onHomeHotGroupTap(Map<String, dynamic> group) {
    // NavGuard.once is global; awaiting showModalBottomSheet here would keep
    // the guard locked for the entire lifetime of the sheet and silently
    // swallow taps on recipe cards inside (which also use NavGuard.once).
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => HotGroupSheet(
          group: group,
          recipeService: _recipeService,
          backgroundParsingService: _backgroundParsingService,
          userService: _userService,
          brightness: Theme.of(ctx).brightness,
          asPage: true,
        ),
      ),
    );
  }

  Widget _buildHomeHotGroupCard(
    Map<String, dynamic> group,
    Brightness brightness,
    Color textPrimary,
  ) {
    final name = (group['name'] as String?)?.trim() ?? '';
    final count = (group['count'] is num) ? (group['count'] as num).toInt() : 0;
    final thumbnailUrl = (group['latestThumbnailUrl'] as String?)?.trim() ?? '';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onHomeHotGroupTap(group),
      child: SizedBox(
        width: _hotGroupCircleSize,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Circular thumbnail. A subtle inner hairline ring keeps the
                // edge crisp against the home background; the soft drop
                // shadow gives it a quiet "lifted" feel without competing
                // with the rectangular "인기 레시피" cards underneath.
            Container(
                  width: _hotGroupCircleSize,
                  height: _hotGroupCircleSize,
              decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.getBorder(brightness),
                    border: Border.all(
                      color: const Color(0x14000000),
                      width: 0.5,
                    ),
                boxShadow: const [
                  BoxShadow(
                        color: Color(0x12000000),
                        blurRadius: 14,
                        offset: Offset(0, 3),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: thumbnailUrl.isNotEmpty
                      ? AppNetworkImage(
                        imageUrl: thumbnailUrl,
                          fit: BoxFit.cover,
                          width: _hotGroupCircleSize,
                          height: _hotGroupCircleSize,
                          memCacheWidth: AppNetworkImage.avatarCacheSize,
                          memCacheHeight: AppNetworkImage.avatarCacheSize,
                          brightness: brightness,
                          placeholder: _buildHotGroupCirclePlaceholder(),
                          errorWidget: _buildHotGroupCirclePlaceholder(),
                        )
                      : _buildHotGroupCirclePlaceholder(),
                ),
                // Count badge — tiny ink-dark pill perched on the circle's
                // top-right edge. Proportional to the smaller bubble so it
                // reads as an accessory dot, not a UI button. Height is
                // left implicit so the badge grows to fit longer counts
                // (e.g. "143") without clipping descenders.
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 20),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2.5,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF191F28),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 1.2),
                    ),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.1,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              name.isNotEmpty ? name : '레시피',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: textPrimary,
                letterSpacing: -0.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Shimmer placeholder sized for the circular hot-group thumbnail.
  Widget _buildHotGroupCirclePlaceholder() {
    return Container(
      width: _hotGroupCircleSize,
      height: _hotGroupCircleSize,
      decoration: const BoxDecoration(
        color: _shimmerImagePlaceholderColor,
        shape: BoxShape.circle,
      ),
    );
  }

  void _onTrendRecipeTap(
    Map<String, dynamic> recipe, {
    String? sectionTitle,
    int? cardIndex,
    String? sectionKey,
  }) {
    final recipeId = recipe['id'] as String? ?? '';
    if (recipeId.isNotEmpty) {
      final trimmedKey = sectionKey?.trim();
      final sectionId = (trimmedKey != null && trimmedKey.isNotEmpty)
          ? trimmedKey
          : (sectionTitle == null || sectionTitle.trim().isEmpty)
              ? 'unknown'
              : HomeSectionKeys.keyForTitle(sectionTitle);
      unawaited(
        AnalyticsService().trackHomeRecipeClicked(
          recipeId: recipeId,
          sectionId: sectionId,
          sectionName: sectionTitle,
          cardIndex: cardIndex,
          cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
        ),
      );
      final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
      unawaited(
        AnalyticsService().logCardEvent(
          'click',
          screen: 'home',
          sectionId: sectionId,
          cardId: recipeId,
          contentType: 'recipe',
          recipeId: recipeId,
          position: cardIndex,
          recipeCuisineType: snapshot.cuisineType,
          recipeTimeCategory: snapshot.timeCategory,
          recipeMenuType: snapshot.menuType,
          recipeMainIngredient: snapshot.mainIngredient,
          recipeMainIngredientSub: snapshot.mainIngredientSub,
          recipeTags: snapshot.tags,
          recipeNutritionRating: snapshot.nutritionRating,
          recipeIngredientCategories: snapshot.ingredientCategories,
          recipeSourcePlatform: snapshot.sourcePlatform,
          recipeServings: snapshot.servings,
        ),
      );
    }
    NavGuard.once(() async {
      if (recipeId.isEmpty) return;
      final parseResponse = await _recipeService.getRecipeById(recipeId);
      if (parseResponse != null && mounted) {
        Navigator.pushNamed(
          context,
          '/recipe-detail',
          arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
        );
      }
    })();
  }

  void _logRecipebookRecipeClicked(Map<String, dynamic> recipe) {
    final recipeId = recipe['id'] as String? ?? '';
    if (recipeId.isEmpty || recipeId.startsWith('local_')) return;
    unawaited(
      AnalyticsService().trackRecipebookRecipeClicked(
        recipeId: recipeId,
        viewMode: _recipebookViewMode == _RecipebookViewMode.grid
            ? 'grid'
            : 'list',
      ),
    );
    final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
    unawaited(
      AnalyticsService().logCardEvent(
        'click',
        screen: 'home',
        sectionId: 'recipebook',
        cardId: recipeId,
        contentType: 'recipe',
        recipeId: recipeId,
        recipeCuisineType: snapshot.cuisineType,
        recipeTimeCategory: snapshot.timeCategory,
        recipeMenuType: snapshot.menuType,
        recipeMainIngredient: snapshot.mainIngredient,
        recipeMainIngredientSub: snapshot.mainIngredientSub,
        recipeTags: snapshot.tags,
        recipeNutritionRating: snapshot.nutritionRating,
        recipeIngredientCategories: snapshot.ingredientCategories,
        recipeSourcePlatform: snapshot.sourcePlatform,
        recipeServings: snapshot.servings,
      ),
    );
  }

  /// 초개인화 히어로: 추천 메뉴 레시피 상세로 이동.
  void _openRecipeById(String recipeId) {
    if (recipeId.isEmpty) return;
    NavGuard.once(() async {
      final parseResponse = await _recipeService.getRecipeById(recipeId);
      if (!mounted) return;
      if (parseResponse != null) {
        Navigator.pushNamed(
          context,
          '/recipe-detail',
          arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
        );
      } else {
        _openMealCalendar();
      }
    })();
  }

  /// 초개인화 히어로: 식단 캘린더 열기.
  void _openMealCalendar() {
    openMealCalendar(context, initialTabIndex: 1);
  }

  /// optimistic-only 스트림 emit이 전체 목록 캐시를 덮어쓰지 않도록 병합한다.
  SavedRecipesResult _mergeSavedRecipesCacheOnStreamUpdate(
    SavedRecipesResult incoming,
  ) {
    final prev = _savedRecipesCache;
    if (prev == null) return _dedupeSavedRecipesResult(incoming);

    final incomingRecipes = incoming.recipes;
    if (incomingRecipes.isEmpty) return incoming;

    final allIncomingParsing = incomingRecipes.every(
      (r) => (r['status'] as String? ?? 'completed') == 'parsing',
    );
    if (!allIncomingParsing) {
      return _dedupeSavedRecipesResult(incoming);
    }

    final prevHasNonParsing = prev.recipes.any(
      (r) => (r['status'] as String? ?? 'completed') != 'parsing',
    );
    if (!prevHasNonParsing || prev.recipes.length <= incomingRecipes.length) {
      return _dedupeSavedRecipesResult(incoming);
    }

    final merged = List<Map<String, dynamic>>.from(prev.recipes);
    // 죽은 opt_ 고스트 카드 제거 (ID 교체 후 캐시에만 남은 빈 카드).
    merged.removeWhere((r) {
      final id = (r['id'] as String?) ?? '';
      return id.startsWith('opt_') &&
          !RecipeService.isLiveOptimisticRecipeId(id);
    });
    for (final incomingCard in incomingRecipes) {
      final id = incomingCard['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final idx = merged.indexWhere((r) => r['id'] == id);
      if (idx >= 0) {
        merged[idx] = incomingCard;
      } else {
        merged.insert(0, incomingCard);
      }
    }
    return _dedupeSavedRecipesResult(
      SavedRecipesResult(
        merged,
        prev.totalCount > incoming.totalCount
            ? prev.totalCount
            : incoming.totalCount,
        recipebookCategories: incoming.recipebookCategories.isNotEmpty
            ? incoming.recipebookCategories
            : prev.recipebookCategories,
        recipebookRecipeCategoryMap:
            incoming.recipebookRecipeCategoryMap.isNotEmpty
            ? incoming.recipebookRecipeCategoryMap
            : prev.recipebookRecipeCategoryMap,
      ),
    );
  }

  /// 같은 URL / 죽은 opt_ 로 생긴 중복·빈 카드를 목록에서 제거한다.
  SavedRecipesResult _dedupeSavedRecipesResult(SavedRecipesResult result) {
    return SavedRecipesResult(
      RecipeService.dedupeRecipeCardsForDisplay(result.recipes),
      result.totalCount,
      recipebookCategories: result.recipebookCategories,
      recipebookRecipeCategoryMap: result.recipebookRecipeCategoryMap,
    );
  }

  Widget _buildSavedRecipesSection(
    BuildContext context, {
    bool showInlineSearch = true,
    ScrollController? scrollController,
  }) {
    if (!_recipebookStreamActivated) {
      return const SizedBox.shrink();
    }
    final stream = _savedRecipesStream;
    if (stream == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 32),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return StreamBuilder<SavedRecipesResult>(
      stream: stream,
      key: const ValueKey('tempSavedRecipesStream'),
      initialData: _savedRecipesCache,
      builder: (context, snapshot) {
        final brightness = Theme.of(context).brightness;
        if (snapshot.hasData) {
          _savedRecipesCache = _mergeSavedRecipesCacheOnStreamUpdate(
            snapshot.data!,
          );
          // 분석 기록 상태를 레시피 스트림과 동기화(성공/실패/제목/썸네일).
          ParseHistoryService.instance.syncFromRecipes(_savedRecipesCache!.recipes);
          _detectNewParseFailures(snapshot.data!.recipes);
          _scheduleRecipebookMetaRebuildIfNeeded(snapshot.data!);
        }
        final result = snapshot.data ?? _savedRecipesCache;
        final recipes = result?.recipes ?? [];
        final totalCount = result?.totalCount ?? 0;
        final isLoading =
            snapshot.connectionState == ConnectionState.waiting &&
            result == null;
        final hasError = snapshot.hasError;

        if (hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '저장한 레시피',
                style: _tempTextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: _textGray2,
                ),
              ),
            ),
          );
        }

        // Recipebook category filter -> taxonomy filter -> search filter.
        final recipebookCategoryFiltered = _filterRecipesByRecipebookCategory(
          recipes,
        );
        final categoryFiltered = _filterRecipesByCategory(
          recipebookCategoryFiltered,
        );
        final filteredRecipes = _applySearchFilter(categoryFiltered);
        final visibleRecipes = _filterRecipebookVisibleRecipes(
          _applySavedRecipeSort(filteredRecipes),
        );
        final renderRecipes = visibleRecipes.length <= _recipebookVisibleCap
            ? visibleRecipes
            : visibleRecipes.sublist(0, _recipebookVisibleCap);

        if (scrollController != null) {
          // Primary/secondary filters live in the sticky top bar with the
          // category pills — scroll content starts at the recipe list.
          final slivers = <Widget>[
            const SliverToBoxAdapter(child: SizedBox(height: 6)),
            if (isLoading && _authService.currentUser != null)
              SliverToBoxAdapter(
                child: _ShimmerScope(
                  linearGradient: _shimmerRecipeGradient,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < 10; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          _ShimmerLoading(
                            isLoading: true,
                            child: const _RecipeCardShimmerSkeleton(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              )
            else
              _buildRecipeCardsSliver(
                context,
                renderRecipes,
                totalRecipeCount: totalCount,
                hasMoreVisible: renderRecipes.length < visibleRecipes.length,
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
          ];
          return AppRefreshIndicator(
            onRefresh: _onRecipebookPullRefresh,
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (notification) {
                if (notification.depth != 0) return false;
                _onRecipebookScroll();
                return false;
              },
              child: CustomScrollView(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                cacheExtent: 200,
                slivers: slivers,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showInlineSearch) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(33554400),
                    border: Border.all(
                      color: const Color(0xFFE5E7EB),
                      width: 1,
                    ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 21),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      size: 22,
                      color: Color(0xFF111111),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: '나의 레시피북에서 검색',
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF99A1AF),
                            letterSpacing: -0.375,
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF111111),
                          letterSpacing: -0.375,
                        ),
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () => _searchController.clear(),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(0xFF99A1AF),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ],
            if (showInlineSearch) ...[
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Row(
                children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3EE),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        Icons.auto_stories_rounded,
                        size: 15,
                        color: Color(0xFFFF6B00),
                      ),
                    ),
                    const SizedBox(width: 8),
                        Text(
                      '레시피북',
                          style: _tempTextStyle(
                        fontSize: 16,
                            fontWeight: FontWeight.w800,
                        height: 1.2,
                        letterSpacing: -0.3,
                            color: _textDark,
                          ),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 6),
                ],
            // Filters are in the expanded sticky header when showInlineSearch
            // is false (recipebook sheet). Keep them here only for the inline
            // (non-sheet) fallback layout.
            if (showInlineSearch &&
                _selectedRecipebookCategoryId == null) ...[
              _buildPrimaryFilterLayer(brightness),
              _buildSecondaryFilterLayer(brightness),
            ],
            const SizedBox(height: 8),
            (isLoading && _authService.currentUser != null)
                ? _ShimmerScope(
                    linearGradient: _shimmerRecipeGradient,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < 10; i++) ...[
                            if (i > 0) const SizedBox(height: 12),
                            _ShimmerLoading(
                              isLoading: true,
                              child: const _RecipeCardShimmerSkeleton(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : _buildRecipeCardsList(
                    context,
                    renderRecipes,
                    totalRecipeCount: totalCount,
                  ),
          ],
        );
      },
    );
  }

  DateTime? _toDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  DateTime? _savedDateForRecipe(Map<String, dynamic> recipe) {
    return _toDateTime(recipe['_savedAt']) ??
        _toDateTime(recipe['savedAt']) ??
        _toDateTime(recipe['updatedAt']) ??
        _parsedDateForRecipe(recipe);
  }

  DateTime? _parsedDateForRecipe(Map<String, dynamic> recipe) {
    return _toDateTime(recipe['parsingStartedAt']) ??
        _toDateTime(recipe['completedAt']) ??
        _toDateTime(recipe['createdAt']) ??
        _toDateTime(recipe['updatedAt']);
  }

  DateTime _parsingStartedAtForRecipe(
    Map<String, dynamic> recipe,
    String recipeId,
  ) {
    return _toDateTime(recipe['parsingStartedAt']) ??
        _toDateTime(recipe['createdAt']) ??
        _parsingFirstSeen.putIfAbsent(recipeId, () => DateTime.now());
  }

  bool _canShowParsingCancelButton(
    Map<String, dynamic> recipe,
    String recipeId,
  ) {
    final started = _parsingStartedAtForRecipe(recipe, recipeId);
    return DateTime.now().difference(started) >= _kParsingCancelButtonAfter;
  }

  String _formatRecipeSavedDate(Map<String, dynamic> recipe) {
    final date = _savedDateForRecipe(recipe) ?? _parsedDateForRecipe(recipe);
    if (date == null) return '';

    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y.$m.$d';
  }

  /// Saved date chip for recipebook thumbnails (bottom-right).
  Widget _buildRecipebookThumbDateBadge(String addedDate) {
    if (addedDate.isEmpty) return const SizedBox.shrink();
    return Positioned(
      right: 6,
      bottom: 6,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            addedDate,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              height: 1.1,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _applySavedRecipeSort(
    List<Map<String, dynamic>> recipes,
  ) {
    // 검색 중에는 검색 우선순위 정렬을 유지합니다.
    if (_searchQuery.isNotEmpty) return recipes;

    final sorted = List<Map<String, dynamic>>.from(recipes);
    sorted.sort((a, b) {
      final statusA = a['status'] as String? ?? 'completed';
      final statusB = b['status'] as String? ?? 'completed';
      if (statusA == 'parsing' && statusB != 'parsing') return -1;
      if (statusA != 'parsing' && statusB == 'parsing') return 1;
      if (statusA == 'parsing' && statusB == 'parsing') {
        final dateA = _parsedDateForRecipe(a);
        final dateB = _parsedDateForRecipe(b);
        if (dateA != null && dateB != null) return dateB.compareTo(dateA);
        if (dateA != null) return -1;
        if (dateB != null) return 1;
      }

      final dateA = _savedDateForRecipe(a);
      final dateB = _savedDateForRecipe(b);
      if (dateA != null && dateB != null) return dateB.compareTo(dateA);
      if (dateA != null) return -1;
      if (dateB != null) return 1;
      return 0;
    });
    return sorted;
  }

  /// 레시피북에 표시할 카드만 남긴다 (삭제 예정·error 제외, parsing은 모두 표시).
  List<Map<String, dynamic>> _filterRecipebookVisibleRecipes(
    List<Map<String, dynamic>> recipes,
  ) {
    return recipes.where((recipe) {
      final id = recipe['id'] as String? ?? '';
      if (id.isEmpty || _optimisticallyDeletedIds.contains(id)) return false;
      // ID 교체 후 캐시에만 남은 빈 opt_ 카드는 숨긴다.
      if (id.startsWith('opt_') &&
          !RecipeService.isLiveOptimisticRecipeId(id)) {
        return false;
      }
      final st = recipe['status'] as String? ?? 'completed';
      // 실패(error) 카드는 레시피북에 띄우지 않는다. 실패 내역은 '분석 기록'에서 관리.
      return st != 'error' && st != 'cancelled';
    }).toList();
  }

  /// Search match priority (same logic as home): -1 = no match, 1+ = match (higher = better).
  int _getSearchMatchPriority(Map<String, dynamic> recipe, String query) {
    return recipeSearchMatchPriority(recipe, query);
  }

  /// Filter by search query and sort by match priority when searching.
  List<Map<String, dynamic>> _applySearchFilter(
    List<Map<String, dynamic>> recipes,
  ) {
    if (_searchQuery.isEmpty) return recipes;
    final withPriority = recipes
        .map((recipe) {
          final p = _getSearchMatchPriority(recipe, _searchQuery);
          return {'recipe': recipe, 'priority': p};
        })
        .where((e) => (e['priority'] as int) != -1)
        .toList();
    withPriority.sort(
      (a, b) => (b['priority'] as int).compareTo(a['priority'] as int),
    );
    return withPriority
        .map((e) => e['recipe'] as Map<String, dynamic>)
        .toList();
  }

  List<Map<String, dynamic>> _filterRecipesByRecipebookCategory(
    List<Map<String, dynamic>> recipes,
  ) {
    final selectedCategoryId = _selectedRecipebookCategoryId;
    if (selectedCategoryId == null || selectedCategoryId.isEmpty)
      return recipes;
    return recipes.where((recipe) {
      final recipeId = (recipe['id'] as String?) ?? '';
      final fromMap = _recipebookRecipeCategoryMap[recipeId];
      final List<String> recipeCategoryIds;
      if (fromMap != null && fromMap.isNotEmpty) {
        recipeCategoryIds = List<String>.from(fromMap);
      } else {
        final raw = recipe['_recipebookCategoryIds'];
        if (raw is List) {
          recipeCategoryIds = raw
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList();
        } else {
          recipeCategoryIds = const [];
        }
      }
      return recipeCategoryIds.contains(selectedCategoryId);
    }).toList();
  }

  String? _recipebookCategoryNameById(String? categoryId) {
    if (categoryId == null || categoryId.isEmpty) return null;
    for (final category in _recipebookCategories) {
      if ((category['id'] as String?) == categoryId) {
        return (category['name'] as String?)?.trim();
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _filterRecipesByCategory(
    List<Map<String, dynamic>> recipes,
  ) {
    if (_selectedPrimaryCategory == '전체') return recipes;
    final result = <Map<String, dynamic>>[];
    final sec = _selectedSecondaryCategory;

    if (_selectedPrimaryCategory == '재료별') {
      final midCat = sec;
      final tertiary = _selectedTertiaryCategory;
      for (final recipe in recipes) {
        final subTypes = _getIngredientSubTypes(recipe);
        if (midCat == null) {
          result.add(recipe);
          continue;
        }
        // mini doc 은 재료 본문이 없어도 categories.main_ingredient 로
        // 중분류(육류/해산물/…)를 바로 판별할 수 있다.
        final mids = <String>{
          ..._getIngredientMidCategories(subTypes),
          ..._ingredientMidsFromCategories(recipe),
        };
        if (!mids.contains(midCat)) continue;
        if (tertiary == null || subTypes.contains(tertiary)) {
          result.add(recipe);
        }
      }
      return result;
    }

    String categoryField = '';
    String fallbackField = '';
    switch (_selectedPrimaryCategory) {
      case '나라별':
        categoryField = 'cuisine_type';
        fallbackField = 'country';
        break;
      case '메뉴별':
        categoryField = 'menu_type';
        fallbackField = 'menu_type';
        break;
      case '시간':
        categoryField = 'time_category';
        fallbackField = 'cook_time';
        break;
      default:
        return recipes;
    }
    for (final recipe in recipes) {
      final recipeCategories =
          recipe['categories'] as Map<String, dynamic>? ?? {};
      final list =
          (recipeCategories[categoryField] as List?) ??
          (recipeCategories[fallbackField] as List?) ??
          [];
      bool match = false;
      if (sec == null) {
        match = list.isNotEmpty;
      } else {
        match = list.any((e) {
          final val = e?.toString() ?? '';
          return val == sec || val.contains(sec);
        });
      }
      if (match) result.add(recipe);
    }
    return result;
  }

  /// Returns a `(label, isSearch)` description of the most specific active
  /// filter (search > tertiary > secondary > primary). Returns null when the
  /// current view is showing all recipes without any narrowing applied.
  ({String label, bool isSearch})? _activeFilterDescription() {
    if (_searchQuery.isNotEmpty) {
      return (label: _searchQuery, isSearch: true);
    }
    final selectedRecipebookCategoryName = _recipebookCategoryNameById(
      _selectedRecipebookCategoryId,
    );
    if (selectedRecipebookCategoryName != null &&
        selectedRecipebookCategoryName.isNotEmpty) {
      return (label: selectedRecipebookCategoryName, isSearch: false);
    }
    final tertiary = _selectedTertiaryCategory;
    if (tertiary != null && tertiary.isNotEmpty) {
      return (label: tertiary, isSearch: false);
    }
    final secondary = _selectedSecondaryCategory;
    if (secondary != null && secondary.isNotEmpty) {
      return (label: secondary, isSearch: false);
    }
    if (_selectedPrimaryCategory != '전체') {
      return (
        label: _getPrimaryCategoryDisplayName(_selectedPrimaryCategory),
        isSearch: false,
      );
    }
    return null;
  }

  // Empty-state CTA: 활성화된 필터/검색 중 "가장 좁은 한 단계"만 푼다.
  // 한 번에 전부 풀어 전체 카테고리로 점프하면 사용자가 머무르던
  // 카테고리/검색 컨텍스트가 한꺼번에 사라져 탐색이 끊긴다.
  // 우선순위는 _activeFilterDescription 과 동일하게 좁은 것부터.
  void _resetFiltersAndSearch() {
    if (!mounted) return;
    setState(() {
      if (_searchQuery.isNotEmpty) {
      _searchQuery = '';
    _searchController.clear();
        return;
      }
      if (_selectedRecipebookCategoryId != null) {
        _selectedRecipebookCategoryId = null;
        return;
      }
      if (_selectedTertiaryCategory != null &&
          _selectedTertiaryCategory!.isNotEmpty) {
        _selectedTertiaryCategory = null;
        return;
      }
      if (_selectedSecondaryCategory != null &&
          _selectedSecondaryCategory!.isNotEmpty) {
        _selectedSecondaryCategory = null;
        _selectedTertiaryCategory = null;
        return;
      }
      if (_selectedPrimaryCategory != '전체') {
        _selectedPrimaryCategory = '전체';
        _selectedSecondaryCategory = null;
        _selectedTertiaryCategory = null;
        return;
      }
    });
  }

  Widget _buildFilteredEmptyState(({String label, bool isSearch}) filter) {
    final title = filter.isSearch
        ? "'${filter.label}'에 해당하는 레시피가 없어요"
        : '${filter.label}에 해당하는 레시피가 없어요';
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 0, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _resetFiltersAndSearch,
          borderRadius: BorderRadius.circular(16),
          child: CustomPaint(
            foregroundPainter: _DashedRoundedBorderPainter(
              color: const Color(0xFFCBD0D7),
              strokeWidth: 1.0,
              dashLength: 3,
              gapLength: 3.5,
              radius: 16,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                color: const Color(0xFFFCFCFC),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF3F4F6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.search_off_rounded,
                      color: Color(0xFF6B7280),
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: _tempTextStyle(
                      fontSize: 13,
                      color: const Color(0xFF111111),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '필터를 초기화하려면 탭하세요',
                    style: _tempTextStyle(
                      fontSize: 11.5,
                      color: const Color(0xFF9CA3AF),
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

  /// Virtualized recipe rows for the expanded recipebook scroll view.
  Widget _buildRecipeCardsSliver(
    BuildContext context,
    List<Map<String, dynamic>> recipes, {
    int totalRecipeCount = 0,
    bool hasMoreVisible = false,
  }) {
    if (recipes.isEmpty) {
      final activeFilter = _activeFilterDescription();
      if (totalRecipeCount > 0 && activeFilter != null) {
        return SliverToBoxAdapter(
          child: _buildFilteredEmptyState(activeFilter),
        );
      }
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(
            left: 20,
            right: 20,
            top: 0,
            bottom: 8,
          ),
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _openAddRecipeSheet(),
                borderRadius: BorderRadius.circular(16),
                child: CustomPaint(
                  foregroundPainter: _DashedRoundedBorderPainter(
                    color: const Color(0xFFCBD0D7),
                    strokeWidth: 1.0,
                    dashLength: 3,
                    gapLength: 3.5,
                    radius: 16,
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 28,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFCFCFC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF3F4F6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            color: Color(0xFF6B7280),
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '레시피를 추가해 보세요',
                          style: _tempTextStyle(
                            fontSize: 13,
                            color: const Color(0xFF111111),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '영상 링크를 붙여넣고 분석을 시작해 보세요',
                          style: _tempTextStyle(
                            fontSize: 11.5,
                            color: const Color(0xFF9CA3AF),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildStarterExampleLinks(),
          ],
          ),
        ),
      );
    }

    if (_recipebookViewMode == _RecipebookViewMode.grid) {
      return _buildRecipebookGridSliver(
        context,
        recipes,
        hasMoreVisible: hasMoreVisible,
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList.separated(
        itemCount: recipes.length + (hasMoreVisible ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (hasMoreVisible && index == recipes.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final recipe = recipes[index];
          final recipeId = recipe['id'] as String? ?? '$index';
          return RepaintBoundary(
            key: ValueKey('recipebook_card_$recipeId'),
            child: _buildRecipeCardFromData(context, recipe),
          );
        },
      ),
    );
  }

  /// Home-style 2-column thumbnail grid for the recipebook.
  /// Image ratio matches [TrendingAllPage] cards (140×175).
  static const double _recipebookGridImageAspect =
      TrendingAllPage._cardWidth / TrendingAllPage._cardImageHeight; // ~0.80
  // Cell = image (140:175) + title/creator meta (~42). Room for narrow widths.
  static const double _recipebookGridCellAspect = 0.58;

  Widget _buildRecipebookGridSliver(
    BuildContext context,
    List<Map<String, dynamic>> recipes, {
    bool hasMoreVisible = false,
  }) {
    final count = recipes.length + (hasMoreVisible ? 1 : 0);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 18,
          crossAxisSpacing: 12,
          childAspectRatio: _recipebookGridCellAspect,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (hasMoreVisible && index == recipes.length) {
              return const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final recipe = recipes[index];
            final recipeId = recipe['id'] as String? ?? '$index';
            return RepaintBoundary(
              key: ValueKey('recipebook_grid_$recipeId'),
              child: _buildRecipebookGridCardFromData(context, recipe),
            );
          },
          childCount: count,
        ),
      ),
    );
  }

  Widget _buildRecipebookGridCardFromData(
    BuildContext context,
    Map<String, dynamic> recipe,
  ) {
    final brightness = Theme.of(context).brightness;
    final recipeId = recipe['id'] as String? ?? '';
    final status = recipe['status'] as String? ?? 'completed';
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    var thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    if (status == 'parsing') {
      if (thumbnailUrl.isNotEmpty) {
        _parsingThumbnailCache[recipeId] = thumbnailUrl;
      } else {
        thumbnailUrl = _parsingThumbnailCache[recipeId] ?? '';
      }
    }
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final sourceUrl =
        recipe['sourceUrl'] as String? ?? (source['url'] as String?) ?? '';
    var platform = (source['platform'] as String? ?? '').trim();
    if (platform.isEmpty) {
      platform = RecipeService.inferPlatformFromUrl(sourceUrl);
    }
    String creator = '@요리';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    } else if (recipe['chefHandle']?.toString().isNotEmpty == true) {
      final h = recipe['chefHandle'].toString();
      creator = h.startsWith('@') ? h : '@$h';
    }

    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);
    final imageFit = _trendCardImageFit(platform, sourceUrl);
    final imageBg = _trendCardImageBg(platform, sourceUrl);
    final addedDate = _formatRecipeSavedDate(recipe);
    final displayTitle =
        status == 'parsing' && (title == '레시피' || title.isEmpty)
            ? '분석 중..'
            : title;

    Future<void> openDetail() async {
      if (status != 'completed' || recipeId.isEmpty) return;
      _logRecipebookRecipeClicked(recipe);
      final parseResponse = await _recipeService.getRecipeById(recipeId);
      if (parseResponse != null && context.mounted) {
        Navigator.pushNamed(
          context,
          '/recipe-detail',
          arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
        );
      }
    }

    return GestureDetector(
      onTap: status == 'completed' ? NavGuard.once(openDetail) : null,
      onLongPress: recipeId.isEmpty
          ? null
          : () => _handleUnsaveRecipe(recipeId),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Same image ratio as home trend cards (140×175).
          AspectRatio(
            aspectRatio: _recipebookGridImageAspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(
                      TrendingAllPage._cardRadius,
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
                  child: thumbnailUrl.isNotEmpty
                      ? ColoredBox(
                          color: imageBg,
                          child: ThumbnailLetterboxMitigation(
                            platform: platform,
                            imageUrl: thumbnailUrl,
                            sourceUrl: sourceUrl,
                            child: AppNetworkImage(
                              imageUrl: thumbnailUrl,
                              fit: imageFit,
                              width: double.infinity,
                              height: double.infinity,
                              memCacheWidth:
                                  AppNetworkImage.carouselThumbMemCacheWidth,
                              memCacheHeight:
                                  AppNetworkImage.carouselThumbMemCacheHeight,
                              brightness: brightness,
                              placeholder:
                                  TrendingAllPage._shimmerThumbPlaceholder(),
                              errorWidget: TrendingAllPage._thumbFallback(),
                            ),
                          ),
                        )
                      : status == 'parsing'
                          ? const ColoredBox(
                              color: Color(0xFFF3F4F6),
                              child: Center(
                                child: SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Color(0xFFFF6B00),
                                  ),
                                ),
                              ),
                            )
                          : TrendingAllPage._thumbFallback(),
                ),
                if (status == 'error')
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC111827),
                        borderRadius: BorderRadius.circular(
                          TrendingAllPage._cardRadius,
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.error_outline_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                if (recipeId.isNotEmpty && status == 'completed')
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _handleUnsaveRecipe(recipeId),
                        child: const SizedBox(
                          width: 26,
                          height: 26,
                          child: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                _buildRecipebookThumbDateBadge(addedDate),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            displayTitle.length > 14
                ? '${displayTitle.substring(0, 14)}…'
                : displayTitle,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: textPrimary,
              letterSpacing: -0.33,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _trendPlatformIcon(platform, 14, brightness),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  status == 'parsing' ? '분석 중' : creator,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: textTertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          RecipeCardSocialRow(recipe: recipe, color: textTertiary),
        ],
      ),
    );
  }

  Widget _buildRecipeCardsList(
    BuildContext context,
    List<Map<String, dynamic>> recipes, {
    int totalRecipeCount = 0,
  }) {
    if (recipes.isEmpty) {
      final activeFilter = _activeFilterDescription();
      // User has saved recipes but the current filter/search yields nothing.
      if (totalRecipeCount > 0 && activeFilter != null) {
        return _buildFilteredEmptyState(activeFilter);
      }
      return Padding(
        padding: const EdgeInsets.only(left: 20, right: 20, top: 0, bottom: 8),
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _openAddRecipeSheet(),
                borderRadius: BorderRadius.circular(16),
                child: CustomPaint(
                  foregroundPainter: _DashedRoundedBorderPainter(
                    color: const Color(0xFFCBD0D7),
                    strokeWidth: 1.0,
                    dashLength: 3,
                    gapLength: 3.5,
                    radius: 16,
                  ),
                  child: Container(
      width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 28,
                      horizontal: 20,
                    ),
      decoration: BoxDecoration(
                      color: const Color(0xFFFCFCFC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
        children: [
          Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF3F4F6),
                            shape: BoxShape.circle,
                          ),
            child: const Icon(
                            Icons.add_rounded,
                            color: Color(0xFF6B7280),
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '레시피를 추가해 보세요',
                          style: _tempTextStyle(
                  fontSize: 13,
                            color: const Color(0xFF111111),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '영상 링크를 붙여넣고 분석을 시작해 보세요',
                          style: _tempTextStyle(
                            fontSize: 11.5,
                            color: const Color(0xFF9CA3AF),
                          ),
                        ),
                ],
              ),
            ),
          ),
              ),
            ),
            const SizedBox(height: 12),
            _buildStarterExampleLinks(),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in recipes.asMap().entries) ...[
            if (entry.key > 0) const SizedBox(height: 12),
            _buildRecipeCardFromData(context, entry.value),
          ],
        ],
      ),
    );
  }

  Widget _buildStarterExampleLinks() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0F1F3), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '처음이라면 이 링크로 연습해보세요',
            style: _tempTextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF111827),
              letterSpacing: -0.25,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '누르면 링크가 자동으로 붙여넣어져요',
            style: _tempTextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF9CA3AF),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 10),
          Column(
            children: [
              for (final entry in featuredExampleVideos.asMap().entries) ...[
                if (entry.key > 0) const SizedBox(height: 8),
                _buildStarterExampleButton(entry.value),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStarterExampleButton(Map<String, String> example) {
    final platform = example['platform'] ?? 'youtube';
    final platformLabel = switch (platform) {
      'instagram' => 'Instagram',
      'tiktok' => 'TikTok',
      'naver_blog' => 'Naver Blog',
      _ => 'YouTube',
    };
    final assetPath = switch (platform) {
      'instagram' => 'lib/assets/instagram-app-icon-hd.png',
      'tiktok' => 'lib/assets/tiktok-app-icon-hd.png',
      'naver_blog' => 'assets/icons/naver_blog_icon.png',
      _ => 'lib/assets/youtube-app-icon-hd.png',
    };
    final url = example['url'] ?? '';
    final creator = example['creator'] ?? platformLabel;
    final title = example['title'] ?? '샘플 레시피 영상';
    final iconSize = platform == 'naver_blog' ? 28.0 : 34.0;
    return Material(
      color: const Color(0xFFF9FAFB),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: url.isEmpty ? null : () => _openAddRecipeSheet(initialUrl: url),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                  width: 34,
                  height: 34,
                child: Center(
                  child: SizedBox(
                    width: iconSize,
                    height: iconSize,
                    child: Image.asset(
                      assetPath,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$platformLabel · $creator',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _tempTextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF9CA3AF),
                        letterSpacing: -0.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _tempTextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF374151),
                        letterSpacing: -0.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: Color(0xFFB4BAC4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 토스식 "분석 중" 카드.
  ///  - 왼쪽: 아이콘 없이 부드러운 배경 위에서 계속 도는 주황 링(진행률 무관, 리셋 버그 없음).
  ///  - 가운데: 영상 제목을 바로 노출 + 4단계 안내가 순차로 전환되어 지루하지 않게.
  Widget _buildParsingCard({
    required BuildContext context,
    required String recipeId,
    required bool showCancelButton,
    required String title,
    required bool hasRealTitle,
    required String platform,
    required String creator,
    required String addedDate,
  }) {
    final brightness = Theme.of(context).brightness;
    final headline = hasRealTitle ? title : '레시피를 불러오고 있어요';
    final showFooter =
        creator.isNotEmpty || platform.isNotEmpty || addedDate.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
      height: _cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(_cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: _cardImageWidth,
                height: _cardImageHeight,
                decoration: const BoxDecoration(color: Colors.white),
                child: const ParsingSpinnerRing(),
              ),
            ),
            const SizedBox(width: _cardImageRightGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    headline,
                    style: _tempTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 19.25 / 14,
                      letterSpacing: -0.35,
                      color: _textDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  const ParsingStageCarousel(),
                  const Spacer(),
                  if (showFooter)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: (creator.isNotEmpty || platform.isNotEmpty)
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildPlatformIconForCreator(
                                      platform,
                                      brightness,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        creator,
                                        style: _tempTextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          height: 16.5 / 11,
                                          color: _textGray2,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (addedDate.isNotEmpty)
                          Text(
                            addedDate,
                            style: _tempTextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              height: 15 / 10,
                              color: _placeholder,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
        if (showCancelButton)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => _confirmCancelParsing(recipeId),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: Color(0xFF9CA3AF),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecipeCardFromData(
    BuildContext context,
    Map<String, dynamic> recipe,
  ) {
    final recipeId = recipe['id'] as String? ?? '';
    final status = recipe['status'] as String? ?? 'completed';
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    var thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    if (status == 'parsing') {
      if (thumbnailUrl.isNotEmpty) {
        _parsingThumbnailCache[recipeId] = thumbnailUrl;
      } else {
        thumbnailUrl = _parsingThumbnailCache[recipeId] ?? '';
      }
    } else {
      _parsingThumbnailCache.remove(recipeId);
      _parsingFirstSeen.remove(recipeId);
      _stuckKeepWaitingIds.remove(recipeId);
    }
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final sourceUrl =
        recipe['sourceUrl'] as String? ?? (source['url'] as String?) ?? '';
    final addedDate = _formatRecipeSavedDate(recipe);

    // Parsing in progress: progress bar, blank time/calories, no tags, optional platform/creator
    if (status == 'parsing') {
      // 분석이 평소보다 오래 걸리는지 감지(무한 스피너 방지).
      final firstSeen =
          _parsingFirstSeen.putIfAbsent(recipeId, () => DateTime.now());
      final bool isStuck =
          DateTime.now().difference(firstSeen) >= _kParsingStuckAfter &&
              !_stuckKeepWaitingIds.contains(recipeId);
      if (isStuck) {
        return _buildParsingStuckCard(
          context: context,
          recipeId: recipeId,
          title: recipeData['title'] as String? ?? title,
          sourceUrl: sourceUrl,
          thumbnailUrl: thumbnailUrl,
        );
      }
      String? creator;
      final uploaderStr =
          recipe['uploader']?.toString() ??
          source['uploader']?.toString() ??
          '';
      final channelStr =
          recipe['channel']?.toString() ?? source['channel']?.toString() ?? '';
      if (uploaderStr.isNotEmpty) {
        creator = uploaderStr.startsWith('@') ? uploaderStr : '@$uploaderStr';
      } else if (channelStr.isNotEmpty) {
        creator = channelStr.startsWith('@') ? channelStr : '@$channelStr';
      }
      var platform = (source['platform'] as String? ?? '').trim();
      if (platform.isEmpty) {
        platform = RecipeService.inferPlatformFromUrl(sourceUrl);
      }
      final parsingTitle = recipeData['title'] as String? ?? '분석 중..';
      final hasRealTitle = parsingTitle != '분석 중..' && parsingTitle.isNotEmpty;
      return _buildParsingCard(
        context: context,
        recipeId: recipeId,
        showCancelButton: _canShowParsingCancelButton(recipe, recipeId),
        title: parsingTitle,
        hasRealTitle: hasRealTitle,
        platform: platform,
        creator: creator ?? '',
        addedDate: addedDate,
      );
    }

    // Error: show error message and delete/retry
    if (status == 'error') {
      final errorMessage = recipe['error'] as String? ?? '파싱 실패';
      final errorType = recipe['errorType'] as String? ?? 'server_error';
      final retryCount = recipe['retryCount'] as int? ?? 0;
      return _buildRecipeErrorCard(
        context: context,
        recipeId: recipeId,
        title: recipeData['title'] as String? ?? title,
        errorMessage: errorMessage,
        errorType: errorType,
        retryCount: retryCount,
        sourceUrl: sourceUrl,
        addedDate: addedDate,
        thumbnailUrl: thumbnailUrl,
      );
    }

    // Completed: full card
    final ingredients = recipeData['ingredients'] as List? ?? [];
    final steps = recipeData['steps'] as List? ?? [];
    int totalMinutes = 0;
    for (var step in steps) {
      if (step is Map && step['est_minutes'] != null) {
        totalMinutes += (step['est_minutes'] as num).toInt();
      }
    }
    if (totalMinutes == 0) totalMinutes = 15;
    final calories =
        recipe['calories'] as num? ?? recipeData['calories'] as num? ?? 0;
    String creator = '@';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    } else if (recipe['chefHandle']?.toString().isNotEmpty == true) {
      final h = recipe['chefHandle'].toString();
      creator = h.startsWith('@') ? h : '@$h';
    } else {
      creator = 'Chef';
    }
    final tagsRaw = recipe['tags'] as List? ?? [];
    final tags = filterRecipeTagsForDisplay(tagsRaw);
    if (tags.isEmpty) tags.add('레시피');
    final platform = source['platform'] as String? ?? '';

    return _buildOneRecipeCard(
      title: title,
      tags: tags,
      ingredientsCount: '${ingredients.length}',
      time: '$totalMinutes',
      kcal: '${calories.toInt()}',
      creator: creator,
      platform: platform,
      sourceUrl: sourceUrl,
      addedDate: addedDate,
      imageUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : null,
      onTap: NavGuard.once(() async {
        _logRecipebookRecipeClicked(recipe);
        final parseResponse = await _recipeService.getRecipeById(recipeId);
        if (parseResponse != null && context.mounted) {
          Navigator.pushNamed(
            context,
            '/recipe-detail',
            arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
          );
        }
      }),
      onUnsave: () => _handleUnsaveRecipe(recipeId),
    );
  }

  /// Confirm + remove the recipe from the user's saved list. Used by the
  /// floating delete button on recipebook cards.
  Future<void> _handleUnsaveRecipe(String recipeId) async {
    if (recipeId.isEmpty) return;

    // Local recipes (saved in SharedPreferences while logged out) are not
    // tied to a Firestore user — delete them directly without requiring login.
    if (recipeId.startsWith('local_')) {
      final confirmed = await AppConfirmDialog.show(
        context: context,
        title: '레시피를 삭제할까요?',
        description: '기기에 저장된 레시피가 삭제됩니다.',
        confirmLabel: '삭제',
      );
      if (confirmed != true || !mounted) return;

      setState(() {
        _optimisticallyDeletedIds.add(recipeId);
      });
      try {
        await _recipeService.deleteRecipe(recipeId);
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('레시피가 삭제되었습니다'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _optimisticallyDeletedIds.remove(recipeId);
          });
          showAppSnackBar(context, 
            SnackBar(
              content: Text('삭제 중 오류가 발생했습니다: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      return;
    }

    final user = _authService.currentUser;
    if (user == null) {
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('로그인이 필요합니다'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '레시피북에서 제거할까요?',
      description: '저장된 레시피 목록에서 제거되며, 언제든지 다시 저장할 수 있어요.',
      confirmLabel: '제거',
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _optimisticallyDeletedIds.add(recipeId);
    });
    try {
      await _userService.removeSavedRecipe(user.uid, recipeId);
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('레시피북에서 제거되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _optimisticallyDeletedIds.remove(recipeId);
        });
        showAppSnackBar(context, 
          SnackBar(
            content: Text('제거 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildRecipeErrorCard({
    required BuildContext context,
    required String recipeId,
    required String title,
    required String errorMessage,
    required String errorType,
    required int retryCount,
    required String sourceUrl,
    required String addedDate,
    String? thumbnailUrl,
  }) {
    String cardTitle;
    String cardSubtitle;
    bool showRetry;
    IconData headerIcon;

    switch (errorType) {
      case 'not_cooking':
        cardTitle = '레시피 영상이 아니에요';
        cardSubtitle = '레시피가 포함된 요리 영상을 넣어주세요!';
        showRetry = false;
        headerIcon = Icons.videocam_off_rounded;
        break;
      case 'video_too_long':
        cardTitle = '영상 길이가 너무 길어요';
        cardSubtitle = '15분 이내 영상만 분석할 수 있어요. 더 짧은 영상을 넣어주세요.';
        showRetry = false;
        headerIcon = Icons.timer_off_rounded;
        break;
      case 'insufficient_info':
        cardTitle = '레시피 정보가 부족해요';
        cardSubtitle = '재료와 조리법이 자세히 나오는 영상을 넣어주세요!';
        showRetry = false;
        headerIcon = Icons.info_outline_rounded;
        break;
      default:
        cardTitle = '서버가 잠시 붐볐어요';
        if (retryCount >= 2) {
          cardSubtitle = '곧 정상화돼요. 링크는 기록에 안전하게 보관했어요';
          showRetry = false;
        } else {
          cardSubtitle = '일시적인 문제예요. 링크는 안전하게 보관했어요';
          showRetry = true;
        }
        headerIcon = Icons.cloud_off_rounded;
        break;
    }

    const accentColor = Color(0xFFFF6B00);

    return Container(
      height: _cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 1, color: accentColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(_cardPadding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: _cardImageWidth,
                  height: _cardImageHeight,
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      width: 1,
                      color: const Color(0xFFE5E7EB),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
                      ? AppNetworkImage(
                          imageUrl: thumbnailUrl,
                          fit: BoxFit.cover,
                          width: _cardImageWidth,
                          height: _cardImageHeight,
                          memCacheWidth:
                              AppNetworkImage.recipeBookThumbMemCacheWidth,
                          memCacheHeight:
                              AppNetworkImage.recipeBookThumbMemCacheHeight,
                          errorWidget: const Center(
                            child: Icon(
                              Icons.error_outline_rounded,
                              color: Color(0xFF9B9BA3),
                              size: 32,
                            ),
                          ),
                        )
                      : const Center(
                          child: Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFF9B9BA3),
                            size: 32,
                          ),
                        ),
                ),
                const SizedBox(width: _cardImageRightGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(headerIcon, color: accentColor, size: 14),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              cardTitle,
                              style: _tempTextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                height: 17.5 / 14,
                                letterSpacing: -0.35,
                                color: const Color(0xFF111111),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        cardSubtitle,
                        style: _tempTextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF6B7280),
                          height: 16.2 / 12,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          if (showRetry) ...[
                            Expanded(
                              child: GestureDetector(
                                onTap: sourceUrl.isEmpty
                                    ? null
                                    : () async {
                                        await _backgroundParsingService
                                            .retryParsing(
                                              recipeId: recipeId,
                                              url: sourceUrl,
                                              preferLang: 'ko',
                                            );
                                        if (!context.mounted) return;
                                        setState(() {});
                                      },
                                child: Container(
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF6B00),
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(
                                          0xFFFF6B00,
                                        ).withValues(alpha: 0.2),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.refresh_rounded,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '다시 시도',
                                        style: _tempTextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          height: 18 / 12,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                setState(() {
                                  _optimisticallyDeletedIds.add(recipeId);
                                });
                                _recipeService
                                    .deleteRecipe(recipeId)
                                    .catchError((e) {
                                      if (mounted) {
                                        setState(() {
                                          _optimisticallyDeletedIds.remove(
                                            recipeId,
                                          );
                                        });
                                      }
                                    });
                              },
                              child: Container(
                                height: 32,
                                decoration: BoxDecoration(
                                  color: _border,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Image.asset(
                                      'assets/icons/trash_icon.png',
                                      width: 14,
                                      height: 14,
                                      color: const Color(0xFF4B5563),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '삭제',
                                      style: _tempTextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: const Color(0xFF4B5563),
                                        height: 18 / 12,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildErrorReportButton(
                            recipeId: recipeId,
                            sourceUrl: sourceUrl,
                            errorType: errorType,
                            errorMessage: errorMessage,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 에러 카드의 원탭 "개발팀에 알리기" 버튼. 실패 맥락을 관리자에게 바로 전송.
  Widget _buildErrorReportButton({
    required String recipeId,
    required String sourceUrl,
    required String errorType,
    required String errorMessage,
  }) {
    final bool reported = _reportedParseIds.contains(recipeId);
    return GestureDetector(
      onTap: reported
          ? null
          : () => _reportParseFailure(
                reason: 'failed',
                recipeId: recipeId,
                sourceUrl: sourceUrl,
                errorType: errorType,
                errorMessage: errorMessage,
              ),
      child: Container(
        width: 38,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE9EDF2), width: 0.9),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(
          reported ? Icons.check_rounded : Icons.campaign_rounded,
          size: 17,
          color: reported
              ? const Color(0xFF059669)
              : const Color(0xFFFF6B00),
        ),
      ),
    );
  }

  Future<void> _reportParseFailure({
    required String reason,
    required String recipeId,
    required String sourceUrl,
    String? errorType,
    String? errorMessage,
  }) async {
    if (_reportedParseIds.contains(recipeId)) return;
    setState(() => _reportedParseIds.add(recipeId));
    try {
      await ParseFailureReportService.instance.report(
        reason: reason,
        recipeId: recipeId,
        sourceUrl: sourceUrl,
        kind: sourceUrl.isEmpty ? 'text' : 'link',
        errorType: errorType,
        errorMessage: errorMessage,
        platform: sourceUrl.isEmpty
            ? ''
            : RecipeService.inferPlatformFromUrl(sourceUrl),
      );
      ParseHistoryService.instance.markReported(recipeId);
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('알려주셔서 감사해요! 빠르게 살펴보고 개선할게요.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _reportedParseIds.remove(recipeId));
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('잠시 후 다시 시도해 주세요.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 새로 발생한 분석 실패를 감지해 '분석 기록'으로 안내하는 스낵바를 띄운다.
  /// (실패 카드는 레시피북에 노출하지 않으므로, 사용자가 "놓친" 느낌을 받지 않도록.)
  void _detectNewParseFailures(List<Map<String, dynamic>> recipes) {
    final errorRecipes = recipes
        .where((r) => (r['status'] as String? ?? '') == 'error')
        .where((r) => (r['id'] as String? ?? '').isNotEmpty)
        .toList();
    final errorIds = errorRecipes.map((r) => r['id'] as String).toSet();
    if (!_errorNotifInitialized) {
      // 앱 진입 시점에 이미 있던 실패는 알림 없이 기록만 한다.
      _seenErrorIds.addAll(errorIds);
      _errorNotifInitialized = true;
      return;
    }
    final fresh = errorIds.difference(_seenErrorIds);
    if (fresh.isEmpty) return;
    // 처음 보는 실패 id는 모두 '본 것'으로 기록해 재emit 시 중복 알림을 막는다.
    _seenErrorIds.addAll(fresh);

    // 스트림은 로컬 캐시 → 서버 순으로 여러 번 emit되므로, 캐시가 비어있던
    // 첫 접속(캐시 삭제 후)에는 과거 실패가 뒤늦게 "새 실패"처럼 들어온다.
    // 실제 실패 발생 시각이 이번 세션 시작 이후인 것만 사용자에게 알린다.
    final cutoff = _sessionStartedAt.subtract(const Duration(minutes: 1));
    final freshRecipes = errorRecipes
        .where((e) => fresh.contains(e['id'] as String))
        .where((e) {
          final failedAt = _parsedDateForRecipe(e);
          return failedAt != null && !failedAt.isBefore(cutoff);
        })
        .toList()
      ..sort((a, b) => (_parsedDateForRecipe(b) ?? DateTime(0))
          .compareTo(_parsedDateForRecipe(a) ?? DateTime(0)));
    if (freshRecipes.isEmpty) return;

    final r = freshRecipes.first;
    final source = r['source'] as Map<String, dynamic>?;
    final url =
        (r['sourceUrl'] as String?) ?? (source?['url'] as String?) ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showParseFailedSnack(
          recipeId: r['id'] as String,
          sourceUrl: url,
          errorType: r['errorType'] as String?,
          errorMessage: r['error'] as String?,
        );
      }
    });
  }

  /// 분석 실패 시 뜨는 팝업. '분석 기록'과 '개발팀에 알리기' 두 가지 행동만 제공한다.
  void _showParseFailedSnack({
    required String recipeId,
    required String sourceUrl,
    String? errorType,
    String? errorMessage,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    final reason = _parseFailureReason(errorType, errorMessage);
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1F2330),
        elevation: 6,
        duration: const Duration(seconds: 7),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_off_rounded,
                    size: 16, color: Color(0xFFFFB37A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _parseFailureHeadline(errorType, errorMessage),
                    style: _tempTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              reason,
              style: _tempTextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFCBD2DE),
                height: 1.35,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _parseFailSnackButton(
                    label: '분석 기록',
                    icon: Icons.history_rounded,
                    filled: false,
                    onTap: () {
                      messenger.hideCurrentSnackBar();
                      _openParseHistoryFromHome();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _parseFailSnackButton(
                    label: '개발팀에 알리기',
                    icon: Icons.campaign_rounded,
                    filled: true,
                    onTap: () {
                      messenger.hideCurrentSnackBar();
                      _reportParseFailure(
                        reason: 'failed',
                        recipeId: recipeId,
                        sourceUrl: sourceUrl,
                        errorType: errorType,
                        errorMessage: errorMessage,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _parseFailSnackButton({
    required String label,
    required IconData icon,
    required bool filled,
    required VoidCallback onTap,
  }) {
    final Color fg = filled ? Colors.white : const Color(0xFFE5E9F0);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? const Color(0xFFFF6B00) : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _tempTextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 실패 팝업의 부드러운 헤드라인. "실패"라는 단정 대신 안심되는 톤으로.
  String _parseFailureHeadline(String? errorType, [String? errorMessage]) {
    switch (resolveDisplayedParseErrorType(
      errorType: errorType,
      errorMessage: errorMessage,
    )) {
      case 'not_cooking':
        return '레시피 영상이 아니었어요';
      case 'video_too_long':
        return '영상이 조금 길었어요';
      case 'insufficient_info':
        return '레시피 정보가 조금 부족했어요';
      case 'unsupported_url':
      case 'invalid_url':
        return '링크를 한 번만 확인해 주세요';
      case 'network_error':
        return '네트워크 연결을 확인해 주세요';
      case 'server_error':
        return '서버가 잠시 붐볐어요';
      default:
        return '레시피를 마저 가져오지 못했어요';
    }
  }

  /// 실패 사유 타입을 사용자 친화 멘트로 변환(팝업/기록 공용).
  String _parseFailureReason(String? errorType, String? errorMessage) {
    final raw = (errorMessage ?? '').trim();
    switch (resolveDisplayedParseErrorType(
      errorType: errorType,
      errorMessage: errorMessage,
    )) {
      case 'not_cooking':
        return '요리 과정이 담긴 영상으로 다시 시도해 주세요.';
      case 'video_too_long':
        return '15분 이내 영상이면 더 잘 분석돼요.';
      case 'insufficient_info':
        return '재료·조리법이 잘 보이는 영상이면 더 잘 담겨요.';
      case 'unsupported_url':
      case 'invalid_url':
        return '지원하는 링크인지 한 번만 확인해 주세요.';
      case 'network_error':
        return '네트워크를 확인한 뒤 다시 시도해 주세요. 서버가 고장난 것은 아니에요.';
      case 'server_error':
        return '링크는 기록에 안전하게 보관했어요. 조금 뒤 다시 시도해 주세요.';
      default:
        if (raw.isNotEmpty) return raw;
        return '링크는 기록에 안전하게 보관했어요. 분석 기록에서 다시 시도할 수 있어요.';
    }
  }

  void _openParseHistoryFromHome() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const ParseHistoryScreen()),
    );
  }

  /// 분석이 평소보다 오래 걸릴 때 보여주는 안심 카드(무한 스피너 방지).
  /// 계속 기다리기 / 개발팀에 알리기 / 그만두기 선택지를 제공한다.
  Widget _buildParsingStuckCard({
    required BuildContext context,
    required String recipeId,
    required String title,
    required String sourceUrl,
    String? thumbnailUrl,
  }) {
    const accent = Color(0xFF2563EB);
    final bool reported = _reportedParseIds.contains(recipeId);
    return Container(
      height: _cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 1, color: accent.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(_cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: _cardImageWidth,
              height: _cardImageHeight,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(width: 1, color: const Color(0xFFE5E7EB)),
              ),
              clipBehavior: Clip.antiAlias,
              child: (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
                  ? AppNetworkImage(
                      imageUrl: thumbnailUrl,
                      fit: BoxFit.cover,
                      width: _cardImageWidth,
                      height: _cardImageHeight,
                      memCacheWidth:
                          AppNetworkImage.recipeBookThumbMemCacheWidth,
                      memCacheHeight:
                          AppNetworkImage.recipeBookThumbMemCacheHeight,
                      errorWidget: const Center(
                        child: Icon(Icons.hourglass_bottom_rounded,
                            color: accent, size: 30),
                      ),
                    )
                  : const Center(
                      child: Icon(Icons.hourglass_bottom_rounded,
                          color: accent, size: 30),
                    ),
            ),
            const SizedBox(width: _cardImageRightGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.hourglass_bottom_rounded,
                          color: accent, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '분석이 평소보다 오래 걸려요',
                          style: _tempTextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            height: 17.5 / 14,
                            letterSpacing: -0.35,
                            color: const Color(0xFF111111),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '서버가 붐비는 중일 수 있어요. 계속 기다리거나 기록에서 다시 시도할 수 있어요.',
                    style: _tempTextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6B7280),
                      height: 16.2 / 12,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _stuckKeepWaitingIds.add(recipeId);
                            });
                          },
                          child: Container(
                            height: 32,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '계속 기다리기',
                              style: _tempTextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 18 / 12,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: reported
                            ? null
                            : () => _reportParseFailure(
                                  reason: 'stuck',
                                  recipeId: recipeId,
                                  sourceUrl: sourceUrl,
                                  errorType: 'stuck',
                                  errorMessage: '분석이 오래 걸림',
                                ),
                        child: Container(
                          width: 38,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: const Color(0xFFE9EDF2), width: 0.9),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            reported
                                ? Icons.check_rounded
                                : Icons.campaign_rounded,
                            size: 17,
                            color: reported
                                ? const Color(0xFF059669)
                                : accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _confirmCancelParsing(recipeId),
                        child: Container(
                          width: 38,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _border,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.close_rounded,
                              size: 16, color: Color(0xFF9CA3AF)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancelParsing(String recipeId) async {
    if (recipeId.isEmpty) return;

    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '분석을 취소하시겠어요?',
      description: '진행 중인 분석이 중단되고 레시피북에서 사라집니다.',
      confirmLabel: '예',
      cancelLabel: '아니오',
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _optimisticallyDeletedIds.add(recipeId);
      _parsingFirstSeen.remove(recipeId);
      _stuckKeepWaitingIds.remove(recipeId);
      _parsingThumbnailCache.remove(recipeId);
    });
    try {
      await _backgroundParsingService.cancelParsing(recipeId);
    } catch (_) {
      // best-effort
    }
  }

  List<Map<String, dynamic>> _getSecondaryFilters(String primaryCategory) {
    switch (primaryCategory) {
      case '나라별':
        return reorderCountryFilters(
          [
            {'label': '한식', 'icon': Icons.restaurant_menu},
            {'label': '양식', 'icon': Icons.restaurant},
            {'label': '일식', 'icon': Icons.set_meal},
            {'label': '중식', 'icon': Icons.dinner_dining},
            {'label': '아시안', 'icon': Icons.ramen_dining},
            {'label': '기타', 'icon': Icons.public},
          ],
          _onboardingProfile,
        );
      case '시간':
        return [
          {'label': '10분 이내', 'icon': Icons.timer},
          {'label': '30분 이내', 'icon': Icons.timer_outlined},
          {'label': '1시간 이내', 'icon': Icons.access_time},
          {'label': '1시간 이상', 'icon': Icons.schedule},
        ];
      case '메뉴별':
        return [
          {'label': '밥', 'icon': Icons.rice_bowl},
          {'label': '면', 'icon': Icons.ramen_dining},
          {'label': '국', 'icon': Icons.soup_kitchen},
          {'label': '찌개', 'icon': Icons.soup_kitchen},
          {'label': '반찬', 'icon': Icons.set_meal},
          {'label': '빵', 'icon': Icons.bakery_dining},
          {'label': '디저트', 'icon': Icons.cake},
          {'label': '샐러드', 'icon': Icons.eco},
        ];
      default:
        return [];
    }
  }

  String _getPrimaryCategoryDisplayName(String category) {
    switch (category) {
      case '전체':
        return '전체';
      case '나라별':
        return '나라';
      case '시간':
        return '소요시간';
      case '메뉴별':
        return '종류';
      case '재료별':
        return '재료';
      default:
        return category;
    }
  }

  /// Subordinate taxonomy filter pills (Toss/Karrot-style "ghost chips").
  ///
  /// Visually softer than the top-level recipebook category pills above so
  /// hierarchy reads at a glance:
  ///   - selected   → light gray fill, dark ink text, no border
  ///   - unselected → transparent fill, muted gray text, no border
  /// Slightly smaller height/font keeps them clearly secondary.
  Widget _buildPrimaryFilterLayer(Brightness brightness) {
    final categories = ['전체', '메뉴별', '나라별', '재료별', '시간'];
    return _buildGhostFilterRow(
      labels: categories.map(_getPrimaryCategoryDisplayName).toList(),
      isSelected: (i) => _selectedPrimaryCategory == categories[i],
      onSelected: (i) {
        final category = categories[i];
        unawaited(
          AnalyticsService().trackHomeCategoryClicked(
            source: 'primary_filter',
            categoryId: category,
            categoryName: _getPrimaryCategoryDisplayName(category),
            position: i,
          ),
        );
        setState(() {
          _selectedPrimaryCategory = category;
          _selectedTertiaryCategory = null;
          if (category == '전체' || category == '재료별') {
            // 재료별은 중분류를 사용자가 직접 고르게 비워 둔다.
            _selectedSecondaryCategory = null;
          } else {
            final secondaryFilters = _getSecondaryFilters(category);
            if (secondaryFilters.isNotEmpty) {
              _selectedSecondaryCategory =
                  (secondaryFilters.first['label'] as String?) ?? '';
            } else {
              _selectedSecondaryCategory = null;
            }
          }
        });
            },
      padding: const EdgeInsets.only(left: 20, right: 20, top: 0, bottom: 6),
    );
  }

  /// Reusable ghost-style chip row used by all subordinate filter layers
  /// underneath the primary recipebook category pills.
  Widget _buildGhostFilterRow({
    required List<String> labels,
    required bool Function(int index) isSelected,
    required void Function(int index) onSelected,
    EdgeInsetsGeometry padding = const EdgeInsets.only(
      left: 20,
      right: 20,
      top: 2,
      bottom: 10,
    ),
  }) {
    const selectedBg = Color(0xFFF2F4F6);
    const selectedText = Color(0xFF191F28);
    const unselectedText = Color(0xFF8B95A1);

    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: padding,
        child: Row(
          spacing: 4,
          children: List.generate(labels.length, (i) {
            final selected = isSelected(i);
            return GestureDetector(
              onTap: () => onSelected(i),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? selectedBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    height: 1.35,
                    letterSpacing: -0.2,
                    color: selected ? selectedText : unselectedText,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildSecondaryFilterLayer(Brightness brightness) {
    if (_selectedPrimaryCategory == '전체') {
      return const SizedBox.shrink();
    }
    if (_selectedPrimaryCategory == '재료별') {
      return _buildIngredientFilterLayer();
    }
    final secondaryFilters = _getSecondaryFilters(_selectedPrimaryCategory);
    if (secondaryFilters.isEmpty) {
      return const SizedBox.shrink();
    }
    final labels = secondaryFilters
        .map((f) => (f['label'] as String?) ?? '')
        .toList();
    return _buildGhostFilterRow(
      labels: labels,
      isSelected: (i) => _selectedSecondaryCategory == labels[i],
      onSelected: (i) {
        final label = labels[i];
        final next =
            _selectedSecondaryCategory == label ? null : label;
        unawaited(
          AnalyticsService().trackHomeCategoryClicked(
            source: 'secondary_filter',
            categoryId: next ?? 'cleared',
            categoryName: next ?? label,
            position: i,
          ),
        );
        setState(() {
          _selectedSecondaryCategory = next;
          _selectedTertiaryCategory = null;
        });
              },
      padding: const EdgeInsets.only(left: 20, right: 20, top: 0, bottom: 12),
    );
  }

  /// 재료 필터: 중분류(육류/해산물/…)를 고르면 그 옆에 세부(돼지고기/소고기/…)가 펼쳐진다.
  Widget _buildIngredientFilterLayer() {
    const selectedBg = Color(0xFFF2F4F6);
    const selectedText = Color(0xFF191F28);
    const unselectedText = Color(0xFF8B95A1);
    const subSelectedBg = Color(0xFFE8EBEE);
    const subSelectedText = Color(0xFF4E5968);
    const subUnselectedText = Color(0xFFA0A8B3);

    final children = <Widget>[];
    for (final midCat in _ingredientMidCategories) {
      final isExpanded = _selectedSecondaryCategory == midCat;
      children.add(
        GestureDetector(
          onTap: () {
            unawaited(
              AnalyticsService().trackHomeCategoryClicked(
                source: 'ingredient_mid_filter',
                categoryId: isExpanded ? 'cleared' : midCat,
                categoryName: midCat,
              ),
            );
            setState(() {
              if (isExpanded) {
                _selectedSecondaryCategory = null;
                _selectedTertiaryCategory = null;
              } else {
                _selectedSecondaryCategory = midCat;
                _selectedTertiaryCategory = null;
              }
            });
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isExpanded ? selectedBg : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              midCat,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: isExpanded ? FontWeight.w700 : FontWeight.w500,
                height: 1.35,
                letterSpacing: -0.2,
                color: isExpanded ? selectedText : unselectedText,
              ),
            ),
          ),
        ),
      );

      if (isExpanded) {
        final subs = _ingredientSubCategories[midCat] ?? const <String>[];
        for (final sub in subs) {
          final isSubSelected = _selectedTertiaryCategory == sub;
          children.add(
            GestureDetector(
              onTap: () {
                unawaited(
                  AnalyticsService().trackHomeCategoryClicked(
                    source: 'ingredient_sub_filter',
                    categoryId: isSubSelected ? 'cleared' : sub,
                    categoryName: sub,
                  ),
                );
                setState(() {
                  _selectedTertiaryCategory = isSubSelected ? null : sub;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSubSelected ? subSelectedBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight:
                        isSubSelected ? FontWeight.w700 : FontWeight.w500,
                    height: 1.35,
                    letterSpacing: -0.2,
                    color: isSubSelected ? subSelectedText : subUnselectedText,
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.only(left: 20, right: 20, top: 0, bottom: 12),
      child: Row(spacing: 4, children: children),
    );
  }

  static const _ingredientMidCategories = ['육류', '해산물', '식물성·대체'];

  static const _ingredientSubCategories = <String, List<String>>{
    '육류': ['돼지고기', '소고기', '닭고기', '기타육류'],
    '해산물': ['생선', '해산물', '건어물'],
    '식물성·대체': ['채소', '두부·콩', '달걀', '버섯', '기타'],
  };

  /// 파싱 LLM/Firestore 표기 → UI 칩 라벨로 맞춘다.
  /// 예: `식물성/대체` → `식물성·대체`, `기타 육류` → `기타육류`
  String _normalizeIngredientLabel(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return t;
    switch (t) {
      case '식물성/대체':
      case '식물성':
        return '식물성·대체';
      case '기타 육류':
        return '기타육류';
      case '두부 / 콩':
      case '두부/콩':
        return '두부·콩';
      default:
        return t;
    }
  }

  Set<String> _ingredientMidsFromCategories(Map<String, dynamic> recipe) {
    final categories = recipe['categories'] as Map<String, dynamic>? ?? {};
    final mids = <String>{};
    final rawMids = <dynamic>[
      ...(categories['main_ingredient'] as List? ?? const []),
      ...(categories['ingredient_type'] as List? ?? const []),
    ];
    for (final raw in rawMids) {
      final normalized = _normalizeIngredientLabel(raw?.toString() ?? '');
      if (_ingredientMidCategories.contains(normalized)) {
        mids.add(normalized);
      }
    }
    return mids;
  }

  static const _meatKeywordsByType = <String, List<String>>{
    '돼지고기': [
      '돼지',
      '삼겹',
      '목살',
      '앞다리',
      '뒷다리',
      '족발',
      '보쌈',
      '돈까스',
      '돈카츠',
      '제육',
      '수육',
    ],
    '소고기': [
      '소고기',
      '쇠고기',
      '한우',
      '차돌',
      '등심',
      '안심',
      '갈비',
      '사태',
      '양지',
      '불고기',
      '육회',
    ],
    '닭고기': ['닭', '치킨', '닭가슴', '닭다리', '닭날개', '닭볶음', '닭갈비', '닭도리'],
  };

  static const _brothExclusions = [
    '닭육수',
    '닭곰탕육수',
    '닭뼈육수',
    'chicken stock',
    'chicken broth',
    'chicken stalk',
  ];

  static const _fishKeywords = [
    '생선',
    '연어',
    '참치',
    '고등어',
    '새우',
    '오징어',
    '문어',
    '조개',
    '굴',
    '홍합',
    '게',
    '랍스터',
    '전복',
    '꽃게',
    '대구',
    '갈치',
    '삼치',
    '광어',
    '우럭',
    '멸치',
    '회',
  ];

  static const _seafoodKeywords = [
    '새우',
    '오징어',
    '문어',
    '조개',
    '굴',
    '홍합',
    '게',
    '랍스터',
    '전복',
    '꽃게',
    '해산물',
    '낙지',
    '꼬막',
    '바지락',
    '소라',
    '성게',
  ];

  static const _driedSeafoodKeywords = [
    '멸치',
    '건새우',
    '다시마',
    '미역',
    '김',
    '건어물',
    '마른새우',
    '북어',
    '황태',
    '쥐포',
  ];

  static const _vegetableKeywords = [
    '채소',
    '양파',
    '마늘',
    '당근',
    '감자',
    '고구마',
    '파',
    '배추',
    '무',
    '시금치',
    '호박',
    '오이',
    '토마토',
    '양배추',
    '브로콜리',
    '고추',
    '피망',
    '파프리카',
    '셀러리',
    '아스파라거스',
    '콩나물',
    '숙주',
    '깻잎',
    '상추',
    '부추',
  ];

  static const _tofuBeanKeywords = [
    '두부',
    '콩',
    '순두부',
    '된장',
    '청국장',
    '비지',
    '콩나물',
    '대두',
    '렌틸',
    '병아리콩',
  ];

  static const _eggKeywords = ['달걀', '계란', '메추리알'];

  static const _mushroomKeywords = [
    '버섯',
    '표고',
    '느타리',
    '팽이',
    '새송이',
    '양송이',
    '목이',
  ];

  Set<String> _getIngredientSubTypes(Map<String, dynamic> recipe) {
    final id = recipe['id'] as String? ?? '';
    if (id.isNotEmpty) {
      final cached = _ingredientSubTypeCache[id];
      if (cached != null) return cached;
    }

    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final ingredients = recipeData['ingredients'] as List? ?? [];
    final result = <String>{};

    for (final ing in ingredients) {
      final item =
          (ing is Map ? (ing['item']?.toString() ?? '') : ing.toString())
              .toLowerCase();
      if (item.isEmpty) continue;

      if (_brothExclusions.any((ex) => item.contains(ex))) continue;

      var matched = false;
      for (final entry in _meatKeywordsByType.entries) {
        if (entry.value.any((kw) => item.contains(kw))) {
          result.add(entry.key);
          matched = true;
          break;
        }
      }
      if (matched) continue;

      const otherMeatKw = [
        '고기',
        '육',
        '베이컨',
        '햄',
        '소시지',
        '오리',
        '양고기',
        'lamb',
        'duck',
        'beef',
        'pork',
      ];
      if (otherMeatKw.any((kw) => item.contains(kw))) {
        result.add('기타육류');
        continue;
      }

      if (_fishKeywords.any((kw) => item.contains(kw))) {
        result.add('생선');
        continue;
      }
      if (_seafoodKeywords.any((kw) => item.contains(kw))) {
        result.add('해산물');
        continue;
      }
      if (_driedSeafoodKeywords.any((kw) => item.contains(kw))) {
        result.add('건어물');
        continue;
      }

      if (_eggKeywords.any((kw) => item.contains(kw))) {
        result.add('달걀');
        continue;
      }
      if (_tofuBeanKeywords.any((kw) => item.contains(kw))) {
        result.add('두부·콩');
        continue;
      }
      if (_mushroomKeywords.any((kw) => item.contains(kw))) {
        result.add('버섯');
        continue;
      }
      if (_vegetableKeywords.any((kw) => item.contains(kw))) {
        result.add('채소');
        continue;
      }
    }

    // 레시피북 카드(mini doc)는 재료 본문이 없을 수 있어 categories 로 보강한다.
    if (result.isEmpty) {
      final categories = recipe['categories'] as Map<String, dynamic>? ?? {};
      final rawSubs = <dynamic>[
        ...(categories['main_ingredient_sub'] as List? ?? const []),
        ...(categories['meat_type'] as List? ?? const []),
      ];
      for (final raw in rawSubs) {
        final val = _normalizeIngredientLabel(raw?.toString() ?? '');
        if (val.isEmpty) continue;
        if (_ingredientSubCategories.values.any((subs) => subs.contains(val))) {
          result.add(val);
          continue;
        }
        final lower = val.toLowerCase();
        var matchedMeat = false;
        for (final entry in _meatKeywordsByType.entries) {
          if (entry.key == val ||
              entry.value.any((kw) => lower.contains(kw))) {
            result.add(entry.key);
            matchedMeat = true;
            break;
          }
        }
        if (matchedMeat) continue;
        if (lower.contains('해산') || lower.contains('어패')) {
          result.add('해산물');
        } else if (lower.contains('생선') || lower.contains('fish')) {
          result.add('생선');
        } else if (lower.contains('채소') || lower.contains('야채')) {
          result.add('채소');
        } else if (lower.contains('육') || lower.contains('고기')) {
          result.add('기타육류');
        }
      }
    }

    if (result.isEmpty) result.add('기타');
    if (id.isNotEmpty) _ingredientSubTypeCache[id] = result;
    return result;
  }

  Set<String> _getIngredientMidCategories(Set<String> subTypes) {
    final mids = <String>{};
    for (final sub in subTypes) {
      for (final entry in _ingredientSubCategories.entries) {
        if (entry.value.contains(sub)) {
          mids.add(entry.key);
          break;
        }
      }
    }
    return mids;
  }

  static const double _cardHeight = 133.33;
  static const double _cardImageWidth = 84;
  static const double _cardImageHeight = 108;
  static const double _cardPadding = 12.67;
  static const double _cardImageRightGap = 16;

  /// One recipe card: horizontal layout per Figma (image 84x108 left, content right).
  /// When [progress] is set (파싱 중), 썸네일 위 링 진행 표시. meta/tags는 [showMeta]/[showTags]에 따름.
  /// When [onUnsave] is non-null, a small delete control floats on the
  /// card's top-right — taps trigger the remove-from-recipebook flow.
  Widget _buildOneRecipeCard({
    required String title,
    required List<String> tags,
    required String ingredientsCount,
    required String time,
    required String kcal,
    required String creator,
    required String platform,
    String sourceUrl = '',
    required String addedDate,
    String? imageUrl,
    VoidCallback? onTap,
    VoidCallback? onUnsave,
    double? progress,
    String? parsingSubtitle,
    String? parsingStage,
    bool showMeta = true,
    bool showTags = true,
    bool showCreator = true,
  }) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);
    final isParsing = progress != null;
    final content = Container(
      height: _cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(_cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: _cardImageWidth,
                height: _cardImageHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? RepaintBoundary(
                              key: ValueKey('thumb_$imageUrl'),
                              child: ThumbnailLetterboxMitigation(
                                platform: platform,
                                imageUrl: imageUrl,
                                sourceUrl: sourceUrl,
                                child: AppNetworkImage(
                                  imageUrl: imageUrl,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  height: double.infinity,
                                  memCacheWidth: AppNetworkImage
                                      .recipeBookThumbMemCacheWidth,
                                  memCacheHeight: AppNetworkImage
                                      .recipeBookThumbMemCacheHeight,
                                  maxWidthDiskCache: 600,
                                  maxHeightDiskCache: 600,
                                  placeholder: Container(color: _border),
                                  errorWidget: Container(
                                    color: _border,
                                    child: const Icon(
                                      Icons.restaurant,
                                      color: _textGray2,
                                      size: 32,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              color: _border,
                              child: const Icon(
                                Icons.restaurant,
                                color: _textGray2,
                                size: 32,
                              ),
                            ),
                    ),
                    if (isParsing) ...[
                      Positioned.fill(
                        child: Container(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                      Positioned.fill(
                        child: Center(
                          child: ParsingRingIndicator(
                            progressPercent: progress,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: _cardImageRightGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    title,
                    style: _tempTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 19.25 / 14,
                      letterSpacing: -0.35,
                      color: _textDark,
                    ),
                    maxLines: parsingSubtitle != null ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (parsingSubtitle != null) ...[
                    // "분석 중" 을 타이틀 아래로 6px 내리기 (기존 2px + 6px).
                    const SizedBox(height: 8),
                    Text(
                      parsingSubtitle,
                      style: _tempTextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: textPrimary,
                      ),
                    ),
                    if (parsingStage != null && parsingStage.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Builder(
                        builder: (_) {
                          final stageStyle = _tempTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                            color: const Color(0xFF9CA3AF),
                          );
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(
                                child: Text(
                                  parsingStage,
                                  style: stageStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ParsingAnimatedDots(style: stageStyle),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  if (showTags && tags.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: tags.take(3).map(_tagOutlined).toList(),
                    ),
                  if (showMeta && ingredientsCount.isNotEmpty) ...[
                    const Spacer(),
                    Row(
                      children: [
                        Text(
                          '재료 $ingredientsCount개',
                          style: _tempTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 16.5 / 11,
                            color: _textGray2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '|',
                          style: _tempTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            height: 15 / 10,
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.schedule_rounded,
                          size: 11,
                          color: _textGray2,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$time분',
                          style: _tempTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 16.5 / 11,
                            color: _textGray2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '|',
                          style: _tempTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            height: 15 / 10,
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: 12,
                          color: _orange,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${kcal}kcal',
                          style: _tempTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            height: 16.5 / 11,
                            color: _orange,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (isParsing) const Spacer(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child:
                            showCreator &&
                                (creator.isNotEmpty || platform.isNotEmpty)
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildPlatformIconForCreator(
                                    platform,
                                    brightness,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      creator,
                                      style: _tempTextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        height: 16.5 / 11,
                                        color: _textGray2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (addedDate.isNotEmpty)
                        Text(
                          addedDate,
                          style: _tempTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            height: 15 / 10,
                            color: _placeholder,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final tappable = onTap != null
        ? GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: content,
          )
        : content;

    if (onUnsave == null) {
      return tappable;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        tappable,
        Positioned(
          top: 10,
          right: 10,
          child: _buildSavedDeleteButton(onUnsave),
        ),
      ],
    );
  }

  /// Minimal remove control for recipebook cards.
  Widget _buildSavedDeleteButton(VoidCallback onUnsave) {
    return Semantics(
      button: true,
      label: '레시피북에서 삭제',
      child: GestureDetector(
        onTap: onUnsave,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 28,
          height: 28,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFAFAFB),
              border: Border.all(color: const Color(0xFFEEF0F3), width: 1),
            ),
            child: const Center(
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Platform icon next to creator (same assets as home screen).
  Widget _buildPlatformIconForCreator(String platform, Brightness brightness) {
    String? assetPath;
    final p = platform.toLowerCase();
    if (p == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (p == 'instagram' || p == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (p == 'tiktok' || p == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
    }
    const iconSize = 23.0;
    if (assetPath != null) {
      // 원형 클리핑 없이 로고 그대로.
      return SizedBox(
        width: iconSize,
        height: iconSize,
        child: Image.asset(
          assetPath,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.video_library, size: 13.5, color: _textGray2),
        ),
      );
    }
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Icon(Icons.video_library, size: 13.5, color: _textGray2),
    );
  }

  static const _chefTagGradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [
      Color(0xFFFFC2D4),
      Color(0xFFFFD6A5),
      Color(0xFFFDFFB6),
      Color(0xFFCAFFBF),
      Color(0xFF9BF6FF),
      Color(0xFFA0C4FF),
      Color(0xFFBDB2FF),
      Color(0xFFFFC2D4),
    ],
  );

  bool _isChefTag(String tag) => isChefDisplayTag(tag);

  Widget _tagOutlined(String label) {
    final textPrimary = AppColors.getTextPrimary(Theme.of(context).brightness);
    final isChef = _isChefTag(label);
    if (isChef) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.33),
        decoration: BoxDecoration(
          gradient: _chefTagGradient,
          borderRadius: BorderRadius.circular(33554400),
          border: Border.all(width: 0.5, color: const Color(0x80FFFFFF)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4DA082FF),
              blurRadius: 6,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          label,
          style: _tempTextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            height: 15 / 10,
            letterSpacing: -0.25,
            color: textPrimary,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.67, vertical: 3.33),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(width: 0.67, color: const Color(0xFFE5E7EB)),
      ),
      child: Text(
        label,
        style: _tempTextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 15 / 10,
          letterSpacing: -0.25,
          color: _textGray2,
        ),
      ),
    );
  }
}

// =============================================================================
// Trending All Page — full trend browse (opened from home "더보기")
// =============================================================================

const Map<int, List<(String, String)>> _seasonalIngredients = {
  1: [
    ('꼬막', '꼬막'),
    ('대구', '대구'),
    ('더덕', '더덕'),
    ('우엉', '우엉'),
    ('방어', '방어'),
    ('한라봉', '한라봉'),
    ('굴', '굴'),
    ('시금치', '시금치'),
    ('배추', '배추'),
    ('무', '무'),
    ('명태', '명태'),
  ],
  2: [
    ('봄동', '봄동'),
    ('시금치', '시금치'),
    ('멍게', '멍게'),
    ('가자미', '가자미'),
    ('딸기', '딸기'),
    ('취나물', '취나물'),
    ('삼치', '삼치'),
    ('냉이', '냉이'),
    ('달래', '달래'),
    ('도미', '도미'),
    ('미나리', '미나리'),
  ],
  3: [
    ('냉이', '냉이'),
    ('달래', '달래'),
    ('쑥', '쑥'),
    ('주꾸미', '주꾸미'),
    ('꽃게', '꽃게'),
    ('도다리', '도다리'),
    ('매생이', '매생이'),
    ('씀바귀', '씀바귀'),
    ('딸기', '딸기'),
    ('바지락', '바지락'),
    ('문어', '문어'),
  ],
  4: [
    ('죽순', '죽순'),
    ('두릅', '두릅'),
    ('미더덕', '미더덕'),
    ('바지락', '바지락'),
    ('멍게', '멍게'),
    ('참나물', '참나물'),
    ('키조개', '키조개'),
    ('쑥갓', '쑥갓'),
    ('주꾸미', '주꾸미'),
    ('갑오징어', '갑오징어'),
    ('도다리', '도다리'),
  ],
  5: [
    ('매실', '매실'),
    ('미나리', '미나리'),
    ('전복', '전복'),
    ('병어', '병어'),
    ('고사리', '고사리'),
    ('참다랑어', '참다랑어'),
    ('장어', '장어'),
    ('죽순', '죽순'),
    ('부추', '부추'),
    ('오이', '오이'),
    ('주꾸미', '주꾸미'),
    ('키조개', '키조개'),
    ('갑오징어', '갑오징어'),
    ('참돔', '참돔'),
  ],
  6: [
    ('감자', '감자'),
    ('참외', '참외'),
    ('한치', '한치'),
    ('농어', '농어'),
    ('복분자', '복분자'),
    ('옥수수', '옥수수'),
    ('가지', '가지'),
    ('애호박', '애호박'),
    ('민어', '민어'),
    ('매실', '매실'),
    ('다슬기', '다슬기'),
  ],
  7: [
    ('수박', '수박'),
    ('옥수수', '옥수수'),
    ('복숭아', '복숭아'),
    ('갈치', '갈치'),
    ('전복', '전복'),
    ('성게', '성게'),
    ('토마토', '토마토'),
    ('자두', '자두'),
    ('오징어', '오징어'),
    ('삼치', '삼치'),
    ('민어', '민어'),
  ],
  8: [
    ('포도', '포도'),
    ('자두', '자두'),
    ('민어', '민어'),
    ('전복', '전복'),
    ('토마토', '토마토'),
    ('고추', '고추'),
    ('복숭아', '복숭아'),
    ('수박', '수박'),
    ('갈치', '갈치'),
    ('전어', '전어'),
    ('가지', '가지'),
  ],
  9: [
    ('고구마', '고구마'),
    ('대하', '대하'),
    ('꽃게', '꽃게'),
    ('사과', '사과'),
    ('배', '배'),
    ('송이버섯', '송이버섯'),
    ('전어', '전어'),
    ('무화과', '무화과'),
    ('토란', '토란'),
    ('고등어', '고등어'),
    ('버섯', '버섯'),
  ],
  10: [
    ('무', '무'),
    ('배추', '배추'),
    ('굴', '굴'),
    ('꽁치', '꽁치'),
    ('고등어', '고등어'),
    ('홍시', '홍시'),
    ('전어', '전어'),
    ('유자', '유자'),
    ('대하', '대하'),
    ('낙지', '낙지'),
    ('버섯', '버섯'),
  ],
  11: [
    ('유자', '유자'),
    ('배추', '배추'),
    ('굴', '굴'),
    ('홍합', '홍합'),
    ('과메기', '과메기'),
    ('귤', '귤'),
    ('방어', '방어'),
    ('꼬막', '꼬막'),
    ('고등어', '고등어'),
    ('시금치', '시금치'),
    ('대하', '대하'),
  ],
  12: [
    ('대게', '대게'),
    ('아귀', '아귀'),
    ('명태', '명태'),
    ('한라봉', '한라봉'),
    ('귤', '귤'),
    ('과메기', '과메기'),
    ('방어', '방어'),
    ('꼬막', '꼬막'),
    ('홍합', '홍합'),
    ('대구', '대구'),
    ('배추', '배추'),
  ],
};

/// Sort axis to apply *after* a section's filter has narrowed the pool.
/// Defaults to `parsedAtDesc`, matching the original "most recently parsed
/// first" behavior for new sections that don't specify their own ranking.
enum _TrendSortBy { parsedAtDesc, proteinDesc, weeklySavesDesc }

class _TrendSectionDef {
  const _TrendSectionDef({
    required this.subtitle,
    required this.title,
    this.timeMaxMinutes,
    // ignore: unused_element_parameter
    this.caloriesMax,
    this.proteinMin,
    this.fatMax,
    this.maxIngredients,
    this.menuTypes,
    // ignore: unused_element_parameter
    this.countries,
    this.anyTags,
    this.titleKeywords,
    this.excludeTitleKeywords,
    // ignore: unused_element_parameter
    this.sortBy = _TrendSortBy.parsedAtDesc,
    // ignore: unused_element_parameter
    this.platformFilter,
    this.indexKey,
  });
  final String subtitle;
  final String title;
  final int? timeMaxMinutes;
  final int? caloriesMax;
  final int? proteinMin;

  /// Upper bound on grams of fat per serving. Combined with [proteinMin] to
  /// surface "lean & strong" macro profiles (high protein, low fat).
  final int? fatMax;

  /// Maximum number of entries in `recipe.ingredients` for the recipe to be
  /// considered (powers the "재료 5개 이하" minimalist section).
  final int? maxIngredients;

  /// Whitelist of `categories.menu_type` (or legacy keys) values. Recipe is
  /// kept if any whitelisted value appears.
  final List<String>? menuTypes;

  /// Whitelist of `categories.country` (or legacy `cuisine_type`) values.
  final List<String>? countries;

  /// Whitelist of top-level `recipe['tags']` values. Recipe is kept if it
  /// carries any one of these tags. Powers the time-aware "상황(Moment)" row
  /// (야식각 / 해장각 / 혼밥용 …).
  final List<String>? anyTags;

  /// Recipe title(또는 recipe.name)에 이 중 하나라도 포함되면 통과.
  /// 태그가 빈약한 큐레이션(예: 안주)에서 제목 기반으로 확실히 모은다.
  final List<String>? titleKeywords;

  /// Recipe title에 이 중 하나라도 포함되면 제외.
  /// 매크로상 통과해도 '건강하지 않게 보이는' 메뉴(튀김/디저트 등)를 거른다.
  final List<String>? excludeTitleKeywords;

  /// How to rank the filtered set. `weeklySavesDesc` is used by the
  /// "이번 주 가장 많이 저장된" section so the most-saved-this-week recipes
  /// float to the front.
  final _TrendSortBy sortBy;

  /// 지정 시 `recipe.source.platform`이 이 값과 일치하는 카드만 노출.
  /// 다른 모든 섹션(`Trending Now`/`Quick`/...)에서는 동일 플랫폼 카드를 제외.
  final String? platformFilter;

  /// CMS/인덱스 키. 라벨이 바뀌어도 home_section_index 조회에 사용.
  final String? indexKey;

  _TrendSectionDef withCms({
    required String title,
    required String indexKey,
  }) {
    return _TrendSectionDef(
      subtitle: subtitle,
      title: title,
      timeMaxMinutes: timeMaxMinutes,
      caloriesMax: caloriesMax,
      proteinMin: proteinMin,
      fatMax: fatMax,
      maxIngredients: maxIngredients,
      menuTypes: menuTypes,
      countries: countries,
      anyTags: anyTags,
      titleKeywords: titleKeywords,
      excludeTitleKeywords: excludeTitleKeywords,
      sortBy: sortBy,
      platformFilter: platformFilter,
      indexKey: indexKey,
    );
  }
}

class _DashedRoundedBorderPainter extends CustomPainter {
  _DashedRoundedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.dashLength,
    required this.gapLength,
    required this.radius,
  });

  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        strokeWidth / 2,
        strokeWidth / 2,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      Radius.circular(radius),
    );

    final fullPath = Path()..addRRect(rrect);
    final dashed = Path();
    for (final metric in fullPath.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = (distance + dashLength).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + gapLength;
      }
    }

    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedBorderPainter old) {
    return old.color != color ||
        old.strokeWidth != strokeWidth ||
        old.dashLength != dashLength ||
        old.gapLength != gapLength ||
        old.radius != radius;
  }
}

/// VisibilityDetector 래핑 후에도 섹션 종류(제철 등)를 식별하기 위한 마커.
class _ImpressedHomeSection extends StatelessWidget {
  const _ImpressedHomeSection({
    required this.sectionId,
    required this.child,
  });

  final String sectionId;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class TrendingAllPage extends StatefulWidget {
  const TrendingAllPage({
    super.key,
    required this.allRecipes,
    required this.onRecipeTap,
    // 인스타 CDN 만료 시 Storage cropped 우선 (없으면 CDN 폴백).
    this.preferCroppedForInstagram = true,
    this.inline = false,
    this.inlineAfterNowTrending,
    this.inlineAfterBoosted,
    this.showMembersOnlySections = true,
    this.popularOnly = false,
    this.firstSectionTopPadding = 0,
    this.sequentialInlineBootstrap = false,
    this.showSequentialTailLoading = true,
    this.onFirstSectionReady,
    this.waitForInlineLeadIn,
  });

  final List<Map<String, dynamic>> allRecipes;
  final void Function(
    Map<String, dynamic> recipe, {
    String? sectionTitle,
    int? cardIndex,
    String? sectionKey,
  }) onRecipeTap;
  final bool preferCroppedForInstagram;

  /// When true, renders trending sections as a [SliverList] so the home
  /// [CustomScrollView] can lazy-build off-screen sections.
  final bool inline;
  final Widget? inlineAfterNowTrending;

  /// 온보딩 부스트 레일 바로 아래(셰프·인기 키워드 앞)에 끼울 슬롯.
  final Widget? inlineAfterBoosted;

  /// Guest users can browse the public lead-in only. Member-only carousels are not
  /// rendered or fetched until the user signs in.
  final bool showMembersOnlySections;

  /// 인기 탭: 셰프별 인기 · 요즘 인기 메뉴 · 실시간 인기만 노출 (추천에도 그대로 유지).
  final bool popularOnly;

  /// 첫 번째 섹션 상단 여백. 로그인 전에는 헤더와의 간격을
  /// 넓혀 다른 섹션과 비슷한 리듬을 맞춘다.
  final double firstSectionTopPadding;

  /// 홈 인라인 모드에서 섹션을 위→아래 순서로 하나씩 노출 (OOM 피크 완화).
  final bool sequentialInlineBootstrap;

  /// 앞쪽 보조 섹션(인기 키워드 등)이 로딩 중이면 아래 섹션 스켈레톤은 숨긴다.
  final bool showSequentialTailLoading;

  /// 첫 번째 섹션이 화면에 올라왔을 때(인기 키워드 등 후속 로딩 트리거).
  final VoidCallback? onFirstSectionReady;

  /// 셰프 공개 직후·다음 캐러셀 공개 전 인기 키워드 자리 잡기를 기다린다.
  final Future<void> Function()? waitForInlineLeadIn;

  static const double _cardWidth = 140;
  static const double _cardImageHeight = 175;
  static const double _cardCaptionHeight = 68;
  static const double _cardRadius = 18;
  static const double _cardGap = 12;

  /// Same slot as home carousel while thumbnails load (static — no ticker).
  static Widget _shimmerThumbPlaceholder() {
    return Container(
      width: _cardWidth,
      height: _cardImageHeight,
      decoration: BoxDecoration(
        color: _shimmerImagePlaceholderColor,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
    );
  }

  static Widget _thumbFallback() {
    return Container(
      width: _cardWidth,
      height: _cardImageHeight,
      decoration: BoxDecoration(
        color: _shimmerImagePlaceholderColor,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
    );
  }

  static const List<_TrendSectionDef> _sections = [
    _TrendSectionDef(subtitle: 'Realtime', title: '실시간 인기 레시피'),
    _TrendSectionDef(
      subtitle: 'Quick',
      title: '10분 완성 레시피',
      timeMaxMinutes: 10,
    ),
    // Minimalist pantry section — 5개 이하의 재료로 도전 가능한 레시피만.
    _TrendSectionDef(subtitle: 'Just 5', title: '5가지 재료로 끝', maxIngredients: 5),
    // Mood / 분위기 카테고리 — 국·찌개 묶음으로 "오늘 저녁 국물 한 그릇" 흐름.
    _TrendSectionDef(
      subtitle: 'Comfort Bowl',
      title: '뜨끈한 국물 한 그릇',
      menuTypes: ['국', '찌개', '국물', '탕'],
    ),
    _TrendSectionDef(subtitle: 'High protein', title: '단백질 많은', proteinMin: 15),
    // Fitness niche — 고단백 + 저지방 매크로 조합. 다이어트 / 헬창 사용자 타겟.
    _TrendSectionDef(
      subtitle: 'Lean & Strong',
      title: '고단백 저지방',
      proteinMin: 20,
      fatMax: 12,
      // 매크로상 통과해도 '건강하지 않게 보이는' 메뉴는 제외해 인식과 맞춘다.
      excludeTitleKeywords: [
        '튀김', '후라이드', '치킨', '강정', '깐풍', '꿔바로우', '탕수',
        '피자', '햄버거', '버거', '핫도그', '라면', '짜파', '마요',
        '크림', '베이컨', '소시지', '곱창', '막창', '삼겹', '대패',
        '떡볶이', '순대', '케이크', '쿠키', '디저트', '도넛', '베이킹',
        '초코', '브라우니', '와플', '팬케이크', '아이스크림', '빙수',
        '전', '부침', '그라탕', '까르보', '로제', '버터',
      ],
    ),
    // 네이버 블로그 섹션은 공유로 인한 저작권 리스크 검토 끝날 때까지 일단 숨김.
    // 다시 활성화하려면 아래 항목을 복원:
    //   _TrendSectionDef(
    //     subtitle: 'Blog',
    //     title: '블로그에서 발견한 레시피',
    //     platformFilter: 'naver_blog',
    //   ),
  ];

  @override
  State<TrendingAllPage> createState() => _TrendingAllPageState();
}

class _TrendingAllPageState extends State<TrendingAllPage> {
  final RecipeService _recipeService = RecipeService.shared;
  final List<Map<String, dynamic>> _allRecipes = [];
  List<String> _seasonalIndexedIds = const <String>[];
  final Map<String, List<String>> _homeSectionIndexedIdsByTitle = {};
  Map<String, List<String>> _chefIndexByChef = {};
  // 셰프별로 한 번 확보한 레시피는 여기 보존한다. `_allRecipes`는
  // `_kAllRecipesMaxInMemory` 상한으로 앞쪽이 잘려나가므로, 셰프 섹션이
  // 그 휘발성 윈도우에 의존하면 스크롤 중 셰프가 하나둘 사라진다. 이 맵은
  // additive-only 라서 한 번 뜬 셰프는 유지된다.
  final Map<String, List<Map<String, dynamic>>> _chefRecipesByChef = {};
  final Map<String, List<Map<String, dynamic>>> _displayedSections = {};
  final List<(Map<String, dynamic>, String)> _displayedSeasonal = [];
  final Set<String> _displayedSeasonalIds = <String>{};
  DocumentSnapshot? _lastCursor;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _seedingCursor = false;
  bool _bootstrapping = true;
  bool _sequentialTailLoading = false;
  final Set<String> _sequentialUnlockedTitles = <String>{};
  bool _firstSectionReadyNotified = false;

  /// 게스트 sequential bootstrap 과 로그인 후 멤버 섹션 로드가 겹칠 때
  /// 늦은 setState / loading 해제가 서로를 덮어쓰지 않도록 세대 번호를 쓴다.
  int _bootstrapGeneration = 0;
  bool _membersOnlyLoadInFlight = false;

  /// 섹션별 가로 스크롤 깊이 (이탈 시 summary 1회).
  final Map<String, int> _sectionMaxVisibleIndex = {};
  final Map<String, int> _sectionItemCount = {};
  final Map<String, String> _sectionDisplayName = {};
  bool _sectionScrollSummaryFlushed = false;
  DateTime? _lastCarouselAppendAttempt;
  static const Duration _kCarouselAppendThrottle =
      Duration(milliseconds: 220);

  /// 홈 섹션 노출 — 앱 세션당 섹션 1회.
  final Set<String> _impressedSectionIds = <String>{};
  static const double _kSectionImpressionThreshold = 0.5;

  /// Time-aware "상황(Moment)" row. Resolved once on init so the title/tag stay
  /// stable for the session, and auto-hides when no recipe carries the tag.
  late final _TrendSectionDef _momentSection = _resolveMomentSection();
  OnboardingProfile? _onboardingProfile;
  final UserService _userService = UserService();

  static const _TrendSectionDef _lateNightSection = _TrendSectionDef(
    subtitle: 'Late night',
    title: '출출한 밤, 야식 한 입',
    anyTags: ['야식각', '야식'],
  );

  /// 안주 큐레이션.
  /// 안주 태그 + 제목 키워드 OR 매칭. 맛/식감 태그(단짠단짠·바삭한 등)는 제외.
  /// 매칭 레시피가 없으면 자동으로 숨겨진다.
  static const _TrendSectionDef _worldCupSection = _TrendSectionDef(
    subtitle: 'Anju',
    title: '맥주 곁들이는 안주 한 상',
    anyTags: ['안주', '술안주', '맥주안주'],
    titleKeywords: [
      // 치킨·튀김류
      '치킨', '후라이드', '양념치킨', '닭강정', '강정', '윙',
      '튀김', '감자튀김', '치즈스틱', '모짜렐라', '나초', '깐풍', '꿔바로우',
      // 꼬치·마른안주
      '꼬치', '양꼬치', '닭발', '똥집', '쥐포', '노가리', '먹태',
      '황태', '육포', '마른안주', '훈제',
      // 해물·구이 안주
      '감바스', '곱창', '막창', '골뱅이', '골뱅이무침', '조개', '홍합',
      // 전·분식 안주
      '파전', '김치전', '해물파전', '부침개', '두부김치',
      '어묵', '오뎅', '떡볶이', '핫도그', '소시지',
      // 안주 키워드
      '안주', '술안주', '맥주안주', '피자',
    ],
    excludeTitleKeywords: [
      '밥', '죽', '리조또', '리소토',
      '볶음밥', '비빔밥', '덮밥', '국밥', '김밥', '주먹밥', '카레밥',
      '찌개', '국', '탕', '조림', '찜',
      '반찬', '밑반찬', '도시락',
      '국수', '라면', '파스타', '스파게티',
    ],
  );

  /// 아기 이유식·유아식 큐레이션. 아기·유아를 직접 가리키는 표현이 제목 또는
  /// 태그에 있어야 한다. 저염·무염·퓨레 등 성인 요리에도 쓰이는 표현은 제외한다.
  static const _TrendSectionDef _babySection = _TrendSectionDef(
    subtitle: 'Baby & Toddler',
    title: '우리 아기 이유식·유아식',
    anyTags: [
      '이유식', '유아식', '아기', '애기', '아가', '유아', '베이비', 'baby',
    ],
    titleKeywords: [
      '이유식', '유아식', '아기', '애기', '아가', '유아', '베이비', 'baby',
    ],
  );

  /// 디저트 전용 큐레이션. 베이킹/케이크/쿠키 등 달콤한 메뉴를 모은다.
  /// 제목 키워드 또는 태그 중 하나만 맞아도 잡히도록 폭넓게 구성(없으면 자동 숨김).
  static const _TrendSectionDef _dessertSection = _TrendSectionDef(
    subtitle: 'Dessert',
    title: '달콤한 디저트 한 입',
    anyTags: [
      '디저트', '베이킹', '홈베이킹', '달달한', '달콤한', '간식용', '디저트류',
    ],
    titleKeywords: [
      '디저트', '케이크', '컵케이크', '롤케이크', '치즈케이크', '쿠키', '베이킹',
      '마카롱', '브라우니', '푸딩', '스콘', '타르트', '마들렌', '휘낭시에',
      '도넛', '초코', '초콜릿', '티라미수', '무스', '젤리', '아이스크림', '빙수',
      '약과', '양갱', '단팥', '파이', '슈크림', '와플', '팬케이크', '크레페',
      '마들렌', '구움과자', '레어치즈', '몽블랑', '에끌레르', '까눌레', '스무디',
    ],
  );

  /// 소스·양념 전용 큐레이션. 만능간장/드레싱/디핑소스 등 직접 만드는 소스류를 모은다.
  /// 제목 키워드 또는 태그 중 하나만 맞아도 잡히도록 폭넓게 구성(없으면 자동 숨김).
  static const _TrendSectionDef _sauceSection = _TrendSectionDef(
    subtitle: 'Sauce',
    title: '만들어두면 든든한 소스·양념',
    // 제목에 '소스/양념장/드레싱' 등 소스 그 자체를 가리키는 단어가 있는 것만.
    // (태그 매칭은 사용 안 함 — 요리가 섞여 들어오는 것을 막기 위해 제목 기준만)
    titleKeywords: [
      '소스', '양념장', '드레싱', '만능간장', '만능장', '맛간장', '맛장',
      '쌈장', '초장', '초고추장', '페스토', '디핑', '비빔장', '겉절이양념',
      '비법양념', '만능양념', '만능소스', '비법소스', '디핑소스',
    ],
    // 소스 단어가 들어가도 '요리'면 제외(예: 토마토소스 파스타, 소스 덮밥).
    excludeTitleKeywords: [
      '파스타', '스파게티', '덮밥', '밥', '면', '국수', '볶음', '구이',
      '조림', '찜', '탕', '찌개', '국', '샐러드', '떡볶이', '무침', '비빔국수',
    ],
  );

  /// Sections actually rendered this session.
  /// 순서: (셰프별) → (인기 키워드) → 소스·양념 → 디저트
  ///       → 실시간 인기 → 아기 이유식·유아식 → moment → 안주 → (제철) → 나머지.
  /// 비로그인: 디저트까지 공개, 실시간 인기부터는 로그인 필요.
  List<_TrendSectionDef> get _hardcodedActiveSections {
    final base = TrendingAllPage._sections;
    if (base.isEmpty) {
      return [
        _sauceSection,
        _dessertSection,
        _babySection,
        _momentSection,
        _worldCupSection,
      ];
    }
    return [
      _sauceSection,
      _dessertSection,
      base.first,
      _babySection,
      _momentSection,
      _worldCupSection,
      ...base.skip(1),
    ];
  }

  /// CMS enabled+order 가 있으면 병합, 실패 시 하드코딩 폴백.
  List<_TrendSectionDef> get _activeSections {
    final hardcoded = _hardcodedActiveSections;
    final cms = HomeCmsService.instance.enabledHomeSections;
    if (cms.isEmpty) return hardcoded;

    final byKey = <String, _TrendSectionDef>{};
    for (final section in hardcoded) {
      final key = _indexKeyForSection(section);
      if (key != null) byKey[key] = section;
    }

    final out = <_TrendSectionDef>[];
    final usedKeys = <String>{};
    var insertedRealtime = false;
    final realtime = hardcoded.where((s) => _indexKeyForSection(s) == null);

    void maybeInsertRealtimeBefore(int hardcodedIndex) {
      if (insertedRealtime) return;
      for (final r in realtime) {
        final ri = hardcoded.indexOf(r);
        if (ri >= 0 && ri < hardcodedIndex) {
          out.add(r);
          insertedRealtime = true;
          return;
        }
      }
    }

    for (final c in cms) {
      if (!c.enabled) continue;
      if (c.kind == 'program' || c.kind == 'poster_pool') continue;
      if (c.kind == 'moment') {
        final momentKey = _indexKeyForSection(_momentSection);
        if (momentKey != c.sectionKey) continue;
        if (usedKeys.contains(c.sectionKey)) continue;
        final hi = hardcoded.indexOf(_momentSection);
        maybeInsertRealtimeBefore(hi < 0 ? hardcoded.length : hi);
        out.add(_momentSection.withCms(title: c.label, indexKey: c.sectionKey));
        usedKeys.add(c.sectionKey);
        continue;
      }
      final existing = byKey[c.sectionKey];
      if (existing != null) {
        final hi = hardcoded.indexOf(existing);
        maybeInsertRealtimeBefore(hi < 0 ? hardcoded.length : hi);
        out.add(existing.withCms(title: c.label, indexKey: c.sectionKey));
        usedKeys.add(c.sectionKey);
      } else if (c.label.isNotEmpty && c.sectionKey.isNotEmpty) {
        out.add(
          _TrendSectionDef(
            subtitle: '',
            title: c.label,
            indexKey: c.sectionKey,
          ),
        );
        usedKeys.add(c.sectionKey);
      }
    }
    if (!insertedRealtime) {
      out.addAll(realtime);
    }
    return out.isEmpty ? hardcoded : out;
  }

  /// Guest users can browse the public lead-in only. `실시간 인기 레시피` is the
  /// first member-only carousel, so it and everything after stay out of the
  /// widget tree and out of the Firestore bootstrap path until sign-in.
  List<_TrendSectionDef> get _personalizedActiveSections {
    final extras = _countrySectionsForProfile(
      widget.popularOnly ? null : _onboardingProfile,
    );
    return applyHomeSectionBoosts<_TrendSectionDef>(
      sections: [...extras, ..._activeSections],
      profile: widget.popularOnly ? null : _onboardingProfile,
      keyOf: _indexKeyForSection,
      extraLateNight: widget.popularOnly ? null : _lateNightSection,
    );
  }

  List<_TrendSectionDef> _countrySectionsForProfile(OnboardingProfile? profile) {
    if (profile == null) return const <_TrendSectionDef>[];
    final out = <_TrendSectionDef>[];
    final used = <String>{};
    for (final cuisine in profile.favoriteCuisines) {
      final label = kOnboardingCuisineToCountryLabel[cuisine];
      final key = onboardingCountrySectionKey(cuisine);
      if (label == null || key == null || used.contains(key)) continue;
      used.add(key);
      out.add(
        _TrendSectionDef(
          subtitle: 'For you',
          title: '$label 레시피',
          countries: [label],
          indexKey: key,
        ),
      );
    }
    return out;
  }

  List<_TrendSectionDef> get _visibleSections {
    if (widget.showMembersOnlySections) return _personalizedActiveSections;
    return _personalizedActiveSections
        .takeWhile((section) => section.title != _kTrendingNowTitle)
        .toList(growable: false);
  }

  bool _isBoostedSection(_TrendSectionDef config) {
    if (widget.popularOnly) return false;
    final key = _indexKeyForSection(config);
    if (key == null) return false;
    return boostedHomeSectionKeys(
      _onboardingProfile ?? OnboardingProfile(),
    ).contains(key);
  }

  /// Picks the moment row's tag + headline from the current time of day.
  _TrendSectionDef _resolveMomentSection() {
    final now = DateTime.now();
    final h = now.hour;
    final weekend =
        now.weekday == DateTime.friday ||
        now.weekday == DateTime.saturday ||
        now.weekday == DateTime.sunday;
    if (h >= 21 || h < 4) {
      return _lateNightSection;
    }
    if (h < 11) {
      return const _TrendSectionDef(
        subtitle: 'Morning',
        title: '든든한 아침 집밥 한 끼',
        anyTags: ['아침', '집밥용', '집밥'],
      );
    }
    if (weekend && h < 17) {
      return const _TrendSectionDef(
        subtitle: 'Guest table',
        title: '손님 부르는 날, 그럴듯한 한 상',
        anyTags: ['손님용', '손님상'],
      );
    }
    if (h < 17) {
      return const _TrendSectionDef(
        subtitle: 'Solo meal',
        title: '혼밥인데 대충 안 하고 싶을 때',
        anyTags: ['혼밥용', '혼밥'],
      );
    }
    return const _TrendSectionDef(
      subtitle: 'Home dinner',
      title: '오늘 저녁 집밥 뭐 만들지',
      anyTags: ['집밥용', '집밥'],
    );
  }

  /// 인덱스 기반 섹션: 지금까지 `_allRecipes` 풀에 fetch 한 ID 개수.
  final Map<String, int> _sectionFetchedCount = {};
  /// 인덱스 ID를 모두 소진한 섹션.
  final Map<String, bool> _sectionExhausted = {};
  /// 동일 섹션 동시 fetch 방지.
  final Set<String> _sectionFetchInFlight = {};
  /// 셰프별 지금까지 fetch 한 인덱스 ID 개수.
  final Map<String, int> _chefFetchedCount = {};
  final Map<String, bool> _chefExhausted = {};
  final Set<String> _chefFetchInFlight = {};

  static const int _kInitialPerSection = 3;
  static const int _kInitialSeasonal = 3;
  /// 스크롤 append 시 캐러셀에 붙이는 장수 (WU4에서 본격 사용).
  static const int _kAppendPerFetch = 4;
  /// 인덱스 섹션 초기 doc fetch 개수 (WU3에서 본격 사용).
  static const int _kSectionInitialFetch = 5;
  /// 인덱스 섹션 append 시 추가 doc fetch 개수 (WU4에서 본격 사용).
  static const int _kSectionAppendFetch = 4;
  /// 셰프당 초기 doc fetch.
  static const int _kChefFetch = 4;
  /// 셰프 가로 스크롤 append 시 추가 doc fetch.
  static const int _kChefAppendFetch = 4;
  /// 제철 초기 doc fetch (WU6에서 본격 사용).
  static const int _kSeasonalInitialFetch = 5;
  /// 지금 뜨는 page rawLimit.
  static const int _kTrendingNowRawLimit = 15;
  /// 제철 인덱스 부족 시 page warmup 라운드 상한 (리드 절감).
  static const int _kSeasonalWarmupMaxRounds = 1;
  static const int _kPrefetchAhead = 10;
  static const int _kBootstrapMaxFetchRounds = 3;
  /// 홈 트렌드 풀 in-memory 상한 (스크롤 prefetch 시 앞쪽 trim).
  /// 레시피 Map 자체는 이미지 캐시보다 훨씬 작아서 300까지는 여유 있다.
  /// 무제한으로 두면 예전에 터졌던 OOM 경로와 같아진다.
  static const int _kAllRecipesMaxInMemory = 300;

  static const Map<String, String> _sectionTitleToIndexKey = {
    '맥주 곁들이는 안주 한 상': 'world_cup',
    '우리 아기 이유식·유아식': 'baby_food',
    '달콤한 디저트 한 입': 'dessert',
    '만들어두면 든든한 소스·양념': 'sauce',
    '10분 완성 레시피': 'quick_10min',
    '5가지 재료로 끝': 'ingredients_5',
    '뜨끈한 국물 한 그릇': 'comfort_bowl',
    '단백질 많은': 'high_protein',
    '고단백 저지방': 'lean_strong',
  };

  String? _indexKeyForSection(_TrendSectionDef config) {
    final explicit = config.indexKey?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    const momentKeys = {
      '출출한 밤, 야식 한 입': 'moment_late_night',
      '든든한 아침 집밥 한 끼': 'moment_morning',
      '손님 부르는 날, 그럴듯한 한 상': 'moment_guest',
      '혼밥인데 대충 안 하고 싶을 때': 'moment_solo',
      '오늘 저녁 집밥 뭐 만들지': 'moment_dinner',
    };
    return momentKeys[config.title] ?? _sectionTitleToIndexKey[config.title];
  }

  List<Map<String, dynamic>> _recipesByIndexedIds(List<String> ids) {
    final byId = <String, Map<String, dynamic>>{};
    for (final r in _allRecipes) {
      final id = r['id']?.toString() ?? '';
      if (id.isNotEmpty) byId[id] = r;
    }
    return hideRecipesOnHome([
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ], _onboardingProfile);
  }

  void _resetSectionFetchState() {
    _sectionFetchedCount.clear();
    _sectionExhausted.clear();
    _sectionFetchInFlight.clear();
    _chefFetchedCount.clear();
    _chefExhausted.clear();
    _chefFetchInFlight.clear();
    _seasonalFetchedCount = 0;
    _seasonalExhausted = false;
    _seasonalFetchInFlight = false;
  }

  /// 인덱스 섹션의 다음 [extra] 개 ID를 Firestore에서 읽어 `_allRecipes` 에 채운다.
  ///
  /// 반환: 이번에 요청한 ID 개수(캐시 hit 포함). 소진/비행 중이면 0.
  /// WU1에서는 추가만 하고 bootstrap/append 경로에는 아직 연결하지 않는다.
  Future<int> _ensureSectionRecipesFetched(String title, int extra) async {
    if (extra <= 0) return 0;
    if (_sectionExhausted[title] == true) return 0;
    if (_sectionFetchInFlight.contains(title)) return 0;

    final indexedIds = _homeSectionIndexedIdsByTitle[title];
    if (indexedIds == null || indexedIds.isEmpty) {
      _sectionExhausted[title] = true;
      return 0;
    }

    final fetched = _sectionFetchedCount[title] ?? 0;
    if (SectionRecipeFetchWindow.isExhausted(
      fetchedCount: fetched,
      totalIds: indexedIds.length,
    )) {
      _sectionExhausted[title] = true;
      return 0;
    }

    final nextIds = SectionRecipeFetchWindow.nextIds(
      indexedIds: indexedIds,
      fetchedCount: fetched,
      extra: extra,
    );
    if (nextIds.isEmpty) {
      _sectionExhausted[title] = true;
      return 0;
    }

    _sectionFetchInFlight.add(title);
    try {
      final recipes = await _recipeService.getExploreRecipesByIds(
        nextIds,
        limit: nextIds.length,
      );
      if (!mounted) return 0;
      _appendUnique(recipes);
      final newFetched = fetched + nextIds.length;
      _sectionFetchedCount[title] = newFetched;
      if (SectionRecipeFetchWindow.isExhausted(
        fetchedCount: newFetched,
        totalIds: indexedIds.length,
      )) {
        _sectionExhausted[title] = true;
      }
      return nextIds.length;
    } catch (_) {
      // 실패 시 오프셋을 올리지 않아 다음 시도에서 같은 구간을 재시도한다.
      return 0;
    } finally {
      _sectionFetchInFlight.remove(title);
    }
  }

  @override
  void initState() {
    super.initState();
    _onboardingProfile = UserService.peekOnboardingProfile();
    _appendUnique(widget.allRecipes);
    unawaited(ChefTagRegistry.ensureLoaded());
    unawaited(_ensureOnboardingProfile());
    _initializePage();
    unawaited(_reloadAfterCms());
  }

  Future<void> _ensureOnboardingProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final profile = await _userService.loadOnboardingProfile();
    if (!mounted) return;
    if (FirebaseAuth.instance.currentUser?.uid != uid) return;
    if (!identical(profile, _onboardingProfile)) {
      _onboardingProfile = profile;
      _stripHiddenFromDisplayed();
    }
    await _primeOnboardingHomeRails();
    if (mounted) setState(() {});
  }

  /// 디스크 캐시·peek 히트여도 나라 레일은 인덱스에 없어서 따로 채운다.
  Future<void> _primeOnboardingHomeRails() async {
    if (widget.popularOnly) return;
    if (!affectsHomeRails(_onboardingProfile)) return;
    for (final config in _visibleSections) {
      if (!mounted) return;
      if (_isBoostedSection(config)) {
        _sequentialUnlockedTitles.add(config.title);
        await _primeHomeSectionIndex(config);
      }
      _refreshSingleSection(config);
      await _fillSectionSeed(config);
    }
  }

  void _stripHiddenFromDisplayed() {
    for (final title in _displayedSections.keys.toList()) {
      _displayedSections[title] = hideRecipesOnHome(
        _displayedSections[title] ?? const <Map<String, dynamic>>[],
        _onboardingProfile,
      );
    }
    _displayedSeasonal.removeWhere(
      (entry) => recipeHiddenOnHome(entry.$1, _onboardingProfile),
    );
    _displayedSeasonalIds
      ..clear()
      ..addAll(
        _displayedSeasonal
            .map((entry) => entry.$1['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty),
      );
    for (final chef in _chefRecipesByChef.keys.toList()) {
      _chefRecipesByChef[chef] = hideRecipesOnHome(
        _chefRecipesByChef[chef] ?? const <Map<String, dynamic>>[],
        _onboardingProfile,
      );
    }
  }

  Future<void> _reloadAfterCms() async {
    await HomeCmsService.instance.ensureLoaded();
    if (!mounted) return;
    _initializePage();
  }

  @override
  void didUpdateWidget(covariant TrendingAllPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.showMembersOnlySections &&
        widget.showMembersOnlySections) {
      unawaited(_loadMembersOnlySectionsAfterSignIn());
    }
  }

  bool _isBootstrapGenerationCurrent(int generation) =>
      generation == _bootstrapGeneration;

  void _setStateIfBootstrapCurrent(int generation, VoidCallback fn) {
    if (!mounted || !_isBootstrapGenerationCurrent(generation)) return;
    setState(fn);
  }

  /// 로그인 전용 캐러셀(실시간 인기 이후)이 이미 채워져 있는지.
  /// 게스트 lead-in 캐시만 있으면 false → 추가 fetch 필요.
  bool _hasMembersOnlyCarouselsReady() {
    final trending = _displayedSections[_kTrendingNowTitle];
    if (trending != null && trending.isNotEmpty) return true;
    for (final config in _activeSections
        .skipWhile((section) => section.title != _kTrendingNowTitle)
        .skip(1)) {
      final recipes = _displayedSections[config.title];
      if (recipes != null && recipes.isNotEmpty) return true;
    }
    return false;
  }

  /// 게스트 부트스트랩 이후 로그인 시, 멤버 전용 캐러셀만 이어서 채운다.
  /// generation 으로 늦은 guest setState 를 무시하고, finally 에서 loading 을 푼다.
  Future<void> _loadMembersOnlySectionsAfterSignIn() async {
    if (!mounted || _membersOnlyLoadInFlight) return;
    _membersOnlyLoadInFlight = true;
    final generation = ++_bootstrapGeneration;

    _setStateIfBootstrapCurrent(generation, () {
      _sequentialTailLoading = true;
      _sequentialUnlockedTitles.add(_kChefRevealKey);
      for (final config in _activeSections) {
        if (config.title == _kTrendingNowTitle) break;
        _sequentialUnlockedTitles.add(config.title);
      }
    });

    try {
      if (!mounted ||
          !widget.showMembersOnlySections ||
          !_isBootstrapGenerationCurrent(generation)) {
        return;
      }

      // 풀 캐시 복원 등으로 이미 있으면 fetch 없이 reveal 만.
      if (_hasMembersOnlyCarouselsReady()) {
        _refreshDisplayedSections(seedOnly: true);
        for (final config in _activeSections
            .skipWhile((section) => section.title != _kTrendingNowTitle)) {
          _sequentialUnlockedTitles.add(config.title);
        }
        _sequentialUnlockedTitles.add(_kSeasonalRevealKey);
        _setStateIfBootstrapCurrent(generation, () {});
        return;
      }

      await _loadMembersOnlySectionsBody(generation);
    } finally {
      _membersOnlyLoadInFlight = false;
      _setStateIfBootstrapCurrent(generation, () {
        _sequentialTailLoading = false;
      });
      if (_isBootstrapGenerationCurrent(generation) &&
          widget.showMembersOnlySections) {
        _schedulePublishHomeTrendingCache();
      }
    }
  }

  Future<void> _loadMembersOnlySectionsBody(int generation) async {
    final membersOnly = _activeSections
        .skipWhile((section) => section.title != _kTrendingNowTitle)
        .toList(growable: false);

    // 게스트 lead-in 은 인덱스 fetch 로 `_allRecipes` 만 채워 두고 explore
    // 커서는 비운 채다. 이 상태에서 `_loadMoreRecipes` 가 last-id 로 seed 하면
    // 잘못된 커서/`_hasMore=false` 로 트렌딩이 비게 되므로 head 부터 다시 연다.
    _lastCursor = null;
    _hasMore = true;

    for (final config in membersOnly) {
      if (!mounted ||
          !widget.showMembersOnlySections ||
          !_isBootstrapGenerationCurrent(generation)) {
        return;
      }
      if (config.title == _kTrendingNowTitle) {
        var rounds = 0;
        while (mounted &&
            _isBootstrapGenerationCurrent(generation) &&
            rounds < _kBootstrapMaxFetchRounds) {
          await _loadMoreRecipes(
            shouldSetState: false,
            refreshSections: false,
            rawLimit: _kTrendingNowRawLimit,
            restartFromHead: rounds == 0,
          );
          if (!_isBootstrapGenerationCurrent(generation)) return;
          _refreshSingleSection(config);
          final trendingCount =
              _displayedSections[_kTrendingNowTitle]?.length ?? 0;
          if (trendingCount >= _kInitialPerSection || !_hasMore) break;
          rounds += 1;
        }
      } else {
        await _primeHomeSectionIndex(config);
        if (!_isBootstrapGenerationCurrent(generation)) return;
        _refreshSingleSection(config);
        await _fillSectionSeed(config);
      }
      if (!_isBootstrapGenerationCurrent(generation)) return;
      _sequentialUnlockedTitles.add(config.title);
      _setStateIfBootstrapCurrent(generation, () {});
      await Future<void>.delayed(Duration.zero);
    }

    if (!mounted ||
        !widget.showMembersOnlySections ||
        !_isBootstrapGenerationCurrent(generation)) {
      return;
    }
    await PerfMonitor.instance.measure(
      'home.seasonal',
      () => _primeSeasonalIndexRecipes(),
    );
    if (!_isBootstrapGenerationCurrent(generation)) return;
    _refreshDisplayedSections(seedOnly: true);
    _sequentialUnlockedTitles.add(_kSeasonalRevealKey);
    await _appendDisplayedForSection(_kLeanStrongSectionTitle);
    _setStateIfBootstrapCurrent(generation, () {});
  }

  /// 디스크에 남은 홈 카드와 Firestore `home_section_index` 앞 30개가 다르면 true.
  /// 한 섹션 읽기가 실패하면 그 섹션만 건너뛰고, 바뀐 섹션이 있으면 true.
  Future<bool> _homeSectionIndexChanged(HomeTrendingFeedSnapshot cached) async {
    await HomeCmsService.instance.ensureLoaded();
    if (!mounted) return false;
    var changed = false;
    for (final config in _visibleSections) {
      if (config.countries != null && config.countries!.isNotEmpty) continue;
      final key = _indexKeyForSection(config);
      if (key == null || key.isEmpty) continue;
      final live = await _recipeService.readHomeSectionRecipeIds(
        sectionKey: key,
        limit: 30,
      );
      if (live == null) continue;
      final previous =
          cached.homeSectionIndexedIdsByTitle[config.title] ??
          const <String>[];
      if (!_sameRecipeIdList(previous, live)) changed = true;
    }
    return changed;
  }

  bool _sameRecipeIdList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Pull-to-refresh from home — clears caches and reloads all trending sections.
  Future<void> reloadFromNetwork() async {
    if (!mounted) return;
    // 진행 중 guest/멤버 로드의 늦은 setState 를 무효화한다.
    _bootstrapGeneration++;
    _membersOnlyLoadInFlight = false;
    setState(() {
      _bootstrapping = true;
      _sequentialTailLoading = false;
      _sequentialUnlockedTitles.clear();
      _firstSectionReadyNotified = false;
      _allRecipes.clear();
      _displayedSections.clear();
      _displayedSeasonal.clear();
      _displayedSeasonalIds.clear();
      _seasonalIndexedIds = const [];
      _homeSectionIndexedIdsByTitle.clear();
      _chefIndexByChef = {};
      _chefRecipesByChef.clear();
      _resetSectionFetchState();
      _lastCursor = null;
      _hasMore = true;
      _loadingMore = false;
      _seedingCursor = false;
    });
    await _initializePage(forceRefresh: true);
  }

  Future<void> _initializePage({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final diskFresh = await _recipeService.isHomeTrendingDiskCacheFresh();
      if (diskFresh) {
        final cached = await _recipeService.peekHomeTrendingFeedCache();
        if (cached != null && cached.allRecipes.isNotEmpty) {
          final indexChanged = await _homeSectionIndexChanged(cached);
          if (!mounted) return;
          if (indexChanged) {
            PerfMonitor.instance.event('home.diskCacheStaleIndex');
          } else {
            PerfMonitor.instance.event('home.diskCacheHit');
            _restoreHomeTrendingFromCache(cached);
            if (!mounted) return;
            setState(() => _bootstrapping = false);
            if (widget.sequentialInlineBootstrap) {
              _notifyFirstSectionReady();
            }
            // 구버전 캐시(셰프 인덱스 미포함)로 히트한 경우, 셰프 섹션이 비어
            // 보이므로 백그라운드로 셰프만 프라임해 자가 치유한다.
            if (_chefIndexByChef.isEmpty) {
              unawaited(_healChefSectionFromCacheHit());
            }
            // 게스트 lead-in 캐시만 있으면 멤버 구간만 이어서 채운다.
            if (widget.showMembersOnlySections &&
                !_hasMembersOnlyCarouselsReady()) {
              unawaited(_loadMembersOnlySectionsAfterSignIn());
            }
            return;
          }
        }
      }
      // 캐시 미스: 만료 payload 삭제와 Firestore bootstrap을 동시에 진행.
      await PerfMonitor.instance.measure('home.bootstrap.network', () async {
        await Future.wait([
          _fetchTrendingBootstrapFromNetwork(),
          if (!diskFresh) _recipeService.clearExpiredHomeTrendingDiskCache(),
        ]);
      });
    } else {
      await PerfMonitor.instance.measure(
        'home.bootstrap.network(refresh)',
        () => _fetchTrendingBootstrapFromNetwork(),
      );
    }

    if (!mounted) return;
    setState(() => _bootstrapping = false);
    _schedulePublishHomeTrendingCache();
    if (widget.showMembersOnlySections) {
      unawaited(_loadMoreRecipes(rawLimit: _kTrendingNowRawLimit));
      unawaited(_warmUpSeasonalUntilFirstMatch());
    }
  }

  /// Firestore bootstrap — 디스크 TTL 확인과 병렬로 시작할 수 있게 분리.
  Future<void> _fetchTrendingBootstrapFromNetwork() async {
    if (widget.inline && widget.sequentialInlineBootstrap) {
      await _fetchTrendingBootstrapSequential();
      return;
    }

    final initialFetch = widget.showMembersOnlySections
        ? (_allRecipes.isEmpty
              ? _loadMoreRecipes(
                  shouldSetState: false,
                  rawLimit: _kTrendingNowRawLimit,
                )
              : _seedCursorFromCurrentList())
        : Future<void>.value();
    final homeSectionFetch = _primeHomeSectionIndexRecipes();
    final chefFetch = _primeChefIndexRecipes();
    await Future.wait([
      initialFetch,
      homeSectionFetch,
      chefFetch,
      if (widget.showMembersOnlySections) _primeSeasonalIndexRecipes(),
    ]);
    await _bootstrapInitialSections();
  }

  static const String _kTrendingNowTitle = '실시간 인기 레시피';
  static const String _kLegacyTrendingNowTitle = '지금 뜨는 레시피';
  static const String _kSeasonalRevealKey = '__seasonal__';
  static const String _kChefRevealKey = '__chef__';

  Future<void> _fetchTrendingBootstrapSequential() async {
    final generation = _bootstrapGeneration;
    _sequentialTailLoading = true;
    _sequentialUnlockedTitles.clear();
    _setStateIfBootstrapCurrent(generation, () {});

    var firstRailReady = false;
    Future<void> primeVisibleSection(_TrendSectionDef config) async {
      if (config.title == _kTrendingNowTitle) {
        var rounds = 0;
        while (mounted &&
            _isBootstrapGenerationCurrent(generation) &&
            rounds < _kBootstrapMaxFetchRounds) {
          await _loadMoreRecipes(
            shouldSetState: false,
            refreshSections: false,
            rawLimit: _kTrendingNowRawLimit,
          );
          if (!_isBootstrapGenerationCurrent(generation)) return;
          _refreshSingleSection(config);
          final trendingCount =
              _displayedSections[_kTrendingNowTitle]?.length ?? 0;
          if (trendingCount >= _kInitialPerSection || !_hasMore) break;
          rounds += 1;
        }
      } else {
        await _primeHomeSectionIndex(config);
        if (!_isBootstrapGenerationCurrent(generation)) return;
        _refreshSingleSection(config);
        await _fillSectionSeed(config);
      }
      if (!_isBootstrapGenerationCurrent(generation)) return;
      _sequentialUnlockedTitles.add(config.title);
      _setStateIfBootstrapCurrent(generation, () {
        if (!firstRailReady) _bootstrapping = false;
      });
      if (!firstRailReady && _isBootstrapGenerationCurrent(generation)) {
        firstRailReady = true;
        _notifyFirstSectionReady();
      }
      await Future<void>.delayed(Duration.zero);
    }

    // 온보딩 부스트(이유식 등)를 셰프보다 먼저 연다.
    for (final config in _visibleSections) {
      if (!mounted || !_isBootstrapGenerationCurrent(generation)) return;
      if (!_isBoostedSection(config)) continue;
      await primeVisibleSection(config);
    }

    await PerfMonitor.instance.measure(
      'home.chef',
      () => _primeChefIndexRecipes(),
    );
    if (!_isBootstrapGenerationCurrent(generation)) return;
    _refreshDisplayedSections(seedOnly: true);
    _sequentialUnlockedTitles.add(_kChefRevealKey);
    _setStateIfBootstrapCurrent(generation, () {
      if (!firstRailReady) _bootstrapping = false;
    });
    if (!firstRailReady && _isBootstrapGenerationCurrent(generation)) {
      firstRailReady = true;
      _notifyFirstSectionReady();
    }
    final waitLeadIn = widget.waitForInlineLeadIn;
    if (waitLeadIn != null) {
      await waitLeadIn();
    }
    if (!_isBootstrapGenerationCurrent(generation)) return;
    await Future<void>.delayed(Duration.zero);

    for (final config in _visibleSections) {
      if (!mounted || !_isBootstrapGenerationCurrent(generation)) return;
      if (_isBoostedSection(config)) continue;
      await primeVisibleSection(config);
    }

    if (!_isBootstrapGenerationCurrent(generation)) return;

    if (widget.showMembersOnlySections) {
      await PerfMonitor.instance.measure(
        'home.seasonal',
        () => _primeSeasonalIndexRecipes(),
      );
      if (!_isBootstrapGenerationCurrent(generation)) return;
      _refreshDisplayedSections(seedOnly: true);
      _sequentialUnlockedTitles.add(_kSeasonalRevealKey);
      _setStateIfBootstrapCurrent(generation, () {});

      await _appendDisplayedForSection(_kLeanStrongSectionTitle);
    }

    // 로그인으로 세대가 바뀌었으면 loading 해제를 하지 않는다.
    // (멤버 로드 finally 가 소유권을 가진다.)
    _setStateIfBootstrapCurrent(generation, () {
      _sequentialTailLoading = false;
    });
  }

  void _notifyFirstSectionReady() {
    if (_firstSectionReadyNotified) return;
    _firstSectionReadyNotified = true;
    widget.onFirstSectionReady?.call();
  }

  Future<void> _primeHomeSectionIndex(_TrendSectionDef config) async {
    final key = _indexKeyForSection(config);
    if (key == null) return;
    if (config.countries != null && config.countries!.isNotEmpty) {
      await _primeCountrySectionRecipes(config);
      return;
    }
    if (_homeSectionIndexedIdsByTitle[config.title]?.isNotEmpty == true) {
      if ((_sectionFetchedCount[config.title] ?? 0) == 0) {
        await _ensureSectionRecipesFetched(
          config.title,
          _kSectionInitialFetch,
        );
      }
      return;
    }
    final ids = await _recipeService.getHomeSectionRecipeIds(
      sectionKey: key,
      limit: 30,
    );
    if (ids.isEmpty) {
      _sectionExhausted[config.title] = true;
      return;
    }
    _homeSectionIndexedIdsByTitle[config.title] = List<String>.from(ids);
    _sectionFetchedCount[config.title] = 0;
    // 섹션당 초기 5개만 full-doc fetch. 나머지는 스크롤 append 시 채운다.
    await _ensureSectionRecipesFetched(
      config.title,
      _kSectionInitialFetch,
    );
  }

  /// 중식/양식 등은 `home_section_index`가 없어서 카테고리 쿼리로 직접 채운다.
  Future<void> _primeCountrySectionRecipes(_TrendSectionDef config) async {
    final visible = _displayedSections[config.title]?.length ?? 0;
    if (visible >= _kInitialPerSection) return;
    final country = config.countries?.isNotEmpty == true
        ? config.countries!.first
        : '';
    if (country.isEmpty) return;
    try {
      final recipes = await _recipeService.fetchRecipesByCountryLabel(
        country: country,
        limit: 30,
      );
      if (!mounted || recipes.isEmpty) return;
      _appendUnique(recipes);
    } catch (e) {
      debugPrint('[TrendingAllPage] country rail $country failed: $e');
    }
  }

  void _refreshSingleSection(_TrendSectionDef config, {bool seedOnly = true}) {
    final ordered = _orderedRecipesForSection(config);
    _mergeSectionRecipes(config.title, ordered, seedOnly: seedOnly);
  }

  Future<void> _fillSectionSeed(_TrendSectionDef config) async {
    if (config.countries != null && config.countries!.isNotEmpty) {
      if ((_displayedSections[config.title]?.length ?? 0) <
          _kInitialPerSection) {
        await _primeCountrySectionRecipes(config);
        _refreshSingleSection(config);
      }
      var rounds = 0;
      while (mounted &&
          rounds < _kBootstrapMaxFetchRounds &&
          (_displayedSections[config.title]?.length ?? 0) <
              _kInitialPerSection &&
          _hasMore) {
        rounds += 1;
        final before = _allRecipes.length;
        await _loadMoreRecipes(
          shouldSetState: false,
          rawLimit: _kTrendingNowRawLimit,
        );
        _refreshSingleSection(config);
        if (_allRecipes.length == before) break;
      }
      return;
    }
    if (_indexKeyForSection(config) == null) return;
    final profile = _onboardingProfile;
    final hideRules = profile != null && hasHomeHideRules(profile);
    if (!hideRules && !_isBoostedSection(config)) return;
    var rounds = 0;
    final maxRounds = _isBoostedSection(config) ? 8 : 2;
    while (mounted &&
        rounds < maxRounds &&
        (_displayedSections[config.title]?.length ?? 0) < _kInitialPerSection &&
        _sectionExhausted[config.title] != true) {
      rounds += 1;
      final got = await _ensureSectionRecipesFetched(
        config.title,
        _kSectionAppendFetch,
      );
      if (got == 0) break;
      _refreshSingleSection(config);
    }
  }

  bool _isSectionRevealed(String revealKey) {
    if (!widget.sequentialInlineBootstrap || !_sequentialTailLoading) {
      return true;
    }
    return _sequentialUnlockedTitles.contains(revealKey);
  }

  Future<void> _primeHomeSectionIndexRecipes() async {
    final keys = <String>{};
    for (final config in _visibleSections) {
      if (config.countries != null && config.countries!.isNotEmpty) {
        continue;
      }
      final key = _indexKeyForSection(config);
      if (key != null) keys.add(key);
    }
    if (keys.isEmpty) return;

    final keyList = keys.toList();
    final idLists = await Future.wait(
      keyList.map(
        (k) => _recipeService.getHomeSectionRecipeIds(sectionKey: k, limit: 30),
      ),
    );
    final keyToIds = <String, List<String>>{};
    for (var i = 0; i < keyList.length; i++) {
      keyToIds[keyList[i]] = idLists[i];
    }

    final titlesToFetch = <String>[];
    for (final config in _visibleSections) {
      if (config.countries != null && config.countries!.isNotEmpty) {
        continue;
      }
      final key = _indexKeyForSection(config);
      if (key == null) continue;
      final ids = keyToIds[key] ?? const <String>[];
      if (ids.isEmpty) {
        _sectionExhausted[config.title] = true;
        continue;
      }
      _homeSectionIndexedIdsByTitle[config.title] = List<String>.from(ids);
      _sectionFetchedCount[config.title] = 0;
      titlesToFetch.add(config.title);
    }
    if (titlesToFetch.isEmpty) return;

    // 섹션마다 앞 5개만 병렬 fetch (이전: 합쳐 최대 60).
    await Future.wait(
      titlesToFetch.map(
        (title) => _ensureSectionRecipesFetched(title, _kSectionInitialFetch),
      ),
    );
  }

  Future<void> _primeChefIndexRecipes() async {
    final byChef = await _recipeService.getChefRecipeIdsByChef();
    if (byChef.isEmpty) return;
    _chefIndexByChef = byChef;
    _chefFetchedCount.clear();
    _chefExhausted.clear();
    _chefFetchInFlight.clear();

    // 초기: 셰프당 [_kChefFetch]개. 이후 가로 스크롤에서 append.
    await Future.wait(
      byChef.keys.map(
        (chef) => _ensureChefRecipesFetched(chef, _kChefFetch),
      ),
    );
    if (!kReleaseMode) {
      final resolved = _buildChefSectionData();
      PerfMonitor.instance.event(
        'home.chef.diag chefsFromIndex=${byChef.length} '
        'perChefFetch=$_kChefFetch '
        'resolvedChefs>=2=${resolved.chefs.length}',
      );
    }
  }

  /// 셰프 인덱스의 다음 [extra]개 ID를 fetch 해 `_allRecipes`에 채운다.
  Future<int> _ensureChefRecipesFetched(String chef, int extra) async {
    if (extra <= 0) return 0;
    if (_chefExhausted[chef] == true) return 0;
    if (_chefFetchInFlight.contains(chef)) return 0;

    final indexedIds = _chefIndexByChef[chef];
    if (indexedIds == null || indexedIds.isEmpty) {
      _chefExhausted[chef] = true;
      return 0;
    }

    final fetched = _chefFetchedCount[chef] ?? 0;
    if (SectionRecipeFetchWindow.isExhausted(
      fetchedCount: fetched,
      totalIds: indexedIds.length,
    )) {
      _chefExhausted[chef] = true;
      return 0;
    }

    final nextIds = SectionRecipeFetchWindow.nextIds(
      indexedIds: indexedIds,
      fetchedCount: fetched,
      extra: extra,
    );
    if (nextIds.isEmpty) {
      _chefExhausted[chef] = true;
      return 0;
    }

    _chefFetchInFlight.add(chef);
    try {
      final recipes = await _recipeService.getExploreRecipesByIds(
        nextIds,
        limit: nextIds.length,
      );
      if (!mounted) return 0;
      _appendUnique(recipes);
      final newFetched = fetched + nextIds.length;
      _chefFetchedCount[chef] = newFetched;
      if (SectionRecipeFetchWindow.isExhausted(
        fetchedCount: newFetched,
        totalIds: indexedIds.length,
      )) {
        _chefExhausted[chef] = true;
      }
      return nextIds.length;
    } finally {
      _chefFetchInFlight.remove(chef);
    }
  }

  /// 선택한 셰프 캐러셀에 다음 [_kChefAppendFetch]장을 붙인다.
  Future<bool> _appendDisplayedForChef(String chef) async {
    if (chef.isEmpty) return false;
    if (_chefExhausted[chef] == true &&
        (_chefFetchInFlight.contains(chef) != true)) {
      // 소진돼도 풀에 더 들어온 게 있으면 capture로 반영
      final before = _chefRecipesByChef[chef]?.length ?? 0;
      _captureChefRecipesFromPool();
      return (_chefRecipesByChef[chef]?.length ?? 0) > before;
    }

    final before = _chefRecipesByChef[chef]?.length ?? 0;
    await _ensureChefRecipesFetched(chef, _kChefAppendFetch);
    if (!mounted) return false;
    _captureChefRecipesFromPool();
    return (_chefRecipesByChef[chef]?.length ?? 0) > before;
  }

  /// 디스크 캐시 히트(구버전 캐시)로 셰프 인덱스가 비었을 때, 셰프만 조용히
  /// 다시 프라임해 섹션을 채우고 캐시를 최신 스키마로 재발행한다.
  Future<void> _healChefSectionFromCacheHit() async {
    try {
      await _primeChefIndexRecipes();
    } catch (_) {
      return;
    }
    if (!mounted || _chefIndexByChef.isEmpty) return;
    setState(() {});
    _schedulePublishHomeTrendingCache();
  }

  void _schedulePublishHomeTrendingCache() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _allRecipes.isEmpty) return;
      _publishHomeTrendingCache();
    });
  }

  void _restoreHomeTrendingFromCache(HomeTrendingFeedSnapshot cached) {
    _appendUnique(cached.allRecipes);
    _seasonalIndexedIds = List<String>.from(cached.seasonalIndexedIds);
    _hasMore = cached.hasMore;
    // 디스크 캐시 히트 경로는 셰프 fetch를 생략하므로, 캐시에 저장된 셰프
    // 인덱스를 복원해 셰프 섹션이 사라지지 않게 한다.
    if (cached.chefIndex.isNotEmpty) {
      _chefIndexByChef = {
        for (final e in cached.chefIndex.entries)
          e.key: List<String>.from(e.value),
      };
      // 캐시에 오프셋이 없으므로 풀에 이미 있는 ID 개수로 self-heal.
      final poolIds = <String>{
        for (final r in _allRecipes)
          if ((r['id'] as String?)?.isNotEmpty ?? false) r['id'] as String,
      };
      _chefFetchedCount.clear();
      _chefExhausted.clear();
      for (final entry in _chefIndexByChef.entries) {
        var count = 0;
        for (final id in entry.value) {
          if (poolIds.contains(id)) {
            count++;
          } else {
            break; // 앞쪽부터 연속 fetch 가정
          }
        }
        _chefFetchedCount[entry.key] = count;
        if (count >= entry.value.length) {
          _chefExhausted[entry.key] = true;
        }
      }
    }

    _homeSectionIndexedIdsByTitle
      ..clear()
      ..addAll(
        cached.homeSectionIndexedIdsByTitle.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        ),
      );
    _sectionFetchedCount
      ..clear()
      ..addAll(cached.sectionFetchedCount);
    _sectionExhausted.clear();
    for (final entry in _homeSectionIndexedIdsByTitle.entries) {
      final fetched = _sectionFetchedCount[entry.key] ?? 0;
      if (SectionRecipeFetchWindow.isExhausted(
        fetchedCount: fetched,
        totalIds: entry.value.length,
      )) {
        _sectionExhausted[entry.key] = true;
      }
    }
    // 구버전 캐시(오프셋 없음): 풀에 이미 있는 인덱스 ID 개수로 self-heal.
    if (_homeSectionIndexedIdsByTitle.isNotEmpty &&
        cached.sectionFetchedCount.isEmpty) {
      final poolIds = <String>{
        for (final r in _allRecipes)
          if ((r['id'] as String?)?.isNotEmpty ?? false) r['id'] as String,
      };
      for (final entry in _homeSectionIndexedIdsByTitle.entries) {
        var count = 0;
        for (final id in entry.value) {
          if (!poolIds.contains(id)) break;
          count += 1;
        }
        _sectionFetchedCount[entry.key] = count;
        if (SectionRecipeFetchWindow.isExhausted(
          fetchedCount: count,
          totalIds: entry.value.length,
        )) {
          _sectionExhausted[entry.key] = true;
        }
      }
    }

    _seasonalFetchedCount = cached.seasonalFetchedCount;
    if (_seasonalIndexedIds.isEmpty) {
      _seasonalExhausted = true;
    } else if (cached.seasonalFetchedCount <= 0 &&
        cached.homeSectionIndexedIdsByTitle.isEmpty) {
      // 구버전: 제철 ID가 풀에 몇 개 있는지 prefix 길이로 추정.
      final poolIds = <String>{
        for (final r in _allRecipes)
          if ((r['id'] as String?)?.isNotEmpty ?? false) r['id'] as String,
      };
      var count = 0;
      for (final id in _seasonalIndexedIds) {
        if (!poolIds.contains(id)) break;
        count += 1;
      }
      _seasonalFetchedCount = count;
    }
    _seasonalExhausted = SectionRecipeFetchWindow.isExhausted(
      fetchedCount: _seasonalFetchedCount,
      totalIds: _seasonalIndexedIds.length,
    );

    final restoredCarousel =
        cached.displayedSections.isNotEmpty ||
        cached.displayedSeasonal.isNotEmpty;

    if (cached.displayedSections.isNotEmpty) {
      _displayedSections
        ..clear()
        ..addAll(
          cached.displayedSections.map(
            (k, v) {
              final title = k == _kLegacyTrendingNowTitle
                  ? _kTrendingNowTitle
                  : k;
              return MapEntry(title, List<Map<String, dynamic>>.from(v));
            },
          ),
        );
    }

    if (cached.displayedSeasonal.isNotEmpty) {
      _displayedSeasonal
        ..clear()
        ..addAll(cached.displayedSeasonal);
      _displayedSeasonalIds
        ..clear()
        ..addAll(
          cached.displayedSeasonal
              .map((e) => e.$1['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
        );
    }

    if (!restoredCarousel) {
      _refreshDisplayedSections(seedOnly: true);
    }
  }

  void _publishHomeTrendingCache() {
    if (_allRecipes.isEmpty) return;
    final displayedSections = <String, List<Map<String, dynamic>>>{};
    for (final entry in _displayedSections.entries) {
      displayedSections[entry.key] = List<Map<String, dynamic>>.from(
        entry.value,
      );
    }
    _recipeService.publishHomeTrendingFeedCache(
      HomeTrendingFeedSnapshot(
        allRecipes: List<Map<String, dynamic>>.from(_allRecipes),
        seasonalIndexedIds: List<String>.from(_seasonalIndexedIds),
        hasMore: _hasMore,
        displayedSections: displayedSections,
        displayedSeasonal: List.from(_displayedSeasonal),
        chefIndex: {
          for (final e in _chefIndexByChef.entries)
            e.key: List<String>.from(e.value),
        },
        homeSectionIndexedIdsByTitle: {
          for (final e in _homeSectionIndexedIdsByTitle.entries)
            e.key: List<String>.from(e.value),
        },
        sectionFetchedCount: Map<String, int>.from(_sectionFetchedCount),
        seasonalFetchedCount: _seasonalFetchedCount,
      ),
    );
  }

  /// 제철용 인덱스 ID 전체 + 지금까지 fetch 한 개수 (섹션 헬퍼와 동일 패턴).
  int _seasonalFetchedCount = 0;
  bool _seasonalExhausted = false;
  bool _seasonalFetchInFlight = false;

  Future<void> _primeSeasonalIndexRecipes() async {
    final month = DateTime.now().month;
    final ids = await _recipeService.getSeasonalRecipeIdsForMonth(
      month: month,
      limit: 30,
    );
    if (ids.isEmpty) {
      _seasonalIndexedIds = const <String>[];
      _seasonalFetchedCount = 0;
      _seasonalExhausted = true;
      return;
    }
    // 전체 ID는 보관하고, full-doc 는 초기 [_kSeasonalInitialFetch]개만.
    _seasonalIndexedIds = List<String>.from(ids);
    _seasonalFetchedCount = 0;
    _seasonalExhausted = false;
    await _ensureSeasonalRecipesFetched(_kSeasonalInitialFetch);
  }

  Future<int> _ensureSeasonalRecipesFetched(int extra) async {
    if (extra <= 0 || _seasonalExhausted || _seasonalFetchInFlight) return 0;
    if (_seasonalIndexedIds.isEmpty) {
      _seasonalExhausted = true;
      return 0;
    }
    final nextIds = SectionRecipeFetchWindow.nextIds(
      indexedIds: _seasonalIndexedIds,
      fetchedCount: _seasonalFetchedCount,
      extra: extra,
    );
    if (nextIds.isEmpty) {
      _seasonalExhausted = true;
      return 0;
    }
    _seasonalFetchInFlight = true;
    try {
      final recipes = await _recipeService.getExploreRecipesByIds(
        nextIds,
        limit: nextIds.length,
      );
      if (!mounted) return 0;
      _appendUnique(recipes);
      _seasonalFetchedCount += nextIds.length;
      if (SectionRecipeFetchWindow.isExhausted(
        fetchedCount: _seasonalFetchedCount,
        totalIds: _seasonalIndexedIds.length,
      )) {
        _seasonalExhausted = true;
      }
      return nextIds.length;
    } catch (_) {
      return 0;
    } finally {
      _seasonalFetchInFlight = false;
    }
  }

  Future<void> _warmUpSeasonalUntilFirstMatch() async {
    if (!mounted) return;
    if (_displayedSeasonal.isNotEmpty) return;
    // 인덱스 기반: page 대신 제철 ID를 추가로 fetch.
    if (_seasonalIndexedIds.isNotEmpty && !_seasonalExhausted) {
      await _ensureSeasonalRecipesFetched(_kSectionAppendFetch);
      if (!mounted) return;
      _refreshDisplayedSections(seedOnly: true);
      if (mounted && _displayedSeasonal.isNotEmpty) setState(() {});
      return;
    }
    var rounds = 0;
    while (mounted &&
        rounds < _kSeasonalWarmupMaxRounds &&
        _displayedSeasonal.isEmpty &&
        _hasMore) {
      rounds += 1;
      await _loadMoreRecipes(
        shouldSetState: true,
        rawLimit: _kTrendingNowRawLimit,
      );
    }
  }

  void _appendUnique(List<Map<String, dynamic>> batch) {
    appendUniqueRecipeMapsWithCap(
      list: _allRecipes,
      batch: batch,
      maxItems: _kAllRecipesMaxInMemory,
    );
  }

  Future<void> _seedCursorFromCurrentList() async {
    if (_seedingCursor || _allRecipes.isEmpty || _lastCursor != null) return;
    _seedingCursor = true;
    try {
      final lastId = _allRecipes.last['id'] as String?;
      if (lastId == null || lastId.isEmpty) {
        _hasMore = false;
        return;
      }
      final snap = await FirebaseFirestore.instance
          .collection('recipes')
          .doc(lastId)
          .get();
      if (!mounted) return;
      if (snap.exists) {
        _lastCursor = snap;
      } else {
        _hasMore = false;
      }
    } catch (_) {
      _hasMore = false;
    } finally {
      _seedingCursor = false;
    }
  }

  Future<void> _loadMoreRecipes({
    bool shouldSetState = true,
    bool refreshSections = true,
    int rawLimit = 30,
    /// true 이면 기존 `_allRecipes`(게스트 인덱스 프라임 등)가 있어도 explore
    /// 피드를 head 부터 다시 연다. last-id cursor seed 를 건너뛴다.
    bool restartFromHead = false,
  }) async {
    if (!mounted || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      if (restartFromHead) {
        _lastCursor = null;
      } else if (_allRecipes.isNotEmpty && _lastCursor == null) {
        await _seedCursorFromCurrentList();
        if (!_hasMore || _lastCursor == null) {
          return;
        }
      }
      final page = await _recipeService.fetchExploreRecipesPage(
        startAfter: _lastCursor,
        rawLimit: rawLimit,
      );
      if (!mounted) return;
      _lastCursor = page.lastRawDocument;
      _hasMore = page.hasMore;
      final before = _allRecipes.length;
      _appendUnique(page.recipes);
      final addedAny = _allRecipes.length != before;
      // 신규 레시피가 없어도 풀·인덱스에 이미 있는 카드를 캐러셀에 붙일 수 있다.
      if (refreshSections) {
        _refreshDisplayedSections();
      }
      if (shouldSetState && (addedAny || !page.hasMore)) {
        setState(() {});
      }
    } catch (_) {
      // keep current list on paging failure
    } finally {
      _loadingMore = false;
    }
  }

  static const String _kLeanStrongSectionTitle = '고단백 저지방';

  bool _isNearCarouselEnd(ScrollMetrics metrics, int itemCount) {
    if (metrics.axis != Axis.horizontal || itemCount <= 0) return false;
    // 카드 수가 prefetch 창보다 작으면 처음부터 near-end로 오인된다.
    // 실제 가로 이동이 있을 때만 append/prefetch를 허용한다.
    if (itemCount <= _kPrefetchAhead && metrics.pixels <= 0) return false;
    final firstVisibleIndex =
        (metrics.pixels /
                (TrendingAllPage._cardWidth + TrendingAllPage._cardGap))
            .floor()
            .clamp(0, itemCount - 1);
    final remainingAhead = itemCount - firstVisibleIndex - 1;
    return remainingAhead <= _kPrefetchAhead;
  }

  void resetScrollSummaries() {
    _sectionMaxVisibleIndex.clear();
    _sectionItemCount.clear();
    _sectionDisplayName.clear();
    _sectionScrollSummaryFlushed = false;
  }

  /// 홈 탭 이탈/dispose 시 섹션별 가로 스크롤 요약 전송.
  void flushScrollSummaries() {
    if (_sectionScrollSummaryFlushed) return;
    _sectionScrollSummaryFlushed = true;
    if (_sectionMaxVisibleIndex.isEmpty) return;
    for (final entry in _sectionMaxVisibleIndex.entries) {
      final sectionId = entry.key;
      final maxIndex = entry.value;
      final itemCount = _sectionItemCount[sectionId] ?? 0;
      if (itemCount <= 0) continue;
      // 초기 viewport만 본 경우(인덱스 0)는 노이즈로 제외. 실제 가로 탐색만.
      if (maxIndex <= 0) continue;
      final depthPercent = itemCount <= 1
          ? 100.0
          : (maxIndex / (itemCount - 1) * 100).clamp(0.0, 100.0);
      unawaited(
        AnalyticsService().trackHomeSectionScrollSummary(
          sectionId: sectionId,
          maxVisibleIndex: maxIndex,
          itemCount: itemCount,
          sectionName: _sectionDisplayName[sectionId],
          depthPercent: depthPercent,
        ),
      );
    }
    _sectionMaxVisibleIndex.clear();
    _sectionItemCount.clear();
    _sectionDisplayName.clear();
  }

  void _recordCarouselScrollDepth(
    ScrollMetrics metrics,
    int itemCount, {
    String? sectionTitle,
    bool seasonal = false,
    String? sectionKey,
  }) {
    if (metrics.axis != Axis.horizontal || itemCount <= 0) return;
    // 초기 viewport 노출만으로 summary가 나가지 않도록, 실제 가로 이동만 기록.
    if (metrics.pixels <= 0) return;
    final displayName = seasonal
        ? '${DateTime.now().month}월 제철'
        : (sectionTitle?.trim().isNotEmpty == true
              ? sectionTitle!.trim()
              : 'unknown');
    final trimmedKey = sectionKey?.trim();
    final sectionId = (trimmedKey != null && trimmedKey.isNotEmpty)
        ? trimmedKey
        : seasonal
            ? HomeSectionKeys.seasonal
            : HomeSectionKeys.keyForTitle(displayName);
    final maxIndex = computeCarouselMaxVisibleIndex(
      pixels: metrics.pixels,
      viewportDimension: metrics.viewportDimension,
      itemStride: TrendingAllPage._cardWidth + TrendingAllPage._cardGap,
      itemCount: itemCount,
    );
    final prev = _sectionMaxVisibleIndex[sectionId] ?? -1;
    if (maxIndex > prev) {
      _sectionMaxVisibleIndex[sectionId] = maxIndex;
    }
    final prevCount = _sectionItemCount[sectionId] ?? 0;
    if (itemCount > prevCount) {
      _sectionItemCount[sectionId] = itemCount;
    }
    _sectionDisplayName[sectionId] = displayName;
  }

  /// 가로 캐러셀 끝 근처: 인덱스 섹션은 ID append fetch, 지금 뜨는만 page prefetch.
  void _onCarouselSectionScroll(
    ScrollMetrics metrics,
    int itemCount, {
    String? sectionTitle,
    bool seasonal = false,
    bool prefetchOnly = false,
    String? chefName,
    String? sectionKey,
  }) {
    _recordCarouselScrollDepth(
      metrics,
      itemCount,
      sectionTitle: sectionTitle,
      seasonal: seasonal,
      sectionKey: sectionKey,
    );
    if (_bootstrapping) return;
    if (!_isNearCarouselEnd(metrics, itemCount)) return;

    final now = DateTime.now();
    if (_lastCarouselAppendAttempt != null &&
        now.difference(_lastCarouselAppendAttempt!) <
            _kCarouselAppendThrottle) {
      return;
    }
    _lastCarouselAppendAttempt = now;

    final isIndexedSection = sectionTitle != null &&
        (_homeSectionIndexedIdsByTitle[sectionTitle]?.isNotEmpty ?? false);

    // 셰프: 선택 셰프 인덱스에서 다음 ID fetch → 캐러셀 append
    if (chefName != null && chefName.isNotEmpty) {
      unawaited(() async {
        final didAppend = await _appendDisplayedForChef(chefName);
        if (didAppend && mounted) setState(() {});
      }());
      return;
    }

    if (!prefetchOnly) {
      if (seasonal) {
        unawaited(() async {
          final didAppend = await _appendDisplayedSeasonal();
          if (didAppend && mounted) setState(() {});
        }());
      } else if (sectionTitle != null && isIndexedSection) {
        unawaited(() async {
          final didAppend = await _appendDisplayedForSection(sectionTitle);
          if (didAppend && mounted) setState(() {});
        }());
      }
    }

    // 공용 page prefetch 는 '지금 뜨는' 만.
    if (sectionTitle == _kTrendingNowTitle && !_loadingMore && _hasMore) {
      unawaited(_loadMoreRecipes(rawLimit: _kTrendingNowRawLimit));
    }
  }

  List<Map<String, dynamic>> _orderedRecipesForSection(_TrendSectionDef config) {
    final indexedIds = _homeSectionIndexedIdsByTitle[config.title];
    if (indexedIds != null && indexedIds.isNotEmpty) {
      return _recipesByIndexedIds(indexedIds);
    }
    return _filterForSection(_allRecipes, config);
  }

  /// 섹션 헤더 화살표 → 해당 섹션만 모아 보는 전체 화면.
  /// 이미 불러 둔 카드를 씨앗으로 넘겨 첫 화면이 비지 않게 하고, 나머지는
  /// 새 화면이 인덱스 ID 를 다시 읽어 이어서 채운다.
  void _openSectionAll(_TrendSectionDef config) {
    final indexKey = _indexKeyForSection(config);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SectionRecipesScreen(
          title: config.title,
          sectionKey: indexKey,
          initialRecipes: _orderedRecipesForSection(config),
          showTimeBadge: config.timeMaxMinutes != null,
          preferCroppedForInstagram: widget.preferCroppedForInstagram,
          // 실시간 인기는 인덱스가 없어 공용 페이지 커서로 더 불러온다.
          loadMore: (indexKey != null && config.countries == null)
              ? null
              : () async {
                  await _loadMoreRecipes(rawLimit: _kTrendingNowRawLimit);
                  if (!mounted) return const <Map<String, dynamic>>[];
                  return _orderedRecipesForSection(config);
                },
        ),
      ),
    );
  }

  void _openSeasonalAll() {
    final month = DateTime.now().month;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SectionRecipesScreen(
          title: '$month월 제철 재료 레시피',
          emoji: '🌿',
          sectionKey: HomeSectionKeys.seasonal,
          recipeIds: _seasonalIndexedIds,
          initialRecipes: [
            for (final (recipe, _) in _filterSeasonalRecipes(month)) recipe,
          ],
          preferCroppedForInstagram: widget.preferCroppedForInstagram,
        ),
      ),
    );
  }

  void _openChefAll(String chef) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SectionRecipesScreen(
          title: '$chef 셰프 레시피',
          emoji: '👨‍🍳',
          sectionKey: HomeSectionKeys.chef,
          recipeIds: _chefIndexByChef[chef] ?? const <String>[],
          initialRecipes:
              _chefRecipesByChef[chef] ?? const <Map<String, dynamic>>[],
          preferCroppedForInstagram: widget.preferCroppedForInstagram,
        ),
      ),
    );
  }

  /// 인덱스 섹션이면 다음 [_kSectionAppendFetch] ID를 fetch 한 뒤,
  /// 캐러셀에 최대 [_kAppendPerFetch]장을 붙인다.
  Future<bool> _appendDisplayedForSection(String title) async {
    _TrendSectionDef? config;
    for (final c in _visibleSections) {
      if (c.title == title) {
        config = c;
        break;
      }
    }
    if (config == null) return false;

    final hasIndex =
        (_homeSectionIndexedIdsByTitle[title]?.isNotEmpty ?? false);
    if (hasIndex && _sectionExhausted[title] != true) {
      await _ensureSectionRecipesFetched(title, _kSectionAppendFetch);
      if (!mounted) return false;
    }

    final before = _displayedSections[title]?.length ?? 0;
    final ordered = _orderedRecipesForSection(config);
    _mergeSectionRecipes(title, ordered, seedOnly: false);
    final after = _displayedSections[title]?.length ?? 0;
    return after > before;
  }

  Future<bool> _appendDisplayedSeasonal() async {
    if (!_seasonalExhausted) {
      await _ensureSeasonalRecipesFetched(_kSectionAppendFetch);
      if (!mounted) return false;
    }
    final month = DateTime.now().month;
    final ordered = _filterSeasonalRecipes(month);
    final before = _displayedSeasonal.length;
    _mergeSeasonalRecipes(ordered, seedOnly: false);
    return _displayedSeasonal.length > before;
  }

  Future<void> _bootstrapInitialSections() async {
    _refreshDisplayedSections(seedOnly: true);
    if (!widget.showMembersOnlySections) return;

    var rounds = 0;
    while (mounted && rounds < _kBootstrapMaxFetchRounds) {
      final seasonalTarget = _seasonalIndexedIds.length < _kInitialSeasonal
          ? _seasonalIndexedIds.length
          : _kInitialSeasonal;
      final seasonalReady =
          _displayedSeasonal.length >= seasonalTarget || !_hasMore;
      final trendingCount =
          _displayedSections[_kTrendingNowTitle]?.length ?? 0;
      final trendingReady =
          trendingCount >= _kInitialPerSection || !_hasMore;

      if (trendingReady && seasonalReady) break;
      if (!_hasMore) break;
      rounds += 1;
      await _loadMoreRecipes(
        shouldSetState: false,
        rawLimit: _kTrendingNowRawLimit,
      );
      _refreshDisplayedSections(seedOnly: true);
    }
    _refreshDisplayedSections(seedOnly: true);
    await _appendDisplayedForSection(_kLeanStrongSectionTitle);
  }

  void _refreshDisplayedSections({bool seedOnly = false}) {
    if (widget.showMembersOnlySections) {
      final month = DateTime.now().month;
      final seasonal = _filterSeasonalRecipes(month);
      _mergeSeasonalRecipes(seasonal, seedOnly: seedOnly);
    }
    for (final config in _visibleSections) {
      final ordered = _orderedRecipesForSection(config);
      _mergeSectionRecipes(config.title, ordered, seedOnly: seedOnly);
    }
  }

  void _mergeSeasonalRecipes(
    List<(Map<String, dynamic>, String)> ordered, {
    required bool seedOnly,
  }) {
    if (ordered.isEmpty) return;
    final isSeedTarget = _displayedSeasonal.isEmpty;
    final int maxAdd = isSeedTarget
        ? _kInitialSeasonal
        : (seedOnly ? 0 : _kAppendPerFetch);
    var added = 0;
    for (final entry in ordered) {
      final id = entry.$1['id']?.toString() ?? '';
      if (id.isEmpty || _displayedSeasonalIds.contains(id)) continue;
      if (added >= maxAdd) break;
      _displayedSeasonal.add(entry);
      _displayedSeasonalIds.add(id);
      added += 1;
    }
  }

  void _mergeSectionRecipes(
    String title,
    List<Map<String, dynamic>> ordered, {
    required bool seedOnly,
  }) {
    if (ordered.isEmpty) return;
    final displayed = _displayedSections.putIfAbsent(title, () => []);
    final seen = displayed
        .map((r) => r['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final isSeedTarget = displayed.isEmpty;
    var maxAdd = isSeedTarget
        ? _kInitialPerSection
        : (seedOnly ? 0 : _kAppendPerFetch);
    final deficit = _kInitialPerSection - displayed.length;
    if (seedOnly && deficit > 0) {
      maxAdd = deficit;
    }
    var added = 0;
    for (final recipe in ordered) {
      final id = recipe['id']?.toString() ?? '';
      if (id.isEmpty || seen.contains(id)) continue;
      if (added >= maxAdd) break;
      displayed.add(recipe);
      seen.add(id);
      added += 1;
    }
  }

  List<Map<String, dynamic>> _filterForSection(
    List<Map<String, dynamic>> recipes,
    _TrendSectionDef config,
  ) {
    // Platform-aware routing between sections:
    // - section.platformFilter != null  → only that platform's recipes
    // - section.platformFilter == null  → exclude platforms that other
    //   sections "own" (e.g. naver_blog has its own External section, so
    //   keep it out of Trending Now / Quick / etc.).
    final ownedPlatforms = <String>{
      for (final s in TrendingAllPage._sections)
        if (s.platformFilter != null) s.platformFilter!,
    };
    String platformOf(Map<String, dynamic> r) {
      final src = r['source'];
      if (src is Map) {
        return (src['platform'] as String? ?? '').toLowerCase();
      }
      return '';
    }

    final scoped = hideRecipesOnHome(
      recipes.where((r) {
        final p = platformOf(r);
        if (config.platformFilter != null) {
          return p == config.platformFilter;
        }
        return !ownedPlatforms.contains(p);
      }).toList(),
      _onboardingProfile,
    );

    if (config.platformFilter != null) {
      // 외부 블로그 섹션: 최근 파싱 순으로만 정렬.
      _sortByParsedAtDesc(scoped);
      return scoped;
    }
    if (config.title == '건강식') {
      return _filterHealthyRecipes(scoped);
    }

    // Generic predicate pipeline so a single section config can stack
    // multiple constraints (e.g. `proteinMin` + `fatMax`, `menuTypes` +
    // `maxIngredients`, etc.) without exploding into per-title branches.
    final filtered = scoped.where((r) {
      if (config.timeMaxMinutes != null &&
          _getTotalMinutes(r) > config.timeMaxMinutes!) {
        return false;
    }
    if (config.caloriesMax != null) {
        final cal = (r['calories'] as num?)?.toDouble();
        if (cal == null || cal <= 0 || cal > config.caloriesMax!) {
          return false;
      }
    }
    if (config.proteinMin != null) {
        final protein = _numAsDouble(_llmEstimate(r)?['protein_g']);
        if (protein == null || protein < config.proteinMin!) {
          return false;
        }
      }
      if (config.fatMax != null) {
        final fat = _numAsDouble(_llmEstimate(r)?['fat_g']);
        if (fat == null || fat > config.fatMax!) {
          return false;
        }
      }
      if (config.maxIngredients != null &&
          _ingredientCount(r) > config.maxIngredients!) {
        return false;
      }
      if (config.menuTypes != null &&
          !_matchesAnyCategoryValue(
            r,
            keys: const ['menu_type'],
            allowed: config.menuTypes!,
          )) {
        return false;
      }
      if (config.countries != null &&
          !_matchesAnyCategoryValue(
            r,
            keys: const ['country', 'cuisine_type'],
            allowed: config.countries!,
          )) {
        return false;
      }
      // 태그/제목 매칭: 둘 다 지정되면 OR(태그 또는 제목 중 하나라도 맞으면 통과),
      // 하나만 지정되면 그 조건만 적용한다.
      final hasTagFilter = config.anyTags != null;
      final hasTitleFilter = config.titleKeywords != null;
      if (hasTagFilter || hasTitleFilter) {
        final tagOk = hasTagFilter && _matchesAnyTag(r, config.anyTags!);
        final titleOk =
            hasTitleFilter && _matchesTitleKeyword(r, config.titleKeywords!);
        if (!tagOk && !titleOk) {
          return false;
        }
      }
      if (config.excludeTitleKeywords != null &&
          _matchesTitleKeyword(r, config.excludeTitleKeywords!)) {
        return false;
      }
      return true;
    }).toList();

    switch (config.sortBy) {
      case _TrendSortBy.proteinDesc:
        _sortByProteinDesc(filtered);
        break;
      case _TrendSortBy.weeklySavesDesc:
        _sortByWeeklySavesDesc(filtered);
        break;
      case _TrendSortBy.parsedAtDesc:
        _sortByParsedAtDesc(filtered);
        break;
    }
    return filtered;
  }

  /// Returns the number of entries in `recipe.ingredients`. 0 when missing.
  int _ingredientCount(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final ingredients = recipeData['ingredients'];
    if (ingredients is List) return ingredients.length;
    return 0;
  }

  /// True if any of the recipe's `categories[key]` values (looked up across
  /// `keys` with case-insensitive equality) appears in [allowed]. Used by the
  /// `menuTypes` / `countries` section filters.
  bool _matchesAnyCategoryValue(
    Map<String, dynamic> recipe, {
    required List<String> keys,
    required List<String> allowed,
  }) {
    final categories = recipe['categories'];
    if (categories is! Map) return false;
    final allowedSet = allowed.map((s) => s.trim().toLowerCase()).toSet();
    for (final key in keys) {
      final raw = categories[key];
      if (raw == null) continue;
      if (raw is String) {
        if (allowedSet.contains(raw.trim().toLowerCase())) return true;
      } else if (raw is List) {
        for (final v in raw) {
          if (v is String && allowedSet.contains(v.trim().toLowerCase())) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// True if the recipe's top-level `tags` list contains any of [allowed]
  /// (case-insensitive, zero-width stripped). Used by the moment section.
  bool _matchesTitleKeyword(Map<String, dynamic> recipe, List<String> keywords) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
    final title =
        (recipe['title']?.toString().isNotEmpty == true
                ? recipe['title']?.toString()
                : recipeData['name']?.toString()) ??
            '';
    if (title.isEmpty) return false;
    final lower = title.toLowerCase();
    for (final k in keywords) {
      if (k.isNotEmpty && lower.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  bool _matchesAnyTag(Map<String, dynamic> recipe, List<String> allowed) {
    return recipeMatchesAnyTag(recipe, allowed);
  }

  /// Sort by `weeklySaves` desc, falling back to lifetime `saveCount` then
  /// the standard `completedAt`/`createdAt` tiebreaker. This keeps the
  /// "이번 주 가장 많이 저장된" row meaningful even when most fetched recipes
  /// have a zero-or-missing weekly counter.
  void _sortByWeeklySavesDesc(List<Map<String, dynamic>> list) {
    int weekly(Map<String, dynamic> r) =>
        (r['weeklySaves'] as num?)?.toInt() ?? 0;
    int lifetime(Map<String, dynamic> r) =>
        (r['saveCount'] as num?)?.toInt() ?? 0;
    list.sort((a, b) {
      final wa = weekly(a);
      final wb = weekly(b);
      if (wa != wb) return wb.compareTo(wa);
      final la = lifetime(a);
      final lb = lifetime(b);
      if (la != lb) return lb.compareTo(la);
      final aDate = _parsedAt(a);
      final bDate = _parsedAt(b);
      if (aDate != null && bDate != null) return bDate.compareTo(aDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      return 0;
    });
  }

  DateTime? _parsedAt(Map<String, dynamic> recipe) {
    final completed = recipe['completedAt'];
    final created = recipe['createdAt'];
    if (completed is Timestamp) return completed.toDate();
    if (completed is DateTime) return completed;
    if (created is Timestamp) return created.toDate();
    if (created is DateTime) return created;
    return null;
  }

  void _sortByParsedAtDesc(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final aDate = _parsedAt(a);
      final bDate = _parsedAt(b);
      if (aDate != null && bDate != null) return bDate.compareTo(aDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      final aId = a['id']?.toString() ?? '';
      final bId = b['id']?.toString() ?? '';
      return bId.compareTo(aId);
    });
  }

  void _sortByProteinDesc(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final aNutrition = a['nutrition'] as Map<String, dynamic>?;
      final bNutrition = b['nutrition'] as Map<String, dynamic>?;
      final aLlm = aNutrition?['llm_estimate'] as Map<String, dynamic>?;
      final bLlm = bNutrition?['llm_estimate'] as Map<String, dynamic>?;
      final aProtein = (aLlm?['protein_g'] as num?)?.toDouble() ?? -1;
      final bProtein = (bLlm?['protein_g'] as num?)?.toDouble() ?? -1;
      final cmp = bProtein.compareTo(aProtein);
      if (cmp != 0) return cmp;
      final aDate = _parsedAt(a);
      final bDate = _parsedAt(b);
      if (aDate != null && bDate != null) return bDate.compareTo(aDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      return 0;
    });
  }

  List<Map<String, dynamic>> _filterHealthyRecipes(
    List<Map<String, dynamic>> recipes,
  ) {
    final list = <Map<String, dynamic>>[];
    for (final r in recipes) {
      final llm = _llmEstimate(r);
      final calories = _numAsDouble(llm?['calories_per_serving']);
      final sodium = _numAsDouble(llm?['sodium_mg']);
      final sugar = _numAsDouble(llm?['sugar_g']);
      if (calories == null || sodium == null || sugar == null) continue;
      if (calories > 600 || sodium > 900 || sugar > 15) continue;
      list.add(r);
    }
    list.sort((a, b) {
      final scoreA = _healthyScore(a);
      final scoreB = _healthyScore(b);
      final cmp = scoreB.compareTo(scoreA);
      if (cmp != 0) return cmp;
      final aDate = _parsedAt(a);
      final bDate = _parsedAt(b);
      if (aDate != null && bDate != null) return bDate.compareTo(aDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      return 0;
    });
    return list;
  }

  Map<String, dynamic>? _llmEstimate(Map<String, dynamic> recipe) {
    final nutrition = recipe['nutrition'] as Map<String, dynamic>?;
    final llm = nutrition?['llm_estimate'] as Map<String, dynamic>?;
    return llm;
  }

  double? _numAsDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return null;
  }

  double _ratingBonus(dynamic ratingRaw) {
    final rating = (ratingRaw?.toString() ?? '').trim().toUpperCase();
    switch (rating) {
      case 'A+':
        return 20;
      case 'A':
        return 16;
      case 'B+':
        return 12;
      case 'B':
        return 10;
      case 'C+':
        return 6;
      case 'C':
        return 4;
      default:
        return 0;
    }
  }

  int _healthyTagCount(Map<String, dynamic> recipe) {
    const healthyTags = {'건강식', '균형식', '채소가득', '저당식'};
    final found = <String>{};
    final tags = recipe['tags'];
    if (tags is List) {
      for (final t in tags) {
        final s = t.toString().trim();
        if (healthyTags.contains(s)) found.add(s);
      }
    }
    final categories = recipe['categories'];
    if (categories is Map) {
      for (final value in categories.values) {
        if (value is List) {
          for (final t in value) {
            final s = t.toString().trim();
            if (healthyTags.contains(s)) found.add(s);
          }
        }
      }
    }
    return found.length;
  }

  double _healthyScore(Map<String, dynamic> recipe) {
    final llm = _llmEstimate(recipe);
    final protein = _numAsDouble(llm?['protein_g']) ?? 0;
    final fiber = _numAsDouble(llm?['fiber_g']) ?? 0;
    final calories = _numAsDouble(llm?['calories_per_serving']) ?? 600;
    final sodium = _numAsDouble(llm?['sodium_mg']) ?? 900;
    final sugar = _numAsDouble(llm?['sugar_g']) ?? 15;
    final rating = _ratingBonus(recipe['nutrition_rating']);
    final tagBonus = (1.5 * _healthyTagCount(recipe)).clamp(0, 4);

    double score = 0;
    score += protein * 1.2;
    score += fiber * 1.5;
    score += (600 - calories).clamp(0, 600) / 12;
    score += (900 - sodium).clamp(0, 900) / 30;
    score += (15 - sugar).clamp(0, 15) * 2;
    score += rating;
    score += tagBonus;
    return score;
  }

  int _getTotalMinutes(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final steps = recipeData['steps'] as List? ?? [];
    int total = 0;
    for (final step in steps) {
      if (step is Map && step['est_minutes'] != null) {
        total += (step['est_minutes'] as num).toInt();
      }
    }
    return total > 0 ? total : 15;
  }

  List<(Map<String, dynamic>, String)> _filterSeasonalRecipes(int month) {
    final seasonalItems = _seasonalIngredients[month] ?? [];
    if (seasonalItems.isEmpty) return [];
    final result = <(Map<String, dynamic>, String)>[];
    final seen = <String>{};
    final byId = <String, Map<String, dynamic>>{};
    for (final recipe in _allRecipes) {
      final id = recipe['id']?.toString() ?? '';
      if (id.isNotEmpty) byId[id] = recipe;
    }

    String labelFromRecipe(Map<String, dynamic> recipe) {
      final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
      final title =
          (recipe['title']?.toString() ??
                  recipeData['title']?.toString() ??
                  recipeData['name']?.toString() ??
                  '')
              .toLowerCase();
      for (final (keyword, label) in seasonalItems) {
        if (title.contains(keyword.toLowerCase())) return label;
      }
      return '';
    }

    for (final id in _seasonalIndexedIds) {
      final recipe = byId[id];
      if (recipe == null) continue;
      if (recipeHiddenOnHome(recipe, _onboardingProfile)) continue;
      final label = labelFromRecipe(recipe);
      if (label.isEmpty) continue;
      if (seen.add(id)) {
        result.add((recipe, label));
      }
    }

    for (final recipe in _allRecipes) {
      if (recipeHiddenOnHome(recipe, _onboardingProfile)) continue;
      final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
      final title =
          (recipe['title']?.toString() ??
                  recipeData['title']?.toString() ??
                  recipeData['name']?.toString() ??
                  '')
              .toLowerCase();
      if (title.isEmpty) continue;
      for (final (keyword, label) in seasonalItems) {
        if (title.contains(keyword.toLowerCase())) {
          final id = recipe['id']?.toString() ?? '';
          if (id.isNotEmpty && !seen.contains(id)) {
            seen.add(id);
            result.add((recipe, label));
          }
          break;
        }
      }
    }
    result.sort(
      (a, b) => b.$1['id'].toString().compareTo(a.$1['id'].toString()),
    );
    return result;
  }

  void _trackSectionImpressionOnce({
    required String sectionId,
    required String sectionName,
    required int sectionOrder,
    required int visibleRecipeCount,
    String? chipSectionKey,
  }) {
    if (_impressedSectionIds.contains(sectionId)) return;
    _impressedSectionIds.add(sectionId);
    unawaited(
      AnalyticsService().trackHomeSectionImpression(
        sectionId: sectionId,
        sectionName: sectionName,
        sectionOrder: sectionOrder,
        visibleRecipeCount: visibleRecipeCount,
        chipSectionKey: chipSectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
  }

  Widget _wrapSectionImpression({
    required String sectionTitle,
    required int sectionOrder,
    required int visibleRecipeCount,
    required Widget child,
    String? sectionKey,
  }) {
    final rawKey = (sectionKey != null && sectionKey.trim().isNotEmpty)
        ? sectionKey.trim()
        : HomeSectionKeys.keyForTitle(sectionTitle);
    final isProgramChip =
        rawKey.startsWith('program_') && rawKey != 'program_curation';
    final sectionId = isProgramChip ? 'program_curation' : rawKey;
    return _ImpressedHomeSection(
      sectionId: sectionId,
      child: VisibilityDetector(
        key: Key('home_section_impression_$sectionId'),
        onVisibilityChanged: (info) {
          if (info.visibleFraction < _kSectionImpressionThreshold) return;
          _trackSectionImpressionOnce(
            sectionId: sectionId,
            sectionName: sectionTitle,
            sectionOrder: sectionOrder,
            visibleRecipeCount: visibleRecipeCount,
            chipSectionKey: isProgramChip ? rawKey : null,
          );
        },
        child: child,
      ),
    );
  }

  /// 인기 탭 전용: 요즘 인기 메뉴 → 실시간 인기 → 셰프별 인기
  /// 비로그인: 로그인 티저는 맨 아래 (추천 탭 순서는 그대로).
  List<Widget> _buildPopularOnlySectionWidgets(Brightness brightness) {
    final widgets = <Widget>[];

    // 1) 요즘 인기 메뉴
    if (widget.inlineAfterNowTrending != null) {
      widgets.add(widget.inlineAfterNowTrending!);
    }

    // 2) 실시간 인기 (로그인 시에만)
    if (widget.showMembersOnlySections) {
      final sectionRecipes = _displayedSections[_kTrendingNowTitle] ??
          const <Map<String, dynamic>>[];
      if (sectionRecipes.isNotEmpty &&
          _isSectionRevealed(_kTrendingNowTitle)) {
        final config = _activeSections.firstWhere(
          (s) => s.title == _kTrendingNowTitle,
          orElse: () => const _TrendSectionDef(
            subtitle: 'Realtime',
            title: '실시간 인기 레시피',
          ),
        );
        widgets.add(
          _wrapSectionImpression(
            sectionTitle: config.title,
            sectionKey: _indexKeyForSection(config),
            sectionOrder: widgets.length,
            visibleRecipeCount: sectionRecipes.length,
            child: _TrendSection(
              subtitle: config.subtitle,
              title: config.title,
              recipes: sectionRecipes,
              brightness: brightness,
              sectionTopPadding: 0,
              analyticsSectionId: _indexKeyForSection(config),
              onRecipeTap: widget.onRecipeTap,
              showTimeBadge: config.timeMaxMinutes != null,
              onHorizontalScroll: (metrics, itemCount) =>
                  _onCarouselSectionScroll(
                metrics,
                itemCount,
                sectionTitle: config.title,
                sectionKey: _indexKeyForSection(config),
              ),
              preferCroppedForInstagram: widget.preferCroppedForInstagram,
              onSeeAll: () => _openSectionAll(config),
            ),
          ),
        );
      }
    }

    // 3) 셰프별 인기
    _appendChefSection(widgets, brightness);

    // 4) 비로그인 전용: 로그인 유도 카드는 맨 아래
    if (!widget.showMembersOnlySections && !_sequentialTailLoading) {
      widgets.add(const _MembersOnlyRecipeTeaser());
    }

    // 탭 직후 첫 섹션에만 여백 (회색 구분선 없이)
    if (widgets.isNotEmpty && widget.firstSectionTopPadding > 0) {
      widgets[0] = Padding(
        padding: EdgeInsets.only(top: widget.firstSectionTopPadding),
        child: widgets[0],
      );
    }
    return widgets;
  }

  /// Builds the trending sections (seasonal + each `_TrendSectionDef`) as a
  /// flat list of widgets. Used both for the standalone Scaffold/CustomScrollView
  /// route and for the inline Column embedded on the home screen.
  List<Widget> _buildSectionWidgets(Brightness brightness) {
    if (widget.popularOnly) {
      return _buildPopularOnlySectionWidgets(brightness);
    }

    final currentMonth = DateTime.now().month;
    final seasonalRecipes = _displayedSeasonal;
    final widgets = <Widget>[];
    Widget buildSeasonalSection() {
      final title = '$currentMonth월 제철';
      return _wrapSectionImpression(
        sectionTitle: title,
        sectionKey: HomeSectionKeys.seasonal,
        sectionOrder: widgets.length,
        visibleRecipeCount: seasonalRecipes.length,
        child: _SeasonalSection(
          month: currentMonth,
          seasonalRecipes: seasonalRecipes,
          brightness: brightness,
          onRecipeTap: widget.onRecipeTap,
          onHorizontalScroll: (metrics, itemCount) => _onCarouselSectionScroll(
            metrics,
            itemCount,
            seasonal: true,
          ),
          onSeeAll: _openSeasonalAll,
        ),
      );
    }

    // 온보딩 부스트(이유식 등) → 셰프별 → 인기 키워드 → 나머지 레일
    final sections = _visibleSections;
    final boostedTitles = <String>{
      for (final config in sections)
        if (_isBoostedSection(config)) config.title,
    };

    void addTrendSection(_TrendSectionDef config) {
      if (!_isSectionRevealed(config.title)) return;
      final sectionRecipes =
          _displayedSections[config.title] ?? const <Map<String, dynamic>>[];
      if (sectionRecipes.isEmpty) return;
      widgets.add(
        _wrapSectionImpression(
          sectionTitle: config.title,
          sectionKey: _indexKeyForSection(config),
          sectionOrder: widgets.length,
          visibleRecipeCount: sectionRecipes.length,
          child: _TrendSection(
            subtitle: config.subtitle,
            title: config.title,
            recipes: sectionRecipes,
            brightness: brightness,
            sectionTopPadding: widgets.isEmpty
                ? widget.firstSectionTopPadding
                : 0,
            analyticsSectionId: _indexKeyForSection(config),
            onRecipeTap: widget.onRecipeTap,
            showTimeBadge: config.timeMaxMinutes != null,
            onHorizontalScroll: (metrics, itemCount) =>
                _onCarouselSectionScroll(
              metrics,
              itemCount,
              sectionTitle: config.title,
              sectionKey: _indexKeyForSection(config),
            ),
            preferCroppedForInstagram: widget.preferCroppedForInstagram,
            alwaysScrollable: config.title == _kLeanStrongSectionTitle,
            onSeeAll: () => _openSectionAll(config),
          ),
        ),
      );
    }

    for (final config in sections) {
      if (boostedTitles.contains(config.title)) addTrendSection(config);
    }

    final boostedReady = boostedTitles.isEmpty ||
        boostedTitles.every(_isSectionRevealed);
    if (widget.inlineAfterBoosted != null &&
        (boostedReady || !_sequentialTailLoading)) {
      widgets.add(widget.inlineAfterBoosted!);
    }

    _appendChefSection(widgets, brightness);
    if (widget.inlineAfterNowTrending != null &&
        _isSectionRevealed(_kChefRevealKey)) {
      widgets.add(widget.inlineAfterNowTrending!);
    }

    // 제철 섹션은 안주 바로 다음에 끼워 넣는다.
    final seasonalAfterIndex = sections.indexOf(_worldCupSection);
    var seasonalInserted = false;
    for (var index = 0; index < sections.length; index++) {
      final config = sections[index];
      if (!boostedTitles.contains(config.title)) {
        addTrendSection(config);
      }
      if (widget.showMembersOnlySections &&
          index == seasonalAfterIndex &&
          seasonalAfterIndex >= 0 &&
          !seasonalInserted &&
          seasonalRecipes.isNotEmpty &&
          _isSectionRevealed(_kSeasonalRevealKey)) {
        widgets.add(buildSeasonalSection());
        seasonalInserted = true;
      }
    }
    if (widget.showMembersOnlySections &&
        !seasonalInserted &&
        seasonalRecipes.isNotEmpty &&
        _isSectionRevealed(_kSeasonalRevealKey)) {
      widgets.add(buildSeasonalSection());
    }
    if (!widget.showMembersOnlySections && !_sequentialTailLoading) {
      widgets.add(const _MembersOnlyRecipeTeaser());
    }
    return widgets;
  }

  void _appendChefSection(List<Widget> widgets, Brightness brightness) {
    if (!_isSectionRevealed(_kChefRevealKey)) return;
    final alreadyIn = widgets.any(
      (w) =>
          w is _ImpressedHomeSection && w.sectionId == HomeSectionKeys.chef,
    );
    if (alreadyIn) return;
    final chef = _buildChefSectionWidget(
      brightness,
      sectionOrder: widgets.length,
    );
    if (chef != null) widgets.add(chef);
  }

  /// 현재 `_allRecipes` 풀에서 셰프별로 2개 이상 확보되면 `_chefRecipesByChef`에
  /// 담아 둔다. 이미 담긴 셰프는 더 많은 레시피가 보일 때만 갱신하고, 풀에서
  /// 사라져도 지우지 않는다(=한 번 뜬 셰프는 유지).
  void _captureChefRecipesFromPool() {
    if (_chefIndexByChef.isEmpty) return;
    final byId = <String, Map<String, dynamic>>{};
    for (final r in _allRecipes) {
      final id = r['id']?.toString() ?? '';
      if (id.isNotEmpty) byId[id] = r;
    }
    for (final entry in _chefIndexByChef.entries) {
      final recipes = hideRecipesOnHome([
        for (final id in entry.value)
          if (byId[id] != null) byId[id]!,
      ], _onboardingProfile);
      if (recipes.length < 2) continue;
      final existing = _chefRecipesByChef[entry.key];
      if (existing == null || recipes.length > existing.length) {
        _chefRecipesByChef[entry.key] = recipes;
      }
    }
  }

  /// known chef allowlist(chefTag / tags[0]) 기준으로 셰프별 레시피를 묶는다.
  /// 레시피 2개 이상인 셰프만, 최대 12명까지.
  ({List<String> chefs, Map<String, List<Map<String, dynamic>>> byChef})
  _buildChefSectionData() {
    // 현재 풀에 셰프 레시피가 남아 있으면 안정 맵에 흡수(additive)한다.
    _captureChefRecipesFromPool();
    if (_chefRecipesByChef.isNotEmpty) {
      final byChef = <String, List<Map<String, dynamic>>>{
        for (final e in _chefRecipesByChef.entries)
          e.key: List<Map<String, dynamic>>.from(e.value),
      };
      final chefs =
          byChef.keys.toList()
            ..sort((a, b) => byChef[b]!.length.compareTo(byChef[a]!.length));
      return (chefs: chefs.take(12).toList(), byChef: byChef);
    }
    final byChef = <String, List<Map<String, dynamic>>>{};
    for (final r in _allRecipes) {
      if (recipeHiddenOnHome(r, _onboardingProfile)) continue;
      final chef = ChefTagRegistry.extractFromRecipe(r);
      if (chef == null) continue;
      (byChef[chef] ??= <Map<String, dynamic>>[]).add(r);
    }
    final chefs =
        byChef.keys.where((c) => (byChef[c]?.length ?? 0) >= 2).toList()
          ..sort((a, b) => byChef[b]!.length.compareTo(byChef[a]!.length));
    return (chefs: chefs.take(12).toList(), byChef: byChef);
  }

  Widget? _buildChefSectionWidget(
    Brightness brightness, {
    required int sectionOrder,
  }) {
    final data = _buildChefSectionData();
    if (data.chefs.isEmpty) return null;
    final recipeCount = data.byChef.values.fold<int>(
      0,
      (total, list) => total + list.length,
    );
    return _wrapSectionImpression(
      sectionTitle: '셰프',
      sectionKey: HomeSectionKeys.chef,
      sectionOrder: sectionOrder,
      visibleRecipeCount: recipeCount,
      child: _ChefSection(
        chefs: data.chefs,
        byChef: data.byChef,
        brightness: brightness,
        onRecipeTap: widget.onRecipeTap,
        onHorizontalScroll: (metrics, itemCount, chef) =>
            _onCarouselSectionScroll(
          metrics,
          itemCount,
          sectionTitle: '셰프',
          sectionKey: HomeSectionKeys.chef,
          chefName: chef,
        ),
        onSeeAll: _openChefAll,
      ),
    );
  }

  /// Skeleton shown inline on the home screen while the very first page of
  /// recipes is still being fetched. Mirrors a single `_TrendSection` slot so
  /// the home layout doesn't jump once content arrives.
  Widget _buildInlineShimmer(Brightness brightness) {
    return _buildInlineSectionShimmer(
      brightness,
      title: '셰프별 인기 레시피',
      topPadding: widget.firstSectionTopPadding,
    );
  }

  /// 다음 섹션이 로드되는 동안 아래에 붙는 얇은 캐러셀 스켈레톤.
  Widget _buildInlineSectionShimmer(
    Brightness brightness, {
    required String title,
    required double topPadding,
  }) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: _homeSectionTitleStyle(textPrimary),
                ),
              ],
            ),
          ),
          const SizedBox(height: _homeSectionRuleGap),
          SizedBox(
            height: TrendingAllPage._cardImageHeight +
                TrendingAllPage._cardCaptionHeight,
            child: _ShimmerScope(
              linearGradient: _shimmerRecipeGradient,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _trendCarouselShimmerItemCount,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: TrendingAllPage._cardGap),
                itemBuilder: (context, index) {
                  return _ShimmerLoading(
                    isLoading: true,
                    child: const _TrendCarouselShimmerCard(),
                  );
                },
              ),
            ),
          ),
          _homeSectionRule(),
        ],
      ),
    );
  }

  String? _nextSequentialShimmerTitle() {
    if (!_sequentialUnlockedTitles.contains(_kChefRevealKey)) {
      return '셰프별 인기 레시피';
    }
    for (final config in _visibleSections) {
      if (_sequentialUnlockedTitles.contains(config.title)) continue;
      return config.title;
    }
    if (widget.showMembersOnlySections &&
        !_sequentialUnlockedTitles.contains(_kSeasonalRevealKey)) {
      return '${DateTime.now().month}월 제철 재료 레시피';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);
    final sections = _buildSectionWidgets(brightness);

    if (widget.inline) {
      // Inline: SliverList so home CustomScrollView lazy-builds off-screen sections.
      if (sections.isEmpty) {
        return SliverToBoxAdapter(child: _buildInlineShimmer(brightness));
      }
      final children = <Widget>[...sections];
      if (_sequentialTailLoading &&
          widget.sequentialInlineBootstrap &&
          widget.showSequentialTailLoading) {
        final nextTitle = _nextSequentialShimmerTitle();
        if (nextTitle != null) {
          children.add(
            _buildInlineSectionShimmer(
              brightness,
              title: nextTitle,
              topPadding: 0,
            ),
          );
        }
      }
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => RepaintBoundary(child: children[index]),
          childCount: children.length,
          addAutomaticKeepAlives: false,
        ),
      );
    }

    const bottomSliverSpacing = 36.0;
    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: Text(
          '인기 레시피',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
        ),
        backgroundColor: AppColors.getBackground(brightness),
        foregroundColor: textPrimary,
        elevation: 0,
      ),
      body: CustomScrollView(
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => sections[index],
              childCount: sections.length,
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: bottomSliverSpacing)),
        ],
      ),
    );
  }
}

/// Guest-only preview for the member carousels that intentionally are not
/// fetched until sign-in.
class _MembersOnlyRecipeTeaser extends StatelessWidget {
  const _MembersOnlyRecipeTeaser();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFFF7F3EF),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white, width: 0.57),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.34,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 132,
                            height: 16,
                            decoration: BoxDecoration(
                              color: const Color(0xFF111111),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: Row(
                              children: const [
                                _TeaserRecipeCard(color: Color(0xFFD99B62)),
                                SizedBox(width: 10),
                                _TeaserRecipeCard(color: Color(0xFF8FB588)),
                                SizedBox(width: 10),
                                _TeaserRecipeCard(color: Color(0xFFE8B07B)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.80),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white, width: 0.57),
                boxShadow: const [
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
                    width: 34,
                    height: 34,
                    decoration: const ShapeDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(0, 1),
                        end: Alignment(1, 0),
                        colors: [Colors.white, Color(0xFFF9FAFB)],
                      ),
                      shape: CircleBorder(
                        side: BorderSide(width: 0.57, color: Colors.white),
                      ),
                      shadows: [
                        BoxShadow(
                          color: Color(0x0C000000),
                          blurRadius: 10,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.lock_rounded,
                      color: Color(0xFF111111),
                      size: 19,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '로그인하고 더 많은 레시피를 만나보세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF111111),
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '실시간 인기 · 이유식 · 제철 레시피가 기다리고 있어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 38,
                    child: FilledButton(
                      onPressed: () => Navigator.pushNamed(context, '/login'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF111111),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      child: const Text('로그인하고 모두 보기'),
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

class _TeaserRecipeCard extends StatelessWidget {
  const _TeaserRecipeCard({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }
}

class _TrendSection extends StatelessWidget {
  const _TrendSection({
    required this.subtitle,
    required this.title,
    required this.recipes,
    required this.brightness,
    this.sectionTopPadding = 0,
    required this.onRecipeTap,
    this.showTimeBadge = false,
    this.onHorizontalScroll,
    this.preferCroppedForInstagram = true,
    this.alwaysScrollable = false,
    this.onSeeAll,
    this.analyticsSectionId,
  });

  final String subtitle;
  final String title;
  final List<Map<String, dynamic>> recipes;
  final Brightness brightness;
  final double sectionTopPadding;
  final void Function(
    Map<String, dynamic> recipe, {
    String? sectionTitle,
    int? cardIndex,
    String? sectionKey,
  }) onRecipeTap;
  final bool showTimeBadge;
  final void Function(ScrollMetrics metrics, int itemCount)? onHorizontalScroll;
  final bool preferCroppedForInstagram;

  /// 고단백 저지방 등 카드 수가 적을 때 가로 스크롤이 막히지 않게 한다.
  final bool alwaysScrollable;

  /// 헤더 화살표. null 이면 화살표를 숨긴다.
  final VoidCallback? onSeeAll;

  /// CMS sectionKey. 없으면 한글 title 로 키를 유도한다.
  final String? analyticsSectionId;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    final sectionId =
        (analyticsSectionId != null && analyticsSectionId!.trim().isNotEmpty)
            ? analyticsSectionId!.trim()
            : HomeSectionKeys.keyForTitle(title);

    return Padding(
      padding: EdgeInsets.only(top: sectionTopPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _homeSectionTitleStyle(textPrimary),
                  ),
                ),
                if (onSeeAll != null) ...[
                  const SizedBox(width: 8),
                  _homeSectionSeeAllArrow(
                    onTap: onSeeAll!,
                    semanticLabel: '$title 전체 보기',
                  ),
                ],
              ],
            ),
          ),
          // 타이틀 위(구분선 gap)와 동일한 아래 여백
          const SizedBox(height: _homeSectionRuleGap),
          SizedBox(
            height: TrendingAllPage._cardImageHeight +
                TrendingAllPage._cardCaptionHeight,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is! ScrollUpdateNotification &&
                    notification is! ScrollEndNotification) {
                  return false;
                }
                final cb = onHorizontalScroll;
                if (cb != null &&
                    notification.metrics.axis == Axis.horizontal) {
                  cb(notification.metrics, recipes.length);
                }
                return false;
              },
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                addAutomaticKeepAlives: false,
                cacheExtent: 220,
                physics: alwaysScrollable
                    ? const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      )
                    : null,
                itemCount: recipes.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: TrendingAllPage._cardGap),
                itemBuilder: (context, index) {
                  return _TrendRecipeCard(
                    recipe: recipes[index],
                    brightness: brightness,
                    onTap: () => onRecipeTap(
                      recipes[index],
                      sectionTitle: title,
                      cardIndex: index,
                      sectionKey: sectionId,
                    ),
                    showTimeBadge: showTimeBadge,
                    preferCroppedForInstagram: preferCroppedForInstagram,
                    sectionId: sectionId,
                    position: index,
                  );
                },
              ),
            ),
          ),
          _homeSectionRule(),
        ],
      ),
    );
  }
}

/// '셰프별 인기 레시피' — 상단 셰프 탭을 누르면 해당 셰프 레시피 카드가 바뀐다.
class _ChefSection extends StatefulWidget {
  const _ChefSection({
    required this.chefs,
    required this.byChef,
    required this.brightness,
    required this.onRecipeTap,
    this.onHorizontalScroll,
    this.onSeeAll,
  });

  final List<String> chefs;
  final Map<String, List<Map<String, dynamic>>> byChef;
  final Brightness brightness;
  final void Function(
    Map<String, dynamic> recipe, {
    String? sectionTitle,
    int? cardIndex,
    String? sectionKey,
  }) onRecipeTap;
  final void Function(ScrollMetrics metrics, int itemCount, String chef)?
      onHorizontalScroll;

  /// 현재 선택된 셰프의 전체 레시피 화면으로 이동.
  final void Function(String chef)? onSeeAll;

  @override
  State<_ChefSection> createState() => _ChefSectionState();
}

class _ChefSectionState extends State<_ChefSection> {
  late String _selected = widget.chefs.first;

  @override
  void didUpdateWidget(covariant _ChefSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.chefs.contains(_selected) && widget.chefs.isNotEmpty) {
      _selected = widget.chefs.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(widget.brightness);
    final recipes =
        widget.byChef[_selected] ?? const <Map<String, dynamic>>[];

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    '셰프별 인기 레시피',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _homeSectionTitleStyle(textPrimary),
                  ),
                ),
                if (widget.onSeeAll != null) ...[
                  const SizedBox(width: 8),
                  _homeSectionSeeAllArrow(
                    onTap: () => widget.onSeeAll!(_selected),
                    semanticLabel: '$_selected 셰프 레시피 전체 보기',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: _homeSectionRuleGap),
          // 셰프 탭 (가로 스크롤 pill)
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              itemCount: widget.chefs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final chef = widget.chefs[i];
                final selected = chef == _selected;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _selected = chef),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF191F28)
                          : const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      chef,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.25,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: TrendingAllPage._cardImageHeight +
                TrendingAllPage._cardCaptionHeight,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is! ScrollUpdateNotification &&
                    notification is! ScrollEndNotification) {
                  return false;
                }
                final cb = widget.onHorizontalScroll;
                if (cb != null &&
                    notification.metrics.axis == Axis.horizontal) {
                  cb(notification.metrics, recipes.length, _selected);
                }
                return false;
              },
              child: ListView.separated(
                key: ValueKey<String>(_selected),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                addAutomaticKeepAlives: false,
                cacheExtent: 220,
                physics: const BouncingScrollPhysics(),
                itemCount: recipes.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: TrendingAllPage._cardGap),
                itemBuilder: (context, index) => _TrendRecipeCard(
                  recipe: recipes[index],
                  brightness: widget.brightness,
                  onTap: () => widget.onRecipeTap(
                    recipes[index],
                    sectionTitle: '셰프 · $_selected',
                    cardIndex: index,
                    sectionKey: HomeSectionKeys.chef,
                  ),
                  topLeftLabel: _selected,
                  sectionId: HomeSectionKeys.chef,
                  position: index,
                ),
              ),
            ),
          ),
          _homeSectionRule(),
        ],
      ),
    );
  }
}

class _SeasonalSection extends StatelessWidget {
  const _SeasonalSection({
    required this.month,
    required this.seasonalRecipes,
    required this.brightness,
    required this.onRecipeTap,
    this.onHorizontalScroll,
    this.onSeeAll,
  });

  final int month;
  final List<(Map<String, dynamic>, String)> seasonalRecipes;
  final Brightness brightness;
  final void Function(
    Map<String, dynamic> recipe, {
    String? sectionTitle,
    int? cardIndex,
    String? sectionKey,
  }) onRecipeTap;
  final void Function(ScrollMetrics metrics, int itemCount)? onHorizontalScroll;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(brightness);

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    '$month월 제철 재료 레시피',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _homeSectionTitleStyle(textPrimary),
                  ),
                ),
                if (onSeeAll != null) ...[
                  const SizedBox(width: 8),
                  _homeSectionSeeAllArrow(
                    onTap: onSeeAll!,
                    semanticLabel: '$month월 제철 재료 레시피 전체 보기',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: _homeSectionRuleGap),
          SizedBox(
            height: TrendingAllPage._cardImageHeight +
                TrendingAllPage._cardCaptionHeight,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is! ScrollUpdateNotification &&
                    notification is! ScrollEndNotification) {
                  return false;
                }
                final cb = onHorizontalScroll;
                if (cb != null &&
                    notification.metrics.axis == Axis.horizontal) {
                  cb(notification.metrics, seasonalRecipes.length);
                }
                return false;
              },
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                addAutomaticKeepAlives: false,
                cacheExtent: 220,
                itemCount: seasonalRecipes.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: TrendingAllPage._cardGap),
                itemBuilder: (context, index) {
                  final (recipe, label) = seasonalRecipes[index];
                  return _SeasonalRecipeCard(
                    recipe: recipe,
                    seasonalLabel: label,
                    brightness: brightness,
                    onTap: () => onRecipeTap(
                      recipe,
                      sectionTitle: '$month월 제철',
                      cardIndex: index,
                      sectionKey: HomeSectionKeys.seasonal,
                    ),
                    sectionId: HomeSectionKeys.seasonal,
                    position: index,
                  );
                },
              ),
            ),
          ),
          _homeSectionRule(),
        ],
      ),
    );
  }
}

class _TrendRecipeCard extends StatelessWidget {
  const _TrendRecipeCard({
    required this.recipe,
    required this.brightness,
    required this.onTap,
    this.showTimeBadge = false,
    this.preferCroppedForInstagram = true,
    this.topLeftLabel,
    this.sectionId,
    this.position,
  });

  final Map<String, dynamic> recipe;
  final Brightness brightness;
  final VoidCallback onTap;
  final bool showTimeBadge;
  final bool preferCroppedForInstagram;
  /// 썸네일 좌상단에 표시할 배지(예: 셰프 이름). null이면 표시 안 함.
  final String? topLeftLabel;
  /// 행동 시그널 계측용 — null이면 impression 계측을 생략.
  final String? sectionId;
  final int? position;

  @override
  Widget build(BuildContext context) {
    final Widget card = _buildCard(context);
    final String? sid = sectionId;
    if (sid == null) return card;
    final String recipeId = recipe['id']?.toString() ?? '';
    final String cardKey = recipeId.isNotEmpty ? recipeId : '${position ?? 0}';
    return VisibilityDetector(
      key: Key('home_trend_card_${sid}_${cardKey}_${position ?? 0}'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        _logHomeCardImpressionOnce(
          sectionId: sid,
          cardKey: cardKey,
          recipeId: recipeId.isEmpty ? null : recipeId,
          position: position ?? 0,
          recipe: recipe,
        );
      },
      child: card,
    );
  }

  Widget _buildCard(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(
      recipe,
      preferCroppedForInstagram: preferCroppedForInstagram,
    );
    final platform = source['platform'] as String? ?? '';
    final sourceUrl =
        (recipe['sourceUrl'] as String?)?.trim() ??
        (source['url'] as String?)?.trim() ??
        '';
    final imageFit = _trendCardImageFit(platform, sourceUrl);
    final imageBg = _trendCardImageBg(platform, sourceUrl);
    String creator = '@';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    } else {
      creator = '@요리';
    }

    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    int minutes = 0;
    if (showTimeBadge) {
      final steps = recipeData['steps'] as List? ?? [];
      for (final step in steps) {
        if (step is Map && step['est_minutes'] != null) {
          minutes += (step['est_minutes'] as num).toInt();
        }
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: TrendingAllPage._cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: TrendingAllPage._cardWidth,
              height: TrendingAllPage._cardImageHeight,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(
                  TrendingAllPage._cardRadius,
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: thumbnailUrl.isNotEmpty ||
                            sourceUrl.toLowerCase().contains('tiktok')
                        ? ColoredBox(
                            color: imageBg,
                            child: ThumbnailLetterboxMitigation(
                              platform: platform,
                              imageUrl: thumbnailUrl,
                              sourceUrl: sourceUrl,
                              child: AppNetworkImage(
                                imageUrl: thumbnailUrl,
                                mediaSourceUrl: sourceUrl,
                                fit: imageFit,
                                width: TrendingAllPage._cardWidth,
                                height: TrendingAllPage._cardImageHeight,
                                memCacheWidth:
                                    AppNetworkImage.carouselThumbMemCacheWidth,
                                memCacheHeight:
                                    AppNetworkImage.carouselThumbMemCacheHeight,
                                brightness: brightness,
                                placeholder:
                                    TrendingAllPage._shimmerThumbPlaceholder(),
                                errorWidget: TrendingAllPage._thumbFallback(),
                              ),
                            ),
                          )
                        : TrendingAllPage._thumbFallback(),
                  ),
                  if (topLeftLabel != null && topLeftLabel!.trim().isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                            colors: [
                              Color(0xFFFFC2D4),
                              Color(0xFFFFD6A5),
                              Color(0xFFFDFFB6),
                              Color(0xFFCAFFBF),
                              Color(0xFF9BF6FF),
                              Color(0xFFA0C4FF),
                              Color(0xFFBDB2FF),
                              Color(0xFFFFC2D4),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            width: 0.5,
                            color: const Color(0x80FFFFFF),
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4DA082FF),
                              blurRadius: 6,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Text(
                          topLeftLabel!,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            height: 15 / 10,
                            letterSpacing: -0.25,
                            color: Color(0xFF111111),
                          ),
                        ),
                      ),
                  ),
                  if (showTimeBadge && minutes > 0)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xE6FFFFFF),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x14000000),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              size: 10,
                              color: Color(0xFF6A7282),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$minutes분',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF4A5565),
                                height: 15 / 10,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title.length > 12 ? '${title.substring(0, 12)}…' : title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: textPrimary,
                letterSpacing: -0.33,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _trendPlatformIcon(platform, 14, brightness),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    creator,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            RecipeCardSocialRow(recipe: recipe, color: textTertiary),
          ],
        ),
      ),
    );
  }
}

class _SeasonalRecipeCard extends StatelessWidget {
  const _SeasonalRecipeCard({
    required this.recipe,
    required this.seasonalLabel,
    required this.brightness,
    required this.onTap,
    this.sectionId,
    this.position,
  });

  final Map<String, dynamic> recipe;
  final String seasonalLabel;
  final Brightness brightness;
  final VoidCallback onTap;
  /// 행동 시그널 계측용 — null이면 impression 계측을 생략.
  final String? sectionId;
  final int? position;

  @override
  Widget build(BuildContext context) {
    final Widget card = _buildCard(context);
    final String? sid = sectionId;
    if (sid == null) return card;
    final String recipeId = recipe['id']?.toString() ?? '';
    final String cardKey = recipeId.isNotEmpty ? recipeId : '${position ?? 0}';
    return VisibilityDetector(
      key: Key('home_seasonal_card_${sid}_${cardKey}_${position ?? 0}'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        _logHomeCardImpressionOnce(
          sectionId: sid,
          cardKey: cardKey,
          recipeId: recipeId.isEmpty ? null : recipeId,
          position: position ?? 0,
          recipe: recipe,
        );
      },
      child: card,
    );
  }

  Widget _buildCard(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    final platform = source['platform'] as String? ?? '';
    final sourceUrl =
        (recipe['sourceUrl'] as String?)?.trim() ??
        (source['url'] as String?)?.trim() ??
        '';
    final imageFit = _trendCardImageFit(platform, sourceUrl);
    final imageBg = _trendCardImageBg(platform, sourceUrl);
    String creator = '@';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    } else {
      creator = '@요리';
    }

    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: TrendingAllPage._cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: TrendingAllPage._cardWidth,
              height: TrendingAllPage._cardImageHeight,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(
                  TrendingAllPage._cardRadius,
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: thumbnailUrl.isNotEmpty ||
                            sourceUrl.toLowerCase().contains('tiktok')
                        ? ColoredBox(
                            color: imageBg,
                            child: ThumbnailLetterboxMitigation(
                              platform: platform,
                              imageUrl: thumbnailUrl,
                              sourceUrl: sourceUrl,
                              child: AppNetworkImage(
                                imageUrl: thumbnailUrl,
                                mediaSourceUrl: sourceUrl,
                                fit: imageFit,
                                width: TrendingAllPage._cardWidth,
                                height: TrendingAllPage._cardImageHeight,
                                memCacheWidth:
                                    AppNetworkImage.carouselThumbMemCacheWidth,
                                memCacheHeight:
                                    AppNetworkImage.carouselThumbMemCacheHeight,
                                brightness: brightness,
                                placeholder:
                                    TrendingAllPage._shimmerThumbPlaceholder(),
                                errorWidget: TrendingAllPage._thumbFallback(),
                              ),
                            ),
                          )
                        : TrendingAllPage._thumbFallback(),
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
                        color: const Color(0xCC009966),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        seasonalLabel,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 15 / 10,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title.length > 12 ? '${title.substring(0, 12)}…' : title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: textPrimary,
                letterSpacing: -0.33,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _trendPlatformIcon(platform, 14, brightness),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    creator,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            RecipeCardSocialRow(recipe: recipe, color: textTertiary),
          ],
        ),
      ),
    );
  }
}

Widget _trendPlatformIcon(String platform, double size, Brightness brightness) {
  String? assetPath;
  final p = platform.toLowerCase();
  if (p == 'youtube') {
    assetPath = 'lib/assets/youtube-app-icon-hd.png';
  } else if (p == 'instagram' || p == 'instagramweb') {
    assetPath = 'lib/assets/instagram-app-icon-hd.png';
  } else if (p == 'tiktok' || p == 'tiktokweb') {
    assetPath = 'lib/assets/tiktok-app-icon-hd.png';
  } else if (p == 'naver_blog') {
    return SizedBox(
      width: size,
      height: size,
      child: Icon(
        Icons.menu_book_rounded,
        size: size * 0.85,
        color: const Color(0xFF03C75A), // Naver brand green
      ),
    );
  }
  if (assetPath != null) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(
          Icons.video_library,
          size: size * 0.7,
          color: AppColors.getTextTertiary(brightness),
        ),
      ),
    );
  }
  return SizedBox(
    width: size,
    height: size,
    child: Icon(
      Icons.video_library,
      size: size * 0.7,
      color: AppColors.getTextTertiary(brightness),
    ),
  );
}

/// 설정 화면과 같이 탭 셸 위에 푸시되는 iOS 레시피북 페이지.
class _IosRecipeBookPage extends StatefulWidget {
  const _IosRecipeBookPage({required this.home});

  final _HomeScreenState home;

  @override
  State<_IosRecipeBookPage> createState() => _IosRecipeBookPageState();
}

class _IosRecipeBookPageState extends State<_IosRecipeBookPage>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    // 홈은 푸시된 라우트 아래에서 TickerMode가 꺼진다. CTA 스프링을
    // 이 페이지 vsync로 옮겨야 리스트 스크롤 때 바가 +로 접힌다.
    widget.home._recipebookBottomCtaController.resync(this);
  }

  @override
  void dispose() {
    final home = widget.home;
    if (home.mounted) {
      home._recipebookBottomCtaController.resync(home);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.home;
    return ListenableBuilder(
      listenable: Listenable.merge([
        home._recipebookUiRevision,
        home._searchController,
      ]),
      builder: (context, _) => home._buildIosRecipebookScaffold(context),
    );
  }
}
