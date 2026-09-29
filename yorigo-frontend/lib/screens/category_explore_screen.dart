// =============================================================================
// CATEGORY EXPLORE (TEMP TAB) — Figma 97-1333
// Same header as 커뮤니티 tab (AppHeader) so this can replace it later.
// Sections are attribute-based (trending, quick, 건강식, 단백질 많은, etc.).
// =============================================================================

import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../widgets/guest_locked_preview_backdrop.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/recipe_card_social_row.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';
import '../widgets/comment_modal.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/review_post_action_sheets.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/pick_recipe_for_review_sheet.dart';
import '../widgets/recipe_search_text_field.dart';
import '../widgets/yorigo_header_logo.dart';
import '../widgets/home_style_recipe_card.dart';
import '../widgets/user_initial_avatar.dart';
import '../widgets/recipe_bookmark_glyph.dart';
import '../widgets/feed_like_heart.dart';
import '../widgets/community_feed_shimmer.dart';
import '../widgets/community_leaderboard_tab.dart';
import '../widgets/feed_post_card.dart' show ExpandableComment;
import '../widgets/recipe_signal_impression.dart';
import '../models/board_post.dart';
import '../services/board_service.dart';
import 'board_compose_screen.dart';
import 'board_post_detail_screen.dart';
// 모임·챌린지 탭: 배포 전까지 숨김.
// import 'meetup_tab.dart';
import 'meetup_compose_screen.dart';
import 'meetup_detail_screen.dart';
// import 'challenge_tab.dart';
import 'challenge_detail_screen.dart';
import 'friend_challenge_compose_screen.dart';
import '../services/meetup_service.dart';
import '../services/challenge_service.dart';
import '../constants/home_section_keys.dart';
import '../services/admin_service.dart';
import '../services/analytics_service.dart';
import '../services/background_parsing_service.dart';
import '../services/recipe_service.dart';
import '../services/report_service.dart';
import '../services/review_service.dart';
import '../services/user_service.dart';
import '../utils/bounded_recipe_list.dart';
import '../utils/recipe_search_match.dart';
import '../utils/nav_guard.dart';
import 'home_screen.dart' show TrendingAllPage;
import '../utils/haptics.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/yorigo_level.dart';
import '../utils/review_cooked_label.dart';
import '../utils/review_display_date.dart';
import 'recipe_detail_screen.dart';

const Color _orange = Color(0xFFFF6B00);
const Color _border = Color(0xFFF3F4F6);
const double _cardWidth = 140;

/// Custom feed icon with color tinting (changes color when active/clicked).
Widget _feedIcon(String asset, {required Color color, required double size}) {
  return ColorFiltered(
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    child: Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.help_outline, size: size, color: color),
    ),
  );
}



