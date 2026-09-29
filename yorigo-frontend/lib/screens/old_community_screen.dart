// Kept for reference — previously the community tab. Replaced by CategoryExploreScreen.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../widgets/app_refresh_indicator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_header.dart';
import '../widgets/comment_modal.dart';
import '../widgets/feed_post_card.dart';
import '../services/review_service.dart';
import '../services/user_service.dart';
import '../services/recipe_service.dart';
import '../utils/chef_tag_utils.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/text_utils.dart';
import 'recipe_detail_screen.dart';

class OldCommunityScreen extends StatefulWidget {
  const OldCommunityScreen({super.key});

  @override
  State<OldCommunityScreen> createState() => _OldCommunityScreenState();
}

class _OldCommunityScreenState extends State<OldCommunityScreen> {
  final ReviewService _reviewService = ReviewService();
  final UserService _userService = UserService();
  final RecipeService _recipeService = RecipeService();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Map<String, dynamic>> _reviews = [];
  List<Map<String, dynamic>> _allReviews = []; // All reviews (for filtering)
  Map<String, Map<String, dynamic>> _userDataCache = {};
  Map<String, bool> _likedStatus = {}; // reviewId -> isLiked
  Map<String, int> _likeCounts = {}; // reviewId -> likeCount
  Map<String, int> _commentCounts = {}; // reviewId -> commentCount
  Map<String, bool> _bookmarkedStatus = {}; // recipeId -> isBookmarked
  bool _isLoading = true;
  bool _showMyReviewsOnly = false; // Tab filter state

  /// Review ID for which the heart animation is currently shown (only this post shows it).
  String? _likingReviewId;

  // Recommended recipes for "Yorigo 추천" section
  List<Map<String, dynamic>> _recommendedRecipes = [];
  bool _isLoadingRecommendations = true;

  @override
  void initState() {
    super.initState();
    _loadReviews();
    _loadRecommendedRecipes();
  }

  Future<void> _loadRecommendedRecipes() async {
    try {
      // Get a mix of popular and recent recipes
      final results = await Future.wait([
        _recipeService.getWeeklyPopularRecipes(limit: 5),
        _recipeService.getRecentlyAddedRecipes(limit: 5),
      ]);

      final allRecipes = <Map<String, dynamic>>[];
      allRecipes.addAll(results[0]);
      allRecipes.addAll(results[1]);

      // Remove duplicates by ID
      final uniqueRecipes = <String, Map<String, dynamic>>{};
      for (var recipe in allRecipes) {
        final id = recipe['id'] as String?;
        if (id != null && !uniqueRecipes.containsKey(id)) {
          uniqueRecipes[id] = recipe;
        }
      }

      if (mounted) {
        setState(() {
          _recommendedRecipes = uniqueRecipes.values.take(10).toList();
          _isLoadingRecommendations = false;
        });
      }
    } catch (e) {
      print('[OldCommunityScreen] Error loading recommended recipes: $e');
      if (mounted) {
        setState(() {
          _isLoadingRecommendations = false;
        });
      }
    }
  }

  Future<void> _loadReviews() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final reviews = await _reviewService.getCommunityReviews();

      // Load user data for post authors and likers (for "X님 외 N명이 좋아합니다")
      final userIds = <String>{};
      for (var review in reviews) {
        final authorId = review['userId'] as String?;
        if (authorId != null && authorId.isNotEmpty) userIds.add(authorId);
        final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
        for (var i = 0; i < likedBy.length && i < 3; i++) {
          if (likedBy[i].isNotEmpty) userIds.add(likedBy[i]);
        }
      }

      final userDataMap = <String, Map<String, dynamic>>{};
      for (var userId in userIds) {
        try {
          final userDoc = await _userService.getUserDocument(userId);
          final userData = userDoc.data() as Map<String, dynamic>?;
          userDataMap[userId] = userData ?? {};
        } catch (e) {
          print('[OldCommunityScreen] Error loading user data: $e');
        }
      }

      // Initialize liked status, like counts, comment counts, and bookmarked status
      final likedStatusMap = <String, bool>{};
      final likeCountsMap = <String, int>{};
      final commentCountsMap = <String, int>{};
      final bookmarkedStatusMap = <String, bool>{};

      // Load saved recipes for current user to check bookmark status
      final user = _auth.currentUser;
      Set<String> savedRecipeIds = {};
      if (user != null) {
        try {
          savedRecipeIds = (await _userService.getSavedRecipes(
            user.uid,
          )).toSet();
        } catch (e) {
          print('[OldCommunityScreen] Error loading saved recipes: $e');
        }
      }

