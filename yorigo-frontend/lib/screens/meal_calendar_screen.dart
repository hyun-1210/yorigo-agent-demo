import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../services/auth_service.dart';
import '../services/meal_plan_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../services/analytics_service.dart';
import '../theme/app_colors.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../widgets/app_network_image.dart';
import '../widgets/cooking_instruction_sheet.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/auto_meal_plan_sheet.dart';
import '../utils/meal_plan_completion_utils.dart';
import '../utils/recipe_source_lookup.dart';
import '../widgets/recipe_signal_impression.dart';

const Color _orange = Color(0xFFFF6B00);
const Color _orangeSoft = Color(0xFFFFF4EC);
const Color _sundayAccent = Color(0xFFE07A3A);
const Color _ink = Color(0xFF111827);
const Color _inkSub = Color(0xFF4B5563);
const Color _muted = Color(0xFF9CA3AF);
const Color _line = Color(0xFFF0F1F3);
const Color _pageBg = Color(0xFFF9FAFB);
const Color _cellEmpty = Color(0xFFF7F8FA);
const Color _selectedFill = Color(0xFFE5E7EB);

const Color _barBreakfast = Color(0xFFFFB347);
const Color _barLunch = Color(0xFFFF8C42);
const Color _barDinner = Color(0xFFFF6B00);
const double _mealPillWidth = 56;

const List<String> _mealOrder = ['breakfast', 'lunch', 'dinner'];
const Map<String, String> _mealLabels = {
  'breakfast': '아침',
  'lunch': '점심',
  'dinner': '저녁',
};

Color _mealBarColor(String mealTime) {
  switch (mealTime) {
    case 'breakfast':
      return _barBreakfast;
    case 'lunch':
      return _barLunch;
    case 'dinner':
      return _barDinner;
    default:
      return _muted;
  }
}

IconData _mealPillIcon(String mealTime) {
  switch (mealTime) {
    case 'breakfast':
      return Icons.wb_twilight_rounded;
    case 'lunch':
      return Icons.wb_sunny_rounded;
    case 'dinner':
      return Icons.nights_stay_rounded;
    default:
      return Icons.restaurant_rounded;
  }
}

enum _CalendarMainTab { calendar, list }

class MealCalendarScreen extends StatefulWidget {
  const MealCalendarScreen({
    super.key,
    this.onStartCooking,
    this.onCookingComplete,
    this.onOpenRecipeDetail,
    this.initialTabIndex = 0,
  });

  final ValueChanged<Map<String, dynamic>>? onStartCooking;
  final void Function(
    BuildContext context,
    Map<String, dynamic> recipe,
    Map<String, dynamic>? fridgeData,
    Brightness brightness,
  )? onCookingComplete;
  final ValueChanged<Map<String, dynamic>>? onOpenRecipeDetail;
  final int initialTabIndex;

  @override
  State<MealCalendarScreen> createState() => _MealCalendarScreenState();
}

