import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, FlutterError, kDebugMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_frame/device_frame.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:ui';
import 'firebase_options.dart';
import 'theme/app_theme.dart';
import 'screens/login_screen.dart';
import 'screens/email_login_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/terms_agreement_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/cart_screen.dart';
import 'screens/fridge_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/customer_center_screen.dart';
import 'screens/recipe_detail_screen.dart';
import 'screens/reparse_recipes_screen.dart';
import 'screens/home_screen.dart';
// CommunityScreen replaced by CategoryExploreScreen at nav index 1; old version kept in old_community_screen.dart
import 'screens/category_explore_screen.dart';
import 'screens/recommendation_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/streak_calendar_screen.dart';
import 'screens/add_recipe_screen.dart';
import 'screens/terms_of_service_screen.dart';
import 'screens/privacy_policy_screen.dart';
import 'screens/admin_error_recipes_screen.dart';
import 'screens/admin_home_section_screen.dart';
// 모임·챌린지: 배포 전까지 숨김.
// import 'screens/admin_challenge_compose_screen.dart';
import 'screens/admin_reports_screen.dart';
import 'screens/admin_user_inquiries_screen.dart';
import 'screens/admin_app_feedback_screen.dart';
import 'providers/app_providers.dart';
import 'services/user_service.dart';
import 'widgets/onboarding_gate.dart';
import 'utils/auth_navigation.dart';
import 'services/analytics_service.dart';
import 'services/admin_service.dart';
import 'services/rewards_service.dart';
import 'services/guest_parse_quota_service.dart';
import 'services/notification_service.dart';
import 'services/recipe_service.dart';
import 'l10n/app_localizations.dart';
import 'models/recipe_models.dart' as models;
import 'config/environment_config.dart';
import 'utils/ingredient_conversion_gap_research_uploader.dart';
import 'utils/chef_tag_utils.dart';
import 'utils/perf_monitor.dart';
import 'utils/auth_session_ready.dart';
import 'utils/naver_blog_utils.dart';
import 'utils/haptics.dart';
import 'services/ingredient_shelf_life_service.dart';
import 'utils/shelf_life_seed_runner.dart';
import 'widgets/app_media_query_merge_nav_insets.dart'
    show AppRootNavigationSafeArea;
import 'widgets/app_toast.dart';
import 'widgets/ios_liquid_glass_tab_bar.dart';
import 'widgets/app_update_gate.dart';
import 'widgets/auth_initialization_gate.dart';
import 'widgets/youtube_player_widget.dart' show YoutubePrewarmer;
import 'widgets/instagram_player_widget.dart' show InstagramPrewarmer;
import 'navigation/community_review_navigation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart' as kakao;

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<MainNavigatorState> mainNavigatorKey =
    GlobalKey<MainNavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    // Background isolate may race with main isolate init; ignore if already initialized.
  }
}

class _AnalyticsNavigatorObserver extends NavigatorObserver {
  _AnalyticsNavigatorObserver(this._analyticsService);

  final AnalyticsService _analyticsService;

  void _track(Route<dynamic>? route) {
    final routeName = route?.settings.name;
    PerfMonitor.instance.event('route:${routeName ?? 'unnamed'}');
    unawaited(_analyticsService.trackRoute(routeName));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _track(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _track(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _track(previousRoute);
  }
}

void main() async {
  // Set up error handlers before anything else
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      print('=== Flutter Error ===');
      print('Exception: ${details.exception}');
      print('Stack: ${details.stack}');
      print('Library: ${details.library}');
      print('====================');
    }
  };

