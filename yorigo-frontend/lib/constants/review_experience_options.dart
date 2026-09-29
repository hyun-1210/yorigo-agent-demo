/// Progressive review sheet and Firestore `reviews` documents share these strings.
abstract final class ReviewExperienceOptions {
  ReviewExperienceOptions._();

  static const List<String> benefitOptions = [
    '🍳 조리가 간편해요',
    '⏱️ 빠르게 완성돼요',
    '📋 설명이 자세해요',
    '😋 맛이 실패 없어요',
    '📸 비주얼이 멋져요',
    '🧹 뒷정리가 편해요',
    '💰 가성비가 좋아요',
    '👨‍👩‍👧 가족들이 좋아해요',
  ];

  static const List<String> difficultyLabels = [
    '어려웠어요',
    '적당해요',
    '쉬웠어요',
  ];

  static const List<String> explanationLabels = [
    '헷갈려요',
    '적당해요',
    '자세해요',
  ];

  /// Summary row "체감 난이도 · 적당해요 · N%"
  static const String summaryDifficultyAnchor = '적당해요';

  /// Summary row "레시피 설명 · 자세해요 · N%"
  static const String summaryExplanationAnchor = '자세해요';
}