class _MealCalendarScreenState extends State<MealCalendarScreen>
    with SingleTickerProviderStateMixin {
  final MealPlanService _mealPlanService = MealPlanService();
  final RecipeService _recipeService = RecipeService.shared;
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();

  final Map<String, Map<String, dynamic>> _mealPlans = {};
  StreamSubscription<Map<String, Map<String, dynamic>>>? _mealPlansSub;
  String? _mealPlansWindowStartKey;
  String? _mealPlansWindowEndKey;
  StreamSubscription<Map<String, dynamic>?>? _fridgeSub;
  StreamSubscription? _authSub;

  /// Months away from the current month (0 = current month).
  int _monthOffset = 0;
  /// 1 = 다음 달(오른쪽에서 들어옴), -1 = 이전 달(왼쪽에서 들어옴).
  int _monthSlideDir = 1;
  /// 화살표/스와이프로 달을 넘길 때만 슬라이드 애니를 켠다.
  bool _animateMonthChange = false;
  late DateTime _selectedDate;

  /// 날짜 상세 영역을 좌우로 부드럽게 넘기기 위한 PageView 컨트롤러.
  /// 페이지 인덱스 = [_dayPageEpoch] 로부터의 경과 일수.
  static final DateTime _dayPageEpoch = DateTime(2000, 1, 1);
  late final PageController _dayPageController;
  bool _animatingDayPage = false;

  /// Calendar collapse sheet (mirrors the home "나의 레시피북" pull-to-collapse):
  /// value 1.0 = full month grid (expanded), 0.0 = single selected-week row.
  late final AnimationController _calSheetController;
  double _calDragTravel = 1.0;
  bool _calDragging = false;
  static const double _calSnapThreshold = 0.5;

  /// Hide the FAB while the add-menu popup is open so its glow doesn't bleed
  /// out around the popup card.
  bool _addMenuOpen = false;
  _CalendarMainTab _mainTab = _CalendarMainTab.calendar;
  final Map<String, GlobalKey> _listSectionKeys = {};
  final ScrollController _listScrollController = ScrollController();
  String? _listAutoScrollMonthToken;
  bool _listAutoScrollDone = false;
  int _listAutoScrollRetryCount = 0;
  /// 오늘 위치로 jump 완료 전에는 리스트를 숨겨 상단→오늘 점프 플래시를 막는다.
  bool _listRevealReady = false;

  List<Map<String, dynamic>> _fridgeRecipes = const [];
  Map<String, dynamic>? _fridgeData;

  @override
  void initState() {
    super.initState();
    _mainTab = switch (widget.initialTabIndex) {
      1 => _CalendarMainTab.list,
      _ => _CalendarMainTab.calendar,
    };
    _selectedDate = _today();
    _dayPageController = PageController(
      initialPage: _dateToPageIndex(_selectedDate),
    );
    _calSheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 1.0,
    );
    _subscribeForWindow();
    _authSub = _authService.authStateChanges.listen((user) {
      if (!mounted) return;
      if (user == null) {
        _mealPlansWindowStartKey = null;
        _mealPlansWindowEndKey = null;
        setState(() {
          _mealPlans.clear();
          _fridgeRecipes = const [];
          _fridgeData = null;
        });
      } else {
        _subscribeFridge(user.uid);
        _subscribeForWindow();
      }
    });
    final current = _authService.currentUser;
    if (current != null) _subscribeFridge(current.uid);
    unawaited(
      AnalyticsService().trackMealCalendarOpened(sourceScreen: 'meal_calendar'),
    );
    if (widget.initialTabIndex == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openInsightsSheet();
      });
    }
    if (widget.initialTabIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onListMonthContextChanged(clearSectionKeys: true);
      });
    }
  }

  @override
  void dispose() {
    _mealPlansSub?.cancel();
    _fridgeSub?.cancel();
    _authSub?.cancel();
    _calSheetController.dispose();
    _dayPageController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// First day of the displayed month.
  DateTime get _displayedMonth {
    final now = DateTime.now();
    return DateTime(now.year, now.month + _monthOffset, 1);
  }

  /// Full month grid: starts on the Sunday on/before the 1st and ends on the
  /// Saturday on/after the last day (always a multiple of 7 days).
  List<DateTime> get _visibleDates {
    final first = _displayedMonth;
    final gridStart = first.subtract(Duration(days: first.weekday % 7));
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final lastDay = DateTime(first.year, first.month, daysInMonth);
    final gridEnd = lastDay.add(Duration(days: 6 - (lastDay.weekday % 7)));
    final total = gridEnd.difference(gridStart).inDays + 1;
    return List.generate(total, (i) => gridStart.add(Duration(days: i)));
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _subscribeForWindow() {
    final dates = _visibleDates;
    final startKey = _dateKey(dates.first);
    final endKey = _dateKey(dates.last);

    // 같은 달력 윈도우면 구독을 재생성하지 않는다 (날짜 스와이프 시 churn 방지).
    if (_mealPlansSub != null &&
        _mealPlansWindowStartKey == startKey &&
        _mealPlansWindowEndKey == endKey) {
      return;
    }
    _mealPlansWindowStartKey = startKey;
    _mealPlansWindowEndKey = endKey;

    _mealPlansSub?.cancel();
    _mealPlansSub = _mealPlanService
        .getMealPlansForDateRange(dates.first, dates.last)
        .listen(
          (plans) {
            if (!mounted) return;
            setState(() {
              for (final d in dates) {
                _mealPlans.remove(_dateKey(d));
              }
              _mealPlans.addAll(plans);
            });
          },
          // 스트림 에러가 리스너를 조용히 종료시켜 라이브 갱신이 멈추는 것을 방지.
          onError: (Object e, StackTrace _) {
            debugPrint('[MealCalendar] meal plan stream error: $e');
          },
        );
  }

  void _subscribeFridge(String uid) {
    _fridgeSub?.cancel();
    _fridgeSub = _userService.getFridgeDataStream(uid).listen((data) {
      if (!mounted) return;
      setState(() {
        _fridgeData = data;
        _fridgeRecipes =
            (data?['recipes'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
      });
    });
  }

  void _goPrevMonth() {
    Haptics.selection();
    setState(() {
      _animateMonthChange = true;
      _monthSlideDir = -1;
      _monthOffset -= 1;
    });
    _subscribeForWindow();
    _onListMonthContextChanged();
    _clearMonthAnimAfterTransition();
  }

  void _goNextMonth() {
    Haptics.selection();
    setState(() {
      _animateMonthChange = true;
      _monthSlideDir = 1;
      _monthOffset += 1;
    });
    _subscribeForWindow();
    _onListMonthContextChanged();
    _clearMonthAnimAfterTransition();
  }

  /// Jump to an arbitrary month (used by month picker / 오늘).
  void _jumpToMonth(DateTime month, {bool animate = true}) {
    final now = DateTime.now();
    final targetOffset =
        (month.year - now.year) * 12 + (month.month - now.month);
    if (targetOffset == _monthOffset) return;
    Haptics.selection();
    setState(() {
      _animateMonthChange = animate;
      _monthSlideDir = targetOffset > _monthOffset ? 1 : -1;
      _monthOffset = targetOffset;
    });
    _subscribeForWindow();
    _onListMonthContextChanged();
    if (animate) _clearMonthAnimAfterTransition();
  }

  void _goToToday() {
    _selectDate(_today());
  }

  Future<void> _openMonthPicker() async {
    Haptics.selection();
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _MonthPickerSheet(initialMonth: _displayedMonth);
      },
    );
    if (!mounted || picked == null) return;
    _jumpToMonth(picked);
  }

  void _clearMonthAnimAfterTransition() {
    // setState로 트리 타입을 바꾸지 않는다.
    // (AnimatedSwitcher ↔ KeyedSubtree 교체는 InheritedElement
    //  _dependents.isEmpty assert를 유발할 수 있음)
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) _animateMonthChange = false;
    });
  }

  void _onCalendarHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // 왼쪽 스와이프 → 다음 달, 오른쪽 스와이프 → 이전 달
    if (velocity <= -220) {
      _goNextMonth();
    } else if (velocity >= 220) {
      _goPrevMonth();
    }
  }

  /// 월 타이틀용: Row(세로 unbounded) 안에서도 안전한 짧은 페이드.
  Widget _monthLabelTransition({required Widget child}) {
    final animate = _animateMonthChange;
    return AnimatedSwitcher(
      duration: animate
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(_monthSlideDir * 0.08, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  /// 캘린더 그리드용 슬라이드. 위젯 트리 구조는 항상 동일하게 유지하고,
  /// 탭 동기화 등 비애니 전환은 duration=0으로 즉시 교체한다.
  Widget _monthTransition({required Widget child}) {
    final animate = _animateMonthChange;
    const curve = Cubic(0.22, 1.15, 0.36, 1.0);
    final duration =
        animate ? const Duration(milliseconds: 420) : Duration.zero;
    final reverseDuration =
        animate ? const Duration(milliseconds: 320) : Duration.zero;
    final sizeDuration =
        animate ? const Duration(milliseconds: 320) : Duration.zero;

    return AnimatedSize(
      duration: sizeDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        reverseDuration: reverseDuration,
        switchInCurve: curve,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          final slidingIn = child.key == ValueKey<int>(_monthOffset);
          final beginX = slidingIn
              ? (_monthSlideDir * 0.22)
              : (_monthSlideDir * -0.14);
          return ClipRect(
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(beginX, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey<int>(_monthOffset),
          child: child,
        ),
      ),
    );
  }

  int _dateToPageIndex(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return d.difference(_dayPageEpoch).inDays;
  }

  DateTime _dateFromPageIndex(int index) =>
      _dayPageEpoch.add(Duration(days: index));

  /// 날짜 상세 PageView가 새 페이지로 정착했을 때 선택 날짜/월 윈도우를 동기화.
  void _onDayPageChanged(int index) {
    if (_animatingDayPage) return;
    final next = _dateFromPageIndex(index);
    final now = DateTime.now();
    final targetOffset =
        (next.year - now.year) * 12 + (next.month - now.month);
    setState(() {
      _animateMonthChange = false;
      _selectedDate = next;
      _monthOffset = targetOffset;
    });
    _subscribeForWindow();
    _onListMonthContextChanged();
    Haptics.selection();
  }

  /// 그리드에서 날짜를 탭하면 상세 PageView를 부드럽게 그 날짜로 이동시킨다.
  void _selectDate(DateTime date) {
    final target = _dateToPageIndex(date);
    final d = DateTime(date.year, date.month, date.day);
    final now = DateTime.now();
    final targetOffset = (d.year - now.year) * 12 + (d.month - now.month);
    setState(() {
      _animateMonthChange = false;
      _selectedDate = d;
      _monthOffset = targetOffset;
    });
    _subscribeForWindow();
    if (_dayPageController.hasClients) {
      final current = _dayPageController.page?.round();
      if (current != target) {
        _animatingDayPage = true;
        _dayPageController
            .animateToPage(
              target,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() => _animatingDayPage = false);
      }
    }
  }

  // --- meal lookups -------------------------------------------------------

  List<String> _mealTimesWithItems(DateTime date) {
    if (_authService.currentUser == null) return const [];
    final plan = _mealPlans[_dateKey(date)];
    if (plan == null) return const [];
    final meals = plan['meals'] as Map<String, dynamic>? ?? {};
    return _mealOrder
        .where((mt) => (meals[mt] as List?)?.isNotEmpty == true)
        .toList();
  }

  List<_MealItem> _mealItems(DateTime date, String mealTime) {
    if (_authService.currentUser == null) return const [];
    final plan = _mealPlans[_dateKey(date)];
    if (plan == null) return const [];
    final meals = plan['meals'] as Map<String, dynamic>? ?? {};
    final titles = plan['recipeTitles'] as Map<String, dynamic>? ?? {};

    final list = (meals[mealTime] as List?) ?? [];
    return list.asMap().entries.map((e) {
      final id = e.value.toString().trim();
      final status = resolveMealPlanSlotStatus(
        plan: plan,
        mealTime: mealTime,
        slotIndex: e.key,
        mealOrder: _mealOrder,
      );
      return _MealItem(
        date: date,
        recipeId: id,
        mealTime: mealTime,
        slotIndex: e.key,
        title: titles[id]?.toString() ?? '메뉴',
        completed: status.completed,
        isMemo: id.startsWith('memo_'),
      );
    }).toList();
  }

  Map<String, dynamic> _actionRecipeFor(_MealItem item) {
    for (final r in _fridgeRecipes) {
      final id = (r['recipeId'] ?? r['id'])?.toString().trim() ?? '';
      if (id == item.recipeId) return r;
    }
    return {'recipeId': item.recipeId, 'recipeName': item.title};
  }

  List<DateTime> _monthDates() {
    final month = _displayedMonth;
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return List.generate(
      lastDay,
      (index) => DateTime(month.year, month.month, index + 1),
    );
  }

  List<_MonthMealSection> _monthMealSections() {
    final sections = <_MonthMealSection>[];
    for (final date in _monthDates()) {
      final times = _mealTimesWithItems(date);
      final items = <_MealItem>[];
      for (final mealTime in _mealOrder) {
        if (times.contains(mealTime)) {
          items.addAll(_mealItems(date, mealTime));
        }
      }
      sections.add(_MonthMealSection(date: date, items: items));
    }
    sections.sort((a, b) => a.date.compareTo(b.date));
    return sections;
  }

  String get _listMonthToken =>
      '${_displayedMonth.year}-${_displayedMonth.month}';

  void _markListRevealReady() {
    if (!mounted || _listRevealReady) return;
    setState(() => _listRevealReady = true);
  }

  void _jumpListTowardTodayIfPossible(List<_MonthMealSection> sections) {
    if (!_listScrollController.hasClients) return;
    final todayIndex =
        sections.indexWhere((s) => _isSameDay(s.date, _today()));
    if (todayIndex < 0) return;
    final maxExtent = _listScrollController.position.maxScrollExtent;
    final estimate = _estimateListOffsetBeforeIndex(sections, todayIndex)
        .clamp(0.0, maxExtent);
    _listScrollController.jumpTo(estimate);
  }

  void _scheduleListAutoScrollToToday(List<_MonthMealSection> sections) {
    if (_mainTab != _CalendarMainTab.list || _listAutoScrollDone) return;
    final today = _today();
    final todayKey = _dateKey(today);
    final todayIndex = sections.indexWhere((s) => _isSameDay(s.date, today));
    if (todayIndex < 0) {
      _listAutoScrollDone = true;
      _listAutoScrollMonthToken = _listMonthToken;
      _markListRevealReady();
      return;
    }
    final targetKey = _listSectionKeys.putIfAbsent(todayKey, () => GlobalKey());
    void tryScroll() {
      if (!mounted || _mainTab != _CalendarMainTab.list) return;
      if (!_listScrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryScroll());
        return;
      }

      final ctx = targetKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: Duration.zero,
          alignment: 0,
        );
        _listAutoScrollDone = true;
        _listAutoScrollMonthToken = _listMonthToken;
        _markListRevealReady();
        return;
      }

      // 아직 target 섹션이 빌드되지 않은 경우(리스트 초기에 화면 밖),
      // 추정 오프셋으로 먼저 이동해 빌드되게 만든 뒤 한 번 더 정렬한다.
      _jumpListTowardTodayIfPossible(sections);
      _listAutoScrollRetryCount += 1;
      if (_listAutoScrollRetryCount <= 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryScroll());
      } else {
        _listAutoScrollDone = true;
        _listAutoScrollMonthToken = _listMonthToken;
        _markListRevealReady();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryScroll());
  }

  /// 리스트 탭 auto-scroll 상태를 초기화하고 1회 스케줄한다.
  void _onListMonthContextChanged({bool clearSectionKeys = true}) {
    if (_mainTab != _CalendarMainTab.list) return;
    _listAutoScrollMonthToken = _listMonthToken;
    if (clearSectionKeys) _listSectionKeys.clear();
    _listAutoScrollDone = false;
    _listAutoScrollRetryCount = 0;
    // 페이드아웃 없이 즉시 숨김 → 상단 플래시 방지
    if (_listRevealReady) {
      setState(() => _listRevealReady = false);
    } else {
      _listRevealReady = false;
    }
    final sections = _monthMealSections();
    _jumpListTowardTodayIfPossible(sections);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mainTab != _CalendarMainTab.list) return;
      _scheduleListAutoScrollToToday(_monthMealSections());
    });
  }

  void _enterListTab() {
    final monthToken = _listMonthToken;
    final needsResync =
        _listAutoScrollMonthToken != monthToken || !_listAutoScrollDone;

    if (!needsResync) {
      // 같은 달·이미 정렬된 상태면 그대로 보여 글리치 없이 전환
      _markListRevealReady();
      return;
    }

    _listAutoScrollMonthToken = monthToken;
    _listAutoScrollDone = false;
    _listAutoScrollRetryCount = 0;
    final sections = _monthMealSections();
    _jumpListTowardTodayIfPossible(sections);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mainTab != _CalendarMainTab.list) return;
      _scheduleListAutoScrollToToday(_monthMealSections());
    });
  }

  void _syncCalendarSelectionFromPage() {
    void sync() {
      if (!mounted || _mainTab != _CalendarMainTab.calendar) return;
      if (!_dayPageController.hasClients) return;
      final page = _dayPageController.page?.round();
      if (page == null) return;
      final pageDate = _dateFromPageIndex(page);
      if (_isSameDay(pageDate, _selectedDate)) return;
      final now = DateTime.now();
      final nextOffset =
          (pageDate.year - now.year) * 12 + (pageDate.month - now.month);
      setState(() {
        _animateMonthChange = false;
        _selectedDate = DateTime(pageDate.year, pageDate.month, pageDate.day);
        _monthOffset = nextOffset;
      });
      _subscribeForWindow();
    }

    // Try now if a client is already attached.
    sync();
    // Also try after the calendar tab has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => sync());
  }

  double _estimateListOffsetBeforeIndex(
    List<_MonthMealSection> sections,
    int targetIndex,
  ) {
    var offset = 0.0;
    for (var i = 0; i < targetIndex; i++) {
      offset += _estimatedListSectionHeight(sections[i]);
    }
    return offset;
  }

  double _estimatedListSectionHeight(_MonthMealSection section) {
    final itemCount = section.items.length;
    const header = 28.0;
    const cardPadding = 22.0; // 12 + 10
    const gapBelowHeader = 10.0;
    const rowHeight = 44.0;
    const inlineActionBlock = 34.0;
    const sectionGap = 8.0;
    if (itemCount == 0) {
      return 56.0 + sectionGap;
    }
    final dividerTotal = itemCount > 1 ? (itemCount - 1) * 5.0 : 0.0;
    return sectionGap +
        cardPadding +
        header +
        gapBelowHeader +
        (rowHeight + inlineActionBlock) * itemCount +
        dividerTotal;
  }

  List<_MealItem> _monthMealItemsFlat() {
    final sections = _monthMealSections();
    return sections.expand((section) => section.items).toList();
  }

  List<MapEntry<String, int>> _topMenusThisMonth() {
    final counts = <String, int>{};
    final titleByRecipeId = <String, String>{};
    for (final item in _monthMealItemsFlat()) {
      final recipeKey = item.recipeId.trim();
      if (recipeKey.isEmpty) continue;
      counts[recipeKey] = (counts[recipeKey] ?? 0) + 1;
      titleByRecipeId.putIfAbsent(recipeKey, () => item.title.trim());
    }
    final entries = counts.entries
        .map((e) => MapEntry(titleByRecipeId[e.key] ?? e.key, e.value))
        .toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    return entries;
  }

  Map<String, int> _mealTimeCountsThisMonth() {
    final map = <String, int>{'breakfast': 0, 'lunch': 0, 'dinner': 0};
    for (final item in _monthMealItemsFlat()) {
      map[item.mealTime] = (map[item.mealTime] ?? 0) + 1;
    }
    return map;
  }

  // --- formatting ---------------------------------------------------------

  String _weekdayLong(DateTime d) {
    const names = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    return names[d.weekday - 1];
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final loggedIn = _authService.currentUser != null;

    return Scaffold(
      backgroundColor: _pageBg,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: loggedIn
          ? _AddMealFabButton(
              visible:
                  _mainTab == _CalendarMainTab.calendar && !_addMenuOpen,
              onTap: _showAddMenu,
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: loggedIn
                  ? Column(
                      children: [
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: _buildMonthNav(),
                        ),
                        const SizedBox(height: 10),
                        _buildMainTabs(),
                        Expanded(
                          child: _buildMainTabSwitcher(),
                        ),
                      ],
                    )
                  : Center(
                      child: Text(
                        '로그인하면 식단 캘린더를 사용할 수 있어요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 48,
      padding: const EdgeInsets.fromLTRB(4, 0, 10, 0),
      color: _pageBg,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Text(
            '식단 캘린더',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: _ink,
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: _ink,
                ),
              ),
              const Spacer(),
              _InsightHeaderButton(onTap: _openInsightsSheet),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMonthNav() {
    final month = _displayedMonth;
    final today = _today();
    final isCurrentMonth =
        month.year == today.year && month.month == today.month;

    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            children: [
              _MonthNavClusterButton(
                icon: Icons.chevron_left_rounded,
                onTap: _goPrevMonth,
              ),
              const Spacer(),
              _MonthNavClusterButton(
                icon: Icons.chevron_right_rounded,
                onTap: _goNextMonth,
              ),
            ],
          ),
          GestureDetector(
            onTap: _openMonthPicker,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _monthLabelTransition(
                child: Column(
                  key: ValueKey<String>('month-label-$_monthOffset'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${month.year}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.15,
                        height: 1.0,
                        color: _muted,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${month.month}월',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.45,
                        height: 1.05,
                        color: _ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!isCurrentMonth)
            Positioned(
              right: 40,
              child: GestureDetector(
                onTap: _goToToday,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    '오늘',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.25,
                      color: _orange,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openInsightsSheet() {
    Haptics.selection();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.88,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9DEE7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '월간 인사이트',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.45,
                            color: _ink,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 22,
                          color: _inkSub,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildStatsTabContent()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMainTabs() {
    const tabs = <(_CalendarMainTab, String)>[
      (_CalendarMainTab.calendar, '캘린더'),
      (_CalendarMainTab.list, '요리 일정'),
    ];
    final selectedIndex = switch (_mainTab) {
      _CalendarMainTab.calendar => 0,
      _CalendarMainTab.list => 1,
    };

    const activeStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: _ink,
      letterSpacing: -0.28,
    );
    const inactiveStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: _muted,
      letterSpacing: -0.28,
    );

    void _onTapTab(_CalendarMainTab nextTab) {
      if (_mainTab == nextTab) return;
      Haptics.selection();
      final enteringList = nextTab == _CalendarMainTab.list;
      final listNeedsResync = enteringList &&
          (_listAutoScrollMonthToken != _listMonthToken ||
              !_listAutoScrollDone);

      setState(() {
        _mainTab = nextTab;
        // 재정렬이 필요할 때만 숨김. AnimatedOpacity 1→0 페이드가
        // 탭 전환과 겹치며 생기던 플래시를 막는다.
        if (listNeedsResync) {
          _listRevealReady = false;
          _listAutoScrollDone = false;
          _listAutoScrollRetryCount = 0;
        }
      });
      if (nextTab == _CalendarMainTab.calendar) {
        _syncCalendarSelectionFromPage();
      } else {
        _enterListTab();
      }
    }

    return SizedBox(
      height: 42,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / tabs.length;
          final indicatorWidth = tabWidth * 0.42;
          final indicatorLeft =
              (selectedIndex * tabWidth) + ((tabWidth - indicatorWidth) / 2);

          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(height: 1, color: _line),
              ),
              Row(
                children: [
                  for (final tab in tabs)
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _onTapTab(tab.$1),
                          splashFactory: NoSplash.splashFactory,
                          highlightColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          overlayColor:
                              MaterialStateProperty.all(Colors.transparent),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              style: _mainTab == tab.$1
                                  ? activeStyle
                                  : inactiveStyle,
                              child: Text(tab.$2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                left: indicatorLeft,
                bottom: 0,
                child: Container(
                  width: indicatorWidth,
                  height: 2,
                  decoration: BoxDecoration(
                    color: _orange,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 탭 전환은 애니메이션 없이 즉시 교체 (PPT 슬라이드 느낌 제거).
  Widget _buildMainTabSwitcher() {
    return IndexedStack(
      index: _mainTab == _CalendarMainTab.calendar ? 0 : 1,
      sizing: StackFit.expand,
      children: [
        _buildCalendarTabContent(),
        _buildListTabContent(),
      ],
    );
  }

  Widget _buildCalendarTabContent() {
    return Column(
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: _onCalendarHorizontalSwipe,
            onVerticalDragStart: (_) {
              _calDragging = true;
              _calSheetController.stop();
            },
            onVerticalDragUpdate: (details) =>
                _onCalDragUpdate(details.delta.dy),
            onVerticalDragEnd: (details) =>
                _onCalDragEnd(details.primaryVelocity ?? 0),
            onVerticalDragCancel: () {
              _calDragging = false;
              _setCalExpanded(_calSheetController.value >= _calSnapThreshold);
            },
            child: Column(
              children: [
                _buildWeekdayLabels(),
                const SizedBox(height: 8),
                _monthTransition(child: _buildGrid()),
              ],
            ),
          ),
        ),
        Expanded(child: _buildCollapseDragArea()),
      ],
    );
  }

  Widget _buildListTabContent() {
    final sections = _monthMealSections();
    return AnimatedOpacity(
      // 숨길 때는 즉시(0ms), 보여줄 때만 짧게 페이드인
      opacity: _listRevealReady ? 1 : 0,
      duration: Duration(milliseconds: _listRevealReady ? 120 : 0),
      curve: Curves.easeOutCubic,
      child: ListView.separated(
        controller: _listScrollController,
        physics: _listRevealReady
            ? const BouncingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 28),
        itemCount: sections.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final section = sections[index];
          final key = _listSectionKeys.putIfAbsent(
            _dateKey(section.date),
            () => GlobalKey(),
          );
          return KeyedSubtree(
            key: key,
            child: _buildMonthListSection(section),
          );
        },
      ),
    );
  }

  Widget _buildTodayChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _orangeSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        '오늘',
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _orange,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  Widget _buildListDayHeader({
    required DateTime date,
    required bool isToday,
    required int itemCount,
  }) {
    return Row(
      children: [
        Text(
          '${date.month}월 ${date.day}일',
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: _ink,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _weekdayLong(date).replaceAll('요일', ''),
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: date.weekday == DateTime.sunday ? _sundayAccent : _muted,
          ),
        ),
        if (isToday) ...[
          const SizedBox(width: 8),
          _buildTodayChip(),
        ],
        const Spacer(),
        if (itemCount > 0) ...[
          Text(
            '$itemCount개',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _muted,
            ),
          ),
          const SizedBox(width: 8),
        ],
        _buildListDateAddButton(date),
      ],
    );
  }

  Widget _buildMonthListSection(_MonthMealSection section) {
    final isToday = _isSameDay(section.date, _today());
    if (section.items.isEmpty) {
      return _buildEmptyDayListRow(section.date, isToday: isToday);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isToday ? _orange.withValues(alpha: 0.28) : _line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildListDayHeader(
            date: section.date,
            isToday: isToday,
            itemCount: section.items.length,
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < section.items.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Divider(height: 1, thickness: 1, color: _line),
              ),
            _buildMonthListRow(
              section.date,
              section.items[i],
              showMealPill: i == 0 ||
                  section.items[i - 1].mealTime != section.items[i].mealTime,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildListDateAddButton(DateTime date, {double size = 28}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openAddMealSheet(date: date),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF4F5F7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.add_rounded,
            size: size * 0.62,
            color: _ink,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyDayListRow(DateTime date, {required bool isToday}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openAddMealSheet(date: date),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isToday ? _orange.withValues(alpha: 0.28) : _line,
            ),
          ),
          child: _buildListDayHeader(
            date: date,
            isToday: isToday,
            itemCount: 0,
          ),
        ),
      ),
    );
  }

  Widget _buildMonthListRow(
    DateTime date,
    _MealItem item, {
    bool showMealPill = true,
  }) {
    final canOpenDetail = !item.isMemo;
    final row = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canOpenDetail ? () => unawaited(_openRecipeDetailForItem(item)) : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showMealPill)
                SizedBox(
                  width: _mealPillWidth,
                  height: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildMealTimePill(item.mealTime),
                  ),
                )
              else
                const SizedBox(width: _mealPillWidth, height: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 24,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  height: 1.1,
                                  color: item.completed ? _muted : _ink,
                                  decoration: item.completed
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                          ),
                          if (item.completed)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.check_circle_rounded,
                                size: 16,
                                color: Color(0xFF16A34A),
                              ),
                            ),
                          _buildRowMenu(date, item),
                        ],
                      ),
                    ),
                    _buildInlineMealActions(item),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (item.isMemo) return row;
    return RecipeIdSignalImpression(
      screen: 'meal_calendar',
      recipeId: item.recipeId,
      sectionId: 'meal_${item.mealTime}',
      position: item.slotIndex,
      contentType: 'meal_plan',
      child: row,
    );
  }

  (Color bg, Color fg) _mealPillColors(String mealTime) {
    switch (mealTime) {
      case 'breakfast':
        return (const Color(0xFFFFF4E5), const Color(0xFFB45309));
      case 'lunch':
        return (const Color(0xFFFFF1E8), const Color(0xFFC2410C));
      case 'dinner':
        return (const Color(0xFFF3F4F6), const Color(0xFF374151));
      default:
        return (const Color(0xFFF4F5F7), _inkSub);
    }
  }

  Widget _buildMealTimePill(String mealTime) {
    final mealLabel = _mealLabels[mealTime] ?? mealTime;
    final mealIcon = _mealPillIcon(mealTime);
    final colors = _mealPillColors(mealTime);
    return Container(
      width: _mealPillWidth,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(mealIcon, size: 12, color: colors.$2),
          const SizedBox(width: 3),
          Text(
            mealLabel,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: colors.$2,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineMealActions(_MealItem item) {
    final actions = <Widget>[
      if (!item.completed)
        _InlineMealActionChip(
          label: '리뷰 남기기',
          onTap: () => unawaited(_leaveReviewForItem(item)),
        ),
      if (!item.isMemo)
        _InlineMealActionChip(
          label: 'Cook-Mode',
          onTap: () => unawaited(_startCookingForItem(item)),
        ),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            actions[i],
          ],
        ],
      ),
    );
  }

  Widget _buildStatsTabContent() {
    final monthSections = _monthMealSections();
    final monthItems = _monthMealItemsFlat();
    final mealTimeCounts = _mealTimeCountsThisMonth();
    final topMenus = _topMenusThisMonth();
    final totalMeals = monthItems.length;
    final recordedDays = monthSections.where((section) => section.items.isNotEmpty).length;
    final completedMeals = monthItems.where((item) => item.completed).length;
    final memoMeals = monthItems.where((item) => item.isMemo).length;
    final avgPerDay = recordedDays == 0 ? 0.0 : totalMeals / recordedDays;
    final completionRate = totalMeals == 0 ? 0.0 : completedMeals / totalMeals;
    final maxMealCount = _mealOrder
        .map((mealTime) => mealTimeCounts[mealTime] ?? 0)
        .fold<int>(0, (max, count) => count > max ? count : max);

    var dominantMealTime = _mealOrder.first;
    var dominantCount = -1;
    for (final mealTime in _mealOrder) {
      final count = mealTimeCounts[mealTime] ?? 0;
      if (count > dominantCount) {
        dominantCount = count;
        dominantMealTime = mealTime;
      }
    }

    final insights = <String>[
      if (totalMeals == 0)
        '아직 기록이 없어요. 달력 탭에서 첫 식단을 추가해보세요.'
      else
        '이번 달에는 ${_mealLabels[dominantMealTime] ?? dominantMealTime} 기록이 가장 많아요.',
      if (totalMeals > 0)
        '완료 처리 비율은 ${(completionRate * 100).toStringAsFixed(0)}%예요.',
      if (memoMeals > 0)
        '직접 입력 메뉴가 $memoMeals개 있어요. 자주 먹는 메뉴는 레시피북과 연결해보세요.',
    ];

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFF8FAFD)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE8EEF6)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.06),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_displayedMonth.month}월 식단 요약',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _ink,
                        letterSpacing: -0.45,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    flex: 10,
                    child: _buildStatMiniChip(
                      label: '기록된 날짜',
                      value: '$recordedDays일',
                      backgroundColor: const Color(0xFFF7FAFF),
                      borderColor: const Color(0xFFDCEBFF),
                      labelColor: const Color(0xFF72829B),
                      valueColor: const Color(0xFF2D4F86),
                      accentColor: const Color(0xFF3B82F6),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 10,
                    child: _buildStatMiniChip(
                      label: '하루 평균',
                      value: '${avgPerDay.toStringAsFixed(1)}회',
                      backgroundColor: const Color(0xFFF7F9FC),
                      borderColor: const Color(0xFFE4EAF3),
                      labelColor: const Color(0xFF748094),
                      valueColor: const Color(0xFF1F2937),
                      accentColor: const Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 12,
                    child: _buildStatMiniChip(
                      label: '기록/완료 요리',
                      valueWidget: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '$totalMeals개',
                                style: const TextStyle(color: Color(0xFFF97316)),
                              ),
                              const TextSpan(
                                text: ' / ',
                                style: TextStyle(color: Color(0xFF98A2B3)),
                              ),
                              TextSpan(
                                text: '$completedMeals개',
                                style: const TextStyle(color: Color(0xFF16A34A)),
                              ),
                            ],
                          ),
                          softWrap: false,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            height: 1,
                            letterSpacing: -0.25,
                          ),
                        ),
                      ),
                      backgroundColor: const Color(0xFFFFF8F3),
                      borderColor: const Color(0xFFFFE4CF),
                      labelColor: const Color(0xFF896B4E),
                      accentColor: const Color(0xFFF97316),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildStatsSectionCard(
          title: '끼니 밸런스',
          child: totalMeals == 0
              ? const Text(
                  '끼니별 기록이 쌓이면 균형을 보여드려요.',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                )
              : Column(
                  children: [
                    for (final mealTime in _mealOrder)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildMealBalanceRow(
                          label: _mealLabels[mealTime] ?? mealTime,
                          count: mealTimeCounts[mealTime] ?? 0,
                          ratio: maxMealCount == 0
                              ? 0
                              : (mealTimeCounts[mealTime] ?? 0) / maxMealCount,
                          color: _mealBarColor(mealTime),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _buildStatsSectionCard(
          title: '자주 먹은 메뉴 TOP',
          child: topMenus.isEmpty
              ? const Text(
                  '아직 이번 달에 등록된 메뉴가 없어요.',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < topMenus.take(3).length; i++)
                      Padding(
                        padding: EdgeInsets.only(bottom: i == 2 ? 0 : 8),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: i == 0
                                    ? const Color(0xFFFFF1E6)
                                    : const Color(0xFFF2F4F7),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: i == 0 ? _orange : _inkSub,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                topMenus[i].key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: _ink,
                                ),
                              ),
                            ),
                            Text(
                              '${topMenus[i].value}회',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _buildStatsSectionCard(
          title: '요리GO 인사이트',
          subtitle: '이번 달 식단 흐름을 한눈에',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: insights.map((text) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE9EEF5)),
                ),
                child: Text(
                  text,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _inkSub,
                    height: 1.35,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsSectionCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFEDF1F6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: _ink,
              letterSpacing: -0.2,
            ),
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _muted,
              ),
            ),
            const SizedBox(height: 14),
          ] else
            const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildStatMiniChip({
    required String label,
    String? value,
    Widget? valueWidget,
    Color backgroundColor = const Color(0xFFFFFFFF),
    Color borderColor = const Color(0xFFFFE6D3),
    Color labelColor = _muted,
    Color valueColor = _ink,
    Color? accentColor,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 84),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            backgroundColor,
            Color.alphaBlend(Colors.white.withValues(alpha: 0.42), backgroundColor),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: (accentColor ?? borderColor).withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 3,
            decoration: BoxDecoration(
              color: (accentColor ?? valueColor).withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: labelColor,
              letterSpacing: -0.15,
            ),
          ),
          const SizedBox(height: 7),
          valueWidget ??
              Text(
                value ?? '-',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: valueColor,
                  height: 1,
                  letterSpacing: -0.25,
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildMealBalanceRow({
    required String label,
    required int count,
    required double ratio,
    required Color color,
  }) {
    final widthFactor = ratio.clamp(0.0, 1.0).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: _inkSub,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 13,
            decoration: BoxDecoration(
              color: const Color(0xFFE9EDF3),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: widthFactor,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 32,
          child: Text(
            '$count회',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: _muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeekdayLabels() {
    const labels = ['일', '월', '화', '수', '목', '금', '토'];
    return Row(
      children: List.generate(7, (i) {
        final color = i == 0 ? _sundayAccent : _muted;
        return Expanded(
          child: Center(
            child: Text(
              labels[i],
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                height: 1.2,
                color: color,
              ),
            ),
          ),
        );
      }),
    );
  }

  static const double _gridRowHeight = 50.0;
  static const double _gridRowGap = 4.0;
  /// 접힌 주간 뷰에서 today 테두리(1.4)가 ClipRect에 잘리지 않도록 여유.
  static const double _gridClipPad = 3.0;

  Widget _buildGrid() {
    final dates = _visibleDates;
    final weeks = <List<DateTime>>[];
    for (var i = 0; i < dates.length; i += 7) {
      weeks.add(dates.sublist(i, i + 7));
    }
    const rowStride = _gridRowHeight + _gridRowGap;
    final fullHeight =
        weeks.length * _gridRowHeight + (weeks.length - 1) * _gridRowGap;
    const collapsedHeight = _gridRowHeight;
    _calDragTravel = (fullHeight - collapsedHeight).clamp(1.0, double.infinity);

    final selIdx = _selectedWeekIndex(weeks);
    final selTop = selIdx * rowStride;

    final fullColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var w = 0; w < weeks.length; w++) ...[
          if (w > 0) const SizedBox(height: _gridRowGap),
          SizedBox(
            height: _gridRowHeight,
            child: Row(
              children: weeks[w]
                  .map((d) => Expanded(child: _buildDayCell(d)))
                  .toList(),
            ),
          ),
        ],
      ],
    );

    return AnimatedBuilder(
      animation: _calSheetController,
      builder: (context, _) {
        final v = _calSheetController.value;
        final contentHeight =
            collapsedHeight + (fullHeight - collapsedHeight) * v;
        final translate = -selTop * (1 - v);
        return ClipRect(
          child: SizedBox(
            height: contentHeight + (_gridClipPad * 2),
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: translate + _gridClipPad,
                  left: 0,
                  right: 0,
                  child: fullColumn,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  int _selectedWeekIndex(List<List<DateTime>> weeks) {
    for (var i = 0; i < weeks.length; i++) {
      if (weeks[i].any((d) => _isSameDay(d, _selectedDate))) return i;
    }
    for (var i = 0; i < weeks.length; i++) {
      if (weeks[i].any((d) => _isSameDay(d, _today()))) return i;
    }
    return 0;
  }

  void _setCalExpanded(bool expanded, {double velocity = 0}) {
    final target = expanded ? 1.0 : 0.0;
    if ((_calSheetController.value - target).abs() < 0.001) {
      _calSheetController.value = target;
      return;
    }
    final spring = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 760,
      ratio: 0.92,
    );
    _calSheetController.animateWith(
      SpringSimulation(spring, _calSheetController.value, target, velocity),
    );
  }

  void _onCalDragUpdate(double deltaY) {
    if (!_calDragging) _calDragging = true;
    final next = (_calSheetController.value + deltaY / _calDragTravel).clamp(
      0.0,
      1.0,
    );
    _calSheetController.value = next;
  }

  void _onCalDragEnd(double primaryVelocity) {
    _calDragging = false;
    final shouldExpand = primaryVelocity.abs() > 220
        ? primaryVelocity > 0
        : _calSheetController.value >= _calSnapThreshold;
    _setCalExpanded(shouldExpand, velocity: primaryVelocity / _calDragTravel);
  }

  /// 핸들에서만 세로 드래그로 캘린더 펼침/접기.
  /// 일자 상세는 스크롤 가능해야 해서 드래그 가로채기를 두지 않는다.
  Widget _buildCollapseDragArea() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) {
            _calDragging = true;
            _calSheetController.stop();
          },
          onVerticalDragUpdate: (details) => _onCalDragUpdate(details.delta.dy),
          onVerticalDragEnd: (details) =>
              _onCalDragEnd(details.primaryVelocity ?? 0),
          onVerticalDragCancel: () {
            _calDragging = false;
            _setCalExpanded(_calSheetController.value >= _calSnapThreshold);
          },
          child: _buildCollapseHandle(),
        ),
        const SizedBox(height: 14),
        // 좌우로 손가락을 따라 부드럽게 슬라이드되며 인접 날짜로 넘어간다.
        Expanded(
          child: PageView.builder(
            controller: _dayPageController,
            onPageChanged: _onDayPageChanged,
            physics: const ClampingScrollPhysics(),
            itemBuilder: (context, index) {
              final date = _dateFromPageIndex(index);
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                // FAB(+ 식단 추가하기)에 가리지 않도록 하단 여유
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                child: _buildDayDetail(date),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCollapseHandle() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setCalExpanded(_calSheetController.value < _calSnapThreshold),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Center(
            child: AnimatedBuilder(
              animation: _calSheetController,
              builder: (context, _) {
                final v = _calSheetController.value;
                return Container(
                  width: 36 + (1 - v) * 10,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(999),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, thickness: 1, color: _line),
        ],
      ),
    );
  }

  Widget _buildDayCell(DateTime date) {
    final today = _today();
    final isToday = _isSameDay(date, today);
    final isSelected = _isSameDay(date, _selectedDate);
    final mealTimes = _mealTimesWithItems(date);
    final inMonth = date.month == _displayedMonth.month;

    final numberColor = !inMonth
        ? const Color(0xFFD1D5DB)
        : isToday
        ? _orange
        : const Color(0xFF6B7280);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectDate(date),
      child: Container(
        height: 50,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(
          color: isSelected
              ? _selectedFill
              : inMonth
              ? _cellEmpty
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isToday
              ? Border.all(color: _orange, width: 1.4)
              : null,
        ),
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: numberColor,
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 5,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: mealTimes
                    .take(3)
                    .map(
                      (mt) => Container(
                        width: 3.5,
                        height: 3.5,
                        margin: const EdgeInsets.symmetric(horizontal: 1.2),
                        decoration: BoxDecoration(
                          color: _mealBarColor(mt),
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayDetail([DateTime? forDate]) {
    final date = forDate ?? _selectedDate;
    final mealTimes = _mealTimesWithItems(date);
    final hasMeals = mealTimes.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${date.month}월 ${date.day}일',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: _ink,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _weekdayLong(date),
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _muted,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        if (hasMeals) ...[
          const SizedBox(height: 14),
          ...mealTimes.map((mt) => _buildAgendaGroup(date, mt)),
        ] else ...[
          const SizedBox(height: 18),
          _buildAutoPlanEmptyCta(date),
        ],
      ],
    );
  }

  Widget _buildAutoPlanEmptyCta(DateTime date) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openAutoMealPlanSheet(startDate: date)),
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _line),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _orangeSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 20,
                  color: _orange,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '맞춤 식단 짜기',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: _ink,
                            ),
                          ),
                        ),
                        SizedBox(width: 6),
                        _BetaBadge(),
                      ],
                    ),
                    SizedBox(height: 3),
                    Text(
                      '냉장고·기록 기반 자동 채우기',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: _muted,
                        letterSpacing: -0.2,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: _muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAgendaGroup(DateTime date, String mealTime) {
    final items = _mealItems(date, mealTime);
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            _buildAgendaRow(
              date,
              items[i],
              label: i == 0 ? (_mealLabels[mealTime] ?? mealTime) : null,
            ),
        ],
      ),
    );
  }

  Widget _buildAgendaRow(
    DateTime date,
    _MealItem item, {
    String? label,
  }) {
    final showMealPill = label != null;
    final row = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.isMemo
            ? null
            : () => unawaited(_openRecipeDetailForItem(item)),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _mealPillWidth,
                child: showMealPill
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: _buildMealTimePill(item.mealTime),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                              letterSpacing: -0.2,
                              color: item.completed
                                  ? _muted
                                  : const Color(0xFF1E2939),
                              decoration: item.completed
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: _muted,
                            ),
                          ),
                        ),
                        if (item.completed)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.check_circle_rounded,
                              size: 16,
                              color: Color(0xFF16A34A),
                            ),
                          ),
                        _buildRowMenu(date, item),
                      ],
                    ),
                    _buildInlineMealActions(item),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (item.isMemo) return row;
    return RecipeIdSignalImpression(
      screen: 'meal_calendar',
      recipeId: item.recipeId,
      sectionId: 'meal_${item.mealTime}',
      position: item.slotIndex,
      contentType: 'meal_plan',
      child: row,
    );
  }

  Widget _buildRowMenu(DateTime date, _MealItem item) {
    return Builder(
      builder: (iconContext) => SizedBox(
        width: 24,
        height: 24,
        child: InkResponse(
          onTap: () => _showRowMenu(date, item, iconContext),
          radius: 16,
          child: const Center(
            child: Icon(Icons.more_vert_rounded, size: 18, color: _muted),
          ),
        ),
      ),
    );
  }

  Future<void> _showRowMenu(
    DateTime date,
    _MealItem item,
    BuildContext iconContext,
  ) async {
    final entries = <_RowMenuEntry>[
      const _RowMenuEntry('delete', Icons.delete_rounded, '삭제', danger: true),
    ];

    final iconBox = iconContext.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (iconBox == null || overlayBox == null) return;
    final topLeft = iconBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = iconBox.size;
    final screenW = overlayBox.size.width;
    final anchorTop = topLeft.dy + size.height + 6;
    final anchorRight = screenW - (topLeft.dx + size.width);

    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '메뉴',
      barrierColor: Colors.black.withValues(alpha: 0.04),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, __) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Stack(
          children: [
            Positioned(
              top: anchorTop,
              right: anchorRight,
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
                  alignment: Alignment.topRight,
                  child: _rowMenuCard(ctx, entries),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!mounted || result == null) return;
    if (result == 'delete') {
      _deleteMeal(date, item);
    }
  }

  Future<void> _openRecipeDetailForItem(_MealItem item) async {
    if (item.isMemo) return;
    final recipeId = item.recipeId.trim();
    if (recipeId.isNotEmpty) {
      AnalyticsService().noteRecipeOpenSource(
        recipeId: recipeId,
        screen: 'meal_calendar',
        sectionId: 'meal_${item.mealTime}',
      );
    }
    final action = _actionRecipeFor(item);
    if (widget.onOpenRecipeDetail != null) {
      widget.onOpenRecipeDetail!(action);
      return;
    }
    if (recipeId.isEmpty) return;
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (!mounted || parseResponse == null) return;
    Navigator.pushNamed(
      context,
      '/recipe-detail',
      arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
    );
  }

  Future<void> _markItemStarted(_MealItem item) async {
    await _mealPlanService.markMealSlotStarted(
      date: item.date,
      mealTime: item.mealTime,
      slotIndex: item.slotIndex,
    );
  }

  Future<void> _markItemCompleted(_MealItem item) async {
    await _mealPlanService.markMealSlotCompleted(
      date: item.date,
      mealTime: item.mealTime,
      slotIndex: item.slotIndex,
    );
  }

  Future<void> _startCookingForItem(_MealItem item) async {
    if (item.isMemo) return;
    Haptics.light();
    final action = _actionRecipeFor(item);
    if (widget.onStartCooking != null) {
      widget.onStartCooking!(action);
      return;
    }

    final recipeId = item.recipeId.trim();
    if (recipeId.isEmpty) return;
    unawaited(_markItemStarted(item));
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (!mounted || parseResponse == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CookingInstructionSheet(
          recipe: parseResponse.recipe,
          recipeId: recipeId,
          source: parseResponse.source,
        ),
      ),
    );
  }

  Future<void> _leaveReviewForItem(_MealItem item) async {
    if (item.completed) return;
    Haptics.light();
    if (item.isMemo) {
      final submitted = await showProgressiveRecipeReviewPopup(
        context,
        recipeId: '',
        recipeTitle: item.title,
        creatorUsername: '',
        platform: 'manual',
        servings: 1,
        fromCookingFlow: false,
        isFreeform: true,
      );
      if (submitted == true) {
        await _markItemCompleted(item);
        if (mounted) _snack('후기를 남겼어요');
      }
      return;
    }

    final action = _actionRecipeFor(item);
    if (widget.onCookingComplete != null) {
      widget.onCookingComplete!(
        context,
        action,
        _fridgeData,
        Theme.of(context).brightness,
      );
      return;
    }

    final recipeId = item.recipeId.trim();
    if (recipeId.isEmpty) return;
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (!mounted || parseResponse == null) return;

    final source = parseResponse.source;
    final recipeModel = parseResponse.recipe;
    String creatorUsername = '@ChefAntoine';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    if (uploader.isNotEmpty) {
      creatorUsername = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creatorUsername = channel.startsWith('@') ? channel : '@$channel';
    }

    final submitted = await showProgressiveRecipeReviewPopup(
      context,
      recipeId: recipeId,
      recipeTitle: recipeModel.name ?? item.title,
      creatorUsername: creatorUsername,
      platform: source['platform'] as String? ?? '',
      thumbnailUrl: source['thumbnail'] as String?,
      servings: recipeModel.servings ?? 2,
    );
    if (submitted == true) {
      await _markItemCompleted(item);
      if (mounted) _snack('후기를 남겼어요');
    }
  }

  Widget _rowMenuCard(BuildContext ctx, List<_RowMenuEntry> entries) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 184,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, color: _line),
              _rowMenuTile(ctx, entries[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rowMenuTile(BuildContext ctx, _RowMenuEntry e) {
    final color = e.danger ? const Color(0xFFEF4444) : _ink;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(ctx, e.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Icon(
                e.icon,
                size: 18,
                color: e.danger ? const Color(0xFFEF4444) : _orange,
              ),
              const SizedBox(width: 11),
              Text(
                e.label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- actions ------------------------------------------------------------

  Future<void> _deleteMeal(DateTime date, _MealItem item) async {
    try {
      await _mealPlanService.removeMealFromDate(
        date: date,
        mealTime: item.mealTime,
        recipeId: item.recipeId,
        slotIndex: item.slotIndex,
      );
      _snack('식단에서 삭제했어요');
    } catch (e) {
      _snack('삭제 중 오류가 발생했어요', error: true);
    }
  }

  Future<void> _showAddMenu() async {
    if (_authService.currentUser == null) {
      _snack('로그인이 필요해요', error: true);
      return;
    }
    setState(() => _addMenuOpen = true);
    final picked = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '식단 추가',
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, __) =>
          _AddMenuCard(onPick: (tab) => Navigator.pop(ctx, tab)),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Stack(
          children: [
            Positioned(
              right: 16,
              bottom: MediaQuery.of(ctx).padding.bottom + 16,
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.85, end: 1).animate(curved),
                  alignment: Alignment.bottomRight,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
    if (mounted) setState(() => _addMenuOpen = false);
    if (picked == null) return;
    if (picked == 2) {
      unawaited(_openAutoMealPlanSheet());
      return;
    }
    _openAddMealSheet(initialTab: picked);
  }

  Future<void> _openAutoMealPlanSheet({DateTime? startDate}) async {
    if (_authService.currentUser == null) {
      _snack('로그인이 필요해요', error: true);
      return;
    }
    final savedCount = await AutoMealPlanSheet.show(
      context: context,
      startDate: startDate ?? _today(),
      existingPlans: Map<String, Map<String, dynamic>>.from(_mealPlans),
      fridgeRecipes: _fridgeRecipes,
      initialDays: 7,
    );
    if (!mounted) return;
    if (savedCount != null && savedCount > 0) {
      _snack('맞춤 식단 $savedCount개를 추가했어요');
    }
  }

  void _openAddMealSheet({int initialTab = 0, DateTime? date}) {
    if (_authService.currentUser == null) {
      _snack('로그인이 필요해요', error: true);
      return;
    }
    final targetDate = date ?? _selectedDate;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AddMealSheet(
        date: targetDate,
        weekdayLong: _weekdayLong(targetDate),
        existingMealTimes: _mealTimesWithItems(targetDate),
        mealPlanService: _mealPlanService,
        recipeService: _recipeService,
        initialTab: initialTab,
      ),
    );
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    showAppSnackBar(
      context,
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : const Color(0xFF16A34A),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}

class _RowMenuEntry {
  const _RowMenuEntry(this.value, this.icon, this.label, {this.danger = false});

  final String value;
  final IconData icon;
  final String label;
  final bool danger;
}

class _MealItem {
  const _MealItem({
    required this.date,
    required this.recipeId,
    required this.mealTime,
    required this.slotIndex,
    required this.title,
    required this.completed,
    required this.isMemo,
  });

  final DateTime date;
  final String recipeId;
  final String mealTime;
  final int slotIndex;
  final String title;
  final bool completed;
  final bool isMemo;
}

class _MonthMealSection {
  const _MonthMealSection({required this.date, required this.items});

  final DateTime date;
  final List<_MealItem> items;
}

class _AddMealFabButton extends StatelessWidget {
  const _AddMealFabButton({
    required this.visible,
    required this.onTap,
  });

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 280),
        curve: visible
            ? const Cubic(0.22, 1, 0.36, 1)
            : Curves.easeInCubic,
        offset: visible ? Offset.zero : const Offset(0, 0.28),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 280),
          curve: visible
              ? const Cubic(0.22, 1, 0.36, 1)
              : Curves.easeInCubic,
          scale: visible ? 1 : 0.92,
          child: AnimatedOpacity(
            duration: Duration(milliseconds: visible ? 240 : 160),
            curve: Curves.easeOutCubic,
            opacity: visible ? 1 : 0,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: _orange.withValues(alpha: visible ? 0.22 : 0),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onTap,
                    child: Ink(
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: _orange,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_rounded,
                            size: 22,
                            color: Colors.white,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '식단 추가하기',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightHeaderButton extends StatelessWidget {
  const _InsightHeaderButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFFF2F3F5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.insights_rounded,
            size: 18,
            color: _ink,
          ),
        ),
      ),
    );
  }
}

class _MonthNavClusterButton extends StatelessWidget {
  const _MonthNavClusterButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFF2F3F5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: _ink),
        ),
      ),
    );
  }
}

