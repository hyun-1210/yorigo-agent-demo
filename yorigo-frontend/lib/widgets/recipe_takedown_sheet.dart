import 'package:flutter/material.dart';
import 'app_toast.dart';

import '../services/report_service.dart';
import 'app_media_query_merge_nav_insets.dart';

const Color _kTextPrimary = Color(0xFF111111);
const Color _kTextMuted = Color(0xFF6B7280);
const Color _kTextOption = Color(0xFF4B5563);
const Color _kSheetBg = Colors.white;
const Color _kOptionBg = Color(0xFFF9FAFB);
const Color _kRadioBorder = Color(0xFFD1D5DB);
const Color _kSubmitDisabledBg = Color(0xFFF3F4F6);
const Color _kSubmitDisabledText = Color(0xFF9CA3AF);
const Color _kBorderLight = Color(0xFFF3F4F6);

/// 레시피 신고 시트의 사유 옵션.
///
/// `code` 는 Firestore `reports.reason` 으로 저장된다. 새 코드는
/// AdminReportsScreen 의 라벨 매핑에도 동일하게 추가되어야 한다.
const List<({String code, String label})> kRecipeTakedownReasons = [
  (code: 'unrelated', label: '관련없는 콘텐츠'),
  (code: 'inappropriate', label: '부적절한 콘텐츠'),
  (code: 'other', label: '기타'),
];

/// 레시피 디테일에서 진입하는 "신고" 시트.
///
/// 동작은 [showReviewReportBottomSheet]와 동일하게 [ReportService.createReport]
/// 를 호출한다. `type: 'recipe'`, `targetId: recipeId` 로 적재되며 admin이
/// 검토 후 `setRecipeHidden(true)` 를 수동으로 트리거한다.
Future<void> showRecipeTakedownSheet(
  BuildContext context, {
  required String recipeId,
  String? sourceUrl,
  String? title,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (ctx) {
      final screenHeight = MediaQuery.sizeOf(ctx).height;
      final viewInsetsBottom = MediaQuery.viewInsetsOf(ctx).bottom;
      final maxSheetHeight = (screenHeight - viewInsetsBottom) * 0.92;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: viewInsetsBottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: _RecipeTakedownSheetBody(
            recipeId: recipeId,
            sourceUrl: sourceUrl,
            title: title,
          ),
        ),
      );
    },
  );
}

class _RecipeTakedownSheetBody extends StatefulWidget {
  const _RecipeTakedownSheetBody({
    required this.recipeId,
    this.sourceUrl,
    this.title,
  });

  final String recipeId;
  final String? sourceUrl;
  final String? title;

  @override
  State<_RecipeTakedownSheetBody> createState() =>
      _RecipeTakedownSheetBodyState();
}

class _RecipeTakedownSheetBodyState extends State<_RecipeTakedownSheetBody> {
  final ReportService _reportService = ReportService();
  final TextEditingController _descriptionController = TextEditingController();
  final ScrollController _listScrollController = ScrollController();
  final GlobalKey _otherFieldKey = GlobalKey();
  String? _selected;
  bool _submitting = false;

  void _scrollOtherFieldIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 260), () {
        if (!mounted) return;
        final ctx = _otherFieldKey.currentContext;
        if (ctx == null || !ctx.mounted) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.05,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    });
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected == null) return;
    final otherDetail = _descriptionController.text.trim();
    if (_selected == 'other' && otherDetail.isEmpty) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('기타 사유를 입력해 주세요'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await _reportService.createReport(
        type: 'recipe',
        targetId: widget.recipeId,
        reason: _selected!,
        description: otherDetail.isNotEmpty ? otherDetail : null,
        targetUrl: widget.sourceUrl,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('신고가 접수되었습니다 — 관리자 검토 후 처리됩니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      var msg = '신고 처리 중 오류가 발생했습니다';
      if (e.toString().contains('이미 신고한')) msg = '이미 신고한 레시피입니다';
      if (e.toString().contains('로그인')) msg = '로그인이 필요합니다';

      if (msg == '이미 신고한 레시피입니다') {
        Navigator.of(context).pop();
        showAppSnackBar(
          context,
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
        return;
      }

      setState(() => _submitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherDetail = _descriptionController.text.trim();
    final canSubmit =
        _selected != null &&
        !_submitting &&
        (_selected != 'other' || otherDetail.isNotEmpty);

    return AppMediaQueryMergeNavInsets(
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: _kSheetBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Row(
                children: [
                  const SizedBox(width: 40, height: 40),
                  const Expanded(
                    child: Text(
                      '신고',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: _kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 22,
                      color: _kTextPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 0.67, color: _kBorderLight),
            Expanded(
              child: ListView(
                controller: _listScrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                children: [
                  const Text(
                    '이 레시피를 신고하시겠어요?',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: _kTextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                      letterSpacing: -0.38,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '관리자 검토 후 처리됩니다.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: _kTextMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.63,
                      letterSpacing: -0.32,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ...kRecipeTakedownReasons.map((e) {
                    final code = e.code;
                    final label = e.label;
                    final selected = _selected == code;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              if (_selected == 'other' && code != 'other') {
                                _descriptionController.clear();
                              }
                              _selected = code;
                            });
                            if (code == 'other') {
                              _scrollOtherFieldIntoView();
                            }
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: _kOptionBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected
                                    ? const Color(
                                        0xFFFF6900,
                                      ).withValues(alpha: 0.5)
                                    : Colors.transparent,
                                width: selected ? 1.33 : 0.67,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      color: _kTextOption,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      height: 1.5,
                                      letterSpacing: -0.38,
                                    ),
                                  ),
                                ),
                                _RadioDot(selected: selected),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                  Padding(
                    key: _otherFieldKey,
                    padding: const EdgeInsets.only(top: 4),
                    child: _DetailField(
                      controller: _descriptionController,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                16 + appSystemNavBottomInset(context),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: Material(
                  color: canSubmit
                      ? const Color(0xFFFF6900)
                      : _kSubmitDisabledBg,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    onTap: canSubmit ? _submit : null,
                    borderRadius: BorderRadius.circular(16),
                    child: Center(
                      child: _submitting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              '제출하기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                color: canSubmit
                                    ? Colors.white
                                    : _kSubmitDisabledText,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                height: 1.5,
                                letterSpacing: -0.4,
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
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: const Color(0xFFF2F4F6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: TextField(
        controller: controller,
        maxLength: 500,
        maxLines: 6,
        decoration: const InputDecoration(
          hintText: '신고 사유를 자세히 입력해 주세요.',
          hintStyle: TextStyle(
            color: Color(0xFF8B95A1),
            fontSize: 14,
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w500,
            height: 1.63,
          ),
          border: InputBorder.none,
          counterText: '',
          isCollapsed: true,
        ),
        style: const TextStyle(
          color: Color(0xFF191F28),
          fontSize: 14,
          fontFamily: 'Pretendard',
          fontWeight: FontWeight.w500,
          height: 1.63,
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? const Color(0xFFFF6900) : _kRadioBorder,
          width: selected ? 1.5 : 1.33,
        ),
        color: selected ? const Color(0xFFFF6900) : Colors.transparent,
      ),
      child: selected
          ? const Center(
              child: Icon(Icons.check, size: 12, color: Colors.white),
            )
          : null,
    );
  }
}
