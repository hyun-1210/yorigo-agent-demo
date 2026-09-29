// Client-side personalized meal planner for the meal calendar.
// Priority: fridge → highly rated reviews → saved book.
// Only fills empty slots; never overwrites existing meals.

class AutoMealPlanCandidate {
  const AutoMealPlanCandidate({
    required this.recipeId,
    required this.recipeTitle,
    required this.source,
    required this.score,
  });

  final String recipeId;
  final String recipeTitle;
  /// `fridge` | `review` | `saved`
  final String source;
  final double score;
}

class AutoMealPlanSuggestion {
  const AutoMealPlanSuggestion({
    required this.date,
    required this.mealTime,
    required this.recipeId,
    required this.recipeTitle,
    required this.source,
  });

  final DateTime date;
  final String mealTime;
  final String recipeId;
  final String recipeTitle;
  final String source;

  String get sourceLabel {
    switch (source) {
      case 'fridge':
        return '냉장고';
      case 'review':
        return '자주 먹은 메뉴';
      case 'saved':
        return '레시피북';
      default:
        return '추천';
    }
  }
}

class AutoMealPlanService {
  static const List<String> mealOrder = ['breakfast', 'lunch', 'dinner'];

  /// Build suggestions for [days] starting at [startDate] (inclusive).
  ///
  /// [mealTimes] defaults to lunch+dinner when the pool is large enough,
  /// otherwise dinner-only.
  List<AutoMealPlanSuggestion> generate({
    required DateTime startDate,
    required int days,
    required Map<String, Map<String, dynamic>> existingPlans,
    required List<Map<String, dynamic>> fridgeRecipes,
    required List<Map<String, dynamic>> savedRecipes,
    required List<Map<String, dynamic>> reviews,
    List<String>? mealTimes,
  }) {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final recentUsage = _recentRecipeUsage(existingPlans, start);
    final candidates = _buildCandidates(
      fridgeRecipes: fridgeRecipes,
      savedRecipes: savedRecipes,
      reviews: reviews,
      recentUsage: recentUsage,
    );
    if (candidates.isEmpty) return const [];

    final slots = _resolveMealTimes(mealTimes, candidates.length, days);
    final usedInBatch = <String>{};
    final suggestions = <AutoMealPlanSuggestion>[];

    for (var d = 0; d < days; d++) {
      final date = start.add(Duration(days: d));
      final dateKey = _dateKey(date);
      final plan = existingPlans[dateKey];
      final meals = Map<String, dynamic>.from(plan?['meals'] as Map? ?? {});

      for (final mealTime in slots) {
        final existing = List<String>.from(meals[mealTime] as List? ?? const []);
        if (existing.isNotEmpty) continue;

        final pick = _pickCandidate(
          candidates: candidates,
          usedInBatch: usedInBatch,
          recentUsage: recentUsage,
        );
        if (pick == null) return suggestions;

        usedInBatch.add(pick.recipeId);
        recentUsage[pick.recipeId] = (recentUsage[pick.recipeId] ?? 0) + 1;
        suggestions.add(
          AutoMealPlanSuggestion(
            date: date,
            mealTime: mealTime,
            recipeId: pick.recipeId,
            recipeTitle: pick.recipeTitle,
            source: pick.source,
          ),
        );
      }
    }

    return suggestions;
  }

  List<String> _resolveMealTimes(
    List<String>? requested,
    int poolSize,
    int days,
  ) {
    if (requested != null && requested.isNotEmpty) {
      return requested
          .where(mealOrder.contains)
          .toList()
        ..sort((a, b) => mealOrder.indexOf(a).compareTo(mealOrder.indexOf(b)));
    }
    final capacity = poolSize;
    final needForFull = days * 3;
    final needForTwo = days * 2;
    if (capacity >= needForFull) {
      return List<String>.from(mealOrder);
    }
    if (capacity >= needForTwo) {
      return const ['lunch', 'dinner'];
    }
    return const ['dinner'];
  }

