import 'package:flutter/material.dart';

import '../services/auto_meal_plan_service.dart';
import '../services/meal_plan_service.dart';
import '../services/recipe_service.dart';
import '../services/review_service.dart';
import '../utils/haptics.dart';

const Color _orange = Color(0xFFFF6B00);
const Color _orangeSoft = Color(0xFFFFF4EC);
const Color _ink = Color(0xFF111827);
const Color _inkSub = Color(0xFF4B5563);
const Color _muted = Color(0xFF9CA3AF);
const Color _line = Color(0xFFF0F1F3);
const Color _pageBg = Color(0xFFF9FAFB);

/// Personalized auto meal-plan preview + confirm sheet.
class AutoMealPlanSheet extends StatefulWidget {
  const AutoMealPlanSheet({
    super.key,
    required this.startDate,
    required this.existingPlans,
    required this.fridgeRecipes,
    this.initialDays = 7,
  });

  final DateTime startDate;
  final Map<String, Map<String, dynamic>> existingPlans;
  final List<Map<String, dynamic>> fridgeRecipes;
  final int initialDays;

  static Future<int?> show({
    required BuildContext context,
    required DateTime startDate,
    required Map<String, Map<String, dynamic>> existingPlans,
    required List<Map<String, dynamic>> fridgeRecipes,
    int initialDays = 7,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AutoMealPlanSheet(
        startDate: startDate,
        existingPlans: existingPlans,
        fridgeRecipes: fridgeRecipes,
        initialDays: initialDays,
      ),
    );
  }

  @override
  State<AutoMealPlanSheet> createState() => _AutoMealPlanSheetState();
}

class _AutoMealPlanSheetState extends State<AutoMealPlanSheet> {
  final _planner = AutoMealPlanService();
  final _mealPlanService = MealPlanService();
  final _recipeService = RecipeService();
  final _reviewService = ReviewService();

  late int _days;
  /// 0 = dinner, 1 = lunch+dinner, 2 = all
  int _mealMode = 1;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<AutoMealPlanSuggestion> _suggestions = const [];
  final Set<int> _deselected = {};
  /// 기간/끼니를 빠르게 바꿀 때 이전 응답이 UI를 덮어쓰지 않게 한다.
  int _generateToken = 0;

  @override
  void initState() {
    super.initState();
    _days = widget.initialDays.clamp(3, 14);
    _generate();
  }

  List<String> get _mealTimes {
    switch (_mealMode) {
      case 0:
        return const ['dinner'];
      case 2:
        return const ['breakfast', 'lunch', 'dinner'];
      case 1:
      default:
        return const ['lunch', 'dinner'];
    }
  }

  String _mealLabel(String mealTime) {
    switch (mealTime) {
      case 'breakfast':
        return '아침';
      case 'lunch':
        return '점심';
      case 'dinner':
        return '저녁';
      default:
        return mealTime;
    }
  }

