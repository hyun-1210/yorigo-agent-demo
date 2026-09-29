import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';
import '../services/admin_service.dart';
import '../services/report_service.dart';
import '../services/user_service.dart';
import '../services/review_service.dart';
import '../services/recipe_service.dart';
import '../utils/recipe_tag_filters.dart';
import '../widgets/feed_post_card.dart';
import '../widgets/recipe_signal_impression.dart';
import '../services/analytics_service.dart';
import '../widgets/comment_modal.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/naver_blog_access_dialog.dart';
import '../widgets/add_recipe_modal.dart';

// Persist recipe meta across feed openings so tags/rating do not reload each time.
final Map<String, List<String>> _recipeTagsGlobalCache = {};
final Map<String, double?> _recipeAverageRatingGlobalCache = {};
final Map<String, int> _recipeReviewCountGlobalCache = {};

/// Full-screen Instagram-style feed of posts for one recipe.
/// Used when user taps a photo in the 후기 grid; order matches grid (most recent first).
class RecipeReviewFeedScrollScreen extends StatefulWidget {
  final List<Map<String, dynamic>> reviews;
  final int initialIndex;

  /// Pre-loaded user data (e.g. from recipe detail 후기) so names show immediately.
  final Map<String, Map<String, dynamic>>? initialUserDataCache;

  const RecipeReviewFeedScrollScreen({
    super.key,
    required this.reviews,
    required this.initialIndex,
    this.initialUserDataCache,
  });

  @override
  State<RecipeReviewFeedScrollScreen> createState() =>
      _RecipeReviewFeedScrollScreenState();
}

