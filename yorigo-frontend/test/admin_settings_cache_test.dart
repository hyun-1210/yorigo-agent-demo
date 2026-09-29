import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/admin_service.dart';

/// 설정 화면 관리자 메뉴 표시 규칙 (캐시 즉시 표시 + 백그라운드 갱신).
bool? nextAdminUiState({
  required bool? currentUi,
  required bool? peekedCache,
  bool? refreshResult,
  bool refreshFailed = false,
}) {
  // 초기: 캐시 peek
  var ui = currentUi ?? peekedCache;
  // 갱신 성공 시 반영, 실패 시 기존 UI 유지
  if (refreshFailed) return ui;
  if (refreshResult != null) return refreshResult;
  return ui;
}

void main() {
  tearDown(() {
    AdminService.instance.clearCache();
  });

  group('AdminService in-memory cache (no Auth user)', () {
    test('debugSetCache + clearCache does not throw', () {
      AdminService.instance.debugSetCache(uid: 'uid-admin', isAdmin: true);
      AdminService.instance.clearCache();
      // Auth currentUser 없음 → peek null
      expect(AdminService.instance.cachedIsAdminForCurrentUser(), isNull);
    });
  });

  group('settings admin UI visibility rules', () {
    test('cached true shows menus before refresh completes', () {
      final ui = nextAdminUiState(
        currentUi: null,
        peekedCache: true,
      );
      expect(ui == true, isTrue);
    });

    test('null peek hides menus until refresh', () {
      var ui = nextAdminUiState(
        currentUi: null,
        peekedCache: null,
      );
      expect(ui == true, isFalse);
      ui = nextAdminUiState(
        currentUi: ui,
        peekedCache: null,
        refreshResult: true,
      );
      expect(ui == true, isTrue);
    });

    test('refresh demotion hides menus', () {
      final ui = nextAdminUiState(
        currentUi: true,
        peekedCache: true,
        refreshResult: false,
      );
      expect(ui == true, isFalse);
    });

    test('refresh failure keeps previous admin menus', () {
      final ui = nextAdminUiState(
        currentUi: true,
        peekedCache: true,
        refreshFailed: true,
      );
      expect(ui == true, isTrue);
    });
  });
}
