import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/yorigo_level.dart';

enum LeaderboardMetric { reviews, likes }

enum LeaderboardPeriod { days7, days30, all }

extension LeaderboardPeriodX on LeaderboardPeriod {
  String get label {
    switch (this) {
      case LeaderboardPeriod.days7:
        return '최근 7일';
      case LeaderboardPeriod.days30:
        return '최근 30일';
      case LeaderboardPeriod.all:
        return '전체';
    }
  }

  DateTime? get since {
    final now = DateTime.now();
    switch (this) {
      case LeaderboardPeriod.days7:
        return now.subtract(const Duration(days: 7));
      case LeaderboardPeriod.days30:
        return now.subtract(const Duration(days: 30));
      case LeaderboardPeriod.all:
        return null;
    }
  }
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.userId,
    required this.rank,
    required this.score,
    required this.name,
    required this.handle,
    required this.photoUrl,
    required this.level,
    required this.dishes,
  });

  final String userId;
  final int rank;
  final int score;
  final String name;
  final String handle;
  final String photoUrl;
  final int level;
  final List<String> dishes;
}

class _Agg {
  int reviews = 0;
  int likes = 0;
  final List<String> titles = [];
}

class _CachedReview {
  const _CachedReview({
    required this.userId,
    required this.createdAt,
    required this.likes,
    required this.title,
  });

  final String userId;
  final DateTime? createdAt;
  final int likes;
  final String title;
}

class CommunityLeaderboardService {
  CommunityLeaderboardService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const int _maxRawReads = 400;
  static const int _batchSize = 80;
  static const int _topLimit = 50;
  static const Duration _cacheTtl = Duration(minutes: 5);

  static List<_CachedReview>? _reviewCache;
  static DateTime? _reviewCacheAt;
  static LeaderboardPeriod? _cachedPeriod;
  static final Map<String, Map<String, dynamic>> _userCache =
      <String, Map<String, dynamic>>{};
  static Future<List<_CachedReview>>? _inflightReviews;
  static LeaderboardPeriod? _inflightPeriod;

  Future<List<LeaderboardEntry>> fetch({
    required LeaderboardMetric metric,
    required LeaderboardPeriod period,
    Set<String>? onlyUserIds,
    bool forceRefresh = false,
  }) async {
    if (onlyUserIds != null && onlyUserIds.isEmpty) return const [];
    final rows = await _loadReviews(
      forceRefresh: forceRefresh,
      period: period,
    );
    final since = period.since;
    final byUser = <String, _Agg>{};

    for (final row in rows) {
      if (since != null &&
          row.createdAt != null &&
          row.createdAt!.isBefore(since)) {
        continue;
      }
      if (onlyUserIds != null && !onlyUserIds.contains(row.userId)) continue;
      final agg = byUser.putIfAbsent(row.userId, _Agg.new);
      agg.reviews += 1;
      agg.likes += row.likes;
      if (row.title.isNotEmpty &&
          !agg.titles.contains(row.title) &&
          agg.titles.length < 2) {
        agg.titles.add(row.title);
      }
    }

    final ranked = byUser.entries.toList()
      ..sort((a, b) {
        final sa =
            metric == LeaderboardMetric.likes ? a.value.likes : a.value.reviews;
        final sb =
            metric == LeaderboardMetric.likes ? b.value.likes : b.value.reviews;
        final cmp = sb.compareTo(sa);
        if (cmp != 0) return cmp;
        return a.key.compareTo(b.key);
      });

    final top = ranked.where((e) {
      final score =
          metric == LeaderboardMetric.likes ? e.value.likes : e.value.reviews;
      return score > 0;
    }).take(_topLimit).toList();

    if (top.isEmpty) return const [];

    final users = await _loadUsers(
      top.map((e) => e.key).toList(),
      forceRefresh: forceRefresh,
    );
    final result = <LeaderboardEntry>[];
    var rank = 0;
    var prevScore = -1;
    for (var i = 0; i < top.length; i++) {
      final uid = top[i].key;
      final agg = top[i].value;
      final score =
          metric == LeaderboardMetric.likes ? agg.likes : agg.reviews;
      if (score != prevScore) {
        rank = i + 1;
        prevScore = score;
      }
      final user = users[uid] ?? const {};
      result.add(
        LeaderboardEntry(
          userId: uid,
          rank: rank,
          score: score,
          name: _nameOf(user),
          handle: _handleOf(user),
          photoUrl: (user['photoUrl'] as String?)?.trim() ?? '',
          level: yorigoLevelFromUserData(user),
          dishes: List<String>.from(agg.titles),
        ),
      );
    }
    return result;
  }