class _RecipeReviewFeedScrollScreenState
    extends State<RecipeReviewFeedScrollScreen> {
  late ScrollController _scrollController;

  /// Mutable copy so we can remove a review from the list after delete.
  late List<Map<String, dynamic>> _reviews;
  final UserService _userService = UserService();
  final ReportService _reportService = ReportService();
  final ReviewService _reviewService = ReviewService();
  final RecipeService _recipeService = RecipeService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Map<String, Map<String, dynamic>> _userDataCache = {};
  final Map<String, bool> _likedStatus = {};
  final Map<String, int> _likeCounts = {};
  final Map<String, int> _commentCounts = {};
  Set<String> _blockedUserIds = <String>{};
  final Map<String, double?> _recipeAverageRating = {};
  final Map<String, int> _recipeReviewCount = {};
  final Map<String, List<String>> _recipeTags = {};

  /// Per-recipe bookmark state — the feed can mix reviews of different
  /// recipes (e.g. when opened from a user's profile), so a single bool would
  /// incorrectly toggle every card together.
  Set<String> _bookmarkedRecipeIds = <String>{};
  bool _isAdmin = false;
  String? _likingReviewId;

  /// Stable target so scroll survives list filter (e.g. blocked users).
  String? _initialReviewId;
  final GlobalKey _initialItemKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _loadAdminStatus();

    // Use pre-loaded user data from recipe detail so author/liker names show immediately
    final initial = widget.initialUserDataCache;
    if (initial != null && initial.isNotEmpty) {
      _userDataCache.addAll(initial);
    }

    _reviews = List<Map<String, dynamic>>.from(widget.reviews);
    if (_reviews.isNotEmpty) {
      final idx = widget.initialIndex.clamp(0, _reviews.length - 1);
      _initialReviewId = (_reviews[idx]['id'] as String?)?.trim();
    }

    _rebuildReviewInteractionCaches();
    _loadBlockedUsers();
    _loadUserData();
    _loadRecipeMetadata();
    _loadBookmarkStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToInitialReview();
    });
  }

  int get _targetIndex {
    final id = _initialReviewId;
    if (id == null || id.isEmpty) return 0;
    final i = _reviews.indexWhere((r) => (r['id'] as String?) == id);
    return i >= 0 ? i : 0;
  }

  void _rebuildReviewInteractionCaches() {
    _likedStatus.clear();
    _likeCounts.clear();
    _commentCounts.clear();
    for (final review in _reviews) {
      final reviewId = review['id'] as String? ?? '';
      if (reviewId.isEmpty) continue;
      _likedStatus[reviewId] = _reviewService.isLiked(review);
      _likeCounts[reviewId] = (review['likeCount'] as num?)?.toInt() ?? 0;
      _commentCounts[reviewId] = (review['commentCount'] as num?)?.toInt() ?? 0;
    }
  }

  Future<void> _loadBlockedUsers() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final blocked = (await _userService.getBlockedUserIds(user.uid)).toSet();
      if (!mounted) return;
      if (blocked.isEmpty) {
        setState(() => _blockedUserIds = <String>{});
        return;
      }
      setState(() {
        _blockedUserIds = blocked;
        _reviews = _reviews.where((review) {
          final authorId = review['userId'] as String? ?? '';
          return !blocked.contains(authorId);
        }).toList();
        _rebuildReviewInteractionCaches();
      });
      await _loadUserData();
      await _loadRecipeMetadata();
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToInitialReview();
        });
      }
    } catch (_) {}
  }

  Future<void> _handleBlockUser({
    required String blockedUserId,
    required String reviewId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) Navigator.pushNamed(context, '/login');
      return;
    }
    if (blockedUserId.isEmpty || blockedUserId == user.uid) return;
    if (_blockedUserIds.contains(blockedUserId)) {
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

    final previousReviews = List<Map<String, dynamic>>.from(_reviews);
    final previousBlocked = Set<String>.from(_blockedUserIds);
    setState(() {
      _blockedUserIds = {..._blockedUserIds, blockedUserId};
      _reviews = _reviews.where((review) {
        return (review['userId'] as String? ?? '') != blockedUserId;
      }).toList();
      _rebuildReviewInteractionCaches();
    });

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
        _reviews = previousReviews;
        _blockedUserIds = previousBlocked;
        _rebuildReviewInteractionCaches();
      });
      showAppSnackBar(context, 
        SnackBar(
          content: Text('차단 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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

  /// Open the review edit sheet prefilled from the current review map; if the
  /// user submits, refetch the document and patch the in-memory list so the
  /// card visibly updates without leaving the feed.
  Future<void> _handleEditReview(Map<String, dynamic> review) async {
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
        final idx = _reviews.indexWhere(
          (r) => (r['id'] as String?) == reviewId,
        );
        if (idx >= 0) {
          _reviews[idx] = {..._reviews[idx], ...fresh};
        }
      });
    } catch (_) {
      // Best-effort refresh; ignore network errors.
    }
  }

  Future<void> _handleDeleteReview(
    String reviewId, {
    bool allowAdminOverride = false,
  }) async {
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
      if (mounted) {
        setState(() {
          _reviews.removeWhere((r) => (r['id'] as String?) == reviewId);
        });
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('후기가 삭제되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[RecipeReviewFeedScrollScreen] Error deleting review: $e');
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('삭제 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _loadBookmarkStatus() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final savedRecipes = await _userService.getSavedRecipes(user.uid);
      if (mounted) {
        setState(() {
          _bookmarkedRecipeIds = savedRecipes.toSet();
        });
      }
    } catch (e) {
      print('[RecipeReviewFeedScrollScreen] Error loading bookmark status: $e');
    }
  }

  Future<void> _handleBookmark(String recipeId) async {
    if (recipeId.isEmpty) return;

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

    final wasBookmarked = _bookmarkedRecipeIds.contains(recipeId);
    if (wasBookmarked) {
      final confirmed = await AppConfirmDialog.show(
        context: context,
        title: '레시피북에서 제거할까요?',
        description: '저장된 레시피 목록에서 제거되며, 언제든지 다시 저장할 수 있어요.',
        confirmLabel: '제거',
      );
      if (confirmed != true || !mounted) return;
    }

    try {
      // Optimistic update
      setState(() {
        if (wasBookmarked) {
          _bookmarkedRecipeIds.remove(recipeId);
        } else {
          _bookmarkedRecipeIds.add(recipeId);
        }
      });

      if (wasBookmarked) {
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
        // Verify the recipe is fetchable before persisting the add.
        final parseResponse = await _recipeService.getRecipeById(recipeId);
        if (parseResponse == null) {
          if (mounted) {
            setState(() {
              _bookmarkedRecipeIds.remove(recipeId);
            });
            showAppSnackBar(context, 
              const SnackBar(
                content: Text('레시피를 찾을 수 없습니다'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        // 네이버 블로그: 본문은 본인 디바이스 로컬에만 있으므로, 단순 attach 만
        // 하면 빈 카드가 된다. 본인 로컬 본문이 없는 경우 → 이 화면 위에 분석
        // 모달을 띄워 본인이 직접 분석하도록 유도.
        final source = parseResponse.source;
        final platform = source['platform'] as String?;
        final sourceUrl = source['url'] as String?;
        final shouldGate = await shouldShowNaverAccessDialog(
          platform: platform,
          recipeId: recipeId,
          sourceUrl: sourceUrl,
        );
        if (!mounted) return;
        if (shouldGate) {
          setState(() {
            _bookmarkedRecipeIds.remove(recipeId);
          });
          if (sourceUrl != null && sourceUrl.isNotEmpty) {
            await showAddRecipeModal(context, initialUrl: sourceUrl);
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
      print('[RecipeReviewFeedScrollScreen] Error toggling bookmark: $e');
      if (mounted) {
        setState(() {
          if (wasBookmarked) {
            _bookmarkedRecipeIds.add(recipeId);
          } else {
            _bookmarkedRecipeIds.remove(recipeId);
          }
        });
        showAppSnackBar(context, 
          SnackBar(
            content: Text('북마크 처리 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Jump near the target with a size estimate, then pin its top edge with
  /// [Scrollable.ensureVisible] (alignment 0) so diary taps land flush.
  void _scrollToInitialReview({int refinePasses = 5}) {
    if (!mounted || !_scrollController.hasClients) return;
    final target = _targetIndex;
    if (target <= 0) return;

    final width = MediaQuery.sizeOf(context).width;
    // Feed cards are ~1:1 photo + header/actions/caption. Underestimate a bit
    // so ensureVisible can correct downward to the true top.
    final estimatedItemHeight = width + 200;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final offset =
        (target * estimatedItemHeight).clamp(0.0, maxExtent);
    if ((_scrollController.offset - offset).abs() > 1) {
      _scrollController.jumpTo(offset);
    }

    void refine(int left) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final ctx = _initialItemKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.0,
            duration: Duration.zero,
            curve: Curves.linear,
          );
        } else if (left > 0) {
          // Item not built yet — nudge further then retry.
          final next = (_scrollController.offset + width)
              .clamp(0.0, _scrollController.position.maxScrollExtent);
          _scrollController.jumpTo(next);
        }
        if (left > 0) refine(left - 1);
      });
    }

    refine(refinePasses);
  }

  Future<void> _loadUserData() async {
    final userIds = _reviews
        .map((review) => review['userId'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toSet();
    final likedByIds = <String>{};
    for (final r in _reviews) {
      final list = r['likedBy'] as List?;
      if (list != null) {
        for (final e in list) {
          final s = e?.toString();
          if (s != null && s.isNotEmpty) likedByIds.add(s);
        }
      }
    }
    userIds.addAll(likedByIds);
    final uncached = userIds
        .where((id) => !_userDataCache.containsKey(id))
        .toList();
    await Future.wait(
      uncached.map((userId) async {
        try {
          final userDoc = await _userService.getUserDocument(userId);
          final userData = userDoc.data() as Map<String, dynamic>?;
          _userDataCache[userId] = userData ?? {};
        } catch (_) {}
      }),
    );
    if (mounted) setState(() {});
  }

  Future<void> _loadRecipeMetadata() async {
    final recipeIds = _reviews
        .map((r) => r['recipeId'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toSet();

    // 1) Prime from global cache immediately (fast reopen path)
    for (final recipeId in recipeIds) {
      final cachedTags = _recipeTagsGlobalCache[recipeId];
      if (cachedTags != null) _recipeTags[recipeId] = cachedTags;
      final cachedAvg = _recipeAverageRatingGlobalCache[recipeId];
      if (cachedAvg != null ||
          _recipeAverageRatingGlobalCache.containsKey(recipeId)) {
        _recipeAverageRating[recipeId] = cachedAvg;
      }
      final cachedCount = _recipeReviewCountGlobalCache[recipeId];
      if (cachedCount != null) _recipeReviewCount[recipeId] = cachedCount;
    }

    // 2) Prime from review payload itself so UI has immediate best-effort metadata
    for (final r in _reviews) {
      final recipeId = (r['recipeId'] as String?)?.trim() ?? '';
      if (recipeId.isEmpty) continue;
      final tagsRaw = r['recipeTags'];
      if (!_recipeTags.containsKey(recipeId) && tagsRaw is List) {
        final tags = tagsRaw
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toList();
        if (tags.isNotEmpty) _recipeTags[recipeId] = tags;
      }
      if (!_recipeAverageRating.containsKey(recipeId)) {
        final avg =
            (r['recipeAverageRating'] as num?)?.toDouble() ??
            (r['averageRating'] as num?)?.toDouble();
        if (avg != null) _recipeAverageRating[recipeId] = avg;
      }
      if (!_recipeReviewCount.containsKey(recipeId)) {
        final cnt =
            (r['recipeReviewCount'] as num?)?.toInt() ??
            (r['reviewCount'] as num?)?.toInt();
        if (cnt != null) _recipeReviewCount[recipeId] = cnt;
      }
    }
    if (mounted) setState(() {});

    // 3) Fetch still-missing metadata in parallel
    final missingIds = recipeIds.where((id) {
      return !_recipeTags.containsKey(id) ||
          !_recipeReviewCount.containsKey(id) ||
          !_recipeAverageRating.containsKey(id);
    }).toList();
    await Future.wait(
      missingIds.map((recipeId) async {
        try {
          final parseResponse = await _recipeService.getRecipeById(recipeId);
          if (parseResponse == null) return;
          final avg = parseResponse.averageRating;
          final cnt = parseResponse.reviewCount ?? 0;
          final rawTags = parseResponse.source['tags'];
          final tags = rawTags is List
              ? filterRecipeTagsForDisplay(rawTags)
              : <String>[];

          _recipeAverageRating[recipeId] = avg;
          _recipeReviewCount[recipeId] = cnt;
          _recipeTags[recipeId] = tags;

          _recipeAverageRatingGlobalCache[recipeId] = avg;
          _recipeReviewCountGlobalCache[recipeId] = cnt;
          _recipeTagsGlobalCache[recipeId] = tags;
        } catch (_) {
          // Keep feed usable even when metadata fetch fails for some recipes.
        }
      }),
    );

    if (mounted) setState(() {});
  }

  Future<void> _handleLike(String reviewId, {bool onlyLike = false}) async {
    if (_likingReviewId != null) return;
    setState(() => _likingReviewId = reviewId);
    try {
      final wasLiked = _likedStatus[reviewId] ?? false;
      if (onlyLike && wasLiked) return;
      final currentCount = _likeCounts[reviewId] ?? 0;
      setState(() {
        _likedStatus[reviewId] = !wasLiked;
        _likeCounts[reviewId] = wasLiked ? currentCount - 1 : currentCount + 1;
      });
      final isLiked = await _reviewService.toggleLike(reviewId);
      final updatedLikeCount = isLiked ? currentCount + 1 : currentCount - 1;
      if (mounted) {
        setState(() {
          _likedStatus[reviewId] = isLiked;
          _likeCounts[reviewId] = updatedLikeCount;
        });
      }
    } catch (_) {
      final idx = _reviews.indexWhere((r) => (r['id'] as String?) == reviewId);
      if (mounted && idx != -1) {
        setState(() {
          _likedStatus[reviewId] = _reviewService.isLiked(_reviews[idx]);
          _likeCounts[reviewId] =
              (_reviews[idx]['likeCount'] as num?)?.toInt() ?? 0;
        });
      }
    } finally {
      if (mounted) setState(() => _likingReviewId = null);
    }
  }

  void _showCommentModal(
    BuildContext context,
    Map<String, dynamic> review,
    Brightness brightness,
  ) async {
    final reviewId = review['id'] as String? ?? '';

    // Show comment modal
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentModal(reviewId: reviewId, review: review),
    );

    // Reload comment count after modal closes
    if (mounted) {
      try {
        final commentCount = await _reviewService.getCommentCount(reviewId);
        setState(() {
          _commentCounts[reviewId] = commentCount;
        });
      } catch (e) {
        print(
          '[RecipeReviewFeedScrollScreen] Error reloading comment count: $e',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        backgroundColor: AppColors.getBackground(brightness),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          '나의 다이어리',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.getTextPrimary(brightness),
            letterSpacing: -0.4,
          ),
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_rounded,
            color: AppColors.getTextPrimary(brightness),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(bottom: 16 + appSystemNavBottomInset(context)),
        physics: const ClampingScrollPhysics(),
        itemCount: _reviews.length,
        itemBuilder: (context, index) {
          final review = _reviews[index];
          final reviewId = review['id'] as String? ?? '';
          final recipeId = review['recipeId'] as String? ?? '';
          final isLiked = _likedStatus[reviewId] ?? false;
          final likeCount = _likeCounts[reviewId] ?? 0;
          final commentCount = _commentCounts[reviewId] ?? 0;
          final isOwnPost = _auth.currentUser?.uid == review['userId'];
          final isInitialTarget = reviewId.isNotEmpty &&
              reviewId == _initialReviewId;

          return KeyedSubtree(
            key: isInitialTarget
                ? _initialItemKey
                : ValueKey('feed_review_$reviewId-$index'),
            child: RecipeIdSignalImpression(
              screen: 'recipe_review_feed',
              recipeId: recipeId,
              sectionId: 'feed_post',
              position: index,
              child: FeedPostCard(
            review: review,
            userDataCache: _userDataCache,
            brightness: brightness,
            recipeTags: _recipeTags[recipeId],
            recipeAverageRating: _recipeAverageRating[recipeId],
            recipeReviewCount: _recipeReviewCount[recipeId],
            isLiked: isLiked,
            likeCount: likeCount,
            commentCount: commentCount,
            isBookmarked: _bookmarkedRecipeIds.contains(recipeId),
            showLikingHeart: _likingReviewId == reviewId && isLiked,
            showRecipeRow: true,
            isOwnPost: isOwnPost,
            isAdmin: _isAdmin,
            onLike: () => _handleLike(reviewId),
            onComment: () => _showCommentModal(context, review, brightness),
            onBookmark: () => _handleBookmark(recipeId),
            onEdit: isOwnPost ? () => _handleEditReview(review) : null,
            onDelete: (isOwnPost || _isAdmin)
                ? () => _handleDeleteReview(
                    reviewId,
                    allowAdminOverride: !isOwnPost && _isAdmin,
                  )
                : null,
            onBlockUser: () => _handleBlockUser(
              blockedUserId: review['userId'] as String? ?? '',
              reviewId: reviewId,
            ),
            onReportSubmitted: () {
              if (!mounted) return;
              setState(() {
                _reviews.removeWhere((r) => (r['id'] as String?) == reviewId);
              });
            },
            onProfileTap: () => Navigator.pushNamed(
              context,
              '/profile',
              arguments: {'userId': review['userId'] as String?},
            ),
            onRecipeTap: recipeId.isEmpty
                ? null
                : () async {
                    AnalyticsService().noteRecipeOpenSource(
                      recipeId: recipeId,
                      screen: 'recipe_review_feed',
                      sectionId: 'feed_post',
                    );
                    try {
                      final parseResponse = await _recipeService.getRecipeById(
                        recipeId,
                      );
                      if (!mounted) return;
                      if (parseResponse != null) {
                        // 네이버 블로그: 본문은 본인 디바이스 로컬에만 저장된다.
                        // 다른 사용자의 분석 결과로 진입하면 빈 디테일을 보게 되므로
                        // 진입을 막고 다이얼로그로 안내한다.
                        final source = parseResponse.source;
                        final platform = source['platform'] as String?;
                        final sourceUrl = source['url'] as String?;
                        final shouldGate = await shouldShowNaverAccessDialog(
                          platform: platform,
                          recipeId: recipeId,
                          sourceUrl: sourceUrl,
                        );
                        if (!mounted) return;
                        if (shouldGate) {
                          if (sourceUrl != null && sourceUrl.isNotEmpty) {
                            await showNaverBlogAccessDialog(
                              context: context,
                              sourceUrl: sourceUrl,
                            );
                          }
                          return;
                        }
                        Navigator.pushNamed(
                          context,
                          '/recipe-detail',
                          arguments: {
                            'parseResponse': parseResponse,
                            'recipeId': recipeId,
                          },
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
                      if (!mounted) return;
                      showAppSnackBar(context, 
                        SnackBar(
                          content: Text('레시피를 불러올 수 없습니다: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
            ),
            ),
          );
        },
      ),
    );
  }
}
