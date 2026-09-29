import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_toast.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rewards_service.dart';

/// Figma: Inter + 한글은 Pretendard 폴백 (브라우저의 Inter + Noto KR과 동일한 역할).
const String _kFigFont = 'Inter';
const List<String> _kFigFontFallback = ['Pretendard'];

/// Figma 674:269 — 의견 보내기 바텀시트 (설정·고객센터 > 의견 보내기).
class ProfileFeedbackSheet extends StatefulWidget {
  const ProfileFeedbackSheet({
    super.key,
    this.initialCategories,
    this.initialDetail,
    this.initialDisliked,
  });

  final List<String>? initialCategories;
  final String? initialDetail;
  final String? initialDisliked;

  /// 요리GO 카카오톡 오픈채팅 (1:1 문의).
  static const String kKakaoInquiryUrl = 'https://open.kakao.com/o/sG43RBri';

  static const String kSupportEmail = 'yorigoadm@gmail.com';

  static Future<void> show(
    BuildContext context, {
    List<String>? initialCategories,
    String? initialDetail,
    String? initialDisliked,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      backgroundColor: Colors.transparent,
      builder: (context) => ProfileFeedbackSheet(
        initialCategories: initialCategories,
        initialDetail: initialDetail,
        initialDisliked: initialDisliked,
      ),
    );
  }

  @override
  State<ProfileFeedbackSheet> createState() => _ProfileFeedbackSheetState();
}

class _ProfileFeedbackSheetState extends State<ProfileFeedbackSheet> {
  static const List<String> _categories = [
    '앱 전반',
    '레시피북 탭',
    '레시피 분석',
    '커뮤니티 탭',
    '장바구니 탭',
    '냉장고 탭',
    '프로필 탭',
    'UI · 디자인',
    '속도 · 성능',
    '버그',
    '기타',
  ];

  final TextEditingController _detailController = TextEditingController();
  final TextEditingController _goodController = TextEditingController();
  final TextEditingController _badController = TextEditingController();

