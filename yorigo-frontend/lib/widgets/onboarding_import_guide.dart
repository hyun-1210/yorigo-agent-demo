import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/onboarding_profile.dart';
import '../utils/haptics.dart';

class OnboardingImportGuide extends StatefulWidget {
  const OnboardingImportGuide({
    super.key,
    required this.profile,
    required this.completed,
    required this.onCompleted,
  });

  final OnboardingProfile profile;
  final bool completed;
  final VoidCallback onCompleted;

  @override
  State<OnboardingImportGuide> createState() => _OnboardingImportGuideState();
}

class _OnboardingImportGuideState extends State<OnboardingImportGuide>
    with TickerProviderStateMixin {
  static const _ink = Color(0xFF111111);
  static const _muted = Color(0xFF8E8E93);
  static const _accent = Color(0xFFFF7A32);

  late int _phase;
  late final AnimationController _pulse;
  late final AnimationController _sheet;

  @override
  void initState() {
    super.initState();
    _phase = widget.completed ? 2 : 0;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _sheet = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    if (_phase >= 1) _sheet.value = 1;
  }

  @override
  void didUpdateWidget(OnboardingImportGuide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.completed && _phase != 2) {
      _phase = 2;
      _sheet.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sheet.dispose();
    super.dispose();
  }

  String get _sourceName {
    const linkable = {
      'youtube',
      'instagram',
      'tiktok',
      'naver_blog',
      'mango',
      'website',
    };
    final labels = widget.profile.recipeSources
        .where(linkable.contains)
        .map(
          (id) => OnboardingProfile.labelFor(
            id,
            OnboardingProfile.recipeSourceChoices,
          ),
        )
        .whereType<String>()
        .take(2)
        .toList();
    if (labels.isEmpty) return 'SNS';
    if (labels.length == 1) return labels.first;
    return '${labels[0]}·${labels[1]}';
  }

  Future<void> _openShare() async {
    if (_phase != 0) return;
    Haptics.medium();
    setState(() => _phase = 1);
    await _sheet.forward();
  }

  void _import() {
    if (_phase != 1) return;
    Haptics.success();
    setState(() => _phase = 2);
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final done = _phase == 2;
    return SizedBox.expand(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        child: Column(
          children: [
            Text(
              done ? '가져왔어요' : '스마트 가져오기',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                color: _ink,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                height: 1.25,
                letterSpacing: -0.7,
              ),
            ),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  color: _muted,
                  fontSize: 15,
                  height: 1.45,
                  letterSpacing: -0.2,
                ),
                children: done
                    ? const [
                        TextSpan(text: '레시피가 나의 레시피북에 정리됐어요.\n재료와 순서까지 바로 볼 수 있어요.'),
                      ]
                    : [
                        TextSpan(text: '$_sourceName 레시피를 '),
                        const TextSpan(
                          text: '읽고',
                          style: TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(text: ' 재료와 순서를 정리해요.'),
                      ],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: 248,
                  height: 478,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(36),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 24,
                          offset: Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(29),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          child: done
                              ? const _DonePhone(key: ValueKey('done'))
                              : _PlayPhone(
                                  key: const ValueKey('play'),
                                  phase: _phase,
                                  pulse: _pulse,
                                  sheet: _sheet,
                                  onShare: _openShare,
                                  onImport: _import,
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
    );
  }
}

class _PlayPhone extends StatelessWidget {
  const _PlayPhone({
    super.key,
    required this.phase,
    required this.pulse,
    required this.sheet,
    required this.onShare,
    required this.onImport,
  });

  final int phase;
  final Animation<double> pulse;
  final Animation<double> sheet;
  final VoidCallback onShare;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _ReelBackdrop(),
        if (phase == 0)
          Positioned(
            right: 14,
            bottom: 28,
            child: _TapShareButton(pulse: pulse, onTap: onShare),
          ),
        if (phase >= 1)
          _ShareSheetOverlay(
            pulse: pulse,
            sheet: sheet,
            onImport: onImport,
          ),
      ],
    );
  }
}

