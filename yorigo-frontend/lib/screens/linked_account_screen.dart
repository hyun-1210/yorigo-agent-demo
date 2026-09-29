import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../widgets/default_profile_avatar.dart';

class LinkedAccountScreen extends StatefulWidget {
  final String providerId;
  final String title;
  final bool isGoogle;
  final bool isKakao;
  final bool canUnlink;

  const LinkedAccountScreen({
    super.key,
    required this.providerId,
    required this.title,
    required this.isGoogle,
    this.isKakao = false,
    required this.canUnlink,
  });

  @override
  State<LinkedAccountScreen> createState() => _LinkedAccountScreenState();
}

class _LinkedAccountScreenState extends State<LinkedAccountScreen> {
  final AuthService _authService = AuthService();
  bool _isWorking = false;
  bool? _kakaoLinked;

  // Figma 282-3779 tokens (all Pretendard)
  static const Color _bg = Color(0xFFF8F9FA);
  static const Color _cardBg = Colors.white;
  static const Color _textPrimary = Color(0xFF191F28);
  static const Color _textMuted = Color(0xFF8B95A1);
  static const Color _successBg = Color(0xFFE8F5E9);
  static const Color _successText = Color(0xFF15803D);
  static const Color _unlinkedInfoBg = Color(0xFFF2F4F6);
  static const Color _unlinkedInfoIconBg = Color(0xFF8B95A1);
  static const Color _unlinkedInfoText = Color(0xFF4E5968);
  static const Color _linkBlue = Color(0xFF3182F6);
  static const Color _danger = Color(0xFFEF4444);
  static const Color _logoRing = Color(0xFF191F28);
  static const Color _border = Color(0xFFF2F4F6);
  static const Color _shadow = Color(0x05000000);
  static const Color _figmaTextSecondary = Color(0xFF333D4B);

  bool get _isLinked {
    if (widget.providerId == 'kakao') return _kakaoLinked ?? false;
    return _authService.isProviderLinked(widget.providerId);
  }

  @override
  void initState() {
    super.initState();
    if (widget.providerId == 'kakao') {
      _authService.isKakaoLinkedToCurrentKakaoSession().then((v) {
        if (mounted) setState(() => _kakaoLinked = v);
      });
    }
  }

  bool get _canShowApple {
    if (widget.providerId != 'apple.com') return true;
    return kIsWeb || (!kIsWeb && (Platform.isIOS || Platform.isMacOS));
  }

  String _providerEmail() {
    if (widget.providerId == 'kakao') return '';
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return '';
    final info = user.providerData.where((p) => p.providerId == widget.providerId).toList();
    final email = info.isNotEmpty ? (info.first.email ?? '') : '';
    return email;
  }

  /// Same logo style as profile settings: Google = red "G", Apple = Icons.apple, Kakao = KakaoTalk asset.
  Widget _providerLogo(bool isLinked) {
    if (widget.isGoogle) {
      return Image.asset(
        'assets/icons/google_g.png',
        width: 60,
        height: 60,
        fit: BoxFit.contain,
      );
    }
    if (widget.isKakao) {
      return Image.asset(
        'assets/icons/kakaotalk_icon.png',
        width: 64,
        height: 64,
        fit: BoxFit.contain,
      );
    }
    if (widget.providerId == 'apple.com') {
      return Icon(
        Icons.apple,
        size: 32,
        color: isLinked ? Colors.white : _figmaTextSecondary,
      );
    }
    if (widget.providerId == 'password') {
      return const Icon(Icons.email_outlined, size: 32, color: Colors.white);
    }
    return const DefaultProfileAvatar(size: 32);
  }

