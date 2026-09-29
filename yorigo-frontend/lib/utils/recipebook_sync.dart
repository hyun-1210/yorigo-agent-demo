/// 레시피북 카테고리 클라우드 동기화 규칙.
///
/// Firestore 가 로그인 유저의 원본이고, 기기는 캐시다.
/// 기본 카테고리만 있는 문서는 "의미 있는 원격 데이터"로 보지 않는다.
/// (새 기기가 「자주 해먹는」만 심어 옛 기기 정리를 덮어쓰는 것을 막기 위함)
enum RecipebookSyncAction {
  /// 클라우드 값을 로컬 캐시에 반영한다.
  applyRemote,

  /// 로컬 값을 클라우드에 올린다. (마이그레이션·오프라인 편집)
  persistLocal,

  /// 양쪽 다 비어 있을 때만 기본 카테고리를 만들고 클라우드에 심는다.
  seedDefaults,
}

class RecipebookSync {
  RecipebookSync._();

  /// 커스텀 폴더 또는 레시피 배정이 있으면 의미 있는 데이터로 본다.
  /// 기본 카테고리(「자주 해먹는」)만 있고 맵이 비어 있으면 false.
  static bool hasMeaningfulData({
    required List<Map<String, dynamic>> categories,
    required Map<String, List<String>> recipeCategoryMap,
  }) {
    if (recipeCategoryMap.isNotEmpty) return true;
    return categories.any((c) => c['isDefault'] != true);
  }

  /// [localUpdatedAt]이 [remoteUpdatedAt]보다 같거나 더 최근이면 true.
  /// 한쪽이 없으면 비교 불가로 false.
  static bool localIsNotOlder({
    required DateTime? localUpdatedAt,
    required DateTime? remoteUpdatedAt,
  }) {
    if (localUpdatedAt == null || remoteUpdatedAt == null) return false;
    return !localUpdatedAt.isBefore(remoteUpdatedAt);
  }

  /// 로그인/앱 시작 시 로컬 vs 클라우드를 어떻게 맞출지 결정한다.
  static RecipebookSyncAction decide({
    required bool remoteHasMeaningfulData,
    required bool localHasMeaningfulData,
    required bool localDirty,
    DateTime? localUpdatedAt,
    DateTime? remoteUpdatedAt,
  }) {
    if (localDirty) {
      if (!remoteHasMeaningfulData) {
        return RecipebookSyncAction.persistLocal;
      }
      if (localIsNotOlder(
        localUpdatedAt: localUpdatedAt,
        remoteUpdatedAt: remoteUpdatedAt,
      )) {
        return RecipebookSyncAction.persistLocal;
      }
      // 클라우드가 더 최신이면 이 기기 미전송 편집은 버린다 (last-write-wins).
      return RecipebookSyncAction.applyRemote;
    }
    if (remoteHasMeaningfulData) {
      return RecipebookSyncAction.applyRemote;
    }
    if (localHasMeaningfulData) {
      return RecipebookSyncAction.persistLocal;
    }
    return RecipebookSyncAction.seedDefaults;
  }

  /// 레시피 ID 가 임시 → 정식으로 바뀔 때 분류 키를 옮긴다.
  /// [fromId]에 배정이 없으면 원본 맵을 그대로 돌려준다.
  static Map<String, List<String>> remapRecipeId({
    required Map<String, List<String>> mapping,
    required String fromId,
    required String toId,
  }) {
    final from = fromId.trim();
    final to = toId.trim();
    if (from.isEmpty || to.isEmpty || from == to) {
      return mapping;
    }
    final fromIds = mapping[from];
    if (fromIds == null || fromIds.isEmpty) {
      return mapping;
    }
    final result = <String, List<String>>{
      for (final e in mapping.entries)
        if (e.key != from) e.key: List<String>.from(e.value),
    };
    final merged = <String>{
      ...?result[to],
      ...fromIds.map((e) => e.trim()).where((e) => e.isNotEmpty),
    }.toList();
    if (merged.isNotEmpty) {
      result[to] = merged;
    } else {
      result.remove(to);
    }
    return result;
  }
}
