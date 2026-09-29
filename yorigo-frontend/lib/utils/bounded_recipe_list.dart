/// in-memory 레시피 목록 상한 — id 중복 없이 append 후 앞쪽 trim.
void appendUniqueRecipeMapsWithCap({
  required List<Map<String, dynamic>> list,
  required List<Map<String, dynamic>> batch,
  required int maxItems,
}) {
  final ids = list
      .map((r) => r['id'] as String?)
      .whereType<String>()
      .toSet();
  for (final recipe in batch) {
    final id = recipe['id'] as String? ?? '';
    if (id.isEmpty || ids.contains(id)) continue;
    ids.add(id);
    list.add(recipe);
  }
  trimListFromFront(list, maxItems);
}

/// [list] 길이가 [maxItems]를 넘으면 앞쪽을 제거한다. 제거한 개수를 반환.
int trimListFromFront<T>(List<T> list, int maxItems) {
  if (maxItems < 0) return 0;
  final overflow = list.length - maxItems;
  if (overflow <= 0) return 0;
  list.removeRange(0, overflow);
  return overflow;
}
