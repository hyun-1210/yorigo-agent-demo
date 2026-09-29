import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';

typedef PasswordResetRequest = Future<void> Function(String email);

/// 가입 이메일로 Firebase 비밀번호 재설정 링크를 보냅니다.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    this.initialEmail,
    this.onRequestReset,
  });

  final String? initialEmail;
  final PasswordResetRequest? onRequestReset;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final TextEditingController _emailController = TextEditingController();
  AuthService? _authService;

  bool _isLoading = false;
  bool _emailTouched = false;
  bool _showEmailError = false;
  bool _emailSent = false;

  static const TextStyle _snackStyle = TextStyle(fontFamily: 'Pretendard');
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
  void initState() {
    super.initState();
    final initial = widget.initialEmail?.trim();
    if (initial != null && initial.isNotEmpty) {
      _emailController.text = initial;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
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
    if (_isLoading || _emailSent) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _emailTouched = true;
      _showEmailError = !_emailValid;
    });

    if (!_emailValid) return;

    setState(() => _isLoading = true);

    final email = _emailController.text.trim();
    final request = widget.onRequestReset ??
        (email) =>
            (_authService ??= AuthService()).requestPasswordResetEmail(email);

    try {
      await request(email);
      if (!mounted) return;
      setState(() => _emailSent = true);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text(e.toString(), style: _snackStyle)),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildSuccessBody(Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 56,
          color: AppColors.primary.withValues(alpha: 0.9),
        ),
        const SizedBox(height: 20),
        Text(
          '재설정 링크를 보냈습니다',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.35,
            letterSpacing: -0.55,
            color: AppColors.getTextPrimary(brightness),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '입력하신 이메일로 비밀번호 재설정 링크를 보냈습니다.\n'
          '메일함과 스팸함을 확인해주세요.',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.55,
            letterSpacing: -0.28,
            color: AppColors.getTextSecondary(brightness),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Google·Apple·카카오로 가입하셨다면 해당 방법으로 로그인해주세요.',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w400,
            height: 1.5,
            letterSpacing: -0.26,
            color: AppColors.getTextTertiary(brightness),
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          height: 52,
          child: Material(
            color: _ctaOrange,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: const Center(
                child: Text(
                  '로그인으로 돌아가기',
                  textAlign: TextAlign.center,
                  style: _primaryCtaText,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormBody(Brightness brightness, bool emailError) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '가입 시 사용한 이메일을 입력하면\n비밀번호 재설정 링크를 보내드립니다.',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.55,
            letterSpacing: -0.28,
            color: AppColors.getTextSecondary(brightness),
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
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onSubmitted: (_) => _isLoading ? null : _submit(),
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
        const SizedBox(height: 32),
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
                    : const Text(
                        '재설정 링크 보내기',
                        textAlign: TextAlign.center,
                        style: _primaryCtaText,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
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
                              '비밀번호 찾기',
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
                          if (_emailSent)
                            _buildSuccessBody(brightness)
                          else
                            _buildFormBody(brightness, emailError),
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
