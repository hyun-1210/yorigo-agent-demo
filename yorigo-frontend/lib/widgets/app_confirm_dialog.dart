import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ios_action_sheet.dart';

/// Modern white confirmation dialog used across the app.
///
/// Replaces the default Material `AlertDialog` with a softer, rounded
/// Toss-style card that matches the rest of the app's tone.
///
/// Usage:
/// ```dart
/// final ok = await AppConfirmDialog.show(
///   context: context,
///   title: '리뷰를 삭제할까요?',
///   description: '삭제된 리뷰는 복구할 수 없어요.',
///   confirmLabel: '삭제',
///   destructive: true,
/// );
/// ```
class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    super.key,
    required this.title,
    this.description,
    this.confirmLabel = '확인',
    this.cancelLabel = '취소',
    this.destructive = false,
  });

  final String title;
  final String? description;
  final String confirmLabel;
  final String cancelLabel;

  /// When `true`, the confirm button uses a red fill to signal a destructive
  /// action. Otherwise the app's primary orange is used.
  final bool destructive;

  /// Returns `true` if the user tapped the confirm button, `false` if they
  /// tapped cancel, or `null` if the dialog was dismissed (barrier/back).
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    String? description,
    String confirmLabel = '확인',
    String cancelLabel = '취소',
    bool destructive = false,
    bool barrierDismissible = true,
  }) async {
    if (IosActionSheet.shouldUse(context)) {
      try {
        return await IosActionSheet.showConfirm(
          context: context,
          title: title,
          message: description,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: destructive,
        );
      } on MissingPluginException {
        // Fall through to the Flutter dialog.
      } on PlatformException {
        // iPad / missing host — keep the existing popup.
      }
    }
    return showGeneralDialog<bool>(
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
            child: AppConfirmDialog(
              title: title,
              description: description,
              confirmLabel: confirmLabel,
              cancelLabel: cancelLabel,
              destructive: destructive,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctx = context;
    final confirmBg = destructive
        ? const Color(0xFFEF4444)
        : const Color(0xFFFF6B00);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
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
                    padding: EdgeInsets.fromLTRB(
                      24,
                      24,
                      24,
                      description == null ? 16 : 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111111),
                            letterSpacing: -0.43,
                            height: 1.35,
                          ),
                        ),
                        if (description != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            description!,
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
                  if (description != null) const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _AppDialogButton(
                            label: cancelLabel,
                            onTap: () => Navigator.pop(ctx, false),
                            background: const Color(0xFFF4F5F7),
                            foreground: const Color(0xFF4B5563),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _AppDialogButton(
                            label: confirmLabel,
                            onTap: () => Navigator.pop(ctx, true),
                            background: confirmBg,
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
    );
  }
}

class _AppDialogButton extends StatelessWidget {
  const _AppDialogButton({
    required this.label,
    required this.onTap,
    required this.background,
    required this.foreground,
  });

  final String label;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: foreground,
              letterSpacing: -0.375,
            ),
          ),
        ),
      ),
    );
  }
}
