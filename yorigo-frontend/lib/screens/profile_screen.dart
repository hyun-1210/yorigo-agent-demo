import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../utils/image_resize.dart';
import '../utils/yorigo_level.dart';
import '../utils/review_display_date.dart';
import '../widgets/app_header.dart';
import '../widgets/guest_locked_preview_backdrop.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/community_feed_shimmer.dart';
import '../widgets/user_initial_avatar.dart';
import '../services/user_service.dart';
import '../services/auth_service.dart';
import '../utils/auth_session_ready.dart';
import '../services/admin_service.dart';
import '../services/review_service.dart';
import '../services/recipe_service.dart';
import '../services/local_storage_service.dart';
import '../services/rewards_service.dart';
import '../widgets/pick_recipe_for_review_sheet.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';
import 'recipe_review_feed_scroll_screen.dart';
import 'profile_edit_screen.dart';
import 'received_likes_list_screen.dart';
import 'user_reviews_list_screen.dart';
import 'follow_list_screen.dart';
import 'admin_post_management_screen.dart';
import 'admin_purchase_verification_screen.dart';
import 'streak_calendar_screen.dart';

enum _DiaryViewMode { grid, calendar }

class ProfileScreen extends StatefulWidget {
  final String? userId; // If null, shows current user's profile
  static final StreamController<void> _refreshController =
      StreamController<void>.broadcast();

  /// In-memory warm cache so first profile paint can skip a prefs round-trip.
  static Map<String, dynamic>? _warmOwnProfileCache;

  static void requestRefresh() {
    if (!_refreshController.isClosed) {
      _refreshController.add(null);
    }
  }

  /// Prefetch own profile disk cache (call after login / app idle).
  static Future<void> warmOwnProfileCache() async {
    try {
      final cached = await LocalStorageService().loadOwnProfileCache();
      if (cached != null) {
        _warmOwnProfileCache = cached;
      }
    } catch (_) {}
  }

