import 'dart:async';

import 'package:flutter/material.dart';

import 'level_up_celebration.dart';

/// 경험치 획득 시 화면 위에 잠깐 뜨는 +EXP 표시.
class XpGainOverlay {
  XpGainOverlay._();

  static OverlayEntry? _entry;

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }

  static void showOnNavigator(
    GlobalKey<NavigatorState> navigatorKey, {
    required int amount,
    String? label,
  }) {
    if (amount <= 0) return;
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay != null) {
      show(overlay, amount: amount, label: label);
      return;
    }
    void attempt(int tries) {
      final next = navigatorKey.currentState?.overlay;
      if (next == null) {
        if (tries >= 10) return;
        Future<void>.delayed(
          const Duration(milliseconds: 16),
          () => attempt(tries + 1),
        );
        return;
      }
      show(next, amount: amount, label: label);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt(0));
  }

  static void show(
    OverlayState overlay, {
    required int amount,
    String? label,
  }) {
    dismiss();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _XpGainView(
        amount: amount,
        label: label,
        onDismiss: () {
          if (_entry == entry) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

/// +EXP와 레벨업이 겹치지 않게 한 줄로 재생한다.
/// 순서: 경험치 표시 → 사라진 뒤 → 레벨이 올랐을 때만 연출.
class XpFeedback {
  XpFeedback._();

  static Future<void> _tail = Future<void>.value();

  static Future<void> enqueue({
    required GlobalKey<NavigatorState> navigatorKey,
    required int amount,
    String? label,
    int? fromLevel,
    int? toLevel,
  }) {
    final done = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await _play(
          navigatorKey: navigatorKey,
          amount: amount,
          label: label,
          fromLevel: fromLevel,
          toLevel: toLevel,
        );
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  static Future<void> _play({
    required GlobalKey<NavigatorState> navigatorKey,
    required int amount,
    String? label,
    int? fromLevel,
    int? toLevel,
  }) async {
    final willLevelUp =
        fromLevel != null && toLevel != null && toLevel > fromLevel;

    if (amount > 0) {
      XpGainOverlay.showOnNavigator(
        navigatorKey,
        amount: amount,
        label: label,
      );
      await Future<void>.delayed(
        Duration(milliseconds: willLevelUp ? 2000 : 2600),
      );
    }

    if (!willLevelUp) return;

    XpGainOverlay.dismiss();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    await LevelUpCelebration.show(
      context: context,
      fromLevel: fromLevel,
      toLevel: toLevel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

class _XpGainView extends StatefulWidget {
  const _XpGainView({
    required this.amount,
    required this.onDismiss,
    this.label,
  });

  final int amount;
  final String? label;
  final VoidCallback onDismiss;

  @override
  State<_XpGainView> createState() => _XpGainViewState();
}

class _XpGainViewState extends State<_XpGainView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..forward().whenComplete(widget.onDismiss);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AppHeader(52) 바로 아래. viewPadding은 시트·세이프영역과 무관하게 고정.
    final top = MediaQuery.viewPaddingOf(context).top + 52 + 8;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final t = _anim.value;
          final appear =
              Curves.easeOutCubic.transform((t / 0.12).clamp(0.0, 1.0));
          final hold =
              t < 0.82 ? 1.0 : 1.0 - ((t - 0.82) / 0.18).clamp(0.0, 1.0);
          final opacity = appear * Curves.easeOut.transform(hold);
          final dy = (1 - appear) * -16 + (t > 0.82 ? (t - 0.82) * -14 : 0);
          return Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: top),
              child: Opacity(
                opacity: opacity,
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFFFE1D1)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.label != null && widget.label!.isNotEmpty) ...[
                  Text(
                    widget.label!,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B7280),
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  '+${widget.amount} EXP',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF6B00),
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
