import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';
import '../utils/reward_claim_gate.dart';
import '../utils/yorigo_level.dart';
import '../widgets/app_toast.dart';
import '../widgets/xp_gain_overlay.dart';

/// EXP/포인트 리워드 시스템 클라이언트.
///
/// - EXP: 앱 사용 전반(넓고 얕게) - 레벨/뱃지 표시용, 소비처 없음.
/// - Points: BM/플랫폼 기여 행동(좁고 엄격) - 적립/랭킹용, 소비처는 추후 별도 설계.
///
/// 지급(claim/claimAttendance)은 Firebase Cloud Functions(claimReward,
/// claimAttendance)에서만 이뤄진다. 조회는 Firestore 직접 읽기.
/// 구매완료 사진 인증만 Railway 백엔드가 담당한다.
class RewardsService {
  RewardsService._();
  static final RewardsService instance = RewardsService._();

  /// [main.dart]의 appNavigatorKey를 주입해 적립 토스트·+EXP를 띄운다.
  static GlobalKey<NavigatorState>? navigatorKey;

  /// 화면에 반영된 누적 EXP. 지급 팝업과 프로필 게이지가 같이 움직인다.
  final ValueNotifier<int> expTotalListenable = ValueNotifier<int>(0);
  bool _expSeeded = false;
  int _pendingLiveExp = 0;
  final RewardClaimGate _claimGate = RewardClaimGate();

  void seedExpTotal(int value) {
    final next = value + _pendingLiveExp;
    _pendingLiveExp = 0;
    _expSeeded = true;
    if (next > expTotalListenable.value) {
      expTotalListenable.value = next;
    }
  }

  void creditLiveExp(int amount) {
    if (amount <= 0) return;
    if (!_expSeeded) {
      _pendingLiveExp += amount;
      return;
    }
    expTotalListenable.value += amount;
  }

  static const cookingLoggedAction = 'exp_cooking_logged';
  static const cookingLoggedTextAction = 'exp_cooking_logged_text';
  static const cookingLoggedPhotoExp = 50;
  static const cookingLoggedTextExp = 30;

  static String get _baseUrl => EnvironmentConfig.baseUrl;

  static void _debugLog(String message) {
    if (kDebugMode) print(message);
  }