  // Handle errors from the platform side
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      print('=== Platform Error ===');
      print('Error: $error');
      print('Stack: $stack');
      print('======================');
    }
    return true;
  };

  // Run app in a Zone to catch all async errors
  runZonedGuarded(
    () async {
      try {
        WidgetsFlutterBinding.ensureInitialized();
        await ChefTagRegistry.ensureLoaded();

        // 성능 계측 시작 (프로파일/디버그 빌드에서만 동작, 릴리스는 no-op)
        PerfMonitor.instance.start();

        // 안드로이드(갤럭시) 첫 프레임에서 시스템 바가 검정으로 깜빡이지 않도록
        // 밝은(흰색) 시스템 바를 기본값으로 설정한다. 이후 테마에 따라
        // YorigoApp 의 AnnotatedRegion 이 다크/라이트로 갱신한다.
        if (!kIsWeb) {
          SystemChrome.setSystemUIOverlayStyle(
            const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
              systemNavigationBarColor: Colors.white,
              systemNavigationBarDividerColor: Colors.white,
              systemNavigationBarIconBrightness: Brightness.dark,
            ),
          );
        }
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
          ]);
        }

        // Pre-warm after the first frame. Creating WKWebView before the
        // Flutter view is attached can abort launch on iOS.

        // 디코딩된 비트맵을 RAM에 잠깐 유지 — 탭/화면 전환 후 돌아왔을 때
        // 즉시 보이게 하려는 용도. (디스크 캐시는 재다운로드는 막지만
        // 화면에 그리려면 매번 RAM으로 디코딩해야 해서 이 역할을 대체 못 함.)
        // 상한을 너무 크게 두면 홈+탐색 IndexedStack에서 OOM으로 강제 종료될 수 있음.
        // 프로파일 실측상 로그인 홈 워킹셋은 이미지 캐시 기준 ~80MB 수준이라,
        // 여유를 두되 최악 피크(홈+탐색 동시 유지)를 낮추도록 110MB로 상한을 둔다.
        PaintingBinding.instance.imageCache.maximumSize = 500;
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            110 * 1024 * 1024; // 110 MB

        // Start loading nav bar bytes immediately (runs in parallel with Firebase init)
        const navAssetPaths = [
          'assets/icons/nav_home.png',
          'assets/icons/nav_community.png',
          'assets/icons/nav_cart.png',
          'assets/icons/nav_fridge.png',
          'assets/icons/nav_profile.png',
        ];
        final navLoadsFuture = Future.wait(
          navAssetPaths.map((p) => rootBundle.load(p)),
        );

        // Initialize Firebase with error handling
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );

          // Crashlytics: 실기기 크래시(스택/OOM 등)를 USB 없이 원격 수집한다.
          // - 웹은 미지원이라 모바일에서만 활성화.
          // - 디버그 빌드에서는 수집을 꺼 개발 중 크래시가 대시보드를 오염시키지 않게 함.
          // - Firebase 초기화 이후에만 인스턴스 접근이 가능하므로, 여기서 전역
          //   에러 핸들러를 Crashlytics 기록으로 재지정한다.
          if (!kIsWeb) {
            try {
              await FirebaseCrashlytics.instance
                  .setCrashlyticsCollectionEnabled(!kDebugMode);
              FlutterError.onError = (FlutterErrorDetails details) {
                FlutterError.presentError(details);
                FirebaseCrashlytics.instance.recordFlutterError(details);
              };
              PlatformDispatcher.instance.onError = (error, stack) {
                FirebaseCrashlytics.instance.recordError(
                  error,
                  stack,
                  fatal: true,
                );
                return true;
              };
            } catch (e) {
              print('[main] Crashlytics init skipped: $e');
            }
          }

          FirebaseMessaging.onBackgroundMessage(
            _firebaseMessagingBackgroundHandler,
          );
          try {
            if (kIsWeb) {
              FirebaseFirestore.instance.settings = const Settings(
                persistenceEnabled: false,
              );
            } else {
              // 잘못된 이전 버전에서 비대해진 로컬 캐시가 남아 있으면, 업데이트만 해도
              // 첫 실행 시 쿼리가 그 캐시를 디코드하다 OOM으로 죽을 수 있다.
              // 수정 버전 첫 실행에서 '딱 한 번' 로컬 캐시를 비워, 재설치/데이터삭제
              // 없이 업데이트만으로 복구되게 한다. (Android/iOS 공통)
              //
              // 중요: clearPersistence()는 Firestore가 '사용되기 전(=종료 상태)'에만
              // 성공한다. settings 지정이나 쿼리 실행 후에 호출하면 FAILED_PRECONDITION
              // 으로 실패하므로, 반드시 (1) settings/쿼리보다 먼저, (2) terminate()로
              // 인스턴스를 확실히 내린 뒤에 호출한다. 그래야 이전 릴리스에서 순서 문제로
              // 정리되지 못한 캐시도 이번 실행에서 실제로 비워진다.
              try {
                final prefs = await SharedPreferences.getInstance();
                const purgeFlag = 'firestore_cache_purged_oom_fix_v1';
                if (!(prefs.getBool(purgeFlag) ?? false)) {
                  // terminate()는 시작 전이면 사실상 no-op, 시작됐으면 안전히 종료.
                  await FirebaseFirestore.instance.terminate();
                  await FirebaseFirestore.instance.clearPersistence();
                  await prefs.setBool(purgeFlag, true);
                  print('[main] Firestore persistence cleared (one-time OOM fix)');
                }
              } catch (e) {
                // 정리 실패해도 앱 실행은 계속한다. (다음 실행에서 다시 시도)
                print('[main] Firestore clearPersistence skipped: $e');
              }

              // 모바일: 로컬 영속성 캐시가 무제한으로 커지면 쿼리 시
              // SQLiteRemoteDocumentCache 디코드가 Java 힙(256MB)을 초과해
              // OutOfMemoryError로 강제 종료된다. LRU 상한을 40MB로 둬서
              // 오래된 캐시 문서를 자동 정리하고 쿼리당 디코드량을 제한한다.
              // (clearPersistence 이후에 지정해야 terminate로 내린 인스턴스가
              //  이 설정으로 재시작된다.)
              FirebaseFirestore.instance.settings = const Settings(
                persistenceEnabled: true,
                cacheSizeBytes: 40 * 1024 * 1024,
              );
            }
          } catch (e, st) {
            print('[main] Warning: Firestore settings failed: $e');
            if (kDebugMode) {
              print('$st');
            }
          }

          // 디스크에 저장된 Firebase Auth 세션 복원이 끝날 때까지 대기한다.
          // (Android에서 프로세스 종료 후 currentUser가 잠깐 null인 레이스 방지)
          try {
            final user = await waitForFirebaseAuthSessionReady();
            print(
              '[main] Auth session ready: '
              'uid=${user?.uid ?? 'signed_out'}',
            );
          } catch (e) {
            AuthSessionController.instance.markSessionReady();
            print('[main] Warning: Auth state restore wait failed: $e');
          }

          print('[main] Firebase initialized successfully');
          if (EnvironmentConfig.enableConversionGapResearchBatch) {
            IngredientConversionGapResearchUploader.install();
          }
          // 재고 수명 데이터 로드는 모든 유저에게 필요하므로 유지(비차단).
          // 컬렉션 시드(쓰기)는 관리자 전용 백그라운드 작업으로 이관한다.
          unawaited(IngredientShelfLifeService.instance.ensureLoaded());
        } catch (e, stackTrace) {
          print('[main] ERROR: Firebase initialization failed');
          print('[main] Error: $e');
          print('[main] Stack trace: $stackTrace');
          // Continue anyway - some features might still work
        }

        // Track first app open (fires once per install, before sign-up)
        try {
          await AnalyticsService().trackAppFirstOpenIfNeeded();
        } catch (e) {
          print('[main] Warning: Failed to track first open: $e');
        }

        // Initialize Kakao SDK
        try {
          var kakaoSdkReady = false;
          if (kIsWeb) {
            // Web 환경에서는 JavaScript App Key만 사용
            if (EnvironmentConfig.kakaoJavaScriptAppKey.isNotEmpty) {
              kakao.KakaoSdk.init(
                javaScriptAppKey: EnvironmentConfig.kakaoJavaScriptAppKey,
              );
              kakaoSdkReady = true;
            } else if (kDebugMode) {
              print(
                '[main] Kakao JS key missing; skipping Kakao SDK init on Web',
              );
            }
          } else {
            // 모바일 환경에서는 Native App Key만 사용
            final nativeKey = EnvironmentConfig.kakaoNativeAppKey.trim();
            if (nativeKey.isNotEmpty) {
              kakao.KakaoSdk.init(nativeAppKey: nativeKey);
              kakaoSdkReady = true;
              if (!kDebugMode) {
                print('[main] Kakao SDK initialized (release/profile)');
              }
            } else {
              print(
                '[main] ERROR: KAKAO_NATIVE_APP_KEY 가 비었습니다. TestFlight/Xcode '
                '아카이브 전에 `flutter build ipa`(또는 ios)로 '
                '`--dart-define-from-file=dart_defines.json` 을 포함해 빌드하세요.',
              );
            }
          }
          if (kDebugMode && kakaoSdkReady) {
            print('[main] Kakao SDK initialized successfully');
          }
        } catch (e, stackTrace) {
          print('[main] ERROR: Kakao SDK initialization failed');
          print('[main] Error: $e');
          print('[main] Stack trace: $stackTrace');
          // Continue anyway - Kakao login might still work
        }

        // ============================================
        // 환경 설정 (테스트용)
        // ============================================
        // 실기기 디버그 APK는 production(Railway + parse.yorigo.kr)을 쓴다.
        // 로컬 FastAPI가 필요할 때만 Settings → Developer Settings에서 Local로 전환.
        if (kDebugMode) {
          EnvironmentConfig.setEnvironment(Environment.production);
        }
        try {
          EnvironmentConfig.printConfig();
        } catch (e) {
          print('[main] Warning: Failed to print environment config: $e');
        }

        // NOTE: 전체 유저 컬렉션(2800여 명)을 스캔·수정하는 마이그레이션은
        // 예전엔 여기서 await 되어 로그인 유저의 콜드 스타트를 ~27초간 막았다.
        // 이제 관리자 전용 백그라운드 작업(_runAdminMaintenanceInBackground)으로
        // 이관하여 일반 유저 기기에서는 실행되지 않고 UI도 막지 않는다.

        // Ensure nav bar asset bytes are loaded (ran in parallel with init)
        await navLoadsFuture;

        try {
          await NotificationService.instance.initialize(
            onActionTap: (action) async {
              mainNavigatorKey.currentState?.openFromNotification(action);
            },
          );
        } catch (e, stackTrace) {
          print(
            '[main] NotificationService init failed; continuing without push: $e',
          );
          print('$stackTrace');
        }

        runApp(
          const ProviderScope(
            child: YorigoApp(),
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          YoutubePrewarmer.instance.warmUp();
          InstagramPrewarmer.instance.warmUp();
        });

        // 유지보수 작업(마이그레이션·시드)은 첫 프레임 이후 백그라운드에서,
        // 그것도 관리자 계정에서만 실행한다. UI 시작을 절대 막지 않는다.
        unawaited(_runAdminMaintenanceInBackground());
      } catch (e, stackTrace) {
        print('[main] FATAL ERROR during app initialization');
        print('[main] Error: $e');
        print('[main] Stack trace: $stackTrace');
        // Try to show an error screen
        runApp(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 64,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'App Initialization Error',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'Error: $e',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    },
    (error, stack) {
      print('[main] Uncaught error in Zone: $error');
      print('[main] Stack: $stack');
    },
  );
}

