import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'app_toast.dart';

import '../services/meal_plan_service.dart';
import '../services/recipe_service.dart';
import 'app_network_image.dart';

// Figma 464-1720 + home sheet alignment
const Color _figmaOrange = Color(0xFFFF6B00);
const Color _figmaTitle = Color(0xFF0F172A);
const Color _figmaText = Color(0xFF1E293B);
const Color _figmaMuted = Color(0xFF94A3B8);
const Color _figmaLabel = Color(0xFF64748B);
const Color _figmaBorder = Color(0xFFF1F5F9);
const Color _figmaHandle = Color(0xFFE2E8F0);
const Color _figmaTodayBg = Color(0xFFFFF9F5);
const Color _figmaBadgeGrey = Color(0xFFF1F5F9);
const Color _figmaBadgeDark = Color(0xFF64748B);

/// Same tokens as [HomeScreen] calendar dots + weekly meal rows (`_barBreakfast` / `_labelBreakfast`, …).
const Color _mealBarBreakfast = Color(0xFFFFB347);
const Color _mealBarLunch = Color(0xFFFF8C42);
const Color _mealBarDinner = Color(0xFFFF6B00);
const Color _mealLabelBreakfast = Color(0xFFE07000);
const Color _mealLabelLunch = Color(0xFFC75A00);
const Color _mealLabelDinner = Color(0xFFA83D00);

(Color bar, Color label) _mealBarAndLabelColors(String mealTime) {
  switch (mealTime) {
    case 'breakfast':
      return (_mealBarBreakfast, _mealLabelBreakfast);
    case 'lunch':
      return (_mealBarLunch, _mealLabelLunch);
    case 'dinner':
      return (_mealBarDinner, _mealLabelDinner);
    default:
      return (const Color(0xFFCBD5E1), _figmaLabel);
  }
}

/// Persists recipe thumbnail URLs for the meal plan editor across opens and stream updates.
/// Images are still cached on disk by [AppNetworkImage]; this avoids refetching Firestore meta.
final Map<String, String> _mealPlanEditorThumbnailCache = {};

class MealPlanEditorDialog extends StatefulWidget {
  final VoidCallback onMealDeleted;

  const MealPlanEditorDialog({super.key, required this.onMealDeleted});

  @override
  State<MealPlanEditorDialog> createState() => _MealPlanEditorDialogState();
}

class _MealPlanEditorDialogState extends State<MealPlanEditorDialog> {
  final MealPlanService _mealPlanService = MealPlanService();
  final RecipeService _recipeService = RecipeService();
  bool _isDeleting = false;

  /// Avoids redundant [precacheImage] work when stream rebuilds with same recipe→URL map.
  String? _precacheBatchKey;

  Stream<Map<String, Map<String, dynamic>>> _getMealPlansStream() {
    final weekDates = _getCalendarDates();
    return _mealPlanService.getMealPlansForDateRange(
      weekDates.first,
      weekDates.last,
    );
  }

