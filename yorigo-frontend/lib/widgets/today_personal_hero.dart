// =============================================================================
// 오늘 뭐 해먹지? — 홈 상단 초개인화 히어로
//
// 시간대 인사 + 닉네임으로 말을 걸고, 오늘 예정된 식단이 있으면 가장 가까운
// 끼니를 "바로 요리"하도록 보여준다. 예정이 없으면 같은 요일에 자주 드셨던
// 메뉴나 요일 테마 멘트로 부드럽게 추천한다.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/meal_plan_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../utils/haptics.dart';
import '../utils/meal_plan_completion_utils.dart';

const Color _heroInk = Color(0xFF111827);
const Color _heroMuted = Color(0xFF8B95A1);

const Map<String, String> _mealLabels = {
  'breakfast': '아침',
  'lunch': '점심',
  'dinner': '저녁',
};

/// 홈 상단에 표시되는 초개인화 한 끼 추천 카드.
class TodayPersonalHero extends StatefulWidget {
  const TodayPersonalHero({
    super.key,
    required this.mealPlanService,
    required this.recipeService,
    required this.userService,
    required this.authService,
    required this.onOpenRecipe,
    required this.onOpenCalendar,
  });

  final MealPlanService mealPlanService;
  final RecipeService recipeService;
  final UserService userService;
  final AuthService authService;

  /// 레시피 상세로 이동 (요리 시작하기 진입점).
  final ValueChanged<String> onOpenRecipe;

  /// 식단 캘린더 열기 (식단 짜기/다른 메뉴 보기).
  final VoidCallback onOpenCalendar;

  @override
  State<TodayPersonalHero> createState() => _TodayPersonalHeroState();
}

