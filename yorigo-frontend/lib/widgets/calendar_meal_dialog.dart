import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import '../theme/app_colors.dart';
import '../services/analytics_service.dart';
import '../services/meal_plan_service.dart';
import '../services/user_service.dart';
import 'step_progress_badge.dart';
import 'app_toast.dart';

void _showLatestSnackBar(BuildContext context, SnackBar snackBar) {
  // 하단 스낵바 대신 상단 토스트(헤더 아래)로 표시.
  showAppSnackBar(context, snackBar);
}

void _trackMealPlanIngredientsAddedToCart({
  required String recipeId,
  required List<dynamic> selectedIngredients,
}) {
  unawaited(
    AnalyticsService().trackRecipeCartIngredientsAdded(
      recipeId: recipeId,
      ingredientNames: [
        for (final row in selectedIngredients)
          if (row is Map) row['item']?.toString() ?? '',
      ],
      source: 'meal_plan',
    ),
  );
}

class CalendarMealDialog extends StatefulWidget {
  final String recipeId;
  final String recipeTitle;
  final Set<String>? selectedIngredients;
  final double? portionCount;
  final dynamic parseResponse; // ParseResponse from recipe_detail_screen
  final VoidCallback?
  onBackToStep1; // Callback to go back to ingredient selection

  const CalendarMealDialog({
    super.key,
    required this.recipeId,
    required this.recipeTitle,
    this.selectedIngredients,
    this.portionCount,
    this.parseResponse,
    this.onBackToStep1,
  });

  @override
  State<CalendarMealDialog> createState() => _CalendarMealDialogState();
}

class _CalendarMealDialogState extends State<CalendarMealDialog> {
  final MealPlanService _mealPlanService = MealPlanService();
  final UserService _userService = UserService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Set<DateTime> _selectedDates = {}; // Multiple dates can be selected
  Map<String, Map<String, dynamic>> _mealPlans = {};
  // Map of date to set of meal times (breakfast, lunch, dinner)
  final Map<DateTime, Set<String>> _selectedMealTimes = {};
  StreamSubscription<Map<String, Map<String, dynamic>>>? _mealPlansSubscription;
  StreamSubscription<User?>? _authStateSubscription;

  @override
  void initState() {
    super.initState();
    // Initialize with today's date selected
    _selectedDates.add(_getToday());
    _loadMealPlans();
    _listenToAuthState();
  }

  void _listenToAuthState() {
    _authStateSubscription = _auth.authStateChanges().listen((user) {
      if (user == null && mounted) {
        // 로그아웃 감지 시 상태 초기화 및 다이얼로그 닫기
        _clearState();
        Navigator.of(context).pop();
      }
    });
  }

  void _clearState() {
    setState(() {
      _mealPlans.clear();
      _selectedDates.clear();
      _selectedMealTimes.clear();
    });
  }

  @override
  void dispose() {
    _mealPlansSubscription?.cancel();
    _authStateSubscription?.cancel();
    super.dispose();
  }

  DateTime _getToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Today plus the next 5 days (6 days total).
  List<DateTime> _getWeekDates() {
    final today = _getToday();
    final List<DateTime> weekDates = [];
    for (int i = 0; i < 6; i++) {
      weekDates.add(today.add(Duration(days: i)));
    }
    return weekDates;
  }

  String _getKoreanDayOfWeek(DateTime date) {
    final weekday = date.weekday;
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[weekday - 1];
  }

  String _getKoreanMonthName(DateTime date) {
    return '${date.month}월';
  }

  List<String> _getMealIndicators(DateTime date) {
    final dateKey = _getDateKey(date);
    final mealPlan = _mealPlans[dateKey];
    if (mealPlan == null) return [];

    final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};
    final List<String> indicators = [];

    if (meals['breakfast'] != null && (meals['breakfast'] as List).isNotEmpty) {
      indicators.add('breakfast');
    }
    if (meals['lunch'] != null && (meals['lunch'] as List).isNotEmpty) {
      indicators.add('lunch');
    }
    if (meals['dinner'] != null && (meals['dinner'] as List).isNotEmpty) {
      indicators.add('dinner');
    }

