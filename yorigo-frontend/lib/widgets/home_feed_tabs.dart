import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 홈 상단 탭 — 커뮤니티(탐색) 탭바와 동일 비율.
/// 선택: 검정 볼드 + 주황 pill 밑줄.
class HomeFeedTabs extends StatelessWidget {
  const HomeFeedTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.tabWidths,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// null이면 글자 수 기준 기본 폭(2글자=32).
  final List<double>? tabWidths;

  /// 홈 기본: 추천 / 인기.
  static const List<String> defaultTabs = ['추천', '인기'];

  static const Color _orange = Color(0xFFFF6B00);
  static const Color _activeText = Color(0xFF101828);
  static const Color _inactiveText = Color(0xFF99A1AF);
  static const double _spacing = 18;
  static const double _leftPadding = 20;
  static const double height = 48;
  static const double _indicatorThickness = 2.5;

  List<double> get _widths {
    if (tabWidths != null && tabWidths!.length == tabs.length) {
      return tabWidths!;
    }
    // 커뮤니티와 동일: 2글자 탭 32
    return List<double>.filled(tabs.length, 32);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);
    final borderLine = AppColors.getBorder(brightness);
    final widths = _widths;
    final index = selectedIndex.clamp(0, tabs.length - 1);
    final indicatorLeft = _leftPadding +
        List<double>.generate(
          index,
          (i) => widths[i] + _spacing,
        ).fold<double>(0, (total, value) => total + value);
    final indicatorWidth = widths[index];

    return ColoredBox(
      color: bg,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 1,
              child: ColoredBox(color: borderLine),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: indicatorLeft,
              bottom: 0,
              width: indicatorWidth,
              height: _indicatorThickness,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _orange,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Positioned.fill(
              child: Padding(
                // 커뮤니티 탭바: horizontal 20 (좌측 정렬 여백)
                padding: const EdgeInsets.symmetric(horizontal: _leftPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < tabs.length; i++) ...[
                      if (i > 0) const SizedBox(width: _spacing),
                      SizedBox(
                        width: widths[i],
                        height: height,
                        child: GestureDetector(
                          onTap: () => onSelected(i),
                          behavior: HitTestBehavior.opaque,
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              tabs[i],
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: i == index
                                    ? _activeText
                                    : _inactiveText,
                                height: 24 / 16,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