      for (var review in reviews) {
        final reviewId = review['id'] as String? ?? '';
        final recipeId = review['recipeId'] as String? ?? '';
        likedStatusMap[reviewId] = _reviewService.isLiked(review);
        likeCountsMap[reviewId] = (review['likeCount'] as num?)?.toInt() ?? 0;
        commentCountsMap[reviewId] =
            (review['commentCount'] as num?)?.toInt() ?? 0;
        if (recipeId.isNotEmpty) {
          bookmarkedStatusMap[recipeId] = savedRecipeIds.contains(recipeId);
        }
      }

      if (mounted) {
        setState(() {
          _allReviews = reviews;
          _reviews = _showMyReviewsOnly ? _filterMyReviews(reviews) : reviews;
          _userDataCache = userDataMap;
          _likedStatus = likedStatusMap;
          _likeCounts = likeCountsMap;
          _commentCounts = commentCountsMap;
          _bookmarkedStatus = bookmarkedStatusMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[OldCommunityScreen] Error loading reviews: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _filterMyReviews(
    List<Map<String, dynamic>> reviews,
  ) {
    final user = _auth.currentUser;
    if (user == null) return [];
    return reviews.where((review) => review['userId'] == user.uid).toList();
  }

  void _toggleMyReviewsFilter(bool showMyReviews) {
    setState(() {
      _showMyReviewsOnly = showMyReviews;
      _reviews = showMyReviews ? _filterMyReviews(_allReviews) : _allReviews;
    });
  }

  Future<void> _handleDeleteReview(String reviewId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('후기 삭제'),
        content: const Text('정말로 이 후기를 삭제하시겠습니까?\n삭제된 후기는 복구할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _reviewService.deleteReview(reviewId);

      if (mounted) {
        setState(() {
          _allReviews.removeWhere((r) => r['id'] == reviewId);
          _reviews.removeWhere((r) => r['id'] == reviewId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('후기가 삭제되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('[CommunityScreen] Error deleting review: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('삭제 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleBookmark(String recipeId) async {
    print(
      '[OldCommunityScreen] _handleBookmark called with recipeId: $recipeId',
    );

    final user = _auth.currentUser;
    if (user == null) {
      print('[OldCommunityScreen] User not logged in, cannot bookmark');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('북마크하려면 로그인이 필요합니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    print('[OldCommunityScreen] Current user: ${user.uid}');
    final isCurrentlyBookmarked = _bookmarkedStatus[recipeId] ?? false;
    print(
      '[OldCommunityScreen] Current bookmark status: $isCurrentlyBookmarked',
    );

    try {
      // Optimistic update
      setState(() {
        _bookmarkedStatus[recipeId] = !isCurrentlyBookmarked;
      });
      print(
        '[OldCommunityScreen] Optimistic update: bookmark status changed to ${!isCurrentlyBookmarked}',
      );

      if (isCurrentlyBookmarked) {
        // Remove from saved recipes
        print('[OldCommunityScreen] Removing bookmark for recipe: $recipeId');
        await _userService.removeSavedRecipe(user.uid, recipeId);
        RecipeService.notifyRecipesChanged();
        print('[OldCommunityScreen] Bookmark removed successfully');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('북마크에서 제거되었습니다'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      } else {
        // Add to saved recipes
        print('[OldCommunityScreen] Adding bookmark for recipe: $recipeId');
        print('[OldCommunityScreen] Checking if recipe exists...');
        final parseResponse = await _recipeService.getRecipeById(recipeId);
        if (parseResponse == null) {
          print(
            '[OldCommunityScreen] Recipe not found or cannot be accessed: $recipeId',
          );
          setState(() {
            _bookmarkedStatus[recipeId] = isCurrentlyBookmarked;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('레시피를 찾을 수 없습니다'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        print('[OldCommunityScreen] Recipe found, adding to saved recipes...');
        await _userService.addSavedRecipe(user.uid, recipeId, fromFeed: true);
        RecipeService.notifyRecipesChanged();
        print('[OldCommunityScreen] Bookmark added successfully to Firestore');

        final savedRecipes = await _userService.getSavedRecipes(user.uid);
        print(
          '[OldCommunityScreen] Current saved recipes count: ${savedRecipes.length}',
        );
        print(
          '[OldCommunityScreen] Recipe $recipeId in saved recipes: ${savedRecipes.contains(recipeId)}',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('북마크에 추가되었습니다'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      }
    } catch (e, stackTrace) {
      print('[OldCommunityScreen] Error toggling bookmark: $e');
      print('[OldCommunityScreen] Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _bookmarkedStatus[recipeId] = isCurrentlyBookmarked;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('북마크 처리 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showCommentModal(
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
        final commentCount = await _reviewService.getCommentCount(reviewId);
        setState(() {
          _commentCounts[reviewId] = commentCount;
        });
      } catch (e) {
        print('[OldCommunityScreen] Error reloading comment count: $e');
      }
    }
  }

  Future<void> _handleLike(String reviewId) async {
    if (_likingReviewId != null) return;

    setState(() {
      _likingReviewId = reviewId;
    });

    try {
      final wasLiked = _likedStatus[reviewId] ?? false;
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
    } catch (e) {
      print('[OldCommunityScreen] Error toggling like: $e');
      if (mounted) {
        final reviewIndex = _reviews.indexWhere(
          (r) => (r['id'] as String?) == reviewId,
        );
        if (reviewIndex != -1) {
          final review = _reviews[reviewIndex];
          setState(() {
            _likedStatus[reviewId] = _reviewService.isLiked(review);
            _likeCounts[reviewId] = (review['likeCount'] as num?)?.toInt() ?? 0;
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _likingReviewId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              onLoginPressed: () {
                Navigator.pushNamed(context, '/login');
              },
            ),
            Expanded(
              child: AppRefreshIndicator(
                onRefresh: () async {
                  await Future.wait([
                    _loadReviews(),
                    _loadRecommendedRecipes(),
                  ]);
                },
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : CustomScrollView(
                        slivers: [
                          SliverToBoxAdapter(
                            child: _buildYorigoRecommendationSection(
                              brightness,
                            ),
                          ),
                          // Feed header with tabs (translated up 10px to reduce gap after carousel)
                          SliverToBoxAdapter(
                            child: Transform.translate(
                              offset: const Offset(0, -10),
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  16,
                                  20,
                                  6,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.getBackground(brightness),
                                  border: Border(
                                    top: BorderSide(
                                      color: AppColors.getBorder(brightness),
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () =>
                                          _toggleMyReviewsFilter(false),
                                      child: Text(
                                        '레시피 피드',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: !_showMyReviewsOnly
                                              ? (brightness == Brightness.dark
                                                    ? const Color(0xFFFFFFFF)
                                                    : const Color(0xFF000000))
                                              : AppColors.getTextTertiary(
                                                  brightness,
                                                ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    GestureDetector(
                                      onTap: () {
                                        final user = _auth.currentUser;
                                        if (user == null) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                '나의 후기를 보려면 로그인이 필요합니다',
                                              ),
                                              backgroundColor: Colors.orange,
                                            ),
                                          );
                                          return;
                                        }
                                        _toggleMyReviewsFilter(true);
                                      },
                                      child: Text(
                                        '나의 후기',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: _showMyReviewsOnly
                                              ? (brightness == Brightness.dark
                                                    ? const Color(0xFFFFFFFF)
                                                    : const Color(0xFF000000))
                                              : AppColors.getTextTertiary(
                                                  brightness,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_reviews.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Text(
                                  '리뷰가 없습니다',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: AppColors.getTextSecondary(
                                      brightness,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.only(bottom: 16),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final review = _reviews[index];
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      bottom: index < _reviews.length - 1
                                          ? 8
                                          : 0,
                                    ),
                                    child: FeedPostCard(
                                      review: review,
                                      userDataCache: _userDataCache,
                                      brightness: brightness,
                                      isLiked:
                                          _likedStatus[review['id']
                                                  as String? ??
                                              ''] ??
                                          false,
                                      likeCount:
                                          _likeCounts[review['id'] as String? ??
                                              ''] ??
                                          0,
                                      commentCount:
                                          _commentCounts[review['id']
                                                  as String? ??
                                              ''] ??
                                          0,
                                      isBookmarked:
                                          _bookmarkedStatus[review['recipeId']
                                                  as String? ??
                                              ''] ??
                                          false,
                                      showLikingHeart:
                                          _likingReviewId ==
                                              (review['id'] as String?) &&
                                          (_likedStatus[review['id']
                                                      as String? ??
                                                  ''] ??
                                              false),
                                      showRecipeRow: true,
                                      isOwnPost:
                                          _auth.currentUser?.uid ==
                                          review['userId'],
                                      onLike: () => _handleLike(
                                        review['id'] as String? ?? '',
                                      ),
                                      onComment: () => _showCommentModal(
                                        context,
                                        review,
                                        brightness,
                                      ),
                                      onBookmark: () {
                                        final recipeId =
                                            review['recipeId'] as String?;
                                        if (recipeId != null &&
                                            recipeId.isNotEmpty) {
                                          _handleBookmark(recipeId);
                                        } else {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                '레시피 ID를 찾을 수 없습니다',
                                              ),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      },
                                      onDelete: () {
                                        final reviewId =
                                            review['id'] as String?;
                                        if (reviewId != null &&
                                            reviewId.isNotEmpty) {
                                          _handleDeleteReview(reviewId);
                                        }
                                      },
                                      onProfileTap: () => Navigator.pushNamed(
                                        context,
                                        '/profile',
                                        arguments: {
                                          'userId': review['userId'] as String?,
                                        },
                                      ),
                                      onRecipeTap: () async {
                                        final recipeId =
                                            review['recipeId'] as String?;
                                        if (recipeId == null ||
                                            recipeId.isEmpty) {
                                          return;
                                        }
                                        try {
                                          final parseResponse =
                                              await _recipeService
                                                  .getRecipeById(recipeId);
                                          if (parseResponse != null &&
                                              mounted) {
                                            Navigator.push(
                                              context,
                                              CupertinoPageRoute(
                                                builder: (context) =>
                                                    RecipeDetailScreen(
                                                      parseResponse:
                                                          parseResponse,
                                                      recipeId: recipeId,
                                                    ),
                                              ),
                                            );
                                          } else if (mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text('레시피를 찾을 수 없습니다'),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          print(
                                            '[OldCommunityScreen] Error navigating to recipe: $e',
                                          );
                                          if (mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '레시피를 불러올 수 없습니다: $e',
                                                ),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  );
                                }, childCount: _reviews.length),
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
  }

  bool _isChefTag(String tag) => isChefDisplayTag(tag);

  Color _getCommunityTagColor(String tag) {
    if (_isChefTag(tag)) return const Color(0xFFF3ECFF);
    switch (tag) {
      case '단백한':
        return const Color(0xFFFFF2F2);
      case '자극적인':
        return const Color(0xFFFFF7F0);
      case '단짠단짠':
        return const Color(0xFFFFFAF0);
      case '매콤한':
      case '얼큰한':
      case '달달한':
        return const Color(0xFFFFF2F2);
      case '담백한':
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFFF0F9FF);
      case '고소한':
        return const Color(0xFFFFFAF0);
      case '진한맛':
      case '꾸덕한':
        return const Color(0xFFFFF3E8);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFFEEF4FF);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
      case '비건':
      case '베지터리언':
        return const Color(0xFFF0FFF0);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFF6EC);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFFBEA);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFF1EEFF);
      case '바삭한':
        return const Color(0xFFFFFAF0);
      case '쫄깃한':
        return const Color(0xFFFFF2F8);
      case '전통':
        return const Color(0xFFF0F0FF);
      case '간편식':
        return const Color(0xFFF0F9FF);
      default:
        return const Color(0xFFFAFAF8);
    }
  }

  Color _getCommunityTagBorderColor(String tag, Brightness brightness) {
    if (_isChefTag(tag)) return const Color(0xFFC6B6F2);
    switch (tag) {
      case '단백한':
        return const Color(0xFFFFCCCC);
      case '자극적인':
        return const Color(0xFFFFD9B3);
      case '단짠단짠':
        return const Color(0xFFFFE5CC);
      case '매콤한':
      case '얼큰한':
      case '달달한':
        return const Color(0xFFFFAAAA);
      case '담백한':
      case '깔끔한':
      case '속편한':
      case '순한':
        return const Color(0xFFCCE5FF);
      case '고소한':
        return const Color(0xFFFFE5CC);
      case '진한맛':
      case '꾸덕한':
        return const Color(0xFFFFD4AD);
      case '촉촉한':
      case '부들부들':
        return const Color(0xFFC4D5FF);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
      case '비건':
      case '베지터리언':
        return const Color(0xFFCCFFCC);
      case '집밥용':
      case '혼밥용':
      case '한끼용':
      case '손님용':
        return const Color(0xFFFFD9B3);
      case '초간편':
      case '10분컷':
        return const Color(0xFFFFE07A);
      case '간식용':
      case '야식각':
      case '해장각':
        return const Color(0xFFC6B6F2);
      case '바삭한':
        return const Color(0xFFFFE5CC);
      case '쫄깃한':
        return const Color(0xFFFFCCE0);
      case '전통':
        return const Color(0xFFCCCCFF);
      case '간편식':
        return const Color(0xFFCCE5FF);
      default:
        return AppColors.getBorder(brightness);
    }
  }

  Color _getCommunityTagTextColor(String tag, Brightness brightness) {
    if (_isChefTag(tag)) return const Color(0xFF5E35B1);
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
        return const Color(0xFF3385D6);
      case '고단백':
      case '건강식':
      case '균형식':
      case '채소가득':
      case '비건':
      case '베지터리언':
        return const Color(0xFF339933);
      case '전통':
        return const Color(0xFF663399);
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

  Widget _buildYorigoRecommendationSection(Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: GestureDetector(
            onTap: () {
              Navigator.pushNamed(context, '/recommendation');
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '레시피 추천',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: brightness == Brightness.dark
                        ? const Color(0xFFFFFFFF)
                        : const Color(0xFF000000),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        _isLoadingRecommendations
            ? const SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator()),
              )
            : _recommendedRecipes.isEmpty
            ? const SizedBox.shrink()
            : SizedBox(
                height: 300,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _recommendedRecipes.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _buildRecommendationCard(
                        _recommendedRecipes[index],
                        brightness,
                      ),
                    );
                  },
                ),
              ),
        const SizedBox(height: 0),
      ],
    );
  }

  Widget _buildRecommendationCard(
    Map<String, dynamic> recipe,
    Brightness brightness,
  ) {
    final title = recipe['title'] as String? ?? '레시피';
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final thumbnailUrl =
        (recipe['thumbnailUrl'] as String?)?.trim() ??
        (source['thumbnail'] as String?)?.trim() ??
        '';
    final recipeId = recipe['id'] as String;

    final tagsRaw = recipe['tags'] as List? ?? [];
    final tags = filterRecipeTagsForDisplay(tagsRaw).take(3).toList();

    final platform = source['platform'] as String? ?? '';
    String creatorInfo = '';
    if (source['uploader'] != null &&
        source['uploader'].toString().isNotEmpty) {
      creatorInfo = source['uploader'].toString();
    } else if (source['channel'] != null &&
        source['channel'].toString().isNotEmpty) {
      creatorInfo = source['channel'].toString();
    }

    const double secondaryFontSize = 10;
    const double imageWidth = 160;
    const double imageHeight = 192;

    return GestureDetector(
      onTap: () async {
        try {
          final parseResponse = await _recipeService.getRecipeById(recipeId);
          if (parseResponse != null && mounted) {
            Navigator.push(
              context,
              CupertinoPageRoute(
                builder: (context) => RecipeDetailScreen(
                  parseResponse: parseResponse,
                  recipeId: recipeId,
                ),
              ),
            );
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('레시피를 찾을 수 없습니다'),
                backgroundColor: Colors.red,
              ),
            );
          }
        } catch (e) {
          print('[OldCommunityScreen] Error navigating to recipe detail: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('레시피를 불러올 수 없습니다: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
      child: SizedBox(
        width: imageWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: thumbnailUrl.isNotEmpty
                  ? AppNetworkImage(
                      imageUrl: thumbnailUrl,
                      width: imageWidth,
                      height: imageHeight,
                      fit: BoxFit.cover,
                      memCacheWidth: AppNetworkImage.listThumbCacheSize,
                      memCacheHeight: AppNetworkImage.listThumbCacheSize,
                      errorWidget: Container(
                        width: imageWidth,
                        height: imageHeight,
                        color: AppColors.getBackgroundTertiary(brightness),
                        child: Icon(
                          Icons.restaurant,
                          size: 40,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      ),
                    )
                  : Container(
                      width: imageWidth,
                      height: imageHeight,
                      color: AppColors.getBackgroundTertiary(brightness),
                      child: Icon(
                        Icons.restaurant,
                        size: 40,
                        color: AppColors.getTextTertiary(brightness),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 3,
                      runSpacing: 3,
                      children: tags.take(3).map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getCommunityTagColor(tag),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: _getCommunityTagBorderColor(
                                tag,
                                brightness,
                              ),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: secondaryFontSize,
                              fontWeight: FontWeight.w900,
                              color: _getCommunityTagTextColor(tag, brightness),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  if (creatorInfo.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildPlatformIconForCreator(platform, brightness),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            truncateChannelName(creatorInfo),
                            style: TextStyle(
                              fontSize: secondaryFontSize,
                              color: AppColors.getTextSecondary(brightness),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlatformIconForCreator(String platform, Brightness brightness) {
    const double size = 14;
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
      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size / 2),
          child: Image.asset(
            assetPath,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _platformIconFallback(size, brightness);
            },
          ),
        ),
      );
    }
    return _platformIconFallback(size, brightness);
  }

  Widget _platformIconFallback(double size, Brightness brightness) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.getBackgroundTertiary(brightness),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.video_library,
        size: size * 0.6,
        color: AppColors.getTextTertiary(brightness),
      ),
    );
  }
}
