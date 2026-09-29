import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'cart_screen.dart' show openMarketplaceLink, ShoppingMarketplace;
import '../theme/app_colors.dart';
import '../models/board_post.dart';
import '../models/recipe_models.dart' as models;
import '../services/recipe_service.dart';
import '../services/review_service.dart';
import '../services/user_service.dart';
import '../services/ingredient_price_service.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../services/rewards_service.dart';
import '../services/meal_plan_service.dart';
import '../services/local_storage_service.dart';
import '../services/coupang_service.dart';
import '../main.dart' show mainNavigatorKey, appNavigatorKey;
import 'recipe_review_feed_scroll_screen.dart';
import '../widgets/recipebook_category_picker_dialog.dart';
import '../widgets/local_storage_warning.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/cooking_instruction_sheet.dart';
import '../widgets/app_network_image.dart';
import '../widgets/youtube_player_widget.dart';
import '../widgets/instagram_player_widget.dart';
import '../widgets/tiktok_player_widget.dart';
import '../widgets/naver_blog_player_widget.dart';
import '../widgets/recipe_takedown_sheet.dart';
import '../widgets/ingredient_select_sheet.dart';
import '../widgets/meal_kit_picker_sheet.dart';
import '../widgets/recipe_native_offer_card.dart';
import '../widgets/comment_modal.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/recipe_edit_sheet.dart';
import '../widgets/recipe_agent_chat_sheet.dart';
import '../services/recipe_agent_service.dart';
import '../widgets/method_step_timer_block.dart';
import '../widgets/related_recipe_rails_section.dart';
import '../widgets/recipe_pairing_section.dart';
import '../widgets/best_ingredient_products_rail.dart';
import '../widgets/home_section_chrome.dart';
import '../utils/related_recipe_rails.dart';
import '../utils/best_ingredient_products.dart';
import '../utils/recipe_pairing.dart';
import '../utils/recipe_overlay.dart';
import '../services/admin_service.dart';
import '../services/board_service.dart';
import '../screens/board_post_detail_screen.dart';
import '../widgets/admin_home_section_curation_sheet.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';
import '../utils/youtube_utils.dart';
import '../utils/inline_media_webview.dart';
import '../utils/instagram_utils.dart';
import '../utils/tiktok_utils.dart';
import '../utils/naver_blog_utils.dart';
import '../utils/source_creator_utils.dart';
import '../utils/ingredient_category_unifier.dart';
import '../utils/chef_tag_utils.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/recipe_social_counts.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../constants/review_experience_options.dart';
import '../utils/review_experience_aggregates.dart';


class RecipeDetailScreen extends StatefulWidget {
  final models.ParseResponse parseResponse;
  final String? recipeId; // Optional recipe ID for delete functionality

