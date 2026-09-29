import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/meal_plan_service.dart';
import '../utils/meal_plan_completion_utils.dart';
import '../services/recipe_service.dart';
import '../widgets/meal_plan_editor_dialog.dart';

const Color _calendarSurface = Colors.white;
const Color _calendarSelectedSurface = Color(0xFFF2F4F7);
const Color _calendarMuted = Color(0xFF8B95A1);
const Color _barBreakfast = Color(0xFFFFB347);
const Color _barLunch = Color(0xFFFF8C42);
const Color _barDinner = Color(0xFFFF6B00);
const Color _labelBreakfast = Color(0xFFE07000);
const Color _labelLunch = Color(0xFFC75A00);
const Color _labelDinner = Color(0xFFA83D00);

TextStyle _ts({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w500,
  double? height,
  double? letterSpacing,
  required Color color,
}) => TextStyle(
  fontFamily: 'Pretendard',
  fontSize: fontSize,
  fontWeight: fontWeight,
  height: height ?? 1.50,
  letterSpacing: letterSpacing,
  color: color,
);

class WeeklyPlanCard extends StatefulWidget {
  const WeeklyPlanCard({
    super.key,
    this.fridgeRecipes = const [],
    this.onStartCooking,
    this.onCookingComplete,
    this.onOpenRecipeDetail,
  });

  final List<Map<String, dynamic>> fridgeRecipes;
  final ValueChanged<Map<String, dynamic>>? onStartCooking;
  final ValueChanged<Map<String, dynamic>>? onCookingComplete;
  final ValueChanged<Map<String, dynamic>>? onOpenRecipeDetail;

  @override
  State<WeeklyPlanCard> createState() => _WeeklyPlanCardState();
}

class _WeeklyPlanCardState extends State<WeeklyPlanCard> {
  final MealPlanService _mealPlanService = MealPlanService();
  final RecipeService _recipeService = RecipeService.shared;
  final AuthService _authService = AuthService();

  final Map<String, Map<String, dynamic>> _mealPlans = {};
  DateTime? _selectedDate;
  bool _mealsSectionExpanded = true;
  StreamSubscription<Map<String, Map<String, dynamic>>>? _mealPlansSubscription;

  static const int _initialPage = 1000;
  late final PageController _weekPageController;

