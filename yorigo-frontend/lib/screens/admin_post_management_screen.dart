import 'package:flutter/material.dart';
import '../widgets/app_refresh_indicator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/admin_service.dart';
import '../services/review_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_confirm_dialog.dart';

class AdminPostManagementScreen extends StatefulWidget {
  const AdminPostManagementScreen({super.key});

  @override
  State<AdminPostManagementScreen> createState() =>
      _AdminPostManagementScreenState();
}

class _AdminPostManagementScreenState extends State<AdminPostManagementScreen> {
  final ReviewService _reviewService = ReviewService();
  bool _checkingAdmin = true;
  bool _isAdmin = false;
  bool _loading = true;
  List<Map<String, dynamic>> _reviews = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final isAdmin = await AdminService.instance.isAdmin();
    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _checkingAdmin = false;
    });
    if (!isAdmin) return;
    await _loadReviews();
  }

  Future<void> _loadReviews() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final reviews = await _reviewService.getCommunityReviews(
        includeHiddenForAdmin: true,
      );
      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleHidden(Map<String, dynamic> review) async {
    final reviewId = review['id'] as String? ?? '';
    if (reviewId.isEmpty) return;
    final isHidden = review['isHidden'] == true;
    try {
      await _reviewService.setReviewHidden(
        reviewId: reviewId,
        hidden: !isHidden,
        reason: !isHidden
            ? 'admin_hide_from_management_page'
            : 'admin_unhide_from_management_page',
      );
      if (!mounted) return;
      setState(() {
        final idx = _reviews.indexWhere(
          (r) => (r['id'] as String?) == reviewId,
        );
        if (idx >= 0) {
          _reviews[idx]['isHidden'] = !isHidden;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(!isHidden ? '게시물을 숨겼습니다' : '게시물 숨김을 해제했습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('처리 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteReview(Map<String, dynamic> review) async {
    final reviewId = review['id'] as String? ?? '';
    if (reviewId.isEmpty) return;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '게시물을 삭제할까요?',
      description: '삭제된 게시물은 복구할 수 없어요.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (confirmed != true) return;

    try {
      await _reviewService.deleteReview(reviewId, allowAdminOverride: true);
      if (!mounted) return;
      setState(() {
        _reviews.removeWhere((r) => (r['id'] as String?) == reviewId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('게시물을 삭제했습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('삭제 중 오류가 발생했습니다: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingAdmin) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('관리자 게시물 관리')),
        body: const Center(child: Text('관리자만 접근할 수 있습니다')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 게시물 관리'),
        actions: [
          IconButton(
            onPressed: _loadReviews,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reviews.isEmpty
          ? const Center(child: Text('표시할 게시물이 없습니다'))
          : AppRefreshIndicator(
              onRefresh: _loadReviews,
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: _reviews.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final review = _reviews[index];
                  final reviewId = review['id'] as String? ?? '';
                  final userId = review['userId'] as String? ?? '';
                  final comment = (review['comment'] as String? ?? '').trim();
                  final photoUrl = (review['photoUrl'] as String? ?? '').trim();
                  final reportCount =
                      (review['reportCount'] as num?)?.toInt() ?? 0;
                  final isHidden = review['isHidden'] == true;
                  final createdAt = (review['createdAt'] as Timestamp?)
                      ?.toDate();
                  final createdText = createdAt == null
                      ? '-'
                      : '${createdAt.year}.${createdAt.month.toString().padLeft(2, '0')}.${createdAt.day.toString().padLeft(2, '0')}';

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '리뷰 ID: $reviewId',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isHidden
                                    ? const Color(0xFFFEE2E2)
                                    : const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                isHidden ? '숨김' : '노출',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isHidden
                                      ? const Color(0xFFB91C1C)
                                      : const Color(0xFF166534),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '작성자: $userId  |  신고 수: $reportCount  |  작성일: $createdText',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6B7280),
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (photoUrl.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              height: 160,
                              width: double.infinity,
                              child: AppNetworkImage(
                                imageUrl: photoUrl,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        if (photoUrl.isNotEmpty) const SizedBox(height: 8),
                        Text(
                          comment.isEmpty ? '(텍스트 없음)' : comment,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _toggleHidden(review),
                                icon: Icon(
                                  isHidden
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 18,
                                ),
                                label: Text(isHidden ? '숨김 해제' : '숨기기'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFEF4444),
                                ),
                                onPressed: () => _deleteReview(review),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                                label: const Text('삭제'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}