/// Compact year + 12-month grid for quick month jump.
class _MonthPickerSheet extends StatefulWidget {
  const _MonthPickerSheet({required this.initialMonth});

  final DateTime initialMonth;

  @override
  State<_MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<_MonthPickerSheet> {
  late int _year;

  @override
  void initState() {
    super.initState();
    _year = widget.initialMonth.year;
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final selected = widget.initialMonth;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD9DEE7),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _MonthNavClusterButton(
                    icon: Icons.chevron_left_rounded,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _year -= 1);
                    },
                  ),
                  Expanded(
                    child: Text(
                      '$_year년',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: _ink,
                      ),
                    ),
                  ),
                  _MonthNavClusterButton(
                    icon: Icons.chevron_right_rounded,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _year += 1);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 12,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.55,
                ),
                itemBuilder: (context, index) {
                  final m = index + 1;
                  final isSelected =
                      selected.year == _year && selected.month == m;
                  final isToday = today.year == _year && today.month == m;
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        Haptics.selection();
                        Navigator.pop(context, DateTime(_year, m, 1));
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _orange
                              : (isToday ? _orangeSoft : const Color(0xFFF7F8FA)),
                          borderRadius: BorderRadius.circular(14),
                          border: isToday && !isSelected
                              ? Border.all(color: _orange.withValues(alpha: 0.45))
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            '$m월',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: isSelected ? Colors.white : _ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMealActionChip extends StatelessWidget {
  const _InlineMealActionChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F5F7),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: _inkSub,
            ),
          ),
        ),
      ),
    );
  }
}