  const ProfileScreen({super.key, this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserService _userService = UserService();
  final AuthService _authService = AuthService();
  final ReviewService _reviewService = ReviewService();
  final LocalStorageService _localStorageService = LocalStorageService();
  final ImagePicker _imagePicker = ImagePicker();

  // Stats
  int _totalLikes = 0;
  int _reviewCount = 0;
  int _uniqueRecipesTried = 0;
  int _monthlyCookingSessions = 0;
  int _lastMonthCookingSessions = 0;
  int _consecutiveStreak = 0;
  int? _followersCount = 0;
  int? _followingCount = 0;
  String _handle = '';
  String? _photoUrl;
  String? _userName;
  String? _viewingUserId; // The userId being viewed
  String? _contentUserId; // Auth uid used by reviews/recipes for this profile
  bool _isOwnProfile = false;
  bool _isAdminUser = false;
  /// 리워드 시스템(Cloud Functions)이 지급한 EXP/레벨/포인트.
  /// 기존 수저 레벨(후기 수 기반)과 별개 — EXP는 앱 사용량, 포인트는 BM 기여.
  int _expTotal = 0;
  int _rewardsLevel = 1;
  bool _hasExpTotal = false;

  int get _displayLevel {
    if (_hasExpTotal) return yorigoLevelFromExp(_expTotal);
    return _rewardsLevel < 1 ? 1 : _rewardsLevel;
  }
  int _pointsBalance = 0;
  int _pointsLifetimeEarned = 0;
  List<Map<String, dynamic>> _allReviews = []; // All reviews for navigation
  Map<String, Set<String>> _dailyStreakActions = <String, Set<String>>{};
  Set<String> _attendanceDays = <String>{};
  Set<String> _cookingDays = <String>{};
  DateTime? _selectedCalendarDay;
  _DiaryViewMode _diaryViewMode = _DiaryViewMode.calendar;
  DateTime _diaryCalendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
  );
  static const String _diaryViewModePrefsKey = 'profile_diary_view_mode';
  bool _isLoading = true;
  bool _isLoadingSecondary = false;
  bool _isLoadingActivity = false;
  bool _activityDataLoaded = false;
  bool _hydratedFromCache = false;
  Map<String, dynamic>? _phase1UserData;
  Future<void>? _activityDataLoadFuture;

  // 팔로우 관련 상태
  bool _isFollowing = false;
  bool _isLoadingFollowStatus = false;

  /// 팔로우 버튼/팔로워 카운트만 부분 리빌드하기 위한 notifier.
  /// 전체 build() 재실행 없이 헤더 안 일부 위젯만 갱신되도록 한다.
  /// 항상 변수와 동기화해서 사용한다 (UI는 notifier 구독, 로직은 변수 읽기).
  final ValueNotifier<({bool isFollowing, int? followersCount, bool isLoading})>
      _followNotifier = ValueNotifier(
    (isFollowing: false, followersCount: 0, isLoading: false),
  );

  void _syncFollowNotifier() {
    _followNotifier.value = (
      isFollowing: _isFollowing,
      followersCount: _followersCount,
      isLoading: _isLoadingFollowStatus,
    );
  }

  /// 유저의 후기 개수를 실시간으로 추적해서, 후기 삭제/추가 시
  /// 레벨/통계가 자동으로 갱신되도록 한다.
  StreamSubscription<int>? _reviewCountSub;
  StreamSubscription<void>? _profileRefreshSub;

  /// Throttle tab-tap refreshes so we don't reload profile data more often
  /// than once per 60 seconds. Forced refreshes (e.g. after profile edit)
  /// bypass this via [_loadProfileData(force: true)].
  DateTime? _lastProfileLoadAt;
  Future<void>? _loadProfileDataFuture;
  bool _bootstrapInFlight = false;

  static const String _actionSaveRecipe = 'save_recipe';
  static const String _actionAddScheduledCart = 'add_scheduled_cart';
  static const String _actionParseRecipe = 'parse_recipe';
  static const String _actionCompleteScheduledCooking =
      'complete_scheduled_cooking';

  /// 요리GO 레벨 진행도. 군더더기 없는 깔끔한 pill 게이지.
  /// 트랙 위로 주황 그라데이션이 둥근 끝으로 차오른다.
  Widget _buildSpoonProgressBar({required double progress}) {
    const trackH = 10.0;
    final p = progress.clamp(0.0, 1.0);

    return SizedBox(
      height: trackH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final fillW = (w * p).clamp(0.0, w);
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              // ── Track ──
              Container(
                height: trackH,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF3),
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              // ── Fill ──
              if (fillW > 0)
                Container(
                  height: trackH,
                  width: fillW,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [Color(0xFFFFB347), Color(0xFFFF6B00)],
                    ),
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF6B00).withValues(alpha: 0.22),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 레벨별 수저 재질을 나타내는 배지 배경
  BoxDecoration _levelBadgeDecoration(int level) {
    final i = (level - 1).clamp(0, 9);
    switch (i) {
      case 0: // 흑수저
        return BoxDecoration(
          color: const Color(0xFF2D2D2D),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 1: // 종이수저
        return BoxDecoration(
          color: const Color(0xFFE8DCC8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD4C4A8), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 2: // 플라스틱수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFFC8C8C8), const Color(0xFFA8A8A8)],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 3: // 나무수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFFA08050), const Color(0xFF6B4E2E)],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5C4033).withOpacity(0.35),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 4: // 스테인리스수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFFE8E8E8), const Color(0xFFB0B0B0)],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 5: // 은수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFFF5F5F5), const Color(0xFFC0C0C0)],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF808080).withOpacity(0.3),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 6: // 금수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFFFFE066), const Color(0xFFD4A017)],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFB8860B).withOpacity(0.4),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 7: // 다이아수저
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFFE0F7FA),
              const Color(0xFFB2EBF2),
              const Color(0xFF80DEEA),
            ],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00ACC1).withOpacity(0.35),
              blurRadius: 5,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 8: // 백수저
        return BoxDecoration(
          color: const Color(0xFFFFFBF5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE8E0D8), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        );
      case 9: // 요리고수저
      default:
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.primaryDark],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.4),
              blurRadius: 5,
              offset: const Offset(0, 1),
            ),
          ],
        );
    }
  }

  Color _levelBadgeTextColor(int level) {
    final i = (level - 1).clamp(0, 9);
    switch (i) {
      case 0:
        return Colors.white;
      case 1:
        return const Color(0xFF5C4A32);
      case 2:
      case 4:
      case 5:
        return const Color(0xFF333333);
      case 3:
      case 6:
      case 7:
      case 9:
        return Colors.white;
      case 8:
        return const Color(0xFF4A4A4A);
      default:
        return Colors.white;
    }
  }

  @override
  void initState() {
    super.initState();
    _viewingUserId = widget.userId ?? _auth.currentUser?.uid;
    _isOwnProfile =
        widget.userId == null || widget.userId == _auth.currentUser?.uid;
    // Apply in-memory warm cache synchronously before first frame when possible.
    if (_isOwnProfile) {
      _tryApplyWarmOwnCacheSync();
    }
    if (_isOwnProfile) {
      RewardsService.instance.expTotalListenable.addListener(_onLiveExpTotal);
    }
    unawaited(_bootstrapProfile());
    _profileRefreshSub = ProfileScreen._refreshController.stream.listen((_) {
      if (!mounted) return;
      // Bootstrap already force-loads; skip competing refresh on first open.
      if (_bootstrapInFlight || _loadProfileDataFuture != null) return;
      unawaited(_loadProfileData());
    });
  }

  void _tryApplyWarmOwnCacheSync() {
    final warm = ProfileScreen._warmOwnProfileCache;
    if (warm == null) return;
    final cachedUid = (warm['uid'] as String?)?.trim();
    if (cachedUid != null &&
        cachedUid.isNotEmpty &&
        _viewingUserId != null &&
        cachedUid != _viewingUserId) {
      return;
    }
    if (cachedUid != null && cachedUid.isNotEmpty && _viewingUserId == null) {
      _viewingUserId = cachedUid;
    }
    _applyProfileCache(warm);
    _hydratedFromCache = true;
    _isLoading = false;
  }

  Future<void> _bootstrapProfile() async {
    _bootstrapInFlight = true;
    try {
      // Hydrate first for instant diary; diary-mode pref can finish in parallel.
      final hydrateFuture = _isOwnProfile
          ? _hydrateFromOwnProfileCache()
          : Future<void>.value();
      unawaited(_loadDiaryViewModePref());
      await hydrateFuture;
      _subscribeReviewCount();
      await _loadProfileData(force: true);
    } finally {
      _bootstrapInFlight = false;
    }
  }

  Future<void> _loadDiaryViewModePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diaryViewModePrefsKey);
      if (!mounted) return;
      // 기본은 캘린더. 예전에 그리드를 고른 경우만 그리드 유지.
      final next = raw == 'grid'
          ? _DiaryViewMode.grid
          : _DiaryViewMode.calendar;
      if (next != _diaryViewMode) {
        setState(() => _diaryViewMode = next);
      }
    } catch (_) {
      // Prefs are best-effort; default stays calendar.
    }
  }

  Future<void> _saveDiaryViewModePref(_DiaryViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _diaryViewModePrefsKey,
        mode == _DiaryViewMode.calendar ? 'calendar' : 'grid',
      );
    } catch (_) {}
  }

  void _setDiaryViewMode(_DiaryViewMode mode) {
    if (_diaryViewMode == mode) return;
    setState(() => _diaryViewMode = mode);
    unawaited(_saveDiaryViewModePref(mode));
  }

  Future<void> _hydrateFromOwnProfileCache() async {
    if (_hydratedFromCache && _allReviews.isNotEmpty) {
      // Already painted from warm memory cache; still refresh disk snapshot quietly.
      final disk = await _localStorageService.loadOwnProfileCache();
      if (disk != null) {
        ProfileScreen._warmOwnProfileCache = disk;
      }
      return;
    }

    final cached = ProfileScreen._warmOwnProfileCache ??
        await _localStorageService.loadOwnProfileCache();
    if (cached == null || !mounted) return;
    ProfileScreen._warmOwnProfileCache = cached;

    final cachedUid = (cached['uid'] as String?)?.trim();
    if (cachedUid != null && cachedUid.isNotEmpty && _viewingUserId == null) {
      _viewingUserId = cachedUid;
    }

    _applyProfileCache(cached);
    if (!mounted) return;
    setState(() {
      _hydratedFromCache = true;
      _isLoading = false;
      _isLoadingSecondary = false;
    });
    _syncFollowNotifier();
  }

  void _applyProfileCache(Map<String, dynamic> cached) {
    _handle = cached['handle'] as String? ?? _handle;
    _photoUrl = cached['photoUrl'] as String? ?? _photoUrl;
    _userName = cached['userName'] as String? ?? _userName;
    _contentUserId = cached['contentUserId'] as String? ?? _contentUserId;
    _totalLikes = (cached['totalLikes'] as num?)?.toInt() ?? _totalLikes;
    _reviewCount = (cached['reviewCount'] as num?)?.toInt() ?? _reviewCount;
    _uniqueRecipesTried =
        (cached['uniqueRecipesTried'] as num?)?.toInt() ?? _uniqueRecipesTried;
    _monthlyCookingSessions =
        (cached['monthlyCookingSessions'] as num?)?.toInt() ??
        _monthlyCookingSessions;
    _lastMonthCookingSessions =
        (cached['lastMonthCookingSessions'] as num?)?.toInt() ??
        _lastMonthCookingSessions;
    _consecutiveStreak =
        (cached['consecutiveStreak'] as num?)?.toInt() ?? _consecutiveStreak;
    _followersCount =
        (cached['followersCount'] as num?)?.toInt() ?? _followersCount;
    _followingCount =
        (cached['followingCount'] as num?)?.toInt() ?? _followingCount;

    final cachedReviews = cached['allReviews'];
    if (cachedReviews is List) {
      _allReviews = cachedReviews
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
  }

  Future<void> _saveOwnProfileCacheToDisk() async {
    if (!_isOwnProfile) return;
    final uid = _viewingUserId ?? _contentUserId;
    if (uid == null || uid.isEmpty) return;

    final data = {
      'handle': _handle,
      'photoUrl': _photoUrl,
      'userName': _userName,
      'contentUserId': _contentUserId,
      'totalLikes': _totalLikes,
      'reviewCount': _reviewCount,
      'uniqueRecipesTried': _uniqueRecipesTried,
      'monthlyCookingSessions': _monthlyCookingSessions,
      'lastMonthCookingSessions': _lastMonthCookingSessions,
      'consecutiveStreak': _consecutiveStreak,
      'followersCount': _followersCount,
      'followingCount': _followingCount,
      'allReviews': _reviewsForCache(_allReviews),
    };
    ProfileScreen._warmOwnProfileCache = {
      'uid': uid,
      ...data,
    };

    await _localStorageService.saveOwnProfileCache(
      uid: uid,
      data: data,
    );
  }

  bool get _hasProfileHeaderContent =>
      _contentUserId != null ||
      _handle.isNotEmpty ||
      (_userName?.isNotEmpty ?? false) ||
      (_photoUrl?.isNotEmpty ?? false);

  DateTime? _reviewCreatedAt(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    return null;
  }

  List<Map<String, dynamic>> _reviewsForCache(
    List<Map<String, dynamic>> reviews,
  ) {
    return reviews.take(80).map((review) {
      dynamic normalize(dynamic value) {
        if (value is Timestamp) return value.toDate().toIso8601String();
        if (value is DateTime) return value.toIso8601String();
        if (value is List) return value.map(normalize).toList();
        if (value is Map) {
          return value.map((key, val) => MapEntry(key.toString(), normalize(val)));
        }
        if (value == null ||
            value is String ||
            value is num ||
            value is bool) {
          return value;
        }
        return value.toString();
      }

      return review.map((key, value) => MapEntry(key, normalize(value)));
    }).toList();
  }

  int _monthlyCookingSessionsFromReviews(List<Map<String, dynamic>> reviews) {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final startOfNextMonth = DateTime(now.year, now.month + 1, 1);
    return reviews.where((review) {
      final createdAt = _reviewCreatedAt(review['createdAt']);
      if (createdAt == null) return false;
      return !createdAt.isBefore(startOfMonth) &&
          createdAt.isBefore(startOfNextMonth);
    }).length;
  }

  int _lastMonthCookingSessionsFromReviews(List<Map<String, dynamic>> reviews) {
    final now = DateTime.now();
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final startOfMonth = DateTime(now.year, now.month, 1);
    return reviews.where((review) {
      final createdAt = _reviewCreatedAt(review['createdAt']);
      if (createdAt == null) return false;
      return !createdAt.isBefore(lastMonth) && createdAt.isBefore(startOfMonth);
    }).length;
  }

  int _consecutiveStreakFromReviews(List<Map<String, dynamic>> reviews) {
    if (reviews.isEmpty) return 0;

    final sorted = List<Map<String, dynamic>>.from(reviews)
      ..sort((a, b) {
        final aMs = _reviewCreatedAt(a['createdAt'])?.millisecondsSinceEpoch ?? 0;
        final bMs = _reviewCreatedAt(b['createdAt'])?.millisecondsSinceEpoch ?? 0;
        return bMs.compareTo(aMs);
      });

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var streak = 0;
    DateTime? expectedDate = today;

    for (final review in sorted) {
      final createdAt = _reviewCreatedAt(review['createdAt']);
      if (createdAt == null || expectedDate == null) continue;

      final reviewDate = DateTime(
        createdAt.year,
        createdAt.month,
        createdAt.day,
      );

      if (reviewDate == expectedDate) {
        streak++;
        expectedDate = expectedDate.subtract(const Duration(days: 1));
      } else if (reviewDate.isBefore(expectedDate)) {
        break;
      }
    }

    return streak;
  }

  ({
    int reviewCount,
    int totalLikes,
    int uniqueRecipes,
    int monthlySessions,
    int lastMonthSessions,
    int consecutiveStreak,
  }) _deriveStatsFromReviews(List<Map<String, dynamic>> allReviews) {
    var totalLikes = 0;
    final uniqueRecipeIds = <String>{};
    for (final review in allReviews) {
      totalLikes += (review['likeCount'] as num?)?.toInt() ?? 0;
      final recipeId = review['recipeId'] as String?;
      if (recipeId != null && recipeId.isNotEmpty) {
        uniqueRecipeIds.add(recipeId);
      }
    }

    return (
      reviewCount: allReviews.length,
      totalLikes: totalLikes,
      uniqueRecipes: uniqueRecipeIds.length,
      monthlySessions: _monthlyCookingSessionsFromReviews(allReviews),
      lastMonthSessions: _lastMonthCookingSessionsFromReviews(allReviews),
      consecutiveStreak: _consecutiveStreakFromReviews(allReviews),
    );
  }

  void _resetActivityDataState() {
    _activityDataLoaded = false;
    _activityDataLoadFuture = null;
    _isLoadingActivity = false;
    _dailyStreakActions = <String, Set<String>>{};
    _phase1UserData = null;
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextViewingUserId = widget.userId ?? _auth.currentUser?.uid;
    if (oldWidget.userId == widget.userId &&
        _viewingUserId == nextViewingUserId) {
      return;
    }

    _viewingUserId = nextViewingUserId;
    _isOwnProfile =
        widget.userId == null || widget.userId == _auth.currentUser?.uid;
    _reviewCountSub?.cancel();
    setState(() {
      _resetActivityDataState();
      _handle = '';
      _photoUrl = null;
      _userName = null;
      _contentUserId = null;
      _allReviews = [];
      _totalLikes = 0;
      _reviewCount = 0;
      _uniqueRecipesTried = 0;
      _monthlyCookingSessions = 0;
      _lastMonthCookingSessions = 0;
      _consecutiveStreak = 0;
      _followersCount = 0;
      _followingCount = 0;
      _attendanceDays = {};
      _cookingDays = {};
      _isLoading = true;
      _isLoadingSecondary = false;
      _hydratedFromCache = false;
    });
    _subscribeReviewCount();
    unawaited(_loadProfileData(force: true));
  }

  void _onLiveExpTotal() {
    if (!mounted || !_isOwnProfile) return;
    final next = RewardsService.instance.expTotalListenable.value;
    if (next == _expTotal) return;
    setState(() {
      _expTotal = next;
      _hasExpTotal = true;
      _rewardsLevel = yorigoLevelFromExp(next);
    });
  }

  @override
  void dispose() {
    RewardsService.instance.expTotalListenable.removeListener(_onLiveExpTotal);
    _reviewCountSub?.cancel();
    _profileRefreshSub?.cancel();
    _followNotifier.dispose();
    super.dispose();
  }

  /// 후기 컬렉션을 실시간 구독.
  /// 카운트가 바뀌면 (작성/삭제) 전체 통계를 다시 로드해서
  /// 레벨/진행률/요리 횟수 등이 일관되게 갱신되도록 함.
  void _subscribeReviewCount() {
    final targetUserId = _viewingUserId;
    if (targetUserId == null) return;
    _reviewCountSub?.cancel();
    _reviewCountSub = _userService.streamReviewCount(targetUserId).listen((
      newCount,
    ) {
      if (!mounted) return;
      // 초기 로드 중에는 _loadProfileData가 곧 동기화하므로 스킵.
      if (_isLoading || _isLoadingSecondary) return;
      // 카운트가 바뀐 경우에만 (작성/삭제) 전체 통계 재로딩.
      if (newCount != _reviewCount) {
        _loadProfileData(force: true);
      }
    });
  }

  Future<void> _loadProfileData({bool force = false}) async {
    if (!force && _lastProfileLoadAt != null) {
      final elapsed = DateTime.now().difference(_lastProfileLoadAt!);
      if (elapsed < const Duration(seconds: 60)) return;
    }
    // Coalesce concurrent loads (tab refresh + bootstrap).
    if (_loadProfileDataFuture != null) {
      return _loadProfileDataFuture!;
    }
    _lastProfileLoadAt = DateTime.now();
    final future = _loadProfileDataBody(force: force);
    _loadProfileDataFuture = future;
    try {
      await future;
    } finally {
      if (identical(_loadProfileDataFuture, future)) {
        _loadProfileDataFuture = null;
      }
    }
  }

  Future<void> _loadProfileDataBody({required bool force}) async {
    final currentUser = _auth.currentUser;
    final targetUserId = _viewingUserId;

    if (targetUserId == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingSecondary = false;
          _contentUserId = null;
        });
      }
      return;
    }

    final hadHeaderContent = _hasProfileHeaderContent;
    final hadDiaryContent = _allReviews.isNotEmpty || _hydratedFromCache;
    if (mounted) {
      setState(() {
        if (force) {
          _activityDataLoaded = false;
          _activityDataLoadFuture = null;
          _dailyStreakActions = <String, Set<String>>{};
        }
        if (!hadHeaderContent) {
          _isLoading = true;
        }
        // Keep cached diary visible; only spin when we have nothing to show.
        if (!hadDiaryContent) {
          _isLoadingSecondary = true;
        }
      });
    }

    try {
      // ── Phase 1: header (user doc + follow counts) ──
      final phase1Results = await Future.wait<dynamic>([
        _userService.getUserDocument(targetUserId),
        _userService.getFollowersCount(targetUserId),
        _userService.getFollowingCount(targetUserId),
        if (_isOwnProfile && currentUser != null)
          AdminService.instance.isAdmin()
        else
          Future<bool>.value(false),
      ]);

      final userDoc = phase1Results[0] as DocumentSnapshot;
      final followersCount = phase1Results[1] as int;
      final followingCount = phase1Results[2] as int;
      final isAdminUser = phase1Results[3] as bool;

      final userData = userDoc.data() as Map<String, dynamic>?;
      _phase1UserData = userData;
      _handle = userData?['handle'] as String? ?? '';
      _photoUrl = userData != null ? resolveUserPhotoUrl(userData) : null;
      _userName = userData?['name'] as String?;
      final hasExpTotal = userData != null && userData.containsKey('expTotal');
      final expTotal = (userData?['expTotal'] as num?)?.toInt() ?? 0;
      final pointsBalance = (userData?['pointsBalance'] as num?)?.toInt() ?? 0;
      final pointsLifetime =
          (userData?['pointsLifetimeEarned'] as num?)?.toInt() ?? 0;
      if (userData != null && (_photoUrl == null || _photoUrl!.isEmpty)) {
        print(
          '[ProfileScreen] No photo resolved for $targetUserId. '
          'Keys=${userData.keys.toList()} '
          'Values=${userData.entries.where((e) => e.key.toLowerCase().contains('photo') || e.key.toLowerCase().contains('image') || e.key.toLowerCase().contains('avatar') || e.key.toLowerCase().contains('picture')).map((e) => '${e.key}=${e.value}').toList()}',
        );
      }
      final documentUid = (userData?['uid'] as String?)?.trim();
      final contentUserId = documentUid != null && documentUid.isNotEmpty
          ? documentUid
          : targetUserId;

      if (_handle.isEmpty && _isOwnProfile && currentUser != null) {
        _handle = await _userService.getOrGenerateHandle(
          currentUser.uid,
          currentUser.displayName ?? 'user',
        );
      }

      if (mounted) {
        setState(() {
          _contentUserId = contentUserId;
          _followersCount = followersCount;
          _followingCount = followingCount;
          _isAdminUser = isAdminUser;
          _hasExpTotal = hasExpTotal;
          _expTotal = expTotal;
          _rewardsLevel = yorigoLevelFromUserData(userData ?? {});
          if (_isOwnProfile && hasExpTotal) {
            RewardsService.instance.seedExpTotal(expTotal);
            _expTotal = RewardsService.instance.expTotalListenable.value;
            _hasExpTotal = true;
            _rewardsLevel = yorigoLevelFromExp(_expTotal);
          }
          _pointsBalance = pointsBalance;
          _pointsLifetimeEarned = pointsLifetime;
          _isLoading = false;
        });
        _syncFollowNotifier();
      }

      if (!_isOwnProfile) {
        unawaited(_loadFollowStatus());
      }

      // ── Phase 2a: reviews first so diary paints ASAP ──
      // 내 다이어리는 「나만 보기」(isHidden=true) 포함. 타인 프로필은 공개만.
      final allReviews = await _reviewService.getUserReviewsByAnyIdentifier(
        userIds: <String>{targetUserId, contentUserId}.toList(),
        handle: _handle,
        includeHidden: _isOwnProfile,
      );

      print(
        '[ProfileScreen] Loaded ${allReviews.length} reviews for '
        'viewing=$targetUserId, content=$contentUserId, handle=$_handle',
      );

      final stats = _deriveStatsFromReviews(allReviews);
      if (mounted) {
        setState(() {
          _totalLikes = stats.totalLikes;
          _reviewCount = stats.reviewCount;
          _uniqueRecipesTried = stats.uniqueRecipes;
          _monthlyCookingSessions = stats.monthlySessions;
          _lastMonthCookingSessions = stats.lastMonthSessions;
          _consecutiveStreak = stats.consecutiveStreak;
          _allReviews = allReviews;
          _selectedCalendarDay ??= _startOfDay(DateTime.now());
          _isLoadingSecondary = false;
        });
        _syncFollowNotifier();
        unawaited(_saveOwnProfileCacheToDisk());
      }

      // ── Phase 2b: streak / attendance — does not block diary ──
      unawaited(
        _loadStreakAndAttendance(
          targetUserId: targetUserId,
          currentUser: currentUser,
        ),
      );
    } catch (e) {
      print('[ProfileScreen] Error loading profile data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingSecondary = false;
        });
      }
    }
  }

  Future<void> _loadStreakAndAttendance({
    required String targetUserId,
    required User? currentUser,
  }) async {
    try {
      final userStreakDays = await _userService.getUserStreakDays(
        targetUserId,
        forceServer: false,
      );
      final attendanceDays = Set<String>.from(userStreakDays.attendanceDays);
      if (_isOwnProfile && currentUser != null) {
        // [임시 비활성] 출석 포인트
        // unawaited(_userService.claimDailyAttendanceReward(targetUserId));
        attendanceDays.add(_dayKey(DateTime.now()));
      }
      if (!mounted) return;
      setState(() {
        _attendanceDays = attendanceDays;
        _cookingDays = userStreakDays.cookingDays;
      });
    } catch (e) {
      print('[ProfileScreen] Streak/attendance load skipped: $e');
    }
  }

  /// Phase 3: heavy streak-action aggregation — only when activity tab opens.
  Future<void> _ensureActivityDataLoaded() async {
    if (_activityDataLoaded) return;
    if (_activityDataLoadFuture != null) {
      await _activityDataLoadFuture;
      return;
    }

    final targetUserId = _viewingUserId;
    if (targetUserId == null) return;

    _activityDataLoadFuture = _loadActivityPhase3(targetUserId);
    await _activityDataLoadFuture;
  }

  Future<void> _loadActivityPhase3(String contentUserId) async {
    if (!mounted) return;
    setState(() => _isLoadingActivity = true);

    try {
      final dailyStreakActions = await _loadDailyStreakActions(
        targetUserId: contentUserId,
        userData: _phase1UserData,
      );

      if (mounted) {
        setState(() {
          _dailyStreakActions = dailyStreakActions;
          _activityDataLoaded = true;
          _isLoadingActivity = false;
        });
      }
    } catch (e) {
      print('[ProfileScreen] Error loading activity data: $e');
      if (mounted) {
        setState(() {
          _activityDataLoaded = true;
          _isLoadingActivity = false;
        });
      }
    } finally {
      _activityDataLoadFuture = null;
    }
  }

  /// 팔로우 상태 확인 및 로드
  Future<void> _loadFollowStatus() async {
    if (_isOwnProfile || _viewingUserId == null) {
      return;
    }

    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return;
    }

    _isLoadingFollowStatus = true;
    _syncFollowNotifier();

    try {
      final isFollowing = await _userService.isUserFollowing(
        currentUser.uid,
        _viewingUserId!,
      );

      if (mounted) {
        _isFollowing = isFollowing;
        _isLoadingFollowStatus = false;
        _syncFollowNotifier();
      }
    } catch (e) {
      print('[ProfileScreen] Error loading follow status: $e');
      if (mounted) {
        _isLoadingFollowStatus = false;
        _syncFollowNotifier();
      }
    }
  }

  Future<Map<String, Set<String>>> _loadDailyStreakActions({
    required String targetUserId,
    required Map<String, dynamic>? userData,
  }) async {
    final Map<String, Set<String>> actionMap = <String, Set<String>>{};

    void addAction(DateTime? dateTime, String actionType) {
      if (dateTime == null) return;
      final day = _startOfDay(dateTime.toLocal());
      final key = _dayKey(day);
      actionMap.putIfAbsent(key, () => <String>{}).add(actionType);
    }

    DateTime? dateFromDynamic(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is int) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    void parseFeedFirstSavedActions(Map<String, dynamic>? rawUserData) {
      if (rawUserData == null) return;
      final feedFirstSavedAtRaw = rawUserData['feedFirstSavedAt'];
      if (feedFirstSavedAtRaw is Map) {
        final map = Map<String, dynamic>.from(feedFirstSavedAtRaw);
        for (final ts in map.values) {
          addAction(dateFromDynamic(ts), _actionSaveRecipe);
        }
      }

      for (final entry in rawUserData.entries) {
        if (!entry.key.startsWith('feedFirstSavedAt.')) {
          continue;
        }
        addAction(dateFromDynamic(entry.value), _actionSaveRecipe);
      }
    }

    void parseCartActions(Map<String, dynamic>? rawUserData) {
      if (rawUserData == null) return;
      final cartItemsRaw = rawUserData['cartItems'];
      if (cartItemsRaw is! List) return;
      for (final item in cartItemsRaw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final hasScheduledDate = map['scheduledDate'] != null;
        if (!hasScheduledDate) continue;
        addAction(
          dateFromDynamic(map['addedAt']) ??
              dateFromDynamic(map['scheduledDate']),
          _actionAddScheduledCart,
        );
      }
    }

    parseFeedFirstSavedActions(userData);
    parseCartActions(userData);

    // 활동 캘린더는 최근 12개월만 보여주므로, 그보다 오래된 문서까지 매번 전량
    // 스캔할 필요가 없다. 계정이 오래되고 레시피/식단이 쌓일수록 무한정 커지던
    // 비용을 최근 구간으로 상한선을 둬 억제한다.
    final activityWindowStart = DateTime.now().subtract(const Duration(days: 365));
    final activityWindowStartKey = _dayKey(activityWindowStart);

    try {
      final recipesSnapshot = await FirebaseFirestore.instance
          .collection('recipes')
          .where('userId', isEqualTo: targetUserId)
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(activityWindowStart),
          )
          .get();
      for (final doc in recipesSnapshot.docs) {
        final data = doc.data();
        addAction(
          dateFromDynamic(data['parsingStartedAt']),
          _actionParseRecipe,
        );
      }
    } catch (e) {
      print('[ProfileScreen] parse actions load skipped: $e');
    }

    try {
      final mealPlansSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUserId)
          .collection('mealPlans')
          .where('dateKey', isGreaterThanOrEqualTo: activityWindowStartKey)
          .get();
      for (final doc in mealPlansSnapshot.docs) {
        final data = doc.data();
        final completedSlots = data['completedSlots'] as List? ?? const [];
        final completedRecipes = data['completedRecipes'] as List? ?? const [];
        final hasCompletedScheduledCooking =
            completedSlots.isNotEmpty || completedRecipes.isNotEmpty;
        if (!hasCompletedScheduledCooking) continue;

        final dateKey = (data['dateKey'] ?? doc.id).toString();
        final day = _dateFromDateKey(dateKey);
        addAction(day, _actionCompleteScheduledCooking);
      }
    } catch (e) {
      print('[ProfileScreen] meal plan actions load skipped: $e');
    }

    return actionMap;
  }

  /// 팔로우/언팔로우 핸들러 (optimistic update)
  Future<void> _handleFollowToggle() async {
    if (_viewingUserId == null || _isLoadingFollowStatus) return;

    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final wasFollowing = _isFollowing;
    final prevFollowers = _followersCount;

    // Optimistic flip — update only the follow notifier so the rest of the
    // profile tree does not rebuild.
    _isFollowing = !wasFollowing;
    _isLoadingFollowStatus = true;
    if (wasFollowing) {
      if (_followersCount != null && _followersCount! > 0) {
        _followersCount = _followersCount! - 1;
      }
    } else {
      _followersCount = (_followersCount ?? 0) + 1;
    }
    _syncFollowNotifier();

    try {
      if (wasFollowing) {
        await _userService.unfollowUser(currentUser.uid, _viewingUserId!);
      } else {
        await _userService.followUser(currentUser.uid, _viewingUserId!);
      }

      if (mounted) {
        _isLoadingFollowStatus = false;
        _syncFollowNotifier();
      }
    } catch (e) {
      print('[ProfileScreen] Error toggling follow: $e');
      // Revert on failure
      if (mounted) {
        _isFollowing = wasFollowing;
        _followersCount = prevFollowers;
        _isLoadingFollowStatus = false;
        _syncFollowNotifier();

        showAppSnackBar(context, 
          SnackBar(
            content: Text('오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 27),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 30,
                offset: Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '로그아웃 하시겠습니까?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.45,
                        color: Color(0xFF191F28),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 55.167,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(dialogContext).pop(false),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                color: Color(0xFFF2F4F6),
                                width: 0.667,
                              ),
                            ),
                          ),
                          child: const Text(
                            '취소',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                              color: Color(0xFF4E5968),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(dialogContext).pop(true),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          child: const Text(
                            '로그아웃',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      await _authService.signOut();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    }
  }

  void _openAdminPostManagementScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const AdminPostManagementScreen(),
      ),
    );
  }

  void _openAdminPurchaseVerificationScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const AdminPurchaseVerificationScreen(),
      ),
    );
  }

  int _expThresholdForLevel(int level) => yorigoExpRequiredForLevel(level);

  double _expProgressToNextLevel() {
    final level = _displayLevel;
    final cur = _expThresholdForLevel(level);
    final next = _expThresholdForLevel(level + 1);
    if (next <= cur) return 1.0;
    if (!_hasExpTotal) return 0.0;
    return ((_expTotal - cur) / (next - cur)).clamp(0.0, 1.0);
  }

  int _expToNextLevel() {
    final level = _displayLevel;
    final next = _expThresholdForLevel(level + 1);
    if (!_hasExpTotal) {
      final cur = _expThresholdForLevel(level);
      return (next - cur).clamp(0, next);
    }
    return (next - _expTotal).clamp(0, next);
  }

  Future<void> _openRewardHistorySheet({required String track}) async {
    if (!_isOwnProfile) return;
    final isPoints = track == 'points';
    final title = isPoints ? '포인트 내역' : '경험치 내역';
    final emptyLabel =
        isPoints ? '아직 적립된 포인트가 없어요' : '아직 적립된 경험치가 없어요';
    final unit = isPoints ? 'P' : 'EXP';
    final accent = isPoints ? const Color(0xFFFF6B00) : const Color(0xFF2563EB);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return FutureBuilder<List<RewardLedgerEntry>>(
              future: RewardsService.instance.getHistory(
                track: track,
                limit: 50,
              ),
              builder: (context, snapshot) {
                final entries = snapshot.data ?? const <RewardLedgerEntry>[];
                return Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(100),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: snapshot.connectionState == ConnectionState.waiting
                          ? const Center(child: CircularProgressIndicator())
                          : entries.isEmpty
                              ? Center(
                                  child: Text(
                                    emptyLabel,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      color: Color(0xFF6A7282),
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  controller: scrollController,
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    24,
                                  ),
                                  itemCount: entries.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final e = entries[index];
                                    final sign = e.amount >= 0 ? '+' : '';
                                    return ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        _rewardActionLabel(e.action),
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      subtitle: e.createdAt == null
                                          ? null
                                          : Text(
                                              e.createdAt!
                                                  .toLocal()
                                                  .toString()
                                                  .split('.')
                                                  .first,
                                              style: const TextStyle(
                                                fontFamily: 'Pretendard',
                                                fontSize: 11,
                                                color: Color(0xFF9CA3AF),
                                              ),
                                            ),
                                      trailing: Text(
                                        '$sign${e.amount}$unit',
                                        style: TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                          color: e.amount >= 0
                                              ? accent
                                              : const Color(0xFFEF4444),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _rewardActionLabel(String action) {
    switch (action) {
      case 'points_attendance':
        return '출석';
      case 'points_streak_7':
        return '연속출석 7일 보너스';
      case 'points_streak_14':
        return '연속출석 14일 보너스';
      case 'points_streak_30':
        return '연속출석 30일 보너스';
      case 'points_cart_add':
        return '장바구니 담기';
      case 'points_purchase_self_report':
        return '구매완료';
      case 'points_purchase_photo_verified':
        return '구매완료 사진인증';
      case 'points_like':
        return '좋아요';
      case 'points_comment':
        return '댓글';
      case 'points_post_created':
        return '게시물 작성';
      case 'points_post_created_low_quality':
        return '게시물 작성';
      case 'points_post_popular':
        return '인기 게시물 보너스';
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
        return action;
    }
  }

  void _openReceivedLikesList() {
    final uid = _contentUserId ?? _viewingUserId;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ReceivedLikesListScreen(userId: uid),
      ),
    );
  }

  void _openAllUserReviewsList() {
    final uid = _contentUserId ?? _viewingUserId;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => UserReviewsListScreen(userId: uid),
      ),
    );
  }

  void _openFollowersList() {
    final uid = _viewingUserId;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            FollowListScreen(userId: uid, kind: FollowListKind.followers),
      ),
    );
  }

  void _openFollowingList() {
    final uid = _viewingUserId;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            FollowListScreen(userId: uid, kind: FollowListKind.following),
      ),
    );
  }

  /// Diary: pick a saved recipe, then open the progressive review sheet (same as fridge flow).
  Future<void> _openAddCookingRecord() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (!_isOwnProfile) return;

    final picked = await PickRecipeForReviewSheet.show(context);
    if (!mounted || picked == null || picked.recipeId.isEmpty) return;
    final recipeId = picked.recipeId;

    if (recipeId == PickRecipeForReviewSheet.directReviewId) {
      await showProgressiveRecipeReviewPopup(
        context,
        recipeId: '',
        recipeTitle: '나의 요리',
        creatorUsername: '',
        platform: 'manual',
        servings: 1,
        fromFridgeCookingComplete: false,
        fromCookingFlow: false,
        isFreeform: true,
        cookedAt: picked.cookedAt,
      );
      if (mounted) {
        await _loadProfileData(force: true);
      }
      return;
    }

    final parseResponse = await RecipeService.shared.getRecipeById(recipeId);
    if (!mounted) return;
    if (parseResponse == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('레시피를 불러올 수 없습니다'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final source = parseResponse.source;
    final recipeModel = parseResponse.recipe;
    String creatorUsername = '@ChefAntoine';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    if (uploader.isNotEmpty) {
      creatorUsername = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creatorUsername = channel.startsWith('@') ? channel : '@$channel';
    }
    final platform = source['platform'] as String? ?? '';
    final thumbnailUrl = source['thumbnail'] as String?;
    final recipeTitle = recipeModel.name ?? '레시피';
    final servings = recipeModel.servings ?? 2;

    await showProgressiveRecipeReviewPopup(
      context,
      recipeId: recipeId,
      recipeTitle: recipeTitle,
      creatorUsername: creatorUsername,
      platform: platform,
      thumbnailUrl: thumbnailUrl,
      servings: servings,
      fromFridgeCookingComplete: false,
      cookedAt: picked.cookedAt,
    );

    if (mounted) {
      await _loadProfileData(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _isOwnProfile
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(44),
              child: AppBar(
                backgroundColor: Colors.white,
                elevation: 0,
                toolbarHeight: 44,
                leadingWidth: 48,
                leading: IconButton(
                  padding: EdgeInsets.zero,
                  splashRadius: 20,
                  icon: Icon(
                    Icons.arrow_back,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                centerTitle: false,
              ),
            ),
      body: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: 'Pretendard'),
        child: ColoredBox(
          color: Colors.white,
          // 하단 inset은 MainNavigator bottom nav가 소유한다.
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (_isOwnProfile)
                  AppHeader(
                    onLoginPressed: () {
                      Navigator.pushNamed(context, '/login');
                    },
                    showCustomerCenterIcon: true,
                    showProfileIcon: true,
                    showRewardsBadge: false,
                  ),
                Expanded(
                  child: StreamBuilder<User?>(
                    stream: _authService.authStateChanges,
                    initialData: _authService.currentUser,
                    builder: (context, snapshot) {
                      // Wait for auth state only on the very first frame to
                      // avoid an empty body before we know which UI to show.
                      if ((snapshot.connectionState == ConnectionState.waiting ||
                              shouldIgnoreTransientAuthNull()) &&
                          snapshot.data == null &&
                          !_hasProfileHeaderContent &&
                          !_hydratedFromCache) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        );
                      }

                      final user = snapshot.data;

                      // If viewing own profile and not logged in, show login prompt
                      if (user == null && _isOwnProfile) {
                        return _buildLoginPrompt(brightness);
                      }

                      // If viewing other user's profile, don't require login
                      if (!_isOwnProfile && _viewingUserId == null) {
                        return Center(
                          child: Text(
                            '사용자를 찾을 수 없습니다',
                            style: TextStyle(
                              color: AppColors.getTextSecondary(brightness),
                            ),
                          ),
                        );
                      }

                      if (_isLoading && !_hasProfileHeaderContent) {
                        return _buildProfileLoadingSkeleton(brightness);
                      }

                      return Container(
                        color: const Color(0xFFF9FAFB),
                        child: _ProfileTabSection(
                          key: ValueKey(_viewingUserId),
                          // 프로필 헤더를 스크롤 안으로 넣어 위까지 통째로 드래그되게 함.
                          // IndexedStack이 양쪽 탭을 동시에 유지하므로 빌더로 각각 생성.
                          headerBuilder: () => RepaintBoundary(
                            child: _buildFigmaProfileHeader(brightness),
                          ),
                          diaryContent: !_hydratedFromCache &&
                                  _isLoadingSecondary &&
                                  _allReviews.isEmpty
                              ? const ProfileDiaryShimmer()
                              : _buildDiaryTabContent(brightness),
                          activityContent: _isLoadingActivity
                              ? const ProfileActivityShimmer()
                              : _buildFigmaActivityTabContent(
                                  brightness,
                                ),
                          onRefresh: () => _loadProfileData(force: true),
                          onActivityTabSelected: () =>
                              unawaited(_ensureActivityDataLoaded()),
                          isOwnProfile: _isOwnProfile,
                          showDiaryAddButton:
                              _isOwnProfile && _allReviews.isNotEmpty,
                          onDiaryAddPressed: _openAddCookingRecord,
                          diaryViewMode: _diaryViewMode,
                          onDiaryViewModeChanged: _setDiaryViewMode,
                          showDiaryViewToggle: _allReviews.isNotEmpty,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginPrompt(Brightness brightness) {
    return Stack(
      children: [
        const GuestLockedPreviewBackdrop(asset: 'assets/profile_preview.png'),
        GuestLockedPromptAlign(
          child: Container(
            width: 272,
            padding: const EdgeInsets.all(27),
            decoration: ShapeDecoration(
              color: Colors.white.withValues(alpha: 0.80),
              shape: RoundedRectangleBorder(
                side: const BorderSide(width: 0.57, color: Colors.white),
                borderRadius: BorderRadius.circular(27),
              ),
              shadows: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 51,
                  offset: Offset(0, 20),
                  spreadRadius: -10,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: ShapeDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment(0.00, 1.00),
                      end: Alignment(1.00, 0.00),
                      colors: [Colors.white, Color(0xFFF9FAFB)],
                    ),
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(width: 0.57, color: Colors.white),
                      borderRadius: BorderRadius.circular(22369600),
                    ),
                    shadows: const [
                      BoxShadow(
                        color: Color(0x0C000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/icons/nav_profile.png',
                      width: 24,
                      height: 24,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '나만의 프로필을 만들어보세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 17,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                    letterSpacing: -0.42,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '요리 기록과 레시피를 저장하고\n나의 요리 여정을 시작해 보세요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 11,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w500,
                    height: 1.60,
                    letterSpacing: -0.27,
                  ),
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/login'),
                  child: Container(
                    width: double.infinity,
                    height: 46,
                    decoration: ShapeDecoration(
                      color: const Color(0xFF111111),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      shadows: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 17,
                          offset: Offset(0, 7),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '3초 만에 로그인하기',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                        letterSpacing: -0.32,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _safeNum(int? v) => (v ?? 0).toString();

  Widget _buildProfileLoadingSkeleton(Brightness brightness) {
    const skeletonColor = Color(0xFFE5E7EB);
    final topPadding = _isOwnProfile ? 24.0 : 8.0;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(20, topPadding, 20, 20),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: skeletonColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 120,
                      height: 18,
                      decoration: BoxDecoration(
                        color: skeletonColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 88,
                      height: 14,
                      decoration: BoxDecoration(
                        color: skeletonColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: List.generate(
                        3,
                        (_) => Expanded(
                          child: Container(
                            height: 36,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: skeletonColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: AppColors.primary),
                const SizedBox(height: 12),
                Text(
                  '프로필 불러오는 중…',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.getTextSecondary(brightness),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const double _contentPaddingH = 20.0;

  /// 리퀴드 디자인: 유기적 형태를 위한 큰 radius
  static const double _cardRadius = 22.0;
  static const double _sectionTitleSize = 17.0;

  /// 리퀴드 디자인: 부드러운 깊이감 (다층 그림자)
  static List<BoxShadow> _liquidShadow({
    double opacity = 0.04,
    double spread = 0,
  }) {
    return [
      BoxShadow(
        color: Colors.black.withOpacity(opacity * 0.6),
        blurRadius: 6,
        offset: const Offset(0, 1),
        spreadRadius: spread,
      ),
      BoxShadow(
        color: Colors.black.withOpacity(opacity),
        blurRadius: 12,
        offset: const Offset(0, 4),
        spreadRadius: spread,
      ),
    ];
  }

  Widget _buildProfileSection(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);
    final level = _displayLevel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary, width: 1.5),
                  boxShadow: _liquidShadow(opacity: 0.05),
                ),
                child: ClipOval(
                  child: _photoUrl != null && _photoUrl!.isNotEmpty
                      ? Image(
                          image: AppNetworkImage.imageProviderForAvatar(
                            _photoUrl!,
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _profilePhotoPlaceholder(),
                        )
                      : _profilePhotoPlaceholder(),
                ),
              ),
              Positioned(
                bottom: -1,
                right: -1,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.2),
                    boxShadow: _liquidShadow(opacity: 0.08),
                  ),
                  child: Center(
                    child: Text(
                      '$level',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _userName ?? (_handle.isNotEmpty ? _handle : '사용자'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                    letterSpacing: -0.4,
                    height: 1.25,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '@$_handle',
                  style: TextStyle(
                    fontSize: 12,
                    color: textSecondary,
                    letterSpacing: -0.2,
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 34,
            child: ValueListenableBuilder<
                ({bool isFollowing, int? followersCount, bool isLoading})>(
              valueListenable: _followNotifier,
              builder: (context, follow, _) {
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: follow.isLoading
                        ? null
                        : () {
                            if (_isOwnProfile) {
                              final user = _auth.currentUser;
                              if (user != null) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ProfileEditScreen(
                                      user: user,
                                      onSaved: () => _loadProfileData(force: true),
                                    ),
                                  ),
                                );
                              }
                            } else {
                              _handleFollowToggle();
                            }
                          },
                    borderRadius: BorderRadius.circular(17),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: _isOwnProfile
                              ? [
                                  AppColors.primary,
                                  AppColors.primary.withOpacity(0.88),
                                ]
                              : (follow.isFollowing
                                    ? [Colors.red, Colors.red.withOpacity(0.88)]
                                    : [
                                        AppColors.primary,
                                        AppColors.primary.withOpacity(0.88),
                                      ]),
                        ),
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        alignment: Alignment.center,
                        child: follow.isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Text(
                                _isOwnProfile
                                    ? '프로필 편집'
                                    : (follow.isFollowing ? '언팔로우' : '팔로우'),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.3,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelSection(Brightness brightness) {
    final level = _displayLevel;
    final levelName = yorigoLevelSpoonName(level);
    final expToNext = _expToNextLevel();
    final progress = _expProgressToNextLevel();
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);
    final isDark = brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.getBackgroundSecondary(brightness)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF3A3A3A)
                    : const Color(0xFFE8E8E8),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$level',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF333333),
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '요리고 레벨 $level $levelName',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                      letterSpacing: -0.3,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: const Color(0xFFE8E8E8),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFFFF7F00),
                      ),
                    ),
                  ),
                  if (expToNext > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      '다음 레벨까지 $expToNext EXP',
                      style: TextStyle(
                        fontSize: 11,
                        color: textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _hasExpTotal ? '$_expTotal EXP' : '활동 반영 전',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFF7F00),
                letterSpacing: -0.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profilePhotoPlaceholder({double size = 56}) {
    final handle = _handle.trim();
    final name = (_userName ?? '').trim();
    final seedCandidate = _contentUserId?.trim().isNotEmpty == true
        ? _contentUserId!.trim()
        : (_viewingUserId?.trim().isNotEmpty == true
              ? _viewingUserId!.trim()
              : (handle.isNotEmpty ? handle : name));
    final displayName = name.isNotEmpty
        ? name
        : (handle.isNotEmpty ? handle : '요리친구');
    return UserInitialAvatar(
      seed: seedCandidate,
      name: displayName,
      size: size,
    );
  }

  Widget _buildStatsSection(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.getBackgroundSecondary(brightness),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.getBorder(brightness), width: 1),
          boxShadow: _liquidShadow(opacity: 0.02),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _safeNum(_reviewCount),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '요리 횟수',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 1,
              height: 24,
              color: AppColors.getBorder(brightness),
            ),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _openFollowersList,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<
                            ({bool isFollowing, int? followersCount, bool isLoading})>(
                          valueListenable: _followNotifier,
                          builder: (context, follow, _) {
                            return Text(
                              _safeNum(follow.followersCount),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: textPrimary,
                                letterSpacing: -0.3,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '팔로워',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: 1,
              height: 24,
              color: AppColors.getBorder(brightness),
            ),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _openFollowingList,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _safeNum(_followingCount),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '팔로잉',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Figma 184-4: Profile header card (white, rounded bottom, shadow)
  Widget _buildFigmaProfileHeader(Brightness brightness) {
    final level = _displayLevel;
    // When viewing someone else's profile we render our own back AppBar above
    // this header, so trim the extra top padding that exists for the own-profile
    // layout (where AppHeader sits above).
    final topPadding = _isOwnProfile ? 24.0 : 8.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar with LV badge
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 64,
              height: 68,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFF3F4F6),
                        width: 0.67,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                          spreadRadius: -1,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: _photoUrl != null && _photoUrl!.isNotEmpty
                          ? Image(
                              image: AppNetworkImage.imageProviderForAvatar(
                                _photoUrl!,
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _profilePhotoPlaceholder(size: 64),
                            )
                          : _profilePhotoPlaceholder(size: 64),
                    ),
                  ),
                  Positioned(
                    right: -4,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white, width: 1.33),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                            spreadRadius: -1,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Text(
                        'LV.$level',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          height: 1.50,
                          letterSpacing: 0.25,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Name, handle, stats
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 4),
                Text(
                  _userName ?? (_handle.isNotEmpty ? _handle : '사용자'),
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF111111),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                    letterSpacing: -0.45,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '@$_handle',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF9CA3AF),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.50,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // 요리 / 팔로워 / 팔로잉 — 구분선으로 나뉜 탭 가능한 스탯
                Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildStatTab('$_reviewCount', '요리', null),
                        _buildStatDivider(),
                        ValueListenableBuilder<
                            ({
                              bool isFollowing,
                              int? followersCount,
                              bool isLoading,
                            })>(
                          valueListenable: _followNotifier,
                          builder: (context, follow, _) => _buildStatTab(
                            '${follow.followersCount ?? 0}',
                            '팔로워',
                            _openFollowersList,
                          ),
                        ),
                        _buildStatDivider(),
                        _buildStatTab(
                          '${_followingCount ?? 0}',
                          '팔로잉',
                          _openFollowingList,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Edit profile button (Figma 184:160)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () {
                if (_isOwnProfile) {
                  final user = _auth.currentUser;
                  if (user != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ProfileEditScreen(
                          user: user,
                          onSaved: () => _loadProfileData(force: true),
                        ),
                      ),
                    );
                  }
                } else {
                  _handleFollowToggle();
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10.67,
                  vertical: 6.67,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(
                    color: const Color(0xFFE5E7EB),
                    width: 0.67,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ValueListenableBuilder<
                    ({bool isFollowing, int? followersCount, bool isLoading})>(
                  valueListenable: _followNotifier,
                  builder: (context, follow, _) {
                    return Text(
                      _isOwnProfile
                          ? '프로필 편집'
                          : (follow.isFollowing ? '언팔로우' : '팔로우'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFF4B5563),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 요리/팔로워/팔로잉 스탯 탭 — pill 없이 깔끔한 텍스트형. onTap 있으면 탭 가능.
  Widget _buildStatTab(String value, String label, VoidCallback? onTap) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: Color(0xFF111111),
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              height: 1.2,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: Color(0xFF6B7280),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: const Color(0x14FF6B00),
        highlightColor: const Color(0x0AFF6B00),
        child: content,
      ),
    );
  }

  Widget _buildStatDivider() {
    return Container(
      width: 1,
      height: 11,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFE9EBEF),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  Widget _buildDiaryTabContent(Brightness brightness) {
    if (_allReviews.isEmpty || _diaryViewMode == _DiaryViewMode.grid) {
      return _buildDiaryGrid(
        brightness,
        onAddCookingRecord: _isOwnProfile ? _openAddCookingRecord : null,
      );
    }
    return _buildDiaryCalendarView();
  }

  /// Sunday-start week for the Instagram-style diary calendar.
  DateTime _startOfSundayWeek(DateTime dateTime) {
    final day = _startOfDay(dateTime);
    final delta = day.weekday % 7; // Sun=0, Mon=1, ... Sat=6
    return day.subtract(Duration(days: delta));
  }

  String? _asNonEmptyUrl(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      for (final key in const ['url', 'photoUrl', 'src', 'downloadUrl']) {
        final nested = _asNonEmptyUrl(value[key]);
        if (nested != null) return nested;
      }
      return null;
    }
    final s = value.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  /// Resolves primary review photo across legacy field variants.
  String? _reviewPhotoUrl(Map<String, dynamic> review) {
    final direct = _asNonEmptyUrl(review['photoUrl']);
    if (direct != null) return direct;
    final legacy = _asNonEmptyUrl(review['photo_url']);
    if (legacy != null) return legacy;
    for (final key in const ['photoUrls', 'photos', 'images', 'imageUrls']) {
      final raw = review[key];
      if (raw is List) {
        for (final item in raw) {
          final url = _asNonEmptyUrl(item);
          if (url != null) return url;
        }
      }
    }
    return null;
  }

  bool _reviewHasPhoto(Map<String, dynamic> review) =>
      _reviewPhotoUrl(review) != null;

  /// Newest review first; photo posts sort above text-only when timestamps tie.
  Map<String, List<Map<String, dynamic>>> _reviewsByDayInMonth(DateTime month) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    final byDay = <String, List<Map<String, dynamic>>>{};
    for (final review in _allReviews) {
      final at = reviewCookedOrCreatedAt(review);
      if (at == null) continue;
      final local = at.toLocal();
      if (local.isBefore(start) || !local.isBefore(end)) continue;
      final key = _dayKey(local);
      (byDay[key] ??= <Map<String, dynamic>>[]).add(review);
    }
    for (final list in byDay.values) {
      list.sort((a, b) {
        final aMs =
            _reviewCreatedAt(a['createdAt'])?.millisecondsSinceEpoch ?? 0;
        final bMs =
            _reviewCreatedAt(b['createdAt'])?.millisecondsSinceEpoch ?? 0;
        if (aMs != bMs) return bMs.compareTo(aMs);
        final aPhoto = _reviewHasPhoto(a) ? 1 : 0;
        final bPhoto = _reviewHasPhoto(b) ? 1 : 0;
        return bPhoto.compareTo(aPhoto);
      });
    }
    return byDay;
  }

  /// For a day: prefer newest photo post; otherwise newest text-only post.
  Map<String, dynamic>? _pickDiaryCalendarDayReview(
    List<Map<String, dynamic>> dayReviews,
  ) {
    if (dayReviews.isEmpty) return null;
    for (final review in dayReviews) {
      if (_reviewHasPhoto(review)) return review;
    }
    return dayReviews.first;
  }

  Widget _buildDiaryCalendarView() {
    final month = DateTime(_diaryCalendarMonth.year, _diaryCalendarMonth.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final byDay = _reviewsByDayInMonth(month);
    final recordedDays = byDay.length;
    final percent =
        daysInMonth <= 0 ? 0.0 : (recordedDays / daysInMonth).clamp(0.0, 1.0);
    final percentLabel = (percent * 100).toStringAsFixed(1);
    final monthStart = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month, daysInMonth);
    final calendarStart = _startOfSundayWeek(monthStart);
    final calendarEnd =
        _startOfSundayWeek(monthEnd).add(const Duration(days: 6));
    final weekRowCount =
        (calendarEnd.difference(calendarStart).inDays ~/ 7) + 1;
    const weekLabels = <String>['일', '월', '화', '수', '목', '금', '토'];
    final now = DateTime.now();
    final today = _startOfDay(now);
    final isCurrentMonth =
        month.year == now.year && month.month == now.month;
    final canGoNext = month.year < now.year ||
        (month.year == now.year && month.month < now.month);
    final progressLabel = isCurrentMonth
        ? '이번 달 기록 $recordedDays / $daysInMonth일'
        : '기록 $recordedDays / $daysInMonth일';

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFF0F1F3), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, 8),
              spreadRadius: -8,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      _diaryMonthNavButton(
                        icon: Icons.chevron_left_rounded,
                        onTap: () {
                          setState(() {
                            _diaryCalendarMonth = DateTime(
                              month.year,
                              month.month - 1,
                            );
                          });
                        },
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              '${month.year}',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF9CA3AF),
                                letterSpacing: 1.0,
                                height: 1.1,
                              ),
                            ),
                            Text(
                              '${month.month}월',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111827),
                                letterSpacing: -0.5,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _diaryMonthNavButton(
                        icon: Icons.chevron_right_rounded,
                        onTap: canGoNext
                            ? () {
                                setState(() {
                                  _diaryCalendarMonth = DateTime(
                                    month.year,
                                    month.month + 1,
                                  );
                                });
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (int i = 0; i < weekLabels.length; i++)
                        Expanded(
                          child: Center(
                            child: Text(
                              weekLabels[i],
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: i == 0
                                    ? const Color(0xFFE07A3A)
                                    : const Color(0xFF9CA3AF),
                                letterSpacing: 0.2,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 3.0;
                  final cellW = (constraints.maxWidth - gap * 6) / 7;
                  final cellH = cellW * 1.18;
                  return Column(
                    children: [
                      for (int week = 0; week < weekRowCount; week++) ...[
                        if (week > 0) const SizedBox(height: gap),
                        SizedBox(
                          height: cellH,
                          child: Row(
                            children: [
                              for (int weekday = 0; weekday < 7; weekday++) ...[
                                if (weekday > 0) const SizedBox(width: gap),
                                SizedBox(
                                  width: cellW,
                                  height: cellH,
                                  child: _buildDiaryCalendarDayCell(
                                    day: calendarStart.add(
                                      Duration(days: week * 7 + weekday),
                                    ),
                                    month: month.month,
                                    today: today,
                                    dayReviews: byDay[_dayKey(
                                          calendarStart.add(
                                            Duration(
                                              days: week * 7 + weekday,
                                            ),
                                          ),
                                        )] ??
                                        const <Map<String, dynamic>>[],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F8F9),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            progressLabel,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF111827),
                              letterSpacing: -0.3,
                              height: 1.3,
                            ),
                          ),
                        ),
                        Text(
                          '$percentLabel%',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFF6B00),
                            letterSpacing: -0.3,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(100),
                      child: LinearProgressIndicator(
                        value: percent,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFE8E9EC),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFFF6B00),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _diaryMonthNavButton({
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: enabled ? 1 : 0.35,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 18,
              color: const Color(0xFF111827),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiaryCalendarDayCell({
    required DateTime day,
    required int month,
    required DateTime today,
    required List<Map<String, dynamic>> dayReviews,
  }) {
    final inMonth = day.month == month;
    if (!inMonth) {
      return const SizedBox.expand();
    }

    final review = _pickDiaryCalendarDayReview(dayReviews);
    final hasEntry = review != null;
    final photoUrl = hasEntry ? _reviewPhotoUrl(review) : null;
    final hasPhoto = photoUrl != null;
    final dayLabel = '${day.day}';
    final isToday = _isSameDay(day, today);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasEntry
            ? () {
                final globalIndex =
                    _allReviews.indexWhere((r) => r['id'] == review['id']);
                final reviewIndex = globalIndex >= 0 ? globalIndex : 0;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => RecipeReviewFeedScrollScreen(
                      reviews: _allReviews,
                      initialIndex: reviewIndex,
                    ),
                  ),
                );
              }
            : null,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: hasPhoto
                  ? Colors.black
                  : hasEntry
                      ? const Color(0xFFF3F4F6)
                      : const Color(0xFFF7F8FA),
              border: isToday
                  ? Border.all(color: const Color(0xFFFF6B00), width: 1.4)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasPhoto)
                  Positioned.fill(
                    child: AppNetworkImage(
                      imageUrl: photoUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: AppNetworkImage.listThumbCacheSize,
                      placeholder: const ColoredBox(color: Color(0xFFE5E7EB)),
                      errorWidget: _buildDiaryCalendarTextTile(review!),
                    ),
                  )
                else if (hasEntry)
                  Positioned.fill(
                    child: _buildDiaryCalendarTextTile(review!),
                  ),
                if (hasPhoto)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 28,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x73000000),
                            Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 4,
                  right: 5,
                  child: Text(
                    dayLabel,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: hasPhoto
                          ? Colors.white
                          : isToday
                              ? const Color(0xFFFF6B00)
                              : const Color(0xFF6B7280),
                      letterSpacing: -0.2,
                      height: 1.1,
                    ),
                  ),
                ),
                if (dayReviews.length > 1)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        '${dayReviews.length}',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact text-only diary cell (no photo that day).
  Widget _buildDiaryCalendarTextTile(Map<String, dynamic> review) {
    final title = (review['recipeTitle'] as String?)?.trim() ?? '';
    final comment = (review['comment'] as String?)?.trim() ?? '';
    final body = comment.isNotEmpty
        ? comment.replaceAll(RegExp(r'\s+'), ' ')
        : (title.isNotEmpty ? title : '기록');

    return Container(
      color: const Color(0xFFF4F5F7),
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 6),
      alignment: Alignment.topLeft,
      child: Text(
        body,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4B5563),
          height: 1.35,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  static const double _sectionGap = 12;

  Widget _buildActivityTabContent(Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        _buildLevelSection(brightness),
        const SizedBox(height: _sectionGap),
        _buildActivityInteractionCards(brightness),
        const SizedBox(height: _sectionGap),
        if (_isOwnProfile && _isAdminUser) _buildSettingsSection(brightness),
      ],
    );
  }

  /// Figma 184-235: Full activity tab content
  Widget _buildFigmaActivityTabContent(Brightness brightness) {
    final level = _displayLevel;
    final levelName = yorigoLevelSpoonName(level);
    final expToNext = _expToNextLevel();
    final progress = _expProgressToNextLevel();

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Level Card ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                  spreadRadius: -8,
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(
                            text: '요리GO 레벨 ',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF111111),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.50,
                            ),
                          ),
                          TextSpan(
                            text: '$level',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFFFF6B00),
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        levelName,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Color(0xFF99A1AF),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          height: 1.50,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildSpoonProgressBar(progress: progress)),
                    const SizedBox(width: 12),
                    Text(
                      expToNext > 0
                          ? '다음까지 $expToNext EXP'
                          : '최고 레벨!',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFF6A7282),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          _buildStreakSummaryCard(),

          const SizedBox(height: 12),

          // ── Stat Cards Row ──
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _openReceivedLikesList,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFF3F4F6),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                          spreadRadius: -8,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFFFE3EC), Color(0xFFFFCFDF)],
                            ),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x33FF2D6E),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                                spreadRadius: -2,
                              ),
                            ],
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.favorite,
                              size: 17,
                              color: Color(0xFFFF2D6E),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '받은 좋아요',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFF6A7282),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                height: 1.50,
                              ),
                            ),
                            Text(
                              '$_totalLikes',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFF111111),
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: _openAllUserReviewsList,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFF3F4F6),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                          spreadRadius: -8,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFE2EEFF), Color(0xFFCFE0FF)],
                            ),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x332F7BFF),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                                spreadRadius: -2,
                              ),
                            ],
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.chat_bubble,
                              size: 16,
                              color: Color(0xFF2F7BFF),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '남겨진 후기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFF6A7282),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                height: 1.50,
                              ),
                            ),
                            Text(
                              '$_reviewCount',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFF111111),
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── 관리자 전용 (의견 보내기는 설정 화면으로 이동) ──
          if (_isOwnProfile && _isAdminUser)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: const Color(0xFFF3F4F6),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                    spreadRadius: -8,
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildFigmaSettingsRow(
                    Icons.admin_panel_settings_outlined,
                    '관리자 게시물 관리',
                    onTap: _openAdminPostManagementScreen,
                  ),
                  _buildFigmaSettingsRow(
                    Icons.receipt_long_outlined,
                    '구매인증 검수',
                    onTap: _openAdminPurchaseVerificationScreen,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  BoxDecoration _rewardsCardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 14,
          offset: const Offset(0, 5),
          spreadRadius: -8,
        ),
      ],
    );
  }

  /// 포인트 전용 카드 (경험치와 분리).
  Widget _buildPointsSummaryCard() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _isOwnProfile ? () => _openRewardHistorySheet(track: 'points') : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          decoration: _rewardsCardDecoration(),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1E6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'P',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFFFF6B00),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '포인트',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isOwnProfile && _pointsLifetimeEarned > 0
                          ? '출석·장바구니·커뮤니티로 모아요 · 누적 $_pointsLifetimeEarned P'
                          : '출석·장바구니·커뮤니티로 모아요',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6A7282),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$_pointsBalance',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFFF6B00),
                  height: 1.05,
                ),
              ),
              const SizedBox(width: 2),
              const Text(
                'P',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFF6B00),
                ),
              ),
              if (_isOwnProfile) ...[
                const SizedBox(width: 2),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFC8CED6),
                  size: 24,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 경험치 전용 카드 (포인트와 분리).
  Widget _buildExpSummaryCard() {
    final expProgress = _expProgressToNextLevel();
    final expToNext = _expToNextLevel();
    final badgeLevel = _displayLevel.clamp(1, 10);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _isOwnProfile ? () => _openRewardHistorySheet(track: 'exp') : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          decoration: _rewardsCardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: _levelBadgeDecoration(badgeLevel),
                    child: Text(
                      '$_displayLevel',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: _levelBadgeTextColor(badgeLevel),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '경험치 Lv.$_displayLevel',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hasExpTotal
                              ? '$_expTotal EXP · 다음 레벨까지 $expToNext'
                              : '이전 활동 반영 전 · ${yorigoLevelSpoonName(_displayLevel)}',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF6A7282),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isOwnProfile)
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFFC8CED6),
                      size: 24,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _buildSpoonProgressBar(progress: expProgress),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreakSummaryCard() {
    final today = _startOfDay(DateTime.now());
    final streakDays = _computeCurrentStreakFromDays(_attendanceDays);
    final isCurrentUserProfile = _isOwnProfile;
    const weekLabels = <String>['일', '월', '화', '수', '목', '금', '토'];
    final currentWeekStart = _startOfDay(
      today.subtract(Duration(days: today.weekday % 7)),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => StreakCalendarScreen(
                userId: _viewingUserId,
                attendanceDays: _attendanceDays,
                cookingDays: _cookingDays,
                includeTodayAttendance: isCurrentUserProfile,
              ),
            ),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 14,
                offset: const Offset(0, 5),
                spreadRadius: -8,
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        children: [
                          const TextSpan(
                            text: '연속 출석 ',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF2B3036),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                          ),
                          TextSpan(
                            text: '$streakDays',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF111827),
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              height: 1.05,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const TextSpan(
                            text: '일',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF2B3036),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFFC8CED6),
                    size: 28,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (int index = 0; index < weekLabels.length; index++)
                    Expanded(
                      child: _buildStreakWeekDayDot(
                        label: weekLabels[index],
                        day: currentWeekStart.add(Duration(days: index)),
                        today: today,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreakWeekDayDot({
    required String label,
    required DateTime day,
    required DateTime today,
  }) {
    final key = _dayKey(day);
    final isToday = _isSameDay(day, today);
    final hasCooking = _cookingDays.contains(key);
    final hasAttendance = _attendanceDays.contains(key);
    final bool isPast = day.isBefore(today);
    final DateTime? firstActivity = _firstStreakActivityDay();
    final bool showIce = isPast &&
        !hasCooking &&
        !hasAttendance &&
        firstActivity != null &&
        !day.isBefore(firstActivity);
    final Color backgroundColor = hasCooking
        ? const Color(0xFFFF6B00)
        : hasAttendance
        ? const Color(0xFFFFA15C)
        : showIce
        ? const Color(0xFFEAF4FF)
        : const Color(0xFFF6F8FA);
    final Color foregroundColor = hasCooking
        ? Colors.white
        : hasAttendance
        ? Colors.white
        : const Color(0xFFAEB6C2);
    final bool showCook = hasCooking;
    final bool showFlame = hasAttendance && !hasCooking;
    final useTodayBadge = isToday && (hasCooking || hasAttendance);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: useTodayBadge ? 34 : (isToday ? 34 : 32),
          height: useTodayBadge ? 34 : (isToday ? 34 : 32),
          decoration: BoxDecoration(
            color: (showCook || showFlame)
                ? const Color(0xFFFFF5EC)
                : backgroundColor,
            gradient: showCook
                ? const RadialGradient(
                    center: Alignment(-0.45, -0.55),
                    radius: 1.05,
                    colors: [
                      Color(0xFFFFF3B0),
                      Color(0xFFFFB34E),
                      Color(0xFFFF6B00),
                      Color(0xFFFF4F00),
                    ],
                    stops: [0.0, 0.42, 0.76, 1.0],
                  )
                : showFlame
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFFFCF7),
                      Color(0xFFFFE2C4),
                      Color(0xFFFFB777),
                    ],
                  )
                : showIce
                ? const RadialGradient(
                    center: Alignment(-0.45, -0.55),
                    radius: 1.05,
                    colors: [
                      Color(0xFFF4FBFF),
                      Color(0xFFCDE9FF),
                      Color(0xFFA3D2FF),
                      Color(0xFF7EBCFF),
                    ],
                    stops: [0.0, 0.42, 0.76, 1.0],
                  )
                : null,
            shape: BoxShape.circle,
            border: Border.all(
              color: showCook
                  ? const Color(0x66FFFFFF)
                  : showFlame
                  ? const Color(0x55FFFFFF)
                  : isToday
                  ? const Color(0xFFFF6B00)
                  : showIce
                  ? const Color(0x66FFFFFF)
                  : Colors.transparent,
              width: (showCook || showFlame) ? 0.8 : (isToday ? 1 : 0.8),
            ),
            boxShadow: showCook
                ? const [
                    BoxShadow(
                      color: Color(0x52FF6B00),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                      spreadRadius: -1,
                    ),
                    BoxShadow(
                      color: Color(0x38FFD24A),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : showFlame
                ? const [
                    BoxShadow(
                      color: Color(0x26FF8A24),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                      spreadRadius: -2,
                    ),
                    BoxShadow(
                      color: Color(0x10000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ]
                : isToday
                ? [
                    BoxShadow(
                      color: const Color(0xFFFF6B00).withValues(alpha: 0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                      spreadRadius: -5,
                    ),
                  ]
                : showIce
                ? const [
                    BoxShadow(
                      color: Color(0x4044A6FF),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                      spreadRadius: -2,
                    ),
                    BoxShadow(
                      color: Color(0x308FD0FF),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: showCook
              ? Image.asset(
                  'assets/icons/streak_cook_3d.png',
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                )
              : showFlame
              ? Image.asset(
                  'assets/icons/streak_flame_3d.png',
                  width: 26,
                  height: 26,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                )
              : showIce
              ? Image.asset(
                  'assets/icons/streak_ice_3d.png',
                  width: 25,
                  height: 25,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: foregroundColor,
                    fontSize: isToday ? 14.5 : 15,
                    fontWeight: isToday ? FontWeight.w900 : FontWeight.w700,
                    height: 1,
                  ),
                ),
        ),
        const SizedBox(height: 6),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: isToday ? 4 : 0,
          height: 4,
          decoration: BoxDecoration(
            color: isToday ? const Color(0xFFFF5A00) : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      ],
    );
  }

  DateTime? _firstStreakActivityDay() {
    final keys = <String>{..._attendanceDays, ..._cookingDays};
    if (keys.isEmpty) return null;
    final earliest = keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    final parts = earliest.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final dayNum = int.tryParse(parts[2]);
    if (year == null || month == null || dayNum == null) return null;
    return DateTime(year, month, dayNum);
  }

  int _computeCurrentStreakFromDays(Set<String> days) {
    return _userService.currentStreakFromAttendanceDays(days);
  }

  Widget _buildWeeklyStreakCalendarSection() {
    final now = DateTime.now();
    final today = _startOfDay(now);
    final monthStart = DateTime(today.year, today.month, 1);
    final monthEnd = DateTime(today.year, today.month + 1, 0);
    final calendarStart = _startOfWeek(monthStart);
    final calendarEnd = _startOfWeek(monthEnd).add(const Duration(days: 6));
    final weekRowCount =
        (calendarEnd.difference(calendarStart).inDays ~/ 7) + 1;

    int streakDays = 0;
    int streakActivities = 0;
    var cursor = today;
    while (true) {
      final activityCount =
          (_dailyStreakActions[_dayKey(cursor)] ?? const {}).length;
      if (activityCount <= 0) {
        break;
      }
      streakDays += 1;
      streakActivities += activityCount;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    const weekLabels = <String>['월', '화', '수', '목', '금', '토', '일'];
    final selectedDay = _selectedCalendarDay ?? today;
    final selectedDayActions =
        _dailyStreakActions[_dayKey(selectedDay)] ?? const <String>{};
    final achievementActions = <Map<String, dynamic>>[
      {'action': _actionSaveRecipe, 'label': '레시피북에 레시피 저장'},
      {'action': _actionAddScheduledCart, 'label': '요리 일정으로 장바구니 담기'},
      {'action': _actionParseRecipe, 'label': '레시피 파싱'},
      {'action': _actionCompleteScheduledCooking, 'label': '오늘 예정된 요리 세션 실행'},
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 8),
            spreadRadius: -8,
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dayCellSize = constraints.maxWidth / 7;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${today.year}년 ${today.month}월',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFF111827),
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                  _buildStreakMetric(label: '나의 요리', value: '$streakDays일'),
                  const SizedBox(width: 14),
                  _buildStreakMetric(
                    label: '요리 활동',
                    value: '$streakActivities회',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final label in weekLabels)
                    SizedBox(
                      width: dayCellSize,
                      child: Center(
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: Color(0xFF9CA3AF),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (
                int weekIndex = 0;
                weekIndex < weekRowCount;
                weekIndex++
              ) ...[
                Builder(
                  builder: (context) {
                    final weekStart = calendarStart.add(
                      Duration(days: weekIndex * 7),
                    );

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          for (int weekday = 0; weekday < 7; weekday++)
                            SizedBox(
                              width: dayCellSize,
                              child: _buildStreakDayCell(
                                day: weekStart.add(Duration(days: weekday)),
                                month: today.month,
                                today: today,
                                isSelected: _isSameDay(
                                  weekStart.add(Duration(days: weekday)),
                                  selectedDay,
                                ),
                                onTap: () {
                                  setState(() {
                                    _selectedCalendarDay = _startOfDay(
                                      weekStart.add(Duration(days: weekday)),
                                    );
                                  });
                                },
                                activityCount:
                                    (_dailyStreakActions[_dayKey(
                                              weekStart.add(
                                                Duration(days: weekday),
                                              ),
                                            )] ??
                                            const {})
                                        .length,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '${selectedDay.month}월 ${selectedDay.day}일 완료 내역',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: Color(0xFF111827),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                selectedDayActions.isEmpty ? '완료한 활동이 없어요.' : '완료한 활동을 확인해보세요.',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: Color(0xFF6B7280),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              for (final achievement in achievementActions)
                _buildAchievementRow(
                  label: achievement['label'] as String,
                  isDone: selectedDayActions.contains(
                    achievement['action'] as String,
                  ),
                ),
              const SizedBox(height: 6),
              const Text(
                '오렌지가 진할수록 더 많은 활동을 완료했어요.',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: Color(0xFF9CA3AF),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStreakMetric({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            color: Color(0xFFFF6B00),
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            color: Color(0xFF6B7280),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildStreakDayCell({
    required DateTime day,
    required int month,
    required DateTime today,
    required bool isSelected,
    required VoidCallback onTap,
    required int activityCount,
  }) {
    if (day.month != month) {
      return const SizedBox(height: 28);
    }

    final isToday = _isSameDay(day, today);
    final isFuture = day.isAfter(today);
    final hasActivity = activityCount > 0;
    final isPastWithoutActivity = day.isBefore(today) && !hasActivity;

    final Color fillColor = hasActivity
        ? _streakOrangeByActivityCount(activityCount)
        : isPastWithoutActivity
        ? const Color(0xFF4B5563)
        : Colors.transparent;
    final Color borderColor = isToday
        ? const Color(0xFF111827)
        : isSelected
        ? const Color(0xFFFF6B00)
        : isFuture
        ? const Color(0xFF6B7280)
        : Colors.transparent;
    final Color textColor = hasActivity || isPastWithoutActivity
        ? Colors.white
        : isToday
        ? const Color(0xFF111827)
        : const Color(0xFF9CA3AF);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 28,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: Container(
              decoration: BoxDecoration(
                color: fillColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: borderColor,
                  width: isToday || isSelected ? 1.5 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: textColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAchievementRow({required String label, required bool isDone}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDone ? const Color(0xFFFFF4EB) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDone ? const Color(0xFFFFDFC8) : const Color(0xFFE5E7EB),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isDone ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 15,
            color: isDone ? const Color(0xFFFF6B00) : const Color(0xFF9CA3AF),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Pretendard',
                color: isDone
                    ? const Color(0xFF7C2D12)
                    : const Color(0xFF4B5563),
                fontSize: 12,
                fontWeight: isDone ? FontWeight.w700 : FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _streakOrangeByActivityCount(int count) {
    final clamped = count.clamp(1, 4);
    switch (clamped) {
      case 1:
        return const Color(0xFFFFB36F);
      case 2:
        return const Color(0xFFFF973E);
      case 3:
        return const Color(0xFFFF7A12);
      default:
        return const Color(0xFFE85E00);
    }
  }

  DateTime _startOfDay(DateTime dateTime) =>
      DateTime(dateTime.year, dateTime.month, dateTime.day);

  DateTime _startOfWeek(DateTime dateTime) {
    final day = _startOfDay(dateTime);
    final delta = day.weekday - DateTime.monday;
    return day.subtract(Duration(days: delta));
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime? _dateFromDateKey(String dateKey) {
    final parts = dateKey.split('-');
    if (parts.length != 3) {
      return null;
    }
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day);
  }

  String _dayKey(DateTime day) => UserService.streakDayKey(day);

  Widget _buildFigmaSettingsRow(
    IconData icon,
    String label, {
    required VoidCallback onTap,
    Color? iconColor,
    Color? labelColor,
    Color? trailingColor,
  }) {
    final ic = iconColor ?? const Color(0xFF6B7280);
    final lc = labelColor ?? const Color(0xFF4B5563);
    final tc = trailingColor ?? const Color(0xFF9CA3AF);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
        child: Row(
          children: [
            Icon(icon, size: 18, color: ic),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: lc,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.50,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: tc),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityInteractionCards(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Row(
        children: [
          Expanded(
            child: _buildPastelStatCard(
              brightness: brightness,
              icon: Icons.favorite_rounded,
              value: _safeNum(_totalLikes),
              label: '받은 좋아요',
              backgroundColor: brightness == Brightness.dark
                  ? AppColors.getBackgroundSecondary(brightness)
                  : Colors.white,
              iconColor: const Color(0xFFFF456A),
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              onTap: _openReceivedLikesList,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildPastelStatCard(
              brightness: brightness,
              icon: Icons.chat_bubble_rounded,
              value: _safeNum(_reviewCount),
              label: '남겨진 후기',
              backgroundColor: brightness == Brightness.dark
                  ? AppColors.getBackgroundSecondary(brightness)
                  : Colors.white,
              iconColor: const Color(0xFF2196F3),
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              onTap: _openAllUserReviewsList,
            ),
          ),
        ],
      ),
    );
  }

  /// Empty cooking diary card aligned with the activity card spacing system.
  Widget _buildLiquidEmptyDiaryCard({
    required String title,
    required String description,
    Future<void> Function()? onAddCookingRecord,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
            spreadRadius: -8,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
              height: 1.35,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF6B7280),
              height: 1.40,
            ),
          ),
          if (onAddCookingRecord != null) ...[
            const SizedBox(height: 20),
            _buildLiquidCtaButton(
              label: '요리 기록 남기기',
              onTap: () => onAddCookingRecord(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiquidCtaButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(100),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFFA15A),
                Color(0xFFFF7A1A),
                Color(0xFFFF5A00),
              ],
              stops: [0.0, 0.48, 1.0],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_rounded,
                          size: 18, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiaryGrid(
    Brightness brightness, {
    Future<void> Function()? onAddCookingRecord,
  }) {
    final emptyTitle = _isOwnProfile ? '아직 요리 기록이 없어요' : '아직 공개된 요리 기록이 없어요';
    final emptyDescription = _isOwnProfile
        ? '요리를 완료하고 첫 리뷰를 남겨보세요'
        : '이 사용자가 남긴 요리 기록이 여기에 표시돼요';

    if (_allReviews.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLiquidEmptyDiaryCard(
              title: emptyTitle,
              description: emptyDescription,
              onAddCookingRecord: onAddCookingRecord,
            ),
          ],
        ),
      );
    }

    return Container(
      color: const Color(0xFFF9FAFB),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 1.0,
        ),
        itemCount: _allReviews.length,
        itemBuilder: (context, index) {
          final review = _allReviews[index];
          return _buildFigmaPhotoGridCard(review, brightness, index);
        },
      ),
    );
  }

  Widget _buildPastelStatCard({
    required Brightness brightness,
    required IconData icon,
    required String value,
    required String label,
    required Color backgroundColor,
    required Color iconColor,
    required Color textPrimary,
    required Color textSecondary,
    VoidCallback? onTap,
  }) {
    const double numberSize = 18.0;
    const double labelSize = 11.0;
    const double iconSize = 18.0; // ~90% of number cap height

    final child = Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 18, 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: numberSize * 1.2,
            child: Center(
              child: Icon(icon, color: iconColor, size: iconSize),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: numberSize,
                  fontWeight: FontWeight.w800,
                  color: textPrimary,
                  letterSpacing: -0.5,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                label,
                style: TextStyle(
                  fontSize: labelSize,
                  fontWeight: FontWeight.w500,
                  color: textSecondary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return child;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: child,
      ),
    );
  }

  Widget _buildSettingsSection(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.getBackgroundSecondary(brightness)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            if (_isAdminUser)
              _buildSettingsTile(
                icon: Icons.admin_panel_settings_outlined,
                label: '관리자 게시물 관리',
                brightness: brightness,
                onTap: _openAdminPostManagementScreen,
              ),
            if (_isAdminUser)
              _buildSettingsTile(
                icon: Icons.receipt_long_outlined,
                label: '구매인증 검수',
                brightness: brightness,
                onTap: _openAdminPurchaseVerificationScreen,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String label,
    required Brightness brightness,
    Color? textColor,
    required VoidCallback onTap,
  }) {
    final color = textColor ?? AppColors.getTextPrimary(brightness);
    final iconColor = textColor ?? AppColors.getTextSecondary(brightness);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 12,
              color: AppColors.getTextTertiary(brightness),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityReviewCard(
    Map<String, dynamic> review,
    Brightness brightness,
    int index,
  ) {
    final photoUrl = review['photoUrl'] as String?;
    final recipeTitle = review['recipeTitle'] as String? ?? '레시피';
    final textPreview = _reviewTextPreview(review);
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    // Find index in all reviews list
    final globalIndex = _allReviews.indexWhere((r) => r['id'] == review['id']);
    final reviewIndex = globalIndex >= 0 ? globalIndex : 0;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RecipeReviewFeedScrollScreen(
              reviews: _allReviews,
              initialIndex: reviewIndex,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background image or gradient
              if (hasPhoto)
                AppNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.cover,
                  // Width-only cap preserves source aspect ratio.
                  memCacheWidth: AppNetworkImage.feedImageCacheSize,
                  errorWidget: _buildActivityGradientBackground(),
                )
              else
                _buildActivityGradientBackground(),

              // Gradient overlay (black at bottom, transparent at top)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.3),
                      Colors.black.withOpacity(0.7),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),

              // Recipe title at bottom left
              Positioned(
                left: 8,
                bottom: 8,
                right: 8,
                child: Text(
                  recipeTitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // Fork & knife icon if no photo
              if (!hasPhoto)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      textPreview,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.88),
                        height: 1.35,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Figma 184-4: Photo grid card with heart + like count badge
  Widget _buildFigmaPhotoGridCard(
    Map<String, dynamic> review,
    Brightness brightness,
    int index,
  ) {
    final photoUrl = _reviewPhotoUrl(review);
    final textPreview = _reviewTextPreview(review);
    final hasPhoto = photoUrl != null;
    final likes =
        (review['likeCount'] as num?)?.toInt() ??
        (review['likes'] as num?)?.toInt() ??
        0;

    final globalIndex = _allReviews.indexWhere((r) => r['id'] == review['id']);
    final reviewIndex = globalIndex >= 0 ? globalIndex : 0;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RecipeReviewFeedScrollScreen(
              reviews: _allReviews,
              initialIndex: reviewIndex,
            ),
          ),
        );
      },
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: const ShapeDecoration(
          color: Color(0xFFF3F4F6),
          shape: RoundedRectangleBorder(),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasPhoto)
              AppNetworkImage(
                imageUrl: photoUrl,
                fit: BoxFit.cover,
                // Width-only cap preserves source aspect ratio.
                memCacheWidth: AppNetworkImage.feedImageCacheSize,
                errorWidget: Container(
                  color: AppColors.getBackgroundTertiary(brightness),
                  child: Center(
                    child: Icon(
                      Icons.restaurant,
                      size: 40,
                      color: AppColors.getTextTertiary(brightness),
                    ),
                  ),
                ),
              )
            else
              _buildTextReviewTile(textPreview),
            // Heart + like count badge (top-right)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.favorite, size: 10, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(
                      '$likes',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Editorial-style tile for text-only reviews (no photo).
  Widget _buildTextReviewTile(String textPreview) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF9FAFB),
            Color(0xFFEFF1F4),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 6,
            left: 10,
            child: Text(
              '\u201C',
              style: TextStyle(
                fontFamily: 'Georgia',
                fontSize: 40,
                height: 1.0,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF9CA3AF).withValues(alpha: 0.35),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 22, 12, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                textPreview,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4B5563),
                  height: 1.45,
                  letterSpacing: -0.2,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _reviewTextPreview(Map<String, dynamic> review) {
    final comment = (review['comment'] as String? ?? '').trim();
    if (comment.isEmpty) {
      final title = (review['recipeTitle'] as String?)?.trim() ?? '';
      return title.isNotEmpty ? title : '레시피';
    }
    return comment.replaceAll(RegExp(r'\s+'), ' ');
  }

  Widget _buildActivityGradientBackground() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.grey.shade200, Colors.grey.shade400],
        ),
      ),
    );
  }

  Widget _buildLogoutButton() {
    const logoutRed = Color(0xFFD32F2F);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _contentPaddingH),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleLogout,
          borderRadius: BorderRadius.circular(_cardRadius + 4),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: logoutRed.withOpacity(0.06),
              border: Border.all(
                color: logoutRed.withOpacity(0.35),
                width: 1.2,
              ),
              borderRadius: BorderRadius.circular(_cardRadius + 4),
              boxShadow: _liquidShadow(opacity: 0.03),
            ),
            child: const Text(
              '로그아웃',
              style: TextStyle(
                fontSize: 15,
                color: Color(0xFFD32F2F),
                fontWeight: FontWeight.w600,
                letterSpacing: -0.25,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tab section with its own state so only this section rebuilds when switching tabs.
/// The top profile header stays fixed and does not refresh.
class _ProfileTabSection extends StatefulWidget {
  final Widget Function() headerBuilder;
  final Widget diaryContent;
  final Widget activityContent;
  final Future<void> Function() onRefresh;
  final VoidCallback? onActivityTabSelected;
  final bool isOwnProfile;
  final bool showDiaryAddButton;
  final Future<void> Function()? onDiaryAddPressed;
  final _DiaryViewMode diaryViewMode;
  final ValueChanged<_DiaryViewMode> onDiaryViewModeChanged;
  final bool showDiaryViewToggle;

  const _ProfileTabSection({
    super.key,
    required this.headerBuilder,
    required this.diaryContent,
    required this.activityContent,
    required this.onRefresh,
    this.onActivityTabSelected,
    required this.isOwnProfile,
    this.showDiaryAddButton = false,
    this.onDiaryAddPressed,
    required this.diaryViewMode,
    required this.onDiaryViewModeChanged,
    this.showDiaryViewToggle = false,
  });

  @override
  State<_ProfileTabSection> createState() => _ProfileTabSectionState();
}

class _ProfileTabSectionState extends State<_ProfileTabSection> {
  late final ScrollController _diaryScrollController;
  late final ScrollController _activityScrollController;
  int _tabIndex = 0;
  bool _tabContentScrolled = false;

  @override
  void initState() {
    super.initState();
    _diaryScrollController = ScrollController();
    _activityScrollController = ScrollController();
    _diaryScrollController.addListener(_handleTabScroll);
    _activityScrollController.addListener(_handleTabScroll);
  }

  @override
  void dispose() {
    _diaryScrollController.removeListener(_handleTabScroll);
    _activityScrollController.removeListener(_handleTabScroll);
    _diaryScrollController.dispose();
    _activityScrollController.dispose();
    super.dispose();
  }

  ScrollController get _activeScrollController =>
      _tabIndex == 0 ? _diaryScrollController : _activityScrollController;

  void _handleTabScroll() {
    final controller = _activeScrollController;
    final next = controller.hasClients && controller.offset > 24;
    if (next != _tabContentScrolled && mounted) {
      setState(() => _tabContentScrolled = next);
    }
  }

  void _selectTab(int index) {
    if (_tabIndex == index) return;
    setState(() {
      _tabIndex = index;
      _tabContentScrolled = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleTabScroll());
    if (index == 1) {
      widget.onActivityTabSelected?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    const profileBg = Color(0xFFF9FAFB);
    final showFab = _tabIndex == 0 &&
        widget.showDiaryAddButton &&
        widget.onDiaryAddPressed != null;
    // Header + tab bar live inside each scroll view so profile → tabs →
    // content move as one unit (no sticky/fixed header).
    // IndexedStack (not PageView) keeps tab switches from sliding sideways.
    return Container(
      width: double.infinity,
      color: profileBg,
      child: Stack(
        children: [
          IndexedStack(
            index: _tabIndex,
            children: [
              AppRefreshIndicator(
                onRefresh: widget.onRefresh,
                child: SingleChildScrollView(
                  controller: _diaryScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      widget.headerBuilder(),
                      _buildTabBar(brightness),
                      widget.diaryContent,
                      const SizedBox(height: 96),
                    ],
                  ),
                ),
              ),
              SingleChildScrollView(
                controller: _activityScrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    widget.headerBuilder(),
                    _buildTabBar(brightness),
                    widget.activityContent,
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
          if (showFab)
            Positioned(
              right: 16,
              bottom: 16 + IosLiquidGlassTabBar.overlayChromeInset(context),
              child: _buildDiaryAddFab(
                collapsed: _tabContentScrolled ||
                    widget.diaryViewMode == _DiaryViewMode.calendar,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabBar(Brightness brightness) {
    final showToggle = widget.showDiaryViewToggle && _tabIndex == 0;
    return Container(
      width: double.infinity,
      color: const Color(0xFFF9FAFB),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
          children: [
            GestureDetector(
              onTap: () => _selectTab(0),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: _tabIndex == 0
                      ? const Color(0xFF111827)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(100),
                  border: _tabIndex == 0
                      ? null
                      : Border.all(
                          color: const Color(0xFFE5E7EB),
                          width: 0.67,
                        ),
                  boxShadow: _tabIndex == 0
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                            spreadRadius: -2,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 6,
                            offset: const Offset(0, 4),
                            spreadRadius: -1,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  widget.isOwnProfile ? '나의 다이어리' : '요리 기록',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: _tabIndex == 0
                        ? Colors.white
                        : const Color(0xFF6A7282),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.50,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _selectTab(1),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: _tabIndex == 1
                      ? const Color(0xFF111827)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(100),
                  border: _tabIndex == 1
                      ? null
                      : Border.all(
                          color: const Color(0xFFE5E7EB),
                          width: 0.67,
                        ),
                  boxShadow: _tabIndex == 1
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                            spreadRadius: -2,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 6,
                            offset: const Offset(0, 4),
                            spreadRadius: -1,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  '활동 기록',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: _tabIndex == 1
                        ? Colors.white
                        : const Color(0xFF6A7282),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.50,
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (showToggle) _buildDiaryViewToggle(),
          ],
      ),
    );
  }

  Widget _buildDiaryViewToggle() {
    final isGrid = widget.diaryViewMode == _DiaryViewMode.grid;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F1F3),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE7E8EB), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _diaryViewToggleButton(
            icon: Icons.calendar_month_rounded,
            selected: !isGrid,
            onTap: () =>
                widget.onDiaryViewModeChanged(_DiaryViewMode.calendar),
            semanticLabel: '캘린더 보기',
          ),
          _diaryViewToggleButton(
            icon: Icons.grid_view_rounded,
            selected: isGrid,
            onTap: () =>
                widget.onDiaryViewModeChanged(_DiaryViewMode.grid),
            semanticLabel: '그리드 보기',
          ),
        ],
      ),
    );
  }

  Widget _diaryViewToggleButton({
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 28,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF111827) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 14,
              color: selected ? Colors.white : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiaryAddFab({required bool collapsed}) {
    const duration = Duration(milliseconds: 320);
    const curve = Curves.easeInOutCubic;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: () => widget.onDiaryAddPressed!(),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: duration,
          curve: curve,
          height: 50,
          // Collapsed: 13+24+13 = 50 so the pill is a true circle (no width
          // lerp — AnimatedContainer can't interpolate null ↔ finite width).
          padding: EdgeInsets.only(
            left: collapsed ? 13 : 16,
            right: collapsed ? 13 : 16,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFF850F),
                Color(0xFFFF7300),
                Color(0xFFFF6400),
              ],
            ),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF5722).withValues(alpha: 0.28),
                blurRadius: collapsed ? 14 : 18,
                offset: Offset(0, collapsed ? 6 : 8),
              ),
              BoxShadow(
                color: const Color(0xFFFF8A50).withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                duration: duration,
                curve: curve,
                scale: collapsed ? 1.12 : 1,
                child: const Icon(
                  Icons.add_rounded,
                  size: 24,
                  color: Colors.white,
                ),
              ),
              ClipRect(
                child: AnimatedAlign(
                  duration: duration,
                  curve: curve,
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  widthFactor: collapsed ? 0 : 1,
                  child: IgnorePointer(
                    ignoring: collapsed,
                    child: AnimatedOpacity(
                      duration: Duration(
                        milliseconds: collapsed ? 120 : 260,
                      ),
                      curve: collapsed
                          ? Curves.easeIn
                          : Curves.easeOutCubic,
                      opacity: collapsed ? 0 : 1,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 5),
                        child: Text(
                          '요리 기록하기',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.3,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _uploadProfileImage(
    String uid,
    File imageFile, {
    String? oldPhotoUrl,
  }) async {
    try {
      File fileToUpload = imageFile;
      try {
        fileToUpload = await resizeImageFile(
          imageFile,
          maxWidth: 800,
          quality: 85,
        );
      } catch (e) {
        print('[ProfileScreen] Resize skipped: $e');
      }

      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('$uid.jpg');

      await storageRef.putFile(fileToUpload);
      final downloadUrl = await storageRef.getDownloadURL();

      // Delete old image if it exists and is different from new one
      if (oldPhotoUrl != null &&
          oldPhotoUrl.isNotEmpty &&
          oldPhotoUrl != downloadUrl) {
        try {
          // Extract the path from the old URL
          final oldRef = FirebaseStorage.instance.refFromURL(oldPhotoUrl);
          await oldRef.delete();
          print('[ProfileScreen] Deleted old profile image');
        } catch (deleteError) {
          // Log but don't fail - old image might not exist or already deleted
          print(
            '[ProfileScreen] Could not delete old profile image: $deleteError',
          );
        }
      }

      return downloadUrl;
    } catch (e) {
      print('[ProfileScreen] Error uploading profile image: $e');
      rethrow;
    }
  }
}
