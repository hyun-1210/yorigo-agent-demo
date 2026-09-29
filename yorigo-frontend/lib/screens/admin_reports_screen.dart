import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../services/report_service.dart';
import '../services/user_service.dart';
import '../services/review_service.dart';
import '../services/recipe_service.dart';
import '../services/admin_service.dart';
import '../navigation/community_review_navigation.dart';
import '../widgets/app_prompt_dialog.dart';
import 'recipe_detail_screen.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  final ReportService _reportService = ReportService();
  final UserService _userService = UserService();
  final ReviewService _reviewService = ReviewService();
  final RecipeService _recipeService = RecipeService();

  String _selectedStatus = 'pending'; // 'pending', 'reviewed', 'resolved', 'dismissed'
  String? _selectedType; // 'review' | 'comment' | 'recipe' | 'recipe_url' | null (all)
  final Map<String, Map<String, dynamic>> _userDataCache = {};
  Map<String, dynamic>? _stats;

  // `FutureBuilder`가 setState마다 새 Future를 만들지 않도록 1회만 생성.
  // 이걸로 필터 변경/스탯 새로고침/유저 캐시 setState 때 발생하던 스피너
  // 깜박임을 차단한다.
  late final Future<bool> _adminFuture = AdminService.instance.isAdmin();

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await _reportService.getReportStats();
    if (mounted) {
      setState(() {
        _stats = stats;
      });
    }
  }

  Future<void> _loadUserData(String userId) async {
    if (_userDataCache.containsKey(userId)) return;

    try {
      final userDoc = await _userService.getUserDocument(userId);
      final userData = userDoc.data() as Map<String, dynamic>?;
      if (mounted) {
        setState(() {
          _userDataCache[userId] = userData ?? {};
        });
      }
    } catch (e) {
      print('[AdminReportsScreen] Error loading user data: $e');
    }
  }

  Future<void> _updateReportStatus(String reportId, String status) async {
    try {
      await _reportService.updateReportStatus(
        reportId: reportId,
        status: status,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('신고 상태가 업데이트되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
        _loadStats(); // 통계 새로고침
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('상태 업데이트 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<String?> _promptHiddenReason({
    required String initialValue,
    required bool isHide,
  }) {
    return AppPromptDialog.show(
      context: context,
      title: isHide ? '숨김 사유를 입력해주세요' : '복구 사유를 입력해주세요',
      hintText: '사유를 입력해주세요',
      initialValue: initialValue,
    );
  }

  Future<void> _applyHiddenToReport({
    required String type,
    required String targetId,
    required String? parentReviewId,
    required bool hidden,
    required String reportReason,
  }) async {
    final reason = await _promptHiddenReason(
      initialValue: reportReason,
      isHide: hidden,
    );
    if (reason == null || reason.isEmpty) return;

    if (type == 'review') {
      await _reviewService.setReviewHidden(
        reviewId: targetId,
        hidden: hidden,
        reason: reason,
      );
      return;
    }

    if (type == 'comment') {
      if (parentReviewId == null || parentReviewId.isEmpty) {
        throw Exception('댓글 숨김/복구를 위한 parentReviewId가 없습니다.');
      }
      await _reviewService.setCommentHidden(
        reviewId: parentReviewId,
        commentId: targetId,
        hidden: hidden,
        reason: reason,
      );
      return;
    }

    if (type == 'recipe') {
      await _recipeService.setRecipeHidden(
        recipeId: targetId,
        hidden: hidden,
        reason: reason,
      );
      return;
    }

    if (type == 'recipe_url') {
      // URL 기반 신고는 자동 매칭 X — admin이 별도로 카드 검색 후 처리.
      throw Exception('URL 신고는 카드 검색 후 직접 숨김 처리해 주세요.');
    }

    throw Exception('알 수 없는 신고 타입입니다: $type');
  }

  Future<void> _deleteTargetFromReport({
    required String type,
    required String targetId,
    required String? parentReviewId,
  }) async {
    if (type == 'review') {
      await _reviewService.deleteReview(targetId, allowAdminOverride: true);
      return;
    }
    if (type == 'comment') {
      if (parentReviewId == null || parentReviewId.isEmpty) {
        throw Exception('댓글 삭제를 위한 parentReviewId가 없습니다.');
      }
      await _reviewService.deleteComment(
        reviewId: parentReviewId,
        commentId: targetId,
        allowAdminOverride: true,
      );
      return;
    }
    if (type == 'recipe' || type == 'recipe_url') {
      throw Exception('레시피는 "삭제" 대신 "숨김" 으로 처리해 주세요.');
    }
    throw Exception('알 수 없는 신고 타입입니다: $type');
  }

  Future<void> _openReportedReviewInFeed({
    required String type,
    required String targetId,
    required String? parentReviewId,
    String? targetUrl,
  }) async {
    if (type == 'recipe') {
      if (targetId.isEmpty) {
        throw Exception('레시피 ID를 찾을 수 없습니다.');
      }
      final loaded = await _recipeService.getRecipeById(targetId);
      if (loaded == null) {
        throw Exception('레시피를 불러올 수 없습니다.');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RecipeDetailScreen(
            parseResponse: loaded,
            recipeId: targetId,
          ),
        ),
      );
      return;
    }

    if (type == 'recipe_url') {
      final url = targetUrl?.trim() ?? '';
      if (url.isEmpty) {
        throw Exception('URL 정보가 없습니다.');
      }
      final uri = Uri.tryParse(url);
      if (uri == null) {
        throw Exception('잘못된 URL 입니다.');
      }
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
      throw Exception('URL을 열 수 없습니다.');
    }

    final reviewId = type == 'review' ? targetId : (parentReviewId ?? '');
    if (reviewId.isEmpty) {
      throw Exception('리뷰 ID를 찾을 수 없습니다.');
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestOpenReviewInFeed(reviewId);
    });
  }

  String _getStatusLabel(String status) {
    switch (status) {
      case 'pending':
        return '대기 중';
      case 'reviewed':
        return '검토 완료';
      case 'resolved':
        return '해결됨';
      case 'dismissed':
        return '기각됨';
      default:
        return status;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.orange;
      case 'reviewed':
        return Colors.blue;
      case 'resolved':
        return Colors.green;
      case 'dismissed':
        return Colors.grey;
      default:
        return Colors.black;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'review':
        return '리뷰';
      case 'comment':
        return '댓글';
      case 'recipe':
        return '레시피';
      case 'recipe_url':
        return 'URL 신고';
      case 'meetup':
        return '모임';
      case 'challenge':
        return '챌린지';
      default:
        return type;
    }
  }

  String _getReasonLabel(String reason) {
    switch (reason) {
      case 'spam':
        return '스팸/광고';
      case 'abuse':
        return '욕설/비방';
      case 'inappropriate':
        return '음란물';
      case 'copyright':
        return '저작권 침해';
      case 'unrelated':
        return '관련없는 콘텐츠';
      case 'owner_self':
        return '본인 게시글입니다';
      case 'misinformation':
        return 'AI 또는 거짓 정보';
      case 'dislike':
        return '마음에 들지 않음';
      case 'other':
        return '기타';
      default:
        return reason;
    }
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
        title: const Text('신고 관리'),
        backgroundColor: AppColors.getBackground(brightness),
        foregroundColor: AppColors.getTextPrimary(brightness),
        elevation: 0,
      ),
      body: Column(
        children: [
          // 통계 카드
          if (_stats != null)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.getBackgroundSecondary(brightness),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.getBorder(brightness),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem('전체', _stats!['total'] ?? 0, Colors.blue),
                  _buildStatItem('대기 중', _stats!['pending'] ?? 0, Colors.orange),
                  _buildStatItem('해결됨', _stats!['resolved'] ?? 0, Colors.green),
                  _buildStatItem('기각됨', _stats!['dismissed'] ?? 0, Colors.grey),
                ],
              ),
            ),

          // 필터
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    value: _selectedStatus,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'pending', child: Text('대기 중')),
                      DropdownMenuItem(value: 'reviewed', child: Text('검토 완료')),
                      DropdownMenuItem(value: 'resolved', child: Text('해결됨')),
                      DropdownMenuItem(value: 'dismissed', child: Text('기각됨')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedStatus = value;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String?>(
                    value: _selectedType,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: null, child: Text('전체')),
                      DropdownMenuItem(value: 'review', child: Text('리뷰')),
                      DropdownMenuItem(value: 'comment', child: Text('댓글')),
                      DropdownMenuItem(value: 'recipe', child: Text('레시피')),
                      DropdownMenuItem(
                        value: 'recipe_url',
                        child: Text('URL 신고'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedType = value;
                      });
                    },
                  ),
                ),
              ],
            ),
          ),

          // 신고 목록
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _reportService.getReports(
                status: _selectedStatus,
                type: _selectedType,
                limit: 100,
              ),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      '오류가 발생했습니다: ${snapshot.error}',
                      style: TextStyle(
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                  );
                }

                final reports = snapshot.data ?? [];

                if (reports.isEmpty) {
                  return Center(
                    child: Text(
                      '신고가 없습니다',
                      style: TextStyle(
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                  );
                }

                // Load user data for all reports
                for (var report in reports) {
                  final reporterId = report['reporterId'] as String?;
                  if (reporterId != null) {
                    _loadUserData(reporterId);
                  }
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: reports.length,
                  itemBuilder: (context, index) {
                    final report = reports[index];
                    final reportId = report['id'] as String? ?? '';
                    final type = report['type'] as String? ?? '';
                    final targetId = report['targetId'] as String? ?? '';
                    final parentReviewId = report['reviewId'] as String?;
                    final reporterId = report['reporterId'] as String? ?? '';
                    final reason = report['reason'] as String? ?? '';
                    final description = report['description'] as String?;
                    final status = report['status'] as String? ?? 'pending';
                    final createdAt = (report['createdAt'] as Timestamp?)?.toDate();
                    final targetUrl = report['targetUrl'] as String?;
                    final reporterEmail = report['reporterEmail'] as String?;
                    final isRecipeType = type == 'recipe' || type == 'recipe_url';

                    final reporterData = _userDataCache[reporterId] ?? {};
                    final reporterName = reporterData['name'] as String? ?? '사용자';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      color: AppColors.getBackgroundSecondary(brightness),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 헤더
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _getStatusColor(status).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _getStatusLabel(status),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _getStatusColor(status),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _typeLabel(type),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                if (createdAt != null)
                                  Text(
                                    _formatDate(createdAt),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.getTextSecondary(brightness),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            
                            // 신고 정보
                            Text(
                              '신고자: $reporterName',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.getTextPrimary(brightness),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '신고 사유: ${_getReasonLabel(reason)}',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.getTextPrimary(brightness),
                              ),
                            ),
                            if (description != null && description.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '추가 설명: $description',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.getTextSecondary(brightness),
                                ),
                              ),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              '대상 ID: $targetId',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.getTextTertiary(brightness),
                              ),
                            ),
                            if (targetUrl != null && targetUrl.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              SelectableText(
                                'URL: $targetUrl',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.getTextSecondary(brightness),
                                ),
                              ),
                            ],
                            if (reporterEmail != null &&
                                reporterEmail.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              SelectableText(
                                '이메일: $reporterEmail',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.getTextSecondary(brightness),
                                ),
                              ),
                            ],

                            // 액션 버튼
                            if (status != 'dismissed') ...[
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        await _openReportedReviewInFeed(
                                          type: type,
                                          targetId: targetId,
                                          parentReviewId: parentReviewId,
                                          targetUrl: targetUrl,
                                        );
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('원본 이동 실패: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: const Text(
                                      '원본 보기',
                                      style: TextStyle(color: Colors.indigo),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        await _applyHiddenToReport(
                                          type: type,
                                          targetId: targetId,
                                          parentReviewId: parentReviewId,
                                          hidden: true,
                                          reportReason: reason,
                                        );
                                        await _updateReportStatus(reportId, 'resolved');
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('숨김 처리 실패: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: const Text(
                                      '숨김',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        await _applyHiddenToReport(
                                          type: type,
                                          targetId: targetId,
                                          parentReviewId: parentReviewId,
                                          hidden: false,
                                          reportReason: reason,
                                        );
                                        await _updateReportStatus(reportId, 'resolved');
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('복구 처리 실패: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: const Text(
                                      '복구',
                                      style: TextStyle(color: Colors.blue),
                                    ),
                                  ),
                                  if (!isRecipeType)
                                    TextButton(
                                      onPressed: () async {
                                        try {
                                          await _deleteTargetFromReport(
                                            type: type,
                                            targetId: targetId,
                                            parentReviewId: parentReviewId,
                                          );
                                          await _updateReportStatus(reportId, 'resolved');
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('대상 삭제 처리 완료'),
                                                backgroundColor: Colors.green,
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('삭제 처리 실패: $e'),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      child: const Text(
                                        '삭제',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                ],
                              ),
                              if (status == 'pending') ...[
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () => _updateReportStatus(reportId, 'dismissed'),
                                      child: const Text(
                                        '기각',
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed: () => _updateReportStatus(reportId, 'reviewed'),
                                      child: const Text('검토 완료'),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                      onPressed: () => _updateReportStatus(reportId, 'resolved'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: const Text('해결됨'),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
      },
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inMinutes < 1) {
      return '방금 전';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}분 전';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}시간 전';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}일 전';
    } else {
      return '${date.month}/${date.day}';
    }
  }
}

