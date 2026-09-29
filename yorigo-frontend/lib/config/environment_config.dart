import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;

enum Environment { local, production, mobileTesting }

class EnvironmentConfig {
  // Set this to manually override the environment
  // Useful for mobile testing scenarios
  static Environment? _manualOverride;

  // Local backend URL (for emulator/simulator development)
  // Android emulator: Use actual local IP address instead of 10.0.2.2
  // Find your IP with: ipconfig (Windows) or ifconfig (macOS/Linux)
  /// Host machine LAN IP for Android devices/emulators hitting local uvicorn.
  /// Update via `ipconfig` if Wi‑Fi changes. Emulator fallback: 10.0.2.2.
  static const String _androidLocalHostIp = '10.90.40.87';

  static String get _localUrl {
    // 웹 환경에서는 Platform을 사용할 수 없으므로 기본값 반환
    if (kIsWeb) {
      return 'http://localhost:8000';
    }

    // 모바일/데스크톱 환경에서만 Platform 사용
    if (Platform.isAndroid) {
      return 'http://$_androidLocalHostIp:8000';
    }
    return 'http://localhost:8000';
  }

  // For mobile testing on physical devices (replace with your local IP)
  // Find your IP: macOS: `ifconfig | grep "inet "`, Windows: `ipconfig`
  static const String _mobileTestingUrl = 'http://10.90.40.87:8000';

  // Production backend URL — keep Railway until AWS cutover (see backend/docs/RAILWAY_TO_AWS_EC2_MIGRATION.md)
  static const String _productionUrl =
      'https://yorigo-agent-demo-production.up.railway.app';

  /// 맥미니 파싱 전담 워커 URL (Cloudflare Tunnel)
  static const String _parsingProductionUrl = 'https://parse.yorigo.kr';

  /// 데모 앱은 파싱을 맥미니로 보내지 않는다.
  static const bool useMacMiniParsing =
      String.fromEnvironment(
        'USE_MACMINI_PARSING',
        defaultValue: 'false',
      ) !=
      'false';

  /// Firebase Cloud Functions (us-central1) — 관리자 홈 섹션 큐레이션 등.
  static const String cloudFunctionsBaseUrl =
      'https://us-central1-codegate-f21f6.cloudfunctions.net';

  static String get adminHomeSectionCurationUrl =>
      '$cloudFunctionsBaseUrl/adminHomeSectionCuration';

  // Kakao SDK Keys
  static const String kakaoNativeAppKey = String.fromEnvironment(
    'KAKAO_NATIVE_APP_KEY',
    // Fallback keeps Kakao login working for default flutter run/build commands.
    defaultValue: '07fa51cd37d69a90ca4a849537a90ea2',
  );
  static const String kakaoJavaScriptAppKey = String.fromEnvironment(
    'KAKAO_JAVASCRIPT_APP_KEY',
    defaultValue: '286566ea5fdb3e42aa95e518505c878a',
  );
  static const String kakaoRestApiKey = String.fromEnvironment(
    'KAKAO_REST_API_KEY',
    defaultValue: '',
  );

  /// iOS: 기본값 `false` — 카카오톡 설치 시 톡 앱 로그인(앱으로 복귀) 우선, Android와 동일.
  /// 톡·앵커 문제가 계속되면 `KAKAO_IOS_PREFER_ACCOUNT_LOGIN=true`(카카오계정 웹만)로 우회한다.
  static const bool kakaoIosPreferAccountLogin =
      String.fromEnvironment(
        'KAKAO_IOS_PREFER_ACCOUNT_LOGIN',
        defaultValue: 'false',
      ) !=
      'false';

  /// Mixpanel project token — pass at build: `--dart-define-from-file=dart_defines.json` etc.
  static const String mixpanelProjectToken = String.fromEnvironment(
    'MIXPANEL_PROJECT_TOKEN',
    // 기본 빌드 명령(`flutter build ...`)에서도 Mixpanel이 동작하도록 기본값 유지
    defaultValue: 'a1bd36d986e8ac99ca46b94dac62f7b0',
  );

  /// Optional EU ingress: `https://api-eu.mixpanel.com`
  static const String mixpanelServerUrl = String.fromEnvironment(
    'MIXPANEL_SERVER_URL',
    defaultValue: '',
  );

  /// 추가 본인인증(PASS/SMS) 사용 여부.
  /// 기본값은 false(비활성화)이며, 필요 시 명시적으로 true로 활성화합니다.
  static const bool enableAdditionalVerification =
      String.fromEnvironment(
        'ENABLE_ADDITIONAL_VERIFICATION',
        defaultValue: 'false',
      ) !=
      'false';

