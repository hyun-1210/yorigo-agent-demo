import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/analytics_service.dart';

/// 레시피 카드 impression 중복 방지 — 프로세스 생존 기간 동안 유지.
final Set<String> _recipeSignalImpressionFired = <String>{};

/// 화면에 50% 이상 보이면 GCS 레시피 impression을 1회 기록한다.
class RecipeSignalImpression extends StatelessWidget {
  const RecipeSignalImpression({
    super.key,
    required this.screen,
    required this.recipe,
    required this.child,
    this.sectionId,
    this.position,
    this.posterId,
    this.chipSectionKey,
  });

  final String screen;
  final Map<String, dynamic> recipe;
  final Widget child;
  final String? sectionId;
  final int? position;
  final String? posterId;
  final String? chipSectionKey;

  @override
  Widget build(BuildContext context) {
    final recipeId =
        (recipe['id'] ?? recipe['recipeId'])?.toString().trim() ?? '';
    if (recipeId.isEmpty) return child;
    final dedupKey =
        '$screen::${posterId ?? ''}::${sectionId ?? 'default'}::$recipeId::${position ?? 0}';
    return VisibilityDetector(
      key: Key('recipe_signal_impression_$dedupKey'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (_recipeSignalImpressionFired.contains(dedupKey)) return;
        _recipeSignalImpressionFired.add(dedupKey);
        unawaited(
          AnalyticsService().logRecipeMapEvent(
            'impression',
            screen: screen,
            recipe: recipe,
            sectionId: sectionId,
            position: position,
            posterId: posterId,
            chipSectionKey: chipSectionKey,
          ),
        );
      },
      child: child,
    );
  }
}

/// 레시피 map이 없는 피드·식단 카드용 impression. recipeId만으로 1회 기록한다.
class RecipeIdSignalImpression extends StatelessWidget {
  const RecipeIdSignalImpression({
    super.key,
    required this.screen,
    required this.recipeId,
    required this.child,
    this.sectionId,
    this.position,
    this.contentType = 'recipe',
  });

  final String screen;
  final String recipeId;
  final Widget child;
  final String? sectionId;
  final int? position;
  final String contentType;

  @override
  Widget build(BuildContext context) {
    final id = recipeId.trim();
    if (id.isEmpty) return child;
    final dedupKey =
        '$screen::${sectionId ?? 'default'}::$id::${position ?? 0}';
    return VisibilityDetector(
      key: Key('recipe_id_signal_impression_$dedupKey'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (_recipeSignalImpressionFired.contains(dedupKey)) return;
        _recipeSignalImpressionFired.add(dedupKey);
        unawaited(
          AnalyticsService().logCardEvent(
            'impression',
            screen: screen,
            sectionId: sectionId,
            cardId: id,
            contentType: contentType,
            recipeId: id,
            position: position,
          ),
        );
      },
      child: child,
    );
  }
}