  bool _periodCovers(LeaderboardPeriod cached, LeaderboardPeriod requested) {
    if (cached == LeaderboardPeriod.all) return true;
    if (cached == LeaderboardPeriod.days30) {
      return requested != LeaderboardPeriod.all;
    }
    return requested == LeaderboardPeriod.days7;
  }

  bool _cacheCovers(LeaderboardPeriod period) {
    if (_reviewCache == null || _cachedPeriod == null) return false;
    return _periodCovers(_cachedPeriod!, period);
  }

  Future<List<_CachedReview>> _loadReviews({
    required bool forceRefresh,
    required LeaderboardPeriod period,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cacheCovers(period) &&
        _reviewCacheAt != null &&
        now.difference(_reviewCacheAt!) < _cacheTtl) {
      return _reviewCache!;
    }
    if (!forceRefresh &&
        _inflightReviews != null &&
        _inflightPeriod != null &&
        _periodCovers(_inflightPeriod!, period)) {
      return _inflightReviews!;
    }

    final pending = _fetchReviews(since: period.since);
    _inflightReviews = pending;
    _inflightPeriod = period;
    try {
      final rows = await pending;
      _reviewCache = rows;
      _reviewCacheAt = DateTime.now();
      _cachedPeriod = period;
      return rows;
    } finally {
      if (identical(_inflightReviews, pending)) {
        _inflightReviews = null;
        _inflightPeriod = null;
      }
    }
  }

  Future<List<_CachedReview>> _fetchReviews({required DateTime? since}) async {
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var reads = 0;
    final rows = <_CachedReview>[];

    while (reads < _maxRawReads) {
      Query<Map<String, dynamic>> query = _firestore
          .collection('reviews')
          .where('isHidden', isEqualTo: false)
          .orderBy('createdAt', descending: true)
          .limit(_batchSize);
      if (cursor != null) {
        query = query.startAfterDocument(cursor);
      }

      QuerySnapshot<Map<String, dynamic>> snap;
      try {
        snap = await query.get();
      } catch (e) {
        print('[Leaderboard] query failed: $e');
        break;
      }
      if (snap.docs.isEmpty) break;

      var hitCutoff = false;
      for (final doc in snap.docs) {
        reads++;
        final data = doc.data();
        final created = _asDate(data['createdAt']);
        if (since != null && created != null && created.isBefore(since)) {
          hitCutoff = true;
          break;
        }
        final visibility = (data['visibility'] as String?)?.trim();
        if (visibility == 'private') continue;
        final uid = (data['userId'] as String?)?.trim() ?? '';
        if (uid.isEmpty) continue;
        final title = (data['recipeTitle'] as String?)?.trim() ?? '';
        rows.add(
          _CachedReview(
            userId: uid,
            createdAt: created,
            likes: (data['likeCount'] as num?)?.toInt() ?? 0,
            title: title,
          ),
        );
      }

      cursor = snap.docs.last;
      if (hitCutoff || snap.docs.length < _batchSize) break;
    }
    return rows;
  }

  Future<Map<String, Map<String, dynamic>>> _loadUsers(
    List<String> userIds, {
    required bool forceRefresh,
  }) async {
    final result = <String, Map<String, dynamic>>{};
    final missing = <String>[];
    for (final id in userIds) {
      if (!forceRefresh && _userCache.containsKey(id)) {
        result[id] = _userCache[id]!;
      } else {
        missing.add(id);
      }
    }
    if (missing.isEmpty) return result;

    await Future.wait(
      missing.map((id) async {
        try {
          final doc = await _firestore.collection('users').doc(id).get();
          final data = doc.data() ?? const <String, dynamic>{};
          _userCache[id] = data;
          result[id] = data;
        } catch (_) {
          result[id] = const {};
        }
      }),
    );
    return result;
  }

  static String _nameOf(Map<String, dynamic> user) {
    final name = (user['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final handle = (user['handle'] as String?)?.trim() ?? '';
    if (handle.isNotEmpty) {
      return handle.startsWith('@') ? handle.substring(1) : handle;
    }
    return '요리사';
  }

  static String _handleOf(Map<String, dynamic> user) {
    final handle = (user['handle'] as String?)?.trim() ?? '';
    if (handle.isEmpty) return '';
    return handle.startsWith('@') ? handle : '@$handle';
  }

  static DateTime? _asDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