  const RecipeDetailScreen({
    super.key,
    required this.parseResponse,
    this.recipeId,
  });

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen>
    with TickerProviderStateMixin {
  double _portionCount = 2;
  double get _portionStep =>
      models.portionStepForBase(_recipe.servings ?? 2.0);
  bool _minusButtonPressed = false;
  bool _plusButtonPressed = false;
  final Set<String> _selectedIngredients = {};
  final RecipeService _recipeService = RecipeService();
  final ReviewService _reviewService = ReviewService();
  final BoardService _boardService = BoardService();
  final UserService _userService = UserService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final MealPlanService _mealPlanService = MealPlanService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final IngredientPriceService _ingredientPriceService =
      IngredientPriceService();
  Map<String, List<String>> _categories = {};
  // 행동 시그널 계측용 레시피 스냅샷 필드 — initState에서 1회 계산.
  List<String>? _signalRecipeTags;
  String? _signalRecipeSourcePlatform;
  int? _signalRecipeServings;
  String? _signalRecipeNutritionRating;
  final Set<String> _impressedIngredientKeys = <String>{};
  int _selectedTabIndex = 0; // 0: 재료, 1: 요리법, 2: 영양정보
  final PageController _tabPageController = PageController();
  final List<double> _tabContentHeights = [800, 800, 800];
  double _currentTabHeight = 800;
  final Set<int> _builtTabs = {0}; // Only build tabs when first visited
  bool _heavyContentReady = false; // Defer video player + heavy widgets
  bool _isAdmin = false;
  bool _isSaved = false;
  bool _showBookmarkOnboarding = false;
  late final AnimationController _ladleBounceController;
  late final Animation<double> _ladleBounceAnimation;
  List<Map<String, dynamic>>? _recipeReviews;
  bool _recipeReviewsLoading = false;
  bool _recipeReviewsLoadedOnce = false;
  bool _recipeReviewsFetchFailed = false;
  List<RelatedRecipeRail> _relatedRails = const [];
  bool _similarRecipesLoading = false;
  bool _similarRecipesLoaded = false;
  List<LoadedPairingLane> _pairingLanes = const [];
  bool _pairingLoading = false;
  bool _pairingLoaded = false;
  final Map<String, Map<String, dynamic>> _reviewUserDataCache = {};
  final Set<String> _popupLikeInFlight = {};
  static const String _starEmptyPath = 'assets/icons/review_star_empty.png';
  static const String _starFilledPath = 'assets/icons/review_star_filled.png';
  bool _isCheckingSaved = true;
  String? _actualRecipeId; // The actual recipe ID in Firebase
  int? _recipeSaveCount;
  int? _videoViewCount;
  List<Map<String, dynamic>> _recipebookCategories = const [];
  // 한 레시피는 여러 카테고리에 동시에 들어갈 수 있다. 표시는 첫 번째
  // 카테고리 + "외 N개" 형태로 축약한다 (뱃지 가로폭 제약).
  List<String> _selectedRecipebookCategoryIds = const [];
  final Set<String> _viewTrackedRecipeIds = {};
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _timestampSub;
  models.Recipe? _liveRecipe;
  final ScrollController _scrollController = ScrollController();
  /// Measures the tab strip in global space for a full-screen-stack hit overlay
  /// (CompositedTransformFollower cannot hit targets outside its small laid-out box).
  final GlobalKey _recipeTabBarHitAnchorKey = GlobalKey();
  final GlobalKey _recipeDetailBodyStackKey = GlobalKey();
  Rect? _recipeTabHitLocalRect;
  bool _recipeTabHitSyncScheduled = false;

  /// Bottom of the gap under the divider — aligns with the top edge of [CustomScrollView].
  final GlobalKey _fixedHeaderBottomKey = GlobalKey();
  final GlobalKey _creatorBarKey = GlobalKey();
  final GlobalKey _recipeTitleKey = GlobalKey();
  final GlobalKey _pinnedMediaKey = GlobalKey();
  bool _showCreatorInHeader = false;
  bool _showRecipeNameInHeader = false;
  bool _isVideoPinned = false;

  /// Tight line: element bottom must pass this (viewport top + slack) to show in header.
  static const double _headerViewportHandoffPx = 2.0;
  /// Header bookmark glyph size (onboarding cutout uses half this for center offset).
  static const double _headerBookmarkVisualSize = 34.0;
  final GlobalKey _headerShareButtonKey = GlobalKey();
  /// Invisible hit slop for tab taps only — does not affect layout or spacing.
  static const double _recipeDetailTabHitExtendUpPx = 0.0;
  static const double _recipeDetailTabHitExtendDownPx = 0.0;
  static const double _recipeDetailTabBarHeight = 52.0;
  static const double _recipeDetailFooterHitReservePx = 80.0;
  /// Tab labels/underline painted this many px higher (overlap review margin; layout height unchanged).
  static const double _recipeDetailTabBarDrawOffsetUpPx = 8.0;
  /// Target visual gap (px) from tab underline to first tab body content.
  static const double _recipeDetailTabContentVisualGapPx = 12.0;
  // Fallback when geometry is not ready (e.g. first frame): title is below video + info.
  static const double _recipeScrollThreshold = 520;
  bool _headerVisibilityPostFrameScheduled = false;

  // 재료 가격 관련
  final Map<String, int?> _ingredientPrices = {}; // 재료별 가격 캐시
  final Map<String, bool> _ingredientPriceLoading = {}; // 로딩 상태
  // Estimated-quantity warning icon + overlay: removed for now (restore via git / search "AI 추정 용량").

  /// 이번 화면 세션에서 백엔드에 이미 보고한 재료명 (중복 요청 방지)
  final Set<String> _reportedMissingNamesSession = {};

  // 구매 추천 관련 (per-recipe cache)
  final CoupangService _coupangService = CoupangService();
  final LocalStorageService _localStorageService = LocalStorageService();
  final Map<String, ProductRecommendation> _recipeRecommendations = {};
  bool _recipeRecommendationsLoading = false;
  Completer<void>? _recipeRecommendationsLoadCompleter;
  bool _recipeRecoDiskCacheLoaded = false;
  Completer<void>? _recipeRecoDiskHydrateCompleter;
  String _previewRailMarketplace = kDefaultPreviewMarketplace;
  final Set<String> _previewMarketplaceLoadsFinished = <String>{};
  final Map<String, Completer<void>> _previewMarketplaceLoadCompleters = {};
  final Set<String> _recipeRecoEmptyKeys = <String>{};
  Timer? _recoUiFlushTimer;
  bool _nativeOffersLoadStarted = false;
  CoupangProduct? _ingredientNativeOffer;
  CoupangProduct? _methodNativeOffer;
  String? _ingredientNativeOfferName;
  String? _methodNativeOfferName;

  // YouTube 영상 재생 상태.
  //
  // 화면 진입 즉시 인라인 플레이어를 띄우기 위해 initState에서 source.url
  // 로부터 videoId를 추출해 채운다. X(닫기) 누르면 null이 되어 썸네일 모드로
  // 돌아가고, 다시 누르면 _openVideoLink()에서 재설정한다. 별도 플래그가
  // 없는 이유는 _youtubeVideoId 단일 nullable 상태로 충분하기 때문.
  String? _youtubeVideoId;
  bool _isPlayerFullscreen = false;
  YouTubePlayerHandle? _youtubeHandle;
  /// Cook-Mode 동안 상세 인라인 플레이어를 트리에서 제거한다.
  /// pause JS만으로는 Shorts nocookie 임베드가 계속 재생되는 경우가 있다.
  bool _holdInlineMediaForCook = false;
  double _heldInlineMediaSeconds = 0;

  /// Unified seek + play for YouTube and Instagram inline players.
  bool get _canSeekAndPlayStep =>
      _youtubeHandle != null || _instagramHandle != null;

  void _seekAndPlayStep(double seconds) {
    if (_youtubeHandle != null) {
      _youtubeHandle!.seekTo(seconds);
      _youtubeHandle!.play();
    } else if (_instagramHandle != null) {
      _instagramHandle!.seekToAndPlay(seconds);
    }
  }

  // Instagram / TikTok 인라인 임베드 재생 상태.
  // YouTube와 동일하게 화면 진입 즉시 임베드를 띄우기 위해 initState에서
  // source.url로부터 추출해 채운다. null이면 썸네일 표시.
  ({String type, String shortcode})? _instagramTarget;
  InstagramPlayerHandle? _instagramHandle;
  bool _didTrackRecipeVideoPlay = false;
  String? _tiktokVideoUrl;
  String? _naverBlogUrl;

  // Top section: open layout (creator + media + meta on page background)
  static const double _videoHeight = 196.0; // 28px smaller than 224
  /// Content inset for open (non-card) recipe detail top.
  static const double _recipeCardOuterPadding = 16.0;
  /// Media uses the pre-open-layout inset so the player stays as large as before.
  static const double _mediaOuterPadding = 8.0;
  static const double _recipeCardInnerPaddingH = 4.0;
  static const double _mediaCornerRadius = 12.0;

  /// Template aspect (Figma 348.67 × 196.13) — video scales to card width.
  static const double _videoAspectW = 348.67;
  static const double _videoAspectH = 196.13;
  static const double _creatorBarHeight = 56.0;
  static const double _roundedBoxHeight =
      _creatorBarHeight +
      _videoHeight +
      8.0 +
      12.0; // creator + thumbnail + gap + disclaimer (bottom 12px less)
  static const double _topSectionHeight = _roundedBoxHeight;

  // Figma design: back button (circle) + white container
  static const double _figmaCreatorBarHeight = 40.0;

  /// 사용자 로컬 오버레이(메모/편집/추가/삭제). [_overlayKey] 기준.
  Map<String, dynamic> _userOverlay = const <String, dynamic>{};

  /// 오버레이 SharedPreferences 키. uid::recipeId 우선, 없으면 uid::sourceUrl.
  String? get _overlaySourceUrl {
    final url = (widget.parseResponse.source['url'] as String?)?.trim();
    if (url != null && url.isNotEmpty) return url;
    return null;
  }

  String get _overlayKey {
    return LocalStorageService.overlayPrimaryKey(
      uid: _auth.currentUser?.uid,
      recipeId: _actualRecipeId ?? widget.recipeId,
      sourceUrl: _overlaySourceUrl,
    );
  }

  /// 머지 결과 (Recipe 본체 + 메모/수정 메타). 가격/장바구니/요리시작 모두 자동 반영.
  MergedRecipe get _merged {
    final base = _liveRecipe ?? widget.parseResponse.recipe;
    if (_userOverlay.isEmpty) {
      return applyOverlay(base, const <String, dynamic>{});
    }
    return applyOverlay(base, _userOverlay);
  }

  /// 머지된 Recipe — 가격/장바구니/카테고리 등 기존 다운스트림 로직 호환.
  models.Recipe get _recipe => _merged.recipe;

  /// 사용자 오버레이 다시 읽기 (편집/저장 후 호출).
  Future<void> _reloadUserOverlay() async {
    final overlay = await _localStorageService.getRecipeOverlayWithFallback(
      uid: _auth.currentUser?.uid,
      recipeId: _actualRecipeId ?? widget.recipeId,
      sourceUrl: _overlaySourceUrl,
    );
    if (!mounted) return;
    setState(() => _userOverlay = overlay);
  }

  void _onTabPageScroll() {
    final page = _tabPageController.page ?? 0;
    final lower = page.floor().clamp(0, 2);
    final upper = page.ceil().clamp(0, 2);
    // Mark adjacent tabs as buildable when user starts swiping
    if (!_builtTabs.contains(lower)) { _builtTabs.add(lower); }
    if (!_builtTabs.contains(upper)) { _builtTabs.add(upper); }
    final t = page - lower;
    final interpolated = _tabContentHeights[lower] * (1 - t) +
        _tabContentHeights[upper] * t;
    if ((interpolated - _currentTabHeight).abs() > 1) {
      setState(() => _currentTabHeight = interpolated);
      // When height shrinks, the outer scroll may overshoot its new max extent.
      // Clamp it so the view doesn't jump to the top.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final pos = _scrollController.position;
        if (pos.pixels > pos.maxScrollExtent) {
          _scrollController.jumpTo(pos.maxScrollExtent);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();

    _tabPageController.addListener(_onTabPageScroll);

    _ladleBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _ladleBounceAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -6.0).chain(CurveTween(curve: Curves.easeOut)), weight: 50),
      TweenSequenceItem(tween: Tween(begin: -6.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)), weight: 50),
    ]).animate(_ladleBounceController);
    _startLadleBounceLoop();

    final recipe = _recipe;
    final baseServings = recipe.servings ?? 2.0;
    final preferredServings =
        UserService.peekOnboardingProfile()?.householdServings;
    _portionCount = (preferredServings ?? baseServings).toDouble();
    if (preferredServings == null) {
      unawaited(_applyHouseholdServings());
    }

    // YouTube 영상이면 화면 진입 즉시 인라인 플레이어를 표시하기 위해
    // videoId를 미리 추출해 둔다 (썸네일 → 탭 → 플레이어 단계 제거).
    final initialSource = widget.parseResponse.source;
    final initialSourceUrl = initialSource['url'] as String? ?? '';
    final initialPlatform =
        (initialSource['platform'] as String? ?? '').toLowerCase();
    if (initialPlatform == 'youtube' || isYouTubeUrl(initialSourceUrl)) {
      final videoId = extractYouTubeVideoId(initialSourceUrl);
      if (videoId != null) {
        _youtubeVideoId = videoId;
      }
    } else if (initialPlatform == 'instagram' ||
        initialPlatform == 'instagramweb' ||
        isInstagramUrl(initialSourceUrl)) {
      final igTarget = extractInstagramShortcode(initialSourceUrl);
      if (igTarget != null) {
        _instagramTarget = igTarget;
      }
    } else if (initialPlatform == 'tiktok' ||
        initialPlatform == 'tiktokweb' ||
        isTikTokUrl(initialSourceUrl)) {
      // TikTok은 oEmbed가 canonical URL을 따라가므로 URL 그대로 사용.
      if (initialSourceUrl.isNotEmpty) {
        _tiktokVideoUrl = initialSourceUrl;
      }
    } else if (initialPlatform == 'naver_blog' ||
        isNaverBlogUrl(initialSourceUrl)) {
      // 네이버 블로그: 영상 자리에 인라인 WebView로 원본 글 렌더.
      if (initialSourceUrl.isNotEmpty) {
        _naverBlogUrl = initialSourceUrl;
      }
    }

    // 장바구니 담기: 6개 그룹 중 "장·양념·소스"만 기본 제외
    for (int i = 0; i < recipe.ingredients.length; i++) {
      final ing = recipe.ingredients[i];
      final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: ing.category,
        ingredientName: ing.item,
      );
      if (groupKey != IngredientCategoryUnifier.seasoningsSauces) {
        _selectedIngredients.add(i.toString());
      }
    }

    // Initialize categories from source (default) with new field names + fallback
    final source = widget.parseResponse.source;
    final categoriesRaw = source['categories'] as Map<String, dynamic>? ?? {};
    List<String> safeStringList(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      if (v is String) return [v];
      return [];
    }
    _categories = {
      'country':
          safeStringList(categoriesRaw['country'] ?? categoriesRaw['cuisine_type']),
      'menu_type':
          safeStringList(categoriesRaw['menu_type']),
      'main_ingredient':
          safeStringList(categoriesRaw['main_ingredient'] ?? categoriesRaw['ingredient_type']),
      'main_ingredient_sub':
          safeStringList(categoriesRaw['main_ingredient_sub'] ?? categoriesRaw['meat_type']),
      'cook_time':
          safeStringList(categoriesRaw['cook_time'] ?? categoriesRaw['time_category']),
    };
    // 행동 시그널 계측(재료 impression/click, cook_start)에 실어 보낼 레시피 스냅샷 —
    // 화면 진입 시 1회 계산해 여러 계측 지점에서 재사용(중복 파싱 방지).
    _signalRecipeTags = safeStringList(source['tags']);
    _signalRecipeSourcePlatform = (source['platform'] as String?)?.trim();
    _signalRecipeServings = recipe.servings?.round();
    _signalRecipeNutritionRating = source['nutrition_rating']?.toString();
    _videoViewCount = _videoViewCountFrom(source);

    // All async loads deferred to after first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Enable heavy content (video player, etc.) after first frame painted
      setState(() => _heavyContentReady = true);
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        final src = widget.parseResponse.source;
        final url = _iosInstagramPosterUrl(src) ??
            (src['thumbnail'] as String?)?.trim();
        if (url != null && url.isNotEmpty) {
          unawaited(
            precacheImage(
              CachedNetworkImageProvider(
                url,
                headers: _iosRecipeThumbHeaders(url),
                cacheKey: url,
              ),
              context,
            ),
          );
        }
      }
      _onScroll();
      _syncRecipeTabHitRect();
      // Stagger loads to avoid competing for resources and excessive rebuilds
      _trackRecipeViewIfNeeded(widget.recipeId);
      _checkIfSavedThenLoadReviews();
      _loadUserCategories();
      _reloadUserOverlay();
      _loadAllIngredientPricesThenReportMissing();
      _loadAdminStatus();
      unawaited(_hydrateRecipeRecommendationsFromDiskAndNotify());
    });

    _scrollController.addListener(_onScroll);
    _scrollController.addListener(_scheduleRecipeTabHitRectSync);
  }

  void _loadAdminStatus() {
    AdminService.instance.isAdmin().then((isAdmin) {
      if (!mounted || isAdmin == _isAdmin) return;
      setState(() => _isAdmin = isAdmin);
    });
  }

  void _scheduleRecipeTabHitRectSync() {
    if (!mounted || _recipeTabHitSyncScheduled) return;
    _recipeTabHitSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recipeTabHitSyncScheduled = false;
      if (!mounted) return;
      _syncRecipeTabHitRect();
    });
  }

  void _syncRecipeTabHitRect() {
    final anchorCtx = _recipeTabBarHitAnchorKey.currentContext;
    final stackCtx = _recipeDetailBodyStackKey.currentContext;
    if (anchorCtx == null || stackCtx == null) return;
    final anchor = anchorCtx.findRenderObject();
    final stack = stackCtx.findRenderObject();
    if (anchor is! RenderBox || stack is! RenderBox) return;
    if (!anchor.hasSize || !stack.hasSize) return;

    final g = anchor.localToGlobal(Offset.zero);
    final gr = Rect.fromLTWH(
      g.dx,
      g.dy - _recipeDetailTabHitExtendUpPx,
      anchor.size.width,
      anchor.size.height +
          _recipeDetailTabHitExtendUpPx +
          _recipeDetailTabHitExtendDownPx,
    );

    final local = Rect.fromPoints(
      stack.globalToLocal(gr.topLeft),
      stack.globalToLocal(gr.bottomRight),
    );

    final maxHeight = _recipeDetailTabBarHeight +
        _recipeDetailTabHitExtendUpPx +
        _recipeDetailTabHitExtendDownPx;
    var clipped = local.height > maxHeight + 1
        ? Rect.fromLTWH(local.left, local.top, local.width, maxHeight)
        : local;

    final footerReserve =
        MediaQuery.paddingOf(context).bottom + _recipeDetailFooterHitReservePx;
    final maxBottom = stack.size.height - footerReserve;
    if (clipped.bottom > maxBottom) {
      clipped = Rect.fromLTRB(
        clipped.left,
        clipped.top,
        clipped.right,
        maxBottom,
      );
    }
    final prev = _recipeTabHitLocalRect;
    if (clipped.height < 8) {
      if (prev != null) {
        setState(() => _recipeTabHitLocalRect = null);
      }
      return;
    }

    const tol = 1.0;
    if (prev == null ||
        (prev.left - clipped.left).abs() > tol ||
        (prev.top - clipped.top).abs() > tol ||
        (prev.width - clipped.width).abs() > tol ||
        (prev.height - clipped.height).abs() > tol) {
      setState(() => _recipeTabHitLocalRect = clipped);
    }
  }

  /// Sync after layout so localToGlobal matches the current scroll transform (avoids late/lingering header).
  void _onScroll() {
    if (!mounted || _headerVisibilityPostFrameScheduled) return;
    // Skip expensive layout queries when scroll position is well past all transition zones
    final offset = _scrollController.offset;
    if (_showCreatorInHeader && _showRecipeNameInHeader && offset > _recipeScrollThreshold + 100) return;
    if (!_showCreatorInHeader && !_showRecipeNameInHeader && offset < 5) return;
    _headerVisibilityPostFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerVisibilityPostFrameScheduled = false;
      if (!mounted) return;
      final currentOffset = _scrollController.offset;
      final showCreator = _isVideoPinned
          ? true
          : (_isElementBottomPastViewportTop(_creatorBarKey) ??
              (currentOffset >=
                  _figmaCreatorBarHeight - _headerViewportHandoffPx));
      final showRecipe =
          _isElementBottomPastViewportTop(_recipeTitleKey) ??
          (currentOffset > _recipeScrollThreshold);
      if (showCreator != _showCreatorInHeader ||
          showRecipe != _showRecipeNameInHeader) {
        setState(() {
          _showCreatorInHeader = showCreator;
          _showRecipeNameInHeader = showRecipe;
        });
      }
    });
  }

  /// True when the element's bottom edge has crossed the scroll viewport top (strict, no blend band).
  bool? _isElementBottomPastViewportTop(GlobalKey elementKey) {
    final boundaryContext = _fixedHeaderBottomKey.currentContext;
    final elementContext = elementKey.currentContext;
    if (boundaryContext == null || elementContext == null) return null;
    final boundaryBox = boundaryContext.findRenderObject();
    final elementBox = elementContext.findRenderObject();
    if (boundaryBox is! RenderBox || elementBox is! RenderBox) return null;
    if (!boundaryBox.hasSize || !elementBox.hasSize) return null;

    final viewportTopY = boundaryBox
        .localToGlobal(Offset(0, boundaryBox.size.height))
        .dy;
    final elementBottomY = elementBox
        .localToGlobal(Offset(0, elementBox.size.height))
        .dy;
    return elementBottomY <= viewportTopY + _headerViewportHandoffPx;
  }

  @override
  void dispose() {
    _analyticsService.setCurrentRecipeContext(null);
    _timestampSub?.cancel();
    _tabPageController.removeListener(_onTabPageScroll);
    _tabPageController.dispose();
    _ladleBounceController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.removeListener(_scheduleRecipeTabHitRectSync);
    _scrollController.dispose();
    _recoUiFlushTimer?.cancel();
    super.dispose();
  }

  /// Listen for Firestore doc changes so background-written timestamps
  /// appear even while the user is already viewing this recipe.
  void _listenForTimestampUpdates(String recipeId) {
    if (_timestampSub != null) return;
    if (recipeId.startsWith('local_')) return;

    final platform =
        (widget.parseResponse.source['platform'] as String? ?? '').toLowerCase();
    if (platform != 'youtube' && platform != 'instagram') return;

    final alreadyHasTimestamps = _recipe.steps.any((s) => s.startSec != null);
    if (alreadyHasTimestamps) return;

    _timestampSub = FirebaseFirestore.instance
        .collection('recipes')
        .doc(recipeId)
        .snapshots()
        .listen((snap) {
      if (!mounted || !snap.exists) return;
      final data = snap.data()!;
      final stepsRaw = (data['recipe'] as Map<String, dynamic>?)?['steps'];
      if (stepsRaw is! List || stepsRaw.isEmpty) return;

      final hasTs = stepsRaw.any(
        (s) => s is Map && s['start_sec'] != null,
      );
      if (!hasTs) return;

      final recipeMap = Map<String, dynamic>.from(
        (data['recipe'] as Map<String, dynamic>?) ?? {},
      );
      // 사용자 제목 별칭 유지: 원본 recipe.name 으로 되돌리지 않도록 현재 표시
      // 제목(별칭 반영본)을 그대로 덮어쓴다.
      final displayedName = _recipe.name;
      if (displayedName != null && displayedName.isNotEmpty) {
        recipeMap['name'] = displayedName;
      }
      final updatedRecipe = models.Recipe.fromJson(recipeMap);
      _timestampSub?.cancel();
      _timestampSub = null;
      if (mounted) setState(() => _liveRecipe = updatedRecipe);
    });
  }

  Future<void> _applyHouseholdServings() async {
    final uid = _auth.currentUser?.uid;
    final before = _portionCount;
    final profile = await _userService.loadOnboardingProfile();
    final servings = profile?.householdServings;
    if (servings == null || !mounted) return;
    if (_auth.currentUser?.uid != uid) return;
    if (_portionCount != before) return;
    if (_portionCount == servings.toDouble()) return;
    setState(() => _portionCount = servings.toDouble());
  }

  void _startLadleBounceLoop() async {
    while (mounted) {
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted || !_showBookmarkOnboarding) break;
      await _ladleBounceController.forward(from: 0);
    }
  }

  static String _onboardingPrefsKey(String uid) => 'bookmark_onboarding_seen_$uid';

  Future<void> _maybeShowOnboarding() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    // Check local prefs first (fast path).
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_onboardingPrefsKey(uid)) == true) return;

    // Also check Firestore so the flag survives app reinstalls / updates.
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.data()?['bookmarkOnboardingSeen'] == true) {
        await prefs.setBool(_onboardingPrefsKey(uid), true);
        return;
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _showBookmarkOnboarding = true;
    });
  }

  void _dismissOnboarding() async {
    if (!_showBookmarkOnboarding) return;
    setState(() {
      _showBookmarkOnboarding = false;
    });
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    // Persist in both local prefs and Firestore.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingPrefsKey(uid), true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {'bookmarkOnboardingSeen': true},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  Widget _buildBookmarkOnboardingOverlay() {
    final topPadding = MediaQuery.of(context).padding.top;
    // Bookmark center: aligns with header bookmark (right padding 14, half visual width).
    final screenWidth = MediaQuery.of(context).size.width;
    final bookmarkCenter = Offset(
      screenWidth - 14 - _headerBookmarkVisualSize / 2,
      topPadding + _headerBookmarkVisualSize / 2,
    );
    const cutoutRadius = 32.0;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissOnboarding,
      child: Stack(
        children: [
          // Dark overlay with circular cutout
          Positioned.fill(
            child: CustomPaint(
              painter: _CutoutOverlayPainter(
                center: bookmarkCenter,
                radius: cutoutRadius,
                overlayColor: Colors.black.withOpacity(0.62),
              ),
            ),
          ),
          // Chat bubble + ladle character
          Positioned(
            top: MediaQuery.of(context).size.height * 0.32 - 88,
            left: 36,
            right: 36,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.12),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Text(
                        '새로운 레시피를 발견하셨군요!\n북마크를 눌러서 나의 레시피북에 저장하세요!',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF333333),
                          height: 1.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    // Speech bubble tail pointing down to the character
                    Positioned(
                      left: 28,
                      bottom: -6,
                      child: CustomPaint(
                        size: const Size(10, 10),
                        painter: _BubbleTailDownPainter(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                AnimatedBuilder(
                  animation: _ladleBounceAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _ladleBounceAnimation.value),
                      child: child,
                    );
                  },
                  child: Image.asset(
                    'assets/images/onboarding_ladle.png',
                    width: 72,
                    height: 72,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkIfSavedThenLoadReviews() async {
    await _checkIfSaved();
    if (mounted) _loadRecipeReviews();
  }

  Future<void> _checkIfSaved() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _isCheckingSaved = false;
        _isSaved = false;
        _recipebookCategories = const [];
        _selectedRecipebookCategoryIds = const [];
      });
      unawaited(_loadSimilarRecipes());
      unawaited(_loadPairings());
      unawaited(_loadRecipeSaveCount());
      return;
    }

    try {
      // Get recipe ID - use provided recipeId or look it up by source URL
      String? recipeId = widget.recipeId;

      if (recipeId == null) {
        // Try to find recipe by source URL (globally, not just user's)
        final sourceUrl = widget.parseResponse.source['url'] as String?;
        if (sourceUrl != null) {
          // First try to find globally
          final recipeData = await _recipeService.getRecipeBySourceUrl(
            sourceUrl,
          );
          if (recipeData != null) {
            recipeId = recipeData['id'] as String?;
            _applySocialStatsFromRecipeDoc(recipeData);
          }

          // If not found globally, check if user has it
          recipeId ??= await _recipeService.getUserRecipeIdBySourceUrl(
            sourceUrl,
          );
        }
      }

      _actualRecipeId = recipeId;
      unawaited(_loadSimilarRecipes());
      unawaited(_loadPairings());
      unawaited(_loadRecipeSaveCount());

      if (recipeId != null) {
        _trackRecipeViewIfNeeded(recipeId);
        _listenForTimestampUpdates(recipeId);
        // Check if recipe is in user's saved recipes
        final savedRecipes = await _userService.getSavedRecipes(user.uid);
        final categoryMap = await _userService.getRecipebookRecipeCategoryMap(
          user.uid,
        );
        final categories = await _userService.getRecipebookCategories(user.uid);
        setState(() {
          _isSaved = savedRecipes.contains(recipeId);
          _recipebookCategories = categories;
          _selectedRecipebookCategoryIds = List<String>.from(
            categoryMap[recipeId] ?? const [],
          );
          _isCheckingSaved = false;
        });
        if (!_isSaved) _maybeShowOnboarding();
      } else {
        final categories = await _userService.getRecipebookCategories(user.uid);
        setState(() {
          _isSaved = false;
          _recipebookCategories = categories;
          _selectedRecipebookCategoryIds = const [];
          _isCheckingSaved = false;
        });
        _maybeShowOnboarding();
      }
    } catch (e) {
      print('[RecipeDetail] Error checking if saved: $e');
      setState(() {
        _isSaved = false;
        _selectedRecipebookCategoryIds = const [];
        _isCheckingSaved = false;
      });
      _maybeShowOnboarding();
    }
  }

  void _trackRecipeViewIfNeeded(String? recipeId) {
    final normalizedRecipeId = recipeId?.trim() ?? '';
    if (normalizedRecipeId.isEmpty || normalizedRecipeId.startsWith('local_')) {
      return;
    }
    if (_viewTrackedRecipeIds.contains(normalizedRecipeId)) {
      return;
    }
    _viewTrackedRecipeIds.add(normalizedRecipeId);
    final platform = widget.parseResponse.source['platform']?.toString();
    unawaited(
      _analyticsService.trackRecipeViewed(
        recipeId: normalizedRecipeId,
        platform: platform,
        sourceScreen: 'recipe_detail',
      ),
    );
  }

  String? get _analyticsRecipeId {
    final id = (_actualRecipeId ?? widget.recipeId)?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  void _trackRecipeVideoPlay() {
    if (_didTrackRecipeVideoPlay) return;
    final recipeId = _analyticsRecipeId;
    if (recipeId == null) return;
    _didTrackRecipeVideoPlay = true;
    final platform = (widget.parseResponse.source['platform']?.toString() ?? '')
        .trim();
    unawaited(
      _analyticsService.trackVideoPlay(
        recipeId: recipeId,
        screen: 'recipe_detail',
        platform: platform.isEmpty ? 'unknown' : platform,
      ),
    );
  }

  void _trackRecipeVideoWatchEnded(int durationMs) {
    final recipeId = _analyticsRecipeId;
    if (recipeId == null) return;
    final platform = (widget.parseResponse.source['platform']?.toString() ?? '')
        .trim();
    unawaited(
      _analyticsService.trackVideoWatchEnded(
        recipeId: recipeId,
        durationMs: durationMs,
        screen: 'recipe_detail',
        platform: platform.isEmpty ? 'unknown' : platform,
      ),
    );
  }

  static const List<String> _recipeDetailTabNames = [
    'ingredients',
    'cooking',
    'nutrition',
  ];

  /// 탭 전환 시 Mixpanel/Firebase 이벤트. 초기 재료 탭(진입 시)은 기록하지 않음.
  void _trackRecipeDetailTabSelected(int index, {String method = 'unknown'}) {
    if (index < 0 || index >= _recipeDetailTabNames.length) return;
    if (index == _selectedTabIndex) return;

    final previousIndex = _selectedTabIndex;
    final recipeId = (_actualRecipeId ?? widget.recipeId)?.trim();
    unawaited(
      _analyticsService.trackRecipeDetailTabSelected(
        tabIndex: index,
        tabName: _recipeDetailTabNames[index],
        recipeId: (recipeId != null && recipeId.isNotEmpty) ? recipeId : null,
        previousTabIndex: previousIndex,
        previousTabName: _recipeDetailTabNames[previousIndex],
        method: method,
      ),
    );
  }

  void _selectRecipeDetailTab(int index, {required String method}) {
    if (index < 0 || index >= _recipeDetailTabNames.length) return;
    if (index == _selectedTabIndex) return;

    _trackRecipeDetailTabSelected(index, method: method);
    _builtTabs.add(index);
    // animateToPage → onPageChanged 에서 재집계되지 않도록 먼저 인덱스 반영
    _selectedTabIndex = index;
    if (_tabPageController.hasClients) {
      _tabPageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() {});
  }

  void _goToNutritionTab() {
    Haptics.selection();
    if (_selectedTabIndex != 2) {
      _selectRecipeDetailTab(2, method: 'calorie_pill');
    }
    final tabCtx = _recipeTabBarHitAnchorKey.currentContext;
    if (tabCtx == null) return;
    Scrollable.ensureVisible(
      tabCtx,
      alignment: 0,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  int _millisecondsFromCreatedAt(dynamic createdAt) {
    if (createdAt == null) return 0;
    if (createdAt is DateTime) return createdAt.millisecondsSinceEpoch;
    try {
      final ms = (createdAt as dynamic).millisecondsSinceEpoch;
      return ms is int ? ms : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 가격 계산 가능 여부와 별개로, 누락 가격 보고 큐 적재 가능 여부를 판단합니다.
  /// - qty > 0
  /// - unit 비어있지 않음
  bool _ingredientEligibleForMissingReport(models.Ingredient ingredient) {
    final recipe = _recipe;
    var baseServings = recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = _portionCount / baseServings;
    final scaledQty = (ingredient.qty ?? 0.0) * scaleFactor;
    final unit = (ingredient.unit ?? '').trim();
    return scaledQty > 0 && unit.isNotEmpty;
  }

  bool _ingredientEligibleForUnitPrice(models.Ingredient ingredient) {
    final recipe = _recipe;
    var baseServings = recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = _portionCount / baseServings;
    final scaledQty = (ingredient.qty ?? 0.0) * scaleFactor;
    final unit = ingredient.unit ?? '';
    return IngredientPriceService.canRequestPrice(scaledQty, unit);
  }

  Future<void> _loadAllIngredientPricesThenReportMissing() async {
    final recipe = _recipe;
    await Future.wait(
      recipe.ingredients.map((ing) => _loadIngredientPrice(ing, batchMode: true)),
    );
    if (!mounted) return;
    setState(() {});
    unawaited(_reportMissingIngredientPricesIfNeeded());
  }

  Future<void> _reportMissingIngredientPricesIfNeeded() async {
    if (_auth.currentUser == null) return;
    final recipe = _recipe;
    final toSend = <String>[];
    for (final ingredient in recipe.ingredients) {
      final key = ingredient.item;
      if (!_ingredientEligibleForMissingReport(ingredient)) continue;
      if (_ingredientPrices[key] != null) continue;
      if (_reportedMissingNamesSession.contains(key)) continue;
      toSend.add(key);
    }
    if (toSend.isEmpty) return;
    final ok = await ApiService.reportMissingIngredientPrices(toSend);
    if (!ok || !mounted) return;
    for (final k in toSend) {
      _reportedMissingNamesSession.add(k);
    }
  }

  /// 재료 가격 로드 (g/ml/개 등 정량이 있는 재료만 요청, 나머지는 가격 미표시)
  Future<void> _loadIngredientPrice(models.Ingredient ingredient, {bool batchMode = false}) async {
    final key = ingredient.item;
    if (_ingredientPriceLoading[key] == true) return;

    final recipe = _recipe;
    var baseServings = recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = _portionCount / baseServings;
    final baseQty = ingredient.qty ?? 0.0;
    final scaledQty = baseQty * scaleFactor;
    final unit = (ingredient.unit ?? '').trim();

    // 단위 허용 목록과 무관하게, 수량/단위가 있으면 조회를 시도합니다.
    if (scaledQty <= 0 || unit.isEmpty) {
      _ingredientPrices[key] = null;
      _ingredientPriceLoading[key] = false;
      if (!batchMode && mounted) setState(() {});
      return;
    }

    _ingredientPriceLoading[key] = true;
    if (!batchMode && mounted) setState(() {});

    try {
      final price = await _ingredientPriceService
          .getIngredientPrice(ingredient.item, scaledQty, unit)
          .timeout(const Duration(seconds: 5));

      if (mounted) {
        _ingredientPrices[key] = price;
        _ingredientPriceLoading[key] = false;
        if (!batchMode) setState(() {});
      }
    } catch (e) {
      if (mounted) {
        _ingredientPrices[key] = null;
        _ingredientPriceLoading[key] = false;
        if (!batchMode) setState(() {});
      }
    }
  }

  /// 인분이 변경될 때 모든 재료 가격을 다시 로드
  Future<void> _reloadAllIngredientPrices() async {
    final recipe = _recipe;
    for (var ingredient in recipe.ingredients) {
      final key = ingredient.item;
      _ingredientPriceLoading[key] = false;
    }
    await Future.wait(
      recipe.ingredients.map((ing) => _loadIngredientPrice(ing, batchMode: true)),
    );
    if (!mounted) return;
    setState(() {});
    await _reportMissingIngredientPricesIfNeeded();
  }

  /// 가격 포맷팅 (천 단위 콤마)
  String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  /// 1인분당 가격 계산
  int _calculatePricePerServing() {
    final recipe = _recipe;

    // 모든 재료 가격 합산 (null인 경우 0원으로 처리)
    // 개별 가격은 이미 현재 인분(_portionCount)에 맞춰 계산되었음
    int totalPrice = 0;
    for (var ingredient in recipe.ingredients) {
      final price = _ingredientPrices[ingredient.item];
      totalPrice += price ?? 0;
    }

    // 현재 인분 기준으로 계산된 총 가격을 인분 수로 나눠서 1인분당 가격 계산
    if (_portionCount <= 0) return 0;
    return (totalPrice / _portionCount).round();
  }

  // ─── 구매 추천 ──
  // preview: 후기 위 레일. 온보딩과 무관하게 쿠팡을 기본으로 보여주고,
  //          보이는 마켓만 slim preview(cart_hit/see_more 없음)로 친다.
  // full: 「재료 구매하기」 시 쿠팡+컬리 전체. slim 미리보기는 see_more를 위해 다시 친다.

  String _recoCacheKey(String marketplace, String ingredient) =>
      recipeRecoCacheKey(marketplace, ingredient);

  double _scaledNeededQty(models.Ingredient ingredient) {
    final baseQty = ingredient.qty ?? 0.0;
    var baseServings = _recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    return baseQty * (_portionCount / baseServings);
  }

  bool _shouldSkipStreamItem(
    String marketplace,
    String ingredientName,
    double neededQty,
    RecipeRecoLoadMode mode,
  ) {
    final isPreview = mode != RecipeRecoLoadMode.full;
    return shouldSkipRecommendationFetch(
      cached: _recipeRecommendations[_recoCacheKey(marketplace, ingredientName)],
      isPreview: isPreview,
      attemptedEmpty: _recipeRecoEmptyKeys.contains(
        _recoCacheKey(marketplace, ingredientName),
      ),
      neededQty: neededQty,
    );
  }

  List<BestIngredientProductCard> _bestIngredientProductCards(
    String marketplace, {
    List<models.Ingredient>? previewIngredients,
  }) {
    return mapBestMatchCards(
      previewIngredients:
          previewIngredients ?? selectPreviewIngredients(_recipe.ingredients),
      recommendations: _recipeRecommendations,
      marketplace: marketplace,
    );
  }

  void _requestRecoUiFlush({bool immediate = false}) {
    if (!mounted) return;
    if (immediate) {
      _recoUiFlushTimer?.cancel();
      _recoUiFlushTimer = null;
      setState(() {});
      return;
    }
    if (_recoUiFlushTimer?.isActive ?? false) return;
    _recoUiFlushTimer = Timer(const Duration(milliseconds: 80), () {
      _recoUiFlushTimer = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _hydrateRecipeRecommendationsFromDisk(String recipeId) async {
    if (recipeId.isEmpty) return;
    if (_recipeRecoDiskCacheLoaded) {
      await (_recipeRecoDiskHydrateCompleter?.future ?? Future.value());
      return;
    }
    _recipeRecoDiskCacheLoaded = true;
    _recipeRecoDiskHydrateCompleter = Completer<void>();
    try {
      final cached =
          await _localStorageService.loadRecipeRecommendationCache(recipeId);
      if (cached == null || cached.isEmpty) return;
      for (final entry in cached.entries) {
        try {
          final reco = ProductRecommendation.fromJson(entry.value);
          if (!shouldPersistRecommendation(reco)) continue;
          _recipeRecommendations[entry.key] = reco;
        } catch (_) {}
      }
    } finally {
      final pending = _recipeRecoDiskHydrateCompleter;
      _recipeRecoDiskHydrateCompleter = null;
      if (pending != null && !pending.isCompleted) pending.complete();
    }
  }

  Future<void> _hydrateRecipeRecommendationsFromDiskAndNotify() async {
    final recipeId = _actualRecipeId ?? widget.recipeId ?? '';
    await _hydrateRecipeRecommendationsFromDisk(recipeId);
    if (mounted && _recipeRecommendations.isNotEmpty) {
      setState(() {});
    }
  }

  Future<void> _startPreviewRecommendations() async {
    final previewTargets = selectPreviewIngredients(_recipe.ingredients);
    if (previewTargets.isEmpty) {
      _previewMarketplaceLoadsFinished.addAll(kPreviewRailMarketplaces);
      return;
    }
    await _ensurePreviewMarketplaceLoaded(_previewRailMarketplace);
  }

  Future<void> _ensurePreviewMarketplaceLoaded(String marketplace) async {
    if (!isPreviewRailMarketplace(marketplace)) return;
    if (_previewMarketplaceLoadsFinished.contains(marketplace)) return;

    final inFlight = _previewMarketplaceLoadCompleters[marketplace];
    if (inFlight != null) {
      await inFlight.future;
      return;
    }

    final gate = Completer<void>();
    _previewMarketplaceLoadCompleters[marketplace] = gate;
    var retries = 0;
    try {
      while (mounted) {
        try {
          final ok = await _ensureRecipeRecommendationsLoaded(
            mode: RecipeRecoLoadMode.preview,
            marketplace: marketplace,
            onUpdated: () => _requestRecoUiFlush(),
          );
          if (ok || retries >= 1) break;
        } catch (_) {
          if (retries >= 1) break;
        }
        retries += 1;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      _previewMarketplaceLoadCompleters.remove(marketplace);
      if (mounted) {
        _previewMarketplaceLoadsFinished.add(marketplace);
        _requestRecoUiFlush(immediate: true);
      }
      if (!gate.isCompleted) gate.complete();
    }
  }

  List<Map<String, dynamic>> _recommendationBatchItems(
    RecipeRecoLoadMode mode, {
    String? marketplace,
  }) {
    final isPreview = mode != RecipeRecoLoadMode.full;
    final marketplaces = isPreview
        ? <String>[marketplace ?? kDefaultPreviewMarketplace]
        : const ['coupang', 'kurly'];
    return buildRecommendationStreamItems(
      ingredients: isPreview
          ? selectPreviewIngredients(_recipe.ingredients)
          : _recipe.ingredients,
      marketplaces: marketplaces,
      scaledQtyOf: _scaledNeededQty,
      alreadyLoaded: (itemMarketplace, name, neededQty) => _shouldSkipStreamItem(
        itemMarketplace,
        name,
        neededQty,
        mode,
      ),
      recordCartHit: !isPreview,
      includeSeeMore: !isPreview,
    );
  }

  /// preview는 레일이 보일 때, full은 첫 「구매」에서 이어서 채운다.
  Future<bool> _ensureRecipeRecommendationsLoaded({
    RecipeRecoLoadMode mode = RecipeRecoLoadMode.full,
    String? marketplace,
    void Function()? onUpdated,
  }) async {
    final recipeId = _actualRecipeId ?? widget.recipeId ?? '';
    await _hydrateRecipeRecommendationsFromDisk(recipeId);

    while (_recipeRecommendationsLoading) {
      await (_recipeRecommendationsLoadCompleter?.future ?? Future.value());
    }

    final batchItems = _recommendationBatchItems(
      mode,
      marketplace: marketplace,
    );
    if (batchItems.isEmpty) {
      onUpdated?.call();
      return true;
    }
    if (!mounted) {
      onUpdated?.call();
      return true;
    }

    _recipeRecommendationsLoading = true;
    _recipeRecommendationsLoadCompleter = Completer<void>();
    onUpdated?.call();
    final recoSw = Stopwatch()..start();
    print(
      '[PERF][recipe_reco] start mode=${mode.name} n=${batchItems.length}',
    );
    var flushedFirstCard = false;
    try {
      final receivedIndices = <int>{};
      var withBest = 0;
      await for (final entry in _coupangService
          .getProductRecommendationsStream(items: batchItems)
          .timeout(const Duration(seconds: 45))) {
        final idx = entry.key;
        final r = entry.value;
        if (idx < 0 || idx >= batchItems.length) continue;
        receivedIndices.add(idx);
        final mp = batchItems[idx]['marketplace'] as String;
        final name = batchItems[idx]['ingredient_name'] as String;
        final key = _recoCacheKey(mp, name);
        if (r == null) {
          _recipeRecoEmptyKeys.add(key);
          continue;
        }
        if (!mounted) continue;
        final merged = mergeIncomingRecommendation(
          existing: _recipeRecommendations[key],
          incoming: r,
        );
        if (merged == null) {
          _recipeRecoEmptyKeys.add(key);
          continue;
        }
        _recipeRecommendations[key] = merged;
        _recipeRecoEmptyKeys.remove(key);
        if (recommendationHasUsableBestMatch(merged)) withBest++;
        if (!flushedFirstCard && recommendationHasUsableBestMatch(merged)) {
          flushedFirstCard = true;
          _requestRecoUiFlush(immediate: true);
        } else {
          onUpdated?.call();
        }
      }

      print(
        '[PERF][recipe_reco] done mode=${mode.name} '
        'ms=${recoSw.elapsedMilliseconds} '
        'n=${batchItems.length} received=${receivedIndices.length} '
        'best_match=$withBest/${receivedIndices.length}',
      );

      if (shouldRetryPreviewStream(
        requestedCount: batchItems.length,
        receivedCount: receivedIndices.length,
      )) {
        return false;
      }

      for (final key in unreceivedRecommendationKeys(
        batchItems: batchItems,
        receivedIndices: receivedIndices,
      )) {
        _recipeRecoEmptyKeys.add(key);
      }

      if (receivedIndices.isNotEmpty && recipeId.isNotEmpty) {
        final toCache = <String, Map<String, dynamic>>{};
        for (final entry in _recipeRecommendations.entries) {
          if (!shouldPersistRecommendation(entry.value)) continue;
          toCache[entry.key] = entry.value.toJson();
        }
        if (toCache.isNotEmpty) {
          unawaited(_localStorageService.saveRecipeRecommendationCache(
            recipeId: recipeId,
            entries: toCache,
          ));
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _recipeRecommendationsLoading = false;
      if (!(_recipeRecommendationsLoadCompleter?.isCompleted ?? true)) {
        _recipeRecommendationsLoadCompleter!.complete();
      }
      _recipeRecommendationsLoadCompleter = null;
      onUpdated?.call();
    }
  }

  static const Map<int, Map<int, String>> _fractionGlyphs = {
    2: {1: '½'},
    3: {1: '⅓', 2: '⅔'},
    4: {1: '¼', 3: '¾'},
  };

  static const _metricUnits = {'g', 'kg', 'ml', 'l', 'cc'};

  String _toFractionString(double value, {String unit = ''}) {
    final whole = value.truncate();
    final frac = value - whole;

    if (frac.abs() < 1e-9) return whole.toString();

    // Metric units (g, ml, kg, l, cc) should use decimals, not fractions.
    if (_metricUnits.contains(unit.toLowerCase().trim())) {
      final twoDecimals = value.toStringAsFixed(2);
      if (twoDecimals.endsWith('0')) return value.toStringAsFixed(1);
      return twoDecimals;
    }

    for (final denom in [2, 3, 4]) {
      final numer = (frac * denom).round();
      if ((frac - numer / denom).abs() < 0.01 && numer > 0 && numer < denom) {
        final gcd = numer.gcd(denom);
        final rn = numer ~/ gcd;
        final rd = denom ~/ gcd;
        final glyph = _fractionGlyphs[rd]?[rn];
        if (glyph != null) {
          return whole > 0 ? '$whole$glyph' : glyph;
        }
      }
    }

    final twoDecimals = value.toStringAsFixed(2);
    if (twoDecimals.endsWith('0')) return value.toStringAsFixed(1);
    return twoDecimals;
  }

  String _getScaledAmountForPortion(double baseAmount, double portionCount, {String unit = ''}) {
    final recipe = _recipe;
    var baseServings = recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = portionCount / baseServings;
    final scaledAmount = baseAmount * scaleFactor;

    return _toFractionString(scaledAmount, unit: unit);
  }

  String _ingredientQtyText(models.Ingredient ingredient, {double? portionCount}) {
    final cookUnit = (ingredient.unit ?? '').trim();
    final baseQty = ingredient.qty ?? ingredient.qtyConventional;
    final unit = cookUnit.isNotEmpty ? cookUnit : (ingredient.unitConventional ?? '');
    if (baseQty == null || unit.isEmpty) return '';
    final recipe = _recipe;
    var baseServings = recipe.servings ?? 2;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = (portionCount ?? _portionCount) / baseServings;
    final scaledAmount = baseQty * scaleFactor;

    // Auto-scale g→kg, ml→L for readability
    if ((unit == 'g' || unit == '그램') && scaledAmount >= 1000) {
      final kg = scaledAmount / 1000;
      return '${_toFractionString(kg, unit: 'kg')}kg';
    }
    if ((unit == 'ml' || unit == '밀리리터') && scaledAmount >= 1000) {
      final l = scaledAmount / 1000;
      return '${_toFractionString(l, unit: 'ml')}L';
    }

    final scaled = _toFractionString(scaledAmount, unit: unit);
    if (scaled.isEmpty) return '';
    return '$scaled$unit';
  }


  Future<void> _handleRemoveFromSaved() async {
    Haptics.light();
    final user = _auth.currentUser;
    if (user == null || _actualRecipeId == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Show confirmation dialog
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '레시피북에서 제거할까요?',
      description: '저장된 레시피 목록에서 제거되며, 언제든지 다시 저장할 수 있어요.',
      confirmLabel: '제거',
    );

    if (confirmed == true && mounted) {
      try {
        setState(() {
          _isSaved = false;
          _bumpRecipeSaveCount(-1);
        });
        await _userService.removeSavedRecipe(
          user.uid,
          _actualRecipeId!,
          sourcePlatform: _signalRecipeSourcePlatform,
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _isSaved = true;
            _bumpRecipeSaveCount(1);
          });
          showAppSnackBar(context, 
            SnackBar(
              content: Text('레시피 제거 중 오류가 발생했습니다: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _handleAddToSaved() async {
    Haptics.light();
    final user = _auth.currentUser;
    if (user == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('저장하려면 로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 네이버 블로그: 본문은 본인 디바이스에만 저장된다(저작권 회피).
    // 다른 사용자가 분석한 메타에 attach 만 하면 본문 없는 빈 카드가 되므로,
    // 본인 로컬에 본문이 없는 경우 → 홈 + 분석 팝업으로 redirect 해서 본인이
    // 직접 분석하도록 유도한다.
    final source = widget.parseResponse.source;
    final platform = (source['platform'] as String?)?.toLowerCase() ?? '';
    final sourceUrl = source['url'] as String?;
    final isNaverRecipe = platform == 'naver_blog' ||
        (sourceUrl != null && isNaverBlogUrl(sourceUrl));
    if (isNaverRecipe) {
      bool hasLocalBody = false;
      if (_actualRecipeId != null) {
        try {
          final body = await LocalStorageService().getNaverBody(_actualRecipeId!);
          hasLocalBody = body != null;
        } catch (_) {
          hasLocalBody = false;
        }
      }
      if (!hasLocalBody) {
        if (sourceUrl == null || sourceUrl.isEmpty) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('레시피 URL을 찾을 수 없습니다'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        // 사용자 명세: 분석 시작 팝업은 홈에서 떠야 한다. 디테일 (및 그 위에
        // 푸시된 라우트들) 를 모두 pop 하고 홈 탭으로 이동한 뒤 root shell 의
        // sheet 를 띄운다.
        final root = mainNavigatorKey.currentState;
        if (root == null) return;
        appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        root.navigateToHome();
        root.showAddRecipeSheet(initialUrl: sourceUrl);
        return;
      }
    }

    try {
      // If recipe doesn't exist in Firebase, save it first
      if (_actualRecipeId == null) {
        if (sourceUrl == null) {
          throw Exception('레시피 URL을 찾을 수 없습니다');
        }

        // Save recipe to Firebase first
        _actualRecipeId = await _recipeService.saveRecipe(
          parseResponse: widget.parseResponse,
          sourceUrl: sourceUrl,
        );
        if (_actualRecipeId != null) _listenForTimestampUpdates(_actualRecipeId!);

        // Small delay to ensure recipe is fully created in Firestore
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Add to saved recipes
      setState(() {
        _isSaved = true;
        _bumpRecipeSaveCount(1);
      });
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('북마크에 추가되었습니다'),
            backgroundColor: Colors.blue,
          ),
        );
      }
      await _userService.addSavedRecipe(
        user.uid,
        _actualRecipeId!,
        sourcePlatform: _signalRecipeSourcePlatform,
      );
      final categories = await _userService.getRecipebookCategories(user.uid);
      if (mounted) {
        setState(() {
          _recipebookCategories = categories;
        });
      }
    } catch (e) {
      print('[RecipeDetail] Error adding to saved: $e');
      if (mounted) {
        setState(() {
          _isSaved = false;
          _bumpRecipeSaveCount(-1);
        });
        showAppSnackBar(context, 
          SnackBar(
            content: Text('레시피 저장 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String? _recipebookCategoryNameById(String? categoryId) {
    if (categoryId == null || categoryId.isEmpty) return null;
    for (final category in _recipebookCategories) {
      if ((category['id'] as String?) == categoryId) {
        final name = (category['name'] as String?)?.trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    return null;
  }

  /// 다중 카테고리가 지정된 레시피의 뱃지 표시용 라벨을 만든다.
  /// 0개 → null (caller 가 '미분류' 로 처리), 1개 → 이름 그대로,
  /// 2개 이상 → "{첫번째 이름} 외 N개" 형태로 축약.
  String? _recipebookCategoryBadgeLabel() {
    if (_selectedRecipebookCategoryIds.isEmpty) return null;
    final names = _selectedRecipebookCategoryIds
        .map(_recipebookCategoryNameById)
        .whereType<String>()
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isEmpty) return null;
    if (names.length == 1) return names.first;
    return '${names.first} 외 ${names.length - 1}개';
  }

  /// 제목 별칭 편집: 내 레시피북에 저장된 레시피만.
  bool get _canEditRecipeTitle {
    if (!_isSaved) return false;
    if (_auth.currentUser == null) return false;
    final rid = (_actualRecipeId ?? widget.recipeId ?? '').trim();
    return rid.isNotEmpty && !rid.startsWith('local_');
  }

  /// 재료/단계/메모 편집 UI — 내 레시피북에 있을 때만 노출.
  bool get _canEditRecipeContent => _isSaved;

  /// 사용자별 제목 별칭 편집 다이얼로그. 원본 레시피 제목은 유지되고, 본인
  /// 레시피북/상세에만 반영된다. 빈 값으로 저장하면 원본 제목으로 되돌린다.
  Future<void> _editRecipeTitleAlias() async {
    final recipeId = (_actualRecipeId ?? widget.recipeId ?? '').trim();
    if (recipeId.isEmpty || recipeId.startsWith('local_')) return;
    if (_auth.currentUser == null) {
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final currentName = (_recipe.name ?? '').trim();
    final controller = TextEditingController(text: currentName);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            '제목 수정',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontWeight: FontWeight.w800,
              fontSize: 17,
              color: Color(0xFF111111),
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: InputDecoration(
              hintText: '레시피 제목을 입력하세요',
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );

    if (result == null) return; // 취소
    final newTitle = result.trim();
    if (newTitle == currentName) return; // 변경 없음

    try {
      await _recipeService.setRecipeTitleAlias(recipeId, newTitle);
      // 상세 화면 제목 즉시 갱신(별칭이 recipe.name 에 반영된 최신 데이터로 재조회).
      final refreshed = await _recipeService.getRecipeById(recipeId);
      if (!mounted) return;
      if (refreshed != null) {
        setState(() => _liveRecipe = refreshed.recipe);
      }
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('제목이 수정되었습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(
          content: Text('제목 수정 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleRecipeCardCategoryTap() async {
    final user = _auth.currentUser;
    if (user == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (!_isSaved || _actualRecipeId == null) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('북마크에 추가한 뒤 이용할 수 있어요')),
      );
      return;
    }
    if (_recipebookCategories.isEmpty) {
      final categories = await _userService.getRecipebookCategories(user.uid);
      if (mounted) {
        setState(() {
          _recipebookCategories = categories;
        });
      }
    }
    if (!mounted) return;

    // Multi-select 흐름: picker 가 "create" 를 요청하면 새 카테고리 생성
    // 다이얼로그를 띄우고 그 결과를 작업 중 선택 집합에 추가한 뒤 picker
    // 를 다시 열어 사용자가 계속 선택을 이어갈 수 있게 한다.
    var workingSelection = List<String>.from(_selectedRecipebookCategoryIds);
    while (mounted) {
      final result = await showRecipebookCategoryMultiPickerDialog(
        context,
        categories: _recipebookCategories,
        initialSelectedIds: workingSelection,
      );
      if (!mounted || result == null) return;

      if (result.createRequested) {
        final newId = await _promptCreateRecipebookCategory(user.uid);
        if (!mounted) return;
        if (newId != null && newId.isNotEmpty) {
          workingSelection = [...workingSelection, newId];
        }
        continue;
      }

      try {
        if (_actualRecipeId == null) return;
        final ids = result.selectedIds
            .where((e) => e.trim().isNotEmpty)
            .toSet()
            .toList();
        await _userService.setRecipebookCategoriesForRecipe(
          user.uid,
          recipeId: _actualRecipeId!,
          categoryIds: ids,
        );
        unawaited(
          _analyticsService.trackRecipebookCategoryAssigned(
            recipeId: _actualRecipeId!,
            categoryCount: ids.length,
          ),
        );
        if (!mounted) return;
        setState(() {
          _selectedRecipebookCategoryIds = ids;
        });
        final names = ids
            .map(_recipebookCategoryNameById)
            .whereType<String>()
            .where((n) => n.isNotEmpty)
            .toList();
        final String message;
        if (names.isEmpty) {
          message = "'미분류'으로 설정했어요";
        } else if (names.length == 1) {
          message = "'${names.first}'으로 설정했어요";
        } else {
          message = "'${names.first}' 외 ${names.length - 1}개 카테고리로 설정했어요";
        }
        showAppSnackBar(context, 
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        if (mounted) {
          showAppSnackBar(context, 
            SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', '')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      return;
    }
  }

  /// "새 카테고리 만들기" 다이얼로그를 띄우고, 생성에 성공하면 새
  /// 카테고리의 ID 를 반환한다. 내부적으로 [_recipebookCategories] 목록을
  /// 새로 받아 setState 까지 처리하므로 caller 는 ID 만 사용하면 된다.
  Future<String?> _promptCreateRecipebookCategory(String uid) async {
    final controller = TextEditingController();
    final iconOptions = <(String key, IconData icon, String label)>[
      ('folder', Icons.folder_rounded, '기본'),
      ('rocket', Icons.rocket_launch_rounded, '도전'),
      ('heart', Icons.favorite_rounded, '즐겨찾기'),
      ('group', Icons.group_rounded, '가족'),
      ('replay', Icons.replay_rounded, '재도전'),
      ('flame', Icons.local_fire_department_rounded, '인기'),
      ('chef', Icons.restaurant_menu_rounded, '요리'),
      ('book', Icons.menu_book_rounded, '기록'),
      ('star', Icons.star_rounded, '추천'),
      ('check', Icons.task_alt_rounded, '완료'),
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
                  SizedBox(
                    height: 96,
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      itemCount: iconOptions.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 5,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                      itemBuilder: (context, index) {
                        final option = iconOptions[index];
                        final selected = selectedIconKey == option.$1;
                        return GestureDetector(
                          onTap: () {
                            setLocalState(() {
                              selectedIconKey = option.$1;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            curve: Curves.easeOutCubic,
                            decoration: BoxDecoration(
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
                              option.$2,
                              size: 20,
                              color: selected
                                  ? const Color(0xFF191F28)
                                  : const Color(0xFF7B8794),
                            ),
                          ),
                        );
                      },
                    ),
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
        );
      },
    );
    controller.dispose();
    final name = createdData?['name'] ?? '';
    final iconKey = createdData?['iconKey'] ?? 'folder';
    if (name.trim().isEmpty) return null;
    try {
      final created = await _userService.addRecipebookCategory(
        uid,
        name,
        iconKey: iconKey,
      );
      final categoryId = (created['id'] as String?)?.trim();
      if (categoryId == null || categoryId.isEmpty) return null;
      final categories = await _userService.getRecipebookCategories(uid);
      if (mounted) {
        setState(() {
          _recipebookCategories = categories;
        });
      }
      return categoryId;
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipe = _recipe;
    final nutrition = widget.parseResponse.nutrition;
    final source = widget.parseResponse.source;
    final baseServings = recipe.servings ?? 2;
    final brightness = Theme.of(context).brightness;

    final topPadding = MediaQuery.of(context).padding.top;
    // Segmented tab control needs a bit more than the old underline tabs.
    const double tabBarHeight = 52.0;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: Stack(
        key: _recipeDetailBodyStackKey,
        children: [
          DefaultTextStyle(
            style: const TextStyle(fontFamily: 'Pretendard'),
            child: SafeArea(
              top: false,
              // iPhone: 탭 바가 없는 푸시 화면이라 하단 SafeArea가
              // CTA 아래에 흰 띠만 만든다. 리스트를 바닥까지 그린다.
              bottom: !IosLiquidGlassTabBar.shouldUse(context),
              child: Column(
            children: [
              // 상단 헤더 + 영상 영역은 고정, 아래 콘텐츠만 스크롤
              Container(
                color: AppColors.getBackground(brightness),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        top: topPadding,
                        left: 14,
                        right: 14,
                      ),
                      child: SizedBox(
                        height: 40,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildFigmaBackButtonBar(),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position:
                                          Tween<Offset>(
                                            begin: const Offset(0, 0.25),
                                            end: Offset.zero,
                                          ).animate(
                                            CurvedAnimation(
                                              parent: animation,
                                              curve: Curves.easeOut,
                                            ),
                                          ),
                                      child: child,
                                    ),
                                  );
                                },
                                child: _showRecipeNameInHeader
                                    ? Align(
                                        key: const ValueKey('recipe-creator'),
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.max,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                widget
                                                        .parseResponse
                                                        .recipe
                                                        .name ??
                                                    '레시피',
                                                style: const TextStyle(
                                                  fontFamily:
                                                      'HakgyoansimJiugae',
                                                  color: Color(0xFF111111),
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w400,
                                                  height: 1.2,
                                                  letterSpacing: -0.38,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 1),
                                              _buildHeaderCreatorCollapsed(
                                                source,
                                                brightness,
                                                compact: true,
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : Align(
                                        key: const ValueKey('creator-only'),
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: _buildHeaderCreatorCollapsed(
                                            source,
                                            brightness,
                                            compact: false,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  _buildHeaderMoreButton(),
                                  const SizedBox(width: 2),
                                  _buildHeaderShareButton(),
                                  const SizedBox(width: 2),
                                  GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: _isCheckingSaved
                                        ? null
                                        : (_isSaved
                                            ? _handleRemoveFromSaved
                                            : _handleAddToSaved),
                                    child: _buildHeaderBookmarkGlyph(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 1,
                      color: brightness == Brightness.dark
                          ? const Color(0xFF3A3A3C)
                          : const Color(0xFFE5E5EA),
                    ),
                    if (_isVideoPinned) ...[
                      ColoredBox(
                        color: AppColors.getBackground(brightness),
                        child: _buildFigmaMediaBlock(
                          source,
                          brightness,
                          includeCreator: false,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    SizedBox(key: _fixedHeaderBottomKey, height: 0),
                  ],
                ),
              ),
              const CompactLocalStorageWarning(),
              Expanded(
                child: CustomScrollView(
                  controller: _scrollController,
                  cacheExtent: 100,
                  slivers: [
                    SliverToBoxAdapter(
                      child: RepaintBoundary(
                        child: _buildFigmaTopSection(
                          recipe,
                          nutrition,
                          source,
                          brightness,
                          includeMedia: !_isVideoPinned,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.zero,
                        child: Container(
                          key: _recipeTabBarHitAnchorKey,
                          height: tabBarHeight,
                          color: AppColors.getBackground(brightness),
                          padding: const EdgeInsets.fromLTRB(
                            _recipeCardOuterPadding,
                            8,
                            _recipeCardOuterPadding,
                            4,
                          ),
                          alignment: Alignment.center,
                          child: _buildTabHeaders(brightness),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: RepaintBoundary(
                        child: ClipRect(
                        clipper: const _TabContentOverflowTopClipper(16),
                        child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        height: _currentTabHeight,
                        child: PageView(
                          controller: _tabPageController,
                          clipBehavior: Clip.none,
                          physics: const _SnappierPagePhysics(),
                          onPageChanged: (index) {
                            // 탭 헤더 탭은 animateToPage → 여기로도 오므로,
                            // 이미 선택된 인덱스는 _track에서 스킵된다.
                            // 스와이프만 여기서 method=swipe로 잡히도록,
                            // 탭 탭 경로는 _selectRecipeDetailTab에서 먼저 track한다.
                            if (index != _selectedTabIndex) {
                              _trackRecipeDetailTabSelected(
                                index,
                                method: 'swipe',
                              );
                            }
                            setState(() {
                              _selectedTabIndex = index;
                              _builtTabs.add(index);
                            });
                          },
                          children: [
                            for (int i = 0; i < 3; i++)
                              _TabContentPage(
                                index: i,
                                onHeightMeasured: (height) {
                                  if (height > 0 && (_tabContentHeights[i] - height).abs() > 1) {
                                    _tabContentHeights[i] = height;
                                    final page = _tabPageController.hasClients
                                        ? (_tabPageController.page ?? 0)
                                        : _selectedTabIndex.toDouble();
                                    if (page.round() == i) {
                                      setState(() => _currentTabHeight = height);
                                    }
                                  }
                                },
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    i == 0 ? 0 : 16,
                                    i == 0 ? 4 : 10,
                                    i == 0 ? 0 : 16,
                                    0,
                                  ),
                                  child: _buildSingleTabContent(
                                    i, recipe, nutrition, baseServings, brightness,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      ),
                    ),
                    ),
                    SliverToBoxAdapter(
                      child: _buildBestIngredientProductsRail(),
                    ),
                    SliverToBoxAdapter(
                      child: _buildReviewSummaryCard(brightness),
                    ),
                    SliverToBoxAdapter(
                      child: _buildPairingSection(brightness),
                    ),
                    SliverToBoxAdapter(
                      child: _buildSimilarRecipesSection(brightness),
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: 96),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      _buildRecipeDetailTabBarHitOverlay(brightness),
      _buildPersistentActionFooter(),
      if (_showBookmarkOnboarding) _buildBookmarkOnboardingOverlay(),
        ],
      ),
    );
  }

  Widget _buildPersistentActionFooter() {
    final iosFlushBottom = IosLiquidGlassTabBar.shouldUse(context);
    final row = Padding(
      padding: EdgeInsets.only(bottom: iosFlushBottom ? 24 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            flex: 10,
            child: _RecipeFrostedActionPill(
              key: const ValueKey('purchase-pill'),
              title: '재료 구매하기',
              titleWidget: const _MarketplacePurchaseTitle(),
              accent: _RecipeFrostedAccent.green,
              onTap: () {
                Haptics.medium();
                unawaited(
                  _analyticsService.trackRecipeCartAddFooterClicked(
                    recipeId: _actualRecipeId ?? widget.recipeId,
                  ),
                );
                _showAddToCartDialog();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: _RecipeFrostedActionPill(
              key: const ValueKey('cook-mode-pill'),
              title: 'Cook-Mode',
              subtitle: '단계별 핸즈프리 요리',
              compact: true,
              accent: _RecipeFrostedAccent.orange,
              animate: false,
              onTap: _openCookingInstructionSheet,
            ),
          ),
        ],
      ),
    );
    return Positioned(
      left: 12,
      right: 12,
      bottom: 0,
      child: iosFlushBottom
          ? row
          : SafeArea(
              top: false,
              child: row,
            ),
    );
  }

  /// 재료 impression/click, cook_start 등 카드 단위 행동 시그널을 초기화 시 계산해둔
  /// 레시피 스냅샷과 함께 기록한다. 화면 곳곳의 계측 지점에서 재사용.
  Future<void> _logRecipeCardSignal(
    String eventType, {
    required String screen,
    String? sectionId,
    String? cardId,
    String? contentType,
    String? ingredientName,
    int? position,
    int? recipeServings,
  }) {
    final String? recipeId = _actualRecipeId ?? widget.recipeId;
    return AnalyticsService().logCardEvent(
      eventType,
      screen: screen,
      sectionId: sectionId,
      cardId: cardId,
      contentType: contentType,
      recipeId: recipeId,
      position: position,
      ingredientName: ingredientName,
      recipeCuisineType: _categories['country'],
      recipeTimeCategory: _categories['cook_time'],
      recipeMenuType: _categories['menu_type'],
      recipeMainIngredient: _categories['main_ingredient'],
      recipeMainIngredientSub: _categories['main_ingredient_sub'],
      recipeTags: _signalRecipeTags,
      recipeNutritionRating: _signalRecipeNutritionRating,
      recipeSourcePlatform: _signalRecipeSourcePlatform,
      recipeServings: recipeServings ?? _signalRecipeServings,
    );
  }

  void _openCookingInstructionSheet() {
    Haptics.medium();
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      unawaited(_analyticsService.trackCookingButtonClickForUser(currentUser.uid));
    }
    final merged = _merged;
    final recipe = merged.recipe;
    final recipeId = _actualRecipeId ?? widget.recipeId;
    unawaited(
      _analyticsService.trackCookingStarted(
        recipeId: recipeId,
        sourceScreen: 'recipe_detail',
      ),
    );
    unawaited(
      _logRecipeCardSignal(
        'cook_start',
        screen: 'recipe_detail',
        sectionId: 'cooking_button',
        cardId: recipeId,
        contentType: 'recipe',
      ),
    );
    if (recipeId != null && recipeId.trim().isNotEmpty) {
      unawaited(_mealPlanService.markRecipeStartedForToday(recipeId));
    }
    final stepMemos =
        merged.stepSources.map((s) => s.memo).toList(growable: false);
    unawaited(
      _pushCookingInstructionSheet(
        recipe: recipe,
        recipeId: recipeId,
        stepMemos: stepMemos,
        recipeMemo: merged.recipeMemo,
      ),
    );
  }

  /// 상세 플레이어를 멈춘 뒤 Cook-Mode로 푸시한다. 복귀 시 같은 위치부터 둔다.
  Future<void> _pushCookingInstructionSheet({
    required models.Recipe recipe,
    required String? recipeId,
    required List<String> stepMemos,
    required String? recipeMemo,
  }) async {
    try {
      final t = await _youtubeHandle?.getCurrentTime();
      if (t != null && t > 0) _heldInlineMediaSeconds = t;
    } catch (_) {}
    _youtubeHandle?.pause();
    _instagramHandle?.pause();
    if (!mounted) return;
    setState(() {
      _holdInlineMediaForCook = true;
      _youtubeHandle = null;
      _instagramHandle = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/cook-mode'),
        builder: (context) => CookingInstructionSheet(
          recipe: recipe,
          recipeId: recipeId,
          source: widget.parseResponse.source,
          stepMemos: stepMemos,
          recipeMemo: recipeMemo,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _holdInlineMediaForCook = false);
  }

  /// Platform label in Korean for disclaimer and creator row
  String _platformLabel(String? platform) {
    if (platform == null) return '유튜브';
    final p = platform.toLowerCase();
    if (p == 'youtube') return '유튜브';
    if (p == 'instagram' || p == 'instagramweb') return '인스타그램';
    if (p == 'tiktok' || p == 'tiktokweb') return '틱톡';
    return '유튜브';
  }

  /// Collapsed creator for header: logo + name (no username). [compact] when recipe name is above.
  Widget _buildHeaderCreatorCollapsed(
    Map<String, dynamic> source,
    Brightness brightness, {
    bool compact = false,
  }) {
    const figmaTextPrimary = Color(0xFF111111);
    final platform = source['platform'] as String? ?? '';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final creatorDisplayName = channel.isNotEmpty
        ? channel
        : (uploader.isNotEmpty
              ? uploader.replaceFirst(RegExp(r'^@'), '')
              : 'Chef');
    final fontSize = compact ? 10.0 : 15.0;
    final iconSize = compact ? 11.0 : 16.0;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, 0.3),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
            child: child,
          ),
        );
      },
      child: _showCreatorInHeader
          ? Row(
              key: ValueKey('creator-visible-$compact'),
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                _buildPlatformIconForCreator(
                  platform,
                  brightness,
                  size: iconSize,
                ),
                SizedBox(width: compact ? 4 : 6),
                Flexible(
                  child: Text(
                    creatorDisplayName,
                    style: TextStyle(
                      color: figmaTextPrimary,
                      fontSize: fontSize,
                      fontWeight: FontWeight.w700,
                      height: 1.50,
                      letterSpacing: compact ? -0.28 : -0.32,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          : SizedBox(key: const ValueKey('creator-hidden')),
    );
  }

  /// Figma 239-6741: Back button — circular white pill with chevron
  Widget _buildFigmaBackButtonBar() {
    const double size = 40;
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0x14000000),
              blurRadius: 16,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.chevron_left_rounded,
          size: 22,
          color: Color(0xFF111111),
        ),
      ),
    );
  }

  /// Get filtered tags from source for Figma top section (no debug prints)
  List<String> _getFigmaTags(Map<String, dynamic> source) {
    return sanitizeRecipeTagList(source['tags'] as List?);
  }

  List<String> _identityDisplayTags(Map<String, dynamic> source) {
    return recipeIdentityDisplayTags(
      tags: source['tags'] as List?,
      occasionTags: source['occasionTags'] as List?,
    );
  }

  int? _videoViewCountFrom(Map<String, dynamic> source) {
    return RecipeSocialCounts.viewCountFromSource(source) ?? _videoViewCount;
  }

  String _formatEngagementCount(int n) {
    if (n >= 100000000) {
      final v = n / 100000000;
      return '${v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}억';
    }
    if (n >= 10000) {
      final v = n / 10000;
      return '${v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}만';
    }
    final digits = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  void _applyRecipeSaveCount(dynamic raw) {
    if (raw is! num) return;
    _recipeSaveCount = raw.toInt().clamp(0, 999999999);
  }

  void _bumpRecipeSaveCount(int delta) {
    _recipeSaveCount = ((_recipeSaveCount ?? 0) + delta).clamp(0, 999999999);
  }

  void _applySocialStatsFromRecipeDoc(Map<String, dynamic>? data) {
    if (data == null) return;
    _applyRecipeSaveCount(data['saveCount']);
    final views = RecipeSocialCounts.viewCountOf(data);
    if (views != null) _videoViewCount = views;
  }

  Future<void> _loadRecipeSaveCount() async {
    var id = _actualRecipeId ?? widget.recipeId;
    if (id == null || id.startsWith('local_')) {
      final sourceUrl = widget.parseResponse.source['url'] as String?;
      if (sourceUrl == null || sourceUrl.isEmpty) return;
      try {
        final data = await _recipeService.getRecipeBySourceUrl(sourceUrl);
        if (data == null || !mounted) return;
        _actualRecipeId ??= data['id'] as String?;
        _applySocialStatsFromRecipeDoc(data);
        setState(() {});
      } catch (_) {}
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('recipes')
          .doc(id)
          .get();
      if (!mounted) return;
      _applySocialStatsFromRecipeDoc(snap.data());
      setState(() {});
    } catch (_) {}
  }

  /// One-line differentiator under the title ("aura").
  String _buildRecipeAuraLine(
    models.Recipe recipe,
    Map<String, dynamic> source,
  ) {
    return recipeTaglineForDisplay(source: source);
  }

  String _mealKitSearchName(String recipeName) =>
      '${recipeName.trim()} 밀키트';

  Future<void> _openMealKitSearch(String recipeName) async {
    final q = Uri.encodeComponent(_mealKitSearchName(recipeName));
    final uri = Uri.parse('https://www.coupang.com/np/search?q=$q');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('밀키트 검색을 열 수 없어요')),
      );
    }
  }

  void _showMealKitPicker(String recipeName) {
    unawaited(_openMealKitPicker(recipeName));
  }

  Future<void> _openMealKitPicker(String recipeName) async {
    final recipeId = _actualRecipeId ?? widget.recipeId;
    unawaited(
      _analyticsService.trackMealKitPickerOpened(recipeId: recipeId),
    );
    await precacheImage(
      const AssetImage(MealKitPickerSheet.heroAsset),
      context,
    );
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      sheetAnimationStyle: const AnimationStyle(
        curve: Curves.easeOutCubic,
        duration: Duration(milliseconds: 340),
      ),
      builder: (_) => MealKitPickerSheet(
        recipeName: recipeName,
        recipeId: _actualRecipeId ?? widget.recipeId,
        onEmptySearch: () => _openMealKitSearch(recipeName),
      ),
    );
  }

  Future<void> _loadSimilarRecipes() async {
    if (_similarRecipesLoaded || _similarRecipesLoading) return;
    _similarRecipesLoading = true;
    try {
      String seed = '';
      final source = widget.parseResponse.source;
      for (final key in [
        'canonical_dish_seed',
        'groupKey',
        'group_key',
        'canonicalDish',
        'canonical_dish',
      ]) {
        final v = (source[key] as String?)?.trim() ?? '';
        if (v.isNotEmpty) {
          seed = v;
          break;
        }
      }

      final recipeId = _actualRecipeId ?? widget.recipeId;
      if (seed.isEmpty && recipeId != null && !recipeId.startsWith('local_')) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection('recipes')
              .doc(recipeId)
              .get();
          final doc = snap.data();
          if (doc != null) {
            seed = (doc['groupKey'] as String?)?.trim() ??
                (doc['canonicalDish'] as String?)?.trim() ??
                '';
            final src = doc['source'];
            if (seed.isEmpty && src is Map) {
              seed = (src['canonical_dish_seed'] as String?)?.trim() ??
                  (src['canonicalDish'] as String?)?.trim() ??
                  '';
            }
          }
        } catch (_) {}
      }
      if (seed.isEmpty) {
        seed = (_recipe.name ?? '').trim();
      }

      final categoriesRaw = source['categories'] as Map<String, dynamic>? ?? {};
      List<String> categoryList(dynamic raw) {
        if (raw is List) {
          return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        }
        if (raw is String && raw.trim().isNotEmpty) return [raw.trim()];
        return const [];
      }

      final dishName = (_recipe.name ?? seed).trim();
      final ingredientLabel = pickRelatedMainIngredient(
        mainIngredientSub: categoryList(
          categoriesRaw['main_ingredient_sub'] ?? categoriesRaw['meat_type'],
        ),
        mainIngredient: categoryList(
          categoriesRaw['main_ingredient'] ?? categoriesRaw['ingredient_type'],
        ),
        ingredientItems: _recipe.ingredients.map((e) => e.item).toList(),
      );
      final menuType = pickRelatedMenuType(
        menuTypes: categoryList(categoriesRaw['menu_type']),
        dishName: dishName,
      );

      final similarFuture = seed.isEmpty
          ? Future.value(const <Map<String, dynamic>>[])
          : _recipeService.fetchSimilarRecipesByCanonicalDish(
              seed,
              limit: 8,
              excludeRecipeId: recipeId,
            );
      final ingredientFuture = ingredientLabel == null
          ? Future.value(const <Map<String, dynamic>>[])
          : _recipeService.fetchRecipesByIngredientIndex(
              ingredientLabel,
              limit: 8,
              excludeRecipeId: recipeId,
            );
      final menuFuture = menuType == null
          ? Future.value(const <Map<String, dynamic>>[])
          : _recipeService.fetchRecipesByCategoryValue(
              categoryField: 'menu_type',
              value: menuType,
              limit: 8,
              excludeRecipeId: recipeId,
            );
      final popularFuture = _recipeService.fetchPopularRelatedRecipes(
        limit: 8,
        excludeRecipeId: recipeId,
      );

      final results = await Future.wait([
        similarFuture,
        ingredientFuture,
        menuFuture,
        popularFuture,
      ]);
      if (!mounted) return;

      final similarLabel = () {
        for (final key in ['canonicalDish', 'canonical_dish']) {
          final v = (source[key] as String?)?.trim() ?? '';
          if (v.isNotEmpty) return v;
        }
        return dishName;
      }();

      final rails = dedupRelatedRecipeRails([
        RelatedRecipeRail(
          id: 'similar_recipes',
          title: relatedSimilarRailTitle(similarLabel),
          subtitle: '지금 보는 요리와 비슷한 레시피예요',
          recipes: results[0],
        ),
        RelatedRecipeRail(
          id: 'main_ingredient_recipes',
          title: relatedIngredientRailTitle(ingredientLabel ?? ''),
          subtitle: '같은 주재료로 색다르게 만들어 보세요',
          recipes: results[1],
        ),
        RelatedRecipeRail(
          id: 'menu_type_recipes',
          title: relatedMenuRailTitle(menuType ?? ''),
          subtitle: '비슷한 조리법·계열의 다른 요리예요',
          recipes: results[2],
        ),
        RelatedRecipeRail(
          id: 'popular_cooked_recipes',
          title: relatedPopularRailTitle,
          subtitle: '저장이 많은 레시피를 모아봤어요',
          recipes: results[3],
        ),
      ]);

      setState(() {
        _relatedRails = rails;
        _similarRecipesLoaded = true;
        _similarRecipesLoading = false;
      });
    } catch (e) {
      debugPrint('[RecipeDetail] similar recipes load failed: $e');
      if (!mounted) return;
      setState(() {
        _relatedRails = const [];
        _similarRecipesLoaded = true;
        _similarRecipesLoading = false;
      });
    }
  }

  Future<void> _loadPairings() async {
    if (_pairingLoaded || _pairingLoading) return;
    _pairingLoading = true;
    try {
      final source = widget.parseResponse.source;
      final categoriesRaw = source['categories'] as Map<String, dynamic>? ?? {};
      List<String> categoryList(dynamic raw) {
        if (raw is List) {
          return raw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
        }
        if (raw is String && raw.trim().isNotEmpty) return [raw.trim()];
        return const [];
      }

      final dishName = (_recipe.name ?? '').trim();
      final plan = resolvePairingPlan(
        dishName: dishName,
        menuTypes: categoryList(categoriesRaw['menu_type']),
        tags: categoryList(source['tags']),
        country: categoryList(
          categoriesRaw['country'] ?? categoriesRaw['cuisine_type'],
        ),
      );
      if (plan.isEmpty) {
        if (!mounted) return;
        setState(() {
          _pairingLanes = const [];
          _pairingLoaded = true;
          _pairingLoading = false;
        });
        return;
      }

      final recipeId = _actualRecipeId ?? widget.recipeId;
      final loaded = await Future.wait(
        plan.lanes.map((lane) async {
          if (lane.categoryValue == null) {
            return LoadedPairingLane(
              id: lane.id,
              label: lane.label,
              sips: lane.sips,
            );
          }
          var recipes = await _recipeService.fetchRecipesByCategoryValue(
            categoryField: 'menu_type',
            value: lane.categoryValue!,
            limit: 12,
            excludeRecipeId: recipeId,
          );
          final accept = lane.accept;
          if (accept != null) {
            recipes = recipes.where(accept).toList();
          }
          recipes = recipes.take(8).toList();
          if (recipes.isEmpty && lane.sips.isNotEmpty) {
            return LoadedPairingLane(
              id: lane.id,
              label: lane.label,
              sips: lane.sips,
            );
          }
          if (recipes.isEmpty) return null;
          return LoadedPairingLane(
            id: lane.id,
            label: lane.label,
            recipes: recipes,
          );
        }),
      );
      if (!mounted) return;
      setState(() {
        _pairingLanes = [
          for (final lane in loaded)
            if (lane != null && !lane.isEmpty) lane,
        ];
        _pairingLoaded = true;
        _pairingLoading = false;
      });
    } catch (e) {
      debugPrint('[RecipeDetail] pairings load failed: $e');
      if (!mounted) return;
      setState(() {
        _pairingLanes = const [];
        _pairingLoaded = true;
        _pairingLoading = false;
      });
    }
  }

  Widget _buildRecipeIdentityStrip({
    required Map<String, dynamic> source,
    required int totalMinutes,
    required double calories,
    required double servings,
    required List<String> tags,
    required Brightness brightness,
  }) {
    const pillFill = Color(0xFFF2F2F2);
    const ink = Color(0xFF0F0F0F);
    final views = _videoViewCountFrom(source);
    final facts = <({IconData icon, String label, VoidCallback? onTap})>[
      if (calories > 0)
        (
          icon: Icons.local_fire_department_outlined,
          label: '${calories.toInt()}kcal/인분',
          onTap: _goToNutritionTab,
        ),
      (
        icon: Icons.person_outline_rounded,
        label: models.formatServingsLabel(servings),
        onTap: null,
      ),
      (icon: Icons.schedule_outlined, label: '$totalMinutes분', onTap: null),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tags.isNotEmpty) ...[
            _buildIdentityTagScroller(source),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: 36,
            width: double.infinity,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final screenW = MediaQuery.sizeOf(context).width;
                return OverflowBox(
                  alignment: Alignment.center,
                  minWidth: screenW,
                  maxWidth: screenW,
                  child: SizedBox(
                    width: screenW,
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: _recipeCardOuterPadding,
                      ),
                      children: [
                _buildYoutubeSplitPill(
                  fill: pillFill,
                  ink: ink,
                  leftIcon: Icons.play_arrow_rounded,
                  leftLabel: views == null ? '—' : _formatEngagementCount(views),
                  rightIcon: Icons.bookmark_rounded,
                  rightLabel: _formatEngagementCount(_recipeSaveCount ?? 0),
                ),
                const SizedBox(width: 8),
                for (final fact in facts) ...[
                  _buildYoutubePill(
                    fill: pillFill,
                    ink: ink,
                    icon: fact.icon,
                    label: fact.label,
                    onTap: fact.onTap,
                  ),
                  const SizedBox(width: 8),
                ],
                _buildIdentityInfoPill(brightness, fill: pillFill),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildYoutubeSplitPill({
    required Color fill,
    required Color ink,
    required IconData leftIcon,
    required String leftLabel,
    required IconData rightIcon,
    required String rightLabel,
  }) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(leftIcon, size: 18, color: ink),
                const SizedBox(width: 6),
                Text(leftLabel, style: _youtubePillText(ink)),
              ],
            ),
          ),
          Container(width: 1, height: 18, color: const Color(0xFFD9D9D9)),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(rightIcon, size: 18, color: ink),
                const SizedBox(width: 6),
                Text(rightLabel, style: _youtubePillText(ink)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildYoutubePill({
    required Color fill,
    required Color ink,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final pill = Container(
      height: 36,
      padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: 6),
          Text(label, style: _youtubePillText(ink)),
        ],
      ),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }

  TextStyle _youtubePillText(Color ink) {
    return TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: ink,
      letterSpacing: -0.2,
      height: 1,
    );
  }

  Widget _buildIdentityInfoPill(Brightness brightness, {required Color fill}) {
    return GestureDetector(
      onTap: () => _showCategoriesInfoDialog(context, brightness),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.more_horiz_rounded,
          size: 18,
          color: Color(0xFF0F0F0F),
        ),
      ),
    );
  }

  Widget _buildSocialProofChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                    height: 1.1,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                    height: 1.1,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _mealKitPreviewSkipNames = {
    '물',
    '소금',
    '후추',
    '후춧가루',
    '식용유',
    '참기름',
    '들기름',
    '깨',
    '통깨',
    '맛술',
    '미림',
    '설탕',
  };

  List<String> _mealKitPreviewIngredientCandidates() {
    final preferred = <String>[];
    final skipped = <String>[];
    final seen = <String>{};
    for (final ing in _recipe.ingredients) {
      final name = ing.item.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      if (_mealKitPreviewSkipNames.contains(name)) {
        skipped.add(name);
      } else {
        preferred.add(name);
      }
    }
    return [...preferred, ...skipped];
  }

  void _prefetchNativeOffers() {
    // 네이티브 오퍼(재료/요리법 상품 카드) 당분간 숨김. 복구 시 아래 early return 제거.
    return;
    if (_nativeOffersLoadStarted) return;
    _nativeOffersLoadStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadNativeOffers());
    });
  }

  String _compactOfferToken(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  bool _sameIngredientLabel(String a, String b) =>
      _compactOfferToken(a) == _compactOfferToken(b);

  bool _offerNameMatches(String productName, String query) {
    final product = _compactOfferToken(productName);
    final needle = _compactOfferToken(query);
    if (product.isEmpty || needle.isEmpty) return false;
    return product.contains(needle) || needle.contains(product);
  }

  String? _firstDisplayedIngredientName() {
    final byGroup = <String, List<models.Ingredient>>{};
    for (final ingredient in _recipe.ingredients) {
      final name = ingredient.item.trim();
      if (name.isEmpty) continue;
      final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: ingredient.category,
        ingredientName: name,
      );
      byGroup.putIfAbsent(groupKey, () => <models.Ingredient>[]).add(ingredient);
    }
    for (final key in IngredientCategoryUnifier.groupOrder) {
      final list = byGroup[key];
      if (list == null || list.isEmpty) continue;
      final name = list.first.item.trim();
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  CoupangProduct? _bestProductForName(String name) {
    return _matchingProductForName(name);
  }

  CoupangProduct? _matchingProductForName(
    String name, {
    String? excludeProductId,
  }) {
    bool usable(CoupangProduct product) {
      if (product.productId.isEmpty || product.productName.isEmpty) {
        return false;
      }
      if (excludeProductId != null && product.productId == excludeProductId) {
        return false;
      }
      return _offerNameMatches(product.productName, name);
    }

    final recos = [
      _recipeRecommendations[_recoCacheKey('coupang', name)],
      _recipeRecommendations[_recoCacheKey('kurly', name)],
    ];
    for (final reco in recos) {
      if (reco == null) continue;
      final candidates = <CoupangProduct>[
        if (reco.bestMatch != null) reco.bestMatch!,
        ...reco.seeMoreList,
        ...reco.allProducts,
      ];
      for (final product in candidates) {
        if (usable(product)) return product;
      }
    }
    return null;
  }

  CoupangProduct? _altProductFromReco(String name, String? usedProductId) {
    return _matchingProductForName(name, excludeProductId: usedProductId);
  }

  CoupangProduct? _productFromSearchResult(ProductSearchResult? result) {
    if (result == null) return null;
    if (result.productId.isEmpty || result.productName.isEmpty) return null;
    return CoupangProduct(
      productId: result.productId,
      productName: result.productName,
      productPrice: result.productPrice,
      productImage: result.productImage,
      productUrl: result.productUrl,
    );
  }

  Future<CoupangProduct?> _searchMatchingProduct(String name) async {
    try {
      final result = await _coupangService.searchProductsAdvanced(
        ingredientName: name,
        limit: 20,
      );
      if (result == null) return null;
      final candidates = <ProductSearchResult>[
        if (result.bestAmountMatch != null) result.bestAmountMatch!,
        if (result.cheapestSameAmount != null) result.cheapestSameAmount!,
        if (result.cheapestOverall != null) result.cheapestOverall!,
        ...result.allProducts,
      ];
      for (final item in candidates) {
        if (_offerNameMatches(item.productName, name)) {
          return _productFromSearchResult(item);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _loadNativeOffers() async {
    final ingredientName = _firstDisplayedIngredientName();
    final equipment = _collectRecipeEquipment(_recipe);
    var toolName = equipment.isNotEmpty ? equipment.first : null;
    if (toolName == null) {
      final extras = _mealKitPreviewIngredientCandidates()
          .where((name) => !_sameIngredientLabel(name, ingredientName ?? ''))
          .toList();
      toolName = extras.isNotEmpty ? extras.first : '냄비';
    }

    Future<void> fetchIfNeeded(String? name) async {
      if (name == null || name.isEmpty) return;
      if (_matchingProductForName(name) != null) return;
      try {
        final reco = await _coupangService.getProductRecommendations(
          ingredientName: name,
          limit: 8,
        );
        if (reco != null) {
          _recipeRecommendations.putIfAbsent(
            _recoCacheKey('coupang', name),
            () => reco,
          );
        }
      } catch (_) {}
    }

    await Future.wait<void>([
      fetchIfNeeded(ingredientName),
      if (toolName != null &&
          !_sameIngredientLabel(toolName, ingredientName ?? ''))
        fetchIfNeeded(toolName),
    ]);

    var ingredientProduct = ingredientName == null
        ? null
        : _matchingProductForName(ingredientName);
    if (ingredientProduct == null && ingredientName != null) {
      ingredientProduct = await _searchMatchingProduct(ingredientName);
    }

    var methodProduct =
        toolName == null ? null : _matchingProductForName(toolName);
    if (methodProduct == null && toolName != null) {
      methodProduct = await _searchMatchingProduct(toolName);
    }
    if (ingredientProduct != null &&
        methodProduct != null &&
        ingredientProduct.productId == methodProduct.productId) {
      methodProduct = toolName == null
          ? null
          : _altProductFromReco(toolName, ingredientProduct.productId);
    }

    if (!mounted) return;
    setState(() {
      _ingredientNativeOffer = ingredientProduct;
      _methodNativeOffer = methodProduct;
      _ingredientNativeOfferName = ingredientName;
      _methodNativeOfferName = toolName;
    });
  }

  List<String> _mealKitPreviewImageUrls(Map<String, dynamic> source) {
    final urls = <String>[];
    void add(String? raw) {
      final url = raw?.trim() ?? '';
      if (url.isEmpty || urls.contains(url)) return;
      urls.add(url);
    }

    add(source['thumbnail'] as String?);
    add(source['og_image_url'] as String?);
    for (final reco in _recipeRecommendations.values) {
      add(reco.bestMatch?.productImage);
      if (urls.length >= 3) break;
    }
    return urls.take(3).toList(growable: false);
  }

  Widget _buildMealKitAvatarStack({
    required List<String> imageUrls,
    required List<String> ingredientNames,
  }) {
    const double size = 30;
    const double overlap = 20;
    final count = 3;
    final width = size + (count - 1) * overlap;

    return SizedBox(
      width: width,
      height: size,
      child: Stack(
        children: List<Widget>.generate(count, (i) {
          final url = i < imageUrls.length ? imageUrls[i] : '';
          final label = i < ingredientNames.length ? ingredientNames[i] : '';
          final initial = label.isNotEmpty
              ? String.fromCharCode(label.runes.first)
              : '요';
          return Positioned(
            left: i * overlap,
            child: Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              clipBehavior: Clip.antiAlias,
              child: url.isNotEmpty
                  ? AppNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      width: size,
                      height: size,
                      memCacheWidth: 90,
                      memCacheHeight: 90,
                    )
                  : Center(
                      child: Text(
                        initial,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF6B7280),
                          height: 1,
                        ),
                      ),
                    ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildMealKitRow(
    models.Recipe recipe,
    Map<String, dynamic> source,
  ) {
    final recipeName = recipe.name ?? '레시피';
    final imageUrls = _mealKitPreviewImageUrls(source);
    final ingredientNames = recipe.ingredients
        .map((e) => e.item.trim())
        .where((e) => e.isNotEmpty)
        .take(3)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () {
            Haptics.selection();
            _showMealKitPicker(recipeName);
          },
          borderRadius: BorderRadius.circular(14),
          splashColor: const Color(0x14000000),
          highlightColor: const Color(0x0A000000),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(
              children: [
                _buildMealKitAvatarStack(
                  imageUrls: imageUrls,
                  ingredientNames: ingredientNames,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '밀키트로 바로 만들어 먹기',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F0F0F),
                      letterSpacing: -0.25,
                      height: 1.2,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Color(0xFF909090),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPairingSection(Brightness _) {
    if (!_pairingLoaded && !_pairingLoading) {
      return const SizedBox.shrink();
    }
    if (_pairingLoaded && _pairingLanes.isEmpty) {
      return const SizedBox.shrink();
    }
    return RecipePairingSection(
      lanes: _pairingLanes,
      loading: _pairingLoading && _pairingLanes.isEmpty,
      recipeService: _recipeService,
    );
  }

  Widget _buildSimilarRecipesSection(Brightness _) {
    if (!_similarRecipesLoaded && !_similarRecipesLoading) {
      return const SizedBox.shrink();
    }
    if (_similarRecipesLoaded && _relatedRails.isEmpty) {
      return const SizedBox.shrink();
    }
    return RelatedRecipeRailsSection(
      rails: _relatedRails,
      loading: _similarRecipesLoading && _relatedRails.isEmpty,
      recipeService: _recipeService,
    );
  }

  void _toggleVideoPinned() {
    Haptics.selection();
    final pinning = !_isVideoPinned;
    setState(() {
      _isVideoPinned = pinning;
      _showCreatorInHeader = pinning;
    });
    if (!pinning && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  Widget _buildVideoPinButton() {
    final pinned = _isVideoPinned;
    return GestureDetector(
      onTap: _toggleVideoPinned,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFE8E6E3),
            width: 0.8,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x07000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          pinned ? Icons.push_pin : Icons.push_pin_outlined,
          size: 14,
          color: pinned ? const Color(0xFFEA580C) : const Color(0xFF6B6560),
        ),
      ),
    );
  }

  double _resolveVideoBoxAspect(Map<String, dynamic> source) {
    final platform = source['platform'] as String? ?? '';
    final sourceUrl = source['url'] as String? ?? '';
    final isYouTube =
        platform.toLowerCase() == 'youtube' || isYouTubeUrl(sourceUrl);
    final p = platform.toLowerCase();
    final isInstagram = p == 'instagram' || p == 'instagramweb';
    final isTikTok = p == 'tiktok' || p == 'tiktokweb';
    final isNaverBlog = p == 'naver_blog' || isNaverBlogUrl(sourceUrl);
    final widthRaw = source['width'];
    final heightRaw = source['height'];
    final widthVal = widthRaw is num ? widthRaw.toDouble() : null;
    final heightVal = heightRaw is num ? heightRaw.toDouble() : null;
    final dimsKnown = widthVal != null &&
        heightVal != null &&
        widthVal > 0 &&
        heightVal > 0;
    // 세로 숏폼은 1:1 nocookie, 가로 롱폼만 시네마. 길이만으로 가로 영상을
    // 숏폼 박스에 넣지 않는다.
    final bool isLandscapeYouTube = isLandscapeYouTubeSource(source);
    final embedWidth =
        MediaQuery.sizeOf(context).width - (_recipeCardOuterPadding * 2);
    // iOS 가로는 시네마 프레임(16:9)을 유지하고 오버레이만 안 잘리게
    // 위아래 24pt 씩만 늘린다. 300pt 박스는 세로처럼 보여 쓰지 않는다.
    final double youtubeBoxAspect = isLandscapeYouTube
        ? (Theme.of(context).platform == TargetPlatform.iOS
            ? YoutubeEmbedLayout.iosCinemaVisibleAspectRatio(embedWidth)
            : YoutubeEmbedLayout.landscapeBoxAspectRatio(embedWidth))
        : 1.0;
    final bool isLandscapeSocial = dimsKnown && widthVal > heightVal;
    final double instagramBoxAspect = isLandscapeSocial ? 16 / 9 : 1.0;
    // iOS 틱톡은 인스타/유튜브 숏폼과 같은 1:1 박스. 영상은 contain 으로
    // 축소해 잘리지 않게 한다. Android 는 기존 3:4.
    final double tiktokBoxAspect = isLandscapeSocial
        ? 16 / 9
        : (Theme.of(context).platform == TargetPlatform.iOS ? 1.0 : 3 / 4);
    return isYouTube
        ? youtubeBoxAspect
        : isInstagram
            ? instagramBoxAspect
            : isTikTok
                ? tiktokBoxAspect
                : isNaverBlog
                    ? 4 / 5
                    : _videoAspectW / _videoAspectH;
  }

  Widget _buildFigmaMediaBlock(
    Map<String, dynamic> source,
    Brightness brightness, {
    bool includeCreator = true,
  }) {
    const Color figmaTextPrimary = Color(0xFF111111);
    const Color figmaTextSecondary = Color(0xFF888888);
    final platform = source['platform'] as String? ?? '';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final creatorDisplayName = channel.isNotEmpty
        ? channel
        : (uploader.isNotEmpty
              ? uploader.replaceFirst(RegExp(r'^@'), '')
              : 'Chef');
    final creatorHandle = resolveCreatorHandle(
      platform: platform,
      uploader: uploader,
      uploaderId: source['uploader_id'] as String?,
      channel: channel,
    );
    final sourceUrl = source['url'] as String? ?? '';
    final isYouTube =
        platform.toLowerCase() == 'youtube' || isYouTubeUrl(sourceUrl);
    final videoBoxAspect = _resolveVideoBoxAspect(source);

    return KeyedSubtree(
      key: _pinnedMediaKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (includeCreator)
          Padding(
            key: _creatorBarKey,
            padding: const EdgeInsets.fromLTRB(
              _recipeCardOuterPadding,
              6,
              _recipeCardOuterPadding,
              6,
            ),
            child: IgnorePointer(
                ignoring: _showCreatorInHeader,
                child: AnimatedOpacity(
                  opacity: _showCreatorInHeader ? 0 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _openOriginalVideo(source),
                          child: SizedBox(
                            height: 24,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _buildCreatorBarPlatformPill(
                                  platform,
                                  brightness,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    creatorDisplayName,
                                    style: const TextStyle(
                                      color: figmaTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      height: 1,
                                      letterSpacing: -0.325,
                                      leadingDistribution:
                                          TextLeadingDistribution.even,
                                    ),
                                    strutStyle: const StrutStyle(
                                      fontSize: 13,
                                      height: 1,
                                      forceStrutHeight: true,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    creatorHandle,
                                    style: const TextStyle(
                                      color: figmaTextSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      height: 1,
                                      letterSpacing: -0.30,
                                      leadingDistribution:
                                          TextLeadingDistribution.even,
                                    ),
                                    strutStyle: const StrutStyle(
                                      fontSize: 12,
                                      height: 1,
                                      forceStrutHeight: true,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      _buildVideoPinButton(),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _openOriginalVideo(source),
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFFE8E6E3),
                              width: 0.8,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x07000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                              BoxShadow(
                                color: Color(0x0A000000),
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Text(
                            '원본 영상',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF2C2A27),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              height: 1,
                              letterSpacing: -0.28,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              _isVideoPinned ? 2.0 : _mediaOuterPadding,
              includeCreator ? 0 : 4,
              _isVideoPinned ? 2.0 : _mediaOuterPadding,
              0,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                _isVideoPinned ? 6.0 : _mediaCornerRadius,
              ),
              child: AspectRatio(
                aspectRatio: videoBoxAspect,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final videoH = constraints.maxHeight;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildThumbnailImageContent(
                          source,
                          brightness,
                          height: videoH,
                          videoAspectRatio: videoBoxAspect,
                        ),
                        if (isYouTube && _youtubeVideoId == null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.86),
                              padding: const EdgeInsets.fromLTRB(
                                _recipeCardInnerPaddingH,
                                3,
                                _recipeCardInnerPaddingH,
                                4,
                              ),
                              child: const Text(
                                '이 영상은 유튜브 공식 플레이어로 재생되며, 수익은 100% 원작자에게 돌아갑니다.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        if (_isVideoPinned)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _buildVideoPinButton(),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Figma 239-6440: Top section — back separate, white container with creator bar, video, recipe info (wired to actual data)
  Widget _buildFigmaTopSection(
    models.Recipe recipe,
    models.Nutrition nutrition,
    Map<String, dynamic> source,
    Brightness brightness, {
    bool includeMedia = true,
  }) {
    const Color figmaTextPrimary = Color(0xFF111111);
    const Color figmaTextSecondary = Color(0xFF888888);
    final figmaTags = _identityDisplayTags(source);

    // Stats: time from steps, calories from nutrition, servings from recipe
    int totalMinutes = 0;
    for (final step in recipe.steps) {
      if (step.estMinutes != null) totalMinutes += step.estMinutes!;
    }
    if (totalMinutes == 0) totalMinutes = 15;
    final calories = nutrition.llmEstimate?.caloriesPerServing ?? 0.0;
    final servings = recipe.servings ?? 2.0;

    // Open layout: no outer white card — content sits on page background.
    // Media keeps the old 8px inset so Instagram/YouTube boxes stay full-size.
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
                  if (includeMedia) _buildFigmaMediaBlock(source, brightness),
                  // Recipe meta — open spacing, no filled card shell.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      _recipeCardOuterPadding,
                      14,
                      _recipeCardOuterPadding,
                      0,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title row
                        IgnorePointer(
                          ignoring: _showRecipeNameInHeader,
                          child: AnimatedOpacity(
                            opacity: _showRecipeNameInHeader ? 0 : 1,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            child: Row(
                              children: [
                                // Title + pencil stay adjacent on the left;
                                // Expanded reserves space so category/rating
                                // stay right, without truncating short titles.
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            key: _recipeTitleKey,
                                            recipe.name ?? '레시피',
                                            style: const TextStyle(
                                              fontFamily: 'HakgyoansimJiugae',
                                              color: figmaTextPrimary,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w400,
                                              height: 1.25,
                                              letterSpacing: -0.4,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (_canEditRecipeTitle) ...[
                                          const SizedBox(width: 2),
                                          GestureDetector(
                                            onTap: _editRecipeTitleAlias,
                                            behavior: HitTestBehavior.opaque,
                                            child: Padding(
                                              padding: const EdgeInsets.all(4),
                                              child: Icon(
                                                Icons.edit_outlined,
                                                size: 18,
                                                color: figmaTextPrimary
                                                    .withValues(alpha: 0.5),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                // Category chip only for recipes already in
                                // the user's recipe book.
                                if (_isSaved) ...[
                                  GestureDetector(
                                    onTap: _handleRecipeCardCategoryTap,
                                    behavior: HitTestBehavior.opaque,
                                    child: Builder(
                                      builder: (_) {
                                        final selectedName =
                                            _recipebookCategoryBadgeLabel();
                                        final isAssigned =
                                            selectedName != null;
                                        return Container(
                                          constraints: const BoxConstraints(
                                            maxWidth: 168,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 11,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isAssigned
                                                ? Colors.white
                                                : const Color(0xFFF2F4F6),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: isAssigned
                                                ? Border.all(
                                                    color: const Color(
                                                      0xFFE8EAEE,
                                                    ),
                                                    width: 1,
                                                  )
                                                : null,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                isAssigned
                                                    ? Icons.folder_rounded
                                                    : Icons
                                                        .bookmark_add_rounded,
                                                size: 13,
                                                color: isAssigned
                                                    ? const Color(0xFFFF6B00)
                                                    : const Color(0xFF4E5968),
                                              ),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                child: Text(
                                                  selectedName ?? '미분류',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: 'Pretendard',
                                                    color: isAssigned
                                                        ? const Color(
                                                            0xFF191F28,
                                                          )
                                                        : const Color(
                                                            0xFF4E5968,
                                                          ),
                                                    fontSize: 11,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                    letterSpacing: -0.2,
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
                                const SizedBox(width: 8),
                                _buildAverageRatingMiniLabel(),
                              ],
                            ),
                          ),
                        ),
                        Builder(
                          builder: (_) {
                            final aura = _buildRecipeAuraLine(recipe, source);
                            if (aura.isEmpty) {
                              return const SizedBox(height: 10);
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 10),
                              child: Text(
                                aura,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  color: figmaTextSecondary,
                                  height: 1.4,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            );
                          },
                        ),
                        _buildRecipeIdentityStrip(
                          source: source,
                          totalMinutes: totalMinutes,
                          calories: calories,
                          servings: servings,
                          tags: figmaTags,
                          brightness: brightness,
                        ),
                        // 밀키트 검색 품질이 재료 매칭에 묶여 있어 당분간 숨김.
                        // _buildMealKitRow(recipe, source),
                      ],
                    ),
                  ),
        ],
      ),
    );
  }

  Widget _buildIdentityTagScroller(Map<String, dynamic> source) {
    final chef = <String>[];
    final taste = <String>[];
    final seen = <String>{};
    for (final tag in sanitizeRecipeTagList(source['tags'] as List?)) {
      final key = normalizeRecipeTagToken(tag);
      if (key.isEmpty || !seen.add(key)) continue;
      if (_isChefTag(tag)) {
        chef.add(tag);
      } else {
        taste.add(tag);
      }
    }
    final occasion = <String>[];
    for (final tag in sanitizeRecipeTagList(source['occasionTags'] as List?)) {
      final key = normalizeRecipeTagToken(tag);
      if (key.isEmpty || !seen.add(key)) continue;
      if (_isChefTag(tag)) {
        chef.add(tag);
      } else {
        occasion.add(tag);
      }
    }
    Widget groupDivider() {
      return const Center(
        child: SizedBox(
          width: 1,
          height: 12,
          child: ColoredBox(color: Color(0xFFE5E7EB)),
        ),
      );
    }

    final items = <Widget>[
      for (final tag in chef) _buildTagPill(tag),
      if (chef.isNotEmpty && (taste.isNotEmpty || occasion.isNotEmpty))
        groupDivider(),
      for (final tag in taste) _buildTagPill(tag),
      if (taste.isNotEmpty && occasion.isNotEmpty) groupDivider(),
      for (final tag in occasion) _buildTagPill(tag),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 30,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenW = MediaQuery.sizeOf(context).width;
          return OverflowBox(
            alignment: Alignment.center,
            minWidth: screenW,
            maxWidth: screenW,
            child: SizedBox(
              width: screenW,
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: _recipeCardOuterPadding,
                  vertical: 2,
                ),
                physics: const BouncingScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, index) =>
                    Center(child: items[index]),
              ),
            ),
          );
        },
      ),
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

  Widget _buildTagPill(String label) {
    final isChef = _isChefTag(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        gradient: isChef ? _chefTagGradient : null,
        color: isChef ? null : Colors.white,
        borderRadius: BorderRadius.circular(22369600),
        border: Border.all(
          width: 0.67,
          color: isChef ? const Color(0x80FFFFFF) : const Color(0xFFEFF4F1),
        ),
        boxShadow: isChef
            ? const [
                BoxShadow(
                  color: Color(0x4DA082FF),
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Pretendard',
          color: isChef ? const Color(0xFF111111) : const Color(0xFF4B5563),
          fontSize: 12,
          fontWeight: isChef ? FontWeight.w700 : FontWeight.w600,
          height: 1.50,
          letterSpacing: -0.30,
        ),
      ),
    );
  }

  /// Figma 239-6467: Single stat item (icon + text), 20.5px height
  Widget _buildStatItem(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.0,
            letterSpacing: -0.32,
          ),
        ),
      ],
    );
  }

  /// Top section: thumbnail behind back + creator bar (liquid overlay), then disclaimer below
  Widget _buildTopSection(Map<String, dynamic> source, Brightness brightness) {
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final platform = source['platform'] as String? ?? '';

    String creatorName = 'ChefAntoine';
    if (uploader.isNotEmpty) {
      creatorName = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creatorName = channel.startsWith('@') ? channel : '@$channel';
    }
    // Use full creator name; truncate only when layout would bring text close to back arrow (handled by Flexible + ellipsis)

    // One rounded box: thumbnail fills area (under back + creator); back and creator bar overlaid with liquid design; disclaimer below
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Stack: thumbnail full height (bar + video), then overlay back + creator bubble with transparent liquid style
            SizedBox(
              height: _creatorBarHeight + _videoHeight,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Thumbnail image behind everything (extends under back button and creator bar)
                  _buildThumbnailImageContent(
                    source,
                    brightness,
                    height: _creatorBarHeight + _videoHeight,
                  ),
                  // Overlay: back button top-left; creator bubble top-right (hugs right)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: 12,
                        bottom: 0,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Back button: top-left
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withOpacity(0.58),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.10),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.12),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 24,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.pop(context),
                              padding: EdgeInsets.zero,
                              style: IconButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          // "원본 영상" button (David: rounded grey button)
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _openVideoLink(source),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  color: Colors.grey.withOpacity(0.85),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.15),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    _buildPlatformIconForCreator(
                                      platform,
                                      brightness,
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      '원본 영상',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
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
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Disclaimer below thumbnail
            Padding(
              padding: const EdgeInsets.only(
                left: 10,
                right: 10,
                top: 2,
                bottom: 0,
              ),
              child: Center(
                child: Text(
                  '이 영상은 ${_platformLabel(platform)} 공식 플레이어로 재생되며, 수익은 100% 원작자에게 돌아갑니다.',
                  style: TextStyle(
                    fontSize: 8,
                    color: AppColors.getTextSecondary(brightness),
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 크리에이터 바의 플랫폼 표식 — 흰 원 pill 없이 로고 자체만 24x24로 표시.
  Widget _buildCreatorBarPlatformPill(String platform, Brightness brightness) {
    return _buildPlatformIconForCreator(platform, brightness, size: 24);
  }

  /// Platform icon for creator bubble; slightly bigger than name+tag stack.
  Widget _buildPlatformIconForCreator(
    String platform,
    Brightness brightness, {
    double size = 24,
  }) {
    final iconSize = size;
    String? assetPath;
    if (platform.toLowerCase() == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (platform.toLowerCase() == 'instagram' ||
        platform.toLowerCase() == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (platform.toLowerCase() == 'tiktok' ||
        platform.toLowerCase() == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
    }
    if (assetPath != null) {
      // 원형 배경 / 클리핑 없이 로고 그대로.
      return SizedBox(
        width: iconSize,
        height: iconSize,
        child: Image.asset(
          assetPath,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return Icon(
              Icons.video_library,
              size: iconSize * 0.56,
              color: AppColors.getTextTertiary(brightness),
            );
          },
        ),
      );
    }
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Icon(
        Icons.video_library,
        size: iconSize * 0.56,
        color: AppColors.getTextTertiary(brightness),
      ),
    );
  }

  /// iOS Instagram 포스터: 카드에 쓰는 저장 썸네일을 우선하고, 없으면 소스 이미지를 쓴다.
  String? _iosInstagramPosterUrl(Map<String, dynamic> source) {
    final resolved = RecipeThumbnailResolver.resolve({
      'source': source,
      'platform': source['platform'],
      'sourceUrl': source['url'],
      'thumbnailUrl': source['thumbnailUrl'] ?? source['thumbnail'],
      'thumbnailUrlLarge': source['thumbnailUrlLarge'],
      'thumbnailUrlCropped': source['thumbnailUrlCropped'],
      'thumbnail_url': source['thumbnail_url'],
    });
    if (resolved.isNotEmpty) return resolved;
    final thumb = (source['thumbnail'] as String?)?.trim();
    if (thumb != null && thumb.isNotEmpty) return thumb;
    final og = (source['og_image_url'] as String?)?.trim();
    if (og != null && og.isNotEmpty) return og;
    return null;
  }

  Map<String, String>? _iosRecipeThumbHeaders(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('cdninstagram') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.com')) {
      return const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://www.instagram.com/',
      };
    }
    return null;
  }

  // Build just the thumbnail image content (the actual image widget)
  //
  // [videoAspectRatio] 가 주어지면 영상 재생 시 그 비율로 플레이어를 렌더링
  // 한다. YouTube 박스의 비율과 일치시키기 위해 호출자가 1:1(Shorts/미상)
  // 또는 16:9(가로 영상)를 직접 지정한다. 비워두면 기존 16:9 기본값.
  Widget _buildThumbnailImageContent(
    Map<String, dynamic> source,
    Brightness brightness, {
    double? height,
    double videoAspectRatio = 16 / 9,
  }) {
    final h = height ?? _videoHeight;
    final sourceUrl = source['url'] as String? ?? '';
    final platform = source['platform'] as String? ?? '';
    final p = platform.toLowerCase();
    final isYouTube =
        p == 'youtube' || isYouTubeUrl(sourceUrl);
    final isInstagram = p == 'instagram' || p == 'instagramweb';
    final isTikTok = p == 'tiktok' || p == 'tiktokweb';
    final isNaverBlog = p == 'naver_blog' || isNaverBlogUrl(sourceUrl);
    final isVideoSource = isYouTube || isInstagram || isTikTok || isNaverBlog;

    // 썸네일 fit 결정.
    //
    // - YouTube: 모든 썸네일이 16:9 캔버스로 발급된다. Shorts의 경우 그
    //   캔버스 안에 9:16 컨텐츠가 letterbox로 들어 있어, 1:1 박스에 contain
    //   으로 넣으면 캔버스 letterbox + 박스 letterbox가 겹쳐 위아래 검정이
    //   거대하게 남는다. cover로 처리하면 캔버스의 letterbox 띠가 자연스럽게
    //   잘려나가 9:16 컨텐츠가 박스에 꽉 차게 보인다. 가로 영상은 박스도
    //   16:9라 cover/contain 결과 동일.
    // - Instagram: native가 9:16(또는 1:1)이라 contain으로 넣으면
    //   좌우 약간만 검정이 남고 컨텐츠가 잘리지 않는다. cover로 두면 위아래
    //   가 잘려 자막/제목 같은 정보가 손실될 수 있다.
    // - TikTok: 세로 영상을 박스 높이에 맞추고 좌우에 검정 여백을 둔다.
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    final BoxFit thumbnailFit;
    if (isYouTube) {
      thumbnailFit = BoxFit.cover;
    } else if (isTikTok) {
      thumbnailFit = BoxFit.contain;
    } else if (isInstagram || isNaverBlog) {
      thumbnailFit = isIos ? BoxFit.cover : BoxFit.contain;
    } else {
      thumbnailFit = BoxFit.cover;
    }
    final thumbnailBackgroundColor = isVideoSource
        ? Colors.black
        : AppColors.getBackgroundTertiary(brightness);
    // 히어로 썸네일 디코딩 해상도 — 화면 폭 기준으로만 잡아 상세 진입 시 메모리 피크를 줄인다.
    final memCacheWidth = isVideoSource
        ? (isIos
            ? (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(400, 1200)
            : null)
        : 800;
    final memCacheHeight = isVideoSource
        ? null
        : (h * 2).ceil().clamp(400, 1000);

    // YouTube player deferred until after first frame for faster card render.
    if (isYouTube &&
        _youtubeVideoId != null &&
        _heavyContentReady &&
        !_holdInlineMediaForCook) {
      return SizedBox(
        width: double.infinity,
        height: h,
        child: YouTubePlayerWidget(
          key: ValueKey(
            'yt-${_youtubeVideoId!}-${videoAspectRatio > 1.0 ? 'L' : 'Sp'}',
          ),
          videoId: _youtubeVideoId!,
          thumbnailUrl: source['thumbnail'] as String?,
          autoPlay: false,
          showControls: true,
          startSeconds: _heldInlineMediaSeconds,
          aspectRatio: videoAspectRatio,
          onFirstPlay: _trackRecipeVideoPlay,
          onWatchEnded: _trackRecipeVideoWatchEnded,
          onDurationKnown: (durationSec) {
            final id = _youtubeVideoId;
            if (!mounted || id == null) return;
            rememberYouTubePlaybackDuration(id, durationSec);
            if (Theme.of(context).platform != TargetPlatform.iOS) return;
            setState(() {});
          },
          onControllerReady: (handle) {
            _youtubeHandle = handle;
          },
          onClose: () {
            setState(() {
              _youtubeVideoId = null;
              _youtubeHandle = null;
              _isPlayerFullscreen = false;
            });
          },
          onFullscreenChanged: (isFullscreen) {
            setState(() {
              _isPlayerFullscreen = isFullscreen;
            });
            if (isFullscreen) {
              _scrollController.jumpTo(0);
            }
          },
        ),
      );
    }

    // Instagram Reels/Posts 인라인 임베드 (deferred).
    if (isInstagram &&
        _instagramTarget != null &&
        _heavyContentReady &&
        !_holdInlineMediaForCook) {
      String? igThumb;
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        igThumb = _iosInstagramPosterUrl(source);
      } else {
        igThumb = source['thumbnail'] as String?;
      }
      return SizedBox(
        width: double.infinity,
        height: h,
        child: InstagramPlayerWidget(
          type: _instagramTarget!.type,
          shortcode: _instagramTarget!.shortcode,
          thumbnailUrl: igThumb,
          aspectRatio: videoAspectRatio,
          onUserPlayedInPlayer: _trackRecipeVideoPlay,
          onFirstPlay: _trackRecipeVideoPlay,
          onWatchEnded: _trackRecipeVideoWatchEnded,
          onControllerReady: (handle) {
            _instagramHandle = handle;
          },
        ),
      );
    }

    // TikTok 인라인 임베드 (deferred).
    if (isTikTok &&
        _tiktokVideoUrl != null &&
        _heavyContentReady &&
        !_holdInlineMediaForCook) {
      return SizedBox(
        width: double.infinity,
        height: h,
        child: TikTokPlayerWidget(
          videoUrl: _tiktokVideoUrl!,
          thumbnailUrl: source['thumbnail'] as String?,
          aspectRatio: videoAspectRatio,
        ),
      );
    }

    // 네이버 블로그 인라인 WebView (deferred).
    if (isNaverBlog &&
        _naverBlogUrl != null &&
        _heavyContentReady &&
        !_holdInlineMediaForCook) {
      return SizedBox(
        width: double.infinity,
        height: h,
        child: NaverBlogPlayerWidget(
          url: _naverBlogUrl!,
          thumbnailUrl: (source['og_image_url'] as String?) ??
              (source['thumbnail'] as String?),
          aspectRatio: videoAspectRatio,
        ),
      );
    }

    // 썸네일 표시
    var thumbnailUrl = source['thumbnail'] as String? ?? '';
    if (isIos) {
      final resolved = _iosInstagramPosterUrl(source);
      if (resolved != null && resolved.isNotEmpty) {
        thumbnailUrl = resolved;
      }
    }
    Widget thumbnailWidget;

    if (thumbnailUrl.isNotEmpty) {
      thumbnailWidget = ColoredBox(
        color: thumbnailBackgroundColor,
        child: CachedNetworkImage(
          imageUrl: thumbnailUrl,
          fit: thumbnailFit,
          width: double.infinity,
          height: h,
          httpHeaders: isIos
              ? _iosRecipeThumbHeaders(thumbnailUrl)
              : const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.instagram.com/',
          },
          memCacheWidth: memCacheWidth,
          memCacheHeight: memCacheHeight,
          maxWidthDiskCache: 1400,
          maxHeightDiskCache: 1200,
          fadeInDuration:
              isIos ? Duration.zero : const Duration(milliseconds: 500),
          placeholder: (_, __) => Container(
            width: double.infinity,
            height: h,
            color: isIos && isVideoSource
                ? Colors.black
                : AppColors.getBackgroundTertiary(brightness),
          ),
          errorWidget: (_, __, ___) => Container(
            width: double.infinity,
            height: h,
            color: AppColors.getBackgroundTertiary(brightness),
            child: Center(
              child: Icon(
                Icons.restaurant,
                size: 64,
                color: AppColors.getTextTertiary(brightness),
              ),
            ),
          ),
        ),
      );
    } else {
      thumbnailWidget = Container(
        width: double.infinity,
        height: h,
        color: AppColors.getBackgroundTertiary(brightness),
        child: Center(
          child: Icon(
            Icons.restaurant,
            size: 64,
            color: AppColors.getTextTertiary(brightness),
          ),
        ),
      );
    }

    // 썸네일 클릭 시 영상 재생
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openVideoLink(source),
        child: thumbnailWidget,
      ),
    );
  }

  // Build just the thumbnail image widget (for use in mask and main image)
  /// Open video link - YouTube는 앱 내 플레이어, 다른 플랫폼은 외부 앱으로 이동
  Future<void> _openVideoLink(Map<String, dynamic> source) async {
    final sourceUrl = source['url'] as String?;
    final platform = source['platform'] as String? ?? '';

    if (sourceUrl == null || sourceUrl.isEmpty) {
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('비디오 링크를 찾을 수 없습니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // YouTube인 경우 인라인 플레이어로 재생.
    // X로 닫아 _youtubeVideoId가 null이 된 상태에서 다시 누른 경우를 위해
    // 같은 setter로 복원한다.
    final lowerPlatform = platform.toLowerCase();
    if (lowerPlatform == 'youtube' || isYouTubeUrl(sourceUrl)) {
      final videoId = extractYouTubeVideoId(sourceUrl);
      if (videoId != null) {
        setState(() {
          _youtubeVideoId = videoId;
        });
      } else {
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('YouTube 영상 ID를 찾을 수 없습니다'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      return;
    }

    // Instagram 인라인 임베드.
    if (lowerPlatform == 'instagram' ||
        lowerPlatform == 'instagramweb' ||
        isInstagramUrl(sourceUrl)) {
      final target = extractInstagramShortcode(sourceUrl);
      if (target != null) {
        setState(() {
          _instagramTarget = target;
        });
        return;
      }
      // shortcode 추출 실패 시 외부 폴백.
      await _launchExternalUrl(sourceUrl);
      return;
    }

    // TikTok 인라인 임베드 (oEmbed는 위젯 내부에서 비동기로 호출).
    if (lowerPlatform == 'tiktok' ||
        lowerPlatform == 'tiktokweb' ||
        isTikTokUrl(sourceUrl)) {
      setState(() {
        _tiktokVideoUrl = sourceUrl;
      });
      return;
    }

    // 네이버 블로그 인라인 WebView 재오픈.
    if (lowerPlatform == 'naver_blog' || isNaverBlogUrl(sourceUrl)) {
      setState(() {
        _naverBlogUrl = sourceUrl;
      });
      return;
    }

    // 그 외 플랫폼은 외부 앱으로 이동.
    await _launchExternalUrl(sourceUrl);
  }

  Future<void> _openOriginalVideo(Map<String, dynamic> source) async {
    final sourceUrl = source['url'] as String?;
    if (sourceUrl == null || sourceUrl.isEmpty) {
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('원본 영상 링크를 찾을 수 없습니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    await _launchExternalUrl(sourceUrl);
  }

  Future<void> _launchExternalUrl(String sourceUrl) async {
    try {
      // Ensure URL has proper scheme
      String finalUrl = sourceUrl;
      if (!sourceUrl.startsWith('http://') &&
          !sourceUrl.startsWith('https://')) {
        finalUrl = 'https://$sourceUrl';
      }

      final uri = Uri.parse(finalUrl);

      // Check if URL can be launched
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('링크를 열 수 없습니다'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('[RecipeDetailScreen] Error opening video link: $e');
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('링크를 여는 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  bool _isChefTag(String tag) => isChefDisplayTag(tag);

  Color _getDescriptorTagColor(String tag) {
    if (_isChefTag(tag)) return const Color(0xFFEFE7FF);
    switch (tag) {
      case '단백한':
        return const Color(0xFFFFEBEB);
      case '자극적인':
        return const Color(0xFFFFF0E0);
      case '단짠단짠':
        return const Color(0xFFFFF5E6);
      case '매콤한':
      case '얼큰한':
        return const Color(0xFFFFE5E5);
      case '달달한':
        return const Color(0xFFFFE8F2);
      case '진한맛':
        return const Color(0xFFFFEFE0);
      case '담백한':
        return const Color(0xFFD6EBFF);
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFFE7F3FF);
      case '고소한':
        return const Color(0xFFFFF5E6);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
        return const Color(0xFFDCF0DD);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFF4E8);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFF8DC);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFF0ECFF);
      case '바삭한':
        return const Color(0xFFFFF5E6);
      case '쫄깃한':
        return const Color(0xFFFFE5EF);
      case '꾸덕한':
        return const Color(0xFFFFECDE);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFFEAF2FF);
      case '전통':
        return const Color(0xFFE0E4FF);
      case '간편식':
        return const Color(0xFFD6EBFF);
      case '비건':
      case '베지터리언':
        return const Color(0xFFDCF0DD);
      default:
        return const Color(0xFFF5F5F5);
    }
  }

  Color _getDescriptorTagBorderColor(String tag, Brightness brightness) {
    if (_isChefTag(tag)) return const Color(0xFFB39DDB);
    switch (tag) {
      case '단백한':
        return const Color(0xFFFFB8B8);
      case '자극적인':
        return const Color(0xFFFFD4A8);
      case '단짠단짠':
        return const Color(0xFFFFD9B3);
      case '매콤한':
      case '얼큰한':
        return const Color(0xFFFF9999);
      case '달달한':
        return const Color(0xFFFFB3D1);
      case '진한맛':
        return const Color(0xFFFFC085);
      case '담백한':
        return const Color(0xFF64B5F6);
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFF8CBDF2);
      case '고소한':
        return const Color(0xFFFFD9B3);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
        return const Color(0xFF81C784);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFC999);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFDD66);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFB6A6F6);
      case '바삭한':
        return const Color(0xFFFFD9B3);
      case '쫄깃한':
        return const Color(0xFFFFB3D0);
      case '꾸덕한':
        return const Color(0xFFFFBE8A);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFF9CB5FF);
      case '전통':
        return const Color(0xFF7986CB);
      case '간편식':
        return const Color(0xFF64B5F6);
      case '비건':
      case '베지터리언':
        return const Color(0xFF81C784);
      default:
        return AppColors.getBorder(brightness);
    }
  }

  Color _getDescriptorTagTextColor(String tag, Brightness brightness) {
    if (_isChefTag(tag)) return const Color(0xFF4527A0);
    switch (tag) {
      case '단백한':
      case '자극적인':
      case '단짠단짠':
      case '매콤한':
      case '고소한':
      case '얼큰한':
      case '달달한':
      case '진한맛':
      case '바삭한':
      case '쫄깃한':
      case '꾸덕한':
        return const Color(0xFFB8862D);
      case '담백한':
      case '간편식':
      case '깔끔한':
      case '속편한':
      case '순한':
      case '촉촉한':
      case '부들부들':
        return const Color(0xFF1565C0);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
      case '비건':
      case '베지터리언':
        return const Color(0xFF1B5E20);
      case '전통':
        return const Color(0xFF512DA8);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFF9A4D00);
      case '초간편':
      case '10분컷':
        return const Color(0xFF8A6D00);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFF5E35B1);
      default:
        return AppColors.getTextSecondary(brightness);
    }
  }

  Widget _buildTitleSection(
    models.Recipe recipe,
    double calories,
    Brightness brightness,
  ) {
    final source = widget.parseResponse.source;
    final tagsRaw = source['tags'] as List? ?? [];

    // Debug: Log raw tags with detailed information
    print('[RecipeDetail] Raw tags from source: $tagsRaw');
    for (int i = 0; i < tagsRaw.length; i++) {
      final tag = tagsRaw[i];
      if (tag == null) {
        print('[RecipeDetail] Tag[$i]: null');
      } else {
        final tagStr = tag.toString();
        print(
          '[RecipeDetail] Tag[$i]: "$tagStr" (type: ${tag.runtimeType}, length: ${tagStr.length}, isEmpty: ${tagStr.trim().isEmpty})',
        );
        if (tagStr.trim().isEmpty) {
          print('[RecipeDetail] Tag[$i] is empty after trim!');
        }
      }
    }

    if (tagsRaw.any((tag) => tag == null || tag.toString().trim().isEmpty)) {
      print(
        '[RecipeDetail] WARNING: Found empty/null tags in source: $tagsRaw',
      );
    }

    // Filter out empty strings, null values, whitespace-only strings, and invalid tags
    final tags = <String>[];
    for (int i = 0; i < tagsRaw.length; i++) {
      final tag = tagsRaw[i];

      // Step 1: Check for null
      if (tag == null) {
        print('[RecipeDetail] Filtered out null tag at index $i');
        continue;
      }

      // Step 2: Convert to string and trim
      final tagStr = tag.toString().trim();

      // Step 3: Check if empty after trim
      if (tagStr.isEmpty) {
        print(
          '[RecipeDetail] Filtered out empty tag at index $i: "$tag" (original: ${tag.runtimeType})',
        );
        continue;
      }

      // Step 4: Check for valid characters (Korean, English, numbers)
      if (!RegExp(r'[가-힣a-zA-Z0-9]').hasMatch(tagStr)) {
        print(
          '[RecipeDetail] Filtered out invalid tag at index $i (no valid chars): "$tagStr"',
        );
        continue;
      }

      // Step 5: Check that removing invisible chars still leaves valid content
      final withoutInvisible = tagStr.replaceAll(
        RegExp(r'[\s\u200B-\u200D\uFEFF]'),
        '',
      );
      if (withoutInvisible.isEmpty ||
          !RegExp(r'[가-힣a-zA-Z0-9]').hasMatch(withoutInvisible)) {
        print(
          '[RecipeDetail] Filtered out tag at index $i (only invisible chars): "$tagStr"',
        );
        continue;
      }

      // Step 6: Tag is valid, add it
      tags.add(tagStr);
      print('[RecipeDetail] Accepted tag at index $i: "$tagStr"');
    }

    final blockedFiltered = filterRecipeTagsForDisplay(List<String>.from(tags));
    tags
      ..clear()
      ..addAll(blockedFiltered);

    // Debug: Log final filtered tags
    if (tags.length != tagsRaw.length) {
      print(
        '[RecipeDetail] Filtered tags: ${tagsRaw.length} → ${tags.length} (removed ${tagsRaw.length - tags.length} invalid tags)',
      );
    }
    // Calculate cooking time from steps
    int totalMinutes = 0;
    for (var step in recipe.steps) {
      if (step.estMinutes != null) {
        totalMinutes += step.estMinutes!;
      }
    }
    if (totalMinutes == 0) totalMinutes = 15; // Default

    final statsColor = brightness == Brightness.dark
        ? const Color(0xFFE0E0E0)
        : const Color(0xFF000000);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left side: Recipe name + tags (same row), then time/calories
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Recipe name
                Text(
                  recipe.name ?? '레시피',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    color: brightness == Brightness.dark
                        ? const Color(0xFFE0E0E0)
                        : const Color(0xFF000000),
                  ),
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: tags
                        .map((tag) {
                          if (tag.isEmpty ||
                              !RegExp(r'[가-힣a-zA-Z0-9]').hasMatch(tag)) {
                            return null;
                          }
                          final isChef = _isChefTag(tag);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              gradient: isChef ? _chefTagGradient : null,
                              color: isChef ? null : _getDescriptorTagColor(tag),
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(
                                color: isChef
                                    ? const Color(0x80FFFFFF)
                                    : _getDescriptorTagBorderColor(tag, brightness),
                                width: 1,
                              ),
                              boxShadow: isChef
                                  ? const [
                                      BoxShadow(
                                        color: Color(0x4DA082FF),
                                        blurRadius: 6,
                                        offset: Offset(0, 1),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: isChef
                                    ? const Color(0xFF111111)
                                    : _getDescriptorTagTextColor(tag, brightness),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          );
                        })
                        .whereType<Widget>()
                        .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                // Time, calories, and servings row (icons and text 1px bigger)
                Row(
                  children: [
                    Icon(Icons.access_time, size: 17, color: statsColor),
                    const SizedBox(width: 6),
                    Text(
                      '$totalMinutes분',
                      style: TextStyle(fontSize: 12, color: statsColor),
                    ),
                    const SizedBox(width: 16),
                    Icon(
                      Icons.local_fire_department_outlined,
                      size: 17,
                      color: statsColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${calories.toInt()}KCal',
                      style: TextStyle(fontSize: 12, color: statsColor),
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.people_outline, size: 17, color: statsColor),
                    const SizedBox(width: 6),
                    Text(
                      '인분',
                      style: TextStyle(fontSize: 12, color: statsColor),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () =>
                          _showCategoriesInfoDialog(context, brightness),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 6,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.info_outline,
                          size: 19,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _resolvedAverageRating() {
    final direct = widget.parseResponse.averageRating;
    if (direct != null && direct > 0) return direct;
    final reviews = _recipeReviews ?? const <Map<String, dynamic>>[];
    if (reviews.isEmpty) return 0;
    final ratings = reviews
        .map((r) => (r['rating'] as num?)?.toDouble())
        .whereType<double>()
        .where((v) => v > 0)
        .toList();
    if (ratings.isEmpty) return 0;
    return ratings.reduce((a, b) => a + b) / ratings.length;
  }

  Widget _buildAverageRatingMiniLabel() {
    final avg = _resolvedAverageRating();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Image.asset(_starFilledPath, width: 14, height: 14),
        const SizedBox(width: 4),
        Text(
          avg > 0 ? avg.toStringAsFixed(1) : '-.-',
          style: const TextStyle(
            color: Color(0xFF333D4B),
            fontSize: 16,
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -0.80,
          ),
        ),
      ],
    );
  }

  static const Color _headerActionIconColor = Color(0xFF111111);
  static const double _headerActionIconSize = 22.0;

  Widget _headerActionIcon(IconData icon, {Color? color}) {
    return SizedBox(
      width: _headerBookmarkVisualSize,
      height: _headerBookmarkVisualSize,
      child: Icon(
        icon,
        size: _headerActionIconSize,
        color: color ?? _headerActionIconColor,
      ),
    );
  }

  Widget _buildRecipeBookmarkGlyph() => _buildHeaderBookmarkGlyph();

  Widget _buildHeaderBookmarkGlyph() {
    return SizedBox(
      width: _headerBookmarkVisualSize,
      height: _headerBookmarkVisualSize,
      child: Icon(
        _isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        size: _headerActionIconSize + 3,
        color: _headerActionIconColor,
      ),
    );
  }

  /// 디테일 헤더 우상단 공유 글리프. 북마크 왼쪽.
  Widget _buildHeaderShareButton() {
    return GestureDetector(
      key: _headerShareButtonKey,
      behavior: HitTestBehavior.translucent,
      onTap: _shareRecipe,
      child: _headerActionIcon(Icons.share),
    );
  }

  Future<void> _shareRecipe() async {
    Haptics.selection();
    final text = _buildRecipeShareText();
    if (text.trim().isEmpty) {
      if (!mounted) return;
      showAppSnackBar(context, const SnackBar(content: Text('공유할 레시피가 없어요')));
      return;
    }
    try {
      final box =
          _headerShareButtonKey.currentContext?.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: _recipe.name?.trim().isNotEmpty == true
              ? _recipe.name!.trim()
              : '요리GO 레시피',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      final recipeId = _overlayKey.isNotEmpty ? _overlayKey : 'recipe';
      final analyticsRecipeId =
          (_actualRecipeId ?? widget.recipeId)?.trim() ?? '';
      if (analyticsRecipeId.isNotEmpty) {
        unawaited(
          _analyticsService.trackRecipeShared(
            recipeId: analyticsRecipeId,
            sourceScreen: 'recipe_detail',
          ),
        );
      }
      unawaited(
        RewardsService.instance.claim(
          'exp_recipe_shared',
          idempotencyKey: 'exp_recipe_shared:$recipeId',
          sourceRef: recipeId,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, const SnackBar(content: Text('공유를 열 수 없어요')));
    }
  }

  String _buildRecipeShareText() {
    final recipe = _recipe;
    final source = widget.parseResponse.source;
    final nutrition = widget.parseResponse.nutrition;
    final title = (recipe.name ?? '').trim();
    final channel = (source['channel'] as String?)?.trim() ?? '';
    final uploader = (source['uploader'] as String?)?.trim() ?? '';
    final creator = channel.isNotEmpty
        ? channel
        : (uploader.isNotEmpty
              ? uploader.replaceFirst(RegExp(r'^@'), '')
              : '');
    final sourceUrl = (source['url'] as String?)?.trim() ?? '';

    var totalMinutes = 0;
    for (final step in recipe.steps) {
      if (step.estMinutes != null) totalMinutes += step.estMinutes!;
    }
    if (totalMinutes == 0) totalMinutes = 15;
    final calories = nutrition.llmEstimate?.caloriesPerServing ?? 0.0;
    final servings = recipe.servings ?? 2.0;
    final aura = _buildRecipeAuraLine(recipe, source);

    final meta = <String>[
      if (creator.isNotEmpty) creator,
      if (totalMinutes > 0) '$totalMinutes분',
      if (calories > 0) '${calories.toInt()}kcal(1인분)',
      models.formatServingsLabel(servings),
    ];

    final ingredientLines = <String>[];
    for (final ingredient in recipe.ingredients) {
      final name = ingredient.item.trim();
      if (name.isEmpty) continue;
      final qty = _ingredientQtyText(ingredient, portionCount: servings);
      ingredientLines.add(qty.isEmpty ? '· $name' : '· $name $qty');
    }

    final buf = StringBuffer();
    buf.writeln(title.isEmpty ? '요리GO 레시피' : title);
    if (meta.isNotEmpty) {
      buf.writeln();
      buf.writeln(meta.join(' · '));
    }
    if (aura.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln(aura.trim());
    }
    if (ingredientLines.isNotEmpty) {
      buf.writeln();
      buf.writeln('재료');
      buf.writeln(ingredientLines.join('\n'));
    }
    buf.writeln();
    buf.writeln('요리GO에서 단계별로 보며 요리해보세요');
    if (sourceUrl.isNotEmpty) {
      buf.writeln();
      buf.writeln('원본 영상');
      buf.writeln(sourceUrl);
    }
    buf.writeln();
    buf.writeln('앱에서 보기');
    buf.write('https://play.google.com/store/apps/details?id=com.yorigo.mobile');
    return buf.toString();
  }

  /// 디테일 헤더 우상단 ... 글리프. 탭 시 액션 시트(현재 항목: 신고).
  Widget _buildHeaderMoreButton() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _showHeaderActionSheet,
      child: _headerActionIcon(Icons.more_horiz_rounded),
    );
  }

  void _showHeaderActionSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (sheetCtx) {
        final bottomInset = MediaQuery.paddingOf(sheetCtx).bottom;
        return Material(
          color: Colors.transparent,
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 48,
                    height: 6,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        _openTakedownSheet();
                      },
                      child: Container(
                        width: double.infinity,
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.flag_outlined,
                              size: 22,
                              color: Color(0xFFEF4444),
                            ),
                            SizedBox(width: 12),
                            Text(
                              '오류 보고',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFFEF4444),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_isAdmin && widget.recipeId != null) ...[
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          AdminHomeSectionCurationSheet.show(
                            context,
                            recipeId: widget.recipeId!,
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          height: 48,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.push_pin_outlined,
                                size: 22,
                                color: Color(0xFF4E5968),
                              ),
                              SizedBox(width: 12),
                              Text(
                                '홈 섹션 관리',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: Color(0xFF111111),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openTakedownSheet() {
    final recipeId = widget.recipeId;
    final source = widget.parseResponse.source;
    final sourceUrl = source['url'] as String?;
    if (recipeId == null || recipeId.isEmpty) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('레시피 ID를 찾을 수 없습니다')),
      );
      return;
    }
    showRecipeTakedownSheet(
      context,
      recipeId: recipeId,
      sourceUrl: sourceUrl,
      title: _recipe.name,
    );
  }

  /// Show dialog with current recipe categories (from stats info button).
  /// Sized to content; matches [AppConfirmDialog] tone.
  void _showCategoriesInfoDialog(BuildContext context, Brightness brightness) {
    final mainIngredient =
        (_categories['main_ingredient'] ?? const <String>[]).join(', ').trim();
    final entries = <MapEntry<String, List<String>>>[];
    for (final e in _categories.entries) {
      final list = e.value;
      if (list.isEmpty) continue;
      // 주재료와 동일한 주재료 상세는 중복 표기라 숨긴다.
      if (e.key == 'main_ingredient_sub') {
        final sub = list.join(', ').trim();
        if (sub.isEmpty || sub == mainIngredient) continue;
      }
      entries.add(MapEntry(e.key, List<String>.from(list)));
    }

    final isDark = brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final onSurface = isDark ? const Color(0xFFE5E5EA) : const Color(0xFF111111);
    final onSurfaceVariant =
        isDark ? const Color(0xFF8E8E93) : const Color(0xFF6B7280);
    final rowBg = isDark ? const Color(0xFF3A3A3C) : const Color(0xFFF7F7F8);
    final buttonBg = isDark ? const Color(0xFF3A3A3C) : const Color(0xFFF4F5F7);
    final buttonFg =
        isDark ? const Color(0xFFE5E5EA) : const Color(0xFF4B5563);

    showGeneralDialog<void>(
      context: context,
      barrierLabel: '카테고리',
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Opacity(
          opacity: curved.value,
          child: Transform.scale(
            scale: 0.96 + 0.04 * curved.value,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Material(
                  color: Colors.transparent,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Container(
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 30,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                            child: Text(
                              '카테고리',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: onSurface,
                                letterSpacing: -0.43,
                                height: 1.35,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: entries.isEmpty
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 12,
                                    ),
                                    child: Text(
                                      '아직 지정된 카테고리가 없어요.',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: onSurfaceVariant,
                                        letterSpacing: -0.35,
                                        height: 1.5,
                                      ),
                                    ),
                                  )
                                : ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight:
                                          MediaQuery.sizeOf(ctx).height * 0.45,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: rowBg,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 4,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (int i = 0;
                                                i < entries.length;
                                                i++) ...[
                                              if (i > 0)
                                                Divider(
                                                  height: 1,
                                                  thickness: 1,
                                                  color: isDark
                                                      ? const Color(0xFF48484A)
                                                      : Colors.white,
                                                ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  vertical: 12,
                                                ),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    SizedBox(
                                                      width: 88,
                                                      child: Text(
                                                        _getCategoryTypeName(
                                                          entries[i].key,
                                                        ),
                                                        style: TextStyle(
                                                          fontFamily:
                                                              'Pretendard',
                                                          fontSize: 13,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          color:
                                                              onSurfaceVariant,
                                                          letterSpacing: -0.3,
                                                          height: 1.35,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        entries[i]
                                                            .value
                                                            .join(', '),
                                                        textAlign:
                                                            TextAlign.right,
                                                        style: TextStyle(
                                                          fontFamily:
                                                              'Pretendard',
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: onSurface,
                                                          letterSpacing: -0.35,
                                                          height: 1.35,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => Navigator.of(ctx).pop(),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  height: 48,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: buttonBg,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '확인',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: buttonFg,
                                      letterSpacing: -0.375,
                                    ),
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
              ),
            ),
          ),
        );
      },
    );
  }

  // Get category type name in Korean (no 별; time_category → 소요 시간)
  String _getCategoryTypeName(String categoryType) {
    switch (categoryType) {
      case 'meat_type':
        return '고기재료';
      case 'cuisine_type':
      case 'country':
        return '나라';
      case 'menu_type':
        return '메뉴 유형';
      case 'meal_time':
        return '끼니';
      case 'ingredient_type':
      case 'main_ingredient':
        return '주재료';
      case 'main_ingredient_sub':
        return '주재료 상세';
      case 'time_category':
      case 'cook_time':
        return '소요 시간';
      default:
        return categoryType;
    }
  }

  // Build tabbed content section (width-constrained so tab content never overflows)
  Widget _buildTabbedContent(
    models.Recipe recipe,
    models.Nutrition nutrition,
    double baseServings,
    Brightness brightness,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.of(context).size.width;
          return SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.max,
              children: [
                _buildTabHeaders(brightness),
                const SizedBox(height: 4),
                // Tab content
                _buildTabContent(recipe, nutrition, baseServings, brightness),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBestIngredientProductsRail() {
    final previewTargets = selectPreviewIngredients(_recipe.ingredients);
    if (previewTargets.isEmpty) return const SizedBox.shrink();

    final selected = isPreviewRailMarketplace(_previewRailMarketplace)
        ? _previewRailMarketplace
        : kDefaultPreviewMarketplace;
    final cardsByMarketplace = <String, List<BestIngredientProductCard>>{
      for (final marketplace in kPreviewRailMarketplaces)
        marketplace: _bestIngredientProductCards(
          marketplace,
          previewIngredients: previewTargets,
        ),
    };
    final selectedCards = cardsByMarketplace[selected] ?? const [];
    final loading = isPreviewMarketplaceLoading(
      marketplace: selected,
      finishedMarketplaces: _previewMarketplaceLoadsFinished,
      hasCards: selectedCards.isNotEmpty,
    );
    if (shouldHidePreviewRail(
      hasPreviewTargets: true,
      cardsByMarketplace: cardsByMarketplace,
      finishedMarketplaces: _previewMarketplaceLoadsFinished,
    )) {
      return const SizedBox.shrink();
    }

    final rail = BestIngredientProductsRail(
      cards: selectedCards,
      loading: loading,
      marketplace: selected,
      recipeId: _actualRecipeId ?? widget.recipeId,
      skeletonCount: previewTargets.length.clamp(1, 4),
      onMarketplaceChanged: (value) {
        if (value == _previewRailMarketplace) return;
        Haptics.selection();
        setState(() => _previewRailMarketplace = value);
        unawaited(_ensurePreviewMarketplaceLoaded(value));
      },
      onOpenCart: () {
        Haptics.selection();
        unawaited(
          _analyticsService.trackBestIngredientProductsCompareClicked(
            recipeId: _actualRecipeId ?? widget.recipeId,
            marketplace: selected,
          ),
        );
        unawaited(_showAddToCartDialog());
      },
    );

    return VisibilityDetector(
      key: Key(
        'best_ingredient_preview_visible_'
        '${_actualRecipeId ?? widget.recipeId ?? ''}',
      ),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.01) return;
        unawaited(_startPreviewRecommendations());
      },
      child: rail,
    );
  }

  Widget _buildReviewSummaryCard(Brightness brightness) {
    final reviews = _recipeReviews ?? [];
    final int reviewCountHint = widget.parseResponse.reviewCount ?? 0;
    final int reviewCount = _recipeReviewsLoadedOnce
        ? reviews.length
        : (reviewCountHint > 0 ? reviewCountHint : reviews.length);
    final bool isLoadingSummary =
        _recipeReviewsLoading ||
        (!_recipeReviewsLoadedOnce && reviewCountHint > 0);
    final previewReviews = _reviewCarouselItems(reviews);

    void openList() {
      final shouldRefreshReviews =
          _recipeReviewsLoading ||
          !_recipeReviewsLoadedOnce ||
          (reviewCountHint > 0 && reviews.isEmpty && _recipeReviewsFetchFailed);
      if (shouldRefreshReviews) {
        _loadRecipeReviews();
      }
      _showReviewPopup(context, brightness);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        homeSectionRule(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            _recipeCardOuterPadding,
            0,
            0,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
        Padding(
          padding: const EdgeInsets.only(right: _recipeCardOuterPadding),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: openList,
                  behavior: HitTestBehavior.opaque,
                  child: RichText(
                    text: TextSpan(
                      children: [
                        const TextSpan(
                          text: '후기',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111111),
                            letterSpacing: -0.4,
                            height: 1.25,
                          ),
                        ),
                        if (reviewCount > 0)
                          TextSpan(
                            text: ' ($reviewCount)',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8B95A1),
                              letterSpacing: -0.2,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (previewReviews.isNotEmpty)
                GestureDetector(
                  onTap: _openWriteReviewFromDetail,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F5F7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '후기 남기기',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (isLoadingSummary && previewReviews.isEmpty)
          SizedBox(
            height: 148,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: _recipeCardOuterPadding),
              physics: const BouncingScrollPhysics(),
              itemCount: 2,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, __) => const _ReviewCarouselSkeletonCard(),
            ),
          )
        else if (previewReviews.isEmpty)
          Padding(
            padding: const EdgeInsets.only(right: _recipeCardOuterPadding),
            child: _ReviewEmptyState(
              failed: _recipeReviewsFetchFailed && reviewCountHint > 0,
              onTap: _recipeReviewsFetchFailed && reviewCountHint > 0
                  ? openList
                  : _openWriteReviewFromDetail,
            ),
          )
        else
          SizedBox(
            height: 148,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: _recipeCardOuterPadding),
              physics: const BouncingScrollPhysics(),
              itemCount: previewReviews.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                return _buildReviewCarouselCard(
                  context: context,
                  review: previewReviews[index],
                  onOpen: openList,
                );
              },
            ),
          ),
            ],
          ),
        ),
        homeSectionRule(),
      ],
    );
  }

  double _reviewCarouselCardWidth(BuildContext context) {
    return (MediaQuery.sizeOf(context).width * 0.72).clamp(240.0, 300.0);
  }

  List<Map<String, dynamic>> _reviewCarouselItems(
    List<Map<String, dynamic>> reviews,
  ) {
    final withText = <Map<String, dynamic>>[];
    final rest = <Map<String, dynamic>>[];
    for (final review in reviews) {
      final comment = _normalizeReviewComment(
        (review['comment'] as String?) ?? '',
      );
      if (comment.isNotEmpty) {
        withText.add(review);
      } else {
        rest.add(review);
      }
    }
    return [...withText, ...rest].take(8).toList();
  }

  Future<void> _openWriteReviewFromDetail() async {
    final recipeId = (_actualRecipeId ?? widget.recipeId)?.trim() ?? '';
    if (recipeId.isEmpty) {
      if (mounted) {
        AppToast.info(context, '레시피를 저장한 뒤 후기를 남길 수 있어요');
      }
      return;
    }
    final source = widget.parseResponse.source;
    final platform = source['platform'] as String? ?? '';
    await showProgressiveRecipeReviewPopup(
      context,
      recipeId: recipeId,
      recipeTitle: _recipe.name ?? '레시피',
      creatorUsername: resolveCreatorHandle(
        platform: platform,
        uploader: source['uploader'] as String? ?? '',
        uploaderId: source['uploader_id'] as String?,
        channel: source['channel'] as String? ?? '',
        fallback: '@ChefAntoine',
      ),
      platform: platform,
      thumbnailUrl: source['thumbnail'] as String?,
      servings: _recipe.servings ?? 2,
    );
    if (mounted) _loadRecipeReviews();
  }

  Widget _buildReviewCarouselCard({
    required BuildContext context,
    required Map<String, dynamic> review,
    required VoidCallback onOpen,
  }) {
    final userId = review['userId'] as String? ?? '';
    final userData = _getReviewUserData(userId);
    final name = (userData['name'] as String?)?.trim().isNotEmpty == true
        ? (userData['name'] as String).trim()
        : (userData['username'] as String?)?.trim().isNotEmpty == true
        ? (userData['username'] as String).trim()
        : '요리고 유저';
    final comment = _normalizeReviewComment(
      (review['comment'] as String?) ?? '',
    );
    final likeCount = (review['likeCount'] as num?)?.toInt() ?? 0;
    final isLiked = _isReviewLikedByCurrentUser(review);
    final createdAtMs = _millisecondsFromCreatedAt(review['createdAt']);
    final timeText = createdAtMs > 0
        ? _formatReviewRelativeTime(createdAtMs)
        : '';
    final body = comment.isNotEmpty ? comment : '별점만 남긴 후기예요';

    return GestureDetector(
      onTap: onOpen,
      child: Container(
        width: _reviewCarouselCardWidth(context),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEDEFF3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111111),
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (timeText.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    timeText,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF8B95A1),
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF4B5563),
                  height: 1.45,
                  letterSpacing: -0.13,
                ),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                unawaited(
                  _handlePopupReviewLike(
                    review,
                    onRefresh: () {
                      if (mounted) setState(() {});
                    },
                  ),
                );
              },
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 16,
                    color: isLiked
                        ? const Color(0xFFFF6B00)
                        : const Color(0xFF8B95A1),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$likeCount',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isLiked
                          ? const Color(0xFFFF6B00)
                          : const Color(0xFF8B95A1),
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

  String _formatReviewRelativeTime(int createdAtMs) {
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(createdAtMs),
    );
    if (diff.inMinutes < 1) return '방금';
    if (diff.inHours < 1) return '${diff.inMinutes}분';
    if (diff.inHours < 24) return '${diff.inHours}시간';
    if (diff.inDays < 7) return '${diff.inDays}일';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}주';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}개월';
    return '${(diff.inDays / 365).floor()}년';
  }

  StateSetter? _reviewPopupSetState;

  void _showReviewPopup(BuildContext context, Brightness brightness) {
    final recipe = _recipe;
    final source = widget.parseResponse.source;
    final recipeId = _actualRecipeId ?? widget.recipeId;
    final hasRecipeId = recipeId != null && recipeId.isNotEmpty;
    final platform = source['platform'] as String? ?? '';
    final thumbnailUrl = source['thumbnail'] as String?;
    final recipeTitle = recipe.name ?? '레시피';
    final servings = recipe.servings ?? 2;
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final creatorUsername = resolveCreatorHandle(
      platform: platform,
      uploader: uploader,
      uploaderId: source['uploader_id'] as String?,
      channel: channel,
      fallback: '@ChefAntoine',
    );
    final int reviewCountHint = widget.parseResponse.reviewCount ?? 0;

    final bool reviewsMissing =
        (_recipeReviews ?? const []).isEmpty && reviewCountHint > 0;
    if ((!_recipeReviewsLoadedOnce || reviewsMissing) &&
        !_recipeReviewsLoading) {
      _loadRecipeReviews();
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      // Square top — flush under the detail header, not a floating card.
      shape: const RoundedRectangleBorder(),
      clipBehavior: Clip.hardEdge,
      builder: (sheetContext) {
        bool isExpanded = false;
        bool photoOnly = false;
        bool latestFirst = false;
        bool writeFabCollapsed = false;
        return StatefulBuilder(
          builder: (context, sheetSetState) {
            _reviewPopupSetState = sheetSetState;

            final bool hasLoadedReviews =
                (_recipeReviews ?? const <Map<String, dynamic>>[]).isNotEmpty;
            final bool showFullReviewLayout =
                hasLoadedReviews || reviewCountHint > 0;
            final bottomInset = appSystemNavBottomInset(sheetContext);
            // Match recipe-detail fixed header block exactly.
            final detailHeaderHeight =
                MediaQuery.paddingOf(sheetContext).top + 40 + 8 + 1;
            final headerBg = AppColors.getBackground(brightness);

            Future<void> openWriteReview() async {
              final id = recipeId?.trim() ?? '';
              if (id.isEmpty) return;
              await showProgressiveRecipeReviewPopup(
                context,
                recipeId: id,
                recipeTitle: recipeTitle,
                creatorUsername: creatorUsername,
                platform: platform,
                thumbnailUrl: thumbnailUrl,
                servings: servings,
              );
              if (mounted) _loadRecipeReviews();
            }

            return AppMediaQueryMergeNavInsets(
              child: ColoredBox(
                color: headerBg,
                child: Column(
                  children: [
                    // Leave the detail header visible; taps close this sheet.
                    SizedBox(
                      height: detailHeaderHeight,
                      width: double.infinity,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                    Expanded(
                      child: Material(
                        color: Colors.white,
                        child: Stack(
                  children: [
                    Column(
                      children: [
                        _buildReviewPopupHeader(sheetContext),
                        Expanded(
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification.metrics.axis != Axis.vertical) {
                                return false;
                              }
                              final next = notification.metrics.pixels > 24;
                              if (next != writeFabCollapsed) {
                                sheetSetState(() {
                                  writeFabCollapsed = next;
                                });
                              }
                              return false;
                            },
                            child: SingleChildScrollView(
                            padding: EdgeInsets.only(bottom: 88 + bottomInset),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  color: Colors.white,
                                  child: _buildReviewPopupTopSection(
                                    recipe,
                                    source,
                                    brightness,
                                  ),
                                ),
                                Container(
                                  height: 8,
                                  width: double.infinity,
                                  color: const Color(0xFFF2F4F6),
                                ),
                                if (showFullReviewLayout) ...[
                                  Container(
                                    color: Colors.white,
                                    child: _buildReviewExperienceSummarySection(
                                      isExpanded: isExpanded,
                                      onToggleExpanded: () {
                                        sheetSetState(() {
                                          isExpanded = !isExpanded;
                                        });
                                      },
                                    ),
                                  ),
                                  Container(
                                    height: 8,
                                    width: double.infinity,
                                    color: const Color(0xFFF2F4F6),
                                  ),
                                  if (_hasPhotoReviews) ...[
                                    Container(
                                      color: Colors.white,
                                      child: _buildPhotoReviewsSection(),
                                    ),
                                    Container(
                                      height: 8,
                                      width: double.infinity,
                                      color: const Color(0xFFF2F4F6),
                                    ),
                                  ],
                                ],
                                Container(
                                  color: Colors.white,
                                  child: _buildPopupReviewsListSection(
                                    photoOnly: photoOnly,
                                    latestFirst: latestFirst,
                                    reviewCountHint: reviewCountHint,
                                    isReviewLoading: _recipeReviewsLoading,
                                    hasCompletedInitialLoad:
                                        _recipeReviewsLoadedOnce,
                                    reviewFetchFailed:
                                        _recipeReviewsFetchFailed,
                                    onTogglePhotoOnly: () {
                                      sheetSetState(() {
                                        photoOnly = !photoOnly;
                                      });
                                    },
                                    onSelectLatest: () {
                                      sheetSetState(() {
                                        latestFirst = true;
                                      });
                                    },
                                    onSelectRecommended: () {
                                      sheetSetState(() {
                                        latestFirst = false;
                                      });
                                    },
                                    onRefresh: () => sheetSetState(() {}),
                                    onWriteFirstReview: openWriteReview,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ),
                        ),
                      ],
                    ),
                    if (hasRecipeId)
                      Positioned(
                        right: 16,
                        bottom: 16 + bottomInset,
                        child: _buildReviewWriteFab(
                          collapsed: writeFabCollapsed,
                          onTap: openWriteReview,
                        ),
                      ),
                  ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _reviewPopupSetState = null;
    });
  }

  /// Same pill / collapse behavior as feed tab "요리 기록하기".
  Widget _buildReviewWriteFab({
    required bool collapsed,
    required VoidCallback onTap,
  }) {
    const duration = Duration(milliseconds: 320);
    const curve = Curves.easeInOutCubic;
    return UnconstrainedBox(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: duration,
          curve: curve,
          height: 50,
          // Collapsed: 13+24+13 = 50 for a true circle. Don't animate width
          // between null and 50 — that throws constraint lerp assertions.
          padding: EdgeInsets.only(
            left: collapsed ? 13 : 16,
            right: collapsed ? 13 : 16,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFF850F),
                Color(0xFFFF7300),
                Color(0xFFFF6400),
              ],
            ),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF5722).withValues(alpha: 0.28),
                blurRadius: collapsed ? 14 : 18,
                offset: Offset(0, collapsed ? 6 : 8),
              ),
              BoxShadow(
                color: const Color(0xFFFF8A50).withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                duration: duration,
                curve: curve,
                scale: collapsed ? 1.12 : 1,
                child: const Icon(
                  Icons.add_rounded,
                  size: 24,
                  color: Colors.white,
                ),
              ),
              ClipRect(
                child: AnimatedAlign(
                  duration: duration,
                  curve: curve,
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  widthFactor: collapsed ? 0 : 1,
                  child: IgnorePointer(
                    ignoring: collapsed,
                    child: AnimatedOpacity(
                      duration: Duration(
                        milliseconds: collapsed ? 120 : 260,
                      ),
                      curve: collapsed
                          ? Curves.easeIn
                          : Curves.easeOutCubic,
                      opacity: collapsed ? 0 : 1,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 5),
                        child: Text(
                          '후기 남기기',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.3,
                            color: Colors.white,
                          ),
                        ),
                      ),
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

  Widget _buildReviewPopupHeader(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(
                Icons.chevron_left_rounded,
                size: 24,
                color: Color(0xFF111111),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewPopupTopSection(
    models.Recipe recipe,
    Map<String, dynamic> source,
    Brightness brightness,
  ) {
    final platform = source['platform'] as String? ?? '';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final creatorDisplayName = channel.isNotEmpty
        ? channel
        : (uploader.isNotEmpty
              ? uploader.replaceFirst(RegExp(r'^@'), '')
              : 'Chef');
    final creatorHandle = resolveCreatorHandle(
      platform: platform,
      uploader: uploader,
      uploaderId: source['uploader_id'] as String?,
      channel: channel,
    );

    final tags = _getFigmaTags(source).take(3).toList();

    final loadedReviews = _recipeReviews ?? [];
    final double avgRating =
        widget.parseResponse.averageRating ??
        (() {
          if (loadedReviews.isEmpty) return 0.0;
          double sum = 0;
          int count = 0;
          for (final review in loadedReviews) {
            final r = (review['rating'] as num?)?.toDouble();
            if (r != null && r > 0) {
              sum += r;
              count++;
            }
          }
          return count > 0 ? (sum / count) : 0.0;
        })();
    final int ratingCount = (widget.parseResponse.reviewCount ?? 0) > 0
        ? (widget.parseResponse.reviewCount ?? 0)
        : loadedReviews.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(color: Colors.white),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Full-width pill: name uses leftover space; handle always fully visible.
          Container(
            width: double.infinity,
            height: 32,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22369600),
              border: Border.all(
                color: const Color(0xCCF3F4F6),
                width: 0.667,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildPlatformIconForCreator(
                  platform,
                  brightness,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    creatorDisplayName,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    maxLines: 1,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      color: Color(0xFF111111),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      letterSpacing: -0.325,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    strutStyle: const StrutStyle(
                      fontSize: 13,
                      height: 1,
                      forceStrutHeight: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  creatorHandle,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF8B95A1),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  strutStyle: const StrutStyle(
                    fontSize: 12,
                    height: 1,
                    forceStrutHeight: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xCCF3F4F6), width: 0.667),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              recipe.name ?? '레시피',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFF111111),
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                                letterSpacing: -0.425,
                              ),
                            ),
                          ),
                          if (_isSaved) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: _handleRecipeCardCategoryTap,
                              behavior: HitTestBehavior.opaque,
                              child: Builder(
                                builder: (_) {
                                  final selectedName =
                                      _recipebookCategoryBadgeLabel();
                                  final isAssigned = selectedName != null;
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isAssigned
                                          ? Colors.white
                                          : const Color(0xFFF2F4F6),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: const Color(0xFFE8EAEE),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isAssigned
                                              ? Icons.folder_rounded
                                              : Icons.bookmark_add_rounded,
                                          size: 12,
                                          color: isAssigned
                                              ? const Color(0xFFFF6B00)
                                              : const Color(0xFF4B5563),
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          selectedName ?? '미분류',
                                          style: TextStyle(
                                            fontFamily: 'Pretendard',
                                            color: isAssigned
                                                ? const Color(0xFF191F28)
                                                : const Color(0xFF4B5563),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: tags
                            .map(
                              (tag) {
                                final isChef = _isChefTag(tag);
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: isChef ? _chefTagGradient : null,
                                    color: isChef
                                        ? null
                                        : const Color(0xFFF8F9FA),
                                    borderRadius:
                                        BorderRadius.circular(22369600),
                                    border: isChef
                                        ? Border.all(
                                            width: 0.5,
                                            color: const Color(0x80FFFFFF),
                                          )
                                        : null,
                                    boxShadow: isChef
                                        ? const [
                                            BoxShadow(
                                              color: Color(0x4DA082FF),
                                              blurRadius: 6,
                                              offset: Offset(0, 1),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Text(
                                    tag,
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      color: isChef
                                          ? const Color(0xFF111111)
                                          : const Color(0xFF4E5968),
                                      fontSize: 11,
                                      fontWeight: isChef
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      height: 1.5,
                                      letterSpacing: -0.275,
                                    ),
                                  ),
                                );
                              },
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: Color(0xFFFACC15),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          ratingCount > 0
                              ? avgRating.toStringAsFixed(1)
                              : '-.-',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: Color(0xFF111111),
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                            letterSpacing: -1.3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$ratingCount개 평점',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFF8B95A1),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        height: 1.5,
                        letterSpacing: -0.275,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildReviewExperienceSummarySection({
    required bool isExpanded,
    required VoidCallback onToggleExpanded,
  }) {
    final reviews = _recipeReviews ?? [];
    final participants = countDistinctParticipantsInWindow(reviews);
    final difficultyPct = percentForLabel(
      reviews: reviews,
      parseLabel: parseReviewDifficultyLabel,
      targetLabel: ReviewExperienceOptions.summaryDifficultyAnchor,
    );
    final explanationPct = percentForLabel(
      reviews: reviews,
      parseLabel: parseReviewRecipeExplanationLabel,
      targetLabel: ReviewExperienceOptions.summaryExplanationAnchor,
    );
    final benefitBars = aggregateBenefitBars(reviews);
    final maxBenefitRows = isExpanded ? 8 : 4;
    final visibleBenefits = benefitBars.take(maxBenefitRows).toList();
    final canExpandBenefits = benefitBars.length > 4;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '요리 경험 요약',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111111),
              letterSpacing: -0.425,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '표시 중인 리뷰 기준',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFF9CA3AF),
              letterSpacing: -0.275,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 6),
          if (participants > 0)
            RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF8B95A1),
                  letterSpacing: -0.325,
                  height: 1.5,
                ),
                children: [
                  const TextSpan(text: '최근 3개월간 '),
                  TextSpan(
                    text: '$participants명',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFF6B00),
                    ),
                  ),
                  const TextSpan(text: ' 참여'),
                ],
              ),
            )
          else
            const Text(
              '최근 3개월간 참여한 사용자가 없어요',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: Color(0xFF8B95A1),
                letterSpacing: -0.325,
                height: 1.5,
              ),
            ),
          const SizedBox(height: 24),
          _buildSummaryGaugeRow(
            '체감 난이도',
            ReviewExperienceOptions.summaryDifficultyAnchor,
            difficultyPct,
          ),
          const SizedBox(height: 24),
          _buildSummaryGaugeRow(
            '레시피 설명',
            ReviewExperienceOptions.summaryExplanationAnchor,
            explanationPct,
          ),
          const SizedBox(height: 32),
          const Text(
            '가장 좋았던 점',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111111),
              letterSpacing: -0.35,
            ),
          ),
          const SizedBox(height: 12),
          if (visibleBenefits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '아직 이 항목 응답이 없어요',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF8B95A1),
                  height: 1.5,
                ),
              ),
            )
          else
            for (int i = 0; i < visibleBenefits.length; i++) ...[
              _buildBenefitBarRow(
                option: visibleBenefits[i].option,
                percent: visibleBenefits[i].percent,
                emphasize: i == 0,
              ),
              if (i < visibleBenefits.length - 1) const SizedBox(height: 8),
            ],
          if (canExpandBenefits) ...[
            const SizedBox(height: 20),
            Center(
              child: GestureDetector(
                onTap: onToggleExpanded,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF4F5F7),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: const Color(0xFF9CA3AF),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryGaugeRow(String title, String anchorLabel, int? percent) {
    if (percent == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111111),
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '아직 이 항목 응답이 없어요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF8B95A1),
                    letterSpacing: -0.325,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(9999),
            child: const LinearProgressIndicator(
              minHeight: 8,
              value: 0,
              backgroundColor: Color(0xFFF2F4F6),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111111),
                letterSpacing: -0.35,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              anchorLabel,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111111),
                letterSpacing: -0.35,
              ),
            ),
            Text(
              ' $percent%',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFF6B00),
                letterSpacing: -0.35,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(9999),
          child: LinearProgressIndicator(
            minHeight: 8,
            value: percent / 100,
            backgroundColor: const Color(0xFFF2F4F6),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)),
          ),
        ),
      ],
    );
  }

  Widget _buildBenefitBarRow({
    required String option,
    required int percent,
    required bool emphasize,
  }) {
    final parts = option.split(' ');
    final emoji = parts.first;
    final text = parts.skip(1).join(' ');
    final fillWidthFactor = (percent / 100).clamp(0.0, 1.0);
    final isTop = emphasize;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: fillWidthFactor,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x26FF6B00),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Text(
                  emoji,
                  style: TextStyle(
                    fontSize: isTop ? 16 : 15,
                    fontWeight: isTop ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '"$text"',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: isTop ? FontWeight.w700 : FontWeight.w500,
                      color: const Color(0xFF111111),
                      height: 1.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '$percent%',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: isTop ? FontWeight.w700 : FontWeight.w500,
                    color: isTop
                        ? const Color(0xFFFF6B00)
                        : const Color(0xFF4E5968),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasPhotoReviews {
    final allReviews = _recipeReviews ?? [];
    return allReviews.any((review) {
      final urls = List<String>.from(review['photoUrls'] as List? ?? []);
      final photoUrl = (review['photoUrl'] as String?)?.trim() ?? '';
      return urls.isNotEmpty || photoUrl.isNotEmpty;
    });
  }

  List<Map<String, dynamic>> _photoReviews() {
    final allReviews = _recipeReviews ?? [];
    return allReviews.where((review) {
      final urls = List<String>.from(review['photoUrls'] as List? ?? []);
      final photoUrl = (review['photoUrl'] as String?)?.trim() ?? '';
      return urls.isNotEmpty || photoUrl.isNotEmpty;
    }).toList();
  }

  Widget _buildPhotoReviewsSection() {
    final photoReviews = _photoReviews();
    if (photoReviews.isEmpty) return const SizedBox.shrink();

    Widget photoTile({
      required String? imageUrl,
      required VoidCallback onTap,
      bool isMore = false,
    }) {
      if (isMore) {
        return GestureDetector(
          onTap: onTap,
          child: Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.white,
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: Color(0xFF4E5968),
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  '더보기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF4E5968),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                    letterSpacing: -0.325,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 130,
          height: 130,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: imageUrl != null && imageUrl.isNotEmpty
              ? AppNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  width: 130,
                  height: 130,
                )
              : const Center(
                  child: Icon(
                    Icons.image_outlined,
                    size: 22,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 20, bottom: 16),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 20),
            child: Text(
              '사진 리뷰',
              style: TextStyle(
                color: Color(0xFF111111),
                fontSize: 17,
                fontFamily: 'Pretendard',
                fontWeight: FontWeight.w700,
                height: 1.5,
                letterSpacing: -0.425,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 138,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 20, right: 20),
              itemCount:
                  photoReviews.length > 4 ? 5 : photoReviews.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final hasMoreTile = photoReviews.length > 4;
                if (hasMoreTile && index == 4) {
                  return photoTile(
                    imageUrl: null,
                    onTap: () => _openRecipeReviewFeed(photoOnly: true),
                    isMore: true,
                  );
                }

                final review = photoReviews[index];
                final urls = List<String>.from(
                  review['photoUrls'] as List? ?? [],
                );
                final primary = urls.isNotEmpty
                    ? urls.first
                    : ((review['photoUrl'] as String?)?.trim().isNotEmpty ==
                              true
                          ? (review['photoUrl'] as String).trim()
                          : null);
                return photoTile(
                  imageUrl: primary,
                  onTap: () => _openRecipeReviewFeed(
                    initialReview: review,
                    photoOnly: true,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openRecipeReviewFeed({
    Map<String, dynamic>? initialReview,
    bool photoOnly = false,
  }) {
    final all = _recipeReviews ?? [];
    final reviews = photoOnly
        ? all.where((review) {
            final urls = List<String>.from(review['photoUrls'] as List? ?? []);
            final photoUrl = (review['photoUrl'] as String?)?.trim() ?? '';
            return urls.isNotEmpty || photoUrl.isNotEmpty;
          }).toList()
        : all;
    if (reviews.isEmpty || !mounted) return;

    int initialIndex = 0;
    if (initialReview != null) {
      final targetId =
          (initialReview['id'] as String?) ??
          (initialReview['reviewId'] as String?);
      final foundIndex = reviews.indexWhere((r) {
        final rid = (r['id'] as String?) ?? (r['reviewId'] as String?);
        return rid == targetId;
      });
      if (foundIndex >= 0) initialIndex = foundIndex;
    }

    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return Material(
            type: MaterialType.transparency,
            child: RecipeReviewFeedScrollScreen(
              reviews: reviews,
              initialIndex: initialIndex,
              initialUserDataCache: _reviewUserDataCache,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final offsetTween = Tween<Offset>(
            begin: const Offset(0.12, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic));
          return SlideTransition(
            position: animation.drive(offsetTween),
            child: child,
          );
        },
      ),
    );
  }

  bool _isReviewLikedByCurrentUser(Map<String, dynamic> review) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return false;
    final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
    return likedBy.contains(uid);
  }

  String _reviewId(Map<String, dynamic> review) {
    return (review['id'] as String?) ??
        (review['reviewId'] as String?) ??
        (review['docId'] as String?) ??
        '';
  }

  bool _isBoardReview(Map<String, dynamic> review) {
    return review['sourceType'] == 'board';
  }

  String _boardPostId(Map<String, dynamic> review) {
    return (review['boardPostId'] as String?)?.trim() ?? '';
  }

  Map<String, dynamic> _boardPostAsReview(BoardPost post) {
    final title = post.title.trim();
    final body = post.body.trim();
    final comment = body.isEmpty
        ? title
        : (title.isEmpty ? body : '$title\n$body');
    return {
      'id': 'board_${post.id}',
      'reviewId': 'board_${post.id}',
      'boardPostId': post.id,
      'sourceType': 'board',
      'userId': post.authorId,
      'comment': comment,
      'rating': 0,
      'likeCount': post.likeCount,
      'commentCount': post.commentCount,
      'likedBy': post.likedBy.toList(),
      'createdAt': post.createdAt,
      'photoUrls': const <String>[],
    };
  }

  Future<void> _handlePopupReviewLike(
    Map<String, dynamic> review, {
    bool onlyLike = false,
    required VoidCallback onRefresh,
  }) async {
    final reviewId = _reviewId(review);
    if (reviewId.isEmpty || _popupLikeInFlight.contains(reviewId)) return;
    if (_auth.currentUser == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }

    final wasLiked = _isReviewLikedByCurrentUser(review);
    if (onlyLike && wasLiked) return;
    _popupLikeInFlight.add(reviewId);
    final currentUid = _auth.currentUser!.uid;

    setState(() {
      final list = _recipeReviews;
      if (list == null) return;
      for (final item in list) {
        if (_reviewId(item) != reviewId) continue;
        final likedBy = List<String>.from(item['likedBy'] as List? ?? []);
        final currentCount = (item['likeCount'] as num?)?.toInt() ?? 0;
        if (wasLiked) {
          likedBy.remove(currentUid);
          item['likeCount'] = math.max(0, currentCount - 1);
        } else {
          if (!likedBy.contains(currentUid)) likedBy.add(currentUid);
          item['likeCount'] = currentCount + 1;
        }
        item['likedBy'] = likedBy;
        break;
      }
    });
    onRefresh();

    try {
      if (_isBoardReview(review)) {
        final postId = _boardPostId(review);
        if (postId.isNotEmpty) {
          await _boardService.toggleLike(postId);
        }
      } else {
        await _reviewService.toggleLike(reviewId);
      }
    } catch (_) {
      // keep optimistic state
    } finally {
      _popupLikeInFlight.remove(reviewId);
    }
  }

  Future<void> _showPopupCommentModal(
    BuildContext context,
    Map<String, dynamic> review, {
    required VoidCallback onRefresh,
  }) async {
    final reviewId = _reviewId(review);
    if (reviewId.isEmpty) return;
    if (_isBoardReview(review)) {
      final postId = _boardPostId(review);
      if (postId.isEmpty) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BoardPostDetailScreen(postId: postId),
        ),
      );
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentModal(reviewId: reviewId, review: review),
    );
    try {
      final count = await _reviewService.getCommentCount(reviewId);
      setState(() {
        final list = _recipeReviews;
        if (list == null) return;
        for (final item in list) {
          if (_reviewId(item) != reviewId) continue;
          item['commentCount'] = count;
          break;
        }
      });
      onRefresh();
    } catch (_) {}
  }

  Widget _buildPopupReviewsListSection({
    required bool photoOnly,
    required bool latestFirst,
    required int reviewCountHint,
    required bool isReviewLoading,
    required bool hasCompletedInitialLoad,
    required bool reviewFetchFailed,
    required VoidCallback onTogglePhotoOnly,
    required VoidCallback onSelectLatest,
    required VoidCallback onSelectRecommended,
    required VoidCallback onRefresh,
    required VoidCallback onWriteFirstReview,
  }) {
    final allReviews = _recipeReviews ?? [];
    final hasAnyReviews = allReviews.isNotEmpty;

    final filtered = allReviews.where((review) {
      if (!photoOnly) return true;
      final urls = List<String>.from(review['photoUrls'] as List? ?? []);
      final photoUrl = (review['photoUrl'] as String?)?.trim() ?? '';
      return urls.isNotEmpty || photoUrl.isNotEmpty;
    }).toList();

    filtered.sort((a, b) {
      if (latestFirst) {
        final aMs = _millisecondsFromCreatedAt(a['createdAt']);
        final bMs = _millisecondsFromCreatedAt(b['createdAt']);
        return bMs.compareTo(aMs);
      }
      final aLikes = (a['likeCount'] as num?)?.toInt() ?? 0;
      final bLikes = (b['likeCount'] as num?)?.toInt() ?? 0;
      if (aLikes != bLikes) return bLikes.compareTo(aLikes);
      final aMs = _millisecondsFromCreatedAt(a['createdAt']);
      final bMs = _millisecondsFromCreatedAt(b['createdAt']);
      return bMs.compareTo(aMs);
    });

    // Horizontal padding is applied per-block so review photos can be
    // full-bleed edge-to-edge (same as community feed).
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasAnyReviews)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111111),
                            height: 1.5,
                            letterSpacing: -0.425,
                          ),
                          children: [
                            const TextSpan(text: '리뷰 '),
                            TextSpan(
                              text: '${filtered.length}',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 17,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF8B95A1),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: onTogglePhotoOnly,
                        child: Row(
                          children: [
                            Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4F5F7),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFFE5E8EB),
                                  width: 0.667,
                                ),
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                size: 12,
                                color: photoOnly
                                    ? const Color(0xFF4E5968)
                                    : Colors.transparent,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              '사진 리뷰만',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF4E5968),
                                height: 1.5,
                                letterSpacing: -0.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: onSelectRecommended,
                        child: Text(
                          '추천순',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: latestFirst
                                ? FontWeight.w500
                                : FontWeight.w700,
                            color: latestFirst
                                ? const Color(0xFF8B95A1)
                                : const Color(0xFF111111),
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: onSelectLatest,
                        child: Text(
                          '최신순',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: latestFirst
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: latestFirst
                                ? const Color(0xFF111111)
                                : const Color(0xFF8B95A1),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          if (allReviews.isEmpty && reviewCountHint == 0 && !isReviewLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildPopupEmptyReviewState(
                onWriteFirstReview: onWriteFirstReview,
              ),
            )
          else if (allReviews.isEmpty && isReviewLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Center(
                child: Text(
                  '후기를 불러오는 중이에요...',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF8B95A1),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            )
          else if (allReviews.isEmpty &&
              reviewCountHint > 0 &&
              hasCompletedInitialLoad &&
              !isReviewLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Center(
                child: Text(
                  reviewFetchFailed
                      ? '후기를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.'
                      : '아직 후기가 동기화되지 않았어요. 잠시 후 다시 시도해 주세요.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF8B95A1),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Center(
                child: Text(
                  '표시할 리뷰가 없어요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF8B95A1),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            )
          else
            for (int i = 0; i < filtered.length; i++)
              _buildPopupReviewPostCard(
                review: filtered[i],
                index: i,
                onLike: () =>
                    _handlePopupReviewLike(filtered[i], onRefresh: onRefresh),
                onImageDoubleTap: () => _handlePopupReviewLike(
                  filtered[i],
                  onlyLike: true,
                  onRefresh: onRefresh,
                ),
                onComment: () => _showPopupCommentModal(
                  context,
                  filtered[i],
                  onRefresh: onRefresh,
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildPopupEmptyReviewState({
    required VoidCallback onWriteFirstReview,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 34, 0, 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            const Text(
              '아직 리뷰가 없어요',
              style: TextStyle(
                fontFamily: 'Pretendard',
                color: Color(0xFF111111),
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.5,
                letterSpacing: -0.45,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '이 레시피를 요리해 보셨나요?\n첫 번째 리뷰를 남겨보세요!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                color: Color(0xFF9BA5B4),
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.63,
                letterSpacing: -0.35,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                5,
                (index) => Padding(
                  padding: EdgeInsets.only(right: index == 4 ? 0 : 8),
                  child: Image.asset(_starEmptyPath, width: 30, height: 30),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(100),
                onTap: onWriteFirstReview,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B00),
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x47FF6B00),
                        blurRadius: 20,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Text(
                    '첫 후기 남기기',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: Colors.white,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                      letterSpacing: -0.39,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _reviewDifficultyLabel(Map<String, dynamic> review) {
    final candidates = [
      review['difficultyLabel'],
      review['difficulty'],
      review['difficultyText'],
      review['difficulty_level'],
    ];
    for (final c in candidates) {
      final v = c?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  String? _reviewExplanationLabel(Map<String, dynamic> review) {
    final candidates = [
      review['recipeExplanationLabel'],
      review['explanation'],
      review['explanationLabel'],
      review['explanationText'],
      review['descriptionClarity'],
    ];
    for (final c in candidates) {
      final v = c?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  List<String> _reviewBenefits(Map<String, dynamic> review) {
    final raw = review['benefits'] ??
        review['benefitLabels'] ??
        review['benefitTags'] ??
        review['benefitOptions'];
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  Widget _buildPopupReviewPostCard({
    required Map<String, dynamic> review,
    required int index,
    required VoidCallback onLike,
    required VoidCallback onImageDoubleTap,
    required VoidCallback onComment,
  }) {
    final userId = review['userId'] as String? ?? '';
    final userData = _getReviewUserData(userId);
    final name = (userData['name'] as String?)?.trim().isNotEmpty == true
        ? (userData['name'] as String).trim()
        : (userData['username'] as String?)?.trim().isNotEmpty == true
        ? (userData['username'] as String).trim()
        : '요리고 유저';
    final followerCount = (userData['followerCount'] as num?)?.toInt() ?? 0;
    final userReviewCount = (userData['reviewCount'] as num?)?.toInt() ?? 0;
    final profileUrl = _resolveUserProfileUrl(userData, review);
    final rating = (review['rating'] as num?)?.toInt().clamp(0, 5) ?? 0;
    final difficulty = _reviewDifficultyLabel(review);
    final explanation = _reviewExplanationLabel(review);
    final benefits = _reviewBenefits(review);
    final comment = _normalizeReviewComment(
      (review['comment'] as String?) ?? '',
    );
    final likeCount = (review['likeCount'] as num?)?.toInt() ?? 0;
    final commentCount = (review['commentCount'] as num?)?.toInt() ?? 0;
    final isLiked = _isReviewLikedByCurrentUser(review);
    final createdAtMs = _millisecondsFromCreatedAt(review['createdAt']);
    final createdDateText = createdAtMs > 0
        ? _formatReviewDateText(createdAtMs)
        : '';
    final urls = List<String>.from(review['photoUrls'] as List? ?? []);
    final legacy = (review['photoUrl'] as String?)?.trim() ?? '';
    final photoUrls = urls.isNotEmpty
        ? urls
        : (legacy.isNotEmpty ? [legacy] : <String>[]);
    final initial = name.isNotEmpty ? name.characters.first : '유';

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFFE888), Color(0xFFF5CB28)],
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: profileUrl != null && profileUrl.isNotEmpty
                      ? AppNetworkImage(imageUrl: profileUrl, fit: BoxFit.cover)
                      : Center(
                          child: Text(
                            initial,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111111),
                        height: 1.5,
                        letterSpacing: -0.35,
                      ),
                    ),
                    Text(
                      '후기 $userReviewCount · 팔로워 $followerCount',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8B95A1),
                        height: 1.5,
                        letterSpacing: -0.325,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Image carousel — full-bleed square, same as community feed.
          if (photoUrls.isNotEmpty)
            AspectRatio(
              aspectRatio: 1.0,
              child: PageView.builder(
                itemCount: photoUrls.length,
                itemBuilder: (context, photoIndex) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            _openRecipeReviewFeed(initialReview: review),
                        onDoubleTap: onImageDoubleTap,
                        child: AppNetworkImage(
                          imageUrl: photoUrls[photoIndex],
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          memCacheWidth: AppNetworkImage.feedImageCacheSize,
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${photoIndex + 1}/${photoUrls.length}',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

          if (photoUrls.isNotEmpty) const SizedBox(height: 12),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
          // Stars + meta capsule
          if (!_isBoardReview(review))
          Container(
            height: 39.333,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFF2F4F6), width: 0.667),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: List.generate(5, (i) {
                    final filled = i < rating;
                    return Padding(
                      padding: const EdgeInsets.only(right: 1),
                      child: Image.asset(
                        filled ? _starFilledPath : _starEmptyPath,
                        width: 14,
                        height: 14,
                      ),
                    );
                  }),
                ),
                const SizedBox(width: 10),
                const Text(
                  '|',
                  style: TextStyle(color: Color(0xFFD1D6DB), fontSize: 11),
                ),
                const SizedBox(width: 10),
                Text(
                  '난이도: ${difficulty ?? ''}',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7684),
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '|',
                  style: TextStyle(color: Color(0xFFD1D6DB), fontSize: 11),
                ),
                const SizedBox(width: 10),
                Text(
                  '설명: ${explanation ?? ''}',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7684),
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Like/comment row
          Row(
            children: [
              InkWell(
                onTap: onLike,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 21,
                        color: isLiked
                            ? const Color(0xFFE74C3C)
                            : const Color(0xFF364153),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$likeCount',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF364153),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: onComment,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/icons/feed_chatbubble.png',
                        width: 20,
                        height: 20,
                        color: const Color(0xFF364153),
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 20,
                          color: Color(0xFF364153),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$commentCount',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF364153),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Comment
          if (comment.isNotEmpty)
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: name,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF101828),
                      height: 1.5,
                    ),
                  ),
                  TextSpan(
                    text: ' $comment',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF1E2939),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          if (comment.isNotEmpty) const SizedBox(height: 10),

          // Benefit chips (optional)
          if (benefits.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (int i = 0; i < benefits.length && i < 2; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      benefits[i],
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF4E5968),
                      ),
                    ),
                  ),
                if (benefits.length > 2)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '+${benefits.length - 2}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF4E5968),
                      ),
                    ),
                  ),
              ],
            ),
          if (benefits.isNotEmpty) const SizedBox(height: 10),

          if (commentCount > 0)
            GestureDetector(
              onTap: onComment,
              child: Text(
                '댓글 $commentCount개 모두 보기',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF99A1AF),
                  height: 1.5,
                ),
              ),
            ),
          if (commentCount > 0) const SizedBox(height: 8),

          // Footer meta (left only: month.day.weekday)
          if (createdDateText.isNotEmpty)
            Text(
              createdDateText,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF8B95A1),
              ),
            ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(height: 0.667, color: const Color(0xFFF2F4F6)),
        ],
      ),
    );
  }

  String _normalizeReviewComment(String raw) {
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String? _resolveUserProfileUrl(
    Map<String, dynamic> userData,
    Map<String, dynamic> review,
  ) {
    final candidates = [
      userData['photoUrl'],
      userData['photo_url'],
      userData['profileImageUrl'],
      userData['avatarUrl'],
      review['userPhotoUrl'],
      review['creatorPhotoUrl'],
      review['photoUrl'],
    ];
    for (final c in candidates) {
      final v = c?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  String _formatReviewDateText(int createdAtMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final wd = weekdays[(dt.weekday - 1).clamp(0, 6)];
    return '${dt.month}.${dt.day}.$wd';
  }

  /// Full-stack [Positioned] hit targets: [CompositedTransformFollower] only hit-tests
  /// inside its laid-out box (~82px at the top), so taps on the real tab never registered.
  Widget _buildRecipeDetailTabBarHitOverlay(Brightness brightness) {
    final tabs = ['재료', '요리법', '영양정보'];
    final rect = _recipeTabHitLocalRect;
    if (rect == null) return const SizedBox.shrink();

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: ExcludeSemantics(
        child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _recipeCardOuterPadding,
        ),
        child: Row(
          children: List<Widget>.generate(3, (i) {
            final isSelected = _selectedTabIndex == i;
            return Expanded(
              child: Semantics(
                button: true,
                label: tabs[i],
                selected: isSelected,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    _selectRecipeDetailTab(i, method: 'tap');
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            );
          }),
        ),
        ),
      ),
    );
  }

  // Build tab headers (재료, 요리법, 영양정보) — sliding pill indicator.
  Widget _buildTabHeaders(Brightness brightness) {
    const tabs = ['재료', '요리법', '영양정보'];
    const animationDuration = Duration(milliseconds: 380);
    const animationCurve = Curves.easeOutCubic;

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              duration: animationDuration,
              curve: animationCurve,
              alignment: Alignment(-1.0 + _selectedTabIndex.toDouble(), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / tabs.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
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
            ),
          ),
          Row(
            children: [
              for (int index = 0; index < tabs.length; index++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: AnimatedDefaultTextStyle(
                      duration: animationDuration,
                      curve: animationCurve,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13.5,
                        fontWeight: _selectedTabIndex == index
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: _selectedTabIndex == index
                            ? AppColors.getTextPrimary(brightness)
                            : AppColors.getTextSecondary(brightness),
                        letterSpacing: -0.2,
                        height: 1.2,
                      ),
                      child: Text(
                        tabs[index],
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // Build tab content based on selected tab
  Widget _buildTabContent(
    models.Recipe recipe,
    models.Nutrition nutrition,
    double baseServings,
    Brightness brightness,
  ) {
    switch (_selectedTabIndex) {
      case 0:
        return _buildIngredientsTab(recipe, baseServings, brightness);
      case 1:
        return _buildRecipeTab(recipe, brightness);
      case 2:
        return _buildNutritionTab(context, nutrition, baseServings, brightness);
      default:
        return _buildNutritionTab(context, nutrition, baseServings, brightness);
    }
  }

  Widget _buildSingleTabContent(
    int index,
    models.Recipe recipe,
    models.Nutrition nutrition,
    double baseServings,
    Brightness brightness,
  ) {
    if (!_builtTabs.contains(index)) {
      return const SizedBox(height: 200);
    }
    switch (index) {
      case 0:
        return _buildIngredientsTab(recipe, baseServings, brightness);
      case 1:
        return _buildRecipeTab(recipe, brightness);
      case 2:
        return _buildNutritionTab(context, nutrition, baseServings, brightness);
      default:
        return const SizedBox.shrink();
    }
  }

  /// Normalize URL so slight differences (trailing slash, query, whitespace) still match.
  static List<String> _sourceUrlVariants(String url) {
    if (url.isEmpty) return [];
    final variants = <String>{};
    final trimmed = url.trim();
    variants.add(trimmed);
    var noSlash = trimmed;
    while (noSlash.endsWith('/')) {
      noSlash = noSlash.substring(0, noSlash.length - 1);
    }
    variants.add(noSlash);
    try {
      final uri = Uri.parse(
        noSlash.startsWith('http') ? noSlash : 'https://$noSlash',
      );
      final withoutQuery = uri.replace(query: '', fragment: '').toString();
      variants.add(withoutQuery);
      var noSlash2 = withoutQuery;
      while (noSlash2.endsWith('/')) {
        noSlash2 = noSlash2.substring(0, noSlash2.length - 1);
      }
      variants.add(noSlash2);
    } catch (_) {}
    return variants.where((s) => s.isNotEmpty).toList();
  }

  Future<void> _loadRecipeReviews() async {
    if (_recipeReviewsLoading) return;
    _recipeReviewsLoading = true;
    var allReviews = <Map<String, dynamic>>[];
    bool fetchFailed = false;
    try {
      final recipeService = RecipeService();
      final sourceUrl = widget.parseResponse.source['url'] as String?;
      final recipeName = _recipe.name?.trim() ?? '';
      final seenIds = <String>{};

      void addReviews(List<Map<String, dynamic>> list) {
        for (final r in list) {
          final rid = r['id'] as String? ?? r['reviewId'] as String?;
          if (rid != null && seenIds.add(rid)) {
            allReviews.add(r);
          }
        }
      }

      // 1) Fast path: direct recipeId first (usually quickest/most accurate).
      final recipeId = _actualRecipeId ?? widget.recipeId;
      print(
        '[_loadRecipeReviews] recipeId=$recipeId, _actualRecipeId=$_actualRecipeId, widget.recipeId=${widget.recipeId}',
      );
      print(
        '[_loadRecipeReviews] sourceUrl=$sourceUrl, recipeName=$recipeName',
      );
      if (recipeId != null && recipeId.isNotEmpty) {
        try {
          final result = await _reviewService
              .getRecipeReviews(recipeId)
              .timeout(const Duration(seconds: 6));
          print(
            '[_loadRecipeReviews] Path 1 (recipeId=$recipeId): found ${result.length} reviews',
          );
          addReviews(result);
        } catch (e) {
          print('[_loadRecipeReviews] Path 1 error: $e');
        }
      }

      // 2) Try recipe IDs that match this source URL (cross-user copies).
      if (allReviews.isEmpty && sourceUrl != null && sourceUrl.isNotEmpty) {
        final urlsToTry = _sourceUrlVariants(sourceUrl);
        final seenRecipeIds = <String>{};
        for (final url in urlsToTry) {
          List<String> recipeIds = const [];
          try {
            recipeIds = await recipeService
                .getRecipeIdsBySourceUrl(url)
                .timeout(const Duration(seconds: 6));
            print(
              '[_loadRecipeReviews] Path 2 URL=$url → recipeIds=$recipeIds',
            );
          } catch (e) {
            print('[_loadRecipeReviews] Path 2 URL=$url error: $e');
            continue;
          }
          for (final id in recipeIds) {
            seenRecipeIds.add(id);
          }
          if (seenRecipeIds.isNotEmpty) {
            try {
              final result = await _reviewService
                  .getReviewsByRecipeIds(seenRecipeIds.toList())
                  .timeout(const Duration(seconds: 8));
              print(
                '[_loadRecipeReviews] Path 2 batch fetch: found ${result.length} reviews for ${seenRecipeIds.length} IDs',
              );
              addReviews(result);
            } catch (e) {
              print('[_loadRecipeReviews] Path 2 batch error: $e');
            }
          }
          if (allReviews.isNotEmpty) break;
        }
      }

      // 3) Fallback: find reviews by recipe title.
      if (allReviews.isEmpty && recipeName.isNotEmpty) {
        try {
          final result = await _reviewService
              .getReviewsByRecipeTitle(recipeName)
              .timeout(const Duration(seconds: 6));
          print(
            '[_loadRecipeReviews] Path 3 (title="$recipeName"): found ${result.length} reviews',
          );
          addReviews(result);
        } catch (e) {
          print('[_loadRecipeReviews] Path 3 error: $e');
        }
        final normalizedTitle = recipeName
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (normalizedTitle != recipeName) {
          try {
            final result = await _reviewService
                .getReviewsByRecipeTitle(normalizedTitle)
                .timeout(const Duration(seconds: 6));
            print(
              '[_loadRecipeReviews] Path 3 normalized (title="$normalizedTitle"): found ${result.length} reviews',
            );
            addReviews(result);
          } catch (e) {
            print('[_loadRecipeReviews] Path 3 normalized error: $e');
          }
        }
      }

      try {
        final boardPosts = await _boardService
            .fetchPostsForRecipe(
              recipeId: recipeId,
              recipeTitle: recipeName,
            )
            .timeout(const Duration(seconds: 6));
        addReviews(
          boardPosts.map(_boardPostAsReview).toList(growable: false),
        );
      } catch (e) {
        print('[_loadRecipeReviews] board posts error: $e');
      }

      // Sort by createdAt descending (newest first)
      allReviews.sort((a, b) {
        final aTs = a['createdAt'];
        final bTs = b['createdAt'];
        if (aTs == null && bTs == null) return 0;
        if (aTs == null) return 1;
        if (bTs == null) return -1;
        final aMs = _millisecondsFromCreatedAt(aTs);
        final bMs = _millisecondsFromCreatedAt(bTs);
        return bMs.compareTo(aMs);
      });

      // Load user data in background so reviews render immediately.
      unawaited(_primeReviewUserData(allReviews));

      // Enrich author stats in background so initial list appears immediately.
      final authorIds = <String>{};
      for (final review in allReviews) {
        final authorId = review['userId'] as String?;
        if (authorId != null && authorId.isNotEmpty) authorIds.add(authorId);
      }
      unawaited(_enrichReviewAuthorStats(authorIds));
    } catch (e) {
      print('[_loadRecipeReviews] Outer catch: $e');
      fetchFailed = true;
    } finally {
      print(
        '[_loadRecipeReviews] Done. Total reviews: ${allReviews.length}, fetchFailed=$fetchFailed',
      );
      if (mounted) {
        setState(() {
          _recipeReviews = allReviews;
          _recipeReviewsLoading = false;
          _recipeReviewsLoadedOnce = true;
          _recipeReviewsFetchFailed = fetchFailed;
        });
        _reviewPopupSetState?.call(() {});
      }
    }
  }

  Future<void> _primeReviewUserData(List<Map<String, dynamic>> reviews) async {
    final userIds = <String>{};
    for (final review in reviews) {
      final authorId = review['userId'] as String?;
      if (authorId != null && authorId.isNotEmpty) userIds.add(authorId);
      final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
      for (var i = 0; i < likedBy.length && i < 3; i++) {
        if (likedBy[i].isNotEmpty) userIds.add(likedBy[i]);
      }
    }

    if (userIds.isEmpty) return;

    final userDataMap = <String, Map<String, dynamic>>{};
    await Future.wait(
      userIds.map((userId) async {
        try {
          final userDoc = await _userService.getUserDocument(userId);
          final userData = Map<String, dynamic>.from(
            (userDoc.data() as Map<String, dynamic>?) ?? <String, dynamic>{},
          );
          userDataMap[userId] = userData;
        } catch (_) {
          // ignore
        }
      }),
    );

    if (!mounted || userDataMap.isEmpty) return;

    setState(() {
      _reviewUserDataCache.addAll(userDataMap);
    });
  }

  Future<void> _enrichReviewAuthorStats(Set<String> authorIds) async {
    if (authorIds.isEmpty) return;
    final statUpdates = <String, Map<String, dynamic>>{};
    await Future.wait(
      authorIds.map((userId) async {
        try {
          final results = await Future.wait<int>([
            _userService.getReviewCount(userId),
            _userService.getFollowersCount(userId),
          ]);
          statUpdates[userId] = {
            'reviewCount': results[0],
            'followerCount': results[1],
          };
        } catch (_) {
          // ignore
        }
      }),
    );

    if (!mounted || statUpdates.isEmpty) return;
    setState(() {
      for (final entry in statUpdates.entries) {
        final existing = Map<String, dynamic>.from(
          _reviewUserDataCache[entry.key] ?? <String, dynamic>{},
        );
        existing.addAll(entry.value);
        _reviewUserDataCache[entry.key] = existing;
      }
    });
  }

  Map<String, dynamic> _getReviewUserData(String userId) {
    return _reviewUserDataCache[userId] ?? {};
  }

  Widget _buildRecipeAgentEntry(Brightness brightness) {
    return Material(
      color: AppColors.primaryLight,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openRecipeAgentSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, size: 18, color: AppColors.primaryDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '레시피 도우미',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                ),
              ),
              Text(
                '질문 · 대체',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.getTextTertiary(brightness),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openRecipeAgentSheet() async {
    if (!RecipeAgentService.enabled) return;
    Haptics.medium();
    if (_auth.currentUser == null) {
      if (!mounted) return;
      await Navigator.pushNamed(context, '/login');
      if (_auth.currentUser == null) return;
      await _reloadUserOverlay();
    }
    if (!mounted) return;
    final recipe = _recipe;
    await showRecipeAgentSheet(
      context: context,
      recipeTitle: recipe.name ?? widget.parseResponse.recipe.name ?? '레시피',
      hasOverlay: _userOverlay.isNotEmpty,
      ingredientNames: recipe.ingredients
          .map((e) => e.item)
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      portionCount: _portionCount.round(),
      onPortionChanged: (next) {
        if (!mounted) return;
        setState(() => _portionCount = next.toDouble());
        _reloadAllIngredientPrices();
      },
      recipeId: _actualRecipeId ?? widget.recipeId,
      isSaved: _isSaved,
      overlay: _userOverlay,
      clientSnapshot: RecipeAgentService.compactSnapshot(recipe),
      ensureSaved: () async {
        if (_isSaved && (_actualRecipeId ?? widget.recipeId) != null) {
          return true;
        }
        await _handleAddToSaved();
        return _isSaved && (_actualRecipeId ?? widget.recipeId) != null;
      },
      onApplied: (patches) async {
        final key = _overlayKey;
        if (key.isEmpty) {
          throw StateError('overlay key empty');
        }
        await _localStorageService.applyOverlayPatches(
          recipeKey: key,
          patches: patches.map((p) => p.toOverlayMap()).toList(),
        );
        await _reloadUserOverlay();
      },
    );
  }

  // Build ingredients tab
  Widget _buildIngredientsTab(
    models.Recipe recipe,
    double baseServings,
    Brightness brightness,
  ) {
    final ingredients = recipe.ingredients;
    final merged = _merged;
    // 머지된 ingredients[i] ↔ ingredientSources[i] 가 1:1 대응. identityMap 으로
    // 빠르게 source 룩업(메모/수정여부/추가여부) 가능.
    final ingredientSources =
        Map<models.Ingredient, IngredientSource>.identity();
    for (var i = 0; i < ingredients.length; i++) {
      ingredientSources[ingredients[i]] = merged.ingredientSources[i];
    }
    final equipment = _collectRecipeEquipment(recipe);
    // _prefetchNativeOffers();
    if (ingredients.isEmpty && equipment.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
        children: [
          if (recipe.steps.isNotEmpty && RecipeAgentService.enabled) ...[
            _buildRecipeAgentEntry(brightness),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '재료 정보가 없습니다',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
            ),
          ),
        ],
      ),
      );
    }

    // Unified 6-category grouping (UI display only).
    final byGroup = <String, List<models.Ingredient>>{};
    for (final ingredient in ingredients) {
      final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: ingredient.category,
        ingredientName: ingredient.item,
      );
      byGroup.putIfAbsent(groupKey, () => <models.Ingredient>[]);
      byGroup[groupKey]!.add(ingredient);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
        if (RecipeAgentService.enabled &&
            (ingredients.isNotEmpty || recipe.steps.isNotEmpty)) ...[
          _buildRecipeAgentEntry(brightness),
          const SizedBox(height: 8),
        ],
        // Per-serving cost + portion stepper
        Row(
          children: [
            Expanded(
              child: Builder(
                builder: (context) {
                  final pricePerServing = _calculatePricePerServing();
                  return Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F9FA),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textHeightBehavior: const TextHeightBehavior(
                          applyHeightToFirstAscent: false,
                          applyHeightToLastDescent: false,
                        ),
                        text: TextSpan(
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            height: 1,
                            color: Color(0xFF2C2A27),
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.35,
                          ),
                          children: [
                            const TextSpan(text: '만들어 먹으면 1인분 약 '),
                            TextSpan(
                              text: '${_formatPrice(pricePerServing)}원',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFEA580C),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F5F7),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_portionCount > _portionStep) {
                        Haptics.selection();
                        setState(() => _portionCount -= _portionStep);
                        _reloadAllIngredientPrices();
                        unawaited(
                          _logRecipeCardSignal(
                            'click',
                            screen: 'recipe_detail',
                            sectionId: 'portion_control',
                            cardId: _actualRecipeId ?? widget.recipeId,
                            contentType: 'servings',
                            recipeServings: _portionCount.round(),
                          ),
                        );
                      }
                    },
                    child: const SizedBox(
                      width: 26,
                      height: 42,
                      child: Icon(Icons.remove, size: 15, color: Color(0xFF111111)),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      models.formatServingsLabel(_portionCount),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _portionCount += _portionStep);
                      _reloadAllIngredientPrices();
                      unawaited(
                        _logRecipeCardSignal(
                          'click',
                          screen: 'recipe_detail',
                          sectionId: 'portion_control',
                          cardId: _actualRecipeId ?? widget.recipeId,
                          contentType: 'servings',
                          recipeServings: _portionCount.round(),
                        ),
                      );
                    },
                    child: const SizedBox(
                      width: 26,
                      height: 42,
                      child: Icon(Icons.add, size: 15, color: Color(0xFF111111)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
              const SizedBox(height: 8),
              ...() {
                final orderedKeys = IngredientCategoryUnifier.groupOrder
                    .where((k) => byGroup[k]?.isNotEmpty ?? false)
                    .toList();
                final widgets = <Widget>[];
                for (var i = 0; i < orderedKeys.length; i++) {
                  if (i > 0) widgets.add(const SizedBox(height: 10));
                  final key = orderedKeys[i];
                  widgets.add(
                    _buildIngredientSection(
                      IngredientCategoryUnifier.titleFromKey(key),
                      key,
                      byGroup[key]!,
                      brightness,
                      sources: ingredientSources,
                      offer: null,
                      offerName: null,
                    ),
                  );
                }
                return widgets;
              }(),
              if (equipment.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildEquipmentChips(equipment),
              ],
              if (_canEditRecipeContent) ...[
                const SizedBox(height: 10),
                _buildAddIngredientButton(),
                if (merged.removedIngredients.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildRemovedIngredientsLink(merged.removedIngredients),
                ],
              ],
            ],
          ),
        ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  children: [
              GestureDetector(
                onTap: () {
                  if (FirebaseAuth.instance.currentUser == null) {
                    showAppSnackBar(context, 
                      const SnackBar(
                        content: Text('로그인 후 이용해 주세요.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }
                  _showIngredientPriceIssueSheet(context, recipe);
                },
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F5F7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Color(0xFF6B7684),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '가격 정보 수정 요청',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF6B7684),
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Color(0xFF6B7684),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F5F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: Color(0xFF6B7684),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '표시된 가격은 AI 기반 추정치이며, 실제 가격과 다를 수 있습니다.',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7684),
                          height: 1.4,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
                  ],
                ),
              ),
            ],
          );
  }

  /// Ingredient section with category header (icon + title), 용량, 금액 columns.
  ///
  /// **금액 (price) display – intended logic (not yet wired to backend):**
  /// The value shown in the 금액 column should be:
  ///   (median unit price from Coupang DB for this ingredient) × (amount needed for this recipe).
  /// Example: recipe needs 200g pork; Coupang median is 3000 won per 100g
  ///   → 금액 = (3000 / 100) × 200 = 6000 won.
  /// Until we have Coupang median unit prices and a way to resolve ingredient → product/unit,
  /// the UI shows "-" as a placeholder.
  static const _shortEquipment = {'칼', '볼', '솥', '팬', '체', '컵'};
  static const _notEquipment = {
    '손',
    '손으로',
    '맨손',
    '양손',
    '손가락',
    '주먹',
    '없음',
    '필요없음',
    '해당없음',
    '-',
    '중불',
    '약불',
    '강불',
    '불',
    '가스불',
    '숟가락',
    '숟갈',
    '수저',
    '밥숟가락',
    '티스푼',
    '테이블스푼',
    '젓가락',
    '나무젓가락',
    '일회용젓가락',
    '뚜껑',
    '냄비뚜껑',
    '팬뚜껑',
  };

  bool _isDisplayableEquipment(String name) {
    final compact = name.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return false;
    if (_notEquipment.contains(compact)) return false;
    if (compact.startsWith('손으로')) return false;
    if (_isTableSpoonEquipment(compact)) return false;
    if ((compact.contains('숟가락') || compact.contains('숟갈')) &&
        !compact.contains('나무') &&
        !compact.contains('계량') &&
        !compact.contains('볶음')) {
      return false;
    }
    if (compact.contains('젓가락')) return false;
    if (compact == '뚜껑' || compact.endsWith('뚜껑')) return false;
    if (compact.length == 1 && !_shortEquipment.contains(compact)) return false;
    return true;
  }

  bool _isTableSpoonEquipment(String compact) {
    final base = compact.replaceFirst(
      RegExp(r'^(큰|작은|대형|소형|중형|중간)'),
      '',
    );
    return _notEquipment.contains(base);
  }

  static final _equipmentSizePrefix = RegExp(
    r'^(큰|작은|대형|소형|중형|중간|넓은|깊은|두꺼운|얇은)\s*',
  );

  String _equipmentGroupKey(String name) {
    final compact = name.replaceAll(RegExp(r'\s+'), '');
    return compact.replaceFirst(RegExp(r'^(큰|작은|대형|소형|중형|중간|넓은|깊은|두꺼운|얇은)'), '');
  }

  String _equipmentDisplayName(String name) {
    final stripped = name.replaceFirst(_equipmentSizePrefix, '').trim();
    return stripped.isEmpty ? name : stripped;
  }

  List<String> _collectRecipeEquipment(models.Recipe recipe) {
    final byBase = <String, String>{};
    void addAll(Iterable<String>? items) {
      if (items == null) return;
      for (final raw in items) {
        final name = raw.trim();
        if (!_isDisplayableEquipment(name)) continue;
        final key = _equipmentGroupKey(name);
        if (key.isEmpty) continue;
        final display = _equipmentDisplayName(name);
        final existing = byBase[key];
        if (existing == null || display.length < existing.length) {
          byBase[key] = display;
        }
      }
    }

    addAll(recipe.equipment);
    for (final step in recipe.steps) {
      addAll(step.tools);
    }
    return byBase.values.toList();
  }

  IconData _equipmentIconFor(String tool) {
    final name = tool.replaceAll(' ', '');
    bool has(String token) => name.contains(token);
    if (has('칼') || has('식칼') || has('나이프')) return Icons.content_cut_rounded;
    if (has('도마')) return Icons.crop_7_5_rounded;
    if (has('팬') || has('프라이') || has('그리들')) {
      return Icons.breakfast_dining_outlined;
    }
    if (has('튀김') || has('에어프라')) return Icons.local_fire_department_outlined;
    if (has('오븐') || has('전자레인')) return Icons.microwave_outlined;
    if (has('믹서') || has('블렌더') || has('핸드블')) return Icons.blender_outlined;
    if (has('체') || has('채반') || has('거름')) return Icons.filter_alt_outlined;
    if (has('계량') || has('저울') || has('컵')) return Icons.straighten_rounded;
    if (has('볼') || has('그릇') || has('접시') || has('용기')) {
      return Icons.rice_bowl_outlined;
    }
    if (has('냄비') || has('솥') || has('전골') || has('뚝배기')) {
      return Icons.soup_kitchen_outlined;
    }
    if (has('숟가락') || has('포크') || has('젓가락') || has('뒤집')) {
      return Icons.restaurant_rounded;
    }
    if (has('랩') || has('호일') || has('종이')) return Icons.layers_outlined;
    if (has('장갑') || has('집게')) return Icons.back_hand_outlined;
    return Icons.kitchen_outlined;
  }

  Widget _buildEquipmentChips(List<String> tools) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 0.667),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: const Color(0xFFF9FAFB),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: Center(
                    child: Text(
                      '🍳',
                      style: TextStyle(fontSize: 16 * 0.95, height: 1.0),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '조리도구',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111111),
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                Text(
                  '${tools.length}',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF9CA3AF),
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return _buildJustifiedEquipmentChips(
                  tools,
                  constraints.maxWidth,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static const _equipmentChipTextStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: Color(0xFF2C2A27),
    letterSpacing: -0.2,
    height: 1.1,
  );

  double _equipmentChipWidth(String tool) {
    final painter = TextPainter(
      text: TextSpan(text: tool, style: _equipmentChipTextStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return 6 + 26 + 8 + painter.width + 10;
  }

  int _equipmentRowFlex(List<String> row, int index, double maxWidth) {
    final gap = 8.0 * (row.length - 1);
    final evenSlot = (maxWidth - gap) / row.length;
    final canSplitEven = row.every(
      (tool) => _equipmentChipWidth(tool) <= evenSlot + 0.5,
    );
    if (canSplitEven) return 1;
    return _equipmentChipWidth(row[index]).round().clamp(1, 10000);
  }

  List<List<String>> _packEquipmentRows(List<String> tools, double maxWidth) {
    const gap = 8.0;
    final rows = <List<String>>[];
    var current = <String>[];
    var used = 0.0;
    for (final tool in tools) {
      final width = _equipmentChipWidth(tool);
      final next = current.isEmpty ? width : used + gap + width;
      if (current.isNotEmpty && next > maxWidth) {
        rows.add(current);
        current = [tool];
        used = width;
      } else {
        current.add(tool);
        used = next;
      }
    }
    if (current.isNotEmpty) rows.add(current);
    return rows;
  }

  Widget _buildJustifiedEquipmentChips(List<String> tools, double maxWidth) {
    final rows = _packEquipmentRows(tools, maxWidth);
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            children: [
              for (var j = 0; j < rows[i].length; j++) ...[
                if (j > 0) const SizedBox(width: 8),
                Expanded(
                  flex: _equipmentRowFlex(rows[i], j, maxWidth),
                  child: _buildEquipmentChip(rows[i][j]),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEquipmentChip(String tool, {bool expand = true}) {
    final label = Text(
      tool,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _equipmentChipTextStyle,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _equipmentIconFor(tool),
              size: 15,
              color: const Color(0xFF6B7280),
            ),
          ),
          const SizedBox(width: 8),
          if (expand) Expanded(child: label) else label,
        ],
      ),
    );
  }

  Widget _buildIngredientSection(
    String title,
    String categoryKey,
    List<models.Ingredient> ingredients,
    Brightness brightness, {
    Map<models.Ingredient, IngredientSource>? sources,
    CoupangProduct? offer,
    String? offerName,
  }) {
    // Figma 239-9599
    final boxBg = brightness == Brightness.dark
        ? const Color(0xFF282828)
        : Colors.white;
    final boxBorder = brightness == Brightness.dark
        ? const Color(0xFF404040)
        : const Color(0xFFF3F4F6);
    // Category header: slightly grey so it’s distinct from the ingredient list
    final headerBg = brightness == Brightness.dark
        ? const Color(0xFF242424)
        : const Color(0xFFF9FAFB);
    const double borderWidth = 0.667;
    final primaryText = brightness == Brightness.dark
        ? const Color(0xFFE5E5EA)
        : const Color(0xFF111111);
    final columnHeaderText = brightness == Brightness.dark
        ? const Color(0xFF8E8E93)
        : const Color(0xFF9CA3AF);
    final quantityText = brightness == Brightness.dark
        ? const Color(0xFF8E8E93)
        : const Color(0xFF6B7280);
    // Right-side columns share one fixed width + one consistent gap so that
    // 용량 · 금액 are evenly spaced and tightly aligned.
    const qtyColumnWidth = 48.0;
    const priceColumnWidth = 64.0;
    const columnGap = 6.0;
    const qtyToPriceGap = 8.0;

    return Container(
      decoration: BoxDecoration(
        color: boxBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: boxBorder, width: borderWidth),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: headerBg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      IngredientCategoryUnifier.buildCategoryIcon(
                        key: categoryKey,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: primaryText,
                            letterSpacing: -0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: columnGap),
                SizedBox(
                  width: qtyColumnWidth,
                  child: Text(
                    '용량',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: columnHeaderText,
                      letterSpacing: -0.2,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: qtyToPriceGap),
                SizedBox(
                  width: priceColumnWidth,
                  child: Text(
                    '금액',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: columnHeaderText,
                      letterSpacing: -0.2,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in ingredients.asMap().entries) ...[
                  () {
                final ingredient = entry.value;
                final qtyStr = _ingredientQtyText(ingredient);
                final source = sources?[ingredient];
                final hasMemo = (source?.memo ?? '').isNotEmpty;
                final isAdded = source?.isAdded ?? false;
                final isEdited = source?.isEdited ?? false;

                final ingredientRow = Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key < ingredients.length - 1 || offer != null
                        ? 8
                        : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _canEditRecipeContent
                              ? () => _openIngredientEditSheet(
                                    ingredient,
                                    source,
                                  )
                              : null,
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  ingredient.item,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: primaryText,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (_canEditRecipeContent) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.edit_outlined,
                                  size: 15,
                                  color: Color(0xFF9CA3AF),
                                ),
                              ],
                              if (_canEditRecipeContent &&
                                  (isAdded || isEdited)) ...[
                                const SizedBox(width: 6),
                                _buildOverlayBadge(
                                    isAdded ? '추가됨' : '수정됨'),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: columnGap),
                      SizedBox(
                        width: qtyColumnWidth,
                        child: Text(
                          qtyStr,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: quantityText,
                          ),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: qtyToPriceGap),
                SizedBox(
                  width: priceColumnWidth,
                  child: _ingredientPriceLoading[ingredient.item] == true
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            width: 40,
                            height: 14,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEBECF0),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        )
                      : Text(
                          _ingredientPrices[ingredient.item] != null
                              ? '${_formatPrice(_ingredientPrices[ingredient.item]!)}원'
                              : _ingredientEligibleForUnitPrice(ingredient)
                              ? '준비중'
                              : '',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
                    ],
                  ),
                  if (hasMemo) ...[
                    const SizedBox(height: 6),
                    _buildIngredientMemoBox(source!.memo),
                  ],
                    ],
                  ),
                );
                final String? recipeIdForSignal = _actualRecipeId ?? widget.recipeId;
                final String dedupKey =
                    '${recipeIdForSignal ?? 'unknown'}::${ingredient.item}::${entry.key}';
                return VisibilityDetector(
                  key: Key('recipe_ingredient_impression_$dedupKey'),
                  onVisibilityChanged: (info) {
                    if (info.visibleFraction < 0.5) return;
                    if (_impressedIngredientKeys.contains(dedupKey)) return;
                    _impressedIngredientKeys.add(dedupKey);
                    unawaited(
                      _logRecipeCardSignal(
                        'row_impression',
                        screen: 'recipe_detail',
                        sectionId: 'ingredient_list',
                        cardId: ingredient.item,
                        contentType: 'ingredient',
                        ingredientName: ingredient.item,
                        position: entry.key,
                      ),
                    );
                  },
                  child: ingredientRow,
                );
                  }(),
                  // 네이티브 오퍼 당분간 숨김.
                  // if (offer != null &&
                  //     _sameIngredientLabel(
                  //       entry.value.item,
                  //       offerName ?? '',
                  //     ))
                  //   Padding(
                  //     padding: EdgeInsets.only(
                  //       bottom: entry.key < ingredients.length - 1 ? 8 : 0,
                  //     ),
                  //     child: RecipeNativeOfferCard(
                  //       product: offer,
                  //       sourceScreen: 'recipe_detail_ingredient_offer',
                  //       ingredientName: offerName,
                  //       recipeId: _actualRecipeId ?? widget.recipeId,
                  //     ),
                  //   ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== User overlay UI helpers =====

  /// 인라인 "수정됨/추가됨" 작은 칩.
  Widget _buildOverlayBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3EC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFFFD3B5), width: 0.667),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(0xFFEA580C),
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  /// 재료 메모 인라인 박스 (❋ 스타일).
  Widget _buildIngredientMemoBox(String memo) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFE4D0), width: 0.667),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Text(
              '❋',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                color: Color(0xFFEA580C),
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              memo,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B7280),
                height: 1.45,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "+ 재료 추가하기" 풀폭 outline 카드.
  Widget _buildAddIngredientButton() {
    return GestureDetector(
      onTap: _openAddIngredientSheet,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 49,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFFFD3B5),
            width: 1.2,
            style: BorderStyle.solid,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_rounded,
              size: 18,
              color: Color(0xFF111111),
            ),
            SizedBox(width: 8),
            Text(
              '재료 추가하기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFF6B00),
                letterSpacing: -0.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 삭제된 재료 복원 링크 (펼치면 리스트 + 항목별 복원 버튼).
  Widget _buildRemovedIngredientsLink(List<RemovedIngredient> removed) {
    return GestureDetector(
      onTap: () => _openRemovedIngredientsSheet(removed),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.restore_rounded,
              size: 14,
              color: AppColors.getTextSecondary(Theme.of(context).brightness),
            ),
            const SizedBox(width: 4),
            Text(
              '삭제한 재료 ${removed.length}개 · 복원하기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppColors.getTextSecondary(
                    Theme.of(context).brightness),
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openIngredientEditSheet(
    models.Ingredient ingredient,
    IngredientSource? source,
  ) async {
    if (!_isSaved) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('북마크에 추가한 뒤 이용할 수 있어요')),
      );
      return;
    }
    final key = _overlayKey;
    if (key.isEmpty) return;

    final isAdded = source?.isAdded ?? false;
    final addedId = source?.addedId;

    await showRecipeEditSheet(
      context,
      mode: isAdded
          ? RecipeEditSheetMode.ingredientEditAdded
          : RecipeEditSheetMode.ingredientEditOriginal,
      initialItem: ingredient.item,
      initialQty: ingredient.qty,
      initialUnit: ingredient.unit,
      initialCategoryKey: ingredient.category,
      initialMemo: source?.memo ?? '',
      onSave: (result) async {
        if (isAdded && addedId != null) {
          await _localStorageService.updateCustomIngredient(
            recipeKey: key,
            id: addedId,
            item: result.item,
            qty: result.qty,
            unit: result.unit,
            category: result.categoryKey,
            memo: result.memo ?? '',
          );
        } else {
          await _localStorageService.setIngredientEdit(
            recipeKey: key,
            item: ingredient.item,
            qty: result.qty,
            unit: result.unit,
            memo: result.memo,
          );
        }
        await _reloadUserOverlay();
        await _loadAllIngredientPricesThenReportMissing();
      },
      onDelete: () async {
        if (isAdded && addedId != null) {
          await _localStorageService.deleteCustomIngredient(
            recipeKey: key,
            id: addedId,
          );
        } else {
          await _localStorageService.removeIngredient(
            recipeKey: key,
            item: ingredient.item,
          );
        }
        await _reloadUserOverlay();
      },
    );
  }

  Future<void> _openAddIngredientSheet() async {
    if (!_isSaved) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('북마크에 추가한 뒤 이용할 수 있어요')),
      );
      return;
    }
    final key = _overlayKey;
    if (key.isEmpty) return;
    await showRecipeEditSheet(
      context,
      mode: RecipeEditSheetMode.ingredientAdd,
      initialCategoryKey: IngredientCategoryUnifier.vegFruit,
      onSave: (result) async {
        final item = result.item?.trim() ?? '';
        if (item.isEmpty) return;
        await _localStorageService.addCustomIngredient(
          recipeKey: key,
          item: item,
          qty: result.qty,
          unit: result.unit,
          category: result.categoryKey,
          memo: result.memo ?? '',
        );
        await _reloadUserOverlay();
        await _loadAllIngredientPricesThenReportMissing();
      },
    );
  }

  Future<void> _openRemovedIngredientsSheet(
    List<RemovedIngredient> removed,
  ) async {
    final key = _overlayKey;
    if (key.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _RemovedItemsSheet(
        title: '삭제한 재료',
        items: removed
            .map((e) =>
                _RemovedItem(label: e.item, restoreLabel: '복원'))
            .toList(),
        onRestore: (index) async {
          await _localStorageService.restoreIngredient(
            recipeKey: key,
            item: removed[index].item,
          );
          await _reloadUserOverlay();
          await _loadAllIngredientPricesThenReportMissing();
        },
      ),
    );
  }

  /// 스텝 메모 인라인 박스 (❋ 스타일, 주황 톤).
  Widget _buildStepMemoBox(String memo) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3EC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFD3B5), width: 0.667),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text(
            '❋',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: Color(0xFFEA580C),
              height: 1.5,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              memo,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B7280),
                height: 1.5,
                letterSpacing: -0.325,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddStepButton(MergedRecipe merged) {
    return GestureDetector(
      onTap: () => _openAddStepSheet(merged),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 49,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD3B5), width: 1.2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 18, color: Color(0xFF111111)),
            SizedBox(width: 8),
            Text(
              '단계 추가하기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFF6B00),
                letterSpacing: -0.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemovedStepsLink(List<RemovedStep> removed) {
    return GestureDetector(
      onTap: () => _openRemovedStepsSheet(removed),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.restore_rounded,
              size: 14,
              color: AppColors.getTextSecondary(Theme.of(context).brightness),
            ),
            const SizedBox(width: 4),
            Text(
              '삭제한 단계 ${removed.length}개 · 복원하기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppColors.getTextSecondary(
                    Theme.of(context).brightness),
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 레시피 전체 메모 버튼 — 조리법 요약 줄 오른쪽에서 탭 → 편집.
  Widget _buildRecipeMemoCard(String memo) {
    final hasMemo = memo.trim().isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openRecipeMemoSheet,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: hasMemo
                ? const Color(0xFFFFD3B5)
                : const Color(0xFFE5E8EB),
            width: hasMemo ? 1.2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasMemo ? Icons.edit_outlined : Icons.edit_note_rounded,
              size: 16,
              color: hasMemo
                  ? const Color(0xFFFF6B00)
                  : const Color(0xFF9CA3AF),
            ),
            const SizedBox(width: 6),
            Text(
              hasMemo ? '내 메모' : '메모 추가',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: hasMemo
                    ? const Color(0xFFFF6B00)
                    : AppColors.getTextSecondary(Theme.of(context).brightness),
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openStepEditSheet(
    models.Step step,
    StepSource? source,
  ) async {
    if (!_isSaved) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('북마크에 추가한 뒤 이용할 수 있어요')),
      );
      return;
    }
    final key = _overlayKey;
    if (key.isEmpty) return;
    final isAdded = source?.isAdded ?? false;
    final addedId = source?.addedId;
    final originalOrder = source?.originalOrder;

    final anchorOptions = isAdded ? _buildAnchorOptions() : null;
    final initialAnchor = isAdded
        ? _findCurrentAnchor(addedId)
        : null;

    await showRecipeEditSheet(
      context,
      mode: isAdded
          ? RecipeEditSheetMode.stepEditAdded
          : RecipeEditSheetMode.stepEditOriginal,
      initialInstruction: step.instruction,
      initialMemo: source?.memo ?? '',
      anchorOptions: anchorOptions,
      initialAnchor: initialAnchor,
      onSave: (result) async {
        if (isAdded && addedId != null) {
          await _localStorageService.updateCustomStep(
            recipeKey: key,
            id: addedId,
            instruction: result.instruction,
            memo: result.memo ?? '',
            anchor: result.anchor,
          );
        } else if (originalOrder != null) {
          await _localStorageService.setStepEdit(
            recipeKey: key,
            order: originalOrder,
            instruction: result.instruction,
            memo: result.memo,
          );
        }
        await _reloadUserOverlay();
      },
      onDelete: () async {
        if (isAdded && addedId != null) {
          await _localStorageService.deleteCustomStep(
            recipeKey: key,
            id: addedId,
          );
        } else if (originalOrder != null) {
          await _localStorageService.removeStep(
            recipeKey: key,
            order: originalOrder,
          );
        }
        await _reloadUserOverlay();
      },
    );
  }

  Future<void> _openAddStepSheet(MergedRecipe merged) async {
    final key = _overlayKey;
    if (key.isEmpty) return;
    final anchorOptions = _buildAnchorOptions();
    await showRecipeEditSheet(
      context,
      mode: RecipeEditSheetMode.stepAdd,
      anchorOptions: anchorOptions,
      onSave: (result) async {
        final instruction = result.instruction?.trim() ?? '';
        if (instruction.isEmpty) return;
        await _localStorageService.addCustomStep(
          recipeKey: key,
          instruction: instruction,
          memo: result.memo ?? '',
          anchor: result.anchor ?? <String, dynamic>{'type': 'end'},
        );
        await _reloadUserOverlay();
      },
    );
  }

  Future<void> _openRecipeMemoSheet() async {
    if (!_isSaved) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('북마크에 추가한 뒤 이용할 수 있어요')),
      );
      return;
    }
    final key = _overlayKey;
    if (key.isEmpty) return;
    final current = _userOverlay['recipeMemo'] as String? ?? '';
    await showRecipeEditSheet(
      context,
      mode: RecipeEditSheetMode.recipeMemo,
      initialMemo: current,
      onSave: (result) async {
        await _localStorageService.saveRecipeMemo(key, result.memo ?? '');
        await _reloadUserOverlay();
      },
      onDelete: current.isEmpty
          ? null
          : () async {
              await _localStorageService.saveRecipeMemo(key, '');
              await _reloadUserOverlay();
            },
    );
  }

  Future<void> _openRemovedStepsSheet(List<RemovedStep> removed) async {
    final key = _overlayKey;
    if (key.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _RemovedItemsSheet(
        title: '삭제한 단계',
        items: removed
            .map((e) => _RemovedItem(
                  label: '${e.order}. ${e.instruction}',
                  restoreLabel: '복원',
                ))
            .toList(),
        onRestore: (index) async {
          await _localStorageService.restoreStep(
            recipeKey: key,
            order: removed[index].order,
          );
          await _reloadUserOverlay();
        },
      ),
    );
  }

  /// 머지된 step 리스트 기준으로 anchor dropdown 옵션 목록을 생성.
  /// 추가 시: 맨 처음 + (각 항목 뒤) + 맨 끝.
  List<StepAnchorOption> _buildAnchorOptions() {
    final merged = _merged;
    final options = <StepAnchorOption>[
      StepAnchorOption(
        label: '맨 처음',
        anchor: const <String, dynamic>{'type': 'start'},
      ),
    ];
    for (var i = 0; i < merged.recipe.steps.length; i++) {
      final step = merged.recipe.steps[i];
      final src = merged.stepSources[i];
      final preview = step.instruction.trim();
      final shortPreview = preview.length > 24
          ? '${preview.substring(0, 24)}…'
          : preview;
      final label = '${step.order}번 뒤: $shortPreview';
      Map<String, dynamic> anchor;
      if (src.isAdded && src.addedId != null) {
        anchor = <String, dynamic>{
          'type': 'afterAdded',
          'value': src.addedId,
        };
      } else if (src.originalOrder != null) {
        anchor = <String, dynamic>{
          'type': 'afterOriginal',
          'value': src.originalOrder,
        };
      } else {
        anchor = const <String, dynamic>{'type': 'end'};
      }
      options.add(StepAnchorOption(label: label, anchor: anchor));
    }
    options.add(StepAnchorOption(
      label: '맨 끝',
      anchor: const <String, dynamic>{'type': 'end'},
    ));
    return options;
  }

  /// 추가 스텝의 현재 anchor 값을 overlay 에서 직접 조회 (편집 시 dropdown 초기값).
  Map<String, dynamic>? _findCurrentAnchor(String? addedId) {
    if (addedId == null) return null;
    final stepsOv = _userOverlay['steps'] as Map?;
    if (stepsOv == null) return null;
    final added = stepsOv['added'];
    if (added is! List) return null;
    for (final raw in added) {
      if (raw is Map && raw['id'] == addedId) {
        final anchor = raw['anchor'];
        if (anchor is Map) return Map<String, dynamic>.from(anchor);
      }
    }
    return null;
  }

  // Build serving size selector (fits in narrow layout; no overflow)
  Widget _buildServingSizeSelector(Brightness brightness) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use slightly tighter padding when space is limited to avoid overflow
        final useTightLayout =
            constraints.maxWidth.isFinite && constraints.maxWidth < 130;
        final horizontalPadding = useTightLayout ? 8.0 : 14.0;
        final spacing = useTightLayout ? 6.0 : 10.0;
        return Container(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            9,
            horizontalPadding,
            9,
          ),
          decoration: BoxDecoration(
            color: AppColors.getBackgroundTertiary(brightness),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    scale: _minusButtonPressed ? 0.88 : 1.0,
                    duration: const Duration(milliseconds: 80),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.remove,
                        size: 18,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                  ),
                  Positioned(
                    left: -6,
                    right: -6,
                    top: -6,
                    bottom: -6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (_) =>
                          setState(() => _minusButtonPressed = true),
                      onTapUp: (_) =>
                          setState(() => _minusButtonPressed = false),
                      onTapCancel: () =>
                          setState(() => _minusButtonPressed = false),
                      onTap: () {
                        if (_portionCount > _portionStep) {
                          setState(() => _portionCount -= _portionStep);
                          _reloadAllIngredientPrices();
                        }
                      },
                    ),
                  ),
                ],
              ),
              SizedBox(width: spacing),
              Text(
                models.formatServingsLabel(_portionCount),
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.getTextPrimary(brightness),
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(width: spacing),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    scale: _plusButtonPressed ? 0.88 : 1.0,
                    duration: const Duration(milliseconds: 80),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.add,
                        size: 18,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                  ),
                  Positioned(
                    left: -6,
                    right: -6,
                    top: -6,
                    bottom: -6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (_) =>
                          setState(() => _plusButtonPressed = true),
                      onTapUp: (_) =>
                          setState(() => _plusButtonPressed = false),
                      onTapCancel: () =>
                          setState(() => _plusButtonPressed = false),
                      onTap: () {
                        setState(() => _portionCount += _portionStep);
                        _reloadAllIngredientPrices();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Show add to cart bottom sheet (shared widget)
  /// [presetSelected] 가 주어지면 그 재료만 선택된 채로 담기 시트를 띄운다.
  /// (재료 행의 「구매」 버튼에서 단건 담기 용도. 이 경우 화면의 전체 선택
  ///  상태 [_selectedIngredients] 는 덮어쓰지 않는다.)
  Future<void> _showAddToCartDialog({Set<String>? presetSelected}) async {
    unawaited(
      _ensureRecipeRecommendationsLoaded(mode: RecipeRecoLoadMode.full),
    );
    final recipe = _recipe;
    final groups = groupIngredientsByCategory(recipe.ingredients);
    final bool isPreset = presetSelected != null;

    final result =
        await showModalBottomSheet<({Set<String> selected, double portionCount})?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (_) => IngredientSelectSheet(
        ingredients: recipe.ingredients,
        groups: groups,
        initialSelected: isPreset
            ? Set<String>.from(presetSelected)
            : <String>{},
        initialPortionCount: _portionCount,
        baseServings: recipe.servings ?? 2.0,
        title: '필요한 재료만 골라 주세요',
        subtitle: '',
        ctaLabel: '선택한 재료 구매하기',
        purchaseCopy: true,
      ),
    );

    if (result == null || !mounted) return;
    final selected = result.selected;
    final portionCount = result.portionCount;

    setState(() {
      if (!isPreset) {
        _selectedIngredients.clear();
        _selectedIngredients.addAll(selected);
      }
      _portionCount = portionCount;
    });
    _reloadAllIngredientPrices();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        showAppSnackBar(
          context,
          const SnackBar(
            content: Text('로그인이 필요합니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final recipeId = _actualRecipeId ?? widget.recipeId;
    if (recipeId == null || recipeId.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          context,
          const SnackBar(
            content: Text('레시피를 먼저 저장해주세요'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      final baseServings = recipe.servings ?? 2.0;
      final scaleFactor = portionCount / baseServings;
      final selectedIngredients = recipe.ingredients
          .asMap()
          .entries
          .where((entry) => selected.contains(entry.key.toString()))
          .map((entry) {
            final ingredient = entry.value;
            final scaledQty =
                ingredient.qty != null ? ingredient.qty! * scaleFactor : null;
            return {
              'item': ingredient.item,
              'qty': scaledQty,
              'unit': ingredient.unit,
              'notes': ingredient.notes,
              'category': ingredient.category,
            };
          })
          .toList();

      await _userService.addToCart(
        user.uid,
        {
          'recipeId': recipeId,
          'recipeName': recipe.name ?? '레시피',
          'servings': portionCount,
          'ingredients': selectedIngredients,
          'addedAt': DateTime.now().millisecondsSinceEpoch,
          'scheduledDate': null,
        },
        parseResponseForThumbnail: widget.parseResponse,
      );

      unawaited(
        _analyticsService.trackRecipeCartIngredientsAdded(
          recipeId: recipeId,
          ingredientNames: [
            for (final row in selectedIngredients)
              row['item']?.toString() ?? '',
          ],
        ),
      );

      if (!mounted) return;
      UserService.markPendingCartAddTip();
      appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      mainNavigatorKey.currentState?.navigateToCart();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(
          content: Text('오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Format step duration as MM:SS (e.g. 00:30, 01:00).
  String _formatStepDuration(int? estMinutes) {
    if (estMinutes == null || estMinutes < 0) return '00:00';
    return '${estMinutes.toString().padLeft(2, '0')}:00';
  }

  /// Split a long instruction into sentences for better readability.
  /// Splits on `.` / `!` / `?` only outside parentheses.
  /// Skips decimal points (e.g. `1.5큰술`). Merges orphan `)` fragments.
  List<String> _splitInstructionSentences(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];

    final sentences = <String>[];
    final buffer = StringBuffer();
    var parenDepth = 0;

    void flushBuffer() {
      final s = buffer.toString().trim();
      if (s.isNotEmpty) sentences.add(s);
      buffer.clear();
    }

    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      buffer.write(ch);

      if (ch == '(' || ch == '（') {
        parenDepth++;
        continue;
      }
      if (ch == ')' || ch == '）') {
        if (parenDepth > 0) parenDepth--;
        continue;
      }
      if (parenDepth > 0) continue;

      if (ch == '!' || ch == '?') {
        flushBuffer();
        continue;
      }
      if (ch == '.') {
        final prevIsDigit = i > 0 && RegExp(r'\d').hasMatch(t[i - 1]);
        final nextIsDigit =
            i + 1 < t.length && RegExp(r'\d').hasMatch(t[i + 1]);
        if (prevIsDigit && nextIsDigit) continue;
        flushBuffer();
      }
    }

    flushBuffer();
    if (sentences.isEmpty) return [t];

    // 괄호 안 분리 예외 등으로 `)` 만 남은 조각을 앞 문장에 병합
    final merged = <String>[];
    final orphanClose = RegExp(r'^[)\]」』】〕）\s]+$');
    for (final s in sentences) {
      if (merged.isNotEmpty && orphanClose.hasMatch(s.trim())) {
        merged[merged.length - 1] = '${merged.last}$s';
      } else {
        merged.add(s);
      }
    }
    return merged;
  }

  Widget _buildStepChapterHeader({
    required int order,
    int? startSec,
    required bool canSeek,
  }) {
    final number = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFFE5E7EB),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        '$order',
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFFEA580C),
          height: 1.0,
        ),
      ),
    );

    if (startSec == null) return number;

    final m = startSec ~/ 60;
    final s = startSec % 60;
    final label = '$m:${s.toString().padLeft(2, '0')}';

    final timeChip = Container(
      height: 26,
      padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFE5E7EB),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: Icon(
              Icons.play_arrow_rounded,
              size: 14,
              color: Color(0xFFEA580C),
            ),
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF3F3F46),
              height: 1.0,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        number,
        const SizedBox(width: 8),
        if (canSeek)
          GestureDetector(
            onTap: () => _seekAndPlayStep(startSec.toDouble()),
            behavior: HitTestBehavior.opaque,
            child: timeChip,
          )
        else
          timeChip,
      ],
    );
  }

  /// Build display text for a step ingredient (e.g. "감자 2개") from step ingredient name + recipe ingredients.
  String _stepIngredientDisplay(
    String ingredientName,
    List<models.Ingredient> recipeIngredients,
  ) {
    try {
      final match = recipeIngredients.firstWhere(
        (ing) => ing.item == ingredientName,
        orElse: () => models.Ingredient(item: ingredientName),
      );
      final qtyStr = _ingredientQtyText(match, portionCount: _portionCount);
      if (qtyStr.isNotEmpty) {
        return '${match.item} $qtyStr';
      }
      return match.item;
    } catch (_) {
      return ingredientName;
    }
  }

  Widget _buildMethodTimelineStep({
    required models.Step step,
    required int index,
    required int totalSteps,
    required models.Recipe recipe,
    required StepSource? source,
  }) {
    final stepIngredients = step.stepIngredients ?? [];
    final tip = (step.tip ?? '').trim();
    final isAdded = source?.isAdded ?? false;
    final isEdited = source?.isEdited ?? false;
    final hasMemo = (source?.memo ?? '').isNotEmpty;
    final canSeek = step.startSec != null && _canSeekAndPlayStep;
    final isLast = index == totalSteps - 1;
    final sentences = _splitInstructionSentences(step.instruction);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE8E6E3),
                      width: 0.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x07000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                      BoxShadow(
                        color: Color(0x0F000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${step.order}',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFEA580C),
                      height: 1,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 1,
                        color: const Color(0xFFE0DCD6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
                padding: EdgeInsets.only(top: 6, bottom: isLast ? 4 : 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: canSeek
                          ? () => _seekAndPlayStep(step.startSec!.toDouble())
                          : (_canEditRecipeContent
                              ? () => _openStepEditSheet(step, source)
                              : null),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                      children: [
                        if (step.startSec != null)
                          GestureDetector(
                            onTap: canSeek
                                ? () => _seekAndPlayStep(
                                    step.startSec!.toDouble(),
                                  )
                                : null,
                            child: Text(
                              '▶  ${_formatStepTimestamp(step.startSec!)}',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: canSeek
                                    ? const Color(0xFFEA580C)
                                    : const Color(0xFFB0A89F),
                                letterSpacing: -0.1,
                                height: 1,
                              ),
                            ),
                          ),
                        const Spacer(),
                        if (_canEditRecipeContent &&
                            (isAdded || isEdited)) ...[
                          _buildOverlayBadge(isAdded ? '추가됨' : '수정됨'),
                          const SizedBox(width: 6),
                        ],
                        if (_canEditRecipeContent)
                          GestureDetector(
                            onTap: () => _openStepEditSheet(step, source),
                            behavior: HitTestBehavior.opaque,
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.edit_outlined,
                                size: 15,
                                color: Color(0xFFC4B8AE),
                              ),
                            ),
                          ),
                      ],
                    ),
                    ),
                    const SizedBox(height: 6),
                    MethodStepTimerBlock(
                      step: step,
                      sentences: sentences,
                      style: _methodInstructionStyle,
                    ),
                    if (tip.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Container(
                                width: 1.5,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEA580C),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    const TextSpan(
                                      text: 'TIP  ',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFFEA580C),
                                        letterSpacing: 1.2,
                                        height: 1.35,
                                      ),
                                    ),
                                    TextSpan(
                                      text: tip,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF7A7168),
                                        height: 1.35,
                                        letterSpacing: -0.15,
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
                    if (stepIngredients.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final name in stepIngredients)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFFE8E6E3),
                                  width: 0.8,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x07000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                  BoxShadow(
                                    color: Color(0x0F000000),
                                    blurRadius: 8,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                _stepIngredientDisplay(
                                  name,
                                  recipe.ingredients,
                                ),
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF5C564F),
                                  letterSpacing: -0.15,
                                  height: 1.2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    // 네이티브 오퍼 당분간 숨김.
                    // if (index == 0 && _methodNativeOffer != null) ...[
                    //   const SizedBox(height: 12),
                    //   RecipeNativeOfferCard(
                    //     product: _methodNativeOffer!,
                    //     sourceScreen: 'recipe_detail_method_offer',
                    //     ingredientName: _methodNativeOfferName,
                    //     recipeId: _actualRecipeId ?? widget.recipeId,
                    //   ),
                    // ],
                    if (hasMemo) ...[
                      const SizedBox(height: 10),
                      _buildStepMemoBox(source!.memo),
                    ],
                  ],
                ),
              ),
          ),
        ],
      ),
    );
  }

  static const _methodInstructionStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Color(0xFF2C2A27),
    height: 1.55,
    letterSpacing: -0.3,
  );

  String _formatStepTimestamp(int startSec) {
    final m = startSec ~/ 60;
    final s = startSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // Figma 359-391: 요리법 tab
  Widget _buildRecipeTab(models.Recipe recipe, Brightness brightness) {
    // _prefetchNativeOffers();
    final steps = recipe.steps;
    final totalSteps = steps.length;
    final merged = _merged;
    // 머지된 steps[i] ↔ stepSources[i] 1:1 대응. identityMap 으로 빠르게 룩업.
    final stepSourceMap = Map<models.Step, StepSource>.identity();
    for (var i = 0; i < steps.length; i++) {
      stepSourceMap[steps[i]] = merged.stepSources[i];
    }
    int totalMinutes = 0;
    for (var s in steps) {
      if (s.estMinutes != null) totalMinutes += s.estMinutes!;
    }
    if (totalMinutes == 0) totalMinutes = 15;

    return Transform.translate(
      offset: const Offset(0, -6),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1AEA580C),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
              BoxShadow(
                color: Color(0x22EA580C),
                blurRadius: 12,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Row(
            children: [
              Icon(
                Icons.play_circle_rounded,
                size: 18,
                color: Color(0xFFEA580C),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A3728),
                      letterSpacing: -0.2,
                    ),
                    children: [
                      TextSpan(text: '단계별로 보며 요리해요 · 아래 '),
                      TextSpan(
                        text: 'Cook-Mode',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFEA580C),
                        ),
                      ),
                      TextSpan(text: '로 시작'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Summary: "총 N단계 · X분" + recipe memo action.
        Row(
          children: [
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                    letterSpacing: -0.375,
                    height: 1.5,
                  ),
                  children: [
                    TextSpan(text: '총 $totalSteps단계 '),
                    const TextSpan(
                      text: '·',
                      style: TextStyle(color: Color(0xFFD1D5DB)),
                    ),
                    TextSpan(text: ' $totalMinutes분'),
                  ],
                ),
              ),
            ),
            if (_canEditRecipeContent) ...[
              const SizedBox(width: 12),
              _buildRecipeMemoCard(merged.recipeMemo),
            ],
          ],
        ),
        const SizedBox(height: 22),

        ...steps.asMap().entries.map((entry) {
          final index = entry.key;
          final step = entry.value;
          return _buildMethodTimelineStep(
            step: step,
            index: index,
            totalSteps: totalSteps,
            recipe: recipe,
            source: stepSourceMap[step],
          );
        }),

        if (_canEditRecipeContent) ...[
          const SizedBox(height: 12),
          _buildAddStepButton(merged),
          if (merged.removedSteps.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildRemovedStepsLink(merged.removedSteps),
          ],
        ],
        const SizedBox(height: 8),
        // Report recipe button
        GestureDetector(
          onTap: () => _showRecipeReportDialog(context, recipe),
          child: Container(
            height: 49,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: Color(0xFF6B7684),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '레시피 정보 수정 요청',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B7684),
                      letterSpacing: -0.35,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Color(0xFF6B7684),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),

        // AI disclaimer
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F5F7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xFF6B7684),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '본 레시피는 AI가 영상을 분석하여 자동 생성한 내용이며, 정확도는 지속적으로 개선되고 있습니다.',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7684),
                    height: 1.5,
                    letterSpacing: -0.35,
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

  void _showRecipeReportDialog(BuildContext context, models.Recipe recipe) {
    final controller = TextEditingController();
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return AppMediaQueryMergeNavInsets(
          child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            return AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: 10,
                      bottom: 22,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '레시피 문제 보고',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111111),
                      letterSpacing: -0.45,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '잘못된 내용이나 개선할 점을 알려주세요.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF6B7684),
                      letterSpacing: -0.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    maxLines: 4,
                    maxLength: 500,
                    autofocus: false,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF111111),
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: '예: 3번 설명이 부족해요, 재료 양이 이상해요',
                      hintStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFFB4BAC4),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF4F5F7),
                      contentPadding: const EdgeInsets.all(16),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      counterStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        color: Color(0xFFB4BAC4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: isSubmitting
                          ? null
                          : () async {
                              final text = controller.text.trim();
                              if (text.isEmpty) return;
                              setSheetState(() => isSubmitting = true);
                              try {
                                await _submitRecipeReport(recipe, text);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  showAppSnackBar(context, 
                                    const SnackBar(
                                      content: Text('보고가 접수되었습니다. 감사합니다!'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              } catch (_) {
                                setSheetState(() => isSubmitting = false);
                                if (ctx.mounted) {
                                  showAppSnackBar(context, 
                                    const SnackBar(
                                      content: Text('전송에 실패했습니다. 다시 시도해주세요.'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5A00),
                        disabledBackgroundColor: const Color(0xFFFFD1BA),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '보내기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
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
          },
        ),
        );
      },
    );
  }

  Future<void> _submitRecipeReport(models.Recipe recipe, String message) async {
    final user = FirebaseAuth.instance.currentUser;
    await FirebaseFirestore.instance
        .collection('recipe_reports')
        .add({
          'recipeId': widget.recipeId ?? '',
          'recipeTitle': recipe.name,
          'message': message,
          'userId': user?.uid ?? 'anonymous',
          'createdAt': FieldValue.serverTimestamp(),
        })
        .timeout(const Duration(seconds: 8));
  }

  void _showIngredientPriceIssueSheet(
    BuildContext context,
    models.Recipe recipe,
  ) {
    final seen = <String>{};
    final uniqueNames = <String>[];
    for (final ing in recipe.ingredients) {
      final n = ing.item.trim();
      if (n.isEmpty || seen.contains(n)) continue;
      seen.add(n);
      uniqueNames.add(n);
    }

    final controller = TextEditingController();
    final selected = <String>{};
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return AppMediaQueryMergeNavInsets(
          child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            return AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: 24,
                      bottom: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    '재료 가격 문제 보고',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111111),
                      letterSpacing: -0.5,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '가격이 이상한 재료를 알려주시면 요리고가 다시 확인할게요.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6A7282),
                      letterSpacing: -0.35,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    '접수된 항목은 순차적으로 조사해 가격 정확도를 높여요.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF99A1AF),
                      letterSpacing: -0.32,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Text(
                        '문제가 있는 재료',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                          letterSpacing: -0.35,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3EA),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${selected.length}개 선택',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFF6B00),
                            letterSpacing: -0.25,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 196),
                    child: Scrollbar(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: uniqueNames.length,
                        itemBuilder: (context, i) {
                          final name = uniqueNames[i];
                          final checked = selected.contains(name);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onTap: () {
                                setSheetState(() {
                                  if (checked) {
                                    selected.remove(name);
                                  } else {
                                    selected.add(name);
                                  }
                                });
                              },
                              borderRadius: BorderRadius.circular(14),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeOutCubic,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: checked
                                      ? const Color(0xFFFFF3EA)
                                      : const Color(0xFFF7F8FA),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: checked
                                        ? const Color(0xFFFF9B63)
                                        : const Color(0xFFEDEFF2),
                                    width: checked ? 1.1 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 160,
                                      ),
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: checked
                                            ? const Color(0xFFFF6B00)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(7),
                                        border: Border.all(
                                          color: checked
                                              ? const Color(0xFFFF6B00)
                                              : const Color(0xFFD1D6DE),
                                          width: 1.8,
                                        ),
                                      ),
                                      child: checked
                                          ? const Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: Colors.white,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: checked
                                              ? const Color(0xFF111111)
                                              : const Color(0xFF2F3845),
                                          letterSpacing: -0.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    maxLines: 4,
                    maxLength: 500,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF111111),
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: '예: 양이 너무 크게 잡혔어요, 가격 단위가 이상해요',
                      hintStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFFB4BAC4),
                        height: 1.45,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF7F8FA),
                      contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFFEDEFF2),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFFEDEFF2),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFFFF9B63),
                          width: 1.2,
                        ),
                      ),
                      counterStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        color: Color(0xFFB4BAC4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: selected.isEmpty || isSubmitting
                            ? const Color(0xFFFFD1BA)
                            : const Color(0xFFFF5A00),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ElevatedButton(
                        onPressed: isSubmitting || selected.isEmpty
                            ? null
                            : () async {
                              setSheetState(() => isSubmitting = true);
                              try {
                                final recipeId =
                                    _actualRecipeId ?? widget.recipeId;
                                final ok =
                                    await ApiService.reportIngredientPriceIssue(
                                  ingredientNames: selected.toList(),
                                  message: controller.text.trim().isEmpty
                                      ? null
                                      : controller.text.trim(),
                                  recipeId: recipeId,
                                  recipeTitle: recipe.name,
                                );
                                if (!ok) {
                                  throw Exception('report failed');
                                }
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  showAppSnackBar(context, 
                                    const SnackBar(
                                      content: Text(
                                        '접수되었습니다. 순차적으로 가격을 다시 조사할게요.',
                                      ),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              } catch (_) {
                                setSheetState(() => isSubmitting = false);
                                if (ctx.mounted) {
                                  showAppSnackBar(context, 
                                    const SnackBar(
                                      content: Text(
                                        '전송에 실패했습니다. 다시 시도해 주세요.',
                                      ),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          disabledBackgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                selected.isEmpty ? '재료를 선택해 주세요' : '보내기',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                  color: selected.isEmpty
                                      ? const Color(0xB36E3A1F)
                                      : Colors.white,
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
          },
        ),
        );
      },
    );
  }

  // Build nutrition tab (layout per design: 1인분 기준, calories, total, hardcoded tags, macronutrients; Korean when locale is ko)
  Widget _buildNutritionTab(
    BuildContext context,
    models.Nutrition nutrition,
    double baseServings,
    Brightness brightness,
  ) {
    final llmEstimate = nutrition.llmEstimate;
    final caloriesPerServing = llmEstimate?.caloriesPerServing ?? 0.0;
    final carbsG = llmEstimate?.carbsG ?? 0;
    final proteinG = llmEstimate?.proteinG ?? 0;
    final fatG = llmEstimate?.fatG ?? 0;
    final sodiumMg = llmEstimate?.sodiumMg ?? 0;

    const carbColor = Color(0xFFE0A045);
    const proteinColor = Color(0xFFD06A62);
    const fatColor = Color(0xFF5AA382);
    const sodiumColor = Color(0xFF6A8CB5);

    final carbKcal = carbsG * 4;
    final proteinKcal = proteinG * 4;
    final fatKcal = fatG * 9;
    final macroKcal = carbKcal + proteinKcal + fatKcal;
    final carbShare = macroKcal > 0 ? carbKcal / macroKcal : 0.0;
    final proteinShare = macroKcal > 0 ? proteinKcal / macroKcal : 0.0;
    final fatShare = macroKcal > 0 ? fatKcal / macroKcal : 0.0;
    const refCarbsG = 130.0;
    const refProteinG = 55.0;
    const refFatG = 54.0;
    const refSodiumMg = 2000.0;

    String dailyCaption(double amount, double ref) =>
        '1일 기준치의 ${((amount / ref) * 100).round()}%';
    double dailyBar(double amount, double ref) =>
        (amount / ref).clamp(0.0, 1.0);

    final hasIngredientEdits = _merged.hasIngredientEdits;

    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0F2F4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                caloriesPerServing <= 0
                    ? '–'
                    : caloriesPerServing.toStringAsFixed(0),
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111111),
                  height: 0.95,
                  letterSpacing: -1.4,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, bottom: 4),
                child: Text(
                  'kcal · 1인분',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8B95A1),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildMacroShareBar(
            carbShare: carbShare,
            proteinShare: proteinShare,
            fatShare: fatShare,
            carbColor: carbColor,
            proteinColor: proteinColor,
            fatColor: fatColor,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _buildMacroTile(
                  label: '탄수화물',
                  value: '${carbsG.toStringAsFixed(1)}g',
                  share: dailyBar(carbsG, refCarbsG),
                  color: carbColor,
                  caption: dailyCaption(carbsG, refCarbsG),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMacroTile(
                  label: '단백질',
                  value: '${proteinG.toStringAsFixed(1)}g',
                  share: dailyBar(proteinG, refProteinG),
                  color: proteinColor,
                  caption: dailyCaption(proteinG, refProteinG),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildMacroTile(
                  label: '지방',
                  value: '${fatG.toStringAsFixed(1)}g',
                  share: dailyBar(fatG, refFatG),
                  color: fatColor,
                  caption: dailyCaption(fatG, refFatG),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMacroTile(
                  label: '나트륨',
                  value: sodiumMg >= 1000
                      ? '${(sodiumMg / 1000).toStringAsFixed(1)}g'
                      : '${sodiumMg.toStringAsFixed(0)}mg',
                  share: dailyBar(sodiumMg, refSodiumMg),
                  color: sodiumColor,
                  caption: dailyCaption(sodiumMg, refSodiumMg),
                ),
              ),
            ],
          ),
          if (llmEstimate != null &&
              (llmEstimate.fiberG > 0 || llmEstimate.sugarG > 0)) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                if (llmEstimate.fiberG > 0)
                  _buildQuietStat('식이섬유', '${llmEstimate.fiberG.toStringAsFixed(1)}g'),
                if (llmEstimate.fiberG > 0 && llmEstimate.sugarG > 0)
                  const SizedBox(width: 16),
                if (llmEstimate.sugarG > 0)
                  _buildQuietStat('당류', '${llmEstimate.sugarG.toStringAsFixed(1)}g'),
              ],
            ),
          ],
        ],
      ),
    );

    if (!hasIngredientEdits) return card;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: Color(0xFF8B95A1),
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '영양정보는 원본 레시피 기준입니다.',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF8B95A1),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        card,
      ],
    );
  }

  Widget _buildMacroShareBar({
    required double carbShare,
    required double proteinShare,
    required double fatShare,
    required Color carbColor,
    required Color proteinColor,
    required Color fatColor,
  }) {
    final hasData = carbShare + proteinShare + fatShare > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 5,
        child: Row(
          children: hasData
              ? [
                  if (carbShare > 0)
                    Expanded(
                      flex: (carbShare * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: carbColor),
                    ),
                  if (proteinShare > 0)
                    Expanded(
                      flex: (proteinShare * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: proteinColor),
                    ),
                  if (fatShare > 0)
                    Expanded(
                      flex: (fatShare * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: fatColor),
                    ),
                ]
              : const [
                  Expanded(child: ColoredBox(color: Color(0xFFEEF0F3))),
                ],
        ),
      ),
    );
  }

  Widget _buildMacroTile({
    required String label,
    required String value,
    required double share,
    required Color color,
    String? caption,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8B95A1),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111111),
              letterSpacing: -0.35,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: const Color(0xFFE8EAED),
              color: color,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9CA3AF),
                letterSpacing: -0.15,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuietStat(String label, String value) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 12.5,
          letterSpacing: -0.2,
        ),
        children: [
          TextSpan(
            text: '$label  ',
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              color: Color(0xFF8B95A1),
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF4B5563),
            ),
          ),
        ],
      ),
    );
  }

  // Update categories in Firestore
  Future<void> _loadUserCategories() async {
    if (widget.recipeId == null) return;

    try {
      final userCategories = await _recipeService.getUserRecipeCategories(
        widget.recipeId!,
      );
      if (userCategories != null && mounted) {
        setState(() {
          _categories = userCategories;
        });
      }
    } catch (e) {
      print('[RecipeDetailScreen] Error loading user categories: $e');
    }
  }

  // Helper methods for tag colors (less primary, slightly more vibrant, liquid-friendly)
  Color _getTagColor(String tag) {
    if (_isChefTag(tag)) return const Color(0xFFEFE7FF);
    switch (tag) {
      case '단백한':
        return const Color(0xFFF8D7DA);
      case '자극적인':
        return const Color(0xFFFFE4C4);
      case '단짠단짠':
        return const Color(0xFFFFF0DB);
      case '매콤한':
      case '얼큰한':
      case '달달한':
        return const Color(0xFFFADBD8);
      case '진한맛':
        return const Color(0xFFFFE9D6);
      case '담백한':
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFFD6EAF8);
      case '고소한':
        return const Color(0xFFFFF3E0);
      case '꾸덕한':
        return const Color(0xFFFFECDE);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFFEAF2FF);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
        return const Color(0xFFD5F5E3);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFF4E8);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFF8DC);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFF0ECFF);
      case '바삭한':
        return const Color(0xFFFFF3E0);
      case '쫄깃한':
        return const Color(0xFFFADBD8);
      case '전통':
        return const Color(0xFFE8DAEF);
      case '간편식':
        return const Color(0xFFD6EAF8);
      case '비건':
      case '베지터리언':
        return const Color(0xFFD5F5E3);
      default:
        return const Color(0xFFEAEDED);
    }
  }

  Color _getTagBorderColor(String tag) {
    if (_isChefTag(tag)) return const Color(0xFFB39DDB);
    switch (tag) {
      case '단백한':
        return const Color(0xFFE8B4B8);
      case '자극적인':
        return const Color(0xFFDEB887);
      case '단짠단짠':
        return const Color(0xFFE8D4B8);
      case '매콤한':
      case '얼큰한':
      case '달달한':
        return const Color(0xFFE8B4B8);
      case '진한맛':
        return const Color(0xFFE8C39A);
      case '담백한':
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFFAED6F1);
      case '고소한':
        return const Color(0xFFE8D4B8);
      case '꾸덕한':
        return const Color(0xFFFFBE8A);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFF9CB5FF);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
        return const Color(0xFFABEBC6);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFC999);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFDD66);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFB6A6F6);
      case '바삭한':
        return const Color(0xFFE8D4B8);
      case '쫄깃한':
        return const Color(0xFFE8B4BC);
      case '전통':
        return const Color(0xFFD2B4DE);
      case '간편식':
        return const Color(0xFFAED6F1);
      case '비건':
      case '베지터리언':
        return const Color(0xFFABEBC6);
      default:
        final brightness = Theme.of(context).brightness;
        return AppColors.getBorder(brightness);
    }
  }

  Color _getTagTextColor(String tag) {
    if (_isChefTag(tag)) return const Color(0xFF4527A0);
    switch (tag) {
      case '단백한':
      case '자극적인':
      case '단짠단짠':
      case '매콤한':
      case '고소한':
      case '얼큰한':
      case '달달한':
      case '진한맛':
      case '바삭한':
      case '쫄깃한':
      case '꾸덕한':
        return const Color(0xFF6E2C00);
      case '담백한':
      case '간편식':
      case '깔끔한':
      case '속편한':
      case '순한':
      case '촉촉한':
      case '부들부들':
        return const Color(0xFF1A5276);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
      case '비건':
      case '베지터리언':
        return const Color(0xFF186A3B);
      case '전통':
        return const Color(0xFF4A235A);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFF9A4D00);
      case '초간편':
      case '10분컷':
        return const Color(0xFF8A6D00);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFF5E35B1);
      default:
        final brightness = Theme.of(context).brightness;
        return AppColors.getTextPrimary(brightness);
    }
  }
}

