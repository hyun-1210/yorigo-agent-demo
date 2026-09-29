/// 클라이언트에서 Cloud Functions 호출을 줄이기 위한 세션 게이트.
///
/// 서버 한도/원장이 진실이다. 여기 값은 같은 세션에서 이미 실패한 청구를
/// 다시 보내지 않기 위한 힌트일 뿐이다.
class RewardClaimGate {
  RewardClaimGate({
    DateTime Function()? clock,
    Map<String, int>? dailyLimits,
  })  : _clock = clock ?? DateTime.now,
        _dailyLimits = dailyLimits ?? kExpDailyLimits;

  static const kExpDailyLimits = <String, int>{
    'exp_recipe_viewed': 20,
    'exp_search': 10,
    'exp_fridge_ingredient_added': 10,
    'exp_follow': 5,
    'exp_session_start': 1,
    'exp_recipe_bookmarked': 10,
    'exp_cooking_started': 3,
    'exp_meal_calendar_used': 5,
    'exp_cooking_completed': 2,
    'exp_cooking_logged': 8,
    'exp_cooking_logged_text': 8,
    'exp_recipe_parsed': 5,
    'exp_recipe_registered': 3,
    'exp_profile_completed': 1,
    'exp_attendance': 1,
    'exp_like': 15,
    'exp_comment': 10,
    'exp_post_created': 3,
    'exp_post_created_short': 3,
    'exp_feedback': 2,
    'exp_recipe_shared': 3,
  };

  static const int maxIdempotencyKeyLen = 200;

  final DateTime Function() _clock;
  final Map<String, int> _dailyLimits;
  final Set<String> _claimedKeys = <String>{};
  final Map<String, int> _dailyCounts = <String, int>{};
  String? _day;

  String utcDayKey([DateTime? now]) {
    final d = (now ?? _clock()).toUtc();
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  String safeIdempotencyKey(String idempotencyKey) {
    final trimmed = idempotencyKey.trim();
    if (trimmed.isEmpty) return '';
    final sanitized = trimmed.replaceAll('/', '_');
    if (sanitized.length <= maxIdempotencyKeyLen) return sanitized;
    return sanitized.substring(0, maxIdempotencyKeyLen);
  }

  String? skipReason(String action, String idempotencyKey) {
    _rollDay();
    final key = safeIdempotencyKey(idempotencyKey);
    if (key.isEmpty) return 'missing_idempotency_key';
    if (_claimedKeys.contains(key)) return 'duplicate';
    final limit = _dailyLimits[action];
    if (limit != null && (_dailyCounts[action] ?? 0) >= limit) {
      return 'daily_limit_reached';
    }
    return null;
  }

  void record({
    required String action,
    required String idempotencyKey,
    required bool granted,
    String? reason,
  }) {
    _rollDay();
    final key = safeIdempotencyKey(idempotencyKey);
    if (key.isEmpty) return;
    if (granted || reason == 'duplicate' || reason == 'daily_limit_reached') {
      _claimedKeys.add(key);
    }
    if (granted) {
      _dailyCounts[action] = (_dailyCounts[action] ?? 0) + 1;
      return;
    }
    if (reason == 'daily_limit_reached') {
      final limit = _dailyLimits[action];
      if (limit != null) {
        _dailyCounts[action] = limit;
      }
    }
  }

  void _rollDay() {
    final day = utcDayKey();
    if (_day == day) return;
    _day = day;
    _dailyCounts.clear();
    _claimedKeys.clear();
  }
}
