import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_colors.dart';
import '../utils/haptics.dart';
import '../utils/yorigo_level.dart';
import '../utils/review_cooked_label.dart';
import '../utils/review_display_date.dart';
import 'app_network_image.dart';
import 'review_post_action_sheets.dart';
import 'user_initial_avatar.dart';
import 'recipe_bookmark_glyph.dart';
import 'feed_like_heart.dart';

const Color _kFeedBorder = Color(0xFFF3F4F6);

/// Instagram-style feed post card. Visually mirrors the community feed card
/// (`category_explore_screen.dart` `_FeedPostCard`) so a review opened from
/// any entry point looks identical.
class FeedPostCard extends StatelessWidget {
  final Map<String, dynamic> review;
  final Map<String, Map<String, dynamic>> userDataCache;
  final Brightness brightness;
  final bool isLiked;
  final int likeCount;
  final bool showLikingHeart;
  final bool showRecipeRow;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback? onProfileTap;
  final VoidCallback? onRecipeTap;
  final int commentCount;
  final bool isBookmarked;
  final VoidCallback? onBookmark;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onReportSubmitted;
  final VoidCallback? onBlockUser;
  final bool isOwnPost;
  final bool isAdmin;
  final List<String>? recipeTags;
  final double? recipeAverageRating;
  final int? recipeReviewCount;

  const FeedPostCard({
    super.key,
    required this.review,
    required this.userDataCache,
    required this.brightness,
    required this.isLiked,
    required this.likeCount,
    this.commentCount = 0,
    this.isBookmarked = false,
    this.showLikingHeart = false,
    this.showRecipeRow = true,
    required this.onLike,
    required this.onComment,
    this.onBookmark,
    this.onDelete,
    this.onEdit,
    this.onReportSubmitted,
    this.onBlockUser,
    this.isOwnPost = false,
    this.isAdmin = false,
    this.recipeTags,
    this.recipeAverageRating,
    this.recipeReviewCount,
    this.onProfileTap,
    this.onRecipeTap,
  });