class _FlatBookmarkPainter extends CustomPainter {
  const _FlatBookmarkPainter({this.color, this.gradient});

  final Color? color;
  final Gradient? gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      // 윗단은 완전히 플랫하게: 아이콘 폰트 대신 직접 그린 shape.
      ..moveTo(size.width * 0.22, size.height * 0.06)
      ..lineTo(size.width * 0.78, size.height * 0.06)
      ..lineTo(size.width * 0.78, size.height * 0.92)
      ..lineTo(size.width * 0.50, size.height * 0.70)
      ..lineTo(size.width * 0.22, size.height * 0.92)
      ..close();

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final fillGradient = gradient;
    if (fillGradient != null) {
      paint.shader = fillGradient.createShader(Offset.zero & size);
    } else {
      paint.color = color ?? const Color(0xFF8C8C8C);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FlatBookmarkPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.gradient != gradient;
  }
}

/// 삭제된 항목 1건의 데이터 (재료/스텝 공용).
class _RemovedItem {
  _RemovedItem({required this.label, required this.restoreLabel});
  final String label;
  final String restoreLabel;
}

/// 삭제된 항목 리스트를 표시하고 개별 복원 가능한 바텀시트.
class _RemovedItemsSheet extends StatelessWidget {
  const _RemovedItemsSheet({
    required this.title,
    required this.items,
    required this.onRestore,
  });

