import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 카드/미니 doc 공통 소셜 숫자.
///
/// 본체는 `recipes.saveCount` 와 `source.play_count`/`source.view_count`.
/// 레시피북 미니는 목록 리드를 늘리지 않으려고 평탄 필드
/// `saveCount` / `sourceViewCount` 로 복사한다.
class RecipeSocialCounts {
  RecipeSocialCounts._();

  /// 파싱 직후 0으로 보이지 않게 recipeId 로 결정적인 북마크 시드(1–8).
  /// 백엔드 `utils.recipe_social_counts.seed_save_count` 와 동일.
  static int seedSaveCount(String recipeId) {
    final rid = recipeId.trim().isEmpty ? 'unknown' : recipeId.trim();
    final digest = sha256.convert(utf8.encode('yorigo:saveCount:$rid'));
    final bytes = digest.bytes;
    final bucket = bytes[0] % 100;
    final valueSrc =
        (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4];
    if (bucket < 55) return 1 + (valueSrc % 2);
    if (bucket < 85) return 3 + (valueSrc % 2);
    if (bucket < 97) return 5 + (valueSrc % 2);
    return 7 + (valueSrc % 2);
  }

  static int? intFrom(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), ''));
    }
    return null;
  }

  static int saveCountOf(Map<String, dynamic> recipe) {
    return intFrom(recipe['saveCount'])?.clamp(0, 999999999) ?? 0;
  }

  /// 인스타는 play_count 가 더 자주·크게 들어 있다. 없으면 view_count.
  /// 미니는 본체 source 맵이 없어서 [sourceViewCount] 만 본다.
  static int? viewCountOf(Map<String, dynamic> recipe) {
    final source = recipe['source'];
    if (source is Map) {
      final fromSource = viewCountFromSource(Map<String, dynamic>.from(source));
      if (fromSource != null) return fromSource;
    }
    return intFrom(recipe['sourceViewCount']);
  }

  static int? viewCountFromSource(Map<String, dynamic> source) {
    for (final key in const [
      'play_count',
      'playCount',
      'view_count',
      'videoViewCount',
      'views',
      'viewCount',
    ]) {
      final n = intFrom(source[key]);
      if (n != null) return n;
    }
    for (final nestedKey in const ['statistics', 'stats', 'engagement']) {
      final nested = source[nestedKey];
      if (nested is! Map) continue;
      final found = viewCountFromSource(Map<String, dynamic>.from(nested));
      if (found != null) return found;
    }
    return null;
  }

  /// 레시피북 미니 소셜 숫자 TTL. 카드마다 이 시간이 지나면 본체에서 다시 베낀다.
  static const Duration socialTtl = Duration(days: 3);

  /// 한 앱 세션에서 본체로 소셜 숫자를 다시 읽는 최대 장 수.
  static const int socialRefreshSessionCap = 40;

  /// 미니 기록/백필용. saveCount 는 필드 없으면 0.
  static Map<String, dynamic> miniSocialFields(Map<String, dynamic> recipe) {
    final views = viewCountOf(recipe);
    return <String, dynamic>{
      'saveCount': saveCountOf(recipe),
      if (views != null) 'sourceViewCount': views,
    };
  }

  /// 카드 맵에 올릴 표시/TTL 필드.
  static Map<String, dynamic> cardSocialFields(Map<String, dynamic> mini) {
    final views = intFrom(mini['sourceViewCount']);
    final syncedRaw = mini['socialSyncedAt'];
    final syncedAt = syncedAtOf(syncedRaw);
    return <String, dynamic>{
      'saveCount': saveCountOf(mini),
      if (views != null) 'sourceViewCount': views,
      if (syncedRaw != null) 'socialSyncedAt': syncedAt ?? DateTime.now(),
    };
  }

  static DateTime? syncedAtOf(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    try {
      final dt = (raw as dynamic).toDate();
      if (dt is DateTime) return dt;
    } catch (_) {}
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  /// 필드 없음 / 저장 카드인데 0 / TTL 만료.
  static bool miniNeedsSocialRefresh(
    Map<String, dynamic> mini, {
    DateTime? now,
  }) {
    if (!mini.containsKey('saveCount')) return true;
    if (saveCountOf(mini) <= 0) return true;
    final synced = syncedAtOf(mini['socialSyncedAt']);
    if (synced == null) return true;
    return (now ?? DateTime.now()).difference(synced) >= socialTtl;
  }

  static bool socialFieldsDiffer(
    Map<String, dynamic> current,
    Map<String, dynamic> incoming,
  ) {
    if (saveCountOf(current) != saveCountOf(incoming)) return true;
    return viewCountOf(current) != viewCountOf(incoming);
  }
}
