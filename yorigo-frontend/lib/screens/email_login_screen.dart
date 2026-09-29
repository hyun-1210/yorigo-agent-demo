import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';
import '../utils/auth_navigation.dart';

/// Email + password login — layout inspired by native email-login flows; styling matches [LoginScreen].
class EmailLoginScreen extends StatefulWidget {
  const EmailLoginScreen({super.key});

  @override
  State<EmailLoginScreen> createState() => _EmailLoginScreenState();
}

class _EmailLoginScreenState extends State<EmailLoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final AuthService _authService = AuthService();

  bool _isLoading = false;
  bool _emailTouched = false;
  bool _showEmailError = false;

  static const TextStyle _snackStyle = TextStyle(fontFamily: 'Pretendard');

  /// Figma CTA (orange); slightly different from [AppColors.primary].
  static const Color _ctaOrange = Color(0xFFFF6B00);

  static const TextStyle _primaryCtaText = TextStyle(
    fontFamily: 'Pretendard',
    color: Colors.white,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.50,
    letterSpacing: -0.38,
  );

  static final RegExp _emailPattern = RegExp(
    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
  );

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _emailValid => _emailPattern.hasMatch(_emailController.text.trim());

  void _onEmailChanged(String _) {
    if (_showEmailError && _emailValid) {
      setState(() => _showEmailError = false);
    }
  }

  InputDecoration _fieldDecoration(
    Brightness brightness, {
    required String hintText,
    bool errorBorder = false,
  }) {
    final borderColor = errorBorder
        ? const Color(0xFFE53935)
        : AppColors.getBorderSecondary(brightness);
    final radius = BorderRadius.circular(12);

    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontFamily: 'Pretendard',
        color: AppColors.getTextTertiary(brightness),
        fontSize: 15,
      ),
      filled: true,
      fillColor: AppColors.getBackgroundTertiary(brightness),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: borderColor, width: errorBorder ? 1.2 : 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: borderColor, width: errorBorder ? 1.2 : 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(
          color: errorBorder ? const Color(0xFFE53935) : AppColors.primary,
          width: 1.4,
        ),
      ),
      suffixIcon: errorBorder
          ? const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(
                Icons.error_outline,
                color: Color(0xFFE53935),
                size: 22,
              ),
            )
          : null,
    );
  }

  Future<void> _submit() async {
    if (_isLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _emailTouched = true;
      _showEmailError = !_emailValid;
    });

    if (!_emailValid) return;

    if (_passwordController.text.isEmpty) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('비밀번호를 입력해주세요.', style: _snackStyle),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _authService.signInWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      showAppSnackBar(context, 
        const SnackBar(content: Text('로그인되었습니다!', style: _snackStyle)),
      );
      AuthNavigation.navigateToAuthenticatedHome(context);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(content: Text(e.toString(), style: _snackStyle)),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final emailError = _emailTouched && _showEmailError;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      
      body: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'Pretendard',
          color: AppColors.getTextPrimary(brightness),
        ),
        child: SafeArea(
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
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                    '이메일로 로그인하기',
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
                  Text(
                    '이메일',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.getTextSecondary(brightness),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (emailError) ...[
                    const Text(
                      '올바른 이메일을 입력해주세요.',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFFE53935),
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: _emailController,
                    onChanged: _onEmailChanged,
                    enabled: !_isLoading,
                    onTapOutside: (_) {
                      setState(() {
                        _emailTouched = true;
                        _showEmailError = !_emailValid;
                      });
                    },
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                    decoration: _fieldDecoration(
                      brightness,
                      hintText: 'your@email.com',
                      errorBorder: emailError,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    '비밀번호',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.getTextSecondary(brightness),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    enabled: !_isLoading,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _isLoading ? null : _submit(),
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                    decoration: _fieldDecoration(
                      brightness,
                      hintText: '6자 이상의 비밀번호',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _isLoading
                          ? null
                          : () {
                              Navigator.of(context).pushNamed(
                                '/forgot-password',
                                arguments: _emailController.text.trim(),
                              );
                            },
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: AppColors.getTextSecondary(brightness),
                      ),
                      child: const Text(
                        '비밀번호를 잊으셨나요?',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.5,
                          letterSpacing: -0.26,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: Material(
                      color: _ctaOrange,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _isLoading ? null : _submit,
                        child: Center(
                          child: _isLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  '로그인',
                                  textAlign: TextAlign.center,
                                  style: _primaryCtaText,
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Center(
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 0,
                      children: [
                        Text(
                          '아직 요리GO 계정이 없으신가요? ',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            height: 1.5,
                            letterSpacing: -0.28,
                            color: AppColors.getTextSecondary(brightness),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pushNamed('/signup');
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.primary,
                          ),
                          child: const Text(
                            '회원가입하기',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.5,
                              letterSpacing: -0.28,
                              decoration: TextDecoration.underline,
                              decorationColor: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}