/// 전체 컬렉션을 스캔·수정하는 유지보수 작업(마이그레이션·시드)을
/// 앱 시작 경로에서 분리해 백그라운드로 실행한다.
///
/// - 일반 유저 기기에서는 절대 실행되지 않도록 관리자 계정만 수행
/// - UI 첫 프레임을 막지 않도록 `await` 하지 않고 호출하며, 홈 로딩과
///   경쟁하지 않도록 수 초 지연 후 시작한다.
Future<void> _runAdminMaintenanceInBackground() async {
  try {
    // 로그인하지 않았거나 관리자가 아니면 즉시 종료(네트워크 스캔 없음).
    if (FirebaseAuth.instance.currentUser == null) return;

    // 첫 프레임 렌더·홈 부트스트랩이 끝난 뒤 실행되도록 잠시 대기.
    await Future<void>.delayed(const Duration(seconds: 5));

    final isAdmin = await AdminService.instance.isAdmin();
    if (!isAdmin) return;

    print('[main] Admin maintenance tasks starting in background...');

    try {
      await ShelfLifeSeedRunner.seedIfNeeded();
    } catch (e) {
      print('[main] ShelfLife seed skipped: $e');
    }
    try {
      await UserService().runLastAccessedAtMigration();
    } catch (e) {
      print('[main] lastAccessedAt migration failed: $e');
    }
    try {
      await AnalyticsService().runHistoricalActiveUsersMigration();
    } catch (e) {
      print('[main] historical active users migration failed: $e');
    }

    print('[main] Admin maintenance tasks finished.');
  } catch (e) {
    print('[main] Admin maintenance skipped: $e');
  }
}

/// When signed in and Firestore has no `termsAcceptedAt`, shows [TermsAgreementScreen] instead of [child].
class _TermsAgreementGate extends StatefulWidget {
  const _TermsAgreementGate({required this.child});

  final Widget child;

  @override
  State<_TermsAgreementGate> createState() => _TermsAgreementGateState();
}

class _TermsAgreementGateState extends State<_TermsAgreementGate> {
  final UserService _userService = UserService();
  bool _busy = true;
  bool _showTerms = false;
  String? _lastGateUid;
  bool _gateReady = false;

  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((user) {
      final uid = user?.uid;
      if (_gateReady && uid == _lastGateUid) {
        unawaited(_reloadSilently());
        return;
      }
      _lastGateUid = uid;
      unawaited(_reload());
    });
    unawaited(_reload());
  }

  /// Token refresh on app resume — do not unmount [MainNavigator] (keeps home caches).
  Future<void> _reloadSilently() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (!mounted) return;
        if (_showTerms) {
          setState(() {
            _showTerms = false;
            _busy = false;
          });
        }
        _lastGateUid = null;
        _gateReady = true;
        return;
      }
      final needs = await _userService.needsTermsAgreement(user.uid);
      if (!mounted) return;
      if (needs != _showTerms) {
        setState(() {
          _showTerms = needs;
          _busy = false;
        });
      }
      _gateReady = true;
    } catch (_) {
      _gateReady = true;
    }
  }

  Future<void> _reload() async {
    if (shouldIgnoreTransientAuthNull()) {
      return;
    }
    setState(() => _busy = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          setState(() {
            _showTerms = false;
            _busy = false;
          });
        }
        _lastGateUid = null;
        _gateReady = true;
        return;
      }
      _lastGateUid = user.uid;
      final needs = await _userService.needsTermsAgreement(user.uid);
      if (!mounted) return;
      setState(() {
        _showTerms = needs;
        _busy = false;
      });
      _gateReady = true;
    } catch (e, st) {
      // Firestore web can throw INTERNAL ASSERTION FAILED after hot restart; must not leave _busy stuck.
      if (kDebugMode) {
        print('[TermsAgreementGate] _reload failed: $e');
        print('$st');
      }
      if (mounted) {
        setState(() {
          _showTerms = false;
          _busy = false;
        });
      }
      _gateReady = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Scaffold(
        body: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_showTerms) {
      return const TermsAgreementScreen();
    }
    return widget.child;
  }
}