class _AddMenuCard extends StatelessWidget {
  const _AddMenuCard({required this.onPick});

  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 244,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _line, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row(
              icon: Icons.auto_awesome_rounded,
              title: '맞춤 식단 짜기',
              subtitle: '냉장고·기록 기반 자동 채우기',
              showBeta: true,
              onTap: () => onPick(2),
            ),
            const Divider(height: 1, thickness: 1, color: _line),
            _row(
              icon: Icons.menu_book_rounded,
              title: '레시피북에서 추가',
              subtitle: '저장한 레시피로 추가',
              onTap: () => onPick(0),
            ),
            const Divider(height: 1, thickness: 1, color: _line),
            _row(
              icon: Icons.edit_rounded,
              title: '직접 추가',
              subtitle: '메뉴 이름만 입력',
              onTap: () => onPick(1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool showBeta = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(icon, size: 19, color: _orange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                              color: _ink,
                            ),
                          ),
                        ),
                        if (showBeta) ...[
                          const SizedBox(width: 6),
                          const _BetaBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: _muted,
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

class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: const Color(0xFF111827).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFF111827).withValues(alpha: 0.10),
        ),
      ),
      child: const Text(
        'Beta',
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.35,
          height: 1.1,
          color: Color(0xFF6B7280),
        ),
      ),
    );
  }
}