  @override
  void initState() {
    super.initState();
    _selectedDate = _getToday();
    _mealsSectionExpanded = false;
    _weekPageController = PageController(initialPage: _initialPage);
    _loadMealPlansForOffset(0);
    _authService.authStateChanges.listen((user) {
      if (mounted && user == null) {
        setState(() {
          _mealsSectionExpanded = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _mealPlansSubscription?.cancel();
    _weekPageController.dispose();
    super.dispose();
  }

  void _loadMealPlansForOffset(int offset) {
    _mealPlansSubscription?.cancel();
    final weekDates = _getWeekDates(offset: offset);
    final startDate = weekDates.first;
    final endDate = weekDates.last;
    _mealPlansSubscription = _mealPlanService
        .getMealPlansForDateRange(startDate, endDate)
        .listen((mealPlans) {
          if (!mounted) return;
          setState(() {
            for (final date in weekDates) {
              _mealPlans.remove(_getDateKey(date));
            }
            _mealPlans.addAll(mealPlans);
          });
        });
  }

  DateTime _getToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  List<DateTime> _getWeekDates({int offset = 0}) {
    final today = _getToday();
    final List<DateTime> weekDates = [];
    final safeOffset = offset.isFinite ? offset.toInt() : 0;
    for (int i = -1; i <= 5; i++) {
      final dayOffset = (i + safeOffset * 7).toInt();
      weekDates.add(today.add(Duration(days: dayOffset)));
    }
    return weekDates;
  }

  String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _getKoreanDayOfWeek(DateTime date) {
    const days = ['일', '월', '화', '수', '목', '금', '토'];
    return days[date.weekday % 7];
  }

  List<String> _getMealIndicators(DateTime date) {
    if (_authService.currentUser == null) return [];
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

  List<Map<String, dynamic>> _getMealItems(DateTime date, String mealType) {
    if (_authService.currentUser == null) return [];
    final dateKey = _getDateKey(date);
    final mealPlan = _mealPlans[dateKey];
    if (mealPlan == null) return [];
    final meals = mealPlan['meals'] as Map<String, dynamic>? ?? {};
    final recipeTitles =
        mealPlan['recipeTitles'] as Map<String, dynamic>? ?? {};
    final rawSlots = mealPlan['completedSlots'] as List? ?? [];
    List<String> completedSlots = rawSlots
        .map((e) => e.toString().trim())
        .toList();
    if (completedSlots.isEmpty) {
      final rawLegacy = mealPlan['completedRecipes'] as List? ?? [];
      final legacyIds = rawLegacy.map((e) => e.toString().trim()).toList();
      if (legacyIds.isNotEmpty) {
        final inferred = <String>[];
        for (final mt in ['breakfast', 'lunch', 'dinner']) {
          final list = (meals[mt] as List?) ?? [];
          for (var i = 0; i < list.length; i++) {
            final id = list[i].toString().trim();
            if (legacyIds.contains(id)) {
              inferred.add('${mt}_$i');
              legacyIds.remove(id);
            }
          }
        }
        completedSlots = inferred;
      }
    }
    final mealTimeMeals = meals[mealType] as List? ?? [];
    return mealTimeMeals.asMap().entries.map((entry) {
      final index = entry.key;
      final recipeId = entry.value.toString().trim();
      final status = resolveMealPlanSlotStatus(
        plan: mealPlan,
        mealTime: mealType,
        slotIndex: index,
      );
      return {
        'recipeId': recipeId,
        'title': recipeTitles[recipeId]?.toString() ?? '레시피',
        'completed': status.completed,
      };
    }).toList();
  }

  Map<String, dynamic>? _fridgeRecipeById(String recipeId) {
    if (recipeId.isEmpty) return null;
    for (final recipe in widget.fridgeRecipes) {
      final id = (recipe['recipeId'] ?? recipe['id'])?.toString().trim() ?? '';
      if (id == recipeId) return recipe;
    }
    return null;
  }

  static Color _dotColorForMeal(String meal) {
    switch (meal) {
      case 'breakfast':
        return _barBreakfast;
      case 'lunch':
        return _barLunch;
      case 'dinner':
        return _barDinner;
      default:
        return const Color(0x59FF6B00);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildWeekCard(context)],
    );
  }

  String _formatSelectedDateHeader() {
    final date = _selectedDate ?? _getToday();
    final today = _getToday();
    if (date.year == today.year &&
        date.month == today.month &&
        date.day == today.day) {
      return '오늘';
    }
    return '${date.month}월 ${date.day}일(${_getKoreanDayOfWeek(date)})';
  }

  Widget _buildWeekCard(BuildContext context) {
    final today = _getToday();

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(color: _calendarSurface),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _mealsSectionExpanded = !_mealsSectionExpanded;
                      });
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          _formatSelectedDateHeader(),
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                            color: Color(0xFF191F28),
                            letterSpacing: -0.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      showModalBottomSheet<void>(
                        context: context,
                        backgroundColor: Colors.transparent,
                        isScrollControlled: true,
                        builder: (context) => MealPlanEditorDialog(
                          onMealDeleted: () => setState(() {}),
                        ),
                      );
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F4F7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.edit_calendar_rounded,
                        size: 17,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: SizedBox(
                height: 82,
                child: PageView.builder(
                  controller: _weekPageController,
                  physics: const PageScrollPhysics(),
                  onPageChanged: (page) {
                    if (!page.isFinite) return;
                    final offset = page.toInt() - _initialPage;
                    _loadMealPlansForOffset(offset);
                  },
                  itemBuilder: (context, page) {
                    final pageOffset = page.isFinite
                        ? (page.toInt() - _initialPage)
                        : 0;
                    final pageWeekDates = _getWeekDates(offset: pageOffset);
                    return _buildWeekRow(pageWeekDates, today);
                  },
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              child: _mealsSectionExpanded
                  ? Column(
                      children: [
                        const SizedBox(height: 0),
                        _buildMealsContent(context),
                      ],
                    )
                  : const SizedBox(height: 0, width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekRow(List<DateTime> weekDates, DateTime today) {
    return Row(
      children: weekDates.asMap().entries.map((entry) {
        final date = entry.value;
        final isToday =
            date.year == today.year &&
            date.month == today.month &&
            date.day == today.day;
        final isSelected =
            _selectedDate != null &&
            date.year == _selectedDate!.year &&
            date.month == _selectedDate!.month &&
            date.day == _selectedDate!.day;
        final mealIndicators = _getMealIndicators(date);
        return Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _mealsSectionExpanded = !_mealsSectionExpanded;
                } else {
                  _selectedDate = date;
                  _mealsSectionExpanded = true;
                }
              });
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isToday ? '오늘' : _getKoreanDayOfWeek(date),
                  style: _ts(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 15 / 10,
                    letterSpacing: -0.1,
                    color: isSelected
                        ? const Color(0xFF191F28)
                        : _calendarMuted,
                  ),
                ),
                const SizedBox(height: 4),
                _CalendarDayCircle(
                  day: date.day,
                  isSelected: isSelected,
                  isExpanded: _mealsSectionExpanded,
                  isToday: isToday,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 5,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: mealIndicators
                        .take(5)
                        .map(
                          (meal) => Container(
                            width: 3.5,
                            height: 3.5,
                            margin: const EdgeInsets.symmetric(horizontal: 1.2),
                            decoration: BoxDecoration(
                              color: _dotColorForMeal(meal),
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                SizedBox(
                  height: 16,
                  child: isSelected
                      ? Align(
                          alignment: Alignment.bottomCenter,
                          child: _CalendarChevron(
                            isExpanded: _mealsSectionExpanded,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMealsContent(BuildContext context) {
    final date = _selectedDate ?? _getToday();
    const mealTypes = ['breakfast', 'lunch', 'dinner'];
    const labels = {'breakfast': '아침', 'lunch': '점심', 'dinner': '저녁'};
    const labelColors = {
      'breakfast': _labelBreakfast,
      'lunch': _labelLunch,
      'dinner': _labelDinner,
    };
    final mealItemsByType = {
      for (final mealType in mealTypes) mealType: _getMealItems(date, mealType),
    };
    final recipeIds = mealItemsByType.values
        .expand((items) => items)
        .map((item) => item['recipeId']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (recipeIds.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: FutureBuilder<Map<String, Map<String, dynamic>>>(
        future: _recipeService.getRecipeMetaForIds(recipeIds),
        builder: (context, snapshot) {
          final metaById =
              snapshot.data ?? const <String, Map<String, dynamic>>{};
          return Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...mealTypes.asMap().entries.map((entry) {
                final mealType = entry.value;
                final items = mealItemsByType[mealType]!;
                if (items.isEmpty) return const SizedBox.shrink();
                return _mealRow(
                  context: context,
                  label: labels[mealType]!,
                  labelColor: labelColors[mealType]!,
                  recipeItems: items,
                  isEmpty: items.isEmpty,
                  metaById: metaById,
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Widget _mealRow({
    required BuildContext context,
    required String label,
    required Color labelColor,
    required List<Map<String, dynamic>> recipeItems,
    required bool isEmpty,
    required Map<String, Map<String, dynamic>> metaById,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            height: 50,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: _ts(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: const Color(0xFF4E5968),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: isEmpty
                ? const SizedBox(height: 50)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: recipeItems.map((item) {
                      final recipeId = item['recipeId'] as String? ?? '';
                      final title = item['title'] as String? ?? '레시피';
                      final meta =
                          metaById[recipeId] ?? const <String, dynamic>{};
                      final fridgeRecipe = _fridgeRecipeById(recipeId);
                      final actionRecipe =
                          fridgeRecipe ??
                          <String, dynamic>{
                            'recipeId': recipeId,
                            'recipeName': title,
                          };
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: _MealRecipeInlineCard(
                          title: title,
                          totalMinutes: (meta['totalMinutes'] as num?)?.toInt(),
                          servings:
                              (fridgeRecipe?['servings'] as num?)?.toInt() ??
                              (meta['servings'] as num?)?.toInt(),
                          isCompleted: item['completed'] == true,
                          onOpen: widget.onOpenRecipeDetail == null
                              ? null
                              : () => widget.onOpenRecipeDetail!(actionRecipe),
                          onStart: widget.onStartCooking == null
                              ? null
                              : () => widget.onStartCooking!(actionRecipe),
                          onComplete: widget.onCookingComplete == null
                              ? null
                              : () => widget.onCookingComplete!(actionRecipe),
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MealRecipeInlineCard extends StatelessWidget {
  const _MealRecipeInlineCard({
    required this.title,
    required this.totalMinutes,
    required this.servings,
    required this.isCompleted,
    required this.onOpen,
    required this.onStart,
    required this.onComplete,
  });

  final String title;
  final int? totalMinutes;
  final int? servings;
  final bool isCompleted;
  final VoidCallback? onOpen;
  final VoidCallback? onStart;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final timeText = totalMinutes != null && totalMinutes! > 0
        ? '$totalMinutes분'
        : '시간 확인';
    final servingsText = servings != null && servings! > 0
        ? '$servings인분'
        : '인분 확인';
    final borderColor = isCompleted
        ? const Color(0xFFDCEFE2)
        : const Color(0xFFE7ECF3);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFEFEFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _ts(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              height: 1.18,
                              letterSpacing: -0.3,
                              color: const Color(0xFF191F28),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        _MealMetaChip(
                          icon: Icons.schedule_rounded,
                          label: timeText,
                        ),
                        const SizedBox(width: 5),
                        _MealMetaChip(
                          icon: Icons.people_outline_rounded,
                          label: servingsText,
                        ),
                      ],
                    ),
                    if (isCompleted) ...[
                      const SizedBox(height: 4),
                      Text(
                        '조리 완료',
                        style: _ts(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF16A34A),
                          letterSpacing: -0.2,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CalendarActionButton(
                    label: '시작',
                    icon: Icons.play_arrow_rounded,
                    isPrimary: true,
                    onTap: onStart,
                  ),
                  const SizedBox(width: 6),
                  _CalendarActionButton(
                    label: isCompleted ? '완료됨' : '완료',
                    icon: isCompleted
                        ? Icons.check_circle_rounded
                        : Icons.check_circle_outline_rounded,
                    isPrimary: false,
                    compact: true,
                    onTap: isCompleted ? null : onComplete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MealMetaChip extends StatelessWidget {
  const _MealMetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11.5, color: const Color(0xFF8B95A1)),
          const SizedBox(width: 3),
          Text(
            label,
            style: _ts(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              height: 1,
              color: const Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarActionButton extends StatelessWidget {
  const _CalendarActionButton({
    required this.label,
    required this.icon,
    required this.isPrimary,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final bool isPrimary;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final background = isPrimary
        ? const Color(0xFFFF6422)
        : const Color(0xFFF8FAFC);
    final foreground = isPrimary
        ? Colors.white
        : (enabled ? const Color(0xFF5D6B7E) : const Color(0xFF9AA6B2));
    final radius = compact ? 10.0 : 12.0;
    final height = compact ? 30.0 : 32.0;
    final horizontalPadding = compact ? 10.0 : 13.0;
    final iconSize = compact ? 12.5 : 14.0;
    final textSize = compact ? 10.5 : 12.0;
    final textWeight = isPrimary ? FontWeight.w800 : FontWeight.w700;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
            border: isPrimary
                ? null
                : Border.all(color: const Color(0xFFDCE2EA), width: 1),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: iconSize, color: foreground),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: textSize,
                    fontWeight: textWeight,
                    height: 1.2,
                    letterSpacing: -0.2,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CalendarDayCircle extends StatelessWidget {
  const _CalendarDayCircle({
    required this.day,
    required this.isSelected,
    required this.isExpanded,
    required this.isToday,
  });

  final int day;
  final bool isSelected;
  final bool isExpanded;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 34,
      decoration: BoxDecoration(
        color: isSelected ? _calendarSelectedSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: isToday && !isSelected
            ? Border.all(color: const Color(0xFFE5E8EF), width: 1)
            : null,
        boxShadow: isSelected
            ? const [
                BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Center(
        child: Text(
          '$day',
          style: _ts(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            height: 19.5 / 13,
            color: isSelected
                ? const Color(0xFF191F28)
                : const Color(0xFF4E5968),
          ),
        ),
      ),
    );
  }
}

class _CalendarChevron extends StatefulWidget {
  const _CalendarChevron({required this.isExpanded});
  final bool isExpanded;

  @override
  State<_CalendarChevron> createState() => _CalendarChevronState();
}

class _CalendarChevronState extends State<_CalendarChevron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: CurvedAnimation(parent: _bounce, curve: Curves.easeInOut),
        builder: (context, child) {
          final t = _bounce.value;
          final linear = t <= 0.5 ? t * 2 : 2 - t * 2;
          final eased = Curves.easeInOut.transform(linear);
          final dy = 3.0 * eased;
          return Transform.translate(offset: Offset(0, dy), child: child);
        },
        child: AnimatedRotation(
          turns: widget.isExpanded ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          child: const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: Color(0xFF8B95A1),
          ),
        ),
      ),
    );
  }
}
