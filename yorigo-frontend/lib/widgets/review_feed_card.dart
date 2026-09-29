import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/user_service.dart';
import 'app_network_image.dart';
import 'user_initial_avatar.dart';

/// Feed-style review card: photo, likes row, stars + comment.
/// Used in recipe detail 후기 tab and in recipe review feed scroll.
class ReviewFeedCard extends StatefulWidget {
  final Map<String, dynamic> review;
  final Map<String, Map<String, dynamic>> userDataCache;
  final Brightness brightness;
  final VoidCallback? onTap;

  const ReviewFeedCard({
    super.key,
    required this.review,
    required this.userDataCache,
    required this.brightness,
    this.onTap,
  });

  @override
  State<ReviewFeedCard> createState() => _ReviewFeedCardState();
}

class _ReviewFeedCardState extends State<ReviewFeedCard> {
  final PageController _photoController = PageController();
  int _photoIndex = 0;

  @override
  void dispose() {
    _photoController.dispose();
    super.dispose();
  }

  /// Resolve all photo URLs for this review.
  /// Prefer `photoUrls` (multi-photo); fall back to single `photoUrl`/legacy.
  /// `photoThumbnailUrl` (singular, primary thumbnail) replaces the first URL
  /// when present to keep the existing list-feed perf optimization.
  List<String> _resolvePhotoUrls(Map<String, dynamic> review) {
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
    if (urls.isNotEmpty) {
      final thumb = (review['photoThumbnailUrl'] as String?)?.trim() ?? '';
      if (thumb.isNotEmpty) {
        urls[0] = thumb;
      }
    }
    return urls;
  }

  Map<String, dynamic> _getUserData(String userId) {
    return widget.userDataCache[userId] ?? {};
  }

