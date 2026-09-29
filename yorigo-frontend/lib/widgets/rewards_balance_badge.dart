import 'package:flutter/material.dart';

import '../services/rewards_service.dart';

/// 홈 헤더·하단 프로필 탭·프로필 아바타 옆 등에 쓰는 포인트/경험치 잔액 뱃지.
class RewardsBalanceBadge extends StatelessWidget {
  const RewardsBalanceBadge({
    super.key,
    this.dense = false,
    this.onTap,
    this.showWhenZero = true,
  });

  /// 하단 네비처럼 좁은 공간용.
  final bool dense;
  final VoidCallback? onTap;
  final bool showWhenZero;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RewardsSummary?>(
      stream: RewardsService.instance.watchSummary(),
      builder: (context, snapshot) {
        final summary = snapshot.data;
        if (summary == null) return const SizedBox.shrink();
        if (!showWhenZero &&
            summary.pointsBalance <= 0 &&
            summary.expTotal <= 0) {
          return const SizedBox.shrink();
        }

        final level = summary.level < 1 ? 1 : summary.level;
        final gap = dense ? 3.0 : 5.0;
        // 레벨만 보이면 EXP 적립이 티가 안 나서 총 EXP도 함께 표시.
        final child = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chip(
              label: 'Lv.$level · ${summary.expTotal}EXP',
              foreground: const Color(0xFF2563EB),
              background: const Color(0xFFEFF6FF),
              dense: dense,
            ),
            SizedBox(width: gap),
            _chip(
              label: '${summary.pointsBalance}P',
              foreground: const Color(0xFFFF6B00),
              background: const Color(0xFFFFF1E6),
              dense: dense,
            ),
          ],
        );

        if (onTap == null) return child;
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: child,
        );
      },
    );
  }

  Widget _chip({
    required String label,
    required Color foreground,
    required Color background,
    required bool dense,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: dense ? 10 : 12,
          fontWeight: FontWeight.w800,
          color: foreground,
          height: 1.1,
        ),
      ),
    );
  }
}
