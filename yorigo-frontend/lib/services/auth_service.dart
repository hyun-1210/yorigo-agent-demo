import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart' as kakao;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart'
    show kIsWeb, kDebugMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'recipe_service.dart';
import 'user_service.dart';
import 'analytics_service.dart';
import '../config/environment_config.dart';
import '../utils/coupang_subparam.dart';

class AgeVerificationResult {
  const AgeVerificationResult({
    required this.allowed,
    required this.isUnder14,
    required this.requiresAdditionalVerification,
    required this.reason,
    this.computedAge,
    this.recommendedVerificationMethod,
  });

  final bool allowed;
  final bool isUnder14;
  final bool requiresAdditionalVerification;
  final String reason;
  final int? computedAge;
  final String? recommendedVerificationMethod;
}

class PassVerificationResult {
  const PassVerificationResult({
    required this.verified,
    required this.reason,
    required this.retryable,
    required this.maxRetryCount,
    this.birthDate,
    this.referenceId,
    this.message,
  });

  final bool verified;
  final String reason;
  final bool retryable;
  final int maxRetryCount;
  final DateTime? birthDate;
  final String? referenceId;
  final String? message;
}

class SmsVerificationResult {
  const SmsVerificationResult({
    required this.verified,
    required this.reason,
    required this.retryable,
    required this.maxRetryCount,
    this.birthDate,
    this.referenceId,
    this.message,
  });

  final bool verified;
  final String reason;
  final bool retryable;
  final int maxRetryCount;
  final DateTime? birthDate;
  final String? referenceId;
  final String? message;
}

class NicePassInitResult {
  const NicePassInitResult({
    required this.requestId,
    required this.authActionUrl,
    required this.tokenVersionId,
    required this.encData,
    required this.integrityValue,
    required this.methodType,
    required this.verificationMethod,
  });