  Future<void> _link() async {
    if (_isWorking) return;
    setState(() => _isWorking = true);
    try {
      if (widget.providerId == 'google.com') {
        await _authService.linkGoogleAccount();
      } else if (widget.providerId == 'apple.com') {
        await _authService.linkAppleAccount();
      } else if (widget.providerId == 'kakao') {
        final success = await _authService.linkKakaoAccount();
        if (success != true) {
          if (!mounted) return;
          setState(() => _isWorking = false);
          return;
        }
        final linked = await _authService.isKakaoLinkedToCurrentKakaoSession();
        if (mounted) setState(() => _kakaoLinked = linked);
      } else {
        throw '지원되지 않는 로그인 방식입니다.';
      }

      if (!mounted) return;
      setState(() => _isWorking = false);
      showAppSnackBar(context, 
        SnackBar(
          content: Text('${widget.title} 계정이 연결되었습니다'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _isWorking = false);
      showAppSnackBar(context, 
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _unlink() async {
    if (_isWorking) return;
    if (!widget.canUnlink) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('최소 하나의 로그인 방법이 필요합니다'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return _FigmaConfirmDialog(
          title: '${widget.title} 계정 연결을 해제하시겠습니까?',
          subtitle: '기기 내 로그인 정보가 삭제됩니다.',
          cancelText: '취소',
          confirmText: '연결 해제',
          confirmColor: _danger,
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _isWorking = true);
    try {
      await _authService.unlinkProvider(widget.providerId);
      if (!mounted) return;
      if (widget.providerId == 'kakao') setState(() => _kakaoLinked = false);
      setState(() => _isWorking = false);
      showAppSnackBar(context, 
        SnackBar(
          content: Text('${widget.title} 계정 연결이 해제되었습니다'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _isWorking = false);
      showAppSnackBar(context, 
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    if (!_canShowApple) {
      return Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _cardBg,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: AppColors.getTextPrimary(brightness)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          centerTitle: true,
          title: Text(
            '${widget.title} 계정',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _textPrimary,
            ),
          ),
        ),
        body: const Center(child: Text('이 기기에서는 Apple 로그인을 지원하지 않습니다.')),
      );
    }

    final email = _providerEmail();
    final isLinked = _isLinked;
    final topTitle = isLinked ? '연결된 소셜 계정' : '연결된 소셜 계정 없음';
    // If there is no provider email, show blank (no placeholder).
    final topSubtitle = isLinked ? email : '';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _cardBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.getTextPrimary(brightness)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: Text(
                '${widget.title} 계정',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _textPrimary,
                  fontSize: 18,
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w800,
                  height: 1.50,
                  letterSpacing: -0.45,
                ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 24, left: 20, right: 20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Top block: logo, title, email — Column to avoid overlap (Figma 282-3780)
              SizedBox(
                width: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      padding: EdgeInsets.zero,
                      decoration: ShapeDecoration(
                        // Use the "connected" logo style for both states.
                        color: widget.isKakao
                            ? Colors.transparent
                            : (widget.isGoogle ? Colors.white : _logoRing),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22369600),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: _providerLogo(true),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      topTitle,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 20,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                        letterSpacing: -0.50,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    if (topSubtitle.isNotEmpty)
                      Text(
                        topSubtitle,
                        style: const TextStyle(
                          color: _textMuted,
                          fontSize: 15,
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w400,
                          height: 1.50,
                          letterSpacing: -0.38,
                        ),
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Green info box + disconnect button — fixed 334 width to match Figma (282-3788)
              Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 95.38),
                        decoration: ShapeDecoration(
                          color: isLinked ? _successBg : _unlinkedInfoBg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: const ShapeDecoration(
                                  color: _unlinkedInfoIconBg,
                                  shape: CircleBorder(),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  isLinked ? Icons.check : Icons.info_rounded,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '현재 ',
                                        style: TextStyle(
                                          color: isLinked ? _successText : _unlinkedInfoText,
                                          fontSize: 13,
                                          fontFamily: 'Pretendard',
                                          fontWeight: FontWeight.w400,
                                          height: 1.63,
                                          letterSpacing: -0.32,
                                        ),
                                      ),
                                      TextSpan(
                                        text: widget.title,
                                        style: TextStyle(
                                          color: isLinked ? _successText : _unlinkedInfoText,
                                          fontSize: 13,
                                          fontFamily: 'Pretendard',
                                          fontWeight: FontWeight.w700,
                                          height: 1.63,
                                          letterSpacing: -0.32,
                                        ),
                                      ),
                                      TextSpan(
                                        text: isLinked
                                            ? ' 계정으로 안전하게 로그인되어 있습니다. 소셜 로그인 연결을 해제하면 해당 계정으로 요리고에 로그인할 수 없습니다.'
                                            : ' 계정과 연결되어 있지 않습니다. 소셜 계정을 연결하면 다음 방문 시 더 간편하게 로그인할 수 있습니다.',
                                        style: TextStyle(
                                          color: isLinked ? _successText : _unlinkedInfoText,
                                          fontSize: 13,
                                          fontFamily: 'Pretendard',
                                          fontWeight: FontWeight.w400,
                                          height: 1.63,
                                          letterSpacing: -0.32,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_isWorking)
                        const SizedBox(
                          height: 46.33,
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                            ),
                          ),
                        )
                      else
                        Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            onTap: () => isLinked ? _unlink() : _link(),
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              width: double.infinity,
                              height: 50,
                              decoration: BoxDecoration(
                                color: isLinked
                                    ? const Color(0xFFFEF2F2)
                                    : const Color(0xFF111111),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: isLinked
                                    ? null
                                    : const [
                                        BoxShadow(
                                          color: Color(0x33000000),
                                          blurRadius: 14,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                              ),
                              alignment: Alignment.center,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isLinked) ...[
                                    Icon(
                                      Icons.link_off_rounded,
                                      size: 16,
                                      color: _danger,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    isLinked ? '연결 해제' : '계정 연결하기',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isLinked ? _danger : Colors.white,
                                      fontSize: 14,
                                      fontFamily: 'Pretendard',
                                      fontWeight: FontWeight.w700,
                                      height: 1.40,
                                      letterSpacing: -0.35,
                                    ),
                                  ),
                                  if (!isLinked) ...[
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.chevron_right_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FigmaConfirmDialog extends StatelessWidget {
  final String title;
  final String subtitle;
  final String cancelText;
  final String confirmText;
  final Color confirmColor;

  const _FigmaConfirmDialog({
    required this.title,
    required this.subtitle,
    required this.cancelText,
    required this.confirmText,
    required this.confirmColor,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 30,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF191F28),
                      letterSpacing: -0.45,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF4E5968),
                      letterSpacing: -0.35,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 0.67, color: Color(0xFFF2F4F6)),
            SizedBox(
              height: 55,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(false),
                      child: Center(
                        child: Text(
                          cancelText,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF4E5968),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(width: 0.67, color: const Color(0xFFF2F4F6)),
                  Expanded(
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(true),
                      child: Center(
                        child: Text(
                          confirmText,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: confirmColor,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