  final String title;
  final List<_RemovedItem> items;
  final Future<void> Function(int index) onRestore;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E8EB),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.4,
                        color: Color(0xFF191F28),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F4F6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(0xFF8B95A1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFF0F2F5),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.label,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6B7280),
                              letterSpacing: -0.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: () async {
                            await onRestore(i);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFFFFF3EC),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            item.restoreLabel,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFEA580C),
                              letterSpacing: -0.3,
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
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(0, size.height / 2)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BubbleTailUpPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BubbleTailDownPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CutoutOverlayPainter extends CustomPainter {
  _CutoutOverlayPainter({
    required this.center,
    required this.radius,
    required this.overlayColor,
  });

  final Offset center;
  final double radius;
  final Color overlayColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = overlayColor;
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CutoutOverlayPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.overlayColor != overlayColor;
  }
}

/// Delegate for pinned tab bar in recipe detail.
class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverTabBarDelegate({required this.child, required this.height});
  final Widget child;
  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(height: height, child: child);
  }

  @override
  bool shouldRebuild(covariant _SliverTabBarDelegate oldDelegate) => true;
}

/// Wraps a tab content child and reports its measured height after layout.
class _TabContentOverflowTopClipper extends CustomClipper<Rect> {
  const _TabContentOverflowTopClipper(this.extraTop);

