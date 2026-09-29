import 'package:flutter/material.dart';
import 'app_toast.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;

import '../services/report_service.dart';
import 'app_media_query_merge_nav_insets.dart';

const Color _kTextPrimary = Color(0xFF111111);
const Color _kTextMuted = Color(0xFF6B7280);
const Color _kTextOption = Color(0xFF4B5563);
const Color _kReportRed = Color(0xFFEF4444);
const Color _kSheetBg = Colors.white;
const Color _kHandle = Color(0xFFE5E7EB);
const Color _kOptionBg = Color(0xFFF9FAFB);
const Color _kRadioBorder = Color(0xFFD1D5DB);
const Color _kSubmitDisabledBg = Color(0xFFF3F4F6);
const Color _kSubmitDisabledText = Color(0xFF9CA3AF);
const Color _kBorderLight = Color(0xFFF3F4F6);

/// Figma: post overflow — 공유하기 / 수정하기 / 신고하기 / 삭제하기.
Future<void> showReviewPostMenuBottomSheet(
  BuildContext context, {
  required bool isOwnPost,
  required String shareText,
  String? shareSubject,
  bool isAdmin = false,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
  VoidCallback? onOpenReport,
  VoidCallback? onBlockUser,
}) async {
  // 관리자는 본인 글이 아니어도 "삭제하기"를 볼 수 있어야 하고,
  // 수정은 본인만, 신고/차단은 본인도, 관리자도 띄우지 않는다.
  final canEdit = isOwnPost && onEdit != null;
  final canDelete = (isOwnPost || isAdmin) && onDelete != null;
  final canReport = !isOwnPost && !isAdmin && onOpenReport != null;
  final canBlock = !isOwnPost && !isAdmin && onBlockUser != null;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (ctx) {
      final bottomInset = MediaQuery.paddingOf(ctx).bottom;
      return Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            color: _kSheetBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 48,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _kHandle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      _MenuRow(
                        icon: Icons.share_outlined,
                        iconColor: _kTextPrimary,
                        label: '공유하기',
                        labelColor: _kTextPrimary,
                        onTap: () async {
                          Navigator.of(ctx).pop();
                          await SharePlus.instance.share(
                            ShareParams(
                              text: shareText,
                              subject: shareSubject ?? '요리GO',
                            ),
                          );
                        },
                      ),
                      if (canEdit) ...[
                        const SizedBox(height: 4),
                        _MenuRow(
                          icon: Icons.edit_outlined,
                          iconColor: _kTextPrimary,
                          label: '수정하기',
                          labelColor: _kTextPrimary,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            onEdit();
                          },
                        ),
                      ],
                      if (canReport) ...[
                        const SizedBox(height: 4),
                        _MenuRow(
                          icon: Icons.flag_outlined,
                          iconColor: _kReportRed,
                          label: '신고하기',
                          labelColor: _kReportRed,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            onOpenReport();
                          },
                        ),
                      ],
                      if (canBlock) ...[
                        const SizedBox(height: 4),
                        _MenuRow(
                          icon: Icons.block_outlined,
                          iconColor: _kReportRed,
                          label: '차단하기',
                          labelColor: _kReportRed,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            onBlockUser();
                          },
                        ),
                      ],
                      if (canDelete) ...[
                        const SizedBox(height: 4),
                        _MenuRow(
                          icon: Icons.delete_outline_rounded,
                          iconColor: _kReportRed,
                          label: '삭제하기',
                          labelColor: _kReportRed,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            onDelete();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.labelColor,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final Color labelColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          height: 48,
          padding: const EdgeInsets.only(left: 16),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: labelColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same reason codes/labels as legacy [ReportDialog] (Firestore `reason` field).
const List<({String code, String label})> kReportReasonOptions = [
  (code: 'spam', label: '스팸/광고'),
  (code: 'abuse', label: '욕설/비방'),
  (code: 'inappropriate', label: '음란물'),
  (code: 'copyright', label: '저작권 침해'),
  (code: 'other', label: '기타'),
];

/// Figma: 신고하기 full sheet (node 349-133 / 349-141).
///
/// Layout mirrors the price/recipe issue report sheets: the entire sheet is
/// wrapped in [AnimatedPadding] so it lifts above the soft keyboard, and the
/// internal list uses [ScrollViewKeyboardDismissBehavior.onDrag] so the
/// keyboard only closes when the user actively drags.
Future<void> showReviewReportBottomSheet(
  BuildContext context, {
  required String type,
  required String targetId,
  String? reviewId,
  VoidCallback? onSubmitted,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (ctx) {
      final screenHeight = MediaQuery.sizeOf(ctx).height;
      final viewInsetsBottom = MediaQuery.viewInsetsOf(ctx).bottom;
      // Cap visible sheet to ~92% of screen, accounting for the keyboard so
      // the header never gets clipped above the screen top.
      final maxSheetHeight = (screenHeight - viewInsetsBottom) * 0.92;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: viewInsetsBottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: _ReportSheetBody(
            type: type,
            targetId: targetId,
            reviewId: reviewId,
            onSubmitted: onSubmitted,
          ),
        ),
      );
    },
  );
}

