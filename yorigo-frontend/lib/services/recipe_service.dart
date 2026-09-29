import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recipe_models.dart' as models;
import '../utils/lru_bounded_map.dart';
import '../utils/naver_mini_doc_utils.dart';
import '../utils/youtube_utils.dart';
import '../utils/naver_blog_utils.dart';
import '../utils/ingredient_index_key.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/tiktok_utils.dart';
import '../utils/recipe_social_counts.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/recipe_search_match.dart';
import '../utils/recipe_source_lookup.dart';
import '../utils/related_recipe_rails.dart';
import 'meal_plan_service.dart';
import 'local_storage_service.dart';
import 'api_service.dart';
import 'user_service.dart';

/// One page of explore recipes for paginated browse.
class ExploreRecipesPageResult {
  ExploreRecipesPageResult({
    required this.recipes,
    this.lastRawDocument,
    required this.hasMore,
  });

  final List<Map<String, dynamic>> recipes;
  final DocumentSnapshot? lastRawDocument;
  final bool hasMore;
}

class _ExploreGuestsCacheEntry {
  const _ExploreGuestsCacheEntry({
    required this.cachedAt,
    required this.recipes,
  });

  final DateTime cachedAt;
  final List<Map<String, dynamic>> recipes;
}

class _ExplorePageCacheEntry {
  const _ExplorePageCacheEntry({
    required this.cachedAt,
    required this.recipes,
    required this.lastRawDocument,
    required this.hasMore,
  });

  final DateTime cachedAt;
  final List<Map<String, dynamic>> recipes;
  final DocumentSnapshot? lastRawDocument;
  final bool hasMore;
}

class _SeasonalIndexCacheEntry {
  const _SeasonalIndexCacheEntry({
    required this.cachedAt,
    required this.recipeIds,
  });

  final DateTime cachedAt;
  final List<String> recipeIds;
}

class _HomeSectionIndexCacheEntry {
  const _HomeSectionIndexCacheEntry({
    required this.cachedAt,
    required this.recipeIds,
  });

  final DateTime cachedAt;
  final List<String> recipeIds;
}

class _ChefIndexCacheEntry {
  const _ChefIndexCacheEntry({
    required this.cachedAt,
    required this.recipeIds,
    required this.count,
  });

  final DateTime cachedAt;
  final List<String> recipeIds;
  final int count;
}

class _ExploreRecipeDocCacheEntry {
  const _ExploreRecipeDocCacheEntry({
    required this.cachedAt,
    required this.recipe,
  });

  final DateTime cachedAt;
  final Map<String, dynamic> recipe;
}

/// 홈 인기/카테고리 캐러셀용 스냅샷 (앱 재진입 시 Firestore 재조회 방지).
class HomeTrendingFeedSnapshot {
  const HomeTrendingFeedSnapshot({
    required this.allRecipes,
    required this.seasonalIndexedIds,
    required this.hasMore,
    this.displayedSections = const {},
    this.displayedSeasonal = const [],
    this.chefIndex = const {},
    this.homeSectionIndexedIdsByTitle = const {},
    this.sectionFetchedCount = const {},
    this.seasonalFetchedCount = 0,
  });

  final List<Map<String, dynamic>> allRecipes;
  final List<String> seasonalIndexedIds;
  final bool hasMore;
  /// 캐러셀에 실제로 붙어 있던 카드(「지금 뜨는 레시피」 등). 복귀 시 재시드 없이 그대로 복원.
  final Map<String, List<Map<String, dynamic>>> displayedSections;
  final List<(Map<String, dynamic>, String)> displayedSeasonal;

  /// 셰프명 → recipeId 목록. 디스크 캐시 히트로 복원할 때 셰프 섹션이
  /// 사라지지 않도록(=fetch 생략 경로에서도) 셰프 인덱스를 함께 보존한다.
  final Map<String, List<String>> chefIndex;

  /// 섹션 타이틀 → 인덱스 recipeId 목록 (스크롤 append fetch용).
  final Map<String, List<String>> homeSectionIndexedIdsByTitle;

  /// 섹션 타이틀 → 지금까지 full-doc fetch 한 ID 개수.
  final Map<String, int> sectionFetchedCount;

  /// 제철 인덱스에서 지금까지 full-doc fetch 한 ID 개수.
  final int seasonalFetchedCount;
}

class _HomeTrendingFeedCacheEntry {
  const _HomeTrendingFeedCacheEntry({
    required this.cachedAt,
    required this.snapshot,
  });

  final DateTime cachedAt;
  final HomeTrendingFeedSnapshot snapshot;
}

/// 홈 화면과 레시피 파싱 시트가 같은 진행률을 보이도록 캐시.
/// [startProgressSimulation]은 목표 %를 **0.5% 단위**로 올리되, [ParsingRingIndicator]가
/// 프레임마다 보간해 iOS 앱 설치 링처럼 부드럽게 보이게 한다. 약 **55초**에 ~94%.
/// Firestore/SSE의 거친 progress는 UI 링에 쓰지 않는다 — 홈 파싱 카드는 Lottie만 사용.
class ParsingProgressCache extends ChangeNotifier {
  final Map<String, double> _progress = {};
  // Continuous (un-snapped) progress per recipe used to drive the simulation.
  // Separate from [_progress] which stores the 0.5%-quantized value consumers read.
  final Map<String, double> _rawProgress = {};
  final Map<String, String> _stage = {};
  final Set<String> _simulatingRecipeIds = {};
  Timer? _simulationTimer;

  /// Finer ticks → smoother target curve for the ring lerp (iOS-like).
  static const Duration _simulationTick = Duration(milliseconds: 32);
  static const double _simulationCap = 94.0;
  static const double _phase1End = 15.0;
  static const double _phase2End = 50.0;

  /// 구간별 목표 시간(초): 5 + 20 + 30 = 55초, 0→15% 빠름 → 15→50% 느림 → 50→94% 일정.
  static const double _durPhase1Sec = 5.0;
  static const double _durPhase2Sec = 20.0;
  static const double _durPhase3Sec = 30.0;

  static double _ratePhase1() => _phase1End / _durPhase1Sec;
  static double _ratePhase2() => (_phase2End - _phase1End) / _durPhase2Sec;
  static double _ratePhase3() => (_simulationCap - _phase2End) / _durPhase3Sec;

  /// 목표 %는 0.5 단위로만 올라가게 해 5% 같은 거친 느낌을 막음; 링은 프레임 보간으로 부드럽게.
  static double _snapHalfPercent(double x) => (x * 2).round() / 2.0;

  static const List<({double min, double max, String label})> _stageRanges = [
    (min: 0, max: 10, label: '영상 확인 중'),
    (min: 10, max: 25, label: '메타데이터 수집 중'),
    (min: 25, max: 45, label: '자막/음성 분석 중'),
    (min: 45, max: 70, label: '재료 추출 중'),
    (min: 70, max: 90, label: '조리 단계 정리 중'),
    (min: 90, max: 100, label: '영양 정보 계산 중'),
  ];

  String _stageFromProgress(double progress) {
    if (progress >= 100) return '완료';
    final normalized = progress.clamp(0, 100).toDouble();
    for (final range in _stageRanges) {
      if (normalized >= range.min && normalized < range.max) {
        return range.label;
      }
    }
    return '분석중...';
  }

  void update(String recipeId, double progress, [String? stage]) {
    final normalizedProgress = progress.clamp(0, 100).toDouble();
    final current = _progress[recipeId] ?? 0.0;
    if (normalizedProgress < current && normalizedProgress < 100) return;
    _progress[recipeId] = normalizedProgress;
    _rawProgress[recipeId] = normalizedProgress;
    if (normalizedProgress >= 100 || stage == '완료') {
      _stage[recipeId] = '완료';
    } else {
      _stage[recipeId] = _stageFromProgress(normalizedProgress);
    }
    notifyListeners();
  }

  double getProgress(String recipeId) => _progress[recipeId] ?? 0.0;
  String getStage(String recipeId) =>
      _stage[recipeId] ?? _stageFromProgress(getProgress(recipeId));

  void remove(String recipeId) {
    stopProgressSimulation(recipeId);
    _progress.remove(recipeId);
    _rawProgress.remove(recipeId);
    _stage.remove(recipeId);
    notifyListeners();
  }

  /// 파싱 중 레시피 ID — 추가 시트를 내려도 진행률이 계속 오름.
  ///
  /// 시작 시각은 각 인스턴스의 필드로 저장하지 않고 (hot-reload 시 필드가 누락되어
  /// dart2js 에서 `Symbol(dartx._set)` 에러가 나는 걸 방지), 진행률 자체의 상태에서
  /// iterative step 으로 곡선을 만든다.
  void startProgressSimulation(String recipeId) {
    if (recipeId.isEmpty) return;
    _simulatingRecipeIds.add(recipeId);
    if (_progress[recipeId] == null) {
      _progress[recipeId] = 0.0;
      _rawProgress[recipeId] = 0.0;
      _stage[recipeId] = _stageFromProgress(0.0);
    } else {
      _rawProgress[recipeId] ??= _progress[recipeId]!;
    }
    if (_simulationTimer != null) return;
    _simulationTimer = Timer.periodic(
      _simulationTick,
      (_) => _tickSimulation(),
    );
  }

  void _tickSimulation() {
    const dtSec = 0.032; // [_simulationTick] 과 동기 (~31Hz)
    for (final id in _simulatingRecipeIds.toList()) {
      final raw = _rawProgress[id] ?? _progress[id] ?? 0.0;
      if (raw >= _simulationCap - 0.001) continue;

      double rate;
      if (raw < _phase1End) {
        rate = _ratePhase1();
      } else if (raw < _phase2End) {
        rate = _ratePhase2();
      } else {
        rate = _ratePhase3();
      }

      final nextRaw = math.min(raw + rate * dtSec, _simulationCap);
      _rawProgress[id] = nextRaw;

      // Expose to consumers in 0.5% steps so the ring's frame-by-frame lerp
      // sees smooth, quantized targets without the raw value's sub-pixel noise.
      final snapped = _snapHalfPercent(nextRaw);
      final current = _progress[id] ?? 0.0;
      if (snapped > current) {
        update(id, snapped);
      }
    }
  }

  void stopProgressSimulation(String recipeId) {
    _simulatingRecipeIds.remove(recipeId);
    if (_simulatingRecipeIds.isEmpty) {
      _simulationTimer?.cancel();
      _simulationTimer = null;
    }
  }

  /// When the backend finishes before the ~45s simulated curve reaches the end,
  /// run this **before** persisting `status: completed` so the parsing card’s
  /// ring visibly fills to 100% first; then the “ready” card can replace it.
  Future<void> animateCompletionRing(String recipeId) async {
    if (recipeId.isEmpty) return;
    stopProgressSimulation(recipeId);

    final pNow = getProgress(recipeId);
    if (pNow >= 99.99) {
      update(recipeId, 100.0, '완료');
      return;
    }
    final start = pNow.clamp(0.0, 99.0);
    final delta = 100.0 - start;
    // Longer jump → longer animation; cap so very fast parses still get a clear finish.
    final durationMs = (420 + delta * 11).round().clamp(420, 1400);
    const steps = 28;
    final stepMs = (durationMs / steps).round().clamp(6, 70);

    double easeOutCubic(double t) {
      final inv = 1.0 - t;
      return 1.0 - inv * inv * inv;
    }

    for (var i = 1; i <= steps; i++) {
      await Future.delayed(Duration(milliseconds: stepMs));
      final t = i / steps;
      final eased = easeOutCubic(t);
      final p = start + delta * eased;
      update(recipeId, p.clamp(0.0, 100.0), '완료');
    }
    update(recipeId, 100.0, '완료');
  }
}

/// Result of saved recipes stream: recipes loaded so far + total count from account.
class SavedRecipesResult {
  final List<Map<String, dynamic>> recipes;
  final int totalCount;
  final List<Map<String, dynamic>> recipebookCategories;
  final Map<String, List<String>> recipebookRecipeCategoryMap;
  const SavedRecipesResult(
    this.recipes,
    this.totalCount, {
    this.recipebookCategories = const [],
    this.recipebookRecipeCategoryMap = const {},
  });
}

/// Legacy recommendation search catalog cap. Live search uses paged RecipeSearchScreen.
@visibleForTesting
const int kRecipeSearchCatalogReadLimit = 80;

class RecipeService {
  /// App-wide instance so [getSavedRecipes] cache and Firestore subscription are shared
  /// (e.g. Home tab + pick-recipe sheet) instead of reloading on every sheet open.
  static final RecipeService shared = RecipeService();

  /// Mirrors `UserService._defaultIconKeyForCategory` so the saved-recipes
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final LocalStorageService _localStorage = LocalStorageService();

  /// Cached saved-recipes stream per user so Home and Temp share one subscription (no duplicate Firestore fetches).
  Stream<SavedRecipesResult>? _cachedSavedRecipesStream;
  String? _cachedSavedRecipesUserId;
  StreamController<SavedRecipesResult>? _savedRecipesReloadController;
  /// broadcast 스트림은 구독 전 emit 을 버린다. 빈 레시피북이 로딩에 남는 것을 막기 위해 마지막 값을 재전송한다.
  SavedRecipesResult? _lastSavedRecipesResult;

  /// 저장 레시피 로드 세대. `_loadAndEmitRecipes` 시작마다 증가시켜, 더 늦게 시작된
  /// 로드(예: 파싱 완료 후 reload)가 항상 최신 emit 을 갖도록 한다. 먼저 시작됐지만
  /// 늦게 끝난 stale 로드가 최신 카드(정상 재료/시간/칼로리)를 0/15/0 으로 덮어쓰는
  /// 경쟁 상태(네이버 파싱 직후 pull-to-refresh 전까지 0 표시 버그)를 막는다.
  int _savedRecipesLoadGeneration = 0;

  // Disk cache for logged-in home recipe list.
  static const Duration _savedRecipesCacheTtl = Duration(hours: 12);
  static const int _savedRecipesCacheMaxItems = 80;
  String? _lastSavedRecipesCacheSignature;
  static const Duration _recipeMetaCacheTtl = Duration(minutes: 20);
  /// 홈 검색/트렌드/카테고리 캐러셀 Firestore read 억제 (앱 나갔다 와도 1시간 재사용).
  static const Duration _exploreCacheTtl = Duration(hours: 1);
  static const int _exploreRecipeDocCacheMaxEntries = 200;
  static const int _explorePageCacheMaxEntries = 8;
  /// getExploreRecipesByIds — 동시 doc.get() 상한 (OOM 피크 완화).
  static const int _exploreRecipeIdFetchChunkSize = 30;
  final Map<String, Map<String, dynamic>> _recipeMetaCacheById = {};
  final Map<String, DateTime> _recipeMetaCachedAtById = {};
  final Map<int, _ExploreGuestsCacheEntry> _exploreGuestsCacheByLimit = {};
  final LruBoundedMap<String, _ExplorePageCacheEntry> _explorePageCacheByKey =
      LruBoundedMap(maxEntries: _explorePageCacheMaxEntries);
  final Map<int, _SeasonalIndexCacheEntry> _seasonalIndexCacheByMonth = {};
  final Map<String, _HomeSectionIndexCacheEntry> _homeSectionIndexCacheByKey = {};
  final Map<String, _ChefIndexCacheEntry> _chefIndexCacheByName = {};
  final LruBoundedMap<String, _ExploreRecipeDocCacheEntry>
  _exploreRecipeDocById =
      LruBoundedMap(maxEntries: _exploreRecipeDocCacheMaxEntries);
  _HomeTrendingFeedCacheEntry? _homeTrendingFeedCache;
  List<Map<String, dynamic>>? _hotGroupsCache;
  DateTime? _hotGroupsCachedAt;

  // In-memory cache for getRecipeById to avoid redundant Firestore reads on re-navigation
  static final Map<String, _ParseResponseCacheEntry> _parseResponseCache = {};
  static const Duration _parseResponseCacheTtl = Duration(minutes: 10);

  /// Last emitted recipe list (without optimistic merge) for instant re-emission.
  static List<Map<String, dynamic>> _lastEmittedRecipes = [];
  int _lastEmittedTotal = 0;

  /// 레시피북 미니 소셜 숫자 세션 예산. 프로세스 동안 uid가 바뀌면 리셋.
  int _miniSocialRefreshSessionUsed = 0;
  final Set<String> _miniSocialRefreshAttemptedIds = <String>{};

  /// 사용자별 레시피 제목 별칭. `users/{uid}.recipeTitleAliases.{recipeId}` 미러(로컬 캐시).
  /// 원본 `recipes/{id}`(공용) 제목은 건드리지 않으므로 다른 사용자는 원본 제목을 본다.
  /// mini doc 이 백필로 덮어써져도 별칭은 별도 필드라 유지된다.
  static Map<String, String> _recipeTitleAliases = <String, String>{};
  static bool _recipeTitleAliasesLoaded = false;

