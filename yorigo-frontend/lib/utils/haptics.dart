import 'package:flutter/services.dart';

/// 앱 전역 햅틱 피드백 헬퍼.
///
/// 플랫폼별 진동 강도 차이를 감추고 "의미 단위"로 호출하기 위한 래퍼.
/// 웹에서는 자동으로 무시되고, 실제 단말(iOS/Android)에서만 동작한다.
class Haptics {
  Haptics._();

  /// 탭/토글 등 가벼운 상호작용 (칩 선택, 체크, 작은 버튼).
  static void light() => HapticFeedback.lightImpact();

  /// 선택 변경 (하단 탭 전환, 세그먼트, 필터 pill, 스테퍼).
  static void selection() => HapticFeedback.selectionClick();

  /// 주요 액션 확정 (추천 실행, 담기, 추가 등 묵직한 버튼).
  static void medium() => HapticFeedback.mediumImpact();

  /// 완료/성공 피드백.
  static void success() => HapticFeedback.mediumImpact();

  /// 경고/에러 피드백.
  static void error() => HapticFeedback.heavyImpact();
}