/// Preloads nav bar icons (decoded to 48x48) before showing MainNavigator so the nav bar appears instantly.
class _NavPrecacheGate extends StatefulWidget {
  const _NavPrecacheGate({required this.child});

  final Widget child;

  @override
  State<_NavPrecacheGate> createState() => _NavPrecacheGateState();
}

class _NavPrecacheGateState extends State<_NavPrecacheGate> {
  static const _navAssets = [
    'assets/yorigo_korean_logo.png',
    'assets/icons/nav_home.png',
    'assets/icons/nav_community.png',
    'assets/icons/nav_cart.png',
    'assets/icons/nav_fridge.png',
    'assets/icons/nav_profile.png',
  ];

  Future<void>? _precacheFuture;

  Future<void> _precache() async {
    for (final asset in _navAssets) {
      await precacheImage(
        ResizeImage(AssetImage(asset), width: 48, height: 48),
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _precacheFuture ??= _precache();
    return FutureBuilder<void>(
      future: _precacheFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return widget.child;
      },
    );
  }
}

class YorigoApp extends ConsumerStatefulWidget {
  const YorigoApp({super.key});

  @override
  ConsumerState<YorigoApp> createState() => _YorigoAppState();
}

class _YorigoAppState extends ConsumerState<YorigoApp> {
  late final AnalyticsService _analyticsService;
  late final _AnalyticsNavigatorObserver _analyticsNavigatorObserver;
  late final IosLiquidGlassTabBarRouteObserver _iosTabBarRouteObserver;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    RewardsService.navigatorKey = appNavigatorKey;
    _analyticsService = ref.read(analyticsServiceProvider);
    _analyticsNavigatorObserver =
        _AnalyticsNavigatorObserver(_analyticsService);
    _iosTabBarRouteObserver = IosLiquidGlassTabBarRouteObserver();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      unawaited(syncAuthLoggedInPreference(user));
      unawaited(_analyticsService.syncCurrentUser(user?.uid));
      if (user != null) {
        unawaited(UserService().backfillCurrentUserPhotoFromAuth());
      }
    });
    unawaited(
      _analyticsService.syncCurrentUser(FirebaseAuth.instance.currentUser?.uid),
    );
    if (FirebaseAuth.instance.currentUser != null) {
      unawaited(UserService().backfillCurrentUserPhotoFromAuth());
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 테마/로케일은 Riverpod provider(ChangeNotifier)를 구독한다.
    // notifyListeners 가 호출되면 이 위젯만 다시 빌드되어 MaterialApp 의
    // themeMode/locale 가 갱신된다. (예전의 addListener+setState 보일러플레이트 제거)
    final themeService = ref.watch(themeServiceProvider);
    final localeService = ref.watch(localeServiceProvider);
    final app = MaterialApp(
      navigatorKey: appNavigatorKey,
      title: '요리고',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeService.themeMode,
      debugShowCheckedModeBanner: false,
      locale: localeService.locale,
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ko', ''), Locale('en', '')],
      navigatorObservers: [
        _analyticsNavigatorObserver,
        _iosTabBarRouteObserver,
      ],
      initialRoute: '/',
      routes: {
        '/': (context) => AppUpdateGate(
          child: _NavPrecacheGate(
            child: AuthInitializationGate(
              child: _TermsAgreementGate(
                child: OnboardingGate(
                  child: MainNavigator(key: mainNavigatorKey),
                ),
              ),
            ),
          ),
        ),
        '/login': (context) => const LoginScreen(),
        '/email-login': (context) => const EmailLoginScreen(),
        '/forgot-password': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final initialEmail = args is String ? args : null;
          return ForgotPasswordScreen(initialEmail: initialEmail);
        },
        '/signup': (context) => const SignupScreen(),
        '/onboarding': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map) {
            return OnboardingScreen(
              continueRouteName: args['continueRouteName'] as String?,
              continueRouteArguments: args['continueRouteArguments'],
              isPreview: args['preview'] == true,
            );
          }
          return const OnboardingScreen();
        },
        '/terms-of-service': (context) => const TermsOfServiceScreen(),
        '/privacy-policy': (context) => const PrivacyPolicyScreen(),
        '/profile': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map && args['userId'] != null) {
            return ProfileScreen(userId: args['userId'] as String);
          }
          return const MainNavigator(initialIndex: 4);
        },
        '/settings': (context) => const SettingsScreen(),
        '/customer-center': (context) => const CustomerCenterScreen(),
        '/reparse-recipes': (context) => const ReparseRecipesScreen(),
        '/recommendation': (context) => const RecommendationScreen(),
        '/admin-reports': (context) => const AdminReportsScreen(),
        '/admin-user-inquiries': (context) =>
            const AdminUserInquiriesScreen(),
        '/admin-app-feedback': (context) => const AdminAppFeedbackScreen(),
        '/admin-error-recipes': (context) => const AdminErrorRecipesScreen(),
        '/admin-home-sections': (context) => const AdminHomeSectionScreen(),
        // 모임·챌린지: 배포 전까지 숨김.
        // '/admin-challenge-compose': (context) =>
        //     const AdminChallengeComposeScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/recipe-detail') {
          final args = settings.arguments;
          Widget page;
          if (args == null) {
            page = Scaffold(
              appBar: AppBar(title: const Text('오류')),
              body: const Center(child: Text('레시피 정보를 불러올 수 없습니다.')),
            );
          } else if (args is models.ParseResponse) {
            page = RecipeDetailScreen(parseResponse: args);
          } else if (args is Map) {
            final parseResponse =
                args['parseResponse'] as models.ParseResponse?;
            final recipeId = args['recipeId'] as String?;
            if (parseResponse == null) {
              page = Scaffold(
                appBar: AppBar(title: const Text('오류')),
                body: const Center(child: Text('레시피 정보를 불러올 수 없습니다.')),
              );
            } else {
              page = RecipeDetailScreen(
                parseResponse: parseResponse,
                recipeId: recipeId,
              );
            }
          } else {
            page = Scaffold(
              appBar: AppBar(title: const Text('오류')),
              body: const Center(child: Text('레시피 정보를 불러올 수 없습니다.')),
            );
          }
          return CupertinoPageRoute(builder: (_) => page, settings: settings);
        }
        return null;
      },
      scrollBehavior: kIsWeb
          ? const MaterialScrollBehavior().copyWith(
              scrollbars: false,
              overscroll: false,
              physics: const ClampingScrollPhysics(),
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
              },
            )
          : const MaterialScrollBehavior().copyWith(
              scrollbars: false,
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
              },
            ),
      builder: (context, child) {
        final Widget w = child ?? const SizedBox.shrink();
        final Widget
        dismissKeyboardOnScroll = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Only dismiss the keyboard when the user **actively drags** a scroll
            // view. Programmatic scrolls (caret-on-screen when a TextField gains
            // focus, viewport adjustments when the keyboard rises,
            // Scrollable.ensureVisible, etc.) also emit ScrollNotifications and
            // must NOT close the keyboard — otherwise text fields inside any
            // scrollable lose focus the instant the keyboard tries to come up.
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              final focus = FocusManager.instance.primaryFocus;
              if (focus != null && focus.context != null && focus.hasFocus) {
                focus.unfocus();
              }
            }
            return false;
          },
          child: w,
        );
        if (kIsWeb) {
          return DeviceFrame(
            device: Devices.android.samsungGalaxyS25,
            isFrameVisible: true,
            screen: AppRootNavigationSafeArea(child: dismissKeyboardOnScroll),
          );
        }
        // 앱은 다크모드를 쓰지 않으므로 상단 상태바/하단 내비게이션바를
        // 항상 흰색(아이콘은 어둡게)으로 고정해 화면과 자연스럽게 연결한다.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarDividerColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          child: AppRootNavigationSafeArea(child: dismissKeyboardOnScroll),
        );
      },
    );

    return app;
  }
}

