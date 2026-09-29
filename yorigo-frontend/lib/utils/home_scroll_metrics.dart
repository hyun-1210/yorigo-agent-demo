/// 홈 가로 캐러셀 / 세로 스크롤 깊이 계산 (analytics summary용).
library;

/// 가로 캐러셀에서 현재 viewport 끝 기준으로 보이는 최대 카드 인덱스.
int computeCarouselMaxVisibleIndex({
  required double pixels,
  required double viewportDimension,
  required double itemStride,
  required int itemCount,
}) {
  if (itemCount <= 0 || itemStride <= 0) return 0;
  final end = pixels + viewportDimension;
  if (end <= 0) return 0;
  final rawIndex = (end / itemStride).ceil() - 1;
  if (rawIndex < 0) return 0;
  if (rawIndex > itemCount - 1) return itemCount - 1;
  return rawIndex;
}

/// 세로 스크롤 깊이(0~100). maxExtent가 0이면 0.
double computeVerticalScrollDepthPercent({
  required double pixels,
  required double maxScrollExtent,
}) {
  if (maxScrollExtent <= 0) return 0;
  final ratio = pixels / maxScrollExtent;
  if (ratio.isNaN || ratio.isInfinite) return 0;
  return (ratio * 100).clamp(0.0, 100.0);
}
