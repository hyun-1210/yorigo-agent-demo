import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? _asDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Cooking-day label for the feed. Empty when it is the same day as upload
/// so "방금 전" is not repeated as today's date.
String? reviewCookedDateLabel(Map<String, dynamic> review) {
  final cooked = _asDate(review['cookedAt']);
  if (cooked == null) return null;

  final created = _asDate(review['createdAt']);
  final cookedDay = _day(cooked);
  final uploadedDay = created != null ? _day(created) : _day(DateTime.now());
  if (cookedDay == uploadedDay) return null;

  if (cooked.year == DateTime.now().year) {
    return '${cooked.month}월 ${cooked.day}일';
  }
  return '${cooked.year}. ${cooked.month}. ${cooked.day}';
}
