import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/auth_session_ready.dart';
import 'recipe_service.dart';

class AppNotificationAction {
  final String type;
  final String reviewId;
  final String commentId;
  final String recipeId;
  final String actorId;
  final String screen;
  final String meetupId;
  final String challengeId;

  const AppNotificationAction({
    required this.type,
    this.reviewId = '',
    this.commentId = '',
    this.recipeId = '',
    this.actorId = '',
    this.screen = '',
    this.meetupId = '',
    this.challengeId = '',
  });

  bool get isFollow => type == 'follow';
  bool get isReviewTarget =>
      type == 'review_like' ||
      type == 'review_comment' ||
      type == 'comment_like' ||
      type == 'comment_reply' ||
      type == 'review_hidden' ||
      type == 'review_deleted' ||
      type == 'comment_hidden' ||
      type == 'comment_deleted';
  bool get isMealPlanReminder =>
      type == 'meal_plan_breakfast_reminder' ||
      type == 'meal_plan_lunch_reminder' ||
      type == 'meal_plan_dinner_reminder';
  bool get isStreakReminder =>
      type == 'daily_streak_reminder' || type == 'weekly_streak_reminder';
  bool get isParseComplete => type == 'parse_complete';
  bool get isRecipeTarget =>
      recipeId.isNotEmpty && (isMealPlanReminder || isParseComplete);
  bool get isStreakCalendarTarget =>
      isStreakReminder || screen == 'streak_calendar';
  bool get isMeetupTarget => meetupId.isNotEmpty;
  bool get isChallengeTarget => challengeId.isNotEmpty;
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _lastUid;
  Timer? _authNullDebounceTimer;
  int _iosTokenRetryGeneration = 0;

  /// Set by [MainNavigator] so in-app notification UI (header bell) can deep-link without importing `main.dart`.
  void Function(AppNotificationAction action)? notificationUiActionDelegate;

  static AppNotificationAction parseActionFromMap(Map<String, dynamic> map) {
    return AppNotificationAction(
      type: (map['type'] ?? '').toString(),
      reviewId: (map['reviewId'] ?? '').toString(),
      commentId: (map['commentId'] ?? '').toString(),
      recipeId: (map['recipeId'] ?? '').toString(),
      actorId: (map['actorId'] ?? '').toString(),
      screen: (map['screen'] ?? '').toString(),
      meetupId: (map['meetupId'] ?? '').toString(),
      challengeId: (map['challengeId'] ?? '').toString(),
    );
  }

  static AppNotificationAction parseActionFromDoc(Map<String, dynamic> data) {
    return AppNotificationAction(
      type: (data['type'] ?? '').toString(),
      reviewId: (data['reviewId'] ?? '').toString(),
      commentId: (data['commentId'] ?? '').toString(),
      recipeId: (data['recipeId'] ?? '').toString(),
      actorId: (data['actorId'] ?? '').toString(),
      screen: (data['screen'] ?? '').toString(),
      meetupId: (data['meetupId'] ?? '').toString(),
      challengeId: (data['challengeId'] ?? '').toString(),
    );
  }

