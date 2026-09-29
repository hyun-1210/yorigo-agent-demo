import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yorigo/services/guest_parse_quota_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('성공 1회 후 게스트 파싱 불가', () async {
    final quota = GuestParseQuotaService.instance;
    expect(await quota.canParseAsGuest(), isTrue);
    await quota.markGuestParseSucceeded();
    expect(await quota.canParseAsGuest(), isFalse);
    expect(await quota.remainingFreeParses(), 0);
  });

  test('pending URL 은 take 시 소비되고 TTL 지나면 null', () async {
    final quota = GuestParseQuotaService.instance;
    await quota.setPendingParseUrl('https://vt.tiktok.com/ZS9gHj85X/');
    final taken = await quota.takePendingParseUrl();
    expect(taken, 'https://vt.tiktok.com/ZS9gHj85X/');
    expect(await quota.takePendingParseUrl(), isNull);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('guest_pending_parse_url', 'https://example.com/a');
    await prefs.setInt(
      'guest_pending_parse_url_at',
      DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    expect(await quota.takePendingParseUrl(), isNull);
  });
}