  final double extraTop;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, -extraTop, size.width, size.height + extraTop);
  }

  @override
  bool shouldReclip(covariant _TabContentOverflowTopClipper old) =>
      extraTop != old.extraTop;
}

class _TabContentPage extends StatefulWidget {
  final int index;
  final Widget child;
  final ValueChanged<double> onHeightMeasured;

  const _TabContentPage({
    required this.index,
    required this.child,
    required this.onHeightMeasured,
  });

  @override
  State<_TabContentPage> createState() => _TabContentPageState();
}

class _TabContentPageState extends State<_TabContentPage> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _measureAfterLayout();
  }

  @override
  void didUpdateWidget(covariant _TabContentPage old) {
    super.didUpdateWidget(old);
    _measureAfterLayout();
  }

  void _measureAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        widget.onHeightMeasured(box.size.height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _measureAfterLayout();
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          clipBehavior: Clip.none,
          child: Container(
            key: _key,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// PageScrollPhysics with a lower velocity threshold so pages snap with
/// a shorter / lighter swipe gesture (~20% less effort than default).
class _SnappierPagePhysics extends PageScrollPhysics {
  const _SnappierPagePhysics({super.parent});

  @override
  _SnappierPagePhysics applyTo(ScrollPhysics? ancestor) {
    return _SnappierPagePhysics(parent: buildParent(ancestor));
  }

  @override
  double get minFlingVelocity => super.minFlingVelocity * 0.4;

  @override
  double get minFlingDistance => super.minFlingDistance * 0.4;
}

enum _RecipeFrostedAccent { ice, orange, cocoa, green }

class _RecipeFrostedActionPill extends StatefulWidget {
  const _RecipeFrostedActionPill({
    super.key,
    required this.title,
    required this.onTap,
    this.titleWidget,
    this.subtitle,
    this.compact = false,
    this.accent = _RecipeFrostedAccent.ice,
    this.animate = true,
  });

  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final VoidCallback onTap;
  final bool compact;
  final _RecipeFrostedAccent accent;
  final bool animate;

  @override
  State<_RecipeFrostedActionPill> createState() =>
      _RecipeFrostedActionPillState();
}

class _RecipeFrostedActionPillState extends State<_RecipeFrostedActionPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shineController;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _syncShineAnimation();
  }

  @override
  void didUpdateWidget(_RecipeFrostedActionPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncShineAnimation();
  }

  void _syncShineAnimation() {
    if (widget.animate) {
      if (!_shineController.isAnimating) {
        _shineController.repeat();
      }
    } else if (_shineController.isAnimating) {
      _shineController
        ..stop()
        ..value = 0;
    }
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
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedBuilder(
            animation: _shineController,
            builder: (context, child) {
              final shineT = widget.animate ? _shineController.value : 0.0;
              final isOrange = widget.accent == _RecipeFrostedAccent.orange;
              final isCocoa = widget.accent == _RecipeFrostedAccent.cocoa;
              final isGreen = widget.accent == _RecipeFrostedAccent.green;
              final borderColor = isOrange
                  ? const Color(0xFFFFA058)
                  : isGreen
                  ? const Color(0xFFC8E86A)
                  : isCocoa
                  ? const Color(0xFFD9C4A8)
                  : const Color(0xFF7EC8FF);
              final shadowColor = isOrange
                  ? const Color(0xFFFF5A00)
                  : isGreen
                  ? const Color(0xFF5CB030)
                  : isCocoa
                  ? const Color(0xFF5C4033)
                  : const Color(0xFF1A7FE8);
              final fillColors = isOrange
                  ? const [
                      Color(0xFFEE5200),
                      Color(0xFFFF6B00),
                      Color(0xFFFF9A38),
                      Color(0xFFFFCFA0),
                    ]
                  : isGreen
                  ? const [
                      Color(0xFF3D9B2E),
                      Color(0xFF6BBF3A),
                      Color(0xFFB4E04A),
                      Color(0xFFE8F7B0),
                    ]
                  : isCocoa
                  ? const [
                      Color(0xFF3D2B1F),
                      Color(0xFF6B4A38),
                      Color(0xFFC4A484),
                      Color(0xFFF3E6D8),
                    ]
                  : const [
                      Color(0xFF2F8FFF),
                      Color(0xFF5BB8FF),
                      Color(0xFF93D4FF),
                      Color(0xFFC9EBFF),
                    ];
              final glazeTail = isOrange
                  ? const Color(0xFFFFC890)
                  : isGreen
                  ? const Color(0xFFDCF5A0)
                  : isCocoa
                  ? const Color(0xFFE8D5C0)
                  : const Color(0xFFB8E8FF);
              final lipColor = isOrange
                  ? const Color(0xFFD85000)
                  : isGreen
                  ? const Color(0xFF3D9B2E)
                  : isCocoa
                  ? const Color(0xFF5C4033)
                  : const Color(0xFF1E7AE0);
              return AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOutCubic,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: borderColor,
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor
                          .withValues(alpha: _pressed ? 0.22 : 0.36),
                      blurRadius: _pressed ? 8 : 16,
                      offset: Offset(0, _pressed ? 2 : 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  clipBehavior: Clip.antiAlias,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: fillColors,
                        stops: const [0.0, 0.30, 0.66, 1.0],
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
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
                                      glazeTail.withValues(alpha: 0.22),
                                    ],
                                    stops: const [0.0, 0.48, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.0),
                                    lipColor.withValues(alpha: 0.10),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.animate)
                          Positioned.fill(
                            child: LayoutBuilder(
                            builder: (context, constraints) {
                              final w = constraints.maxWidth;
                              final halfTravel = w / 2 + 16;
                              return IgnorePointer(
                                child: ClipRect(
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Transform.translate(
                                        offset: Offset(
                                          -halfTravel + 2 * halfTravel * shineT,
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
                        Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: widget.compact ? 12 : 16,
                            ),
                            child: Center(child: child),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  widget.titleWidget ??
                  Text(
                    widget.title,
                    maxLines: 1,
                    softWrap: false,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: widget.compact ? 13 : 14,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFF191F28),
                      letterSpacing: -0.35,
                      height: 1.1,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle!,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: widget.compact ? 9 : 10,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF191F28),
                        letterSpacing: -0.15,
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MarketplacePurchaseTitle extends StatelessWidget {
  const _MarketplacePurchaseTitle();

  static const _labelStyle = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 14,
    fontWeight: FontWeight.w900,
    color: Color(0xFF191F28),
    letterSpacing: -0.35,
    height: 1.1,
  );

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _MarketplaceAppIcon(
          assetPath: 'assets/marketplace/coupang_app_icon.png',
        ),
        SizedBox(width: 4),
        _MarketplaceAppIcon(
          assetPath: 'assets/marketplace/kurly_app_icon.png',
        ),
        SizedBox(width: 9),
        Text('재료 구매하기', style: _labelStyle),
      ],
    );
  }
}

class _MarketplaceAppIcon extends StatelessWidget {
  const _MarketplaceAppIcon({required this.assetPath});

  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.asset(
          assetPath,
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class _ReviewCarouselSkeletonCard extends StatelessWidget {
  const _ReviewCarouselSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: (MediaQuery.sizeOf(context).width * 0.72).clamp(240.0, 300.0),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

class _ReviewEmptyState extends StatelessWidget {
  const _ReviewEmptyState({
    required this.failed,
    required this.onTap,
  });

  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F6F3),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed ? '후기를 불러오지 못했어요' : '아직 꿀팁이 없어요',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111111),
                      letterSpacing: -0.28,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failed ? '잠시 후 다시 시도해 주세요' : '만들어본 사람만 아는 꿀팁이 궁금해요',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF8B95A1),
                      letterSpacing: -0.15,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFE6E3DC)),
              ),
              child: Text(
                failed ? '다시 시도' : '후기 남기기',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2C2A27),
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