  Future<String?> _idToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      return await user.getIdToken();
    } catch (e) {
      _debugLog('[RewardsService] getIdToken error: $e');
      return null;
    }
  }

  /// Callable 응답은 플랫폼에 따라 Map<Object?, Object?>로 올 수 있어
  /// `call<Map<String, dynamic>>` 캐스트에 의존하면 적립이 전부 실패한다.
  Map<String, dynamic> _asStringKeyedMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'points_attendance':
        return '출석';
      case 'points_streak_7':
        return '연속출석 7일';
      case 'points_streak_14':
        return '연속출석 14일';
      case 'points_streak_30':
        return '연속출석 30일';
      case 'points_cart_add':
        return '장바구니 담기';
      case 'points_purchase_self_report':
        return '구매완료';
      case 'points_purchase_photo_verified':
        return '구매인증';
      case 'points_like':
        return '좋아요';
      case 'points_comment':
        return '댓글';
      case 'points_post_created':
      case 'points_post_created_low_quality':
        return '게시물 작성';
      case 'points_post_popular':
        return '인기글 보너스';
      case 'exp_session_start':
        return '오늘 접속';
      case 'exp_attendance':
        return '오늘 출석';
      case 'exp_streak_3':
        return '3일 연속 출석';
      case 'exp_streak_7':
        return '7일 연속 출석';
      case 'exp_streak_14':
        return '14일 연속 출석';
      case 'exp_streak_30':
        return '30일 연속 출석';
      case 'exp_like':
        return '좋아요';
      case 'exp_comment':
        return '댓글';
      case 'exp_post_created':
      case 'exp_post_created_short':
        return '속닥속닥 작성';
      case 'exp_likes_10':
        return '좋아요 10개';
      case 'exp_likes_30':
        return '좋아요 30개';
      case 'exp_comments_5':
        return '댓글 5개';
      case 'exp_comments_15':
        return '댓글 15개';
      case 'exp_recipe_viewed':
        return '레시피 조회';
      case 'exp_search':
        return '검색';
      case 'exp_fridge_ingredient_added':
        return '냉장고 추가';
      case 'exp_follow':
        return '팔로우';
      case 'exp_recipe_bookmarked':
        return '저장';
      case 'exp_cooking_started':
        return '요리 시작';
      case 'exp_cooking_completed':
        return '요리 완료';
      case 'exp_cooking_logged':
      case 'exp_cooking_logged_text':
        return '요리 기록';
      case 'exp_meal_calendar_used':
        return '식단 캘린더';
      case 'exp_recipe_parsed':
        return '레시피 분석';
      case 'exp_recipe_registered':
        return '레시피 등록';
      case 'exp_profile_completed':
        return '프로필 완성';
      case 'exp_feedback':
        return '의견 보내기';
      case 'exp_recipe_shared':
        return '레시피 공유';
      case 'exp_backfill':
        return '이전 활동 반영';
      default:
        return action.startsWith('points_') ? '포인트' : '경험치';
    }
  }

  /// 조회/검색처럼 초고빈도 EXP만 토스트 생략. 팔로우·접속·저장 등은 표시.
  bool _shouldToastExp(String action) {
    const silent = {
      'exp_recipe_viewed',
      'exp_search',
      'exp_session_start',
    };
    return !silent.contains(action);
  }

  Future<void> _presentExp({
    required String action,
    required int amount,
    int? fromLevel,
    int? toLevel,
  }) async {
    if (amount <= 0 &&
        (fromLevel == null || toLevel == null || toLevel <= fromLevel)) {
      return;
    }
    if (amount > 0 && !_shouldToastExp(action)) return;
    final prevExp = expTotalListenable.value;
    final key = navigatorKey;
    if (key == null) return;
    await XpFeedback.enqueue(
      navigatorKey: key,
      amount: _shouldToastExp(action) ? amount : 0,
      label: _actionLabel(action),
      fromLevel: fromLevel ?? yorigoLevelFromExp(prevExp),
      toLevel: toLevel ?? yorigoLevelFromExp(prevExp),
    );
  }

  void _applyGrantedExp(RewardClaimResult result) {
    if (!result.granted || result.amount <= 0) return;
    if (result.balance > 0) {
      seedExpTotal(result.balance);
      return;
    }
    creditLiveExp(result.amount);
  }

  void _showGrantedToast({
    required String action,
    required String track,
    required int amount,
    int? fromLevel,
    int? toLevel,
  }) {
    if (amount <= 0 &&
        (fromLevel == null || toLevel == null || toLevel <= fromLevel)) {
      return;
    }
    if (track == 'exp') {
      unawaited(_presentExp(
        action: action,
        amount: amount,
        fromLevel: fromLevel,
        toLevel: toLevel,
      ));
      return;
    }
    if (amount <= 0) return;

    final key = navigatorKey;
    if (key == null) return;

    final label = _actionLabel(action);
    final message = '$label  +$amount P';
    const type = AppToastType.success;

    // 앱 콜드스타트 직후(출석/접속 EXP)에는 Navigator Overlay가 아직 없을 수 있어
    // 준비될 때까지 짧게 재시도한다.
    void attempt(int tries) {
      final overlay = key.currentState?.overlay;
      if (overlay == null) {
        if (tries >= 25) {
          _debugLog(
            '[RewardsService] toast skipped (no overlay): $action +$amount',
          );
          return;
        }
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => attempt(tries + 1),
        );
        return;
      }
      AppToast.showOnNavigator(key, message, type: type);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt(0));
  }

  /// 일반 행동 리워드 청구. [action]은 functions/rewards.js REWARD_CATALOG 키.
  Future<RewardClaimResult> claim(
    String action, {
    required String idempotencyKey,
    String? sourceRef,
    bool showToast = true,
    int? levelFrom,
    int? levelTo,
  }) async {
    if (!action.startsWith('exp_')) {
      return RewardClaimResult.notGranted(
        action: action,
        reason: 'temporarily_disabled',
      );
    }
    if (FirebaseAuth.instance.currentUser == null) {
      return RewardClaimResult.notGranted(action: action, reason: 'unauthenticated');
    }
    final skip = _claimGate.skipReason(action, idempotencyKey);
    if (skip != null) {
      return RewardClaimResult.notGranted(action: action, reason: skip);
    }
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('claimReward');
      final result = await callable.call({
        'action': action,
        'idempotencyKey': idempotencyKey,
        if (sourceRef != null) 'sourceRef': sourceRef,
      });
      final data = _asStringKeyedMap(result.data);
      final claimResult = RewardClaimResult.fromCallable(action, data);
      _claimGate.record(
        action: action,
        idempotencyKey: idempotencyKey,
        granted: claimResult.granted,
        reason: claimResult.reason,
      );
      if (claimResult.granted && claimResult.amount > 0) {
        final prevExp = claimResult.balance > claimResult.amount
            ? claimResult.balance - claimResult.amount
            : expTotalListenable.value;
        _applyGrantedExp(claimResult);
        if (showToast) {
          unawaited(_presentExp(
            action: action,
            amount: claimResult.amount,
            fromLevel: levelFrom ?? yorigoLevelFromExp(prevExp),
            toLevel: levelTo ??
                (claimResult.level ?? yorigoLevelFromExp(claimResult.balance)),
          ));
        }
      }
      return claimResult;
    } catch (e) {
      _debugLog('[RewardsService] claim($action) error: $e');
      return RewardClaimResult.notGranted(action: action, reason: 'error');
    }
  }

  /// 요리 기록 경험치. 사진은 50, 글만은 30. 공개/나만보기 동일.
  Future<RewardClaimResult> claimCookingLogged({
    required String reviewId,
    required bool hasPhoto,
  }) async {
    final action =
        hasPhoto ? cookingLoggedAction : cookingLoggedTextAction;
    if (!_expSeeded) {
      await getSummary();
    }
    final fromExp = expTotalListenable.value;
    final result = await claim(
      action,
      idempotencyKey: '$action:$reviewId',
      sourceRef: reviewId,
      showToast: false,
    );
    if (!result.granted || result.amount <= 0) return result;
    final toExp = result.balance > 0
        ? result.balance
        : expTotalListenable.value;
    final key = navigatorKey;
    if (key != null) {
      await XpFeedback.enqueue(
        navigatorKey: key,
        amount: result.amount,
        label: _actionLabel(action),
        fromLevel: yorigoLevelFromExp(fromExp),
        toLevel: yorigoLevelFromExp(toExp),
      );
    }
    return result;
  }

  static const _streakExpByDays = <int, String>{
    3: 'exp_streak_3',
    7: 'exp_streak_7',
    14: 'exp_streak_14',
    30: 'exp_streak_30',
  };

  static final Set<String> _attendanceExpShown = <String>{};

  /// 앱에 들어온 날(KST) 기준 출석 + 3/7/14/30일 연속 보너스.
  /// 같은 날은 호출이 여러 번이어도 한 번만 표시·청구한다.
  Future<void> claimAttendanceExp({
    required int streakDays,
    required String dayKey,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final shownKey = '$uid:$dayKey';
    if (_attendanceExpShown.contains(shownKey)) return;
    final attendance = await claim(
      'exp_attendance',
      idempotencyKey: 'exp_attendance:$uid:$dayKey',
      showToast: false,
    );
    if (attendance.reason == 'error') return;
    _attendanceExpShown.add(shownKey);
    if (attendance.granted && attendance.amount > 0) {
      await _presentExp(
        action: 'exp_attendance',
        amount: attendance.amount,
      );
    }

    final streakAction = _streakExpByDays[streakDays];
    if (streakAction == null) return;
    final streak = await claim(
      streakAction,
      idempotencyKey: '$streakAction:$uid:$dayKey',
      showToast: false,
    );
    if (streak.granted && streak.amount > 0) {
      await _presentExp(
        action: streakAction,
        amount: streak.amount,
      );
    }
  }

  Future<void> claimLikeExp({
    required String contentId,
    String? authorId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || (authorId != null && authorId == uid)) return;
    await claim(
      'exp_like',
      idempotencyKey: 'exp_like:$contentId:$uid',
      sourceRef: contentId,
    );
  }

  Future<void> claimCommentExp({
    required String commentId,
    required String sourceRef,
    required int textLength,
  }) async {
    if (textLength < 5) return;
    await claim(
      'exp_comment',
      idempotencyKey: 'exp_comment:$commentId',
      sourceRef: sourceRef,
    );
  }

  Future<void> claimPostCreatedExp({
    required String postId,
    required int bodyLength,
  }) async {
    final action =
        bodyLength >= 20 ? 'exp_post_created' : 'exp_post_created_short';
    await claim(
      action,
      idempotencyKey: 'exp_post_created:$postId',
      sourceRef: postId,
    );
  }

  /// 내 글이 좋아요/댓글 수 기준에 도달했을 때. 작성자 본인만, 한 줄로 청구.
  Future<void> claimAuthorSocialMilestones({
    required String contentId,
    required String? authorId,
    required int likeCount,
    required int commentCount,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || authorId != uid) return;
    if (likeCount >= 10) {
      await claim(
        'exp_likes_10',
        idempotencyKey: 'exp_likes_10:$contentId',
        sourceRef: contentId,
      );
    }
    if (likeCount >= 30) {
      await claim(
        'exp_likes_30',
        idempotencyKey: 'exp_likes_30:$contentId',
        sourceRef: contentId,
      );
    }
    if (commentCount >= 5) {
      await claim(
        'exp_comments_5',
        idempotencyKey: 'exp_comments_5:$contentId',
        sourceRef: contentId,
      );
    }
    if (commentCount >= 15) {
      await claim(
        'exp_comments_15',
        idempotencyKey: 'exp_comments_15:$contentId',
        sourceRef: contentId,
      );
    }
  }

  /// 일일 출석 + (streakDays가 7/14/30이면) 연속출석 마일스톤 보너스.
  Future<RewardClaimResult> claimAttendance(
    int streakDays, {
    bool showToast = true,
  }) async {
    // [임시 비활성] 출석 포인트 — 복구 시 이 return 과 아래 블록 주석을 해제.
    return RewardClaimResult.notGranted(
      action: 'points_attendance',
      reason: 'temporarily_disabled',
    );
    /*
    if (FirebaseAuth.instance.currentUser == null) {
      return RewardClaimResult.notGranted(
        action: 'points_attendance',
        reason: 'unauthenticated',
      );
    }
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'claimAttendance',
      );
      final result = await callable.call({
        'streakDays': streakDays,
      });
      final data = _asStringKeyedMap(result.data);
      final claimResult = RewardClaimResult.fromCallable(
        'points_attendance',
        data,
      );
      if (showToast && claimResult.granted) {
        _showGrantedToast(
          action: 'points_attendance',
          track: 'points',
          amount: claimResult.amount,
        );
      }
      // 연속출석 보너스는 출석 중복이어도 별도 지급될 수 있어 응답 필드로만 토스트.
      final milestoneGranted = data['milestoneGranted'] == true;
      final milestoneAmount = (data['milestoneAmount'] as num?)?.toInt() ?? 0;
      if (showToast && milestoneGranted && milestoneAmount > 0) {
        final key = navigatorKey;
        if (key != null && key.currentState?.overlay != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            AppToast.showOnNavigator(
              key,
              '연속출석 $streakDays일 보너스  +$milestoneAmount P',
              type: AppToastType.success,
            );
          });
        }
      }
      return claimResult;
    } catch (e) {
      _debugLog('[RewardsService] claimAttendance error: $e');
      return RewardClaimResult.notGranted(
        action: 'points_attendance',
        reason: 'error',
      );
    }
    */
  }

  Future<RewardsSummary?> getSummary() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      if (!snap.exists) return null;
      final summary = RewardsSummary.fromJson(snap.data() ?? const {});
      seedExpTotal(summary.expTotal);
      return summary;
    } catch (e) {
      _debugLog('[RewardsService] getSummary error: $e');
      return null;
    }
  }

  /// 로그인 유저의 포인트/경험치 잔액을 실시간으로 구독한다.
  /// 로그아웃 시 null을 방출한다.
  Stream<RewardsSummary?> watchSummary() async* {
    await for (final user in FirebaseAuth.instance.authStateChanges()) {
      if (user == null) {
        yield null;
        continue;
      }
      yield* FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots()
          .map((snap) {
        if (!snap.exists) {
          return const RewardsSummary(
            expTotal: 0,
            level: 1,
            pointsBalance: 0,
            pointsLifetimeEarned: 0,
          );
        }
        return RewardsSummary.fromJson(snap.data() ?? const {});
      });
    }
  }

  Future<List<RewardLedgerEntry>> getHistory({
    String track = 'points',
    int limit = 50,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const [];
    final collectionName = track == 'exp' ? 'exp_ledger' : 'points_ledger';
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(collectionName)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snap.docs
          .map((doc) => RewardLedgerEntry.fromJson(doc.id, doc.data()))
          .toList();
    } catch (e) {
      _debugLog('[RewardsService] getHistory error: $e');
      return const [];
    }
  }

  Future<PurchaseVerificationResult?> submitPurchaseVerification(
    Uint8List imageBytes,
  ) async {
    // [임시 비활성] 구매인증(포인트) — 복구 시 이 return 과 아래 블록 주석을 해제.
    return null;
    /*
    final token = await _idToken();
    if (token == null || token.isEmpty) return null;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/purchase-verification/submit'),
      )
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            imageBytes,
            filename: 'order_confirmation.jpg',
          ),
        );

      final streamed = await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        _debugLog(
          '[RewardsService] submitPurchaseVerification ${response.statusCode}: ${response.body}',
        );
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return PurchaseVerificationResult.fromJson(data);
    } catch (e) {
      _debugLog('[RewardsService] submitPurchaseVerification error: $e');
      return null;
    }
    */
  }

  Future<List<PurchaseVerificationQueueItem>> fetchPurchaseVerificationQueue() async {
    final token = await _idToken();
    if (token == null || token.isEmpty) return const [];
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/purchase-verification/admin/queue'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        _debugLog(
          '[RewardsService] fetchPurchaseVerificationQueue ${response.statusCode}: ${response.body}',
        );
        return const [];
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final raw = data['items'] as List? ?? const [];
      return raw
          .whereType<Map>()
          .map(
            (e) => PurchaseVerificationQueueItem.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList();
    } catch (e) {
      _debugLog('[RewardsService] fetchPurchaseVerificationQueue error: $e');
      return const [];
    }
  }

  Future<PurchaseVerificationReviewResult?> reviewPurchaseVerification({
    required String verificationId,
    required bool approve,
    String? note,
  }) async {
    final token = await _idToken();
    if (token == null || token.isEmpty) return null;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/purchase-verification/$verificationId/review'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'action': approve ? 'approve' : 'reject',
              if (note != null && note.isNotEmpty) 'note': note,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        _debugLog(
          '[RewardsService] reviewPurchaseVerification ${response.statusCode}: ${response.body}',
        );
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return PurchaseVerificationReviewResult.fromJson(data);
    } catch (e) {
      _debugLog('[RewardsService] reviewPurchaseVerification error: $e');
      return null;
    }
  }
}

