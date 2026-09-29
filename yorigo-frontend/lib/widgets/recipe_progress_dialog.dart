import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class RecipeProgressDialog extends StatelessWidget {
  final String currentStage;
  final double progress;

  const RecipeProgressDialog({
    super.key,
    required this.currentStage,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.getBackground(brightness),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Yorigo icon
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.all(10),
              child: Image.asset(
                'assets/Yorigo_icon_light.png',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 24),

            // Progress indicator
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: progress / 100,
                    strokeWidth: 8,
                    backgroundColor: AppColors.getBackgroundTertiary(
                      brightness,
                    ),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  ),
                ),
                Text(
                  '${progress.toInt()}%',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Current stage text
            Text(
              currentStage,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.getTextPrimary(brightness),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),

            // Stage progress list
            _buildStageList(currentStage, progress, brightness),
          ],
        ),
      ),
    );
  }

  Widget _buildStageList(
    String currentStage,
    double progress,
    Brightness brightness,
  ) {
    final stages = [
      {'name': '분석중...', 'progress': 0},
      {'name': '레시피 분석중', 'progress': 16},
      {'name': '재료 분석중', 'progress': 33},
      {'name': '카테고리 분석중', 'progress': 50},
      {'name': '태그 분석중', 'progress': 66},
      {'name': '영양 분석중', 'progress': 83},
    ];

    return Column(
      children: stages.map((stage) {
        final stageName = stage['name'] as String;
        final stageProgress = (stage['progress'] as int?) ?? 0;
        final isCompleted = progress > stageProgress;
        final isCurrent = currentStage == stageName;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                isCompleted
                    ? Icons.check_circle
                    : isCurrent
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: isCompleted
                    ? Colors.green
                    : isCurrent
                    ? AppColors.primary
                    : AppColors.getTextTertiary(brightness),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  stageName,
                  style: TextStyle(
                    fontSize: 14,
                    color: isCompleted || isCurrent
                        ? AppColors.getTextPrimary(brightness)
                        : AppColors.getTextTertiary(brightness),
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
