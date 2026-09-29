import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../utils/auth_session_ready.dart';
import '../services/locale_service.dart';
import '../services/recipe_service.dart';
import '../services/theme_service.dart';
import '../services/user_service.dart';

/// 앱 전역 서비스·상태 provider.
/// 화면마다 `UserService()` 등을 새로 만들지 않고 ref.read/watch로 공유한다.
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final userServiceProvider = Provider<UserService>((ref) => UserService());

final recipeServiceProvider = Provider<RecipeService>(
  (ref) => RecipeService.shared,
);

final analyticsServiceProvider = Provider<AnalyticsService>(
  (ref) => AnalyticsService(),
);

final themeServiceProvider = ChangeNotifierProvider<ThemeService>(
  (ref) => ThemeService(),
);

final localeServiceProvider = ChangeNotifierProvider<LocaleService>(
  (ref) => LocaleService(),
);

/// Firebase Auth 세션 스트림 — 로그인 상태 변화를 한 곳에서 구독.
final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

/// Cold-start auth restore finished in [waitForFirebaseAuthSessionReady].
final authSessionReadyProvider = Provider<bool>((ref) {
  return AuthSessionController.instance.sessionReady;
});