class RewardClaimResult {
  const RewardClaimResult({
    required this.action,
    required this.granted,
    this.track,
    this.amount = 0,
    this.reason,
    this.balance = 0,
    this.level,
  });

  final String action;
  final bool granted;
  final String? track;
  final int amount;
  final String? reason;
  final int balance;
  final int? level;

  factory RewardClaimResult.notGranted({
    required String action,
    String? reason,
  }) {
    return RewardClaimResult(action: action, granted: false, reason: reason);
  }

  factory RewardClaimResult.fromCallable(
    String action,
    Map<String, dynamic> data,
  ) {
    return RewardClaimResult(
      action: action,
      granted: data['granted'] == true,
      track: data['track']?.toString(),
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      reason: data['reason']?.toString(),
      balance: (data['balance'] as num?)?.toInt() ?? 0,
      level: (data['level'] as num?)?.toInt(),
    );
  }
}

class RewardsSummary {
  const RewardsSummary({
    required this.expTotal,
    required this.level,
    required this.pointsBalance,
    required this.pointsLifetimeEarned,
  });

  final int expTotal;
  final int level;
  final int pointsBalance;
  final int pointsLifetimeEarned;

  factory RewardsSummary.fromJson(Map<String, dynamic> json) {
    return RewardsSummary(
      expTotal: (json['expTotal'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 1,
      pointsBalance: (json['pointsBalance'] as num?)?.toInt() ?? 0,
      pointsLifetimeEarned: (json['pointsLifetimeEarned'] as num?)?.toInt() ?? 0,
    );
  }
}

class RewardLedgerEntry {
  const RewardLedgerEntry({
    required this.id,
    required this.action,
    required this.amount,
    required this.track,
    required this.status,
    this.sourceRef,
    this.createdAt,
  });

  final String id;
  final String action;
  final int amount;
  final String track;
  final String status;
  final String? sourceRef;
  final DateTime? createdAt;

  factory RewardLedgerEntry.fromJson(String id, Map<String, dynamic> json) {
    final createdAtRaw = json['createdAt'];
    DateTime? createdAt;
    if (createdAtRaw is Timestamp) {
      createdAt = createdAtRaw.toDate();
    } else if (createdAtRaw != null) {
      createdAt = DateTime.tryParse(createdAtRaw.toString());
    }
    return RewardLedgerEntry(
      id: id,
      action: json['action']?.toString() ?? '',
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      track: json['track']?.toString() ?? 'points',
      status: json['status']?.toString() ?? 'confirmed',
      sourceRef: json['sourceRef']?.toString(),
      createdAt: createdAt,
    );
  }
}

class PurchaseVerificationResult {
  const PurchaseVerificationResult({
    required this.verificationId,
    required this.status,
    required this.pointsAwarded,
    this.marketplace,
    this.extractedAmount,
    this.extractedOrderNumber,
    this.reason,
  });

  final String verificationId;
  final String status;
  final int pointsAwarded;
  final String? marketplace;
  final int? extractedAmount;
  final String? extractedOrderNumber;
  final String? reason;

  bool get isApproved => status == 'approved';
  bool get isPending => status == 'pending';

  factory PurchaseVerificationResult.fromJson(Map<String, dynamic> json) {
    return PurchaseVerificationResult(
      verificationId: json['verificationId']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      pointsAwarded: (json['pointsAwarded'] as num?)?.toInt() ?? 0,
      marketplace: json['marketplace']?.toString(),
      extractedAmount: (json['extractedAmount'] as num?)?.toInt(),
      extractedOrderNumber: json['extractedOrderNumber']?.toString(),
      reason: json['reason']?.toString(),
    );
  }
}

class PurchaseVerificationQueueItem {
  const PurchaseVerificationQueueItem({
    required this.id,
    required this.uid,
    this.marketplace,
    this.orderNumber,
    this.extractedAmount,
    this.purchasedAtRaw,
    this.confidence,
    this.createdAt,
  });

  final String id;
  final String uid;
  final String? marketplace;
  final String? orderNumber;
  final int? extractedAmount;
  final String? purchasedAtRaw;
  final double? confidence;
  final String? createdAt;

  factory PurchaseVerificationQueueItem.fromJson(Map<String, dynamic> json) {
    return PurchaseVerificationQueueItem(
      id: json['id']?.toString() ?? '',
      uid: json['uid']?.toString() ?? '',
      marketplace: json['marketplace']?.toString(),
      orderNumber: json['orderNumber']?.toString(),
      extractedAmount: (json['extractedAmount'] as num?)?.toInt(),
      purchasedAtRaw: json['purchasedAtRaw']?.toString(),
      confidence: (json['confidence'] as num?)?.toDouble(),
      createdAt: json['createdAt']?.toString(),
    );
  }
}

class PurchaseVerificationReviewResult {
  const PurchaseVerificationReviewResult({
    required this.verificationId,
    required this.status,
    required this.pointsAwarded,
  });

  final String verificationId;
  final String status;
  final int pointsAwarded;

  factory PurchaseVerificationReviewResult.fromJson(Map<String, dynamic> json) {
    return PurchaseVerificationReviewResult(
      verificationId: json['verificationId']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      pointsAwarded: (json['pointsAwarded'] as num?)?.toInt() ?? 0,
    );
  }
}
