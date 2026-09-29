import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReportService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// 신고 생성 (리뷰 / 댓글 / 레시피 / 레시피 URL / 모임 / 챌린지).
  ///
  /// - `type='review' | 'comment'`: 기존 흐름. `targetId` 필수.
  /// - `type='recipe'`: 레시피 카드 제외 요청. `targetId=recipeId` 필수,
  ///   `targetUrl` 은 admin 행 렌더링 보조용으로 옵션.
  /// - `type='recipe_url'`: 설정 > 약관 및 정책 > 제외 요청 폼. `targetUrl`
  ///   필수(URL 자체가 식별자), `targetId` 는 빈 문자열 허용. `reporterEmail`
  ///   은 admin 회신용으로 옵션.
  Future<String> createReport({
    required String type,
    required String targetId,
    required String reason,
    String? description,
    String? reviewId,
    String? targetUrl,
    String? reporterEmail,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    const allowedTypes = {
      'review',
      'comment',
      'recipe',
      'recipe_url',
      'meetup',
      'challenge',
    };
    if (!allowedTypes.contains(type)) {
      throw Exception('잘못된 신고 타입입니다');
    }
    if (type == 'comment' && (reviewId == null || reviewId.trim().isEmpty)) {
      throw Exception('댓글 신고에는 reviewId가 필요합니다');
    }
    if (type == 'recipe_url') {
      final url = targetUrl?.trim() ?? '';
      if (url.isEmpty) {
        throw Exception('URL이 필요합니다');
      }
    } else {
      if (targetId.trim().isEmpty) {
        throw Exception('targetId가 필요합니다');
      }
    }

    // 중복 신고 확인 (recipe_url은 URL 기반 dedup)
    final dedupKey = type == 'recipe_url'
        ? (targetUrl?.trim() ?? '')
        : targetId;
    final hasReported = await hasUserReported(
      type: type,
      targetId: dedupKey,
      userId: user.uid,
    );

    if (hasReported) {
      throw Exception('이미 신고한 항목입니다');
    }

    try {
      // 신고 문서 생성
      final reportData = <String, dynamic>{
        'type': type,
        'targetId': type == 'recipe_url'
            ? (targetUrl?.trim() ?? '')
            : targetId,
        'reviewId': (reviewId?.trim().isNotEmpty == true)
            ? reviewId!.trim()
            : (type == 'review' ? targetId : null),
        'reporterId': user.uid,
        'reason': reason,
        'description': description,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (targetUrl != null && targetUrl.trim().isNotEmpty) {
        reportData['targetUrl'] = targetUrl.trim();
      }
      if (reporterEmail != null && reporterEmail.trim().isNotEmpty) {
        reportData['reporterEmail'] = reporterEmail.trim();
      }

      final docRef = await _firestore.collection('reports').add(reportData);

      // 신고 통계 업데이트 (review/comment 만 — recipe/recipe_url 은 admin
      // 큐 단순 표시용이라 reportCount 비표시)
      if (type == 'review' || type == 'comment') {
        await _updateReportStats(type, targetId);
      }

      // 자동 조치 확인 (신고 횟수 기반)
      await _checkAutoAction(type, targetId);

      print('[ReportService] Report created: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('[ReportService] Error creating report: $e');
      rethrow;
    }
  }

  /// 사용자가 이미 신고했는지 확인
  Future<bool> hasUserReported({
    required String type,
    required String targetId,
    required String userId,
  }) async {
    try {
      final querySnapshot = await _firestore
          .collection('reports')
          .where('type', isEqualTo: type)
          .where('targetId', isEqualTo: targetId)
          .where('reporterId', isEqualTo: userId)
          .limit(1)
          .get();

      return querySnapshot.docs.isNotEmpty;
    } catch (e) {
      print('[ReportService] Error checking if user reported: $e');
      return false;
    }
  }

  /// 신고 통계 업데이트 (targetId별 신고 횟수)
  Future<void> _updateReportStats(String type, String targetId) async {
    try {
      // 해당 타겟의 신고 횟수 조회
      final reportsSnapshot = await _firestore
          .collection('reports')
          .where('type', isEqualTo: type)
          .where('targetId', isEqualTo: targetId)
          .where('status', isEqualTo: 'pending')
          .get();

      final reportCount = reportsSnapshot.docs.length;

      // 리뷰 또는 댓글 문서에 reportCount 업데이트
      if (type == 'review') {
        await _firestore.collection('reviews').doc(targetId).update({
          'reportCount': reportCount,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else if (type == 'comment') {
        // 댓글의 경우 reviewId를 통해 접근
        final reportDoc = reportsSnapshot.docs.first;
        final reviewId = reportDoc.data()['reviewId'] as String?;
        if (reviewId != null) {
          await _firestore
              .collection('reviews')
              .doc(reviewId)
              .collection('comments')
              .doc(targetId)
              .update({
            'reportCount': reportCount,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (e) {
      print('[ReportService] Error updating report stats: $e');
      // 통계 업데이트 실패해도 신고는 성공으로 처리
    }
  }

  /// 자동 조치 훅 (예: 신고 누적 시 자동 숨김)
  ///
  /// Firestore 규칙상 `isHidden` 등은 **관리자만** 갱신 가능하므로 클라이언트 자동 숨김은 제거됨.
  /// 동일 동작이 필요하면 Cloud Functions(Admin SDK)에서 `reports` 변화를 구독해 처리하세요.
  Future<void> _checkAutoAction(String type, String targetId) async {}

  /// 관리자용: 신고 목록 조회 (Stream)
  Stream<List<Map<String, dynamic>>> getReports({
    String? status, // 'pending', 'reviewed', 'resolved', 'dismissed'
    String? type, // 'review', 'comment'
    int? limit,
  }) {
    Query query = _firestore.collection('reports');

    if (status != null) {
      query = query.where('status', isEqualTo: status);
    }

    return query.snapshots().map((snapshot) {
      final reports = snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>?;
        final convertedData = Map<String, dynamic>.from(data ?? {});
        return {
          'id': doc.id,
          ...convertedData,
        };
      }).toList();

      // Avoid composite index requirement by sorting/filtering client-side.
      final filtered = type == null
          ? reports
          : reports.where((r) => r['type'] == type).toList();

      filtered.sort((a, b) {
        final aTs = a['createdAt'] as Timestamp?;
        final bTs = b['createdAt'] as Timestamp?;
        final aMs = aTs?.millisecondsSinceEpoch ?? 0;
        final bMs = bTs?.millisecondsSinceEpoch ?? 0;
        return bMs.compareTo(aMs);
      });

      if (limit != null && filtered.length > limit) {
        return filtered.take(limit).toList();
      }
      return filtered;
    });
  }

  /// 관리자용: 신고 상태 업데이트
  Future<void> updateReportStatus({
    required String reportId,
    required String status, // 'reviewed', 'resolved', 'dismissed'
    String? reviewedBy,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    if (!['reviewed', 'resolved', 'dismissed'].contains(status)) {
      throw Exception('잘못된 상태입니다');
    }

    try {
      final updateData = {
        'status': status,
        'reviewedBy': reviewedBy ?? user.uid,
        'reviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await _firestore.collection('reports').doc(reportId).update(updateData);
      print('[ReportService] Report status updated: $reportId -> $status');
    } catch (e) {
      print('[ReportService] Error updating report status: $e');
      rethrow;
    }
  }

  /// 관리자용: 신고 통계 조회
  Future<Map<String, dynamic>> getReportStats() async {
    try {
      final pendingReports = await _firestore
          .collection('reports')
          .where('status', isEqualTo: 'pending')
          .get();

      final resolvedReports = await _firestore
          .collection('reports')
          .where('status', isEqualTo: 'resolved')
          .get();

      final dismissedReports = await _firestore
          .collection('reports')
          .where('status', isEqualTo: 'dismissed')
          .get();

      final reviewReports = await _firestore
          .collection('reports')
          .where('type', isEqualTo: 'review')
          .get();

      final commentReports = await _firestore
          .collection('reports')
          .where('type', isEqualTo: 'comment')
          .get();

      return {
        'total': pendingReports.docs.length +
            resolvedReports.docs.length +
            dismissedReports.docs.length,
        'pending': pendingReports.docs.length,
        'resolved': resolvedReports.docs.length,
        'dismissed': dismissedReports.docs.length,
        'reviewReports': reviewReports.docs.length,
        'commentReports': commentReports.docs.length,
      };
    } catch (e) {
      print('[ReportService] Error getting report stats: $e');
      return {
        'total': 0,
        'pending': 0,
        'resolved': 0,
        'dismissed': 0,
        'reviewReports': 0,
        'commentReports': 0,
      };
    }
  }

  /// 관리자용: 신고 삭제
  Future<void> deleteReport(String reportId) async {
    try {
      await _firestore.collection('reports').doc(reportId).delete();
      print('[ReportService] Report deleted: $reportId');
    } catch (e) {
      print('[ReportService] Error deleting report: $e');
      rethrow;
    }
  }

  /// 특정 타겟의 신고 횟수 조회
  Future<int> getReportCount({
    required String type,
    required String targetId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('reports')
          .where('type', isEqualTo: type)
          .where('targetId', isEqualTo: targetId)
          .where('status', isEqualTo: 'pending')
          .get();

      return snapshot.docs.length;
    } catch (e) {
      print('[ReportService] Error getting report count: $e');
      return 0;
    }
  }
}