// ===========================================================================
// Add-meal bottom sheet: "무엇을 추가할까요?"  (끼니 선택 → 내 레시피북 / 직접 입력하기)
// ===========================================================================

class _AddMealSheet extends StatefulWidget {
  const _AddMealSheet({
    required this.date,
    required this.weekdayLong,
    required this.existingMealTimes,
    required this.mealPlanService,
    required this.recipeService,
    this.initialTab = 0,
  });

  final DateTime date;
  final String weekdayLong;
  final List<String> existingMealTimes;
  final MealPlanService mealPlanService;
  final RecipeService recipeService;
  final int initialTab;

  @override
  State<_AddMealSheet> createState() => _AddMealSheetState();
}

class _AddMealSheetState extends State<_AddMealSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final Future<List<Map<String, dynamic>>> _recipesFuture;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _memoController = TextEditingController();
  String _query = '';
  late String _mealTime;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _mealTime = _defaultMealTime();
    _recipesFuture = widget.recipeService
        .getSavedRecipesForExplore(limit: 100)
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => const <Map<String, dynamic>>[],
        );
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  String _defaultMealTime() {
    final h = DateTime.now().hour;
    if (h < 10) return 'breakfast';
    if (h < 16) return 'lunch';
    return 'dinner';
  }

  Future<void> _addRecipe(String recipeId, String title) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await widget.mealPlanService.addMealToDate(
        date: widget.date,
        mealTime: _mealTime,
        recipeId: recipeId,
        recipeTitle: title,
      );
      if (!mounted) return;
      Navigator.pop(context);
      _toast('${_mealLabels[_mealTime]}에 추가했어요');
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        _toast('추가 중 오류가 발생했어요', error: true);
      }
    }
  }

  Future<void> _addMemo() async {
    final text = _memoController.text.trim();
    if (text.isEmpty) {
      _toast('메뉴 이름을 입력해주세요', error: true);
      return;
    }
    final id = 'memo_${DateTime.now().millisecondsSinceEpoch}';
    await _addRecipe(id, text);
  }

  void _toast(String message, {bool error = false}) {
    showAppSnackBar(
      context,
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : const Color(0xFF16A34A),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.86;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: height,
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
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '어떤 메뉴를 추가할까요?',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.date.month}월 ${widget.date.day}일 ${widget.weekdayLong}',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildMealTimeSelector(),
            const SizedBox(height: 14),
            _buildSheetTabs(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildRecipeBookTab(), _buildDirectInputTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetTabs() {
    const labels = ['내 레시피북', '직접 추가하기'];
    const activeStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: _ink,
      letterSpacing: -0.28,
    );
    const inactiveStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: _muted,
      letterSpacing: -0.28,
    );

    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        final selectedIndex = _tabController.index;
        return SizedBox(
          height: 42,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tabWidth = constraints.maxWidth / labels.length;
              final indicatorWidth = tabWidth * 0.42;
              final indicatorLeft =
                  (selectedIndex * tabWidth) + ((tabWidth - indicatorWidth) / 2);

              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(height: 1, color: _line),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < labels.length; i++)
                        Expanded(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                if (_tabController.index == i) return;
                                Haptics.selection();
                                _tabController.animateTo(i);
                              },
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.transparent,
                              overlayColor:
                                  MaterialStateProperty.all(Colors.transparent),
                              child: Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutCubic,
                                  style: selectedIndex == i
                                      ? activeStyle
                                      : inactiveStyle,
                                  child: Text(labels[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: indicatorLeft,
                    bottom: 0,
                    child: Container(
                      width: indicatorWidth,
                      height: 2,
                      decoration: BoxDecoration(
                        color: _orange,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildMealTimeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: _mealOrder.map((mt) {
          final selected = mt == _mealTime;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: mt == 'dinner' ? 0 : 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Haptics.selection();
                    setState(() => _mealTime = mt);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? _orange : const Color(0xFFEDEFF2),
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      _mealLabels[mt]!,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: selected ? _orange : _inkSub,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRecipeBookTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _line),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded, size: 20, color: _muted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    cursorColor: _orange,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: '레시피 검색',
                      hintStyle: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _recipesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _RecipeBookLoading();
              }
              final all = (snapshot.data ?? [])
                  .where(isEligibleSavedRecipeForMealPlan)
                  .toList();
              final filtered = _query.isEmpty
                  ? all
                  : all.where((r) {
                      final title = _recipeTitle(r).toLowerCase();
                      return title.contains(_query);
                    }).toList();

              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    _query.isEmpty ? '저장한 레시피가 없어요' : '검색 결과가 없어요',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _muted,
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final recipe = filtered[index];
                  final id = recipe['id'] as String? ?? '';
                  final title = _recipeTitle(recipe);
                  final thumb = RecipeThumbnailResolver.resolve(recipe);
                  final category = _recipeCategory(recipe);
                  return _RecipeBookRow(
                    title: title,
                    thumb: thumb,
                    category: category,
                    onTap: (id.isEmpty || _adding)
                        ? null
                        : () => _addRecipe(id, title),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDirectInputTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      children: [
        const Text(
          '메뉴 이름',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: _inkSub,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _line),
          ),
          child: TextField(
            controller: _memoController,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _addMemo(),
            cursorColor: _orange,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
            decoration: const InputDecoration(
              isCollapsed: true,
              contentPadding: EdgeInsets.symmetric(vertical: 14),
              border: InputBorder.none,
              hintText: '예) 김치찌개, 외식 - 삼겹살',
              hintStyle: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: _muted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 14, color: _muted),
            SizedBox(width: 5),
            Expanded(
              child: Text(
                '메뉴를 간편하게 적고 계획해 보세요',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _muted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _adding ? null : _addMemo,
            child: Ink(
              height: 50,
              decoration: BoxDecoration(
                color: _orange,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(
                  '${_mealLabels[_mealTime]}에 추가하기',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _recipeTitle(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    return recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
  }

  String _recipeCategory(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final c =
        (recipe['category'] as String?) ??
        (recipeData['category'] as String?) ??
        '';
    return c.trim();
  }
}

class _RecipeBookRow extends StatelessWidget {
  const _RecipeBookRow({
    required this.title,
    required this.thumb,
    required this.category,
    required this.onTap,
  });

  final String title;
  final String thumb;
  final String category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: thumb.isNotEmpty
                        ? AppNetworkImage(
                            imageUrl: thumb,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            memCacheWidth: 96,
                            memCacheHeight: 96,
                          )
                        : Container(
                            color: _cellEmpty,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.restaurant_rounded,
                              size: 20,
                              color: _muted,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.25,
                          color: _ink,
                        ),
                      ),
                      if (category.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          category,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _orange,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: Colors.white,
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

// ===========================================================================
// Shimmer loading for the recipe-book tab (same sliding diagonal style used
// in cart/home/review loaders).
// ===========================================================================

class _RecipeBookLoading extends StatelessWidget {
  const _RecipeBookLoading();

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _calShimmerGradient,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, __) => const _ShimmerLoading(
          isLoading: true,
          child: _RecipeBookSkeletonCard(),
        ),
      ),
    );
  }
}

class _RecipeBookSkeletonCard extends StatelessWidget {
  const _RecipeBookSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _calShimmerSkeletonColor,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _calShimmerSkeletonColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 72,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _calShimmerSkeletonColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _calShimmerSkeletonColor,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ],
      ),
    );
  }
}

const _calShimmerSkeletonColor = Color(0xFFEBECF0);

const _calShimmerGradient = LinearGradient(
  colors: [
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
    Color(0xFFF4F5F7),
    Color(0xFFEFEFF2),
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
  ],
  stops: [0.0, 0.44, 0.48, 0.52, 0.56, 1.0],
  begin: Alignment(-1.0, -1.0),
  end: Alignment(1.0, 1.0),
  tileMode: TileMode.clamp,
);

class _SlidingDiagonalGradientTransform extends GradientTransform {
  const _SlidingDiagonalGradientTransform({required this.slidePercent});
  final double slidePercent;
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * slidePercent,
      bounds.height * slidePercent,
      0.0,
    );
  }
}

class _ShimmerScope extends StatefulWidget {
  static _ShimmerScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ShimmerScopeState>();
  const _ShimmerScope({required this.linearGradient, this.child});
  final LinearGradient linearGradient;
  final Widget? child;
  @override
  _ShimmerScopeState createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<_ShimmerScope>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController.unbounded(vsync: this)
      ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1400));
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
    colors: widget.linearGradient.colors,
    stops: widget.linearGradient.stops,
    begin: widget.linearGradient.begin,
    end: widget.linearGradient.end,
    transform: _SlidingDiagonalGradientTransform(
      slidePercent: _shimmerController.value,
    ),
  );
  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;

  Listenable get shimmerChanges => _shimmerController;
  @override
  Widget build(BuildContext context) =>
      widget.child ?? const SizedBox.shrink();
}

class _ShimmerLoading extends StatefulWidget {
  const _ShimmerLoading({required this.isLoading, required this.child});
  final bool isLoading;
  final Widget child;
  @override
  State<_ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<_ShimmerLoading> {
  Listenable? _shimmerChanges;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shimmerChanges?.removeListener(_onShimmerChange);
    _shimmerChanges = _ShimmerScope.of(context)?.shimmerChanges;
    _shimmerChanges?.addListener(_onShimmerChange);
  }

  @override
  void dispose() {
    _shimmerChanges?.removeListener(_onShimmerChange);
    super.dispose();
  }

  void _onShimmerChange() {
    if (widget.isLoading && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;
    final shimmer = _ShimmerScope.of(context);
    if (shimmer == null || !shimmer.isSized) return widget.child;
    final gradient = shimmer.gradient;
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return widget.child;
    final childBounds = Rect.fromLTWH(0, 0, ro.size.width, ro.size.height);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => gradient.createShader(childBounds),
      child: widget.child,
    );
  }
}
