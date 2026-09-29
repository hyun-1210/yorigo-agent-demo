import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/home_scroll_metrics.dart';

void main() {
  group('computeCarouselMaxVisibleIndex', () {
    const stride = 140.0 + 12.0; // card + gap

    test('at rest shows first viewport cards', () {
      // viewport ~ 360 → roughly 2+ cards → index 1 or 2
      final index = computeCarouselMaxVisibleIndex(
        pixels: 0,
        viewportDimension: 360,
        itemStride: stride,
        itemCount: 20,
      );
      expect(index, greaterThanOrEqualTo(1));
      expect(index, lessThan(20));
    });

    test('scrolled deep increases max index and clamps to last', () {
      final mid = computeCarouselMaxVisibleIndex(
        pixels: stride * 5,
        viewportDimension: 360,
        itemStride: stride,
        itemCount: 20,
      );
      final end = computeCarouselMaxVisibleIndex(
        pixels: stride * 100,
        viewportDimension: 360,
        itemStride: stride,
        itemCount: 20,
      );
      expect(mid, greaterThan(5));
      expect(end, 19);
    });

    test('empty or invalid inputs return 0', () {
      expect(
        computeCarouselMaxVisibleIndex(
          pixels: 0,
          viewportDimension: 360,
          itemStride: stride,
          itemCount: 0,
        ),
        0,
      );
      expect(
        computeCarouselMaxVisibleIndex(
          pixels: 0,
          viewportDimension: 360,
          itemStride: 0,
          itemCount: 10,
        ),
        0,
      );
    });
  });

  group('computeVerticalScrollDepthPercent', () {
    test('maps offset to percent and clamps', () {
      expect(
        computeVerticalScrollDepthPercent(pixels: 0, maxScrollExtent: 1000),
        0,
      );
      expect(
        computeVerticalScrollDepthPercent(pixels: 500, maxScrollExtent: 1000),
        50,
      );
      expect(
        computeVerticalScrollDepthPercent(pixels: 2000, maxScrollExtent: 1000),
        100,
      );
      expect(
        computeVerticalScrollDepthPercent(pixels: 10, maxScrollExtent: 0),
        0,
      );
    });
  });
}
