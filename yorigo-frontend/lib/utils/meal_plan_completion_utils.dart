import 'package:cloud_firestore/cloud_firestore.dart';

/// 기본 끼니 순서.
const List<String> defaultMealOrder = ['breakfast', 'lunch', 'dinner'];

/// 슬롯 ID (`breakfast_0` 등)를 만든다.
String buildMealPlanSlotId(String mealTime, int slotIndex) =>
    '${mealTime}_$slotIndex';

/// 슬롯 ID를 mealTime + index로 파싱한다. 실패 시 null.
({String mealTime, int slotIndex})? parseMealPlanSlotId(
  String slotId, {
  List<String> mealOrder = defaultMealOrder,
}) {
  final trimmed = slotId.trim();
  if (trimmed.isEmpty) return null;
  for (final mealTime in mealOrder) {
    final prefix = '${mealTime}_';
    if (!trimmed.startsWith(prefix)) continue;
    final idx = int.tryParse(trimmed.substring(prefix.length));
    if (idx == null || idx < 0) return null;
    return (mealTime: mealTime, slotIndex: idx);
  }
  return null;
}

/// mealPlans 문서에서 완료된 슬롯 ID 집합을 해석한다 (legacy 포함).
Set<String> completedSlotIdsFromPlan(
  Map<String, dynamic> plan, {
  List<String> mealOrder = defaultMealOrder,
}) {
  final completed = <String>{};
  final slotAtRaw = plan['completedSlotAt'];
  if (slotAtRaw is Map) {
    for (final key in slotAtRaw.keys) {
      final slotId = key.toString().trim();
      if (slotId.isNotEmpty) completed.add(slotId);
    }
  }

  for (final slotId in (plan['completedSlots'] as List? ?? [])) {
    final trimmed = slotId.toString().trim();
    if (trimmed.isNotEmpty) completed.add(trimmed);
  }

  final legacy = (plan['completedRecipes'] as List? ?? [])
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (legacy.isEmpty) return completed;

  final meals = plan['meals'] as Map<String, dynamic>? ?? {};
  for (final mealTime in mealOrder) {
    final list = (meals[mealTime] as List?) ?? [];
    for (var i = 0; i < list.length; i++) {
      final recipeId = list[i]?.toString().trim() ?? '';
      if (recipeId.isNotEmpty && legacy.contains(recipeId)) {
        completed.add(buildMealPlanSlotId(mealTime, i));
      }
    }
  }
  return completed;
}

/// [recipeId]와 일치하는 미완료 슬롯 ID 목록.
List<String> findUncompletedSlotIdsForRecipe({
  required Map<String, dynamic> plan,
  required String recipeId,
  List<String> mealOrder = defaultMealOrder,
}) {
  final recipeIdStr = recipeId.trim();
  if (recipeIdStr.isEmpty) return const [];

  final completed = completedSlotIdsFromPlan(plan, mealOrder: mealOrder);
  final meals = plan['meals'] as Map<String, dynamic>? ?? {};
  final slots = <String>[];

  for (final mealTime in mealOrder) {
    final list =
        (meals[mealTime] as List?)?.map((e) => e.toString().trim()).toList() ??
        [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] != recipeIdStr) continue;
      final slotId = buildMealPlanSlotId(mealTime, i);
      if (!completed.contains(slotId)) slots.add(slotId);
    }
  }
  return slots;
}

/// 요리 시작 표시 가능한 첫 슬롯 ID (started/completed 제외).
String? findFirstStartableSlotIdForRecipe({
  required Map<String, dynamic> plan,
  required String recipeId,
  List<String> mealOrder = defaultMealOrder,
}) {
  final recipeIdStr = recipeId.trim();
  if (recipeIdStr.isEmpty) return null;

  final completed = completedSlotIdsFromPlan(plan, mealOrder: mealOrder);
  final started = (plan['startedSlots'] as List? ?? [])
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toSet();
  final meals = plan['meals'] as Map<String, dynamic>? ?? {};

  for (final mealTime in mealOrder) {
    final list =
        (meals[mealTime] as List?)?.map((e) => e.toString().trim()).toList() ??
        [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] != recipeIdStr) continue;
      final slotId = buildMealPlanSlotId(mealTime, i);
      if (started.contains(slotId) || completed.contains(slotId)) continue;
      return slotId;
    }
  }
  return null;
}

