import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mixpanel_flutter/mixpanel_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/environment_config.dart';
import '../utils/recipe_signal_snapshot.dart';
import 'rewards_service.dart';

/// EXP 리워드 idempotency key에 쓰는 "오늘" 문자열 (KST 여부는 중요치 않고
/// 기기 로컬 날짜 기준 하루 단위 중복 방지만 되면 된다).
String _rewardsDayKey([DateTime? dateTime]) {
  final dt = dateTime ?? DateTime.now();
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

/// 이벤트 버퍼에 담아두는 pending 이벤트 — flush 시점에 JSONL 한 줄로 직렬화된다.
class _PendingInteractionEvent {
  _PendingInteractionEvent({required this.eventId, required this.map});
  final String eventId;
  final Map<String, dynamic> map;
}

/// 식별자용 sanitize — 영문/숫자/밑줄만 남김. 한글 라벨에는 쓰지 말 것.
@visibleForTesting
String sanitizeAnalyticsName(String value, {String fallback = 'unknown'}) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (normalized.isEmpty) {
    return fallback;
  }
  return normalized.length > 40 ? normalized.substring(0, 40) : normalized;
}

/// 표시용 라벨/이름 보존 truncate — 한글·공백 유지.
@visibleForTesting
String truncateAnalyticsValue(String value, {String fallback = 'unknown'}) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return fallback;
  }
  return normalized.length > 100 ? normalized.substring(0, 100) : normalized;
}

/// 홈 1차 필터 한글 라벨 → 조인 가능한 ascii id.
@visibleForTesting
const Map<String, String> kHomePrimaryFilterIds = <String, String>{
  '전체': 'all',
  '메뉴별': 'menu',
  '나라별': 'country',
  '재료별': 'ingredient',
  '시간': 'time',
};

/// Mixpanel/GCS 조인용 안정 id.
///
/// ascii 식별자는 sanitize 그대로 쓰고, 한글 라벨은 전부 `unknown`으로 뭉개지
/// 않게 utf-8 hex (`k_…`) 로 남긴다. 표시 문구는 [truncateAnalyticsValue]로만 보낸다.
@visibleForTesting
String stableAnalyticsId(String raw, {String fallback = 'unknown'}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return fallback;
  final mapped = kHomePrimaryFilterIds[trimmed];
  if (mapped != null) return mapped;
  final sanitized = sanitizeAnalyticsName(trimmed, fallback: '');
  if (sanitized.isNotEmpty) return sanitized;
  final hex = utf8
      .encode(trimmed)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final id = 'k_$hex';
  return id.length > 40 ? id.substring(0, 40) : id;
}

/// 카드 클릭 화면이 있으면 상세 `recipe_viewed` source를 그 화면으로 대체한다.
@visibleForTesting
String resolveRecipeViewSource({
  required String fallback,
  required String recipeId,
  String? pendingRecipeId,
  String? pendingScreen,
}) {
  final requested = fallback.trim();
  final pendingId = pendingRecipeId?.trim() ?? '';
  final pending = pendingScreen?.trim() ?? '';
  if (pendingId == recipeId.trim() &&
      pending.isNotEmpty &&
      (requested.isEmpty || requested == 'recipe_detail')) {
    return pending;
  }
  return requested.isEmpty ? 'recipe_detail' : requested;
}

