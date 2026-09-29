import '../constants/review_experience_options.dart';

int reviewCreatedAtMs(dynamic createdAt) {
  if (createdAt == null) return 0;
  if (createdAt is DateTime) return createdAt.millisecondsSinceEpoch;
  try {
    final ms = (createdAt as dynamic).millisecondsSinceEpoch;
    return ms is int ? ms : 0;
  } catch (_) {
    return 0;
  }
}

/// Distinct [userId] with a review in the last [window] (default 90 days).
/// Only considers reviews with parseable `createdAt` within the window.
int countDistinctParticipantsInWindow(
  List<Map<String, dynamic>> reviews, {
  Duration window = const Duration(days: 90),
}) {
  final cutoffMs =
      DateTime.now().subtract(window).millisecondsSinceEpoch;
  final seen = <String>{};
  for (final r in reviews) {
    final ms = reviewCreatedAtMs(r['createdAt']);
    if (ms == 0 || ms < cutoffMs) continue;
    final uid = (r['userId'] as String?)?.trim() ?? '';
    if (uid.isEmpty) continue;
    seen.add(uid);
  }
  return seen.length;
}

String? parseReviewDifficultyLabel(Map<String, dynamic> review) {
  final candidates = [
    review['difficultyLabel'],
    review['difficulty'],
    review['difficultyText'],
    review['difficulty_level'],
  ];
  for (final c in candidates) {
    final v = c?.toString().trim() ?? '';
    if (v.isNotEmpty) return v;
  }
  return null;
}

String? parseReviewRecipeExplanationLabel(Map<String, dynamic> review) {
  final candidates = [
    review['recipeExplanationLabel'],
    review['explanation'],
    review['explanationLabel'],
    review['explanationText'],
    review['descriptionClarity'],
  ];
  for (final c in candidates) {
    final v = c?.toString().trim() ?? '';
    if (v.isNotEmpty) return v;
  }
  return null;
}

List<String> parseReviewBenefitLabels(Map<String, dynamic> review) {
  final raw = review['benefits'] ??
      review['benefitTags'] ??
      review['benefitOptions'] ??
      review['benefitLabels'];
  if (raw is List) {
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}

/// Percent of reviews that picked [targetLabel] among those with any non-empty label from [parseLabel].
int? percentForLabel({
  required List<Map<String, dynamic>> reviews,
  required String? Function(Map<String, dynamic>) parseLabel,
  required String targetLabel,
}) {
  var denom = 0;
  var num = 0;
  for (final r in reviews) {
    final label = parseLabel(r);
    if (label == null || label.isEmpty) continue;
    denom++;
    if (label == targetLabel) num++;
  }
  if (denom == 0) return null;
  return ((num * 100.0) / denom).round().clamp(0, 100);
}

/// Per-option counts among reviews that selected at least one canonical benefit.
/// Sorted by count descending, then stable by [ReviewExperienceOptions.benefitOptions] order.
List<({String option, int percent, int count})> aggregateBenefitBars(
  List<Map<String, dynamic>> reviews,
) {
  final counts = <String, int>{
    for (final o in ReviewExperienceOptions.benefitOptions) o: 0,
  };
  var denom = 0;
  for (final r in reviews) {
    final labels = parseReviewBenefitLabels(r);
    final canonicalHits = <String>{};
    for (final l in labels) {
      if (counts.containsKey(l)) canonicalHits.add(l);
    }
    if (canonicalHits.isEmpty) continue;
    denom++;
    for (final l in canonicalHits) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
  }
  if (denom == 0) return [];

  final entries = <({String option, int percent, int count})>[];
  for (final o in ReviewExperienceOptions.benefitOptions) {
    final c = counts[o] ?? 0;
    if (c <= 0) continue;
    final p = ((c * 100.0) / denom).round().clamp(0, 100);
    entries.add((option: o, percent: p, count: c));
  }
  entries.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return ReviewExperienceOptions.benefitOptions
        .indexOf(a.option)
        .compareTo(ReviewExperienceOptions.benefitOptions.indexOf(b.option));
  });
  return entries;
}