/// 슬롯에 해당 recipeId가 있는지 검증한다.
bool mealPlanSlotMatchesRecipe({
  required Map<String, dynamic> plan,
  required String mealTime,
  required int slotIndex,
  required String recipeId,
}) {
  final meals = plan['meals'] as Map<String, dynamic>? ?? {};
  final list = (meals[mealTime] as List?) ?? [];
  if (slotIndex < 0 || slotIndex >= list.length) return false;
  return list[slotIndex]?.toString().trim() == recipeId.trim();
}

/// memo 식단 ID 여부.
bool isMemoMealId(String recipeId) => recipeId.trim().startsWith('memo_');

/// 추천 가능한 첫 meal id (memo 제외).
String? firstRecommendableMealId(List<dynamic> list) {
  for (final raw in list) {
    final id = raw.toString().trim();
    if (id.isEmpty || isMemoMealId(id)) continue;
    return id;
  }
  return null;
}

/// 식단 슬롯(`breakfast_0` 등) 완료 상태.
class MealPlanSlotStatus {
  const MealPlanSlotStatus({
    required this.completed,
    this.completedAt,
  });

  final bool completed;
  final DateTime? completedAt;
}

/// mealPlans 문서에서 슬롯 완료 여부·완료 시각을 해석한다.
MealPlanSlotStatus resolveMealPlanSlotStatus({
  required Map<String, dynamic> plan,
  required String mealTime,
  required int slotIndex,
  List<String> mealOrder = const ['breakfast', 'lunch', 'dinner'],
}) {
  final slotId = '${mealTime}_$slotIndex';
  final slotAtRaw = plan['completedSlotAt'];
  if (slotAtRaw is Map) {
    final completedAt = _toDateTime(slotAtRaw[slotId]);
    if (completedAt != null) {
      return MealPlanSlotStatus(completed: true, completedAt: completedAt);
    }
  }

  final completedSlots = (plan['completedSlots'] as List? ?? [])
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (completedSlots.contains(slotId)) {
    return const MealPlanSlotStatus(completed: true);
  }

  final legacy = (plan['completedRecipes'] as List? ?? [])
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (legacy.isEmpty) {
    return const MealPlanSlotStatus(completed: false);
  }

  final meals = plan['meals'] as Map<String, dynamic>? ?? {};
  final list = (meals[mealTime] as List?) ?? [];
  if (slotIndex < 0 || slotIndex >= list.length) {
    return const MealPlanSlotStatus(completed: false);
  }
  final recipeId = list[slotIndex]?.toString().trim() ?? '';
  if (recipeId.isNotEmpty && legacy.contains(recipeId)) {
    return const MealPlanSlotStatus(completed: true);
  }

  return const MealPlanSlotStatus(completed: false);
}

/// UI용 완료 라벨 (예: `3/10 요리 완료`, `오늘 요리 완료`).
String? formatMealCompletedLabel(DateTime? completedAt) {
  if (completedAt == null) return '요리 완료';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(
    completedAt.year,
    completedAt.month,
    completedAt.day,
  );
  if (day == today) return '오늘 요리 완료';
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == yesterday) return '어제 요리 완료';
  return '${completedAt.month}/${completedAt.day} 요리 완료';
}

DateTime? _toDateTime(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

/// 식단 삭제 후 `completedSlotAt` / `completedSlots` 키를 재정렬한다.
Map<String, dynamic> reindexCompletedSlotAtAfterRemoval({
  required Map<String, dynamic> completedSlotAt,
  required String mealTime,
  required int removedIndex,
}) {
  final next = <String, dynamic>{};
  for (final entry in completedSlotAt.entries) {
    final key = entry.key.toString();
    if (!key.startsWith('${mealTime}_')) {
      next[key] = entry.value;
      continue;
    }
    final idx = int.tryParse(key.substring(mealTime.length + 1));
    if (idx == null) continue;
    if (idx == removedIndex) continue;
    if (idx > removedIndex) {
      next['${mealTime}_${idx - 1}'] = entry.value;
    } else {
      next[key] = entry.value;
    }
  }
  return next;
}
