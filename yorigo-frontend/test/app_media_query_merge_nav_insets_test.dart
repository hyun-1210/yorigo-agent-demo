import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/widgets/app_media_query_merge_nav_insets.dart';

void main() {
  testWidgets('edge-to-edge에서 viewPadding을 MediaQuery.padding으로 병합한다', (
    tester,
  ) async {
    late MediaQueryData merged;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47),
          viewPadding: EdgeInsets.only(top: 47, bottom: 34),
          systemGestureInsets: EdgeInsets.only(bottom: 20),
        ),
        child: AppMediaQueryMergeNavInsets(
          child: Builder(
            builder: (context) {
              merged = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(merged.padding.top, 47);
    expect(merged.padding.bottom, 34);
    expect(appSystemNavBottomInset(
      tester.element(find.byType(SizedBox)),
    ), 34);
  });

  testWidgets('키보드가 열린 동안 bottom padding은 Flutter 기본값을 유지한다', (
    tester,
  ) async {
    late MediaQueryData merged;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 0),
          viewPadding: EdgeInsets.only(top: 47, bottom: 34),
          viewInsets: EdgeInsets.only(bottom: 280),
          systemGestureInsets: EdgeInsets.only(bottom: 20),
        ),
        child: AppMediaQueryMergeNavInsets(
          child: Builder(
            builder: (context) {
              merged = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(merged.padding.bottom, 0);
    expect(appSystemNavBottomInset(
      tester.element(find.byType(SizedBox)),
    ), 0);
  });

  testWidgets('gesture inset이 viewPadding보다 크면 더 큰 값을 사용한다', (
    tester,
  ) async {
    late MediaQueryData merged;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.only(bottom: 16),
          systemGestureInsets: EdgeInsets.only(bottom: 28),
        ),
        child: AppMediaQueryMergeNavInsets(
          child: Builder(
            builder: (context) {
              merged = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(merged.padding.bottom, 28);
  });
}