  /// `users/{uid}` 문서에서 별칭 맵을 로컬 캐시에 반영한다.
  static void _applyUserTitleAliases(Map<String, dynamic>? userData) {
    final raw = userData?['recipeTitleAliases'];
    final next = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final s = v?.toString().trim() ?? '';
        if (s.isNotEmpty) next[k.toString()] = s;
      });
    }
    _recipeTitleAliases = next;
    _recipeTitleAliasesLoaded = true;
  }
  List<Map<String, dynamic>> _lastRecipebookCategories = const [];
  Map<String, List<String>> _lastRecipebookRecipeCategoryMap = const {};
  DateTime? _lastSavedRecipesCacheWrittenAt;

  /// Notify that recipe list may have changed (e.g. new parsing started). Listeners refresh immediately.
  static final StreamController<void> _recipesChangedController =
      StreamController<void>.broadcast(sync: true);
  static void notifyRecipesChanged() {
    if (!_recipesChangedController.isClosed) {
      _recipesChangedController.add(null);
    }
  }

  /// 디스크에 저장된 레시피북 목록(유효 TTL 내)을 읽는다. optimistic 병합용.
  Future<({List<Map<String, dynamic>> recipes, int totalCount})?>
  _peekSavedRecipesDiskCache(String userId) async {
    try {
      final cachedPayload = await _localStorage.loadSavedRecipesCache(userId);
      if (cachedPayload == null) return null;

      final cachedAtIso = cachedPayload['cachedAt'] as String?;
      final cachedAt = cachedAtIso != null
          ? DateTime.tryParse(cachedAtIso)
          : null;
      if (cachedAt == null) return null;
      if (DateTime.now().difference(cachedAt) > _savedRecipesCacheTtl) {
        return null;
      }

      final totalCount = (cachedPayload['totalCount'] as num?)?.toInt() ?? 0;
      final recipesRaw = cachedPayload['recipes'] as List? ?? [];
      final recipes = recipesRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      return (recipes: recipes, totalCount: totalCount);
    } catch (_) {
      return null;
    }
  }

  Future<void> _emitInstantSavedRecipesWithOptimistic(
    String userId,
    StreamController<SavedRecipesResult> controller,
  ) async {
    if (controller.isClosed) return;

    var base = _lastEmittedRecipes;
    var total = _lastEmittedTotal;
    if (base.isEmpty) {
      final disk = await _peekSavedRecipesDiskCache(userId);
      if (disk != null && disk.recipes.isNotEmpty) {
        base = disk.recipes;
        total = disk.totalCount;
        _lastEmittedRecipes = List.from(base);
        _lastEmittedTotal = total;
      }
    }

    if (base.isEmpty && _optimisticRecipes.isEmpty) return;

    final patched = base.isEmpty
        ? <Map<String, dynamic>>[]
        : _patchRecipebookCategoryIdsOnCards(
            base,
            _lastRecipebookRecipeCategoryMap,
          );
    final instantMerged = _mergeOptimistic(patched);
    _emitSavedRecipes(
      controller,
      SavedRecipesResult(
        instantMerged,
        base.isEmpty
            ? instantMerged.length
            : total + _optimisticRecipes.length,
        recipebookCategories: _lastRecipebookCategories,
        recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
      ),
    );
  }

  void _emitSavedRecipes(
    StreamController<SavedRecipesResult> controller,
    SavedRecipesResult result,
  ) {
    _lastSavedRecipesResult = result;
    if (!controller.isClosed) {
      controller.add(result);
    }
  }

  /// Pull-to-refresh: 디스크 캐시·북마크 캐시를 비우고 Firestore에서 목록을 다시 emit.
  Future<void> reloadSavedRecipesFromNetwork() async {
    final user = _auth.currentUser;
    if (user == null) {
      notifyRecipesChanged();
      return;
    }
    await _localStorage.clearSavedRecipesCache(user.uid);
    UserService.invalidateSavedRecipesCache();
    final controller = _savedRecipesReloadController;
    if (controller != null && !controller.isClosed) {
      await _loadAndEmitRecipes(user.uid, controller);
    } else {
      notifyRecipesChanged();
    }
  }

  /// 파싱 진행률 공유 (홈 카드와 add_recipe 시트가 동일한 %/스테이지 표시).
  static final ParsingProgressCache parsingProgressCache =
      ParsingProgressCache();

  /// Optimistic parsing cards: show immediately with 0% progress, then fill in when real data arrives.
  static final Map<String, Map<String, dynamic>> _optimisticRecipes = {};

  /// Add a temporary card (0% progress) so it appears as soon as user pulls down. Real data will replace it in place.
  static String addOptimisticParsingRecipe({
    String? recipeId,
    required String sourceUrl,
  }) {
    final normalizedUrl = _normalizeSourceUrl(sourceUrl);
    // 같은 URL 의 이전 옵티미스틱 카드가 남아 빈 카드가 겹치지 않게 정리.
    if (normalizedUrl.isNotEmpty) {
      for (final id in List<String>.from(_optimisticRecipes.keys)) {
        final existingUrl = _normalizeSourceUrl(
          (_optimisticRecipes[id]?['sourceUrl'] as String?) ?? '',
        );
        if (existingUrl == normalizedUrl) {
          _optimisticRecipes.remove(id);
          parsingProgressCache.remove(id);
        }
      }
    }
    final id = recipeId ?? 'opt_${DateTime.now().millisecondsSinceEpoch}';
    final platform = _extractPlatformFromUrl(normalizedUrl.isNotEmpty ? normalizedUrl : sourceUrl);
    _optimisticRecipes[id] = {
      'id': id,
      'status': 'parsing',
      'progress': 0.0,
      'stage': '시작 중...',
      'sourceUrl': normalizedUrl.isNotEmpty ? normalizedUrl : sourceUrl,
      'recipe': {'title': '분석 중..'},
      'source': {
        'url': normalizedUrl.isNotEmpty ? normalizedUrl : sourceUrl,
        'platform': platform,
      },
      'createdAt': DateTime.now().toIso8601String(),
      'parsingStartedAt': DateTime.now().toIso8601String(),
    };
    notifyRecipesChanged();
    return id;
  }

  /// Replace a temporary optimistic ID with a real Firestore ID.
  static void replaceOptimisticRecipeId(String oldId, String newId) {
    if (oldId == newId) return;
    final data = _optimisticRecipes.remove(oldId);
    if (data != null) {
      data['id'] = newId;
      // 동일 URL 로 남은 다른 옵티미스틱(옛 opt_ 등) 제거.
      final url = _normalizeSourceUrl((data['sourceUrl'] as String?) ?? '');
      if (url.isNotEmpty) {
        for (final id in List<String>.from(_optimisticRecipes.keys)) {
          if (id == newId) continue;
          final existingUrl = _normalizeSourceUrl(
            (_optimisticRecipes[id]?['sourceUrl'] as String?) ?? '',
          );
          if (existingUrl == url) {
            _optimisticRecipes.remove(id);
            parsingProgressCache.remove(id);
          }
        }
      }
      _optimisticRecipes[newId] = data;
    }
    final progress = parsingProgressCache.getProgress(oldId);
    if (progress > 0) {
      parsingProgressCache.stopProgressSimulation(oldId);
      parsingProgressCache._progress.remove(oldId);
      parsingProgressCache._rawProgress.remove(oldId);
      parsingProgressCache._stage.remove(oldId);
    }
  }

  /// Remove an optimistic card (e.g. when a duplicate is detected).
  /// [recipeId] 와 같은 sourceUrl 을 가진 잔여 옵티미스틱 카드도 함께 제거한다.
  static void removeOptimisticParsingRecipe(String recipeId, {String? sourceUrl}) {
    final removed = _optimisticRecipes.remove(recipeId);
    parsingProgressCache.remove(recipeId);
    final url = _normalizeSourceUrl(
      sourceUrl ?? (removed?['sourceUrl'] as String?) ?? '',
    );
    if (url.isNotEmpty) {
      for (final id in List<String>.from(_optimisticRecipes.keys)) {
        final existingUrl = _normalizeSourceUrl(
          (_optimisticRecipes[id]?['sourceUrl'] as String?) ?? '',
        );
        if (existingUrl == url) {
          _optimisticRecipes.remove(id);
          parsingProgressCache.remove(id);
        }
      }
    }
    notifyRecipesChanged();
  }

  /// Replace an optimistic parsing card in-place with real recipe data.
  /// The card stays at position 0 (where optimistic cards live) but transforms
  /// from "parsing" to "completed" with full metadata — no position jump.
  static void replaceOptimisticWithExistingRecipe(
    String optimisticId,
    Map<String, dynamic> realRecipeData,
  ) {
    _optimisticRecipes.remove(optimisticId);
    parsingProgressCache.remove(optimisticId);
    final realId = (realRecipeData['id'] as String?) ?? '';
    if (realId.isNotEmpty) {
      _lastEmittedRecipes.removeWhere((r) => (r['id'] as String?) == realId);
      _lastEmittedRecipes.insert(0, realRecipeData);
    }
    notifyRecipesChanged();
  }

  /// Update an existing optimistic parsing card with real metadata from the
  /// early video_info SSE event (title, thumbnail, uploader, channel).
  static void updateOptimisticParsingRecipe(
    String recipeId, {
    String? title,
    String? thumbnail,
    String? uploader,
    String? channel,
  }) {
    final card = _optimisticRecipes[recipeId];
    if (card == null) return;

    if (title != null && title.isNotEmpty) {
      final recipe = (card['recipe'] as Map<String, dynamic>?) ?? {};
      recipe['title'] = title;
      card['recipe'] = recipe;
    }
    if (thumbnail != null && thumbnail.isNotEmpty) {
      card['thumbnailUrl'] = thumbnail;
      final recipe = (card['recipe'] as Map<String, dynamic>?) ?? {};
      recipe['thumbnailUrl'] = thumbnail;
      card['recipe'] = recipe;
    }
    if (uploader != null && uploader.isNotEmpty) {
      card['uploader'] = uploader;
      final source = (card['source'] as Map<String, dynamic>?) ?? {};
      source['uploader'] = uploader;
      card['source'] = source;
    }
    if (channel != null && channel.isNotEmpty) {
      card['channel'] = channel;
      final source = (card['source'] as Map<String, dynamic>?) ?? {};
      source['channel'] = channel;
      card['source'] = source;
    }
    notifyRecipesChanged();
  }

  static String _extractPlatformFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return 'youtube';
    }
    if (lower.contains('instagram.com')) return 'instagram';
    if (lower.contains('tiktok.com')) return 'tiktok';
    return 'unknown';
  }

  /// UI에서 소스 URL만 있을 때 플랫폼 아이콘 표시용.
  static String inferPlatformFromUrl(String url) =>
      _extractPlatformFromUrl(url);

  static String _normalizeSourceUrl(String sourceUrl) {
    final raw = sourceUrl.trim();
    if (raw.isEmpty) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;

    final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    String rebuiltHost = host;
    List<String> rebuiltSegments = segments;
    final qp = Map<String, String>.from(uri.queryParameters);

    if (host.contains('youtu.be')) {
      if (segments.isNotEmpty) {
        qp['v'] = segments.first;
      }
      rebuiltHost = 'www.youtube.com';
      rebuiltSegments = const ['watch'];
    }

    if (rebuiltHost.contains('youtube.com')) {
      String? videoId = qp['v'];
      if ((videoId == null || videoId.isEmpty) && rebuiltSegments.length >= 2) {
        final first = rebuiltSegments.first;
        if (first == 'shorts' || first == 'embed' || first == 'live') {
          videoId = rebuiltSegments[1];
        }
      }
      if (videoId != null && videoId.isNotEmpty) {
        return Uri(
          scheme: 'https',
          host: 'www.youtube.com',
          path: '/watch',
          queryParameters: {'v': videoId},
        ).toString();
      }
    }

    if (rebuiltHost.contains('instagram.com')) {
      if (segments.length >= 2) {
        final first = segments[0];
        if (first == 'reel' ||
            first == 'reels' ||
            first == 'p' ||
            first == 'tv') {
          return Uri(
            scheme: 'https',
            host: 'www.instagram.com',
            path: '/$first/${segments[1]}/',
          ).toString();
        }
      }
    }

    if (rebuiltHost.contains('tiktok.com')) {
      String? id;
      for (var i = 0; i < rebuiltSegments.length - 1; i++) {
        if (rebuiltSegments[i] == 'video') {
          id = rebuiltSegments[i + 1];
          break;
        }
      }
      if (id != null && id.isNotEmpty) {
        return Uri(
          scheme: 'https',
          host: 'www.tiktok.com',
          path: '/video/$id',
        ).toString();
      }
    }

    // 네이버 블로그: 래퍼(link.naver.com) unwrap 후 모바일 canonical로.
    // 단축 URL(naver.me)은 클라가 redirect 풀 수 없어 normalize 불가 — 그대로 둔다.
    if (rebuiltHost.contains('link.naver.com') ||
        rebuiltHost.contains('blog.naver.com') ||
        raw.toLowerCase().contains('naver.me')) {
      final unwrapped = unwrapNaverBlogUrl(raw);
      final unwrappedUri = Uri.tryParse(unwrapped);
      if (unwrappedUri != null) {
        rebuiltHost = unwrappedUri.host.toLowerCase();
        rebuiltSegments =
            unwrappedUri.pathSegments.where((s) => s.isNotEmpty).toList();
        qp
          ..clear()
          ..addAll(unwrappedUri.queryParameters);
      }
    }
    if (rebuiltHost.contains('blog.naver.com')) {
      String? blogId;
      String? logNo;
      final qBlogId = qp['blogId'];
      final qLogNo = qp['logNo'];
      if (qBlogId != null &&
          qBlogId.isNotEmpty &&
          qLogNo != null &&
          qLogNo.isNotEmpty &&
          RegExp(r'^\d+$').hasMatch(qLogNo)) {
        blogId = qBlogId;
        logNo = qLogNo;
      } else if (rebuiltSegments.length == 2 &&
          RegExp(r'^\d+$').hasMatch(rebuiltSegments[1])) {
        blogId = rebuiltSegments[0];
        logNo = rebuiltSegments[1];
      }
      if (blogId != null && logNo != null) {
        return Uri(
          scheme: 'https',
          host: 'm.blog.naver.com',
          path: '/$blogId/$logNo',
        ).toString();
      }
    }

    final filteredQuery = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      final k = entry.key.toLowerCase();
      if (k.startsWith('utm_')) continue;
      if (k == 'feature' || k == 'si' || k == 'fbclid' || k == 'igshid') {
        continue;
      }
      filteredQuery[entry.key] = entry.value;
    }

    return Uri(
      scheme: scheme,
      host: rebuiltHost,
      path: uri.path,
      queryParameters: filteredQuery.isEmpty ? null : filteredQuery,
    ).toString();
  }

  static String? _buildSourceKey(String sourceUrl) {
    final normalized = _normalizeSourceUrl(sourceUrl);
    if (normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    if (host.contains('youtube.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return 'youtube:$v';
      if (segments.length >= 2) {
        final first = segments.first;
        if (first == 'shorts' || first == 'embed' || first == 'live') {
          return 'youtube:${segments[1]}';
        }
      }
    }

    if (host.contains('instagram.com') && segments.length >= 2) {
      final first = segments.first;
      if (first == 'reel' ||
          first == 'reels' ||
          first == 'p' ||
          first == 'tv') {
        return 'instagram:${segments[1]}';
      }
    }

    if (host.contains('tiktok.com')) {
      for (var i = 0; i < segments.length - 1; i++) {
        if (segments[i] == 'video') {
          return 'tiktok:${segments[i + 1]}';
        }
      }
    }

    if (host.contains('blog.naver.com')) {
      // _normalizeSourceUrl 이 모바일 형태로 통일하므로 segments == [blogId, logNo].
      if (segments.length == 2 && RegExp(r'^\d+$').hasMatch(segments[1])) {
        return 'naver_blog:${segments[0]}__${segments[1]}';
      }
    }
    return null;
  }

  /// 같은 영상 URL의 recipes 문서를 찾는다.
  ///
  /// 기본은 공개 문서만 (`isHidden == false`). 숨김 껍데기가 섞이면
  /// Firestore list 규칙으로 쿼리 전체가 실패한다.
  /// 네이버 메타 조회만 [includeHidden] true.
  Future<QuerySnapshot<Map<String, dynamic>>?> _queryRecipesBySource(
    String sourceUrl, {
    bool completedOnly = false,
    int? limit,
    String? userId,
    bool includeHidden = false,
  }) async {
    final raw = sourceUrl.trim();
    if (raw.isEmpty) return null;
    final normalized = _normalizeSourceUrl(raw);
    final sourceKey = _buildSourceKey(raw);

    Query<Map<String, dynamic>> base = _firestore.collection('recipes');
    if (completedOnly) {
      base = base.where('status', isEqualTo: 'completed');
    }
    if (userId != null && userId.isNotEmpty) {
      base = base.where('userId', isEqualTo: userId);
    }
    // 공개 URL 조회는 isHidden==false 를 쿼리에 넣는다. 안 넣으면 숨김 껍데기가
    // 한 건이라도 있을 때 list 규칙 때문에 쿼리 전체가 permission-denied 가 된다.
    if (shouldConstrainSourceQueryToVisible(
      includeHidden: includeHidden,
      userId: userId,
    )) {
      base = base.where('isHidden', isEqualTo: false);
    }

    Query<Map<String, dynamic>> withLimit(Query<Map<String, dynamic>> q) {
      if (limit == null) return q;
      return q.limit(limit);
    }

    if (sourceKey != null) {
      final byKey = await withLimit(
        base.where('sourceKey', isEqualTo: sourceKey),
      ).get();
      if (byKey.docs.isNotEmpty) return byKey;
    }

    final byRaw = await withLimit(
      base.where('sourceUrl', isEqualTo: raw),
    ).get();
    if (byRaw.docs.isNotEmpty) return byRaw;

    if (normalized != raw) {
      final byNormalized = await withLimit(
        base.where('sourceUrl', isEqualTo: normalized),
      ).get();
      if (byNormalized.docs.isNotEmpty) return byNormalized;
    }

    return byRaw;
  }

  bool _isVisibleRecipeDocData(Map<String, dynamic> data) {
    return data['isHidden'] != true;
  }

  /// 나의 레시피북(savedRecipes)에 포함할지 판단.
  ///
  /// [isHidden] 은 **공개 피드**(탐색·카테고리·네이버 외부 섹션)에서만 숨긴다.
  /// 본인이 savedRecipes 에 붙인 hidden 레시피(네이버 블로그 등)는 레시피북에
  /// 표시한다 — 분석 중 → 완료 카드 전환이 여기서 유지된다.
  ///
  /// 예외: `hiddenReason: duplicate_of:*` 사본은 canonical 이 대신 노출되므로 제외.
  /// 파싱 실패·취소 문서는 Firestore 에 남겨 두되 레시피북에는 붙이지 않는다.
  bool _includeHiddenInSavedRecipesStream(Map<String, dynamic> data) {
    if (isCancelledRecipeData(data)) return false;
    if (_isDuplicateOfHiddenData(data)) return false;
    final status = (data['status'] as String?)?.toLowerCase();
    if (status == 'error' || status == 'failed') return false;
    if (data['isHidden'] != true) return true;
    return true;
  }

  /// dedup 임시 사본(`hiddenReason: duplicate_of:*`) 여부.
  static bool _isDuplicateOfHiddenData(Map<String, dynamic> data) {
    if (data['isHidden'] != true) return false;
    final reason = (data['hiddenReason'] as String?) ?? '';
    return reason.startsWith('duplicate_of:');
  }

  /// 재료·칼로리가 모두 비어 completed 처럼 보이는 "가짜 카드" 후보.
  /// (UI 는 totalMinutes==0 을 15분으로 표시하므로 0재료·15분·0kcal 로 보임)
  static bool _looksLikeHollowCompletedCard(Map<String, dynamic> m) {
    final status = ((m['status'] as String?) ?? 'completed').toLowerCase();
    if (status == 'parsing' || status == 'error' || status == 'cancelled') {
      return false;
    }
    final ing = (m['ingredientCount'] as num?)?.toInt() ?? 0;
    final cal = (m['calories'] as num?)?.toInt() ?? 0;
    return ing <= 0 && cal <= 0;
  }

  /// dedup 임시 id 를 레시피북 배열·mini doc 에서만 제거 (saveCount 감소 없음).
  Future<void> cleanupDedupTempSavedRecipe(String uid, String recipeId) async {
    if (uid.isEmpty || recipeId.isEmpty) return;
    try {
      await _firestore.collection('users').doc(uid).set({
        'savedRecipes': FieldValue.arrayRemove([recipeId]),
        'savedAt.$recipeId': FieldValue.delete(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[RecipeService] cleanupDedupTemp arrayRemove failed: $e');
    }
    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .delete();
    } catch (e) {
      debugPrint('[RecipeService] cleanupDedupTemp mini delete failed: $e');
    }
    UserService.invalidateSavedRecipesCache();
  }

  /// User cancelled parse (not an error doc) — reusable slot for same URL.
  static bool isCancelledRecipeData(Map<String, dynamic> data) {
    return (data['status'] as String?)?.toLowerCase() == 'cancelled';
  }

  static bool isReusableCancelledRecipeData(Map<String, dynamic> data) {
    if (!isCancelledRecipeData(data)) return false;
    if (data['error'] != null || data['errorType'] != null) return false;
    final reason = (data['hiddenReason'] as String?) ?? '';
    if (reason.startsWith('duplicate_of:')) return false;
    return true;
  }

  /// Find a clean-cancelled doc for [sourceUrl] that can be revived on re-parse.
  Future<String?> findReusableCancelledRecipeId(String sourceUrl) async {
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
        limit: 8,
      );
      final matches = (querySnapshot?.docs ?? [])
          .where((doc) => isReusableCancelledRecipeData(doc.data()))
          .toList();
      if (matches.isEmpty) return null;
      return matches.first.id;
    } catch (e) {
      print('[RecipeService] findReusableCancelledRecipeId error: $e');
      return null;
    }
  }

  Future<String?> findReusableFailedRecipeId(
    String sourceUrl, {
    required String userId,
  }) async {
    if (userId.isEmpty) return null;
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
        limit: 8,
      );
      final matches = (querySnapshot?.docs ?? [])
          .where((doc) => isReusableFailedRecipeData(doc.data(), userId: userId))
          .toList();
      if (matches.isEmpty) return null;
      return matches.first.id;
    } catch (e) {
      print('[RecipeService] findReusableFailedRecipeId error: $e');
      return null;
    }
  }

  Future<int> readParsingGeneration(String recipeId) async {
    try {
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      final raw = doc.data()?['parsingGeneration'];
      if (raw is num) return raw.toInt();
      return 1;
    } catch (_) {
      return 1;
    }
  }

  bool _isReusableRecipeDocData(Map<String, dynamic> data) {
    final status = (data['status'] as String?)?.toLowerCase();
    final recipeRaw = data['recipe'];
    final hasRecipePayload = recipeRaw is Map && recipeRaw.isNotEmpty;
    // Legacy docs may not have status; treat null as completed/public.
    final isCompletedLike = status == null || status == 'completed';
    return hasRecipePayload && isCompletedLike;
  }

  /// Like [_isReusableRecipeDocData] but also matches recipes that are still
  /// parsing. Used for dedup checks so we don't create a second document for
  /// the same URL while another user's parse is in progress.
  bool _existsForDedup(Map<String, dynamic> data) {
    return isReusableSourceDocForDedup(data);
  }

  bool _isNaverBlogMetaDoc(Map<String, dynamic> data) {
    final source = data['source'];
    if (source is Map) {
      final platform = (source['platform'] as String?)?.toLowerCase() ?? '';
      if (platform == 'naver_blog') return true;
    }
    final sourceKey = (data['sourceKey'] as String?) ?? '';
    return sourceKey.startsWith('naver_blog:');
  }

  /// URL당 공용 메타 1건(dedup) 후보. hidden 포함, duplicate_of 사본 제외.
  bool _isReusableNaverMetaDocData(Map<String, dynamic> data) {
    if (!_isNaverBlogMetaDoc(data)) return false;
    final reason = (data['hiddenReason'] as String?) ?? '';
    if (reason.startsWith('duplicate_of:')) return false;
    final status = (data['status'] as String?)?.toLowerCase();
    if (status == 'failed' || status == 'error' || status == 'cancelled') {
      return false;
    }
    if (status == 'parsing') return true;
    if (status == null || status == 'completed') {
      final recipeRaw = data['recipe'];
      return recipeRaw is Map && recipeRaw.isNotEmpty;
    }
    return false;
  }

  /// 네이버 블로그: sourceKey 기준 공용 메타 조회 (isHidden 포함).
  /// URL당 Firestore meta 1건 dedup(B) 에 사용한다.
  Future<Map<String, dynamic>?> getNaverBlogMetaForDedup(String sourceUrl) async {
    if (!isNaverBlogUrl(sourceUrl.trim())) return null;
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
        includeHidden: true,
      );
      final matches = (querySnapshot?.docs ?? [])
          .where((doc) => _isReusableNaverMetaDocData(doc.data()))
          .toList();
      if (matches.isEmpty) return null;

      matches.sort((a, b) {
        final sa = (a.data()['status'] as String?) ?? 'completed';
        final sb = (b.data()['status'] as String?) ?? 'completed';
        if (sa == 'completed' && sb != 'completed') return -1;
        if (sb == 'completed' && sa != 'completed') return 1;
        return 0;
      });

      final doc = matches.first;
      return {'id': doc.id, ...Map<String, dynamic>.from(doc.data())};
    } catch (e) {
      print('[RecipeService] getNaverBlogMetaForDedup error: $e');
      return null;
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _visibleRecipeDocs(
    QuerySnapshot<Map<String, dynamic>>? snapshot,
  ) {
    if (snapshot == null) return const [];
    return snapshot.docs
        .where((doc) => _isVisibleRecipeDocData(doc.data()))
        .toList();
  }

  /// Merge optimistic entries into the list (prepend if not already present).
  /// Remove from optimistic when real data appears (by ID or normalized sourceUrl).
  List<Map<String, dynamic>> _mergeOptimistic(List<Map<String, dynamic>> list) {
    final ids = list.map((r) => r['id'] as String?).whereType<String>().toSet();
    final realSourceUrls = <String>{};
    for (final r in list) {
      final url = _normalizeSourceUrl(
        (r['sourceUrl'] as String?)?.trim() ??
            ((r['source'] is Map ? (r['source'] as Map)['url'] : null)
                    as String?)
                ?.trim() ??
            '',
      );
      if (url.isNotEmpty) realSourceUrls.add(url);
    }

    for (final id in List<String>.from(_optimisticRecipes.keys)) {
      if (ids.contains(id)) {
        _optimisticRecipes.remove(id);
        parsingProgressCache.remove(id);
        continue;
      }
      final optUrl = _normalizeSourceUrl(
        (_optimisticRecipes[id]?['sourceUrl'] as String?)?.trim() ?? '',
      );
      if (optUrl.isNotEmpty && realSourceUrls.contains(optUrl)) {
        _optimisticRecipes.remove(id);
        parsingProgressCache.remove(id);
      }
    }
    final merged = List<Map<String, dynamic>>.from(list);
    for (final e in _optimisticRecipes.entries) {
      if (!ids.contains(e.key)) {
        merged.insert(0, e.value);
        ids.add(e.key);
      }
    }
    return _dedupeRecipeCardsBySourceUrl(merged);
  }

  /// 같은 소스 URL(또는 opt_ 잔여)로 생긴 중복 카드를 하나로 합친다.
  /// completed > parsing, 실 ID > opt_, 제목/썸네일 있는 쪽을 우선한다.
  static List<Map<String, dynamic>> _dedupeRecipeCardsBySourceUrl(
    List<Map<String, dynamic>> recipes,
  ) {
    if (recipes.length <= 1) return recipes;

    int score(Map<String, dynamic> r) {
      final id = (r['id'] as String?) ?? '';
      final status = (r['status'] as String?) ?? 'completed';
      final recipeData = r['recipe'] as Map<String, dynamic>? ?? {};
      final title = ((r['title'] as String?) ??
              (recipeData['title'] as String?) ??
              (recipeData['name'] as String?) ??
              '')
          .trim();
      final thumb = ((r['thumbnailUrl'] as String?) ?? '').trim();
      var s = 0;
      if (!id.startsWith('opt_')) s += 100;
      if (status == 'completed') {
        s += 50;
      } else if (status == 'parsing') {
        s += 10;
      }
      if (title.isNotEmpty && title != '분석 중..' && title != '레시피') s += 20;
      if (thumb.isNotEmpty) s += 10;
      return s;
    }

    String sourceKeyOf(Map<String, dynamic> r) {
      final url = _normalizeSourceUrl(
        (r['sourceUrl'] as String?)?.trim() ??
            ((r['source'] is Map ? (r['source'] as Map)['url'] : null)
                    as String?)
                ?.trim() ??
            '',
      );
      if (url.isNotEmpty) return 'url:$url';
      final id = (r['id'] as String?) ?? '';
      return 'id:$id';
    }

    final bestByKey = <String, Map<String, dynamic>>{};
    final order = <String>[];
    for (final r in recipes) {
      final key = sourceKeyOf(r);
      final existing = bestByKey[key];
      if (existing == null) {
        bestByKey[key] = r;
        order.add(key);
        continue;
      }
      if (score(r) > score(existing)) {
        bestByKey[key] = r;
      }
    }

    return [
      for (final key in order) bestByKey[key]!,
    ].where((r) {
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) return false;
      // ID 교체 후 홈 캐시에만 남은 죽은 opt_ 카드는 표시하지 않는다.
      if (id.startsWith('opt_') && !_optimisticRecipes.containsKey(id)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// 홈 캐시 등에 남은 죽은 옵티미스틱(opt_) 카드인지.
  static bool isLiveOptimisticRecipeId(String recipeId) =>
      _optimisticRecipes.containsKey(recipeId);

  /// 홈/레시피북 표시용 중복·고스트 카드 제거 (URL dedupe + 죽은 opt_).
  static List<Map<String, dynamic>> dedupeRecipeCardsForDisplay(
    List<Map<String, dynamic>> recipes,
  ) =>
      _dedupeRecipeCardsBySourceUrl(recipes);

  // Check if a recipe with the given sourceUrl already exists in Firebase (any user)
  Future<Map<String, dynamic>?> getRecipeBySourceUrl(String sourceUrl) async {
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
      );

      final reusableDocs = _visibleRecipeDocs(querySnapshot)
          .where((doc) => _isReusableRecipeDocData(doc.data()))
          .toList();
      if (reusableDocs.isEmpty) {
        return null;
      }

      final doc = reusableDocs.first;
      final data = doc.data();
      final convertedData = Map<String, dynamic>.from(data);
      return {'id': doc.id, ...convertedData};
    } catch (e) {
      print('Error getting recipe by sourceUrl: $e');
      return null;
    }
  }

  /// 같은 URL의 공개 문서(완료 또는 파싱 중). 숨김 껍데기는 쿼리에서 제외한다.
  /// 동시 파싱 때 두 번째 유저가 새 id 를 만들지 않게 한다.
  Future<Map<String, dynamic>?> getAnyRecipeBySourceUrl(String sourceUrl) async {
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
      );

      final matchingDocs = (querySnapshot?.docs ?? [])
          .where((doc) => _existsForDedup(doc.data()))
          .toList();
      if (matchingDocs.isEmpty) return null;

      // Prefer completed docs over parsing ones.
      matchingDocs.sort((a, b) {
        final sa = (a.data()['status'] as String?) ?? 'completed';
        final sb = (b.data()['status'] as String?) ?? 'completed';
        if (sa == 'completed' && sb != 'completed') return -1;
        if (sb == 'completed' && sa != 'completed') return 1;
        return 0;
      });

      final doc = matchingDocs.first;
      return {'id': doc.id, ...Map<String, dynamic>.from(doc.data())};
    } catch (e) {
      print('Error in getAnyRecipeBySourceUrl: $e');
      return null;
    }
  }

  /// All recipe document IDs that have this sourceUrl (same recipe saved by different users).
  Future<List<String>> getRecipeIdsBySourceUrl(String sourceUrl) async {
    try {
      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        completedOnly: false,
      );
      return _visibleRecipeDocs(querySnapshot)
          .where((doc) => _isReusableRecipeDocData(doc.data()))
          .map((d) => d.id)
          .toList();
    } catch (e) {
      print('Error getting recipe IDs by sourceUrl: $e');
      return [];
    }
  }

  /// 사용자가 이미 이 sourceUrl의 레시피를 저장했는지 확인 (savedRecipes 기준)
  Future<String?> getUserSavedRecipeIdBySourceUrl(String sourceUrl) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      final url = sourceUrl.trim();
      if (url.isEmpty) return null;
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final savedIdsRaw = List<String>.from(
        userDoc.data()?['savedRecipes'] ?? [],
      );
      if (savedIdsRaw.isEmpty) return null;
      final savedIds = savedIdsRaw.toSet();

      if (isNaverBlogUrl(url)) {
        final meta = await getNaverBlogMetaForDedup(url);
        final metaId = meta?['id'] as String?;
        if (metaId != null && savedIds.contains(metaId)) return metaId;
        return null;
      }

      final matched = await _queryRecipesBySource(url, completedOnly: false);
      final matchedDocs = _visibleRecipeDocs(matched);
      if (matchedDocs.isEmpty) return null;

      for (final doc in matchedDocs) {
        if (!_isReusableRecipeDocData(doc.data())) continue;
        if (savedIds.contains(doc.id)) return doc.id;
      }
      return null;
    } catch (e) {
      print('Error checking saved recipe by sourceUrl: $e');
      return null;
    }
  }

  /// First resolves user-owned recipe; if not found, resolves user-saved completed recipe.
  Future<String?> getUserSavedOrOwnedRecipeIdBySourceUrl(
    String sourceUrl,
  ) async {
    final owned = await getUserRecipeIdBySourceUrl(sourceUrl);
    if (owned != null) return owned;
    return getUserSavedRecipeIdBySourceUrl(sourceUrl);
  }

  // Check if the current user already has a recipe with the given sourceUrl (created by them).
  // Failed/error recipes are excluded so the user can re-parse the same URL.
  Future<String?> getUserRecipeIdBySourceUrl(String sourceUrl) async {
    final user = _auth.currentUser;
    if (user == null) {
      return null;
    }

    try {
      if (isNaverBlogUrl(sourceUrl.trim())) {
        final meta = await getNaverBlogMetaForDedup(sourceUrl);
        if (meta != null && meta['userId'] == user.uid) {
          return meta['id'] as String?;
        }
        return null;
      }

      final querySnapshot = await _queryRecipesBySource(
        sourceUrl,
        userId: user.uid,
        limit: 5,
      );
      final visibleDocs = _visibleRecipeDocs(querySnapshot);
      for (final doc in visibleDocs) {
        final status = (doc.data()['status'] as String?)?.toLowerCase();
        if (status == 'failed' || status == 'error' || status == 'cancelled') {
          continue;
        }
        return doc.id;
      }
      return null;
    } catch (e) {
      print('Error checking user recipe by sourceUrl: $e');
      return null;
    }
  }

  /// Returns normalized URL and canonical sourceKey for writes.
  ({String normalizedUrl, String? sourceKey}) buildCanonicalSourceInfo(
    String sourceUrl,
  ) {
    final normalized = _normalizeSourceUrl(sourceUrl);
    return (normalizedUrl: normalized, sourceKey: _buildSourceKey(normalized));
  }

  // Get ParseResponse from existing recipe data
  Future<models.ParseResponse?> getParseResponseFromRecipeData(
    Map<String, dynamic> recipeData,
  ) async {
    try {
      // Convert Firestore maps to Map<String, dynamic> recursively
      final source = _toMapStringDynamic(recipeData['source']);
      final recipe = _toMapStringDynamic(recipeData['recipe']);
      final nutrition = _toMapStringDynamic(recipeData['nutrition']);
      _hydrateSourceTaxonomyFromRecipeDoc(source, recipeData);

      // Create and return the ParseResponse
      final parseResponse = models.ParseResponse.fromJson({
        'source': source,
        'recipe': recipe,
        'nutrition': nutrition,
        'debug': {},
      });

      return parseResponse;
    } catch (e, stackTrace) {
      print('Error converting recipe data to ParseResponse: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  // Save a recipe (Firebase for authenticated users, local for unauthenticated)
  Future<String> saveRecipe({
    required models.ParseResponse parseResponse,
    String? sourceUrl,
  }) async {
    final user = _auth.currentUser;
    final canonical = sourceUrl != null && sourceUrl.isNotEmpty
        ? buildCanonicalSourceInfo(sourceUrl)
        : null;
    final canonicalUrl = canonical?.normalizedUrl;
    final sourceKey = canonical?.sourceKey;

    // If user is not logged in, save locally
    if (user == null) {
      print('[RecipeService] User not logged in, saving locally');
      return await _localStorage.saveRecipeLocally(
        parseResponse: parseResponse,
        sourceUrl: canonicalUrl ?? sourceUrl,
      );
    }

    // User is logged in, save to Firebase
    // Check if user already has this recipe saved
    if (canonicalUrl != null && canonicalUrl.isNotEmpty) {
      final existingRecipeId = await getUserRecipeIdBySourceUrl(canonicalUrl);
      if (existingRecipeId != null) {
        throw Exception('이미 저장된 레시피입니다');
      }
    }

    final recipe = parseResponse.recipe;
    final nutrition = parseResponse.nutrition;

    // Create recipe document
    final recipeData = {
      'userId': user.uid,
      'title': recipe.name ?? parseResponse.source['title'] ?? '레시피',
      'sourceUrl': canonicalUrl ?? sourceUrl,
      'sourceKey': sourceKey,
      'thumbnailUrl': parseResponse.source['thumbnail'] ?? '',
      'source': parseResponse
          .source, // This includes uploader, channel, uploader_id, categories, tags, nutrition_rating
      'categories':
          parseResponse.source['categories'] ??
          {}, // Save categories for filtering
      'tags': parseResponse.source['tags'] ?? [], // Save tags for display
      ...recipeDisplayMetaWriteFields(parseResponse.source),
      'nutrition_rating':
          parseResponse.source['nutrition_rating'] ??
          'A', // Save nutrition rating
      'recipe': {
        'name': recipe.name,
        'servings': recipe.servings,
        'ingredients': recipe.ingredients
            .map((ing) => ing.toRecipeStorageMap())
            .toList(),
        'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
        'equipment': recipe.equipment,
        'notes': recipe.notes,
      },
      'nutrition': {
        'per_serving': nutrition.perServing,
        'assumptions': nutrition.assumptions,
        'llm_estimate': nutrition.llmEstimate != null
            ? {
                'calories_per_serving':
                    nutrition.llmEstimate!.caloriesPerServing,
                'protein_g': nutrition.llmEstimate!.proteinG,
                'fat_g': nutrition.llmEstimate!.fatG,
                'carbs_g': nutrition.llmEstimate!.carbsG,
                'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                'sugar_g': nutrition.llmEstimate!.sugarG,
                'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                'fiber_g': nutrition.llmEstimate!.fiberG,
              }
            : null,
      },
      'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
      'usedOcr': parseResponse.debug['used_ocr'] == true,
      'purchaseOccasionCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'isHidden': false,
      'completedAt':
          FieldValue.serverTimestamp(), // Store completion time for sorting
      'status': 'completed', // Store status for sorting
    };

    // Initialize save tracking fields
    final docRef = _firestore.collection('recipes').doc();
    recipeData['saveCount'] = RecipeSocialCounts.seedSaveCount(docRef.id);
    recipeData['weeklySaves'] = 0;
    recipeData['monthlySaves'] = 0;
    recipeData['lastSavedAt'] = null;
    recipeData['viewCount'] = 0;
    recipeData['lastViewedAt'] = null;

    // Add recipe to recipes collection
    await docRef.set(recipeData);

    // If thumbnail exists, upload to Storage; extension creates small copy under thumbnails/
    final originalThumbnailUrl = parseResponse.source['thumbnail'] ?? '';
    if (originalThumbnailUrl.isNotEmpty) {
      try {
        final sourceMap = parseResponse.source;
        final pair = await _uploadThumbnailToStorage(
          thumbnailUrl: originalThumbnailUrl,
          recipeId: docRef.id,
          sourceUrl: sourceMap['url'] as String?,
          platform: sourceMap['platform'] as String?,
        );
        if (pair != null) {
          final patch = <String, dynamic>{
            'thumbnailUrlLarge': pair.largeUrl,
            'thumbnailUrl': pair.cardUrl,
          };
          if (pair.croppedUrl != null && pair.croppedUrl!.isNotEmpty) {
            patch['thumbnailUrlCropped'] = pair.croppedUrl;
          }
          await docRef.update(patch);
        }
      } catch (e) {
        print('[RecipeService] Error uploading thumbnail after creation: $e');
      }
    }

    // Add recipe ID to user's saved recipes and track save
    await _firestore.collection('users').doc(user.uid).update({
      'savedRecipes': FieldValue.arrayUnion([docRef.id]),
    });

    // Hybrid denormalization: 카드용 미니 데이터를 서브컬렉션에도 복사한다.
    // 옛 배열은 폴백/호환을 위해 유지. (조회 경로는 추후 서브컬렉션 우선으로 전환)
    await _writeSavedRecipeMiniDoc(user.uid, docRef.id, recipeData);

    // Track the save
    await _trackRecipeSave(docRef.id);

    return docRef.id;
  }

  /// 외부(BackgroundParsingService 등)에서 파싱 완료 후 미니 doc 을 갱신할 수 있도록 공개.
  Future<void> updateSavedRecipeMiniDoc(
    String uid,
    String recipeId,
    Map<String, dynamic> recipeData,
  ) => _writeSavedRecipeMiniDoc(uid, recipeId, recipeData);

  /// 네이버 파싱 완료: Firestore 메타 + parseResponse 집계값으로 mini doc 갱신.
  /// 재료/단계 본문은 넣지 않고 ingredientCount/calories/totalMinutes 만 기록한다.
  Future<void> updateNaverSavedRecipeMiniDoc(
    String uid,
    String recipeId,
    Map<String, dynamic> recipeData,
    models.ParseResponse parseResponse,
  ) async {
    try {
      final mini = _buildSavedRecipeMiniMap(recipeId, recipeData);
      var totalMinutes = 0;
      for (final step in parseResponse.recipe.steps) {
        final mins = step.estMinutes;
        if (mins != null) totalMinutes += mins;
      }
      applyNaverParseCountsToMini(
        mini,
        ingredientCount: parseResponse.recipe.ingredients.length,
        calories:
            parseResponse.nutrition.llmEstimate?.caloriesPerServing ?? 0,
        totalMinutes: totalMinutes,
      );
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .set(mini);
    } catch (e) {
      print('[RecipeService] naver savedRecipes mini-doc sync error: $e');
    }
  }

  /// Bump savedAt on an existing recipe's mini-doc so it sorts to the top.
  /// Also moves it to position 0 in the local cache so the next instant
  /// re-emit already shows it first (no waiting for Firestore round-trip).
  Future<void> bumpSavedRecipeTimestamp(String recipeId) async {
    _moveRecipeToFrontOfCache(recipeId);
    final user = _auth.currentUser;
    if (user == null || recipeId.isEmpty) return;
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .set({'savedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[RecipeService] bumpSavedRecipeTimestamp error: $e');
    }
  }

  static void _moveRecipeToFrontOfCache(String recipeId) {
    if (recipeId.isEmpty) return;
    final idx = _lastEmittedRecipes.indexWhere(
      (r) => (r['id'] as String?) == recipeId,
    );
    if (idx > 0) {
      final recipe = _lastEmittedRecipes.removeAt(idx);
      _lastEmittedRecipes.insert(0, recipe);
    }
  }

  /// 비동기 파싱 완료 시(백엔드 FCM / Firestore 리스너) 홈 레시피북 카드를 갱신한다.
  Future<void> handleParseCompleted(String recipeId) async {
    final user = _auth.currentUser;
    if (user == null || recipeId.isEmpty) return;

    String? sourceUrl;
    try {
      final existingOpt = _optimisticRecipes[recipeId];
      sourceUrl = existingOpt?['sourceUrl'] as String?;
      if (sourceUrl == null || sourceUrl.isEmpty) {
        final doc = await _firestore.collection('recipes').doc(recipeId).get();
        sourceUrl = doc.data()?['sourceUrl'] as String?;
      }
    } catch (_) {}

    removeOptimisticParsingRecipe(recipeId, sourceUrl: sourceUrl);
    parsingProgressCache.remove(recipeId);

    try {
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      final data = doc.data();
      if (!doc.exists || data == null) {
        notifyRecipesChanged();
        return;
      }

      // 숨김 dedup 사본이면 canonical 레시피를 북마크·목록에 노출한다.
      if (data['isHidden'] == true) {
        final reason = (data['hiddenReason'] as String?) ?? '';
        const prefix = 'duplicate_of:';
        if (reason.startsWith(prefix)) {
          final canonicalId = reason.substring(prefix.length).trim();
          // 임시 사본 id 가 레시피북에 남으면 0재료·15분·0kcal 가짜 카드가 된다.
          unawaited(cleanupDedupTempSavedRecipe(user.uid, recipeId));
          if (canonicalId.isNotEmpty && canonicalId != recipeId) {
            await UserService().addSavedRecipe(user.uid, canonicalId);
            UserService.invalidateSavedRecipesCache();
          }
          notifyRecipesChanged();
          return;
        }
        // 네이버 블로그 등: isHidden 이지만 duplicate 사본이 아니면
        // 본인 레시피북에 completed 카드로 노출한다.
        // main doc 에 재료/칼로리 없음 → updateSavedRecipeMiniDoc(0) 으로 덮지 않는다.
        notifyRecipesChanged();
        return;
      }

      await UserService().addSavedRecipe(user.uid, recipeId);
      UserService.invalidateSavedRecipesCache();
    } catch (e) {
      print('[RecipeService] handleParseCompleted bookmark sync failed: $e');
      try {
        final doc = await _firestore.collection('recipes').doc(recipeId).get();
        final data = doc.data();
        if (doc.exists && data != null) {
          await updateSavedRecipeMiniDoc(user.uid, recipeId, data);
        }
      } catch (_) {}
    }

    notifyRecipesChanged();
  }

  static bool _isNaverBlogRecipeData(Map<String, dynamic> r) =>
      isNaverBlogRecipeData(r);

  static bool _isNaverBlogMiniDoc(Map<String, dynamic> m) =>
      isNaverBlogMiniDoc(m);

  /// Firestore main 기준 mini sync 시 네이버 집계값(0)이 기존 parseResponse 기록을 덮지 않게.
  Future<void> _preserveNaverMiniCardCounts(
    String uid,
    String recipeId,
    Map<String, dynamic> mini,
  ) async {
    try {
      final snap = await _firestore
          .collection('users')
          .doc(uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .get();
      if (!snap.exists) return;
      preserveNaverMiniCardCountsFromExisting(mini, snap.data());
    } catch (_) {
      // ignore — best effort
    }
  }

  /// 카드용 미니 데이터를 `users/{uid}/savedRecipes/{rid}` 에 기록한다.
  /// N+1 read 를 단일 query 로 줄이기 위한 denormalization. 본문(steps/ingredients)은
  /// 포함하지 않으며, 디테일 진입 시 `recipes/{rid}` 본체에서 fetch 한다.
  ///
  /// 미니 필드(카드 표시용): title/thumbnail/status/calories/ingredientCount/
  /// totalMinutes/sourceUploader/sourceChannel/saveCount/sourceViewCount.
  Future<void> _writeSavedRecipeMiniDoc(
    String uid,
    String recipeId,
    Map<String, dynamic> recipeData,
  ) async {
    try {
      final mini = _buildSavedRecipeMiniMap(recipeId, recipeData);
      if (_isNaverBlogRecipeData(recipeData) || _isNaverBlogMiniDoc(mini)) {
        await _preserveNaverMiniCardCounts(uid, recipeId, mini);
      }
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .set(mini);
    } catch (e) {
      // 동기화 실패는 옛 배열에 이미 들어갔으므로 무시 가능 (다음 진입 시 백필됨).
      print('[RecipeService] savedRecipes mini-doc sync error: $e');
    }
  }

  static String? _nonEmptyMiniString(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// 상세·곁들임·유사 레일이 읽는 source.categories / source.tags /
  /// source.tagline / source.occasionTags 에 본체 값을 넣는다.
  /// 본체가 비면 source 원본을 유지한다.
  /// 유저 레시피북 칸(users.recipebook)은 넣지 않는다.
  static void _hydrateSourceTaxonomyFromRecipeDoc(
    Map<String, dynamic> source,
    Map<String, dynamic> recipeDoc,
  ) {
    final categories = _categoriesFromRecipeData(recipeDoc);
    if (categories != null) {
      source['categories'] = categories;
    }
    final tags = recipeDoc['tags'];
    if (tags is List && tags.isNotEmpty) {
      source['tags'] = List<dynamic>.from(tags);
    }
    hydrateRecipeDisplayMeta(source, recipeDoc);
  }

  static Map<String, dynamic>? _categoriesFromRecipeData(
    Map<String, dynamic> r,
  ) {
    final raw = r['categories'];
    if (raw is! Map || raw.isEmpty) return null;
    return Map<String, dynamic>.from(raw);
  }

  static bool _miniCategoriesMissing(Map<String, dynamic> m) {
    final raw = m['categories'];
    return raw is! Map || raw.isEmpty;
  }

  /// 옛 미니 doc(creator/tags/categories 없음) → recipes/{rid}에서 보강 필요.
  static bool _miniDocNeedsBackfill(Map<String, dynamic> m) {
    final missingCreator = _nonEmptyMiniString(m['sourceUploader']) == null &&
        _nonEmptyMiniString(m['sourceChannel']) == null;
    final missingTags = m['tags'] == null || (m['tags'] is List && (m['tags'] as List).isEmpty);
    return missingCreator || missingTags || _miniCategoriesMissing(m);
  }

  Map<String, dynamic> _miniSocialWriteFields(Map<String, dynamic> recipe) {
    return <String, dynamic>{
      ...RecipeSocialCounts.miniSocialFields(recipe),
      'socialSyncedAt': FieldValue.serverTimestamp(),
    };
  }


  /// `recipes/{rid}` 본체에서 카드용 크리에이터 필드 추출 (source + 파싱 중 top-level).
  static ({String? uploader, String? channel}) _miniSourceCreatorFields(
    Map<String, dynamic> r,
  ) {
    final source = r['source'];
    final sourceMap = source is Map ? Map<String, dynamic>.from(source) : null;
    return (
      uploader:
          _nonEmptyMiniString(sourceMap?['uploader']) ??
          _nonEmptyMiniString(r['uploader']),
      channel:
          _nonEmptyMiniString(sourceMap?['channel']) ??
          _nonEmptyMiniString(r['channel']),
    );
  }

  /// 옛 미니 doc 필드를 recipes/{rid}에서 비동기 보강 (목록 로드 경로에서 동기 full fetch 금지).
  Future<void> _backfillSavedRecipeMiniDocFromMain({
    required String userId,
    required String rid,
  }) async {
    try {
      final main = await _firestore.collection('recipes').doc(rid).get();
      final data = main.data();
      if (!main.exists || data == null) return;
      if (_isDuplicateOfHiddenData(data)) {
        await cleanupDedupTempSavedRecipe(userId, rid);
        return;
      }
      await updateSavedRecipeMiniDoc(userId, rid, data);
    } catch (_) {
      // 다음 진입/폴링에서 재시도
    }
  }

  void _scheduleMiniSocialRefresh({
    required String userId,
    required List<Map<String, dynamic>> recipes,
  }) {
    final staleSocialIds = recipes
        .where(RecipeSocialCounts.miniNeedsSocialRefresh)
        .map((r) => r['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (staleSocialIds.isEmpty) return;
    unawaited(
      _refreshStaleMiniSocialFields(
        userId: userId,
        candidateIds: staleSocialIds,
      ),
    );
  }

  /// 레시피북 로드 후 스탤 미니 소셜 숫자를 본체에서 배치로 다시 베낀다.
  /// 화면 앞쪽(목록 순서)부터, 세션당 [RecipeSocialCounts.socialRefreshSessionCap]장.
  Future<void> _refreshStaleMiniSocialFields({
    required String userId,
    required List<String> candidateIds,
  }) async {
    if (candidateIds.isEmpty) return;
    final remaining = RecipeSocialCounts.socialRefreshSessionCap -
        _miniSocialRefreshSessionUsed;
    if (remaining <= 0) return;

    final ids = <String>[];
    for (final id in candidateIds) {
      if (ids.length >= remaining) break;
      if (id.isEmpty || _miniSocialRefreshAttemptedIds.contains(id)) continue;
      ids.add(id);
    }
    if (ids.isEmpty) return;

    _miniSocialRefreshSessionUsed += ids.length;
    _miniSocialRefreshAttemptedIds.addAll(ids);

    var listChanged = false;
    const chunkSize = 30;
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      final slice = ids.sublist(
        offset,
        math.min(offset + chunkSize, ids.length),
      );
      List<DocumentSnapshot<Map<String, dynamic>>> mains;
      try {
        mains = await Future.wait(
          slice.map((id) => _firestore.collection('recipes').doc(id).get()),
        );
      } catch (_) {
        continue;
      }

      for (var i = 0; i < slice.length; i++) {
        final rid = slice[i];
        final data = mains[i].data();
        if (!mains[i].exists || data == null) continue;

        final incoming = RecipeSocialCounts.miniSocialFields(data);
        final idx = _lastEmittedRecipes.indexWhere((r) => r['id'] == rid);
        final current = idx >= 0 ? _lastEmittedRecipes[idx] : null;
        final differ = current == null ||
            RecipeSocialCounts.socialFieldsDiffer(current, incoming);

        try {
          await _firestore
              .collection('users')
              .doc(userId)
              .collection('savedRecipes')
              .doc(rid)
              .set(
                differ
                    ? _miniSocialWriteFields(data)
                    : <String, dynamic>{
                        'socialSyncedAt': FieldValue.serverTimestamp(),
                      },
                SetOptions(merge: true),
              );
        } catch (_) {
          continue;
        }

        if (differ && idx >= 0) {
          _lastEmittedRecipes[idx] = <String, dynamic>{
            ..._lastEmittedRecipes[idx],
            ...incoming,
          };
          listChanged = true;
        }
      }
    }

    if (!listChanged) return;
    final controller = _savedRecipesReloadController;
    if (controller == null || controller.isClosed) return;
    _emitSavedRecipes(
      controller,
      SavedRecipesResult(
        _mergeOptimistic(List<Map<String, dynamic>>.from(_lastEmittedRecipes)),
        _lastEmittedTotal,
        recipebookCategories: _lastRecipebookCategories,
        recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
      ),
    );
  }

  /// `recipes/{rid}` 본체 doc 데이터에서 카드용 미니 필드를 추출한다.
  /// `_writeSavedRecipeMiniDoc` 와 `_loadAndEmitRecipes` 폴백 경로 백필에서 공유.
  Map<String, dynamic> _buildSavedRecipeMiniMap(
    String recipeId,
    Map<String, dynamic> r,
  ) {
    final source = r['source'];
    final sourcePlatform = source is Map ? source['platform'] as String? : null;
    final creator = _miniSourceCreatorFields(r);
    final recipeBody = r['recipe'] is Map ? r['recipe'] as Map : null;
    final ingredients = recipeBody?['ingredients'] as List? ?? const [];
    final steps = recipeBody?['steps'] as List? ?? const [];
    int totalMinutes = 0;
    for (final s in steps) {
      if (s is Map && s['est_minutes'] is num) {
        totalMinutes += (s['est_minutes'] as num).toInt();
      }
    }
    final calories = (r['calories'] as num?) ?? 0;
    final categories = _categoriesFromRecipeData(r);
    final title = _nonEmptyMiniString(r['title']) ??
        _nonEmptyMiniString(recipeBody?['title']) ??
        _nonEmptyMiniString(recipeBody?['name']);
    return <String, dynamic>{
      'recipeId': recipeId,
      'title': title,
      if (r['thumbnailUrl'] != null) 'thumbnailUrl': r['thumbnailUrl'],
      if (r['thumbnailUrlLarge'] != null)
        'thumbnailUrlLarge': r['thumbnailUrlLarge'],
      if (r['thumbnailUrlCropped'] != null)
        'thumbnailUrlCropped': r['thumbnailUrlCropped'],
      if (r['createdAt'] != null) 'createdAt': r['createdAt'],
      'savedAt': FieldValue.serverTimestamp(),
      if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
      if (r['sourceUrl'] != null) 'sourceUrl': r['sourceUrl'],
      if (creator.uploader != null) 'sourceUploader': creator.uploader,
      if (creator.channel != null) 'sourceChannel': creator.channel,
      if (r['status'] != null) 'status': r['status'],
      'isHidden': r['isHidden'] == true,
      // 목록 필터가 mini 만으로도 duplicate_of 를 걸러내도록 복사.
      if (r['hiddenReason'] != null) 'hiddenReason': r['hiddenReason'],
      'calories': calories,
      'ingredientCount': ingredients.length,
      'totalMinutes': totalMinutes,
      if (r['tags'] is List && (r['tags'] as List).isNotEmpty)
        'tags': r['tags'],
      if (categories != null) 'categories': categories,
      ..._miniSocialWriteFields(r),
    };
  }

  /// Check if thumbnail already exists in Firebase Storage for a recipe
  Future<String?> _checkThumbnailInStorage(String? recipeId) async {
    if (recipeId == null || recipeId.isEmpty) {
      return null;
    }

    try {
      final storagePath = 'recipe_thumbnails/$recipeId.jpg';
      final storageRef = _storage.ref().child(storagePath);
      final downloadUrl = await storageRef.getDownloadURL();
      print(
        '[RecipeService] Thumbnail already exists in storage for recipe $recipeId',
      );
      return downloadUrl;
    } catch (e) {
      // File doesn't exist in storage
      return null;
    }
  }

  Future<String?> _tryGetSmallRecipeThumbUrl(String baseName) async {
    try {
      return await _storage
          .ref('recipe_thumbnails/thumbnails/${baseName}_200x200.jpg')
          .getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  /// Base name for recipe_thumbnails/{base}.jpg and thumbnails/{base}_200x200.jpg (Resize extension).
  String _recipeThumbnailBaseName(String thumbnailUrl, String? recipeId) {
    if (recipeId != null && recipeId.isNotEmpty) return recipeId;
    return '${thumbnailUrl.hashCode.abs()}';
  }

  /// After large file exists, wait for Resize Images extension then return card + large URLs.
  Future<({String cardUrl, String largeUrl, String? croppedUrl})>
  _finalizeRecipeThumbnailPair(
    String baseName,
    String largeDownloadUrl,
    String? croppedUrl,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    var smallUrl = await _tryGetSmallRecipeThumbUrl(baseName);
    if (smallUrl == null) {
      await Future<void>.delayed(const Duration(seconds: 2));
      smallUrl = await _tryGetSmallRecipeThumbUrl(baseName);
    }
    if (smallUrl != null) {
      print('[RecipeService] Recipe card thumbnail (200x200): $smallUrl');
    } else {
      print(
        '[RecipeService] Small recipe thumbnail missing; using large for cards (check extension /recipe_thumbnails)',
      );
    }
    return (
      cardUrl: smallUrl ?? largeDownloadUrl,
      largeUrl: largeDownloadUrl,
      croppedUrl: croppedUrl,
    );
  }

  bool _isYouTubeThumbnailCandidate({
    required String thumbnailUrl,
    String? sourceUrl,
    String? platform,
  }) {
    final p = (platform ?? '').toLowerCase().trim();
    if (p == 'youtube' || p.contains('youtube')) return true;
    final u = thumbnailUrl.toLowerCase();
    if (u.contains('ytimg.com') || u.contains('youtube.com/vi/')) return true;
    final s = (sourceUrl ?? '').trim();
    if (s.isNotEmpty && isYouTubeUrl(s)) return true;
    return false;
  }

  bool _isInstagramThumbnailCandidate({
    required String thumbnailUrl,
    String? sourceUrl,
    String? platform,
  }) {
    final p = (platform ?? '').toLowerCase().trim();
    if (p == 'instagram' || p == 'instagramweb' || p.contains('instagram')) {
      return true;
    }
    final u = thumbnailUrl.toLowerCase();
    if (u.contains('instagram.com') || u.contains('cdninstagram.com')) {
      return true;
    }
    final s = (sourceUrl ?? '').toLowerCase().trim();
    return s.contains('instagram.com') || s.contains('instagr.am');
  }

  ({int x, int y, int width, int height})? _fixedScaleCropBounds(
    img.Image image, {
    double scaleX = 1.52,
    double scaleY = 1.28,
  }) {
    final w = image.width;
    final h = image.height;
    if (w < 2 || h < 2) return null;
    final sx = scaleX <= 1.0 ? 1.0 : scaleX;
    final sy = scaleY <= 1.0 ? 1.0 : scaleY;
    if (sx <= 1.0 && sy <= 1.0) return null;

    final cropW = (w / sx).round().clamp(1, w);
    final cropH = (h / sy).round().clamp(1, h);
    if (cropW >= w && cropH >= h) return null;

    final cropX = ((w - cropW) / 2).round().clamp(0, w - cropW);
    final cropY = ((h - cropH) / 2).round().clamp(0, h - cropH);
    return (x: cropX, y: cropY, width: cropW, height: cropH);
  }

  ({int x, int y, int width, int height})? _centerAspectCropBounds(
    img.Image image, {
    double aspectRatio = 4 / 5,
  }) {
    final w = image.width;
    final h = image.height;
    if (w < 2 || h < 2 || aspectRatio <= 0) return null;

    final currentRatio = w / h;
    int cropW = w;
    int cropH = h;
    if (currentRatio < aspectRatio) {
      cropH = (w / aspectRatio).round().clamp(1, h).toInt();
    } else if (currentRatio > aspectRatio) {
      cropW = (h * aspectRatio).round().clamp(1, w).toInt();
    }
    if (cropW == w && cropH == h) return null;

    final cropX = ((w - cropW) / 2).round().clamp(0, w - cropW);
    final cropY = ((h - cropH) / 2).round().clamp(0, h - cropH);
    return (x: cropX, y: cropY, width: cropW, height: cropH);
  }

  Future<String?> _uploadYouTubeCroppedVariant({
    required Uint8List originalBytes,
    required String baseName,
    required String sourceThumbnailUrl,
  }) async {
    try {
      final croppedPath = 'recipe_thumbnails/cropped/${baseName}_cropped.jpg';
      final croppedRef = _storage.ref().child(croppedPath);
      try {
        return await croppedRef.getDownloadURL();
      } catch (_) {
        // continue and generate
      }

      final decoded = img.decodeImage(originalBytes);
      if (decoded == null) return null;
      final bounds = _fixedScaleCropBounds(decoded, scaleX: 3.20, scaleY: 1.28);
      if (bounds == null) return null;

      final cropped = img.copyCrop(
        decoded,
        x: bounds.x,
        y: bounds.y,
        width: bounds.width,
        height: bounds.height,
      );
      final encoded = img.encodeJpg(cropped, quality: 90);
      if (encoded.isEmpty) return null;

      final snapshot = await croppedRef.putData(
        Uint8List.fromList(encoded),
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {
            'sourceUrl': sourceThumbnailUrl,
            'variant': 'cropped',
          },
        ),
      );
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      print('[RecipeService] Failed to upload cropped YouTube thumbnail: $e');
      return null;
    }
  }

  Future<String?> _uploadInstagramCroppedVariant({
    required Uint8List originalBytes,
    required String baseName,
    required String sourceThumbnailUrl,
  }) async {
    try {
      final croppedPath = 'recipe_thumbnails/cropped/${baseName}_cropped.jpg';
      final croppedRef = _storage.ref().child(croppedPath);
      try {
        return await croppedRef.getDownloadURL();
      } catch (_) {
        // continue and generate
      }

      final decoded = img.decodeImage(originalBytes);
      if (decoded == null) return null;
      final bounds = _centerAspectCropBounds(decoded, aspectRatio: 4 / 5);
      final cropped = bounds == null
          ? decoded
          : img.copyCrop(
              decoded,
              x: bounds.x,
              y: bounds.y,
              width: bounds.width,
              height: bounds.height,
            );
      final encoded = img.encodeJpg(cropped, quality: 90);
      if (encoded.isEmpty) return null;

      final snapshot = await croppedRef.putData(
        Uint8List.fromList(encoded),
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {
            'sourceUrl': sourceThumbnailUrl,
            'variant': 'instagram_4x5_cropped',
          },
        ),
      );
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      print('[RecipeService] Failed to upload cropped Instagram thumbnail: $e');
      return null;
    }
  }

  /// Download thumbnail from URL, upload to recipe_thumbnails/{id}.jpg, resolve 200x200 from extension.
  Future<({String cardUrl, String largeUrl, String? croppedUrl})?>
  _uploadThumbnailToStorage({
    required String thumbnailUrl,
    String? recipeId,
    String? sourceUrl,
    String? platform,
  }) async {
    final baseName = _recipeThumbnailBaseName(thumbnailUrl, recipeId);
    final isYouTube = _isYouTubeThumbnailCandidate(
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
      platform: platform,
    );
    final isInstagram = _isInstagramThumbnailCandidate(
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
      platform: platform,
    );
    try {
      var downloadUrl = thumbnailUrl;
      var response = await http.get(
        Uri.parse(downloadUrl),
        headers: isTikTokCdnThumbnailUrl(downloadUrl)
            ? const {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 13; SM-N981N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                'Referer': 'https://www.tiktok.com/',
                'Accept':
                    'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
              }
            : const <String, String>{},
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        print(
          '[RecipeService] Failed to download thumbnail: ${response.statusCode}',
        );
        final src = (sourceUrl ?? '').trim();
        if (isTikTokUrl(src)) {
          final oembed = await fetchTikTokOEmbed(src);
          final fresh = oembed?.thumbnailUrl?.trim() ?? '';
          if (fresh.isNotEmpty) {
            downloadUrl = fresh;
            response = await http.get(Uri.parse(downloadUrl));
          }
        }
      }
      if (response.statusCode != 200) {
        print(
          '[RecipeService] Failed to download thumbnail: ${response.statusCode}',
        );
        return null;
      }

      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        print('[RecipeService] Thumbnail download empty body');
        return null;
      }

      final fileName = '$baseName.jpg';
      final storagePath = 'recipe_thumbnails/$fileName';
      final storageRef = _storage.ref().child(storagePath);

      try {
        final existingUrl = await storageRef.getDownloadURL();
        print('[RecipeService] Thumbnail already exists in storage');
        String? croppedUrl;
        if (isYouTube) {
          croppedUrl = await _uploadYouTubeCroppedVariant(
            originalBytes: bytes,
            baseName: baseName,
            sourceThumbnailUrl: thumbnailUrl,
          );
        } else if (isInstagram) {
          croppedUrl = await _uploadInstagramCroppedVariant(
            originalBytes: bytes,
            baseName: baseName,
            sourceThumbnailUrl: thumbnailUrl,
          );
        }
        return _finalizeRecipeThumbnailPair(baseName, existingUrl, croppedUrl);
      } catch (e) {
        // upload
      }

      // putData: Web/모바일 공통 (putFile + 임시 File은 Web에서 _Namespace 오류)
      final uploadTask = storageRef.putData(
        bytes,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {'sourceUrl': thumbnailUrl},
        ),
      );

      final snapshot = await uploadTask;
      downloadUrl = await snapshot.ref.getDownloadURL();

      String? croppedUrl;
      if (isYouTube) {
        croppedUrl = await _uploadYouTubeCroppedVariant(
          originalBytes: bytes,
          baseName: baseName,
          sourceThumbnailUrl: thumbnailUrl,
        );
      } else if (isInstagram) {
        croppedUrl = await _uploadInstagramCroppedVariant(
          originalBytes: bytes,
          baseName: baseName,
          sourceThumbnailUrl: thumbnailUrl,
        );
      }

      print('[RecipeService] Thumbnail uploaded (large): $downloadUrl');
      return _finalizeRecipeThumbnailPair(baseName, downloadUrl, croppedUrl);
    } catch (e) {
      print('[RecipeService] Error uploading thumbnail to storage: $e');
      return null;
    }
  }

  /// 백그라운드 파싱 완료 후 등: 외부 썸네일을 Storage에 올리고 `thumbnailUrl` / `thumbnailUrlLarge` 반영.
  Future<void> uploadAndApplyRecipeThumbnails(
    String recipeId,
    String externalThumbnailUrl, {
    String? sourceUrl,
    String? platform,
  }) async {
    if (recipeId.isEmpty || externalThumbnailUrl.trim().isEmpty) return;
    try {
      final pair = await _uploadThumbnailToStorage(
        thumbnailUrl: externalThumbnailUrl.trim(),
        recipeId: recipeId,
        sourceUrl: sourceUrl,
        platform: platform,
      );
      if (pair != null) {
        final patch = <String, dynamic>{
          'thumbnailUrlLarge': pair.largeUrl,
          'thumbnailUrl': pair.cardUrl,
        };
        if (pair.croppedUrl != null && pair.croppedUrl!.isNotEmpty) {
          patch['thumbnailUrlCropped'] = pair.croppedUrl;
        }
        await _firestore.collection('recipes').doc(recipeId).update(patch);
      }
    } catch (e) {
      print('[RecipeService] uploadAndApplyRecipeThumbnails: $e');
    }
  }

  // Track when a user saves a recipe
  Future<void> _trackRecipeSave(String recipeId) async {
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    final monthAgo = now.subtract(const Duration(days: 30));

    final recipeRef = _firestore.collection('recipes').doc(recipeId);
    final recipeDoc = await recipeRef.get();

    if (!recipeDoc.exists) return;

    final data = recipeDoc.data() ?? {};
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate() ?? now;

    final update = <String, dynamic>{
      'saveCount': FieldValue.increment(1),
      'lastSavedAt': FieldValue.serverTimestamp(),
    };
    if (createdAt.isAfter(weekAgo)) {
      update['weeklySaves'] = FieldValue.increment(1);
    }
    if (createdAt.isAfter(monthAgo)) {
      update['monthlySaves'] = FieldValue.increment(1);
    }
    await recipeRef.update(update);
  }

  // 검색 화면 전용: 최신 completed 공개 레시피만 상한만큼 읽는다.
  // 과거에는 전체 recipes 를 가져와 검색 1회가 컬렉션 크기만큼 read 가 나갔다.
  // 실제 홈 검색은 RecipeSearchScreen 의 페이지네이션을 쓴다.
  Future<List<Map<String, dynamic>>> fetchAllRecipesForSearch({
    int limit = kRecipeSearchCatalogReadLimit,
  }) async {
    final safeLimit = limit < 1 ? kRecipeSearchCatalogReadLimit : math.min(limit, kRecipeSearchCatalogReadLimit);
    final snapshot = await _firestore
        .collection('recipes')
        .where('isHidden', isEqualTo: false)
        .where('status', isEqualTo: 'completed')
        .orderBy('createdAt', descending: true)
        .limit(safeLimit)
        .get();
    return snapshot.docs.map((doc) {
      final data = doc.data();
      final convertedData = Map<String, dynamic>.from(data);
      return {'id': doc.id, ...convertedData};
    }).toList();
  }

  // Get all-time popular recipes (top 10 by save count)
  /// 올타임 인기 레시피: isHidden + status + saveCount DESC 복합 인덱스 사용.
  /// 백필 후에는 모든 doc 에 saveCount 필드가 존재해야 인덱스에 포함된다.
  /// (백필 Cloud Function: `backfillSaveCountFields`)
  Future<List<Map<String, dynamic>>> getAllTimePopularRecipes({
    int limit = 10,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .orderBy('saveCount', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs.map((doc) {
        return {'id': doc.id, ...doc.data()};
      }).toList();
    } catch (e) {
      debugPrint('getAllTimePopularRecipes: $e');
      return [];
    }
  }

  /// 위클리 탑 레시피: isHidden + status + weeklySaves DESC 복합 인덱스 사용.
  Future<List<Map<String, dynamic>>> getWeeklyPopularRecipes({
    int limit = 10,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .orderBy('weeklySaves', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs.map((doc) {
        return {'id': doc.id, ...doc.data()};
      }).toList();
    } catch (e) {
      debugPrint('getWeeklyPopularRecipes: $e');
      return [];
    }
  }

  /// 월간 인기 레시피: isHidden + status + monthlySaves DESC 복합 인덱스 사용.
  /// 백필 후에는 모든 doc 에 monthlySaves 필드가 존재해야 인덱스에 포함된다.
  Future<List<Map<String, dynamic>>> getMonthlyPopularRecipes({
    int limit = 10,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .orderBy('monthlySaves', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs.map((doc) {
        return {'id': doc.id, ...doc.data()};
      }).toList();
    } catch (e) {
      debugPrint('getMonthlyPopularRecipes: $e');
      return [];
    }
  }

  // Get most recently added recipes (top 10 by creation date)
  Future<List<Map<String, dynamic>>> getRecentlyAddedRecipes({
    int limit = 10,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('recipes')
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        final convertedData = Map<String, dynamic>.from(data);
        return {'id': doc.id, ...convertedData};
      }).toList();
    } catch (e) {
      print('Error getting recently added recipes: $e');
      return [];
    }
  }

  // Get all recipes for the current user (recipes they created)
  Stream<SavedRecipesResult> getUserRecipes() {
    final user = _auth.currentUser;

    // If user is not logged in, return local recipes as a stream
    // Emit immediately on listen + on notifyRecipesChanged + every 500ms so parsing card appears right away
    if (user == null) {
      final controller = StreamController<SavedRecipesResult>.broadcast();
      void emit() async {
        if (controller.isClosed) return;
        final list = await _localStorage.getLocalRecipes();
        final merged = _mergeOptimistic(list);
        controller.add(
          SavedRecipesResult(
            merged,
            merged.length,
            recipebookCategories: _lastRecipebookCategories,
            recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
          ),
        );
      }

      emit();
      Timer? timer;
      StreamSubscription<void>? changeSub;
      timer = Timer.periodic(const Duration(milliseconds: 500), (_) => emit());
      changeSub = _recipesChangedController.stream.listen((_) => emit());
      controller.onCancel = () {
        timer?.cancel();
        changeSub?.cancel();
      };
      return controller.stream;
    }

    // User is logged in, return Firebase recipes.
    // 본인이 작성한 레시피이므로 limit 없이 전체 구독한다.
    return _firestore
        .collection('recipes')
        .where('userId', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          final list = snapshot.docs.map((doc) {
            final data = doc.data();
            final convertedData = Map<String, dynamic>.from(data);
            return {'id': doc.id, ...convertedData};
          }).toList();
          return SavedRecipesResult(
            list,
            list.length,
            recipebookCategories: _lastRecipebookCategories,
            recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
          );
        });
  }

  // Get saved recipes for the current user (recipes they saved, not necessarily created).
  // Returns a shared cached stream per user so Home and Temp (and any other listener) reuse
  // the same subscription and avoid duplicate Firestore fetches — loading stays fast.
  /// 앱 세션 동안 마지막으로 로드된 저장 레시피 목록을 동기로 반환한다.
  /// 스트림(broadcast) 재구독 시 첫 emit 까지 shimmer 가 뜨는 것을 막기 위해
  /// 직전 목록을 즉시 보여주는 워밍 스냅샷 용도. 없으면 null.
  SavedRecipesResult? get warmSavedRecipesSnapshot {
    if (_auth.currentUser == null) return null;
    final last = _lastSavedRecipesResult;
    if (last != null) return last;
    if (_lastEmittedRecipes.isEmpty && _optimisticRecipes.isEmpty) return null;
    final merged = _mergeOptimistic(
      List<Map<String, dynamic>>.from(_lastEmittedRecipes),
    );
    if (merged.isEmpty) return null;
    return SavedRecipesResult(
      merged,
      _lastEmittedTotal,
      recipebookCategories: _lastRecipebookCategories,
      recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
    );
  }

  Stream<SavedRecipesResult> getSavedRecipes() {
    final user = _auth.currentUser;

    if (user == null) {
      _cachedSavedRecipesStream = null;
      _cachedSavedRecipesUserId = null;
      return Stream.value(
        const SavedRecipesResult(
          [],
          0,
          recipebookCategories: [],
          recipebookRecipeCategoryMap: {},
        ),
      );
    }

    if (_cachedSavedRecipesStream != null &&
        _cachedSavedRecipesUserId == user.uid) {
      return _cachedSavedRecipesStream!;
    }

    if (_cachedSavedRecipesUserId != null &&
        _cachedSavedRecipesUserId != user.uid) {
      _savedRecipesLoadGeneration++;
      _miniSocialRefreshSessionUsed = 0;
      _miniSocialRefreshAttemptedIds.clear();
      _lastSavedRecipesResult = null;
      _lastEmittedRecipes = [];
      _lastEmittedTotal = 0;
      _optimisticRecipes.clear();
    }

    final StreamController<SavedRecipesResult> mainController =
        StreamController<SavedRecipesResult>.broadcast();

    bool lastHasParsing = false;
    bool pollInFlight = false;
    Timer? pollTimer;
    // 파싱 폴링 시작 시각. 비정상적으로 오래 'parsing' 상태가 지속되면(멈춤/실패)
    // 무한 폴링으로 read 가 계속 발생하는 것을 막기 위한 상한 기준.
    DateTime? fastPollStartedAt;
    // 폴링 1회당 user 문서 + 저장 레시피 전체 mini doc 을 재조회하므로 주기가
    // 짧을수록 read 비용이 선형 증가한다. 진행 표시는 2초 간격이면 충분하다.
    const Duration pollInterval = Duration(milliseconds: 2000);
    // 정상 파싱은 이보다 훨씬 빨리 끝난다. 초과 시 폴링을 멈추고 이후에는
    // user-doc 리스너 / 수동 새로고침 / 재진입에 의존한다.
    const Duration maxFastPollDuration = Duration(minutes: 6);

    void startPoll(bool fast) {
      pollTimer?.cancel();
      if (!fast) {
        // No recipes are parsing -- stop polling entirely.
        // The user-doc listener will trigger a reload when savedRecipes changes.
        pollTimer = null;
        fastPollStartedAt = null;
        return;
      }
      fastPollStartedAt ??= DateTime.now();
      pollTimer = Timer.periodic(
        pollInterval,
        (timer) async {
          // 멈춘 파싱으로 인한 무한 read 방지: 상한 초과 시 폴링 중단.
          final startedAt = fastPollStartedAt;
          if (startedAt != null &&
              DateTime.now().difference(startedAt) > maxFastPollDuration) {
            timer.cancel();
            pollTimer = null;
            fastPollStartedAt = null;
            lastHasParsing = false;
            return;
          }
          if (pollInFlight || mainController.isClosed) return;
          pollInFlight = true;
          try {
            // 폴링 tick 에서는 전체 재조회 대신 parsing 중인 카드만 확인한다.
            final hasParsing = await _pollParsingRecipes(
              user.uid,
              mainController,
            );
            if (mainController.isClosed) return;
            if (lastHasParsing != hasParsing) {
              lastHasParsing = hasParsing;
              startPoll(hasParsing);
            }
          } finally {
            pollInFlight = false;
          }
        },
      );
    }

    // Quick first emit from disk cache (best-effort).
    () async {
      try {
        final ls = LocalStorageService();
        _lastRecipebookCategories = List<Map<String, dynamic>>.from(
          await ls.getRecipebookCategories(user.uid, seedIfEmpty: false),
        );
        final mapRaw = await ls.getRecipebookRecipeCategoryMap(user.uid);
        _lastRecipebookRecipeCategoryMap = mapRaw.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        );

        final cachedPayload = await _localStorage.loadSavedRecipesCache(
          user.uid,
        );
        if (cachedPayload == null) return;

        final cachedAtIso = cachedPayload['cachedAt'] as String?;
        final cachedAt = cachedAtIso != null
            ? DateTime.tryParse(cachedAtIso)
            : null;
        if (cachedAt == null) return;
        if (DateTime.now().difference(cachedAt) > _savedRecipesCacheTtl) return;

        final totalCount = (cachedPayload['totalCount'] as num?)?.toInt() ?? 0;
        final recipesRaw = cachedPayload['recipes'] as List? ?? [];
        final recipes = recipesRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        lastHasParsing = recipes.any(
          (r) => (r['status'] as String?) == 'parsing',
        );
        _lastEmittedRecipes = List.from(recipes);
        _lastEmittedTotal = totalCount;
        if (!mainController.isClosed) {
          _emitSavedRecipes(
            mainController,
            SavedRecipesResult(
              recipes,
              totalCount,
              recipebookCategories: _lastRecipebookCategories,
              recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
            ),
          );
        }
      } catch (_) {
        // ignore cache read errors
      }
    }();

    // Only start polling if cache indicates active parsing; otherwise rely
    // on the Firestore user-doc listener to trigger refreshes on demand.
    if (lastHasParsing) {
      startPoll(true);
    }

    // React only when savedRecipes / savedAt change — not lastAccessedAt or attendance
    // (written on every app resume via MainNavigator._trackAppAccess).
    String? lastBookmarkSignature;
    var bookmarkListenerPrimed = false;
    String? lastRecipebookSignature;

    final usersStream = _firestore.collection('users').doc(user.uid).snapshots();

    final usersSubscription = usersStream.listen(
      (userDoc) {
        if (mainController.isClosed) return;
        final data = userDoc.data();
        final recipebookSig = UserService.recipebookSnapshotSignature(data);
        if (lastRecipebookSignature != recipebookSig) {
          lastRecipebookSignature = recipebookSig;
          unawaited(
            UserService().applyRecipebookFromUserSnapshot(user.uid, data),
          );
        }
        final signature = _savedRecipesBookmarkSignature(data);
        if (bookmarkListenerPrimed && signature == lastBookmarkSignature) {
          return;
        }
        bookmarkListenerPrimed = true;
        lastBookmarkSignature = signature;
        _scheduleSavedRecipesReloadFromUserDoc(
          userId: user.uid,
          userDoc: userDoc,
          controller: mainController,
          isPollInFlight: () => pollInFlight,
          setPollInFlight: (v) => pollInFlight = v,
          onHasParsing: (hasParsing) {
            if (lastHasParsing != hasParsing) {
              lastHasParsing = hasParsing;
              startPoll(hasParsing);
            }
          },
        );
      },
      onError: (error) {
        // Error listening to users stream - silently continue
      },
    );

    StreamSubscription<void>? changeSub;
    changeSub = _recipesChangedController.stream.listen((_) async {
      try {
        final ls = LocalStorageService();
        _lastRecipebookCategories = List<Map<String, dynamic>>.from(
          await ls.getRecipebookCategories(user.uid, seedIfEmpty: false),
        );
        final mapRaw = await ls.getRecipebookRecipeCategoryMap(user.uid);
        _lastRecipebookRecipeCategoryMap = mapRaw.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        );
      } catch (_) {
        // keep previous map
      }

      // Immediately re-emit last known recipes with fresh optimistic merge
      // so new parsing cards appear without waiting for Firestore.
      if (!mainController.isClosed &&
          (_optimisticRecipes.isNotEmpty || _lastEmittedRecipes.isNotEmpty)) {
        await _emitInstantSavedRecipesWithOptimistic(user.uid, mainController);
      }
      if (mainController.isClosed || pollInFlight) return;
      pollInFlight = true;
      _loadAndEmitRecipes(user.uid, mainController)
          .then((hasParsing) {
            if (mainController.isClosed) return;
            if (lastHasParsing != hasParsing) {
              lastHasParsing = hasParsing;
              startPoll(hasParsing);
            }
          })
          .whenComplete(() {
            pollInFlight = false;
          });
    });

    // First remote fetch.
    if (!mainController.isClosed && !pollInFlight) {
      pollInFlight = true;
      _loadAndEmitRecipes(user.uid, mainController)
          .then((hasParsing) {
            lastHasParsing = hasParsing;
            startPoll(hasParsing);
          })
          .whenComplete(() {
            pollInFlight = false;
          });
    }

    _cachedSavedRecipesStream = mainController.stream;
    _cachedSavedRecipesUserId = user.uid;
    _savedRecipesReloadController = mainController;
    mainController.onListen = () {
      final replay = _lastSavedRecipesResult;
      if (replay == null) return;
      scheduleMicrotask(() {
        if (!mainController.isClosed && mainController.hasListener) {
          mainController.add(replay);
        }
      });
    };
    mainController.onCancel = () {
      usersSubscription.cancel();
      pollTimer?.cancel();
      changeSub?.cancel();
      if (identical(_savedRecipesReloadController, mainController)) {
        _cachedSavedRecipesStream = null;
        _savedRecipesReloadController = null;
      }
    };

    return _cachedSavedRecipesStream!;
  }

  List<String> _recipebookCategoryIdsFor(
    String recipeId,
    Map<String, List<String>> recipebookRecipeCategoryMap,
  ) {
    return List<String>.from(recipebookRecipeCategoryMap[recipeId] ?? const []);
  }

  Map<String, dynamic> _savedRecipeCardFromMiniFields({
    required String recipeId,
    required Map<String, dynamic> m,
    required Timestamp? savedAt,
    required List<String> categoryIds,
  }) {
    final ingCount = (m['ingredientCount'] as num?)?.toInt() ?? 0;
    final totalMin = (m['totalMinutes'] as num?)?.toInt() ?? 0;
    final sourceUploader = _nonEmptyMiniString(m['sourceUploader']);
    final sourceChannel = _nonEmptyMiniString(m['sourceChannel']);
    // 사용자별 별칭이 있으면 카드 제목으로 우선 사용(원본 제목은 그대로 보존).
    final alias = _recipeTitleAliases[recipeId];
    final displayTitle =
        (alias != null && alias.isNotEmpty) ? alias : m['title'];
    return <String, dynamic>{
      'id': recipeId,
      '_savedAt': savedAt,
      '_recipebookCategoryIds': categoryIds,
      'title': displayTitle,
      if (m['thumbnailUrl'] != null) 'thumbnailUrl': m['thumbnailUrl'],
      if (m['thumbnailUrlLarge'] != null)
        'thumbnailUrlLarge': m['thumbnailUrlLarge'],
      if (m['thumbnailUrlCropped'] != null)
        'thumbnailUrlCropped': m['thumbnailUrlCropped'],
      if (m['createdAt'] != null) 'createdAt': m['createdAt'],
      if (m['sourceUrl'] != null) 'sourceUrl': m['sourceUrl'],
      'status': m['status'] ?? 'completed',
      'isHidden': m['isHidden'] == true,
      'calories': m['calories'] ?? 0,
      'source': <String, dynamic>{
        if (m['sourcePlatform'] != null) 'platform': m['sourcePlatform'],
        if (m['sourceUrl'] != null) 'url': m['sourceUrl'],
        if (sourceUploader != null) 'uploader': sourceUploader,
        if (sourceChannel != null) 'channel': sourceChannel,
      },
      if (sourceUploader != null) 'uploader': sourceUploader,
      if (sourceChannel != null) 'channel': sourceChannel,
      if (m['tags'] is List && (m['tags'] as List).isNotEmpty)
        'tags': m['tags'],
      if (m['categories'] is Map && (m['categories'] as Map).isNotEmpty)
        'categories': Map<String, dynamic>.from(m['categories'] as Map),
      ...RecipeSocialCounts.cardSocialFields(m),
      'recipe': <String, dynamic>{
        'ingredients': List<Map<String, dynamic>>.filled(
          ingCount,
          const <String, dynamic>{},
        ),
        'steps': totalMin > 0
            ? <Map<String, dynamic>>[
                <String, dynamic>{'est_minutes': totalMin},
              ]
            : <Map<String, dynamic>>[],
      },
    };
  }

  List<Map<String, dynamic>> _patchRecipebookCategoryIdsOnCards(
    List<Map<String, dynamic>> recipes,
    Map<String, List<String>> recipebookRecipeCategoryMap,
  ) {
    return recipes
        .map((r) {
          final rid = r['id'] as String? ?? '';
          return <String, dynamic>{
            ...r,
            '_recipebookCategoryIds': _recipebookCategoryIdsFor(
              rid,
              recipebookRecipeCategoryMap,
            ),
          };
        })
        .toList();
  }

  /// `null` 은 더 이상 반환하지 않는다. 실패한 chunk 는 건너뛰고 가능한 카드만 모은다.
  Future<List<Map<String, dynamic>>> _fetchSavedRecipeCardsForIds({
    required String userId,
    required List<String> orderedIds,
    required Map<String, Timestamp> savedAtMap,
    Map<String, List<String>> recipebookRecipeCategoryMap = const {},
  }) async {
    if (orderedIds.isEmpty) return [];

    const int chunkSize = 15;
    final recipes = <Map<String, dynamic>>[];

    for (var offset = 0; offset < orderedIds.length; offset += chunkSize) {
      final chunkIds = orderedIds.sublist(
        offset,
        math.min(offset + chunkSize, orderedIds.length),
      );

      List<DocumentSnapshot<Map<String, dynamic>>> miniDocs;
      try {
        miniDocs = await Future.wait(
          chunkIds.map(
            (rid) => _firestore
                .collection('users')
                .doc(userId)
                .collection('savedRecipes')
                .doc(rid)
                .get(),
          ),
        );
      } catch (_) {
        continue;
      }

      for (var i = 0; i < chunkIds.length; i++) {
        final rid = chunkIds[i];
        Map<String, dynamic> m;

        if (miniDocs[i].exists) {
          m = Map<String, dynamic>.from(miniDocs[i].data() ?? {});
          if (_isDuplicateOfHiddenData(m)) {
            unawaited(cleanupDedupTempSavedRecipe(userId, rid));
            continue;
          }
          // 옛 mini 는 hiddenReason 이 없어 duplicate_of 사본이
          // "0재료·15분·0kcal" 완료 카드로 남는 경우가 있다 → 본체 확인.
          if (_looksLikeHollowCompletedCard(m) && !_isNaverBlogMiniDoc(m)) {
            try {
              final main =
                  await _firestore.collection('recipes').doc(rid).get();
              final mainData = main.data();
              if (mainData != null &&
                  (_isDuplicateOfHiddenData(mainData) ||
                      !_includeHiddenInSavedRecipesStream(mainData))) {
                unawaited(cleanupDedupTempSavedRecipe(userId, rid));
                continue;
              }
            } catch (_) {
              // 확인 실패 시 아래 일반 경로로 진행
            }
          }
          if (_miniDocNeedsBackfill(m)) {
            unawaited(_backfillSavedRecipeMiniDocFromMain(userId: userId, rid: rid));
          }
        } else {
          try {
            final main = await _firestore.collection('recipes').doc(rid).get();
            if (!main.exists) continue;
            final data = main.data();
            if (data == null || !_includeHiddenInSavedRecipesStream(data)) {
              if (data != null) {
                unawaited(cleanupDedupTempSavedRecipe(userId, rid));
              }
              continue;
            }
            m = _buildSavedRecipeMiniMap(rid, data);
            unawaited(updateSavedRecipeMiniDoc(userId, rid, data));
          } catch (_) {
            continue;
          }
        }

        if (!_includeHiddenInSavedRecipesStream(m)) {
          unawaited(cleanupDedupTempSavedRecipe(userId, rid));
          continue;
        }

        recipes.add(
          _savedRecipeCardFromMiniFields(
            recipeId: rid,
            m: m,
            savedAt: savedAtMap[rid],
            categoryIds: _recipebookCategoryIdsFor(
              rid,
              recipebookRecipeCategoryMap,
            ),
          ),
        );
      }
    }

    // 미니 doc 이 parsing 인데 본체는 completed 인 경우(비동기 파싱) → 본체 기준으로 패치.
    final parsingIds = recipes
        .where((r) => (r['status'] as String?) == 'parsing')
        .map((r) => r['id'] as String?)
        .whereType<String>()
        .toList();
    if (parsingIds.isNotEmpty) {
      try {
        final mainDocs = await Future.wait(
          parsingIds.map((id) => _firestore.collection('recipes').doc(id).get()),
        );
        // 뒤에서부터 제거해도 index 가 안전하도록 역순 처리.
        for (var i = parsingIds.length - 1; i >= 0; i--) {
          final main = mainDocs[i].data();
          if (main == null || main['status'] != 'completed') continue;
          final rid = parsingIds[i];
          final idx = recipes.indexWhere((r) => r['id'] == rid);
          if (idx < 0) continue;

          // dedup 임시 사본: 목록에서 제거하고 mini/배열 정리.
          // (이전엔 main 기준으로 hollow mini 를 써넣어 가짜 카드가 고착됐다.)
          if (!_includeHiddenInSavedRecipesStream(main) ||
              _isDuplicateOfHiddenData(main)) {
            recipes.removeAt(idx);
            unawaited(cleanupDedupTempSavedRecipe(userId, rid));
            continue;
          }

          // 네이버 블로그는 본문(재료/단계/칼로리)이 main doc 에 없다(§30 저작권).
          // 카드 집계값은 오직 mini doc(updateNaverSavedRecipeMiniDoc)에서만 온다.
          // main 기준으로 재구성하면 0재료·15분·0kcal 카드가 되어버리므로 스킵하고,
          // 파싱 완료 시 reload(최신 세대 emit)가 정상 카드를 그리도록 맡긴다.
          if (_isNaverBlogRecipeData(main)) continue;

          final mini = _buildSavedRecipeMiniMap(rid, main);
          recipes[idx] = _savedRecipeCardFromMiniFields(
            recipeId: rid,
            m: mini,
            savedAt: savedAtMap[rid],
            categoryIds: _recipebookCategoryIdsFor(
              rid,
              recipebookRecipeCategoryMap,
            ),
          );
          unawaited(updateSavedRecipeMiniDoc(userId, rid, main));
        }
      } catch (_) {
        // ignore — 다음 폴링/FCM 에서 재시도
      }
    }

    // 정렬: parsing 우선 + savedAt desc (옛 path 와 동일 규칙)
    final orderMap = <String, int>{};
    for (var i = 0; i < orderedIds.length; i++) {
      orderMap[orderedIds[i]] = i;
    }
    recipes.sort((a, b) {
      final statusA = a['status'] as String? ?? 'completed';
      final statusB = b['status'] as String? ?? 'completed';
      if (statusA == 'parsing' && statusB != 'parsing') return -1;
      if (statusA != 'parsing' && statusB == 'parsing') return 1;
      final recipeIdA = a['id'] as String? ?? '';
      final recipeIdB = b['id'] as String? ?? '';
      final savedAtA = savedAtMap[recipeIdA]?.toDate();
      final savedAtB = savedAtMap[recipeIdB]?.toDate();
      if (savedAtA != null && savedAtB != null) {
        return savedAtB.compareTo(savedAtA);
      }
      if (savedAtA != null) return -1;
      if (savedAtB != null) return 1;
      final orderA = orderMap[recipeIdA] ?? 999999;
      final orderB = orderMap[recipeIdB] ?? 999999;
      return orderA.compareTo(orderB);
    });

    return recipes;
  }

  /// 카드용 미니 doc 들로 빠르게 emit 한다.
  ///
  /// 반환값: true 면 parsing 상태 레시피가 있다.
  Future<bool> _tryFastSavedRecipesEmit({
    required String userId,
    required List<String> orderedIds,
    required int totalCount,
    required Map<String, Timestamp> savedAtMap,
    required Map<String, List<String>> recipebookRecipeCategoryMap,
    required StreamController<SavedRecipesResult> controller,
    int? loadGeneration,
  }) async {
    if (orderedIds.isEmpty) return false;

    final recipes = await _fetchSavedRecipeCardsForIds(
      userId: userId,
      orderedIds: orderedIds,
      savedAtMap: savedAtMap,
      recipebookRecipeCategoryMap: recipebookRecipeCategoryMap,
    );

    final merged = _mergeOptimistic(recipes);
    final hasParsing =
        merged.any((r) => (r['status'] as String?) == 'parsing');

    // 이 로드가 시작된 뒤 더 최신 로드가 시작됐다면(예: 파싱 완료 후 reload),
    // 오래된 이 로드의 결과로 emit·캐시를 덮어쓰지 않는다. 최신 로드가 정상 카드를
    // 그리도록 양보한다. (네이버 파싱 직후 0/15/0 stale 카드 고정 방지)
    if (loadGeneration != null && loadGeneration != _savedRecipesLoadGeneration) {
      return hasParsing;
    }

    _lastEmittedRecipes = List.from(recipes);
    _lastEmittedTotal = totalCount;
    _scheduleMiniSocialRefresh(userId: userId, recipes: recipes);

    _emitSavedRecipes(
      controller,
      SavedRecipesResult(
        merged,
        totalCount,
        recipebookCategories: _lastRecipebookCategories,
        recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
      ),
    );

    final now = DateTime.now();
    final cacheSignature = '$userId:${orderedIds.join(',')}';
    final shouldWriteCache =
        _lastSavedRecipesCacheSignature != cacheSignature ||
        _lastSavedRecipesCacheWrittenAt == null ||
        now.difference(_lastSavedRecipesCacheWrittenAt!).inSeconds > 30;
    if (shouldWriteCache) {
      _lastSavedRecipesCacheSignature = cacheSignature;
      _lastSavedRecipesCacheWrittenAt = now;
      try {
        final cacheRecipes = recipes
            .take(_savedRecipesCacheMaxItems)
            .map((r) {
              final converted = _toJsonCompatible(r);
              if (converted is Map) {
                return Map<String, dynamic>.from(converted);
              }
              return <String, dynamic>{};
            })
            .where((m) => m.isNotEmpty)
            .toList();
        await _localStorage.saveSavedRecipesCache(
          uid: userId,
          cachedAt: now,
          recipes: cacheRecipes,
          totalCount: totalCount,
        );
      } catch (_) {
        // ignore cache write errors
      }
    }

    return hasParsing;
  }

  /// Bookmark fields that should trigger [getSavedRecipes] reload via the user-doc
  /// listener. Ignores lastAccessedAt, attendance, profile, etc.
  String _savedRecipesBookmarkSignature(Map<String, dynamic>? userData) {
    if (userData == null) return '';
    final ids = List<String>.from(userData['savedRecipes'] ?? const []);
    final idPart = ids.join('\u0001');

    final savedAtMillis = <String, int>{};
    final savedAtRaw = userData['savedAt'];
    if (savedAtRaw is Map) {
      for (final entry in Map<String, dynamic>.from(savedAtRaw).entries) {
        final v = entry.value;
        if (v is Timestamp) {
          savedAtMillis[entry.key] = v.millisecondsSinceEpoch;
        }
      }
    }
    for (final entry in userData.entries) {
      if (!entry.key.startsWith('savedAt.')) continue;
      final v = entry.value;
      if (v is Timestamp) {
        savedAtMillis[entry.key.substring(8)] = v.millisecondsSinceEpoch;
      }
    }
    final sortedKeys = savedAtMillis.keys.toList()..sort();
    final atPart = sortedKeys
        .map((k) => '$k:${savedAtMillis[k]}')
        .join('\u0002');

    return '$idPart\u0003$atPart';
  }

  void _scheduleSavedRecipesReloadFromUserDoc({
    required String userId,
    required DocumentSnapshot<Map<String, dynamic>> userDoc,
    required StreamController<SavedRecipesResult> controller,
    required void Function(bool hasParsing) onHasParsing,
    required bool Function() isPollInFlight,
    required void Function(bool value) setPollInFlight,
  }) {
    if (isPollInFlight() || controller.isClosed) return;
    setPollInFlight(true);
    _loadAndEmitRecipes(userId, controller, userDocSnapshot: userDoc)
        .then((hasParsing) {
          if (controller.isClosed) return;
          onHasParsing(hasParsing);
        })
        .whenComplete(() {
          setPollInFlight(false);
        });
  }

  /// 파싱 폴링 최적화 전용 경량 로더.
  ///
  /// 기존 폴링은 tick 마다 [_loadAndEmitRecipes] 를 호출해 user 문서 + 저장
  /// 레시피 전체(N건)의 mini doc 을 재조회했다(저장 레시피가 많을수록 read 폭증).
  /// 파싱 완료를 감지하는 데 필요한 것은 '현재 parsing 상태인 카드'의 상태뿐이므로,
  /// 그 소수의 mini doc 만 읽어 상태를 확인한다. 완료가 감지되면 그때 1회
  /// [_loadAndEmitRecipes] 로 전체를 정확히 동기화한다.
  ///
  /// 반환값: 아직 파싱 중인 레시피가 남아있는지 여부.
  Future<bool> _pollParsingRecipes(
    String userId,
    StreamController<SavedRecipesResult> controller,
  ) async {
    // 직전 emit(_lastEmittedRecipes: 미니 doc 기반 카드) 기준 parsing id 목록.
    final parsingIds = _lastEmittedRecipes
        .where((r) => (r['status'] as String?) == 'parsing')
        .map((r) => (r['id'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    // parsing 카드가 mini doc 으로 확정되기 전(옵티미스틱 단계)이거나 목록을 알 수
    // 없으면, 기존 동작대로 안전하게 전체 리로드한다(정확성 우선, 회귀 없음).
    if (parsingIds.isEmpty) {
      return await _loadAndEmitRecipes(userId, controller);
    }

    // parsing 중인 소수의 mini doc 만 조회한다.
    List<DocumentSnapshot<Map<String, dynamic>>> docs;
    try {
      docs = await Future.wait(
        parsingIds.map(
          (rid) => _firestore
              .collection('users')
              .doc(userId)
              .collection('savedRecipes')
              .doc(rid)
              .get(),
        ),
      );
    } catch (_) {
      // 폴링 조회 실패는 다음 tick 에서 재시도(파싱 유지 간주).
      return true;
    }

    bool anyCompleted = false;
    for (var i = 0; i < parsingIds.length; i++) {
      final d = docs[i];
      if (!d.exists) continue; // 아직 미생성/일시 오류 → 파싱 유지 간주
      final status = (d.data()?['status'] as String?);
      if (status != null && status != 'parsing') {
        anyCompleted = true;
      }
    }

    // 하나라도 완료되면 전체를 정확히 반영하기 위해 1회 풀 리로드.
    if (anyCompleted) {
      return await _loadAndEmitRecipes(userId, controller);
    }

    // 아직 전부 파싱 중이면 마지막으로 알려진 목록을 그대로 재emit 한다
    // (옵티미스틱 카드/진행 표시 유지). 전체 mini doc 재조회는 생략된다.
    if (!controller.isClosed &&
        (_lastEmittedRecipes.isNotEmpty || _optimisticRecipes.isNotEmpty)) {
      _emitSavedRecipes(
        controller,
        SavedRecipesResult(
          _mergeOptimistic(
            List<Map<String, dynamic>>.from(_lastEmittedRecipes),
          ),
          _lastEmittedTotal,
          recipebookCategories: _lastRecipebookCategories,
          recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
        ),
      );
    }
    return true;
  }

  // Helper function to load and emit recipes
  Future<bool> _loadAndEmitRecipes(
    String userId,
    StreamController<SavedRecipesResult> controller, {
    DocumentSnapshot<Map<String, dynamic>>? userDocSnapshot,
  }) async {
    // 이 로드의 세대. 이후 더 늦게 시작된 로드가 있으면 이 로드의 emit 은 stale 로 간주.
    final int loadGeneration = ++_savedRecipesLoadGeneration;
    try {
      // Minimize logging (prevent too many log outputs)
      final userDoc =
          userDocSnapshot ??
          await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        // 유저 문서가 없어도 로컬 카테고리 캐시는 유지한다.
        try {
          final ls = LocalStorageService();
          _lastRecipebookCategories = List<Map<String, dynamic>>.from(
            await ls.getRecipebookCategories(userId, seedIfEmpty: false),
          );
          final mapRaw = await ls.getRecipebookRecipeCategoryMap(userId);
          _lastRecipebookRecipeCategoryMap = mapRaw.map(
            (k, v) => MapEntry(k, List<String>.from(v)),
          );
        } catch (_) {}
        if (!controller.isClosed) {
          _emitSavedRecipes(
            controller,
            SavedRecipesResult(
              [],
              0,
              recipebookCategories: _lastRecipebookCategories,
              recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
            ),
          );
        }
        return false;
      }

      final userData = userDoc.data();
      // 사용자별 제목 별칭 캐시 갱신(카드 제목 override 에 사용).
      _applyUserTitleAliases(userData);
      final savedRecipeIds = List<String>.from(userData?['savedRecipes'] ?? []);
      final totalCount = savedRecipeIds.length;
      // 레시피북 카테고리/매핑: 유저 문서(Firestore) 원본 + 로컬 캐시.
      final ls = LocalStorageService();
      final recipebookCategories = await ls.getRecipebookCategories(
        userId,
        seedIfEmpty: false,
      );
      final recipebookRecipeCategoryMap =
          await ls.getRecipebookRecipeCategoryMap(userId);
      _lastRecipebookCategories = List<Map<String, dynamic>>.from(
        recipebookCategories,
      );
      _lastRecipebookRecipeCategoryMap = recipebookRecipeCategoryMap.map(
        (k, v) => MapEntry(k, List<String>.from(v)),
      );

      // Get savedAt map (recipeId -> timestamp)
      final savedAtMap = <String, Timestamp>{};
      if (userData != null) {
        final savedAtRaw = userData['savedAt'];
        if (savedAtRaw != null && savedAtRaw is Map) {
          final savedAtMapRaw = Map<String, dynamic>.from(savedAtRaw);
          savedAtMapRaw.forEach((key, value) {
            if (value is Timestamp) savedAtMap[key] = value;
          });
        }
        userData.forEach((key, value) {
          if (key.startsWith('savedAt.') && value is Timestamp) {
            savedAtMap[key.substring(8)] = value;
          }
        });
      }

      if (savedRecipeIds.isEmpty) {
        _emitSavedRecipes(
          controller,
          SavedRecipesResult(
            _mergeOptimistic([]),
            0,
            recipebookCategories: _lastRecipebookCategories,
            recipebookRecipeCategoryMap: _lastRecipebookRecipeCategoryMap,
          ),
        );
        return false;
      }

      // Fixed order from user doc only (savedAt desc)
      final orderedIds = List<String>.from(savedRecipeIds)
        ..sort((a, b) {
          final dateA = savedAtMap[a]?.toDate();
          final dateB = savedAtMap[b]?.toDate();
          if (dateA != null && dateB != null) return dateB.compareTo(dateA);
          if (dateA != null) return -1;
          if (dateB != null) return 1;
          return 0;
        });

      // 미니 doc 기반 카드 목록만 emit (full recipes/{rid} bulk fetch 제거).
      return await _tryFastSavedRecipesEmit(
        userId: userId,
        orderedIds: orderedIds,
        totalCount: totalCount,
        savedAtMap: savedAtMap,
        recipebookRecipeCategoryMap: recipebookRecipeCategoryMap,
        controller: controller,
        loadGeneration: loadGeneration,
      );
    } catch (e) {
      if (!controller.isClosed) controller.addError(e);
      return false;
    }
  }

  /// Fetches only meta (totalMinutes, thumbnailUrl, servings, sourceUrl, platform) for the given recipe IDs.
  /// Used by fridge "사용할 재료" tab so we load just the few fridge recipes in parallel instead of all saved recipes.
  Future<Map<String, Map<String, dynamic>>> getRecipeMetaForIds(
    List<String> recipeIds,
  ) async {
    if (recipeIds.isEmpty) return {};
    final ids = recipeIds.toSet().toList();
    try {
      final result = <String, Map<String, dynamic>>{};
      final now = DateTime.now();
      final idsToFetch = <String>[];
      for (final recipeId in ids) {
        final cachedMeta = _recipeMetaCacheById[recipeId];
        final cachedAt = _recipeMetaCachedAtById[recipeId];
        if (cachedMeta != null &&
            cachedAt != null &&
            now.difference(cachedAt) <= _recipeMetaCacheTtl) {
          result[recipeId] = Map<String, dynamic>.from(cachedMeta);
          continue;
        }
        _recipeMetaCacheById.remove(recipeId);
        _recipeMetaCachedAtById.remove(recipeId);
        idsToFetch.add(recipeId);
      }

      if (idsToFetch.isEmpty) return result;

      final fetchedEntries = await Future.wait(
        idsToFetch.map((recipeId) async {
          try {
            final doc = await _firestore
                .collection('recipes')
                .doc(recipeId)
                .get();
            if (!doc.exists) return null;
            final data = doc.data();
            if (data == null) return null;

            final recipeData = (data['recipe'] is Map)
                ? Map<String, dynamic>.from(
                    (data['recipe'] as Map).map(
                      (k, v) => MapEntry(k.toString(), v),
                    ),
                  )
                : <String, dynamic>{};
            final steps = recipeData['steps'] as List? ?? [];
            int totalMinutes = 0;
            for (final step in steps) {
              if (step is Map && step['est_minutes'] != null) {
                totalMinutes += (step['est_minutes'] as num).toInt();
              }
            }
            if (totalMinutes == 0) totalMinutes = 15;

            final servings =
                (recipeData['servings'] as num?)?.toInt() ??
                (data['servings'] as num?)?.toInt() ??
                2;
            final thumbnailUrl = RecipeThumbnailResolver.resolve(
              Map<String, dynamic>.from(data),
              preferCroppedForInstagram: true,
            );
            final srcMap = data['source'] is Map
                ? Map<String, dynamic>.from(
                    (data['source'] as Map).map(
                      (k, v) => MapEntry(k.toString(), v),
                    ),
                  )
                : <String, dynamic>{};
            final metaSourceUrl =
                (data['sourceUrl'] as String?)?.trim() ??
                (srcMap['url'] as String?)?.trim() ??
                '';
            final metaPlatform = (srcMap['platform'] as String?)?.trim() ?? '';

            final meta = <String, dynamic>{
              'totalMinutes': totalMinutes,
              'thumbnailUrl': thumbnailUrl,
              'servings': servings,
              'sourceUrl': metaSourceUrl,
              'platform': metaPlatform,
            };
            return MapEntry<String, Map<String, dynamic>>(recipeId, meta);
          } catch (_) {
            // Skip permission denied / transient errors for single docs.
            return null;
          }
        }),
      );

      for (final entry in fetchedEntries) {
        if (entry == null) continue;
        result[entry.key] = entry.value;
        _recipeMetaCacheById[entry.key] = Map<String, dynamic>.from(
          entry.value,
        );
        _recipeMetaCachedAtById[entry.key] = now;
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// explore/피커용 저장 레시피 빠른 로드. 미니 doc 병렬 fetch + 필요 시 recipes 백필.
  Future<List<Map<String, dynamic>>> getSavedRecipesForExplore({
    int limit = 40,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return [];
    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return [];
      final userData = userDoc.data();
      final savedRecipeIds = List<String>.from(userData?['savedRecipes'] ?? []);
      if (savedRecipeIds.isEmpty) return _mergeOptimistic([]);

      final ids = savedRecipeIds.take(limit).toList();

      final savedAtMap = <String, Timestamp>{};
      if (userData != null) {
        final savedAtRaw = userData['savedAt'];
        if (savedAtRaw != null && savedAtRaw is Map) {
          final savedAtMapRaw = Map<String, dynamic>.from(savedAtRaw);
          savedAtMapRaw.forEach((key, value) {
            if (value is Timestamp) savedAtMap[key] = value;
          });
        }
        userData.forEach((key, value) {
          if (key.startsWith('savedAt.') && value is Timestamp) {
            savedAtMap[key.substring(8)] = value;
          }
        });
      }

      final recipes = await _fetchSavedRecipeCardsForIds(
        userId: user.uid,
        orderedIds: ids,
        savedAtMap: savedAtMap,
      );
      _scheduleMiniSocialRefresh(userId: user.uid, recipes: recipes);

      final seenSourceUrls = <String>{};
      final deduped = <Map<String, dynamic>>[];
      for (final r in recipes) {
        final url = (r['sourceUrl'] as String?)?.trim() ?? '';
        if (url.isNotEmpty && seenSourceUrls.contains(url)) continue;
        if (url.isNotEmpty) seenSourceUrls.add(url);
        deduped.add(r);
      }
      return _mergeOptimistic(deduped);
    } catch (_) {
      return [];
    }
  }

  /// Fetches visible completed recipes from Firestore for explore/트렌드.
  /// Query aligns with security rules by explicitly filtering hidden/completed docs.
  /// If indexed query fails (index missing), falls back to id-ordered scan.
  Future<List<Map<String, dynamic>>> getExploreRecipesForGuests({
    int limit = 50,
  }) async {
    final cached = _getExploreGuestsCached(limit);
    if (cached != null) {
      return _mergeOptimistic(cached);
    }
    try {
      final primary = await _getExploreRecipesForGuestsPrimary(limit);
      if (primary.isNotEmpty) {
        _setExploreGuestsCache(limit, primary);
        return _mergeOptimistic(_cloneRecipeMaps(primary));
      }
      final fallback = await _getExploreRecipesForGuestsIdScan(limit);
      _setExploreGuestsCache(limit, fallback);
      return _mergeOptimistic(_cloneRecipeMaps(fallback));
    } catch (e) {
      debugPrint('getExploreRecipesForGuests: $e');
      try {
        final fallback = await _getExploreRecipesForGuestsIdScan(limit);
        _setExploreGuestsCache(limit, fallback);
        return _mergeOptimistic(_cloneRecipeMaps(fallback));
      } catch (_) {
        return [];
      }
    }
  }

  /// Primary explore query ordered by recency.
  /// Requires composite index:
  /// - isHidden ASC + createdAt DESC (+ __name__)
  /// - isHidden ASC + status ASC + createdAt DESC (+ __name__)
  Future<List<Map<String, dynamic>>> _getExploreRecipesForGuestsPrimary(
    int limit,
  ) async {
    final query = _firestore
        .collection('recipes')
        .where('isHidden', isEqualTo: false)
        .where('status', isEqualTo: 'completed')
        .orderBy('createdAt', descending: true)
        .limit(limit * 3);
    final snapshot = await query.get();
    final recipes = <Map<String, dynamic>>[];
    final seenSourceUrls = <String>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final sourceUrl = (data['sourceUrl'] as String?)?.trim() ?? '';
      if (sourceUrl.isNotEmpty && seenSourceUrls.contains(sourceUrl)) continue;
      if (sourceUrl.isNotEmpty) seenSourceUrls.add(sourceUrl);
      recipes.add({'id': doc.id, ...data});
      if (recipes.length >= limit * 2) break;
    }
    _sortExploreRecipesByParsedAtDesc(recipes);
    return recipes;
  }

  Future<List<Map<String, dynamic>>> _getExploreRecipesForGuestsIdScan(
    int limit,
  ) async {
    final query = _firestore
        .collection('recipes')
        .where('isHidden', isEqualTo: false)
        .orderBy(FieldPath.documentId)
        .limit(math.min(limit * 4, 400));
    final snapshot = await query.get();
    final recipes = <Map<String, dynamic>>[];
    final seenSourceUrls = <String>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (data['isHidden'] == true) continue;
      final st = data['status'] as String?;
      if (st != null && st != 'completed') continue;
      final sourceUrl = (data['sourceUrl'] as String?)?.trim() ?? '';
      if (sourceUrl.isNotEmpty && seenSourceUrls.contains(sourceUrl)) continue;
      if (sourceUrl.isNotEmpty) seenSourceUrls.add(sourceUrl);
      recipes.add({'id': doc.id, ...data});
      if (recipes.length >= limit) break;
    }
    _sortExploreRecipesByParsedAtDesc(recipes);
    return recipes;
  }

  /// Paged fetch for 트렌드 search browse (avoids streaming the whole collection).
  /// Orders by createdAt(desc), then sorts each page by parsed recency
  /// (completedAt > createdAt) so "지금 뜨는 레시피" starts with recently parsed.
  /// Requires composite index:
  /// - isHidden ASC + createdAt DESC (+ __name__)
  /// - isHidden ASC + status ASC + createdAt DESC (+ __name__)
  Future<ExploreRecipesPageResult> fetchExploreRecipesPage({
    DocumentSnapshot? startAfter,
    int rawLimit = 30,
  }) async {
    final cached = _getExplorePageCached(
      startAfter: startAfter,
      rawLimit: rawLimit,
    );
    if (cached != null) {
      return cached;
    }
    try {
      Query q = _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .orderBy('createdAt', descending: true)
          .limit(rawLimit);
      if (startAfter != null) {
        q = q.startAfterDocument(startAfter);
      }
      final snapshot = await q.get();
      final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      final recipes = <Map<String, dynamic>>[];
      final seenSourceUrls = <String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final sourceUrl = (data['sourceUrl'] as String?)?.trim() ?? '';
        if (sourceUrl.isNotEmpty && seenSourceUrls.contains(sourceUrl)) {
          continue;
        }
        if (sourceUrl.isNotEmpty) seenSourceUrls.add(sourceUrl);
        recipes.add({'id': doc.id, ...data});
      }
      final merged = _mergeOptimistic(recipes);
      _sortExploreRecipesByParsedAtDesc(merged);
      final hasMore = snapshot.docs.length >= rawLimit;
      final result = ExploreRecipesPageResult(
        recipes: merged,
        lastRawDocument: lastDoc,
        hasMore: hasMore,
      );
      _setExplorePageCache(
        startAfter: startAfter,
        rawLimit: rawLimit,
        result: result,
      );
      return result;
    } catch (e) {
      debugPrint('fetchExploreRecipesPage: $e');
      // Fallback for environments without required composite indexes.
      // Keeps community/home trending visible until indexes are deployed.
      try {
        final fallback = await _fetchExploreRecipesPageIdScan(
          startAfter: startAfter,
          rawLimit: rawLimit,
        );
        _setExplorePageCache(
          startAfter: startAfter,
          rawLimit: rawLimit,
          result: fallback,
        );
        return fallback;
      } catch (fallbackError) {
        debugPrint('fetchExploreRecipesPage fallback: $fallbackError');
        return ExploreRecipesPageResult(
          recipes: const [],
          lastRawDocument: null,
          hasMore: false,
        );
      }
    }
  }

  /// 네이버 블로그 카드 전용 페이지네이션. `recipes` 컬렉션 전체를 순회하며
  /// 클라에서 platform 을 필터하면 naver_blog 가 희귀할 때 성능이 매우 나쁘다.
  /// 이 메서드는 `where source.platform == naver_blog` 를 직접 걸어 빠르게 가져온다.
  /// 복합 인덱스: isHidden + status + source.platform + createdAt(desc) 필요.
  Future<ExploreRecipesPageResult> fetchNaverBlogRecipesPage({
    DocumentSnapshot? startAfter,
    int rawLimit = 18,
  }) async {
    final cached = _getExplorePageCached(
      startAfter: startAfter,
      rawLimit: rawLimit,
      prefix: 'naver_blog',
    );
    if (cached != null) {
      return cached;
    }
    try {
      Query q = _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .where('source.platform', isEqualTo: 'naver_blog')
          .orderBy('createdAt', descending: true)
          .limit(rawLimit);
      if (startAfter != null) {
        q = q.startAfterDocument(startAfter);
      }
      final snapshot = await q.get();
      final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      final recipes = <Map<String, dynamic>>[];
      final seenSourceUrls = <String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final sourceUrl = (data['sourceUrl'] as String?)?.trim() ?? '';
        if (sourceUrl.isNotEmpty && seenSourceUrls.contains(sourceUrl)) {
          continue;
        }
        if (sourceUrl.isNotEmpty) seenSourceUrls.add(sourceUrl);
        recipes.add({'id': doc.id, ...data});
      }
      _sortExploreRecipesByParsedAtDesc(recipes);
      final hasMore = snapshot.docs.length >= rawLimit;
      final result = ExploreRecipesPageResult(
        recipes: recipes,
        lastRawDocument: lastDoc,
        hasMore: hasMore,
      );
      _setExplorePageCache(
        startAfter: startAfter,
        rawLimit: rawLimit,
        prefix: 'naver_blog',
        result: result,
      );
      return result;
    } catch (e) {
      debugPrint('fetchNaverBlogRecipesPage: $e');
      return ExploreRecipesPageResult(
        recipes: const [],
        lastRawDocument: null,
        hasMore: false,
      );
    }
  }

  Future<ExploreRecipesPageResult> _fetchExploreRecipesPageIdScan({
    DocumentSnapshot? startAfter,
    required int rawLimit,
  }) async {
    Query q = _firestore
        .collection('recipes')
        .where('isHidden', isEqualTo: false)
        .orderBy(FieldPath.documentId)
        .limit(rawLimit);
    if (startAfter != null) {
      q = q.startAfterDocument(startAfter);
    }
    final snapshot = await q.get();
    final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
    final recipes = <Map<String, dynamic>>[];
    final seenSourceUrls = <String>{};
    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['isHidden'] == true) continue;
      final st = data['status'] as String?;
      if (st != null && st != 'completed') continue;
      final sourceUrl = (data['sourceUrl'] as String?)?.trim() ?? '';
      if (sourceUrl.isNotEmpty && seenSourceUrls.contains(sourceUrl)) continue;
      if (sourceUrl.isNotEmpty) seenSourceUrls.add(sourceUrl);
      recipes.add({'id': doc.id, ...data});
    }
    final merged = _mergeOptimistic(recipes);
    _sortExploreRecipesByParsedAtDesc(merged);
    final hasMore = snapshot.docs.length >= rawLimit;
    return ExploreRecipesPageResult(
      recipes: merged,
      lastRawDocument: lastDoc,
      hasMore: hasMore,
    );
  }

  Future<List<String>> getSeasonalRecipeIdsForMonth({
    required int month,
    int limit = 60,
  }) async {
    final cached = _seasonalIndexCacheByMonth[month];
    if (cached != null && _isExploreCacheFresh(cached.cachedAt)) {
      return cached.recipeIds.take(limit).toList();
    }

    try {
      final doc = await _firestore
          .collection('seasonal_recipe_index')
          .doc(month.toString())
          .get();
      if (!doc.exists) return const <String>[];
      final data = doc.data() ?? <String, dynamic>{};
      final rawIds = data['recipeIds'];
      if (rawIds is! List) return const <String>[];
      final ids = <String>[];
      final seen = <String>{};
      for (final id in rawIds) {
        final s = id?.toString() ?? '';
        if (s.isEmpty || seen.contains(s)) continue;
        seen.add(s);
        ids.add(s);
      }
      _seasonalIndexCacheByMonth[month] = _SeasonalIndexCacheEntry(
        cachedAt: DateTime.now(),
        recipeIds: List<String>.from(ids),
      );
      return ids.take(limit).toList();
    } catch (e) {
      debugPrint('getSeasonalRecipeIdsForMonth: $e');
      return const <String>[];
    }
  }

  Future<List<String>> getHomeSectionRecipeIds({
    required String sectionKey,
    int limit = 60,
  }) async {
    final cached = _homeSectionIndexCacheByKey[sectionKey];
    if (cached != null && _isExploreCacheFresh(cached.cachedAt)) {
      return cached.recipeIds.take(limit).toList();
    }

    final ids = await _readHomeSectionRecipeIds(sectionKey);
    if (ids == null) return const <String>[];
    return ids.take(limit).toList();
  }

  /// 인덱스 전체를 읽고 메모리 캐시를 갱신한다. 네트워크 실패 시 null.
  Future<List<String>?> _readHomeSectionRecipeIds(String sectionKey) async {
    try {
      final doc = await _firestore
          .collection('home_section_index')
          .doc(sectionKey)
          .get();
      if (!doc.exists) {
        _homeSectionIndexCacheByKey[sectionKey] = _HomeSectionIndexCacheEntry(
          cachedAt: DateTime.now(),
          recipeIds: const <String>[],
        );
        return const <String>[];
      }
      final data = doc.data() ?? <String, dynamic>{};
      final rawIds = data['recipeIds'];
      if (rawIds is! List) return const <String>[];
      final ids = <String>[];
      final seen = <String>{};
      for (final id in rawIds) {
        final s = id?.toString() ?? '';
        if (s.isEmpty || seen.contains(s)) continue;
        seen.add(s);
        ids.add(s);
      }
      _homeSectionIndexCacheByKey[sectionKey] = _HomeSectionIndexCacheEntry(
        cachedAt: DateTime.now(),
        recipeIds: List<String>.from(ids),
      );
      return ids;
    } catch (e) {
      debugPrint('getHomeSectionRecipeIds($sectionKey): $e');
      return null;
    }
  }

  /// 홈 디스크 스냅샷과 비교할 때 사용. 실패하면 null이라 기존 카드를 유지한다.
  Future<List<String>?> readHomeSectionRecipeIds({
    required String sectionKey,
    int limit = 30,
  }) async {
    final ids = await _readHomeSectionRecipeIds(sectionKey);
    if (ids == null) return null;
    return ids.take(limit).toList();
  }

  /// 방송 프로그램 섹션 레시피.
  ///
  /// `home_section_index/{sectionKey}` 만 사용한다.
  /// 인덱스가 비어 있으면 빈 목록을 반환하고, explore 키워드 스캔 폴백은 하지 않는다.
  /// (필터링은 Cloud Functions 인덱스 빌드가 담당.)
  Future<List<Map<String, dynamic>>> getProgramSectionRecipes({
    required String sectionKey,
    int limit = 40,
  }) async {
    if (limit <= 0) return const <Map<String, dynamic>>[];

    final indexedIds = await getHomeSectionRecipeIds(
      sectionKey: sectionKey,
      limit: limit,
    );
    if (indexedIds.isEmpty) return const <Map<String, dynamic>>[];
    return getExploreRecipesByIds(indexedIds, limit: limit);
  }

  /// chef_recipe_index 에서 count>=minCount 인 셰프를 count 내림차순으로 반환.
  Future<Map<String, List<String>>> getChefRecipeIdsByChef({
    int minCount = 2,
    int maxChefs = 12,
  }) async {
    try {
      if (maxChefs <= 0) return const {};
      final snap = await _firestore
          .collection('chef_recipe_index')
          .where('count', isGreaterThanOrEqualTo: minCount)
          .orderBy('count', descending: true)
          .limit(maxChefs)
          .get();
      final entries = <({String chef, List<String> ids, int count})>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final chef = (data['chefName'] as String?)?.trim() ?? doc.id;
        if (chef.isEmpty) continue;
        final count = (data['count'] as num?)?.toInt() ?? 0;
        if (count < minCount) continue;
        final cached = _chefIndexCacheByName[chef];
        List<String> ids;
        if (cached != null && _isExploreCacheFresh(cached.cachedAt)) {
          ids = cached.recipeIds;
        } else {
          final rawIds = data['recipeIds'];
          ids = <String>[];
          final seen = <String>{};
          if (rawIds is List) {
            for (final id in rawIds) {
              final s = id?.toString() ?? '';
              if (s.isEmpty || seen.contains(s)) continue;
              seen.add(s);
              ids.add(s);
            }
          }
          _chefIndexCacheByName[chef] = _ChefIndexCacheEntry(
            cachedAt: DateTime.now(),
            recipeIds: List<String>.from(ids),
            count: count,
          );
        }
        entries.add((chef: chef, ids: ids, count: count));
      }
      final result = <String, List<String>>{};
      for (final e in entries) {
        result[e.chef] = e.ids;
      }
      return result;
    } catch (e) {
      debugPrint('getChefRecipeIdsByChef: $e');
      return const {};
    }
  }

  Map<String, dynamic>? _getExploreRecipeDocCached(String recipeId) {
    final entry = _exploreRecipeDocById.get(recipeId);
    if (entry == null) return null;
    if (!_isExploreCacheFresh(entry.cachedAt)) {
      _exploreRecipeDocById.remove(recipeId);
      return null;
    }
    return Map<String, dynamic>.from(entry.recipe);
  }

  void _setExploreRecipeDocCache(String recipeId, Map<String, dynamic> recipe) {
    _exploreRecipeDocById.put(
      recipeId,
      _ExploreRecipeDocCacheEntry(
        cachedAt: DateTime.now(),
        recipe: Map<String, dynamic>.from(recipe),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getExploreRecipesByIds(
    List<String> recipeIds, {
    int limit = 40,
  }) async {
    if (recipeIds.isEmpty) return const <Map<String, dynamic>>[];
    final ids = <String>[];
    final seen = <String>{};
    for (final id in recipeIds) {
      final s = id.trim();
      if (s.isEmpty || seen.contains(s)) continue;
      seen.add(s);
      ids.add(s);
      if (ids.length >= limit) break;
    }
    if (ids.isEmpty) return const <Map<String, dynamic>>[];

    try {
      final recipes = <Map<String, dynamic>>[];
      final toFetch = <String>[];
      for (final id in ids) {
        final cached = _getExploreRecipeDocCached(id);
        if (cached != null) {
          recipes.add(cached);
        } else {
          toFetch.add(id);
        }
      }
      if (toFetch.isNotEmpty) {
        for (var offset = 0; offset < toFetch.length; offset += _exploreRecipeIdFetchChunkSize) {
          final chunkEnd = math.min(
            offset + _exploreRecipeIdFetchChunkSize,
            toFetch.length,
          );
          final chunk = toFetch.sublist(offset, chunkEnd);
          final refs = chunk
              .map((id) => _firestore.collection('recipes').doc(id))
              .toList(growable: false);
          final snaps = await Future.wait(refs.map((ref) => ref.get()));
          for (var i = 0; i < snaps.length; i++) {
            final snap = snaps[i];
            final id = chunk[i];
            if (!snap.exists) continue;
            final data = snap.data();
            if (data == null) continue;
            if (data['isHidden'] == true) continue;
            final st = data['status'] as String?;
            if (st != null && st != 'completed') continue;
            final recipe = {'id': id, ...data};
            _setExploreRecipeDocCache(id, recipe);
            recipes.add(recipe);
          }
        }
      }
      final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      recipes.sort((a, b) {
        final ai = order[a['id']?.toString() ?? ''] ?? 999999;
        final bi = order[b['id']?.toString() ?? ''] ?? 999999;
        return ai.compareTo(bi);
      });
      return _mergeOptimistic(recipes);
    } catch (e) {
      debugPrint('getExploreRecipesByIds: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// 핫한 레시피 묶음(같은 기본 요리명) 가져오기.
  /// 백엔드(`recipe_groups`)는 5개 이상인 묶음만 `eligible:true` 로 표시되어 있고,
  /// 정렬은 `recentCount`(최근 3일 내 파싱 수) desc → `count`(전체 묶음 크기) desc.
  /// 인덱스: `eligible ASC + recentCount DESC + count DESC`.
  Future<List<Map<String, dynamic>>> fetchHotRecipeGroups({
    int limit = 30,
  }) async {
    try {
      final snap = await _firestore
          .collection('recipe_groups')
          .where('eligible', isEqualTo: true)
          .orderBy('recentCount', descending: true)
          .orderBy('count', descending: true)
          .limit(limit)
          .get();
      final out = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        out.add({'id': doc.id, ...data});
      }
      return out;
    } catch (e) {
      debugPrint('fetchHotRecipeGroups: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// 핫한 레시피 묶음 실시간 스트림. `fetchHotRecipeGroups`와 동일한 쿼리/인덱스를
  /// 사용하되 `snapshots()`로 구독해 묶음 카운트가 바뀔 때마다 자동 갱신된다.
  Stream<List<Map<String, dynamic>>> streamHotRecipeGroups({int limit = 200}) {
    return _firestore
        .collection('recipe_groups')
        .where('eligible', isEqualTo: true)
        .orderBy('recentCount', descending: true)
        .orderBy('count', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) =>
              snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList(),
        );
  }

  /// 요리명 검색: recency 스캔 대신 같은 `groupKey` 레시피를 바로 찾는다.
  /// "두부 부침" 은 compact 키 "두부부침" 으로도 조회한다.
  Future<List<Map<String, dynamic>>> searchRecipesByDishQuery(
    String query, {
    int limit = 20,
  }) async {
    final keys = dishGroupKeysForQuery(query);
    if (keys.isEmpty || limit <= 0) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    final keysToQuery = keys.take(6).toList(growable: false);
    final pages = await Future.wait(
      keysToQuery.map(
        (key) => fetchRecipesInGroup(
          key,
          limit: math.max(4, limit),
        ),
      ),
    );
    for (final page in pages) {
      for (final recipe in page.recipes) {
        final id = recipe['id'] as String? ?? '';
        if (id.isEmpty || !seen.add(id)) continue;
        out.add(recipe);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// 한 묶음(`groupKey`)에 속한 레시피들을 파싱(`completedAt`) 최신순으로 가져온다.
  /// 바텀시트에서 lazy 페이지네이션으로 사용.
  /// 인덱스: `groupKey ASC + isHidden ASC + status ASC + completedAt DESC`.
  Future<ExploreRecipesPageResult> fetchRecipesInGroup(
    String groupKey, {
    DocumentSnapshot? startAfter,
    int limit = 20,
  }) async {
    final key = groupKey.trim();
    if (key.isEmpty) {
      return ExploreRecipesPageResult(
        recipes: const [],
        lastRawDocument: null,
        hasMore: false,
      );
    }
    try {
      Query q = _firestore
          .collection('recipes')
          .where('groupKey', isEqualTo: key)
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .orderBy('completedAt', descending: true)
          .limit(limit);
      if (startAfter != null) q = q.startAfterDocument(startAfter);
      final snapshot = await q.get();
      final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      final recipes = <Map<String, dynamic>>[];
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        recipes.add({'id': doc.id, ...data});
      }
      return ExploreRecipesPageResult(
        recipes: recipes,
        lastRawDocument: lastDoc,
        hasMore: snapshot.docs.length >= limit,
      );
    } catch (e) {
      debugPrint('fetchRecipesInGroup: $e');
      return ExploreRecipesPageResult(
        recipes: const [],
        lastRawDocument: null,
        hasMore: false,
      );
    }
  }

  bool _isExploreCacheFresh(DateTime cachedAt) {
    return DateTime.now().difference(cachedAt) <= _exploreCacheTtl;
  }

  String _explorePageCacheKey({
    required DocumentSnapshot? startAfter,
    required int rawLimit,
    String prefix = '',
  }) {
    final cursor = startAfter?.id ?? '__first__';
    final p = prefix.isEmpty ? '' : '$prefix|';
    return '$p$cursor|$rawLimit';
  }

  HomeTrendingFeedSnapshot _cloneHomeTrendingFeedSnapshot(
    HomeTrendingFeedSnapshot s,
  ) {
    final displayed = <String, List<Map<String, dynamic>>>{};
    for (final entry in s.displayedSections.entries) {
      displayed[entry.key] = _cloneRecipeMaps(entry.value);
    }
    return HomeTrendingFeedSnapshot(
      allRecipes: _cloneRecipeMaps(s.allRecipes),
      seasonalIndexedIds: List<String>.from(s.seasonalIndexedIds),
      hasMore: s.hasMore,
      displayedSections: displayed,
      displayedSeasonal: s.displayedSeasonal
          .map(
            (e) => (
              Map<String, dynamic>.from(e.$1),
              e.$2,
            ),
          )
          .toList(growable: false),
      chefIndex: {
        for (final e in s.chefIndex.entries) e.key: List<String>.from(e.value),
      },
      homeSectionIndexedIdsByTitle: {
        for (final e in s.homeSectionIndexedIdsByTitle.entries)
          e.key: List<String>.from(e.value),
      },
      sectionFetchedCount: Map<String, int>.from(s.sectionFetchedCount),
      seasonalFetchedCount: s.seasonalFetchedCount,
    );
  }

  Map<String, dynamic> _homeTrendingSnapshotToJson(HomeTrendingFeedSnapshot s) {
    final displayedSections = <String, dynamic>{};
    for (final entry in s.displayedSections.entries) {
      displayedSections[entry.key] = entry.value.map(_toJsonCompatible).toList();
    }
    final displayedSeasonal = s.displayedSeasonal
        .map(
          (e) => {
            'recipe': _toJsonCompatible(e.$1),
            'label': e.$2,
          },
        )
        .toList();
    return {
      'allRecipes': s.allRecipes.map(_toJsonCompatible).toList(),
      'seasonalIndexedIds': s.seasonalIndexedIds,
      'hasMore': s.hasMore,
      'displayedSections': displayedSections,
      'displayedSeasonal': displayedSeasonal,
      'chefIndex': s.chefIndex,
      'homeSectionIndexedIdsByTitle': s.homeSectionIndexedIdsByTitle,
      'sectionFetchedCount': s.sectionFetchedCount,
      'seasonalFetchedCount': s.seasonalFetchedCount,
    };
  }

  HomeTrendingFeedSnapshot? _homeTrendingSnapshotFromJson(
    Map<String, dynamic> raw,
  ) {
    try {
      final allRaw = raw['allRecipes'] as List? ?? const [];
      final allRecipes = allRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (allRecipes.isEmpty) return null;

      // 구버전 캐시의 naverRecipes/naverHasMore 는 무시한다 (홈 네이버 섹션 제거).

      final displayedSections = <String, List<Map<String, dynamic>>>{};
      final sectionsRaw = raw['displayedSections'];
      if (sectionsRaw is Map) {
        for (final entry in sectionsRaw.entries) {
          final list = entry.value;
          if (list is! List) continue;
          displayedSections[entry.key.toString()] = list
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }

      final displayedSeasonal = <(Map<String, dynamic>, String)>[];
      final seasonalRaw = raw['displayedSeasonal'] as List? ?? const [];
      for (final item in seasonalRaw) {
        if (item is! Map) continue;
        final recipe = item['recipe'];
        final label = item['label']?.toString() ?? '';
        if (recipe is Map) {
          displayedSeasonal.add((
            Map<String, dynamic>.from(recipe),
            label,
          ));
        }
      }

      final chefIndex = <String, List<String>>{};
      final chefRaw = raw['chefIndex'];
      if (chefRaw is Map) {
        for (final entry in chefRaw.entries) {
          final ids = entry.value;
          if (ids is! List) continue;
          chefIndex[entry.key.toString()] =
              ids.map((e) => e.toString()).toList();
        }
      }

      final homeSectionIndexedIdsByTitle = <String, List<String>>{};
      final sectionIdsRaw = raw['homeSectionIndexedIdsByTitle'];
      if (sectionIdsRaw is Map) {
        for (final entry in sectionIdsRaw.entries) {
          final ids = entry.value;
          if (ids is! List) continue;
          homeSectionIndexedIdsByTitle[entry.key.toString()] =
              ids.map((e) => e.toString()).toList();
        }
      }

      final sectionFetchedCount = <String, int>{};
      final fetchedRaw = raw['sectionFetchedCount'];
      if (fetchedRaw is Map) {
        for (final entry in fetchedRaw.entries) {
          final n = entry.value;
          if (n is num) {
            sectionFetchedCount[entry.key.toString()] = n.toInt();
          }
        }
      }

      final seasonalFetchedCount =
          (raw['seasonalFetchedCount'] as num?)?.toInt() ?? 0;

      return HomeTrendingFeedSnapshot(
        allRecipes: allRecipes,
        seasonalIndexedIds: List<String>.from(
          raw['seasonalIndexedIds'] as List? ?? const [],
        ),
        hasMore: raw['hasMore'] as bool? ?? true,
        displayedSections: displayedSections,
        displayedSeasonal: displayedSeasonal,
        chefIndex: chefIndex,
        homeSectionIndexedIdsByTitle: homeSectionIndexedIdsByTitle,
        sectionFetchedCount: sectionFetchedCount,
        seasonalFetchedCount: seasonalFetchedCount,
      );
    } catch (_) {
      return null;
    }
  }

  HomeTrendingFeedSnapshot? _peekHomeTrendingFeedCacheMemory() {
    final entry = _homeTrendingFeedCache;
    if (entry == null || !_isExploreCacheFresh(entry.cachedAt)) {
      _homeTrendingFeedCache = null;
      return null;
    }
    return _cloneHomeTrendingFeedSnapshot(entry.snapshot);
  }

  /// 디스크 캐시 TTL만 확인 (큰 JSON 파싱 없음).
  Future<bool> isHomeTrendingDiskCacheFresh() async {
    final cachedAt = await _localStorage.loadHomeTrendingFeedCacheCachedAt();
    return cachedAt != null && _isExploreCacheFresh(cachedAt);
  }

  /// 만료·잔여 payload 정리 — bootstrap과 병렬로 돌려도 됨.
  Future<void> clearExpiredHomeTrendingDiskCache() async {
    final cachedAt = await _localStorage.loadHomeTrendingFeedCacheCachedAt();
    if (cachedAt != null && _isExploreCacheFresh(cachedAt)) return;
    if (cachedAt != null ||
        await _localStorage.hasHomeTrendingFeedCachePayload()) {
      await _localStorage.clearHomeTrendingFeedCache();
    }
  }

  /// Restores home trending carousels without network when cache is still fresh.
  Future<HomeTrendingFeedSnapshot?> peekHomeTrendingFeedCache() async {
    final memory = _peekHomeTrendingFeedCacheMemory();
    if (memory != null) return memory;

    try {
      final cachedAt = await _localStorage.loadHomeTrendingFeedCacheCachedAt();
      if (cachedAt == null || !_isExploreCacheFresh(cachedAt)) {
        unawaited(clearExpiredHomeTrendingDiskCache());
        return null;
      }
      final snapshotMap = await _localStorage.loadHomeTrendingFeedCachePayload();
      if (snapshotMap == null) return null;
      final snapshot = _homeTrendingSnapshotFromJson(snapshotMap);
      if (snapshot == null) return null;
      final cloned = _cloneHomeTrendingFeedSnapshot(snapshot);
      _homeTrendingFeedCache = _HomeTrendingFeedCacheEntry(
        cachedAt: cachedAt,
        snapshot: cloned,
      );
      return _cloneHomeTrendingFeedSnapshot(cloned);
    } catch (_) {
      return null;
    }
  }

  void publishHomeTrendingFeedCache(HomeTrendingFeedSnapshot snapshot) {
    if (snapshot.allRecipes.isEmpty) return;
    final cloned = _cloneHomeTrendingFeedSnapshot(snapshot);
    final now = DateTime.now();
    _homeTrendingFeedCache = _HomeTrendingFeedCacheEntry(
      cachedAt: now,
      snapshot: cloned,
    );
    unawaited(_persistHomeTrendingFeedCacheToDisk(cloned, now));
  }

  Future<void> _persistHomeTrendingFeedCacheToDisk(
    HomeTrendingFeedSnapshot cloned,
    DateTime now,
  ) async {
    try {
      await _localStorage.saveHomeTrendingFeedCache(
        cachedAt: now,
        payload: _homeTrendingSnapshotToJson(cloned),
      );
    } catch (_) {
      // ignore disk write errors
    }
  }

  /// Pull-to-refresh 등 — explore/홈 트렌드 캐시를 비우고 Firestore를 다시 읽게 한다.
  void invalidateExploreCaches() {
    _exploreGuestsCacheByLimit.clear();
    _explorePageCacheByKey.clear();
    _seasonalIndexCacheByMonth.clear();
    _homeSectionIndexCacheByKey.clear();
    _chefIndexCacheByName.clear();
    _exploreRecipeDocById.clear();
    _homeTrendingFeedCache = null;
    _hotGroupsCache = null;
    _hotGroupsCachedAt = null;
    unawaited(_localStorage.clearHomeTrendingFeedCache());
  }

  /// 인기 키워드(recipe_groups) — 홈 재진입 시 1시간 동안 스트림 대신 캐시 사용.
  Future<List<Map<String, dynamic>>> getHotRecipeGroupsCached({
    int limit = 200,
  }) async {
    final cachedAt = _hotGroupsCachedAt;
    final cached = _hotGroupsCache;
    if (cached != null &&
        cachedAt != null &&
        _isExploreCacheFresh(cachedAt)) {
      return cached
          .map((g) => Map<String, dynamic>.from(g))
          .toList(growable: false);
    }
    final fresh = await fetchHotRecipeGroups(limit: limit);
    _hotGroupsCache = fresh
        .map((g) => Map<String, dynamic>.from(g))
        .toList(growable: false);
    _hotGroupsCachedAt = DateTime.now();
    return fresh;
  }

  List<Map<String, dynamic>> _cloneRecipeMaps(List<Map<String, dynamic>> list) {
    return list.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  List<Map<String, dynamic>>? _getExploreGuestsCached(int limit) {
    final entry = _exploreGuestsCacheByLimit[limit];
    if (entry == null) return null;
    if (!_isExploreCacheFresh(entry.cachedAt)) {
      _exploreGuestsCacheByLimit.remove(limit);
      return null;
    }
    return _cloneRecipeMaps(entry.recipes);
  }

  void _setExploreGuestsCache(int limit, List<Map<String, dynamic>> recipes) {
    _exploreGuestsCacheByLimit[limit] = _ExploreGuestsCacheEntry(
      cachedAt: DateTime.now(),
      recipes: _cloneRecipeMaps(recipes),
    );
  }

  ExploreRecipesPageResult? _getExplorePageCached({
    required DocumentSnapshot? startAfter,
    required int rawLimit,
    String prefix = '',
  }) {
    final key = _explorePageCacheKey(
      startAfter: startAfter,
      rawLimit: rawLimit,
      prefix: prefix,
    );
    final entry = _explorePageCacheByKey.get(key);
    if (entry == null) return null;
    if (!_isExploreCacheFresh(entry.cachedAt)) {
      _explorePageCacheByKey.remove(key);
      return null;
    }
    return ExploreRecipesPageResult(
      recipes: _cloneRecipeMaps(entry.recipes),
      lastRawDocument: entry.lastRawDocument,
      hasMore: entry.hasMore,
    );
  }

  void _setExplorePageCache({
    required DocumentSnapshot? startAfter,
    required int rawLimit,
    required ExploreRecipesPageResult result,
    String prefix = '',
  }) {
    final key = _explorePageCacheKey(
      startAfter: startAfter,
      rawLimit: rawLimit,
      prefix: prefix,
    );
    _explorePageCacheByKey.put(
      key,
      _ExplorePageCacheEntry(
        cachedAt: DateTime.now(),
        recipes: _cloneRecipeMaps(result.recipes),
        lastRawDocument: result.lastRawDocument,
        hasMore: result.hasMore,
      ),
    );
  }

  DateTime? _exploreParsedAt(Map<String, dynamic> recipe) {
    final completed = recipe['completedAt'];
    final created = recipe['createdAt'];
    if (completed is Timestamp) return completed.toDate();
    if (completed is DateTime) return completed;
    if (created is Timestamp) return created.toDate();
    if (created is DateTime) return created;
    return null;
  }

  void _sortExploreRecipesByParsedAtDesc(List<Map<String, dynamic>> recipes) {
    recipes.sort((a, b) {
      final aDate = _exploreParsedAt(a);
      final bDate = _exploreParsedAt(b);
      if (aDate != null && bDate != null) return bDate.compareTo(aDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      final aId = a['id']?.toString() ?? '';
      final bId = b['id']?.toString() ?? '';
      return bId.compareTo(aId);
    });
  }

  // Helper to recursively convert Firestore maps to Map<String, dynamic>
  dynamic _convertFirestoreData(dynamic data) {
    if (data == null) return null;

    if (data is Map) {
      final Map<String, dynamic> result = {};
      data.forEach((key, value) {
        result[key.toString()] = _convertFirestoreData(value);
      });
      return result;
    } else if (data is List) {
      return data.map((item) => _convertFirestoreData(item)).toList();
    }
    return data;
  }

  // Helper to safely convert to Map<String, dynamic>
  Map<String, dynamic> _toMapStringDynamic(dynamic data) {
    if (data == null) return {};
    final converted = _convertFirestoreData(data);
    if (converted is Map<String, dynamic>) {
      return converted;
    }
    return {};
  }

  // Convert Firestore-specific values (Timestamp/DateTime) into JSON-compatible values.
  dynamic _toJsonCompatible(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    if (value is Map) {
      return value.map(
        (key, v) => MapEntry(key.toString(), _toJsonCompatible(v)),
      );
    }
    if (value is List) {
      return value.map(_toJsonCompatible).toList();
    }
    return value;
  }

  // Get a single recipe by ID
  Future<models.ParseResponse?> getRecipeById(String recipeId) async {
    // Fast path: return from in-memory cache if available
    final cached = _parseResponseCache[recipeId];
    if (cached != null && !cached.isExpired) {
      return cached.response;
    }

    try {
      // Check if this is a local recipe (ID starts with "local_")
      if (recipeId.startsWith('local_')) {
        final localRecipe = await _localStorage.getLocalRecipe(recipeId);
        if (localRecipe == null) {
          print('Local recipe not found: $recipeId');
          return null;
        }

        // Convert local recipe data to ParseResponse
        final source = _toMapStringDynamic(localRecipe['source']);
        final recipe = _toMapStringDynamic(localRecipe['recipe']);
        final nutrition = _toMapStringDynamic(localRecipe['nutrition']);
        _hydrateSourceTaxonomyFromRecipeDoc(source, localRecipe);

        return models.ParseResponse.fromJson({
          'source': source,
          'recipe': recipe,
          'nutrition': nutrition,
          'debug': {},
          'averageRating': null,
          'reviewCount': null,
        });
      }

      // Firebase recipe - proceed with normal lookup
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      if (!doc.exists) {
        print('[RecipeService] Recipe not found in Firestore: $recipeId');
        return null;
      }

      final data = doc.data();
      if (data == null) {
        print('[RecipeService] Recipe data is null: $recipeId');
        return null;
      }

      if (isCancelledRecipeData(data)) {
        return null;
      }

      // 다른 사용자가 조회할 때는 완료된 레시피만 반환
      // 단, 사용자가 저장한 레시피(savedRecipes)는 status와 관계없이 조회 가능
      final status = data['status'] as String?;
      final user = _auth.currentUser;
      final recipeUserId = data['userId'] as String?;
      final isOwner = user != null && recipeUserId == user.uid;

      // 사용자가 저장한 레시피인지 확인
      bool isSavedByUser = false;
      if (user != null && !isOwner) {
        final userService = UserService();
        final savedRecipes = await userService.getSavedRecipes(user.uid);
        isSavedByUser = savedRecipes.contains(recipeId);
      }

      // 다른 사용자가 조회할 때는 완료된 레시피만 반환
      // status가 null인 경우는 오래된 레시피이므로 기본적으로 공개로 간주하여 허용
      // 단, status가 명시적으로 'pending' 또는 'failed'인 경우만 거부
      if (!isOwner && !isSavedByUser) {
        if (status != null && status != 'completed') {
          // status가 명시적으로 'pending' 또는 'failed'인 경우만 거부
          print('[RecipeService] Recipe access denied: $recipeId');
          print('  - Status: $status (expected: "completed" or null)');
          print('  - Is Owner: $isOwner');
          print('  - Is Saved: $isSavedByUser');
          print('  - Recipe UserId: $recipeUserId');
          print('  - Current UserId: ${user?.uid}');
          print('  - Recipe exists in Firestore: true');
          return null;
        }
        // status가 null이거나 'completed'인 경우 허용
        if (status == null) {
          print(
            '[RecipeService] Recipe $recipeId has null status, allowing access (treating as public)',
          );
        }
      }

      // Convert Firestore maps to Map<String, dynamic> recursively
      final source = _toMapStringDynamic(data['source']);
      final recipe = _toMapStringDynamic(data['recipe']);
      final nutrition = _toMapStringDynamic(data['nutrition']);

      // 네이버 블로그: 본문(재료/단계/영양)은 공용 recipes 에 저장하지 않는다.
      // 사용자 본인 디바이스 로컬에만 보관(§30 사적 복제). 따라서 본문은
      // LocalStorageService.getNaverBody 로 가져와 합친다. 본인이 직접 분석한
      // 적 없는 네이버 레시피는 본문이 비어 있고, WebView 와 메타 카드만 표시된다.
      final platform = (source['platform'] as String?) ?? '';
      if (platform == 'naver_blog') {
        try {
          final localBody = await _localStorage.getNaverBody(recipeId);
          if (localBody != null) {
            final localRecipe = _toMapStringDynamic(localBody['recipe']);
            final localNutrition = _toMapStringDynamic(localBody['nutrition']);
            for (final key in const [
              'ingredients',
              'steps',
              'equipment',
              'notes',
            ]) {
              if (localRecipe[key] != null) {
                recipe[key] = localRecipe[key];
              }
            }
            for (final key in const ['name', 'servings']) {
              if (localRecipe[key] != null) {
                recipe[key] = localRecipe[key];
              }
            }
            if (localNutrition.isNotEmpty) {
              nutrition.addAll(localNutrition);
            }
            // og:image 는 디테일 WebView poster + 디테일 hero 썸네일로만 사용.
            // Firestore 에는 저장하지 않으므로 본인 로컬에서 source 에 주입.
            final localOg =
                (localBody['ogImageUrl'] as String?)?.trim() ?? '';
            if (localOg.isNotEmpty) {
              source['og_image_url'] = localOg;
              source['thumbnail'] = localOg;
            }
          }
        } catch (e) {
          print('[RecipeService] Naver local body load failed: $e');
        }
      }

      // Detail hero: large thumbnail when available (lists use thumbnailUrl = card size)
      final largeThumb = (data['thumbnailUrlLarge'] as String?)?.trim();
      final cardThumb = (data['thumbnailUrl'] as String?)?.trim();
      if (largeThumb != null && largeThumb.isNotEmpty) {
        source['thumbnail'] = largeThumb;
      } else if (cardThumb != null && cardThumb.isNotEmpty) {
        source['thumbnail'] = cardThumb;
      }

      _hydrateSourceTaxonomyFromRecipeDoc(source, data);

      // Include average rating and review count from recipe doc (updated by ReviewService)
      final averageRating = data['averageRating'] as num?;
      final reviewCount = data['reviewCount'] as int?;

      // 사용자별 제목 별칭이 있으면 상세 화면 제목(recipe.name)에 덮어쓴다.
      // 원본 recipes/{id} 는 변경하지 않으므로 다른 사용자에겐 원본 제목이 보인다.
      // (장바구니/식단 등 recipe.name 을 쓰는 다운스트림도 별칭으로 일관 표시)
      await _ensureTitleAliasesLoaded();
      final titleAlias = _recipeTitleAliases[recipeId];
      if (titleAlias != null && titleAlias.isNotEmpty) {
        recipe['name'] = titleAlias;
      }

      // Create and return the ParseResponse
      final parseResponse = models.ParseResponse.fromJson({
        'source': source,
        'recipe': recipe,
        'nutrition': nutrition,
        'debug': {},
        if (averageRating != null) 'averageRating': averageRating.toDouble(),
        if (reviewCount != null) 'reviewCount': reviewCount,
      });

      _parseResponseCache[recipeId] = _ParseResponseCacheEntry(parseResponse);
      return parseResponse;
    } catch (e, stackTrace) {
      print('Error getting recipe: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  // Delete a recipe
  Future<void> deleteRecipe(String recipeId) async {
    // Check if this is a local recipe
    if (recipeId.startsWith('local_')) {
      await _localStorage.deleteLocalRecipe(recipeId);
      print('[RecipeService] Deleted local recipe: $recipeId');
      return;
    }

    // Firebase recipe - requires authentication
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to delete Firebase recipes');
    }

    // Remove recipe from all meal plans first
    final mealPlanService = MealPlanService();
    await mealPlanService.removeRecipeFromAllMealPlans(recipeId);

    // Remove from user's saved recipes (옛 배열 + 새 서브컬렉션 둘 다)
    await _firestore.collection('users').doc(user.uid).update({
      'savedRecipes': FieldValue.arrayRemove([recipeId]),
    });
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('savedRecipes')
          .doc(recipeId)
          .delete();
    } catch (e) {
      // 옛 데이터엔 서브컬렉션 doc 이 없을 수 있음 — 무시.
    }

    // Remove from cart
    final userService = UserService();
    await userService.removeCartItemsByRecipeId(user.uid, recipeId);

    // Delete recipe document if user owns it (userId matches) - so it disappears from list immediately
    final recipeDoc = await _firestore
        .collection('recipes')
        .doc(recipeId)
        .get();
    if (recipeDoc.exists) {
      final data = recipeDoc.data();
      final recipeUserId = data?['userId'] as String?;
      if (recipeUserId == user.uid) {
        await _firestore.collection('recipes').doc(recipeId).delete();
      }
    }
  }

  /// Admin/moderation: hide/unhide a recipe (soft moderation).
  Future<void> setRecipeHidden({
    required String recipeId,
    required bool hidden,
    required String reason,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw Exception('숨김 사유가 필요합니다');
    }

    try {
      final recipeRef = _firestore.collection('recipes').doc(recipeId);
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(recipeRef);
        if (!snapshot.exists) {
          throw Exception('레시피를 찾을 수 없습니다');
        }

        if (hidden) {
          transaction.update(recipeRef, {
            'isHidden': true,
            'hiddenAt': FieldValue.serverTimestamp(),
            'hiddenReason': trimmedReason,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          transaction.update(recipeRef, {
            'isHidden': false,
            'hiddenAt': FieldValue.delete(),
            'hiddenReason': FieldValue.delete(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      print('[RecipeService] Error setting recipe hidden: $e');
      rethrow;
    }
  }

  /// 별칭 캐시가 아직 로드되지 않았으면 `users/{uid}` 문서에서 1회 로드한다.
  /// (홈 목록을 거치지 않고 알림/딥링크로 상세에 바로 진입한 경우 대비)
  Future<void> _ensureTitleAliasesLoaded() async {
    if (_recipeTitleAliasesLoaded) return;
    final user = _auth.currentUser;
    if (user == null) {
      _recipeTitleAliasesLoaded = true;
      return;
    }
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      _applyUserTitleAliases(doc.data());
    } catch (_) {
      // best effort — 다음 목록 로드에서 다시 채워진다.
    }
  }

  /// 사용자가 지정한 레시피 제목 별칭을 반환한다. 없으면 null(원본 제목 사용).
  Future<String?> getRecipeTitleAlias(String recipeId) async {
    if (recipeId.isEmpty) return null;
    await _ensureTitleAliasesLoaded();
    final alias = _recipeTitleAliases[recipeId];
    return (alias != null && alias.isNotEmpty) ? alias : null;
  }

  /// 사용자별 레시피 제목 별칭을 저장/삭제한다(본인 문서에만 기록, 원본 미변경).
  /// [alias] 가 비어있으면 별칭을 제거하고 원본 제목으로 되돌린다.
  Future<void> setRecipeTitleAlias(String recipeId, String? alias) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }
    if (recipeId.isEmpty) return;
    final trimmed = (alias ?? '').trim();
    final ref = _firestore.collection('users').doc(user.uid);

    if (trimmed.isEmpty) {
      await ref.update({
        'recipeTitleAliases.$recipeId': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _recipeTitleAliases.remove(recipeId);
    } else {
      await ref.update({
        'recipeTitleAliases.$recipeId': trimmed,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _recipeTitleAliases[recipeId] = trimmed;
    }
    _recipeTitleAliasesLoaded = true;

    // 상세 화면 캐시 무효화(다음 getRecipeById 는 별칭 반영본을 재생성).
    _parseResponseCache.remove(recipeId);

    // 마지막 emit 목록의 카드 제목을 즉시 패치해 깜빡임을 줄인다.
    if (trimmed.isNotEmpty) {
      for (final r in _lastEmittedRecipes) {
        if ((r['id'] as String?) == recipeId) {
          r['title'] = trimmed;
        }
      }
    }

    // 레시피북 카드 즉시 새로고침(디스크 캐시 비우고 mini doc 재조회).
    await RecipeService.shared.reloadSavedRecipesFromNetwork();
  }

  // Update recipe categories (user-specific)
  Future<void> updateRecipeCategories(
    String recipeId,
    Map<String, List<String>> categories,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to update recipes');
    }

    // Store categories in user document (user-specific)
    await _firestore.collection('users').doc(user.uid).update({
      'recipeCategories.$recipeId': categories,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Get user-specific recipe categories
  Future<Map<String, List<String>>?> getUserRecipeCategories(
    String recipeId,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      return null;
    }

    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final recipeCategories = userData?['recipeCategories'];

      if (recipeCategories != null &&
          recipeCategories is Map &&
          recipeCategories.containsKey(recipeId)) {
        final categories = recipeCategories[recipeId];
        if (categories != null && categories is Map) {
          return (categories as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, List<String>.from(value as List)),
          );
        }
      }
      return null;
    } catch (e) {
      print('[RecipeService] Error fetching user recipe categories: $e');
      return null;
    }
  }

  /// Migrate existing recipes to upload thumbnails to Firebase Storage
  /// This ensures thumbnails are permanently stored and won't disappear
  /// Processes all recipes, not just the current user's
  Future<Map<String, int>> migrateThumbnailsToStorage({
    bool allRecipes = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null && !allRecipes) {
      throw Exception('User must be logged in to migrate thumbnails');
    }

    print(
      '[RecipeService] Starting thumbnail migration (allRecipes: $allRecipes)...',
    );

    // Get all recipes or just user's recipes
    QuerySnapshot recipesSnapshot;
    if (allRecipes) {
      // Get ALL recipes (requires proper Firestore rules)
      recipesSnapshot = await _firestore.collection('recipes').get();
    } else {
      // Get user's recipes
      recipesSnapshot = await _firestore
          .collection('recipes')
          .where('userId', isEqualTo: user!.uid)
          .get();
    }

    print(
      '[RecipeService] Found ${recipesSnapshot.docs.length} recipes to check',
    );

    int updatedCount = 0;
    int skippedCount = 0;
    int errorCount = 0;
    int recoveredCount = 0;

    for (final doc in recipesSnapshot.docs) {
      try {
        final data = doc.data() as Map<String, dynamic>?;
        if (data == null) {
          skippedCount++;
          continue;
        }
        final currentThumbnailUrl = data['thumbnailUrl'] as String? ?? '';
        final sourceMap = data['source'] is Map
            ? Map<String, dynamic>.from(
                (data['source'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              )
            : <String, dynamic>{};

        // Check if thumbnail already exists in Firebase Storage
        final existingStorageUrl = await _checkThumbnailInStorage(doc.id);
        if (existingStorageUrl != null) {
          final smallUrl = await _tryGetSmallRecipeThumbUrl(doc.id);
          final cardUrl = smallUrl ?? existingStorageUrl;
          final needsUpdate =
              currentThumbnailUrl != cardUrl ||
              (data['thumbnailUrlLarge'] as String?) != existingStorageUrl;
          if (needsUpdate) {
            try {
              final patch = <String, dynamic>{
                'thumbnailUrlLarge': existingStorageUrl,
                'thumbnailUrl': cardUrl,
                'updatedAt': FieldValue.serverTimestamp(),
              };
              final currentCropped =
                  (data['thumbnailUrlCropped'] as String?)?.trim() ?? '';
              if (currentCropped.isNotEmpty) {
                patch['thumbnailUrlCropped'] = currentCropped;
              }
              await _firestore.collection('recipes').doc(doc.id).update(patch);
              updatedCount++;
              print(
                '[RecipeService] Updated recipe ${doc.id} thumbnails (card=${smallUrl != null})',
              );
            } catch (e) {
              print(
                '[RecipeService] Failed to update Firestore for recipe ${doc.id}: $e',
              );
              errorCount++;
            }
          } else {
            skippedCount++;
          }
          continue;
        }

        // Skip if already using Firebase Storage URL (but file doesn't exist in Storage)
        if (currentThumbnailUrl.contains('firebasestorage')) {
          skippedCount++;
          continue;
        }

        // If no thumbnail, skip (don't re-parse - thumbnails should be saved when recipe is first created)
        // Re-parsing just for thumbnails is expensive and unnecessary
        if (currentThumbnailUrl.isEmpty) {
          skippedCount++;
          print(
            '[RecipeService] Skipping recipe ${doc.id} - no thumbnail and re-parsing is disabled',
          );
          continue;
        }

        // Try to upload existing thumbnail
        final uploadedPair = await _uploadThumbnailToStorage(
          thumbnailUrl: currentThumbnailUrl,
          recipeId: doc.id,
          sourceUrl:
              (data['sourceUrl'] as String?) ?? (sourceMap['url'] as String?),
          platform: sourceMap['platform'] as String?,
        );

        if (uploadedPair != null) {
          final patch = <String, dynamic>{
            'thumbnailUrlLarge': uploadedPair.largeUrl,
            'thumbnailUrl': uploadedPair.cardUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          };
          if (uploadedPair.croppedUrl != null &&
              uploadedPair.croppedUrl!.isNotEmpty) {
            patch['thumbnailUrlCropped'] = uploadedPair.croppedUrl;
          }
          await _firestore.collection('recipes').doc(doc.id).update(patch);
          updatedCount++;
          print('[RecipeService] Migrated thumbnail for recipe ${doc.id}');
        } else {
          // Upload failed (e.g., 403 error), skip recovery to avoid expensive re-parsing
          // Thumbnails should be saved when recipe is first created
          errorCount++;
          print(
            '[RecipeService] Failed to upload thumbnail for recipe ${doc.id} - skipping recovery to avoid re-parsing',
          );
        }
      } catch (e) {
        errorCount++;
        print(
          '[RecipeService] Error migrating thumbnail for recipe ${doc.id}: $e',
        );
      }
    }

    print(
      '[RecipeService] Thumbnail migration complete: $updatedCount updated, $recoveredCount recovered, $skippedCount skipped, $errorCount errors',
    );
    return <String, int>{
      'updated': updatedCount,
      'recovered': recoveredCount,
      'skipped': skippedCount,
      'errors': errorCount,
    };
  }

  /// Re-download missing thumbnails from source URLs and upload to Firebase Storage
  /// This function re-parses recipes with missing thumbnails to get fresh thumbnail URLs
  Future<Map<String, int>> recoverMissingThumbnails() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to recover thumbnails');
    }

    print('[RecipeService] Starting thumbnail recovery...');

    // Get all user's recipes
    final recipesSnapshot = await _firestore
        .collection('recipes')
        .where('userId', isEqualTo: user.uid)
        .get();

    print(
      '[RecipeService] Found ${recipesSnapshot.docs.length} recipes to check',
    );

    int recoveredCount = 0;
    int skippedCount = 0;
    int errorCount = 0;

    for (final doc in recipesSnapshot.docs) {
      try {
        final data = doc.data();
        final currentThumbnailUrl = data['thumbnailUrl'] as String? ?? '';
        final sourceMap = data['source'] is Map
            ? Map<String, dynamic>.from(
                (data['source'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              )
            : <String, dynamic>{};

        // Skip if already using Firebase Storage URL
        if (currentThumbnailUrl.contains('firebasestorage')) {
          skippedCount++;
          continue;
        }

        // If thumbnail is missing or broken, try to re-parse from source
        bool needsRecovery = currentThumbnailUrl.isEmpty;

        // If thumbnail exists but is not from Firebase Storage, try to upload it first
        if (!needsRecovery &&
            !currentThumbnailUrl.contains('firebasestorage')) {
          try {
            // Try to upload existing thumbnail
            final uploadedPair = await _uploadThumbnailToStorage(
              thumbnailUrl: currentThumbnailUrl,
              recipeId: doc.id,
              sourceUrl:
                  (data['sourceUrl'] as String?) ??
                  (sourceMap['url'] as String?),
              platform: sourceMap['platform'] as String?,
            );
            if (uploadedPair != null) {
              final patch = <String, dynamic>{
                'thumbnailUrlLarge': uploadedPair.largeUrl,
                'thumbnailUrl': uploadedPair.cardUrl,
                'updatedAt': FieldValue.serverTimestamp(),
              };
              if (uploadedPair.croppedUrl != null &&
                  uploadedPair.croppedUrl!.isNotEmpty) {
                patch['thumbnailUrlCropped'] = uploadedPair.croppedUrl;
              }
              await _firestore.collection('recipes').doc(doc.id).update(patch);
              recoveredCount++;
              print('[RecipeService] Recovered thumbnail for recipe ${doc.id}');
              continue;
            }
          } catch (e) {
            // If upload fails, try to re-parse
            needsRecovery = true;
          }
        }

        // DISABLED: Re-parsing to recover thumbnails
        // Re-parsing is expensive and causes unnecessary API calls
        // Thumbnails should be saved when recipe is first created
        if (needsRecovery) {
          skippedCount++;
          print(
            '[RecipeService] Skipping recipe ${doc.id} - thumbnail recovery via re-parsing is disabled',
          );
          // Original re-parsing code commented out to prevent automatic API calls
          /*
          try {
            print(
              '[RecipeService] Re-parsing recipe ${doc.id} to recover thumbnail',
            );

            // Re-parse the recipe using the API
            final parseResponse = await ApiService.parseRecipe(
              url: sourceUrl,
              preferLang: 'ko',
            );

            // Convert to ParseResponse model
            final parsedRecipe = models.ParseResponse.fromJson(parseResponse);
            final newThumbnailUrl = parsedRecipe.source['thumbnail'] ?? '';

            if (newThumbnailUrl.isNotEmpty) {
              // Upload new thumbnail to Firebase Storage
              final uploadedUrl = await _uploadThumbnailToStorage(
                thumbnailUrl: newThumbnailUrl,
                recipeId: doc.id,
              );

              if (uploadedUrl != null) {
                await _firestore.collection('recipes').doc(doc.id).update({
                  'thumbnailUrl': uploadedUrl,
                  'updatedAt': FieldValue.serverTimestamp(),
                });
                recoveredCount++;
                print(
                  '[RecipeService] Recovered thumbnail for recipe ${doc.id} from source',
                );
              } else {
                errorCount++;
                print(
                  '[RecipeService] Failed to upload recovered thumbnail for recipe ${doc.id}',
                );
              }
            } else {
              skippedCount++;
              print(
                '[RecipeService] No thumbnail found in source for recipe ${doc.id}',
              );
            }
          } catch (e) {
            errorCount++;
            print(
              '[RecipeService] Error recovering thumbnail for recipe ${doc.id}: $e',
            );
          }
          */
        }
      } catch (e) {
        errorCount++;
        print(
          '[RecipeService] Error processing recipe ${doc.id} for thumbnail recovery: $e',
        );
      }
    }

    print(
      '[RecipeService] Thumbnail recovery complete: $recoveredCount recovered, $skippedCount skipped, $errorCount errors',
    );
    return {
      'recovered': recoveredCount,
      'skipped': skippedCount,
      'errors': errorCount,
    };
  }

  /// Migrate existing recipes to include uploader_thumbnail field
  /// This ensures all recipes have the field set (even if empty) for UI consistency
  /// The UI will automatically show platform icons as fallback if thumbnail is empty
  Future<int> migrateRecipesForProfilePictures() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to migrate recipes');
    }

    print('[RecipeService] Starting migration for profile pictures...');

    // Get all user's recipes
    final recipesSnapshot = await _firestore
        .collection('recipes')
        .where('userId', isEqualTo: user.uid)
        .get();

    print(
      '[RecipeService] Found ${recipesSnapshot.docs.length} recipes to check',
    );

    int updatedCount = 0;
    int skippedCount = 0;

    for (final doc in recipesSnapshot.docs) {
      try {
        final data = doc.data();
        final source = _toMapStringDynamic(data['source'] ?? {});

        // Check if uploader_thumbnail field is missing
        if (!source.containsKey('uploader_thumbnail')) {
          // Add empty uploader_thumbnail field to ensure UI consistency
          await _firestore.collection('recipes').doc(doc.id).update({
            'source.uploader_thumbnail': '',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          updatedCount++;
          print(
            '[RecipeService] Updated recipe ${doc.id} - added uploader_thumbnail field',
          );
        } else {
          skippedCount++;
        }
      } catch (e) {
        print('[RecipeService] Error migrating recipe ${doc.id}: $e');
      }
    }

    print(
      '[RecipeService] Migration complete: $updatedCount updated, $skippedCount skipped',
    );
    return updatedCount;
  }

  // Get recipes that can be re-parsed (have sourceUrl and are owned by current user)
  Future<List<Map<String, dynamic>>> getReparsableRecipes() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in');
    }

    // Get all recipes owned by current user
    final recipesSnapshot = await _firestore
        .collection('recipes')
        .where('userId', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .get();

    // Filter recipes that have sourceUrl
    final reparsableRecipes = <Map<String, dynamic>>[];
    for (var doc in recipesSnapshot.docs) {
      final data = doc.data();
      final sourceUrl = data['sourceUrl'] as String?;
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        final convertedData = Map<String, dynamic>.from(data);
        reparsableRecipes.add({'id': doc.id, ...convertedData});
      }
    }

    return reparsableRecipes;
  }

  // Re-parse selected recipes with new parsing logic (for testing)
  // This will re-parse recipes that have a sourceUrl using the updated parsing logic
  Future<Map<String, int>> reparseSelectedRecipes(
    List<String> recipeIds,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to re-parse recipes');
    }

    print(
      '[RecipeService] Starting recipe re-parsing for ${recipeIds.length} recipes...',
    );

    int reparseCount = 0;
    int skippedCount = 0;
    int errorCount = 0;
    int updatedCount = 0;

    for (var recipeId in recipeIds) {
      try {
        final recipeDoc = await _firestore
            .collection('recipes')
            .doc(recipeId)
            .get();
        if (!recipeDoc.exists) {
          skippedCount++;
          print('[RecipeService] Recipe $recipeId does not exist');
          continue;
        }

        final data = recipeDoc.data()!;
        final sourceUrl = data['sourceUrl'] as String?;

        // Skip recipes without sourceUrl (can't re-parse them)
        if (sourceUrl == null || sourceUrl.isEmpty) {
          skippedCount++;
          print('[RecipeService] Skipping recipe $recipeId - no sourceUrl');
          continue;
        }

        // Check if current user owns this recipe (required for update)
        final recipeUserId = data['userId'] as String?;
        if (user.uid != recipeUserId) {
          skippedCount++;
          print(
            '[RecipeService] Cannot update recipe $recipeId - not owned by current user',
          );
          continue;
        }

        print('[RecipeService] Re-parsing recipe $recipeId from $sourceUrl');

        // Re-parse the recipe using the API
        try {
          final parseResponse = await ApiService.parseRecipe(
            url: sourceUrl,
            preferLang: 'ko',
          );

          // Convert to ParseResponse model
          final parsedRecipe = models.ParseResponse.fromJson(parseResponse);
          reparseCount++;

          // Update the recipe with new parsed data
          final recipe = parsedRecipe.recipe;
          final nutrition = parsedRecipe.nutrition;

          // Update recipe document
          await recipeDoc.reference.update({
            'recipe': {
              'name': recipe.name,
              'servings': recipe.servings,
              'ingredients': recipe.ingredients
                  .map((ing) => ing.toRecipeStorageMap())
                  .toList(),
              'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
              'equipment': recipe.equipment,
              'notes': recipe.notes,
            },
            'nutrition': {
              'per_serving': nutrition.perServing,
              'assumptions': nutrition.assumptions,
              'llm_estimate': nutrition.llmEstimate != null
                  ? {
                      'calories_per_serving':
                          nutrition.llmEstimate!.caloriesPerServing,
                      'protein_g': nutrition.llmEstimate!.proteinG,
                      'fat_g': nutrition.llmEstimate!.fatG,
                      'carbs_g': nutrition.llmEstimate!.carbsG,
                      'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                      'sugar_g': nutrition.llmEstimate!.sugarG,
                      'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                      'fiber_g': nutrition.llmEstimate!.fiberG,
                    }
                  : null,
            },
            'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
            'source':
                parsedRecipe.source, // Update source with new categories/tags
            'categories': parsedRecipe.source['categories'] ?? {},
            'tags': parsedRecipe.source['tags'] ?? [],
            ...recipeDisplayMetaWriteFields(parsedRecipe.source),
            'nutrition_rating': parsedRecipe.source['nutrition_rating'] ?? 'A',
            'updatedAt': FieldValue.serverTimestamp(),
          });

          // Upload thumbnail if available
          final thumbnailUrl = parsedRecipe.source['thumbnail'] ?? '';
          if (thumbnailUrl.isNotEmpty) {
            try {
              final uploadedPair = await _uploadThumbnailToStorage(
                thumbnailUrl: thumbnailUrl,
                recipeId: recipeId,
                sourceUrl: parsedRecipe.source['url'] as String?,
                platform: parsedRecipe.source['platform'] as String?,
              );
              if (uploadedPair != null) {
                final patch = <String, dynamic>{
                  'thumbnailUrlLarge': uploadedPair.largeUrl,
                  'thumbnailUrl': uploadedPair.cardUrl,
                };
                if (uploadedPair.croppedUrl != null &&
                    uploadedPair.croppedUrl!.isNotEmpty) {
                  patch['thumbnailUrlCropped'] = uploadedPair.croppedUrl;
                }
                await recipeDoc.reference.update(patch);
                print(
                  '[RecipeService] Uploaded thumbnail for recipe $recipeId',
                );
              }
            } catch (e) {
              print(
                '[RecipeService] Error uploading thumbnail for recipe $recipeId: $e',
              );
            }
          }

          updatedCount++;
          print('[RecipeService] Updated recipe $recipeId');
        } catch (e) {
          print('[RecipeService] Error re-parsing recipe $recipeId: $e');
          errorCount++;
        }
      } catch (e) {
        print('[RecipeService] Error processing recipe $recipeId: $e');
        errorCount++;
      }
    }

    print(
      '[RecipeService] Re-parsing complete: $reparseCount re-parsed, $updatedCount updated, $skippedCount skipped, $errorCount errors',
    );
    return {
      'reparsed': reparseCount,
      'updated': updatedCount,
      'skipped': skippedCount,
      'errors': errorCount,
    };
  }

  // Migrate existing recipes to add save tracking fields
  // This should be called once to update all existing recipes
  // Note: We can't count existing saves due to security rules, so we initialize to 0
  // Save counts will be tracked going forward as users save recipes
  Future<void> migrateExistingRecipes() async {
    try {
      print('Starting recipe migration...');

      // Get all recipes (this is allowed by security rules - anyone can read recipes)
      final recipesSnapshot = await _firestore.collection('recipes').get();
      print('Found ${recipesSnapshot.docs.length} recipes to migrate');

      // Update each recipe
      int updatedCount = 0;
      int skippedCount = 0;
      int errorCount = 0;

      for (var recipeDoc in recipesSnapshot.docs) {
        final recipeId = recipeDoc.id;
        final data = recipeDoc.data();

        // Check if recipe already has save tracking fields
        final hasSaveCount = data.containsKey('saveCount');
        final hasWeeklySaves = data.containsKey('weeklySaves');
        final hasMonthlySaves = data.containsKey('monthlySaves');
        final hasLastSavedAt = data.containsKey('lastSavedAt');
        final hasViewCount = data.containsKey('viewCount');
        final hasLastViewedAt = data.containsKey('lastViewedAt');

        // Skip if all fields already exist
        if (hasSaveCount &&
            hasWeeklySaves &&
            hasMonthlySaves &&
            hasLastSavedAt &&
            hasViewCount &&
            hasLastViewedAt) {
          skippedCount++;
          continue;
        }

        // Check if current user owns this recipe (required for update)
        final user = _auth.currentUser;
        final recipeUserId = data['userId'] as String?;

        // Only update recipes owned by current user (due to security rules)
        // For other recipes, we can't update them without admin permissions
        if (user == null || recipeUserId != user.uid) {
          // Skip recipes not owned by current user
          // These will need to be updated by their owners or via admin
          continue;
        }

        // Prepare update data - initialize to 0
        // Save counts will be tracked going forward as users save recipes
        final updateData = <String, dynamic>{};

        if (!hasSaveCount) {
          updateData['saveCount'] = 0;
        }
        if (!hasWeeklySaves) {
          updateData['weeklySaves'] = 0;
        }
        if (!hasMonthlySaves) {
          updateData['monthlySaves'] = 0;
        }
        if (!hasLastSavedAt) {
          updateData['lastSavedAt'] = null;
        }
        if (!hasViewCount) {
          updateData['viewCount'] = 0;
        }
        if (!hasLastViewedAt) {
          updateData['lastViewedAt'] = null;
        }

        // Update recipe (only if user owns it)
        if (updateData.isNotEmpty) {
          try {
            await recipeDoc.reference.update(updateData);
            updatedCount++;
          } catch (e) {
            print('Error updating recipe $recipeId: $e');
            errorCount++;
          }
        }
      }

      print('Migration complete!');
      print('Updated: $updatedCount recipes (owned by current user)');
      print('Skipped: $skippedCount recipes (already had fields)');
      if (errorCount > 0) {
        print('Errors: $errorCount recipes');
      }
      print(
        'Note: Recipes owned by other users will be updated when their owners use the app',
      );
    } catch (e, stackTrace) {
      print('Error migrating recipes: $e');
      print('Stack trace: $stackTrace');
      // Don't rethrow - just log the error and continue
      // This allows the app to continue working even if migration fails
    }
  }

  // ===== LOCAL STORAGE METHODS =====

  /// Get all locally stored recipes (for unauthenticated users). Returns [] on error so UI always loads.
  Future<List<Map<String, dynamic>>> getLocalRecipes() async {
    try {
      return await _localStorage.getLocalRecipes();
    } catch (_) {
      return [];
    }
  }

  /// Get count of local recipes
  Future<int> getLocalRecipeCount() async {
    return await _localStorage.getLocalRecipeCount();
  }

  /// Delete a local recipe
  Future<void> deleteLocalRecipe(String recipeId) async {
    await _localStorage.deleteLocalRecipe(recipeId);
  }

  /// Migrate local recipes to Firebase when user logs in
  /// Returns number of recipes migrated
  Future<int> migrateLocalRecipesToFirebase() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to migrate recipes');
    }

    print('[RecipeService] Starting migration of local recipes to Firebase...');

    final migrationMap = await _localStorage.migrateToFirebase(
      saveToFirebase: (parseResponse, sourceUrl) async {
        // Use internal Firebase save method
        return await _saveToFirebase(parseResponse, sourceUrl);
      },
    );

    print(
      '[RecipeService] Migration complete: ${migrationMap.length} recipes migrated',
    );
    return migrationMap.length;
  }

  /// Internal method to save directly to Firebase (bypasses local storage)
  /// Returns null if recipe already exists (duplicate)
  Future<String?> _saveToFirebase(
    models.ParseResponse parseResponse,
    String? sourceUrl,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in');
    }

    final canonical = sourceUrl != null && sourceUrl.isNotEmpty
        ? buildCanonicalSourceInfo(sourceUrl)
        : null;
    final canonicalUrl = canonical?.normalizedUrl;
    final sourceKey = canonical?.sourceKey;

    // Check if user already has this recipe (by sourceUrl)
    if (canonicalUrl != null && canonicalUrl.isNotEmpty) {
      final existingRecipeId = await getUserRecipeIdBySourceUrl(canonicalUrl);
      if (existingRecipeId != null) {
        print(
          '[RecipeService] Recipe with sourceUrl already exists, skipping: $canonicalUrl',
        );
        return null; // Recipe already exists, skip migration
      }
    }

    final recipe = parseResponse.recipe;
    final nutrition = parseResponse.nutrition;

    // Create recipe document
    final recipeData = {
      'userId': user.uid,
      'title': recipe.name ?? parseResponse.source['title'] ?? '레시피',
      'sourceUrl': canonicalUrl ?? sourceUrl,
      'sourceKey': sourceKey,
      'thumbnailUrl': parseResponse.source['thumbnail'] ?? '',
      'source': parseResponse.source,
      'categories': parseResponse.source['categories'] ?? {},
      'tags': parseResponse.source['tags'] ?? [],
      ...recipeDisplayMetaWriteFields(parseResponse.source),
      'nutrition_rating': parseResponse.source['nutrition_rating'] ?? 'A',
      'recipe': {
        'name': recipe.name,
        'servings': recipe.servings,
        'ingredients': recipe.ingredients
            .map((ing) => ing.toRecipeStorageMap())
            .toList(),
        'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
        'equipment': recipe.equipment,
        'notes': recipe.notes,
      },
      'nutrition': {
        'per_serving': nutrition.perServing,
        'assumptions': nutrition.assumptions,
        'llm_estimate': nutrition.llmEstimate != null
            ? {
                'calories_per_serving':
                    nutrition.llmEstimate!.caloriesPerServing,
                'protein_g': nutrition.llmEstimate!.proteinG,
                'fat_g': nutrition.llmEstimate!.fatG,
                'carbs_g': nutrition.llmEstimate!.carbsG,
                'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                'sugar_g': nutrition.llmEstimate!.sugarG,
                'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                'fiber_g': nutrition.llmEstimate!.fiberG,
              }
            : null,
      },
      'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
      'usedOcr': parseResponse.debug['used_ocr'] == true,
      'purchaseOccasionCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'saveCount': 0,
      'weeklySaves': 0,
      'monthlySaves': 0,
      'lastSavedAt': null,
      'viewCount': 0,
      'lastViewedAt': null,
    };

    // Add recipe to recipes collection
    final docRef = _firestore.collection('recipes').doc();
    recipeData['saveCount'] = RecipeSocialCounts.seedSaveCount(docRef.id);
    await docRef.set(recipeData);

    // Upload thumbnail to Firebase Storage if available
    final originalThumbnailUrl = parseResponse.source['thumbnail'] ?? '';
    if (originalThumbnailUrl.isNotEmpty) {
      try {
        final sourceMap = parseResponse.source;
        final uploadedPair = await _uploadThumbnailToStorage(
          thumbnailUrl: originalThumbnailUrl,
          recipeId: docRef.id,
          sourceUrl: sourceMap['url'] as String?,
          platform: sourceMap['platform'] as String?,
        );
        if (uploadedPair != null) {
          final patch = <String, dynamic>{
            'thumbnailUrlLarge': uploadedPair.largeUrl,
            'thumbnailUrl': uploadedPair.cardUrl,
          };
          if (uploadedPair.croppedUrl != null &&
              uploadedPair.croppedUrl!.isNotEmpty) {
            patch['thumbnailUrlCropped'] = uploadedPair.croppedUrl;
          }
          await docRef.update(patch);
        }
      } catch (e) {
        print(
          '[RecipeService] Error uploading thumbnail in _saveToFirebase: $e',
        );
        // Continue even if thumbnail upload fails
      }
    }

    // Add recipe ID to user's saved recipes
    await _firestore.collection('users').doc(user.uid).update({
      'savedRecipes': FieldValue.arrayUnion([docRef.id]),
    });

    // Hybrid denormalization: 서브컬렉션에도 카드용 미니 데이터 복사.
    await _writeSavedRecipeMiniDoc(user.uid, docRef.id, recipeData);

    await _trackRecipeSave(docRef.id);

    return docRef.id;
  }

  // ────────────────────────────────────────────────────────────────────
  // Manual paste (content-based) dedup + post-save similar-recipes hook
  // ────────────────────────────────────────────────────────────────────

  /// 글/사진 input 파싱 결과의 content sha256-based sourceKey 로
  /// **status == "completed"** 인 기존 레시피를 찾는다. 실패한 파싱은
  /// 동일 콘텐츠를 다시 시도할 수 있어야 하므로 의도적으로 제외한다.
  Future<Map<String, dynamic>?> fetchCompletedRecipeBySourceKey(
    String sourceKey,
  ) async {
    final key = sourceKey.trim();
    if (key.isEmpty) return null;
    try {
      final snap = await _firestore
          .collection('recipes')
          .where('sourceKey', isEqualTo: key)
          .where('status', isEqualTo: 'completed')
          .where('isHidden', isEqualTo: false)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return null;
      final doc = snap.docs.first;
      final data = Map<String, dynamic>.from(doc.data());
      data['id'] = doc.id;
      return data;
    } catch (e) {
      debugPrint('[RecipeService] fetchCompletedRecipeBySourceKey failed: $e');
      return null;
    }
  }

  /// 방금 저장한 manual 레시피와 동일한 `canonicalDish` seed 를 가진
  /// 다른 완료된 레시피 최대 [limit] 개를 반환한다. 결과는 가벼운 home-card용
  /// Map 형태로 [HomeStyleRecipeCard.fromRecipeMap] 이 그대로 소비할 수 있다.
  Future<List<Map<String, dynamic>>> fetchSimilarRecipesByCanonicalDish(
    String seed, {
    int limit = 3,
    String? excludeRecipeId,
  }) async {
    final key = seed.trim();
    if (key.isEmpty) return const <Map<String, dynamic>>[];

    Future<List<Map<String, dynamic>>> queryByField(
      String field,
      String value,
    ) async {
      final snap = await _firestore
          .collection('recipes')
          .where(field, isEqualTo: value)
          .where('status', isEqualTo: 'completed')
          .where('isHidden', isEqualTo: false)
          .limit(limit + 2)
          .get();
      final List<Map<String, dynamic>> results = [];
      for (final doc in snap.docs) {
        if (excludeRecipeId != null && doc.id == excludeRecipeId) continue;
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        results.add(data);
        if (results.length >= limit) break;
      }
      return results;
    }

    // `recipe_groups`와 공개 레시피 목록의 실제 결합 키는 groupKey다.
    // 과거 구현은 표시명(canonicalDish)을 직접 비교해 두 정규화기가 조금만
    // 달라도 0건이 됐다. 현재 groupKey를 우선하고, 아직 groupKey가 없는
    // 레거시 문서만 기존 canonicalDish 쿼리로 보완한다.
    var groupKey = key;
    if (groupKey.length > 24) groupKey = groupKey.substring(0, 24);
    groupKey = groupKey
        .replaceAll(RegExp(r'[/\.#\[\]*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    try {
      final grouped = await queryByField('groupKey', groupKey);
      if (grouped.isNotEmpty) return grouped;
    } catch (e) {
      debugPrint('[RecipeService] similar recipes groupKey query failed: $e');
    }

    try {
      return await queryByField('canonicalDish', key);
    } catch (e) {
      debugPrint('[RecipeService] fetchSimilarRecipesByCanonicalDish failed: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// `ingredient_recipe_index` 로 같은 주재료를 쓰는 공개 레시피를 가져온다.
  Future<List<Map<String, dynamic>>> fetchRecipesByIngredientIndex(
    String ingredientName, {
    int limit = 8,
    String? excludeRecipeId,
  }) async {
    final docId = IngredientIndexKey.docIdFromName(ingredientName);
    if (docId.isEmpty || limit <= 0) return const <Map<String, dynamic>>[];
    try {
      final snap = await _firestore
          .collection('ingredient_recipe_index')
          .doc(docId)
          .get();
      if (!snap.exists) return const <Map<String, dynamic>>[];
      final rawIds = snap.data()?['recipeIds'];
      if (rawIds is! List) return const <Map<String, dynamic>>[];
      final ids = <String>[];
      final seen = <String>{};
      if (excludeRecipeId != null && excludeRecipeId.isNotEmpty) {
        seen.add(excludeRecipeId);
      }
      for (final raw in rawIds) {
        final id = raw?.toString().trim() ?? '';
        if (id.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        ids.add(id);
        if (ids.length >= limit) break;
      }
      if (ids.isEmpty) return const <Map<String, dynamic>>[];
      return getExploreRecipesByIds(ids, limit: limit);
    } catch (e) {
      debugPrint('[RecipeService] fetchRecipesByIngredientIndex failed: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// `categories.{field}` array-contains 로 같은 요리 계열을 가져온다.
  /// 클라 list 규칙(`isHidden != true`)에 맞게 isHidden==false 를 쿼리에 넣는다.
  Future<List<Map<String, dynamic>>> fetchRecipesByCategoryValue({
    required String categoryField,
    required String value,
    int limit = 8,
    String? excludeRecipeId,
  }) async {
    final field = categoryField.trim();
    final key = value.trim();
    if (field.isEmpty || key.isEmpty || limit <= 0) {
      return const <Map<String, dynamic>>[];
    }

    final exclude = <String>{
      if (excludeRecipeId != null && excludeRecipeId.isNotEmpty) excludeRecipeId,
    };

    Future<List<Map<String, dynamic>>> queryField(String path) async {
      final snap = await _firestore
          .collection('recipes')
          .where('isHidden', isEqualTo: false)
          .where('status', isEqualTo: 'completed')
          .where(path, arrayContains: key)
          .limit(limit + 4)
          .get();
      final results = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        if (exclude.contains(doc.id)) continue;
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        results.add(data);
        if (results.length >= limit) break;
      }
      return results;
    }

    try {
      // 적으면 빈/짧은 레일로 둔다. 인기 30으로 채우면 리드만 늘고
      // 반찬/음료 칸이 엉뚱한 인기 카드로 채워진다.
      return await queryField('categories.$field');
    } catch (e) {
      debugPrint('[RecipeService] category query $field=$key failed: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// 온보딩 나라 레일용. `categories.country` 우선, 없으면 `cuisine_type`.
  Future<List<Map<String, dynamic>>> fetchRecipesByCountryLabel({
    required String country,
    int limit = 30,
  }) async {
    final label = country.trim();
    if (label.isEmpty || limit <= 0) {
      return const <Map<String, dynamic>>[];
    }

    final seen = <String>{};
    final out = <Map<String, dynamic>>[];

    Future<void> addFrom(String field) async {
      if (out.length >= limit) return;
      try {
        final batch = await fetchRecipesByCategoryValue(
          categoryField: field,
          value: label,
          limit: limit,
        );
        for (final recipe in batch) {
          final id = recipe['id']?.toString() ?? '';
          if (id.isEmpty || !seen.add(id)) continue;
          out.add(recipe);
          if (out.length >= limit) return;
        }
      } catch (e) {
        debugPrint(
          '[RecipeService] country query $field=$label failed: $e',
        );
      }
    }

    await addFrom('country');
    if (out.length < limit) {
      await addFrom('cuisine_type');
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _popularRecipesMatchingCategory({
    required String categoryField,
    required String value,
    required int limit,
    required Set<String> excludeIds,
  }) async {
    final popular = await getAllTimePopularRecipes(limit: 30);
    final matched = <Map<String, dynamic>>[];
    for (final recipe in popular) {
      final id = recipeIdOf(recipe);
      if (id.isEmpty || excludeIds.contains(id)) continue;
      if (!_recipeHasCategoryValue(recipe, categoryField, value)) continue;
      matched.add(recipe);
      if (matched.length >= limit) break;
    }
    return matched;
  }

  bool _recipeHasCategoryValue(
    Map<String, dynamic> recipe,
    String field,
    String value,
  ) {
    final buckets = <dynamic>[
      recipe['categories'],
      if (recipe['source'] is Map)
        (recipe['source'] as Map)['categories'],
    ];
    for (final raw in buckets) {
      if (raw is! Map) continue;
      final list = raw[field];
      if (list is! List) continue;
      for (final item in list) {
        if (item?.toString().trim() == value) return true;
      }
    }
    return false;
  }

  /// 주간 저장 수 우선, 부족하면 올타임 인기로 채운다.
  Future<List<Map<String, dynamic>>> fetchPopularRelatedRecipes({
    int limit = 8,
    String? excludeRecipeId,
  }) async {
    if (limit <= 0) return const <Map<String, dynamic>>[];
    final exclude = <String>{
      if (excludeRecipeId != null && excludeRecipeId.isNotEmpty) excludeRecipeId,
    };
    var recipes = excludeRecipeIds(
      await getWeeklyPopularRecipes(limit: limit + 4),
      exclude,
    );
    if (recipes.length < 3) {
      final extra = excludeRecipeIds(
        await getAllTimePopularRecipes(limit: limit + 4),
        {...exclude, ...recipes.map(recipeIdOf)},
      );
      recipes = [...recipes, ...extra];
    }
    if (recipes.length > limit) {
      return recipes.take(limit).toList();
    }
    return recipes;
  }

  static const String _kSimilarRecipesSheetDismissedKey =
      'dismiss_similar_recipes_popup_v1';

  Future<bool> isSimilarRecipesSheetDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kSimilarRecipesSheetDismissedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setSimilarRecipesSheetDismissed(bool dismissed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSimilarRecipesSheetDismissedKey, dismissed);
    } catch (e) {
      debugPrint('[RecipeService] setSimilarRecipesSheetDismissed failed: $e');
    }
  }
}

class _ParseResponseCacheEntry {
  final models.ParseResponse response;
  final DateTime cachedAt;
  _ParseResponseCacheEntry(this.response) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > RecipeService._parseResponseCacheTtl;
}
