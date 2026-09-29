import 'package:shared_preferences/shared_preferences.dart';

/// 비로그인(게스트) 무료 분석 횟수 관리.
///
/// 정책
/// - 무료 횟수는 **분석에 성공했을 때만** 소진된다 (실패·취소는 소진되지 않는다).
/// - 기기 단위로 영구 보관하며, 로그아웃해도 다시 채워주지 않는다.
/// - 로그인 사용자에게는 적용되지 않는다.
///
/// 클라이언트 로컬 카운터이므로 앱 재설치나 API 직접 호출로는 우회될 수 있다.
/// 완전한 차단이 필요하면 백엔드 파싱 엔드포인트에 토큰 검증을 붙여야 한다.
class GuestParseQuotaService {
  GuestParseQuotaService._();

  static final GuestParseQuotaService instance = GuestParseQuotaService._();

  /// 게스트가 무료로 성공시킬 수 있는 분석 횟수.
  static const int freeParseLimit = 1;

  static const String _successCountKey = 'guest_parse_success_count';
  static const String _pendingUrlKey = 'guest_pending_parse_url';
  static const String _pendingUrlAtKey = 'guest_pending_parse_url_at';

  /// 로그인 리다이렉트가 길어져도 이 시간 안에 돌아오면 이어서 분석한다.
  static const Duration _pendingUrlTtl = Duration(minutes: 30);

  Future<int> successCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_successCountKey) ?? 0;
  }

  Future<bool> canParseAsGuest() async {
    return (await successCount()) < freeParseLimit;
  }

  Future<int> remainingFreeParses() async {
    final used = await successCount();
    final left = freeParseLimit - used;
    return left < 0 ? 0 : left;
  }

  Future<void> markGuestParseSucceeded() async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_successCountKey) ?? 0) + 1;
    await prefs.setInt(_successCountKey, next);
  }

  /// 로그인 화면이 네비게이션 스택을 초기화하므로, 막힌 URL은 화면 상태가 아니라
  /// 여기에 남겨 두고 로그인 완료 후 다시 꺼내 분석을 이어간다.
  Future<void> setPendingParseUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingUrlKey, trimmed);
    await prefs.setInt(
      _pendingUrlAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 보관된 URL을 꺼내면서 즉시 지운다 (중복 실행 방지).
  Future<String?> takePendingParseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_pendingUrlKey);
    final savedAt = prefs.getInt(_pendingUrlAtKey);
    await clearPendingParseUrl();
    if (url == null || url.isEmpty || savedAt == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - savedAt;
    if (age < 0 || age > _pendingUrlTtl.inMilliseconds) return null;
    return url;
  }

  Future<void> clearPendingParseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingUrlKey);
    await prefs.remove(_pendingUrlAtKey);
  }
}
