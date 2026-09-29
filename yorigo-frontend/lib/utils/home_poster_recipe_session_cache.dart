/// 홈 포스터 큐레이션 화면용 칩별 레시피 세션 캐시.
///
/// 화면 State 가 파괴돼도 프로세스 생존 동안 유지되어, 재진입 시 스켈레톤
/// 재로딩을 피한다. TTL 만료 시 자동 무효화.
class HomePosterRecipeSessionCache {
  HomePosterRecipeSessionCache({
    this.ttl = const Duration(minutes: 30),
  });

  /// 앱 전역 기본 인스턴스 (포스터 화면이 공유).
  static final HomePosterRecipeSessionCache instance =
      HomePosterRecipeSessionCache();

  final Duration ttl;
  final Map<String, _HomePosterChipCacheEntry> _entries =
      <String, _HomePosterChipCacheEntry>{};

  int get length => _entries.length;

  List<Map<String, dynamic>>? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.cachedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.recipes;
  }

  void set(String key, List<Map<String, dynamic>> recipes) {
    _entries[key] = _HomePosterChipCacheEntry(
      List<Map<String, dynamic>>.unmodifiable(recipes),
    );
  }

  void clear() => _entries.clear();

  /// 테스트용: 임의 시각으로 엔트리 삽입.
  void debugSetWithCachedAt(
    String key,
    List<Map<String, dynamic>> recipes,
    DateTime cachedAt,
  ) {
    _entries[key] = _HomePosterChipCacheEntry(
      List<Map<String, dynamic>>.unmodifiable(recipes),
      cachedAt: cachedAt,
    );
  }
}

class _HomePosterChipCacheEntry {
  _HomePosterChipCacheEntry(
    this.recipes, {
    DateTime? cachedAt,
  }) : cachedAt = cachedAt ?? DateTime.now();

  final List<Map<String, dynamic>> recipes;
  final DateTime cachedAt;
}
