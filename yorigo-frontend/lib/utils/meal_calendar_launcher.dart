import 'package:flutter/material.dart';

import '../screens/meal_calendar_screen.dart';

/// 식단 캘린더 화면으로 이동한다.
///
/// [onStartCooking] / [onCookingComplete] 가 없으면 캘린더 내부 standalone handler가
/// 슬롯 단위 started/completed marking 을 수행한다.
void openMealCalendar(
  BuildContext context, {
  int initialTabIndex = 0,
  ValueChanged<Map<String, dynamic>>? onStartCooking,
  void Function(
    BuildContext context,
    Map<String, dynamic> recipe,
    Map<String, dynamic>? fridgeData,
    Brightness brightness,
  )?
  onCookingComplete,
  ValueChanged<Map<String, dynamic>>? onOpenRecipeDetail,
}) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MealCalendarScreen(
        initialTabIndex: initialTabIndex,
        onStartCooking: onStartCooking,
        onCookingComplete: onCookingComplete,
        onOpenRecipeDetail: onOpenRecipeDetail,
      ),
    ),
  );
}