  static Widget buildLikesRow(
    Map<String, dynamic> review,
    int likeCount,
    Map<String, Map<String, dynamic>> userDataCache,
    Brightness brightness,
  ) {
    final likedBy =
        (review['likedBy'] as List?)
            ?.map((e) => e?.toString())
            .where((s) => s != null && s.isNotEmpty)
            .cast<String>()
            .take(3)
            .toList() ??
        [];
    const double avatarSize = 20.0;
    const double overlap = 5.0;
    const double borderWidth = 2.5;

    String firstLikerName = '누군가';
    if (likedBy.isNotEmpty) {
      final first = userDataCache[likedBy.first] ?? {};
      firstLikerName = first['name'] as String? ?? '누군가';
    }

    final othersCount = likeCount - 1;
    final othersText = othersCount > 2 ? '여러명' : '$othersCount';
    final textColor = AppColors.getTextPrimary(brightness);
    final baseStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: textColor,
    );
    final boldStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: textColor,
    );

    final totalAvatarWidth = likedBy.isEmpty
        ? 0.0
        : (avatarSize + borderWidth * 2) +
              (likedBy.length - 1) * (avatarSize - overlap);

    return Row(
      children: [
        SizedBox(
          width: totalAvatarWidth,
          height: avatarSize + borderWidth * 2,
          child: Stack(
            clipBehavior: Clip.none,
            children: List.generate(likedBy.length, (i) {
              final uid = likedBy[i];
              final userData = userDataCache[uid] ?? {};
              final photoUrl = resolveUserPhotoUrl(userData);
              final likerName = (userData['name'] as String?)?.trim() ?? '';
              final likerHandle = (userData['handle'] as String?)?.trim() ?? '';
              final initialAvatar = UserInitialAvatar(
                seed: uid,
                name: likerName.isNotEmpty
                    ? likerName
                    : (likerHandle.isNotEmpty ? likerHandle : '요리친구'),
                size: avatarSize,
              );
              return Positioned(
                left: i * (avatarSize - overlap),
                top: 0,
                child: Container(
                  width: avatarSize + borderWidth * 2,
                  height: avatarSize + borderWidth * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: Colors.white, width: borderWidth),
                  ),
                  child: ClipOval(
                    child: photoUrl != null && photoUrl.isNotEmpty
                        ? Image(
                            image: AppNetworkImage.imageProviderForAvatar(
                              photoUrl,
                            ),
                            width: avatarSize,
                            height: avatarSize,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => initialAvatar,
                          )
                        : initialAvatar,
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: likeCount == 1
              ? Text.rich(
                  TextSpan(
                    style: baseStyle,
                    children: [
                      TextSpan(text: firstLikerName, style: boldStyle),
                      const TextSpan(text: '님이 좋아합니다'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : Text.rich(
                  TextSpan(
                    style: baseStyle,
                    children: [
                      TextSpan(text: firstLikerName, style: boldStyle),
                      const TextSpan(text: '님 외 '),
                      TextSpan(text: othersText, style: boldStyle),
                      const TextSpan(text: '명이 좋아합니다'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final brightness = widget.brightness;
    final userDataCache = widget.userDataCache;

    final photoUrls = _resolvePhotoUrls(review);
    final hasPhoto = photoUrls.isNotEmpty;
    final rating = (review['rating'] as num?)?.toInt() ?? 0;
    final comment = review['comment'] as String? ?? '';
    final likeCount = (review['likeCount'] as num?)?.toInt() ?? 0;
    final userId = review['userId'] as String? ?? '';
    final userData = _getUserData(userId);
    final handle = userData['handle'] as String? ?? '';

    const double starSize = 18.0;
    const double step = starSize * 0.7;
    const double starRowWidth = starSize + 4 * step;
    const double handleGap = 6.0;
    const double starsToTextGap = 2.0;

    final commentStyle = TextStyle(
      fontSize: 14,
      color: AppColors.getTextPrimary(brightness),
      height: 1.4,
    );
    final handleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: AppColors.getTextPrimary(brightness),
    );

    final commentText = comment.replaceAll(RegExp(r'[\r\n]+'), ' ');

    return InkWell(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: AppColors.getBackground(brightness),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.getBorder(brightness), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasPhoto)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(11),
                ),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: PageView.builder(
                          controller: _photoController,
                          itemCount: photoUrls.length,
                          onPageChanged: (i) => setState(() => _photoIndex = i),
                          itemBuilder: (context, i) {
                            return AppNetworkImage(
                              imageUrl: photoUrls[i],
                              fit: BoxFit.cover,
                              width: double.infinity,
                              // Width-only cap preserves source aspect ratio on decode.
                              memCacheWidth: AppNetworkImage.feedImageCacheSize,
                              errorWidget: Container(
                                color: AppColors.getBackgroundSecondary(
                                  brightness,
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.broken_image,
                                    size: 48,
                                    color: AppColors.getTextTertiary(
                                      brightness,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (photoUrls.length > 1)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${_photoIndex + 1}/${photoUrls.length}',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            else
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: AppColors.getBackgroundTertiary(brightness),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.star,
                    size: 40,
                    color: AppColors.getTextTertiary(brightness),
                  ),
                ),
              ),
            if (likeCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: buildLikesRow(
                  review,
                  likeCount,
                  userDataCache,
                  brightness,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxContentWidth = constraints.maxWidth;
                  double firstLineWidth =
                      maxContentWidth - starRowWidth - starsToTextGap;
                  if (handle.isNotEmpty) {
                    final handlePainter = TextPainter(
                      text: TextSpan(text: handle, style: handleStyle),
                      textDirection: TextDirection.ltr,
                      maxLines: 1,
                    )..layout(maxWidth: double.infinity);
                    firstLineWidth -= handlePainter.width + handleGap;
                  }
                  firstLineWidth = firstLineWidth.clamp(0.0, double.infinity);

                  String firstLine = commentText;
                  String rest = '';
                  if (commentText.isNotEmpty && firstLineWidth > 0) {
                    final commentPainter = TextPainter(
                      text: TextSpan(text: commentText, style: commentStyle),
                      textDirection: TextDirection.ltr,
                      maxLines: 1,
                    )..layout(maxWidth: firstLineWidth);
                    var endOffset = commentPainter
                        .getPositionForOffset(Offset(firstLineWidth, 8))
                        .offset;
                    endOffset = endOffset.clamp(0, commentText.length);
                    if (endOffset < commentText.length && endOffset > 0) {
                      firstLine = commentText.substring(0, endOffset).trim();
                      rest = commentText.substring(endOffset).trim();
                    }
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (handle.isNotEmpty)
                            Text(handle, style: handleStyle),
                          if (handle.isNotEmpty) SizedBox(width: handleGap),
                          SizedBox(
                            width: starRowWidth,
                            height: starSize,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: List.generate(5, (i) {
                                return Positioned(
                                  left: i * step,
                                  top: 0,
                                  child: Icon(
                                    i < rating ? Icons.star : Icons.star_border,
                                    color: const Color(0xFFFF6B35),
                                    size: starSize,
                                  ),
                                );
                              }),
                            ),
                          ),
                          if (commentText.isNotEmpty) ...[
                            SizedBox(width: starsToTextGap),
                            Expanded(
                              child: Text(
                                firstLine,
                                style: commentStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (rest.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(rest, style: commentStyle),
                      ],
                    ],
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