  String _weekdayShort(DateTime date) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[date.weekday - 1];
  }

  Future<void> _generate() async {
    if (_saving) return;
    final token = ++_generateToken;
    // 조회·생성에 동일한 스냅샷을 써서 occupancy/옵션 불일치를 막는다.
    final days = _days;
    final mealTimes = List<String>.from(_mealTimes);

    setState(() {
      _loading = true;
      _error = null;
      _deselected.clear();
    });
    try {
      final start = DateTime(
        widget.startDate.year,
        widget.startDate.month,
        widget.startDate.day,
      );
      final end = start.add(Duration(days: days - 1));
      // 타임아웃은 빈 맵으로 삼키지 않는다 — 점유 슬롯 오판 → append 방지.
      final rangePlans = await _mealPlanService
          .getMealPlansForDateRange(start, end)
          .first
          .timeout(const Duration(seconds: 6));
      if (!mounted || token != _generateToken) return;

      final mergedPlans = <String, Map<String, dynamic>>{
        ...widget.existingPlans,
        ...rangePlans,
      };

      final saved = await _recipeService.getSavedRecipesForExplore(limit: 100);
      if (!mounted || token != _generateToken) return;
      final reviews = await _reviewService.getUserReviews();
      if (!mounted || token != _generateToken) return;

      final suggestions = _planner.generate(
        startDate: start,
        days: days,
        existingPlans: mergedPlans,
        fridgeRecipes: widget.fridgeRecipes,
        savedRecipes: saved,
        reviews: reviews,
        mealTimes: mealTimes,
      );
      if (!mounted || token != _generateToken) return;
      setState(() {
        _suggestions = suggestions;
        _loading = false;
        if (suggestions.isEmpty) {
          _error = '추천할 메뉴가 부족해요. 레시피를 저장하거나 냉장고에 담아 보세요.';
        }
      });
    } catch (e) {
      if (!mounted || token != _generateToken) return;
      setState(() {
        _loading = false;
        _suggestions = const [];
        _error = '맞춤 식단을 만들지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  List<AutoMealPlanSuggestion> get _selectedSuggestions {
    final out = <AutoMealPlanSuggestion>[];
    for (var i = 0; i < _suggestions.length; i++) {
      if (!_deselected.contains(i)) out.add(_suggestions[i]);
    }
    return out;
  }

  Future<void> _confirm() async {
    final selected = _selectedSuggestions;
    if (selected.isEmpty || _saving || _loading) return;
    setState(() => _saving = true);
    // 저장 중 재생성 요청이 끼어들지 않게 토큰을 무효화한다.
    _generateToken += 1;
    Haptics.medium();
    var savedCount = 0;
    try {
      for (final item in selected) {
        await _mealPlanService.addMealToDate(
          date: item.date,
          mealTime: item.mealTime,
          recipeId: item.recipeId,
          recipeTitle: item.recipeTitle,
        );
        savedCount += 1;
      }
      if (!mounted) return;
      Navigator.pop(context, savedCount);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('일부 일정 저장에 실패했어요'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final selectedCount = _selectedSuggestions.length;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.88,
        decoration: const BoxDecoration(
          color: _pageBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Flexible(
                              child: Text(
                                '맞춤 식단 짜기',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  color: _ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF111827)
                                    .withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: const Color(0xFF111827)
                                      .withValues(alpha: 0.10),
                                ),
                              ),
                              child: const Text(
                                'Beta',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.35,
                                  height: 1.1,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '냉장고·기록 기반 자동 채우기',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _muted,
                            letterSpacing: -0.2,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: _muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '기간',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _inkSub,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final d in const [3, 7, 14]) ...[
                        if (d != 3) const SizedBox(width: 8),
                        Expanded(
                          child: _OptionChip(
                            label: '$d일',
                            selected: _days == d,
                            onTap: _saving
                                ? null
                                : () {
                                    if (_days == d) return;
                                    Haptics.selection();
                                    setState(() => _days = d);
                                    _generate();
                                  },
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '끼니',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _inkSub,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final entry in const [
                        (0, '저녁만'),
                        (1, '점심·저녁'),
                        (2, '세끼'),
                      ]) ...[
                        if (entry.$1 != 0) const SizedBox(width: 8),
                        Expanded(
                          child: _OptionChip(
                            label: entry.$2,
                            selected: _mealMode == entry.$1,
                            onTap: _saving
                                ? null
                                : () {
                                    if (_mealMode == entry.$1) return;
                                    Haptics.selection();
                                    setState(() => _mealMode = entry.$1);
                                    _generate();
                                  },
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Divider(height: 1, thickness: 1, color: _line),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _orange),
                    )
                  : _error != null && _suggestions.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _muted,
                                height: 1.45,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                          itemCount: _suggestions.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = _suggestions[index];
                            final selected = !_deselected.contains(index);
                            return _SuggestionTile(
                              selected: selected,
                              dateLabel:
                                  '${item.date.month}/${item.date.day} ${_weekdayShort(item.date)}',
                              mealLabel: _mealLabel(item.mealTime),
                              title: item.recipeTitle,
                              sourceLabel: item.sourceLabel,
                              onToggle: _saving
                                  ? null
                                  : () {
                                      Haptics.selection();
                                      setState(() {
                                        if (selected) {
                                          _deselected.add(index);
                                        } else {
                                          _deselected.remove(index);
                                        }
                                      });
                                    },
                            );
                          },
                        ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                12 + MediaQuery.paddingOf(context).bottom,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: _line)),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: (!_loading && !_saving && selectedCount > 0)
                      ? _confirm
                      : null,
                  child: Ink(
                    height: 52,
                    decoration: BoxDecoration(
                      color: (!_loading && !_saving && selectedCount > 0)
                          ? _orange
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              selectedCount > 0
                                  ? '$selectedCount개 일정에 추가하기'
                                  : '선택된 메뉴가 없어요',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                                color: selectedCount > 0
                                    ? Colors.white
                                    : _muted,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? _orange : const Color(0xFFEDEFF2),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              color: selected ? _orange : _inkSub,
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.selected,
    required this.dateLabel,
    required this.mealLabel,
    required this.title,
    required this.sourceLabel,
    required this.onToggle,
  });

  final bool selected;
  final String dateLabel;
  final String mealLabel;
  final String title;
  final String sourceLabel;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? _orange.withValues(alpha: 0.28) : _line,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: selected ? _orange : Colors.white,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: selected ? _orange : const Color(0xFFD1D5DB),
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          dateLabel,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _inkSub,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _orangeSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            mealLabel,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: _orange,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          sourceLabel,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.25,
                        color: selected ? _ink : _muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
