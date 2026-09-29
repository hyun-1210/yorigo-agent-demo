import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A compact, refined step indicator: a lifted white pill containing a small
/// "STEP" caption, animated rounded progress segments, and an "n / total"
/// counter. Shared across the multi-step add-to-cart flow so each step shows a
/// consistent badge (e.g. 1 / 2 → 2 / 2).
class StepProgressBadge extends StatelessWidget {
  final int currentStep;
  final int totalSteps;

  const StepProgressBadge({
    super.key,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 11, 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.22), width: 1),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'STEP',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 9,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: accent.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(width: 8),
          for (var i = 0; i < totalSteps; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: i < currentStep ? 16 : 6,
              height: 5,
              decoration: BoxDecoration(
                gradient: i < currentStep
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          accent,
                          Color.lerp(accent, const Color(0xFFFF8A3D), 0.4) ??
                              accent,
                        ],
                      )
                    : null,
                color: i < currentStep
                    ? null
                    : accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
          const SizedBox(width: 9),
          RichText(
            text: TextSpan(
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11.5,
                height: 1,
                letterSpacing: -0.2,
              ),
              children: [
                TextSpan(
                  text: '$currentStep',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
                TextSpan(
                  text: ' / $totalSteps',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: accent.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