  Future<void> initialize({
    required Future<void> Function(AppNotificationAction action) onActionTap,
  }) async {
    if (_initialized) return;

    try {
      await _requestPermission();
      await _initLocalNotification(onActionTap);
    } catch (e, stackTrace) {
      debugPrint('[NotificationService] Local notification init failed: $e');
      debugPrint('$stackTrace');
    }

    try {
      await _registerCurrentToken();
      _lastUid = _auth.currentUser?.uid;

      _auth.authStateChanges().listen((user) async {
        _authNullDebounceTimer?.cancel();
        if (user == null) {
          _authNullDebounceTimer = Timer(const Duration(milliseconds: 800), () async {
            if (_auth.currentUser != null) return;
            if (_lastUid != null && _lastUid!.isNotEmpty) {
              await _unregisterCurrentTokenForUid(_lastUid!);
            }
            _lastUid = null;
          });
          return;
        }
        if (_lastUid != null && _lastUid != user.uid) {
          await _unregisterCurrentTokenForUid(_lastUid!);
        }
        if (_lastUid != user.uid) {
          _lastUid = user.uid;
          try {
            await _registerCurrentToken();
          } catch (e) {
            debugPrint(
              '[NotificationService] Token refresh on login skipped: $e',
            );
          }
        }
      });

      _messaging.onTokenRefresh.listen((token) async {
        try {
          await _saveToken(token);
        } catch (e) {
          debugPrint('[NotificationService] onTokenRefresh save failed: $e');
        }
      });

      FirebaseMessaging.onMessage.listen((message) async {
        try {
          final action = parseActionFromMap(message.data);
          if (action.isParseComplete && action.recipeId.isNotEmpty) {
            await RecipeService.shared.handleParseCompleted(action.recipeId);
          }
          await _showForegroundLocalNotification(message);
        } catch (e) {
          debugPrint('[NotificationService] onMessage show failed: $e');
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((message) async {
        try {
          await onActionTap(parseActionFromMap(message.data));
        } catch (e) {
          debugPrint('[NotificationService] onMessageOpenedApp failed: $e');
        }
      });

      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        await onActionTap(parseActionFromMap(initialMessage.data));
      }
    } catch (e, stackTrace) {
      // Embedded / restricted browsers (e.g. IDE preview) often have no Push API.
      debugPrint(
        '[NotificationService] FCM unavailable; app continues without push: $e',
      );
      debugPrint('$stackTrace');
    }

    _initialized = true;

    // iOS: APNs token often arrives after the first few seconds (SDK updates, cold start,
    // simulator). Retries avoid a one-shot failure when getToken runs too early.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _scheduleIosApnsTokenRetries();
    }
  }

  Future<void> _requestPermission() async {
    if (kIsWeb) return;
    await _messaging.setAutoInitEnabled(true);
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    debugPrint(
      '[NotificationService] permission status: ${settings.authorizationStatus.name}',
    );
  }

  Future<void> _initLocalNotification(
    Future<void> Function(AppNotificationAction action) onActionTap,
  ) async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);

