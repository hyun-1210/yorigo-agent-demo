import 'package:flutter/material.dart';

/// Toss-style top toast notifications.
///
/// Usage:
///   AppToast.success(context, '로그인되었습니다');
///   AppToast.error(context, '비밀번호가 일치하지 않습니다');
///   AppToast.info(context, '저장되었습니다');
enum AppToastType { success, error, info, warning }

/// 토스트가 뜨는 위치. 화면 위쪽 버튼을 가리지 않도록 아래로 띄울 수 있다.
enum AppToastPosition { top, bottom }

class AppToast {
  AppToast._();

  static OverlayEntry? _currentEntry;

  static void success(BuildContext context, String message,
      {String? title,
      Duration duration = const Duration(milliseconds: 2400),
      AppToastPosition position = AppToastPosition.top}) {
    _show(context, message,
        title: title,
        type: AppToastType.success,
        duration: duration,
        position: position);
  }

  static void error(BuildContext context, String message,
      {String? title,
      Duration duration = const Duration(milliseconds: 2800),
      AppToastPosition position = AppToastPosition.top}) {
    _show(context, message,
        title: title,
        type: AppToastType.error,
        duration: duration,
        position: position);
  }

  static void info(BuildContext context, String message,
      {String? title,
      Duration duration = const Duration(milliseconds: 2400),
      AppToastPosition position = AppToastPosition.top}) {
    _show(context, message,
        title: title,
        type: AppToastType.info,
        duration: duration,
        position: position);
  }

  static void warning(BuildContext context, String message,
      {String? title,
      Duration duration = const Duration(milliseconds: 2400),
      AppToastPosition position = AppToastPosition.top}) {
    _show(context, message,
        title: title,
        type: AppToastType.warning,
        duration: duration,
        position: position);
  }

  static void _show(
    BuildContext context,
    String message, {
    String? title,
    required AppToastType type,
    required Duration duration,
    AppToastPosition position = AppToastPosition.top,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay == null) return;
    _insert(overlay, message,
        title: title, type: type, duration: duration, position: position);
  }

  /// [GlobalKey<NavigatorState>]처럼 Overlay 조상이 없는 context에서도 표시.
  static void showOnNavigator(
    GlobalKey<NavigatorState> navigatorKey,
    String message, {
    String? title,
    required AppToastType type,
    Duration duration = const Duration(milliseconds: 2400),
    AppToastPosition position = AppToastPosition.top,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _insert(overlay, message,
        title: title, type: type, duration: duration, position: position);
  }

  static OverlayState? _resolveOverlay(BuildContext context) {
    // 일반 위젯 context: Overlay는 조상에 있다.
    final fromAncestor = Overlay.maybeOf(context, rootOverlay: true);
    if (fromAncestor != null) return fromAncestor;
    // navigatorKey.currentContext는 Navigator 자체라 Overlay가 자식이다.
    return Navigator.maybeOf(context, rootNavigator: true)?.overlay;
  }

  static void _insert(
    OverlayState overlay,
    String message, {
    String? title,
    required AppToastType type,
    required Duration duration,
    AppToastPosition position = AppToastPosition.top,
  }) {
    _currentEntry?.remove();
    _currentEntry = null;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppToastView(
        message: message,
        title: title,
        type: type,
        duration: duration,
        position: position,
        onDismiss: () {
          if (_currentEntry == entry) {
            _currentEntry = null;
          }
          entry.remove();
        },
      ),
    );
    _currentEntry = entry;
    overlay.insert(entry);
  }
}

/// Drop-in replacement for `ScaffoldMessenger.of(context).showSnackBar(...)`
/// that renders the message as a top toast (below the header) instead of the
/// bottom of the screen.
///
/// Plain-text snackbars are converted to a top toast. Snackbars whose content
/// has no extractable text fall back to the original bottom snackbar.
void showAppSnackBar(
  BuildContext context,
  SnackBar snackBar, {
  AppToastPosition position = AppToastPosition.top,
}) {
  final message = _extractSnackBarMessage(snackBar.content);
  if (message == null || message.trim().isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(snackBar);
    return;
  }
  AppToast._show(
    context,
    message.trim(),
    type: _toastTypeFromSnackBar(snackBar),
    duration: snackBar.duration,
    position: position,
  );
}

