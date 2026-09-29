import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import '../theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../services/recipe_service.dart';
import '../utils/username_suggestion_generator.dart';
import '../utils/auth_navigation.dart';
import '../models/onboarding_profile.dart';
import 'terms_agreement_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _handleController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  bool _isLoading = false;
  bool _isGoogleSignIn = false; // Track if user came from Google sign-in
  bool _isKakaoSignIn = false; // Track if user came from Kakao sign-in
  bool _isAppleSignIn = false; // Track if user came from Apple sign-in
  String? _socialProviderFromRoute;
  String? _pendingKakaoCustomToken;
  String? _pendingKakaoAccessToken;
  String? _pendingKakaoEmail;
  String? _pendingKakaoDisplayName;
  String? _pendingKakaoId;
  DateTime? _selectedBirthDate;
  bool _isBirthDateFromSocialProfile = false;
  bool _forceSocialCompleteFromRoute = false;
  bool _socialTermsPreAgreed = false;
  bool _isNewUserFromRoute = false;
  bool _routeArgsApplied = false;
  int _routeArgsRetryCount = 0;
  static const int _maxRouteArgsRetryCount = 8;

  late final UsernameSuggestionGenerator _usernameGenerator =
      UsernameSuggestionGenerator();

  bool get _isSocialSignup =>
      _isGoogleSignIn || _isKakaoSignIn || _isAppleSignIn;
  bool get _isDeferredKakaoSignup =>
      _isKakaoSignIn &&
      (_pendingKakaoCustomToken?.isNotEmpty == true) &&
      (_pendingKakaoAccessToken?.isNotEmpty == true);

  @override
  void initState() {
    super.initState();
    _checkSocialLoginStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _generateAndApplySuggestion();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeArgsApplied) return;
    final applied = _applyRouteArguments();
    if (!applied) {
      _scheduleRouteArgumentsRetry();
    }
  }

  bool _applyRouteArguments() {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args == null) {
      print('[SignupScreen] Route args not ready yet, will retry');
      return false;
    }
    if (args is! Map) {
      _routeArgsApplied = true;
      return true;
    }

    final forceSocialComplete = args['forceSocialComplete'] == true;
    final socialProvider = args['socialProvider']?.toString();
    final socialBirthDateRaw = args['socialBirthDate']?.toString();
    final socialBirthDate = _tryParseBirthDate(socialBirthDateRaw);
    final pendingKakaoCustomToken = args['pendingKakaoCustomToken']?.toString();
    final pendingKakaoAccessToken = args['pendingKakaoAccessToken']?.toString();
    final pendingKakaoEmail = args['pendingKakaoEmail']?.toString();
    final pendingKakaoDisplayName = args['pendingKakaoDisplayName']?.toString();
    final pendingKakaoId = args['pendingKakaoId']?.toString();
    final socialTermsPreAgreed = args['socialTermsPreAgreed'] == true;
    final isNewUser = args['isNewUser'] == true;
    if (!forceSocialComplete || socialProvider == null) {
      _routeArgsApplied = true;
      return true;
    }

    setState(() {
      _forceSocialCompleteFromRoute = true;
      _isNewUserFromRoute = isNewUser;
      _isGoogleSignIn = socialProvider == 'google';
      _isKakaoSignIn = socialProvider == 'kakao';
      _isAppleSignIn = socialProvider == 'apple';
      _socialProviderFromRoute = socialProvider;
      _pendingKakaoCustomToken = pendingKakaoCustomToken;
      _pendingKakaoAccessToken = pendingKakaoAccessToken;
      _pendingKakaoEmail = pendingKakaoEmail;
      _pendingKakaoDisplayName = pendingKakaoDisplayName;
      _pendingKakaoId = pendingKakaoId;
      _socialTermsPreAgreed = socialTermsPreAgreed;
      if (socialBirthDate != null) {
        _selectedBirthDate = socialBirthDate;
        _isBirthDateFromSocialProfile = true;
      }
      if ((pendingKakaoEmail ?? '').isNotEmpty) {
        _emailController.text = pendingKakaoEmail!;
      }
      if (_nameController.text.trim().isEmpty &&
          (pendingKakaoDisplayName ?? '').isNotEmpty) {
        _nameController.text = pendingKakaoDisplayName!;
      }
    });
    _routeArgsApplied = true;

    print(
      '[SignupScreen] Applied route args - socialProvider: $socialProvider, forceSocialComplete: $forceSocialComplete',
    );
    return true;
  }

  DateTime? _tryParseBirthDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return DateTime.parse(raw).toLocal();
    } catch (_) {
      return null;
    }
  }

  /// 소셜 가입 시 Firestore에 넣을 이메일.
  /// 카카오 custom token은 Auth.email이 null이므로 pendingKakaoEmail을 우선한다.
  String? _resolveSocialEmailForPersist(String? authEmail) {
    return UserService.resolvePersistableEmail(
      pendingSocialEmail: _pendingKakaoEmail,
      formEmail: _emailController.text.trim(),
      authEmail: authEmail,
    );
  }

  void _scheduleRouteArgumentsRetry() {
    if (!mounted || _routeArgsApplied) return;
    if (_routeArgsRetryCount >= _maxRouteArgsRetryCount) {
      print('[SignupScreen] Route args retry limit reached');
      _routeArgsApplied = true;
      return;
    }

    _routeArgsRetryCount++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _routeArgsApplied) return;
      final applied = _applyRouteArguments();
      if (!applied) {
        _scheduleRouteArgumentsRetry();
      }
    });
  }

  Future<void> _checkSocialLoginStatus() async {
    // If user is already logged in (e.g., from Google/Kakao sign-in), prefill information
    final currentUser = _authService.currentUser;
    if (currentUser == null) {
      // Deferred Kakao signup mode: not signed in yet by design.
      if (_isDeferredKakaoSignup && mounted) {
        setState(() {
          if ((_pendingKakaoEmail ?? '').isNotEmpty) {
            _emailController.text = _pendingKakaoEmail!;
          }
          if (_nameController.text.trim().isEmpty &&
              (_pendingKakaoDisplayName ?? '').isNotEmpty) {
            _nameController.text = _pendingKakaoDisplayName!;
          }
        });
      }
      return;
    }

    // Firebase Auth user 정보 최신화 (providerData가 제대로 반영되도록)
    // auth_service에서 이미 reload()를 호출했지만, 화면 전환 타이밍 문제로
    // 여기서 다시 한 번 reload()를 호출하여 최신 정보를 가져옴
    try {
      await currentUser.reload();
      print('[SignupScreen] Reloaded user to get latest providerData');
    } catch (e) {
      print('[SignupScreen] Warning: Failed to reload user: $e');
      // reload 실패해도 계속 진행
    }

    // 최신 정보로 다시 가져오기
    final refreshedUser = _authService.currentUser;
    if (refreshedUser == null) return;

    // 로그인 화면에서 소셜 완료 모드를 명시 전달한 경우 우선 적용
    if (_forceSocialCompleteFromRoute) {
      if (mounted) {
        setState(() {
          _emailController.text = refreshedUser.email ?? '';
        });
      }
      return;
    }

    // Check if user came from Google sign-in (has google.com provider)
    _isGoogleSignIn = refreshedUser.providerData.any(
      (info) => info.providerId == 'google.com',
    );
    _isAppleSignIn = refreshedUser.providerData.any(
      (info) => info.providerId == 'apple.com',
    );

    // Check if user came from Kakao sign-in
    // 카카오 로그인은 두 가지 방식이 있음:
    // 1. Custom Token 방식: providerId가 'custom' (단, Firebase는 Custom Token 시 providerData를 비움!)
    // 2. Fallback 방식 (이메일/비밀번호): providerId가 'password'
    // 두 경우 모두 Firestore에 kakaoId가 있을 수 있음
    if (!_isGoogleSignIn && !_isAppleSignIn) {
      try {
        // 먼저 provider 확인 (custom 또는 password)
        final hasCustomProvider = refreshedUser.providerData.any(
          (info) => info.providerId == 'custom',
        );
        final hasPasswordProvider = refreshedUser.providerData.any(
          (info) => info.providerId == 'password',
        );
        // Custom Token 로그인 시 providerData가 비어 있음( Firebase 동작 ). 이 경우 Firestore kakaoId로만 판별 가능.
        final isProviderDataEmpty = refreshedUser.providerData.isEmpty;

        // Custom Token 방식인 경우 즉시 카카오로 간주 (providerData에 'custom'이 있는 경우)
        if (hasCustomProvider) {
          _isKakaoSignIn = true;
          print(
            '[SignupScreen] Detected Kakao login via Custom Token (custom provider)',
          );
        } else {
          // Firestore 문서 확인 (여러 번 시도하여 문서 생성 대기)
          bool foundKakaoId = false;
          for (int i = 0; i < 8; i++) {
            final userDoc = await _userService.getUserDocument(
              refreshedUser.uid,
            );
            if (userDoc.exists) {
              final userData = userDoc.data() as Map<String, dynamic>?;
              if (userData?['kakaoId'] != null) {
                foundKakaoId = true;
                print(
                  '[SignupScreen] Found kakaoId in Firestore document (attempt ${i + 1})',
                );
                break;
              }
            }
            if (i < 7) {
              await Future.delayed(Duration(milliseconds: 500));
            }
          }

          if (foundKakaoId) {
            _isKakaoSignIn = true;
            print('[SignupScreen] Detected Kakao login via Firestore kakaoId');
          } else if (hasPasswordProvider) {
            _isKakaoSignIn = true;
            print(
              '[SignupScreen] Detected Kakao login via password provider (fallback method)',
            );
          } else if (isProviderDataEmpty) {
            // Custom Token은 providerData가 비어 있음. 아직 Firestore에 kakaoId가 안 보일 수 있으므로
            // "로그인됨 + 이메일 있음 + Google 아님 + provider 비어 있음"이면 카카오 Custom Token으로 간주.
            _isKakaoSignIn = true;
            print(
              '[SignupScreen] Detected Kakao login via empty providerData (Custom Token fallback)',
            );
          }
        }
      } catch (e) {
        print('[SignupScreen] Error checking Kakao status: $e');
        final hasCustomProvider = refreshedUser.providerData.any(
          (info) => info.providerId == 'custom',
        );
        final hasPasswordProvider = refreshedUser.providerData.any(
          (info) => info.providerId == 'password',
        );
        final isProviderDataEmpty = refreshedUser.providerData.isEmpty;
        _isKakaoSignIn =
            hasCustomProvider || hasPasswordProvider || isProviderDataEmpty;
        if (_isKakaoSignIn) {
          print(
            '[SignupScreen] Detected Kakao login via fallback (error case)',
          );
        }
      }
    }

    print(
      '[SignupScreen] Social login status - Google: $_isGoogleSignIn, Kakao: $_isKakaoSignIn, Apple: $_isAppleSignIn',
    );

    if (_isSocialSignup) {
      // Prefill email only; name/handle come from username suggestion (set in addPostFrameCallback)
      if (mounted) {
        setState(() {
          _emailController.text = refreshedUser.email ?? '';
        });
      }
    }
  }

  /// Generate a Korean display name + English userId pair and apply internally.
  /// Keeps values already set from onboarding unless [forceHandle] is true.
  Future<void> _generateAndApplySuggestion({bool forceHandle = false}) async {
    var suggestion = _usernameGenerator.generate();
    String handle = suggestion.userId;

    for (int i = 0; i < 20; i++) {
      final candidate = i == 0 ? handle : '${handle}_${i + 1}';
      final available = await _userService.isHandleAvailable(
        candidate,
        exceptUserId: _authService.currentUser?.uid,
      );
      if (available) {
        handle = candidate;
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = suggestion.displayName;
      }
      if (forceHandle || _handleController.text.trim().isEmpty) {
        _handleController.text = handle;
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String _birthDateLabel() {
    final birthDate = _selectedBirthDate;
    if (birthDate == null) return '생년월일을 선택해주세요';
    final yyyy = birthDate.year.toString().padLeft(4, '0');
    final mm = birthDate.month.toString().padLeft(2, '0');
    final dd = birthDate.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }

  Future<void> _pickBirthDate() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    final initialDate =
        _selectedBirthDate ?? DateTime(2000, now.month, now.day);
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      isScrollControlled: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BirthDateWheelPicker(
        initialDate: initialDate,
        minYear: 1900,
        maxDate: now,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedBirthDate = DateTime(picked.year, picked.month, picked.day);
      _isBirthDateFromSocialProfile = false;
    });
  }

  Future<void> _cleanupBlockedSocialSignupSession() async {
    if (!_isSocialSignup) return;
    final currentUser = _authService.currentUser;
    if (currentUser == null) return;

    try {
      // If social pre-signup user is blocked by age gate, remove partial account/session.
      await _authService.deleteAccount();
    } catch (e) {
      print(
        '[SignupScreen] Warning: failed to delete blocked social pre-signup account: $e',
      );
      try {
        await _authService.signOut();
      } catch (signOutError) {
        print(
          '[SignupScreen] Warning: failed to sign out after blocked social signup: $signOutError',
        );
      }
    }
  }

  Future<void> _handleSignUp() async {
    if (_isLoading) return;

    var handle = _handleController.text.trim().toLowerCase().replaceFirst(
      '@',
      '',
    );
    if (handle.isEmpty) {
      await _generateAndApplySuggestion();
      handle = _handleController.text.trim().toLowerCase().replaceFirst(
        '@',
        '',
      );
    }

    if (!_isSocialSignup) {
      if (_emailController.text.trim().isEmpty ||
          _passwordController.text.trim().isEmpty ||
          _confirmPasswordController.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('모든 필드를 입력해주세요.')));
        return;
      }
    }

    if (_selectedBirthDate == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('생년월일을 선택해주세요.')));
      return;
    }

    if (handle.length < 3 ||
        handle.length > 24 ||
        !RegExp(r'^[a-z0-9_]+$').hasMatch(handle)) {
      await _generateAndApplySuggestion(forceHandle: true);
      handle = _handleController.text.trim().toLowerCase().replaceFirst(
        '@',
        '',
      );
    }

    setState(() {
      _isLoading = true;
    });

    bool isAvailable = false;
    try {
      isAvailable = await _userService.isHandleAvailable(
        handle,
        exceptUserId: _authService.currentUser?.uid,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('아이디 확인 중 오류가 발생했습니다: $e')));
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }
    if (!isAvailable) {
      await _generateAndApplySuggestion(forceHandle: true);
      handle = _handleController.text.trim().toLowerCase().replaceFirst(
        '@',
        '',
      );
    }

    // Password validation only for regular signup
    if (!_isSocialSignup) {
      if (_passwordController.text != _confirmPasswordController.text) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('비밀번호가 일치하지 않습니다.')));
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      if (_passwordController.text.length < 6) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('비밀번호는 최소 6자 이상이어야 합니다.')));
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }
    }

    try {
      if (_isSocialSignup && !_socialTermsPreAgreed) {
        final agreed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const TermsAgreementScreen(
              returnResultInsteadOfNavigating: true,
              allowUnauthenticatedContinue: true,
            ),
          ),
        );
        if (agreed != true) {
          return;
        }
      }

      final provider =
          _socialProviderFromRoute ??
          (_isGoogleSignIn
              ? 'google'
              : _isKakaoSignIn
              ? 'kakao'
              : _isAppleSignIn
              ? 'apple'
              : 'email');
      final verificationMethod = _isSocialSignup
          ? (_isBirthDateFromSocialProfile
                ? 'social_profile'
                : 'self_reported')
          : 'self_reported';
      final ageResult = await _authService.verifyAgeGate(
        birthDate: _selectedBirthDate!,
        verificationMethod: verificationMethod,
        provider: provider,
      );
      if (!mounted) return;
      if (!ageResult.allowed) {
        if (ageResult.isUnder14) {
          await _cleanupBlockedSocialSignupSession();
          if (!mounted) return;
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('만 14세 미만은 가입할 수 없습니다. 로그인 정보가 정리되었습니다.'),
            ),
          );
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        } else if (ageResult.requiresAdditionalVerification) {
          final recommended = ageResult.recommendedVerificationMethod ?? 'PASS';
          showAppSnackBar(context, 
            SnackBar(content: Text('추가 본인인증이 필요합니다. 권장 방식: $recommended')),
          );
        } else {
          showAppSnackBar(context, 
            const SnackBar(content: Text('연령 검증에 실패했습니다. 다시 시도해주세요.')),
          );
        }
        return;
      }

      // 현재 로그인 상태 재확인 (중요: _isKakaoSignIn이 false일 수 있지만 실제로는 로그인된 상태일 수 있음)
      final currentUser = _authService.currentUser;
      if (currentUser != null) {
        // Firebase Auth user 정보 최신화
        try {
          await currentUser.reload();
        } catch (e) {
          print(
            '[SignupScreen] Warning: Failed to reload user in _handleSignUp: $e',
          );
        }

        // 최신 정보로 다시 가져오기
        final refreshedUser = _authService.currentUser;
        if (refreshedUser != null) {
          // provider 확인
          final hasGoogleProvider = refreshedUser.providerData.any(
            (info) => info.providerId == 'google.com',
          );
          final hasAppleProvider = refreshedUser.providerData.any(
            (info) => info.providerId == 'apple.com',
          );
          final hasCustomProvider = refreshedUser.providerData.any(
            (info) => info.providerId == 'custom',
          );
          final hasPasswordProvider = refreshedUser.providerData.any(
            (info) => info.providerId == 'password',
          );

          // Firestore에서 kakaoId 확인
          bool hasKakaoId = false;
          try {
            final userDoc = await _userService.getUserDocument(
              refreshedUser.uid,
            );
            if (userDoc.exists) {
              final userData = userDoc.data() as Map<String, dynamic>?;
              hasKakaoId = userData?['kakaoId'] != null;
            }
          } catch (e) {
            print('[SignupScreen] Warning: Failed to check kakaoId: $e');
          }

          // 이미 소셜 로그인된 상태인지 확인
          // Custom Token은 providerData가 비어 있어 hasCustomProvider가 false이므로, Firestore kakaoId만으로도 카카오로 판단.
          final isSocialLogin =
              hasGoogleProvider ||
              hasAppleProvider ||
              hasCustomProvider ||
              hasKakaoId ||
              (hasPasswordProvider && hasKakaoId);

          if (isSocialLogin) {
            // 이미 소셜 로그인된 상태 - 일반 회원가입으로 처리하지 않음
            print(
              '[SignupScreen] User is already logged in via social login, updating profile instead',
            );

            // _isKakaoSignIn 또는 _isGoogleSignIn 플래그 업데이트 (Custom Token은 providerData 비어 있어 hasKakaoId로만 판별)
            if (hasGoogleProvider) {
              _isGoogleSignIn = true;
            } else if (hasAppleProvider) {
              _isAppleSignIn = true;
            } else if (hasCustomProvider ||
                hasKakaoId ||
                (hasPasswordProvider && hasKakaoId)) {
              _isKakaoSignIn = true;
            }
          }
        }
      }

      if (_isSocialSignup) {
        // 소셜 가입: 이미 로그인된 유저 또는(정석 플로우) deferred 카카오 완료 후 유저
        var currentUser = _authService.currentUser;
        if (currentUser == null && _isDeferredKakaoSignup) {
          final completed = await _authService.completeDeferredKakaoSignup(
            customToken: _pendingKakaoCustomToken!,
            accessToken: _pendingKakaoAccessToken!,
            kakaoIdHint: _pendingKakaoId,
          );
          currentUser = completed.user;
        }
        if (currentUser == null) {
          throw '로그인 상태를 확인할 수 없습니다.';
        }

        var name = _nameController.text.trim();
        if (name.isEmpty) {
          name = _usernameGenerator.generate().displayName;
          _nameController.text = name;
        }

        // 카카오는 custom token이라 Auth.email이 null → pendingKakaoEmail 우선
        final resolvedEmail = _resolveSocialEmailForPersist(currentUser.email);

        // Update user document with name and handle (creates if doesn't exist)
        await _userService.updateUserProfile(
          uid: currentUser.uid,
          email: resolvedEmail,
          emailSource: resolvedEmail != null ? provider : null,
          name: name,
          handle: handle,
          birthDate: _birthDateLabel(),
          ageVerificationMethod: verificationMethod,
          signupProvider: provider,
          isAgeVerified14Plus: true,
          onboardingRequired: OnboardingDecision.shouldStampOnboardingRequired(
            isSocialSignup: true,
            isNewUser: _isNewUserFromRoute,
          ),
        );
        // empty-only 안전망 (기존 email이 있으면 no-op)
        await _userService.ensureUserEmailIfEmpty(
          uid: currentUser.uid,
          email: resolvedEmail,
          emailSource: provider,
        );
        await _userService.recordTermsAgreement(currentUser.uid);
        if (_isSocialSignup) {
          await _authService.trackSocialSignupCompletion(provider);
        }

        // Also update Firebase Auth display name
        if (currentUser.displayName != name) {
          await currentUser.updateDisplayName(name);
          await currentUser.reload();
        }

        // Migrate local recipes to Firebase
        final recipeService = RecipeService();
        try {
          final migratedCount = await recipeService
              .migrateLocalRecipesToFirebase();
          if (migratedCount > 0) {
            print(
              '[SignupScreen] Migrated $migratedCount local recipes to Firebase',
            );
          }
        } catch (e) {
          print('[SignupScreen] Warning: Failed to migrate local recipes: $e');
        }

        if (!mounted) return;

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('회원가입이 완료되었습니다!')));

        if (!mounted) return;
        AuthNavigation.navigateToAuthenticatedHome(context);
      } else {
        // Regular email/password signup
        // 단, 현재 로그인된 상태가 아닐 때만 계정 생성
        final currentUserBeforeSignup = _authService.currentUser;
        if (currentUserBeforeSignup != null) {
          // 이미 로그인된 상태인데 소셜 로그인이 아닌 경우
          // 이는 예상치 못한 상황이므로 에러 처리
          throw '이미 로그인된 상태입니다. 로그아웃 후 다시 시도해주세요.';
        }

        // Show Terms immediately after clicking "create account".
        // We can't record acceptance yet (no uid), so we only collect consent here.
        final agreed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const TermsAgreementScreen(
              returnResultInsteadOfNavigating: true,
              allowUnauthenticatedContinue: true,
            ),
          ),
        );
        if (agreed != true) {
          // User backed out / did not agree.
          return;
        }

        var signupName = _nameController.text.trim();
        if (signupName.isEmpty) {
          signupName = _usernameGenerator.generate().displayName;
          _nameController.text = signupName;
        }
        final credential = await _authService.signUpWithEmail(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          name: signupName,
          handle: handle,
          birthDate: _selectedBirthDate,
          verificationMethod: verificationMethod,
          provider: provider,
        );

        if (!mounted) return;
        final uid = credential?.user?.uid;
        if (uid != null) {
          // Record terms agreement immediately after account creation.
          await _userService.recordTermsAgreement(
            uid,
            onboardingRequired: true,
          );
        }

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('계정이 생성되었습니다!')));

        AuthNavigation.navigateToAuthenticatedHome(context);
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.arrow_back,
                      size: 22,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        '회원가입하기',
                        textAlign: TextAlign.start,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                          letterSpacing: -0.55,
                          color: AppColors.getTextPrimary(brightness),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Email Input
                    _buildInputField(
                      context: context,
                      label: '이메일 주소',
                      controller: _emailController,
                      hintText: 'your@email.com',
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      enabled:
                          !_isGoogleSignIn &&
                          !_isKakaoSignIn &&
                          !_isAppleSignIn, // Disable if social sign-in
                    ),
                    const SizedBox(height: 20),

                    _buildBirthDateField(context: context),
                    const SizedBox(height: 20),
                    if (_isSocialSignup && !_isBirthDateFromSocialProfile) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.getBackgroundTertiary(brightness),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.getBorderSecondary(brightness),
                          ),
                        ),
                        child: Text(
                          '소셜 계정의 생년월일 정보가 없어 직접 입력된 생년월일로 가입을 진행합니다.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.getTextSecondary(brightness),
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Password Input (only show for regular signup)
                    if (!_isSocialSignup) ...[
                      _buildInputField(
                        context: context,
                        label: '비밀번호',
                        controller: _passwordController,
                        hintText: '••••••••',
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 20),

                      // Confirm Password Input
                      _buildInputField(
                        context: context,
                        label: '비밀번호 확인',
                        controller: _confirmPasswordController,
                        hintText: '••••••••',
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handleSignUp(),
                      ),
                    ],
                    const SizedBox(height: 28),

                    // Sign Up Button
                    ElevatedButton(
                      onPressed: _isLoading ? null : _handleSignUp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor: AppColors.primary.withValues(
                          alpha: 0.6,
                        ),
                        minimumSize: const Size(double.infinity, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: AppColors.getBackground(brightness),
                                strokeWidth: 2,
                              ),
                            )
                          : Text(
                              _isSocialSignup
                                  ? '완료'
                                  : '계정 만들기',
                              style: TextStyle(
                                color: AppColors.getBackground(brightness),
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '만 14세 이상만 가입 가능하며, 회원가입 시 ',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: AppColors.getTextSecondary(brightness),
                            height: 1.5,
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pushNamed('/terms-of-service'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.getTextSecondary(
                              brightness,
                            ),
                          ),
                          child: Text(
                            '이용약관',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 11,
                              color: AppColors.getTextSecondary(brightness),
                              decoration: TextDecoration.underline,
                              height: 1.5,
                            ),
                          ),
                        ),
                        Text(
                          ' 및 ',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: AppColors.getTextSecondary(brightness),
                            height: 1.5,
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pushNamed('/privacy-policy'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.getTextSecondary(
                              brightness,
                            ),
                          ),
                          child: Text(
                            '개인정보처리방침',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 11,
                              color: AppColors.getTextSecondary(brightness),
                              decoration: TextDecoration.underline,
                              height: 1.5,
                            ),
                          ),
                        ),
                        Text(
                          '에 동의하게 됩니다',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: AppColors.getTextSecondary(brightness),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Login Link
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '계정이 이미 있으신가요?',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.getTextSecondary(brightness),
                          ),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacementNamed(context, '/login');
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.primary,
                          ),
                          child: const Text(
                            '로그인하기',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField({
    required BuildContext context,
    required String label,
    required TextEditingController controller,
    required String hintText,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    bool obscureText = false,
    void Function(String)? onSubmitted,
    bool enabled = true,
  }) {
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.getTextPrimary(brightness),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          enabled: enabled,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(color: AppColors.getTextTertiary(brightness)),
            filled: true,
            fillColor: AppColors.getBackgroundTertiary(brightness),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.getBorderSecondary(brightness),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.getBorderSecondary(brightness),
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
          style: TextStyle(
            fontSize: 16,
            color: AppColors.getTextPrimary(brightness),
          ),
        ),
      ],
    );
  }

  Widget _buildBirthDateField({required BuildContext context}) {
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '생년월일',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.getTextPrimary(brightness),
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickBirthDate,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.getBackgroundTertiary(brightness),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.getBorderSecondary(brightness),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _birthDateLabel(),
                  style: TextStyle(
                    fontSize: 16,
                    color: _selectedBirthDate == null
                        ? AppColors.getTextTertiary(brightness)
                        : AppColors.getTextPrimary(brightness),
                  ),
                ),
                Icon(
                  Icons.calendar_month,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '만 14세 이상만 가입할 수 있습니다.',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.getTextTertiary(brightness),
          ),
        ),
      ],
    );
  }
}