    return indicators;
  }

  String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Color _getMealColor(String meal) {
    switch (meal) {
      case 'breakfast':
        return AppColors.breakfast;
      case 'lunch':
        return AppColors.lunch;
      case 'dinner':
        return AppColors.dinner;
      default:
        return AppColors.textTertiary;
    }
  }

  Future<void> _loadMealPlans() async {
    final weekDates = _getWeekDates();
    final startDate = weekDates.first;
    final endDate = weekDates.last;

    // 기존 구독 해제
    await _mealPlansSubscription?.cancel();

    _mealPlansSubscription = _mealPlanService
        .getMealPlansForDateRange(startDate, endDate)
        .listen((mealPlans) {
      if (mounted) {
        setState(() {
          _mealPlans = mealPlans;
        });
      }
    });
  }

  List<Map<String, dynamic>> _getMealItems(DateTime date) {
    final dateKey = _getDateKey(date);
    final mealPlan = _mealPlans[dateKey];
    if (mealPlan == null) return [];

    final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};
    final recipeTitles =
        mealPlan['recipeTitles'] as Map<String, dynamic>? ?? {};
    final List<Map<String, dynamic>> mealItems = [];

    // Breakfast meals
    if (meals['breakfast'] != null) {
      final breakfastRecipes = meals['breakfast'] as List? ?? [];
      for (var recipeId in breakfastRecipes) {
        mealItems.add({
          'mealTime': 'breakfast',
          'recipeId': recipeId.toString(),
          'recipeTitle': recipeTitles[recipeId]?.toString() ?? '레시피',
        });
      }
    }

    // Lunch meals
    if (meals['lunch'] != null) {
      final lunchRecipes = meals['lunch'] as List? ?? [];
      for (var recipeId in lunchRecipes) {
        mealItems.add({
          'mealTime': 'lunch',
          'recipeId': recipeId.toString(),
          'recipeTitle': recipeTitles[recipeId]?.toString() ?? '레시피',
        });
      }
    }

    // Dinner meals
    if (meals['dinner'] != null) {
      final dinnerRecipes = meals['dinner'] as List? ?? [];
      for (var recipeId in dinnerRecipes) {
        mealItems.add({
          'mealTime': 'dinner',
          'recipeId': recipeId.toString(),
          'recipeTitle': recipeTitles[recipeId]?.toString() ?? '레시피',
        });
      }
    }

    return mealItems;
  }

  Widget _buildMealRow(
    String mealType,
    String label,
    List<Map<String, dynamic>> items,
    BuildContext context,
    bool isSelectable,
    DateTime?
    dateForRow, // The date this row represents (null if not selectable)
  ) {
    final brightness = Theme.of(context).brightness;
    Color barColor;
    switch (mealType) {
      case 'breakfast':
        barColor = AppColors.breakfast;
        break;
      case 'lunch':
        barColor = AppColors.lunch;
        break;
      case 'dinner':
        barColor = AppColors.dinner;
        break;
      default:
        barColor = AppColors.getTextTertiary(brightness);
    }

    // Check if this meal is selected for the given date
    final isSelected =
        dateForRow != null &&
        _selectedMealTimes[dateForRow]?.contains(mealType) == true;

    return SizedBox(
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Colored vertical bar
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          // Meal label
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.getTextPrimary(brightness),
            ),
          ),
          const SizedBox(width: 8),
          // Meal items as tags
          Expanded(
            child: items.isEmpty
                ? const SizedBox.shrink()
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.start,
                    children: items.map((item) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.getBackground(brightness),
                          border: Border.all(
                            color: AppColors.getBorder(brightness),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          item['recipeTitle'] as String,
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.getTextPrimary(brightness),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(width: 8),
          // Add/Select button (circular + or check)
          isSelectable && dateForRow != null
              ? GestureDetector(
                  onTap: () {
                    setState(() {
                      // Toggle selection for this date and meal time
                      _selectedMealTimes[dateForRow] ??= {};
                      if (isSelected) {
                        _selectedMealTimes[dateForRow]!.remove(mealType);
                        // Remove date from map if no meals selected
                        if (_selectedMealTimes[dateForRow]!.isEmpty) {
                          _selectedMealTimes.remove(dateForRow);
                        }
                      } else {
                        _selectedMealTimes[dateForRow]!.add(mealType);
                      }
                    });
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.transparent
                          : const Color(0xFFF5F1E8), // Light beige
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? Colors.transparent
                            : AppColors.getBorder(brightness),
                        width: 1,
                      ),
                    ),
                    child: Icon(
                      isSelected ? Icons.check : Icons.add,
                      size: 20,
                      color: isSelected
                          ? AppColors
                                .primary // Orange checkmark
                          : AppColors.getTextPrimary(brightness),
                    ),
                  ),
                )
              : GestureDetector(
                  onTap: () async {
                    if (dateForRow != null) {
                      try {
                        await _mealPlanService.addMealToDate(
                          date: dateForRow,
                          mealTime: mealType,
                          recipeId: widget.recipeId,
                          recipeTitle: widget.recipeTitle,
                        );
                        // Reload meal plans to update the UI
                        _loadMealPlans();
                        if (mounted) {
                          _showLatestSnackBar(
                            context,
                            const SnackBar(
                              content: Text('메뉴가 추가되었습니다'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          _showLatestSnackBar(
                            context,
                            SnackBar(
                              content: Text('오류가 발생했습니다: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    }
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F1E8), // Light beige
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.getBorder(brightness),
                        width: 1,
                      ),
                    ),
                    child: Icon(
                      Icons.add,
                      size: 20,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  String _formatDateForDisplay(DateTime date) {
    final month = date.month;
    final day = date.day;
    final dayOfWeek = _getKoreanDayOfWeek(date);
    return '$month월 $day일 ($dayOfWeek)';
  }

  @override
  Widget build(BuildContext context) {
    final today = _getToday();
    final monthName = _getKoreanMonthName(today);
    final weekDates = _getWeekDates();

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step indicator (only show if this is Step 2)
            if (widget.selectedIngredients != null) ...[
              const StepProgressBadge(currentStep: 2, totalSteps: 2),
              const SizedBox(height: 16),
            ],
            // Title
            Text(
              widget.selectedIngredients != null ? '날짜와 식사 선택' : '날짜 선택',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.getTextPrimary(Theme.of(context).brightness),
              ),
            ),
            const SizedBox(height: 16),
            // Calendar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
              decoration: const BoxDecoration(color: Colors.white),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Month name
                  Text(
                    monthName,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.getTextPrimary(
                        Theme.of(context).brightness,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Calendar dates
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Row(
                            children: weekDates.map((date) {
                              // Normalize date to remove time component for comparison
                              final normalizedDate = DateTime(
                                date.year,
                                date.month,
                                date.day,
                              );
                              final isSelected = _selectedDates.any(
                                (selectedDate) =>
                                    selectedDate.year == normalizedDate.year &&
                                    selectedDate.month ==
                                        normalizedDate.month &&
                                    selectedDate.day == normalizedDate.day,
                              );
                              final mealIndicators = _getMealIndicators(date);

                              return Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      // Always use single selection mode
                                      // Clear all previous selections first
                                      _selectedDates.clear();
                                      _selectedMealTimes.clear();
                                      
                                      // Select only the new date (or deselect if already selected)
                                      if (!isSelected) {
                                        _selectedDates.add(normalizedDate);
                                      }
                                      // If already selected, clearing above will deselect it
                                    });
                                  },
                                  child: Column(
                                    children: [
                                      Text(
                                        _getKoreanDayOfWeek(date),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isSelected
                                              ? AppColors.primary
                                              : AppColors.getTextSecondary(
                                                  Theme.of(context).brightness,
                                                ),
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? AppColors.primary
                                              : Colors.transparent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${date.day}',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: isSelected
                                                  ? Colors.white
                                                  : AppColors.getTextPrimary(
                                                      Theme.of(
                                                        context,
                                                      ).brightness,
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: mealIndicators.take(3).map((
                                          meal,
                                        ) {
                                          return Container(
                                            width: 6,
                                            height: 6,
                                            margin: const EdgeInsets.symmetric(
                                              horizontal: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: _getMealColor(meal),
                                              shape: BoxShape.circle,
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          // Orange lines for selected dates
                          ...weekDates
                              .asMap()
                              .entries
                              .where((entry) {
                                final date = entry.value;
                                final normalizedDate = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                );
                                return _selectedDates.any(
                                  (selectedDate) =>
                                      selectedDate.year ==
                                          normalizedDate.year &&
                                      selectedDate.month ==
                                          normalizedDate.month &&
                                      selectedDate.day == normalizedDate.day,
                                );
                              })
                              .map((entry) {
                                return Positioned(
                                  left: entry.key * (constraints.maxWidth / 7),
                                  width: constraints.maxWidth / 7,
                                  bottom: -16,
                                  child: Container(
                                    height: 2,
                                    color: AppColors.primary,
                                  ),
                                );
                              }),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Meal rows section - show for all selected dates
            if (_selectedDates.isNotEmpty &&
                widget.selectedIngredients != null) ...[
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: () {
                      final sortedDates = _selectedDates.toList()
                        ..sort((a, b) => a.compareTo(b));
                      return sortedDates.map((date) {
                        // Get meal items for this date
                        final mealItems = _getMealItems(date);
                        final breakfastItems = mealItems
                            .where((item) => item['mealTime'] == 'breakfast')
                            .cast<Map<String, dynamic>>()
                            .toList();
                        final lunchItems = mealItems
                            .where((item) => item['mealTime'] == 'lunch')
                            .cast<Map<String, dynamic>>()
                            .toList();
                        final dinnerItems = mealItems
                            .where((item) => item['mealTime'] == 'dinner')
                            .cast<Map<String, dynamic>>()
                            .toList();

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Date header
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8, top: 8),
                              child: Text(
                                _formatDateForDisplay(date),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.getTextPrimary(
                                    Theme.of(context).brightness,
                                  ),
                                ),
                              ),
                            ),
                            // Meal rows for this date
                            _buildMealRow(
                              'breakfast',
                              '아침',
                              breakfastItems,
                              context,
                              true,
                              date,
                            ),
                            const SizedBox(height: 12),
                            _buildMealRow(
                              'lunch',
                              '점심',
                              lunchItems,
                              context,
                              true,
                              date,
                            ),
                            const SizedBox(height: 12),
                            _buildMealRow(
                              'dinner',
                              '저녁',
                              dinnerItems,
                              context,
                              true,
                              date,
                            ),
                            const SizedBox(height: 20),
                          ],
                        );
                      }).toList();
                    }(),
                  ),
                ),
              ),
            ] else if (_selectedDates.isNotEmpty &&
                widget.selectedIngredients == null) ...[
              // Show meal rows for first selected date when not in selectable mode
              Builder(
                builder: (context) {
                  final firstDate = _selectedDates.first;
                  final mealItems = _getMealItems(firstDate);
                  final breakfastItems = mealItems
                      .where((item) => item['mealTime'] == 'breakfast')
                      .cast<Map<String, dynamic>>()
                      .toList();
                  final lunchItems = mealItems
                      .where((item) => item['mealTime'] == 'lunch')
                      .cast<Map<String, dynamic>>()
                      .toList();
                  final dinnerItems = mealItems
                      .where((item) => item['mealTime'] == 'dinner')
                      .cast<Map<String, dynamic>>()
                      .toList();

                  return Column(
                    children: [
                      _buildMealRow(
                        'breakfast',
                        '아침',
                        breakfastItems,
                        context,
                        false,
                        firstDate,
                      ),
                      const SizedBox(height: 12),
                      _buildMealRow(
                        'lunch',
                        '점심',
                        lunchItems,
                        context,
                        false,
                        firstDate,
                      ),
                      const SizedBox(height: 12),
                      _buildMealRow(
                        'dinner',
                        '저녁',
                        dinnerItems,
                        context,
                        false,
                        firstDate,
                      ),
                      const SizedBox(height: 20),
                    ],
                  );
                },
              ),
            ],
            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Back button (only show in Step 2)
                if (widget.selectedIngredients != null &&
                    widget.onBackToStep1 != null)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onBackToStep1!();
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_back,
                          size: 18,
                          color: AppColors.getTextPrimary(
                            Theme.of(context).brightness,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '이전',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(
                              Theme.of(context).brightness,
                            ),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox.shrink(),
                // Right side buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        '취소',
                        style: TextStyle(
                          color: AppColors.getTextSecondary(
                            Theme.of(context).brightness,
                          ),
                        ),
                      ),
                    ),
                    if (widget.selectedIngredients != null &&
                        _selectedDates.isNotEmpty &&
                        _selectedMealTimes.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () async {
                          await _handleCompleteStep2(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          '완료',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCompleteStep2(BuildContext context) async {
    if (_selectedDates.isEmpty || _selectedMealTimes.isEmpty) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        _showLatestSnackBar(
          context,
          const SnackBar(
            content: Text('로그인이 필요합니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      // Count total number of meals selected (used for cart and message)
      int totalMealCount = 0;
      for (final mealTimes in _selectedMealTimes.values) {
        totalMealCount += mealTimes.length;
      }

      // Step 1: Add to meal plan for all selected date/meal combinations
      for (final date in _selectedMealTimes.keys) {
        final mealTimes = _selectedMealTimes[date]!;
        for (final mealTime in mealTimes) {
          await _mealPlanService.addMealToDate(
            date: date,
            mealTime: mealTime,
            recipeId: widget.recipeId,
            recipeTitle: widget.recipeTitle,
          );
        }
      }

      // Step 2: Add selected ingredients to cart
      if (widget.selectedIngredients != null &&
          widget.parseResponse != null &&
          widget.portionCount != null) {
        // Calculate total servings: portionCount × number of meals
        final totalServings = widget.portionCount! * totalMealCount;

        // Access recipe from parseResponse (dynamic type)
        final parseResponse = widget.parseResponse as dynamic;
        final recipe = parseResponse.recipe;
        final baseServings = recipe.servings ?? 2;
        // Scale factor based on total servings (portionCount × number of meals)
        final scaleFactor = totalServings / baseServings;

        // Get selected ingredients with scaled quantities
        final selectedIngredients = recipe.ingredients
            .asMap()
            .entries
            .where(
              (entry) =>
                  widget.selectedIngredients!.contains(entry.key.toString()),
            )
            .map((entry) {
              final ingredient = entry.value;
              final scaledQty = ingredient.qty != null
                  ? ingredient.qty! * scaleFactor
                  : null;

              return {
                'item': ingredient.item,
                'qty': scaledQty,
                'unit': ingredient.unit,
                'notes': ingredient.notes,
                'category': ingredient.category, // Store category in Firestore
              };
            })
            .toList();

        // Earliest cook day among selected slots (cart + shopping screen remember past dates).
        DateTime? earliestDay;
        for (final d in _selectedMealTimes.keys) {
          final day = DateTime(d.year, d.month, d.day);
          if (earliestDay == null || day.isBefore(earliestDay)) earliestDay = day;
        }

        // Create cart item with total servings
        final cartItem = <String, dynamic>{
          'recipeId': widget.recipeId,
          'recipeName': recipe.name ?? '레시피',
          'servings':
              totalServings, // Total servings = portionCount × number of meals
          'ingredients': selectedIngredients,
          'addedAt': DateTime.now().millisecondsSinceEpoch,
          if (earliestDay != null) 'scheduledDate': earliestDay.millisecondsSinceEpoch,
        };

        // Add to cart
        await _userService.addToCart(
          user.uid,
          cartItem,
          parseResponseForThumbnail: parseResponse,
        );
        _trackMealPlanIngredientsAddedToCart(
          recipeId: widget.recipeId,
          selectedIngredients: selectedIngredients,
        );
      }

      // Close dialog
      Navigator.of(context).pop();

      // Show success message
      if (mounted) {
        final message = totalMealCount > 1
            ? '$totalMealCount개의 식사가 계획에 추가되고, 재료가 장바구니에 추가되었습니다'
            : '식사 계획에 추가되고 장바구니에 추가되었습니다';

        _showLatestSnackBar(
          context,
          SnackBar(content: Text(message), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        _showLatestSnackBar(
          context,
          SnackBar(
            content: Text('오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Orange for sheet (match home screen accent)
const Color _calendarSheetOrange = Color(0xFFFF6B35);
const Color _calendarSheetOrangeLight = Color(0xFFFFF5ED);

/// Orange shades for 아침/점심/저녁 (match home screen oval bars and dots)
Color _calendarMealBarColor(String mealType) {
  switch (mealType) {
    case 'breakfast':
      return _calendarSheetOrange;
    case 'lunch':
      return Color.lerp(_calendarSheetOrange, _calendarSheetOrangeLight, 0.35)!;
    case 'dinner':
      return Color.lerp(_calendarSheetOrange, _calendarSheetOrangeLight, 0.6)!;
    default:
      return _calendarSheetOrange;
  }
}

/// Bottom sheet for step 2: date first, then meal type. Expands after date is selected.
class CalendarMealSheet extends StatefulWidget {
  final String recipeId;
  final String recipeTitle;
  final Set<String>? selectedIngredients;
  final double? portionCount;
  final dynamic parseResponse;
  final VoidCallback? onBackToStep1;
  /// Called after sheet is closed when user confirmed add (담기). Use to e.g. pop recipe detail and go home.
  final VoidCallback? onAddedToCart;

  const CalendarMealSheet({
    super.key,
    required this.recipeId,
    required this.recipeTitle,
    this.selectedIngredients,
    this.portionCount,
    this.parseResponse,
    this.onBackToStep1,
    this.onAddedToCart,
  });

  @override
  State<CalendarMealSheet> createState() => _CalendarMealSheetState();
}

class _CalendarMealSheetState extends State<CalendarMealSheet> with SingleTickerProviderStateMixin {
  final MealPlanService _mealPlanService = MealPlanService();
  final UserService _userService = UserService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  DateTime? _selectedDate;
  String? _selectedMealTime; // 'breakfast' | 'lunch' | 'dinner'
  Map<String, Map<String, dynamic>> _mealPlans = {};
  bool _showSuccessOverlay = false;
  AnimationController? _successBounceController;
  StreamSubscription<Map<String, Map<String, dynamic>>>? _mealPlansSubscription;
  StreamSubscription<User?>? _authStateSubscription;

  @override
  void dispose() {
    _successBounceController?.dispose();
    _mealPlansSubscription?.cancel();
    _authStateSubscription?.cancel();
    super.dispose();
  }

  void _startSuccessBounce() {
    _successBounceController?.dispose();
    _successBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  DateTime _getToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Today plus the next 20 days (21 days total). Horizontally scrollable in the sheet.
  List<DateTime> _getWeekDates() {
    final today = _getToday();
    final List<DateTime> weekDates = [];
    for (int i = 0; i < 21; i++) {
      weekDates.add(today.add(Duration(days: i)));
    }
    return weekDates;
  }

  String _getKoreanDayOfWeek(DateTime date) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[date.weekday - 1];
  }

  String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  List<String> _getMealIndicators(DateTime date) {
    final dateKey = _getDateKey(date);
    final mealPlan = _mealPlans[dateKey];
    if (mealPlan == null) return [];

    final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};
    final List<String> indicators = [];

    if (meals['breakfast'] != null && (meals['breakfast'] as List).isNotEmpty) {
      indicators.add('breakfast');
    }
    if (meals['lunch'] != null && (meals['lunch'] as List).isNotEmpty) {
      indicators.add('lunch');
    }
    if (meals['dinner'] != null && (meals['dinner'] as List).isNotEmpty) {
      indicators.add('dinner');
    }
    return indicators;
  }

  Widget _buildSheetDateChip(
    DateTime date, {
    required DateTime today,
    required Color textPrimary,
    required Color textTertiary,
  }) {
    final normalized = DateTime(date.year, date.month, date.day);
    final isToday = normalized.year == today.year &&
        normalized.month == today.month &&
        normalized.day == today.day;
    final isSelected = _selectedDate != null &&
        _selectedDate!.year == normalized.year &&
        _selectedDate!.month == normalized.month &&
        _selectedDate!.day == normalized.day;
    final indicators = _getMealIndicators(date);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedDate = null;
              _selectedMealTime = null;
            } else {
              _selectedDate = normalized;
              _selectedMealTime = null;
            }
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  isToday ? '오늘' : _getKoreanDayOfWeek(date),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? textPrimary : textTertiary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isSelected ? _calendarSheetOrange : Colors.transparent,
                  shape: BoxShape.circle,
                  border: isSelected
                      ? null
                      : Border.all(
                          color: const Color(0xFFE8E8E8),
                          width: 1,
                        ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? Colors.white : textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 6,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  // Same orange dots whether selected or not — they sit on the sheet (white),
                  // not on the orange circle, so white70 was invisible when selected.
                  children: indicators.take(3).map((meal) {
                    return Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: _calendarSheetOrange.withOpacity(isSelected ? 0.85 : 0.6),
                        shape: BoxShape.circle,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadMealPlans();
    _listenToAuthState();
  }

  void _listenToAuthState() {
    _authStateSubscription = _auth.authStateChanges().listen((user) {
      if (user == null && mounted) {
        // 로그아웃 감지 시 상태 초기화 및 시트 닫기
        _clearState();
        Navigator.of(context).pop();
      }
    });
  }

  void _clearState() {
    setState(() {
      _mealPlans.clear();
      _selectedDate = null;
      _selectedMealTime = null;
    });
  }

  Future<void> _loadMealPlans() async {
    final weekDates = _getWeekDates();
    final startDate = weekDates.first;
    final endDate = weekDates.last;

    // 기존 구독 해제
    await _mealPlansSubscription?.cancel();

    _mealPlansSubscription = _mealPlanService
        .getMealPlansForDateRange(startDate, endDate)
        .listen((mealPlans) {
      if (mounted) {
        setState(() => _mealPlans = mealPlans);
      }
    });
  }

  String _mealLabel(String meal) {
    switch (meal) {
      case 'breakfast':
        return '아침';
      case 'lunch':
        return '점심';
      case 'dinner':
        return '저녁';
      default:
        return meal;
    }
  }

  /// Existing recipes already in the meal plan for this date + meal type.
  List<Map<String, dynamic>> _getMealItemsForSlot(DateTime date, String mealType) {
    final dateKey = _getDateKey(date);
    final mealPlan = _mealPlans[dateKey];
    if (mealPlan == null) return [];

    final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};
    final recipeTitles = mealPlan['recipeTitles'] as Map<String, dynamic>? ?? {};
    final recipeIds = meals[mealType] as List? ?? [];
    if (recipeIds.isEmpty) return [];

    return recipeIds.asMap().entries.map((entry) {
      final recipeId = entry.value.toString();
      return {
        'recipeId': recipeId,
        'recipeTitle': recipeTitles[recipeId]?.toString() ?? '레시피',
      };
    }).toList();
  }

  Future<void> _addToCartOnly() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        _showLatestSnackBar(
          context,
          const SnackBar(
            content: Text('로그인이 필요합니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (widget.selectedIngredients == null ||
        widget.parseResponse == null ||
        widget.portionCount == null) {
      return;
    }

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _showSuccessOverlay = true);
    _startSuccessBounce();
    if (mounted) setState(() {});

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      navigator.pop();
      widget.onAddedToCart?.call();
    });

    Future(() async {
      try {
        final parseResponse = widget.parseResponse as dynamic;
        final recipe = parseResponse.recipe;
        final totalServings = widget.portionCount!;
        final baseServings = recipe.servings ?? 2;
        final scaleFactor = totalServings / baseServings;

        final selectedIngredients = recipe.ingredients
            .asMap()
            .entries
            .where((entry) =>
                widget.selectedIngredients!.contains(entry.key.toString()))
            .map((entry) {
              final ingredient = entry.value;
              final scaledQty = ingredient.qty != null
                  ? ingredient.qty! * scaleFactor
                  : null;
              return {
                'item': ingredient.item,
                'qty': scaledQty,
                'unit': ingredient.unit,
                'notes': ingredient.notes,
                'category': ingredient.category,
              };
            })
            .toList();

        final cartItem = {
          'recipeId': widget.recipeId,
          'recipeName': recipe.name ?? '레시피',
          'servings': totalServings,
          'ingredients': selectedIngredients,
          'addedAt': DateTime.now().millisecondsSinceEpoch,
          'scheduledDate': null,
        };

        await _userService.addToCart(
          user.uid,
          cartItem,
          parseResponseForThumbnail: parseResponse,
        );
        _trackMealPlanIngredientsAddedToCart(
          recipeId: widget.recipeId,
          selectedIngredients: selectedIngredients,
        );
        messenger
          ..clearSnackBars()
          ..showSnackBar(
          const SnackBar(
            content: Text('장바구니에 추가되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
          SnackBar(
            content: Text('오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  void _optimisticallyAddRecipeToSlot(DateTime date, String mealType) {
    final dateKey = _getDateKey(date);
    _mealPlans[dateKey] ??= {'meals': <String, dynamic>{}, 'recipeTitles': <String, dynamic>{}};
    final plan = _mealPlans[dateKey]!;
    final meals = plan['meals'] as Map<String, dynamic>;
    final recipeTitles = plan['recipeTitles'] as Map<String, dynamic>;
    meals[mealType] ??= <String>[];
    final list = meals[mealType] as List;
    if (!list.contains(widget.recipeId)) list.add(widget.recipeId);
    recipeTitles[widget.recipeId] = widget.recipeTitle;
  }

  Future<void> _handleConfirmWithSchedule() async {
    if (_selectedDate == null || _selectedMealTime == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        _showLatestSnackBar(
          context,
          const SnackBar(
            content: Text('로그인이 필요합니다'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (widget.selectedIngredients == null ||
        widget.parseResponse == null ||
        widget.portionCount == null) {
      return;
    }

    final date = _selectedDate!;
    final mealTime = _selectedMealTime!;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _optimisticallyAddRecipeToSlot(date, mealTime);
      _showSuccessOverlay = true;
    });
    _startSuccessBounce();
    if (mounted) setState(() {});

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      navigator.pop();
      widget.onAddedToCart?.call();
    });

    Future(() async {
      try {
        await _mealPlanService.addMealToDate(
          date: date,
          mealTime: mealTime,
          recipeId: widget.recipeId,
          recipeTitle: widget.recipeTitle,
        );

        final parseResponse = widget.parseResponse as dynamic;
        final recipe = parseResponse.recipe;
        final totalServings = widget.portionCount!;
        final baseServings = recipe.servings ?? 2;
        final scaleFactor = totalServings / baseServings;

        final selectedIngredients = recipe.ingredients
            .asMap()
            .entries
            .where((entry) =>
                widget.selectedIngredients!.contains(entry.key.toString()))
            .map((entry) {
              final ingredient = entry.value;
              final scaledQty = ingredient.qty != null
                  ? ingredient.qty! * scaleFactor
                  : null;
              return {
                'item': ingredient.item,
                'qty': scaledQty,
                'unit': ingredient.unit,
                'notes': ingredient.notes,
                'category': ingredient.category,
              };
            })
            .toList();

        final scheduledDay = DateTime(date.year, date.month, date.day);
        final cartItem = <String, dynamic>{
          'recipeId': widget.recipeId,
          'recipeName': recipe.name ?? '레시피',
          'servings': totalServings,
          'ingredients': selectedIngredients,
          'addedAt': DateTime.now().millisecondsSinceEpoch,
          'scheduledDate': scheduledDay.millisecondsSinceEpoch,
        };

        await _userService.addToCart(
          user.uid,
          cartItem,
          parseResponseForThumbnail: parseResponse,
        );
        _trackMealPlanIngredientsAddedToCart(
          recipeId: widget.recipeId,
          selectedIngredients: selectedIngredients,
        );
        messenger
          ..clearSnackBars()
          ..showSnackBar(
          const SnackBar(
            content: Text('식사 계획에 추가되고 장바구니에 추가되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
          SnackBar(
            content: Text('오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textSecondary = AppColors.getTextSecondary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);
    final weekDates = _getWeekDates();
    final today = _getToday();
    final hasDateSelected = _selectedDate != null;
    final hasMealSelected = _selectedMealTime != null;

    final double screenHeight = MediaQuery.of(context).size.height;
    // Taller when date + meal rows are shown so 아침·점심·저녁 stay above the bottom actions (no overlap).
    // Step 2 header (badge + title stacked) is taller than the bare title, so
    // the no-date sheet needs extra room to avoid clipping the week row.
    final double collapsedHeight =
        widget.selectedIngredients != null ? 364 : 300;
    final double mealSelectedHeight =
        (screenHeight * 0.92 - 56).clamp(640.0, screenHeight);
    // Before a meal is picked the orange CTA (52) + its 10px gap are absent, so
    // trim that exact amount to keep "일정 없이" naturally tucked under the cards
    // instead of being pushed to the bottom with a big empty gap.
    final double sheetHeight = !hasDateSelected
        ? collapsedHeight
        : hasMealSelected
            ? mealSelectedHeight
            : mealSelectedHeight - 62;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      height: sheetHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 36,
                  height: 3.5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD0D0D0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row: navigation controls only.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onBackToStep1?.call();
                          },
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF0F0F0),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.arrow_back,
                                size: 20, color: Color(0xFF555555)),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF0F0F0),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.close,
                                size: 20, color: Color(0xFF555555)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Step badge + title, left-aligned beneath the back button.
                    if (widget.selectedIngredients != null) ...[
                      const StepProgressBadge(currentStep: 2, totalSteps: 2),
                      const SizedBox(height: 10),
                    ],
                    const Text(
                      '언제 요리할까요?',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF222222),
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              physics: hasDateSelected
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                hasDateSelected ? 20 : 0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _calendarSheetOrange,
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          '1',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '날짜를 선택하세요',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: SizedBox(
                      height: 92,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const double spacing = 4;
                          const int visibleCount = 6;
                          final double chipWidth =
                              (constraints.maxWidth - spacing * (visibleCount - 1)) /
                                  visibleCount;
                          return ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: weekDates.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: spacing),
                            itemBuilder: (context, index) => SizedBox(
                              width: chipWidth,
                              child: _buildSheetDateChip(
                                weekDates[index],
                                today: today,
                                textPrimary: textPrimary,
                                textTertiary: textTertiary,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (hasDateSelected) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _calendarSheetOrange,
                            boxShadow: [
                              BoxShadow(
                                color: _calendarSheetOrange.withOpacity(0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            '2',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '끼니를 선택하세요',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: _buildMealRow(_selectedDate!, 'breakfast', '아침', textPrimary, textSecondary),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: _buildMealRow(_selectedDate!, 'lunch', '점심', textPrimary, textSecondary),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: _buildMealRow(_selectedDate!, 'dinner', '저녁', textPrimary, textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDateSelected && hasMealSelected)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _handleConfirmWithSchedule,
                          borderRadius: BorderRadius.circular(14),
                          child: Ink(
                            decoration: BoxDecoration(
                              color: _calendarSheetOrange,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: _calendarSheetOrange.withOpacity(0.35),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Container(
                              alignment: Alignment.center,
                              child: Text(
                                '${_selectedDate!.month}/${_selectedDate!.day} ${_mealLabel(_selectedMealTime!)} · 장바구니에 담기',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (hasDateSelected && hasMealSelected) const SizedBox(height: 10),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _addToCartOnly,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '일정 없이 장바구니만 담기',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF1A1A1A),
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
          ),
          if (_showSuccessOverlay) _buildSuccessOverlay(),
        ],
      ),
    );
  }

  /// Centered grey rounded card with green checkmark + "추가 완료!" (bouncy success feedback).
  Widget _buildSuccessOverlay() {
    const greenCheck = Color(0xFF22C55E);
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _showSuccessOverlay ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Material(
          color: Colors.black38,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_successBounceController != null)
                    AnimatedBuilder(
                      animation: _successBounceController!,
                      builder: (context, child) {
                        final bounce = Tween<double>(begin: 0, end: -10)
                            .chain(CurveTween(curve: Curves.easeInOut))
                            .evaluate(_successBounceController!);
                        return Transform.translate(
                          offset: Offset(0, bounce),
                          child: child,
                        );
                      },
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 48,
                        color: greenCheck,
                      ),
                    )
                  else
                    Icon(Icons.check_circle_rounded, size: 48, color: greenCheck),
                  const SizedBox(height: 12),
                  const Text(
                    '추가 완료!',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF333333),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// White rounded pill with the recipe name (no badge). `accent` marks the
  /// recipe being added now via orange border/shadow; others stay neutral.
  Widget _buildRecipeChip({
    required String title,
    required Color textColor,
    required bool accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent
              ? _calendarSheetOrange.withOpacity(0.40)
              : const Color(0xFFE4E6EA),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent
                ? _calendarSheetOrange.withOpacity(0.16)
                : Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: textColor,
          letterSpacing: -0.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildMealRow(
    DateTime date,
    String mealType,
    String label,
    Color textPrimary,
    Color textSecondary,
  ) {
    final isSelected = _selectedMealTime == mealType;
    final barColor = _calendarMealBarColor(mealType);
    final existingItems = _getMealItemsForSlot(date, mealType);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedMealTime = isSelected ? null : mealType;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          decoration: BoxDecoration(
            color: isSelected
                ? _calendarSheetOrangeLight.withOpacity(0.36)
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? _calendarSheetOrange.withOpacity(0.45)
                  : const Color(0xFFEAEAEA),
              width: isSelected ? 1.3 : 1,
            ),
            boxShadow: null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 3.5,
                height: 16,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 11),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: isSelected ? textPrimary : textSecondary,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 8,
                    alignment: WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                    for (final item in existingItems)
                      _buildRecipeChip(
                        title: item['recipeTitle'] as String? ?? '레시피',
                        textColor: textPrimary,
                        accent: false,
                      ),
                    if (isSelected && !existingItems.any((e) => e['recipeId'] == widget.recipeId))
                      _buildRecipeChip(
                        title: widget.recipeTitle,
                        textColor: textPrimary,
                        accent: true,
                      ),
                  ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