/// Gray overlay with heart icon when post is liked.
class _LikeOverlay extends StatefulWidget {
  const _LikeOverlay({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_LikeOverlay> createState() => _LikeOverlayState();
}

class _LikeOverlayState extends State<_LikeOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 25),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.linear));
    _scale = Tween<double>(begin: 0.3, end: 1.15).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.35, curve: Curves.elasticOut),
      ),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Container(
            color: Colors.black.withValues(alpha: 0.25 * _opacity.value),
            child: Opacity(
              opacity: _opacity.value,
              child: Center(
                child: Transform.scale(
                  scale: _scale.value,
                  child: const Icon(
                    Icons.favorite,
                    color: Colors.red,
                    size: 64,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

const double _cardImageHeight = 175;
const double _cardRadius = 18;
const double _sectionPaddingH = 20;

/// Top padding above the trend search bar in the category grid’s first row.
const double _trendSearchBarTopPadding = 0;

/// Space from search row bottom to first category (8px tighter than tab-to-search).
const double _trendSearchBarToFirstSectionGap = 12;
const double _cardGap = 12;

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
    return BoxFit.cover;
  }
  return BoxFit.cover;
}

/// Monthly seasonal ingredients (Korean 제철 재료).
/// Each month maps to a list of (keyword, display label) pairs.
/// Keywords are matched against recipe ingredient item names.
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

/// Returns recipes whose title contains at least one seasonal keyword for [month],
/// along with the matched seasonal ingredient label.
List<(Map<String, dynamic> recipe, String seasonalLabel)>
_filterSeasonalRecipes(List<Map<String, dynamic>> recipes, int month) {
  final seasonalItems = _seasonalIngredients[month] ?? [];
  if (seasonalItems.isEmpty) return [];

  final result = <(Map<String, dynamic>, String)>[];
  final seen = <String>{};

  for (final recipe in recipes) {
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

  result.sort((a, b) => b.$1['id'].toString().compareTo(a.$1['id'].toString()));
  return result;
}

/// Section config: trending/quick or attribute-based (calories, protein).
class _SectionConfig {
  const _SectionConfig({
    required this.subtitle,
    required this.title,
    this.timeMaxMinutes,
    this.caloriesMax,
    this.proteinMin,
  });
  final String subtitle;
  final String title;
  final int? timeMaxMinutes;
  final int? caloriesMax;
  final int? proteinMin;
}

class CategoryExploreScreen extends StatefulWidget {
  const CategoryExploreScreen({super.key});

  static final ValueNotifier<String?> _openReviewIdNotifier =
      ValueNotifier<String?>(null);
  static final ValueNotifier<bool> _activateSearchNotifier =
      ValueNotifier<bool>(false);
  static final ValueNotifier<int> _showTrendingTabNotifier = ValueNotifier<int>(
    0,
  );
  static final ValueNotifier<int> _openTrendingPageNotifier =
      ValueNotifier<int>(0);
  /// MainNavigator 하단 탭 index 1(탐색) 활성 여부 — false면 피드 fetch 지연.
  static final ValueNotifier<bool> _mainTabSelectedNotifier =
      ValueNotifier<bool>(false);

  static void setMainTabSelected(bool selected) {
    if (_mainTabSelectedNotifier.value == selected) return;
    _mainTabSelectedNotifier.value = selected;
  }

  static void notifyOpenReview(String reviewId) {
    _openReviewIdNotifier.value = reviewId;
  }

  static void notifyActivateSearch() {
    _activateSearchNotifier.value = true;
  }

  /// Force the screen to surface the 트렌드 (popular recipes) sub-tab — used
  /// by external entry points like the empty cart "레시피 둘러보기" CTA.
  static void notifyShowTrending() {
    _showTrendingTabNotifier.value = _showTrendingTabNotifier.value + 1;
  }

  /// Push the dedicated 인기 레시피 page (TrendingAllPage) directly. Reuses
  /// the recipes already loaded in this screen so it opens immediately.
  static void notifyOpenTrendingPage() {
    _openTrendingPageNotifier.value = _openTrendingPageNotifier.value + 1;
  }

  static final ValueNotifier<String?> _openMeetupIdNotifier =
      ValueNotifier<String?>(null);
  static final ValueNotifier<String?> _openChallengeIdNotifier =
      ValueNotifier<String?>(null);

  static void notifyOpenMeetup(String meetupId) {
    if (meetupId.isEmpty) return;
    _openMeetupIdNotifier.value = meetupId;
  }

  static void notifyOpenChallenge(String challengeId) {
    if (challengeId.isEmpty) return;
    _openChallengeIdNotifier.value = challengeId;
  }

  @override
  State<CategoryExploreScreen> createState() => _CategoryExploreScreenState();
}

// Figma 97-1934: tab bar — active = black text + orange underline, inactive = gray
const Color _tabOrange = Color(0xFFFF6B00);
const Color _tabActiveText = Color(0xFF101828);
const Color _tabInactiveText = Color(0xFF99A1AF);

/// Rotating search hints (트렌드 tab): one opaque line at a time.
const List<String> _trendSearchSuggestions = [
  '김치찌개',
  '된장찌개',
  '계란말이',
  '크림파스타',
  '양파',
  '마늘',
  '두부',
  '브로콜리',
];

const TextStyle _trendSearchOpaqueHint = TextStyle(
  fontFamily: 'Pretendard',
  color: Color(0xFF6B7280),
  fontSize: 13,
  fontWeight: FontWeight.w500,
);

/// Figma 514:330 shell + rotating hints (4s) when not in “browse all” mode.
class _TrendSearchBar extends StatefulWidget {
  const _TrendSearchBar({
    required this.controller,
    required this.focusNode,
    required this.browseAll,
    required this.onActivateBrowse,
    this.leading,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool browseAll;
  final VoidCallback onActivateBrowse;

  /// When non-null, replaces GO logo (e.g. back while browsing all).
  final Widget? leading;

  @override
  State<_TrendSearchBar> createState() => _TrendSearchBarState();
}

class _TrendSearchBarState extends State<_TrendSearchBar>
    with TickerProviderStateMixin {
  static final Color _kSuggestionEnd = const Color(
    0xFF9CA3AF,
  ).withValues(alpha: 0.72);

  int _suggestionIndex = 0;
  Timer? _timer;

  /// 0 idle, 1 fade out (grey→white), 2 fade in (white→grey).
  int _animStep = 0;

  late final AnimationController _fadeOut;
  late final AnimationController _fadeIn;

  @override
  void initState() {
    super.initState();
    _fadeOut = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _fadeIn = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    widget.focusNode.addListener(_onFocusOrTextChanged);
    widget.controller.addListener(_onFocusOrTextChanged);
    _restartRotationTimer();
  }

  @override
  void didUpdateWidget(covariant _TrendSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.browseAll != widget.browseAll) {
      _restartRotationTimer();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onFocusOrTextChanged);
      widget.controller.addListener(_onFocusOrTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusOrTextChanged);
      widget.focusNode.addListener(_onFocusOrTextChanged);
    }
  }

  void _onFocusOrTextChanged() {
    _restartRotationTimer();
  }

  void _restartRotationTimer() {
    _timer?.cancel();
    _timer = null;
    _fadeOut.stop();
    _fadeIn.stop();
    _fadeOut.reset();
    _fadeIn.reset();
    _animStep = 0;
    if (mounted) setState(() {});

    if (widget.browseAll) return;
    if (widget.focusNode.hasFocus || widget.controller.text.isNotEmpty) return;
    _timer = Timer.periodic(const Duration(milliseconds: 4300), (_) {
      _onRotationTick();
    });
  }

  void _onRotationTick() {
    if (!mounted) return;
    if (widget.browseAll) return;
    if (widget.focusNode.hasFocus || widget.controller.text.isNotEmpty) return;
    if (_animStep != 0) return;
    _startFadeSequence();
  }

  void _startFadeSequence() {
    setState(() => _animStep = 1);
    _fadeOut.forward(from: 0).then((_) async {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() {
        _suggestionIndex =
            (_suggestionIndex + 1) % _trendSearchSuggestions.length;
        _animStep = 2;
      });
      _fadeOut.reset();
      await _fadeIn.forward(from: 0);
      if (!mounted) return;
      setState(() => _animStep = 0);
      _fadeIn.reset();
    });
  }

  Color _suggestionColor() {
    if (_animStep == 1) {
      final t = Curves.easeInOut.transform(_fadeOut.value);
      return Color.lerp(_kSuggestionEnd, Colors.white, t)!;
    }
    if (_animStep == 2) {
      final t = Curves.easeInOut.transform(_fadeIn.value);
      return Color.lerp(Colors.white, _kSuggestionEnd, t)!;
    }
    return _kSuggestionEnd;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fadeOut.dispose();
    _fadeIn.dispose();
    widget.focusNode.removeListener(_onFocusOrTextChanged);
    widget.controller.removeListener(_onFocusOrTextChanged);
    super.dispose();
  }

  Widget _buildSuggestionBubble() {
    return AnimatedBuilder(
      animation: Listenable.merge([_fadeOut, _fadeIn]),
      builder: (context, _) {
        return Text(
          _trendSearchSuggestions[_suggestionIndex],
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: _suggestionColor(),
            height: 1.15,
            letterSpacing: -0.15,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final showBubble =
        !widget.browseAll &&
        !widget.focusNode.hasFocus &&
        widget.controller.text.isEmpty;
    return RecipeSearchTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: widget.browseAll ? '레시피, 셰프, 재료 검색' : '관심 있는 레시피나 셰프를 찾아보세요',
      hintStyle: widget.browseAll ? null : _trendSearchOpaqueHint,
      centerOverlay: showBubble ? _buildSuggestionBubble() : null,
      leading: widget.leading,
      textInputAction: TextInputAction.search,
      onTap: () {
        widget.onActivateBrowse();
        widget.focusNode.requestFocus();
      },
    );
  }
}

class _CategoryExploreScreenState extends State<CategoryExploreScreen> {
  final RecipeService _recipeService = RecipeService.shared;
  final ReviewService _reviewService = ReviewService();
  final ReportService _reportService = ReportService();
  final UserService _userService = UserService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  StreamSubscription<User?>? _authSub;

  int _selectedTopTab = 0; // Community opens directly to the feed.
  /// 커뮤니티 상단 탭바. 아래로 스크롤하면 숨기고, 위로 올리면 다시 보인다.
  bool _communityTabBarVisible = true;
  double _communityScrollPixels = 0;
  bool _communityTabBarAnimating = false;
  Duration _communityTabBarDuration = _kCommunityTabBarShowDuration;
  Curve _communityTabBarCurve = _kCommunityTabBarShowCurve;
  BoardCategory _selectedBoardCategory = BoardCategory.all;
  final BoardService _boardService = BoardService();
  /// 게시판 글 목록. 상세에서 좋아요·댓글이 바뀌면 목록 숫자도 바로 맞춰진다.
  StreamSubscription<List<BoardPost>>? _boardPostsSub;
  List<BoardPost>? _boardPostsCache;
  bool _boardPostsLoading = true;
  String? _boardPostsError;
  /// null = 아직 로드 전, 빈 Set = 로드됐지만 팔로잉 없음.
  /// 피드 칩만 [ValueListenableBuilder]로 구독해 전체 피드 리빌드를 막는다.
  final ValueNotifier<Set<String>?> _followingUserIdsNotifier =
      ValueNotifier<Set<String>?>(null);
  List<Map<String, dynamic>> _followingUsers = [];
  bool _followingLoading = false;
  // Sort is always 최신순 (newest first); 인기순 toggle removed.

  // Feed tab: same data as community screen (reviews from DB)
  List<Map<String, dynamic>> _feedReviews = [];
  Map<String, Map<String, dynamic>> _feedUserDataCache = {};
  /// 탭/위젯이 다시 만들어져도 닉네임 깜빡임을 줄이기 위한 세션 캐시.
  static final Map<String, Map<String, dynamic>> _sessionFeedUserCache = {};
  Map<String, bool> _feedLikedStatus = {};
  Map<String, int> _feedLikeCounts = {};
  Map<String, int> _feedCommentCounts = {};
  Map<String, bool> _feedBookmarkedStatus = {};
  Map<String, List<String>> _feedRecipeTagsCache =
      {}; // recipeId -> descriptor tags for recipe card chips
  Map<String, double?> _feedRecipeAverageRating =
      {}; // recipeId -> average rating (all reviews)
  Map<String, int> _feedRecipeReviewCount =
      {}; // recipeId -> total review count
  Set<String> _feedBlockedUserIds = <String>{};
  Set<String> _feedSavedRecipeIds = <String>{};
  bool _feedLoading = false;
  bool _feedLoadingMore = false;
  bool _feedHasMore = true;
  DocumentSnapshot? _feedLastCursor;
  bool _feedBootstrapped = false;
  bool _isAdmin = false;
  String? _feedLikingReviewId;
  int _feedLoadSeq = 0;
  final ScrollController _feedScrollController = ScrollController();
  final ScrollController _followingScrollController = ScrollController();
  final ScrollController _boardScrollController = ScrollController();
  final ScrollController _leaderboardScrollController = ScrollController();
  final ScrollController _meetupScrollController = ScrollController();
  final ScrollController _challengeScrollController = ScrollController();
  final ScrollController _communityTabBarScrollController = ScrollController();
  bool _communityFabCollapsed = false;
  final Map<String, GlobalKey> _reviewKeys = {};

  /// Cached future for 트렌드 tab (same data source for logged-in/guest).
  Future<List<Map<String, dynamic>>>? _cachedExploreFuture;

  /// Bump when explore query wiring changes so we don't reuse a stale Future (e.g. empty []).
  static const int _kExploreQueryCacheGeneration = 2;
  int _exploreQueryCacheGenerationSeen = 0;

  void _syncExploreCacheGeneration() {
    if (_exploreQueryCacheGenerationSeen != _kExploreQueryCacheGeneration) {
      _cachedExploreFuture = null;
      _exploreQueryCacheGenerationSeen = _kExploreQueryCacheGeneration;
    }
  }

  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();
  final TextEditingController _trendSearchController = TextEditingController();
  final FocusNode _trendSearchFocus = FocusNode();
  bool _trendBrowseAllRecipes = false;
  String _trendSearchQuery = '';

  final ScrollController _browseScrollController = ScrollController();
  final List<Map<String, dynamic>> _browseRecipes = [];
  DocumentSnapshot? _browseLastCursor;
  bool _browseHasMore = true;
  bool _browseInitialLoading = false;
  bool _browseLoadingMore = false;
  String? _browseError;
  Timer? _browseSearchDebounce;

  static const int _kFeedPageSize = 10;
  /// 10개 중 7번째(index 6) → remainingAhead == 3 일 때 다음 페이지 prefetch.
  static const int _kFeedPrefetchRemaining = 3;
  static const int _kFeedMaxInMemory = 200;

  static const int _kBrowseShowAfterCount = 10;
  static const int _kBrowseInitialPrefetch = 40;
  static const int _kBrowseRawBatch = 30;
  /// 탐색 탭 초기 bulk load 상한. 더 필요하면 스크롤 시 페이지 fetch.
  static const int _kExploreGuestListLimit = 100;
  /// 스크롤 페이지네이션으로 쌓이는 in-memory 목록 상한 (앞쪽 trim).
  static const int _kBrowseRecipesMaxInMemory = 200;

  static const List<_SectionConfig> _sections = [
    _SectionConfig(subtitle: 'Trending Now', title: '지금 뜨는 레시피'),
    _SectionConfig(subtitle: 'Quick', title: '10분 완성 레시피', timeMaxMinutes: 10),
    _SectionConfig(subtitle: 'Healthy', title: '건강식', caloriesMax: 450),
    _SectionConfig(subtitle: 'High protein', title: '단백질 많은', proteinMin: 15),
  ];

  bool get _isGuestUser => _auth.currentUser == null;
  // ignore: unused_field
  bool _guestFeedTermsAccepted = false;
  bool get _canAccessFeed => true;

  // Hot & New 인기 레시피 carousel
  final List<Map<String, dynamic>> _hotNewRecipes = [];
  final ScrollController _hotNewScrollController = ScrollController();
  DocumentSnapshot? _hotNewLastCursor;
  bool _hotNewHasMore = true;
  bool _hotNewLoading = true;
  bool _hotNewLoadingMore = false;

  // 핫한 레시피 (recipe_groups) — 같은 기본 요리명으로 묶인 그룹 carousel
  List<Map<String, dynamic>> _hotGroups = [];
  final ScrollController _hotGroupsScrollController = ScrollController();
  bool _hotGroupsLoading = true;

  @override
  void initState() {
    super.initState();
    CategoryExploreScreen._openReviewIdNotifier.addListener(
      _onExternalOpenReview,
    );
    CategoryExploreScreen._activateSearchNotifier.addListener(
      _onExternalActivateSearch,
    );
    CategoryExploreScreen._showTrendingTabNotifier.addListener(
      _onExternalShowTrending,
    );
    CategoryExploreScreen._openTrendingPageNotifier.addListener(
      _onExternalOpenTrendingPage,
    );
    CategoryExploreScreen._mainTabSelectedNotifier.addListener(
      _onMainTabSelectionChanged,
    );
    CategoryExploreScreen._openMeetupIdNotifier.addListener(_onExternalOpenMeetup);
    CategoryExploreScreen._openChallengeIdNotifier.addListener(
      _onExternalOpenChallenge,
    );
    _trendSearchController.addListener(_onTrendSearchChanged);
    _browseScrollController.addListener(_onBrowseScroll);
    _feedScrollController.addListener(_onFeedScrollForFab);
    _followingScrollController.addListener(_onFollowingScrollForFab);
    _authSub = _auth.authStateChanges().listen((_) {
      if (mounted) setState(() {});
      if (_auth.currentUser != null) {
        _bootstrapFeedIfNeeded();
      }
    });
    _loadAdminStatus();
    _bootstrapFeedIfNeeded();
    _refreshBoardPosts();
  }

  /// IndexedStack에서 탐색 탭이 선택됐을 때만 피드·팔로잉 데이터를 로드한다.
  void _onMainTabSelectionChanged() {
    _bootstrapFeedIfNeeded();
  }

  void _bootstrapFeedIfNeeded() {
    if (_feedBootstrapped) return;
    if (!_canAccessFeed) {
      if (mounted) {
        setState(() {
          _feedReviews = [];
          _feedLoading = false;
        });
      }
      return;
    }
    if (_auth.currentUser == null) {
      if (mounted) {
        setState(() => _feedLoading = false);
      }
      return;
    }
    if (!CategoryExploreScreen._mainTabSelectedNotifier.value) return;

    _feedBootstrapped = true;
    _loadFeedReviews();
    unawaited(_loadFollowingUserIds());
  }

  void _refreshBoardPosts() {
    _boardPostsSub?.cancel();
    _boardPostsLoading = _boardPostsCache == null;
    _boardPostsError = null;
    _boardPostsSub = _boardService
        .watchPosts(categoryId: _selectedBoardCategory.id)
        .listen(
          (posts) {
            if (!mounted) return;
            setState(() {
              _boardPostsCache = posts;
              _boardPostsLoading = false;
              _boardPostsError = null;
            });
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _boardPostsError = error.toString();
              _boardPostsLoading = false;
            });
            unawaited(_fetchBoardPostsFallback());
          },
        );
  }

  Future<void> _fetchBoardPostsFallback({bool fromServer = false}) async {
    try {
      final posts = await _boardService.fetchPosts(
        categoryId: _selectedBoardCategory.id,
        source: fromServer ? Source.server : Source.serverAndCache,
      );
      if (!mounted) return;
      setState(() {
        _boardPostsCache = posts;
        _boardPostsError = null;
        _boardPostsLoading = false;
      });
    } catch (_) {}
  }

  Future<void> _loadAdminStatus() async {
    try {
      final isAdmin = await AdminService.instance.isAdmin();
      if (!mounted) return;
      if (isAdmin != _isAdmin) {
        setState(() => _isAdmin = isAdmin);
      }
    } catch (_) {
      // Admin 판별 실패 시 기본값(false) 유지.
    }
  }

  void _appendHotNewUnique(List<Map<String, dynamic>> batch) {
    final ids = _hotNewRecipes
        .map((r) => r['id'] as String?)
        .whereType<String>()
        .toSet();
    for (final recipe in batch) {
      final id = recipe['id'] as String? ?? '';
      if (id.isEmpty || ids.contains(id)) continue;
      // 외부 블로그(네이버) 카드는 Hot New 메인 캐러셀에서 제외 — 인기/핫
      // 메인 노출은 정형 레시피만, 외부 블로그는 더보기 별도 섹션에서만.
      final platform = (recipe['source'] is Map)
          ? ((recipe['source'] as Map)['platform'] as String? ?? '')
                .toLowerCase()
          : '';
      if (platform == 'naver_blog') continue;
      ids.add(id);
      _hotNewRecipes.add(recipe);
    }
  }

  void _onHotNewScroll() {
    if (!_hotNewScrollController.hasClients) return;
    if (_hotNewLoadingMore || !_hotNewHasMore) return;
    if (_hotNewRecipes.isEmpty) return;
    const itemExtent = 140.0 + 12.0;
    final firstVisibleIndex =
        (_hotNewScrollController.position.pixels / itemExtent).floor().clamp(
          0,
          _hotNewRecipes.length - 1,
        );
    final remainingAhead = _hotNewRecipes.length - firstVisibleIndex - 1;
    if (remainingAhead <= 10) {
      _loadMoreHotNewRecipes();
    }
  }

  Future<void> _loadHotNewRecipes() async {
    if (!mounted) return;
    setState(() {
      _hotNewLoading = true;
      _hotNewLoadingMore = false;
      _hotNewLastCursor = null;
      _hotNewHasMore = true;
      _hotNewRecipes.clear();
    });
    try {
      final page = await _recipeService.fetchExploreRecipesPage(rawLimit: 30);
      if (!mounted) return;
      _appendHotNewUnique(page.recipes);
      setState(() {
        _hotNewLastCursor = page.lastRawDocument;
        _hotNewHasMore = page.hasMore;
        _hotNewLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _hotNewLoading = false);
    }
  }

  Future<void> _loadMoreHotNewRecipes() async {
    if (!mounted || _hotNewLoadingMore || !_hotNewHasMore) return;
    _hotNewLoadingMore = true;
    try {
      final page = await _recipeService.fetchExploreRecipesPage(
        startAfter: _hotNewLastCursor,
        rawLimit: 30,
      );
      if (!mounted) return;
      _hotNewLastCursor = page.lastRawDocument;
      _hotNewHasMore = page.hasMore;
      final before = _hotNewRecipes.length;
      _appendHotNewUnique(page.recipes);
      if (_hotNewRecipes.length != before) setState(() {});
    } catch (_) {
      // keep current list if paging fails
    } finally {
      _hotNewLoadingMore = false;
    }
  }

  void _onHotNewRecipeTap(
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
              ? 'hot_new'
              : HomeSectionKeys.keyForTitle(sectionTitle);
      unawaited(
        AnalyticsService().trackHomeRecipeClicked(
          recipeId: recipeId,
          sectionId: sectionId,
          sectionName: sectionTitle,
          cardIndex: cardIndex,
          sourceScreen: 'category_explore',
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

  // ignore: unused_element
  Future<void> _loadHotGroups() async {
    if (!mounted) return;
    setState(() => _hotGroupsLoading = true);
    try {
      final groups = await _recipeService.fetchHotRecipeGroups(limit: 30);
      if (!mounted) return;
      setState(() {
        _hotGroups = groups;
        _hotGroupsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _hotGroupsLoading = false);
    }
  }

  void _onHotGroupTap(Map<String, dynamic> group) {
    // NavGuard.once is global; awaiting showModalBottomSheet here would keep
    // the guard locked for the entire lifetime of the sheet and silently
    // swallow taps on recipe cards inside (which also use NavGuard.once).
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) => HotGroupSheet(
        group: group,
        recipeService: _recipeService,
        backgroundParsingService: _backgroundParsingService,
        userService: _userService,
        brightness: Theme.of(ctx).brightness,
      ),
    );
  }

  Future<void> _openHotNewAll() async {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrendingAllPage(
          allRecipes: _hotNewRecipes,
          onRecipeTap: _onHotNewRecipeTap,
          preferCroppedForInstagram: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    CategoryExploreScreen._openReviewIdNotifier.removeListener(
      _onExternalOpenReview,
    );
    CategoryExploreScreen._activateSearchNotifier.removeListener(
      _onExternalActivateSearch,
    );
    CategoryExploreScreen._showTrendingTabNotifier.removeListener(
      _onExternalShowTrending,
    );
    CategoryExploreScreen._openTrendingPageNotifier.removeListener(
      _onExternalOpenTrendingPage,
    );
    CategoryExploreScreen._mainTabSelectedNotifier.removeListener(
      _onMainTabSelectionChanged,
    );
    CategoryExploreScreen._openMeetupIdNotifier.removeListener(
      _onExternalOpenMeetup,
    );
    CategoryExploreScreen._openChallengeIdNotifier.removeListener(
      _onExternalOpenChallenge,
    );
    _browseSearchDebounce?.cancel();
    _browseScrollController.removeListener(_onBrowseScroll);
    _browseScrollController.dispose();
    _hotNewScrollController.removeListener(_onHotNewScroll);
    _hotNewScrollController.dispose();
    _hotGroupsScrollController.dispose();
    _trendSearchController.dispose();
    _trendSearchFocus.dispose();
    _feedScrollController.removeListener(_onFeedScrollForFab);
    _feedScrollController.dispose();
    _followingScrollController.removeListener(_onFollowingScrollForFab);
    _followingScrollController.dispose();
    _boardPostsSub?.cancel();
    _boardScrollController.dispose();
    _leaderboardScrollController.dispose();
    _meetupScrollController.dispose();
    _challengeScrollController.dispose();
    _communityTabBarScrollController.dispose();
    _followingUserIdsNotifier.dispose();
    super.dispose();
  }

  void _onFeedScrollForFab() =>
      _onFeedListScroll(_feedScrollController, followingOnly: false);

  void _onFollowingScrollForFab() =>
      _onFeedListScroll(_followingScrollController, followingOnly: true);

  void _onFeedListScroll(
    ScrollController controller, {
    required bool followingOnly,
  }) {
    if (!controller.hasClients) return;
    if (_selectedTopTab != (followingOnly ? 1 : 0)) return;
    final next = controller.offset > 24;
    if (next != _communityFabCollapsed && mounted) {
      setState(() => _communityFabCollapsed = next);
    }
    final pos = controller.position;
    if (pos.maxScrollExtent > 0 &&
        pos.maxScrollExtent - pos.pixels <= 1200) {
      final visibleCount = _filteredFeedReviews(
        _feedReviews,
        followingOnly: followingOnly,
      ).length;
      if (visibleCount > 0) {
        _maybePrefetchFeed(
          reviewIndex: visibleCount - 1,
          visibleCount: visibleCount,
        );
      }
    }
  }

  void _scrollCommunityTabToTop(int index) {
    final controller = switch (index) {
      0 => _feedScrollController,
      1 => _followingScrollController,
      2 => _boardScrollController,
      3 => _leaderboardScrollController,
      4 => _meetupScrollController,
      5 => _challengeScrollController,
      _ => null,
    };
    if (controller == null || !controller.hasClients) return;
    if (controller.offset <= 0) return;
    unawaited(
      controller.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: const Cubic(0.16, 1, 0.3, 1),
      ),
    );
  }

  bool _handleCommunityScrollNotification(ScrollNotification notification) {
    if (_isGuestUser) return false;
    if (_communityTabBarAnimating) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification) return false;

    final pixels = notification.metrics.pixels;
    final delta =
        notification.scrollDelta ?? (pixels - _communityScrollPixels);
    _communityScrollPixels = pixels;

    if (pixels <= 8) {
      _setCommunityTabBarVisible(true);
      return false;
    }
    if (delta > 6) {
      _setCommunityTabBarVisible(false);
    } else if (delta < -6) {
      _setCommunityTabBarVisible(true);
    }
    return false;
  }

  void _setCommunityTabBarVisible(bool visible) {
    if (_communityTabBarVisible == visible) return;
    setState(() {
      _communityTabBarVisible = visible;
      _communityTabBarAnimating = true;
      if (visible) {
        _communityTabBarDuration = _kCommunityTabBarShowDuration;
        _communityTabBarCurve = _kCommunityTabBarShowCurve;
      } else {
        _communityTabBarDuration = _kCommunityTabBarHideDuration;
        _communityTabBarCurve = _kCommunityTabBarHideCurve;
      }
    });
    Future<void>.delayed(
      _communityTabBarDuration + const Duration(milliseconds: 40),
      () {
        if (mounted) _communityTabBarAnimating = false;
      },
    );
  }

  bool _recipeMatchesTrendSearch(Map<String, dynamic> recipe, String query) {
    return recipeMatchesSearchQuery(recipe, query);
  }

  void _onTrendSearchChanged() {
    setState(() => _trendSearchQuery = _trendSearchController.text.trim());
    _browseSearchDebounce?.cancel();
    if (!_trendBrowseAllRecipes) return;
    if (_trendSearchQuery.isEmpty) return;
    _browseSearchDebounce = Timer(const Duration(milliseconds: 380), () {
      if (!mounted) return;
      _tryLoadMoreForSearch();
    });
  }

  Future<void> _tryLoadMoreForSearch() async {
    if (!_trendBrowseAllRecipes || !mounted) return;
    final q = _trendSearchQuery;
    if (q.isEmpty) return;
    if (_browseRecipes.any((r) => _recipeMatchesTrendSearch(r, q))) return;
    try {
      final dishHits = await _recipeService.searchRecipesByDishQuery(
        q,
        limit: 8,
      );
      if (!mounted || _trendSearchQuery != q) return;
      if (dishHits.isNotEmpty) {
        final existing = List<Map<String, dynamic>>.from(_browseRecipes);
        _browseRecipes.clear();
        _appendBrowseUnique(dishHits);
        _appendBrowseUnique(existing);
        setState(() {});
        if (_browseRecipes.any((r) => _recipeMatchesTrendSearch(r, q))) {
          return;
        }
      }
    } catch (_) {}
    for (var i = 0; i < 12; i++) {
      if (!mounted || _trendSearchQuery != q) return;
      if (_browseRecipes.any((r) => _recipeMatchesTrendSearch(r, q))) return;
      if (!_browseHasMore) return;
      while (mounted && _browseLoadingMore) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (!mounted || _trendSearchQuery != q) return;
      if (!_browseHasMore) return;
      await _loadMoreBrowse();
    }
  }

  void _appendBrowseUnique(List<Map<String, dynamic>> batch) {
    appendUniqueRecipeMapsWithCap(
      list: _browseRecipes,
      batch: batch,
      maxItems: _kBrowseRecipesMaxInMemory,
    );
  }

  void _onBrowseScroll() {
    if (!_trendBrowseAllRecipes) return;
    if (!_browseScrollController.hasClients) return;
    final pos = _browseScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMoreBrowse();
    }
  }

  Future<void> _loadBrowseInitial() async {
    if (!mounted || !_trendBrowseAllRecipes) return;
    setState(() {
      _browseInitialLoading = true;
      _browseError = null;
    });
    try {
      _browseRecipes.clear();
      _browseLastCursor = null;
      _browseHasMore = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_browseScrollController.hasClients) return;
        _browseScrollController.jumpTo(0);
      });

      // Same Firestore path as 트렌드 tab: shared Future + getExploreRecipesForGuests.
      _syncExploreCacheGeneration();
      _cachedExploreFuture ??= _recipeService.getExploreRecipesForGuests(
        limit: _kExploreGuestListLimit,
      );
      final guestList = await _cachedExploreFuture!;
      if (!mounted || !_trendBrowseAllRecipes) return;
      _appendBrowseUnique(guestList);
      setState(() {});
      if (_browseRecipes.length >= _kBrowseShowAfterCount) {
        setState(() => _browseInitialLoading = false);
      }

      if (_browseRecipes.isNotEmpty) {
        final lastId = _browseRecipes.last['id'] as String?;
        if (lastId != null) {
          final snap = await FirebaseFirestore.instance
              .collection('recipes')
              .doc(lastId)
              .get();
          if (snap.exists) {
            _browseLastCursor = snap;
          }
        }
      }

      // If guest list is empty (rules / data), fall back to paged document-id scan.
      if (_browseRecipes.isEmpty) {
        while (mounted && _trendBrowseAllRecipes && _browseHasMore) {
          if (_browseRecipes.length >= _kBrowseInitialPrefetch) break;
          final page = await _recipeService.fetchExploreRecipesPage(
            startAfter: _browseLastCursor,
            rawLimit: _kBrowseRawBatch,
          );
          if (!mounted || !_trendBrowseAllRecipes) return;
          _browseLastCursor = page.lastRawDocument;
          _browseHasMore = page.hasMore;
          _appendBrowseUnique(page.recipes);
          setState(() {});
          if (_browseRecipes.length >= _kBrowseShowAfterCount) {
            setState(() => _browseInitialLoading = false);
          }
          if (!_browseHasMore) break;
          if (page.lastRawDocument == null && page.recipes.isEmpty) break;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _browseError = e.toString());
    }
    if (mounted) setState(() => _browseInitialLoading = false);
  }

  Future<void> _loadMoreBrowse() async {
    if (!_trendBrowseAllRecipes || !mounted) return;
    if (_browseLoadingMore || !_browseHasMore) return;
    setState(() => _browseLoadingMore = true);
    try {
      final page = await _recipeService.fetchExploreRecipesPage(
        startAfter: _browseLastCursor,
        rawLimit: _kBrowseRawBatch,
      );
      if (!mounted || !_trendBrowseAllRecipes) return;
      _browseLastCursor = page.lastRawDocument;
      _browseHasMore = page.hasMore;
      _appendBrowseUnique(page.recipes);
      setState(() {});
    } catch (_) {}
    if (mounted) setState(() => _browseLoadingMore = false);
  }

  /// Browse-all list: search field is the first scroll item so it scrolls away with the list.
  Widget _buildTrendBrowseListBody(Brightness brightness) {
    final secondary = AppColors.getTextSecondary(brightness);
    final bottomPadding = MediaQuery.of(context).padding.bottom + 36;
    final filtered = _trendSearchQuery.isEmpty
        ? _browseRecipes
        : _browseRecipes
              .where((r) => _recipeMatchesTrendSearch(r, _trendSearchQuery))
              .toList();

    if (_browseError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '레시피를 불러올 수 없어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: secondary),
          ),
        ),
      );
    }

    if (_browseInitialLoading && filtered.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          _trendSearchQuery.isEmpty ? '아직 레시피가 없어요.' : '검색 결과가 없어요.',
          style: TextStyle(fontSize: 15, color: secondary),
        ),
      );
    }

    return ListView.builder(
      controller: _browseScrollController,
      padding: EdgeInsets.fromLTRB(
        _sectionPaddingH,
        0,
        _sectionPaddingH,
        bottomPadding,
      ),
      itemCount: filtered.length + 1 + (_browseLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              0,
              _trendSearchBarTopPadding,
              0,
              _trendSearchBarToFirstSectionGap,
            ),
            child: _buildTrendSearchBar(brightness),
          );
        }
        final dataIndex = index - 1;
        if (dataIndex >= filtered.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: HomeStyleRecipeCard.fromRecipeMap(
            context,
            filtered[dataIndex],
            recipeService: _recipeService,
            backgroundParsingService: _backgroundParsingService,
            hideAddedDateWhenEmpty: false,
            screenName: 'category_explore',
            sectionId: 'explore_list',
            position: dataIndex,
            onAfterRecipeMutation: () {
              if (mounted) setState(() {});
            },
          ),
        );
      },
    );
  }

  void _onExternalOpenReview() {
    final reviewId = CategoryExploreScreen._openReviewIdNotifier.value;
    if (reviewId == null || reviewId.isEmpty) return;
    _openReviewFromNotification(reviewId);
    CategoryExploreScreen._openReviewIdNotifier.value = null;
  }

  void _onExternalOpenMeetup() {
    final meetupId = CategoryExploreScreen._openMeetupIdNotifier.value;
    if (meetupId == null) return;
    CategoryExploreScreen._openMeetupIdNotifier.value = null;
    if (!mounted) return;
    _selectCommunityTopTab(4);
    if (meetupId.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MeetupDetailScreen(meetupId: meetupId),
        ),
      );
    });
  }

  void _onExternalOpenChallenge() {
    final challengeId = CategoryExploreScreen._openChallengeIdNotifier.value;
    if (challengeId == null) return;
    CategoryExploreScreen._openChallengeIdNotifier.value = null;
    if (!mounted) return;
    _selectCommunityTopTab(5);
    if (challengeId.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChallengeDetailScreen(challengeId: challengeId),
        ),
      );
    });
  }

  /// Trend is no longer a visible community tab; external trend CTAs still
  /// open the dedicated 인기 레시피 page.
  void _onExternalShowTrending() {
    if (!mounted) return;
    unawaited(_onExternalOpenTrendingPage());
  }

  /// Push the dedicated 인기 레시피 page (TrendingAllPage) directly using
  /// already-loaded data. If recipes haven't loaded yet (rare since this
  /// screen pre-loads on init), do a quick fetch first.
  Future<void> _onExternalOpenTrendingPage() async {
    if (!mounted) return;
    if (_hotNewRecipes.isEmpty) {
      await _loadHotNewRecipes();
      if (!mounted) return;
    }
    _openHotNewAll();
  }

  void _onExternalActivateSearch() {
    if (!CategoryExploreScreen._activateSearchNotifier.value) return;
    CategoryExploreScreen._activateSearchNotifier.value = false;
    if (!mounted) return;
    unawaited(_onExternalOpenTrendingPage());
  }

  Future<void> _loadFeedReviews() async {
    if (!_canAccessFeed) {
      if (mounted) {
        setState(() {
          _feedReviews = [];
          _feedLoading = false;
          _feedHasMore = false;
          _feedLastCursor = null;
        });
      }
      return;
    }
    final loadSeq = ++_feedLoadSeq;
    _feedLoadingMore = false;
    // 이미 피드가 있으면 스피너로 비우지 않고, 새 데이터를 준비한 뒤 한 번에 교체.
    if (_feedReviews.isEmpty && mounted) {
      setState(() => _feedLoading = true);
    }
    try {
      final page = await _reviewService.fetchCommunityReviewsPage(
        photoTarget: _kFeedPageSize,
      );
      final user = _auth.currentUser;
      Set<String> savedRecipeIds = {};
      Set<String> blockedUserIds = {};
      if (user != null) {
        try {
          savedRecipeIds = (await _userService.getSavedRecipes(
            user.uid,
          )).toSet();
        } catch (_) {}
        try {
          blockedUserIds = (await _userService.getBlockedUserIds(
            user.uid,
          )).toSet();
        } catch (_) {}
      }
      final visibleReviews = _filterBlockedFeedReviews(
        page.reviews,
        blockedUserIds,
      );
      if (!mounted || loadSeq != _feedLoadSeq) return;

      final likedStatusMap = <String, bool>{};
      final likeCountsMap = <String, int>{};
      final commentCountsMap = <String, int>{};
      final bookmarkedStatusMap = <String, bool>{};
      _indexFeedReviewMeta(
        visibleReviews,
        likedStatusMap: likedStatusMap,
        likeCountsMap: likeCountsMap,
        commentCountsMap: commentCountsMap,
        bookmarkedStatusMap: bookmarkedStatusMap,
        savedRecipeIds: savedRecipeIds,
      );

      final authorCache = await _loadFeedAuthorProfiles(visibleReviews);
      if (!mounted || loadSeq != _feedLoadSeq) return;

      setState(() {
        _feedReviews = visibleReviews;
        _feedLastCursor = page.lastRawDocument;
        _feedHasMore = page.hasMore;
        _feedLikedStatus = likedStatusMap;
        _feedLikeCounts = likeCountsMap;
        _feedCommentCounts = commentCountsMap;
        _feedBookmarkedStatus = bookmarkedStatusMap;
        _feedBlockedUserIds = blockedUserIds;
        _feedSavedRecipeIds = savedRecipeIds;
        _feedUserDataCache = {
          ..._feedUserDataCache,
          ...authorCache,
        };
        _feedLoading = false;
        _feedLoadingMore = false;
      });

      unawaited(
        _hydrateFeedRecipeMeta(
          visibleReviews: visibleReviews,
          loadSeq: loadSeq,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _feedLoading = false);
    }
  }

  List<Map<String, dynamic>> _filterBlockedFeedReviews(
    List<Map<String, dynamic>> reviews,
    Set<String> blockedUserIds,
  ) {
    if (blockedUserIds.isEmpty) return List<Map<String, dynamic>>.from(reviews);
    return reviews.where((review) {
      final authorId = review['userId'] as String? ?? '';
      return !blockedUserIds.contains(authorId);
    }).toList();
  }

  void _indexFeedReviewMeta(
    List<Map<String, dynamic>> reviews, {
    required Map<String, bool> likedStatusMap,
    required Map<String, int> likeCountsMap,
    required Map<String, int> commentCountsMap,
    required Map<String, bool> bookmarkedStatusMap,
    required Set<String> savedRecipeIds,
  }) {
    for (final review in reviews) {
      final reviewId = review['id'] as String? ?? '';
      final recipeId = review['recipeId'] as String? ?? '';
      if (_feedLikeInFlight.contains(reviewId)) {
        likedStatusMap[reviewId] = _feedLikedStatus[reviewId] ?? false;
        likeCountsMap[reviewId] = _feedLikeCounts[reviewId] ?? 0;
      } else {
        likedStatusMap[reviewId] = _reviewService.isLiked(review);
        likeCountsMap[reviewId] = (review['likeCount'] as num?)?.toInt() ?? 0;
      }
      commentCountsMap[reviewId] =
          (review['commentCount'] as num?)?.toInt() ?? 0;
      if (recipeId.isNotEmpty) {
        bookmarkedStatusMap[recipeId] = savedRecipeIds.contains(recipeId);
      }
    }
  }

  void _maybePrefetchFeed({
    required int reviewIndex,
    required int visibleCount,
  }) {
    if (_feedLoading || _feedLoadingMore || !_feedHasMore) return;
    if (_feedReviews.length >= _kFeedMaxInMemory) return;
    if (visibleCount <= 0) return;
    final remainingAhead = visibleCount - reviewIndex - 1;
    if (remainingAhead > _kFeedPrefetchRemaining) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadMoreFeedReviews());
    });
  }

  Future<void> _loadMoreFeedReviews() async {
    if (!_canAccessFeed) return;
    if (_feedLoading || _feedLoadingMore || !_feedHasMore) return;
    if (_feedReviews.length >= _kFeedMaxInMemory) {
      _feedHasMore = false;
      return;
    }
    final loadSeq = _feedLoadSeq;
    _feedLoadingMore = true;
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && loadSeq == _feedLoadSeq && _feedLoadingMore) {
          setState(() {});
        }
      });
    }
    try {
      final seen = _feedReviews
          .map((r) => r['id'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final page = await _reviewService.fetchCommunityReviewsPage(
        startAfter: _feedLastCursor,
        photoTarget: _kFeedPageSize,
      );
      if (!mounted || loadSeq != _feedLoadSeq) return;

      final fresh = _filterBlockedFeedReviews(
        page.reviews,
        _feedBlockedUserIds,
      ).where((review) {
        final id = review['id'] as String? ?? '';
        return id.isNotEmpty && seen.add(id);
      }).toList();

      if (fresh.isEmpty) {
        if (!mounted || loadSeq != _feedLoadSeq) return;
        setState(() {
          _feedLastCursor = page.lastRawDocument;
          _feedHasMore = page.hasMore;
          _feedLoadingMore = false;
        });
        return;
      }

      _indexFeedReviewMeta(
        fresh,
        likedStatusMap: _feedLikedStatus,
        likeCountsMap: _feedLikeCounts,
        commentCountsMap: _feedCommentCounts,
        bookmarkedStatusMap: _feedBookmarkedStatus,
        savedRecipeIds: _feedSavedRecipeIds,
      );

      final authorCache = await _loadFeedAuthorProfiles(fresh);
      if (!mounted || loadSeq != _feedLoadSeq) return;

      setState(() {
        _feedLastCursor = page.lastRawDocument;
        _feedHasMore = page.hasMore;
        _feedReviews = [..._feedReviews, ...fresh];
        _feedUserDataCache = {
          ..._feedUserDataCache,
          ...authorCache,
        };
        _feedLoadingMore = false;
      });

      unawaited(
        _hydrateFeedRecipeMeta(visibleReviews: fresh, loadSeq: loadSeq),
      );
    } catch (_) {
      if (mounted && loadSeq == _feedLoadSeq) {
        setState(() => _feedLoadingMore = false);
      }
    }
  }

  Future<Map<String, Map<String, dynamic>>> _loadFeedAuthorProfiles(
    List<Map<String, dynamic>> visibleReviews,
  ) async {
    final userIds = <String>{};
    for (final review in visibleReviews) {
      final authorId = (review['userId'] as String?)?.trim() ?? '';
      if (authorId.isNotEmpty) userIds.add(authorId);
      final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
      for (var i = 0; i < likedBy.length && i < 3; i++) {
        final id = likedBy[i].trim();
        if (id.isNotEmpty) userIds.add(id);
      }
    }

    final result = <String, Map<String, dynamic>>{};
    final missing = <String>[];
    for (final userId in userIds) {
      final session = _sessionFeedUserCache[userId];
      if (session != null) {
        result[userId] = session;
        continue;
      }
      final local = _feedUserDataCache[userId];
      if (local != null && local.isNotEmpty) {
        result[userId] = local;
        _sessionFeedUserCache[userId] = local;
        continue;
      }
      missing.add(userId);
    }

    if (missing.isNotEmpty) {
      await Future.wait(
        missing.map((userId) async {
          try {
            final userDoc = await _userService.getUserDocument(userId);
            final data =
                userDoc.data() as Map<String, dynamic>? ?? <String, dynamic>{};
            result[userId] = data;
            _sessionFeedUserCache[userId] = data;
          } catch (_) {
            result[userId] = const <String, dynamic>{};
          }
        }),
      );
    }

    return result;
  }

  void _applyFollowingIds(Set<String> serverIds) {
    final next = Set<String>.from(serverIds);
    final current = _followingUserIdsNotifier.value;
    if (current != null) {
      for (final id in _followToggleInFlight) {
        if (current.contains(id)) {
          next.add(id);
        } else {
          next.remove(id);
        }
      }
    }
    _followingUserIdsNotifier.value = next;
  }

  Future<void> _loadFollowingUserIds() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (_followingLoading) return;
    setState(() => _followingLoading = true);
    try {
      final ids = await _userService.getFollowingIds(user.uid, limit: 200);
      if (!mounted) return;
      _applyFollowingIds(ids);

      final following = await _userService.getFollowing(user.uid, limit: 200);
      if (!mounted) return;
      final hydratedIds = <String>{...ids};
      for (final item in following) {
        final profileUid = item['uid']?.toString() ?? '';
        final contentUid = item['contentUid']?.toString() ?? '';
        if (profileUid.isNotEmpty) hydratedIds.add(profileUid);
        if (contentUid.isNotEmpty) hydratedIds.add(contentUid);
      }
      _applyFollowingIds(hydratedIds);
      setState(() {
        _followingUsers = following;
        _followingLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (_followingUserIdsNotifier.value == null) {
        _followingUserIdsNotifier.value = <String>{};
      }
      setState(() {
        _followingUsers = [];
        _followingLoading = false;
      });
    }
  }

  /// Tracks per-author follow toggle calls so a user can't double-tap and
  /// spam the follows collection while a request is in-flight.
  final Set<String> _followToggleInFlight = <String>{};

  bool _canOpenUserProfile(String? userId) {
    final uid = (userId ?? '').trim();
    if (uid.isEmpty) return false;
    if (uid == (_auth.currentUser?.uid ?? '')) return true;
    final cached = _feedUserDataCache[uid];
    return !isSeedUserProfile(cached);
  }

  Future<void> _openUserProfile(String? userId) async {
    final uid = (userId ?? '').trim();
    if (uid.isEmpty) return;
    if (uid == (_auth.currentUser?.uid ?? '')) {
      Navigator.pushNamed(context, '/profile', arguments: {'userId': uid});
      return;
    }
    var user = _feedUserDataCache[uid] ?? _sessionFeedUserCache[uid];
    if (user == null || user.isEmpty) {
      try {
        final doc = await _userService.getUserDocument(uid);
        user = (doc.data() as Map<String, dynamic>?) ?? const {};
        _feedUserDataCache[uid] = user;
        _sessionFeedUserCache[uid] = user;
      } catch (_) {
        user = const {};
      }
    }
    if (isSeedUserProfile(user)) return;
    if (!mounted) return;
    Navigator.pushNamed(context, '/profile', arguments: {'userId': uid});
  }

  Future<void> _handleFeedFollowToggle(String? authorId) async {
    final user = _auth.currentUser;
    final targetId = (authorId ?? '').trim();
    if (targetId.isEmpty) return;
    if (user == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    if (user.uid == targetId) return;
    if (_followToggleInFlight.contains(targetId)) return;
    if (_followingUserIdsNotifier.value == null) {
      await _loadFollowingUserIds();
      if (!mounted || _followingUserIdsNotifier.value == null) return;
      if (_followToggleInFlight.contains(targetId)) return;
    }

    final currentFollowing = _followingUserIdsNotifier.value ?? <String>{};
    final wasFollowing = currentFollowing.contains(targetId);

    // Build the optimistic snapshot for the following-id set so the per-post
    // chip flips this frame (no await between tap and rebuild).
    final updatedIds = Set<String>.from(currentFollowing);
    if (wasFollowing) {
      updatedIds.remove(targetId);
    } else {
      updatedIds.add(targetId);
    }

    // Also project the change onto the avatar rail list immediately so the
    // 팔로잉 탭's rail stays consistent with the chip without a server round
    // trip. New follow rows borrow the author's cached profile snippet from
    // the feed's user cache so the avatar/handle don't pop in blank.
    List<Map<String, dynamic>> nextFollowingUsers = _followingUsers;
    if (wasFollowing) {
      nextFollowingUsers = _followingUsers
          .where(
            (u) =>
                (u['uid']?.toString() ?? '') != targetId &&
                (u['contentUid']?.toString() ?? '') != targetId,
          )
          .toList();
    } else {
      final cached = _feedUserDataCache[targetId] ?? <String, dynamic>{};
      nextFollowingUsers = [
        <String, dynamic>{
          'uid': targetId,
          'contentUid': cached['uid']?.toString() ?? targetId,
          'name': cached['name']?.toString() ?? '',
          'photoUrl': resolveUserPhotoUrl(cached),
          'handle': cached['handle']?.toString(),
        },
        ..._followingUsers,
      ];
    }

    _followToggleInFlight.add(targetId);
    _followingUserIdsNotifier.value = updatedIds;
    _followingUsers = nextFollowingUsers;
    // 팔로잉 탭: 아바타 레일·필터된 목록만 갱신. 피드 탭은 칩이 notifier만 구독.
    if (_selectedTopTab == 1 && mounted) {
      setState(() {});
    }

    try {
      if (wasFollowing) {
        await _userService.unfollowUser(user.uid, targetId);
      } else {
        await _userService.followUser(user.uid, targetId);
      }
    } catch (e) {
      if (!mounted) return;
      final rollbackIds = Set<String>.from(
        _followingUserIdsNotifier.value ?? <String>{},
      );
      if (wasFollowing) {
        rollbackIds.add(targetId);
      } else {
        rollbackIds.remove(targetId);
      }
      _followingUserIdsNotifier.value = rollbackIds;
      _followingUsers = currentFollowing.contains(targetId)
          ? _followingUsers
          : _followingUsers
                .where(
                  (u) =>
                      (u['uid']?.toString() ?? '') != targetId &&
                      (u['contentUid']?.toString() ?? '') != targetId,
                )
                .toList();
      if (_selectedTopTab == 1) {
        setState(() {});
      }
      showAppSnackBar(context, 
        SnackBar(
          content: Text(wasFollowing ? '언팔로우 실패: $e' : '팔로우 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _followToggleInFlight.remove(targetId);
    }
  }

  Future<void> _hydrateFeedRecipeMeta({
    required List<Map<String, dynamic>> visibleReviews,
    required int loadSeq,
  }) async {
    final recipeIds = visibleReviews
        .map((r) => r['recipeId'] as String?)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .where((id) => !_feedRecipeAverageRating.containsKey(id))
        .toSet()
        .toList();
    if (recipeIds.isEmpty) return;

    final tagsCache = <String, List<String>>{};
    final avgRatingCache = <String, double?>{};
    final reviewCountCache = <String, int>{};
    await Future.wait(
      recipeIds.map((id) async {
        try {
          final recipe = await _recipeService.getRecipeById(id);
          if (recipe == null) return;
          final raw = recipe.source['tags'];
          if (raw is List) {
            tagsCache[id] = filterRecipeTagsForDisplay(raw);
          }
          avgRatingCache[id] = recipe.averageRating;
          reviewCountCache[id] = recipe.reviewCount ?? 0;
        } catch (_) {}
      }),
    );

    if (!mounted || loadSeq != _feedLoadSeq) return;
    setState(() {
      _feedRecipeTagsCache = {
        ..._feedRecipeTagsCache,
        ...tagsCache,
      };
      _feedRecipeAverageRating = {
        ..._feedRecipeAverageRating,
        ...avgRatingCache,
      };
      _feedRecipeReviewCount = {
        ..._feedRecipeReviewCount,
        ...reviewCountCache,
      };
    });
  }

  final Set<String> _feedLikeInFlight = {};

  Future<void> _handleFeedLike(String reviewId, {bool onlyLike = false}) async {
    if (_feedLikeInFlight.contains(reviewId)) return;
    if (_auth.currentUser == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    final wasLiked = _feedLikedStatus[reviewId] ?? false;
    if (onlyLike && wasLiked) return;
    _feedLikeInFlight.add(reviewId);
    final currentCount = _feedLikeCounts[reviewId] ?? 0;
    setState(() {
      _feedLikedStatus[reviewId] = !wasLiked;
      _feedLikeCounts[reviewId] = wasLiked
          ? currentCount - 1
          : currentCount + 1;
      if (!wasLiked && onlyLike) _feedLikingReviewId = reviewId;
    });
    try {
      await _reviewService.toggleLike(reviewId);
    } catch (_) {
      // Keep the optimistic state — user intended the action
    } finally {
      _feedLikeInFlight.remove(reviewId);
      if (_feedLikingReviewId == reviewId) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) {
            setState(() {
              if (_feedLikingReviewId == reviewId) _feedLikingReviewId = null;
            });
          }
        });
      }
    }
  }

  void _showFeedCommentModal(
    BuildContext context,
    Map<String, dynamic> review,
    Brightness brightness,
  ) async {
    final reviewId = review['id'] as String? ?? '';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentModal(reviewId: reviewId, review: review),
    );
    if (mounted) {
      try {
        final count = await _reviewService.getCommentCount(reviewId);
        setState(() => _feedCommentCounts[reviewId] = count);
      } catch (_) {}
    }
  }

  /// Open the review edit sheet prefilled from [review]; on submit, refetch
  /// the document and patch the in-memory feed list so the card updates in
  /// place without leaving the community feed.
  Future<void> _handleFeedEdit(Map<String, dynamic> review) async {
    final reviewId = review['id'] as String? ?? '';
    if (reviewId.isEmpty) return;
    final result = await showProgressiveRecipeReviewEditPopup(
      context,
      reviewId: reviewId,
      existingReview: review,
    );
    if (result != true || !mounted) return;
    try {
      final fresh = await _reviewService.getReviewById(reviewId);
      if (!mounted || fresh == null) return;
      setState(() {
        final idx = _feedReviews.indexWhere(
          (r) => (r['id'] as String?) == reviewId,
        );
        if (idx >= 0) {
          _feedReviews[idx] = {..._feedReviews[idx], ...fresh};
        }
      });
    } catch (_) {
      // Best-effort; ignore network errors.
    }
  }

  Future<void> _handleFeedDelete(
    String reviewId, {
    bool allowAdminOverride = false,
  }) async {
    if (reviewId.isEmpty) return;

    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '후기를 삭제할까요?',
      description: '삭제된 후기는 복구할 수 없어요.',
      confirmLabel: '삭제',
      destructive: true,
    );

    if (confirmed != true) return;

    try {
      await _reviewService.deleteReview(
        reviewId,
        allowAdminOverride: allowAdminOverride,
      );
      if (!mounted) return;
      setState(() {
        _feedReviews.removeWhere((r) => (r['id'] as String?) == reviewId);
      });
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('후기가 삭제되었습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text('삭제 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleFeedBlockUser({
    required String blockedUserId,
    required String reviewId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    if (blockedUserId.isEmpty || blockedUserId == user.uid) return;
    if (_feedBlockedUserIds.contains(blockedUserId)) {
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('이미 차단한 사용자입니다'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }

    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '이 사용자를 차단할까요?',
      description: '차단된 사용자의 게시물은 피드에서 바로 숨겨져요.',
      confirmLabel: '차단',
      destructive: true,
    );
    if (confirmed != true) return;

    final previousReviews = List<Map<String, dynamic>>.from(_feedReviews);
    final previousBlocked = Set<String>.from(_feedBlockedUserIds);

    if (mounted) {
      setState(() {
        _feedBlockedUserIds = {..._feedBlockedUserIds, blockedUserId};
        _feedReviews.removeWhere(
          (review) => (review['userId'] as String? ?? '') == blockedUserId,
        );
      });
    }

    try {
      await _userService.blockUser(uid: user.uid, blockedUserId: blockedUserId);
      try {
        await _reportService.createReport(
          type: 'review',
          targetId: reviewId,
          reason: 'abuse',
          description: 'user_blocked_from_feed',
        );
      } catch (_) {}
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('사용자를 차단했습니다. 관련 게시물을 숨겼습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedReviews = previousReviews;
        _feedBlockedUserIds = previousBlocked;
      });
      showAppSnackBar(context, 
        SnackBar(
          content: Text('차단 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleFeedBookmark(String recipeId) async {
    final user = _auth.currentUser;
    if (user == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('북마크하려면 로그인이 필요합니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final isCurrentlyBookmarked = _feedBookmarkedStatus[recipeId] ?? false;
    if (isCurrentlyBookmarked) {
      final confirmed = await AppConfirmDialog.show(
        context: context,
        title: '레시피북에서 제거할까요?',
        description: '저장된 레시피 목록에서 제거되며, 언제든지 다시 저장할 수 있어요.',
        confirmLabel: '제거',
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _feedBookmarkedStatus[recipeId] = !isCurrentlyBookmarked;
      if (isCurrentlyBookmarked) {
        _feedSavedRecipeIds.remove(recipeId);
      } else {
        _feedSavedRecipeIds.add(recipeId);
      }
    });
    try {
      if (isCurrentlyBookmarked) {
        await _userService.removeSavedRecipe(user.uid, recipeId);
        RecipeService.notifyRecipesChanged();
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('북마크에서 제거되었습니다'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      } else {
        final parseResponse = await _recipeService.getRecipeById(recipeId);
        if (parseResponse == null) {
          setState(() {
            _feedBookmarkedStatus[recipeId] = isCurrentlyBookmarked;
            _feedSavedRecipeIds.remove(recipeId);
          });
          if (mounted) {
            showAppSnackBar(context, 
              const SnackBar(
                content: Text('레시피를 찾을 수 없습니다'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
        await _userService.addSavedRecipe(user.uid, recipeId, fromFeed: true);
        RecipeService.notifyRecipesChanged();
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('북마크에 추가되었습니다'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _feedBookmarkedStatus[recipeId] = isCurrentlyBookmarked;
        if (isCurrentlyBookmarked) {
          _feedSavedRecipeIds.add(recipeId);
        } else {
          _feedSavedRecipeIds.remove(recipeId);
        }
      });
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('오류: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openReviewFromNotification(String reviewId) async {
    if (!mounted) return;
    final canOpenFeed = await _ensureGuestCanOpenFeed();
    if (!canOpenFeed) {
      return;
    }
    if (_selectedTopTab != 0) {
      setState(() => _selectedTopTab = 0);
      await Future.delayed(const Duration(milliseconds: 180));
    }

    if (!_feedReviews.any((r) => (r['id'] as String? ?? '') == reviewId)) {
      await _loadFeedReviews();
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // 피드 페이지네이션에 아직 안 들어온 리뷰(알림·관리자 원본 보기)는
    // 단건 조회로 상단에 끼워 키 기반 스크롤이 동작하도록 한다.
    if (!_feedReviews.any((r) => (r['id'] as String? ?? '') == reviewId)) {
      try {
        final fresh = await _reviewService.getReviewById(reviewId);
        if (!mounted) return;
        if (fresh != null) {
          setState(() {
            _feedReviews.insert(0, fresh);
          });
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } catch (_) {
        // best-effort: 조회 실패 시 기존 동작(스크롤 시도) 유지
      }
    }

    final key = _reviewKeys[reviewId];
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.15,
      );
    } else {
      final idx = _feedReviews.indexWhere(
        (r) => (r['id'] as String? ?? '') == reviewId,
      );
      if (idx >= 0 && _feedScrollController.hasClients) {
        final offset = (_tabBarHeight + idx * 620.0).clamp(
          0.0,
          _feedScrollController.position.maxScrollExtent,
        );
        _feedScrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  Future<bool> _ensureGuestCanOpenFeed() async {
    if (_canAccessFeed) return true;

    bool agreed = false;
    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setLocalState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF4ED),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFFFFE1D1)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: _orange,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '비로그인 상태 안내',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFB93815),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '피드 이용 약관 동의',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '현재 로그인하지 않아 게스트 모드로 피드를 보고 있어요.\n커뮤니티 콘텐츠 이용 전 이용약관 동의가 필요합니다.',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        height: 1.45,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: agreed,
                            activeColor: _orange,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            onChanged: (value) {
                              setLocalState(() {
                                agreed = value ?? false;
                              });
                            },
                          ),
                          Expanded(
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TextButton(
                                  style: TextButton.styleFrom(
                                    foregroundColor: _orange,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => Navigator.of(
                                    context,
                                  ).pushNamed('/terms-of-service'),
                                  child: const Text(
                                    '이용약관',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Text('에 동의합니다'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFE5E7EB)),
                              foregroundColor: const Color(0xFF6B7280),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              minimumSize: const Size.fromHeight(48),
                            ),
                            child: const Text(
                              '취소',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: agreed
                                ? () => Navigator.of(dialogContext).pop(true)
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: _orange,
                              disabledBackgroundColor: const Color(0xFFF3F4F6),
                              disabledForegroundColor: const Color(0xFF9CA3AF),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              minimumSize: const Size.fromHeight(48),
                            ),
                            child: const Text(
                              '동의하고 보기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result == true) {
      if (!mounted) return false;
      setState(() {
        _guestFeedTermsAccepted = true;
      });
      await _loadFeedReviews();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);

    return Scaffold(
      backgroundColor: bg,
      // 하단 inset은 MainNavigator bottom nav가 소유한다.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            AppHeader(
              onLoginPressed: () => Navigator.pushNamed(context, '/login'),
              showLoginButton: !_isGuestUser,
              showCalendarIcon: true,
              showNotificationIcon: true,
            ),
            if (_isGuestUser)
              _buildTopTabBar(brightness),
            Expanded(
              child: _isGuestUser
                  ? _buildSelectedTopTabContent(brightness)
                  : _buildCollapsibleCommunityBody(brightness),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildCommunityFab(brightness),
    );
  }

  Widget _buildCollapsibleCommunityBody(Brightness brightness) {
    return ClipRect(
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _handleCommunityScrollNotification,
            child: AnimatedPadding(
              duration: _communityTabBarDuration,
              curve: _communityTabBarCurve,
              padding: EdgeInsets.only(
                top: _communityTabBarVisible ? _tabBarHeight : 0,
              ),
              child: _buildSelectedTopTabContent(brightness),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_communityTabBarVisible,
              child: AnimatedSlide(
                offset: _communityTabBarVisible
                    ? Offset.zero
                    : const Offset(0, -1),
                duration: _communityTabBarDuration,
                curve: _communityTabBarCurve,
                child: AnimatedOpacity(
                  opacity: _communityTabBarVisible ? 1 : 0,
                  duration: _communityTabBarVisible
                      ? _kCommunityTabBarShowDuration
                      : const Duration(milliseconds: 180),
                  curve: _communityTabBarVisible
                      ? Curves.easeOut
                      : Curves.easeIn,
                  child: _buildTopTabBar(brightness),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedTopTabContent(Brightness brightness) {
    if (_isGuestUser) return _buildGuestLockedFeed(brightness);
    if (_selectedTopTab == 1) return _buildFollowingTabContent(brightness);
    if (_selectedTopTab == 2) return _buildBoardTabContent(brightness);
    if (_selectedTopTab == 3) return _buildLeaderboardTabContent();
    // 모임·챌린지 탭: 배포 전까지 숨김.
    // if (_selectedTopTab == 4) {
    //   return MeetupTab(scrollController: _meetupScrollController);
    // }
    // if (_selectedTopTab == 5) {
    //   return ChallengeTab(scrollController: _challengeScrollController);
    // }
    return _buildFeedTabContent(brightness);
  }

  Widget _buildLeaderboardTabContent() {
    return CommunityLeaderboardTab(
      topBar: const SizedBox(height: 6),
      scrollController: _leaderboardScrollController,
      onProfileTap: (userId) {
        if (!_canOpenUserProfile(userId)) return;
        _openUserProfile(userId);
      },
    );
  }

  Widget? _buildCommunityFab(Brightness brightness) {
    if (_isGuestUser) return null;
    // Board tab uses a different compose entry: a circular pencil FAB
    // (당근/네이버 카페 패턴) targeting the board_posts collection rather
    // than the recipe-review flow.
    if (_selectedTopTab == 2) return _buildBoardComposeFab();
    if (_selectedTopTab == 3) return null;
    // 모임·챌린지 FAB: 배포 전까지 숨김.
    // if (_selectedTopTab == 4) {
    //   return _buildOrangeComposeFab(
    //     label: '모임 만들기',
    //     onTap: _openMeetupCompose,
    //   );
    // }
    // if (_selectedTopTab == 5) {
    //   return _buildOrangeComposeFab(
    //     label: '친구 챌린지',
    //     onTap: _openFriendChallengeCompose,
    //   );
    // }
    return _buildOrangeComposeFab(
      label: '요리 기록하기',
      onTap: _openCommunityWrite,
    );
  }

  Widget _buildOrangeComposeFab({
    required String label,
    required VoidCallback onTap,
  }) {
    final collapsed = _communityFabCollapsed;
    const duration = Duration(milliseconds: 320);
    const curve = Curves.easeInOutCubic;
    // Match the fridge "재료 추가" button visual; collapses to a + circle on scroll.
    // UnconstrainedBox keeps Scaffold FAB constraints from stretching the pill.
    // Nudge toward the nav without overlapping (endFloat already clears the bar).
    return Transform.translate(
      offset: const Offset(0, 8),
      child: UnconstrainedBox(
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
                      child: Padding(
                        padding: const EdgeInsets.only(left: 5),
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
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
    ),
    );
  }

  Future<void> _openMeetupCompose() async {
    final user = _auth.currentUser;
    if (user == null || user.isAnonymous) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    if (!mounted) return;
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const MeetupComposeScreen()),
    );
    if (created == true) {
      MeetupService.instance.invalidateCache();
    }
  }

  Future<void> _openFriendChallengeCompose() async {
    final user = _auth.currentUser;
    if (user == null || user.isAnonymous) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    if (!mounted) return;
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const FriendChallengeComposeScreen(),
      ),
    );
    if (created == true) {
      ChallengeService.instance.invalidateCache();
    }
  }

  Future<void> _openCommunityWrite() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    final picked = await PickRecipeForReviewSheet.show(context);
    if (!mounted || picked == null || picked.recipeId.isEmpty) return;
    final recipeId = picked.recipeId;

    if (recipeId == PickRecipeForReviewSheet.directReviewId) {
      final submitted = await showProgressiveRecipeReviewPopup(
        context,
        recipeId: '',
        recipeTitle: '나의 요리',
        creatorUsername: '',
        platform: 'manual',
        servings: 1,
        fromFridgeCookingComplete: false,
        fromCookingFlow: false,
        isFreeform: true,
        cookedAt: picked.cookedAt,
      );
      if (submitted == true && mounted) {
        await _loadFeedReviews();
      }
      return;
    }

    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (!mounted) return;
    if (parseResponse == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('레시피를 불러올 수 없습니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final source = parseResponse.source;
    final recipe = parseResponse.recipe;
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final creatorUsername = uploader.isNotEmpty
        ? (uploader.startsWith('@') ? uploader : '@$uploader')
        : (channel.isNotEmpty
              ? (channel.startsWith('@') ? channel : '@$channel')
              : '@Yorigo');
    final submitted = await showProgressiveRecipeReviewPopup(
      context,
      recipeId: recipeId,
      recipeTitle: recipe.name ?? '레시피',
      creatorUsername: creatorUsername,
      platform: source['platform'] as String? ?? '',
      thumbnailUrl: source['thumbnail'] as String?,
      servings: recipe.servings ?? 2,
      fromFridgeCookingComplete: false,
      cookedAt: picked.cookedAt,
    );
    if (submitted == true && mounted) {
      await _loadFeedReviews();
    }
  }

  Widget _buildGuestLockedFeed(Brightness brightness) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GuestLockedPreviewBackdrop(
          asset: 'assets/community_preview.png',
          extendAboveBy: _tabBarHeight,
        ),
        GuestLockedPromptAlign(
          extraTopLift: -_tabBarHeight / 2,
          child: Container(
            width: 272,
            padding: const EdgeInsets.fromLTRB(27, 27, 27, 27),
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
                      'assets/icons/nav_community.png',
                      width: 24,
                      height: 24,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '요리 후기, 여기 다 있어요',
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
                  '로그인 한 번으로 이웃들의 요리 후기와\n특별한 레시피를 모두 확인해 보세요!',
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

  // 모임(32)·챌린지(48)는 배포 전까지 탭에서 숨김.
  static const List<double> _tabWidths = [32, 48, 64, 32]; // , 32, 48];
  static const List<String> _communityTabLabels = [
    '피드',
    '팔로잉',
    '속닥속닥',
    '랭킹',
    // '모임',
    // '챌린지',
  ];
  static const double _tabSpacing = 14;
  static const double _tabBarLeftPadding = 16;
  static const double _tabBarHeight = 48;
  static const double _tabIndicatorThickness = 2.5;
  static const double _tabBarContentGap = 10;
  static const Duration _kCommunityTabBarShowDuration = Duration(
    milliseconds: 340,
  );
  static const Duration _kCommunityTabBarHideDuration = Duration(
    milliseconds: 260,
  );
  /// 나타날 때: 빠르게 출발해 부드럽게 착지.
  static const Cubic _kCommunityTabBarShowCurve = Cubic(0.16, 1, 0.3, 1);
  /// 사라질 때: 살짝 머무르다 빠르게 올라감.
  static const Cubic _kCommunityTabBarHideCurve = Cubic(0.4, 0, 0.2, 1);
  static const ScrollPhysics _communityScrollPhysics = BouncingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  double get _communityTabBarContentWidth {
    var width = _tabBarLeftPadding * 2;
    for (var i = 0; i < _tabWidths.length; i++) {
      width += _tabWidths[i];
      if (i > 0) width += _tabSpacing;
    }
    return width;
  }

  void _ensureCommunityTabLabelVisible(int index) {
    final controller = _communityTabBarScrollController;
    if (!controller.hasClients) return;
    var left = _tabBarLeftPadding;
    for (var i = 0; i < index; i++) {
      left += _tabWidths[i] + _tabSpacing;
    }
    final right = left + _tabWidths[index];
    final view = controller.position.viewportDimension;
    final offset = controller.offset;
    double? target;
    if (left < offset + 8) {
      target = (left - _tabBarLeftPadding).clamp(0, controller.position.maxScrollExtent);
    } else if (right > offset + view - 8) {
      target = (right - view + _tabBarLeftPadding)
          .clamp(0, controller.position.maxScrollExtent);
    }
    if (target == null) return;
    unawaited(
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _selectCommunityTopTab(int index) {
    if (!mounted) return;
    if (index == 1) {
      unawaited(_loadFollowingUserIds());
      final followingCount = _filteredFeedReviews(
        _feedReviews,
        followingOnly: true,
      ).length;
      if (followingCount < _kFeedPageSize) {
        unawaited(_loadMoreFeedReviews());
      }
    }
    setState(() {
      _selectedTopTab = index;
      _communityTabBarVisible = true;
      _communityScrollPixels = 0;
      _trendBrowseAllRecipes = false;
      _browseRecipes.clear();
      _browseLastCursor = null;
      _browseHasMore = true;
      _browseError = null;
      _communityFabCollapsed = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureCommunityTabLabelVisible(index);
      _scrollCommunityTabToTop(index);
    });
  }

  Widget _buildTopTabBar(Brightness brightness) {
    final labels = _communityTabLabels;
    final bg = AppColors.getBackground(brightness);
    final borderLine = AppColors.getBorder(brightness);

    final selectedIndex = _selectedTopTab.clamp(0, labels.length - 1).toInt();
    final indicatorLeft =
        _tabBarLeftPadding +
        List<double>.generate(
          selectedIndex,
          (index) => _tabWidths[index] + _tabSpacing,
        ).fold<double>(0, (total, value) => total + value);
    final indicatorWidth = _tabWidths[selectedIndex];
    final contentWidth = _communityTabBarContentWidth;

    return ColoredBox(
      color: bg,
      child: SizedBox(
        width: double.infinity,
        height: _tabBarHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 1,
              child: Container(color: borderLine),
            ),
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final minWidth = constraints.maxWidth;
                  final rowWidth =
                      contentWidth > minWidth ? contentWidth : minWidth;
                  return SingleChildScrollView(
                    controller: _communityTabBarScrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: SizedBox(
                      width: rowWidth,
                      height: _tabBarHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          AnimatedPositioned(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            left: indicatorLeft,
                            bottom: 0,
                            width: indicatorWidth,
                            height: _tabIndicatorThickness,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: _tabOrange,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: _tabBarLeftPadding,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                for (var index = 0; index < labels.length; index++) ...[
                                  if (index > 0) const SizedBox(width: _tabSpacing),
                                  SizedBox(
                                    width: _tabWidths[index],
                                    height: _tabBarHeight,
                                    child: GestureDetector(
                                      onTap: () async {
                                        final canOpenFeed =
                                            await _ensureGuestCanOpenFeed();
                                        if (!canOpenFeed) return;
                                        _selectCommunityTopTab(index);
                                      },
                                      behavior: HitTestBehavior.opaque,
                                      child: Center(
                                        child: Text(
                                          labels[index],
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.visible,
                                          style: TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            color: _selectedTopTab == index
                                                ? _tabActiveText
                                                : _tabInactiveText,
                                            height: 24 / 16,
                                          ),
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

  /// Search row: back replaces GO logo inside the pill when browsing all recipes.
  Widget _buildTrendSearchBar(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    return _TrendSearchBar(
      controller: _trendSearchController,
      focusNode: _trendSearchFocus,
      browseAll: _trendBrowseAllRecipes,
      leading: _trendBrowseAllRecipes
          ? RecipeSearchLeadingBackButton(
              color: textPrimary,
              onPressed: () {
                setState(() {
                  _trendBrowseAllRecipes = false;
                  _trendSearchController.clear();
                  _trendSearchQuery = '';
                  _browseRecipes.clear();
                  _browseLastCursor = null;
                  _browseHasMore = true;
                  _browseError = null;
                });
                _trendSearchFocus.unfocus();
              },
            )
          : null,
      onActivateBrowse: () {
        if (!_trendBrowseAllRecipes) {
          setState(() {
            _trendBrowseAllRecipes = true;
            _browseRecipes.clear();
            _browseLastCursor = null;
            _browseHasMore = true;
            _browseError = null;
          });
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _loadBrowseInitial(),
          );
        }
      },
    );
  }

  // ignore: unused_element
  Widget _buildTrendTabContent(Brightness brightness) {
    _syncExploreCacheGeneration();
    final bottomSliverSpacing = MediaQuery.of(context).padding.bottom + 36;
    final future = _cachedExploreFuture ??= _recipeService
        .getExploreRecipesForGuests(limit: _kExploreGuestListLimit);

    // Search bar is the first sliver / first list row so it scrolls with content.
    // IndexedStack keeps 트렌드 + browse list mounted for image cache (still one TextField).
    return IndexedStack(
      index: _trendBrowseAllRecipes ? 1 : 0,
      sizing: StackFit.expand,
      children: [
        FutureBuilder<List<Map<String, dynamic>>>(
          future: future,
          builder: (context, snapshot) {
            final allRecipes = snapshot.data ?? [];
            final isLoading =
                snapshot.connectionState == ConnectionState.waiting;
            final hasError = snapshot.hasError;
            final searchSliver = SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  _sectionPaddingH,
                  _trendSearchBarTopPadding,
                  _sectionPaddingH,
                  _trendSearchBarToFirstSectionGap,
                ),
                child: _buildTrendSearchBar(brightness),
              ),
            );

            if (isLoading && allRecipes.isEmpty && !hasError) {
              return CustomScrollView(
                slivers: [
                  searchSliver,
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
              );
            }
            if (hasError || allRecipes.isEmpty) {
              return CustomScrollView(
                slivers: [
                  searchSliver,
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          '아직 표시할 레시피가 없어요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            color: AppColors.getTextSecondary(brightness),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            final currentMonth = DateTime.now().month;
            final seasonalRecipes = _filterSeasonalRecipes(
              allRecipes,
              currentMonth,
            );

            return CustomScrollView(
              slivers: [
                searchSliver,
                if (seasonalRecipes.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _SeasonalSectionBlock(
                      month: currentMonth,
                      seasonalRecipes: seasonalRecipes,
                      brightness: brightness,
                      onRecipeTap: (recipe) => _onRecipeTap(recipe),
                    ),
                  ),
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final config = _sections[index];
                    final sectionRecipes = _filterForSection(
                      allRecipes,
                      config,
                    );
                    if (sectionRecipes.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _SectionBlock(
                      subtitle: config.subtitle,
                      title: config.title,
                      recipes: sectionRecipes,
                      brightness: brightness,
                      isFirstSection: seasonalRecipes.isEmpty && index == 0,
                      onSeeMore: () =>
                          _onSeeMore(config.title, allRecipes, config),
                      onRecipeTap: (recipe) => _onRecipeTap(recipe),
                      showTimeBadge: config.timeMaxMinutes != null,
                    );
                  }, childCount: _sections.length),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(height: bottomSliverSpacing),
                ),
              ],
            );
          },
        ),
        _buildTrendBrowseListBody(brightness),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildHotNewSection(
    Color textPrimary,
    Color textTertiary,
    Brightness brightness,
  ) {
    if (_hotNewLoading && _hotNewRecipes.isEmpty) {
      return const SizedBox(height: 16);
    }
    if (_hotNewRecipes.isEmpty) return const SizedBox(height: 16);

    final recipes = _hotNewRecipes;
    if (recipes.isEmpty) return const SizedBox(height: 16);

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Hot & New',
                  style: TextStyle(
                    fontFamily: 'Caveat',
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: _orange,
                    letterSpacing: 0.5,
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '인기 레시피',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: textPrimary,
                          letterSpacing: -0.4,
                          height: 24 / 19,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _openHotNewAll,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '더보기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: textTertiary,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 175 + 50,
            child: ListView.separated(
              controller: _hotNewScrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: recipes.length + (_hotNewLoadingMore ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                if (index >= recipes.length) {
                  return const SizedBox(
                    width: 28,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                return _buildHotNewCard(recipes[index], brightness);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHotNewCard(Map<String, dynamic> recipe, Brightness brightness) {
    const cardWidth = 140.0;
    const imageHeight = 175.0;
    const radius = 18.0;

    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final title =
        (recipe['title'] as String?) ??
        (recipeData['title'] as String?) ??
        (recipeData['name'] as String?) ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(
      recipe,
      preferCroppedForInstagram: true,
    );
    final platform = (source['platform'] as String?) ?? '';
    final sourceUrl =
        (recipe['sourceUrl'] as String?)?.trim() ??
        (source['url'] as String?)?.trim() ??
        '';
    final imageFit = _trendCardImageFit(platform, sourceUrl);
    String creator = '@';
    final uploader = source['uploader']?.toString() ?? '';
    final channel = source['channel']?.toString() ?? '';
    if (uploader.isNotEmpty) {
      creator = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creator = channel.startsWith('@') ? channel : '@$channel';
    } else {
      creator = '@요리';
    }

    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    return GestureDetector(
      onTap: () => _onHotNewRecipeTap(recipe),
      child: SizedBox(
        width: cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: cardWidth,
              height: imageHeight,
              decoration: BoxDecoration(
                color: AppColors.getBorder(brightness),
                borderRadius: BorderRadius.circular(radius),
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
                      color: AppColors.getBorder(brightness),
                      child: ThumbnailLetterboxMitigation(
                        platform: platform,
                        imageUrl: thumbnailUrl,
                        sourceUrl: sourceUrl,
                        child: AppNetworkImage(
                          imageUrl: thumbnailUrl,
                          fit: imageFit,
                          width: cardWidth,
                          height: imageHeight,
                          memCacheWidth: AppNetworkImage.listThumbCacheSize,
                          memCacheHeight: AppNetworkImage.listThumbCacheSize,
                          brightness: brightness,
                          placeholder: Container(
                            width: cardWidth,
                            height: imageHeight,
                            color: AppColors.getBorder(brightness),
                            child: Icon(
                              Icons.restaurant,
                              size: 48,
                              color: textTertiary,
                            ),
                          ),
                          errorWidget: Icon(
                            Icons.restaurant,
                            size: 48,
                            color: textTertiary,
                          ),
                        ),
                      ),
                    )
                  : Icon(Icons.restaurant, size: 48, color: textTertiary),
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
                _buildHotNewPlatformIcon(platform, 14, brightness),
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
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildHotGroupsSection(
    Color textPrimary,
    Color textTertiary,
    Brightness brightness,
  ) {
    if (_hotGroupsLoading && _hotGroups.isEmpty) {
      return const SizedBox(height: 16);
    }
    if (_hotGroups.isEmpty) return const SizedBox(height: 0);

    final groups = _hotGroups;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Hot Topics',
                  style: TextStyle(
                    fontFamily: 'Caveat',
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: _orange,
                    letterSpacing: 0.5,
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -4),
                  child: Text(
                    '핫한 레시피',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: textPrimary,
                      letterSpacing: -0.4,
                      height: 24 / 19,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 175 + 38,
            child: ListView.separated(
              controller: _hotGroupsScrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: groups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                return _buildHotGroupCard(groups[index], brightness);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHotGroupCard(Map<String, dynamic> group, Brightness brightness) {
    const cardWidth = 140.0;
    const imageHeight = 175.0;
    const radius = 18.0;

    final name = (group['name'] as String?)?.trim() ?? '';
    final count = (group['count'] is num) ? (group['count'] as num).toInt() : 0;
    final thumbnailUrl = (group['latestThumbnailUrl'] as String?)?.trim() ?? '';
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    return GestureDetector(
      onTap: () => _onHotGroupTap(group),
      child: SizedBox(
        width: cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                Container(
                  width: cardWidth,
                  height: imageHeight,
                  decoration: BoxDecoration(
                    color: AppColors.getBorder(brightness),
                    borderRadius: BorderRadius.circular(radius),
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
                      ? AppNetworkImage(
                          imageUrl: thumbnailUrl,
                          fit: BoxFit.cover,
                          width: cardWidth,
                          height: imageHeight,
                          memCacheWidth: AppNetworkImage.listThumbCacheSize,
                          memCacheHeight: AppNetworkImage.listThumbCacheSize,
                          brightness: brightness,
                          placeholder: Container(
                            width: cardWidth,
                            height: imageHeight,
                            color: AppColors.getBorder(brightness),
                            child: Icon(
                              Icons.restaurant,
                              size: 48,
                              color: textTertiary,
                            ),
                          ),
                          errorWidget: Icon(
                            Icons.restaurant,
                            size: 48,
                            color: textTertiary,
                          ),
                        )
                      : Icon(Icons.restaurant, size: 48, color: textTertiary),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.0,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              name.isNotEmpty ? name : '레시피',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: textPrimary,
                letterSpacing: -0.33,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHotNewPlatformIcon(
    String platform,
    double size,
    Brightness brightness,
  ) {
    String? assetPath;
    final p = platform.toLowerCase();
    if (p == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (p == 'instagram' || p == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (p == 'tiktok' || p == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
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

  List<Map<String, dynamic>> _filteredFeedReviews(
    List<Map<String, dynamic>> source, {
    bool followingOnly = false,
  }) {
    Iterable<Map<String, dynamic>> reviews = source;
    if (followingOnly) {
      final following = _followingUserIdsNotifier.value ?? <String>{};
      reviews = reviews.where((review) {
        final uid = review['userId'] as String? ?? '';
        return following.contains(uid);
      });
    }
    return reviews.toList();
  }

  Widget _buildFeedTabContent(
    Brightness brightness, {
    bool followingOnly = false,
    ScrollController? controller,
  }) {
    final sorted = _filteredFeedReviews(
      _feedReviews,
      followingOnly: followingOnly,
    );
    final showHeader = followingOnly;
    final headerCount = showHeader ? 1 : 0;
    final showMoreSpinner =
        _feedLoadingMore && sorted.isNotEmpty && _feedHasMore;
    final bodyCount = sorted.isEmpty ? 1 : sorted.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: AppRefreshIndicator(
            onRefresh: () async {
              await _loadFeedReviews();
              if (followingOnly) await _loadFollowingUserIds();
            },
            child: ListView.builder(
              controller: controller ??
                  (followingOnly
                      ? _followingScrollController
                      : _feedScrollController),
              physics: _communityScrollPhysics,
              cacheExtent: 600,
              padding: const EdgeInsets.only(
                top: _tabBarContentGap,
                bottom: 24,
              ),
              itemCount:
                  headerCount + bodyCount + (showMoreSpinner ? 1 : 0),
              itemBuilder: (context, index) {
                final contentIndex = index;
                if (showHeader && contentIndex == 0) {
                  return _buildFollowingAvatarRail(brightness);
                }
                if (showMoreSpinner &&
                    index == headerCount + bodyCount) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                if (_feedLoading && sorted.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: CommunityFeedShimmer(),
                  );
                }
                if (sorted.isEmpty) {
                  if (_feedHasMore && !_feedLoading && !_feedLoadingMore) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      unawaited(_loadMoreFeedReviews());
                    });
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Center(
                      child: Text(
                        followingOnly
                            ? (_feedLoadingMore
                                ? '팔로잉한 요리 기록을 찾는 중...'
                                : '팔로잉한 요리 기록이 없어요')
                            : '아직 후기가 없어요',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      ),
                    ),
                  );
                }
                final reviewIndex = contentIndex - headerCount;
                _maybePrefetchFeed(
                  reviewIndex: reviewIndex,
                  visibleCount: sorted.length,
                );
                final review = sorted[reviewIndex];
                final reviewId = review['id'] as String? ?? '';
                final recipeId = review['recipeId'] as String? ?? '';
                final key = _reviewKeys.putIfAbsent(
                  reviewId,
                  () => GlobalKey(debugLabel: 'feed_$reviewId'),
                );
                return Padding(
                  key: key,
                  padding: EdgeInsets.only(
                    bottom: reviewIndex < sorted.length - 1 ? 8 : 0,
                  ),
                  child: RecipeIdSignalImpression(
                    screen: 'community_feed',
                    recipeId: recipeId,
                    sectionId: 'feed_post',
                    position: reviewIndex,
                    child: _FeedPostCard(
                    review: review,
                    userDataCache: _feedUserDataCache,
                    recipeTags: _feedRecipeTagsCache[recipeId] ?? [],
                    recipeAverageRating: _feedRecipeAverageRating[recipeId],
                    recipeReviewCount: _feedRecipeReviewCount[recipeId] ?? 0,
                    brightness: brightness,
                    isLiked: _feedLikedStatus[reviewId] ?? false,
                    likeCount: _feedLikeCounts[reviewId] ?? 0,
                    commentCount: _feedCommentCounts[reviewId] ?? 0,
                    isBookmarked: _feedBookmarkedStatus[recipeId] ?? false,
                    showLikingHeart: _feedLikingReviewId == reviewId,
                    onLike: () => _handleFeedLike(reviewId),
                    onImageDoubleTap: () =>
                        _handleFeedLike(reviewId, onlyLike: true),
                    onComment: () =>
                        _showFeedCommentModal(context, review, brightness),
                    onBookmark: () {
                      if (recipeId.isNotEmpty) {
                        _handleFeedBookmark(recipeId);
                      } else {
                        showAppSnackBar(context, 
                          const SnackBar(
                            content: Text('레시피 ID를 찾을 수 없습니다'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                    onDelete: () {
                      final isOwn =
                          (_auth.currentUser?.uid ?? '') ==
                          (review['userId'] as String? ?? '');
                      _handleFeedDelete(
                        reviewId,
                        allowAdminOverride: !isOwn && _isAdmin,
                      );
                    },
                    onEdit:
                        ((_auth.currentUser?.uid ?? '') ==
                            (review['userId'] as String? ?? ''))
                        ? () => _handleFeedEdit(review)
                        : null,
                    onBlockUser: () => _handleFeedBlockUser(
                      blockedUserId: review['userId'] as String? ?? '',
                      reviewId: reviewId,
                    ),
                    onReportSubmitted: () {
                      if (!mounted) return;
                      setState(() {
                        _feedReviews.removeWhere(
                          (r) => (r['id'] as String?) == reviewId,
                        );
                      });
                    },
                    isOwnPost:
                        (_auth.currentUser?.uid ?? '') ==
                        (review['userId'] as String? ?? ''),
                    isAdmin: _isAdmin,
                    followAuthorId: review['userId'] as String?,
                    followingIdsListenable: _followingUserIdsNotifier,
                    onToggleFollow: () =>
                        _handleFeedFollowToggle(review['userId'] as String?),
                    onProfileTap: _canOpenUserProfile(
                          review['userId'] as String?,
                        )
                        ? () => _openUserProfile(review['userId'] as String?)
                        : null,
                    onRecipeTap: NavGuard.once(() async {
                      if (recipeId.isEmpty) return;
                      AnalyticsService().noteRecipeOpenSource(
                        recipeId: recipeId,
                        screen: 'community_feed',
                        sectionId: 'feed_post',
                      );
                      try {
                        final parseResponse = await _recipeService
                            .getRecipeById(recipeId);
                        if (!context.mounted) return;
                        if (parseResponse != null) {
                          Navigator.push(
                            context,
                            CupertinoPageRoute(
                              builder: (context) => RecipeDetailScreen(
                                parseResponse: parseResponse,
                                recipeId: recipeId,
                              ),
                            ),
                          );
                        } else {
                          showAppSnackBar(context, 
                            const SnackBar(
                              content: Text('레시피를 찾을 수 없습니다'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          showAppSnackBar(context, 
                            SnackBar(
                              content: Text('레시피를 불러올 수 없습니다: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    }),
                  ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBoardTabContent(Brightness brightness) {
    // The compose entry is rendered as a board-specific FAB via the parent
    // Scaffold's floatingActionButton slot — same pattern as 당근 동네생활 /
    // 네이버 카페 / 카카오 오픈채팅. Keeping it out of the scroll content
    // means it stays one tap away regardless of scroll position.
    final categoryPills = Container(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final c in BoardCategory.values) ...[
                    _buildBoardPill(c),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
    );

    final posts = _boardPostsCache ?? const <BoardPost>[];
    final showLoading = _boardPostsLoading && _boardPostsCache == null;
    final showError =
        _boardPostsError != null && _boardPostsCache == null && !showLoading;
    final showEmpty = !showLoading && !showError && posts.isEmpty;
    final bodyCount = showLoading || showError || showEmpty ? 1 : posts.length;

    return AppRefreshIndicator(
      onRefresh: () => _fetchBoardPostsFallback(fromServer: true),
      child: ListView.builder(
        controller: _boardScrollController,
        physics: _communityScrollPhysics,
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 96),
        itemCount: 1 + bodyCount,
        itemBuilder: (context, i) {
          if (i == 0) return categoryPills;
          if (showLoading) {
            return const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (showError) {
            return _buildBoardErrorState(_boardPostsError ?? '');
          }
          if (showEmpty) return _buildBoardEmptyState();
          return _buildBoardPostCard(brightness, posts[i - 1]);
        },
      ),
    );
  }

  /// Board-only compose FAB. Visually distinct from the recipe-review pill
  /// FAB used on the feed: solid circular brand chip with a pencil glyph,
  /// matching the pattern 당근 / 네이버 카페 / 카카오 오픈채팅 use for "글쓰기".
  Widget _buildBoardComposeFab() {
    return Semantics(
      button: true,
      label: '게시글 쓰기',
      child: GestureDetector(
        onTap: _openBoardCompose,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF8A1F), Color(0xFFFF7300), Color(0xFFFF5A00)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF5722).withValues(alpha: 0.32),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: const Color(0xFFFF8A50).withValues(alpha: 0.18),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.edit_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }

  Future<void> _openBoardCompose() async {
    if (_auth.currentUser == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('로그인이 필요합니다')));
      return;
    }
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            BoardComposeScreen.create(initialCategory: _selectedBoardCategory),
        fullscreenDialog: true,
      ),
    );
    if (!mounted) return;
    if (result is String && result.isNotEmpty) {
      setState(() {
        _refreshBoardPosts();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('게시글이 등록됐어요')));
    }
  }

  Widget _buildBoardEmptyState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 80),
      child: Column(
        children: [
        const SizedBox(height: 32),
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFFFF5EC),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.forum_rounded,
            color: Color(0xFFFF7300),
            size: 30,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          '아직 글이 없어요',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '고민이든 조언이든, 첫 속닥을 시작해보세요',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            color: Color(0xFF6B7280),
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildBoardErrorState(String error) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Center(
        child: Text(
          '속닥속닥을 불러올 수 없어요\n$error',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            color: Color(0xFF6B7280),
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildBoardPostCard(Brightness brightness, BoardPost post) {
    final textSecondary = AppColors.getTextSecondary(brightness);
    final categoryLabel = BoardCategory.fromId(post.category).label;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BoardPostDetailScreen(postId: post.id),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(
            bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildBoardTag(categoryLabel),
                      const SizedBox(height: 10),
                      Text(
                        post.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                          height: 1.28,
                          letterSpacing: -0.35,
                        ),
                      ),
                      if (post.body.trim().isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          post.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: textSecondary,
                            letterSpacing: -0.2,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (post.hasTaggedRecipe) ...[
                  const SizedBox(width: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x14000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 64,
                        height: 80,
                        child: (post.recipeThumbnailUrl ?? '').isEmpty
                            ? const ColoredBox(
                                color: Color(0xFFF3F4F6),
                                child: Icon(
                                  Icons.restaurant_rounded,
                                  color: Color(0xFF9CA3AF),
                                ),
                              )
                            : AppNetworkImage(
                                imageUrl: post.recipeThumbnailUrl!,
                                fit: BoxFit.cover,
                                width: 64,
                                height: 80,
                              ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatCommunityTimeAgo(post.createdAt)}'
                    '${post.viewCount > 0 ? ' · 조회 ${post.viewCount}' : ''}',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                _buildBoardMeta(
                  icon: Icons.favorite_border_rounded,
                  label: '${post.likeCount}',
                ),
                const SizedBox(width: 12),
                _buildBoardMeta(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: '${post.commentCount}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Pull a user doc into [_feedUserDataCache] so board cards show the right
  /// author name on the second build instead of "요리친구" forever.
  Future<void> _lazyLoadUserDoc(String uid) async {
    final session = _sessionFeedUserCache[uid];
    if (session != null) {
      if (_feedUserDataCache[uid] != session) {
        setState(() => _feedUserDataCache[uid] = session);
      }
      return;
    }
    if (_feedUserDataCache.containsKey(uid)) return;
    // Insert a sentinel to prevent reentrant loads.
    _feedUserDataCache[uid] = const <String, dynamic>{};
    try {
      final doc = await _userService.getUserDocument(uid);
      final data = doc.data() as Map<String, dynamic>?;
      final resolved = data ?? const <String, dynamic>{};
      _sessionFeedUserCache[uid] = resolved;
      if (!mounted) return;
      setState(() {
        _feedUserDataCache[uid] = resolved;
      });
    } catch (_) {
      // Leave the sentinel so we don't hammer the network on failure.
    }
  }

  Widget _buildBoardPill(BoardCategory category) {
    final selected = category.id == _selectedBoardCategory.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _selectedBoardCategory = category;
        _boardPostsCache = null;
        _refreshBoardPosts();
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF111827) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFF111827) : const Color(0xFFEDEFF3),
            width: 0.8,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          category.label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : const Color(0xFF6B7280),
            letterSpacing: -0.25,
          ),
        ),
      ),
    );
  }

  Widget _buildBoardTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(width: 0.67, color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4B5563),
          height: 1.4,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  Widget _buildBoardMeta({required IconData icon, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 14, color: const Color(0xFF8B95A1)),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8B95A1),
            height: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildFollowingAvatarRail(Brightness brightness) {
    if (_followingUsers.isEmpty) return const SizedBox.shrink();
    final users = _followingUsers.take(20).toList();
    return Container(
      height: 112,
      color: AppColors.getBackground(brightness),
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: users.length,
        separatorBuilder: (_, __) => const SizedBox(width: 13),
        itemBuilder: (context, index) {
          final user = users[index];
          final name = (user['name']?.toString().trim().isNotEmpty == true
              ? user['name'].toString().trim()
              : (user['handle']?.toString().trim().isNotEmpty == true
                    ? user['handle'].toString().trim()
                    : '요리친구'));
          final photoUrl = user['photoUrl']?.toString().trim() ?? '';
          final uid = user['uid']?.toString() ?? '';
          final fallbackSeed = uid.isNotEmpty ? uid : name;
          final initialFallback = UserInitialAvatar(
            seed: fallbackSeed,
            name: name,
            size: 54,
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _canOpenUserProfile(uid)
                ? () => _openUserProfile(uid)
                : null,
            child: SizedBox(
              width: 58,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFF7518), width: 1.4),
                    ),
                    child: ClipOval(
                      child: photoUrl.isNotEmpty
                          ? AppNetworkImage(
                              imageUrl: photoUrl,
                              width: 54,
                              height: 54,
                              fit: BoxFit.cover,
                              errorWidget: initialFallback,
                            )
                          : initialFallback,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    name.startsWith('@') ? name.substring(1) : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF6B7280),
                      letterSpacing: -0.25,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFollowingTabContent(Brightness brightness) {
    if (_followingUserIdsNotifier.value == null && !_followingLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadFollowingUserIds());
      });
    }
    if (_followingLoading && _followingUserIdsNotifier.value == null) {
      return ListView(
        controller: _followingScrollController,
        physics: _communityScrollPhysics,
        padding: const EdgeInsets.only(top: _tabBarContentGap),
        children: const [
          CommunityFeedShimmer(includeFollowingRail: true),
        ],
      );
    }
    if ((_followingUserIdsNotifier.value ?? <String>{}).isEmpty) {
      return AppRefreshIndicator(
        onRefresh: _loadFollowingUserIds,
        child: ListView(
          controller: _followingScrollController,
          physics: _communityScrollPhysics,
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SizedBox(height: 44),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildFollowingEmptyCard(brightness),
            ),
          ],
        ),
      );
    }
    return _buildFeedTabContent(brightness, followingOnly: true);
  }

  Widget _buildFollowingEmptyCard(Brightness brightness) {
    final textSecondary = AppColors.getTextSecondary(brightness);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFF0F1F3), width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Color(0xFFFFF3EA),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.group_rounded, color: _orange, size: 26),
          ),
          const SizedBox(height: 16),
          const Text(
            '팔로잉한 요리 친구가 없어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '마음에 드는 요리 기록 작성자를 팔로우하면\n여기에서 새 요리 기록만 모아볼 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textSecondary,
              height: 1.5,
              letterSpacing: -0.25,
            ),
          ),
        ],
      ),
    );
  }

  /// Figma 97-1998 static 1:1 mockup — no database wiring, layout and visuals only.
  // ignore: unused_element
  Widget _buildFigmaMockupTabContent(Brightness brightness) {
    return ListView(padding: EdgeInsets.zero, children: [_FigmaMockupPost()]);
  }

  // ignore: unused_element
  Widget _buildPlaceholderTabContent(Brightness brightness) {
    final textColor = AppColors.getTextTertiary(brightness);
    return Center(
      child: Text(
        '곧 이어서 볼 수 있어요',
        style: TextStyle(fontSize: 15, color: textColor),
      ),
    );
  }

  List<Map<String, dynamic>> _filterForSection(
    List<Map<String, dynamic>> recipes,
    _SectionConfig config,
  ) {
    if (config.title == '건강식') {
      return _filterHealthyRecipes(recipes);
    }
    if (config.timeMaxMinutes != null) {
      final list = <Map<String, dynamic>>[];
      for (final r in recipes) {
        if (_getTotalMinutes(r) <= config.timeMaxMinutes!) list.add(r);
      }
      _sortByParsedAtDesc(list);
      return list;
    }
    if (config.caloriesMax != null) {
      final list = <Map<String, dynamic>>[];
      for (final r in recipes) {
        final cal = (r['calories'] as num?)?.toDouble();
        if (cal != null && cal > 0 && cal <= config.caloriesMax!) list.add(r);
      }
      return list;
    }
    if (config.proteinMin != null) {
      final list = <Map<String, dynamic>>[];
      for (final r in recipes) {
        final nutrition = r['nutrition'] as Map<String, dynamic>?;
        final llm = nutrition?['llm_estimate'] as Map<String, dynamic>?;
        final protein = (llm?['protein_g'] as num?)?.toDouble();
        if (protein != null && protein >= config.proteinMin!) list.add(r);
      }
      _sortByProteinDesc(list);
      return list;
    }
    return recipes;
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

  void _onSeeMore(
    String sectionTitle,
    List<Map<String, dynamic>> allRecipes,
    _SectionConfig config,
  ) {
    final filtered = _filterForSection(allRecipes, config);
    if (filtered.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _CategoryListPage(
          title: sectionTitle,
          recipes: filtered,
          onRecipeTap: _onRecipeTap,
        ),
      ),
    );
  }

  void _onRecipeTap(Map<String, dynamic> recipe) {
    NavGuard.once(() async {
      final recipeId = recipe['id'] as String? ?? '';
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
}

/// Compact follow toggle that sits inside the feed post header.
/// Refined warm amber gradient when CTA, soft neutral pill when following.
class _FeedFollowChip extends StatelessWidget {
  const _FeedFollowChip({required this.isFollowing, required this.onTap});

  final bool isFollowing;
  final VoidCallback onTap;

  // Slightly muted warm-amber palette (less neon than the brand orange) so
  // the per-post chip feels premium rather than alert-style.
  static const Color _ctaTop = Color(0xFFFF9145);
  static const Color _ctaBottom = Color(0xFFE85A1A);
  static const Color _ctaShadow = Color(0x33E85A1A); // ~0.20 alpha

  @override
  Widget build(BuildContext context) {
    final following = isFollowing;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(100),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: following ? Colors.white : null,
            gradient: following
                ? null
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_ctaTop, _ctaBottom],
                  ),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: following
                  ? const Color(0xFFE5E7EB)
                  : Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: following
                ? null
                : const [
                    BoxShadow(
                      color: _ctaShadow,
                      blurRadius: 10,
                      offset: Offset(0, 3),
                      spreadRadius: -2,
                    ),
                  ],
          ),
          child: Text(
            following ? '팔로잉' : '팔로우',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: following ? const Color(0xFF6B7280) : Colors.white,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedProfileAvatar extends StatefulWidget {
  const _FeedProfileAvatar({
    required this.profilePhotoUrl,
    required this.seed,
    required this.name,
  });
  final String? profilePhotoUrl;
  final String seed;
  final String name;

  @override
  State<_FeedProfileAvatar> createState() => _FeedProfileAvatarState();
}

class _FeedProfileAvatarState extends State<_FeedProfileAvatar> {
  bool _networkFailed = false;

  @override
  void didUpdateWidget(covariant _FeedProfileAvatar old) {
    super.didUpdateWidget(old);
    if (old.profilePhotoUrl != widget.profilePhotoUrl) {
      _networkFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.profilePhotoUrl;
    final hasUrl = url != null && url.isNotEmpty && !_networkFailed;
    return ClipOval(
      child: SizedBox(
        width: 34,
        height: 34,
        child: hasUrl
            ? Image.network(
                url,
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _networkFailed = true);
                  });
                  return _initialAvatar();
                },
              )
            : _initialAvatar(),
      ),
    );
  }

  Widget _initialAvatar() {
    return UserInitialAvatar(
      seed: widget.seed,
      name: widget.name,
      size: 34,
      fontSize: 14,
    );
  }
}

String? _resolveProfileUrl(
  Map<String, dynamic> userData,
  Map<String, dynamic> review,
) {
  final fromUser = resolveUserPhotoUrl(userData);
  if (fromUser != null && fromUser.isNotEmpty) return fromUser;
  final fromReview = [
    review['userPhotoUrl'],
    review['creatorPhotoUrl'],
    review['authorPhotoUrl'],
  ];
  for (final c in fromReview) {
    final v = c?.toString().trim() ?? '';
    if (v.isNotEmpty) return v;
  }
  return null;
}

/// 피드 헤더용 작성자 표시 이름.
/// `creatorUsername`은 레시피 채널/업로더 핸들이라 절대 fallback으로 쓰지 않는다.
String _resolveFeedAuthorDisplayName(
  Map<String, dynamic> userData,
  Map<String, dynamic> review,
) {
  String stripAt(String value) =>
      value.startsWith('@') ? value.substring(1) : value;

  final profileName = (userData['name'] as String?)?.trim() ?? '';
  if (profileName.isNotEmpty) return stripAt(profileName);

  final creatorName = (review['creatorName'] as String?)?.trim() ?? '';
  if (creatorName.isNotEmpty) return stripAt(creatorName);

  final handle = (userData['handle'] as String?)?.trim() ?? '';
  if (handle.isNotEmpty) return stripAt(handle);

  return '사용자';
}

/// Resolve all review photo URLs for the community feed post card.
/// Prefers `photoUrls` (multi-photo); falls back to legacy single `photoUrl`.
List<String> _resolvePostPhotoUrls(Map<String, dynamic> review) {
  final raw = review['photoUrls'];
  final urls = <String>[];
  if (raw is List) {
    for (final u in raw) {
      final s = u?.toString().trim() ?? '';
      if (s.isNotEmpty) urls.add(s);
    }
  }
  if (urls.isEmpty) {
    final single = (review['photoUrl'] as String?)?.trim() ?? '';
    if (single.isNotEmpty) urls.add(single);
  }
  return urls;
}

// Figma 97-1998: custom feed post UI — header, image, recipe card, actions, description. Filled from review data.
class _FeedPostCard extends StatelessWidget {
  const _FeedPostCard({
    required this.review,
    required this.userDataCache,
    required this.recipeTags,
    this.recipeAverageRating,
    required this.recipeReviewCount,
    required this.brightness,
    required this.isLiked,
    required this.likeCount,
    required this.commentCount,
    required this.isBookmarked,
    required this.showLikingHeart,
    required this.onLike,
    required this.onImageDoubleTap,
    required this.onComment,
    required this.onBookmark,
    required this.onDelete,
    required this.onBlockUser,
    required this.onReportSubmitted,
    required this.isOwnPost,
    this.isAdmin = false,
    this.onProfileTap,
    required this.onRecipeTap,
    this.onEdit,
    this.followAuthorId,
    this.followingIdsListenable,
    this.onToggleFollow,
  });

  final Map<String, dynamic> review;
  final Map<String, Map<String, dynamic>> userDataCache;
  final List<String> recipeTags;
  final double? recipeAverageRating;
  final int recipeReviewCount;
  final Brightness brightness;
  final bool isLiked;
  final int likeCount;
  final int commentCount;
  final bool isBookmarked;
  final bool showLikingHeart;
  final VoidCallback onLike;
  final VoidCallback onImageDoubleTap;
  final VoidCallback onComment;
  final VoidCallback onBookmark;
  final VoidCallback onDelete;
  final VoidCallback onBlockUser;
  final VoidCallback onReportSubmitted;
  final bool isOwnPost;
  final bool isAdmin;
  final VoidCallback? onProfileTap;
  final VoidCallback onRecipeTap;
  final VoidCallback? onEdit;
  final String? followAuthorId;
  final ValueListenable<Set<String>?>? followingIdsListenable;
  final VoidCallback? onToggleFollow;



  Widget _buildFollowChipForAuthor() {
    final authorId = (followAuthorId ?? '').trim();
    final listenable = followingIdsListenable;
    if (onToggleFollow == null || listenable == null || authorId.isEmpty) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<Set<String>?>(
      valueListenable: listenable,
      builder: (_, ids, __) {
        if (ids == null) return const SizedBox.shrink();
        return _FeedFollowChip(
          isFollowing: ids.contains(authorId),
          onTap: onToggleFollow!,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = review['userId'] as String? ?? '';
    final userData = userDataCache[userId] ?? {};
    // creatorUsername은 레시피 채널명(영문)이라 작성자 닉네임 fallback으로 쓰지 않는다.
    final displayName = _resolveFeedAuthorDisplayName(userData, review);
    final profilePhotoUrl = _resolveProfileUrl(userData, review);
    final authorLevel = yorigoLevelFromUserData(userData);
    final timeAgo = reviewFeedTimeAgo(review);
    final cookedLabel = reviewCookedDateLabel(review);

    final photoUrls = _resolvePostPhotoUrls(review);
    final recipeTitle = review['recipeTitle'] as String? ?? '레시피';
    // 연결된 레시피가 없는(유저가 직접 올린) 후기: recipeId가 비어 있다.
    // 이 경우 레시피 북마크는 의미가 없어 숨기고, 대신 작성자 이름을 보여준다.
    final hasLinkedRecipe =
        (review['recipeId'] as String?)?.trim().isNotEmpty == true;
    final platform = review['platform'] as String? ?? '';
    final creatorUsername = review['creatorUsername'] as String? ?? '';
    final handle = creatorUsername.startsWith('@')
        ? creatorUsername
        : '@$creatorUsername';
    final comment = review['comment'] as String? ?? '';

    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);
    const cardBorder = Color(0xFFF3F4F6);
    const tagBg = Color(0xFFF9FAFB);
    const tagBorder = Color(0xFFE5E7EB);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Post header: avatar + name + time, more
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onProfileTap,
                  child: Row(
                    children: [
                      _FeedProfileAvatar(
                        profilePhotoUrl: profilePhotoUrl,
                        seed:
                            (review['userId']?.toString().trim().isNotEmpty ==
                                true)
                            ? review['userId'].toString().trim()
                            : (creatorUsername.isNotEmpty
                                  ? creatorUsername
                                  : displayName),
                        name: displayName,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: textPrimary,
                                      letterSpacing: -0.33,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(100),
                                  ),
                                  child: Text(
                                    'Lv.$authorLevel',
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF4B5563),
                                      height: 1.1,
                                      letterSpacing: -0.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (timeAgo.isNotEmpty || cookedLabel != null)
                              Text.rich(
                                TextSpan(
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 10.5,
                                    color: textTertiary,
                                    height: 1.2,
                                  ),
                                  children: [
                                    if (timeAgo.isNotEmpty) TextSpan(text: timeAgo),
                                    if (timeAgo.isNotEmpty && cookedLabel != null)
                                      const TextSpan(
                                        text: '  ·  ',
                                        style: TextStyle(color: Color(0xFFD1D5DB)),
                                      ),
                                    if (cookedLabel != null)
                                      TextSpan(text: cookedLabel),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!isOwnPost && onToggleFollow != null) ...[
                _buildFollowChipForAuthor(),
                const SizedBox(width: 4),
              ],
              IconButton(
                icon: Icon(Icons.more_horiz, size: 25, color: textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () {
                  final rid = review['id'] as String? ?? '';
                  showReviewPostMenuBottomSheet(
                    context,
                    isOwnPost: isOwnPost,
                    isAdmin: isAdmin,
                    shareText: defaultReviewShareText(review),
                    shareSubject: defaultReviewShareSubject(review),
                    onEdit: isOwnPost ? onEdit : null,
                    onDelete: (isOwnPost || isAdmin) ? onDelete : null,
                    onOpenReport: (!isOwnPost && !isAdmin && rid.isNotEmpty)
                        ? () {
                            showReviewReportBottomSheet(
                              context,
                              type: 'review',
                              targetId: rid,
                              onSubmitted: onReportSubmitted,
                            );
                          }
                        : null,
                    onBlockUser: (!isOwnPost && !isAdmin) ? onBlockUser : null,
                  );
                },
              ),
            ],
          ),
        ),
        // Full-width image (review photo) with like overlay — edge to edge, 1:1 like Instagram
        _FeedPhotoCarousel(
          photoUrls: photoUrls,
          onTap: onRecipeTap,
          onDoubleTap: onImageDoubleTap,
          showLikingHeart: showLikingHeart,
          textTertiary: textTertiary,
        ),
        // Recipe card floats slightly over the photo.
        Transform.translate(
          offset: const Offset(0, -18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: GestureDetector(
            onTap: onRecipeTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: cardBorder),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x18000000),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                    spreadRadius: -4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                recipeTitle,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: textPrimary,
                                  letterSpacing: -0.3,
                                  height: 1.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (recipeReviewCount > 0 &&
                                recipeAverageRating != null) ...[
                              const SizedBox(width: 5),
                              const Icon(
                                Icons.star_rounded,
                                size: 11,
                                color: Color(0xFFF59E0B),
                              ),
                              const SizedBox(width: 2),
                              Text(
                                recipeAverageRating!.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E2939),
                                ),
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '($recipeReviewCount)',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 10,
                                  color: Color(0xFF99A1AF),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (hasLinkedRecipe)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onBookmark,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Transform.translate(
                              offset: const Offset(0, -2),
                              child: RecipeBookmarkGlyph(
                                isBookmarked: isBookmarked,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (recipeTags.isNotEmpty ||
                      !hasLinkedRecipe ||
                      platform.isNotEmpty ||
                      handle.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        if (recipeTags.isNotEmpty)
                          Expanded(
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: recipeTags
                                  .take(3)
                                  .map((t) => _tagChip(t, tagBg, tagBorder))
                                  .toList(),
                            ),
                          )
                        else
                          const Spacer(),
                        if (!hasLinkedRecipe) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: _feedSourceChip(
                              icon: const Icon(
                                Icons.person_rounded,
                                size: 11,
                                color: Color(0xFF8B95A1),
                              ),
                              label: displayName,
                              brightness: brightness,
                              border: tagBorder,
                            ),
                          ),
                        ] else if (platform.isNotEmpty ||
                            handle.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: _feedSourceChip(
                              icon: _PlatformIcon(
                                platform: platform,
                                size: 12,
                                brightness: brightness,
                              ),
                              label: handle,
                              brightness: brightness,
                              border: tagBorder,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          ),
        ),
        // Action row: like, comment, share, bookmark
        Transform.translate(
          offset: const Offset(0, -6),
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 5),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Haptics.light();
                  onLike();
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 5, 8, 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FeedLikeHeart(
                        isLiked: isLiked,
                        size: 24,
                        color: isLiked
                            ? const Color(0xFFE5484D)
                            : textSecondary,
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
              const SizedBox(width: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onComment,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _feedIcon(
                        'assets/icons/feed_chatbubble.png',
                        color: textSecondary,
                        size: 20,
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
              const Spacer(),
            ],
          ),
        ),
        ),
        // Description (caption) + "댓글 N개 모두 보기" + timestamp
        Transform.translate(
          offset: const Offset(0, -6),
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (comment.isNotEmpty)
                ExpandableComment(
                  displayName: displayName,
                  comment: comment,
                  textColor: textPrimary,
                ),
              if (comment.isNotEmpty) const SizedBox(height: 4),
              GestureDetector(
                onTap: onComment,
                child: Text(
                  '댓글 $commentCount개 모두 보기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: textTertiary,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                timeAgo.isNotEmpty ? timeAgo : '방금 전',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 10.5,
                  color: textTertiary,
                ),
              ),
            ],
          ),
        ),
        ),
      ],
    );
  }

  static Widget _tagChip(String label, Color bg, Color border) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22369600),
        border: Border.all(width: 0.67, color: const Color(0xFFEFF4F1)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4B5563),
        ),
      ),
    );
  }

  static Widget _feedSourceChip({
    required Widget icon,
    required String label,
    required Brightness brightness,
    required Color border,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.getBackground(brightness),
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4A5565),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Square 1:1 photo carousel for the community feed post card.
/// Supports up to 3 photos with a top-right N/M pill (only when multi).
/// Preserves the existing tap (open recipe) and double-tap (like) gestures
/// and the floating like overlay.
class _FeedPhotoCarousel extends StatefulWidget {
  const _FeedPhotoCarousel({
    required this.photoUrls,
    required this.onTap,
    required this.onDoubleTap,
    required this.showLikingHeart,
    required this.textTertiary,
  });

  final List<String> photoUrls;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final bool showLikingHeart;
  final Color textTertiary;

  @override
  State<_FeedPhotoCarousel> createState() => _FeedPhotoCarouselState();
}

class _FeedPhotoCarouselState extends State<_FeedPhotoCarousel> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.photoUrls;
    final hasPhoto = urls.isNotEmpty;

    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              color: _border,
              child: hasPhoto
                  ? PageView.builder(
                      controller: _controller,
                      itemCount: urls.length,
                      onPageChanged: (i) => setState(() => _index = i),
                      itemBuilder: (context, i) {
                        return GestureDetector(
                          onTap: widget.onTap,
                          onDoubleTap: widget.onDoubleTap,
                          behavior: HitTestBehavior.opaque,
                          child: AppNetworkImage(
                            imageUrl: urls[i],
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            // Width-only cap preserves source aspect ratio.
                            memCacheWidth: AppNetworkImage.feedImageCacheSize,
                            errorWidget: Icon(
                              Icons.restaurant,
                              size: 48,
                              color: widget.textTertiary,
                            ),
                          ),
                        );
                      },
                    )
                  : GestureDetector(
                      onTap: widget.onTap,
                      onDoubleTap: widget.onDoubleTap,
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Icon(
                          Icons.restaurant,
                          size: 48,
                          color: widget.textTertiary,
                        ),
                      ),
                    ),
            ),
          ),
          if (hasPhoto && urls.length > 1)
            Positioned(
              right: 12,
              top: 12,
              child: IgnorePointer(
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
                    '${_index + 1}/${urls.length}',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (widget.showLikingHeart)
            Positioned.fill(child: _LikeOverlay(onTap: widget.onTap)),
        ],
      ),
    );
  }
}

/// Platform logo (YouTube, Instagram, TikTok) before creator name.
class _PlatformIcon extends StatelessWidget {
  const _PlatformIcon({
    required this.platform,
    required this.size,
    required this.brightness,
  });
  final String platform;
  final double size;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    String? assetPath;
    final p = platform.toLowerCase();
    if (p == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (p == 'instagram' || p == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (p == 'tiktok' || p == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
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
}

class _SectionBlock extends StatelessWidget {
  const _SectionBlock({
    required this.subtitle,
    required this.title,
    required this.recipes,
    required this.brightness,
    this.isFirstSection = false,
    required this.onSeeMore,
    required this.onRecipeTap,
    this.showTimeBadge = false,
  });

  final String subtitle;
  final String title;
  final List<Map<String, dynamic>> recipes;
  final Brightness brightness;
  final bool isFirstSection;
  final VoidCallback onSeeMore;
  final void Function(Map<String, dynamic>) onRecipeTap;
  final bool showTimeBadge;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    return Padding(
      padding: EdgeInsets.only(
        top: isFirstSection ? _trendSearchBarToFirstSectionGap : 24,
        bottom: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _sectionPaddingH),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontFamily: 'Caveat',
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: _orange,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Transform.translate(
                        offset: const Offset(0, -4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 19,
                                fontWeight: FontWeight.w900,
                                color: textPrimary,
                                letterSpacing: -0.4,
                                height: 24 / 19,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: onSeeMore,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '더보기',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: textTertiary,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.chevron_right,
                                    size: 18,
                                    color: textTertiary,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: _cardImageHeight + 68,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: _sectionPaddingH),
              scrollDirection: Axis.horizontal,
              itemCount: recipes.length,
              separatorBuilder: (_, __) => const SizedBox(width: _cardGap),
              itemBuilder: (context, index) {
                return _ExploreRecipeCard(
                  recipe: recipes[index],
                  brightness: brightness,
                  onTap: () => onRecipeTap(recipes[index]),
                  showTimeBadge: showTimeBadge,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonalSectionBlock extends StatelessWidget {
  const _SeasonalSectionBlock({
    required this.month,
    required this.seasonalRecipes,
    required this.brightness,
    required this.onRecipeTap,
  });

  final int month;
  final List<(Map<String, dynamic>, String)> seasonalRecipes;
  final Brightness brightness;
  final void Function(Map<String, dynamic>) onRecipeTap;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppColors.getTextPrimary(brightness);

    return Padding(
      padding: const EdgeInsets.only(
        top: _trendSearchBarToFirstSectionGap,
        bottom: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _sectionPaddingH),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'In Season',
                  style: TextStyle(
                    fontFamily: 'Caveat',
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF009966),
                    letterSpacing: 0.5,
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -4),
                  child: Text(
                    '$month월 제철 재료 레시피',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: textPrimary,
                      letterSpacing: -0.4,
                      height: 24 / 19,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: _cardImageHeight + 68,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: _sectionPaddingH),
              scrollDirection: Axis.horizontal,
              itemCount: seasonalRecipes.length,
              separatorBuilder: (_, __) => const SizedBox(width: _cardGap),
              itemBuilder: (context, index) {
                final (recipe, label) = seasonalRecipes[index];
                return _SeasonalRecipeCard(
                  recipe: recipe,
                  seasonalLabel: label,
                  brightness: brightness,
                  onTap: () => onRecipeTap(recipe),
                );
              },
            ),
          ),
        ],
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
  });

  final Map<String, dynamic> recipe;
  final String seasonalLabel;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(
      recipe,
      preferCroppedForInstagram: true,
    );
    final platform = source['platform'] as String? ?? '';
    final sourceUrl =
        (recipe['sourceUrl'] as String?)?.trim() ??
        (source['url'] as String?)?.trim() ??
        '';
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
        width: _cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _cardWidth,
              height: _cardImageHeight,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(_cardRadius),
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
                    child: thumbnailUrl.isNotEmpty
                        ? ThumbnailLetterboxMitigation(
                            platform: platform,
                            imageUrl: thumbnailUrl,
                            sourceUrl: sourceUrl,
                            child: AppNetworkImage(
                              imageUrl: thumbnailUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              memCacheWidth: AppNetworkImage.listThumbCacheSize,
                              memCacheHeight:
                                  AppNetworkImage.listThumbCacheSize,
                              maxWidthDiskCache: 600,
                              maxHeightDiskCache: 600,
                              errorWidget: Icon(
                                Icons.restaurant,
                                size: 48,
                                color: textTertiary,
                              ),
                            ),
                          )
                        : Icon(Icons.restaurant, size: 48, color: textTertiary),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
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
                      child: Text(
                        seasonalLabel,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF009966),
                          height: 15 / 10,
                          letterSpacing: -0.2,
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
                _PlatformIcon(
                  platform: platform,
                  size: 14,
                  brightness: brightness,
                ),
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

/// Expanded list of carousel recipes with search bar. Initially shows carousel recipes;
/// when user searches, uses full search across all recipes (same as RecommendationScreen).
class _CategoryListPage extends StatefulWidget {
  const _CategoryListPage({
    required this.title,
    required this.recipes,
    required this.onRecipeTap,
  });

  final String title;
  final List<Map<String, dynamic>> recipes;
  final void Function(Map<String, dynamic>) onRecipeTap;

  @override
  State<_CategoryListPage> createState() => _CategoryListPageState();
}

class _CategoryListPageState extends State<_CategoryListPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static int _getSearchMatchPriority(
    Map<String, dynamic> recipe,
    String query,
  ) {
    return recipeSearchMatchPriority(recipe, query);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: Row(
          children: [
            const YorigoHeaderLogo(height: 22, maxWidth: 100),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: textPrimary,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.getBackground(brightness),
        foregroundColor: textPrimary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search bar (same style and functionality as RecommendationScreen)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.getBackground(brightness),
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.getBorder(brightness),
                    width: 1,
                  ),
                ),
              ),
              child: RecipeSearchTextField(controller: _searchController),
            ),
            // Content: 검색은 부모가 넘겨준 widget.recipes 안에서만 필터링.
            // (이전엔 검색 시 컬렉션 전체 라이브 listener 폴백을 켰는데, 비용이
            // 컸고 이 화면이 받는 카테고리 데이터셋 밖을 검색해야 할 이유가 없음.)
            Expanded(
              child: Builder(
                builder: (context) {
                  final filtered = _searchQuery.isEmpty
                      ? widget.recipes
                      : widget.recipes
                            .where(
                              (recipe) =>
                                  _getSearchMatchPriority(
                                    recipe,
                                    _searchQuery,
                                  ) !=
                                  -1,
                            )
                            .toList();

                  if (_searchQuery.isNotEmpty && filtered.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.search_off,
                                  size: 64,
                                  color: AppColors.getTextTertiary(brightness),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '검색 결과가 없습니다',
                                  style: TextStyle(
                                    fontSize: 16,
                              color: AppColors.getTextSecondary(brightness),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _sectionPaddingH,
                            vertical: 12,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final recipe = filtered[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ExploreRecipeCard(
                                recipe: recipe,
                                brightness: brightness,
                                onTap: () => widget.onRecipeTap(recipe),
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
    );
  }
}

class _ExploreRecipeCard extends StatelessWidget {
  const _ExploreRecipeCard({
    required this.recipe,
    required this.brightness,
    required this.onTap,
    this.showTimeBadge = false,
  });

  final Map<String, dynamic> recipe;
  final Brightness brightness;
  final VoidCallback onTap;
  final bool showTimeBadge;

  static int _calcMinutes(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final steps = recipeData['steps'] as List? ?? [];
    int total = 0;
    for (final step in steps) {
      if (step is Map && step['est_minutes'] != null) {
        total += (step['est_minutes'] as num).toInt();
      }
    }
    return total > 0 ? total : 0;
  }

  @override
  Widget build(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(
      recipe,
      preferCroppedForInstagram: true,
    );
    final platform = source['platform'] as String? ?? '';
    final sourceUrl =
        (recipe['sourceUrl'] as String?)?.trim() ??
        (source['url'] as String?)?.trim() ??
        '';
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
    final minutes = showTimeBadge ? _calcMinutes(recipe) : 0;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: _cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _cardWidth,
              height: _cardImageHeight,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(_cardRadius),
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
                    child: thumbnailUrl.isNotEmpty
                        ? ThumbnailLetterboxMitigation(
                            platform: platform,
                            imageUrl: thumbnailUrl,
                            sourceUrl: sourceUrl,
                            child: AppNetworkImage(
                              imageUrl: thumbnailUrl,
                              fit: BoxFit.cover,
                              width: _cardWidth,
                              height: _cardImageHeight,
                              memCacheWidth: AppNetworkImage.listThumbCacheSize,
                              memCacheHeight:
                                  AppNetworkImage.listThumbCacheSize,
                              errorWidget: Icon(
                                Icons.restaurant,
                                size: 48,
                                color: textTertiary,
                              ),
                            ),
                          )
                        : Icon(Icons.restaurant, size: 48, color: textTertiary),
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
                _PlatformIcon(
                  platform: platform,
                  size: 14,
                  brightness: brightness,
                ),
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

/// Static 1:1 Figma 97-1998 feed post — no data wiring, layout/visuals only.
class _FigmaMockupPost extends StatelessWidget {
  const _FigmaMockupPost();

  static const Color _c101828 = Color(0xFF101828);
  static const Color _c1e2939 = Color(0xFF1E2939);
  static const Color _c364153 = Color(0xFF364153);
  static const Color _c4a5565 = Color(0xFF4A5565);
  static const Color _c6a7282 = Color(0xFF6A7282);
  static const Color _c99a1af = Color(0xFF99A1AF);
  static const Color _ce5e7eb = Color(0xFFE5E7EB);
  static const Color _cf3f4f6 = Color(0xFFF3F4F6);
  static const Color _cf9fafb = Color(0xFFF9FAFB);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final imageSize = width;

    return Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52.5,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFD490), Color(0xFFF0B040)],
                      ),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '하',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '하은',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _c101828,
                            letterSpacing: -0.325,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          '1시간 전',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 10.5,
                            color: _c99a1af,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 25,
                    height: 25,
                    child: Icon(Icons.more_horiz, size: 20, color: _c364153),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: imageSize,
            height: imageSize,
            color: _cf3f4f6,
            child: Center(
              child: Icon(Icons.image_outlined, size: 48, color: _c99a1af),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 12, right: 12),
            child: Container(
              width: (imageSize - 24) < 350 ? (imageSize - 24) : 350,
              height: 75.5,
              padding: const EdgeInsets.fromLTRB(15, 11, 15, 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _cf3f4f6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0D000000),
                    blurRadius: 18,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '크림 파스타',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _c101828,
                          letterSpacing: -0.3375,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.star_rounded,
                        size: 10,
                        color: const Color(0xFFEAB308),
                      ),
                      const SizedBox(width: 2),
                      const Text(
                        '4.8',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _c1e2939,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Text(
                        '(2,104)',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 10.5,
                          color: _c99a1af,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        height: 23.75,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: _ce5e7eb),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_circle_outline,
                              size: 11,
                              color: _c4a5565,
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              'pasta_master',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: _c4a5565,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      _tagChip('꾸덕한'),
                      _tagChip('데이트'),
                      _tagChip('양식'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _feedIcon(
                  'assets/icons/feed_heart.png',
                  color: _c364153,
                  size: 22,
                ),
                const SizedBox(width: 4),
                const Text(
                  '318',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _c364153,
                  ),
                ),
                const SizedBox(width: 14),
                _feedIcon(
                  'assets/icons/feed_chatbubble.png',
                  color: _c364153,
                  size: 20,
                ),
                const SizedBox(width: 4),
                const Text(
                  '52',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _c364153,
                  ),
                ),
                const Spacer(),
                _feedIcon(
                  'assets/icons/feed_bookmark.png',
                  color: _c364153,
                  size: 21,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: const TextSpan(
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      height: 19.5 / 13,
                    ),
                    children: [
                      TextSpan(
                        text: 'haeun_table',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          color: _c101828,
                        ),
                      ),
                      TextSpan(
                        text:
                            ' 주말 브런치로 크림 파스타 도전 🍝 생크림이 전부인줄 알았는데 버터가 핵심이었어요!',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w400,
                          color: _c1e2939,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                RichText(
                  text: const TextSpan(
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      height: 18 / 12,
                    ),
                    children: [
                      TextSpan(
                        text: 'minjun_chef',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w600,
                          color: _c364153,
                        ),
                      ),
                      TextSpan(
                        text: ' 플레이팅이 너무 예쁘다 진짜',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w400,
                          color: _c6a7282,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '댓글 52개 모두 보기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    color: _c99a1af,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '1시간 전',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10.5,
                    color: _c99a1af,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: _cf9fafb,
        border: Border.all(color: _ce5e7eb),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: _c6a7282,
        ),
      ),
    );
  }
}

// ============================================================================
// 핫한 레시피 묶음 — 카드 탭 시 올라오는 바텀시트.
// `recipe_groups/{groupKey}` 의 레시피들을 `completedAt` 최신순으로 페이지네이션.
// ============================================================================
class HotGroupSheet extends StatefulWidget {
  const HotGroupSheet({
    super.key,
    required this.group,
    required this.recipeService,
    required this.backgroundParsingService,
    required this.userService,
    required this.brightness,
    this.asPage = false,
  });

  final Map<String, dynamic> group;
  final RecipeService recipeService;
  final BackgroundParsingService backgroundParsingService;
  final UserService userService;
  final Brightness brightness;

  /// true면 바텀시트가 아니라 전체 페이지(Scaffold)로 렌더한다.
  final bool asPage;

  @override
  State<HotGroupSheet> createState() => _HotGroupSheetState();
}

class _HotGroupSheetState extends State<HotGroupSheet> {
  static const int _pageSize = 20;

  final List<Map<String, dynamic>> _recipes = [];
  DocumentSnapshot? _lastCursor;
  bool _hasMore = true;
  bool _initialLoading = true;
  bool _loadingMore = false;

  // 현재 유저의 북마크 상태를 sheet 안에서만 캐시. 토글 시 optimistic update.
  final Set<String> _bookmarkedIds = <String>{};
  final Set<String> _bookmarkInFlight = <String>{};

  // 레시피별 "현재 저장 중인 사람 수". users/{uid}/savedRecipes/{rid} 서브문서를
  // collectionGroup count 로 집계한 값(저장 시 생성·해제 시 삭제되므로 정확).
  // 누적값 saveCount 와 달리 실시간 현재 상태를 반영한다.
  final Map<String, int> _saverCounts = <String, int>{};
  // 주기적으로 다시 집계해 순위를 자동 갱신한다.
  Timer? _saverCountTimer;
  bool _refreshingCounts = false;

  // 시트 내부 전용 ScaffoldMessenger. 루트 메신저로 SnackBar 를 띄우면 시트
  // 뒤쪽에서 떠서 안 보이므로, 시트 안에서 직접 보여주기 위해 사용.
  final GlobalKey<ScaffoldMessengerState> _sheetMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  void _showSheetSnack(String message, {Color background = Colors.blue}) {
    _sheetMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: background,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String get _groupKey => (widget.group['id'] as String?)?.trim() ?? '';
  String get _name => (widget.group['name'] as String?)?.trim() ?? '';
  int get _count => (widget.group['count'] is num)
      ? (widget.group['count'] as num).toInt()
      : 0;

  // viewCount + bookmark count 내림차순 정렬. 실시간 _saverCounts 가 있으면
  // 북마크 부분에 사용하고, 아직 집계 전이면 누적 saveCount 로 폴백.
  List<Map<String, dynamic>> get _rankedRecipes {
    final list = List<Map<String, dynamic>>.from(_recipes);
    int rankValue(Map<String, dynamic> r) {
      final id = r['id'] as String? ?? '';
      final views = (r['viewCount'] as num?)?.toInt() ?? 0;
      final live = _saverCounts[id];
      final saves = live ?? ((r['saveCount'] as num?)?.toInt() ?? 0);
      return views + saves;
    }

    list.sort((a, b) => rankValue(b).compareTo(rankValue(a)));
    return list;
  }


  @override
  void initState() {
    super.initState();
    _loadInitial();
    // 다른 사람이 저장/해제해도 순위가 따라오도록 주기적으로 재집계.
    _saverCountTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _refreshSaverCounts(),
    );
  }

  @override
  void dispose() {
    _saverCountTimer?.cancel();
    super.dispose();
  }

  /// 한 레시피를 현재 저장 중인 사람 수를 collectionGroup 집계 count 로 조회.
  /// savedRecipes 서브문서는 저장 시 생성·해제 시 삭제되므로 정확한 현재값.
  Future<int> _fetchSaverCount(String recipeId) async {
    final agg = await FirebaseFirestore.instance
        .collectionGroup('savedRecipes')
        .where('recipeId', isEqualTo: recipeId)
        .count()
        .get();
    return agg.count ?? 0;
  }

  /// 로드된 모든 레시피의 현재 저장자 수를 병렬로 재집계해 순위를 갱신.
  /// 인덱스 미배포 등으로 실패하면 기존값/누적 saveCount 로 폴백(조용히 무시).
  Future<void> _refreshSaverCounts() async {
    if (_refreshingCounts) return;
    final ids = _recipes
        .map((r) => r['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    _refreshingCounts = true;
    try {
      final results = await Future.wait(
        ids.map((id) async {
          try {
            return MapEntry(id, await _fetchSaverCount(id));
          } catch (_) {
            return MapEntry<String, int?>(id, null);
          }
        }),
      );
      if (!mounted) return;
      setState(() {
        for (final e in results) {
          if (e.value != null) _saverCounts[e.key] = e.value!;
        }
      });
    } finally {
      _refreshingCounts = false;
    }
  }

  Future<void> _loadInitial() async {
    final page = await widget.recipeService.fetchRecipesInGroup(
      _groupKey,
      limit: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      _recipes
        ..clear()
        ..addAll(page.recipes);
      _lastCursor = page.lastRawDocument;
      _hasMore = page.hasMore;
      _initialLoading = false;
    });
    _refreshBookmarkStatuses();
    _refreshSaverCounts();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await widget.recipeService.fetchRecipesInGroup(
        _groupKey,
        startAfter: _lastCursor,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _recipes.addAll(page.recipes);
        _lastCursor = page.lastRawDocument;
        _hasMore = page.hasMore;
      });
      _refreshBookmarkStatuses();
      _refreshSaverCounts();
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _refreshBookmarkStatuses() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final saved = await widget.userService.getSavedRecipes(user.uid);
      if (!mounted) return;
      final ids = _recipes
          .map((r) => r['id'] as String? ?? '')
          .where((id) => id.isNotEmpty);
      setState(() {
        for (final id in ids) {
          if (saved.contains(id)) {
            _bookmarkedIds.add(id);
          } else {
            _bookmarkedIds.remove(id);
          }
        }
      });
    } catch (_) {
      // 북마크 상태 조회 실패는 UI에 치명적이지 않으므로 silent fail.
    }
  }

  Future<void> _toggleBookmark(String recipeId) async {
    if (recipeId.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSheetSnack('북마크하려면 로그인이 필요합니다', background: Colors.red);
      return;
    }
    if (_bookmarkInFlight.contains(recipeId)) return;
    final wasBookmarked = _bookmarkedIds.contains(recipeId);
    setState(() {
      _bookmarkInFlight.add(recipeId);
      if (wasBookmarked) {
        _bookmarkedIds.remove(recipeId);
        // 내 저장 해제를 순위에 즉시 반영(낙관적). 서버 집계로 곧 보정됨.
        final cur = _saverCounts[recipeId];
        if (cur != null) _saverCounts[recipeId] = cur > 0 ? cur - 1 : 0;
      } else {
        _bookmarkedIds.add(recipeId);
        final cur = _saverCounts[recipeId];
        if (cur != null) _saverCounts[recipeId] = cur + 1;
      }
    });
    // Optimistic UI already updated — show feedback immediately instead of
    // waiting for Firestore (addSavedRecipe can take 1–2s with tracking).
    if (wasBookmarked) {
      _showSheetSnack('북마크에서 제거되었습니다');
    } else {
      _showSheetSnack('북마크에 추가되었습니다');
    }
    try {
      if (wasBookmarked) {
        await widget.userService.removeSavedRecipe(user.uid, recipeId);
        RecipeService.notifyRecipesChanged();
        if (!mounted) return;
      } else {
        await widget.userService.addSavedRecipe(
          user.uid,
          recipeId,
          fromFeed: true,
        );
        RecipeService.notifyRecipesChanged();
        if (!mounted) return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasBookmarked) {
          _bookmarkedIds.add(recipeId);
        } else {
          _bookmarkedIds.remove(recipeId);
        }
      });
      _showSheetSnack('오류: $e', background: Colors.red);
    } finally {
      if (mounted) {
        setState(() => _bookmarkInFlight.remove(recipeId));
      }
    }
    // 서버 기준 정확한 현재 저장자 수로 보정(낙관적 값 오차 방지).
    if (mounted) {
      try {
        final fresh = await _fetchSaverCount(recipeId);
        if (mounted) setState(() => _saverCounts[recipeId] = fresh);
      } catch (_) {}
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
      _loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.asPage) return _buildPage(context);
    return _buildSheet(context);
  }

  // ── 전체 페이지 모드 (홈 인기 키워드 진입) ─────────────────────────────
  Widget _buildPage(BuildContext context) {
    final bg = AppColors.getBackground(widget.brightness);
    final textPrimary = AppColors.getTextPrimary(widget.brightness);
    final textTertiary = AppColors.getTextTertiary(widget.brightness);

    return ScaffoldMessenger(
      key: _sheetMessengerKey,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: textPrimary),
          title: Text(
            _name.isNotEmpty ? _name : '레시피',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: textPrimary,
              letterSpacing: -0.4,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: _countBadge()),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: _buildListView(null, textTertiary),
          ),
        ),
      ),
    );
  }

  Widget _countBadge() {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE9EDF2), width: 0.9),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.restaurant_rounded, size: 14, color: Color(0xFF111827)),
          const SizedBox(width: 4),
          Text(
            '$_count개',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              color: _orange,
              letterSpacing: -0.25,
            ),
          ),
        ],
      ),
    );
  }

  // ── 바텀시트 모드 (기존 탐색 화면 호환) ───────────────────────────────
  Widget _buildSheet(BuildContext context) {
    final bg = AppColors.getBackground(widget.brightness);
    final textPrimary = AppColors.getTextPrimary(widget.brightness);
    final textTertiary = AppColors.getTextTertiary(widget.brightness);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        // 시트 내부 전용 ScaffoldMessenger + Scaffold. 루트 메신저는 시트
        // 뒤쪽에 SnackBar 를 띄워 가려지므로, 여기서 시트 내부 하단에 보여줌.
        return ScaffoldMessenger(
          key: _sheetMessengerKey,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Container(
          decoration: BoxDecoration(
            color: bg,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Drag handle area — DraggableScrollableSheet handles dismiss
              // automatically; this gives a clear hit target.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: 10, bottom: 8),
                color: bg,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: textTertiary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        _name.isNotEmpty ? _name : '레시피',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: textPrimary,
                          letterSpacing: -0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                      decoration: BoxDecoration(
                            color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFFE9EDF2),
                              width: 0.9,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x12000000),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.restaurant_rounded,
                                size: 15,
                                color: Color(0xFF111827),
                              ),
                              const SizedBox(width: 4),
                              Text(
                        '$_count개',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                          color: _orange,
                                  letterSpacing: -0.25,
                        ),
                              ),
                            ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.5, color: _border),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                      child: _buildListView(scrollController, textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── 순위 리스트 (페이지/시트 공용) ────────────────────────────────────
  Widget _buildListView(ScrollController? controller, Color textTertiary) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final ranked = _rankedRecipes;
    if (ranked.isEmpty) {
      return Center(
                          child: Text(
                            '아직 레시피가 없어요',
                            style: TextStyle(fontSize: 15, color: textTertiary),
                          ),
      );
    }
    return ListView.separated(
      controller: controller,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: ranked.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
        if (index >= ranked.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox(
                                    width: 22,
                                    height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                ),
                              );
                            }
        final recipe = ranked[index];
                            final recipeId = recipe['id'] as String? ?? '';
        final isBookmarked = _bookmarkedIds.contains(recipeId);
        // 레시피 카드 디자인은 그대로 두고, 순위는 카드 패딩 위에
        // 오버레이로만 얹는다(카드 크기·레이아웃 변경 없음).
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                HomeStyleRecipeCard.fromRecipeMap(
                                  context,
                                  recipe,
                                  recipeService: widget.recipeService,
              backgroundParsingService: widget.backgroundParsingService,
                                  forceHideDate: true,
                                  screenName: 'category_explore',
                                  sectionId: 'popular_rank',
                                  position: index,
            ),
            if (index < 10)
              Positioned(
                top: -6,
                left: -6,
                child: _rankBadge(index),
                                ),
                                Positioned(
                                  top: -3.5,
                                  right: 13,
                                  child: Semantics(
                                    button: true,
                label: isBookmarked ? '레시피북에서 제거' : '레시피북에 저장',
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _toggleBookmark(recipeId),
                                      child: Container(
                                        width: 32,
                                        height: 32,
                                        alignment: Alignment.center,
                                        child: RecipeBookmarkGlyph(
                                          isBookmarked: isBookmarked,
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

  // 카드 좌상단 코너에 얹는 순위 배지. 1·2·3등은 메달(왕관) + 그라데이션,
  // 그 외는 회색 숫자 배지.
  Widget _rankBadge(int index) {
    final rank = index + 1;
    const medalColors = <int, List<Color>>{
      1: [Color(0xFFFFD66B), Color(0xFFE8A93B)], // gold
      2: [Color(0xFFE2E7EE), Color(0xFFAEB7C2)], // silver
      3: [Color(0xFFEEBE8E), Color(0xFFC8854F)], // bronze
    };
    final bool isMedal = rank <= 3;
    final List<Color> colors =
        isMedal ? medalColors[rank]! : const [Color(0xFFF2F4F7), Color(0xFFDDE2E9)];
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: (isMedal ? colors[1] : Colors.black).withValues(alpha: 0.30),
            blurRadius: 6,
            offset: const Offset(0, 2),
              ),
            ],
          ),
      alignment: Alignment.center,
      child: Text(
        '$rank',
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: isMedal ? Colors.white : const Color(0xFF6B7280),
          height: 1.0,
        ),
      ),
    );
  }

}
// 홈화면 저장 카드의 북마크 글리프와 동일한 path 를 사용 (둘 다 flat bookmark).
// 저장됨: 오렌지 그라데이션, 미저장: 회색 채움 + 가운데 위쪽 흰색 `+` 아이콘.
class _HotGroupBookmarkGlyph extends StatelessWidget {
  const _HotGroupBookmarkGlyph({required this.isBookmarked});

  final bool isBookmarked;

  @override
  Widget build(BuildContext context) {
    const size = 28.0;
    const savedGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFFF9A3D), Color(0xFFFF6B00), Color(0xFFFF4D00)],
      stops: [0.0, 0.55, 1.0],
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(size, size),
            painter: _HotGroupBookmarkPainter(
              color: isBookmarked ? null : const Color(0xFFA6A6A6),
              gradient: isBookmarked ? savedGradient : null,
            ),
          ),
          if (!isBookmarked)
            const Positioned(
              top: 4,
              child: Icon(Icons.add, size: 14, color: Colors.white),
            ),
        ],
      ),
    );
  }
}

class _HotGroupBookmarkPainter extends CustomPainter {
  const _HotGroupBookmarkPainter({this.color, this.gradient});

  final Color? color;
  final Gradient? gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
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
      paint.color = color ?? const Color(0xFFA6A6A6);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HotGroupBookmarkPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.gradient != gradient;
  }
}