/// iOS-style three-column wheel picker for picking a birth date.
///
/// Shows year/month/day columns with Korean unit suffixes (년/월/일).
/// Days auto-clamp when the new (year, month) has fewer days, and the confirm
/// button is disabled when the chosen date exceeds [maxDate].
class _BirthDateWheelPicker extends StatefulWidget {
  final DateTime initialDate;
  final int minYear;
  final DateTime maxDate;

  const _BirthDateWheelPicker({
    required this.initialDate,
    required this.minYear,
    required this.maxDate,
  });

  @override
  State<_BirthDateWheelPicker> createState() => _BirthDateWheelPickerState();
}

class _BirthDateWheelPickerState extends State<_BirthDateWheelPicker> {
  static const Color _orange = Color(0xFFFF6B00);
  static const Color _textPrimary = Color(0xFF111111);
  static const Color _textSecondary = Color(0xFF6B7280);
  static const Color _divider = Color(0xFFF3F4F6);
  static const double _itemExtent = 38;

  late int _year;
  late int _month;
  late int _day;
  late FixedExtentScrollController _yearController;
  late FixedExtentScrollController _monthController;
  late FixedExtentScrollController _dayController;

  @override
  void initState() {
    super.initState();
    _year = widget.initialDate.year;
    _month = widget.initialDate.month;
    _day = widget.initialDate.day;
    _yearController = FixedExtentScrollController(
      initialItem: _year - widget.minYear,
    );
    _monthController = FixedExtentScrollController(initialItem: _month - 1);
    _dayController = FixedExtentScrollController(initialItem: _day - 1);
  }