  final String requestId;
  final String authActionUrl;
  final String tokenVersionId;
  final String encData;
  final String integrityValue;
  final String methodType;
  final String verificationMethod;
}

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // 캐시/LRU 맵을 가진 RecipeService를 매번 새로 만들지 않고 공유 인스턴스를 사용한다.
  final RecipeService _recipeService = RecipeService.shared;
  final AnalyticsService _analyticsService = AnalyticsService();
  // Web client ID (client_type: 3) — Firebase/Google Cloud "Web application" OAuth client.
  // iOS/Android must pass this as serverClientId so Firebase gets a valid id_token; iOS also
  // needs AppDelegate to forward OAuth URLs to super (see AppDelegate.open url).
  static const String _googleWebClientId =
      '784944328733-engq2165koiihj0nshitqt4ftthh3l9s.apps.googleusercontent.com';
  // iOS/macOS native OAuth client (GoogleService-Info CLIENT_ID) — set explicitly so GID
  // sign-in is configured even if plist load order differs in release/TestFlight.
  static const String _googleIosClientId =
      '784944328733-ifnt308sg458cpo2l8kvaau2rqk9liim.apps.googleusercontent.com';

  static String? get _googleClientIdForPlatform {
    if (kIsWeb) {
      return _googleWebClientId;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return _googleIosClientId;
    }
    return null;
  }

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: _googleClientIdForPlatform,
    serverClientId: kIsWeb ? null : _googleWebClientId,
    scopes: ['email', 'openid'],
    forceCodeForRefreshToken: false,
  );
  static const bool _allowKakaoEmailPasswordFallback = false;

  /// iOS Kakao SDK 플러그인은 카카오톡·계정(웹)과 무관하게 같은
  /// `PlatformException(CANCELED, …)`만 돌려 UI 설명이 실제 진입 경로와 어긋날 수 있다.
  static String _kakaoIosLoginCanceledHint(Object? appleDetails) {
    final ds = appleDetails?.toString() ?? '';
    final norm = ds.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final code3AnchorHint = norm.contains('error 3') && norm.contains('authenticationservices')
        ? '\n• iOS 코드 3(AuthenticationServices …): 로그인 UI를 붙일 창(앵커) 문제입니다. '
            '`swift` 패치 문자열 `[yorigo] v3: Flutter embedding + all visible windows` 가 '
            'KakaoFlutterSdkCommonPlugin.swift 에 있어야 합니다. 없으면 `ios/`에서 다시 '
            '`pod install` 후 클린 빌드하세요.'
        : '';
    final tail = ds.trim().isNotEmpty ? '\n시스템 상세: ${ds.trim()}' : '';
    return '카카오 로그인이 완료되지 않았습니다. '
        'iOS는 카카오톡으로만 진행해도 동일하게 "취소(CANCELED)"만 오는 경우가 있어 브라우저만의 문제처럼 보이지 않을 수 있습니다.'
        '$tail$code3AnchorHint\n\n'
        '• 카카오톡 동의 후에도 간헐적이면 앱을 완전히 종료한 뒤 다시 시도하거나 카카오톡 업데이트를 확인해 주세요.\n'
        '• 카카오 쪽 추가 동의(웹)가 끼어든 뒤에는 처음부터 다시 로그인해 보세요.\n'
        '• 패치 검증 및 기타 플랫폼 확인은 위 메시지의 `[yorigo]` 안내를 따르세요.';
  }

  /// Kakao 플러터 이슈: 카카오톡 단계에서 [CANCELED]인데 카카오계정(브라우저)까지 이어 붙이면
  /// ASWeb 세션과 리다이렉트가 꼬여 잘못된 CANCEL이 난다 → 계정 폴백 생략.
  static bool _isKakaoTalkCanceledWrongToChainAccount(Object e) =>
      e is PlatformException && e.code == 'CANCELED';

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Auth state changes stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<AgeVerificationResult> verifyAgeGate({
    required DateTime birthDate,
    required String verificationMethod,
    required String provider,
  }) async {
    final baseUrl = EnvironmentConfig.baseUrl;
    final birthDateIso = birthDate.toIso8601String().split('T').first;

    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/age/verify'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'birth_date': birthDateIso,
            'verification_method': verificationMethod,
            'provider': provider,
          }),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode != 200) {
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}
      throw detail ?? '연령 검증 중 오류가 발생했습니다.';
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return AgeVerificationResult(
      allowed: decoded['allowed'] == true,
      isUnder14: decoded['is_under_14'] == true,
      requiresAdditionalVerification:
          decoded['requires_additional_verification'] == true,
      reason: decoded['reason']?.toString() ?? 'unknown',
      computedAge: (decoded['computed_age'] as num?)?.toInt(),
      recommendedVerificationMethod: decoded['recommended_verification_method']
          ?.toString(),
    );
  }

  Future<void> trackSocialSignupCompletion(String method) async {
    await _analyticsService.trackSignUp(method: method);
  }

  Future<PassVerificationResult> verifyPassIdentity({
    required String verificationToken,
    required String provider,
    required int retryCount,
    String? requestId,
  }) async {
    final baseUrl = EnvironmentConfig.baseUrl;
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/age/pass/verify'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'verification_token': verificationToken,
            'provider': provider,
            'retry_count': retryCount,
            'request_id': requestId,
          }),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode != 200) {
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}
      throw detail ?? 'PASS 인증 검증 중 오류가 발생했습니다.';
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    DateTime? birthDate;
    final birthDateRaw = decoded['birth_date']?.toString();
    if (birthDateRaw != null && birthDateRaw.isNotEmpty) {
      try {
        birthDate = DateTime.parse(birthDateRaw);
      } catch (_) {}
    }
    return PassVerificationResult(
      verified: decoded['verified'] == true,
      reason: decoded['reason']?.toString() ?? 'unknown',
      retryable: decoded['retryable'] == true,
      maxRetryCount: (decoded['max_retry_count'] as num?)?.toInt() ?? 3,
      birthDate: birthDate,
      referenceId: decoded['reference_id']?.toString(),
      message: decoded['message']?.toString(),
    );
  }

  Future<NicePassInitResult> initNicePassVerification({
    required String provider,
  }) async {
    final baseUrl = EnvironmentConfig.baseUrl;
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/age/pass/nice/init'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'provider': provider}),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode != 200) {
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}
      throw detail ?? 'NICE PASS 초기화에 실패했습니다.';
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return NicePassInitResult(
      requestId: decoded['request_id']?.toString() ?? '',
      authActionUrl: decoded['auth_action_url']?.toString() ?? '',
      tokenVersionId: decoded['token_version_id']?.toString() ?? '',
      encData: decoded['enc_data']?.toString() ?? '',
      integrityValue: decoded['integrity_value']?.toString() ?? '',
      methodType: decoded['method_type']?.toString() ?? 'get',
      verificationMethod: decoded['verification_method']?.toString() ?? 'pass',
    );
  }

  Future<SmsVerificationResult> verifySmsIdentity({
    required String verificationToken,
    required String provider,
    required int retryCount,
    String? requestId,
  }) async {
    final baseUrl = EnvironmentConfig.baseUrl;
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/age/sms/verify'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'verification_token': verificationToken,
            'provider': provider,
            'retry_count': retryCount,
            'request_id': requestId,
          }),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode != 200) {
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}
      throw detail ?? 'SMS 인증 검증 중 오류가 발생했습니다.';
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    DateTime? birthDate;
    final birthDateRaw = decoded['birth_date']?.toString();
    if (birthDateRaw != null && birthDateRaw.isNotEmpty) {
      try {
        birthDate = DateTime.parse(birthDateRaw);
      } catch (_) {}
    }
    return SmsVerificationResult(
      verified: decoded['verified'] == true,
      reason: decoded['reason']?.toString() ?? 'unknown',
      retryable: decoded['retryable'] == true,
      maxRetryCount: (decoded['max_retry_count'] as num?)?.toInt() ?? 3,
      birthDate: birthDate,
      referenceId: decoded['reference_id']?.toString(),
      message: decoded['message']?.toString(),
    );
  }

  Future<NicePassInitResult> initNiceSmsVerification({
    required String provider,
  }) async {
    final baseUrl = EnvironmentConfig.baseUrl;
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/age/sms/nice/init'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'provider': provider}),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode != 200) {
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}
      throw detail ?? 'NICE SMS 초기화에 실패했습니다.';
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return NicePassInitResult(
      requestId: decoded['request_id']?.toString() ?? '',
      authActionUrl: decoded['auth_action_url']?.toString() ?? '',
      tokenVersionId: decoded['token_version_id']?.toString() ?? '',
      encData: decoded['enc_data']?.toString() ?? '',
      integrityValue: decoded['integrity_value']?.toString() ?? '',
      methodType: decoded['method_type']?.toString() ?? 'get',
      verificationMethod: decoded['verification_method']?.toString() ?? 'sms',
    );
  }

  // Sign up with email and password
  Future<UserCredential?> signUpWithEmail({
    required String email,
    required String password,
    required String name,
    String? handle,
    DateTime? birthDate,
    String verificationMethod = 'self_reported',
    String provider = 'email',
  }) async {
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Update display name
      await userCredential.user?.updateDisplayName(name);
      await userCredential.user?.reload();

      // Create user document in Firestore
      if (userCredential.user != null) {
        await _createUserDocument(
          uid: userCredential.user!.uid,
          email: email,
          name: name,
          handle: handle,
          birthDate: birthDate,
          ageVerificationMethod: verificationMethod,
          signupProvider: provider,
        );
        await _analyticsService.trackSignUp(method: 'email');
      }

      // Migrate local recipes to Firebase after successful signup
      try {
        final migratedCount = await _recipeService
            .migrateLocalRecipesToFirebase();
        if (migratedCount > 0) {
          print(
            '[AuthService] Migrated $migratedCount local recipes to Firebase after signup',
          );
        }
      } catch (e) {
        // Don't fail signup if migration fails - just log it
        print('[AuthService] Warning: Failed to migrate local recipes: $e');
      }

      // Note: Profile picture migration and thumbnail migration are not needed
      // for new signups since the user has no recipes yet. These migrations
      // will be handled during login when the user accesses existing recipes.

      return userCredential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Create user document in Firestore
  Future<void> _createUserDocument({
    required String uid,
    required String email,
    required String name,
    String? handle,
    String? kakaoId,
    DateTime? birthDate,
    String? ageVerificationMethod,
    String? signupProvider,
  }) async {
    try {
      // Use provided handle or generate a unique one
      final userService = UserService();
      final finalHandle = handle != null && handle.isNotEmpty
          ? handle
          : await userService.generateUniqueHandle(name, forUserId: uid);

      // 가입 시 유저당 고정 1개. 이후 재발급하지 않는다.
      final coupangSubparam = generateCoupangSubparam();
      final userData = <String, dynamic>{
        'uid': uid,
        'email': email,
        'name': name,
        'handle': finalHandle,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'lastAccessedAt': FieldValue.serverTimestamp(),
        'savedRecipes': [],
        'cartItems': [],
        'coupangSubparam': coupangSubparam,
      };

      // 카카오 ID가 있으면 추가
      if (kakaoId != null) {
        userData['kakaoId'] = kakaoId;
      }
      if (birthDate != null) {
        userData['birthDate'] = birthDate.toIso8601String().split('T').first;
        userData['isAgeVerified14Plus'] = true;
        userData['ageVerifiedAt'] = FieldValue.serverTimestamp();
        userData['ageVerificationMethod'] =
            ageVerificationMethod ?? 'self_reported';
      }
      if (signupProvider != null && signupProvider.isNotEmpty) {
        userData['signupProvider'] = signupProvider;
      }

      await _firestore.collection('users').doc(uid).set(userData);
      UserService.cacheCoupangSubparam(uid, coupangSubparam);
      await userService.syncUserHandleRegistry(
        uid: uid,
        newHandle: finalHandle,
        previousHandle: null,
      );
    } catch (e) {
      // Log error but don't throw - user account is already created
      print('Error creating user document: $e');
    }
  }

  // Sign in with email and password
  Future<UserCredential?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Update last accessed timestamp
      if (userCredential.user != null) {
        final userService = UserService();
        await userService.updateLastAccessed(userCredential.user!.uid);
        await _analyticsService.trackLogin(method: 'email');
      }

      // Migrate local recipes to Firebase after successful login
      try {
        final migratedCount = await _recipeService
            .migrateLocalRecipesToFirebase();
        if (migratedCount > 0) {
          print(
            '[AuthService] Migrated $migratedCount local recipes to Firebase after login',
          );
        }
      } catch (e) {
        // Don't fail login if migration fails - just log it
        print('[AuthService] Warning: Failed to migrate local recipes: $e');
      }

      // DISABLED: Automatic thumbnail migration on login
      // This was causing automatic parse_recipe API calls even when users weren't using the app
      // Uncomment below if you want to re-enable automatic migration
      // _recipeService.migrateThumbnailsToStorage(allRecipes: true).catchError((e) {
      //   print('[AuthService] Warning: Failed to migrate thumbnails: $e');
      //   return <String, int>{
      //     'updated': 0,
      //     'recovered': 0,
      //     'skipped': 0,
      //     'errors': 0,
      //   };
      // });

      return userCredential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // Sign in with Google
  // Returns UserCredential and a boolean indicating if it's a new user
  Future<Map<String, dynamic>?> signInWithGoogle() async {
    try {
      // Sign out any existing Google Sign-In session to ensure fresh authentication
      // This prevents issues with cached scopes that might request People API
      await _googleSignIn.signOut();

      // Trigger the authentication flow
      // On web, try signInSilently first to avoid deprecation warnings
      GoogleSignInAccount? googleUser;
      if (kIsWeb) {
        try {
          // Try silent sign-in first (for web) - this won't show popup if user is already signed in
          googleUser = await _googleSignIn.signInSilently();
        } catch (e) {
          // Silent sign-in failed, user needs to sign in explicitly
          if (kDebugMode) {
            print('[AuthService] Silent sign-in failed: $e');
          }
        }

        // If silent sign-in didn't work, use signIn (will show deprecation warning but still works)
        // Note: This is deprecated on web but still functional
        googleUser ??= await _googleSignIn.signIn();
      } else {
        // For mobile platforms, use signIn directly
        googleUser = await _googleSignIn.signIn();
      }

      if (googleUser == null) {
        // User canceled the sign-in
        return null;
      }

      // Obtain the auth details from the request
      // Wrap in try-catch to handle People API errors specifically
      GoogleSignInAuthentication googleAuth;
      try {
        googleAuth = await googleUser.authentication;
      } catch (authError) {
        // If authentication fails (e.g., People API error), log and rethrow
        print('[AuthService] Error getting Google authentication: $authError');
        final errorString = authError.toString();
        if (errorString.contains('People API') ||
            errorString.contains('403') ||
            errorString.contains('PERMISSION_DENIED') ||
            errorString.contains('SERVICE_DISABLED')) {
          throw 'Google 로그인 설정 오류입니다. 관리자에게 문의해주세요.';
        }
        rethrow;
      }

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase with the Google credential
      final userCredential = await _auth.signInWithCredential(credential);

      if (userCredential.user == null) {
        return null;
      }

      // Check if user document exists in Firestore to determine if it's a new user
      final userDoc = await _firestore
          .collection('users')
          .doc(userCredential.user!.uid)
          .get();

      final isNewUser = !userDoc.exists;

      if (!isNewUser) {
        // Existing user - update last accessed and migrate recipes
        final userService = UserService();
        await userService.updateLastAccessed(userCredential.user!.uid);
        await userService.ensureUserEmailIfEmpty(
          uid: userCredential.user!.uid,
          email: userCredential.user!.email,
          emailSource: 'google',
        );
        await _analyticsService.trackLogin(method: 'google');

        // Migrate local recipes to Firebase after successful sign-in
        await _migrateRecipesAfterSignIn();
      }

      return {
        'userCredential': userCredential,
        'isNewUser': isNewUser,
        'socialProvider': 'google',
        'authPath': 'google_oauth',
        'socialBirthDate': null,
      };
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      // Log the full error for debugging
      print('[AuthService] Google sign-in error: $e');

      // Check if error is related to People API
      final errorString = e.toString();
      if (errorString.contains('People API') ||
          errorString.contains('403') ||
          errorString.contains('PERMISSION_DENIED') ||
          errorString.contains('SERVICE_DISABLED')) {
        // People API is not enabled or not accessible
        // This is a configuration issue that cannot be resolved by retrying
        throw 'Google 로그인 설정 오류입니다. 관리자에게 문의해주세요.';
      }

      // For other errors, provide a generic message
      throw '구글 로그인 중 오류가 발생했습니다: ${e.toString().replaceAll(RegExp(r'^Exception: '), '')}';
    }
  }

  // Sign in with Apple
  // Returns UserCredential and a boolean indicating if it's a new user
  Future<Map<String, dynamic>?> signInWithApple() async {
    try {
      // Check if platform supports Apple Sign In
      // Note: Web support for sign_in_with_apple is limited and may cause JSObject errors
      // It's recommended to use Apple Sign-In only on iOS and macOS
      if (kIsWeb) {
        throw 'Apple 로그인은 현재 웹에서 지원되지 않습니다. iOS 또는 macOS에서 사용해주세요.';
      }

      if (!Platform.isIOS && !Platform.isMacOS) {
        throw 'Apple 로그인은 iOS, macOS에서만 사용할 수 있습니다.';
      }

      // Request credential for the currently signed in Apple account
      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      // Create an OAuth credential
      final oAuthCredential = OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        accessToken: appleCredential.authorizationCode,
      );

      // Sign in to Firebase with the Apple credential
      final userCredential = await _auth.signInWithCredential(oAuthCredential);
      if (userCredential.user == null) {
        return null;
      }

      final userDoc = await _firestore
          .collection('users')
          .doc(userCredential.user!.uid)
          .get();
      final isNewUser = !userDoc.exists;

      // Use Apple's provided name if available, otherwise use a default
      String displayName = 'Apple User';
      if (appleCredential.givenName != null ||
          appleCredential.familyName != null) {
        displayName =
            '${appleCredential.givenName ?? ''} ${appleCredential.familyName ?? ''}'
                .trim();
      }

      await _createUserDocumentIfNotExists(
        uid: userCredential.user!.uid,
        email: userCredential.user!.email ?? '',
        name: displayName,
      );

      // Update Firebase Auth display name if not set
      if (userCredential.user!.displayName == null &&
          displayName != 'Apple User') {
        await userCredential.user!.updateDisplayName(displayName);
      }

      if (!isNewUser) {
        // Existing user - update last accessed and migrate recipes
        final userService = UserService();
        await userService.updateLastAccessed(userCredential.user!.uid);
        await userService.ensureUserEmailIfEmpty(
          uid: userCredential.user!.uid,
          email: userCredential.user!.email,
          emailSource: 'apple',
        );
        await _analyticsService.trackLogin(method: 'apple');
        await _migrateRecipesAfterSignIn();
      }

      return {
        'userCredential': userCredential,
        'isNewUser': isNewUser,
        'socialProvider': 'apple',
        'authPath': 'apple_oauth',
        // Apple Sign In SDK doesn't provide DOB for this flow.
        'socialBirthDate': null,
      };
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw 'Apple 로그인 중 오류가 발생했습니다: $e';
    }
  }

  /// 카카오 OAuth 코드·토큰 획득 (플랫폼별 분기).
  ///
  /// iOS + [EnvironmentConfig.kakaoIosPreferAccountLogin]: 카카오계정만 사용 (톡 앱 리다이렉트 회피).
  Future<kakao.OAuthToken> _acquireKakaoOAuthToken() async {
    if (!kIsWeb &&
        Platform.isIOS &&
        EnvironmentConfig.kakaoIosPreferAccountLogin) {
      print(
        '[AuthService] Kakao iOS: 카카오계정(시스템 웹)만 사용 '
        '(KAKAO_IOS_PREFER_ACCOUNT_LOGIN)',
      );
      return await kakao.UserApi.instance.loginWithKakaoAccount();
    }

    if (await kakao.isKakaoTalkInstalled()) {
      try {
        final token = await kakao.UserApi.instance.loginWithKakaoTalk();
        print('[AuthService] Kakao login successful via KakaoTalk');
        return token;
      } catch (e) {
        print('[AuthService] KakaoTalk login failed: $e');
        if (e is PlatformException &&
            e.code == 'CANCELED' &&
            Platform.isIOS &&
            !(e.message ?? '').toLowerCase().contains('user canceled login')) {
          try {
            final token = await kakao.UserApi.instance.loginWithKakaoAccount();
            print(
              '[AuthService] Kakao login successful via KakaoAccount (iOS Talk→Account retry)',
            );
            return token;
          } catch (accountError) {
            print(
              '[AuthService] KakaoAccount retry after Talk failed: $accountError',
            );
            if (accountError is PlatformException &&
                accountError.code == 'CANCELED') {
              throw kakao.KakaoClientException(
                kakao.ClientErrorCause.cancelled,
                '',
              );
            }
            rethrow;
          }
        }
        if (_isKakaoTalkCanceledWrongToChainAccount(e)) {
          print(
            '[AuthService] KakaoTalk flow CANCELED; skip KakaoAccount fallback',
          );
          throw kakao.KakaoClientException(kakao.ClientErrorCause.cancelled, '');
        }
        print('[AuthService] Falling back to KakaoAccount login...');
        return await kakao.UserApi.instance.loginWithKakaoAccount();
      }
    }

    print(
      '[AuthService] Kakao login via KakaoAccount (KakaoTalk not installed)',
    );
    return await kakao.UserApi.instance.loginWithKakaoAccount();
  }

  // Sign in with Kakao
  // Returns UserCredential and a boolean indicating if it's a new user
  Future<Map<String, dynamic>?> signInWithKakao() async {
    try {
      if (!kIsWeb && EnvironmentConfig.kakaoNativeAppKey.trim().isEmpty) {
        throw '카카오 로그인을 사용할 수 없습니다(Native 앱 키가 빌드에 없음). '
            '`flutter build ipa --release --dart-define-from-file=dart_defines.json` 로 '
            '다시 빌드하거나, Xcode 아카이브 전에 해당 Flutter 명령으로 생성된 '
            '`ios/Flutter/Generated.xcconfig` 가 최신인지 확인해주세요.';
      }

      // 웹 환경에서는 카카오 로그인 지원 안 함
      // 카카오 Flutter SDK는 웹 환경을 지원하지 않음 (Javascript env validation failed)
      // Custom Token 방식은 백엔드 API를 사용하므로 웹에서도 테스트 가능하지만,
      // 카카오 SDK 자체가 웹에서 작동하지 않을 수 있음
      // 테스트를 위해 임시로 주석 처리 - 실제 프로덕션에서는 활성화 필요
      // if (kIsWeb) {
      //   throw '웹 환경에서는 카카오 로그인을 지원하지 않습니다. 모바일 앱에서 이용해주세요.';
      // }

      if (kIsWeb) {
        print('[AuthService] ⚠ 웹 환경에서 카카오 로그인 테스트 중 (Custom Token 방식)');
      }

      final token = await _acquireKakaoOAuthToken();
      return await _handleKakaoLogin(token);
    } on kakao.KakaoClientException catch (e) {
      if (e.reason == kakao.ClientErrorCause.cancelled) {
        print('[AuthService] Kakao login cancelled (client)');
        return null;
      }
      rethrow;
    } on PlatformException catch (e, stackTrace) {
      print(
        '[AuthService] Kakao PlatformException: code=${e.code} message=${e.message} '
        'details=${e.details}\n$stackTrace',
      );
      if (e.code == 'CANCELED') {
        throw _kakaoIosLoginCanceledHint(e.details);
      }
      if (e.code == 'REDIRECT_URL_MISMATCH' ||
          e.code == 'REDIRET_URL_MISMATCH') {
        throw '카카오 로그인 리다이렉트 URI가 맞지 않습니다. Native App Key와 '
            'iOS/Android의 kakao URL Scheme이 동일한지 확인하세요.';
      }
      throw '카카오 로그인 중 오류가 발생했습니다: ${e.message ?? e.code}';
    } catch (e) {
      print('[AuthService] Kakao sign-in error: $e');
      final errorString = e.toString();

      // 사용자가 로그인 취소
      if (errorString.contains('UserCancel') ||
          errorString.contains('CancelledException') ||
          errorString.contains('사용자가 취소')) {
        print('[AuthService] User cancelled Kakao login');
        return null;
      }

      // 웹(Flutter 웹 빌드)에서만 카카오 JS 경로 불가 안내. 동일 문자열/invalid_request는
      // 네이티브 오류(API·키 설정)에서도 나올 수 있어 무조건 "웹"으로 안내하면 혼선이 난다.
      if (kIsWeb &&
          (errorString.contains('Javascript env validation failed') ||
              errorString.contains('invalid_request'))) {
        throw '웹 환경에서는 카카오 로그인을 지원하지 않습니다. iOS 또는 Android 앱에서 이용해주세요.';
      }

      // KOE009 / 카카오 콘솔 플랫폼 불일치 (번들 ID 미등록·오타 등)
      final lc = errorString.toLowerCase();
      if (!kIsWeb &&
          Platform.isIOS &&
          (lc.contains('bundle validation') ||
              lc.contains('ios_bundle_id') ||
              lc.contains('misconfigured') ||
              lc.contains('invalid android_key_hash'))) {
        throw '카카오 iOS 번들 ID가 등록되어 있지 않거나 앱과 다릅니다. 카카오 개발자 '
            '[내 애플리케이션] → 사용 중인 앱(Native 앱 키가 빌드와 같은 앱) → 플랫폼 '
            '→ iOS 에 Bundle ID를 `com.yorigo.kr`(Xcode Runner와 동일)로 저장한 뒤 다시 시도해 주세요.';
      }

      // 인증 오류 처리
      if (errorString.contains('AuthException') ||
          errorString.contains('OAuthException')) {
        throw '카카오 로그인 인증에 실패했습니다. 다시 시도해주세요.';
      }

      throw '카카오 로그인 중 오류가 발생했습니다: ${errorString.replaceAll(RegExp(r'^Exception: '), '')}';
    }
  }

  // 카카오 로그인 처리 헬퍼 메서드
  Future<Map<String, dynamic>?> _handleKakaoLogin(
    kakao.OAuthToken token,
  ) async {
    try {
      // 카카오 사용자 정보 가져오기
      kakao.User user = await kakao.UserApi.instance.me();
      print('[AuthService] Kakao user info retrieved: ${user.id}');

      // 카카오 이메일이 없으면 에러
      if (user.kakaoAccount?.email == null) {
        throw '카카오 이메일 정보가 필요합니다. 카카오 개발자 콘솔에서 이메일 동의 항목을 설정해주세요.';
      }

      final String email = user.kakaoAccount!.email!;
      final String displayName =
          user.kakaoAccount?.profile?.nickname ??
          user.kakaoAccount?.name ??
          '카카오 사용자';

      print('[AuthService] Kakao email: $email, displayName: $displayName');

      // ========== Custom Token 방식 (권장) ==========
      // 데이터 일관성을 위해 백엔드 커스텀 토큰 + 백엔드 링크 동기화가 기본 경로입니다.
      print('[AuthService] Requesting Firebase Custom Token from backend...');

      String? customToken;
      String? kakaoIdFromCustomToken;
      String? kakaoBirthDateFromCustomToken;
      bool requiresProfileCompletion = false;

      try {
        final baseUrl = EnvironmentConfig.baseUrl;
        final response = await http
            .post(
              Uri.parse('$baseUrl/auth/kakao/custom-token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'access_token': token.accessToken}),
            )
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw Exception('Backend API request timeout');
              },
            );

        if (response.statusCode == 200) {
          final responseData =
              jsonDecode(response.body) as Map<String, dynamic>;
          customToken = responseData['custom_token'] as String;
          kakaoIdFromCustomToken = responseData['kakao_id'] as String;
          kakaoBirthDateFromCustomToken = responseData['birth_date'] as String?;
          requiresProfileCompletion =
              responseData['requires_profile_completion'] == true;
          print('[AuthService] ✅ Received Firebase Custom Token from backend');
        } else {
          print(
            '[AuthService] ❌ Backend API error: ${response.statusCode} - ${response.body}',
          );
          if (!_allowKakaoEmailPasswordFallback) {
            throw '카카오 로그인 서버 연동에 실패했습니다. 잠시 후 다시 시도해주세요.';
          }
        }
      } catch (e) {
        print('[AuthService] ❌ Custom Token API failed: $e');
        if (!_allowKakaoEmailPasswordFallback) {
          throw '카카오 로그인 서버 연동에 실패했습니다. 잠시 후 다시 시도해주세요.';
        }
      }

      if (customToken != null) {
        if (requiresProfileCompletion) {
          // 연령/프로필 완료 전에는 Firebase 로그인(세션 생성)을 지연한다.
          return {
            'userCredential': null,
            'isNewUser': true,
            'socialProvider': 'kakao',
            'authPath': 'kakao_pending_signup',
            'socialBirthDate': kakaoBirthDateFromCustomToken,
            'pendingKakaoCustomToken': customToken,
            'pendingKakaoAccessToken': token.accessToken,
            'pendingKakaoEmail': email,
            'pendingKakaoDisplayName': displayName,
            'pendingKakaoId': kakaoIdFromCustomToken,
          };
        }

        // Custom Token으로 Firebase Auth 로그인
        final userCredential = await _auth.signInWithCustomToken(customToken);
        if (userCredential.user == null) {
          throw 'Firebase Custom Token 로그인에 실패했습니다. 잠시 후 다시 시도해주세요.';
        }

        print('[AuthService] ✅ Signed in with Firebase Custom Token');

        // Firebase Auth user 정보 최신화 (providerData가 제대로 반영되도록)
        await userCredential.user!.reload();
        print('[AuthService] Reloaded user to update providerData');

        // 백엔드에서 kakao_id -> uid 매핑을 강제하여 중복 연결을 차단한다.
        await _linkKakaoOnBackend(
          accessToken: token.accessToken,
          user: userCredential.user!,
        );

        bool isNewUser = false;
        final userDoc = await _firestore
            .collection('users')
            .doc(userCredential.user!.uid)
            .get();

        isNewUser = !userDoc.exists;

        if (!isNewUser) {
          // 기존 사용자 - 카카오 ID 강제 동기화
          if (kakaoIdFromCustomToken != null) {
            await _firestore
                .collection('users')
                .doc(userCredential.user!.uid)
                .set({
                  'kakaoId': kakaoIdFromCustomToken,
                  'updatedAt': FieldValue.serverTimestamp(),
                }, SetOptions(merge: true));
            print('[AuthService] Synced user document with Kakao ID');
          }

          final userService = UserService();
          await userService.updateLastAccessed(userCredential.user!.uid);
          // Auth.email이 null인 카카오 custom token → SDK email로 empty-only backfill
          await userService.ensureUserEmailIfEmpty(
            uid: userCredential.user!.uid,
            email: email,
            emailSource: 'kakao',
          );
          await _analyticsService.trackLogin(method: 'kakao');
          await _migrateRecipesAfterSignIn();
        }

        return {
          'userCredential': userCredential,
          'isNewUser': isNewUser,
          'socialProvider': 'kakao',
          'authPath': 'custom_token',
          'socialBirthDate': kakaoBirthDateFromCustomToken,
        };
      }

      if (!_allowKakaoEmailPasswordFallback) {
        throw '카카오 로그인 서버 연동에 실패했습니다. 잠시 후 다시 시도해주세요.';
      }

      print('[AuthService] 기존 방식(이메일/비밀번호)으로 fallback...');

      // ========== 기존 방식 (Fallback) ==========
      // 백엔드 API 실패 시 기존 이메일/비밀번호 방식 사용
      // 카카오 ID 기반 고정 비밀번호 생성 (accessToken 제외하여 항상 동일하게)
      // 카카오 ID는 고유하므로 이를 기반으로 비밀번호 생성
      final kakaoId = user.id.toString();
      final tempPassword = 'kakao_$kakaoId';

      print(
        '[AuthService] Using fallback method: Kakao ID: $kakaoId, Generated password pattern: kakao_*',
      );

      // Firestore에서 카카오 ID로 기존 사용자 찾기
      final existingUserQuery = await _firestore
          .collection('users')
          .where('kakaoId', isEqualTo: kakaoId)
          .limit(1)
          .get();

      UserCredential? userCredential;
      bool isNewUser = false;

      if (existingUserQuery.docs.isNotEmpty) {
        // Firestore에 카카오 ID로 가입한 사용자가 있음 - 기존 사용자 로그인
        final existingUserDoc = existingUserQuery.docs.first;
        final existingEmail = existingUserDoc.data()['email'] as String?;
        final existingUid = existingUserDoc.id;

        print(
          '[AuthService] Found existing user with Kakao ID: $existingUid, email: $existingEmail',
        );

        // 카카오 비밀번호로 로그인 시도 (먼저 로그인해야 Firestore 업데이트 권한이 있음)
        try {
          userCredential = await _auth.signInWithEmailAndPassword(
            email: email,
            password: tempPassword,
          );
          isNewUser = false;
          print('[AuthService] Signed in existing Kakao user');

          // 로그인 성공 후 이메일이 null이거나 다르면 현재 카카오 이메일로 업데이트
          if (existingEmail == null || existingEmail != email) {
            print(
              '[AuthService] Updating email in Firestore from $existingEmail to $email',
            );
            try {
              await _firestore.collection('users').doc(existingUid).update({
                'email': email,
                'updatedAt': FieldValue.serverTimestamp(),
              });
            } catch (updateError) {
              print(
                '[AuthService] Warning: Failed to update email in Firestore: $updateError',
              );
              // 업데이트 실패해도 로그인은 성공했으므로 계속 진행
            }
          }
        } catch (e) {
          print('[AuthService] Error signing in with Kakao password: $e');
          // 비밀번호가 맞지 않으면 Firebase Auth에 계정이 없을 수 있음
          // 이메일로 계정 생성 시도
          try {
            userCredential = await _auth.createUserWithEmailAndPassword(
              email: email,
              password: tempPassword,
            );
            isNewUser = false; // Firestore에는 이미 존재하므로 새 사용자 아님
            print(
              '[AuthService] Created Firebase Auth account for existing Firestore user',
            );

            // 계정 생성 후 이메일 업데이트
            if (existingEmail == null || existingEmail != email) {
              print(
                '[AuthService] Updating email in Firestore from $existingEmail to $email',
              );
              try {
                await _firestore.collection('users').doc(existingUid).update({
                  'email': email,
                  'updatedAt': FieldValue.serverTimestamp(),
                });
              } catch (updateError) {
                print(
                  '[AuthService] Warning: Failed to update email in Firestore: $updateError',
                );
                // 업데이트 실패해도 계정 생성은 성공했으므로 계속 진행
              }
            }
          } catch (createError) {
            print(
              '[AuthService] Error creating Firebase Auth account: $createError',
            );
            // email-already-in-use 오류인 경우, 다른 비밀번호일 수 있음
            // 하지만 카카오 ID 기반 비밀번호는 항상 동일하므로 이 경우는 드뭄
            if (createError.toString().contains('email-already-in-use')) {
              throw '이 이메일은 다른 로그인 방법으로 가입되어 있습니다. 해당 방법으로 로그인해주세요.';
            }
            throw '카카오 로그인 중 오류가 발생했습니다. 다시 시도해주세요.';
          }
        }
      } else {
        // Firestore에 카카오 ID로 가입한 사용자가 없음
        // 기존 계정이 있는지 확인
        final signInMethods = await _auth.fetchSignInMethodsForEmail(email);
        print(
          '[AuthService] Existing sign-in methods for $email: $signInMethods',
        );

        if (signInMethods.isEmpty) {
          // 새 사용자 - 카카오로 처음 가입
          try {
            userCredential = await _auth.createUserWithEmailAndPassword(
              email: email,
              password: tempPassword,
            );
            isNewUser = true;
            print('[AuthService] New Kakao user created in Firebase');
          } catch (e) {
            print('[AuthService] Error creating new user: $e');
            // 계정이 이미 존재할 수 있음 (동시 생성 시도 등)
            if (e.toString().contains('email-already-in-use')) {
              // 이미 존재하는 경우, 카카오 비밀번호로 로그인 시도
              try {
                userCredential = await _auth.signInWithEmailAndPassword(
                  email: email,
                  password: tempPassword,
                );
                isNewUser = false;
                print(
                  '[AuthService] Signed in existing user with Kakao password',
                );
              } catch (signInError) {
                print('[AuthService] Error signing in: $signInError');
                // 카카오 비밀번호가 맞지 않으면 다른 방식으로 가입한 계정
                throw '이 이메일은 다른 로그인 방법으로 가입되어 있습니다. 해당 방법으로 로그인해주세요.';
              }
            } else {
              throw 'Firebase 계정 생성 중 오류가 발생했습니다: $e';
            }
          }
        } else {
          // 기존 사용자 - 카카오 비밀번호로 로그인 시도
          try {
            userCredential = await _auth.signInWithEmailAndPassword(
              email: email,
              password: tempPassword,
            );
            isNewUser = false;
            print('[AuthService] Signed in existing user with Kakao');
          } catch (e) {
            print('[AuthService] Error signing in existing user: $e');
            // 비밀번호가 맞지 않는 경우 (다른 방식으로 가입했을 수 있음)
            throw '이 이메일은 다른 로그인 방법으로 가입되어 있습니다. 해당 방법으로 로그인해주세요.';
          }
        }
      }

      // userCredential은 모든 경로에서 할당되므로 null이 아님
      final firebaseUser = userCredential.user;
      if (firebaseUser == null) {
        throw 'Firebase 사용자 정보를 가져올 수 없습니다.';
      }

      // Firebase Auth display name 업데이트
      if (firebaseUser.displayName == null ||
          firebaseUser.displayName != displayName) {
        await firebaseUser.updateDisplayName(displayName);
        await firebaseUser.reload();
        print('[AuthService] Updated display name to: $displayName');
      }

      // Firestore에 사용자 문서 생성 또는 업데이트
      final userDoc = await _firestore
          .collection('users')
          .doc(firebaseUser.uid)
          .get();

      if (userDoc.exists) {
        // 기존 사용자 - 카카오 ID가 없으면 추가
        final userData = userDoc.data();
        if (userData != null && userData['kakaoId'] == null) {
          await _firestore.collection('users').doc(firebaseUser.uid).update({
            'kakaoId': kakaoId,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          print('[AuthService] Updated user document with Kakao ID');
        }

        // last accessed 업데이트
        final userService = UserService();
        await userService.updateLastAccessed(firebaseUser.uid);

        // 레시피 마이그레이션
        await _migrateRecipesAfterSignIn();
        print('[AuthService] Updated last accessed and migrated recipes');
      }

      return {
        'userCredential': userCredential,
        'isNewUser': isNewUser,
        'socialProvider': 'kakao',
        'authPath': 'email_password_fallback',
        'socialBirthDate': null,
      };
    } catch (e) {
      print('[AuthService] Error in _handleKakaoLogin: $e');
      rethrow;
    }
  }

  Future<void> _linkKakaoOnBackend({
    required String accessToken,
    required User user,
  }) async {
    final firebaseIdToken = await user.getIdToken();
    final baseUrl = EnvironmentConfig.baseUrl;
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/kakao/link'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'access_token': accessToken,
            'firebase_id_token': firebaseIdToken,
          }),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode == 200) {
      print('[AuthService] Kakao link synced on backend');
      return;
    }

    String? detail;
    try {
      final decoded = jsonDecode(response.body);
      detail = decoded is Map ? decoded['detail']?.toString() : null;
    } catch (_) {}

    if (response.statusCode == 409) {
      throw detail ?? '이미 다른 계정에 연결된 카카오 계정입니다.';
    }
    if (response.statusCode == 401) {
      throw detail ?? '로그인 정보가 유효하지 않습니다. 다시 로그인해주세요.';
    }
    if (response.statusCode == 503 || response.statusCode == 504) {
      throw detail ?? '카카오 로그인 서버가 일시적으로 불안정합니다. 잠시 후 다시 시도해주세요.';
    }
    throw detail ?? '카카오 계정 연결 동기화 중 오류가 발생했습니다.';
  }

  Future<UserCredential> completeDeferredKakaoSignup({
    required String customToken,
    required String accessToken,
    String? kakaoIdHint,
  }) async {
    // 혹시 남아 있을 수 있는 세션을 정리하고 최종 로그인 처리.
    if (_auth.currentUser != null) {
      await signOut();
    }

    final userCredential = await _auth.signInWithCustomToken(customToken);
    final signedInUser = userCredential.user;
    if (signedInUser == null) {
      throw '카카오 로그인 완료 처리에 실패했습니다.';
    }

    await signedInUser.reload();
    await _linkKakaoOnBackend(accessToken: accessToken, user: signedInUser);

    if (kakaoIdHint != null && kakaoIdHint.isNotEmpty) {
      await _firestore.collection('users').doc(signedInUser.uid).set({
        'kakaoId': kakaoIdHint,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    return userCredential;
  }

  // Helper method to create user document if it doesn't exist
  Future<void> _createUserDocumentIfNotExists({
    required String uid,
    required String email,
    required String name,
  }) async {
    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      if (!userDoc.exists) {
        await _createUserDocument(uid: uid, email: email, name: name);
      } else {
        // 기존 소셜 유저 문서에 subparam이 없으면 한 번만 채운다.
        await UserService().ensureCoupangSubparam(uid);
      }
    } catch (e) {
      print('Error checking/creating user document: $e');
    }
  }

  // Helper method to migrate recipes after sign-in
  Future<void> _migrateRecipesAfterSignIn() async {
    try {
      final migratedCount = await _recipeService
          .migrateLocalRecipesToFirebase();
      if (migratedCount > 0) {
        print(
          '[AuthService] Migrated $migratedCount local recipes to Firebase after social sign-in',
        );
      }
    } catch (e) {
      print('[AuthService] Warning: Failed to migrate local recipes: $e');
    }

    // DISABLED: Automatic thumbnail migration on login
    // This was causing automatic parse_recipe API calls even when users weren't using the app
    // Uncomment below if you want to re-enable automatic migration
    // _recipeService.migrateThumbnailsToStorage(allRecipes: true).catchError((e) {
    //   print('[AuthService] Warning: Failed to migrate thumbnails: $e');
    //   return <String, int>{
    //     'updated': 0,
    //     'recovered': 0,
    //     'skipped': 0,
    //     'errors': 0,
    //   };
    // });
  }

  // Get list of linked providers for current user
  List<String> getLinkedProviders() {
    final user = _auth.currentUser;
    if (user == null) return [];

    return user.providerData.map((info) => info.providerId).toList();
  }

  // Check if a specific provider is linked
  bool isProviderLinked(String providerId) {
    return getLinkedProviders().contains(providerId);
  }

  // Check if Kakao is linked (stored in Firestore, not in Firebase providerData)
  Future<bool> isKakaoLinked() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final data = doc.data();
      return data != null && data['kakaoId'] != null;
    } catch (e) {
      print('[AuthService] Error checking Kakao link: $e');
      return false;
    }
  }

  // Best-effort check: compare stored kakaoId with current Kakao session user.
  // If Kakao session is unavailable/expired, optionally fall back to the stored value check.
  Future<bool> isKakaoLinkedToCurrentKakaoSession({
    bool fallbackToStored = true,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final data = doc.data();
      final storedKakaoId = data?['kakaoId'];
      if (storedKakaoId == null) return false;

      final kakaoUser = await kakao.UserApi.instance.me();
      final currentKakaoId = kakaoUser.id.toString();
      return storedKakaoId.toString() == currentKakaoId;
    } catch (e) {
      print('[AuthService] Error checking Kakao session link: $e');
      if (!fallbackToStored) return false;
      return await isKakaoLinked();
    }
  }

  // Link Kakao account to current user (writes kakaoId to Firestore only)
  Future<bool> linkKakaoAccount() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw '로그인이 필요합니다.';
    }
    if (await isKakaoLinked()) {
      throw '카카오톡 계정이 이미 연결되어 있습니다.';
    }
    try {
      final token = await _acquireKakaoOAuthToken();

      final firebaseIdToken = await user.getIdToken();
      final baseUrl = EnvironmentConfig.baseUrl;

      final response = await http
          .post(
            Uri.parse('$baseUrl/auth/kakao/link'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'access_token': token.accessToken,
              'firebase_id_token': firebaseIdToken,
            }),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Backend API request timeout'),
          );

      if (response.statusCode == 200) {
        print('[AuthService] Kakao account linked successfully (backend)');
        return true;
      }

      // Backend errors are returned as { "detail": "..." }
      String? detail;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded is Map ? decoded['detail']?.toString() : null;
      } catch (_) {}

      if (response.statusCode == 409) {
        throw detail ?? '이미 다른 계정에 연결된 카카오 계정입니다.';
      }
      if (response.statusCode == 401) {
        throw detail ?? '로그인 정보가 유효하지 않습니다. 다시 로그인해주세요.';
      }
      if (response.statusCode == 503 || response.statusCode == 504) {
        throw detail ?? '카카오톡 연결 중 서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
      }

      throw detail ?? '카카오톡 연결 중 오류가 발생했습니다.';
    } on kakao.KakaoClientException catch (e) {
      if (e.reason == kakao.ClientErrorCause.cancelled) {
        return false;
      }
      rethrow;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') {
        throw _kakaoIosLoginCanceledHint(e.details);
      }
      if (e.code == 'REDIRECT_URL_MISMATCH' ||
          e.code == 'REDIRET_URL_MISMATCH') {
        throw '카카오 로그인 리다이렉트 URI가 맞지 않습니다. Native App Key와 '
            'iOS/Android의 kakao URL Scheme이 동일한지 확인하세요.';
      }
      throw '카카오톡 연결 중 오류가 발생했습니다: ${e.message ?? e.code}';
    } catch (e) {
      // If we already threw a user-facing string (e.g. backend detail), keep it as-is.
      if (e is String) {
        if (e.contains('UserCancel') ||
            e.contains('CancelledException') ||
            e.contains('사용자가 취소')) {
          return false;
        }
        rethrow;
      }
      final s = e.toString();
      if (s.contains('UserCancel') ||
          s.contains('CancelledException') ||
          s.contains('사용자가 취소')) {
        return false;
      }

      // Network/server layer messages
      if (s.contains('SocketException') ||
          s.contains('Failed host lookup') ||
          s.contains('Connection refused')) {
        throw '네트워크 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
      }

      // Preserve our domain error messages without wrapping.
      final normalized = s.replaceAll(RegExp(r'^Exception:\s*'), '');
      if (normalized.contains('이미 다른 계정에 연결된 카카오 계정입니다.')) {
        throw normalized;
      }
      throw '카카오톡 연결 중 오류가 발생했습니다: $e';
    }
  }

  // Unlink Kakao (remove mapping + kakaoId from Firestore via backend)
  Future<void> unlinkKakaoAccount() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw '로그인이 필요합니다.';
    }
    if (!await isKakaoLinked()) {
      throw '연결되지 않은 계정입니다.';
    }
    final linked = getLinkedProviders();
    if (linked.isEmpty) {
      throw '최소 하나의 로그인 방법이 필요합니다. 다른 계정을 먼저 연결해주세요.';
    }

    final firebaseIdToken = await user.getIdToken();
    final baseUrl = EnvironmentConfig.baseUrl;

    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/kakao/unlink'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'firebase_id_token': firebaseIdToken}),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Backend API request timeout'),
        );

    if (response.statusCode == 200) {
      print('[AuthService] Kakao account unlinked successfully (backend)');
      return;
    }

    String? detail;
    try {
      final decoded = jsonDecode(response.body);
      detail = decoded is Map ? decoded['detail']?.toString() : null;
    } catch (_) {}

    if (response.statusCode == 400) {
      throw detail ?? '연결되지 않은 계정입니다.';
    }
    if (response.statusCode == 401) {
      throw detail ?? '로그인 정보가 유효하지 않습니다. 다시 로그인해주세요.';
    }
    if (response.statusCode == 503 || response.statusCode == 504) {
      throw detail ?? '카카오톡 연결 해제 중 서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
    }

    throw detail ?? '카카오톡 연결 해제 중 오류가 발생했습니다.';
  }

  // Link Google account to current user
  Future<void> linkGoogleAccount() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw '로그인이 필요합니다.';
      }

      // Check if Google is already linked
      if (isProviderLinked('google.com')) {
        throw 'Google 계정이 이미 연결되어 있습니다.';
      }

      // Sign out any existing Google Sign-In session to ensure fresh authentication
      await _googleSignIn.signOut();

      // Trigger the Google authentication flow
      // On web, try signInSilently first to avoid deprecation warnings
      GoogleSignInAccount? googleUser;
      if (kIsWeb) {
        // Try silent sign-in first (for web)
        googleUser = await _googleSignIn.signInSilently();
        // If silent sign-in fails, use signIn (will show deprecation warning but still works)
        googleUser ??= await _googleSignIn.signIn();
      } else {
        // For mobile platforms, use signIn directly
        googleUser = await _googleSignIn.signIn();
      }

      if (googleUser == null) {
        // User canceled the sign-in
        return;
      }

      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Link the credential to the current user
      await user.linkWithCredential(credential);

      print('[AuthService] Google account linked successfully');
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use') {
        throw '이 Google 계정은 이미 다른 사용자에게 연결되어 있습니다.';
      } else if (e.code == 'provider-already-linked') {
        throw 'Google 계정이 이미 연결되어 있습니다.';
      }
      throw _handleAuthException(e);
    } catch (e) {
      throw 'Google 계정 연결 중 오류가 발생했습니다: $e';
    }
  }

  // Link Apple account to current user
  Future<void> linkAppleAccount() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw '로그인이 필요합니다.';
      }

      // Check if Apple is already linked
      if (isProviderLinked('apple.com')) {
        throw 'Apple 계정이 이미 연결되어 있습니다.';
      }

      // Request credential for the currently signed in Apple account
      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      // Create an OAuth credential
      final oAuthCredential = OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        accessToken: appleCredential.authorizationCode,
      );

      // Link the credential to the current user
      await user.linkWithCredential(oAuthCredential);

      print('[AuthService] Apple account linked successfully');
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use') {
        throw '이 Apple 계정은 이미 다른 사용자에게 연결되어 있습니다.';
      } else if (e.code == 'provider-already-linked') {
        throw 'Apple 계정이 이미 연결되어 있습니다.';
      }
      throw _handleAuthException(e);
    } catch (e) {
      throw 'Apple 계정 연결 중 오류가 발생했습니다: $e';
    }
  }

  // Unlink a provider from current user
  Future<void> unlinkProvider(String providerId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw '로그인이 필요합니다.';
      }

      if (providerId == 'kakao') {
        await unlinkKakaoAccount();
        return;
      }

      // Check if provider is linked
      if (!isProviderLinked(providerId)) {
        throw '연결되지 않은 계정입니다.';
      }

      // Don't allow unlinking if it's the only provider
      if (user.providerData.length <= 1) {
        throw '최소 하나의 로그인 방법이 필요합니다. 다른 계정을 먼저 연결해주세요.';
      }

      // Unlink the provider
      await user.unlink(providerId);

      // If it's Google, also sign out from Google Sign In
      if (providerId == 'google.com') {
        await _googleSignIn.signOut();
      }

      print('[AuthService] Provider $providerId unlinked successfully');
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw '계정 연결 해제 중 오류가 발생했습니다: $e';
    }
  }

  // Get provider display name in Korean
  String getProviderDisplayName(String providerId) {
    switch (providerId) {
      case 'password':
        return '이메일';
      case 'google.com':
        return 'Google';
      case 'apple.com':
        return 'Apple';
      case 'kakao':
        return '카카오톡';
      default:
        return providerId;
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _analyticsService.trackLogout();
    } catch (e) {
      print('[AuthService] Warning: failed to track logout: $e');
    }
    await _googleSignIn.signOut();
    await _auth.signOut();
    UserService.clearRecipebookSyncState();
    UserService.clearOnboardingProfileCache();
  }

  // Handle Firebase Auth exceptions
  String _handleAuthException(FirebaseAuthException e) {
    switch (e.code) {
      case 'weak-password':
        return '비밀번호가 너무 약합니다. 더 강력한 비밀번호를 사용해주세요.';
      case 'email-already-in-use':
        return '이미 사용 중인 이메일입니다.';
      case 'user-not-found':
        return '사용자를 찾을 수 없습니다.';
      case 'wrong-password':
        return '잘못된 비밀번호입니다.';
      case 'invalid-email':
        return '유효하지 않은 이메일 주소입니다.';
      case 'user-disabled':
        return '비활성화된 계정입니다.';
      case 'too-many-requests':
        return '너무 많은 요청이 발생했습니다. 잠시 후 다시 시도해주세요.';
      case 'operation-not-allowed':
        return '이메일 로그인이 활성화되지 않았습니다.';
      case 'invalid-credential':
        return '잘못된 인증 정보입니다.';
      default:
        return '인증 오류가 발생했습니다: ${e.message}';
    }
  }

  // Send password reset email
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  /// 비밀번호 재설정 메일 발송. 계정 존재 여부는 노출하지 않습니다.
  Future<void> requestPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      await _analyticsService.trackPasswordResetRequested();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        return;
      }
      throw _handleAuthException(e);
    }
  }

  // Delete user account and all associated data
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인된 사용자가 없습니다.');
    }

    try {
      final firebaseIdToken = await user.getIdToken();
      final baseUrl = EnvironmentConfig.baseUrl;

      final response = await http
          .post(
            Uri.parse('$baseUrl/auth/account/delete'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'firebase_id_token': firebaseIdToken}),
          )
          .timeout(
            // 서버가 recipes/reviews/follows 등 다수 컬렉션을 지우므로 20s는 부족하다.
            const Duration(seconds: 90),
            onTimeout: () => throw Exception(
              '계정 삭제 처리 시간이 초과되었습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요.',
            ),
          );

      if (response.statusCode != 200) {
        String? detail;
        try {
          final decoded = jsonDecode(response.body);
          detail = decoded is Map ? decoded['detail']?.toString() : null;
        } catch (_) {}
        throw Exception(detail ?? '계정 삭제 요청 처리 중 오류가 발생했습니다.');
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final legalHold = payload['legal_hold_applied'] == true;
      final deleted = payload['deleted'] == true;
      final message = payload['message']?.toString() ?? '계정 삭제 처리 상태를 확인하세요.';

      if (legalHold || !deleted) {
        throw Exception(message);
      }

      try {
        await _analyticsService.trackAccountDeleted();
      } catch (e) {
        print('[AuthService] Warning: failed to track account deletion: $e');
      }

      // Server-side deletion does not always invalidate local auth state immediately.
      // Force local sign-out so UI/session is cleared right away.
      try {
        await signOut();
      } catch (signOutError) {
        // Deletion already succeeded on backend; do not fail the flow due to local sign-out issue.
        print('[AuthService] Warning: local sign-out after deletion failed: $signOutError');
      }
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      print('[AuthService] Error deleting account: $e');
      rethrow;
    }
  }
}
