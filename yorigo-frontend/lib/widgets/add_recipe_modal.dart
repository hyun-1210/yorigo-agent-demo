import 'package:flutter/material.dart';

import '../screens/add_recipe_screen.dart';

/// `AddRecipeScreen` 을 호출 컨텍스트의 Navigator 위에 modal bottom sheet 로 띄운다.
///
/// 기존 `mainNavigatorKey.currentState.showAddRecipeSheet(...)` 는 root shell 의
/// IndexedStack 위에 sheet 를 layered 로 그리기 때문에, push 된 fullscreen 라우트
/// (예: TrendingAllPage, 리뷰 피드 스크롤 화면) 에 가려져 사용자가 그 라우트를
/// 닫을 때까지 sheet 가 보이지 않는다. 이 헬퍼는 호출 측 컨텍스트의 Navigator
/// 에 직접 모달을 푸시해 그 화면 위에 sheet 가 즉시 뜨도록 한다.
///
/// "북마크 추가" 처럼 *현재 화면에 머무르며* sheet 를 띄우고 싶은 진입점에서 사용.
/// 반대로 "내가 분석하기" 처럼 홈 탭으로 이동 후 sheet 를 띄우고 싶을 때는
/// 기존 `showAddRecipeSheet` 를 그대로 쓴다.
Future<void> showAddRecipeModal(
  BuildContext context, {
  String? initialUrl,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => AddRecipeScreen(
      initialUrl: initialUrl,
      bottomOffset: AddRecipeScreen.bottomNavOffsetFor(context),
    ),
  );
}