  List<AutoMealPlanCandidate> _buildCandidates({
    required List<Map<String, dynamic>> fridgeRecipes,
    required List<Map<String, dynamic>> savedRecipes,
    required List<Map<String, dynamic>> reviews,
    required Map<String, int> recentUsage,
  }) {
    final byId = <String, AutoMealPlanCandidate>{};

    void upsert({
      required String recipeId,
      required String title,
      required String source,
      required double baseScore,
    }) {
      final id = recipeId.trim();
      final name = title.trim();
      if (id.isEmpty || name.isEmpty) return;
      if (id.startsWith('memo_')) return;

      final usagePenalty = (recentUsage[id] ?? 0) * 18.0;
      final score = baseScore - usagePenalty;
      final existing = byId[id];
      if (existing == null || score > existing.score) {
        byId[id] = AutoMealPlanCandidate(
          recipeId: id,
          recipeTitle: name,
          source: source,
          score: score,
        );
      }
    }

    for (final r in fridgeRecipes) {
      final id = (r['recipeId'] ?? r['id'])?.toString() ?? '';
      final title =
          (r['recipeName'] ?? r['title'] ?? r['name'])?.toString() ?? '';
      upsert(
        recipeId: id,
        title: title,
        source: 'fridge',
        baseScore: 120,
      );
    }

    final ratingByRecipe = <String, double>{};
    final cookedCount = <String, int>{};
    for (final review in reviews) {
      final id = (review['recipeId'] as String?)?.trim() ?? '';
      if (id.isEmpty) continue;
      final rating = (review['rating'] as num?)?.toDouble() ?? 0;
      final prevRating = ratingByRecipe[id] ?? 0;
      if (rating > prevRating) ratingByRecipe[id] = rating;
      cookedCount[id] = (cookedCount[id] ?? 0) + 1;
      final title =
          (review['recipeTitle'] ?? review['title'])?.toString() ?? '';
      final score =
          55 + ((ratingByRecipe[id] ?? 0) * 12) + ((cookedCount[id] ?? 1) * 3);
      upsert(
        recipeId: id,
        title: title,
        source: 'review',
        baseScore: score,
      );
    }

    for (final r in savedRecipes) {
      final status = (r['status'] as String? ?? 'completed').trim();
      if (status == 'parsing') continue;
      final id = (r['id'] ?? r['recipeId'])?.toString() ?? '';
      final recipeData = r['recipe'] as Map<String, dynamic>? ?? const {};
      final title = (r['title'] ??
              recipeData['title'] ??
              recipeData['name'] ??
              '')
          .toString();
      final ratingBoost = (ratingByRecipe[id] ?? 0) * 8;
      upsert(
        recipeId: id,
        title: title,
        source: 'saved',
        baseScore: 40 + ratingBoost,
      );
    }

    final list = byId.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.recipeTitle.compareTo(b.recipeTitle);
      });
    return list;
  }

  AutoMealPlanCandidate? _pickCandidate({
    required List<AutoMealPlanCandidate> candidates,
    required Set<String> usedInBatch,
    required Map<String, int> recentUsage,
  }) {
    AutoMealPlanCandidate? best;
    var bestScore = double.negativeInfinity;
    for (final c in candidates) {
      if (usedInBatch.contains(c.recipeId)) continue;
      final adjusted = c.score - ((recentUsage[c.recipeId] ?? 0) * 18.0);
      if (adjusted > bestScore) {
        bestScore = adjusted;
        best = c;
      }
    }
    return best;
  }

  Map<String, int> _recentRecipeUsage(
    Map<String, Map<String, dynamic>> existingPlans,
    DateTime start,
  ) {
    final usage = <String, int>{};
    final windowStart = start.subtract(const Duration(days: 14));
    existingPlans.forEach((dateKey, plan) {
      final parts = dateKey.split('-');
      if (parts.length != 3) return;
      final date = DateTime(
        int.tryParse(parts[0]) ?? 0,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[2]) ?? 1,
      );
      if (date.isBefore(windowStart)) return;
      final meals = plan['meals'] as Map? ?? const {};
      for (final key in mealOrder) {
        final list = List<String>.from(meals[key] as List? ?? const []);
        for (final id in list) {
          if (id.trim().isEmpty || id.startsWith('memo_')) continue;
          usage[id] = (usage[id] ?? 0) + 1;
        }
      }
    });
    return usage;
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
