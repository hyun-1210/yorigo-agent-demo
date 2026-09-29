import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/app_refresh_indicator.dart';
import '../services/review_service.dart';
import '../widgets/app_network_image.dart';
import 'review_detail_screen.dart';

/// Lists all reviews written by [userId], newest first. Tap opens [ReviewDetailScreen].
class UserReviewsListScreen extends StatefulWidget {
  const UserReviewsListScreen({super.key, required this.userId});

  final String userId;

  @override
  State<UserReviewsListScreen> createState() => _UserReviewsListScreenState();
}

class _UserReviewsListScreenState extends State<UserReviewsListScreen> {
  final ReviewService _reviewService = ReviewService();
  bool _loading = true;
  List<Map<String, dynamic>> _reviews = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _reviewService.getUserReviews(widget.userId);
      list.sort((a, b) {
        final dateA = _reviewDate(a);
        final dateB = _reviewDate(b);
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA);
      });
      if (mounted) {
        setState(() {
          _reviews = list;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[UserReviewsListScreen] load error: $e');
      if (mounted) {
        setState(() {
          _reviews = [];
          _loading = false;
        });
      }
    }
  }

  DateTime? _reviewDate(Map<String, dynamic> r) {
    final ts = r['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    if (ts is DateTime) return ts;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '남겨진 후기',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111111),
          ),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reviews.isEmpty
              ? Center(
                  child: Text(
                    '아직 남긴 후기가 없어요',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600,
                    ),
                  ),
                )
              : AppRefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      12,
                      16,
                      24 + appSystemNavBottomInset(context),
                    ),
                    itemCount: _reviews.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final review = _reviews[index];
                      final photoUrl = review['photoUrl'] as String?;
                      final title =
                          review['recipeTitle'] as String? ?? '레시피';
                      final date = _reviewDate(review);
                      final dateStr = date != null
                          ? '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}'
                          : '';

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) => ReviewDetailScreen(
                                  allReviews: _reviews,
                                  initialIndex: index,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: photoUrl != null &&
                                            photoUrl.isNotEmpty
                                        ? AppNetworkImage(
                                            imageUrl: photoUrl,
                                            width: 56,
                                            height: 56,
                                            fit: BoxFit.cover,
                                            // Width-only cap preserves
                                            // source aspect ratio on decode.
                                            memCacheWidth: 112,
                                          )
                                        : Container(
                                            color: const Color(0xFFF3F4F6),
                                            child: const Icon(
                                              Icons.restaurant,
                                              color: Color(0xFF9CA3AF),
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF111111),
                                          height: 1.3,
                                        ),
                                      ),
                                      if (dateStr.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          dateStr,
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF9CA3AF),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFF9CA3AF),
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