class _TodayPersonalHeroState extends State<TodayPersonalHero>
    with SingleTickerProviderStateMixin {
  _HeroData? _data;
  bool _loading = true;
  int _loadGen = 0;
  StreamSubscription? _authSub;
  StreamSubscription<Map<String, Map<String, dynamic>>>? _todayPlanSub;
  late final AnimationController _nameShimmerController;

  @override
  void initState() {
    super.initState();
    _nameShimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat();
    _load();
    _subscribeTodayPlan();
    _authSub = widget.authService.authStateChanges.listen((user) {
      if (!mounted) return;
      _subscribeTodayPlan();
      _load();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _todayPlanSub?.cancel();
    _nameShimmerController.dispose();
    super.dispose();
  }

  void _subscribeTodayPlan() {
    _todayPlanSub?.cancel();
    _todayPlanSub = null;
    if (widget.authService.currentUser == null) return;

    _todayPlanSub = widget.mealPlanService
        .getMealPlansForDateRange(_today, _today)
        .listen((_) {
          if (mounted) _load();
        });
  }

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// 현재 시간대 인사말 + 추천용 슬롯 우선순위.
  ({
    String greeting,
    List<String> slotPriority,
    String? primaryMealLabel,
    String sectionKey,
  })
  _timeContext() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 10) {
      return (
        greeting: '좋은 아침이에요',
        slotPriority: const ['breakfast', 'lunch'],
        primaryMealLabel: null,
        sectionKey: 'moment_morning',
      );
    } else if (hour >= 10 && hour < 14) {
      return (
        greeting: '즐거운 점심시간이에요',
        slotPriority: const ['lunch', 'dinner'],
        primaryMealLabel: null,
        sectionKey: 'moment_solo',
      );
    } else if (hour >= 14 && hour < 17) {
      return (
        greeting: '나른한 오후예요',
        slotPriority: const ['dinner'],
        primaryMealLabel: null,
        sectionKey: _isWeekend ? 'moment_guest' : 'moment_solo',
      );
    } else if (hour >= 17 && hour < 21) {
      return (
        greeting: '좋은 저녁이에요',
        slotPriority: const ['dinner'],
        primaryMealLabel: null,
        sectionKey: 'moment_dinner',
      );
    }
    return (
      greeting: '출출한 밤이에요',
      slotPriority: const ['dinner'],
      primaryMealLabel: '야식',
      sectionKey: 'moment_late_night',
    );
  }

  String _weekdayKo(DateTime d) {
    const names = ['월', '화', '수', '목', '금', '토', '일'];
    return names[d.weekday - 1];
  }

  /// 날짜+시간 블록(3시간 단위)+salt를 기반으로 멘트 variant를 고른다.
  /// 같은 시점에는 안정적으로 보이되, 시간대/요일이 바뀌면 자연스럽게 순환한다.
  int _headlineVariantSeed(String salt) {
    final now = DateTime.now();
    final dayKey = DateTime(now.year, now.month, now.day)
            .millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    final hourBlock = now.hour ~/ 3;
    return (dayKey * 37) + (hourBlock * 11) + salt.hashCode.abs();
  }

  String _pickHeadlineVariant(List<String> options, {required String salt}) {
    if (options.isEmpty) return '';
    final seed = _headlineVariantSeed(salt);
    return options[seed % options.length];
  }

  bool get _isLateNight {
    final hour = DateTime.now().hour;
    return hour >= 21 || hour < 4;
  }

  bool get _isWeekend {
    final weekday = DateTime.now().weekday;
    return weekday == DateTime.friday ||
        weekday == DateTime.saturday ||
        weekday == DateTime.sunday;
  }

  String _plannedHeadline(_MealPick planned) {
    final weekday = _weekdayKo(_today);
    final mealLabel = planned.mealLabel;
    final title = planned.title;
    if (mealLabel == '야식') {
      return _pickHeadlineVariant(
        [
          '오늘 예정하신 $title,\n가볍게 준비해볼까요?',
          '출출한 밤이에요\n예정하신 $title 어떠세요?',
          '오늘 밤 메뉴로 잡아둔\n$title 준비해볼까요?',
        ],
        salt: 'planned-late-night-$weekday-$title',
      );
    }
    final options = <String>[
      '오늘 $mealLabel은\n$title 어떠세요?',
      '$weekday요일 $mealLabel은\n$title 어떠세요?',
      '오늘의 $mealLabel 메뉴로\n$title 어떠세요?',
      '$weekday요일엔 $mealLabel으로\n$title 어떠세요?',
    ];
    return _pickHeadlineVariant(
      options,
      salt: 'planned-$weekday-$mealLabel-$title',
    );
  }

  String _frequentHeadline(_MealPick frequent, {String? primaryMealLabel}) {
    final weekday = _weekdayKo(_today);
    final title = frequent.title;
    if (primaryMealLabel == '야식') {
      return _pickHeadlineVariant(
        [
          '야식으로\n$title 어떠세요?',
          '금방 생각나는 메뉴로\n$title 어떠세요?',
          '출출한 밤엔\n$title도 좋겠어요',
        ],
        salt: 'frequent-late-night-$weekday-$title',
      );
    }
    final options = <String>[
      '$weekday요일에 자주 드셨던\n$title 어떠세요?',
      '요즘 $weekday요일엔\n$title을 자주 고르셨어요',
      '오늘은 익숙한 메뉴로\n$title 어떠세요?',
      '$weekday요일 루틴 메뉴로\n$title 어떠세요?',
    ];
    return _pickHeadlineVariant(options, salt: 'frequent-$weekday-$title');
  }

  String _contextualRecipeHeadline(
    _MealPick pick, {
    String? primaryMealLabel,
  }) {
    final title = pick.title;
    if (primaryMealLabel == '야식') {
      return _pickHeadlineVariant(
        [
          '야식으로\n$title 어떠세요?',
          '출출한 밤엔\n$title도 좋겠어요',
          '오늘 밤 가볍게\n$title 어떠세요?',
        ],
        salt: 'context-late-night-$title',
      );
    }

    switch (_today.weekday) {
      case DateTime.friday:
        return _pickHeadlineVariant(
          [
            '불금인데, 오늘은\n$title 어떠세요?',
            '한 주 고생 많으셨어요\n$title로 마무리해볼까요?',
            '금요일엔 조금 더 맛있게\n$title 어떠세요?',
          ],
          salt: 'context-friday-$title',
        );
      case DateTime.saturday:
        return _pickHeadlineVariant(
          [
            '여유로운 주말이에요\n$title 어떠세요?',
            '토요일엔 천천히\n$title 만들어볼까요?',
            '주말 분위기에 맞춰\n$title 어떠세요?',
          ],
          salt: 'context-saturday-$title',
        );
      case DateTime.sunday:
        return _pickHeadlineVariant(
          [
            '일요일 마무리로\n$title 어떠세요?',
            '편안한 집밥으로\n$title 만들어볼까요?',
            '내일을 준비하는 오늘\n$title 어떠세요?',
          ],
          salt: 'context-sunday-$title',
        );
      case DateTime.monday:
        return _pickHeadlineVariant(
          [
            '새로운 한 주의 시작엔\n$title 어떠세요?',
            '월요일엔 부담 없이\n$title 만들어볼까요?',
            '한 주 첫 메뉴로\n$title 어떠세요?',
          ],
          salt: 'context-monday-$title',
        );
      case DateTime.tuesday:
        return _pickHeadlineVariant(
          [
            '화요일엔 균형 있게\n$title 어떠세요?',
            '오늘 리듬을 잡아줄\n$title 어떠세요?',
            '차분한 화요일엔\n$title도 좋겠어요',
          ],
          salt: 'context-tuesday-$title',
        );
      case DateTime.wednesday:
        return _pickHeadlineVariant(
          [
            '한 주의 중간엔\n$title 어떠세요?',
            '수요일 기운 채우게\n$title 만들어볼까요?',
            '오늘 한 끼는 든든하게\n$title 어떠세요?',
          ],
          salt: 'context-wednesday-$title',
        );
      case DateTime.thursday:
        return _pickHeadlineVariant(
          [
            '목요일엔 조금 더 든든하게\n$title 어떠세요?',
            '주말 전 힘을 위해\n$title 만들어볼까요?',
            '오늘은 익숙한 집밥처럼\n$title 어떠세요?',
          ],
          salt: 'context-thursday-$title',
        );
      default:
        return '오늘은\n$title 어떠세요?';
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final user = widget.authService.currentUser;
    if (user == null) {
      if (mounted && gen == _loadGen) {
        setState(() {
          _data = null;
          _loading = false;
        });
      }
      return;
    }

    final nickname = await _resolveNickname(user.uid);
    if (!mounted || gen != _loadGen) return;

    final ctx = _timeContext();

    // 1) 오늘 예정된 식단 확인
    final planned = await _resolvePlannedMeal(
      ctx.slotPriority,
      primaryMealLabel: ctx.primaryMealLabel,
    );
    if (!mounted || gen != _loadGen) return;
    if (planned != null) {
      setState(() {
        _data = _HeroData(
          nickname: nickname,
          greeting: ctx.greeting,
          headline: _plannedHeadline(planned),
          recipeId: planned.recipeId,
        );
        _loading = false;
      });
      return;
    }

    // 2) 같은 요일에 자주 드셨던 메뉴 추천
    final frequent = await _resolveWeekdayFrequentMeal([
      ctx.slotPriority.first,
    ]);
    if (!mounted || gen != _loadGen) return;
    if (frequent != null) {
      setState(() {
        _data = _HeroData(
          nickname: nickname,
          greeting: ctx.greeting,
          headline: _frequentHeadline(
            frequent,
            primaryMealLabel: ctx.primaryMealLabel,
          ),
          recipeId: frequent.recipeId,
        );
        _loading = false;
      });
      return;
    }

    // 3) 현재 시간대/요일에 맞는 홈 큐레이션 레시피 추천
    final contextual = await _resolveContextualRecipe(ctx.sectionKey);
    if (!mounted || gen != _loadGen) return;
    if (contextual != null) {
      setState(() {
        _data = _HeroData(
          nickname: nickname,
          greeting: ctx.greeting,
          headline: _contextualRecipeHeadline(
            contextual,
            primaryMealLabel: ctx.primaryMealLabel,
          ),
          recipeId: contextual.recipeId,
        );
        _loading = false;
      });
      return;
    }

    // 4) 요일 테마 멘트 (예정·기록·추천 레시피 모두 없을 때)
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _data = _HeroData(
        nickname: nickname,
        greeting: ctx.greeting,
        headline: _themedHeadline(),
        recipeId: null,
      );
      _loading = false;
    });
  }

  Future<String> _resolveNickname(String uid) async {
    try {
      final doc = await widget.userService.getUserDocument(uid);
      final data = doc.data() as Map<String, dynamic>?;
      final name = (data?['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    final displayName = widget.authService.currentUser?.displayName?.trim();
    return displayName ?? '';
  }

  Future<_MealPick?> _resolvePlannedMeal(
    List<String> preferredSlots, {
    String? primaryMealLabel,
  }) async {
    try {
      final plan = await widget.mealPlanService.getMealPlanForDate(_today);
      if (plan == null) return null;
      final meals = plan['meals'] as Map<String, dynamic>? ?? {};
      final titles = plan['recipeTitles'] as Map<String, dynamic>? ?? {};

      // 시간대별 우선순위 슬롯만 확인해 어색한 끼니(예: 심야 점심 추천)를 방지한다.
      for (var i = 0; i < preferredSlots.length; i++) {
        final slot = preferredSlots[i];
        final list = (meals[slot] as List?) ?? const [];
        final id = firstRecommendableMealId(list);
        if (id == null) continue;
        final resolvedLabel = (i == 0 && primaryMealLabel != null)
            ? primaryMealLabel
            : (_mealLabels[slot] ?? slot);
        return _MealPick(
          recipeId: id,
          title: titles[id]?.toString() ?? '오늘의 메뉴',
          mealLabel: resolvedLabel,
          isMemo: false,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<_MealPick?> _resolveWeekdayFrequentMeal(
    List<String> allowedSlots,
  ) async {
    try {
      final today = _today;
      final start = today.subtract(const Duration(days: 35));
      final end = today.subtract(const Duration(days: 1));
      final plans = await widget.mealPlanService
          .getMealPlansForDateRange(start, end)
          .first;

      final counts = <String, int>{};
      final titleById = <String, String>{};
      plans.forEach((dateKey, data) {
        DateTime? date;
        try {
          date = DateTime.parse(dateKey);
        } catch (_) {
          return;
        }
        if (date.weekday != today.weekday) return;
        final meals = data['meals'] as Map<String, dynamic>? ?? {};
        final titles = data['recipeTitles'] as Map<String, dynamic>? ?? {};
        for (final slot in allowedSlots) {
          final list = (meals[slot] as List?) ?? const [];
          for (final raw in list) {
            final id = raw.toString().trim();
            if (id.isEmpty || isMemoMealId(id)) continue;
            counts[id] = (counts[id] ?? 0) + 1;
            titleById[id] = titles[id]?.toString() ?? '오늘의 메뉴';
          }
        }
      });

      if (counts.isEmpty) return null;
      final sorted = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final best = sorted.first;
      if (best.value < 2) return null; // "자주"의 기준
      final id = best.key;
      return _MealPick(
        recipeId: id,
        title: titleById[id] ?? '오늘의 메뉴',
        mealLabel: '',
        isMemo: false,
      );
    } catch (_) {}
    return null;
  }

  Future<_MealPick?> _resolveContextualRecipe(String sectionKey) async {
    try {
      final ids = await widget.recipeService.getHomeSectionRecipeIds(
        sectionKey: sectionKey,
        limit: 12,
      );
      if (ids.isEmpty) return null;
      final recipes = await widget.recipeService.getExploreRecipesByIds(
        ids,
        limit: ids.length,
      );
      if (recipes.isEmpty) return null;
      final recipe = recipes[_headlineVariantSeed('recipe-$sectionKey') %
          recipes.length];
      final id = recipe['id']?.toString() ?? '';
      if (id.isEmpty) return null;
      final title = _titleFromRecipe(recipe);
      if (title.isEmpty) return null;
      return _MealPick(
        recipeId: id,
        title: title,
        mealLabel: '',
        isMemo: false,
      );
    } catch (_) {}
    return null;
  }

  String _titleFromRecipe(Map<String, dynamic> recipe) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    return (recipe['title']?.toString() ??
            recipeData['title']?.toString() ??
            recipeData['name']?.toString() ??
            '')
        .trim();
  }

  String _themedHeadline() {
    if (_isLateNight) return _lateNightThemedHeadline();

    switch (_today.weekday) {
      case DateTime.friday:
        return _pickHeadlineVariant(
          const [
            '불금인데, 오늘은\n맛있는 메뉴로 마무리해볼까요?',
            '한 주 고생 많으셨어요\n기분 좋은 한 끼 어떠세요?',
            '금요일엔 조금 더 맛있게\n오늘 메뉴를 골라볼까요?',
          ],
          salt: 'theme-friday',
        );
      case DateTime.saturday:
        return _pickHeadlineVariant(
          const [
            '여유로운 주말이에요\n특별한 한 끼는 어떠세요?',
            '토요일엔 조금 천천히\n정성 한 끼 만들어볼까요?',
            '주말 분위기에 맞춰\n맛있는 메뉴를 골라보세요',
          ],
          salt: 'theme-saturday',
        );
      case DateTime.sunday:
        return _pickHeadlineVariant(
          const [
            '든든하게 마무리하는 일요일이에요\n오늘은 무엇을 드셔볼까요?',
            '일요일엔 편안한 집밥으로\n한 주를 마무리해볼까요?',
            '내일을 준비하는 일요일\n부담 없는 메뉴 어떠세요?',
          ],
          salt: 'theme-sunday',
        );
      case DateTime.monday:
        return _pickHeadlineVariant(
          const [
            '새로운 한 주의 시작이에요\n오늘 식단을 채워볼까요?',
            '월요일엔 가볍게 시작해요\n오늘 메뉴를 골라보세요',
            '한 주의 첫 끼니로\n든든한 메뉴 어떠세요?',
          ],
          salt: 'theme-monday',
        );
      case DateTime.tuesday:
        return _pickHeadlineVariant(
          const [
            '화요일엔 균형 있게\n오늘 요리를 골라볼까요?',
            '화요일은 리듬을 잡는 날이에요\n무엇을 드셔볼까요?',
            '차분한 화요일\n깔끔한 한 끼 어떠세요?',
          ],
          salt: 'theme-tuesday',
        );
      case DateTime.wednesday:
        return _pickHeadlineVariant(
          const [
            '수요일엔 기운 채우는 메뉴로\n오늘 한 끼 어떠세요?',
            '한 주의 중간이에요\n맛있는 메뉴로 힘내볼까요?',
            '수요일엔 든든한 메뉴로\n리듬을 이어가볼까요?',
          ],
          salt: 'theme-wednesday',
        );
      case DateTime.thursday:
        return _pickHeadlineVariant(
          const [
            '목요일엔 조금 더 든든하게\n오늘 메뉴 어떠세요?',
            '주말 전 마지막 힘을 위해\n맛있는 요리를 골라볼까요?',
            '목요일엔 익숙한 집밥이 좋아요\n메뉴를 선택해보세요',
          ],
          salt: 'theme-thursday',
        );
      default:
        return _pickHeadlineVariant(
          const [
            '오늘은 어떤 요리를 만들어볼까요?\n메뉴를 골라보세요',
            '지금 기분에 맞는 메뉴로\n한 끼 준비해볼까요?',
            '오늘 식탁에 올릴 메뉴를\n가볍게 골라보세요',
          ],
          salt: 'theme-default',
        );
    }
  }

  String _lateNightThemedHeadline() {
    switch (_today.weekday) {
      case DateTime.friday:
        return _pickHeadlineVariant(
          const [
            '불금인데, 야식으로\n기분 좋게 마무리해볼까요?',
            '한 주 고생 많으셨어요\n야식으로 뭐 드셔볼까요?',
            '금요일 밤엔 가볍게 즐길\n야식 메뉴를 골라보세요',
          ],
          salt: 'late-theme-friday',
        );
      case DateTime.saturday:
        return _pickHeadlineVariant(
          const [
            '주말 밤엔 야식도 좋죠\n맛있는 메뉴 골라볼까요?',
            '토요일 밤이에요\n가볍게 즐길 야식 어떠세요?',
            '여유로운 밤엔\n좋아하는 메뉴로 채워볼까요?',
          ],
          salt: 'late-theme-saturday',
        );
      case DateTime.sunday:
        return _pickHeadlineVariant(
          const [
            '일요일 밤은 부담 없이\n야식 메뉴를 골라볼까요?',
            '한 주 마무리엔\n편안한 야식 어떠세요?',
            '출출한 일요일 밤이에요\n가볍게 뭐 드셔볼까요?',
          ],
          salt: 'late-theme-sunday',
        );
      case DateTime.monday:
        return _pickHeadlineVariant(
          const [
            '월요일 밤엔 무리 없이\n가벼운 야식 어떠세요?',
            '하루를 잘 마쳤다면\n야식으로 쉬어가볼까요?',
            '출출한 밤이에요\n부담 없는 메뉴를 골라보세요',
          ],
          salt: 'late-theme-monday',
        );
      case DateTime.tuesday:
        return _pickHeadlineVariant(
          const [
            '화요일 밤엔 담백하게\n야식 메뉴를 골라볼까요?',
            '출출한 지금\n가볍게 즐길 메뉴 어떠세요?',
            '오늘 밤은 편하게\n야식으로 마무리해볼까요?',
          ],
          salt: 'late-theme-tuesday',
        );
      case DateTime.wednesday:
        return _pickHeadlineVariant(
          const [
            '한 주의 중간 밤이에요\n야식으로 잠깐 쉬어갈까요?',
            '수요일 밤엔 든든하지만 가볍게\n메뉴를 골라보세요',
            '출출한 밤이에요\n기분 좋은 야식 어떠세요?',
          ],
          salt: 'late-theme-wednesday',
        );
      case DateTime.thursday:
        return _pickHeadlineVariant(
          const [
            '목요일 밤엔 조금만 더 가볍게\n야식 메뉴 어떠세요?',
            '주말 전 밤이에요\n맛있는 야식으로 쉬어갈까요?',
            '출출한 지금\n부담 없는 메뉴를 골라보세요',
          ],
          salt: 'late-theme-thursday',
        );
      default:
        return _pickHeadlineVariant(
          const [
            '출출한 밤이에요\n야식으로 뭐 드셔볼까요?',
            '오늘 밤은 가볍게\n맛있는 메뉴 어떠세요?',
            '잠들기 전 출출하다면\n부담 없는 메뉴를 골라보세요',
          ],
          salt: 'late-theme-default',
        );
    }
  }

  Widget _buildGreeting(_HeroData data) {
    const baseStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 16,
      fontWeight: FontWeight.w800,
      color: _heroMuted,
      letterSpacing: -0.35,
      height: 1.25,
    );
    final nickname = data.nickname.trim();
    if (nickname.isEmpty) {
      return Text(data.greeting, style: baseStyle);
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _nameShimmerController,
          builder: (context, child) {
            return ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                return LinearGradient(
                  colors: const [
                    Color(0xFFFF6B00),
                    Color(0xFFFF9A3D),
                    Color(0xFFFFC078),
                    Color(0xFFFF6B00),
                  ],
                  stops: const [0.0, 0.34, 0.58, 1.0],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  transform: _NameShimmerTransform(
                    progress: _nameShimmerController.value,
                  ),
                ).createShader(bounds);
              },
              child: child,
            );
          },
          child: Text(
            nickname,
            style: baseStyle.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
        Text('님, ${data.greeting}', style: baseStyle),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _buildSkeleton();
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGreeting(data),
          const SizedBox(height: 7),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: data.recipeId == null
                ? null
                : () {
                    Haptics.light();
                    if (isMemoMealId(data.recipeId!)) {
                      widget.onOpenCalendar();
                      return;
                    }
                    widget.onOpenRecipe(data.recipeId!);
                  },
            child: Text(
              data.headline,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 25,
                fontWeight: FontWeight.w900,
                color: _heroInk,
                letterSpacing: -0.85,
                height: 1.22,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                Haptics.light();
                widget.onOpenCalendar();
              },
              child: const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 0, 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '요리 일정 보기',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: _heroMuted,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: _heroMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 112,
                height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 132,
                height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Container(
            width: 268,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFFEDEFF2),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: 232,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFFEDEFF2),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 0, 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroData {
  const _HeroData({
    required this.nickname,
    required this.greeting,
    required this.headline,
    required this.recipeId,
  });

  final String nickname;
  final String greeting;
  final String headline;
  final String? recipeId;
}

class _NameShimmerTransform extends GradientTransform {
  const _NameShimmerTransform({required this.progress});

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
  }
}

class _MealPick {
  const _MealPick({
    required this.recipeId,
    required this.title,
    required this.mealLabel,
    required this.isMemo,
  });

  final String recipeId;
  final String title;
  final String mealLabel;
  final bool isMemo;
}
