import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';

import '../services/user_service.dart';

/// Figma 490:102 — mandatory terms + privacy; Pretendard. No push opt-in row.
class TermsAgreementScreen extends StatefulWidget {
  const TermsAgreementScreen({
    super.key,
    this.returnResultInsteadOfNavigating = false,
    this.allowUnauthenticatedContinue = false,
    this.allowBackNavigation = false,
    this.continueRouteName,
    this.continueRouteArguments,
  });

  /// When true, this screen behaves like a "popup flow":
  /// - user can go back (we don't hard-block pop)
  /// - on continue, we `Navigator.pop(context, true)` instead of navigating to `/`
  final bool returnResultInsteadOfNavigating;

  /// When true (typically for signup), allow the user to accept terms even when
  /// there is no signed-in Firebase user yet. Caller is responsible for recording
  /// the agreement after account creation.
  final bool allowUnauthenticatedContinue;

  /// When true, allows popping this screen via system/back button.
  final bool allowBackNavigation;

  /// Optional route to continue to after agreement.
  /// If provided, this screen pushes that route and keeps itself in stack.
  final String? continueRouteName;
  final Object? continueRouteArguments;

  @override
  State<TermsAgreementScreen> createState() => _TermsAgreementScreenState();
}

class _TermsAgreementScreenState extends State<TermsAgreementScreen> {
  final UserService _userService = UserService();

  bool _agreeTerms = false;
  bool _agreePrivacy = false;
  bool _submitting = false;

  static const Color _bg = Color(0xFFF9FAFB);
  static const Color _title = Color(0xFF111111);
  static const Color _subtitle = Color(0xFFB0B8C1);
  static const Color _rowText = Color(0xFF4B5563);
  static const Color _requiredOrange = Color(0xFFFF6B00);
  static const Color _cardFill = Color(0xFFF9FAFB);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _divider = Color(0xFFF2F4F6);
  static const Color _ctaDisabledFill = Color(0xFFF3F4F6);
  static const Color _ctaDisabledText = Color(0xFFD1D5DB);

  bool get _canContinue => _agreeTerms && _agreePrivacy;

  void _setAll(bool v) {
    setState(() {
      _agreeTerms = v;
      _agreePrivacy = v;
    });
  }

  Future<void> _onContinue() async {
    if (!_canContinue || _submitting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null && !widget.allowUnauthenticatedContinue) return;

    setState(() => _submitting = true);
    try {
      if (user != null) {
        await _userService.recordTermsAgreement(user.uid);
      }
      if (!mounted) return;
      if (widget.continueRouteName != null &&
          widget.continueRouteName!.trim().isNotEmpty) {
        Navigator.of(context).pushNamed(
          widget.continueRouteName!,
          arguments: widget.continueRouteArguments,
        );
      } else if (widget.returnResultInsteadOfNavigating) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _circleCheckVisual(bool checked) {
    return SizedBox(
      width: 22,
      height: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: checked ? _requiredOrange : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: checked ? _requiredOrange : _border,
            width: 0.67,
          ),
        ),
        child: checked
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : null,
      ),
    );
  }

  Widget _squareCheck({
    required bool checked,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 22,
        height: 22,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: checked ? _requiredOrange : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: checked ? _requiredOrange : _border,
              width: 0.67,
            ),
          ),
          child: checked
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.returnResultInsteadOfNavigating || widget.allowBackNavigation,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 28, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                      },
                      icon: const Icon(
                        Icons.arrow_back,
                        size: 22,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Text(
                            '서비스 약관에 동의해주세요',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: _title,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              height: 1.35,
                              letterSpacing: -0.55,
                            ),
                          ),
                          ),
                          const SizedBox(height: 6),
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Text(
                            '요리GO를 이용하기 위해 약관 동의가 필요합니다',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: _subtitle,
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              height: 1.50,
                              letterSpacing: -0.32,
                            ),
                          ),
                          ),
                          const SizedBox(height: 32),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.only(top: 0, bottom: 8),
                            decoration: BoxDecoration(
                              color: _cardFill,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                InkWell(
                                  onTap: () => _setAll(!(_agreeTerms && _agreePrivacy)),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
                                    child: Row(
                                      children: [
                                        _circleCheckVisual(
                                          _agreeTerms && _agreePrivacy,
                                        ),
                                        const SizedBox(width: 12),
                                        const Expanded(
                                          child: Text(
                                            '모두 동의합니다',
                                            style: TextStyle(
                                              fontFamily: 'Pretendard',
                                              color: _title,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              height: 1.50,
                                              letterSpacing: -0.38,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Divider(height: 1, thickness: 1, color: _divider),
                                ),
                                _termRow(
                                  checked: _agreeTerms,
                                  onToggle: () {
                                    setState(() {
                                      _agreeTerms = !_agreeTerms;
                                    });
                                  },
                                  labelBefore: '서비스 이용약관 동의 ',
                                  mandatory: true,
                                  onChevron: () => Navigator.of(context).pushNamed('/terms-of-service'),
                                ),
                                _termRow(
                                  checked: _agreePrivacy,
                                  onToggle: () {
                                    setState(() {
                                      _agreePrivacy = !_agreePrivacy;
                                    });
                                  },
                                  labelBefore: '개인정보 처리방침 동의 ',
                                  mandatory: true,
                                  onChevron: () => Navigator.of(context).pushNamed('/privacy-policy'),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 318),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: Material(
                        color: _canContinue && !_submitting
                            ? _requiredOrange
                            : _ctaDisabledFill,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _canContinue && !_submitting ? _onContinue : null,
                          child: Center(
                            child: _submitting
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    '동의하고 계속하기',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      color: _canContinue
                                          ? Colors.white
                                          : _ctaDisabledText,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      height: 1.50,
                                      letterSpacing: -0.38,
                                    ),
                                  ),
                          ),
                        ),
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

  Widget _termRow({
    required bool checked,
    required VoidCallback onToggle,
    required String labelBefore,
    required bool mandatory,
    required VoidCallback onChevron,
  }) {
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _squareCheck(checked: checked, onTap: onToggle),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: onToggle,
                behavior: HitTestBehavior.opaque,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: labelBefore,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: _rowText,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.50,
                          letterSpacing: -0.35,
                        ),
                      ),
                      TextSpan(
                        text: mandatory ? '(필수)' : '(선택)',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          color: mandatory ? _requiredOrange : _subtitle,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.50,
                          letterSpacing: -0.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: onChevron,
              icon: const Icon(
                Icons.chevron_right,
                size: 22,
                color: _rowText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
