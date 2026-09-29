/// 홈 트렌드 섹션 인덱스 ID에서 다음에 fetch할 구간을 계산한다.
///
/// Firestore 접근 없이 오프셋만 다루므로 단위 테스트로 검증한다.
class SectionRecipeFetchWindow {
  SectionRecipeFetchWindow._();

  /// [indexedIds] 의 [fetchedCount] 이후에서 최대 [extra] 개를 반환.
  /// 더 이상 없으면 빈 리스트.
  static List<String> nextIds({
    required List<String> indexedIds,
    required int fetchedCount,
    required int extra,
  }) {
    if (extra <= 0 || indexedIds.isEmpty) return const <String>[];
    final start = fetchedCount < 0 ? 0 : fetchedCount;
    if (start >= indexedIds.length) return const <String>[];
    final end = (start + extra).clamp(0, indexedIds.length);
    if (end <= start) return const <String>[];
    return indexedIds.sublist(start, end);
  }

  /// 인덱스 ID를 모두 소진했는지.
  static bool isExhausted({
    required int fetchedCount,
    required int totalIds,
  }) {
    if (totalIds <= 0) return true;
    return fetchedCount >= totalIds;
  }
}
