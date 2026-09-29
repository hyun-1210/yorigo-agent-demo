import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/meal_plan_completion_utils.dart';
import 'analytics_service.dart';
import 'rewards_service.dart';
import 'user_service.dart';

class MealPlanService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserService _userService = UserService();
  static const List<String> _mealTimes = ['breakfast', 'lunch', 'dinner'];

  // Save a meal plan for a specific date and meal time
  Future<void> addMealToDate({
    required DateTime date,
    required String mealTime, // 'breakfast', 'lunch', 'dinner'
    required String recipeId,
    required String recipeTitle,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to add meals');
    }

    // Format date as YYYY-MM-DD for consistent storage
    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    // Get or create meal plan document for this date
    final mealPlanRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey);

    final mealPlanDoc = await mealPlanRef.get();
    var newlyAdded = false;

    if (mealPlanDoc.exists) {
      // Update existing meal plan
      final data = mealPlanDoc.data() ?? {};
      final meals = Map<String, dynamic>.from(data['meals'] ?? {});

      // Get existing meals for this meal time
      final mealTimeMeals = List<String>.from(meals[mealTime] ?? []);

      // Add recipe if not already present
      if (!mealTimeMeals.contains(recipeId)) {
        mealTimeMeals.add(recipeId);
        newlyAdded = true;
      }

      meals[mealTime] = mealTimeMeals;

      await mealPlanRef.update({
        'dateKey': dateKey,
        'meals': meals,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } else {
      newlyAdded = true;
      // Create new meal plan
      await mealPlanRef.set({
        'date': Timestamp.fromDate(date),
        'dateKey': dateKey,
        'meals': {
          mealTime: [recipeId],
        },
        'recipeTitles': {recipeId: recipeTitle},
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    // Also update recipe titles map
    await mealPlanRef.update({'recipeTitles.$recipeId': recipeTitle});
    if (newlyAdded) {
      unawaited(
        AnalyticsService().trackMealPlanAdded(
          recipeId: recipeId,
          mealTime: mealTime,
          recipeTitle: recipeTitle,
        ),
      );
      unawaited(
        RewardsService.instance.claim(
          'exp_meal_calendar_used',
          idempotencyKey: 'exp_meal_calendar_used:$dateKey:$mealTime:$recipeId',
          sourceRef: recipeId,
        ),
      );
    }
  }

  // Get meal plan for a specific date
  Future<Map<String, dynamic>?> getMealPlanForDate(DateTime date) async {
    final user = _auth.currentUser;
    if (user == null) {
      return null;
    }

    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final mealPlanDoc = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey)
        .get();

    if (!mealPlanDoc.exists) {
      return null;
    }

    return mealPlanDoc.data();
  }

  /// 특정 날짜·슬롯을 요리 완료 처리한다.
  Future<void> markMealSlotCompleted({
    required DateTime date,
    required String mealTime,
    required int slotIndex,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final dateKey = _dateKeyFromDateTime(date);
    final slotId = buildMealPlanSlotId(mealTime, slotIndex);

    final mealPlanRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey);

    final mealPlanDoc = await mealPlanRef.get();
    if (!mealPlanDoc.exists) return;

    final data = mealPlanDoc.data() ?? {};
    final completed = completedSlotIdsFromPlan(data, mealOrder: _mealTimes);
    if (completed.contains(slotId)) return;

    final meals = data['meals'] as Map<String, dynamic>? ?? {};
    final list = (meals[mealTime] as List?) ?? [];
    if (slotIndex < 0 || slotIndex >= list.length) return;
    final recipeId = list[slotIndex]?.toString().trim() ?? '';

    await mealPlanRef.update({
      'updatedAt': FieldValue.serverTimestamp(),
      'completedSlots': FieldValue.arrayUnion([slotId]),
      'completedSlotAt.$slotId': FieldValue.serverTimestamp(),
    });
    if (recipeId.isNotEmpty) {
      unawaited(
        AnalyticsService().trackMealPlanCompleted(
          recipeId: recipeId,
          mealTime: mealTime,
        ),
      );
    }
  }

  /// 특정 날짜·슬롯을 요리 시작 처리한다.
  Future<void> markMealSlotStarted({
    required DateTime date,
    required String mealTime,
    required int slotIndex,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final dateKey = _dateKeyFromDateTime(date);
    final slotId = buildMealPlanSlotId(mealTime, slotIndex);

    final mealPlanRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey);

    final mealPlanDoc = await mealPlanRef.get();
    if (!mealPlanDoc.exists) return;

    final data = mealPlanDoc.data() ?? {};
    final completed = completedSlotIdsFromPlan(data, mealOrder: _mealTimes);
    if (completed.contains(slotId)) return;

    final startedSlots = (data['startedSlots'] as List? ?? [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (startedSlots.contains(slotId)) return;

    final meals = data['meals'] as Map<String, dynamic>? ?? {};
    final list = (meals[mealTime] as List?) ?? [];
    if (slotIndex < 0 || slotIndex >= list.length) return;

    startedSlots.add(slotId);
    await mealPlanRef.update({
      'startedSlots': startedSlots,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 오늘 식단에서 [recipeId]가 들어 있는 슬롯을 요리 완료 처리한다.
  ///
  /// `completedSlotAt.{slotId}` 에 완료 시각을 저장하고, Cloud Functions 호환을 위해
  /// `completedSlots` 도 함께 갱신한다. 다른 날짜 mealPlan 은 변경하지 않는다.
  Future<void> markRecipeCompletedForToday(String recipeId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final recipeIdStr = recipeId.toString().trim();
    if (recipeIdStr.isEmpty) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final plan = await getMealPlanForDate(today);
    if (plan == null) return;

    final slotsToMark = findUncompletedSlotIdsForRecipe(
      plan: plan,
      recipeId: recipeIdStr,
      mealOrder: _mealTimes,
    );
    if (slotsToMark.isEmpty) return;

    final dateKey = _dateKeyFromDateTime(today);
    final mealPlanRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey);

    final update = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
      'completedSlots': FieldValue.arrayUnion(slotsToMark),
    };
    for (final slotId in slotsToMark) {
      update['completedSlotAt.$slotId'] = FieldValue.serverTimestamp();
    }
    await mealPlanRef.update(update);
    for (final slotId in slotsToMark) {
      final parsed = parseMealPlanSlotId(slotId, mealOrder: _mealTimes);
      if (parsed == null) continue;
      unawaited(
        AnalyticsService().trackMealPlanCompleted(
          recipeId: recipeIdStr,
          mealTime: parsed.mealTime,
        ),
      );
    }
  }

  /// Mark one slot in today's meal plan as cooking-started.
  /// Only marks slots that are planned and not already started/completed.
  Future<void> markRecipeStartedForToday(String recipeId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final recipeIdStr = recipeId.toString().trim();
    if (recipeIdStr.isEmpty) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final plan = await getMealPlanForDate(today);
    if (plan == null) return;

    final slotId = findFirstStartableSlotIdForRecipe(
      plan: plan,
      recipeId: recipeIdStr,
      mealOrder: _mealTimes,
    );
    if (slotId == null) return;

    final parsed = parseMealPlanSlotId(slotId, mealOrder: _mealTimes);
    if (parsed == null) return;

    await markMealSlotStarted(
      date: today,
      mealTime: parsed.mealTime,
      slotIndex: parsed.slotIndex,
    );
  }

  /// YYYY-MM-DD 형식 dateKey를 만든다.
  String _dateKeyFromDateTime(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// [startDate]~[endDate] 사이(포함)의 dateKey 목록.
  List<String> _dateKeysBetween(DateTime startDate, DateTime endDate) {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    final keys = <String>[];
    for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      keys.add(_dateKeyFromDateTime(d));
    }
    return keys;
  }

  List<List<T>> _chunkList<T>(List<T> list, int chunkSize) {
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += chunkSize) {
      final end = i + chunkSize > list.length ? list.length : i + chunkSize;
      chunks.add(list.sublist(i, end));
    }
    return chunks;
  }

  Map<String, Map<String, dynamic>> _mealPlansFromSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final mealPlans = <String, Map<String, dynamic>>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final dateKey = data['dateKey'] as String? ?? doc.id;
      mealPlans[dateKey] = data;
    }
    return mealPlans;
  }

  /// whereIn 청크 스트림을 하나로 합친다.
  Stream<Map<String, Map<String, dynamic>>> _mergeMealPlanChunkStreams(
    CollectionReference<Map<String, dynamic>> collection,
    List<List<String>> chunks,
  ) {
    late final StreamController<Map<String, Map<String, dynamic>>> controller;
    final latest = List<Map<String, Map<String, dynamic>>?>.filled(
      chunks.length,
      null,
    );
    final subscriptions =
        <StreamSubscription<Map<String, Map<String, dynamic>>>>[];

    void tryEmit() {
      if (latest.any((chunk) => chunk == null)) return;
      final merged = <String, Map<String, dynamic>>{};
      for (final chunk in latest) {
        merged.addAll(chunk!);
      }
      controller.add(merged);
    }

    controller = StreamController<Map<String, Map<String, dynamic>>>(
      onListen: () {
        for (var i = 0; i < chunks.length; i++) {
          final index = i;
          final sub = collection
              .where(FieldPath.documentId, whereIn: chunks[index])
              .snapshots()
              .map(_mealPlansFromSnapshot)
              .listen(
                (data) {
                  latest[index] = data;
                  tryEmit();
                },
                onError: controller.addError,
              );
          subscriptions.add(sub);
        }
      },
      onCancel: () async {
        for (final sub in subscriptions) {
          await sub.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  // Get all meal plans for a date range
  Stream<Map<String, Map<String, dynamic>>> getMealPlansForDateRange(
    DateTime startDate,
    DateTime endDate,
  ) {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.value({});
    }

    final dateKeys = _dateKeysBetween(startDate, endDate);
    if (dateKeys.isEmpty) {
      return Stream.value({});
    }

    final collection = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans');

    // dateKey 범위 쿼리(where >=, <=)는 색인 없이 failed-precondition이 난다.
    // 문서 ID가 dateKey이므로 whereIn으로 필요한 날짜만 구독한다(최대 30개/쿼리).
    const whereInLimit = 30;
    if (dateKeys.length <= whereInLimit) {
      return collection
          .where(FieldPath.documentId, whereIn: dateKeys)
          .snapshots()
          .map(_mealPlansFromSnapshot);
    }

    return _mergeMealPlanChunkStreams(
      collection,
      _chunkList(dateKeys, whereInLimit),
    );
  }

  Future<void> removeMealFromDate({
    required DateTime date,
    required String mealTime,
    required String recipeId,
    required int slotIndex,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to remove meals');
    }

    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final mealPlanRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .doc(dateKey);

    final mealPlanDoc = await mealPlanRef.get();

    if (mealPlanDoc.exists) {
      final data = mealPlanDoc.data() ?? {};
      final meals = Map<String, dynamic>.from(data['meals'] ?? {});
      final mealTimeMeals = List<String>.from(meals[mealTime] ?? []);

      if (slotIndex < 0 || slotIndex >= mealTimeMeals.length) {
        throw Exception('삭제할 식단 항목을 찾을 수 없습니다');
      }
      if (mealTimeMeals[slotIndex] != recipeId) {
        throw Exception('삭제할 식단 항목이 일치하지 않습니다');
      }

      mealTimeMeals.removeAt(slotIndex);
      meals[mealTime] = mealTimeMeals;

      final rawCompletedSlotAt = data['completedSlotAt'];
      final completedSlotAt = rawCompletedSlotAt is Map
          ? Map<String, dynamic>.from(rawCompletedSlotAt)
          : <String, dynamic>{};
      final nextCompletedSlotAt = reindexCompletedSlotAtAfterRemoval(
        completedSlotAt: completedSlotAt,
        mealTime: mealTime,
        removedIndex: slotIndex,
      );

      final legacyCompleted = List<String>.from(data['completedRecipes'] ?? [])
        ..remove(recipeId);

      final hasAnyMeals = meals.values.any(
        (mealList) => mealList is List && mealList.isNotEmpty,
      );

      if (hasAnyMeals) {
        await mealPlanRef.update({
          'meals': meals,
          'completedSlotAt': nextCompletedSlotAt,
          'completedSlots': nextCompletedSlotAt.keys.toList(),
          'completedRecipes': legacyCompleted,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        await mealPlanRef.delete();
      }
      unawaited(
        AnalyticsService().trackMealPlanRemoved(
          recipeId: recipeId,
          mealTime: mealTime,
        ),
      );
    }
  }

  // Remove a recipe from all meal plans (used when recipe is deleted)
  Future<void> removeRecipeFromAllMealPlans(String recipeId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception(
        'User must be logged in to remove recipes from meal plans',
      );
    }

    // Get all meal plans for this user
    final mealPlansSnapshot = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('mealPlans')
        .get();

    // Process each meal plan
    final batch = _firestore.batch();
    final List<String> emptyMealPlanIds = [];
    bool hasBatchOperations = false;

    for (var doc in mealPlansSnapshot.docs) {
      final data = doc.data();
      final meals = Map<String, dynamic>.from(data['meals'] ?? {});
      bool recipeFound = false;

      // Remove recipe from all meal times
      for (var mealTime in ['breakfast', 'lunch', 'dinner']) {
        final mealTimeMeals = List<String>.from(meals[mealTime] ?? []);
        if (mealTimeMeals.contains(recipeId)) {
          mealTimeMeals.remove(recipeId);
          meals[mealTime] = mealTimeMeals;
          recipeFound = true;
        }
      }

      // If recipe was found in this meal plan, update or delete it
      if (recipeFound) {
        // Check if all meals are now empty
        final hasAnyMeals = meals.values.any(
          (mealList) => mealList is List && mealList.isNotEmpty,
        );

        if (hasAnyMeals) {
          // Update meal plan: remove recipe from meals and recipeTitles
          final updateData = <String, dynamic>{
            'meals': meals,
            'updatedAt': FieldValue.serverTimestamp(),
          };

          // Remove recipe from recipeTitles if it exists
          final recipeTitles = Map<String, dynamic>.from(
            data['recipeTitles'] ?? {},
          );
          if (recipeTitles.containsKey(recipeId)) {
            recipeTitles.remove(recipeId);
            updateData['recipeTitles'] = recipeTitles;
          }

          batch.update(doc.reference, updateData);
          hasBatchOperations = true;
        } else {
          // All meals are empty, mark for deletion
          emptyMealPlanIds.add(doc.id);
        }
      }
    }

    // Commit batch updates if there are any
    if (hasBatchOperations) {
      await batch.commit();
    }

    // Delete empty meal plans
    for (var mealPlanId in emptyMealPlanIds) {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('mealPlans')
          .doc(mealPlanId)
          .delete();
    }

    // Also remove all cart items related to this recipe
    await _userService.removeCartItemsByRecipeId(user.uid, recipeId);
  }
}