class _ReelBackdrop extends StatelessWidget {
  const _ReelBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF2B211C),
            Color(0xFF6B3E28),
            Color(0xFFD4783A),
          ],
        ),
      ),
      child: Stack(
        children: [
          const Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'Recipes',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 118,
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0xFF7EB6C9),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24, width: 6),
                boxShadow: const [
                  BoxShadow(color: Color(0x44000000), blurRadius: 16),
                ],
              ),
              child: const Icon(
                Icons.soup_kitchen_rounded,
                color: Colors.white,
                size: 52,
              ),
            ),
          ),
          const Positioned(
            left: 14,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '집밥 채널',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '오늘 저녁 수프',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            right: 14,
            top: 88,
            child: Column(
              children: [
                _ReelStat(icon: Icons.favorite_rounded, label: '225k'),
                SizedBox(height: 14),
                _ReelStat(icon: Icons.chat_bubble_rounded, label: '818'),
                SizedBox(height: 14),
                _ReelStat(icon: Icons.bookmark_rounded, label: '25'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelStat extends StatelessWidget {
  const _ReelStat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.white, size: 22),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TapShareButton extends StatelessWidget {
  const _TapShareButton({required this.pulse, required this.onTap});

  final Animation<double> pulse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = pulse.value;
        return Column(
          children: [
            Transform.translate(
              offset: Offset(0, 4 * math.sin(t * math.pi)),
              child: const _HandHint(label: '여기를 누르세요'),
            ),
            const SizedBox(height: 8),
            Transform.scale(
              scale: 1 + (t * 0.06),
              child: child,
            ),
          ],
        );
      },
      child: Material(
        color: _OnboardingImportGuideState._accent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: const SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.ios_share_rounded, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

class _ShareSheetOverlay extends StatelessWidget {
  const _ShareSheetOverlay({
    required this.pulse,
    required this.sheet,
    required this.onImport,
  });

  final Animation<double> pulse;
  final Animation<double> sheet;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: sheet, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0x66000000)),
          SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.28),
              end: Offset.zero,
            ).animate(curved),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0x33000000),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        _SheetThumb(),
                        SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '오늘 저녁 수프',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _OnboardingImportGuideState._ink,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Recipe from SNS',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  color: _OnboardingImportGuideState._muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const _SheetApp(
                          label: 'AirDrop',
                          color: Color(0xFF3A3A3C),
                          child: Icon(
                            Icons.wifi_tethering_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        _YorigoImportApp(pulse: pulse, onTap: onImport),
                        const _SheetApp(
                          label: '메시지',
                          color: Color(0xFF34C759),
                          child: Icon(
                            Icons.chat_bubble_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        const _SheetApp(
                          label: '더보기',
                          color: Color(0xFF8E8E93),
                          child: Icon(
                            Icons.more_horiz_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetThumb extends StatelessWidget {
  const _SheetThumb();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFD4783A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.soup_kitchen_rounded, color: Colors.white, size: 18),
    );
  }
}

class _SheetApp extends StatelessWidget {
  const _SheetApp({
    required this.label,
    required this.color,
    required this.child,
  });

  final String label;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(child: child),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 9,
            fontWeight: FontWeight.w500,
            color: _OnboardingImportGuideState._ink,
          ),
        ),
      ],
    );
  }
}

class _YorigoImportApp extends StatelessWidget {
  const _YorigoImportApp({required this.pulse, required this.onTap});

  final Animation<double> pulse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = pulse.value;
        return Column(
          children: [
            Transform.translate(
              offset: Offset(0, 3 * math.sin(t * math.pi)),
              child: const _HandHint(label: '탭해서 가져오기', dark: true),
            ),
            const SizedBox(height: 6),
            Transform.scale(scale: 1 + (t * 0.05), child: child),
          ],
        );
      },
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: _OnboardingImportGuideState._accent, width: 2),
                boxShadow: const [
                  BoxShadow(color: Color(0x55FF7A32), blurRadius: 10),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  'assets/icons/yorigo_app_icon.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              '요리GO',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: _OnboardingImportGuideState._ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HandHint extends StatelessWidget {
  const _HandHint({required this.label, this.dark = false});

  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? _OnboardingImportGuideState._ink : Colors.white;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.touch_app_rounded, color: color, size: 16),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

class _DonePhone extends StatelessWidget {
  const _DonePhone({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/onboarding_home_guide.jpg',
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          filterQuality: FilterQuality.high,
        ),
        const Positioned(
          top: 18,
          left: 0,
          right: 0,
          child: Text(
            '정리됐어요!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              color: _OnboardingImportGuideState._accent,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
        ),
      ],
    );
  }
}