  @override
  void dispose() {
    _yearController.dispose();
    _monthController.dispose();
    _dayController.dispose();
    super.dispose();
  }

  int _daysIn(int year, int month) {
    // Last day of month: day 0 of (month + 1).
    return DateTime(year, month + 1, 0).day;
  }

  bool get _exceedsMax =>
      DateTime(_year, _month, _day).isAfter(widget.maxDate);

  /// Bring the day wheel back into range when the new (year, month) is shorter.
  void _clampDayIfNeeded() {
    final maxDay = _daysIn(_year, _month);
    if (_day > maxDay) {
      _day = maxDay;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dayController.animateToItem(
          maxDay - 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final yearCount = widget.maxDate.year - widget.minYear + 1;
    final dayCount = _daysIn(_year, _month);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '생년월일 선택',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1, color: _divider),
            SizedBox(
              height: 220,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _wheel(
                      controller: _yearController,
                      itemCount: yearCount,
                      onChanged: (i) => setState(() {
                        _year = widget.minYear + i;
                        _clampDayIfNeeded();
                      }),
                      label: (i) => '${widget.minYear + i}년',
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: _wheel(
                      controller: _monthController,
                      itemCount: 12,
                      onChanged: (i) => setState(() {
                        _month = i + 1;
                        _clampDayIfNeeded();
                      }),
                      label: (i) => '${i + 1}월',
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: _wheel(
                      controller: _dayController,
                      itemCount: dayCount,
                      onChanged: (i) => setState(() => _day = i + 1),
                      label: (i) => '${i + 1}일',
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: _divider),
            SizedBox(
              height: 52,
              child: Center(
                child: TextButton(
                  onPressed: _exceedsMax
                      ? null
                      : () => Navigator.of(context).pop(
                          DateTime(_year, _month, _day),
                        ),
                  style: TextButton.styleFrom(
                    foregroundColor: _orange,
                    disabledForegroundColor: _textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                  ),
                  child: const Text(
                    '확인',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int itemCount,
    required ValueChanged<int> onChanged,
    required String Function(int i) label,
  }) {
    return CupertinoPicker(
      scrollController: controller,
      itemExtent: _itemExtent,
      onSelectedItemChanged: onChanged,
      magnification: 1.0,
      useMagnifier: false,
      diameterRatio: 1.6,
      squeeze: 1.1,
      selectionOverlay: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(0x14000000),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      children: List.generate(
        itemCount,
        (i) => Center(
          child: Text(
            label(i),
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: _textPrimary,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ),
    );
  }
}