  /// 오늘부터 7일 (오늘 .. 오늘+6).
  List<DateTime> _getCalendarDates() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final List<DateTime> dates = [];
    for (int i = 0; i <= 6; i++) {
      dates.add(today.add(Duration(days: i)));
    }
    return dates;
  }

  DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  String _dateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _weekdayLong(DateTime date) {
    const names = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    return names[date.weekday - 1];
  }

  String _formatRangeHeader(DateTime start, DateTime end) {
    return '${start.month}.${start.day} — ${end.month}.${end.day}';
  }

  void _ensureThumbnailsLoaded(Set<String> recipeIds) {
    final missing = recipeIds.where((id) {
      final u = _mealPlanEditorThumbnailCache[id];
      return u == null || u.isEmpty;
    }).toList();
    if (missing.isEmpty) return;
    Future<void>(() async {
      final meta = await _recipeService.getRecipeMetaForIds(missing);
      if (!mounted) return;
      var changed = false;
      for (final e in meta.entries) {
        final u = (e.value['thumbnailUrl'] as String?)?.trim() ?? '';
        if (u.isNotEmpty) {
          _mealPlanEditorThumbnailCache[e.key] = u;
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    });
  }

  /// Warms Flutter's image cache so reopening the sheet does not replay loaders/fades.
  void _schedulePrecacheForRecipeIds(Set<String> recipeIds) {
    final key = recipeIds.map((id) => '$id:${_mealPlanEditorThumbnailCache[id] ?? ""}').join('|');
    if (key == _precacheBatchKey || recipeIds.isEmpty) return;
    _precacheBatchKey = key;
    final ctx = context;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctx.mounted) return;
      for (final id in recipeIds) {
        final url = _mealPlanEditorThumbnailCache[id];
        if (url == null || url.isEmpty) continue;
        precacheImage(
          CachedNetworkImageProvider(
            url,
            maxWidth: 100,
            maxHeight: 100,
            cacheKey: id,
          ),
          ctx,
        );
      }
    });
  }

  Future<bool> _showRemoveConfirmation() async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 27),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 30,
                offset: Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '식단에서 제거할까요?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.45,
                        color: Color(0xFF191F28),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '식단표에서 해당 레시피가 삭제됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: -0.35,
                        color: Color(0xFF4E5968),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 55.167,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(false),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
                            ),
                          ),
                          child: const Text(
                            '취소',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                              color: Color(0xFF4E5968),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(true),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          child: const Text(
                            '삭제',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: Color(0xFFEF4444),
                            ),
                          ),
                        ),
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
    return result ?? false;
  }

  Future<void> _deleteMeal(
    DateTime date,
    String mealTime,
    String recipeId,
    int slotIndex,
  ) async {
    if (_isDeleting) return;
    final confirmed = await _showRemoveConfirmation();
    if (!confirmed || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      await _mealPlanService.removeMealFromDate(
        date: date,
        mealTime: mealTime,
        recipeId: recipeId,
        slotIndex: slotIndex,
      );
      widget.onMealDeleted();
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text(
              '식사 계획이 삭제되었습니다',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text(
              '삭제 중 오류가 발생했습니다: $e',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final sheetHeight = (screenHeight * 0.88).clamp(520.0, screenHeight * 0.92);

    return Container(
      height: sheetHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 40,
            offset: Offset(0, -12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<Map<String, Map<String, dynamic>>>(
        stream: _getMealPlansStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: _figmaOrange),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '오류가 발생했습니다',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: _figmaMuted,
                ),
              ),
            );
          }

          final mealPlans = snapshot.data ?? {};
          final weekDates = _getCalendarDates();
          final start = weekDates.first;
          final end = weekDates.last;
          const mealOrder = ['breakfast', 'lunch', 'dinner'];

          final recipeIds = <String>{};
          for (final date in weekDates) {
            final plan = mealPlans[_dateKey(date)];
            if (plan == null) continue;
            final meals = plan['meals'] as Map<String, dynamic>? ?? {};
            for (final mt in mealOrder) {
              for (final id in (meals[mt] as List?) ?? []) {
                recipeIds.add(id.toString());
              }
            }
          }
          _ensureThumbnailsLoaded(recipeIds);
          _schedulePrecacheForRecipeIds(recipeIds);

          final today = _today();
          final yesterday = today.subtract(const Duration(days: 1));

          final dayBlocks = <Widget>[];
          for (final date in weekDates) {
            final dateKey = _dateKey(date);
            final plan = mealPlans[dateKey];

            final rows = <Widget>[];
            if (plan != null) {
              final meals = plan['meals'] as Map<String, dynamic>? ?? {};
              final recipeTitles =
                  plan['recipeTitles'] as Map<String, dynamic>? ?? {};
              for (final mealTime in mealOrder) {
                final mealList = (meals[mealTime] as List?) ?? [];
                for (var i = 0; i < mealList.length; i++) {
                  final recipeId = mealList[i].toString();
                  final title =
                      recipeTitles[recipeId]?.toString() ?? '레시피';
                  final thumb = _mealPlanEditorThumbnailCache[recipeId];
                  rows.add(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _MealPlanRecipeRow(
                        recipeId: recipeId,
                        mealTime: mealTime,
                        title: title,
                        thumbnailUrl: thumb,
                        // 같은 끼니가 연속되면 첫 항목에만 라벨 표시.
                        showLabel: i == 0,
                        onDelete: _isDeleting
                            ? null
                            : () => _deleteMeal(date, mealTime, recipeId, i),
                      ),
                    ),
                  );
                }
              }
            }

            if (rows.isEmpty) continue;

            final isToday = date.year == today.year &&
                date.month == today.month &&
                date.day == today.day;
            final isYesterday = date.year == yesterday.year &&
                date.month == yesterday.month &&
                date.day == yesterday.day;

            dayBlocks.add(
              _DayBlock(
                date: date,
                dayNumber: date.day,
                weekdayLabel: _weekdayLong(date),
                isToday: isToday,
                isYesterday: isYesterday,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              ),
            );
          }

          final daySections = <Widget>[];
          for (var i = 0; i < dayBlocks.length; i++) {
            daySections.add(dayBlocks[i]);
            if (i < dayBlocks.length - 1) {
              daySections.add(
                Container(
                  margin: const EdgeInsets.only(left: 20, right: 20),
                  height: 0.67,
                  color: _figmaBorder,
                ),
              );
            }
          }

          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 3,
                  decoration: BoxDecoration(
                    color: _figmaHandle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 20, top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatRangeHeader(start, end),
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: _figmaOrange,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                        letterSpacing: 0.66,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '이번 주 식단표',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: _figmaTitle,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                height: 0.67,
                color: _figmaBorder,
              ),
              Expanded(
                child: daySections.isEmpty
                    ? Center(
                        child: Text(
                          '계획된 식사가 없습니다',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: _figmaMuted,
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                        children: daySections,
                      ),
              ),
            ],
          );

          return SafeArea(top: false, child: body);
        },
      ),
    );
  }
}

