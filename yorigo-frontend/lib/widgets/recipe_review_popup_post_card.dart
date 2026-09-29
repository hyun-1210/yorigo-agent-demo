import 'package:flutter/material.dart';
import '../widgets/app_network_image.dart';
import 'review_post_action_sheets.dart';

/// Review post card used by:
/// - the recipe detail "comment box" popup list (사진 리뷰 포함)
/// - the full-screen review feed opened from a photo
///
/// Note: This is intentionally styled to match the design from `_buildPopupReviewPostCard`
/// inside `recipe_detail_screen.dart`.
class RecipeReviewPopupPostCard extends StatelessWidget {
  static const String _starEmptyPath = 'assets/icons/review_star_empty.png';
  static const String _starFilledPath = 'assets/icons/review_star_filled.png';

  final Map<String, dynamic> review;
  final int index;
  final Brightness brightness;
  final Map<String, Map<String, dynamic>> userDataCache;

  final bool isLiked;
  final int likeCount;
  final int commentCount;

  final VoidCallback onLike;
  final VoidCallback onImageDoubleTap;
  final VoidCallback onComment;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final bool isOwnPost;
  final bool isAdmin;

  const RecipeReviewPopupPostCard({
    super.key,
    required this.review,
    required this.index,
    required this.brightness,
    required this.userDataCache,
    required this.isLiked,
    required this.likeCount,
    required this.commentCount,
    required this.onLike,
    required this.onImageDoubleTap,
    required this.onComment,
    this.onDelete,
    this.onEdit,
    this.isOwnPost = false,
    this.isAdmin = false,
  });

  @override
  Widget build(BuildContext context) {
    final userId = review['userId'] as String? ?? '';
    final userData = userDataCache[userId] ?? {};

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User row
          Row(
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
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.more_horiz,
                  size: 24,
                  color: Color(0xFF8B95A1),
                ),
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
                            );
                          }
                        : null,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Image carousel — square, same as community feed.
          if (photoUrls.isNotEmpty)
            AspectRatio(
              aspectRatio: 1.0,
              child: PageView.builder(
                itemCount: photoUrls.length,
                itemBuilder: (context, photoIndex) {
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          onDoubleTap: onImageDoubleTap,
                          behavior: HitTestBehavior.opaque,
                          child: AppNetworkImage(
                            imageUrl: photoUrls[photoIndex],
                            fit: BoxFit.cover,
                            width: double.infinity,
                            memCacheWidth: AppNetworkImage.feedImageCacheSize,
                          ),
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

          // Stars + meta capsule
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
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

          // Comment (name bold + written review)
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
    final raw =
        review['benefits'] ??
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

  int _millisecondsFromCreatedAt(dynamic createdAt) {
    if (createdAt == null) return 0;
    if (createdAt is DateTime) return createdAt.millisecondsSinceEpoch;
    try {
      final ms = (createdAt as dynamic).millisecondsSinceEpoch;
      return ms is int ? ms : 0;
    } catch (_) {}
    return 0;
  }

  String _formatReviewDateText(int createdAtMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final wd = weekdays[(dt.weekday - 1).clamp(0, 6)];
    return '${dt.month}.${dt.day}.$wd';
  }
}