String? _extractSnackBarMessage(Widget content) {
  if (content is Text) {
    return content.data ?? content.textSpan?.toPlainText();
  }
  if (content is RichText) {
    return content.text.toPlainText();
  }
  if (content is Padding) {
    final child = content.child;
    return child == null ? null : _extractSnackBarMessage(child);
  }
  if (content is Container) {
    final child = content.child;
    return child == null ? null : _extractSnackBarMessage(child);
  }
  if (content is Flexible) {
    return _extractSnackBarMessage(content.child);
  }
  if (content is Expanded) {
    return _extractSnackBarMessage(content.child);
  }
  if (content is Row) {
    return _firstTextInList(content.children);
  }
  if (content is Column) {
    return _firstTextInList(content.children);
  }
  return null;
}

String? _firstTextInList(List<Widget> children) {
  for (final child in children) {
    final found = _extractSnackBarMessage(child);
    if (found != null && found.trim().isNotEmpty) return found;
  }
  return null;
}

AppToastType _toastTypeFromSnackBar(SnackBar snackBar) {
  final bg = snackBar.backgroundColor;
  if (bg != null) {
    final r = (bg.r * 255).round();
    final g = (bg.g * 255).round();
    final b = (bg.b * 255).round();
    if (r > 170 && g < 120 && b < 120) return AppToastType.error;
  }
  return AppToastType.info;
}

class _AppToastView extends StatefulWidget {
  const _AppToastView({
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismiss,
    this.title,
    this.position = AppToastPosition.top,
  });

  final String message;
  final String? title;
  final AppToastType type;
  final Duration duration;
  final VoidCallback onDismiss;
  final AppToastPosition position;

  @override
  State<_AppToastView> createState() => _AppToastViewState();
}

class _AppToastViewState extends State<_AppToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    );
    // 위쪽이면 위에서, 아래쪽이면 아래에서 슬라이드되어 들어온다.
    final begin = widget.position == AppToastPosition.top ? -1.0 : 1.0;
    _slide = Tween<double>(begin: begin, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
    );
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();

    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _controller.reverse();
      if (!mounted) return;
      widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final config = _ToastConfig.fromType(widget.type);
    final isTop = widget.position == AppToastPosition.top;
    // 키보드가 떠 있으면 아래 토스트가 가려지지 않도록 인셋만큼 띄운다.
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final hasTitle = widget.title != null && widget.title!.trim().isNotEmpty;

    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _slide.value * 80),
            child: Opacity(opacity: _fade.value, child: child),
          );
        },
        child: SafeArea(
          child: Padding(
            // 상단 토스트는 앱 헤더(높이 52) 아래에 뜨도록 헤더 높이만큼 더 내린다.
            padding: EdgeInsets.only(
              top: isTop ? (mediaQuery.padding.top > 0 ? 8 : 16) + 52 : 0,
              bottom: isTop ? 0 : (keyboardInset > 0 ? keyboardInset + 12 : 16),
              left: 16,
              right: 16,
            ),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  14,
                  hasTitle ? 14 : 13,
                  16,
                  hasTitle ? 14 : 13,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: hasTitle
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: hasTitle ? 28 : 24,
                      height: hasTitle ? 28 : 24,
                      decoration: BoxDecoration(
                        color: config.iconBg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        config.icon,
                        size: hasTitle ? 15 : 14,
                        color: config.iconColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: hasTitle
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.title!.trim(),
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF111827),
                                    letterSpacing: -0.35,
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.message,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF6B7280),
                                    letterSpacing: -0.25,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              widget.message,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF111111),
                                letterSpacing: -0.3,
                                height: 1.4,
                              ),
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

class _ToastConfig {
  const _ToastConfig({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBg;

  factory _ToastConfig.fromType(AppToastType type) {
    switch (type) {
      case AppToastType.success:
        return const _ToastConfig(
          icon: Icons.check_rounded,
          iconColor: Colors.white,
          iconBg: Color(0xFFFF6B00),
        );
      case AppToastType.error:
        return const _ToastConfig(
          icon: Icons.close_rounded,
          iconColor: Colors.white,
          iconBg: Color(0xFFEF4444),
        );
      case AppToastType.warning:
        return const _ToastConfig(
          icon: Icons.priority_high_rounded,
          iconColor: Colors.white,
          iconBg: Color(0xFFF59E0B),
        );
      case AppToastType.info:
        return const _ToastConfig(
          icon: Icons.info_outline_rounded,
          iconColor: Color(0xFF6B7280),
          iconBg: Color(0xFFF3F4F6),
        );
    }
  }
}
