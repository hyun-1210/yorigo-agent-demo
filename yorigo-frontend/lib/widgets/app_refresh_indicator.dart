import 'package:flutter/material.dart';

/// 앱 전역에서 동일하게 사용하는 당겨서 새로고침 인디케이터.
///
/// 모든 화면에서 흰색 배경 + 어두운(검정) 화살표로 통일한다.
class AppRefreshIndicator extends StatelessWidget {
  const AppRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.displacement = 40.0,
    this.edgeOffset = 0.0,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final double displacement;
  final double edgeOffset;

  /// 화살표/스피너 색 (검정 계열).
  static const Color arrowColor = Color(0xFF111111);

  /// 인디케이터 원형 배경색 (흰색).
  static const Color circleBackgroundColor = Colors.white;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      displacement: displacement,
      edgeOffset: edgeOffset,
      color: arrowColor,
      backgroundColor: circleBackgroundColor,
      strokeWidth: 2.5,
      child: child,
    );
  }
}
