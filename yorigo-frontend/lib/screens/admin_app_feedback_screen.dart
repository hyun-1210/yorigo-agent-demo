import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_refresh_indicator.dart';

/// 관리자용 인앱 피드백(`app_feedback`) 목록.
class AdminAppFeedbackScreen extends StatefulWidget {
  const AdminAppFeedbackScreen({super.key});

  @override
  State<AdminAppFeedbackScreen> createState() => _AdminAppFeedbackScreenState();
}

class _AdminAppFeedbackScreenState extends State<AdminAppFeedbackScreen> {
  late final Future<bool> _adminFuture = AdminService.instance.isAdmin();

  Future<void> _refreshQuery(Query<Map<String, dynamic>> query) async {
    await query.get(const GetOptions(source: Source.server));
  }

  String _formatDate(Timestamp? ts) {
    if (ts == null) return '-';
    final date = ts.toDate();
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inHours < 1) return '${diff.inMinutes}분 전';
    if (diff.inDays < 1) return '${diff.inHours}시간 전';
    if (diff.inDays < 7) return '${diff.inDays}일 전';
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  Widget _emptyList(String message) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Center(
          child: Text(
            message,
            style: TextStyle(
              color: AppColors.getTextSecondary(Theme.of(context).brightness),
            ),
          ),
        ),
      ],
    );
  }

  Widget _metaRow(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label: $value',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _buildFeedbackList(Brightness brightness) {
    final query = FirebaseFirestore.instance
        .collection('app_feedback')
        .orderBy('createdAt', descending: true)
        .limit(100);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('오류: ${snap.error}'));
        }

        final docs = snap.data?.docs ?? [];

        return AppRefreshIndicator(
          onRefresh: () => _refreshQuery(query),
          child: docs.isEmpty
              ? _emptyList('앱 피드백이 없습니다.')
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data();
                    final categories =
                        (data['categories'] as List?)?.cast<String>() ?? [];
                    final detail = data['detail'] as String? ?? '';
                    final liked = data['liked'] as String? ?? '';
                    final disliked = data['disliked'] as String? ?? '';
                    final platform = data['platform'] as String? ?? '';
                    final userId = data['userId'] as String? ?? '';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      color: AppColors.getBackgroundSecondary(brightness),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: categories
                                        .map(
                                          (c) => Chip(
                                            label: Text(
                                              c,
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                            visualDensity: VisualDensity.compact,
                                            materialTapTargetSize:
                                                MaterialTapTargetSize.shrinkWrap,
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ),
                                Text(
                                  _formatDate(data['createdAt'] as Timestamp?),
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            if (detail.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(detail),
                            ],
                            if (liked.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                '👍 $liked',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            if (disliked.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                '👎 $disliked',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            const SizedBox(height: 6),
                            _metaRow('플랫폼', platform),
                            _metaRow('UID', userId),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return FutureBuilder<bool>(
      future: _adminFuture,
      builder: (context, adminSnap) {
        if (adminSnap.connectionState != ConnectionState.done) {
          return Scaffold(
            backgroundColor: AppColors.getBackground(brightness),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (adminSnap.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('권한 없음')),
            body: const Center(child: Text('관리자 권한이 필요합니다.')),
          );
        }

        return Scaffold(
          backgroundColor: AppColors.getBackground(brightness),
          appBar: AppBar(
            title: const Text('앱 피드백'),
            backgroundColor: AppColors.getBackground(brightness),
            foregroundColor: AppColors.getTextPrimary(brightness),
            elevation: 0,
          ),
          body: _buildFeedbackList(brightness),
        );
      },
    );
  }
}
