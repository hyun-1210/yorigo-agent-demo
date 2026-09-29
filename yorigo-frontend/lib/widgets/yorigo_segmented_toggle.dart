import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 설정 스타일의 슬라이딩 세그먼트 토글(2옵션 전용).
class YorigoSegmentedToggle extends StatelessWidget {
  final String leftLabel;
  final String rightLabel;
  final int selectedIndex; // 0: left, 1: right
  final ValueChanged<int> onChanged;
  final Color activeColor;
  final Color inactiveBackgroundColor;

  const YorigoSegmentedToggle({
    super.key,
    required this.leftLabel,
    required this.rightLabel,
    required this.selectedIndex,
    required this.onChanged,
    this.activeColor = const Color(0xFFFF6B35),
    this.inactiveBackgroundColor = const Color(0xFFF2F3F5),
  }) : assert(selectedIndex == 0 || selectedIndex == 1);

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.15,
    );

    final children = <int, Widget>{
      0: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
        child: Text(
          leftLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textStyle.copyWith(
            color: selectedIndex == 0 ? Colors.white : const Color(0xFF5B6472),
          ),
        ),
      ),
      1: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
        child: Text(
          rightLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textStyle.copyWith(
            color: selectedIndex == 1 ? Colors.white : const Color(0xFF5B6472),
          ),
        ),
      ),
    };

    return CupertinoTheme(
      data: CupertinoTheme.of(context).copyWith(
        primaryColor: activeColor,
      ),
      child: Container(
        constraints: const BoxConstraints(minWidth: 188),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: inactiveBackgroundColor,
        ),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: selectedIndex,
          children: children,
          thumbColor: activeColor,
          backgroundColor: inactiveBackgroundColor,
          onValueChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }
}