  /// 기존 가입자 연령게이트 임시 예외 여부.
  /// 기본값 true: 기존 사용자 로그인 막힘 방지.
  static const bool enableLegacyAgeGateBypass =
      String.fromEnvironment(
        'ENABLE_LEGACY_AGE_GATE_BYPASS',
        defaultValue: 'true',
      ) !=
      'false';

  /// 연령게이트 강제 시작 시점(ISO8601).
  /// 비어 있으면 기존 계정 전체를 예외로 처리.
  static const String ageGateEnforceFromIso = String.fromEnvironment(
    'AGE_GATE_ENFORCE_FROM_ISO',
    defaultValue: '',
  );

  static DateTime? get ageGateEnforceFrom {
    final raw = ageGateEnforceFromIso.trim();
    if (raw.isEmpty) return null;
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Get the current environment
  static Environment get currentEnvironment {
    if (_manualOverride != null) {
      return _manualOverride!;
    }

    // In debug mode, default to local FastAPI on :8000.
    if (kDebugMode) {
      return Environment.local;
    }

    // Release and profile modes always use production
    return Environment.production;
  }

  /// Get the backend URL based on current environment
  static String get baseUrl {
    switch (currentEnvironment) {
      case Environment.local:
        return _localUrl;
      case Environment.mobileTesting:
        return mobileTestingUrl;
      case Environment.production:
        return _productionUrl;
    }
  }

  /// 파싱 API 전용 URL. USE_MACMINI_PARSING=false 이면 baseUrl과 동일.
  static String get parsingBaseUrl {
    if (!useMacMiniParsing) {
      return baseUrl;
    }
    switch (currentEnvironment) {
      case Environment.local:
        return _localUrl;
      case Environment.mobileTesting:
        return mobileTestingUrl;
      case Environment.production:
        return _parsingProductionUrl;
    }
  }

  /// 파싱 폴백 URL: 맥미니가 다운/응답불가일 때 사용하는 클라우드 백엔드.
  /// 항상 `baseUrl`(현재 활성 클라우드 = Railway 또는 AWS)을 가리키므로
  /// 클라우드 전환과 무관하게 폴백이 자동으로 올바른 대상을 향한다.
  static String get parsingFallbackUrl => baseUrl;

  /// 파싱 요청을 시도할 base URL을 우선순위 순서로 반환한다.
  /// [맥미니(주), 클라우드(폴백)] — 둘이 같으면(맥미니 비활성) 단일 항목.
  /// 맥미니가 죽으면 클라이언트가 클라우드로 자동 폴백한다.
  static List<String> get parsingBaseUrlCandidates {
    final primary = parsingBaseUrl;
    final fallback = parsingFallbackUrl;
    if (primary == fallback) {
      return <String>[primary];
    }
    return <String>[primary, fallback];
  }

  /// Manually set the environment (useful for testing)
  static void setEnvironment(Environment env) {
    _manualOverride = env;
    print('[EnvironmentConfig] Environment manually set to: $env');
    print('[EnvironmentConfig] Backend URL: $baseUrl');
  }

  /// Reset to automatic environment detection
  static void resetEnvironment() {
    _manualOverride = null;
    print('[EnvironmentConfig] Environment reset to automatic detection');
    print('[EnvironmentConfig] Current environment: $currentEnvironment');
    print('[EnvironmentConfig] Backend URL: $baseUrl');
  }

  /// Print current configuration (useful for debugging)
  static void printConfig() {
    print('=== Environment Configuration ===');
    print('Environment: $currentEnvironment');
    print('Backend URL: $baseUrl');
    print('Parsing URL: $parsingBaseUrl');
    print('Parsing fallback URL: $parsingFallbackUrl');
    print('Parsing candidates: $parsingBaseUrlCandidates');
    print('Mac mini parsing: $useMacMiniParsing');
    print(
      'Parsing process: Android==iOS '
      '(async → $parsingBaseUrl, fallback → $parsingFallbackUrl)',
    );
    print('Debug Mode: $kDebugMode');
    print('Release Mode: $kReleaseMode');
    print('Platform: $defaultTargetPlatform');
    print('Manual Override: ${_manualOverride ?? "None"}');
    print('================================');
  }

  /// When true and an admin is logged in: every **3** conversion-gap events are POSTed to
  /// `/admin/conversion-gaps/research-batch` (Gemini + embedded Google search URLs).
  static const bool enableConversionGapResearchBatch =
      String.fromEnvironment(
        'ENABLE_CONVERSION_GAP_RESEARCH_BATCH',
        defaultValue: 'false',
      ) !=
      'false';

  /// Update the mobile testing URL (useful if you need to change it at runtime)
  static String? _customMobileTestingUrl;

  static void setMobileTestingUrl(String url) {
    _customMobileTestingUrl = url;
    print('[EnvironmentConfig] Mobile testing URL set to: $url');
  }

  static String get mobileTestingUrl =>
      _customMobileTestingUrl ?? _mobileTestingUrl;
}
