import 'package:flutter/material.dart';

/// 홈 섹션 공통 크롬: 구분선 · 타이틀 · 전체보기.
/// TV / 셰프 / 트렌드 섹션이 같은 비율을 쓰도록 한곳에서 관리한다.

const Color homeSectionDividerColor = Color(0xFFF2F2F2);
const double homeSectionRuleBandHeight = 8;
const double homeSectionRuleGap = 16;
const Color homeSectionSeeAllColor = Color(0xFF666666);

TextStyle homeSectionTitleStyle(Color color) {
  return TextStyle(
    fontFamily: 'Pretendard',
    fontSize: 17,
    fontWeight: FontWeight.w800,
    color: color,
    letterSpacing: -0.4,
    height: 1.25,
  );
}

/// Baemin-style section band: full-bleed light gray with equal white space above/below.
Widget homeSectionRule() {
  return const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(height: homeSectionRuleGap),
      SizedBox(
        width: double.infinity,
        height: homeSectionRuleBandHeight,
        child: ColoredBox(color: homeSectionDividerColor),
      ),
      SizedBox(height: homeSectionRuleGap),
    ],
  );
}

/// 섹션 헤더 '전체보기 >': 글자 13 / chevron 10 / #666 / 타이틀과 수직 중앙.
Widget homeSectionSeeAllArrow({
  required VoidCallback onTap,
  String semanticLabel = '전체보기',
}) {
  return Semantics(
    button: true,
    label: semanticLabel,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: const Padding(
        padding: EdgeInsets.fromLTRB(6, 0, 0, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '전체보기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: homeSectionSeeAllColor,
                letterSpacing: -0.2,
                height: 1.25,
              ),
            ),
            SizedBox(width: 4),
            Icon(
              Icons.arrow_forward_ios,
              size: 10,
              color: homeSectionSeeAllColor,
            ),
          ],
        ),
      ),
    ),
  );
}
