import 'package:flutter/material.dart';

/// Modern white prompt dialog with a multi-line text field.
///
/// Shares its visual language with [AppConfirmDialog] so confirm and prompt
/// flows feel consistent across the app.
///
/// Usage:
/// ```dart
/// final reason = await AppPromptDialog.show(
///   context: context,
///   title: '숨김 사유',
///   hintText: '사유를 입력해주세요',
/// );
/// ```
class AppPromptDialog extends StatefulWidget {
  const AppPromptDialog({
    super.key,
    required this.title,
    this.description,
    this.hintText = '',
    this.initialValue = '',
    this.confirmLabel = '확인',
    this.cancelLabel = '취소',
    this.minLines = 3,
    this.maxLines = 5,
    this.maxLength,
    this.requireNonEmpty = true,
  });

  final String title;
  final String? description;
  final String hintText;
  final String initialValue;
  final String confirmLabel;
  final String cancelLabel;
  final int minLines;
  final int maxLines;
  final int? maxLength;

  /// When true, the confirm button stays disabled until the user types
  /// non-whitespace characters.
  final bool requireNonEmpty;

  /// Returns the trimmed user-entered string, or `null` if cancelled/dismissed.
  static Future<String?> show({
    required BuildContext context,
    required String title,
    String? description,
    String hintText = '',
    String initialValue = '',
    String confirmLabel = '확인',
    String cancelLabel = '취소',
    int minLines = 3,
    int maxLines = 5,
    int? maxLength,
    bool requireNonEmpty = true,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<String>(
      context: context,
      barrierLabel: title,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Opacity(
          opacity: curved.value,
          child: Transform.scale(
            scale: 0.96 + 0.04 * curved.value,
            child: AppPromptDialog(
              title: title,
              description: description,
              hintText: hintText,
              initialValue: initialValue,
              confirmLabel: confirmLabel,
              cancelLabel: cancelLabel,
              minLines: minLines,
              maxLines: maxLines,
              maxLength: maxLength,
              requireNonEmpty: requireNonEmpty,
            ),
          ),
        );
      },
    );
  }

  @override
  State<AppPromptDialog> createState() => _AppPromptDialogState();
}

class _AppPromptDialogState extends State<AppPromptDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _hasContent = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    _hasContent = _controller.text.trim().isNotEmpty;
    _controller.addListener(_handleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleChanged() {
    final has = _controller.text.trim().isNotEmpty;
    if (has != _hasContent) {
      setState(() => _hasContent = has);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (widget.requireNonEmpty && value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final canConfirm = !widget.requireNonEmpty || _hasContent;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111111),
                              letterSpacing: -0.43,
                              height: 1.35,
                            ),
                          ),
                          if (widget.description != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              widget.description!,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF6B7280),
                                letterSpacing: -0.35,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F9FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFEEF0F2),
                            width: 1,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          minLines: widget.minLines,
                          maxLines: widget.maxLines,
                          maxLength: widget.maxLength,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF111111),
                            height: 1.5,
                            letterSpacing: -0.36,
                          ),
                          cursorColor: const Color(0xFFFF6B00),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            counterText: '',
                            hintText: widget.hintText,
                            hintStyle: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF9CA3AF),
                              height: 1.5,
                              letterSpacing: -0.36,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _PromptButton(
                              label: widget.cancelLabel,
                              enabled: true,
                              onTap: () => Navigator.pop(context, null),
                              background: const Color(0xFFF4F5F7),
                              foreground: const Color(0xFF4B5563),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _PromptButton(
                              label: widget.confirmLabel,
                              enabled: canConfirm,
                              onTap: _submit,
                              background: const Color(0xFFFF6B00),
                              foreground: Colors.white,
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
      ),
    );
  }
}

class _PromptButton extends StatelessWidget {
  const _PromptButton({
    required this.label,
    required this.onTap,
    required this.background,
    required this.foreground,
    required this.enabled,
  });

  final String label;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final bg = enabled ? background : background.withValues(alpha: 0.45);
    final fg = enabled ? foreground : foreground.withValues(alpha: 0.55);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: -0.375,
            ),
          ),
        ),
      ),
    );
  }
}
