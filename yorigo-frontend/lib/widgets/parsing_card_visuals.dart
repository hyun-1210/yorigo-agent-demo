import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

// -----------------------------------------------------------------------------
// 분석 중 카드 전용 비주얼 (토스식).
//  - [ParsingSpinnerRing]   : 진행률과 무관하게 "계속" 부드럽게 도는 주황 링.
//                             (determinate 링이 94%→0%로 리셋되던 버그 제거)
//  - [ParsingStageCarousel] : 5단계 안내 문구를 순차로 페이드/슬라이드 전환해
//                             대기 시간을 지루하지 않게 보여준다.
// -----------------------------------------------------------------------------

/// 분석 중 카드의 로딩 비주얼.
/// Lottie 주방 쿠킹 애니메이션을 반복 재생한다.
/// [size]가 주어지면 정사각형으로, 아니면 부모(썸네일 박스)를 가득 채운다.
class ParsingSpinnerRing extends StatelessWidget {
  const ParsingSpinnerRing({
    super.key,
    this.size,
    this.fit = BoxFit.contain,
    this.scale = 1.3,
  });

  /// 정사각형 크기. null이면 부모 크기를 채운다.
  final double? size;
  final BoxFit fit;

  /// 박스 안에서 애니메이션을 살짝 키우는 배율(부모가 클립하므로 밖으로 안 나간다).
  final double scale;

  static const String _asset = 'assets/lottie/parsing_loader.json';

  @override
  Widget build(BuildContext context) {
    Widget animation = Lottie.asset(
      _asset,
      fit: fit,
      repeat: true,
      animate: true,
    );
    if (scale != 1.0) {
      animation = Transform.scale(scale: scale, child: animation);
    }
    if (size != null) {
      return SizedBox(width: size, height: size, child: animation);
    }
    return SizedBox.expand(child: animation);
  }
}

/// 분석 단계 안내. [stages] 5단계를 순차로 보여주며 일정 간격으로 다음 단계로 전환.
/// 진행률에 묶지 않고 자체 타이머로 순환해 항상 살아있는 느낌을 준다.
class ParsingStageCarousel extends StatefulWidget {
  const ParsingStageCarousel({super.key});

  static const List<({String title, String sub})> stages = [
    (title: '앞치마 두르는 중', sub: '레시피 링크 여는 중'),
    (title: '영상 정주행 중', sub: '자막까지 꼼꼼히 보는 중'),
    (title: '재료 탈탈 터는 중', sub: '뭐가 들어갔나 살피는 중'),
    (title: '레시피 받아적는 중', sub: '순서대로 정리하는 중'),
    (title: '간 보는 중', sub: '빠진 재료 없나 확인하는 중'),
  ];

  @override
  State<ParsingStageCarousel> createState() => _ParsingStageCarouselState();
}

class _ParsingStageCarouselState extends State<ParsingStageCarousel> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 2.8초마다 다음 단계로 천천히 전환(너무 빨리 안 바뀌게).
    _timer = Timer.periodic(const Duration(milliseconds: 2800), (_) {
      if (!mounted) return;
      setState(() {
        _index = (_index + 1) % ParsingStageCarousel.stages.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = ParsingStageCarousel.stages[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // (B) 단계 텍스트: 제목에 흐르는 샤이머 + 단계 전환은 롤업 페이드.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 360),
          reverseDuration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) {
            // 부모 Expanded 폭을 Stack/텍스트에 전달해 말줄임이 동작하게 한다.
            return SizedBox(
              width: double.infinity,
              child: Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.hardEdge,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              ),
            );
          },
          transitionBuilder: (child, anim) {
            final slide = Tween<Offset>(
              begin: const Offset(0, 0.14),
              end: Offset.zero,
            ).animate(anim);
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(position: slide, child: child),
            );
          },
          child: SizedBox(
            width: double.infinity,
            child: Column(
              key: ValueKey(_index),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _ShimmerText(
                  text: stage.title,
                  base: const Color(0xFF191F28),
                  highlight: const Color(0xFFFF8A2B),
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    letterSpacing: -0.35,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  stage.sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    letterSpacing: -0.2,
                    color: Color(0xFFAEB4BE),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 글자 위로 밝은 하이라이트가 흐르는 샤이머 텍스트(대기업 로딩 느낌).
class _ShimmerText extends StatefulWidget {
  const _ShimmerText({
    required this.text,
    required this.style,
    required this.base,
    required this.highlight,
  });

  final String text;
  final TextStyle style;
  final Color base;
  final Color highlight;

  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return SizedBox(
          width: double.infinity,
          child: ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (rect) {
              const band = 0.22;
              // 하이라이트 밴드 중심을 -band → 1+band 로 이동.
              final c = _c.value * (1 + 2 * band) - band;
              var a = (c - band).clamp(0.0, 1.0);
              var b = c.clamp(0.0, 1.0);
              var d = (c + band).clamp(0.0, 1.0);
              // 동일 stop이 겹치면 그라데이션이 깜빡일 수 있어 최소 간격을 둔다.
              const eps = 0.001;
              if (b <= a) b = (a + eps).clamp(0.0, 1.0);
              if (d <= b) d = (b + eps).clamp(0.0, 1.0);
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [widget.base, widget.highlight, widget.base],
                stops: [a, b, d],
              ).createShader(rect);
            },
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.style.copyWith(color: Colors.white),
            ),
          ),
        );
      },
    );
  }
}



