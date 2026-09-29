import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? parseReviewTimestamp(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}

/// Cooking-record date for a review. Falls back to createdAt for older docs.
DateTime? reviewCookedOrCreatedAt(Map<String, dynamic> review) {
  return parseReviewTimestamp(review['cookedAt']) ??
      parseReviewTimestamp(review['createdAt']);
}

/// Relative label for the community feed.
///
/// Uses `cookedAt` (the day chosen when the photo was uploaded). Same calendar
/// day as today still uses `createdAt` so "방금 전" stays accurate.
String reviewFeedTimeAgo(Map<String, dynamic> review) {
  final cooked = parseReviewTimestamp(review['cookedAt']);
  final created = parseReviewTimestamp(review['createdAt']);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  if (cooked != null) {
    final cookedDay = DateTime(cooked.year, cooked.month, cooked.day);
    final days = today.difference(cookedDay).inDays;
    if (days > 0) return _labelFromCalendarDays(days, cooked);
  }

  return _labelFromClock(created ?? cooked, now);
}

/// 인스타/유튜브처럼 상대 시간을 조금 더 길게 쓴다.
/// 방금 → 분 → 시간 → 일(6일) → 주(3주) → 1개월 전 → 그 이후는 `2026.06.03`.
String formatCommunityTimeAgo(DateTime dt, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = n.difference(dt);
  if (diff.isNegative || diff.inSeconds < 60) return '방금 전';
  if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
  if (diff.inHours < 24) return '${diff.inHours}시간 전';
  return _labelFromCalendarDays(diff.inDays, dt);
}

String _labelFromCalendarDays(int days, [DateTime? dt]) {
  if (days < 7) return '$days일 전';
  if (days < 30) return '${(days / 7).floor()}주 전';
  if (days < 60) return '1개월 전';
  if (dt != null) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}.$m.$d';
  }
  return '1개월 전';
}

String _labelFromClock(DateTime? date, DateTime now) {
  if (date == null) return '';
  final d = now.difference(date);
  if (d.inMinutes < 1) return '방금 전';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  return _labelFromCalendarDays(d.inDays, date);
}
