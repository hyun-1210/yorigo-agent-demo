import 'package:flutter/material.dart';

import '../utils/haptics.dart';

/// EXP로 레벨이 올랐을 때 잠깐 보여주는 연출.
class LevelUpCelebration {
  LevelUpCelebration._();

  static Future<void> show({
    required BuildContext context,
    required int fromLevel,
    required int toLevel,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierLabel: '레벨',
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (ctx, _, _) => _LevelUpCelebrationView(
        fromLevel: fromLevel,
        toLevel: toLevel,
      ),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }
}

class _LevelUpCelebrationView extends StatefulWidget {
  const _LevelUpCelebrationView({
    required this.fromLevel,
    required this.toLevel,
  });

  final int fromLevel;
  final int toLevel;

  @override
  State<_LevelUpCelebrationView> createState() =>
      _LevelUpCelebrationViewState();
}

class _LevelUpCelebrationViewState extends State<_LevelUpCelebrationView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    )..forward();
    Haptics.light();
    Future<void>.delayed(const Duration(milliseconds: 360), () {
      if (mounted) Haptics.success();
    });
    Future<void>.delayed(const Duration(milliseconds: 2680), _close);
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final glow = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    final badge = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.06, 0.42, curve: Curves.easeOutCubic),
    );
    final fromFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.22, 0.48, curve: Curves.easeIn),
    );
    final toFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.40, 0.78, curve: Curves.easeOutCubic),
    );
    final nameFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.54, 0.88, curve: Curves.easeOut),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _intro,
          builder: (context, _) {
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xE6111111)),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: badge.value,
                        child: const Text(
                          'LEVEL UP',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            color: Color(0xFFFF8A3D),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2.4,
                            height: 1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 220,
                        height: 220,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: glow.value * 0.9,
                              child: Container(
                                width: 200,
                                height: 200,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      const Color(0xFFFF6B00)
                                          .withValues(alpha: 0.48),
                                      const Color(0xFFFF6B00)
                                          .withValues(alpha: 0.0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Transform.scale(
                              scale: 0.92 + (0.08 * badge.value),
                              child: Opacity(
                                opacity: badge.value,
                                child: _LevelBadge(
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Opacity(
                                        opacity: 1 - fromFade.value,
                                        child: Transform.translate(
                                          offset:
                                              Offset(0, -6 * fromFade.value),
                                          child: _LevelText(
                                            'LV.${widget.fromLevel}',
                                          ),
                                        ),
                                      ),
                                      Opacity(
                                        opacity: toFade.value,
                                        child: Transform.scale(
                                          scale: 0.88 + (0.12 * toFade.value),
                                          child: _LevelText(
                                            'LV.${widget.toLevel}',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Opacity(
                        opacity: nameFade.value,
                        child: Transform.translate(
                          offset: Offset(0, 8 * (1 - nameFade.value)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              '축하해요, 레벨 업!',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                color: Color(0xFFF3F4F6),
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.35,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _LevelText extends StatelessWidget {
  const _LevelText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Pretendard',
        color: Colors.white,
        fontSize: 34,
        fontWeight: FontWeight.w900,
        height: 1.15,
        letterSpacing: 0.4,
      ),
    );
  }
}
