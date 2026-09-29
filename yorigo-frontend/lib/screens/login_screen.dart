import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_colors.dart';
import '../services/auth_service.dart';
import '../utils/auth_navigation.dart';
import '../config/environment_config.dart';
import '../widgets/app_toast.dart';
import 'terms_agreement_screen.dart';

/// Figma login node 489:54 — hero wordmark, Kakao + Google; Apple on iOS/macOS unless preview flag forces it. Pretendard only.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoading = false;

  static const double _contentW = 318;
  static const Color _figmaTagline = Color(0xFF111111);
  static const Color _figmaMutedLabel = Color(0xFFC4CAD4);
  static const Color _figmaDividerLine = Color(0xFFF2F4F6);
  static const Color _figmaOrText = Color(0xFFD1D5DB);
  static const Color _figmaEmailBtnText = Color(0xFF4B5563);
  static const Color _figmaEmailBtnBorder = Color(0xFFE8EAED);
  static const Color _figmaGoogleCircleBorder = Color(0xFFEAECEF);
  static const Color _figmaLegal = Color(0xFFD1D5DB);

  static const TextStyle _pretendard11Label = TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: _figmaMutedLabel,
    height: 1.50,
    letterSpacing: -0.28,
  );

  /// Locks line box to Figma rhythm and avoids sub-pixel overflow under fixed row height.
  static const StrutStyle _strut11Label = StrutStyle(
    fontFamily: 'Pretendard',
    fontSize: 11,
    height: 1.5,
    leadingDistribution: TextLeadingDistribution.even,
    forceStrutHeight: true,
  );

  /// TEMP: `true` shows the Apple circle on web/Android too (layout check). Set to `false` before release.
  static const bool _kPreviewAppleSocialButton = true;

  bool get _showApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  bool get _showAppleSocialButton => _showApple || _kPreviewAppleSocialButton;

  bool _isLegacyAgeGateBypassEligible(Map<String, dynamic> data) {
    if (!EnvironmentConfig.enableLegacyAgeGateBypass) return false;
    final enforceFrom = EnvironmentConfig.ageGateEnforceFrom;
    if (enforceFrom == null) return true;

    final createdAtRaw = data['createdAt'];
    DateTime? createdAt;
    if (createdAtRaw is Timestamp) {
      createdAt = createdAtRaw.toDate();
    } else if (createdAtRaw is DateTime) {
      createdAt = createdAtRaw;
    } else if (createdAtRaw is String) {
      createdAt = DateTime.tryParse(createdAtRaw);
    }
    // createdAt을 해석할 수 없으면 보수적으로 기존 계정 예외 적용
    if (createdAt == null) return true;
    return createdAt.isBefore(enforceFrom);
  }

  Future<bool> _needsSocialProfileCompletion(User user) async {
    try {
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return true;
      final data = userDoc.data();
      if (data == null) return true;

      final name = data['name']?.toString().trim() ?? '';
      final handle = data['handle']?.toString().trim() ?? '';
      final birthDate = data['birthDate']?.toString().trim() ?? '';
      final isAgeVerified14Plus = data['isAgeVerified14Plus'] == true;
      if (name.isEmpty || handle.isEmpty) return true;
      final ageGateIncomplete = birthDate.isEmpty || !isAgeVerified14Plus;
      if (!ageGateIncomplete) return false;
      if (_isLegacyAgeGateBypassEligible(data)) return false;
      return true;
    } catch (_) {
      // 네트워크/일시 오류 시 회원가입 화면으로 유도해 프로필 미완성 상태를 방지
      return true;
    }
  }

  Future<void> _openSocialTermsThenSignup({
    required String socialProvider,
    required String authPath,
    required bool isNewUser,
    String? socialBirthDate,
    String? pendingKakaoCustomToken,
    String? pendingKakaoAccessToken,
    String? pendingKakaoEmail,
    String? pendingKakaoDisplayName,
    String? pendingKakaoId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TermsAgreementScreen(
          allowUnauthenticatedContinue: true,
          allowBackNavigation: true,
          continueRouteName: '/signup',
          continueRouteArguments: {
            'socialProvider': socialProvider,
            'forceSocialComplete': true,
            'isNewUser': isNewUser,
            'authPath': authPath,
            'socialBirthDate': socialBirthDate,
            'pendingKakaoCustomToken': pendingKakaoCustomToken,
            'pendingKakaoAccessToken': pendingKakaoAccessToken,
            'pendingKakaoEmail': pendingKakaoEmail,
            'pendingKakaoDisplayName': pendingKakaoDisplayName,
            'pendingKakaoId': pendingKakaoId,
            'socialTermsPreAgreed': true,
          },
        ),
      ),
    );
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final result = await _authService.signInWithGoogle();
      if (!mounted) return;
      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }
      final isNewUser = result['isNewUser'] as bool;
      final userCredential = result['userCredential'] as UserCredential?;
      final socialProvider = result['socialProvider'] as String?;
      final authPath = result['authPath'] as String?;
      final socialBirthDate = result['socialBirthDate'] as String?;
      if (authPath == 'kakao_pending_signup') {
        AppToast.info(context, '추가 정보를 입력해주세요.');
        await _openSocialTermsThenSignup(
          socialProvider: socialProvider ?? 'kakao',
          authPath: authPath ?? 'kakao_pending_signup',
          isNewUser: true,
          socialBirthDate: socialBirthDate,
          pendingKakaoCustomToken: result['pendingKakaoCustomToken']?.toString(),
          pendingKakaoAccessToken: result['pendingKakaoAccessToken']?.toString(),
          pendingKakaoEmail: result['pendingKakaoEmail']?.toString(),
          pendingKakaoDisplayName: result['pendingKakaoDisplayName']?.toString(),
          pendingKakaoId: result['pendingKakaoId']?.toString(),
        );
        return;
      }
      if (userCredential == null) {
        setState(() => _isLoading = false);
        return;
      }
      final shouldCompleteProfile =
          isNewUser ||
          await _needsSocialProfileCompletion(userCredential.user!);
      if (shouldCompleteProfile) {
        AppToast.info(context, '추가 정보를 입력해주세요.');
        await _openSocialTermsThenSignup(
          socialProvider: socialProvider ?? 'google',
          authPath: authPath ?? 'google_oauth',
          isNewUser: isNewUser,
          socialBirthDate: socialBirthDate,
        );
      } else {
        AppToast.success(context, 'Google로 로그인되었습니다');
        AuthNavigation.navigateToAuthenticatedHome(context);
      }
    } catch (e) {
      if (!mounted) return;
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      if (msg.startsWith("'") && msg.endsWith("'")) {
        msg = msg.substring(1, msg.length - 1);
      }
      AppToast.error(context, msg, duration: const Duration(seconds: 4));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleAppleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final result = await _authService.signInWithApple();
      if (!mounted) return;
      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }
      final isNewUser = result['isNewUser'] as bool;
      final userCredential = result['userCredential'] as UserCredential?;
      final socialProvider = result['socialProvider'] as String?;
      final authPath = result['authPath'] as String?;
      final socialBirthDate = result['socialBirthDate'] as String?;
      if (userCredential == null) {
        setState(() => _isLoading = false);
        return;
      }
      final shouldCompleteProfile =
          isNewUser ||
          await _needsSocialProfileCompletion(userCredential.user!);
      if (shouldCompleteProfile) {
        AppToast.info(context, '추가 정보를 입력해주세요.');
        await _openSocialTermsThenSignup(
          socialProvider: socialProvider ?? 'apple',
          authPath: authPath ?? 'apple_oauth',
          isNewUser: isNewUser,
          socialBirthDate: socialBirthDate,
        );
      } else {
        AppToast.success(context, 'Apple로 로그인되었습니다');
        AuthNavigation.navigateToAuthenticatedHome(context);
      }
    } catch (e) {
      if (!mounted) return;
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      if (msg.startsWith("'") && msg.endsWith("'")) {
        msg = msg.substring(1, msg.length - 1);
      }
      AppToast.error(context, msg, duration: const Duration(seconds: 4));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleKakaoSignIn() async {
    // Flutter 웹 빌드: Kakao 플러터 SDK 카카오계정 플로우가 지원 범위 밖인 경우가 많음
    if (kIsWeb) {
      if (!mounted) return;
      AppToast.info(
        context,
        '카카오 로그인은 iOS 또는 Android 앱에서 이용할 수 있습니다.',
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      // iOS: KakaoTalk → 앱 복귀 직후 임베딩 창이 안정화되기까지 ASWeb 앵커/세션이 깨지는 경우가 있어 여유를 둔다.
      if (!kIsWeb && Platform.isIOS) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
      }
      final result = await _authService.signInWithKakao();
      if (!mounted) return;
      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }
      final isNewUser = result['isNewUser'] as bool;
      final userCredential = result['userCredential'] as UserCredential?;
      final socialProvider = result['socialProvider'] as String?;
      final authPath = result['authPath'] as String?;
      final socialBirthDate = result['socialBirthDate'] as String?;
      if (authPath == 'kakao_pending_signup') {
        AppToast.info(context, '추가 정보를 입력해주세요.');
        await _openSocialTermsThenSignup(
          socialProvider: socialProvider ?? 'kakao',
          authPath: authPath ?? 'kakao_pending_signup',
          isNewUser: true,
          socialBirthDate: socialBirthDate,
          pendingKakaoCustomToken: result['pendingKakaoCustomToken']?.toString(),
          pendingKakaoAccessToken: result['pendingKakaoAccessToken']?.toString(),
          pendingKakaoEmail: result['pendingKakaoEmail']?.toString(),
          pendingKakaoDisplayName: result['pendingKakaoDisplayName']?.toString(),
          pendingKakaoId: result['pendingKakaoId']?.toString(),
        );
        return;
      }
      if (userCredential == null) {
        setState(() => _isLoading = false);
        return;
      }
      final shouldCompleteProfile =
          isNewUser ||
          await _needsSocialProfileCompletion(userCredential.user!);
      if (shouldCompleteProfile) {
        AppToast.info(context, '추가 정보를 입력해주세요.');
        await _openSocialTermsThenSignup(
          socialProvider: socialProvider ?? 'kakao',
          authPath: authPath ?? 'unknown',
          isNewUser: isNewUser,
          socialBirthDate: socialBirthDate,
        );
      } else {
        AppToast.success(context, '카카오로 로그인되었습니다');
        AuthNavigation.navigateToAuthenticatedHome(context);
      }
    } catch (e) {
      if (!mounted) return;
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      if (msg.startsWith("'") && msg.endsWith("'")) {
        msg = msg.substring(1, msg.length - 1);
      }
      AppToast.error(context, msg, duration: const Duration(seconds: 4));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _circularSocialButton({
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
    required Color backgroundColor,
    Color? borderColor,
    List<BoxShadow>? boxShadow,
  }) {
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onPressed,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: backgroundColor,
                shape: BoxShape.circle,
                border: borderColor != null
                    ? Border.all(color: borderColor, width: 0.67)
                    : null,
                boxShadow: boxShadow,
              ),
              child: Center(child: icon),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: _pretendard11Label,
            textAlign: TextAlign.center,
            strutStyle: _strut11Label,
          ),
        ],
      ),
    );
  }

  Widget _socialRow() {
    final kakao = _circularSocialButton(
      onPressed: _isLoading ? null : _handleKakaoSignIn,
      backgroundColor: const Color(0xFFFEE500),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
      icon: Image.asset(
        'assets/icons/kakaotalk_icon.png',
        width: 38,
        height: 38,
        fit: BoxFit.contain,
      ),
      label: '카카오',
    );

    final google = _circularSocialButton(
      onPressed: _isLoading ? null : _handleGoogleSignIn,
      backgroundColor: Colors.white,
      borderColor: _figmaGoogleCircleBorder,
      boxShadow: const [
        BoxShadow(
          color: Color(0x0F000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
      icon: Image.asset(
        'assets/icons/google_g.png',
        width: 38,
        height: 38,
        fit: BoxFit.contain,
      ),
      label: '구글',
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          kakao,
          if (_showAppleSocialButton) ...[
            const SizedBox(width: 28),
            _circularSocialButton(
              onPressed: _isLoading ? null : _handleAppleSignIn,
              backgroundColor: const Color(0xFF111111),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1E000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
              icon: const Icon(Icons.apple, color: Colors.white, size: 24),
              label: '애플',
            ),
          ],
          const SizedBox(width: 28),
          google,
        ],
      ),
    );
  }

  Widget _orDivider() {
    return SizedBox(
      height: 16.5,
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: _figmaDividerLine),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '또는',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: _figmaOrText,
                height: 1.50,
                letterSpacing: 1.10,
              ),
            ),
          ),
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: _figmaDividerLine),
          ),
        ],
      ),
    );
  }

  Widget _emailLoginPill() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: _isLoading
            ? null
            : () => Navigator.of(context).pushNamed('/email-login'),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: double.infinity,
          height: 46,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _figmaEmailBtnBorder, width: 0.67),
          ),
          child: Text(
            '이메일 또는 아이디로 로그인',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _figmaEmailBtnText,
              height: 1.50,
              letterSpacing: -0.35,
            ),
          ),
        ),
      ),
    );
  }

  Widget _heroBlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 175,
          height: 40,
          child: Image.asset(
            'assets/yorigo_korean_logo.png',
            fit: BoxFit.contain,
            alignment: Alignment.center,
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'SNS 레시피 자동 정리, 장보기까지',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: _figmaTagline,
            height: 1.50,
            letterSpacing: -0.32,
          ),
        ),
      ],
    );
  }

  Widget _lowerBlock(Brightness brightness) {
    // Figma stack vertical rhythm: social 0–78.5, divider 97.5, pill 133, browse 198, legal 245.5
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _socialRow(),
          const SizedBox(height: 14),
          _orDivider(),
          const SizedBox(height: 14),
          _emailLoginPill(),
          const SizedBox(height: 14),
          SizedBox(
            height: 35.5,
            child: Center(
              child: GestureDetector(
                onTap: _isLoading
                    ? null
                    : () {
                        Navigator.of(
                          context,
                        ).pushNamedAndRemoveUntil('/', (route) => false);
                      },
                child: Text(
                  '로그인 없이 둘러보기',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _figmaMutedLabel,
                    height: 1.50,
                    letterSpacing: -0.32,
                    decoration: TextDecoration.underline,
                    decorationColor: _figmaMutedLabel,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '만 14세 이상만 가입 가능하며, 로그인 시 ',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: _figmaLegal,
                    height: 1.63,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/terms-of-service'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: _figmaLegal,
                  ),
                  child: const Text(
                    '이용약관',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 10,
                      decoration: TextDecoration.underline,
                      height: 1.63,
                    ),
                  ),
                ),
                Text(
                  ' 및 ',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: _figmaLegal,
                    height: 1.63,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/privacy-policy'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: _figmaLegal,
                  ),
                  child: const Text(
                    '개인정보처리방침',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 10,
                      decoration: TextDecoration.underline,
                      height: 1.63,
                    ),
                  ),
                ),
                Text(
                  '에 동의하게 됩니다',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: _figmaLegal,
                    height: 1.63,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'Pretendard',
          color: AppColors.getTextPrimary(brightness),
        ),
        child: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _contentW),
                    child: Transform.translate(
                      offset: const Offset(0, -13),
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _heroBlock(),
                        const SizedBox(height: 28),
                        _lowerBlock(brightness),
                      ],
                    ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                  onPressed: () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    } else {
                      Navigator.of(
                        context,
                      ).pushNamedAndRemoveUntil('/', (route) => false);
                    }
                  },
                ),
              ),
            ),
            if (_isLoading)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.08),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