  final Set<String> _selectedCategories = {};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCategories;
    if (initial != null) {
      for (final c in initial) {
        if (_categories.contains(c)) _selectedCategories.add(c);
      }
    }
    final detail = widget.initialDetail?.trim();
    if (detail != null && detail.isNotEmpty) {
      _detailController.text = detail;
    }
    final disliked = widget.initialDisliked?.trim();
    if (disliked != null && disliked.isNotEmpty) {
      _badController.text = disliked;
    }
  }

  @override
  void dispose() {
    _detailController.dispose();
    _goodController.dispose();
    _badController.dispose();
    super.dispose();
  }

  /// 카테고리 칩을 하나 이상 선택했을 때만 전송 가능 (다중 선택 허용).
  bool get _canSubmit => _selectedCategories.isNotEmpty;

  Future<void> _launchMail() async {
    final uri = Uri.parse(
      'mailto:${ProfileFeedbackSheet.kSupportEmail}'
      '?subject=${Uri.encodeComponent('[요리GO] 문의')}',
    );
    try {
      await launchUrl(uri);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('메일 앱을 열 수 없어요.')));
    }
  }

  Future<void> _launchKakao() async {
    final uri = Uri.parse(ProfileFeedbackSheet.kKakaoInquiryUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('카카오톡을 열 수 없어요.')));
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      showAppSnackBar(
        context,
        const SnackBar(content: Text('의견 전송은 로그인 후 이용할 수 있어요.')));
      return;
    }
    setState(() => _submitting = true);
    try {
      await FirebaseFirestore.instance.collection('app_feedback').add({
        'createdAt': FieldValue.serverTimestamp(),
        'userId': user.uid,
        'categories': _selectedCategories.toList(),
        'detail': _detailController.text.trim(),
        'liked': _goodController.text.trim(),
        'disliked': _badController.text.trim(),
        'platform': defaultTargetPlatform.name,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      final written = '${_detailController.text}${_goodController.text}${_badController.text}'
          .trim();
      if (written.length >= 8) {
        await RewardsService.instance.claim(
          'exp_feedback',
          idempotencyKey:
              'exp_feedback:${user.uid}:${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('의견을 보냈어요. 소중한 한 마디 고마워요!')));
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text('전송에 실패했어요: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // Cap the visible sheet to ~92% of the area NOT occupied by the keyboard
    // so the header never gets pushed above the screen top when the soft
    // keyboard rises.
    final maxH = (MediaQuery.sizeOf(context).height - bottomInset) * 0.92;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          constraints: BoxConstraints(maxHeight: maxH),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            boxShadow: [
              BoxShadow(
                color: Color(0x2E000000),
                blurRadius: 24,
                offset: Offset(0, -12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 14),
                Center(
                  child: Container(
                    width: 36,
                    height: 3.5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '의견 보내기',
                              style: TextStyle(
                                fontFamily: _kFigFont,
                                fontFamilyFallback: _kFigFontFallback,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                height: 27 / 18,
                                letterSpacing: -0.45,
                                color: Color(0xFF111111),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '불편하셨던 점을 알려주시면 빠르게 개선하겠습니다.',
                              style: TextStyle(
                                fontFamily: _kFigFont,
                                fontFamilyFallback: _kFigFontFallback,
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                height: 19.5 / 13,
                                letterSpacing: -0.325,
                                color: const Color(0xFF9CA3AF),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Material(
                        color: const Color(0xFFF3F4F6),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).pop(),
                          child: SizedBox(
                            width: 32,
                            height: 32,
                            child: Center(
                              child: SvgPicture.asset(
                                'assets/icons/feedback_sheet_close.svg',
                                width: 16,
                                height: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _card(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '어떤 부분에 대한 의견인가요?',
                                style: TextStyle(
                                  fontFamily: _kFigFont,
                                  fontFamilyFallback: _kFigFontFallback,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.35,
                                  color: Color(0xFF111111),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _categories.map((c) {
                                  final sel = _selectedCategories.contains(c);
                                  return GestureDetector(
                                    onTap: () => setState(() {
                                      if (sel) {
                                        _selectedCategories.remove(c);
                                      } else {
                                        _selectedCategories.add(c);
                                      }
                                    }),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 150,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: sel
                                            ? const Color(0xFF111111)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        border: Border.all(
                                          color: sel
                                              ? const Color(0xFF111111)
                                              : const Color(0xFFE5E7EB),
                                          width: 0.667,
                                        ),
                                      ),
                                      child: Text(
                                        c,
                                        style: TextStyle(
                                          fontFamily: _kFigFont,
                                          fontFamilyFallback: _kFigFontFallback,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: sel
                                              ? Colors.white
                                              : const Color(0xFF374151),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _card(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text.rich(
                                TextSpan(
                                  style: const TextStyle(
                                    fontFamily: _kFigFont,
                                    fontFamilyFallback: _kFigFontFallback,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.35,
                                    color: Color(0xFF111111),
                                  ),
                                  children: [
                                    const TextSpan(text: '자세히 말씀해주세요 '),
                                    TextSpan(
                                      text: '(선택)',
                                      style: TextStyle(
                                        fontFamily: _kFigFont,
                                        fontFamilyFallback: _kFigFontFallback,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: const Color(0xFF9CA3AF),
                                        height: 19.5 / 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF9FAFB),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: const Color(0xFFF0F0F2),
                                    width: 1,
                                  ),
                                ),
                                child: TextField(
                                  controller: _detailController,
                                  maxLines: 5,
                                  maxLength: 300,
                                  buildCounter:
                                      (
                                        context, {
                                        required currentLength,
                                        required isFocused,
                                        maxLength,
                                      }) => const SizedBox.shrink(),
                                  style: const TextStyle(
                                    fontFamily: _kFigFont,
                                    fontFamilyFallback: _kFigFontFallback,
                                    fontSize: 13,
                                    height: 21.125 / 13,
                                    letterSpacing: -0.325,
                                    color: Color(0xFF111111),
                                  ),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    hintText:
                                        '불편하셨던 점, 아쉬웠던 점, 또는 칭찬해주고 싶은 점을 편하게 적어주세요. 모든 의견을 꼼꼼히 읽고 반영할게요.',
                                    hintStyle: TextStyle(
                                      fontFamily: _kFigFont,
                                      fontFamilyFallback: _kFigFontFallback,
                                      fontSize: 13,
                                      color: Color(0xFFC5CAD2),
                                      height: 21.125 / 13,
                                    ),
                                    border: InputBorder.none,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: _detailController,
                                builder: (context, value, _) {
                                  return Text(
                                    '${value.text.characters.length} / 300자',
                                    style: const TextStyle(
                                      fontFamily: _kFigFont,
                                      fontFamilyFallback: _kFigFontFallback,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF9CA3AF),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _optionalShortField(
                          emoji: '👍',
                          title: ' 좋았던 점',
                          hint: '어떤 점이 마음에 드셨나요?',
                          controller: _goodController,
                        ),
                        const SizedBox(height: 12),
                        _optionalShortField(
                          emoji: '👎',
                          title: ' 아쉬웠던 점',
                          hint: '불편하거나 아쉬웠던 점이 있나요?',
                          controller: _badController,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SvgPicture.asset(
                              'assets/icons/feedback_anonymity_lock.svg',
                              width: 14,
                              height: 14,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '보내주신 의견은 익명으로 처리되며 서비스 개선에만 사용됩니다.',
                                style: TextStyle(
                                  fontFamily: _kFigFont,
                                  fontFamilyFallback: _kFigFontFallback,
                                  fontSize: 12,
                                  height: 18 / 12,
                                  letterSpacing: -0.3,
                                  color: const Color(0xFF9CA3AF),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '직접 문의하기',
                          style: TextStyle(
                            fontFamily: _kFigFont,
                            fontFamilyFallback: _kFigFontFallback,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.3,
                            color: const Color(0xFF9CA3AF),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _kakaoButton(),
                        const SizedBox(height: 8),
                        _mailButton(),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56.5,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: _canSubmit && !_submitting
                            ? const [
                                BoxShadow(
                                  color: Color(0x47FF6B00),
                                  blurRadius: 10,
                                  offset: Offset(0, 6),
                                ),
                              ]
                            : null,
                      ),
                      child: Material(
                        color: _canSubmit && !_submitting
                            ? const Color(0xFFFF6B00)
                            : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: _canSubmit && !_submitting ? _submit : null,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.send_rounded,
                                size: 16,
                                color: _canSubmit && !_submitting
                                    ? Colors.white
                                    : const Color(0xFFC5CAD2),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _submitting ? '보내는 중…' : '의견 보내기',
                                style: TextStyle(
                                  fontFamily: _kFigFont,
                                  fontFamilyFallback: _kFigFontFallback,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.375,
                                  height: 22.5 / 15,
                                  color: _canSubmit && !_submitting
                                      ? Colors.white
                                      : const Color(0xFFC5CAD2),
                                ),
                              ),
                            ],
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
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
            spreadRadius: -8,
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _optionalShortField({
    required String emoji,
    required String title,
    required String hint,
    required TextEditingController controller,
  }) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                emoji,
                style: const TextStyle(fontSize: 14, height: 21 / 14),
              ),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: _kFigFont,
                  fontFamilyFallback: _kFigFontFallback,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.35,
                  color: Color(0xFF111111),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '(선택)',
                style: TextStyle(
                  fontFamily: _kFigFont,
                  fontFamilyFallback: _kFigFontFallback,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF9CA3AF),
                  height: 19.5 / 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 48,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFF0F1F3), width: 1),
            ),
            child: TextField(
              controller: controller,
              style: const TextStyle(
                fontFamily: _kFigFont,
                fontFamilyFallback: _kFigFontFallback,
                fontSize: 13,
                letterSpacing: -0.325,
                color: Color(0xFF111111),
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(
                  fontFamily: _kFigFont,
                  fontFamilyFallback: _kFigFontFallback,
                  fontSize: 13,
                  color: Color(0xFFC5CAD2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kakaoButton() {
    return Material(
      color: const Color(0xFFFFF4C2),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _launchKakao,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
          child: Row(
            children: [
              Image.asset(
                'assets/icons/kakaotalk_icon.png',
                width: 34,
                height: 34,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '카카오톡 1:1 문의',
                      style: TextStyle(
                        fontFamily: _kFigFont,
                        fontFamilyFallback: _kFigFontFallback,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.325,
                        color: Color(0xFF3C1E1E),
                      ),
                    ),
                    Text(
                      '빠르게 답변 드릴게요',
                      style: TextStyle(
                        fontFamily: _kFigFont,
                        fontFamilyFallback: _kFigFontFallback,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.275,
                        color: const Color(0xFF3C1E1E).withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: Color(0xFF3C1E1E),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mailButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
            spreadRadius: -8,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _launchMail,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0x14111111),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: SvgPicture.asset(
                    'assets/icons/feedback_mail_envelope.svg',
                    width: 17,
                    height: 17,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '고객문의 메일',
                        style: TextStyle(
                          fontFamily: _kFigFont,
                          fontFamilyFallback: _kFigFontFallback,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.325,
                          color: Color(0xFF111111),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ProfileFeedbackSheet.kSupportEmail,
                        style: const TextStyle(
                          fontFamily: _kFigFont,
                          fontFamilyFallback: _kFigFontFallback,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.275,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Color(0xFF9CA3AF),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