    await _local.initialize(
      settings,
      onDidReceiveNotificationResponse: (resp) async {
        final payload = resp.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final map = jsonDecode(payload) as Map<String, dynamic>;
          await onActionTap(parseActionFromMap(map));
        } catch (_) {}
      },
    );

    const channel = AndroidNotificationChannel(
      'yorigo_notifications',
      'Yorigo Notifications',
      importance: Importance.high,
    );
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  Future<void> _showForegroundLocalNotification(RemoteMessage message) async {
    final title = message.notification?.title ?? '요리고';
    final body = message.notification?.body ?? '';
    final payload = jsonEncode(message.data);

    const androidDetails = AndroidNotificationDetails(
      'yorigo_notifications',
      'Yorigo Notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _local.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  Future<void> _registerCurrentToken() async {
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS can return before APNs token is ready on fresh installs.
        final apnsReady = await _waitForApnsToken();
        if (!apnsReady) {
          debugPrint(
            '[NotificationService] APNs token not ready yet; will retry if scheduled',
          );
          return;
        }
      }

      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      await _saveToken(token);
    } on FirebaseException catch (e) {
      // Still thrown on some iOS builds even after getAPNSToken() is non-null (short race).
      final code = e.code.toLowerCase();
      if (code.contains('apns-token')) {
        debugPrint(
          '[NotificationService] getToken: APNs not ready ($code); retry may succeed',
        );
      } else {
        debugPrint('[NotificationService] getToken/register skipped: $e');
      }
    } catch (e) {
      debugPrint('[NotificationService] getToken/register skipped: $e');
    }
  }

  Future<void> _unregisterCurrentTokenForUid(String uid) async {
    if (uid.isEmpty) return;
    try {
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('fcmTokens')
          .doc(token)
          .delete();
    } on FirebaseException catch (e) {
      // 토큰/APNs 준비 레이스나 권한 이슈로 실패해도 인증 흐름은 계속 진행.
      debugPrint('[NotificationService] token unregister skipped: $e');
    } catch (e) {
      debugPrint('[NotificationService] token unregister skipped: $e');
    }
  }

  /// Poll until APNs gives a device token or timeout. Window must survive cold start + Xcode/iOS updates.
  Future<bool> _waitForApnsToken() async {
    const attempts = 30;
    const delay = Duration(milliseconds: 400);
    for (var i = 0; i < attempts; i++) {
      final apnsToken = await _messaging.getAPNSToken();
      if (apnsToken != null && apnsToken.isNotEmpty) {
        return true;
      }
      await Future<void>.delayed(delay);
    }
    return false;
  }

  /// Post-startup attempts; cancel prior scheduled retries when [initialize] runs again.
  void _scheduleIosApnsTokenRetries() {
    final gen = ++_iosTokenRetryGeneration;
    const delays = <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 8),
      Duration(seconds: 20),
    ];
    for (final d in delays) {
      Future<void>.delayed(d, () async {
        if (!_initialized || gen != _iosTokenRetryGeneration) return;
        try {
          await _registerCurrentToken();
        } catch (e) {
          debugPrint('[NotificationService] iOS deferred token register: $e');
        }
      });
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    await _firestore
        .collection('users')
        .doc(uid)
        .collection('fcmTokens')
        .doc(token)
        .set({
          'token': token,
          'platform': defaultTargetPlatform.name,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> scheduleAdminPushDebugTest({int delaySeconds = 30}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('로그인된 사용자만 푸시 테스트를 예약할 수 있습니다.');
    }
    final clampedDelay = delaySeconds.clamp(5, 120);
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('pushDebugRequests')
        .add({
          'requestedBy': uid,
          'delaySeconds': clampedDelay,
          'platform': defaultTargetPlatform.name,
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'queued',
        });
  }

  /// Admin-only: schedule a random recipe for today's meal slot and send the
  /// cooking reminder immediately (same payload as production meal reminders).
  Future<void> scheduleAdminMealReminderTest({
    required String mealType,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('로그인된 사용자만 식사 알림 테스트를 요청할 수 있습니다.');
    }
    const allowed = {'breakfast', 'lunch', 'dinner'};
    if (!allowed.contains(mealType)) {
      throw ArgumentError.value(mealType, 'mealType', 'breakfast, lunch, dinner only');
    }
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('mealReminderTestRequests')
        .add({
          'requestedBy': uid,
          'mealType': mealType,
          'platform': defaultTargetPlatform.name,
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'queued',
        });
  }

  static const instagramMaintenanceCampaignId =
      'instagram_maintenance_2026_06';
  static const appReinstallCampaignId = 'app_reinstall_2026_07';

  /// One-time broadcast: Instagram maintenance notice to every user (push + inbox).
  Future<void> scheduleInstagramMaintenanceBroadcast() async {
    await _scheduleSystemBroadcast(instagramMaintenanceCampaignId);
  }

  /// One-time broadcast: app reinstall guidance to every user (push + inbox).
  Future<void> scheduleAppReinstallBroadcast() async {
    await _scheduleSystemBroadcast(appReinstallCampaignId);
  }

  Future<void> _scheduleSystemBroadcast(String campaignId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('로그인된 관리자만 전체 공지를 발송할 수 있습니다.');
    }

    final ref = _firestore.collection('adminBroadcastRequests').doc(campaignId);
    final existing = await ref.get();
    if (existing.exists) {
      throw StateError('already_exists');
    }
    await ref.set({
      'campaignId': campaignId,
      'requestedBy': uid,
      'status': 'queued',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<List<Map<String, dynamic>>> myNotificationsStream({int limit = 100}) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value([]);

    return _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs.map((d) => {'id': d.id, ...d.data()}).toList(),
        );
  }

  Stream<int> unreadCountStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(0);

    // 뱃지는 99 초과 시 '99+'로만 표시하므로, 안 읽은 알림 문서를 전부 읽을
    // 필요가 없다. limit(100)으로 실시간 리스너가 읽는 문서 수를 상한해
    // Firestore read 비용을 제한한다. (0~99는 정확, 100 이상은 '99+'로 동일 표시)
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .limit(100)
        .snapshots()
        .map((s) => s.docs.length);
  }

  Future<void> markAsRead(String notificationId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || notificationId.isEmpty) return;
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .doc(notificationId)
        .set({'isRead': true}, SetOptions(merge: true));
  }

  Future<void> markAllAsRead() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final unread = await _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .get();
    if (unread.docs.isEmpty) return;

    final batch = _firestore.batch();
    for (final doc in unread.docs) {
      batch.set(doc.reference, {'isRead': true}, SetOptions(merge: true));
    }
    await batch.commit();
  }
}
