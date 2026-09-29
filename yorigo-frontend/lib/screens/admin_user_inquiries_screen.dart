import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../widgets/app_refresh_indicator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/admin_service.dart';
import '../services/recipe_service.dart';
import '../theme/app_colors.dart';
import 'recipe_detail_screen.dart';

class AdminUserInquiriesScreen extends StatefulWidget {
  const AdminUserInquiriesScreen({super.key});

  @override
  State<AdminUserInquiriesScreen> createState() =>
      _AdminUserInquiriesScreenState();
}

class _AdminUserInquiriesScreenState extends State<AdminUserInquiriesScreen>
    with SingleTickerProviderStateMixin {
  final RecipeService _recipeService = RecipeService();
  late final TabController _tabController;
  late final Future<bool> _adminFuture = AdminService.instance.isAdmin();

  /// parsing_failures / fridge_scan_reports 탭: open만 / 전체
  bool _parsingOpenOnly = true;
  bool _fridgeScanOpenOnly = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refreshQuery(Query<Map<String, dynamic>> query) async {
    await query.get(const GetOptions(source: Source.server));
  }

  Future<void> _openRecipe(String recipeId) async {
    if (recipeId.trim().isEmpty) return;
    final loaded = await _recipeService.getRecipeById(recipeId.trim());
    if (!mounted) return;
    if (loaded == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('레시피를 불러올 수 없습니다.')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecipeDetailScreen(
          parseResponse: loaded,
          recipeId: recipeId.trim(),
        ),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('잘못된 URL 입니다.')),
        );
      }
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL을 열 수 없습니다.')),
      );
    }
  }

  Future<void> _resolveParsingFailure(String docId) async {
    try {
      await FirebaseFirestore.instance
          .collection('parsing_failures')
          .doc(docId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('처리 완료로 표시했습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('처리 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
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

  String _parsingReasonLabel(String reason) {
    switch (reason) {
      case 'failed':
        return '분석 실패';
      case 'stuck':
        return '오래 걸림';
      case 'wrong_result':
        return '결과 이상';
      default:
        return reason;
    }
  }

  String _fridgeScanReasonLabel(String reason) {
    switch (reason) {
      case 'wrong_name':
        return '이름 오류';
      case 'missing_item':
        return '재료 누락';
      case 'blocked_item':
        return 'DB 미매칭(추천 제외)';
      case 'junk_item':
        return '이상한 항목';
      case 'other':
        return '기타';
      default:
        return reason;
    }
  }

  Future<void> _resolveFridgeScanReport(String docId) async {
    try {
      await FirebaseFirestore.instance
          .collection('fridge_scan_reports')
          .doc(docId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('처리 완료로 표시했습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('처리 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
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

  Widget _buildParsingFailuresTab(Brightness brightness) {
    final query = FirebaseFirestore.instance
        .collection('parsing_failures')
        .orderBy('createdAt', descending: true)
        .limit(100);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              FilterChip(
                label: const Text('미처리만'),
                selected: _parsingOpenOnly,
                onSelected: (v) => setState(() => _parsingOpenOnly = v),
              ),
              const SizedBox(width: 8),
              Text(
                '최근 100건',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: query.snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('오류: ${snap.error}'));
              }

              var docs = snap.data?.docs ?? [];
              if (_parsingOpenOnly) {
                docs = docs
                    .where((d) => (d.data()['status'] as String? ?? 'open') == 'open')
                    .toList();
              }

              return AppRefreshIndicator(
                onRefresh: () => _refreshQuery(query),
                child: docs.isEmpty
                    ? _emptyList('파싱 실패 신고가 없습니다.')
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final data = doc.data();
                          final status = data['status'] as String? ?? 'open';
                          final reason = data['reason'] as String? ?? '';
                          final sourceUrl = data['sourceUrl'] as String? ?? '';
                          final recipeId = data['recipeId'] as String? ?? '';
                          final errorMessage =
                              data['errorMessage'] as String? ?? '';
                          final errorType = data['errorType'] as String? ?? '';
                          final platform = data['platform'] as String? ?? '';
                          final note = data['note'] as String? ?? '';
                          final userEmail = data['userEmail'] as String? ?? '';
                          final userId = data['userId'] as String? ?? '';
                          final isResolved = status == 'resolved';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            color: AppColors.getBackgroundSecondary(brightness),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      _statusChip(
                                        isResolved ? '처리됨' : '미처리',
                                        isResolved ? Colors.green : Colors.orange,
                                      ),
                                      const SizedBox(width: 8),
                                      _statusChip(
                                        _parsingReasonLabel(reason),
                                        Colors.blue,
                                      ),
                                      const Spacer(),
                                      Text(
                                        _formatDate(
                                          data['createdAt'] as Timestamp?,
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (errorMessage.isNotEmpty)
                                    Text(
                                      errorMessage,
                                      style: const TextStyle(color: Colors.red),
                                    ),
                                  const SizedBox(height: 6),
                                  _metaRow('플랫폼', platform),
                                  _metaRow('에러 유형', errorType),
                                  _metaRow('이메일', userEmail),
                                  _metaRow('UID', userId),
                                  if (note.isNotEmpty) _metaRow('메모', note),
                                  if (sourceUrl.isNotEmpty)
                                    InkWell(
                                      onTap: () => _openUrl(sourceUrl),
                                      child: Text(
                                        sourceUrl,
                                        style: const TextStyle(
                                          color: Colors.blue,
                                          decoration: TextDecoration.underline,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (recipeId.isNotEmpty)
                                        TextButton(
                                          onPressed: () => _openRecipe(recipeId),
                                          child: const Text('레시피 보기'),
                                        ),
                                      if (!isResolved)
                                        TextButton(
                                          onPressed: () =>
                                              _resolveParsingFailure(doc.id),
                                          child: const Text('처리 완료'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFridgeScanReportsTab(Brightness brightness) {
    final query = FirebaseFirestore.instance
        .collection('fridge_scan_reports')
        .orderBy('createdAt', descending: true)
        .limit(100);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              FilterChip(
                label: const Text('미처리만'),
                selected: _fridgeScanOpenOnly,
                onSelected: (v) => setState(() => _fridgeScanOpenOnly = v),
              ),
              const SizedBox(width: 8),
              Text(
                '최근 100건',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: query.snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('오류: ${snap.error}'));
              }

              var docs = snap.data?.docs ?? [];
              if (_fridgeScanOpenOnly) {
                docs = docs
                    .where(
                      (d) =>
                          (d.data()['status'] as String? ?? 'open') == 'open',
                    )
                    .toList();
              }

              return AppRefreshIndicator(
                onRefresh: () => _refreshQuery(query),
                child: docs.isEmpty
                    ? _emptyList('영수증 인식 신고가 없습니다.')
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final data = doc.data();
                          final status = data['status'] as String? ?? 'open';
                          final reason = data['reason'] as String? ?? '';
                          final note = data['note'] as String? ?? '';
                          final focusName =
                              data['focusItemName'] as String? ?? '';
                          final focusRaw =
                              data['focusRawLine'] as String? ?? '';
                          final itemsJson = data['itemsJson'] as String? ?? '';
                          final userEmail = data['userEmail'] as String? ?? '';
                          final userId = data['userId'] as String? ?? '';
                          final isResolved = status == 'resolved';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            color:
                                AppColors.getBackgroundSecondary(brightness),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      _statusChip(
                                        isResolved ? '처리됨' : '미처리',
                                        isResolved
                                            ? Colors.green
                                            : Colors.orange,
                                      ),
                                      const SizedBox(width: 8),
                                      _statusChip(
                                        _fridgeScanReasonLabel(reason),
                                        Colors.blue,
                                      ),
                                      const Spacer(),
                                      Text(
                                        _formatDate(
                                          data['createdAt'] as Timestamp?,
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (note.isNotEmpty) Text(note),
                                  const SizedBox(height: 6),
                                  _metaRow('포커스 이름', focusName),
                                  _metaRow('포커스 원문', focusRaw),
                                  _metaRow('이메일', userEmail),
                                  _metaRow('UID', userId),
                                  if (itemsJson.isNotEmpty)
                                    _metaRow(
                                      '인식 스냅샷',
                                      itemsJson.length > 180
                                          ? '${itemsJson.substring(0, 180)}…'
                                          : itemsJson,
                                    ),
                                  if (!isResolved)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed: () =>
                                            _resolveFridgeScanReport(doc.id),
                                        child: const Text('처리 완료'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRecipeReportsTab(Brightness brightness) {
    final query = FirebaseFirestore.instance
        .collection('recipe_reports')
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
              ? _emptyList('레시피 문제 보고가 없습니다.')
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data();
                    final recipeId = data['recipeId'] as String? ?? '';
                    final recipeTitle = data['recipeTitle'] as String? ?? '';
                    final message = data['message'] as String? ?? '';
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
                              children: [
                                Expanded(
                                  child: Text(
                                    recipeTitle.isNotEmpty
                                        ? recipeTitle
                                        : '레시피',
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  _formatDate(data['createdAt'] as Timestamp?),
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(message),
                            const SizedBox(height: 6),
                            _metaRow('UID', userId),
                            _metaRow('레시피 ID', recipeId),
                            if (recipeId.isNotEmpty)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => _openRecipe(recipeId),
                                  child: const Text('레시피 보기'),
                                ),
                              ),
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

  Widget _statusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
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
            title: const Text('사용자 문의'),
            backgroundColor: AppColors.getBackground(brightness),
            foregroundColor: AppColors.getTextPrimary(brightness),
            elevation: 0,
            bottom: TabBar(
              controller: _tabController,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.getTextSecondary(brightness),
              indicatorColor: AppColors.primary,
              tabs: const [
                Tab(text: '파싱 실패'),
                Tab(text: '레시피 문제'),
                Tab(text: '영수증 인식'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildParsingFailuresTab(brightness),
              _buildRecipeReportsTab(brightness),
              _buildFridgeScanReportsTab(brightness),
            ],
          ),
        );
      },
    );
  }
}