class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();

  factory AnalyticsService() {
    return _instance;
  }

  AnalyticsService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  FirebaseAnalytics? _analytics;
  Mixpanel? _mixpanel;
  bool _mixpanelInitAttempted = false;
  bool _mixpanelIdentified = false;
  bool _superPropertiesRegistered = false;
  String? _currentScreenName;
  DateTime? _currentScreenStartedAt;
  bool _screenTimerPaused = false;
  final Set<String> _activePeriodWritesInFlight = <String>{};
  final Set<String> _mpActiveUserInFlight = <String>{};

  // ---- 행동 시그널 수집(카드 단위 impression/click 등) ----
  // Firestore가 아니라 Firebase Storage(GCS)에 JSONL 배치로 직접 업로드한다.
  // 이유: 이벤트 1건당 Firestore 문서 1개 쓰기(+색인) 과금 대신, 배치(파일) 1개
  // 업로드로 묶어 비용을 이벤트 개수가 아니라 업로드 배치 횟수에 비례시킨다.
  static const String _signalsRawPrefix = 'signals/raw';
  static const int _flushBatchSize = 20;
  static const Duration _flushInterval = Duration(seconds: 5);
  static const String _pendingRetryQueueKey = '_signal_pending_retry_batches_v1';
  static const int _maxPendingRetryBatches = 30; // 장시간 오프라인 시 로컬 저장 폭주 방지

  final List<_PendingInteractionEvent> _eventBuffer = <_PendingInteractionEvent>[];
  final Uuid _uuid = const Uuid();
  Timer? _signalFlushTimer;
  bool _retryQueueFlushInProgress = false;
  String? _cachedSessionId;
  String? _cachedDeviceId;
  String? _cachedAppVersion;
  /// 카드 클릭 → 상세 진입 귀속. `recipe_viewed`가 source를 잃는 것을 막는다.
  String? _pendingRecipeOpenId;
  String? _pendingRecipeOpenScreen;
  String? _pendingRecipeOpenSection;
  /// 현재 레시피 상세. screen_stay를 레시피 단위 dwell로 남길 때 사용.
  String? _currentRecipeId;

  /// Mixpanel 토큰이 없으면 no-op, 초기화 실패 시에도 앱은 계속 동작
  Future<void> _initMixpanelIfNeeded() async {
    if (_mixpanel != null || _mixpanelInitAttempted) {
      return;
    }
    _mixpanelInitAttempted = true;
    final String token = EnvironmentConfig.mixpanelProjectToken.trim();
    if (token.isEmpty) {
      return;
    }
    try {
      final Mixpanel mp = await Mixpanel.init(
        token,
        trackAutomaticEvents: false,
      );
      final String serverUrl = EnvironmentConfig.mixpanelServerUrl.trim();
      if (serverUrl.isNotEmpty) {
        mp.setServerURL(serverUrl);
      }
      // 테스트 빌드: --dart-define=MIXPANEL_DEBUG_LOG=true (profile/release에서도 동작)
      const bool mixpanelDebugLog = bool.fromEnvironment(
        'MIXPANEL_DEBUG_LOG',
        defaultValue: false,
      );
      if (mixpanelDebugLog) {
        mp.setLoggingEnabled(true);
      }
      _mixpanel = mp;
      await _registerSuperPropertiesIfNeeded(mp);
    } catch (e) {
      print('[AnalyticsService] Error initializing Mixpanel: $e');
    }
  }

  /// 모든 이벤트에 버전·플랫폼·환경이 붙도록 1회 등록
  Future<void> _registerSuperPropertiesIfNeeded(Mixpanel mp) async {
    if (_superPropertiesRegistered) {
      return;
    }
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      _cachedAppVersion = info.version;
      final String platform = kIsWeb
          ? 'web'
          : defaultTargetPlatform.name.toLowerCase();
      final String buildMode = kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug');
      mp.registerSuperProperties(<String, dynamic>{
        'app_version': info.version,
        'app_build': info.buildNumber,
        // OS. 이벤트 `platform`은 파싱 등에서 콘텐츠 소스(instagram)로 쓰이므로
        // 기기 값은 `device_os`로도 남긴다.
        'platform': platform,
        'device_os': platform,
        'build_mode': buildMode,
        'environment': EnvironmentConfig.currentEnvironment.name,
      });
      _superPropertiesRegistered = true;
    } catch (e) {
      print('[AnalyticsService] Error registering Mixpanel super properties: $e');
    }
  }

  /// Firebase 이벤트와 동일한 이름/속성으로 Mixpanel에 전송
  Future<void> _mpTrack(
    String eventName, {
    Map<String, Object?>? properties,
  }) async {
    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp == null) {
      return;
    }
    try {
      Map<String, dynamic>? map;
      if (properties != null && properties.isNotEmpty) {
        map = <String, dynamic>{};
        for (final MapEntry<String, Object?> e in properties.entries) {
          if (e.value != null) {
            map[e.key] = e.value as Object;
          }
        }
      }
      map ??= <String, dynamic>{};
      map.putIfAbsent('device_os', _deviceOs);
      if (_cachedAppVersion != null && _cachedAppVersion!.isNotEmpty) {
        map.putIfAbsent('app_version', () => _cachedAppVersion);
      }
      await mp.track(eventName, properties: map);
    } catch (e) {
      print('[AnalyticsService] Mixpanel track "$eventName": $e');
    }
  }

  Future<void> _mpPeopleIncrement(String property, double by) async {
    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp == null) {
      return;
    }
    try {
      mp.getPeople().increment(property, by);
    } catch (e) {
      print('[AnalyticsService] Mixpanel people increment "$property": $e');
    }
  }

  Future<void> _mpPeopleSet(String property, Object value) async {
    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp == null) {
      return;
    }
    try {
      mp.getPeople().set(property, value);
    } catch (e) {
      print('[AnalyticsService] Mixpanel people set "$property": $e');
    }
  }

  /// Mixpanel people.set은 브릿지 호출이 동기 큐라, init 한 뒤 속성만 넣는다.
  Future<void> _mpPeopleSetAll(Map<String, Object> properties) async {
    if (properties.isEmpty) return;
    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp == null) return;
    try {
      final people = mp.getPeople();
      for (final entry in properties.entries) {
        people.set(entry.key, entry.value);
      }
    } catch (e) {
      print('[AnalyticsService] Mixpanel people setAll: $e');
    }
  }

  Future<void> _setFaUserProperty(String name, String? value) async {
    if (value == null || value.isEmpty) return;
    await initialize();
    try {
      await _analytics?.setUserProperty(name: name, value: value);
    } catch (e) {
      print('[AnalyticsService] FA user property "$name": $e');
    }
  }

  Future<void> initialize() async {
    try {
      _analytics ??= FirebaseAnalytics.instance;
      await _analytics!.setAnalyticsCollectionEnabled(true);
    } catch (e) {
      print('[AnalyticsService] Error initializing Firebase Analytics: $e');
    }
    await _ensureAppVersionCached();
    await _initMixpanelIfNeeded();
    // 앱 기동 시 이전 세션에서 업로드 실패해 로컬에 남아있던 배치가 있으면 재시도.
    unawaited(_flushRetryQueue());
  }

  Future<void> syncCurrentUser(String? userId) async {
    await initialize();

    try {
      await _analytics?.setUserId(id: userId);
      await _analytics?.setUserProperty(
        name: 'auth_state',
        value: userId == null ? 'signed_out' : 'signed_in',
      );
    } catch (e) {
      print('[AnalyticsService] Error syncing current user: $e');
    }

    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp == null) {
      return;
    }
    try {
      if (userId == null || userId.isEmpty) {
        // reset() 은 실제 로그아웃(identified → anonymous) 전환일 때만 호출.
        // 첫 실행 시 아직 identify 된 적 없으면 reset 하면 app_first_open 과
        // 이후 sign_up 의 identity chain 이 끊긴다.
        if (_mixpanelIdentified) {
          await mp.reset();
          _mixpanelIdentified = false;
        }
      } else {
        await mp.identify(userId);
        _mixpanelIdentified = true;
        mp.getPeople().set('auth_state', 'signed_in');
      }
    } catch (e) {
      print('[AnalyticsService] Error syncing Mixpanel user: $e');
    }
  }

  Future<void> trackRoute(String? routeName) async {
    final screenName = _screenNameFromRoute(routeName);
    if (screenName == null) {
      return;
    }

    await trackScreen(screenName);
  }

  Future<void> trackMainTab(int index) async {
    const tabNames = {
      0: 'dashboard_home',
      1: 'feed_explore',
      2: 'shopping_cart',
      3: 'fridge',
      4: 'profile',
    };

    final screenName = tabNames[index];
    if (screenName == null) {
      return;
    }

    await trackScreen(screenName);
  }

  Future<void> trackScreen(String screenName, {String? screenClass}) async {
    final normalizedScreenName = _sanitizeName(screenName, fallback: 'unknown');
    await initialize();

    if (_currentScreenName == normalizedScreenName &&
        _currentScreenStartedAt != null) {
      return;
    }

    await _flushCurrentScreenStay(nextScreenName: normalizedScreenName);

    _currentScreenName = normalizedScreenName;
    _currentScreenStartedAt = DateTime.now();
    _screenTimerPaused = false;

    try {
      await _analytics?.logScreenView(
        screenName: normalizedScreenName,
        screenClass: screenClass ?? normalizedScreenName,
      );
      await _analytics?.setUserProperty(
        name: 'current_screen',
        value: normalizedScreenName,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking screen view: $e');
    }

    await _mpTrack(
      'screen_view',
      properties: {
        'screen_name': normalizedScreenName,
        'screen_class': screenClass ?? normalizedScreenName,
      },
    );
  }

  Future<void> handleAppLifecycleChange(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (_currentScreenName != null &&
          (_currentScreenStartedAt == null || _screenTimerPaused)) {
        _currentScreenStartedAt = DateTime.now();
        _screenTimerPaused = false;
      }
      // 재시작 시 이전에 실패해 로컬에 쌓인 배치를 다시 올려본다.
      unawaited(_flushRetryQueue());
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      if (_currentScreenName != null && !_screenTimerPaused) {
        await _flushCurrentScreenStay(keepCurrentScreenName: true);
        _screenTimerPaused = true;
      }
      // 백그라운드 전환 시점에 버퍼에 남아있는 이벤트를 즉시 flush.
      await _flushEventBuffer();
    }
  }

  // ===================== 행동 시그널 수집 (카드 impression/click 등) =====================
  //
  // Firestore 대신 Firebase Storage(GCS)에 JSONL 배치로 직접 업로드한다.
  // - 비용: 이벤트 100개를 각각 Firestore 문서로 쓰면 쓰기 100회 과금이지만,
  //   버퍼에 모았다가 파일 1개로 업로드하면 업로드 1회로 묶여 비용이 이벤트 수가 아니라
  //   업로드 배치 횟수에 비례한다. Storage 저장 단가 자체도 Firestore보다 훨씬 낮다.
  // - 미로그인 사용자는 수집하지 않는다(storage.rules가 request.auth.uid 기준으로만
  //   쓰기를 허용 — 기존 Firestore 이벤트 컬렉션들의 isSignedIn() 관례와 동일).
  // - 오프라인/업로드 실패 시: Firestore SDK와 달리 Storage 업로드는 자동 오프라인
  //   큐잉이 없으므로, 실패한 배치를 SharedPreferences에 직접 남겨뒀다가 다음 flush
  //   또는 앱 재개 시점에 재시도한다(_flushRetryQueue).

  Future<String> _getOrCreateSessionId() async {
    if (_cachedSessionId != null) return _cachedSessionId!;
    _cachedSessionId = _uuid.v4();
    return _cachedSessionId!;
  }

  Future<String> _getOrCreateDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString('_signal_device_id_v1');
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = _uuid.v4();
        await prefs.setString('_signal_device_id_v1', deviceId);
      }
      _cachedDeviceId = deviceId;
      return deviceId;
    } catch (e) {
      // SharedPreferences 접근 실패 시에도 이벤트 자체는 계속 쌓이도록 세션 한정 fallback.
      _cachedDeviceId ??= _uuid.v4();
      return _cachedDeviceId!;
    }
  }

  /// 카드 단위 impression/click/cook_start/cook_done/purchase/review 이벤트를 버퍼에 쌓는다.
  /// 호출부는 화면에 이미 들고 있는 recipe/product raw map에서 속성값을 그대로 꺼내
  /// 전달하면 된다(추가 API 호출 없음). null 필드는 문서 크기 절약을 위해 자동 생략.
  Future<void> logCardEvent(
    String eventType, {
    required String screen,
    String? sectionId,
    String? cardId,
    String? contentType,
    String? recipeId,
    int? position,
    List<String>? recipeCuisineType,
    List<String>? recipeTimeCategory,
    List<String>? recipeMenuType,
    List<String>? recipeMainIngredient,
    List<String>? recipeMainIngredientSub,
    List<String>? recipeTags,
    String? recipeNutritionRating,
    List<String>? recipeIngredientCategories,
    String? recipeSourcePlatform,
    int? recipeServings,
    String? marketplace,
    String? productId,
    String? ingredientName,
    int? price,
    double? productRating,
    int? productReviewCount,
    double? productBayesianRating,
    double? productValueScore,
    bool? productIsRocket,
    bool? productIsFreeShipping,
    double? productDiscountRate,
    double? productUnitPrice,
    double? productPackageSize,
    String? productPackageUnit,
    int? productSalesRank,
    String? ingredientCategory,
    String? posterId,
    String? chipSectionKey,
    String? sourceScreen,
    int? durationMs,
  }) async {
    try {
      // 상세 initState의 recipe_viewed보다 먼저 pending을 남겨야 한다.
      // session/device await 뒤에 두면 source_screen이 recipe_detail로 덮인다.
      if (eventType == 'click' &&
          recipeId != null &&
          recipeId.trim().isNotEmpty &&
          (contentType == null ||
              contentType == 'recipe' ||
              contentType == 'review')) {
        noteRecipeOpenSource(
          recipeId: recipeId,
          screen: screen,
          sectionId: sectionId,
        );
      }
      final String? userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null || userId.isEmpty) {
        // 비로그인 사용자는 수집 대상 아님(storage.rules와 일치).
        return;
      }
      await _ensureAppVersionCached();
      final String sessionId = await _getOrCreateSessionId();
      final String deviceId = await _getOrCreateDeviceId();
      final String eventId = _uuid.v4();
      final Map<String, dynamic> map = <String, dynamic>{
        'eventId': eventId,
        'eventType': eventType,
        'clientTs': DateTime.now().toUtc().toIso8601String(),
        'userId': userId,
        'sessionId': sessionId,
        'deviceId': deviceId,
        'appVersion': _cachedAppVersion,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
        'screen': screen,
        'sectionId': sectionId,
        'cardId': cardId,
        'contentType': contentType,
        'recipeId': recipeId,
        'position': position,
        'recipeCuisineType': recipeCuisineType,
        'recipeTimeCategory': recipeTimeCategory,
        'recipeMenuType': recipeMenuType,
        'recipeMainIngredient': recipeMainIngredient,
        'recipeMainIngredientSub': recipeMainIngredientSub,
        'recipeTags': recipeTags,
        'recipeNutritionRating': recipeNutritionRating,
        'recipeIngredientCategories': recipeIngredientCategories,
        'recipeSourcePlatform': recipeSourcePlatform,
        'recipeServings': recipeServings,
        'marketplace': marketplace,
        'productId': productId,
        'ingredientName': ingredientName,
        'price': price,
        'productRating': productRating,
        'productReviewCount': productReviewCount,
        'productBayesianRating': productBayesianRating,
        'productValueScore': productValueScore,
        'productIsRocket': productIsRocket,
        'productIsFreeShipping': productIsFreeShipping,
        'productDiscountRate': productDiscountRate,
        'productUnitPrice': productUnitPrice,
        'productPackageSize': productPackageSize,
        'productPackageUnit': productPackageUnit,
        'productSalesRank': productSalesRank,
        'ingredientCategory': ingredientCategory,
        'posterId': posterId,
        'chipSectionKey': chipSectionKey,
        'sourceScreen': sourceScreen,
        'durationMs': durationMs,
      }..removeWhere((_, dynamic v) => v == null);
      _eventBuffer.add(_PendingInteractionEvent(eventId: eventId, map: map));
      _scheduleSignalFlush();
      if (_eventBuffer.length >= _flushBatchSize) {
        await _flushEventBuffer();
      }
    } catch (e) {
      // 계측 실패가 실제 화면 동작에 영향을 주면 안 되므로 조용히 무시.
      print('[AnalyticsService] logCardEvent("$eventType") failed: $e');
    }
  }

  /// 레시피 raw map에서 스냅샷을 뽑아 [logCardEvent]로 보낸다.
  /// 포스터/프로그램/전체보기 등 신규 표면에서 필드 누락을 막기 위한 공통 진입점.
  Future<void> logRecipeMapEvent(
    String eventType, {
    required String screen,
    required Map<String, dynamic> recipe,
    String? sectionId,
    int? position,
    String contentType = 'recipe',
    String? posterId,
    String? chipSectionKey,
  }) async {
    final String recipeId =
        (recipe['id'] ?? recipe['recipeId'])?.toString().trim() ?? '';
    if (recipeId.isEmpty) return;
    final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
    await logCardEvent(
      eventType,
      screen: screen,
      sectionId: sectionId,
      cardId: recipeId,
      contentType: contentType,
      recipeId: recipeId,
      position: position,
      posterId: posterId,
      chipSectionKey: chipSectionKey,
      recipeCuisineType: snapshot.cuisineType,
      recipeTimeCategory: snapshot.timeCategory,
      recipeMenuType: snapshot.menuType,
      recipeMainIngredient: snapshot.mainIngredient,
      recipeMainIngredientSub: snapshot.mainIngredientSub,
      recipeTags: snapshot.tags,
      recipeNutritionRating: snapshot.nutritionRating,
      recipeIngredientCategories: snapshot.ingredientCategories,
      recipeSourcePlatform: snapshot.sourcePlatform,
      recipeServings: snapshot.servings,
    );
  }

  /// Mixpanel 전용 이벤트에 개인화 GCS 한 줄을 붙일 때 사용.
  void _signal({
    required String eventType,
    required String screen,
    String? sectionId,
    String? cardId,
    String? contentType,
    String? recipeId,
    String? ingredientName,
    int? position,
    String? recipeSourcePlatform,
    int? recipeServings,
    String? marketplace,
    String? productId,
    int? price,
    String? posterId,
    String? chipSectionKey,
    String? sourceScreen,
    int? durationMs,
  }) {
    unawaited(
      logCardEvent(
        eventType,
        screen: screen,
        sectionId: sectionId,
        cardId: cardId,
        contentType: contentType,
        recipeId: recipeId,
        ingredientName: ingredientName,
        position: position,
        recipeSourcePlatform: recipeSourcePlatform,
        recipeServings: recipeServings,
        marketplace: marketplace,
        productId: productId,
        price: price,
        posterId: posterId,
        chipSectionKey: chipSectionKey,
        sourceScreen: sourceScreen,
        durationMs: durationMs,
      ),
    );
  }

  /// 레시피 카드 클릭 직후 상세 진입 귀속에 쓴다.
  void noteRecipeOpenSource({
    required String recipeId,
    required String screen,
    String? sectionId,
  }) {
    final id = recipeId.trim();
    final src = screen.trim();
    if (id.isEmpty || src.isEmpty) return;
    _pendingRecipeOpenId = id;
    _pendingRecipeOpenScreen = src;
    _pendingRecipeOpenSection = sectionId?.trim();
  }

  void setCurrentRecipeContext(String? recipeId) {
    final id = recipeId?.trim();
    _currentRecipeId = (id == null || id.isEmpty) ? null : id;
  }

  void _scheduleSignalFlush() {
    _signalFlushTimer ??= Timer.periodic(_flushInterval, (_) {
      unawaited(_flushEventBuffer());
    });
  }

  Future<String> _buildSignalBatchPath(String userId) async {
    final DateTime now = DateTime.now().toUtc();
    final String dateStr = DateFormat('yyyy-MM-dd').format(now);
    final String sessionId = await _getOrCreateSessionId();
    final String batchId = _uuid.v4().substring(0, 8);
    return '$_signalsRawPrefix/$dateStr/$userId/${sessionId}_${now.millisecondsSinceEpoch}_$batchId.jsonl';
  }

  Future<void> _flushEventBuffer() async {
    if (_eventBuffer.isEmpty) return;
    final String? userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) {
      // 플러시 시점에 로그아웃된 경우 — 버퍼는 비우되 업로드는 생략(고아 데이터 방지).
      _eventBuffer.clear();
      return;
    }
    final List<_PendingInteractionEvent> pending =
        List<_PendingInteractionEvent>.from(_eventBuffer);
    _eventBuffer.clear();
    final String jsonl = pending.map((e) => jsonEncode(e.map)).join('\n');
    final String path = await _buildSignalBatchPath(userId);
    await _uploadJsonlBatch(path, jsonl);
  }

  Future<void> _uploadJsonlBatch(String path, String jsonl) async {
    try {
      final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonl));
      final Reference ref = FirebaseStorage.instance.ref().child(path);
      await ref.putData(bytes, SettableMetadata(contentType: 'application/x-ndjson'));
    } catch (e) {
      print('[AnalyticsService] Signal batch upload failed, queued for retry: $e');
      await _persistFailedBatchForRetry(path, jsonl);
    }
  }

  Future<void> _persistFailedBatchForRetry(String path, String jsonl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> queue =
          prefs.getStringList(_pendingRetryQueueKey) ?? <String>[];
      queue.add(jsonEncode(<String, String>{'path': path, 'content': jsonl}));
      // 장시간 오프라인 시 로컬 저장이 무한정 늘어나지 않도록 오래된 배치부터 버림
      // (최신 행동 데이터를 우선 보존 — 오래된 impression 몇 개보다 최신 신호가 더 유용).
      final List<String> trimmed = queue.length > _maxPendingRetryBatches
          ? queue.sublist(queue.length - _maxPendingRetryBatches)
          : queue;
      await prefs.setStringList(_pendingRetryQueueKey, trimmed);
    } catch (e) {
      print('[AnalyticsService] Failed to persist retry queue: $e');
    }
  }

  Future<void> _flushRetryQueue() async {
    if (_retryQueueFlushInProgress) return;
    _retryQueueFlushInProgress = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> queue =
          prefs.getStringList(_pendingRetryQueueKey) ?? <String>[];
      if (queue.isEmpty) return;
      final List<String> stillFailing = <String>[];
      for (final String raw in queue) {
        try {
          final Map<String, dynamic> item =
              jsonDecode(raw) as Map<String, dynamic>;
          final String path = item['path'] as String;
          final String content = item['content'] as String;
          final Uint8List bytes = Uint8List.fromList(utf8.encode(content));
          await FirebaseStorage.instance
              .ref()
              .child(path)
              .putData(bytes, SettableMetadata(contentType: 'application/x-ndjson'));
        } catch (e) {
          stillFailing.add(raw);
        }
      }
      await prefs.setStringList(_pendingRetryQueueKey, stillFailing);
    } catch (e) {
      print('[AnalyticsService] Failed to flush retry queue: $e');
    } finally {
      _retryQueueFlushInProgress = false;
    }
  }

  /// Fire once per install on the very first app launch (before sign-up).
  /// Uses SharedPreferences to guarantee single-fire.
  Future<void> trackAppFirstOpenIfNeeded() async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('_mp_first_open_tracked') == true) return;

    try {
      await _analytics?.logEvent(name: 'app_first_open');
    } catch (e) {
      print('[AnalyticsService] Error tracking first open (Firebase): $e');
    }
    await _mpTrack('app_first_open');
    await prefs.setBool('_mp_first_open_tracked', true);
  }

  Future<void> trackSignUp({required String method}) async {
    await initialize();

    final String m = _sanitizeName(method);
    try {
      await _analytics?.logSignUp(signUpMethod: m);
    } catch (e) {
      print('[AnalyticsService] Error tracking sign up: $e');
    }
    await _mpTrack('sign_up', properties: {'sign_up_method': m});
    await _mpPeopleSet('signup_method', m);
  }

  Future<void> trackOnboardingStarted({required String entry}) async {
    final sanitized = _sanitizeName(entry, fallback: 'signup');
    await _logBoth(
      'onboarding_started',
      properties: {'entry': sanitized},
    );
    _signal(
      eventType: 'onboarding_start',
      screen: 'onboarding',
      sectionId: sanitized,
      cardId: 'funnel',
      contentType: 'onboarding',
    );
  }

  Future<void> trackOnboardingStepViewed({
    required String stepId,
    required String phase,
  }) async {
    await _mpTrack(
      'onboarding_step_viewed',
      properties: {
        'step_id': _sanitizeName(stepId),
        'phase': _sanitizeName(phase, fallback: 'ask'),
      },
    );
  }

  Future<void> trackOnboardingStepAnswered({
    required String stepId,
    required List<String> answerIds,
  }) async {
    final answers = answerIds
        .map((id) => _sanitizeName(id))
        .where((id) => id != 'unknown')
        .take(8)
        .toList();
    await _mpTrack(
      'onboarding_step_answered',
      properties: {
        'step_id': _sanitizeName(stepId),
        'answer_count': answers.length,
        if (answers.isNotEmpty) 'answer_ids': answers.join(','),
      },
    );
  }

  Future<void> trackOnboardingSkipped({required String fromStep}) async {
    await _logBoth(
      'onboarding_skipped',
      properties: {'from_step': _sanitizeName(fromStep)},
    );
    _signal(
      eventType: 'onboarding_skip',
      screen: 'onboarding',
      sectionId: _sanitizeName(fromStep),
      cardId: 'funnel',
      contentType: 'onboarding',
    );
  }

  Future<void> trackOnboardingCompleted({
    required int answeredCount,
    required bool skipped,
    String? entry,
    String? personaId,
    List<String>? favoriteCuisines,
    List<String>? goals,
    List<String>? avoidedIngredients,
    String? preferredMarketplace,
    int? householdServings,
  }) async {
    final sanitizedEntry = _sanitizeName(entry ?? 'signup', fallback: 'signup');
    await _logBoth(
      'onboarding_completed',
      properties: {
        'answered_count': answeredCount,
        'skipped': skipped ? 1 : 0,
        'entry': sanitizedEntry,
        if (personaId != null) 'persona': _sanitizeName(personaId),
      },
    );
    unawaited(
      logCardEvent(
        skipped ? 'onboarding_skip' : 'onboarding_complete',
        screen: 'onboarding',
        sectionId: sanitizedEntry,
        cardId: personaId == null ? 'funnel' : _sanitizeName(personaId),
        contentType: 'onboarding',
        recipeCuisineType: favoriteCuisines,
        recipeTags: goals,
        recipeIngredientCategories: avoidedIngredients,
        marketplace: preferredMarketplace,
        recipeServings: householdServings,
      ),
    );
  }

  Future<void> setOnboardingPeopleTraits({
    String? gender,
    String? ageGroup,
    String? cookingFrequency,
    String? cookingSkill,
    String? householdSize,
    List<String>? goals,
    List<String>? favoriteCuisines,
    List<String>? avoidedIngredients,
    List<String>? dietRestrictions,
    List<String>? recipeSources,
    String? preferredMarketplace,
    List<String>? preferredMarketplaces,
    String? shoppingStyle,
    List<String>? shoppingPriorities,
    String? personaId,
  }) async {
    String joinIds(List<String> values, {int take = 8}) {
      return values
          .map(_sanitizeName)
          .where((id) => id != 'unknown')
          .take(take)
          .join(',');
    }

    final people = <String, Object>{
      'onboarding_completed': true,
      if (gender != null) 'onboarding_gender': _sanitizeName(gender),
      if (ageGroup != null) 'onboarding_age_group': _sanitizeName(ageGroup),
      if (cookingFrequency != null)
        'onboarding_cooking_frequency': _sanitizeName(cookingFrequency),
      if (cookingSkill != null)
        'onboarding_cooking_skill': _sanitizeName(cookingSkill),
      if (householdSize != null)
        'onboarding_household_size': _sanitizeName(householdSize),
      if (goals != null && goals.isNotEmpty) 'onboarding_goals': joinIds(goals),
      if (favoriteCuisines != null && favoriteCuisines.isNotEmpty)
        'onboarding_cuisines': joinIds(favoriteCuisines),
      if (avoidedIngredients != null && avoidedIngredients.isNotEmpty)
        'onboarding_avoided': joinIds(avoidedIngredients),
      if (dietRestrictions != null && dietRestrictions.isNotEmpty)
        'onboarding_diet_restrictions': joinIds(dietRestrictions),
      if (recipeSources != null && recipeSources.isNotEmpty)
        'onboarding_recipe_sources': joinIds(recipeSources, take: 10),
      if (personaId != null) 'onboarding_persona': _sanitizeName(personaId),
      if (preferredMarketplace != null)
        'onboarding_marketplace': _sanitizeName(preferredMarketplace),
      if (preferredMarketplaces != null && preferredMarketplaces.isNotEmpty)
        'onboarding_marketplaces': joinIds(preferredMarketplaces),
      if (shoppingStyle != null)
        'onboarding_shopping_style': _sanitizeName(shoppingStyle),
      if (shoppingPriorities != null && shoppingPriorities.isNotEmpty)
        'onboarding_shopping_priorities': joinIds(shoppingPriorities),
    };
    await _mpPeopleSetAll(people);

    await Future.wait(<Future<void>>[
      _setFaUserProperty('ob_done', '1'),
      _setFaUserProperty(
        'ob_persona',
        personaId == null ? null : _sanitizeName(personaId),
      ),
      _setFaUserProperty(
        'ob_age_group',
        ageGroup == null ? null : _sanitizeName(ageGroup),
      ),
      _setFaUserProperty(
        'ob_gender',
        gender == null ? null : _sanitizeName(gender),
      ),
      _setFaUserProperty(
        'ob_household',
        householdSize == null ? null : _sanitizeName(householdSize),
      ),
    ]);

    await _initMixpanelIfNeeded();
    final Mixpanel? mp = _mixpanel;
    if (mp != null) {
      try {
        mp.registerSuperProperties(<String, dynamic>{
          'onboarding_completed': true,
          if (personaId != null)
            'onboarding_persona': _sanitizeName(personaId),
          if (ageGroup != null)
            'onboarding_age_group': _sanitizeName(ageGroup),
        });
      } catch (e) {
        print('[AnalyticsService] Mixpanel onboarding super props: $e');
      }
    }
  }

  /// Dual-write helper: Firebase Analytics + Mixpanel with the same props.
  Future<void> _logBoth(
    String eventName, {
    Map<String, Object?>? properties,
  }) async {
    await initialize();
    final Map<String, Object> firebaseParams = <String, Object>{};
    if (properties != null) {
      for (final MapEntry<String, Object?> e in properties.entries) {
        if (e.value != null) {
          firebaseParams[e.key] = e.value as Object;
        }
      }
    }
    try {
      await _analytics?.logEvent(
        name: eventName,
        parameters: firebaseParams.isEmpty ? null : firebaseParams,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking $eventName (Firebase): $e');
    }
    await _mpTrack(eventName, properties: properties);
  }

  Future<void> trackLogin({required String method}) async {
    final String m = _sanitizeName(method);
    await _logBoth('login', properties: {'login_method': m});
    await _mpPeopleSet('last_login_method', m);
  }

  Future<void> trackLogout() async {
    await _logBoth('logout');
  }

  Future<void> trackPasswordResetRequested() async {
    await _logBoth('password_reset_requested');
  }

  Future<void> trackAccountDeleted() async {
    await _logBoth('account_deleted');
    await _mpPeopleSet('account_deleted', true);
  }

  Future<void> trackRecipeViewed({
    required String recipeId,
    String? platform,
    String? sourceScreen,
  }) async {
    final resolvedSource = resolveRecipeViewSource(
      fallback: sourceScreen ?? 'recipe_detail',
      recipeId: recipeId,
      pendingRecipeId: _pendingRecipeOpenId,
      pendingScreen: _pendingRecipeOpenScreen,
    );
    final sectionId = (_pendingRecipeOpenId == recipeId.trim())
        ? (_pendingRecipeOpenSection ?? 'recipe_view')
        : 'recipe_view';
    setCurrentRecipeContext(recipeId);
    await _logBoth(
      'recipe_viewed',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'source_screen': _sanitizeName(resolvedSource),
        ..._legacyContentPlatformProps(platform),
        if (sectionId.trim().isNotEmpty) 'section_id': _sanitizeName(sectionId),
      },
    );
    _signal(
      eventType: 'view',
      screen: 'recipe_detail',
      sectionId: sectionId,
      cardId: recipeId,
      contentType: 'recipe',
      recipeId: recipeId,
      recipeSourcePlatform: platform,
      sourceScreen: resolvedSource,
    );
    // 동일 레시피는 하루 1번만 EXP 인정 (idempotency key에 day+recipeId 포함).
    unawaited(
      RewardsService.instance.claim(
        'exp_recipe_viewed',
        idempotencyKey: 'exp_recipe_viewed:$recipeId:${_rewardsDayKey()}',
      ),
    );
  }

  Future<void> trackCookingStarted({
    required String? recipeId,
    String sourceScreen = 'recipe_detail',
  }) async {
    await _logBoth(
      'cooking_started',
      properties: {
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        'source_screen': _sanitizeName(sourceScreen),
      },
    );
    final key = (recipeId != null && recipeId.trim().isNotEmpty)
        ? recipeId.trim()
        : DateTime.now().millisecondsSinceEpoch.toString();
    unawaited(
      RewardsService.instance.claim(
        'exp_cooking_started',
        idempotencyKey: 'exp_cooking_started:$key:${_rewardsDayKey()}',
      ),
    );
  }

  Future<void> trackCookingCompleted({
    required String? recipeId,
    String sourceScreen = 'fridge',
    bool writeGcs = true,
  }) async {
    await _logBoth(
      'cooking_completed',
      properties: {
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        'source_screen': _sanitizeName(sourceScreen),
      },
    );
    if (writeGcs && recipeId != null && recipeId.trim().isNotEmpty) {
      _signal(
        eventType: 'cook_done',
        screen: sourceScreen,
        sectionId: 'cook_complete',
        cardId: recipeId,
        contentType: 'recipe',
        recipeId: recipeId,
      );
    }
    // 조리 시트 Mixpanel 전용 호출(writeGcs: false)은 카운터/EXP를 건드리지 않는다.
    // 냉장고 요리완료가 기존 성공 라벨이다.
    if (!writeGcs) return;
    await _mpPeopleIncrement('cookingCompletedCount', 1);
    final key = (recipeId != null && recipeId.trim().isNotEmpty)
        ? recipeId.trim()
        : DateTime.now().millisecondsSinceEpoch.toString();
    unawaited(
      RewardsService.instance.claim(
        'exp_cooking_completed',
        idempotencyKey: 'exp_cooking_completed:$key:${_rewardsDayKey()}',
      ),
    );
  }

  Future<void> trackSearchOpened({String sourceScreen = 'home'}) async {
    await _logBoth(
      'search_opened',
      properties: {'source_screen': _sanitizeName(sourceScreen)},
    );
    _signal(
      eventType: 'click',
      screen: sourceScreen,
      sectionId: 'search_open',
      cardId: 'search',
      contentType: 'search',
    );
    unawaited(
      RewardsService.instance.claim(
        'exp_search',
        idempotencyKey:
            'exp_search:${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
  }

  /// 검색어 입력(디바운스 후). 개인화는 cardId=쿼리.
  Future<void> trackSearchQuery({required String query}) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final clipped = _truncateValue(q, fallback: 'unknown');
    await _logBoth(
      'search_query_submitted',
      properties: {'query': clipped},
    );
    _signal(
      eventType: 'click',
      screen: 'recipe_search',
      sectionId: 'search_query',
      cardId: clipped,
      contentType: 'search',
    );
  }

  Future<void> trackAddRecipeOpened({
    String source = 'home',
    bool hasInitialUrl = false,
  }) async {
    await _logBoth(
      'add_recipe_opened',
      properties: {
        'source': _sanitizeName(source),
        'has_initial_url': hasInitialUrl ? 1 : 0,
      },
    );
  }

  Future<void> trackNotificationsOpened() async {
    await _logBoth('notifications_opened');
    _signal(
      eventType: 'click',
      screen: 'notification',
      sectionId: 'notification_open',
      cardId: 'notifications',
      contentType: 'notification',
    );
  }

  Future<void> trackNotificationTapped({
    required String type,
    bool isActionable = true,
  }) async {
    await _logBoth(
      'notification_tapped',
      properties: {
        'notification_type': _sanitizeName(type),
        'is_actionable': isActionable ? 1 : 0,
      },
    );
    _signal(
      eventType: 'click',
      screen: 'notification',
      sectionId: 'notification_tap',
      cardId: type,
      contentType: 'notification',
    );
  }

  Future<void> trackFridgeIngredientAdded({
    required int itemCount,
    String method = 'manual',
    List<String>? ingredientNames,
    List<String?>? recipeIds,
  }) async {
    final rawNames = ingredientNames ?? const <String>[];
    final rawIds = recipeIds ?? const <String?>[];
    final rows = <({String name, String? recipeId})>[];
    for (var i = 0; i < rawNames.length; i++) {
      final name = rawNames[i].trim();
      if (name.isEmpty) continue;
      final rawId = i < rawIds.length ? (rawIds[i]?.trim() ?? '') : '';
      final recipeId =
          (rawId.isEmpty ||
              rawId == 'unknown' ||
              rawId.startsWith('manual_'))
          ? null
          : rawId;
      rows.add((name: name, recipeId: recipeId));
    }
    final uniqueRecipeIds = <String>{
      for (final row in rows)
        if (row.recipeId != null) row.recipeId!,
    };
    final singleRecipeId =
        uniqueRecipeIds.length == 1 ? uniqueRecipeIds.first : null;
    final methodKey = _sanitizeName(method, fallback: 'manual');

    await _logBoth(
      'fridge_ingredient_added',
      properties: {
        'item_count': itemCount > 0 ? itemCount : 1,
        'method': methodKey,
        if (singleRecipeId != null) 'recipe_id': singleRecipeId,
      },
    );
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      // 재료별은 Mixpanel + GCS만. FA는 사용자당 일일 한도에 재료 수만큼 쌓인다.
      await _mpTrack(
        'fridge_ingredient_item_added',
        properties: {
          'ingredient_name': _truncateValue(row.name, fallback: 'unknown'),
          'method': methodKey,
          'position': i,
          if (row.recipeId != null) 'recipe_id': row.recipeId,
        },
      );
      _signal(
        eventType: 'fridge_add',
        screen: methodKey == 'cart' ? 'cart' : 'fridge',
        sectionId: 'fridge_add',
        cardId: row.name,
        contentType: 'fridge_ingredient',
        ingredientName: row.name,
        recipeId: row.recipeId,
        sourceScreen: methodKey,
        position: i,
      );
    }
    await _mpPeopleIncrement('fridgeAddCount', itemCount > 0 ? itemCount.toDouble() : 1);
    // 장바구니 구매완료→냉장고는 별도 구매 이벤트와 겹치므로 경험치 클레임은 수동 추가만.
    if (methodKey != 'cart') {
      unawaited(
        RewardsService.instance.claim(
          'exp_fridge_ingredient_added',
          idempotencyKey:
              'exp_fridge_ingredient_added:${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
    }
  }

  /// 냉장고 재료로 추천을 돌릴 때, 고른 재료를 개인화 시그널로 남긴다.
  Future<void> trackFridgeRecommendationRun({
    required List<String> ingredientNames,
  }) async {
    final names = [
      for (final name in ingredientNames)
        if (name.trim().isNotEmpty) name.trim(),
    ];
    if (names.isEmpty) return;
    await _logBoth(
      'fridge_recommendation_run',
      properties: {'ingredient_count': names.length},
    );
    for (var i = 0; i < names.length; i++) {
      _signal(
        eventType: 'click',
        screen: 'fridge',
        sectionId: 'fridge_recommendation_input',
        cardId: names[i],
        contentType: 'fridge_ingredient',
        ingredientName: names[i],
        position: i,
      );
    }
  }

  Future<void> trackUserFollowed({required String targetUserId}) async {
    unawaited(
      RewardsService.instance.claim(
        'exp_follow',
        idempotencyKey: 'exp_follow:$targetUserId',
      ),
    );
    await _logBoth(
      'user_followed',
      properties: {
        'target_user_id': _truncateValue(targetUserId, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'like',
      screen: 'profile',
      sectionId: 'follow',
      cardId: targetUserId,
      contentType: 'user',
    );
    await _mpPeopleIncrement('followCount', 1);
  }

  Future<void> trackUserUnfollowed({required String targetUserId}) async {
    await _logBoth(
      'user_unfollowed',
      properties: {
        'target_user_id': _truncateValue(targetUserId, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'unlike',
      screen: 'profile',
      sectionId: 'unfollow',
      cardId: targetUserId,
      contentType: 'user',
    );
  }

  Future<void> trackMainTabSelected({
    required int index,
    required String tabName,
  }) async {
    await _logBoth(
      'main_tab_selected',
      properties: {
        'tab_index': index,
        'tab_name': _sanitizeName(tabName),
      },
    );
    _signal(
      eventType: 'click',
      screen: 'main',
      sectionId: 'main_tab',
      cardId: tabName,
      contentType: 'main_tab',
      position: index,
    );
  }

  /// 레시피 상세 탭 전환 (재료 / 요리법 / 영양정보).
  /// 포인트/EXP claim은 넣지 않음 (탭 전환만 트래킹).
  Future<void> trackRecipeDetailTabSelected({
    required int tabIndex,
    required String tabName,
    String? recipeId,
    int? previousTabIndex,
    String? previousTabName,
    String method = 'unknown',
  }) async {
    await _logBoth(
      'recipe_detail_tab_selected',
      properties: {
        'tab_index': tabIndex,
        'tab_name': _sanitizeName(tabName),
        'method': _sanitizeName(method, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        if (previousTabIndex != null) 'previous_tab_index': previousTabIndex,
        if (previousTabName != null && previousTabName.trim().isNotEmpty)
          'previous_tab_name': _sanitizeName(previousTabName),
      },
    );
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'recipe_detail_tab',
      cardId: tabName,
      contentType: 'tab',
      recipeId: recipeId,
      position: tabIndex,
    );
  }

  Future<void> trackMealCalendarOpened({String sourceScreen = 'home'}) async {
    await _logBoth(
      'meal_calendar_opened',
      properties: {'source_screen': _sanitizeName(sourceScreen)},
    );
    _signal(
      eventType: 'click',
      screen: sourceScreen,
      sectionId: 'meal_calendar_open',
      cardId: 'meal_calendar',
      contentType: 'meal_plan',
    );
  }

  Future<void> trackRecipeShared({
    required String recipeId,
    String sourceScreen = 'recipe_detail',
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'recipe_shared',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'source_screen': _sanitizeName(sourceScreen),
      },
    );
    _signal(
      eventType: 'share',
      screen: sourceScreen,
      sectionId: 'recipe_share',
      cardId: id,
      contentType: 'recipe',
      recipeId: id,
    );
  }

  Future<void> trackFridgeIngredientsRemoved({
    required List<String> ingredientNames,
  }) async {
    final names = [
      for (final name in ingredientNames)
        if (name.trim().isNotEmpty) name.trim(),
    ];
    if (names.isEmpty) return;
    await _logBoth(
      'fridge_ingredient_removed',
      properties: {'item_count': names.length},
    );
    for (var i = 0; i < names.length; i++) {
      _signal(
        eventType: 'remove',
        screen: 'fridge',
        sectionId: 'fridge_remove',
        cardId: names[i],
        contentType: 'fridge_ingredient',
        ingredientName: names[i],
        position: i,
      );
    }
  }

  Future<void> trackCartItemsRemoved({
    required String recipeId,
    int? itemCount,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'cart_items_removed',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        if (itemCount != null) 'item_count': itemCount,
      },
    );
    _signal(
      eventType: 'remove',
      screen: 'cart',
      sectionId: 'cart_remove',
      cardId: id,
      contentType: 'recipe',
      recipeId: id,
    );
  }

  Future<void> trackMealPlanCompleted({
    required String recipeId,
    required String mealTime,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'meal_plan_completed',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'meal_time': _sanitizeName(mealTime, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'meal_complete',
      screen: 'meal_plan',
      sectionId: 'meal_plan_$mealTime',
      cardId: id,
      contentType: 'meal_plan',
      recipeId: id,
    );
  }

  Future<void> trackMealPlanRemoved({
    required String recipeId,
    required String mealTime,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'meal_plan_removed',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'meal_time': _sanitizeName(mealTime, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'remove',
      screen: 'meal_plan',
      sectionId: 'meal_plan_$mealTime',
      cardId: id,
      contentType: 'meal_plan',
      recipeId: id,
    );
  }

  Future<void> trackSearchEmpty({required String query}) async {
    final clipped = _truncateValue(query, fallback: 'unknown');
    await _logBoth(
      'search_empty',
      properties: {'query': clipped},
    );
    _signal(
      eventType: 'search_empty',
      screen: 'recipe_search',
      sectionId: 'search_empty',
      cardId: clipped,
      contentType: 'search',
    );
  }

  Future<void> trackRecipeOverlayEdited({
    required String recipeId,
    required String editType,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'recipe_overlay_edited',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'edit_type': _sanitizeName(editType, fallback: 'edit'),
      },
    );
    _signal(
      eventType: 'edit',
      screen: 'recipe_detail',
      sectionId: 'overlay_$editType',
      cardId: id,
      contentType: 'recipe_overlay',
      recipeId: id,
    );
  }

  Future<void> trackRecipebookCategoryAssigned({
    required String recipeId,
    required int categoryCount,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'recipebook_category_assigned',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'category_count': categoryCount,
      },
    );
    _signal(
      eventType: 'folder',
      screen: 'recipe_detail',
      sectionId: 'recipebook_category',
      cardId: id,
      contentType: 'recipebook_folder',
      recipeId: id,
    );
  }

  Future<void> trackVideoPlay({
    required String recipeId,
    String screen = 'recipe_detail',
    String platform = 'youtube',
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty) return;
    await _logBoth(
      'recipe_video_played',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'source_screen': _sanitizeName(screen),
        ..._legacyContentPlatformProps(platform),
      },
    );
    _signal(
      eventType: 'play',
      screen: screen,
      sectionId: 'video_play',
      cardId: id,
      contentType: 'video',
      recipeId: id,
      recipeSourcePlatform: platform,
    );
  }

  Future<void> trackVideoWatchEnded({
    required String recipeId,
    required int durationMs,
    String screen = 'recipe_detail',
    String platform = 'youtube',
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty || durationMs < 1000) return;
    await _logBoth(
      'recipe_video_watch_ended',
      properties: {
        'recipe_id': _truncateValue(id, fallback: 'unknown'),
        'duration_seconds': (durationMs / 1000).round(),
        'source_screen': _sanitizeName(screen),
        ..._legacyContentPlatformProps(platform),
      },
    );
    _signal(
      eventType: 'dwell',
      screen: screen,
      sectionId: 'video_watch',
      cardId: id,
      contentType: 'video',
      recipeId: id,
      recipeSourcePlatform: platform,
      durationMs: durationMs,
    );
  }

  Future<void> trackCookingStepDwell({
    required String recipeId,
    required int stepIndex,
    required int durationMs,
    String? contentType,
  }) async {
    final id = recipeId.trim();
    if (id.isEmpty || durationMs < 1000) return;
    _signal(
      eventType: 'dwell',
      screen: 'cooking_mode',
      sectionId: 'cooking_step',
      cardId: 'step_$stepIndex',
      contentType: contentType ?? 'cooking_step',
      recipeId: id,
      position: stepIndex,
      durationMs: durationMs,
    );
  }

  Future<void> trackShareExtensionOpened() async {
    await _logBoth('share_extension_opened');
  }

  Future<void> trackParsingRequested({
    required String platform,
    required bool isAuthenticated,
    bool isRetry = false,
    String parsePath = 'unknown',
  }) async {
    await initialize();

    try {
      final params = <String, Object>{
        ..._legacyContentPlatformProps(platform),
        'is_authenticated': isAuthenticated ? 1 : 0,
        'parse_path': _sanitizeName(parsePath, fallback: 'unknown'),
      };
      if (isRetry) params['is_retry'] = 1;
      await _analytics?.logEvent(
        name: 'parsing_request_started',
        parameters: params,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking parsing request: $e');
    }
    await _mpTrack(
      'parsing_request_started',
      properties: {
        ..._legacyContentPlatformProps(platform),
        'is_authenticated': isAuthenticated ? 1 : 0,
        'parse_path': _sanitizeName(parsePath, fallback: 'unknown'),
        if (isRetry) 'is_retry': 1,
      },
    );
  }

  /// 파싱 요청 시 동일 URL 의 기존 레시피가 이미 DB 에 존재하여 dedup 처리됨
  Future<void> trackRecipeDedupFound({
    required String platform,
    required bool isAuthenticated,
  }) async {
    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'recipe_dedup_found',
        parameters: {
          ..._legacyContentPlatformProps(platform),
          'is_authenticated': isAuthenticated ? 1 : 0,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking recipe dedup: $e');
    }
    await _mpTrack(
      'recipe_dedup_found',
      properties: {
        ..._legacyContentPlatformProps(platform),
        'is_authenticated': isAuthenticated ? 1 : 0,
      },
    );
  }

  Future<void> trackParsingCompleted({
    required String platform,
    required int ingredientCount,
    required int stepCount,
    required bool savedToCloud,
    int? durationMs,
    String? recipeId,
    String parsePath = 'sse',
  }) async {
    await initialize();

    try {
      final parameters = <String, Object>{
        ..._legacyContentPlatformProps(platform),
        'ingredient_count': ingredientCount,
        'step_count': stepCount,
        'saved_to_cloud': savedToCloud ? 1 : 0,
        'parse_path': _sanitizeName(parsePath, fallback: 'sse'),
      };
      if (durationMs != null && durationMs >= 0) {
        parameters['parse_time_ms'] = durationMs;
        parameters['parse_time_sec'] = (durationMs / 1000).round();
      }

      await _analytics?.logEvent(
        name: 'recipe_parsing_completed',
        parameters: parameters,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking parsing completion: $e');
    }
    await _mpTrack(
      'recipe_parsing_completed',
      properties: {
        ..._legacyContentPlatformProps(platform),
        'ingredient_count': ingredientCount,
        'step_count': stepCount,
        'saved_to_cloud': savedToCloud ? 1 : 0,
        'parse_path': _sanitizeName(parsePath, fallback: 'sse'),
        if (durationMs != null && durationMs >= 0) 'parse_time_ms': durationMs,
        if (durationMs != null && durationMs >= 0)
          'parse_time_sec': (durationMs / 1000).round(),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
      },
    );
    final parsedId = recipeId?.trim() ?? '';
    if (parsedId.isNotEmpty) {
      _signal(
        eventType: 'parse',
        screen: 'parse',
        sectionId: 'recipe_parse',
        cardId: parsedId,
        contentType: 'recipe_parse',
        recipeId: parsedId,
        recipeSourcePlatform: platform,
      );
    }
    if (savedToCloud) {
      unawaited(
        RewardsService.instance.claim(
          'exp_recipe_parsed',
          idempotencyKey:
              'exp_recipe_parsed:${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
    }
  }

  /// 레시피 파싱 실패 (백엔드 오류, 저장 실패, 재시도 소진 등)
  Future<void> trackParsingFailed({
    required String platform,
    required bool savedToCloud,
    required String errorMessage,
    String errorType = 'server_error',
    String parsePath = 'unknown',
  }) async {
    await initialize();

    final String err = _truncateValue(errorMessage, fallback: 'unknown');
    final String et = _sanitizeName(errorType, fallback: 'server_error');
    final String path = _sanitizeName(parsePath, fallback: 'unknown');
    try {
      await _analytics?.logEvent(
        name: 'recipe_parsing_failed',
        parameters: {
          ..._legacyContentPlatformProps(platform),
          'saved_to_cloud': savedToCloud ? 1 : 0,
          'error': err,
          'error_type': et,
          'parse_path': path,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking parsing failure: $e');
    }
    await _mpTrack(
      'recipe_parsing_failed',
      properties: {
        ..._legacyContentPlatformProps(platform),
        'saved_to_cloud': savedToCloud ? 1 : 0,
        'error': err,
        'error_type': et,
        'parse_path': path,
      },
    );
    _signal(
      eventType: 'parse_fail',
      screen: 'parse',
      sectionId: 'recipe_parse',
      cardId: et,
      contentType: 'recipe_parse',
      recipeSourcePlatform: platform,
    );
  }

  Future<void> trackIngredientPurchaseChecked({
    required String ingredientName,
    required bool isChecked,
    String? category,
    String? marketplace,
    String? recipeId,
  }) async {
    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'ingredient_purchase_checked',
        parameters: {
          'ingredient_name': _truncateValue(
            ingredientName,
            fallback: 'unknown',
          ),
          'checked': isChecked ? 1 : 0,
          if (category != null && category.trim().isNotEmpty)
            'category': _truncateValue(category, fallback: 'unknown'),
          if (category != null && category.trim().isNotEmpty)
            'category_id': stableAnalyticsId(category),
          if (marketplace != null && marketplace.trim().isNotEmpty)
            'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
          if (recipeId != null && recipeId.trim().isNotEmpty)
            'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking ingredient purchase check: $e');
    }
    await _mpTrack(
      'ingredient_purchase_checked',
      properties: {
        'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
        'checked': isChecked ? 1 : 0,
        if (category != null && category.trim().isNotEmpty)
          'category': _truncateValue(category, fallback: 'unknown'),
        if (category != null && category.trim().isNotEmpty)
          'category_id': stableAnalyticsId(category),
        if (marketplace != null && marketplace.trim().isNotEmpty)
          'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
      },
    );
    // GCS check/uncheck는 trackProductCheckEvent 한 곳에서만 남긴다.
    // 여기에도 쓰면 로그인 유저 체크 1회가 학습 시그널 2줄이 된다.
  }

  /// Store a raw product check/uncheck event for spreadsheet export.
  Future<void> trackProductCheckEvent({
    required String userId,
    required String ingredientName,
    required bool isChecked,
    required String marketplace,
    String? category,
    String? recipeId,
    String? platformProductName,
    int? price,
    String? productId,
    String? productUrl,
    String? originalUrl,
    String? deeplinkUrl,
    double? packageSize,
    String? packageUnit,
    double? unitPrice,
    double? rating,
    int? reviews,
    double? matchScore,
  }) async {
    final uid = userId.trim();
    final ingredient = ingredientName.trim();
    if (uid.isEmpty || ingredient.isEmpty) {
      return;
    }

    final normalizedMarketplace = _sanitizeName(
      marketplace,
      fallback: 'unknown',
    );

    final recipeIdText = recipeId?.trim();
    final productIdText = productId?.trim();

    // Firestore 서브컬렉션에 체크마다 문서를 쌓지 않는다. GCS 시그널만 남긴다.
    unawaited(
      logCardEvent(
        isChecked ? 'check' : 'uncheck',
        screen: 'cart',
        sectionId: 'product_check',
        cardId: (productIdText != null && productIdText.isNotEmpty)
            ? productIdText
            : ingredient,
        contentType: 'product',
        recipeId: (recipeIdText != null && recipeIdText.isNotEmpty)
            ? recipeIdText
            : null,
        ingredientName: ingredient,
        ingredientCategory: category,
        marketplace: normalizedMarketplace,
        productId: (productIdText != null && productIdText.isNotEmpty)
            ? productIdText
            : null,
        price: price,
        productRating: rating,
        productReviewCount: reviews,
        productUnitPrice: unitPrice,
        productPackageSize: packageSize,
        productPackageUnit: packageUnit,
      ),
    );
  }

  Future<void> trackPurchaseCompleted({
    required int ingredientCount,
    required int recipeCount,
    int totalExpenditure = 0,
    int coupangExpenditure = 0,
    int kurlyExpenditure = 0,
    List<String>? recipeIds,
  }) async {
    await initialize();

    final ids = <String>[
      for (final raw in recipeIds ?? const <String>[])
        if (raw.trim().isNotEmpty &&
            raw.trim() != 'unknown' &&
            !raw.trim().startsWith('manual_'))
          raw.trim(),
    ];
    final singleRecipeId = ids.length == 1 ? ids.first : null;

    try {
      final int total = totalExpenditure >= 0 ? totalExpenditure : 0;
      final int coupang = coupangExpenditure >= 0 ? coupangExpenditure : 0;
      final int kurly = kurlyExpenditure >= 0 ? kurlyExpenditure : 0;
      await _analytics?.logEvent(
        name: 'cart_purchase_completed',
        parameters: {
          'ingredient_count': ingredientCount,
          'recipe_count': recipeCount,
          'total_expenditure': total,
          'coupang_expenditure': coupang,
          'kurly_expenditure': kurly,
          if (singleRecipeId != null) 'recipe_id': singleRecipeId,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking purchase completion: $e');
    }
    await _mpTrack(
      'cart_purchase_completed',
      properties: {
        'ingredient_count': ingredientCount,
        'recipe_count': recipeCount,
        'total_expenditure': totalExpenditure >= 0 ? totalExpenditure : 0,
        'coupang_expenditure': coupangExpenditure >= 0 ? coupangExpenditure : 0,
        'kurly_expenditure': kurlyExpenditure >= 0 ? kurlyExpenditure : 0,
        if (singleRecipeId != null) 'recipe_id': singleRecipeId,
      },
    );
    _signal(
      eventType: 'purchase',
      screen: 'cart',
      sectionId: 'purchase_complete',
      cardId: singleRecipeId ?? 'cart_purchase',
      contentType: 'cart',
      recipeId: singleRecipeId,
      price: totalExpenditure >= 0 ? totalExpenditure : null,
    );
  }

  /// Track when a user taps an affiliate link to open Coupang/Kurly.
  Future<void> trackAffiliateLinkClicked({
    required String marketplace,
    String? ingredientName,
    String? recipeId,
    String? productId,
    String? sourceScreen,
  }) async {
    final normalizedMarketplace = _sanitizeName(
      marketplace,
      fallback: 'unknown',
    );

    await _logBoth(
      'affiliate_link_clicked',
      properties: {
        'marketplace': normalizedMarketplace,
        if (ingredientName != null && ingredientName.trim().isNotEmpty)
          'ingredient_name': _truncateValue(
            ingredientName,
            fallback: 'unknown',
          ),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        if (productId != null && productId.trim().isNotEmpty)
          'product_id': _truncateValue(productId, fallback: 'unknown'),
        if (sourceScreen != null && sourceScreen.trim().isNotEmpty)
          'source_screen': _sanitizeName(sourceScreen),
      },
    );
    // Firestore 경유 기록은 UserService.logAffiliateVisit 가 하루 문서에 붙인다.
    // 장바구니·포스터는 호출측에서 더 풍부한 GCS 클릭을 이미 남긴다.
    // 밀키트는 제휴 클릭이지 구매 완료가 아니다.
    final source = sourceScreen?.trim() ?? '';
    if (source == 'meal_kit_picker') {
      _signal(
        eventType: 'click',
        screen: 'meal_kit_picker',
        sectionId: 'meal_kit',
        cardId: (productId != null && productId.trim().isNotEmpty)
            ? productId
            : ingredientName,
        contentType: 'product',
        recipeId: recipeId,
        ingredientName: ingredientName,
        marketplace: normalizedMarketplace,
        productId: productId,
      );
    }
  }

  /// 제휴 링크 실제 오픈 성공/실패. 클릭 이벤트와 분리해 CTR 왜곡을 줄인다.
  Future<void> trackAffiliateOpenResult({
    required String marketplace,
    required bool success,
    String? productId,
    String? ingredientName,
    String? recipeId,
    String? sourceScreen,
    String? failureReason,
    String? platform,
  }) async {
    await _logBoth(
      'affiliate_open_result',
      properties: {
        'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        'success': success ? 1 : 0,
        if (productId != null && productId.trim().isNotEmpty)
          'product_id': _truncateValue(productId, fallback: 'unknown'),
        if (ingredientName != null && ingredientName.trim().isNotEmpty)
          'ingredient_name': _truncateValue(
            ingredientName,
            fallback: 'unknown',
          ),
        if (sourceScreen != null && sourceScreen.trim().isNotEmpty)
          'source_screen': _sanitizeName(sourceScreen),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        if (failureReason != null && failureReason.trim().isNotEmpty)
          'failure_reason': _truncateValue(failureReason, fallback: 'unknown'),
        if (platform != null && platform.trim().isNotEmpty)
          'open_platform': _sanitizeName(platform),
      },
    );
  }

  /// 장바구니 쿠팡/컬리 탭 또는 스와이프 전환
  Future<void> trackCartMarketplaceSelected({
    required String marketplace,
    required String method,
    String? previousMarketplace,
  }) async {
    await _logBoth(
      'cart_marketplace_selected',
      properties: {
        'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        'method': _sanitizeName(method, fallback: 'unknown'),
        if (previousMarketplace != null &&
            previousMarketplace.trim().isNotEmpty)
          'previous_marketplace': _sanitizeName(
            previousMarketplace,
            fallback: 'unknown',
          ),
      },
    );
  }

  /// 「대체상품 보기」 시트 오픈
  Future<void> trackCartAlternativeProductsOpened({
    required String ingredientName,
    required String marketplace,
    required int candidateCount,
    String? recipeId,
  }) async {
    await _logBoth(
      'cart_alternative_products_opened',
      properties: {
        'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
        'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        'candidate_count': candidateCount < 0 ? 0 : candidateCount,
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
      },
    );
  }

  /// 대체상품 시트에서 다른 상품 선택
  Future<void> trackCartAlternativeProductSelected({
    required String ingredientName,
    required String marketplace,
    required String productId,
    int? price,
    int? rank,
    String? filter,
    String? sort,
    String? recipeId,
  }) async {
    await _logBoth(
      'cart_alternative_product_selected',
      properties: {
        'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
        'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        'product_id': _truncateValue(productId, fallback: 'unknown'),
        if (price != null && price >= 0) 'price': price,
        if (rank != null && rank >= 0) 'rank': rank,
        if (filter != null && filter.trim().isNotEmpty)
          'filter': _truncateValue(filter, fallback: 'unknown'),
        if (sort != null && sort.trim().isNotEmpty)
          'sort': _sanitizeName(sort, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
      },
    );
    _signal(
      eventType: 'click',
      screen: 'cart',
      sectionId: 'cart_alternative',
      cardId: productId,
      contentType: 'product',
      ingredientName: ingredientName,
      marketplace: marketplace,
      productId: productId,
      recipeId: recipeId,
      price: price,
      position: rank,
    );
  }

  /// 장바구니 재료 카드의 마켓 구매 버튼 클릭 (의도)
  Future<void> trackCartProductBuyClicked({
    required String ingredientName,
    required String marketplace,
    String? productId,
    String? productName,
    String? recipeId,
    int? price,
    String source = 'main_card',
  }) async {
    await _logBoth(
      'cart_product_buy_clicked',
      properties: {
        'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
        'marketplace': _sanitizeName(marketplace, fallback: 'unknown'),
        'source': _sanitizeName(source, fallback: 'main_card'),
        if (productId != null && productId.trim().isNotEmpty)
          'product_id': _truncateValue(productId, fallback: 'unknown'),
        if (productName != null && productName.trim().isNotEmpty)
          'product_name': _truncateValue(productName, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
        if (price != null && price >= 0) 'price': price,
      },
    );
  }

  /// 홈 상단 포스터 캐러셀 노출/클릭 (Mixpanel + GCS).
  /// posterId 는 CMS 문서 id (라벨이 바뀌어도 동일). position 은 CMS order.
  Future<void> trackHomePosterEvent({
    required String eventType,
    required String posterId,
    String? posterTitle,
    int? position,
    String? cmsUpdatedAt,
  }) async {
    await _logBoth(
      eventType == 'click' ? 'home_poster_clicked' : 'home_poster_impression',
      properties: {
        'poster_id': _sanitizeName(posterId, fallback: 'unknown'),
        if (posterTitle != null && posterTitle.trim().isNotEmpty)
          'poster_title': _truncateValue(posterTitle, fallback: 'unknown'),
        if (position != null && position >= 0) 'position': position,
        if (cmsUpdatedAt != null && cmsUpdatedAt.trim().isNotEmpty)
          'cms_updated_at': _truncateValue(cmsUpdatedAt, fallback: 'unknown'),
      },
    );
    unawaited(
      logCardEvent(
        eventType,
        screen: 'home',
        sectionId: 'poster_carousel',
        cardId: posterId,
        contentType: 'poster',
        position: position,
        posterId: posterId,
      ),
    );
  }

  /// 홈 추천/인기 탭 전환.
  Future<void> trackHomeFeedTabSelected({
    required int tabIndex,
    required String tabName,
  }) async {
    await _logBoth(
      'home_feed_tab_selected',
      properties: {
        'tab_index': tabIndex,
        'tab_name': _sanitizeName(tabName, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'click',
      screen: 'home',
      sectionId: 'feed_tab',
      cardId: tabName,
      contentType: 'feed_tab',
      position: tabIndex,
    );
  }

  /// 프로그램 큐레이션 칩 선택.
  Future<void> trackHomeProgramChipSelected({
    required String sectionKey,
    required String label,
    int? position,
    String? cmsUpdatedAt,
  }) async {
    await _logBoth(
      'home_program_chip_selected',
      properties: {
        'section_id': _sanitizeName(sectionKey, fallback: 'unknown'),
        'section_name': _truncateValue(label, fallback: 'unknown'),
        if (position != null && position >= 0) 'position': position,
        if (cmsUpdatedAt != null && cmsUpdatedAt.trim().isNotEmpty)
          'cms_updated_at': _truncateValue(cmsUpdatedAt, fallback: 'unknown'),
      },
    );
    unawaited(
      logCardEvent(
        'click',
        screen: 'home',
        sectionId: sectionKey,
        cardId: sectionKey,
        contentType: 'program',
        position: position,
      ),
    );
  }

  /// 레시피 상세 「함께 곁들이면 좋은」 칩 선택.
  Future<void> trackPairingChipSelected({
    required String laneId,
    required String label,
    int? position,
  }) async {
    await _logBoth(
      'pairing_chip_selected',
      properties: {
        'section_id': _sanitizeName(laneId, fallback: 'unknown'),
        'section_name': _truncateValue(label, fallback: 'unknown'),
        if (position != null && position >= 0) 'position': position,
      },
    );
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'pairing_chip',
      cardId: laneId,
      contentType: 'pairing',
      position: position,
    );
  }

  /// 레시피 상세 최적 재료 레일 → 장바구니 비교 CTA.
  Future<void> trackBestIngredientProductsCompareClicked({
    String? recipeId,
    String? marketplace,
  }) async {
    final id = recipeId?.trim() ?? '';
    final market = (marketplace ?? '').trim().toLowerCase();
    await _logBoth(
      'best_ingredient_products_compare_clicked',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
        'section_id': 'best_ingredient_products',
        if (market.isNotEmpty) 'marketplace': market,
      },
    );
    if (id.isEmpty) return;
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'best_ingredient_products',
      cardId: id,
      contentType: 'cart_compare_cta',
      recipeId: id,
    );
  }

  /// 상세 하단 연관/곁들임 레시피 클릭 (Mixpanel). GCS 클릭은 호출측 logCardEvent.
  Future<void> trackRelatedRecipeClicked({
    required String recipeId,
    required String sectionId,
    String? sectionName,
    int? cardIndex,
  }) async {
    noteRecipeOpenSource(
      recipeId: recipeId,
      screen: 'recipe_detail',
      sectionId: sectionId,
    );
    await _logBoth(
      'related_recipe_clicked',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'section_id': _sanitizeName(sectionId, fallback: 'unknown'),
        if (sectionName != null && sectionName.trim().isNotEmpty)
          'section_name': _truncateValue(sectionName, fallback: 'unknown'),
        if (cardIndex != null && cardIndex >= 0) 'card_index': cardIndex,
      },
    );
  }

  /// 레시피 상세 밀키트 시트 오픈.
  Future<void> trackMealKitPickerOpened({String? recipeId}) async {
    await _logBoth(
      'meal_kit_picker_opened',
      properties: {
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': recipeId.trim(),
      },
    );
    final id = recipeId?.trim() ?? '';
    if (id.isEmpty) return;
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'meal_kit',
      cardId: id,
      contentType: 'meal_kit',
      recipeId: id,
    );
  }

  /// 홈 레시피북 도크에서 저장 레시피 클릭 (Mixpanel). GCS는 호출측 logCardEvent.
  Future<void> trackRecipebookRecipeClicked({
    required String recipeId,
    String? viewMode,
  }) async {
    noteRecipeOpenSource(
      recipeId: recipeId,
      screen: 'home',
      sectionId: 'recipebook',
    );
    await _logBoth(
      'recipebook_recipe_clicked',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        if (viewMode != null && viewMode.trim().isNotEmpty)
          'view_mode': _sanitizeName(viewMode, fallback: 'unknown'),
      },
    );
  }

  /// 식단 추가 (라이브를 백필 meal_plan_add 와 맞춘다).
  Future<void> trackMealPlanAdded({
    required String recipeId,
    required String mealTime,
    String? recipeTitle,
  }) async {
    await _logBoth(
      'meal_plan_added',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'meal_time': _sanitizeName(mealTime, fallback: 'unknown'),
        if (recipeTitle != null && recipeTitle.trim().isNotEmpty)
          'recipe_title': _truncateValue(recipeTitle, fallback: 'unknown'),
      },
    );
    unawaited(
      logCardEvent(
        'click',
        screen: 'meal_plan',
        sectionId: 'meal_plan_$mealTime',
        cardId: recipeId,
        contentType: 'meal_plan_add',
        recipeId: recipeId,
      ),
    );
  }

  /// 홈 레시피북 pill / 1·2차 분류 필터 클릭
  Future<void> trackHomeCategoryClicked({
    required String source,
    String? categoryId,
    String? categoryName,
    int? position,
    String? posterId,
    String? cmsUpdatedAt,
  }) async {
    await _logBoth(
      'home_category_clicked',
      properties: {
        'source': _sanitizeName(source, fallback: 'unknown'),
        if (categoryId != null && categoryId.trim().isNotEmpty)
          'category_id': stableAnalyticsId(categoryId),
        if (categoryName != null && categoryName.trim().isNotEmpty)
          'category_name': _truncateValue(categoryName, fallback: 'unknown'),
        if (position != null && position >= 0) 'position': position,
        if (posterId != null && posterId.trim().isNotEmpty)
          'poster_id': _sanitizeName(posterId, fallback: 'unknown'),
        if (cmsUpdatedAt != null && cmsUpdatedAt.trim().isNotEmpty)
          'cms_updated_at': _truncateValue(cmsUpdatedAt, fallback: 'unknown'),
      },
    );
    final id = (categoryId != null && categoryId.trim().isNotEmpty)
        ? stableAnalyticsId(categoryId)
        : stableAnalyticsId(categoryName ?? 'unknown');
    _signal(
      eventType: 'click',
      screen: 'home',
      sectionId: source,
      cardId: id,
      contentType: 'category',
      position: position,
      posterId: posterId,
    );
  }

  /// 홈 트렌드/섹션 카드 클릭 (출처 포함).
  /// [sectionId] 는 CMS sectionKey / poster chip sectionKey 같은 안정 키.
  /// 한글 라벨은 [sectionName] 으로만 남긴다(CMS에서 카피가 바뀌어도 시계열 유지).
  Future<void> trackHomeRecipeClicked({
    required String recipeId,
    required String sectionId,
    String? sectionName,
    int? cardIndex,
    String? posterId,
    String? chipSectionKey,
    String? cmsUpdatedAt,
    String sourceScreen = 'home',
  }) async {
    noteRecipeOpenSource(
      recipeId: recipeId,
      screen: sourceScreen,
      sectionId: sectionId,
    );
    await _logBoth(
      'home_recipe_clicked',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'section_id': _sanitizeName(sectionId, fallback: 'unknown'),
        if (sectionName != null && sectionName.trim().isNotEmpty)
          'section_name': _truncateValue(sectionName, fallback: 'unknown'),
        if (cardIndex != null && cardIndex >= 0) 'card_index': cardIndex,
        if (posterId != null && posterId.trim().isNotEmpty)
          'poster_id': _sanitizeName(posterId, fallback: 'unknown'),
        if (chipSectionKey != null && chipSectionKey.trim().isNotEmpty)
          'chip_section_key': _sanitizeName(
            chipSectionKey,
            fallback: 'unknown',
          ),
        if (cmsUpdatedAt != null && cmsUpdatedAt.trim().isNotEmpty)
          'cms_updated_at': _truncateValue(cmsUpdatedAt, fallback: 'unknown'),
      },
    );
  }

  /// 홈 가로 캐러셀 스크롤 깊이 요약 (섹션 이탈 시 1회)
  Future<void> trackHomeSectionScrollSummary({
    required String sectionId,
    required int maxVisibleIndex,
    required int itemCount,
    String? sectionName,
    double? depthPercent,
  }) async {
    final int safeItemCount = itemCount < 0 ? 0 : itemCount;
    final int safeMaxIndex = maxVisibleIndex < 0 ? 0 : maxVisibleIndex;
    final double? safeDepth = depthPercent == null
        ? null
        : depthPercent.clamp(0, 100).toDouble();
    await _logBoth(
      'home_section_scroll_summary',
      properties: {
        'section_id': _sanitizeName(sectionId, fallback: 'unknown'),
        'max_visible_index': safeMaxIndex,
        'item_count': safeItemCount,
        if (sectionName != null && sectionName.trim().isNotEmpty)
          'section_name': _truncateValue(sectionName, fallback: 'unknown'),
        if (safeDepth != null) 'depth_percent': safeDepth.round(),
      },
    );
  }

  /// 홈 세로 스크롤 깊이 요약 (홈 이탈 시 1회)
  Future<void> trackHomeVerticalScrollSummary({
    required double maxDepthPercent,
    String? deepestSectionId,
    String? sessionId,
  }) async {
    await _logBoth(
      'home_vertical_scroll_summary',
      properties: {
        'max_depth_percent': maxDepthPercent.clamp(0, 100).round(),
        if (deepestSectionId != null && deepestSectionId.trim().isNotEmpty)
          'deepest_section_id': _sanitizeName(
            deepestSectionId,
            fallback: 'unknown',
          ),
        if (sessionId != null && sessionId.trim().isNotEmpty)
          'session_id': _truncateValue(sessionId, fallback: 'unknown'),
      },
    );
  }

  /// 홈 섹션 노출 (세션당 섹션 1회).
  /// 프로그램 블록은 [sectionId]=program_curation 과 칩 키를 같이 남긴다.
  Future<void> trackHomeSectionImpression({
    required String sectionId,
    String? sectionName,
    int? sectionOrder,
    int? visibleRecipeCount,
    String? cmsUpdatedAt,
    String? chipSectionKey,
  }) async {
    await _logBoth(
      'home_section_impression',
      properties: {
        'section_id': _sanitizeName(sectionId, fallback: 'unknown'),
        if (sectionName != null && sectionName.trim().isNotEmpty)
          'section_name': _truncateValue(sectionName, fallback: 'unknown'),
        if (sectionOrder != null && sectionOrder >= 0)
          'section_order': sectionOrder,
        if (visibleRecipeCount != null && visibleRecipeCount >= 0)
          'visible_recipe_count': visibleRecipeCount,
        if (cmsUpdatedAt != null && cmsUpdatedAt.trim().isNotEmpty)
          'cms_updated_at': _truncateValue(cmsUpdatedAt, fallback: 'unknown'),
        if (chipSectionKey != null && chipSectionKey.trim().isNotEmpty)
          'chip_section_key': _sanitizeName(
            chipSectionKey,
            fallback: 'unknown',
          ),
      },
    );
  }

  /// Track when >= 50% (rounded up) of a recipe's ingredients have been
  /// checked as purchased in the shopping cart.
  Future<void> trackCartMajorityChecked({
    required String recipeId,
    required String recipeName,
    required int totalIngredients,
    required int checkedCount,
    required int threshold,
  }) async {
    await initialize();

    final props = <String, Object>{
      'recipe_id': recipeId,
      'recipe_name': _truncateValue(recipeName, fallback: 'unknown'),
      'total_ingredients': totalIngredients,
      'checked_count': checkedCount,
      'threshold': threshold,
    };

    try {
      await _analytics?.logEvent(
        name: 'cart_majority_checked',
        parameters: props,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking cart majority checked: $e');
    }

    await _mpTrack('cart_majority_checked',
        properties: Map<String, dynamic>.from(props));
  }

  /// Track a single purchased ingredient for spend analysis dimensions.
  Future<void> trackIngredientPurchased({
    required String ingredientName,
    required int price,
    required String marketplace,
    String? category,
    String? recipeId,
  }) async {
    await initialize();

    final String normalizedMarketplace = _sanitizeName(
      marketplace,
      fallback: 'unknown',
    );
    final int safePrice = price >= 0 ? price : 0;
    final String normalizedCategoryName =
        (category == null || category.trim().isEmpty)
        ? 'unknown'
        : _truncateValue(category, fallback: 'unknown');
    final String normalizedCategoryId =
        (category == null || category.trim().isEmpty)
        ? 'unknown'
        : stableAnalyticsId(category);
    final String recipeIdText = recipeId?.trim() ?? '';
    final String? recipeIdValue =
        (recipeIdText.isEmpty ||
            recipeIdText == 'unknown' ||
            recipeIdText.startsWith('manual_'))
        ? null
        : recipeIdText;

    // 재료별은 Mixpanel만. FA는 구매완료 1회에 재료 수만큼 쌓여 일일 한도에 걸린다.
    await _mpTrack(
      'ingredient_purchased',
      properties: {
        'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
        'price': safePrice,
        'marketplace': normalizedMarketplace,
        'category': normalizedCategoryName,
        'category_id': normalizedCategoryId,
        if (recipeIdValue != null) 'recipe_id': recipeIdValue,
      },
    );
  }

  int _asIntCounter(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Apply dynamic expenditure delta from ingredient-level purchase toggles.
  /// Positive delta on check, negative delta on uncheck.
  Future<void> trackPurchaseSpendDeltaForUser(
    String userId, {
    required int totalDelta,
    int coupangDelta = 0,
    int kurlyDelta = 0,
  }) async {
    if (totalDelta == 0 && coupangDelta == 0 && kurlyDelta == 0) {
      return;
    }

    try {
      final userRef = _firestore.collection('users').doc(userId);
      await _firestore.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        final data = snap.data() ?? <String, dynamic>{};

        final currentTotal = _asIntCounter(data['purchaseTotalPrice']);
        final currentCoupang = _asIntCounter(data['purchaseTotalPriceCoupang']);
        final currentKurly = _asIntCounter(data['purchaseTotalPriceKurly']);

        final nextTotal = (currentTotal + totalDelta).clamp(0, 1 << 62);
        final nextCoupang = (currentCoupang + coupangDelta).clamp(0, 1 << 62);
        final nextKurly = (currentKurly + kurlyDelta).clamp(0, 1 << 62);

        tx.set(userRef, {
          'purchaseTotalPrice': nextTotal,
          'purchaseTotalPriceCoupang': nextCoupang,
          'purchaseTotalPriceKurly': nextKurly,
        }, SetOptions(merge: true));
      });
    } catch (e) {
      print('[AnalyticsService] Error tracking purchase spend delta: $e');
    }

    if (totalDelta != 0) {
      await _mpPeopleIncrement('purchaseTotalPrice', totalDelta.toDouble());
    }
    if (coupangDelta != 0) {
      await _mpPeopleIncrement(
        'purchaseTotalPriceCoupang',
        coupangDelta.toDouble(),
      );
    }
    if (kurlyDelta != 0) {
      await _mpPeopleIncrement('purchaseTotalPriceKurly', kurlyDelta.toDouble());
    }
  }

  /// Count an in-progress purchase session once per cart signature when
  /// purchased ratio reaches the threshold.
  Future<void> trackInProgressPurchaseSessionForUser(
    String userId, {
    required String cartSignature,
    required int purchasedCount,
    required int totalCount,
    double thresholdRatio = 0.25,
  }) async {
    if (cartSignature.trim().isEmpty) return;
    if (totalCount <= 0) return;
    final ratio = purchasedCount / totalCount;
    if (ratio < thresholdRatio) return;

    try {
      final userRef = _firestore.collection('users').doc(userId);
      bool incremented = false;
      await _firestore.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        final data = snap.data() ?? <String, dynamic>{};
        final lastSignature = (data['lastInProgressCartSignature'] as String?) ?? '';
        if (lastSignature == cartSignature) {
          return;
        }
        tx.set(userRef, {
          'hasInProgressPurchaseSession': true,
          'lastInProgressCartSignature': cartSignature,
          'inProgressPurchaseUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        incremented = true;
      });
      if (incremented) {
        await _mpPeopleSet('hasInProgressPurchaseSession', true);
      }
    } catch (e) {
      print('[AnalyticsService] Error tracking in-progress purchase session: $e');
    }
  }

  /// Recipe detail footer 「장바구니에 담기」 tap.
  Future<void> trackRecipeCartAddFooterClicked({String? recipeId}) async {
    await initialize();
    final props = <String, Object>{
      if (recipeId != null && recipeId.trim().isNotEmpty)
        'recipe_id': recipeId.trim(),
    };
    try {
      await _analytics?.logEvent(
        name: 'recipe_cart_add_footer_clicked',
        parameters: props,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking cart add footer click: $e');
    }
    await _mpTrack('recipe_cart_add_footer_clicked', properties: props);
    final id = recipeId?.trim() ?? '';
    if (id.isNotEmpty) {
      _signal(
        eventType: 'click',
        screen: 'recipe_detail',
        sectionId: 'cart_add_footer',
        cardId: id,
        contentType: 'cart_add_all',
        recipeId: id,
      );
    }
  }

  /// 재료 선택 시트에서 담기 확정. Mixpanel 요약·재료별 + GCS cart_add.
  Future<void> trackRecipeCartIngredientsAdded({
    required String recipeId,
    required List<String> ingredientNames,
    String source = 'recipe_detail',
  }) async {
    final id = recipeId.trim();
    final names = <String>[
      for (final raw in ingredientNames)
        if (raw.trim().isNotEmpty) raw.trim(),
    ];
    if (id.isEmpty || names.isEmpty) return;
    final sourceKey = _sanitizeName(source, fallback: 'recipe_detail');
    await _logBoth(
      'recipe_cart_ingredients_added',
      properties: {
        'recipe_id': id,
        'ingredient_count': names.length,
        'source': sourceKey,
      },
    );
    final gcsScreen = sourceKey == 'meal_plan' ? 'meal_calendar' : 'recipe_detail';
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      await _mpTrack(
        'recipe_cart_ingredient_added',
        properties: {
          'recipe_id': id,
          'ingredient_name': _truncateValue(name, fallback: 'unknown'),
          'position': i,
          'source': sourceKey,
        },
      );
      _signal(
        eventType: 'cart_add',
        screen: gcsScreen,
        sectionId: 'cart_confirm',
        cardId: name,
        contentType: 'ingredient',
        recipeId: id,
        ingredientName: name,
        position: i,
      );
    }
  }

  Future<void> trackRecipeAgentOpened({String? recipeId}) async {
    final id = recipeId?.trim() ?? '';
    await _logBoth(
      'recipe_agent_opened',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
      },
    );
    if (id.isEmpty) return;
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'recipe_agent',
      cardId: id,
      contentType: 'recipe_agent',
      recipeId: id,
    );
  }

  Future<void> trackRecipeAgentTurn({
    String? recipeId,
    String? chipId,
    required bool onTopic,
    required int patchCount,
    required int latencyMs,
    String? engine,
  }) async {
    final id = recipeId?.trim() ?? '';
    final chip = (chipId != null && chipId.trim().isNotEmpty)
        ? _sanitizeName(chipId, fallback: 'freeform')
        : 'freeform';
    await _logBoth(
      'recipe_agent_turn',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
        'chip_id': chip,
        'on_topic': onTopic ? 1 : 0,
        'patch_count': patchCount,
        'latency_ms': latencyMs < 0 ? 0 : latencyMs,
        if (engine != null && engine.trim().isNotEmpty)
          'engine': _sanitizeName(engine, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'recipe_agent_turn',
      cardId: chip,
      contentType: 'recipe_agent',
      recipeId: id.isEmpty ? null : id,
    );
  }

  Future<void> trackRecipeAgentTurnFailed({
    String? recipeId,
    String? chipId,
    int? statusCode,
  }) async {
    final id = recipeId?.trim() ?? '';
    await _logBoth(
      'recipe_agent_turn_failed',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
        if (chipId != null && chipId.trim().isNotEmpty)
          'chip_id': _sanitizeName(chipId, fallback: 'freeform'),
        if (statusCode != null) 'status_code': statusCode,
      },
    );
  }

  Future<void> trackRecipeAgentPatchApplied({
    String? recipeId,
    required int patchCount,
  }) async {
    final id = recipeId?.trim() ?? '';
    await _logBoth(
      'recipe_agent_patch_applied',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
        'patch_count': patchCount,
      },
    );
    if (id.isEmpty) return;
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'recipe_agent_apply',
      cardId: id,
      contentType: 'recipe_agent',
      recipeId: id,
    );
  }

  Future<void> trackRecipeAgentPatchDismissed({String? recipeId}) async {
    final id = recipeId?.trim() ?? '';
    await _logBoth(
      'recipe_agent_patch_dismissed',
      properties: {
        if (id.isNotEmpty) 'recipe_id': id,
      },
    );
    if (id.isEmpty) return;
    _signal(
      eventType: 'click',
      screen: 'recipe_detail',
      sectionId: 'recipe_agent_dismiss',
      cardId: id,
      contentType: 'recipe_agent',
      recipeId: id,
    );
  }

  /// Recipe detail ingredient row 「담기」 tap.
  Future<void> trackRecipeIngredientAddClicked({
    required String? recipeId,
    required String ingredientName,
  }) async {
    await initialize();
    final props = <String, Object>{
      'ingredient_name': _truncateValue(ingredientName, fallback: 'unknown'),
      if (recipeId != null && recipeId.trim().isNotEmpty)
        'recipe_id': recipeId.trim(),
    };
    try {
      await _analytics?.logEvent(
        name: 'recipe_ingredient_add_clicked',
        parameters: props,
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking ingredient add click: $e');
    }
    await _mpTrack('recipe_ingredient_add_clicked', properties: props);
  }

  /// Track when a user clicks a purchase button in the shopping cart.
  /// This is fired before the actual purchase flow starts.
  Future<void> trackPurchaseButtonClicked({
    required int ingredientCount,
    String? source,
  }) async {
    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'purchase_button_clicked',
        parameters: {
          'ingredient_count': ingredientCount,
          if (source != null && source.trim().isNotEmpty)
            'source': _sanitizeName(source),
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking purchase button click: $e');
    }
    await _mpTrack(
      'purchase_button_clicked',
      properties: {
        'ingredient_count': ingredientCount,
        if (source != null && source.trim().isNotEmpty)
          'source': _sanitizeName(source),
      },
    );
  }

  /// Track when a user saves a recipe from the feed (recipe already parsed by another user).
  Future<void> trackRecipeSavedFromFeed({
    required String recipeId,
    required String recipeName,
    required String? originalUploader,
    int? ingredientCount,
  }) async {
    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'recipe_saved_from_feed',
        parameters: {
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
          'recipe_name': _truncateValue(recipeName, fallback: 'unknown'),
          if (originalUploader != null && originalUploader.isNotEmpty)
            'original_uploader': _truncateValue(
              originalUploader,
              fallback: 'unknown',
            ),
          if (ingredientCount != null && ingredientCount >= 0)
            'ingredient_count': ingredientCount,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking recipe saved from feed: $e');
    }
    await _mpTrack(
      'recipe_saved_from_feed',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'recipe_name': _truncateValue(recipeName, fallback: 'unknown'),
        if (originalUploader != null && originalUploader.isNotEmpty)
          'original_uploader': _truncateValue(
            originalUploader,
            fallback: 'unknown',
          ),
        if (ingredientCount != null && ingredientCount >= 0)
          'ingredient_count': ingredientCount,
      },
    );
  }

  /// Track when a user bookmarks (saves) a recipe.
  Future<void> trackRecipeBookmarked({
    required String recipeId,
    String? platform,
  }) async {
    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'recipe_bookmarked',
        parameters: {
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
          ..._sourcePlatformProps(platform),
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking recipe bookmark: $e');
    }

    await _mpTrack(
      'recipe_bookmarked',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        ..._sourcePlatformProps(platform),
      },
    );
    unawaited(
      logCardEvent(
        'save',
        screen: 'recipe_detail',
        sectionId: 'bookmark',
        cardId: recipeId,
        contentType: 'recipe_save',
        recipeId: recipeId,
        recipeSourcePlatform: platform,
      ),
    );
    unawaited(
      RewardsService.instance.claim(
        'exp_recipe_bookmarked',
        idempotencyKey: 'exp_recipe_bookmarked:$recipeId',
      ),
    );
  }

  /// 북마크 해제. 노출 대비 저장/해제로 선호를 가른다.
  Future<void> trackRecipeUnbookmarked({
    required String recipeId,
    String? platform,
  }) async {
    await _logBoth(
      'recipe_unbookmarked',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        ..._sourcePlatformProps(platform),
      },
    );
    _signal(
      eventType: 'unsave',
      screen: 'recipe_detail',
      sectionId: 'unbookmark',
      cardId: recipeId,
      contentType: 'recipe_unsave',
      recipeId: recipeId,
      recipeSourcePlatform: platform,
    );
  }

  /// 리뷰/게시글/댓글 좋아요·취소.
  Future<void> trackContentLiked({
    required String contentType,
    required String contentId,
    required bool liked,
    String? recipeId,
    String? authorId,
  }) async {
    final eventName = liked ? 'content_liked' : 'content_unliked';
    await _logBoth(
      eventName,
      properties: {
        'content_type': _sanitizeName(contentType, fallback: 'unknown'),
        'content_id': _truncateValue(contentId, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        if (authorId != null && authorId.trim().isNotEmpty)
          'author_id': _truncateValue(authorId, fallback: 'unknown'),
      },
    );
    _signal(
      eventType: liked ? 'like' : 'unlike',
      screen: contentType == 'board_post' ? 'community' : 'review',
      sectionId: '${contentType}_like',
      cardId: contentId,
      contentType: contentType,
      recipeId: recipeId,
    );
  }

  /// 커뮤니티 글·댓글, 리뷰 댓글 작성.
  ///
  /// [contentId]는 생성된 글/댓글 id. 댓글은 [parentId]에 대상 글/리뷰 id를
  /// 넣고, GCS `cardId`는 부모 id를 써서 "무엇에 달았는지"를 남긴다.
  Future<void> trackContentCreated({
    required String contentType,
    required String contentId,
    String? parentId,
    String? recipeId,
    String? categoryId,
  }) async {
    await _logBoth(
      'content_created',
      properties: {
        'content_type': _sanitizeName(contentType, fallback: 'unknown'),
        'content_id': _truncateValue(contentId, fallback: 'unknown'),
        if (parentId != null && parentId.trim().isNotEmpty)
          'parent_id': _truncateValue(parentId, fallback: 'unknown'),
        if (recipeId != null && recipeId.trim().isNotEmpty)
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        if (categoryId != null && categoryId.trim().isNotEmpty)
          'category_id': _truncateValue(categoryId, fallback: 'unknown'),
      },
    );
    final bool isBoard = contentType.startsWith('board');
    _signal(
      eventType: 'create',
      screen: isBoard ? 'community' : 'review',
      sectionId: '${contentType}_create',
      cardId: (parentId != null && parentId.trim().isNotEmpty)
          ? parentId
          : contentId,
      contentType: contentType,
      recipeId: recipeId,
    );
  }

  /// 모임·챌린지 참여/인증. 카드 impression은 남기지 않는다.
  Future<void> trackCommunitySocialAction({
    required String action,
    required String contentType,
    required String contentId,
  }) async {
    await _logBoth(
      'community_social',
      properties: {
        'action': _sanitizeName(action, fallback: 'unknown'),
        'content_type': _sanitizeName(contentType, fallback: 'unknown'),
        'content_id': _truncateValue(contentId, fallback: 'unknown'),
      },
    );
  }

  /// Track newly created review events for period-based counts.
  Future<void> trackReviewCreated({
    required String recipeId,
    required int rating,
    required String platform,
    int photoCount = 0,
  }) async {
    await initialize();

    final int safePhotoCount = photoCount >= 0 ? photoCount : 0;
    try {
      await _analytics?.logEvent(
        name: 'review_created',
        parameters: {
          'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
          'rating': rating,
          ..._legacyContentPlatformProps(platform),
          'photo_count': safePhotoCount,
          'has_photo': safePhotoCount > 0 ? 1 : 0,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking review creation: $e');
    }

    await _mpTrack(
      'review_created',
      properties: {
        'recipe_id': _truncateValue(recipeId, fallback: 'unknown'),
        'rating': rating,
        ..._legacyContentPlatformProps(platform),
        'photo_count': safePhotoCount,
        'has_photo': safePhotoCount > 0 ? 1 : 0,
      },
    );
    unawaited(
      logCardEvent(
        'review',
        screen: 'recipe_detail',
        sectionId: 'review',
        cardId: recipeId,
        contentType: 'recipe',
        recipeId: recipeId,
        recipeSourcePlatform: platform,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Per-user Firestore counters (used for aggregate average metrics)
  // ---------------------------------------------------------------------------

  /// Increment the parse attempt counter for the given user.
  Future<void> trackParseAttemptForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'parseAttemptCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[AnalyticsService] Error tracking parse attempt for user: $e');
    }
    await _mpPeopleIncrement('parseAttemptCount', 1);
  }

  /// Increment the review count counter for the given user.
  Future<void> trackReviewWrittenForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'reviewCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[AnalyticsService] Error tracking review written for user: $e');
    }
    await _mpPeopleIncrement('reviewCount', 1);
  }

  /// Increment the purchase button click counter for the given user.
  Future<void> trackPurchaseButtonClickForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'purchaseButtonClickCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      print(
        '[AnalyticsService] Error tracking purchase button click for user: $e',
      );
    }
    await _mpPeopleIncrement('purchaseButtonClickCount', 1);
  }

  /// Increment the cooking-start button click counter for the given user.
  Future<void> trackCookingButtonClickForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'cookingButtonClickCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      print(
        '[AnalyticsService] Error tracking cooking button click for user: $e',
      );
    }
    await _mpPeopleIncrement('cookingButtonClickCount', 1);
  }

  /// Increment the saved recipes count for the given user (recipes saved from feed).
  Future<void> trackSavedRecipeForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'savedRecipesFromFeedCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[AnalyticsService] Error tracking saved recipe for user: $e');
    }
    await _mpPeopleIncrement('savedRecipesFromFeedCount', 1);
  }

  /// Record that the given user has completed at least one ingredient purchase.
  Future<void> trackPurchaseForUser(
    String userId, {
    int itemsBoughtCount = 0,
    int totalExpenditure = 0,
    int coupangExpenditure = 0,
    int kurlyExpenditure = 0,
    int purchasedRecipeCount = 0,
    int purchasedRecipeServings = 0,
  }) async {
    try {
      final Map<String, Object> update = <String, Object>{
        'hasPurchasedIngredients': true,
        'purchaseCount': FieldValue.increment(1),
        'lastInProgressCartSignature': '',
      };
      if (itemsBoughtCount > 0) {
        update['itemsBoughtTotalCount'] = FieldValue.increment(
          itemsBoughtCount,
        );
      }
      if (totalExpenditure > 0) {
        update['purchaseTotalPrice'] = FieldValue.increment(totalExpenditure);
      }
      if (coupangExpenditure > 0) {
        update['purchaseTotalPriceCoupang'] = FieldValue.increment(
          coupangExpenditure,
        );
      }
      if (kurlyExpenditure > 0) {
        update['purchaseTotalPriceKurly'] = FieldValue.increment(
          kurlyExpenditure,
        );
      }
      if (purchasedRecipeCount > 0) {
        update['purchasedRecipeCountTotal'] = FieldValue.increment(
          purchasedRecipeCount,
        );
      }
      if (purchasedRecipeServings > 0) {
        update['purchasedRecipeServingsTotal'] = FieldValue.increment(
          purchasedRecipeServings,
        );
      }
      await _firestore
          .collection('users')
          .doc(userId)
          .set(update, SetOptions(merge: true));
    } catch (e) {
      print('[AnalyticsService] Error tracking purchase for user: $e');
    }
    await _mpPeopleSet('hasPurchasedIngredients', true);
    await _mpPeopleIncrement('purchaseCount', 1);
    if (itemsBoughtCount > 0) {
      await _mpPeopleIncrement(
        'itemsBoughtTotalCount',
        itemsBoughtCount.toDouble(),
      );
    }
    if (totalExpenditure > 0) {
      await _mpPeopleIncrement(
        'purchaseTotalPrice',
        totalExpenditure.toDouble(),
      );
    }
    if (coupangExpenditure > 0) {
      await _mpPeopleIncrement(
        'purchaseTotalPriceCoupang',
        coupangExpenditure.toDouble(),
      );
    }
    if (kurlyExpenditure > 0) {
      await _mpPeopleIncrement(
        'purchaseTotalPriceKurly',
        kurlyExpenditure.toDouble(),
      );
    }
    if (purchasedRecipeCount > 0) {
      await _mpPeopleIncrement(
        'purchasedRecipeCountTotal',
        purchasedRecipeCount.toDouble(),
      );
    }
    if (purchasedRecipeServings > 0) {
      await _mpPeopleIncrement(
        'purchasedRecipeServingsTotal',
        purchasedRecipeServings.toDouble(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Aggregate metric queries
  // ---------------------------------------------------------------------------

  /// Average number of video parse attempts across users who attempted at least once.
  Future<double> getAverageParseAttemptsPerUser() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('parseAttemptCount', isGreaterThan: 0)
          .get();
      if (snapshot.docs.isEmpty) return 0.0;
      final total = snapshot.docs.fold<int>(0, (sum, doc) {
        final count = doc.data()['parseAttemptCount'];
        return sum + (count is int ? count : (count as num?)?.toInt() ?? 0);
      });
      return total / snapshot.docs.length;
    } catch (e) {
      print('[AnalyticsService] Error computing avg parse attempts: $e');
      return 0.0;
    }
  }

  /// Average number of reviews written across users who wrote at least one review.
  Future<double> getAverageReviewsPerUser() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('reviewCount', isGreaterThan: 0)
          .get();
      if (snapshot.docs.isEmpty) return 0.0;
      final total = snapshot.docs.fold<int>(0, (sum, doc) {
        final count = doc.data()['reviewCount'];
        return sum + (count is int ? count : (count as num?)?.toInt() ?? 0);
      });
      return total / snapshot.docs.length;
    } catch (e) {
      print('[AnalyticsService] Error computing avg reviews per user: $e');
      return 0.0;
    }
  }

  /// Proportion of users who purchased ingredients and also wrote at least one review.
  /// Returns a value between 0.0 and 1.0.
  Future<double> getCookToReviewConversionRate() async {
    try {
      final purchasedSnap = await _firestore
          .collection('users')
          .where('hasPurchasedIngredients', isEqualTo: true)
          .get();
      if (purchasedSnap.docs.isEmpty) return 0.0;

      final reviewedCount = purchasedSnap.docs.where((doc) {
        final count = doc.data()['reviewCount'];
        final n = count is int ? count : (count as num?)?.toInt() ?? 0;
        return n > 0;
      }).length;

      return reviewedCount / purchasedSnap.docs.length;
    } catch (e) {
      print('[AnalyticsService] Error computing cook-to-review rate: $e');
      return 0.0;
    }
  }

  /// Average number of purchase button clicks across users who clicked at least once.
  Future<double> getAveragePurchaseButtonClicksPerUser() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('purchaseButtonClickCount', isGreaterThan: 0)
          .get();
      if (snapshot.docs.isEmpty) return 0.0;
      final total = snapshot.docs.fold<int>(0, (sum, doc) {
        final count = doc.data()['purchaseButtonClickCount'];
        return sum + (count is int ? count : (count as num?)?.toInt() ?? 0);
      });
      return total / snapshot.docs.length;
    } catch (e) {
      print(
        '[AnalyticsService] Error computing avg purchase button clicks: $e',
      );
      return 0.0;
    }
  }

  /// Average number of recipes saved from feed per user across users who saved at least one.
  Future<double> getAverageSavedRecipesFromFeedPerUser() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('savedRecipesFromFeedCount', isGreaterThan: 0)
          .get();
      if (snapshot.docs.isEmpty) return 0.0;
      final total = snapshot.docs.fold<int>(0, (sum, doc) {
        final count = doc.data()['savedRecipesFromFeedCount'];
        return sum + (count is int ? count : (count as num?)?.toInt() ?? 0);
      });
      return total / snapshot.docs.length;
    } catch (e) {
      print(
        '[AnalyticsService] Error computing avg saved recipes from feed: $e',
      );
      return 0.0;
    }
  }

  Future<void> _flushCurrentScreenStay({
    String? nextScreenName,
    bool keepCurrentScreenName = false,
  }) async {
    final currentScreenName = _currentScreenName;
    final currentScreenStartedAt = _currentScreenStartedAt;
    if (currentScreenName == null || currentScreenStartedAt == null) {
      return;
    }

    final durationMs = DateTime.now()
        .difference(currentScreenStartedAt)
        .inMilliseconds;
    _currentScreenStartedAt = null;
    if (!keepCurrentScreenName) {
      _currentScreenName = null;
    }

    if (durationMs < 1000) {
      return;
    }

    await initialize();

    try {
      await _analytics?.logEvent(
        name: 'screen_stay',
        parameters: {
          'screen_name': currentScreenName,
          'duration_seconds': (durationMs / 1000).round(),
          if (nextScreenName != null) 'next_screen': nextScreenName,
        },
      );
    } catch (e) {
      print('[AnalyticsService] Error tracking screen stay: $e');
    }
    await _mpTrack(
      'screen_stay',
      properties: {
        'screen_name': currentScreenName,
        'duration_seconds': (durationMs / 1000).round(),
        if (nextScreenName != null) 'next_screen': nextScreenName,
        if (_currentRecipeId != null) 'recipe_id': _currentRecipeId,
      },
    );
    if (currentScreenName == 'recipe_detail' &&
        _currentRecipeId != null &&
        _currentRecipeId!.isNotEmpty) {
      _signal(
        eventType: 'dwell',
        screen: 'recipe_detail',
        sectionId: 'recipe_stay',
        cardId: _currentRecipeId,
        contentType: 'recipe',
        recipeId: _currentRecipeId,
        durationMs: durationMs,
      );
    }
  }

  String? _screenNameFromRoute(String? routeName) {
    switch (routeName) {
      case '/':
        return 'main_navigator';
      case '/login':
        return 'login';
      case '/signup':
        return 'signup';
      case '/onboarding':
        return 'onboarding';
      case '/profile':
        return 'profile_detail';
      case '/settings':
        return 'settings';
      case '/customer-center':
        return 'customer_center';
      case '/reparse-recipes':
        return 'reparse_recipes';
      case '/recommendation':
        return 'recommendation';
      case '/admin-reports':
        return 'admin_reports';
      case '/admin-error-recipes':
        return 'admin_error_recipes';
      case '/recipe-detail':
        return 'recipe_detail';
      default:
        if (routeName == null || routeName.trim().isEmpty) {
          return null;
        }
        return _sanitizeName(routeName.replaceAll('/', '_'));
    }
  }

  String _deviceOs() {
    return kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();
  }

  Future<void> _ensureAppVersionCached() async {
    if (_cachedAppVersion != null && _cachedAppVersion!.trim().isNotEmpty) {
      return;
    }
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (info.version.trim().isNotEmpty) {
        _cachedAppVersion = info.version.trim();
      }
    } catch (e) {
      print('[AnalyticsService] PackageInfo version lookup failed: $e');
    }
  }

  /// 콘텐츠 소스만. 슈퍼프로퍼티 `platform`(OS)과 키를 분리한다.
  Map<String, Object> _sourcePlatformProps(String? platform) {
    final src = (platform ?? '').trim();
    if (src.isEmpty) return const <String, Object>{};
    final sanitized = _sanitizeName(src);
    return <String, Object>{'source_platform': sanitized};
  }

  /// 파싱 등 기존 대시보드가 이벤트 `platform`=instagram 을 쓰던 곳.
  /// 기기 OS는 Mixpanel `device_os`로 본다.
  Map<String, Object> _legacyContentPlatformProps(String? platform) {
    final src = (platform ?? '').trim();
    if (src.isEmpty) return const <String, Object>{};
    final sanitized = _sanitizeName(src);
    return <String, Object>{
      'platform': sanitized,
      'source_platform': sanitized,
    };
  }

  String _sanitizeName(String value, {String fallback = 'unknown'}) {
    return sanitizeAnalyticsName(value, fallback: fallback);
  }

  String _truncateValue(String value, {String fallback = 'unknown'}) {
    return truncateAnalyticsValue(value, fallback: fallback);
  }

  // Get period IDs for current day, week, and month
  String _getDayId(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  String _getWeekId(DateTime date) {
    // Get ISO week number
    final weekNumber = _getWeekNumber(date);
    final year = date.year;
    // Handle year boundary (week might belong to previous year)
    if (weekNumber == 53 && date.month == 1) {
      return '${year - 1}-W53';
    }
    return '$year-W${weekNumber.toString().padLeft(2, '0')}';
  }

  String _getMonthId(DateTime date) {
    return DateFormat('yyyy-MM').format(date);
  }

  // Calculate ISO week number (week starts on Monday)
  int _getWeekNumber(DateTime date) {
    // Adjust weekday: Monday = 1, Sunday = 7
    int weekday = date.weekday;

    // Find the Thursday of the week (ISO week belongs to the year of its Thursday)
    final thursday = date.add(Duration(days: 4 - weekday));
    final jan1 = DateTime(thursday.year, 1, 1);
    final daysSinceJan1 = thursday.difference(jan1).inDays;

    // Week number is days since Jan 1 divided by 7, plus 1
    final weekNumber = (daysSinceJan1 / 7).floor() + 1;

    return weekNumber;
  }

  int _activePeriodCount(Map<String, dynamic> data) {
    final count = data['count'];
    if (count is int) return count < 0 ? 0 : count;
    if (count is num) {
      final n = count.toInt();
      return n < 0 ? 0 : n;
    }
    final userIds = data['userIds'] as List<dynamic>? ?? const [];
    return userIds.length;
  }

  Future<void> _trackActivePeriod({
    required String userId,
    required String periodType,
    required String periodId,
    required DateTime now,
  }) async {
    SharedPreferences? prefs;
    final prefKey = 'active_user_period_v1_${userId}_$periodType';
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getString(prefKey) == periodId) return;
    } catch (_) {
      // If local persistence is unavailable, keep the exact Firestore path.
    }

    final inFlightKey = '$userId|$periodType|$periodId';
    if (!_activePeriodWritesInFlight.add(inFlightKey)) return;
    try {
      final ref = _firestore
          .collection('activeUsers')
          .doc(periodType)
          .collection('periods')
          .doc(periodId);
      final userRef = _firestore.collection('users').doc(userId);
      final markKey = '${periodType}_$periodId';
      await _firestore.runTransaction((tx) async {
        final userSnap = await tx.get(userRef);
        final userData = userSnap.data() ?? <String, dynamic>{};
        final marks = userData['activePeriodMarks'];
        if (marks is Map && marks[markKey] == true) return;

        final periodSnap = await tx.get(ref);
        tx.set(userRef, {
          'activePeriodMarks.$markKey': true,
        }, SetOptions(merge: true));

        if (!periodSnap.exists) {
          tx.set(ref, {
            'periodId': periodId,
            'date': Timestamp.fromDate(now),
            'count': 1,
            'countMode': 'members',
            'userIds': [userId],
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return;
        }

        final data = periodSnap.data() ?? <String, dynamic>{};
        final legacyIds = (data['userIds'] as List<dynamic>?) ?? const [];
        final alreadyLegacy = data['countMode'] != 'members' &&
            legacyIds.any((id) => id.toString() == userId);
        final updates = <String, dynamic>{
          'periodId': periodId,
          'date': data['date'] ?? Timestamp.fromDate(now),
          'countMode': 'members',
          'updatedAt': FieldValue.serverTimestamp(),
          'userIds': [userId],
        };
        if (!alreadyLegacy) {
          if (data['count'] is num) {
            updates['count'] = FieldValue.increment(1);
          } else if (legacyIds.isNotEmpty) {
            updates['count'] = legacyIds.length + 1;
          } else {
            updates['count'] = 1;
          }
        } else if (data['count'] is! num && legacyIds.isNotEmpty) {
          updates['count'] = legacyIds.length;
        }
        tx.set(ref, updates, SetOptions(merge: true));
      });
      await prefs?.setString(prefKey, periodId);
    } catch (e) {
      print('[AnalyticsService] Error tracking $periodType active user: $e');
    } finally {
      _activePeriodWritesInFlight.remove(inFlightKey);
    }
  }

  Future<bool> _hasDailyActiveMembership({
    required String userId,
    required String dayId,
  }) async {
    try {
      final userSnap = await _firestore.collection('users').doc(userId).get();
      final marks = userSnap.data()?['activePeriodMarks'];
      if (marks is Map && marks['daily_$dayId'] == true) return true;
      return false;
    } catch (e) {
      print('[AnalyticsService] Daily active membership lookup failed: $e');
      return false;
    }
  }

  // Track each unique period once per local installation. Repeated resumes in
  // the same day/week/month cannot change member-doc uniqueness or its count.
  // Mixpanel `yorigo_active_user` 는 재설치 시 prefs 가 비므로, 같은 KST 날은
  // Firestore daily membership 이 있으면 보내지 않는다.
  Future<void> trackActiveUser(String userId) async {
    final DateTime now = DateTime.now();
    final String dayId = _getDayId(now);
    final String weekId = _getWeekId(now);
    final String monthId = _getMonthId(now);

    var shouldTrackMp = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'mp_active_user_day_v1_$userId';
      if (prefs.getString(key) == dayId) {
        shouldTrackMp = false;
      } else if (await _hasDailyActiveMembership(
        userId: userId,
        dayId: dayId,
      )) {
        shouldTrackMp = false;
        await prefs.setString(key, dayId);
      } else {
        await prefs.setString(key, dayId);
      }
    } catch (_) {}

    await Future.wait([
      _trackActivePeriod(
        userId: userId,
        periodType: 'daily',
        periodId: dayId,
        now: now,
      ),
      _trackActivePeriod(
        userId: userId,
        periodType: 'weekly',
        periodId: weekId,
        now: now,
      ),
      _trackActivePeriod(
        userId: userId,
        periodType: 'monthly',
        periodId: monthId,
        now: now,
      ),
    ]);

    final mpKey = '$userId|$dayId';
    if (shouldTrackMp && _mpActiveUserInFlight.add(mpKey)) {
      try {
        await _mpTrack(
          'yorigo_active_user',
          properties: {'day_id': dayId, 'week_id': weekId, 'month_id': monthId},
        );
      } finally {
        _mpActiveUserInFlight.remove(mpKey);
      }
    }
    unawaited(
      RewardsService.instance.claim(
        'exp_session_start',
        idempotencyKey: 'exp_session_start:$userId:$dayId',
      ),
    );
  }

  // Get active users for the last N periods
  Future<List<Map<String, dynamic>>> getActiveUsersHistory({
    required String periodType, // 'daily', 'weekly', or 'monthly'
    int limit = 7,
  }) async {
    try {
      final querySnapshot = await _firestore
          .collection('activeUsers')
          .doc(periodType)
          .collection('periods')
          .orderBy('date', descending: true)
          .limit(limit)
          .get();

      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'periodId': data['periodId'] as String? ?? doc.id,
          'date': data['date'] as Timestamp?,
          'count': _activePeriodCount(data),
        };
      }).toList();
    } catch (e) {
      print('[AnalyticsService] Error getting active users history: $e');
      return [];
    }
  }

  // Get active users count for a specific period
  Future<int> getActiveUsersCount({
    required String periodType,
    required String periodId,
  }) async {
    try {
      final doc = await _firestore
          .collection('activeUsers')
          .doc(periodType)
          .collection('periods')
          .doc(periodId)
          .get();

      if (!doc.exists) {
        return 0;
      }

      final data = doc.data()!;
      return _activePeriodCount(data);
    } catch (e) {
      print('[AnalyticsService] Error getting active users count: $e');
      return 0;
    }
  }

  // Get all active users statistics (last 7 days, weeks, months)
  Future<Map<String, List<Map<String, dynamic>>>>
  getAllActiveUsersStats() async {
    try {
      final results = await Future.wait([
        getActiveUsersHistory(periodType: 'daily', limit: 7),
        getActiveUsersHistory(periodType: 'weekly', limit: 7),
        getActiveUsersHistory(periodType: 'monthly', limit: 7),
      ]);

      return {'daily': results[0], 'weekly': results[1], 'monthly': results[2]};
    } catch (e) {
      print('[AnalyticsService] Error getting all active users stats: $e');
      return {'daily': [], 'weekly': [], 'monthly': []};
    }
  }

  // 전체 users 스캔은 비용이 커서 앱에서 돌리지 않는다.
  Future<int> migrateHistoricalActiveUsers() async {
    return 0;
  }

  Future<int> runHistoricalActiveUsersMigration() async {
    return 0;
  }

  // Reset migration flag (for testing/debugging purposes)
  Future<void> resetHistoricalActiveUsersMigration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const migrationKey = 'historical_active_users_migration_completed';
      await prefs.remove(migrationKey);
      print(
        '[AnalyticsService] Historical migration flag reset. Migration will run on next app start.',
      );
    } catch (e) {
      print('[AnalyticsService] Error resetting historical migration flag: $e');
    }
  }
}
