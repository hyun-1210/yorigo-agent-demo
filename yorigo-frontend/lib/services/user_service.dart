import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/onboarding_profile.dart';
import '../utils/cart_item_thumbnail_helper.dart';
import '../utils/coupang_subparam.dart';
import '../utils/coupang_visit_log.dart';
import '../utils/recipebook_sync.dart';
import 'analytics_service.dart';
import 'local_storage_service.dart';
import 'recipe_service.dart';
import 'rewards_service.dart';

class UserStreakDays {
  final Set<String> attendanceDays;
  final Set<String> cookingDays;

  const UserStreakDays({
    required this.attendanceDays,
    required this.cookingDays,
  });
}

/// 레시피 저장 시 애널리틱스용 메타 (saveCount 갱신과 함께 조회)
class _RecipeSaveTrackInfo {
  final String? platform;
  final String recipeName;
  final String? originalUploader;
  final int? ingredientCount;

  const _RecipeSaveTrackInfo({
    required this.platform,
    required this.recipeName,
    required this.originalUploader,
    required this.ingredientCount,
  });
}

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AnalyticsService _analyticsService = AnalyticsService();

  /// 장바구니 담기 직후 CartScreen이 탭 비가시 상태여도 상품 검색을 돌리기 위한 신호.
  /// (앱 재진입 시 기존 재료 자동검색은 건드리지 않는다.)
  static final StreamController<void> _cartItemAddedController =
      StreamController<void>.broadcast();
  static bool pendingCartAddSearch = false;

  /// 레시피에서 담기 직후 장바구니 탭에서 한 번 보여줄 안내 토스트.
  static bool pendingCartAddTip = false;

  /// 프로세스 안에서 출석 EXP를 이미 처리한 날. `uid:yyyy-MM-dd`
  static final Set<String> _attendanceExpClaimedKeys = <String>{};

  /// 로그인 유저 `coupangSubparam` 메모리 캐시. uid가 바뀌면 다시 읽는다.
  static String? _coupangSubparamCache;
  static String? _coupangSubparamCacheUid;
  static final Map<String, Future<String?>> _coupangSubparamInFlight =
      <String, Future<String?>>{};
  static final Set<String> _coupangVisitPrunedUids = <String>{};

  /// 약관 게이트와 온보딩 게이트가 같은 기동에서 유저 문서를 두 번 읽지 않게 한다.
  static Map<String, dynamic>? _userDataCache;
  static String? _userDataCacheUid;
  static DateTime? _userDataCacheAt;
  static const _userDataCacheTtl = Duration(seconds: 20);
  static final Set<String> _onboardingCompletedMemory = <String>{};
  static OnboardingProfile? _onboardingProfileCache;
  static String? _onboardingProfileCacheUid;
  static Future<OnboardingProfile?>? _onboardingProfileInFlight;
  static String? _onboardingProfileInFlightUid;
  static int _onboardingProfileLoadEpoch = 0;

  /// 장바구니 구매 완료 직후 냉장고 탭에서 한 번 보여줄 안내 토스트.
  static bool pendingFridgePurchaseTip = false;

  static Stream<void> get cartItemAddedStream =>
      _cartItemAddedController.stream;

  static void _notifyCartItemAdded() {
    pendingCartAddSearch = true;
    if (!_cartItemAddedController.isClosed) {
      _cartItemAddedController.add(null);
    }
  }

  static void markPendingCartAddTip() {
    pendingCartAddTip = true;
  }

  static void markPendingFridgePurchaseTip() {
    pendingFridgePurchaseTip = true;
  }

  /// Canonical `YYYY-MM-DD` key for streak maps (KST / UTC+9).
  /// Cloud Functions 출석 리마인드와 동일한 날짜 키를 쓴다.
  static String streakDayKey(DateTime dateTime) {
    final kst = dateTime.toUtc().add(const Duration(hours: 9));
    final normalized = DateTime.utc(kst.year, kst.month, kst.day);
    final month = normalized.month.toString().padLeft(2, '0');
    final day = normalized.day.toString().padLeft(2, '0');
    return '${normalized.year}-$month-$day';
  }

  static String? normalizeStreakDayKey(String raw) {
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(raw.trim());
    if (match == null) return null;
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }

  String _streakDayKey(DateTime dateTime) => streakDayKey(dateTime);

  Set<String> _normalizeStreakDays(dynamic raw) {
    if (raw is! Map) return <String>{};
    final days = <String>{};
    for (final key in raw.keys) {
      final normalized = normalizeStreakDayKey(key.toString());
      if (normalized != null) {
        days.add(normalized);
      }
    }
    return days;
  }

  Set<String> _extractStreakDaysFromUserData(
    Map<String, dynamic> data,
    String fieldName,
  ) {
    final days = <String>{..._normalizeStreakDays(data[fieldName])};

    final prefix = '$fieldName.';
    for (final entry in data.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final normalized = normalizeStreakDayKey(
        entry.key.substring(prefix.length),
      );
      if (normalized != null) {
        days.add(normalized);
      }
    }
    return days;
  }

  // In-memory cache for getSavedRecipes to avoid repeated user doc fetches
  static List<String>? _savedRecipesCache;
  static String? _savedRecipesCacheUid;
  static DateTime? _savedRecipesCachedAt;
  static const _savedRecipesCacheTtl = Duration(minutes: 5);

  static void _invalidateUserDataCache(String uid) {
    if (_userDataCacheUid == uid) {
      _userDataCache = null;
      _userDataCacheUid = null;
      _userDataCacheAt = null;
    }
  }

  static void _bumpOnboardingProfileEpoch() {
    _onboardingProfileLoadEpoch += 1;
  }

  /// 동기 조회. 캐시가 있을 때만 홈/상세/장바구니가 첫 프레임에 쓴다.
  static OnboardingProfile? peekOnboardingProfile() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _onboardingProfileCacheUid != uid) return null;
    return _onboardingProfileCache;
  }

  static void cacheOnboardingProfile(String uid, OnboardingProfile profile) {
    _onboardingProfileCache = profile;
    _onboardingProfileCacheUid = uid;
  }

  static void clearOnboardingProfileCache() {
    _onboardingProfileCache = null;
    _onboardingProfileCacheUid = null;
    _onboardingProfileInFlight = null;
    _onboardingProfileInFlightUid = null;
    _onboardingProfileLoadEpoch += 1;
  }

  Future<OnboardingProfile?> loadOnboardingProfile({
    bool allowCache = true,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      clearOnboardingProfileCache();
      return null;
    }
    if (allowCache) {
      final cached = peekOnboardingProfile();
      if (cached != null) return cached;
    }
    if (_onboardingProfileInFlight != null &&
        _onboardingProfileInFlightUid == uid) {
      return _onboardingProfileInFlight;
    }
    final pending = _loadOnboardingProfileUncached(uid, allowCache: allowCache);
    _onboardingProfileInFlight = pending;
    _onboardingProfileInFlightUid = uid;
    try {
      return await pending;
    } finally {
      if (identical(_onboardingProfileInFlight, pending)) {
        _onboardingProfileInFlight = null;
        _onboardingProfileInFlightUid = null;
      }
    }
  }

  Future<OnboardingProfile?> _loadOnboardingProfileUncached(
    String uid, {
    required bool allowCache,
  }) async {
    final epoch = _onboardingProfileLoadEpoch;
    try {
      final data = await readUserData(uid, allowCache: allowCache);
      if (data == null) {
        if (epoch == _onboardingProfileLoadEpoch) return null;
        return peekOnboardingProfile();
      }
      final profile = OnboardingProfile.fromMap(data);
      if (FirebaseAuth.instance.currentUser?.uid == uid &&
          epoch == _onboardingProfileLoadEpoch) {
        cacheOnboardingProfile(uid, profile);
        return profile;
      }
      return peekOnboardingProfile();
    } catch (e) {
      print('[UserService] loadOnboardingProfile failed: $e');
      return peekOnboardingProfile();
    }
  }

  static bool isOnboardingCompletedInMemory(String uid) {
    return _onboardingCompletedMemory.contains(uid);
  }

  Future<Map<String, dynamic>?> readUserData(
    String uid, {
    bool allowCache = true,
  }) async {
    if (allowCache &&
        _userDataCacheUid == uid &&
        _userDataCacheAt != null &&
        DateTime.now().difference(_userDataCacheAt!) < _userDataCacheTtl) {
      return _userDataCache;
    }
    final epoch = _onboardingProfileLoadEpoch;
    final snap = await getUserDocument(uid);
    if (!snap.exists) {
      _invalidateUserDataCache(uid);
      return null;
    }
    final data = snap.data();
    if (data is! Map<String, dynamic>) {
      _invalidateUserDataCache(uid);
      return null;
    }
    _userDataCache = data;
    _userDataCacheUid = uid;
    _userDataCacheAt = DateTime.now();
    if (FirebaseAuth.instance.currentUser?.uid == uid &&
        epoch == _onboardingProfileLoadEpoch) {
      cacheOnboardingProfile(uid, OnboardingProfile.fromMap(data));
    }
    return data;
  }

  // Get user document
  Future<DocumentSnapshot> getUserDocument(String uid) async {
    final snap = await _firestore.collection('users').doc(uid).get();
    _maybeEnsureCoupangSubparamFromSnapshot(uid, snap.data());
    return snap;
  }

  /// 가입·기동 시 만든 값을 프로세스 캐시에 넣는다. 재발급하지 않는다.
  static void cacheCoupangSubparam(String uid, String subparam) {
    final trimmedUid = uid.trim();
    final trimmed = subparam.trim();
    if (trimmedUid.isEmpty || trimmed.isEmpty) return;
    _coupangSubparamCacheUid = trimmedUid;
    _coupangSubparamCache = trimmed;
  }

  static void clearCoupangSubparamCache() {
    _coupangSubparamCache = null;
    _coupangSubparamCacheUid = null;
    _coupangSubparamInFlight.clear();
  }

  /// 현재 로그인 유저의 고정 `coupangSubparam`. 비로그인이면 null.
  Future<String?> getCurrentCoupangSubparam() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return null;
    return ensureCoupangSubparam(uid);
  }

  /// 제휴몰을 연 시각을 오늘(KST) 문서 하나에 붙인다. 나중에 경유 기록 UI용.
  /// 쿠팡·컬리·네이버 BrandConnect만 남긴다. 클릭마다 문서를 만들지 않는다.
  Future<void> logAffiliateVisit({
    required String marketplace,
    String? sourceScreen,
    String? productId,
    String? ingredientName,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    final market = normalizeAffiliateVisitMarketplace(marketplace);
    if (market == null) return;
    final todayId = coupangVisitDayId(DateTime.now());
    final entry = <String, dynamic>{
      'at': Timestamp.fromDate(DateTime.now()),
      'marketplace': market,
      if (sourceScreen != null && sourceScreen.trim().isNotEmpty)
        'sourceScreen': sourceScreen.trim(),
      if (productId != null && productId.trim().isNotEmpty)
        'productId': productId.trim(),
      if (ingredientName != null && ingredientName.trim().isNotEmpty)
        'ingredientName': ingredientName.trim(),
    };
    final col = _firestore
        .collection('users')
        .doc(uid)
        .collection(kCoupangVisitsCollection);
    try {
      await _firestore.runTransaction((tx) async {
        final ref = col.doc(todayId);
        final snap = await tx.get(ref);
        final data = snap.data();
        final existingRaw = data?['visits'];
        final existing = <Map<String, dynamic>>[];
        if (existingRaw is List) {
          for (final item in existingRaw) {
            if (item is Map<String, dynamic>) {
              existing.add(item);
            } else if (item is Map) {
              existing.add(Map<String, dynamic>.from(item));
            }
          }
        }
        final visits = appendCoupangVisit(existing: existing, next: entry);
        tx.set(ref, <String, dynamic>{
          'date': todayId,
          'visits': visits,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      print('[UserService] logAffiliateVisit failed uid=$uid: $e');
    }
    if (_coupangVisitPrunedUids.add(uid)) {
      unawaited(pruneOldCoupangVisitDocs(uid, todayId: todayId));
    }
  }

  /// 오늘(KST)이 아닌 경유 문서를 지운다. 하루 1문서만 남긴다.
  Future<void> pruneOldCoupangVisitDocs(String uid, {String? todayId}) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return;
    final today = (todayId ?? coupangVisitDayId(DateTime.now())).trim();
    try {
      final snap = await _firestore
          .collection('users')
          .doc(trimmedUid)
          .collection(kCoupangVisitsCollection)
          .get();
      final staleIds = coupangVisitDocIdsToDelete(
        docIds: snap.docs.map((d) => d.id),
        todayId: today,
      );
      if (staleIds.isEmpty) return;
      final batch = _firestore.batch();
      for (final id in staleIds) {
        batch.delete(
          _firestore
              .collection('users')
              .doc(trimmedUid)
              .collection(kCoupangVisitsCollection)
              .doc(id),
        );
      }
      await batch.commit();
    } catch (e) {
      print('[UserService] pruneOldCoupangVisitDocs failed uid=$trimmedUid: $e');
    }
  }

  /// `users/{uid}.coupangSubparam`이 없으면 한 번만 생성해 merge.
  /// 이미 있으면 절대 재발급하지 않는다.
  Future<String?> ensureCoupangSubparam(String uid) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return null;
    if (_coupangSubparamCacheUid == trimmedUid &&
        (_coupangSubparamCache ?? '').isNotEmpty) {
      return _coupangSubparamCache;
    }

    final inFlight = _coupangSubparamInFlight[trimmedUid];
    if (inFlight != null) return inFlight;

    final future = _ensureCoupangSubparamUncached(trimmedUid);
    _coupangSubparamInFlight[trimmedUid] = future;
    try {
      return await future;
    } finally {
      _coupangSubparamInFlight.remove(trimmedUid);
    }
  }

  Future<String?> _ensureCoupangSubparamUncached(String uid) async {
    try {
      final ref = _firestore.collection('users').doc(uid);
      final value = await _firestore.runTransaction<String>((tx) async {
        final snap = await tx.get(ref);
        final existing =
            (snap.data()?['coupangSubparam']?.toString() ?? '').trim();
        if (existing.isNotEmpty) return existing;

        final generated = generateCoupangSubparam();
        tx.set(
          ref,
          <String, dynamic>{
            'coupangSubparam': generated,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        return generated;
      });
      if (value.isNotEmpty) {
        cacheCoupangSubparam(uid, value);
      }
      return value.isEmpty ? null : value;
    } catch (e) {
      print('[UserService] ensureCoupangSubparam failed uid=$uid: $e');
      if (_coupangSubparamCacheUid == uid) return _coupangSubparamCache;
      return null;
    }
  }

  void _maybeEnsureCoupangSubparamFromSnapshot(
    String uid,
    Map<String, dynamic>? data,
  ) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid != uid) return;
    final existing = (data?['coupangSubparam']?.toString() ?? '').trim();
    if (existing.isNotEmpty) {
      cacheCoupangSubparam(uid, existing);
      return;
    }
    unawaited(ensureCoupangSubparam(uid));
  }

  /// Backfill `photoUrl` on the current user's Firestore document from their
  /// Firebase Auth `photoURL` (set by social sign-in providers) when the
  /// Firestore document is missing one. No-op if both sides already have a
  /// photo or if the auth user has none. Safe to call on every app launch.
  Future<void> backfillCurrentUserPhotoFromAuth() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final authPhotoUrl = user.photoURL?.trim() ?? '';
      if (authPhotoUrl.isEmpty) return;
      final docRef = _firestore.collection('users').doc(user.uid);
      final snap = await docRef.get();
      final data = snap.data();
      final existing = data != null ? resolveUserPhotoUrl(data) : null;
      if (existing != null && existing.isNotEmpty) return;
      await docRef.set({
        'photoUrl': authPhotoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print(
        '[UserService] Backfilled photoUrl from Firebase Auth for uid=${user.uid}',
      );
    } catch (e) {
      print('[UserService] backfillCurrentUserPhotoFromAuth failed: $e');
    }
    // 기존 유저: 앱 기동 시 subparam이 없으면 한 번 생성.
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) {
      unawaited(ensureCoupangSubparam(current.uid));
    }
  }

  // Get user data stream
  Stream<DocumentSnapshot> getUserStream(String uid) {
    return _firestore.collection('users').doc(uid).snapshots();
  }

  /// `true` if the user must see the in-app terms agreement (no recorded acceptance yet).
  Future<bool> needsTermsAgreement(String uid) async {
    final data = await readUserData(uid);
    if (data == null) return true;
    return data['termsAcceptedAt'] == null;
  }

  /// Persists mandatory terms + privacy consent (same screen). Call after user taps continue.
  Future<void> recordTermsAgreement(
    String uid, {
    bool onboardingRequired = false,
  }) async {
    await _firestore.collection('users').doc(uid).set({
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'privacyPolicyAcceptedAt': FieldValue.serverTimestamp(),
      if (onboardingRequired) 'onboardingRequired': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _invalidateUserDataCache(uid);
  }

  static String onboardingCompletedPrefsKey(String uid) =>
      'onboarding_completed_v1_$uid';

  static String onboardingDraftPrefsKey(String uid) =>
      'onboarding_draft_v1_$uid';

  /// 완료 캐시가 있으면 Firestore를 치지 않는다. 기존 회원도 completedAt이 없으면 연다.
  Future<bool> needsOnboarding(String uid) async {
    if (_onboardingCompletedMemory.contains(uid)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(onboardingCompletedPrefsKey(uid)) == true) {
        _onboardingCompletedMemory.add(uid);
        return false;
      }
    } catch (e) {
      print('[UserService] onboarding prefs read failed: $e');
    }
    final data = await readUserData(uid);
    if (data == null) return false;
    final needs = OnboardingDecision.needsOnboarding(data);
    if (!needs && data['onboardingCompletedAt'] != null) {
      await cacheOnboardingCompleted(uid);
    }
    return needs;
  }

  Future<void> cacheOnboardingCompleted(String uid) async {
    _onboardingCompletedMemory.add(uid);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(onboardingCompletedPrefsKey(uid), true);
      await prefs.remove(onboardingDraftPrefsKey(uid));
    } catch (e) {
      print('[UserService] cacheOnboardingCompleted failed: $e');
    }
  }

  Future<void> markOnboardingRequired(String uid) async {
    await _firestore.collection('users').doc(uid).set({
      'onboardingRequired': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _invalidateUserDataCache(uid);
  }

  Future<void> recordOnboardingCompleted(String uid) async {
    await _firestore.collection('users').doc(uid).set({
      'onboardingCompletedAt': FieldValue.serverTimestamp(),
      'onboardingRequired': false,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _invalidateUserDataCache(uid);
    await cacheOnboardingCompleted(uid);
  }

  /// 단계마다 Firestore에 쓰지 않고 로컬에만 이어서기 초안을 남긴다.
  Future<void> saveOnboardingDraft({
    required String uid,
    required String stepId,
    required OnboardingProfile profile,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        onboardingDraftPrefsKey(uid),
        jsonEncode(<String, dynamic>{
          'stepId': stepId,
          'profile': profile.toMap(),
        }),
      );
    } catch (e) {
      print('[UserService] saveOnboardingDraft failed: $e');
    }
  }

  Future<({String stepId, OnboardingProfile profile})?> loadOnboardingDraft(
    String uid,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(onboardingDraftPrefsKey(uid));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final stepId = decoded['stepId']?.toString() ?? '';
      if (stepId.isEmpty) return null;
      final profileRaw = decoded['profile'];
      final profile = OnboardingProfile.fromMap(
        profileRaw is Map
            ? Map<String, dynamic>.from(profileRaw)
            : const <String, dynamic>{},
      );
      return (stepId: stepId, profile: profile);
    } catch (e) {
      print('[UserService] loadOnboardingDraft failed: $e');
      return null;
    }
  }

  /// 네트워크 없이 이어서 열지 판정할 때 쓴다.
  Future<bool> hasOnboardingDraft(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(onboardingDraftPrefsKey(uid));
      return raw != null && raw.isNotEmpty;
    } catch (e) {
      print('[UserService] hasOnboardingDraft failed: $e');
      return false;
    }
  }

  /// Persists onboarding answers. Safe if the user doc does not exist yet.
  /// [completed]이면 같은 쓰기에 완료 플래그를 넣어 Firestore를 한 번만 친다.
  Future<void> saveOnboardingProfile(
    String uid,
    OnboardingProfile profile, {
    bool persistHandle = false,
    bool completed = false,
    String? previousName,
    String? previousHandle,
  }) async {
    var existingHandle = previousHandle?.trim();
    var existingName = previousName?.trim();
    if (persistHandle && (existingHandle == null || existingName == null)) {
      try {
        final data = await readUserData(uid);
        existingHandle ??= (data?['handle'] as String?)?.trim();
        existingName ??= (data?['name'] as String?)?.trim();
      } catch (e) {
        print('[UserService] saveOnboardingProfile previous doc failed: $e');
      }
    }
    final updates = <String, dynamic>{
      ...profile.toUserDocUpdates(persistHandle: persistHandle),
      'updatedAt': FieldValue.serverTimestamp(),
      if (completed) 'onboardingCompletedAt': FieldValue.serverTimestamp(),
      if (completed) 'onboardingRequired': false,
    };
    await _firestore.collection('users').doc(uid).set(
      updates,
      SetOptions(merge: true),
    );
    _invalidateUserDataCache(uid);
    _bumpOnboardingProfileEpoch();
    cacheOnboardingProfile(uid, profile);
    if (completed) {
      await cacheOnboardingCompleted(uid);
    }
    final name = profile.displayName?.trim() ?? '';
    final handle = profile.handle?.trim() ?? '';
    if (persistHandle && handle.isNotEmpty && handle != existingHandle) {
      try {
        await syncUserHandleRegistry(
          uid: uid,
          newHandle: handle,
          previousHandle: existingHandle,
        );
      } catch (e) {
        print('[UserService] onboarding handle registry failed: $e');
      }
    }
    final nameChanged = name.isNotEmpty && name != existingName;
    final handleChanged =
        persistHandle && handle.isNotEmpty && handle != existingHandle;
    if (nameChanged || handleChanged) {
      try {
        await _updateUserReviewsCreatorInfo(
          uid,
          name: nameChanged ? name : null,
          handle: handleChanged ? handle : null,
        );
      } catch (e) {
        print('[UserService] onboarding review creator sync failed: $e');
      }
    }
    if (name.isEmpty) return;
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null &&
        authUser.uid == uid &&
        (authUser.displayName ?? '').trim() != name) {
      try {
        await authUser.updateDisplayName(name);
      } catch (e) {
        print('[UserService] updateDisplayName from onboarding failed: $e');
      }
    }
  }

  /// 간단한 이메일 형식 검사 (소셜 이메일 backfill용).
  static bool looksLikeEmail(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 254) return false;
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed);
  }

  /// 소셜 가입/로그인에서 Firestore에 넣을 이메일 후보를 고른다.
  /// pending(카카오) → 폼 → Auth 순. 유효한 첫 값만 반환.
  static String? resolvePersistableEmail({
    String? pendingSocialEmail,
    String? formEmail,
    String? authEmail,
  }) {
    for (final candidate in <String?>[
      pendingSocialEmail,
      formEmail,
      authEmail,
    ]) {
      final trimmed = (candidate ?? '').trim();
      if (looksLikeEmail(trimmed)) return trimmed;
    }
    return null;
  }

  /// 소셜/가입 이메일을 Firestore `users.email`에 채운다.
  ///
  /// - 기존 non-empty email은 절대 덮어쓰지 않음 (기존 회원 보호)
  /// - Auth email은 변경하지 않음 (email-already-in-use 충돌 회피)
  /// - 실패해도 예외를 밖으로 던지지 않음 (로그인/가입 흐름 보호)
  ///
  /// Returns: 새로 기록했으면 true, 스킵/실패면 false.
  Future<bool> ensureUserEmailIfEmpty({
    required String uid,
    required String? email,
    required String emailSource,
  }) async {
    final trimmedUid = uid.trim();
    final trimmedEmail = (email ?? '').trim();
    final trimmedSource = emailSource.trim();
    if (trimmedUid.isEmpty || trimmedEmail.isEmpty || trimmedSource.isEmpty) {
      return false;
    }
    if (!looksLikeEmail(trimmedEmail)) {
      print(
        '[UserService] ensureUserEmailIfEmpty: invalid email skipped '
        'uid=$trimmedUid source=$trimmedSource',
      );
      return false;
    }

    try {
      final ref = _firestore.collection('users').doc(trimmedUid);
      final snap = await ref.get();
      final existing = (snap.data()?['email']?.toString() ?? '').trim();
      if (existing.isNotEmpty) {
        return false;
      }

      await ref.set({
        'email': trimmedEmail,
        'emailSource': trimmedSource,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      print('[UserService] ensureUserEmailIfEmpty failed uid=$trimmedUid: $e');
      return false;
    }
  }

  // Update user profile
  Future<void> updateUserProfile({
    required String uid,
    String? email,
    String? emailSource,
    String? name,
    String? photoUrl,
    String? handle,
    String? birthDate,
    String? ageVerificationMethod,
    String? signupProvider,
    bool? isAgeVerified14Plus,
    bool onboardingRequired = false,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (photoUrl != null) updates['photoUrl'] = photoUrl;
    if (handle != null) updates['handle'] = handle;
    if (birthDate != null) {
      updates['birthDate'] = birthDate;
      updates['ageVerifiedAt'] = FieldValue.serverTimestamp();
    }
    if (ageVerificationMethod != null) {
      updates['ageVerificationMethod'] = ageVerificationMethod;
    }
    if (signupProvider != null) {
      updates['signupProvider'] = signupProvider;
    }
    if (isAgeVerified14Plus != null) {
      updates['isAgeVerified14Plus'] = isAgeVerified14Plus;
    }
    if (onboardingRequired) {
      updates['onboardingRequired'] = true;
    }
    updates['updatedAt'] = FieldValue.serverTimestamp();

    // Check if document exists, if not create it
    final userDoc = await _firestore.collection('users').doc(uid).get();
    final String? previousHandle = userDoc.exists
        ? (userDoc.data()?['handle'] as String?)?.trim()
        : null;
    final existingEmail =
        (userDoc.data()?['email']?.toString() ?? '').trim();

    // email은 빈 칸일 때만 채움. 기존 회원 non-empty email은 덮어쓰지 않음.
    if (email != null) {
      final trimmedEmail = email.trim();
      if (trimmedEmail.isNotEmpty && existingEmail.isEmpty) {
        updates['email'] = trimmedEmail;
        final trimmedSource = emailSource?.trim();
        if (trimmedSource != null && trimmedSource.isNotEmpty) {
          updates['emailSource'] = trimmedSource;
        }
      }
    }

    if (userDoc.exists) {
      // Document exists, update it
      await _firestore.collection('users').doc(uid).update(updates);
    } else {
      // Document doesn't exist, create it with merge option
      // Include existing fields if any, and add required fields
      final newData = <String, dynamic>{
        'uid': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'savedRecipes': [],
        'cartItems': [],
        ...updates,
      };
      await _firestore
          .collection('users')
          .doc(uid)
          .set(newData, SetOptions(merge: true));
    }
    _invalidateUserDataCache(uid);

    if (handle != null) {
      final trimmed = handle.trim();
      try {
        await syncUserHandleRegistry(
          uid: uid,
          newHandle: trimmed.isEmpty ? null : trimmed,
          previousHandle: previousHandle,
        );
      } catch (e) {
        print('[UserService] syncUserHandleRegistry after profile update: $e');
      }
    }

    // Propagate name/handle changes to user's reviews so posts show updated info
    if (name != null || handle != null) {
      await _updateUserReviewsCreatorInfo(uid, name: name, handle: handle);
    }

    unawaited(_maybeClaimProfileCompleted(uid));
  }

  Future<void> _maybeClaimProfileCompleted(String uid) async {
    try {
      final snap = await _firestore.collection('users').doc(uid).get();
      final data = snap.data() ?? {};
      final named = (data['name'] as String?)?.trim() ?? '';
      final handle = (data['handle'] as String?)?.trim() ?? '';
      final photo = (data['photoUrl'] as String?)?.trim() ?? '';
      if (named.isEmpty || handle.isEmpty || photo.isEmpty) return;
      await RewardsService.instance.claim(
        'exp_profile_completed',
        idempotencyKey: 'exp_profile_completed:$uid',
      );
    } catch (e) {
      print('[UserService] profile completed exp skipped: $e');
    }
  }

  /// Updates creatorUsername (and optionally creatorName) in all reviews by this user.
  /// Ensures nickname/handle changes in profile edit flow through to displayed posts.
  Future<void> _updateUserReviewsCreatorInfo(
    String uid, {
    String? name,
    String? handle,
  }) async {
    try {
      final reviewsSnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .get();

      if (reviewsSnapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      for (final doc in reviewsSnapshot.docs) {
        final updates = <String, dynamic>{
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (handle != null) {
          updates['creatorUsername'] = handle.startsWith('@')
              ? handle
              : '@$handle';
        }
        if (name != null) {
          updates['creatorName'] = name;
        }
        batch.update(doc.reference, updates);
      }
      await batch.commit();
    } catch (e) {
      print('[UserService] Error updating reviews creator info: $e');
      // Don't rethrow - profile update succeeded; review updates are best-effort
    }
  }

  // Update last accessed timestamp and track active user
  Future<void> updateLastAccessed(String uid) async {
    unawaited(ensureCoupangSubparam(uid));
    try {
      final dayKey = _streakDayKey(DateTime.now());
      final firstOpenToday = await _reserveFirstOpenAttendance(uid, dayKey);

      await _firestore.collection('users').doc(uid).set({
        'lastAccessedAt': FieldValue.serverTimestamp(),
        'attendanceDays.$dayKey': FieldValue.serverTimestamp(),
        'lastAttendanceAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Track active user for analytics (daily, weekly, monthly)
      try {
        await _analyticsService.trackActiveUser(uid);
      } catch (e) {
        print('[UserService] Error tracking active user: $e');
        // Don't throw - analytics tracking shouldn't break the app
      }

      if (firstOpenToday) {
        unawaited(claimDailyAttendanceReward(uid, dayKey: dayKey));
        _coupangVisitPrunedUids.add(uid);
        unawaited(pruneOldCoupangVisitDocs(uid, todayId: dayKey));
      }
    } catch (e) {
      print('[UserService] Error updating lastAccessedAt: $e');
      // Don't throw - this is not critical
    }
  }

  /// 오늘(KST) 앱을 처음 연 호출만 true. 재진입·로그인·resume은 false.
  Future<bool> _reserveFirstOpenAttendance(String uid, String dayKey) async {
    final lock = '$uid:$dayKey';
    if (_attendanceExpClaimedKeys.contains(lock)) return false;
    _attendanceExpClaimedKeys.add(lock);

    try {
      final prefs = await SharedPreferences.getInstance();
      final prefsKey = 'attendance_exp_day_$uid';
      if (prefs.getString(prefsKey) == dayKey) return false;

      final doc = await _firestore.collection('users').doc(uid).get();
      final data = doc.data();
      if (data != null) {
        final days = _extractStreakDaysFromUserData(data, 'attendanceDays');
        if (days.contains(dayKey)) {
          await prefs.setString(prefsKey, dayKey);
          return false;
        }
      }
      await prefs.setString(prefsKey, dayKey);
      return true;
    } catch (e) {
      print('[UserService] Error reserving first-open attendance: $e');
      return true;
    }
  }

  /// 출석일 기록 후 연속일수를 계산해 출석 경험치를 청구한다.
  Future<void> claimDailyAttendanceReward(
    String uid, {
    String? dayKey,
  }) async {
    try {
      final todayKey = dayKey ?? _streakDayKey(DateTime.now());
      final streakData = await getUserStreakDays(uid);
      final days = <String>{...streakData.attendanceDays, todayKey};
      final streak = currentStreakFromAttendanceDays(days);
      await RewardsService.instance.claimAttendanceExp(
        streakDays: streak,
        dayKey: todayKey,
      );
    } catch (e) {
      print('[UserService] Error claiming daily attendance reward: $e');
    }
  }

  DateTime? _dateFromStreakDayKey(String dayKey) {
    final normalized = normalizeStreakDayKey(dayKey);
    if (normalized == null) return null;
    final parts = normalized.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  Set<String> _activeDaysFromUserData(Map<String, dynamic>? data) {
    final days = <String>{};
    final marks = data?['activePeriodMarks'];
    if (marks is! Map) return days;
    for (final raw in marks.keys) {
      final key = raw.toString();
      if (!key.startsWith('daily_')) continue;
      final fromKey = normalizeStreakDayKey(key.substring(6));
      if (fromKey != null) days.add(fromKey);
    }
    return days;
  }

  Future<void> _backfillMissingAttendanceDays(
    String uid,
    Set<String> missingDayKeys,
  ) async {
    if (missingDayKeys.isEmpty) return;

    final cutoff = DateTime.now().subtract(const Duration(days: 90));
    for (final dayKey in missingDayKeys) {
      final date = _dateFromStreakDayKey(dayKey);
      if (date == null || date.isBefore(cutoff)) continue;
      await recordAttendanceDay(uid, dateTime: date);
    }
  }

  Future<void> recordAttendanceDay(String uid, {DateTime? dateTime}) async {
    final dayKey = _streakDayKey(dateTime ?? DateTime.now());
    try {
      await _firestore.collection('users').doc(uid).set({
        'attendanceDays.$dayKey': FieldValue.serverTimestamp(),
        'lastAttendanceAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[UserService] Error recording attendance day: $e');
    }
  }

  /// 현재 연속 출석일. 날짜 키는 KST `yyyy-MM-dd`.
  ///
  /// 오늘 출석이 아직 없으면 어제부터 센다. 오늘이 끝나기 전에는
  /// 어제까지의 연속이 끊기지 않는다. 어제까지도 비면 0.
  int currentStreakFromAttendanceDays(Set<String> attendanceDays) {
    var cursorKey = _streakDayKey(DateTime.now());
    if (!attendanceDays.contains(cursorKey)) {
      final yesterday = _shiftStreakDayKey(cursorKey, -1);
      if (yesterday == null) return 0;
      cursorKey = yesterday;
    }
    var streak = 0;
    while (attendanceDays.contains(cursorKey)) {
      streak += 1;
      final previous = _shiftStreakDayKey(cursorKey, -1);
      if (previous == null) break;
      cursorKey = previous;
    }
    return streak;
  }

  String? _shiftStreakDayKey(String dayKey, int days) {
    final date = _dateFromStreakDayKey(dayKey);
    if (date == null) return null;
    final shifted = date.add(Duration(days: days));
    final month = shifted.month.toString().padLeft(2, '0');
    final day = shifted.day.toString().padLeft(2, '0');
    return '${shifted.year}-$month-$day';
  }

  Future<void> recordCookingDay(String uid, {DateTime? dateTime}) async {
    final dayKey = _streakDayKey(dateTime ?? DateTime.now());
    try {
      await _firestore.collection('users').doc(uid).set({
        'cookingDays.$dayKey': FieldValue.serverTimestamp(),
        'lastCookingAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[UserService] Error recording cooking day: $e');
    }
  }

  Future<UserStreakDays> getUserStreakDays(
    String uid, {
    bool forceServer = false,
  }) async {
    Set<String> storedAttendance = <String>{};
    Set<String> storedCooking = <String>{};

    try {
      final doc = await _firestore.collection('users').doc(uid).get(
        forceServer
            ? const GetOptions(source: Source.server)
            : const GetOptions(source: Source.serverAndCache),
      );
      final data = doc.data();
      if (data != null) {
        storedAttendance = _extractStreakDaysFromUserData(data, 'attendanceDays');
        storedCooking = _extractStreakDaysFromUserData(data, 'cookingDays');
      }
      final activeUserDays = _activeDaysFromUserData(data);
      final mergedAttendance = <String>{...storedAttendance, ...activeUserDays};
      final missingAttendance = activeUserDays.difference(storedAttendance);
      if (missingAttendance.isNotEmpty) {
        unawaited(_backfillMissingAttendanceDays(uid, missingAttendance));
      }

      return UserStreakDays(
        attendanceDays: mergedAttendance,
        cookingDays: storedCooking,
      );
    } catch (e) {
      print('[UserService] Error merging active user streak days: $e');
      return UserStreakDays(
        attendanceDays: storedAttendance,
        cookingDays: storedCooking,
      );
    }
  }

  Future<int> migrateLastAccessedAt() async {
    return 0;
  }

  // lastAccessedAt is written on every app open. Do not scan the users collection.
  Future<int> runLastAccessedAtMigration() async {
    return 0;
  }

  // Reset migration flag (for testing/debugging purposes)
  Future<void> resetLastAccessedAtMigration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const migrationKey = 'lastAccessedAt_migration_completed';
      await prefs.remove(migrationKey);
      print(
        '[UserService] Migration flag reset. Migration will run on next app start.',
      );
    } catch (e) {
      print('[UserService] Error resetting migration flag: $e');
    }
  }

  // Generate a unique handle for a user
  Future<String> generateUniqueHandle(
    String baseName, {
    String? forUserId,
  }) async {
    // Clean the base name: lowercase, remove spaces, keep only alphanumeric and underscores
    String cleanBase = baseName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '')
        .substring(0, baseName.length > 15 ? 15 : baseName.length);

    if (cleanBase.isEmpty) {
      cleanBase = 'user';
    }

    // Try the base handle first
    if (await isHandleAvailable(cleanBase, exceptUserId: forUserId)) {
      return cleanBase;
    }

    // If not available, try with random numbers
    final random = Random();
    for (int i = 0; i < 100; i++) {
      final candidate = '$cleanBase${random.nextInt(9999)}';
      if (await isHandleAvailable(candidate, exceptUserId: forUserId)) {
        return candidate;
      }
    }

    // Fallback: use timestamp
    return '$cleanBase${DateTime.now().millisecondsSinceEpoch % 10000}';
  }

  /// Returns true if [handle] is not used by any **other** user.
  /// Pass [exceptUserId] (Firebase Auth uid) so the current user keeping their
  /// own handle (e.g. during 소셜 회원가입) is not treated as a collision.
  ///
  /// 1) [user_handles] 문서(아이디=핸들) O(1) get — list 권한 없이 공개 핸들 조회에 사용
  /// 2) 레거시: 로그인된 경우에만 [users] 에서 `handle==` + limit(1) (규칙에서 list 는 로그인 필요)
  ///
  /// 이메일 회원가입(비로그인)일 때는 [users] 쿼리를 할 수 없어 예외가 나고, 잘못 "이미 사용 중"이 됨.
  /// 레지스트리에 문서가 없으면 **사용 가능**으로 본다(레거시-only 충돌은 가입 시 문서 쓰기로 해결).
  Future<bool> isHandleAvailable(String handle, {String? exceptUserId}) async {
    const collectionUserHandles = 'user_handles';
    try {
      final regDoc = await _firestore
          .collection(collectionUserHandles)
          .doc(handle)
          .get();
      if (regDoc.exists) {
        final owner = regDoc.data()?['uid'] as String?;
        if (exceptUserId != null &&
            exceptUserId.isNotEmpty &&
            owner == exceptUserId) {
          return true;
        }
        return false;
      }
    } catch (e) {
      print('[UserService] user_handles get failed, may try legacy: $e');
    }

    if (FirebaseAuth.instance.currentUser == null) {
      return true;
    }

    try {
      final querySnapshot = await _firestore
          .collection('users')
          .where('handle', isEqualTo: handle)
          .limit(1)
          .get();
      if (querySnapshot.docs.isEmpty) {
        return true;
      }
      if (exceptUserId != null && exceptUserId.isNotEmpty) {
        final takenByOther = querySnapshot.docs
            .where((d) => d.id != exceptUserId)
            .toList();
        return takenByOther.isEmpty;
      }
      return false;
    } catch (e) {
      print('[UserService] Error checking handle availability (legacy): $e');
      return false;
    }
  }

  /// users 문서에 기록한 핸들과 [user_handles] 매핑을 맞춤 (신규/변경/삭제).
  Future<void> syncUserHandleRegistry({
    required String uid,
    String? newHandle,
    String? previousHandle,
  }) async {
    final ch = (previousHandle ?? '').trim();
    final nh = (newHandle ?? '').trim();
    if (ch.isEmpty && nh.isEmpty) {
      return;
    }

    final batch = _firestore.batch();
    if (ch.isNotEmpty) {
      final oldRef = _firestore.collection('user_handles').doc(ch);
      final oldSnap = await oldRef.get();
      if (oldSnap.exists && (oldSnap.data()?['uid'] as String?) == uid) {
        batch.delete(oldRef);
      }
    }
    if (nh.isNotEmpty) {
      final newRef = _firestore.collection('user_handles').doc(nh);
      batch.set(newRef, <String, dynamic>{'uid': uid}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  // Get or generate handle for a user
  Future<String> getOrGenerateHandle(String uid, String? name) async {
    final doc = await getUserDocument(uid);
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>?;
      final existingHandle = data?['handle'] as String?;
      if (existingHandle != null && existingHandle.isNotEmpty) {
        return existingHandle;
      }
    }

    // Generate a new handle
    final baseName = name ?? 'user';
    final newHandle = await generateUniqueHandle(baseName, forUserId: uid);

    // Save it to the user document
    await _firestore.collection('users').doc(uid).set({
      'handle': newHandle,
    }, SetOptions(merge: true));

    try {
      await syncUserHandleRegistry(
        uid: uid,
        newHandle: newHandle,
        previousHandle: null,
      );
    } catch (e) {
      print('[UserService] syncUserHandleRegistry in getOrGenerateHandle: $e');
    }

    return newHandle;
  }

  // Add recipe to saved recipes and track save
  Future<void> addSavedRecipe(
    String uid,
    String recipeId, {
    bool fromFeed = false,
    String? sourcePlatform,
  }) async {
    print('[UserService] addSavedRecipe called: uid=$uid, recipeId=$recipeId');

    // Check if recipe is already in saved recipes
    final doc = await getUserDocument(uid);
    final data = doc.data() as Map<String, dynamic>?;
    final savedRecipes = List<String>.from(data?['savedRecipes'] ?? []);
    print('[UserService] Current saved recipes: $savedRecipes');
    print(
      '[UserService] Recipe already saved: ${savedRecipes.contains(recipeId)}',
    );

    final feedFirstSavedAtRaw = data?['feedFirstSavedAt'];
    final feedFirstSavedAtMap = feedFirstSavedAtRaw is Map
        ? Map<String, dynamic>.from(feedFirstSavedAtRaw)
        : <String, dynamic>{};
    final hasFeedFirstSaveHistory =
        feedFirstSavedAtMap.containsKey(recipeId) ||
        data?['feedFirstSavedAt.$recipeId'] != null;
    final isFirstSave = !savedRecipes.contains(recipeId);

    // Only track save if recipe is not already saved
    if (isFirstSave) {
      print('[UserService] Tracking recipe save for: $recipeId');
      // Track the save in the recipe document
      final _RecipeSaveTrackInfo? saveInfo = await _trackRecipeSave(recipeId);
      try {
        await _analyticsService.trackRecipeBookmarked(
          recipeId: recipeId,
          platform: sourcePlatform ?? saveInfo?.platform,
        );
        await _analyticsService.trackSavedRecipeForUser(uid);
        // 피드에서 첫 저장일 때만 전용 이벤트 (기존 bookmarked와 병행)
        if (fromFeed) {
          await _analyticsService.trackRecipeSavedFromFeed(
            recipeId: recipeId,
            recipeName: saveInfo?.recipeName ?? 'unknown',
            originalUploader: saveInfo?.originalUploader,
            ingredientCount: saveInfo?.ingredientCount,
          );
        }
      } catch (e) {
        print('[UserService] Error tracking bookmark analytics: $e');
      }
    }

    // Use set with merge to create the field if it doesn't exist
    print('[UserService] Adding recipe to savedRecipes array in Firestore...');

    final update = <String, dynamic>{
      'savedRecipes': FieldValue.arrayUnion([recipeId]),
      'savedAt.$recipeId': FieldValue.serverTimestamp(),
    };
    if (fromFeed && isFirstSave && !hasFeedFirstSaveHistory) {
      update['feedFirstSavedAt.$recipeId'] = FieldValue.serverTimestamp();
    }

    // Use dot notation to update specific key in savedAt map
    await _firestore
        .collection('users')
        .doc(uid)
        .set(update, SetOptions(merge: true));
    await ensureRecipebookCategoryDefaults(uid);

    // Hybrid denormalization: 카드용 미니 데이터를 서브컬렉션에도 동기화.
    // 옛 배열은 폴백/호환 위해 유지. (조회 경로는 추후 서브컬렉션 우선으로 전환)
    await _writeSavedRecipeMiniDocFromRecipe(uid, recipeId);

    invalidateSavedRecipesCache();

    // Verify it was added
    final updatedDoc = await getUserDocument(uid);
    final updatedData = updatedDoc.data() as Map<String, dynamic>?;
    final updatedSavedRecipes = List<String>.from(
      updatedData?['savedRecipes'] ?? [],
    );
    print('[UserService] Updated saved recipes: $updatedSavedRecipes');
    print(
      '[UserService] Recipe $recipeId in updated list: ${updatedSavedRecipes.contains(recipeId)}',
    );
  }

  /// recipes/{rid} 본체에서 카드용 미니 필드만 골라 `users/{uid}/savedRecipes/{rid}`
  /// 서브컬렉션에 기록. N+1 read → 단일 query 로 줄이기 위한 denormalization.
  Future<void> _writeSavedRecipeMiniDocFromRecipe(
    String uid,
    String recipeId,
  ) async {
    try {
      final recipeDoc =
          await _firestore.collection('recipes').doc(recipeId).get();
      if (!recipeDoc.exists) return;
      final r = recipeDoc.data() ?? <String, dynamic>{};
      await RecipeService.shared.updateSavedRecipeMiniDoc(uid, recipeId, r);
    } catch (e) {
      // 동기화 실패는 옛 배열에 이미 들어갔으므로 무시 가능.
      print('[UserService] savedRecipes mini-doc sync error: $e');
    }
  }

  Future<void> _decrementRecipeSaveCount(String recipeId) async {
    try {
      final recipeRef = _firestore.collection('recipes').doc(recipeId);
      final recipeDoc = await recipeRef.get();
      if (!recipeDoc.exists) return;

      final current = (recipeDoc.data()?['saveCount'] as num?)?.toInt() ?? 0;
      if (current <= 0) return;

      await recipeRef.update({'saveCount': FieldValue.increment(-1)});
    } catch (e) {
      print('[UserService] Error decrementing recipe saveCount: $e');
    }
  }

  Future<String?> _lookupRecipeSourcePlatform(String recipeId) async {
    try {
      final recipeDoc =
          await _firestore.collection('recipes').doc(recipeId).get();
      if (!recipeDoc.exists) return null;
      final data = recipeDoc.data() ?? {};
      final source = data['source'] is Map<String, dynamic>
          ? data['source'] as Map<String, dynamic>
          : null;
      final platform =
          (source?['platform'] as String?) ??
          (source?['source_platform'] as String?) ??
          (data['platform'] as String?);
      final trimmed = platform?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      return trimmed;
    } catch (_) {
      return null;
    }
  }

  // Track when a recipe is saved by a user
  Future<_RecipeSaveTrackInfo?> _trackRecipeSave(String recipeId) async {
    try {
      final now = DateTime.now();
      final weekAgo = now.subtract(const Duration(days: 7));
      final monthAgo = now.subtract(const Duration(days: 30));

      final recipeRef = _firestore.collection('recipes').doc(recipeId);
      final recipeDoc = await recipeRef.get();

      if (!recipeDoc.exists) {
        print(
          '[UserService] Recipe $recipeId does not exist, skipping save tracking',
        );
        return null;
      }

      final data = recipeDoc.data() ?? {};
      final source = data['source'] is Map<String, dynamic>
          ? data['source'] as Map<String, dynamic>
          : null;
      final recipeBody = data['recipe'] is Map<String, dynamic>
          ? data['recipe'] as Map<String, dynamic>
          : null;
      final String? platform =
          (source?['platform'] as String?) ??
          (source?['source_platform'] as String?) ??
          (data['platform'] as String?);
      final String recipeName =
          (data['title'] as String?)?.trim().isNotEmpty == true
          ? (data['title'] as String).trim()
          : ((recipeBody?['name'] as String?)?.trim().isNotEmpty == true
                ? (recipeBody!['name'] as String).trim()
                : 'unknown');
      final String? originalUploader =
          (source?['uploader'] as String?) ?? (source?['channel'] as String?);
      final ingredients = recipeBody?['ingredients'];
      final int? ingredientCount = ingredients is List
          ? ingredients.length
          : null;
      final lastSavedAt = (data['lastSavedAt'] as Timestamp?)?.toDate();

      final update = <String, dynamic>{
        'saveCount': FieldValue.increment(1),
        'lastSavedAt': FieldValue.serverTimestamp(),
      };
      if (lastSavedAt == null || lastSavedAt.isAfter(weekAgo)) {
        update['weeklySaves'] = FieldValue.increment(1);
      }
      if (lastSavedAt == null || lastSavedAt.isAfter(monthAgo)) {
        update['monthlySaves'] = FieldValue.increment(1);
      }
      await recipeRef.update(update);
      return _RecipeSaveTrackInfo(
        platform: platform,
        recipeName: recipeName,
        originalUploader: originalUploader,
        ingredientCount: ingredientCount,
      );
    } catch (e) {
      // Log error but don't fail the save operation
      print('[UserService] Error tracking recipe save: $e');
      // Continue - saving to user's list should still succeed
      return null;
    }
  }

  // Remove recipe from saved recipes
  Future<void> removeSavedRecipe(
    String uid,
    String recipeId, {
    String? sourcePlatform,
  }) async {
    print(
      '[UserService] removeSavedRecipe called: uid=$uid, recipeId=$recipeId',
    );

    // Check current saved recipes
    final doc = await getUserDocument(uid);
    final data = doc.data() as Map<String, dynamic>?;
    final savedRecipes = List<String>.from(data?['savedRecipes'] ?? []);
    print('[UserService] Current saved recipes before removal: $savedRecipes');

    final wasSaved = savedRecipes.contains(recipeId);

    // Use dot notation to remove specific key from savedAt map
    // Note: Firestore doesn't support removing map keys directly, so we need to set it to null
    await _firestore.collection('users').doc(uid).set({
      'savedRecipes': FieldValue.arrayRemove([recipeId]),
      'savedAt.$recipeId': FieldValue.delete(),
    }, SetOptions(merge: true));

    if (wasSaved) {
      await _decrementRecipeSaveCount(recipeId);
      try {
        String? platform = sourcePlatform;
        if (platform == null || platform.trim().isEmpty) {
          platform = await _lookupRecipeSourcePlatform(recipeId);
        }
        await _analyticsService.trackRecipeUnbookmarked(
          recipeId: recipeId,
          platform: platform,
        );
      } catch (e) {
        print('[UserService] Error tracking unbookmark: $e');
      }
    }

    // Hybrid denormalization: 서브컬렉션 미니 doc 도 제거.
    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .delete();
    } catch (e) {
      // 옛 데이터엔 서브컬렉션 doc 이 없을 수 있음 — 무시.
    }

    // 유저별 카테고리 매핑도 제거.
    await _localStorage.removeRecipeCategoryMapping(uid, recipeId);
    unawaited(_persistRecipebookToFirestore(uid));

    invalidateSavedRecipesCache();

    // Verify it was removed
    final updatedDoc = await getUserDocument(uid);
    final updatedData = updatedDoc.data() as Map<String, dynamic>?;
    final updatedSavedRecipes = List<String>.from(
      updatedData?['savedRecipes'] ?? [],
    );
    print(
      '[UserService] Updated saved recipes after removal: $updatedSavedRecipes',
    );
    print(
      '[UserService] Recipe $recipeId still in list: ${updatedSavedRecipes.contains(recipeId)}',
    );

    // 네이버 블로그 본문은 본인 디바이스 로컬에만 저장되므로, 북마크 해제 시
    // 함께 정리해 orphan 데이터 누적을 방지한다. recipeId 가 네이버가 아니면
    // 해당 키가 없어 no-op 으로 안전하게 처리된다.
    try {
      await LocalStorageService().deleteNaverBody(recipeId);
    } catch (e) {
      print('[UserService] deleteNaverBody failed for $recipeId: $e');
    }
  }

  // Add item to cart
  Future<void> addToCart(
    String uid,
    Map<String, dynamic> cartItem, {
    Map<String, dynamic>? recipeDocHint,
    dynamic parseResponseForThumbnail,
  }) async {
    final enriched = await CartItemThumbnailHelper.enrichCartItem(
      cartItem,
      recipeDocHint: recipeDocHint,
      parseResponseForThumbnail: parseResponseForThumbnail,
    );
    // Use set with merge to create the field if it doesn't exist
    await _firestore.collection('users').doc(uid).set({
      'cartItems': FieldValue.arrayUnion([enriched]),
    }, SetOptions(merge: true));
    _notifyCartItemAdded();

    // [임시 비활성] 장바구니 담기 포인트
    // final recipeId = enriched['recipeId']?.toString() ?? 'default';
    // final addedAt = enriched['addedAt']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    // unawaited(
    //   RewardsService.instance.claim(
    //     'points_cart_add',
    //     idempotencyKey: 'points_cart_add:$uid:$recipeId:$addedAt',
    //   ),
    // );
  }

  // Remove item from cart
  Future<void> removeFromCart(String uid, Map<String, dynamic> cartItem) async {
    await _firestore.collection('users').doc(uid).set({
      'cartItems': FieldValue.arrayRemove([cartItem]),
    }, SetOptions(merge: true));
  }

  // Clear cart
  Future<void> clearCart(String uid) async {
    await _firestore.collection('users').doc(uid).set({
      'cartItems': [],
    }, SetOptions(merge: true));
  }

  // Get saved recipes
  Future<List<String>> getSavedRecipes(String uid) async {
    // Return cached result if fresh
    if (_savedRecipesCacheUid == uid &&
        _savedRecipesCache != null &&
        _savedRecipesCachedAt != null &&
        DateTime.now().difference(_savedRecipesCachedAt!) <
            _savedRecipesCacheTtl) {
      return _savedRecipesCache!;
    }

    final doc = await getUserDocument(uid);
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>?;
      final result = List<String>.from(data?['savedRecipes'] ?? []);
      _savedRecipesCache = result;
      _savedRecipesCacheUid = uid;
      _savedRecipesCachedAt = DateTime.now();
      return result;
    }
    return [];
  }

  // ─── 레시피북 카테고리: Firestore users/{uid} 원본 + 로컬 캐시 ─────
  // 개인 데이터이므로 공용 recipes 문서가 아니라 유저 문서에만 저장한다.

  final LocalStorageService _localStorage = LocalStorageService();

  /// uid → 진행 중/완료된 초기 동기화. 인스턴스가 달라도 한 번만 수행.
  static final Map<String, Future<void>> _recipebookEnsureLocks = {};

  /// uid → 직렬화된 persist 체인. 동시 set() 이 서로를 덮지 않게 한다.
  static final Map<String, Future<void>> _recipebookPersistTails = {};

  static final Map<String, Timer> _recipebookPersistRetryTimers = {};

  static final Set<String> _recipebookSyncInProgress = {};

  static void clearRecipebookSyncState() {
    _recipebookEnsureLocks.clear();
    _recipebookSyncInProgress.clear();
    for (final timer in _recipebookPersistRetryTimers.values) {
      timer.cancel();
    }
    _recipebookPersistRetryTimers.clear();
  }

  static DateTime? _toDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is Timestamp) return raw.toDate();
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw);
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    }
    return null;
  }

  static int? _toEpochMillis(dynamic raw) {
    return _toDateTime(raw)?.millisecondsSinceEpoch;
  }

  static List<Map<String, dynamic>> _parseRemoteRecipebookCategories(
    dynamic raw,
  ) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) {
          final mapped = Map<String, dynamic>.from(e);
          final created = _toEpochMillis(mapped['createdAt']);
          final updated = _toEpochMillis(mapped['updatedAt']);
          if (created != null) mapped['createdAt'] = created;
          if (updated != null) mapped['updatedAt'] = updated;
          return mapped;
        })
        .where((e) => ((e['id'] as String?) ?? '').isNotEmpty)
        .toList();
  }

  static Map<String, List<String>> _parseRemoteRecipebookMap(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    raw.forEach((k, v) {
      final key = k.toString();
      if (key.isEmpty) return;
      if (v is List) {
        final ids = v
            .map((e) => e?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList();
        if (ids.isNotEmpty) result[key] = ids;
      } else if (v is String && v.trim().isNotEmpty) {
        result[key] = [v.trim()];
      }
    });
    return result;
  }

  Future<void> _persistRecipebookToFirestore(String uid) {
    if (uid.isEmpty) return Future.value();
    final prev = _recipebookPersistTails[uid] ?? Future.value();
    final next = prev.then((_) => _persistRecipebookOnce(uid));
    _recipebookPersistTails[uid] = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _persistRecipebookOnce(String uid) async {
    try {
      final categories = await _localStorage.getRecipebookCategories(
        uid,
        seedIfEmpty: false,
      );
      final mapping = await _localStorage.getRecipebookRecipeCategoryMap(uid);
      if (categories.isEmpty && mapping.isEmpty) {
        return;
      }
      final mapForFirestore = <String, dynamic>{
        for (final e in mapping.entries) e.key: e.value,
      };
      await _firestore.collection('users').doc(uid).set({
        'recipebookCategories': categories,
        'recipebookRecipeCategoryMap': mapForFirestore,
        'recipebookCategoriesUpdatedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _localStorage.markRecipebookClean(uid);
      _recipebookPersistRetryTimers.remove(uid)?.cancel();
    } catch (e) {
      print('[UserService] recipebook Firestore persist failed: $e');
      _scheduleRecipebookPersistRetry(uid);
    }
  }

  void _scheduleRecipebookPersistRetry(String uid) {
    if (uid.isEmpty) return;
    _recipebookPersistRetryTimers[uid]?.cancel();
    _recipebookPersistRetryTimers[uid] = Timer(const Duration(seconds: 8), () {
      unawaited(_persistRecipebookToFirestore(uid));
    });
  }

  Future<void> _applyRemoteRecipebook(
    String uid, {
    required List<Map<String, dynamic>> remoteCats,
    required Map<String, List<String>> remoteMap,
    DateTime? remoteUpdatedAt,
  }) async {
    await _localStorage.replaceRecipebookCategories(
      uid,
      remoteCats.isNotEmpty
          ? remoteCats
          : await _localStorage.seedDefaultCategoriesIfEmpty(uid),
    );
    await _localStorage.replaceRecipebookRecipeCategoryMap(uid, remoteMap);
    await _localStorage.markRecipebookClean(
      uid,
      remoteUpdatedAt: remoteUpdatedAt,
    );
  }

  /// 로그인/홈 진입 시: Firestore 를 원본으로 로컬 캐시를 맞춘다.
  /// [force]면 세션 캐시를 무시하고 다시 읽는다 (당겨서 새로고침).
  Future<void> ensureRecipebookCategoryDefaults(
    String uid, {
    bool force = false,
  }) async {
    if (uid.isEmpty) return;
    if (force) {
      _recipebookEnsureLocks.remove(uid);
    }
    final existing = _recipebookEnsureLocks[uid];
    if (existing != null) return existing;
    final future = _runRecipebookEnsure(uid);
    _recipebookEnsureLocks[uid] = future;
    try {
      await future;
    } catch (e) {
      _recipebookEnsureLocks.remove(uid);
      rethrow;
    }
  }

  Future<void> _runRecipebookEnsure(String uid) async {
    _recipebookSyncInProgress.add(uid);
    try {
      await _syncRecipebookFromFirestore(uid);
    } finally {
      _recipebookSyncInProgress.remove(uid);
    }
  }

  Future<void> _syncRecipebookFromFirestore(String uid) async {
    try {
      final localCats = await _localStorage.getRecipebookCategories(
        uid,
        seedIfEmpty: false,
      );
      final localMap = await _localStorage.getRecipebookRecipeCategoryMap(uid);
      final localDirty = await _localStorage.isRecipebookDirty(uid);
      final localUpdatedAt = await _localStorage.getRecipebookLocalUpdatedAt(
        uid,
      );

      final doc = await _firestore.collection('users').doc(uid).get();
      final data = doc.data();
      final remoteCats = _parseRemoteRecipebookCategories(
        data?['recipebookCategories'],
      );
      final remoteMap = _parseRemoteRecipebookMap(
        data?['recipebookRecipeCategoryMap'],
      );
      final remoteUpdatedAt = _toDateTime(
        data?['recipebookCategoriesUpdatedAt'],
      );

      final action = RecipebookSync.decide(
        remoteHasMeaningfulData: RecipebookSync.hasMeaningfulData(
          categories: remoteCats,
          recipeCategoryMap: remoteMap,
        ),
        localHasMeaningfulData: RecipebookSync.hasMeaningfulData(
          categories: localCats,
          recipeCategoryMap: localMap,
        ),
        localDirty: localDirty,
        localUpdatedAt: localUpdatedAt,
        remoteUpdatedAt: remoteUpdatedAt,
      );

      switch (action) {
        case RecipebookSyncAction.applyRemote:
          await _applyRemoteRecipebook(
            uid,
            remoteCats: remoteCats,
            remoteMap: remoteMap,
            remoteUpdatedAt: remoteUpdatedAt,
          );
          return;
        case RecipebookSyncAction.persistLocal:
          await _persistRecipebookToFirestore(uid);
          return;
        case RecipebookSyncAction.seedDefaults:
          await _localStorage.seedDefaultCategoriesIfEmpty(uid);
          await _persistRecipebookToFirestore(uid);
          return;
      }
    } catch (e) {
      print('[UserService] ensureRecipebookCategoryDefaults failed: $e');
      _recipebookEnsureLocks.remove(uid);
      try {
        await _localStorage.seedDefaultCategoriesIfEmpty(uid);
      } catch (_) {}
    }
  }

  /// 이미 구독 중인 users/{uid} 스냅샷에서 분류를 반영한다. 추가 읽기 없음.
  /// dirty 로컬이 있으면 덮지 않는다 (미전송 편집 보호).
  Future<void> applyRecipebookFromUserSnapshot(
    String uid,
    Map<String, dynamic>? data,
  ) async {
    if (uid.isEmpty || data == null) return;
    try {
      if (await _localStorage.isRecipebookDirty(uid)) return;
      final remoteCats = _parseRemoteRecipebookCategories(
        data['recipebookCategories'],
      );
      final remoteMap = _parseRemoteRecipebookMap(
        data['recipebookRecipeCategoryMap'],
      );
      if (!RecipebookSync.hasMeaningfulData(
        categories: remoteCats,
        recipeCategoryMap: remoteMap,
      )) {
        return;
      }
      await _applyRemoteRecipebook(
        uid,
        remoteCats: remoteCats,
        remoteMap: remoteMap,
        remoteUpdatedAt: _toDateTime(data['recipebookCategoriesUpdatedAt']),
      );
    } catch (e) {
      print('[UserService] applyRecipebookFromUserSnapshot failed: $e');
    }
  }

  static String recipebookSnapshotSignature(Map<String, dynamic>? data) {
    final updated = _toEpochMillis(data?['recipebookCategoriesUpdatedAt']) ?? 0;
    final cats = _parseRemoteRecipebookCategories(
      data?['recipebookCategories'],
    );
    final map = _parseRemoteRecipebookMap(data?['recipebookRecipeCategoryMap']);
    return '$updated:${cats.length}:${map.length}:${cats.map((c) => c['id']).join(',')}';
  }

  Future<List<Map<String, dynamic>>> getRecipebookCategories(
    String uid, {
    bool ensureDefaults = true,
  }) async {
    if (ensureDefaults && !_recipebookSyncInProgress.contains(uid)) {
      await ensureRecipebookCategoryDefaults(uid);
    }
    return _localStorage.getRecipebookCategories(uid, seedIfEmpty: true);
  }

  Future<Map<String, List<String>>> getRecipebookRecipeCategoryMap(
    String uid,
  ) async {
    return _localStorage.getRecipebookRecipeCategoryMap(uid);
  }

  Future<Map<String, dynamic>> addRecipebookCategory(
    String uid,
    String name, {
    String iconKey = 'folder',
  }) async {
    await ensureRecipebookCategoryDefaults(uid);
    final created = await _localStorage.addRecipebookCategory(
      uid,
      name,
      iconKey: iconKey,
    );
    await _persistRecipebookToFirestore(uid);
    RecipeService.notifyRecipesChanged();
    return created;
  }

  Future<void> renameRecipebookCategory(
    String uid, {
    required String categoryId,
    required String newName,
  }) async {
    await ensureRecipebookCategoryDefaults(uid);
    await _localStorage.renameRecipebookCategory(
      uid,
      categoryId: categoryId,
      newName: newName,
    );
    await _persistRecipebookToFirestore(uid);
    RecipeService.notifyRecipesChanged();
  }

  Future<void> deleteRecipebookCategory(String uid, String categoryId) async {
    await ensureRecipebookCategoryDefaults(uid);
    await _localStorage.deleteRecipebookCategory(uid, categoryId);
    await _persistRecipebookToFirestore(uid);
    RecipeService.notifyRecipesChanged();
  }

  /// 한 레시피에 여러 카테고리를 동시에 할당한다.
  /// 빈 리스트면 해당 레시피의 카테고리 매핑이 모두 제거된다.
  Future<void> setRecipebookCategoriesForRecipe(
    String uid, {
    required String recipeId,
    required List<String> categoryIds,
  }) async {
    await ensureRecipebookCategoryDefaults(uid);
    await _localStorage.setRecipebookCategoriesForRecipe(
      uid: uid,
      recipeId: recipeId,
      categoryIds: categoryIds,
    );
    await _persistRecipebookToFirestore(uid);
    RecipeService.notifyRecipesChanged();
  }

  /// 파싱 dedup 등으로 레시피 ID 가 바뀌면 분류 키를 같이 옮긴다.
  Future<void> remapRecipebookCategoryRecipeId({
    required String uid,
    required String fromRecipeId,
    required String toRecipeId,
  }) async {
    if (uid.isEmpty || fromRecipeId.isEmpty || toRecipeId.isEmpty) return;
    if (fromRecipeId == toRecipeId) return;
    final changed = await _localStorage.remapRecipebookRecipeId(
      uid: uid,
      fromRecipeId: fromRecipeId,
      toRecipeId: toRecipeId,
    );
    if (!changed) return;
    await _persistRecipebookToFirestore(uid);
    RecipeService.notifyRecipesChanged();
  }

  /// Invalidate saved recipes cache (call after save/unsave operations)
  static void invalidateSavedRecipesCache() {
    _savedRecipesCache = null;
    _savedRecipesCacheUid = null;
    _savedRecipesCachedAt = null;
  }

  /// Returns blocked user ids for the given user.
  Future<List<String>> getBlockedUserIds(String uid) async {
    final doc = await getUserDocument(uid);
    if (!doc.exists) return [];
    final data = doc.data() as Map<String, dynamic>?;
    return List<String>.from(data?['blockedUserIds'] ?? const <String>[]);
  }

  /// Blocks [blockedUserId] for [uid]. Blocked user's reviews are hidden client-side.
  Future<void> blockUser({
    required String uid,
    required String blockedUserId,
  }) async {
    if (uid.trim().isEmpty || blockedUserId.trim().isEmpty) return;
    if (uid == blockedUserId) {
      throw Exception('본인은 차단할 수 없습니다');
    }
    await _firestore.collection('users').doc(uid).set({
      'blockedUserIds': FieldValue.arrayUnion([blockedUserId]),
      'blockedUsersUpdatedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Removes [blockedUserId] from [uid]'s block list.
  Future<void> unblockUser({
    required String uid,
    required String blockedUserId,
  }) async {
    if (uid.trim().isEmpty || blockedUserId.trim().isEmpty) return;
    await _firestore.collection('users').doc(uid).set({
      'blockedUserIds': FieldValue.arrayRemove([blockedUserId]),
      'blockedUsersUpdatedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Get cart items
  Future<List<Map<String, dynamic>>> getCartItems(String uid) async {
    final doc = await getUserDocument(uid);
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>?;
      final items = data?['cartItems'] as List?;
      return items?.map((item) => item as Map<String, dynamic>).toList() ?? [];
    }
    return [];
  }

  // Fridge: save ingredients and recipes sent from cart when user presses 구매 완료
  Future<void> saveFridgeData(
    String uid, {
    required List<Map<String, dynamic>> ingredients,
    required List<Map<String, dynamic>> recipes,
    bool updateLastSentAt = true,
  }) async {
    final fridgeMap = <String, dynamic>{
      'ingredients': ingredients,
      'recipes': recipes,
    };
    if (updateLastSentAt) {
      fridgeMap['lastSentAt'] = FieldValue.serverTimestamp();
    }
    await _firestore.collection('users').doc(uid).set({
      'fridgeData': fridgeMap,
    }, SetOptions(merge: true));
  }

  /// Saves fridge data and clears the cart in a single write. Use on 구매 완료 so the
  /// cart screen and fridge stay in sync; meal plan is not modified.
  Future<void> saveFridgeDataAndClearCart(
    String uid, {
    required List<Map<String, dynamic>> ingredients,
    required List<Map<String, dynamic>> recipes,
  }) async {
    await _firestore.collection('users').doc(uid).set({
      'fridgeData': {
        'lastSentAt': FieldValue.serverTimestamp(),
        'ingredients': ingredients,
        'recipes': recipes,
      },
      'cartItems': <dynamic>[],
    }, SetOptions(merge: true));
  }

  /// Restores fridge and cart to previous state (for 구매 완료 취소). Writes both in one update.
  Future<void> restoreFridgeAndCart(
    String uid, {
    required Map<String, dynamic>? fridgeData,
    required List<dynamic> cartItems,
  }) async {
    final fridge =
        fridgeData ??
        <String, dynamic>{
          'lastSentAt': FieldValue.serverTimestamp(),
          'ingredients': <dynamic>[],
          'recipes': <dynamic>[],
        };
    await _firestore.collection('users').doc(uid).set({
      'fridgeData': fridge,
      'cartItems': cartItems,
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>?> getFridgeData(String uid) async {
    final doc = await getUserDocument(uid);
    if (!doc.exists) return null;
    final data = doc.data() as Map<String, dynamic>?;
    return data?['fridgeData'] as Map<String, dynamic>?;
  }

  /// Stream of fridge data for the given user. Emits whenever the user doc (e.g. after 구매 완료) changes.
  Stream<Map<String, dynamic>?> getFridgeDataStream(String uid) {
    return getUserStream(uid).map((doc) {
      if (!doc.exists) return null;
      final data = doc.data() as Map<String, dynamic>?;
      return data?['fridgeData'] as Map<String, dynamic>?;
    });
  }

  Future<void> clearFridgeData(String uid) async {
    await _firestore.collection('users').doc(uid).set({
      'fridgeData': {
        'lastSentAt': FieldValue.serverTimestamp(),
        'ingredients': [],
        'recipes': [],
      },
    }, SetOptions(merge: true));
  }

  /// Remove an ingredient from all cart items. Filters the ingredient out of each
  /// recipe's ingredients; removes recipes that end up with no ingredients.
  Future<void> removeIngredientFromCart(
    String uid,
    String ingredientName,
  ) async {
    final doc = await getUserDocument(uid);
    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>?;
    final cartItems = data?['cartItems'] as List? ?? [];

    final updatedItems = <Map<String, dynamic>>[];
    for (final item in cartItems) {
      final cartItem = Map<String, dynamic>.from(item as Map<String, dynamic>);
      final ingredients =
          (cartItem['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
          [];
      final filtered = ingredients
          .where(
            (ing) =>
                ((ing['item'] ?? ing['name'])?.toString() ?? '') !=
                ingredientName,
          )
          .toList();
      if (filtered.isNotEmpty) {
        cartItem['ingredients'] = filtered;
        updatedItems.add(cartItem);
      }
    }

    await _firestore.collection('users').doc(uid).set({
      'cartItems': updatedItems,
    }, SetOptions(merge: true));
  }

  // Remove all cart items with a specific recipeId
  Future<void> removeCartItemsByRecipeId(String uid, String recipeId) async {
    final doc = await getUserDocument(uid);
    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>?;
    final cartItems = data?['cartItems'] as List? ?? [];

    // Filter out items with matching recipeId
    final remainingItems = cartItems.where((item) {
      final cartItem = item as Map<String, dynamic>;
      final itemRecipeId = cartItem['recipeId']?.toString();
      return itemRecipeId != recipeId;
    }).toList();

    // Update cart with remaining items
    await _firestore.collection('users').doc(uid).set({
      'cartItems': remainingItems,
    }, SetOptions(merge: true));
  }

  /// Replace all cart items for a specific recipeId with a new cart item.
  Future<void> replaceCartItemsByRecipeId(
    String uid,
    String recipeId,
    Map<String, dynamic> newCartItem,
  ) async {
    final doc = await getUserDocument(uid);
    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>?;
    final cartItems = data?['cartItems'] as List? ?? [];

    final remainingItems = cartItems.where((item) {
      final cartItem = item as Map<String, dynamic>;
      return cartItem['recipeId']?.toString() != recipeId;
    }).toList();

    remainingItems.add(newCartItem);

    await _firestore.collection('users').doc(uid).set({
      'cartItems': remainingItems,
    }, SetOptions(merge: true));
  }

  // Get total likes on user's reviews (sum of likeCount for all user's reviews)
  Future<int> getTotalRecipeLikes(String uid) async {
    try {
      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .get();

      int totalLikes = 0;
      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        // Count likes on reviews (likeCount field, defaults to 0 if not present)
        final likeCount = (data['likeCount'] as num?)?.toInt() ?? 0;
        totalLikes += likeCount;
      }
      return totalLikes;
    } catch (e) {
      print('[UserService] Error getting total review likes: $e');
      return 0;
    }
  }

  /// 문서 전체를 받지 않고 공개 후기 개수만 센다.
  Future<int> countReviewsByUser(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return 0;
    try {
      final snap = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: id)
          .where('isHidden', isEqualTo: false)
          .count()
          .get();
      return snap.count ?? 0;
    } catch (e) {
      print('[UserService] Error counting reviews: $e');
      return getReviewCount(id);
    }
  }

  // Get number of reviews posted by user
  Future<int> getReviewCount(String uid) async {
    try {
      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .get();
      return querySnapshot.docs.length;
    } catch (e) {
      print('[UserService] Error getting review count: $e');
      return 0;
    }
  }

  /// 유저의 후기 개수를 실시간으로 스트리밍한다.
  /// 후기가 작성/삭제될 때마다 새 카운트가 즉시 emit 됨.
  Stream<int> streamReviewCount(String uid) {
    return _firestore
        .collection('reviews')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((snap) => snap.docs.length)
        .handleError((Object e) {
          print('[UserService] Error streaming review count: $e');
        });
  }

  // Get number of unique recipes tried (recipes with reviews)
  Future<int> getUniqueRecipesTried(String uid) async {
    try {
      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .get();

      final uniqueRecipeIds = <String>{};
      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final recipeId = data['recipeId'] as String?;
        if (recipeId != null) {
          uniqueRecipeIds.add(recipeId);
        }
      }
      return uniqueRecipeIds.length;
    } catch (e) {
      print('[UserService] Error getting unique recipes tried: $e');
      return 0;
    }
  }

  // Get reviews for current month (max 9)
  Future<List<Map<String, dynamic>>> getMonthlyReviews(String uid) async {
    try {
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);
      final startOfNextMonth = DateTime(now.year, now.month + 1, 1);

      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth),
          )
          .orderBy('createdAt', descending: true)
          .limit(9)
          .get();

      // Filter in memory for end date
      final reviews = querySnapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .where((review) {
            final createdAt = (review['createdAt'] as Timestamp?)?.toDate();
            if (createdAt == null) return false;
            return createdAt.isBefore(startOfNextMonth);
          })
          .toList();

      return reviews;
    } catch (e) {
      print('[UserService] Error getting monthly reviews: $e');
      return [];
    }
  }

  // Get monthly cooking sessions (reviews count for current month)
  Future<int> getMonthlyCookingSessions(String uid) async {
    try {
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);
      final startOfNextMonth = DateTime(now.year, now.month + 1, 1);

      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth),
          )
          .orderBy('createdAt')
          .get();

      // Filter in memory for end date
      final count = querySnapshot.docs.where((doc) {
        final createdAt = (doc.data()['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) return false;
        return createdAt.isBefore(startOfNextMonth);
      }).length;

      return count;
    } catch (e) {
      print('[UserService] Error getting monthly cooking sessions: $e');
      return 0;
    }
  }

  // Get last month's cooking sessions for comparison
  Future<int> getLastMonthCookingSessions(String uid) async {
    try {
      final now = DateTime.now();
      final lastMonth = DateTime(now.year, now.month - 1, 1);
      final startOfMonth = DateTime(now.year, now.month, 1);

      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(lastMonth),
          )
          .orderBy('createdAt')
          .get();

      // Filter in memory for end date
      final count = querySnapshot.docs.where((doc) {
        final createdAt = (doc.data()['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) return false;
        return createdAt.isBefore(startOfMonth);
      }).length;

      return count;
    } catch (e) {
      print('[UserService] Error getting last month cooking sessions: $e');
      return 0;
    }
  }

  // Get consecutive streak days
  Future<int> getConsecutiveStreak(String uid) async {
    try {
      final querySnapshot = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .get();

      if (querySnapshot.docs.isEmpty) return 0;

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      int streak = 0;
      DateTime? expectedDate = today;

      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) continue;

        final reviewDate = DateTime(
          createdAt.year,
          createdAt.month,
          createdAt.day,
        );

        if (reviewDate == expectedDate) {
          streak++;
          expectedDate = expectedDate?.subtract(const Duration(days: 1));
        } else if (reviewDate.isBefore(expectedDate!)) {
          // Gap in streak, break
          break;
        }
        // If reviewDate is after expectedDate, skip (shouldn't happen with descending order)
      }

      return streak;
    } catch (e) {
      print('[UserService] Error getting consecutive streak: $e');
      return 0;
    }
  }

  // Get user badges (empty for now, returns empty list)
  Future<List<Map<String, dynamic>>> getUserBadges(String uid) async {
    // TODO: Implement badge system
    return [];
  }

  // Get available badges with progress (empty for now)
  Future<List<Map<String, dynamic>>> getAvailableBadgesWithProgress(
    String uid,
  ) async {
    // TODO: Implement badge system
    // Should return badges ordered by closest to achieve
    return [];
  }

  // ========== 팔로우 시스템 메서드 ==========

  /// 사용자를 팔로우합니다
  Future<bool> followUser(String followerId, String followingId) async {
    try {
      print(
        '[UserService] followUser called: followerId=$followerId, followingId=$followingId',
      );

      // 1. 자기 자신 팔로우 방지
      if (followerId == followingId) {
        print('[UserService] Cannot follow self');
        throw Exception('자기 자신을 팔로우할 수 없습니다');
      }

      final isFollowing = await isUserFollowing(followerId, followingId);
      if (isFollowing) {
        return true;
      }

      // 3. follows 컬렉션에 문서 추가
      print('[UserService] Creating follow relationship...');
      await _firestore.collection('follows').add({
        'followerId': followerId,
        'followingId': followingId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      print('[UserService] Follow relationship created successfully');
      try {
        await _analyticsService.trackUserFollowed(targetUserId: followingId);
      } catch (e) {
        print('[UserService] Error tracking follow analytics: $e');
      }

      return true;
    } catch (e) {
      print('[UserService] Error following user: $e');
      rethrow;
    }
  }

  /// 팔로우를 취소합니다
  Future<bool> unfollowUser(String followerId, String followingId) async {
    try {
      print(
        '[UserService] unfollowUser called: followerId=$followerId, followingId=$followingId',
      );

      // 팔로우 관계 찾기
      final querySnapshot = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: followerId)
          .where('followingId', isEqualTo: followingId)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        return true;
      }

      // 문서 삭제
      print('[UserService] Deleting follow relationship...');
      for (final doc in querySnapshot.docs) {
        await doc.reference.delete();
      }
      print('[UserService] Follow relationship deleted successfully');
      try {
        await _analyticsService.trackUserUnfollowed(targetUserId: followingId);
      } catch (e) {
        print('[UserService] Error tracking unfollow analytics: $e');
      }

      return true;
    } catch (e) {
      print('[UserService] Error unfollowing user: $e');
      rethrow;
    }
  }

  /// 팔로우 상태 확인
  Future<bool> isUserFollowing(String followerId, String followingId) async {
    try {
      final querySnapshot = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: followerId)
          .where('followingId', isEqualTo: followingId)
          .limit(1)
          .get();

      final isFollowing = querySnapshot.docs.isNotEmpty;
      print(
        '[UserService] isUserFollowing: followerId=$followerId, followingId=$followingId, result=$isFollowing',
      );
      return isFollowing;
    } catch (e) {
      print('[UserService] Error checking follow status: $e');
      return false;
    }
  }

  /// 팔로워 수 조회
  Future<int> getFollowersCount(String userId) async {
    try {
      final querySnapshot = await _firestore
          .collection('follows')
          .where('followingId', isEqualTo: userId)
          .get();

      final count = querySnapshot.docs.length;
      print('[UserService] getFollowersCount: userId=$userId, count=$count');
      return count;
    } catch (e) {
      print('[UserService] Error getting followers count: $e');
      return 0;
    }
  }

  /// 팔로잉 수 조회
  Future<int> getFollowingCount(String userId) async {
    try {
      final querySnapshot = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: userId)
          .get();

      final count = querySnapshot.docs.length;
      print('[UserService] getFollowingCount: userId=$userId, count=$count');
      return count;
    } catch (e) {
      print('[UserService] Error getting following count: $e');
      return 0;
    }
  }

  /// 팔로워 목록 조회
  Future<List<Map<String, dynamic>>> getFollowers(
    String userId, {
    int limit = 50,
  }) async {
    try {
      final followsQuery = await _firestore
          .collection('follows')
          .where('followingId', isEqualTo: userId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();

      final followerIds = followsQuery.docs
          .map((doc) => doc.data()['followerId'] as String)
          .toList();

      // 사용자 정보 조회
      final users = <Map<String, dynamic>>[];
      for (final followerId in followerIds) {
        final userDoc = await _firestore
            .collection('users')
            .doc(followerId)
            .get();
        if (userDoc.exists) {
          final userData = userDoc.data()!;
          final contentUid =
              (userData['uid'] as String?)?.trim().isNotEmpty == true
              ? (userData['uid'] as String).trim()
              : followerId;
          users.add({
            'uid': followerId,
            'contentUid': contentUid,
            'name': userData['name'] ?? '',
            'photoUrl': resolveUserPhotoUrl(userData),
            'handle': userData['handle'],
          });
        }
      }

      return users;
    } catch (e) {
      print('[UserService] Error getting followers: $e');
      return [];
    }
  }

  /// Fast follow-id set for chips. Skips per-user profile fetches.
  Future<Set<String>> getFollowingIds(String userId, {int limit = 200}) async {
    try {
      final followsQuery = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: userId)
          .limit(limit)
          .get();
      final ids = <String>{};
      for (final doc in followsQuery.docs) {
        final followingId = doc.data()['followingId']?.toString().trim() ?? '';
        if (followingId.isNotEmpty) ids.add(followingId);
      }
      return ids;
    } catch (e) {
      print('[UserService] Error getting following ids: $e');
      return {};
    }
  }

  /// 팔로잉 목록 조회
  Future<List<Map<String, dynamic>>> getFollowing(
    String userId, {
    int limit = 50,
  }) async {
    try {
      final followsQuery = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: userId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();

      final followingIds = followsQuery.docs
          .map((doc) => doc.data()['followingId'] as String)
          .toList();

      // 사용자 정보 조회
      final users = <Map<String, dynamic>>[];
      for (final followingId in followingIds) {
        final userDoc = await _firestore
            .collection('users')
            .doc(followingId)
            .get();
        if (userDoc.exists) {
          final userData = userDoc.data()!;
          final contentUid =
              (userData['uid'] as String?)?.trim().isNotEmpty == true
              ? (userData['uid'] as String).trim()
              : followingId;
          users.add({
            'uid': followingId,
            'contentUid': contentUid,
            'name': userData['name'] ?? '',
            'photoUrl': resolveUserPhotoUrl(userData),
            'handle': userData['handle'],
          });
        }
      }

      return users;
    } catch (e) {
      print('[UserService] Error getting following: $e');
      return [];
    }
  }
}

/// Pick the first non-empty profile photo URL from any of the legacy field
/// variants we have used over time. Keep this aligned with the feed's
/// `_resolveProfileUrl` helper so the same user shows their photo everywhere.
///
/// In addition to the known keys, the function also scans for any field whose
/// (case-insensitive) name looks like a profile picture — `photoUrl`,
/// `photoURL`, `profile_picture`, `kakao_account.profile.profile_image_url`,
/// etc. — so social-signin users whose photos live under provider-specific
/// keys still get a hit.
/// Seed / demo accounts (속닥속닥 페르소나 등) must not open a profile page.
bool isSeedUserProfile(Map<String, dynamic>? userData) {
  if (userData == null || userData.isEmpty) return false;
  if (userData['seedBoardAuthor'] == true) return true;
  final email = userData['email']?.toString().trim().toLowerCase() ?? '';
  return email.endsWith('@yorigo.app');
}

/// Process-wide user-doc cache so board names/photos don't refetch and pop in.
class UserDocCache {
  static final Map<String, Map<String, dynamic>> _docs = {};

  static Map<String, dynamic>? peek(String uid) {
    if (uid.isEmpty) return null;
    return _docs[uid];
  }

  static void put(String uid, Map<String, dynamic> data) {
    if (uid.isEmpty) return;
    _docs[uid] = data;
  }

  static Future<Map<String, dynamic>> ensure(
    UserService users,
    String uid,
  ) async {
    final hit = peek(uid);
    if (hit != null) return hit;
    try {
      final doc = await users.getUserDocument(uid);
      final data = (doc.data() as Map<String, dynamic>?) ?? const {};
      put(uid, data);
      return data;
    } catch (_) {
      put(uid, const {});
      return const {};
    }
  }

  static Future<void> ensureAll(
    UserService users,
    Iterable<String> uids,
  ) async {
    final missing = uids
        .where((uid) => uid.isNotEmpty && !_docs.containsKey(uid))
        .toSet();
    if (missing.isEmpty) return;
    await Future.wait(missing.map((uid) => ensure(users, uid)));
  }
}

String? resolveUserPhotoUrl(Map<String, dynamic> userData) {
  const knownKeys = <String>[
    'photoUrl',
    'photoURL',
    'photo_url',
    'profileImageUrl',
    'profile_image_url',
    'avatarUrl',
    'avatar_url',
    'profilePhotoUrl',
    'profile_photo_url',
    'profilePicture',
    'profile_picture',
    'thumbnailImageUrl',
    'thumbnail_image_url',
    'picture',
    'image',
    'imageUrl',
    'image_url',
  ];
  for (final key in knownKeys) {
    final raw = userData[key]?.toString().trim() ?? '';
    if (raw.isNotEmpty && _looksLikeUrl(raw)) return raw;
  }

  // Fuzzy fallback: any top-level field whose name contains "photo", "image",
  // "picture", "avatar", or "thumb" and whose value looks like a URL.
  for (final entry in userData.entries) {
    final lowerKey = entry.key.toLowerCase();
    if (!(lowerKey.contains('photo') ||
        lowerKey.contains('image') ||
        lowerKey.contains('picture') ||
        lowerKey.contains('avatar') ||
        lowerKey.contains('thumb'))) {
      continue;
    }
    final raw = entry.value?.toString().trim() ?? '';
    if (raw.isNotEmpty && _looksLikeUrl(raw)) return raw;
  }

  // One level of nesting — e.g. social-login payloads stored as
  // `kakaoAccount.profile.profile_image_url`. Cheap to scan and only kicks in
  // when nothing was found above.
  for (final entry in userData.entries) {
    final value = entry.value;
    if (value is Map) {
      final nestedHit = resolveUserPhotoUrl(
        value.map((k, v) => MapEntry(k.toString(), v)),
      );
      if (nestedHit != null) return nestedHit;
    }
  }

  return null;
}

bool _looksLikeUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('gs://') ||
      lower.startsWith('data:');
}