class MainNavigator extends StatefulWidget {
  final int initialIndex;

  const MainNavigator({super.key, this.initialIndex = 0});

  @override
  State<MainNavigator> createState() => MainNavigatorState();

  static MainNavigatorState? of(BuildContext context) {
    return context.findAncestorStateOfType<MainNavigatorState>();
  }
}

/// Undo data for "구매 완료 취소": fridge and cart state before the last purchase.
class MainNavigatorState extends State<MainNavigator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;
  /// Native overlay failed (missing plugin / platform error) → Flutter nav.
  bool _iosNativeTabFailed = false;
  /// 한 번이라도 연 탭만 트리에 올린다 (앱 시작 시 5개 탭 동시 마운트로 인한
  /// 메모리 피크/OOM 방지). 방문 후에는 IndexedStack 으로 상태가 유지된다.
  final Set<int> _visitedTabs = <int>{0};
  bool _showFridgeArrivalAnimation = false;
  final GlobalKey _fridgeNavKey = GlobalKey();
  final UserService _userService = UserService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final RecipeService _recipeService = RecipeService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late final AnimationController _fridgeBounceController;
  late final Animation<double> _fridgeBounceScale;

  /// Native may deliver the same share via `sharedText` and `getInitialSharedText`; ignore dupes.
  String? _lastDedupedShareUrl;
  DateTime? _lastDedupedShareAt;

  /// Live cart recipe count for the bottom nav badge.
  int _cartRecipeCount = 0;
  StreamSubscription<DocumentSnapshot>? _cartCountSub;
  StreamSubscription<User?>? _authAccessSub;

  // Getter to check current tab index (for screens to know if they're visible)
  int get currentIndex => _currentIndex;

  bool _showAddRecipeSheet = false;
  int _addRecipeSheetGeneration = 0;

  void showAddRecipeSheet({String? initialUrl, bool autoAnalyze = false}) {
    if (_showAddRecipeSheet) return;
    final generation = ++_addRecipeSheetGeneration;
    setState(() => _showAddRecipeSheet = true);
    unawaited(IosLiquidGlassTabBar.setChromeHitsEnabled(false));
    unawaited(
      _analyticsService.trackAddRecipeOpened(
        source: 'main_navigator',
        hasInitialUrl: initialUrl != null && initialUrl.trim().isNotEmpty,
      ),
    );
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      builder: (_) => AddRecipeScreen(
        initialUrl: initialUrl,
        autoAnalyze: autoAnalyze,
        bottomOffset: AddRecipeScreen.bottomNavOffsetFor(context),
      ),
    ).whenComplete(() {
      if (!mounted || generation != _addRecipeSheetGeneration) return;
      setState(() => _showAddRecipeSheet = false);
      if (!IosLiquidGlassTabBar.coveredByPushedRoute.value) {
        unawaited(IosLiquidGlassTabBar.setChromeHitsEnabled(true));
      }
    });
  }

  /// 무료 분석 소진으로 막혔던 링크를 로그인 직후 이어서 분석한다.
  /// 로그인 화면이 스택을 초기화하므로 URL 은 로컬에 보관해 두고 여기서 꺼낸다.
  Future<void> _resumePendingParseAfterLogin() async {
    final url = await GuestParseQuotaService.instance.takePendingParseUrl();
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    if (_currentIndex != 0) _onTabTapped(0);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    showAddRecipeSheet(initialUrl: url, autoAnalyze: true);
  }

  void hideAddRecipeSheet() {
    if (!_showAddRecipeSheet) return;
    setState(() => _showAddRecipeSheet = false);
    // 분석 기록 재시도처럼 이미 popUntil(isFirst)로 시트를 닫은 뒤
    // 홈 탭 전환이 들어오면 추가 pop이 앱 셸까지 제거해 검은 화면이 된다.
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, 4);
    _visitedTabs.add(_currentIndex);
    WidgetsBinding.instance.addObserver(this);
    RewardsService.navigatorKey = appNavigatorKey;
    _fridgeBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fridgeBounceScale = Tween<double>(begin: 1.0, end: 1.25)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_fridgeBounceController);
    _trackAppAccess();
    _authAccessSub = _auth.authStateChanges().listen((user) {
      if (user != null) {
        unawaited(_trackAppAccess());
        unawaited(_resumePendingParseAfterLogin());
        unawaited(ProfileScreen.warmOwnProfileCache());
      }
    });
    if (_auth.currentUser != null) {
      unawaited(_resumePendingParseAfterLogin());
      unawaited(ProfileScreen.warmOwnProfileCache());
    }
    // Prefetch profile tab after home settles so first open feels instant.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AuthNavigation.pendingOpenAddRecipe) {
        AuthNavigation.pendingOpenAddRecipe = false;
        Future<void>.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          showAddRecipeSheet();
        });
      }
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted || _auth.currentUser == null) return;
        unawaited(ProfileScreen.warmOwnProfileCache());
        if (!_visitedTabs.contains(4)) {
          setState(() => _visitedTabs.add(4));
        }
      });
    });
    if (!kIsWeb) {
      try {
        // Set up method channel to receive shared text from native code
        const platform = MethodChannel('yorigo.app/share');

        // Listen for shared text
        platform.setMethodCallHandler((call) async {
          try {
            print('[MainNavigator] Received method call: ${call.method}');
            if (call.method == 'sharedText' && mounted) {
              final sharedText = call.arguments as String?;
              print('[MainNavigator] Received shared text: $sharedText');
              if (sharedText != null && sharedText.isNotEmpty) {
                _handleSharedUrl(sharedText);
              }
            }
          } catch (e) {
            print('[MainNavigator] Error in method call handler: $e');
          }
        });

        // Get initial shared text when app opens
        // Add a delay to ensure native side is ready
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          platform
              .invokeMethod('getInitialSharedText')
              .then((value) {
                if (value != null &&
                    value is String &&
                    value.isNotEmpty &&
                    mounted) {
                  _handleSharedUrl(value);
                }
              })
              .catchError((error) {
                // This is expected if no shared text is available
                print(
                  '[MainNavigator] No initial shared text (this is normal): $error',
                );
              });
        });
      } catch (e) {
        print('[MainNavigator] Error setting up method channel: $e');
        // Don't crash the app if method channel setup fails
      }
    }
    NotificationService.instance.notificationUiActionDelegate =
        openFromNotification;
    bindOpenReviewInFeed(openReviewInFeed);
    CategoryExploreScreen.setMainTabSelected(_currentIndex == 1);
    HomeScreen.setMainTabSelected(_currentIndex == 0);
    unawaited(_analyticsService.trackMainTab(_currentIndex));
    _listenCartCount();
  }

  void _listenCartCount() {
    final user = _auth.currentUser;
    if (user == null) return;
    _cartCountSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      final items = data?['cartItems'] as List? ?? [];
      final count = items.length;
      if (count != _cartRecipeCount && mounted) {
        setState(() => _cartRecipeCount = count);
      }
    });
  }

  // Track when user accesses the app
  Future<void> _trackAppAccess() async {
    final user = _auth.currentUser;
    if (user != null) {
      try {
        await _userService.updateLastAccessed(user.uid);
      } catch (e) {
        print('[MainNavigator] Error tracking app access: $e');
      }
    }
  }

  @override
  void dispose() {
    _cartCountSub?.cancel();
    _authAccessSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.notificationUiActionDelegate = null;
    unbindOpenReviewInFeed();
    _fridgeBounceController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_analyticsService.handleAppLifecycleChange(state));
    if (state == AppLifecycleState.resumed) {
      unawaited(_trackAppAccess());
    }
  }

  Offset? getFridgeNavOffset() {
    final box = _fridgeNavKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2));
    }
    if (IosLiquidGlassTabBar.shouldUse(context)) {
      final size = MediaQuery.sizeOf(context);
      final bottom = MediaQuery.paddingOf(context).bottom;
      return Offset(size.width * 0.7, size.height - bottom - 36);
    }
    return null;
  }

  void bounceFridgeIcon() {
    _fridgeBounceController.forward(from: 0).then((_) {
      _fridgeBounceController.reverse();
    });
  }

  void _handleSharedUrl(String sharedText) {
    print('[MainNavigator] Handling shared URL: $sharedText');
    unawaited(_analyticsService.trackShareExtensionOpened());
    final url = _extractSharedRecipeUrl(sharedText);

    if (url != null && mounted) {
      print('[MainNavigator] Extracted URL: $url');
      final now = DateTime.now();
      if (_lastDedupedShareUrl == url &&
          _lastDedupedShareAt != null &&
          now.difference(_lastDedupedShareAt!) < const Duration(seconds: 3)) {
        print('[MainNavigator] Skipping duplicate share delivery for: $url');
        return;
      }
      _lastDedupedShareUrl = url;
      _lastDedupedShareAt = now;

      // Check if URL is from a supported platform
      final lowerUrl = url.toLowerCase();
      final isYouTube =
          lowerUrl.contains('youtube.com') || lowerUrl.contains('youtu.be');
      final isInstagram =
          lowerUrl.contains('instagram.com') || lowerUrl.contains('instagr.am');
      final isTikTok = lowerUrl.contains('tiktok.com');
      final isNaver = isNaverBlogUrl(url);

      print(
        '[MainNavigator] URL check - YouTube: $isYouTube, '
        'Instagram: $isInstagram, TikTok: $isTikTok, Naver: $isNaver',
      );

      if (isYouTube || isInstagram || isTikTok || isNaver) {
        // Shared video flow must always land on dashboard before opening the sheet.
        if (_currentIndex != 0) {
          _onTabTapped(0);
        }
        if (_showAddRecipeSheet) {
          hideAddRecipeSheet();
        }
        print('[MainNavigator] Opening AddRecipeScreen with URL: $url');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          showAddRecipeSheet(initialUrl: url, autoAnalyze: true);
        });
      } else {
        print('[MainNavigator] URL is not from a supported platform: $url');
      }
    } else {
      if (url == null) {
        print('[MainNavigator] Could not extract valid URL from: $sharedText');
      } else {
        print(
          '[MainNavigator] Widget not mounted, cannot open AddRecipeScreen',
        );
      }
    }
  }

  /// 공유 텍스트에서 레시피 URL을 꺼낸다. 스킴이 없는 youtu.be 도 허용한다.
  String? _extractSharedRecipeUrl(String sharedText) {
    final trimmedText = sharedText.trim();
    if (trimmedText.isEmpty) return null;

    final uri = Uri.tryParse(trimmedText);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      print('[MainNavigator] Parsed as direct URI: $trimmedText');
      return trimmedText;
    }

    final urlRegex = RegExp(r'https?://[^\s\)]+', caseSensitive: false);
    final match = urlRegex.firstMatch(trimmedText);
    if (match != null) {
      var url = match.group(0)!;
      url = url.replaceAll(RegExp(r'[.,;:!?]+$'), '');
      print('[MainNavigator] Extracted URL from text: $url');
      return url;
    }

    final loose = RegExp(
      r'(?:https?://)?(?:www\.)?'
      r'(?:youtube\.com|youtu\.be|m\.youtube\.com|music\.youtube\.com|'
      r'instagram\.com|instagr\.am|tiktok\.com|'
      r'blog\.naver\.com|m\.blog\.naver\.com|naver\.me)'
      r'[^\s\)\]<>"]*',
      caseSensitive: false,
    ).firstMatch(trimmedText);
    if (loose == null) {
      print('[MainNavigator] Could not find URL pattern in: $trimmedText');
      return null;
    }
    var url = loose.group(0)!;
    url = url.replaceAll(RegExp(r'[.,;:!?]+$'), '');
    if (!url.toLowerCase().startsWith('http')) {
      url = 'https://$url';
    }
    print('[MainNavigator] Extracted scheme-less URL: $url');
    return url;
  }

  void _onTabTapped(int index) {
    const tabNames = ['home', 'explore', 'cart', 'fridge', 'profile'];
    final tabName =
        index >= 0 && index < tabNames.length ? tabNames[index] : 'unknown';
    PerfMonitor.instance.event('tab:$tabName');
    if (_showAddRecipeSheet && index != _currentIndex) {
      hideAddRecipeSheet();
    }
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
    CategoryExploreScreen.setMainTabSelected(index == 1);
    HomeScreen.setMainTabSelected(index == 0);
    if (index == 4) {
      ProfileScreen.requestRefresh();
    }
    unawaited(_analyticsService.trackMainTab(index));
    unawaited(
      _analyticsService.trackMainTabSelected(index: index, tabName: tabName),
    );
  }

  void navigateToProfile() {
    _onTabTapped(4);
  }

  void navigateToCommunity() {
    _onTabTapped(1);
  }

  /// Recipe discovery now lives on the Home tab. Keep the old method name so
  /// existing CTAs route to the new surface without touching every caller.
  void navigateToCommunityTrending() {
    _onTabTapped(0);
  }

  /// Recipe discovery now lives on the Home tab.
  void navigateToCommunityTrendingPage() {
    _onTabTapped(0);
  }

  void navigateToHome() {
    _onTabTapped(0);
  }

  /// 탐색 탭(피드)으로 전환한 뒤 해당 리뷰 위치로 스크롤 (알림·관리자 원본보기 공통).
  void openReviewInFeed(String reviewId) {
    if (reviewId.isEmpty) return;
    _onTabTapped(1);
    Future.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      CategoryExploreScreen.notifyOpenReview(reviewId);
    });
  }

  void openFromNotification(AppNotificationAction action) {
    unawaited(
      _analyticsService.trackNotificationTapped(
        type: action.type,
        isActionable: true,
      ),
    );
    if (action.isFollow) {
      if (action.actorId.isNotEmpty) {
        Navigator.pushNamed(
          context,
          '/profile',
          arguments: {'userId': action.actorId},
        );
      }
      return;
    }

    if (action.isRecipeTarget) {
      AnalyticsService().noteRecipeOpenSource(
        recipeId: action.recipeId,
        screen: 'notification',
        sectionId: 'notification_tap',
      );
      if (action.isParseComplete) {
        unawaited(RecipeService.shared.handleParseCompleted(action.recipeId));
      }
      unawaited(_openRecipeDetailFromId(action.recipeId));
      return;
    }

    if (action.isStreakCalendarTarget) {
      unawaited(_openStreakCalendarFromNotification());
      return;
    }

    if (action.type == 'review_like' && action.actorId.isNotEmpty) {
      Navigator.pushNamed(
        context,
        '/profile',
        arguments: {'userId': action.actorId},
      );
      return;
    }

    if (action.isReviewTarget && action.reviewId.isNotEmpty) {
      openReviewInFeed(action.reviewId);
      return;
    }

    // 모임·챌린지 딥링크: 배포 전까지 비활성.
    // if (action.isMeetupTarget) {
    //   _onTabTapped(1);
    //   Future.delayed(const Duration(milliseconds: 250), () {
    //     if (!mounted) return;
    //     CategoryExploreScreen.notifyOpenMeetup(action.meetupId);
    //   });
    //   return;
    // }
    //
    // if (action.isChallengeTarget) {
    //   _onTabTapped(1);
    //   Future.delayed(const Duration(milliseconds: 250), () {
    //     if (!mounted) return;
    //     CategoryExploreScreen.notifyOpenChallenge(action.challengeId);
    //   });
    //   return;
    // }
  }

  Future<void> _openStreakCalendarFromNotification() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    _onTabTapped(4);
    final streakDays = await _userService.getUserStreakDays(
      uid,
      forceServer: true,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StreakCalendarScreen(
          userId: uid,
          attendanceDays: streakDays.attendanceDays,
          cookingDays: streakDays.cookingDays,
          includeTodayAttendance: true,
        ),
      ),
    );
  }

  Future<void> _openRecipeDetailFromId(String recipeId) async {
    final targetRecipeId = recipeId.trim();
    if (targetRecipeId.isEmpty) return;
    final parseResponse = await _recipeService.getRecipeById(targetRecipeId);
    if (!mounted || parseResponse == null) return;
    await Navigator.pushNamed(
      context,
      '/recipe-detail',
      arguments: {'parseResponse': parseResponse, 'recipeId': targetRecipeId},
    );
  }

  void navigateToCart() {
    _onTabTapped(2);
  }

  void navigateToFridge({bool withArrivalAnimation = false}) {
    if (withArrivalAnimation) {
      setState(() => _showFridgeArrivalAnimation = true);
    }
    _onTabTapped(3);
    _maybeShowFridgePurchaseTip();
  }

  void _clearFridgeArrivalAnimation() {
    if (_showFridgeArrivalAnimation) {
      setState(() => _showFridgeArrivalAnimation = false);
    }
  }

  /// 구매 완료 후 냉장고 도착 시 — 장바구니 담기 팁과 같은 안내 토스트.
  void _maybeShowFridgePurchaseTip() {
    if (!UserService.pendingFridgePurchaseTip) return;
    UserService.pendingFridgePurchaseTip = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.success(
        context,
        '유통기한과 남은 양을 확인하며 냉장고에서 관리해 보세요',
        title: '냉장고에 저장됐어요',
        duration: const Duration(milliseconds: 4200),
      );
    });
  }

  /// 방문한 탭만 실제 화면을 만들고, 미방문 탭은 빈 위젯으로 둔다.
  /// 한 번 방문하면 [_visitedTabs] 에 남아 IndexedStack 으로 상태가 보존된다.
  Widget _buildTab(int index) {
    if (!_visitedTabs.contains(index)) {
      return const SizedBox.shrink();
    }
    switch (index) {
      case 0:
        return const HomeScreen();
      case 1:
        return const CategoryExploreScreen();
      case 2:
        return CartScreen(
          getFridgeNavOffset: getFridgeNavOffset,
          onPurchaseComplete: () =>
              navigateToFridge(withArrivalAnimation: false),
          onFridgeIconBounceRequested: bounceFridgeIcon,
        );
      case 3:
        return FridgeScreen(
          showArrivalAnimation: _showFridgeArrivalAnimation,
          onArrivalAnimationDone: _clearFridgeArrivalAnimation,
        );
      default:
        return const ProfileScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final useIosLiquidTab =
        !_iosNativeTabFailed && IosLiquidGlassTabBar.shouldUse(context);
    final overlayHeight =
        useIosLiquidTab ? IosLiquidGlassTabBar.hostHeight(context) : 0.0;
    Widget tabs = IndexedStack(
      index: _currentIndex,
      children: [for (var i = 0; i < 5; i++) _buildTab(i)],
    );
    if (overlayHeight > 0) {
      // extendBody lets the feed show through the glass. Replace (do not add
      // to) the home-indicator padding so nested FABs / SafeArea chrome sit
      // flush above the overlay instead of overlapping it.
      final mediaQuery = MediaQuery.of(context);
      tabs = MediaQuery(
        data: mediaQuery.copyWith(
          padding: mediaQuery.padding.copyWith(bottom: overlayHeight),
          viewPadding: mediaQuery.viewPadding.copyWith(bottom: overlayHeight),
        ),
        child: tabs,
      );
    }
    return Scaffold(
      key: _scaffoldKey,
      extendBody: useIosLiquidTab,
      body: IosLiquidGlassTabBarScope(
        overlayHeight: overlayHeight,
        child: tabs,
      ),
      bottomNavigationBar: _buildBottomNav(useIosLiquidTab: useIosLiquidTab),
    );
  }

  static const Color _navOrange = Color(0xFFFF6B00);
  static const Color _navUnselected = Color(0xFF99A1AF);

  Widget _buildBottomNav({required bool useIosLiquidTab}) {
    if (useIosLiquidTab) {
      return IosLiquidGlassTabBar(
        selectedIndex: _currentIndex,
        cartBadge: _cartRecipeCount,
        onTabSelected: _onTabTapped,
        onNativeUnavailable: () {
          if (!mounted || _iosNativeTabFailed) return;
          setState(() => _iosNativeTabFailed = true);
        },
      );
    }
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.padding.bottom;
    // Keep a small, friendly breathing room under the nav bar.
    // If device has a home-indicator inset, use it; otherwise keep a subtle gap.
    final navBottomSafeGap = bottomInset > 0 ? bottomInset : 6.0;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: _currentIndex == 0
                ? Colors.white
                : const Color(0xFFF3F4F6),
            width: 1,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: 8, bottom: 8 + navBottomSafeGap),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(
              context,
              Icons.home_rounded,
              0,
              imageAsset: 'assets/icons/nav_home.png',
            ),
            _buildNavItem(
              context,
              Icons.forum_rounded,
              1,
              imageAsset: 'assets/icons/nav_community.png',
            ),
            _buildNavItem(
              context,
              Icons.shopping_cart_rounded,
              2,
              imageAsset: 'assets/icons/nav_cart.png',
            ),
            _buildNavItem(
              context,
              Icons.kitchen_rounded,
              3,
              key: _fridgeNavKey,
              imageAsset: 'assets/icons/nav_fridge.png',
            ),
            _buildNavItem(
              context,
              Icons.person_rounded,
              4,
              imageAsset: 'assets/icons/nav_profile.png',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    int index, {
    Key? key,
    String? imageAsset,
    String? svgAsset,
  }) {
    final isActive = _currentIndex == index;
    const labels = ['홈', '커뮤니티', '장바구니', '냉장고', '프로필'];
    final label = index < labels.length ? labels[index] : '';

    final iconColor = isActive ? _navOrange : _navUnselected;
    final labelColor = isActive ? _navOrange : _navUnselected;

    final Widget iconWidget = svgAsset != null
        ? SvgPicture.asset(
            svgAsset,
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
            placeholderBuilder: (_) => Icon(icon, size: 24, color: iconColor),
          )
        : imageAsset != null
        ? _buildBoldNavIcon(
            imageAsset,
            iconColor,
            fallback: Icon(icon, size: 24, color: iconColor),
          )
        : Icon(icon, size: 24, color: iconColor);

    // Fixed-height icon area so text doesn't shift when selected
    const double iconAreaHeight = 32.0;
    final Widget badgedIcon = (index == 2 && _cartRecipeCount > 0)
        ? Badge(
            offset: const Offset(8, -8),
            smallSize: 14,
            largeSize: 14,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            label: Text(
              '$_cartRecipeCount',
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            backgroundColor: _navOrange,
            child: iconWidget,
          )
        : iconWidget;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: iconAreaHeight,
          child: Center(child: badgedIcon),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: labelColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    final scaledContent = index == 3
        ? ScaleTransition(scale: _fridgeBounceScale, child: content)
        : content;

    return Expanded(
      key: key,
      child: GestureDetector(
        onTap: () {
          Haptics.selection();
          _onTabTapped(index);
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: scaledContent,
        ),
      ),
    );
  }

  Widget _buildBoldNavIcon(
    String asset,
    Color color, {
    required Widget fallback,
  }) {
    const size = 24.0;
    return Image.asset(
      asset,
      width: size,
      height: size,
      cacheWidth: 48,
      cacheHeight: 48,
      color: color,
      colorBlendMode: BlendMode.srcIn,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
