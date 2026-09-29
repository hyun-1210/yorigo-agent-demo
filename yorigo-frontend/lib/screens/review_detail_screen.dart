import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../widgets/naver_blog_access_dialog.dart';
import '../widgets/user_initial_avatar.dart';
import '../services/user_service.dart';
import '../services/recipe_service.dart';
import '../utils/text_utils.dart';

class ReviewDetailScreen extends StatefulWidget {
  final List<Map<String, dynamic>> allReviews;
  final int initialIndex;

  const ReviewDetailScreen({
    super.key,
    required this.allReviews,
    required this.initialIndex,
  });

  @override
  State<ReviewDetailScreen> createState() => _ReviewDetailScreenState();
}

class _ReviewDetailScreenState extends State<ReviewDetailScreen> {
  late ScrollController _scrollController;
  final UserService _userService = UserService();
  final RecipeService _recipeService = RecipeService();
  final Map<String, Map<String, dynamic>> _userDataCache = {};

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _loadUserData();
    // Scroll to initial position after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToInitialPosition();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToInitialPosition() {
    // For content-based sizing, we estimate position
    // Each review card is approximately 500-600px, scroll to approximate position
    if (_scrollController.hasClients && widget.initialIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          // Approximate scroll - will be close to the target item
          final estimatedItemHeight = 550.0;
          final offset = widget.initialIndex * estimatedItemHeight;
          _scrollController.jumpTo(
            offset.clamp(0.0, _scrollController.position.maxScrollExtent),
          );
        }
      });
    }
  }

  Future<void> _loadUserData() async {
    // Load user data for all reviews
    final userIds = widget.allReviews
        .map((review) => review['userId'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toSet();

    for (var userId in userIds) {
      if (_userDataCache.containsKey(userId)) continue;

      try {
        final userDoc = await _userService.getUserDocument(userId);
        final userData = userDoc.data() as Map<String, dynamic>?;
        _userDataCache[userId] = userData ?? {};
      } catch (e) {
        print('[ReviewDetailScreen] Error loading user data: $e');
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  Map<String, dynamic> _getUserData(String userId) {
    return _userDataCache[userId] ?? {};
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return DateFormat('MM.dd.yyyy').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: Stack(
        children: [
          // Scrollable reviews - content-based sizing with small margins
          ListView.separated(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 56,
              bottom: 16,
            ),
            physics: const ClampingScrollPhysics(),
            itemCount: widget.allReviews.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final review = widget.allReviews[index];
              return _buildReviewPage(review, brightness, index);
            },
          ),
          // Sticky back button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewPage(
    Map<String, dynamic> review,
    Brightness brightness,
    int index,
  ) {
    final userId = review['userId'] as String? ?? '';
    final userData = _getUserData(userId);
    final userName =
        userData['name'] as String? ??
        (review['creatorUsername'] as String? ?? '사용자');
    final handle = userData['handle'] as String? ?? '';
    final photoUrl = resolveUserPhotoUrl(userData);
    final reviewPhotoUrls = _resolveReviewPhotoUrls(review);
    final hasReviewPhoto = reviewPhotoUrls.isNotEmpty;
    final rating = (review['rating'] as num?)?.toInt() ?? 0;
    final comment = review['comment'] as String? ?? '';
    final createdAt = (review['createdAt'] as Timestamp?)?.toDate();
    final dateString = _formatDate(createdAt);
    final recipeId = review['recipeId'] as String? ?? '';
    final recipeTitle = review['recipeTitle'] as String? ?? '레시피';
    final creatorUsername = review['creatorUsername'] as String? ?? '';
    final platform = review['platform'] as String? ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Recipe info row (above profile section)
        if (recipeId.isNotEmpty)
          InkWell(
            onTap: () async {
              try {
                final parseResponse = await _recipeService.getRecipeById(
                  recipeId,
                );
                if (parseResponse != null && mounted) {
                  // 네이버 블로그: 본문은 본인 디바이스 로컬에만 저장.
                  // 본문이 없으면 디테일 진입 차단하고 다이얼로그 표시.
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
                  if (mounted) {
                    showAppSnackBar(context, 
                      const SnackBar(
                        content: Text('레시피를 불러올 수 없습니다'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              } catch (e) {
                print('[ReviewDetailScreen] Error navigating to recipe: $e');
                if (mounted) {
                  showAppSnackBar(context, 
                    const SnackBar(
                      content: Text('레시피를 불러올 수 없습니다'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.getBackgroundSecondary(brightness),
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.getBorder(brightness),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Recipe title
                  Expanded(
                    child: Text(
                      recipeTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (creatorUsername.isNotEmpty || platform.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (creatorUsername.isNotEmpty)
                          Flexible(
                            child: Text(
                              truncateChannelName(creatorUsername),
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.getTextSecondary(brightness),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                          ),
                        if (platform.isNotEmpty) ...[
                          if (creatorUsername.isNotEmpty)
                            const SizedBox(width: 8),
                          _buildPlatformIcon(platform, brightness),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

        // Profile section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Profile picture
              if (photoUrl != null && photoUrl.isNotEmpty)
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  backgroundImage: AppNetworkImage.imageProviderForAvatar(
                    photoUrl,
                  ),
                )
              else
                UserInitialAvatar(
                  seed: userId.isNotEmpty
                      ? userId
                      : (handle.isNotEmpty ? handle : userName),
                  name: userName,
                  size: 48,
                ),
              const SizedBox(width: 12),
              // Name and handle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                    if (handle.isNotEmpty)
                      Text(
                        '@$handle',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.getTextSecondary(brightness),
                        ),
                      ),
                  ],
                ),
              ),
              // Date
              Text(
                dateString,
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
            ],
          ),
        ),

        // Review images (only if exists) - square aspect ratio, swipeable when multi
        if (hasReviewPhoto)
          AspectRatio(
            aspectRatio: 1.0,
            child: _ReviewPhotoCarousel(
              photoUrls: reviewPhotoUrls,
              brightness: brightness,
            ),
          ),

        // Rating and comment section
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Star rating
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    index < rating ? Icons.star : Icons.star_border,
                    color: AppColors.primary,
                    size: 24,
                  );
                }),
              ),
              if (comment.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  comment,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.getTextPrimary(brightness),
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlatformIcon(String platform, Brightness brightness) {
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

    if (assetPath == null) {
      return const SizedBox.shrink();
    }

    return Image.asset(
      assetPath,
      width: 24,
      height: 24,
      errorBuilder: (context, error, stackTrace) {
        return const SizedBox.shrink();
      },
    );
  }

  /// Resolve all review photo URLs from a Firestore document.
  /// Prefers `photoUrls` (multi-photo); falls back to legacy `photoUrl`.
  List<String> _resolveReviewPhotoUrls(Map<String, dynamic> review) {
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
}

/// Square swipeable carousel for the review detail page.
/// Shows a "N/M" pill in the top-right when there is more than one photo.
class _ReviewPhotoCarousel extends StatefulWidget {
  const _ReviewPhotoCarousel({
    required this.photoUrls,
    required this.brightness,
  });

  final List<String> photoUrls;
  final Brightness brightness;

  @override
  State<_ReviewPhotoCarousel> createState() => _ReviewPhotoCarouselState();
}

class _ReviewPhotoCarouselState extends State<_ReviewPhotoCarousel> {
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
    final brightness = widget.brightness;
    return Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _controller,
            itemCount: urls.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              return AppNetworkImage(
                imageUrl: urls[i],
                fit: BoxFit.cover,
                width: double.infinity,
                memCacheWidth: AppNetworkImage.feedImageCacheSize,
                errorWidget: Container(
                  color: AppColors.getBackgroundSecondary(brightness),
                  child: Center(
                    child: Icon(
                      Icons.broken_image,
                      size: 48,
                      color: AppColors.getTextTertiary(brightness),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (urls.length > 1)
          Positioned(
            right: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
      ],
    );
  }
}