class _DayBlock extends StatelessWidget {
  const _DayBlock({
    required this.date,
    required this.dayNumber,
    required this.weekdayLabel,
    required this.isToday,
    required this.isYesterday,
    required this.child,
  });

  final DateTime date;
  final int dayNumber;
  final String weekdayLabel;
  final bool isToday;
  final bool isYesterday;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final subLabel = isYesterday
        ? '어제'
        : isToday
            ? '오늘'
            : '${date.month}.${date.day}';

    final headerBg =
        isToday ? _figmaTodayBg : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 60,
          color: headerBg,
          padding: const EdgeInsets.only(left: 20, right: 16),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isToday
                      ? _figmaOrange
                      : isYesterday
                          ? _figmaBadgeDark
                          : _figmaBadgeGrey,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$dayNumber',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: isToday || isYesterday
                        ? Colors.white
                        : _figmaMuted,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      weekdayLabel,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: isToday ? _figmaOrange : _figmaText,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                    Text(
                      subLabel,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: _figmaMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (isToday)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _figmaOrange,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _figmaOrange.withValues(alpha: 0.7),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16),
          child: child,
        ),
      ],
    );
  }
}

class _MealPlanRecipeRow extends StatelessWidget {
  const _MealPlanRecipeRow({
    required this.recipeId,
    required this.mealTime,
    required this.title,
    required this.thumbnailUrl,
    required this.onDelete,
    this.showLabel = true,
  });

  final String recipeId;
  final String mealTime;
  final String title;
  final String? thumbnailUrl;
  final VoidCallback? onDelete;
  final bool showLabel;

  String get _mealLabelText {
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

  @override
  Widget build(BuildContext context) {
    final (barColor, labelColor) = _mealBarAndLabelColors(mealTime);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 42,
          height: 28,
          child: showLabel
              ? Row(
                  children: [
                    Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _mealLabelText,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          color: labelColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                )
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 51),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _figmaBorder, width: 0.67),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0C000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 50,
                  height: 50,
                  child: thumbnailUrl != null && thumbnailUrl!.isNotEmpty
                      ? AppNetworkImage(
                          imageUrl: thumbnailUrl!,
                          cacheKey: recipeId,
                          fit: BoxFit.cover,
                          width: 50,
                          height: 50,
                          memCacheWidth: 100,
                          memCacheHeight: 100,
                          fadeInImmediately: true,
                        )
                      : Container(
                          color: const Color(0xFFF1F5F9),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.restaurant_rounded,
                            size: 22,
                            color: _figmaMuted.withValues(alpha: 0.7),
                          ),
                        ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 4),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: _figmaText,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        height: 1.38,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: GestureDetector(
                    onTap: onDelete,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: _figmaMuted.withValues(
                          alpha: onDelete == null ? 0.35 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