class _ReportSheetBody extends StatefulWidget {
  const _ReportSheetBody({
    required this.type,
    required this.targetId,
    this.reviewId,
    this.onSubmitted,
  });

  final String type;
  final String targetId;
  final String? reviewId;
  final VoidCallback? onSubmitted;

  @override
  State<_ReportSheetBody> createState() => _ReportSheetBodyState();
}

class _ReportSheetBodyState extends State<_ReportSheetBody> {
  final ReportService _reportService = ReportService();
  final TextEditingController _descriptionController = TextEditingController();
  final ScrollController _listScrollController = ScrollController();
  final GlobalKey _otherFieldKey = GlobalKey();
  String? _selected;
  bool _submitting = false;

  /// After [AnimatedSize] opens the 기타 field, scroll so the full text box is visible.
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
        type: widget.type,
        targetId: widget.targetId,
        reason: _selected!,
        description: _selected == 'other' ? otherDetail : null,
        reviewId: widget.reviewId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSubmitted?.call();
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('신고가 접수되었습니다'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      var msg = '신고 처리 중 오류가 발생했습니다';
      if (e.toString().contains('이미 신고한')) msg = '이미 신고한 항목입니다';
      if (e.toString().contains('로그인')) msg = '로그인이 필요합니다';

      // 성공 시와 동일하게, 중복 신고는 시트를 닫은 뒤 안내만 표시한다.
      // (catch에서 pop을 안 하면 제출 버튼이 먹통처럼 보인다.)
      if (msg == '이미 신고한 항목입니다') {
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
                      '신고하기',
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
                    '이 게시물을 신고하는 이유를 선택해주세요.',
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
                    '회원님의 신고는 익명으로 처리되며, 요리고 커뮤니티 가이드라인에 따라 안전하게 검토됩니다.',
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
                  ...kReportReasonOptions.map((e) {
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
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _selected == 'other'
                        ? Padding(
                            key: _otherFieldKey,
                            padding: const EdgeInsets.only(top: 4),
                            child: _ReviewStyleReportDetailField(
                              controller: _descriptionController,
                              onChanged: (_) => setState(() {}),
                            ),
                          )
                        : const SizedBox.shrink(),
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

/// Same gray rounded box + typography as [ProgressiveRecipeReviewSheet._buildFigmaReviewCommentInput].
class _ReviewStyleReportDetailField extends StatelessWidget {
  const _ReviewStyleReportDetailField({
    required this.controller,
    required this.onChanged,
  });

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
          hintText: '신고 내용을 자세히 입력해 주세요.',
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

const String _kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.yorigo.mobile';

String defaultReviewShareSubject(Map<String, dynamic> review) {
  final title = (review['recipeTitle'] as String?)?.trim() ?? '';
  return title.isNotEmpty ? title : '요리GO 요리 후기';
}

/// Share card for a feed review. Matches recipe-detail share tone:
/// title, the reviewer's words, then the same store CTA. No raw IDs.
String defaultReviewShareText(Map<String, dynamic> review) {
  final title = defaultReviewShareSubject(review);
  final comment = (review['comment'] as String?)?.trim() ?? '';
  final buf = StringBuffer();
  buf.writeln(title);
  if (comment.isNotEmpty) {
    buf.writeln();
    buf.writeln(comment);
  }
  buf.writeln();
  buf.writeln('앱에서 보기');
  buf.write(_kPlayStoreUrl);
  return buf.toString();
}