  static String? _resolveProfileUrl(
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
    ];
    for (final c in candidates) {
      final v = c?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  /// `creatorUsername`은 레시피 채널명이라 작성자 닉네임 fallback으로 쓰지 않는다.
  static String _resolveAuthorDisplayName(
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

  /// Resolve all review photo URLs.
  /// Prefers `photoUrls` (multi-photo); falls back to legacy single `photoUrl`.
  static List<String> _resolveReviewPhotoUrls(Map<String, dynamic> review) {
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

  @override
  Widget build(BuildContext context) {
    final userId = review['userId'] as String? ?? '';
    final userData = userDataCache[userId] ?? {};
    // creatorUsername은 레시피 채널명(영문)이라 작성자 닉네임 fallback으로 쓰지 않는다.
    final displayName = _resolveAuthorDisplayName(userData, review);
    final profilePhotoUrl = _resolveProfileUrl(userData, review);
    final authorLevel = yorigoLevelFromUserData(userData);
    final timeAgo = reviewFeedTimeAgo(review);
    final cookedLabel = reviewCookedDateLabel(review);

    final photoUrls = _resolveReviewPhotoUrls(review);
    final recipeTitle = review['recipeTitle'] as String? ?? '레시피';
    // 연결된 레시피가 없는(유저가 직접 올린) 후기: 북마크 숨기고 작성자 이름 표시.
    final hasLinkedRecipe =
        (review['recipeId'] as String?)?.trim().isNotEmpty == true;
    final platform = review['platform'] as String? ?? '';
    final creatorUsername = review['creatorUsername'] as String? ?? '';
    final handle = creatorUsername.trim().isEmpty
        ? ''
        : (creatorUsername.startsWith('@') ? creatorUsername : '@$creatorUsername');
    final comment = review['comment'] as String? ?? '';

    final mergedRecipeTags = (recipeTags ?? const <String>[])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final resolvedAverageRating =
        recipeAverageRating ??
        (review['recipeAverageRating'] as num?)?.toDouble() ??
        (review['averageRating'] as num?)?.toDouble();
    final resolvedReviewCount =
        recipeReviewCount ??
        (review['recipeReviewCount'] as num?)?.toInt() ??
        (review['reviewCount'] as num?)?.toInt() ??
        0;

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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
              IconButton(
                icon: Icon(Icons.more_horiz, size: 25, color: textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () {
                  final reviewId = review['id'] as String? ?? '';
                  showReviewPostMenuBottomSheet(
                    context,
                    isOwnPost: isOwnPost,
                    isAdmin: isAdmin,
                    shareText: defaultReviewShareText(review),
                    shareSubject: defaultReviewShareSubject(review),
                    onEdit: isOwnPost ? onEdit : null,
                    onDelete: (isOwnPost || isAdmin) ? onDelete : null,
                    onOpenReport:
                        (!isOwnPost && !isAdmin && reviewId.isNotEmpty)
                        ? () {
                            showReviewReportBottomSheet(
                              context,
                              type: 'review',
                              targetId: reviewId,
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
        // Full-width image (1:1) with optional like overlay; multi-photo supports swipe.
        _FeedPhotoCarousel(
          photoUrls: photoUrls,
          onTap: onRecipeTap,
          onDoubleTap: () {
            Haptics.light();
            onLike();
          },
          showLikingHeart: showLikingHeart,
          textTertiary: textTertiary,
        ),
        if (showRecipeRow)
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
                              if (resolvedReviewCount > 0 &&
                                  resolvedAverageRating != null) ...[
                                const SizedBox(width: 5),
                                const Icon(
                                  Icons.star_rounded,
                                  size: 11,
                                  color: Color(0xFFF59E0B),
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  resolvedAverageRating.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1E2939),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '($resolvedReviewCount)',
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
                            onTap: onBookmark == null
                                ? null
                                : () {
                                    Haptics.light();
                                    onBookmark!();
                                  },
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
                    if (mergedRecipeTags.isNotEmpty ||
                        !hasLinkedRecipe ||
                        platform.isNotEmpty ||
                        handle.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          if (mergedRecipeTags.isNotEmpty)
                            Expanded(
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: mergedRecipeTags
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
        // Action row: like, comment, bookmark
        Transform.translate(
          offset: const Offset(0, -6),
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 5),
          child: Row(
            children: [
              SizedBox(
                height: 34,
                child: InkWell(
                  onTap: () {
                    Haptics.light();
                    onLike();
                  },
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FeedLikeHeart(
                          isLiked: isLiked,
                          size: 26,
                          color: isLiked ? Colors.red : textSecondary,
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
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: onComment,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/icons/feed_chatbubble.png',
                        width: 20,
                        height: 20,
                        color: textSecondary,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.chat_bubble_outline,
                          color: textSecondary,
                          size: 20,
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
              const Spacer(),
            ],
          ),
        ),
        ),
        // Caption + comments link + timestamp
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

/// 34px circle avatar with a brand orange ring when the user has uploaded a
/// photo, or a soft pastel `color + first letter` chip otherwise.
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

/// Square 1:1 photo carousel for the review feed post card.
/// Up to 3 photos with a top-right N/M pill (only when multi).
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
  final VoidCallback? onTap;
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
              color: _kFeedBorder,
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
            Positioned.fill(child: _LikeOverlay(onTap: widget.onTap ?? () {})),
        ],
      ),
    );
  }
}

/// Animated red-heart overlay on double-tap-like, fading after ~1.2s.
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

/// Platform logo (YouTube / Instagram / TikTok) shown in the recipe card pill.
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

class ExpandableComment extends StatefulWidget {
  final String displayName;
  final String comment;
  final Color textColor;

  const ExpandableComment({
    super.key,
    required this.displayName,
    required this.comment,
    required this.textColor,
  });

  @override
  State<ExpandableComment> createState() => _ExpandableCommentState();
}

class _ExpandableCommentState extends State<ExpandableComment> {
  bool _expanded = false;

  static const _suffix = '...\u2060더\u2060보\u2060기';
  static const _suffixGray = Color(0xFF9CA3AF);
  static const _extraTrimChars = 4;

  TextStyle _bodyStyle() => TextStyle(
        fontFamily: 'Pretendard',
        fontSize: 13,
        color: widget.textColor,
        height: 1.5,
      );

  TextStyle _suffixStyle(TextStyle body) => body.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: _suffixGray,
      );

  TextSpan _nameSpan(TextStyle body) => TextSpan(
        text: '${widget.displayName} ',
        style: body.copyWith(fontWeight: FontWeight.w700),
      );

  TextSpan _collapsedSpan({
    required TextSpan nameSpan,
    required String trimmedComment,
    required TextStyle body,
    required TextStyle suffixStyle,
  }) {
    return TextSpan(
      style: body,
      children: [
        nameSpan,
        if (trimmedComment.isNotEmpty) TextSpan(text: trimmedComment),
        TextSpan(text: _suffix, style: suffixStyle),
      ],
    );
  }

  bool _collapsedLayoutFits({
    required TextSpan span,
    required double maxWidth,
  }) {
    final plain = span.toPlainText();
    final suffixStart = plain.length - _suffix.length;

    final painter = TextPainter(
      text: span,
      maxLines: 2,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    if (painter.didExceedMaxLines) return false;

    final suffixLine =
        painter.getLineBoundary(TextPosition(offset: suffixStart));
    final endLine = painter.getLineBoundary(
      TextPosition(offset: plain.length - 1),
    );
    return suffixLine.start == endLine.start;
  }

  String _trimCommentForSuffix({
    required TextSpan nameSpan,
    required TextStyle body,
    required TextStyle suffixStyle,
    required double maxWidth,
  }) {
    final nameLen = '${widget.displayName} '.length;

    final suffixPainter = TextPainter(
      text: TextSpan(text: _suffix, style: suffixStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final reservedWidth = suffixPainter.width + 10;

    final fullPainter = TextPainter(
      text: TextSpan(style: body, children: [
        nameSpan,
        TextSpan(text: widget.comment),
      ]),
      maxLines: 2,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    final lines = fullPainter.computeLineMetrics();
    if (lines.isEmpty) return '';

    final lastLine = lines.last;
    final cutX = (lastLine.left + lastLine.width - reservedWidth)
        .clamp(lastLine.left, lastLine.left + lastLine.width);
    final cutOffset = fullPainter
        .getPositionForOffset(Offset(cutX, lastLine.baseline))
        .offset;

    var end = (cutOffset - nameLen).clamp(0, widget.comment.length);
    end = (end - _extraTrimChars).clamp(0, widget.comment.length);
    var trimmed = _prefixByGraphemes(widget.comment, end);

    while (trimmed.isNotEmpty) {
      final span = _collapsedSpan(
        nameSpan: nameSpan,
        trimmedComment: trimmed,
        body: body,
        suffixStyle: suffixStyle,
      );
      if (_collapsedLayoutFits(span: span, maxWidth: maxWidth)) {
        return trimmed;
      }
      trimmed = trimmed.characters.skipLast(1).toString().trimRight();
    }

    return '';
  }

  String _prefixByGraphemes(String text, int endOffset) {
    if (endOffset <= 0) return '';
    if (endOffset >= text.length) return text.trimRight();
    var taken = 0;
    final buffer = StringBuffer();
    for (final grapheme in text.characters) {
      final next = taken + grapheme.length;
      if (next > endOffset) break;
      buffer.write(grapheme);
      taken = next;
    }
    return buffer.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final body = _bodyStyle();
    final suffixStyle = _suffixStyle(body);
    final nameSpan = _nameSpan(body);

    final fullCaption = Text.rich(
      TextSpan(style: body, children: [
        nameSpan,
        TextSpan(text: widget.comment),
      ]),
    );

    if (_expanded) return fullCaption;

    return LayoutBuilder(
      builder: (context, constraints) {
        final overflowPainter = TextPainter(
          text: TextSpan(style: body, children: [
            nameSpan,
            TextSpan(text: widget.comment),
          ]),
          maxLines: 2,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (!overflowPainter.didExceedMaxLines) return fullCaption;

        final trimmed = _trimCommentForSuffix(
          nameSpan: nameSpan,
          body: body,
          suffixStyle: suffixStyle,
          maxWidth: constraints.maxWidth,
        );

        return GestureDetector(
          onTap: () => setState(() => _expanded = true),
          behavior: HitTestBehavior.opaque,
          child: Text.rich(
            _collapsedSpan(
              nameSpan: nameSpan,
              trimmedComment: trimmed,
              body: body,
              suffixStyle: suffixStyle,
            ),
            maxLines: 2,
          ),
        );
      },
    );
  }
}
