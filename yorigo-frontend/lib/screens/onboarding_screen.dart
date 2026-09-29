import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/onboarding_profile.dart';
import '../services/analytics_service.dart';
import '../services/user_service.dart';
import '../theme/app_colors.dart';
import '../utils/auth_navigation.dart';
import '../utils/haptics.dart';
import '../utils/username_suggestion_generator.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    this.continueRouteName,
    this.continueRouteArguments,
    this.isPreview = false,
    this.initialUserData,
  });

  final String? continueRouteName;
  final Object? continueRouteArguments;
  final bool isPreview;
  final Map<String, dynamic>? initialUserData;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step {
  nickname,
  profile,
  goals,
  sources,
  saveGuide,
  cooking,
  taste,
  homeGuide,
  restrictions,
  bookGuide,
  habits,
  shopGuide,
  finalGuide,
}

class _OnboardingLook {
  static const bg = Color(0xFFFFFFFF);
  static const ink = Color(0xFF111111);
  static const muted = Color(0xFF8E8E93);
  static const accent = Color(0xFFFF6900);
  static const accentSoft = Color(0xFFFFF5ED);
  static const borderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFC043),
      Color(0xFFFF6900),
      Color(0xFFFF6B7A),
      Color(0xFFD4A0E8),
    ],
    stops: [0.0, 0.42, 0.74, 1.0],
  );
  static const ctaGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFC043),
      Color(0xFFFF6900),
      Color(0xFFFF6B7A),
    ],
    stops: [0.0, 0.5, 1.0],
  );
  static const line = Color(0xFFE8E8ED);
  static const track = Color(0xFFF0F0F2);
  static const ctaDisabled = Color(0xFFF0F0F2);
  static const ctaDisabledText = Color(0xFFC7C7CC);

  static const titleStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: ink,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.35,
    letterSpacing: -0.4,
  );
  static const hintStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: muted,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    letterSpacing: -0.2,
  );
  static const labelStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: muted,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const chipStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: ink,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.2,
  );
  static const inputStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: ink,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
  );
}

/// 어절 안에서는 줄바꿈하지 않는다. `맞춰` → `맞/춰` 같은 한글 분절을 막는다.
String _keepEojeol(String text) {
  return text.splitMapJoin(
    RegExp(r'\S+'),
    onMatch: (m) => m.group(0)!.split('').join('\u2060'),
    onNonMatch: (n) => n,
  );
}

Duration _typingDelayAfter(String text) {
  final count = text.runes.where((r) => r != 0x2060).length;
  return Duration(milliseconds: (160 + count * 14).clamp(200, 560));
}

class _TypedText extends StatefulWidget {
  const _TypedText({
    super.key,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.start,
    this.delay = Duration.zero,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final Duration delay;

  @override
  State<_TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<_TypedText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: _durationFor(widget.text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  Duration _durationFor(String text) {
    final count = text.runes.where((r) => r != 0x2060 && r != 0x0A).length;
    return Duration(milliseconds: (160 + count * 14).clamp(200, 700));
  }

  void _play() {
    _delay?.cancel();
    _progress
      ..stop()
      ..value = 0;
    if (widget.delay <= Duration.zero) {
      _forward();
      return;
    }
    _delay = Timer(widget.delay, () {
      if (mounted) _forward();
    });
  }

  void _forward() {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = 1;
      return;
    }
    _progress.forward();
  }

  @override
  void didUpdateWidget(_TypedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text && oldWidget.delay == widget.delay) {
      return;
    }
    _progress.duration = _durationFor(widget.text);
    _play();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _progress.dispose();
    super.dispose();
  }

  (String, String) _split(String display, double t) {
    final units = display.runes.toList();
    final live = units.where((r) => r != 0x2060).length;
    final target = (live * Curves.easeOutCubic.transform(t.clamp(0, 1))).round();
    var seen = 0;
    var index = 0;
    while (index < units.length && seen < target) {
      if (units[index] != 0x2060) seen++;
      index++;
    }
    while (index < units.length && units[index] == 0x2060) {
      index++;
    }
    return (
      String.fromCharCodes(units.take(index)),
      String.fromCharCodes(units.skip(index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final display = _keepEojeol(widget.text);
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final (visible, rest) = _split(display, _progress.value);
        return Text.rich(
          TextSpan(
            style: widget.style,
            children: [
              TextSpan(text: visible),
              TextSpan(
                text: rest,
                style: widget.style.copyWith(color: Colors.transparent),
              ),
            ],
          ),
          textAlign: widget.textAlign,
        );
      },
    );
  }
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  static final _nicknamePattern = RegExp(r'^[가-힣a-zA-Z0-9_.]{2,15}$');

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _handleController = TextEditingController();
  final TextEditingController _avoidedOtherController = TextEditingController();
  final TextEditingController _dietOtherController = TextEditingController();
  final UsernameSuggestionGenerator _usernameGenerator =
      UsernameSuggestionGenerator();
  final UserService _userService = UserService();
  final AnalyticsService _analytics = AnalyticsService();
  OnboardingProfile _profile = OnboardingProfile();

  int _index = 0;
  bool _finishing = false;
  bool _startedTracked = false;
  bool _skipNickname = false;
  String? _existingName;
  String? _existingHandle;
  bool _showFrequency = false;
  bool _showChildMeal = false;
  bool _showSkill = false;
  bool _showDiet = false;
  bool _showShopPriorities = false;
  final GlobalKey<_GuideStageState> _guideKey = GlobalKey<_GuideStageState>();
  Timer? _draftSaveTimer;

  List<_Step> get _steps {
    if (_skipNickname) {
      return _Step.values.where((step) => step != _Step.nickname).toList();
    }
    return _Step.values;
  }

  String get _entry {
    if (widget.isPreview) return 'preview';
    if (_skipNickname) return 'existing';
    return 'signup';
  }

  _Step get _step => _steps[_index];
  bool get _isLast => _index >= _steps.length - 1;

  String get _stepId => _step.name;

  bool _isGuideStep(_Step step) {
    switch (step) {
      case _Step.saveGuide:
      case _Step.homeGuide:
      case _Step.bookGuide:
      case _Step.shopGuide:
      case _Step.finalGuide:
        return true;
      case _Step.nickname:
      case _Step.profile:
      case _Step.goals:
      case _Step.sources:
      case _Step.cooking:
      case _Step.taste:
      case _Step.restrictions:
      case _Step.habits:
        return false;
    }
  }

  bool get _canContinue {
    if (_finishing) return false;
    switch (_step) {
      case _Step.goals:
        return _profile.goals.isNotEmpty;
      case _Step.profile:
        return _profile.gender != null && _profile.ageGroup != null;
      case _Step.sources:
        return _profile.recipeSources.isNotEmpty;
      case _Step.saveGuide:
      case _Step.homeGuide:
      case _Step.bookGuide:
      case _Step.shopGuide:
      case _Step.finalGuide:
        return true;
      case _Step.cooking:
        if (_profile.householdSize == null ||
            _profile.cookingFrequency == null) {
          return false;
        }
        if (OnboardingProfile.offersChildMealFollowUp(_profile.householdSize) &&
            _profile.cooksForChild == null) {
          return false;
        }
        return true;
      case _Step.taste:
        return _profile.favoriteCuisines.isNotEmpty &&
            _profile.cookingSkill != null;
      case _Step.restrictions:
        if (_profile.avoidedIngredients.isEmpty ||
            _profile.dietRestrictions.isEmpty) {
          return false;
        }
        if (_profile.avoidedIngredients.contains('other') &&
            (_profile.avoidedOther ?? '').trim().isEmpty) {
          return false;
        }
        if (_profile.dietRestrictions.contains('other') &&
            (_profile.dietOther ?? '').trim().isEmpty) {
          return false;
        }
        return true;
      case _Step.habits:
        return _profile.preferredMarketplaces.isNotEmpty &&
            _profile.shoppingPriorities.isNotEmpty;
      case _Step.nickname:
        return _isValidNickname(_nameController.text);
    }
  }

  String get _ctaLabel {
    if (_step == _Step.finalGuide) return '요리GO 시작하기';
    return '계속';
  }

  bool _isValidNickname(String raw) {
    return _nicknamePattern.hasMatch(raw.trim());
  }

  String _cleanHandle(String raw) {
    var handle = raw.trim().toLowerCase();
    if (handle.startsWith('@')) handle = handle.substring(1);
    return handle;
  }

  bool _isValidHandle(String raw) {
    return UsernameSuggestionGenerator.isValidUserId(_cleanHandle(raw));
  }

  Future<void> _ensureGeneratedIdentity() async {
    final nameEmpty = _nameController.text.trim().isEmpty;
    final handleEmpty = _cleanHandle(_handleController.text).isEmpty;
    if (!nameEmpty && !handleEmpty) return;
    await _applySuggestion(
      overwriteName: nameEmpty,
      overwriteHandle: handleEmpty,
    );
  }

  Future<void> _applySuggestion({
    required bool overwriteName,
    bool overwriteHandle = true,
  }) async {
    final suggestion = _usernameGenerator.generate();
    var handle = suggestion.userId;
    final uid = widget.isPreview
        ? null
        : FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && overwriteHandle) {
      for (var i = 0; i < 20; i++) {
        final candidate = i == 0 ? handle : '${handle}_${i + 1}';
        final available = await _userService.isHandleAvailable(
          candidate,
          exceptUserId: uid,
        );
        if (available) {
          handle = candidate;
          break;
        }
      }
    }
    if (!mounted) return;
    if (overwriteName) {
      _nameController.text = suggestion.displayName;
    }
    if (overwriteHandle) {
      _handleController.text = handle;
      _profile.handle = handle;
    }
    _profile.displayName = _nameController.text.trim();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nameController.addListener(() {
      _profile.displayName = _nameController.text.trim();
      setState(() {});
      _scheduleDraftSave();
    });
    _handleController.addListener(() {
      _profile.handle = _cleanHandle(_handleController.text);
      setState(() {});
      _scheduleDraftSave();
    });
    _avoidedOtherController.addListener(() {
      _profile.avoidedOther = _avoidedOtherController.text.trim();
      setState(() {});
      _scheduleDraftSave();
    });
    _dietOtherController.addListener(() {
      _profile.dietOther = _dietOtherController.text.trim();
      setState(() {});
      _scheduleDraftSave();
    });
    unawaited(_prefill());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_persistProgress());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftSaveTimer?.cancel();
    unawaited(_persistProgress());
    _nameController.dispose();
    _handleController.dispose();
    _avoidedOtherController.dispose();
    _dietOtherController.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    Map<String, dynamic>? userData;
    ({String stepId, OnboardingProfile profile})? draft;
    final user = widget.isPreview ? null : FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        userData = widget.initialUserData ??
            await _userService.readUserData(user.uid);
        if (userData != null) {
          _profile = OnboardingProfile.fromMap(userData);
          final existingHandle = userData['handle']?.toString().trim() ?? '';
          if (existingHandle.isNotEmpty) {
            _profile.handle = existingHandle;
          }
          _existingName = userData['name']?.toString().trim();
          if (_existingName != null && _existingName!.isEmpty) {
            _existingName = null;
          }
          _existingHandle =
              existingHandle.isEmpty ? null : existingHandle;
        }
      } catch (e) {
        debugPrint('[OnboardingScreen] prefill failed: $e');
      }
      final authName = user.displayName?.trim() ?? '';
      if ((_profile.displayName ?? '').trim().isEmpty && authName.isNotEmpty) {
        _profile.displayName = authName;
      }
      _skipNickname = OnboardingDecision.skipNickname(userData);
      draft = await _userService.loadOnboardingDraft(user.uid);
      if (draft != null) {
        final keptHandle = _profile.handle;
        final keptName = _skipNickname ? _profile.displayName : null;
        _profile = draft.profile;
        if ((_profile.handle ?? '').trim().isEmpty &&
            (keptHandle ?? '').trim().isNotEmpty) {
          _profile.handle = keptHandle;
        }
        if (_skipNickname &&
            (_profile.displayName ?? '').trim().isEmpty &&
            (keptName ?? '').trim().isNotEmpty) {
          _profile.displayName = keptName;
        }
      }
    }
    if (!mounted) return;
    final filled = _profile.displayName?.trim() ?? '';
    if (_nameController.text.trim().isEmpty && filled.isNotEmpty) {
      _nameController.text = filled;
    }
    final filledHandle = _profile.handle?.trim() ?? '';
    if (_handleController.text.trim().isEmpty && filledHandle.isNotEmpty) {
      _handleController.text = filledHandle;
    }
    final filledOther = _profile.avoidedOther?.trim() ?? '';
    if (_avoidedOtherController.text.trim().isEmpty && filledOther.isNotEmpty) {
      _avoidedOtherController.text = filledOther;
    }
    final filledDietOther = _profile.dietOther?.trim() ?? '';
    if (_dietOtherController.text.trim().isEmpty && filledDietOther.isNotEmpty) {
      _dietOtherController.text = filledDietOther;
    }
    if (!_skipNickname) {
      await _ensureGeneratedIdentity();
    }
    if (!mounted) return;
    _showChildMeal = OnboardingProfile.offersChildMealFollowUp(
      _profile.householdSize,
    );
    _showFrequency = _profile.householdSize != null &&
        (!_showChildMeal || _profile.cooksForChild != null);
    _showSkill = _profile.favoriteCuisines.isNotEmpty;
    _showDiet = _profile.avoidedIngredients.isNotEmpty;
    _showShopPriorities = _profile.preferredMarketplaces.isNotEmpty;
    _index = OnboardingDecision.restoreStepIndex(
      stepNames: _steps.map((step) => step.name),
      savedStepId: draft?.stepId,
    );
    setState(() {});
    _trackView();
  }

  void _trackView() {
    if (!_startedTracked) {
      _startedTracked = true;
      unawaited(_analytics.trackOnboardingStarted(entry: _entry));
    }
    unawaited(
      _analytics.trackOnboardingStepViewed(
        stepId: _stepId,
        phase: 'ask',
      ),
    );
  }

  List<String> _answerIdsFor(_Step step) {
    switch (step) {
      case _Step.goals:
        return List<String>.from(_profile.goals);
      case _Step.profile:
        return [
          if (_profile.gender != null) _profile.gender!,
          if (_profile.ageGroup != null) _profile.ageGroup!,
        ];
      case _Step.sources:
        return List<String>.from(_profile.recipeSources);
      case _Step.saveGuide:
      case _Step.homeGuide:
      case _Step.bookGuide:
      case _Step.shopGuide:
      case _Step.finalGuide:
        return const ['viewed'];
      case _Step.cooking:
        return [
          if (_profile.householdSize != null) _profile.householdSize!,
          if (_profile.cooksForChild == true) 'child_meal',
          if (_profile.cookingFrequency != null) _profile.cookingFrequency!,
        ];
      case _Step.taste:
        return [
          ..._profile.favoriteCuisines,
          if (_profile.cookingSkill != null) _profile.cookingSkill!,
        ];
      case _Step.restrictions:
        return [
          ..._profile.avoidedIngredients,
          ..._profile.dietRestrictions.map((id) => 'diet_$id'),
        ];
      case _Step.habits:
        return [
          ..._profile.preferredMarketplaces,
          ..._profile.shoppingPriorities.map((id) => 'priority_$id'),
        ];
      case _Step.nickname:
        return [
          if (_isValidNickname(_nameController.text)) 'has_name',
        ];
    }
  }

  Future<void> _persistProgress() async {
    if (widget.isPreview || _finishing) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await _userService.saveOnboardingDraft(
        uid: uid,
        stepId: _stepId,
        profile: _profile,
      );
    } catch (e) {
      debugPrint('[OnboardingScreen] save draft failed: $e');
    }
  }

  void _scheduleDraftSave() {
    if (widget.isPreview || _finishing) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistProgress());
    });
  }

  Future<void> _finish({
    required bool skipped,
    bool openAddRecipe = false,
  }) async {
    if (_finishing) return;
    _draftSaveTimer?.cancel();
    setState(() => _finishing = true);
    _profile.displayName = _nameController.text.trim();
    _profile.handle = _cleanHandle(_handleController.text);
    try {
      if (widget.isPreview) {
        if (!mounted) return;
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          AuthNavigation.navigateToAuthenticatedHome(context);
        }
        return;
      }
      if (skipped) {
        unawaited(_analytics.trackOnboardingSkipped(fromStep: _stepId));
      }
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await _userService.saveOnboardingProfile(
          uid,
          _profile,
          persistHandle: !_skipNickname,
          completed: true,
          previousName: _existingName,
          previousHandle: _existingHandle,
        );
      }
      unawaited(
        _analytics.trackOnboardingCompleted(
          answeredCount: _profile.answeredCount,
          skipped: skipped,
          entry: _entry,
          personaId: _profile.persona.id,
          favoriteCuisines: _profile.favoriteCuisines,
          goals: _profile.goals,
          avoidedIngredients: _profile.avoidedIngredients,
          preferredMarketplace: _profile.preferredMarketplace,
          householdServings: _profile.householdServings,
        ),
      );
      unawaited(
        _analytics.setOnboardingPeopleTraits(
          gender: _profile.gender,
          ageGroup: _profile.ageGroup,
          cookingFrequency: _profile.cookingFrequency,
          cookingSkill: _profile.cookingSkill,
          householdSize: _profile.householdSize,
          goals: _profile.goals,
          favoriteCuisines: _profile.favoriteCuisines,
          avoidedIngredients: _profile.avoidedIngredients,
          dietRestrictions: _profile.dietRestrictions,
          recipeSources: _profile.recipeSources,
          preferredMarketplace: _profile.preferredMarketplace,
          preferredMarketplaces: _profile.preferredMarketplaces,
          shoppingStyle: _profile.shoppingStyle,
          shoppingPriorities: _profile.shoppingPriorities,
          personaId: _profile.persona.id,
        ),
      );
      if (!mounted) return;
      final next = widget.continueRouteName?.trim();
      if (next != null && next.isNotEmpty) {
        Navigator.of(context).pushNamed(next, arguments: _continueArguments());
      } else {
        AuthNavigation.navigateToAuthenticatedHome(
          context,
          openAddRecipe: openAddRecipe,
        );
      }
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Object? _continueArguments() {
    final raw = widget.continueRouteArguments;
    final name = _profile.displayName?.trim() ?? '';
    final handle = _profile.handle?.trim() ?? '';
    if (raw is! Map) {
      if (name.isEmpty && handle.isEmpty) return raw;
      return {
        if (name.isNotEmpty) 'onboardingDisplayName': name,
        if (handle.isNotEmpty) 'onboardingHandle': handle,
        'onboardingProfile': _profile.toMap(),
      };
    }
    final args = Map<String, dynamic>.from(raw);
    if (name.isNotEmpty) args['onboardingDisplayName'] = name;
    if (handle.isNotEmpty) args['onboardingHandle'] = handle;
    args['onboardingProfile'] = _profile.toMap();
    return args;
  }

  void _goTo(int next) {
    setState(() => _index = next.clamp(0, _steps.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _trackView());
    unawaited(_persistProgress());
  }

  void _advance() {
    if (!_canContinue) return;
    // AnimatedSwitcher가 이전 가이드를 잠시 남겨 두면 GlobalKey가
    // 질문 단계의 계속 탭을 숨은 슬라이드 넘기기로 삼킨다.
    if (_isGuideStep(_step)) {
      final guide = _guideKey.currentState;
      if (guide != null && guide.advanceSlide()) {
        return;
      }
    }
    Haptics.medium();
    if (!_isGuideStep(_step)) {
      unawaited(
        _analytics.trackOnboardingStepAnswered(
          stepId: _stepId,
          answerIds: _answerIdsFor(_step),
        ),
      );
    }
    if (_isLast) {
      unawaited(_finish(skipped: false, openAddRecipe: !_skipNickname));
      return;
    }
    _goTo(_index + 1);
  }

  void _back() {
    if (_isGuideStep(_step)) {
      final guide = _guideKey.currentState;
      if (guide != null && guide.rewindSlide()) {
        return;
      }
    }
    if (_index > 0) {
      Haptics.selection();
      _goTo(_index - 1);
      return;
    }
    unawaited(_persistProgress());
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _selectSingle(void Function() apply) {
    Haptics.selection();
    setState(apply);
    _scheduleDraftSave();
  }

  void _toggle(List<String> target, String id, {int? max}) {
    Haptics.selection();
    setState(() {
      if (target.contains(id)) {
        target.remove(id);
        return;
      }
      if (max != null && target.length >= max) {
        return;
      }
      target.add(id);
    });
    _scheduleDraftSave();
  }

  void _toggleDiet(String id) {
    Haptics.selection();
    setState(() {
      if (id == 'none') {
        _profile.dietRestrictions
          ..clear()
          ..add('none');
        _dietOtherController.clear();
        _profile.dietOther = null;
        return;
      }
      _profile.dietRestrictions.remove('none');
      if (_profile.dietRestrictions.contains(id)) {
        _profile.dietRestrictions.remove(id);
        if (id == 'other') {
          _dietOtherController.clear();
          _profile.dietOther = null;
        }
      } else {
        _profile.dietRestrictions.add(id);
      }
    });
    _scheduleDraftSave();
  }

  void _toggleAvoided(String id) {
    Haptics.selection();
    setState(() {
      if (id == 'none') {
        _profile.avoidedIngredients
          ..clear()
          ..add('none');
        _avoidedOtherController.clear();
        _profile.avoidedOther = null;
      } else {
        _profile.avoidedIngredients.remove('none');
        if (_profile.avoidedIngredients.contains(id)) {
          _profile.avoidedIngredients.remove(id);
          if (id == 'other') {
            _avoidedOtherController.clear();
            _profile.avoidedOther = null;
          }
        } else {
          _profile.avoidedIngredients.add(id);
        }
      }
      if (_profile.avoidedIngredients.isNotEmpty) {
        _showDiet = true;
      }
    });
    _scheduleDraftSave();
  }

  void _toggleMarkets(String id) {
    _toggle(_profile.preferredMarketplaces, id);
    _profile.preferredMarketplace = _profile.preferredMarketplaces.isEmpty
        ? null
        : _profile.preferredMarketplaces.first;
    if (_profile.preferredMarketplaces.isNotEmpty) {
      setState(() => _showShopPriorities = true);
    }
  }

  void _toggleSources(String id) {
    _toggle(_profile.recipeSources, id);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _back();
      },
      child: Scaffold(
      backgroundColor: _OnboardingLook.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildChrome(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _buildBody(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Column(
                children: [
                  _CtaButton(
                    label: _ctaLabel,
                    enabled: _canContinue,
                    loading: _finishing,
                    onTap: _advance,
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

  Widget _buildChrome() {
    final progress = (_index + 1) / _steps.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Row(
        children: [
          _CircleBackButton(onTap: _back),
          const SizedBox(width: 14),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: SizedBox(
                height: 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: _OnboardingLook.track),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress.clamp(0.08, 1.0),
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _OnboardingLook.ctaGradient,
                        ),
                      ),
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

  Widget _buildBody() {
    switch (_step) {
      case _Step.goals:
        return _AskPage(
          title: '요리GO에서 가장 하고 싶은 건\n무엇인가요?',
          hint: '원하는 만큼 골라 주세요.\n원하시는 흐름에 가까운 경험부터 열어 둘게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FieldLabel('레시피'),
              const SizedBox(height: 8),
              _OptionList(
                choices: OnboardingProfile.recipeGoalChoices,
                selectedIds: _profile.goals.toSet(),
                onTap: (id) => _toggle(_profile.goals, id),
                columns: 2,
                maxLines: 2,
                tiles: true,
              ),
              const SizedBox(height: 24),
              const _FieldLabel('요리 생활'),
              const SizedBox(height: 8),
              _OptionList(
                choices: OnboardingProfile.livingGoalChoices,
                selectedIds: _profile.goals.toSet(),
                onTap: (id) => _toggle(_profile.goals, id),
                columns: 2,
                maxLines: 2,
                tiles: true,
              ),
            ],
          ),
        );
      case _Step.profile:
        final name = _profile.displayName?.trim() ?? '';
        return _AskPage(
          title: '성별과 나이를 알려주세요',
          titleWidget: name.isEmpty
              ? null
              : _NamedQuestionTitle(
                  name: name,
                  suffix: '님의',
                  question: '성별과 나이를 알려주세요',
                ),
          hint: '고르신 성별과 연령대에 맞춰\n추천을 구성해 둘게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FieldLabel('성별'),
              const SizedBox(height: 8),
              _OptionList(
                choices: OnboardingProfile.genderChoices,
                selectedIds: {
                  if (_profile.gender != null) _profile.gender!,
                },
                onTap: (id) => _selectSingle(() => _profile.gender = id),
                columns: 2,
              ),
              const SizedBox(height: 28),
              const _FieldLabel('연령대'),
              const SizedBox(height: 8),
              _OptionList(
                choices: OnboardingProfile.ageGroupChoices,
                selectedIds: {
                  if (_profile.ageGroup != null) _profile.ageGroup!,
                },
                onTap: (id) => _selectSingle(() => _profile.ageGroup = id),
                columns: 3,
              ),
            ],
          ),
        );
      case _Step.sources:
        return _AskPage(
          title: '레시피는 주로 어디서\n발견하시나요?',
          hint: '자주 보시는 곳에서 공유하거나 링크만 넣으면\n재료와 요리 순서를 바로 정리해 드릴게요.',
          child: _OptionList(
            choices: OnboardingProfile.recipeSourceChoices,
            selectedIds: _profile.recipeSources.toSet(),
            onTap: _toggleSources,
          ),
        );
      case _Step.saveGuide:
        return _SaveGuidePage(guideKey: _guideKey);
      case _Step.cooking:
        return _AskPage(
          title: '보통 몇 인분을 요리하시나요?',
          hint: '고르신 인분에 맞춰 분량과 레시피를 계산해 드릴게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OptionList(
                choices: OnboardingProfile.householdSizeChoices,
                selectedIds: {
                  if (_profile.householdSize != null) _profile.householdSize!,
                },
                onTap: (id) => _selectSingle(() {
                  final previous = _profile.householdSize;
                  _profile.householdSize = id;
                  _showChildMeal =
                      OnboardingProfile.offersChildMealFollowUp(id);
                  if (!_showChildMeal) {
                    _profile.cooksForChild = false;
                    _showFrequency = true;
                  } else {
                    if (!OnboardingProfile.offersChildMealFollowUp(previous)) {
                      _profile.cooksForChild = null;
                    }
                    _showFrequency = _profile.cooksForChild != null;
                  }
                }),
              ),
              _Reveal(
                visible: _showChildMeal,
                child: _FollowUp(
                  title: '아이와 함께 먹는 요리도\n자주 만드시나요?',
                  note: '이유식',
                  hint: '아이와 같이 먹는 요리를 추천에 반영해 둘게요.',
                  child: _OptionList(
                    choices: OnboardingProfile.childMealYesNoChoices,
                    selectedIds: {
                      if (_profile.cooksForChild == true) 'yes',
                      if (_profile.cooksForChild == false) 'no',
                    },
                    onTap: (id) => _selectSingle(() {
                      _profile.cooksForChild = id == 'yes';
                      _showFrequency = true;
                    }),
                  ),
                ),
              ),
              _Reveal(
                visible: _showFrequency,
                child: _FollowUp(
                  title: '일주일에 몇 번 정도 요리하시나요?',
                  hint: '고르신 횟수에 맞춰 식단 제안 빈도를 조절해 둘게요.',
                  child: _OptionList(
                    choices: OnboardingProfile.cookingFrequencyChoices,
                    selectedIds: {
                      if (_profile.cookingFrequency != null)
                        _profile.cookingFrequency!,
                    },
                    onTap: (id) => _selectSingle(
                      () => _profile.cookingFrequency = id,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case _Step.taste:
        return _AskPage(
          title: '어떤 요리를 자주 찾으시나요?',
          hint: '최대 5개까지 골라 주세요.\n고르신 스타일을 홈 추천에 먼저 보여 드릴게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OptionList(
                choices: OnboardingProfile.cuisineChoices,
                selectedIds: _profile.favoriteCuisines.toSet(),
                onTap: (id) {
                  _toggle(_profile.favoriteCuisines, id, max: 5);
                  if (_profile.favoriteCuisines.isNotEmpty) {
                    setState(() => _showSkill = true);
                  }
                },
              ),
              _Reveal(
                visible: _showSkill,
                child: _FollowUp(
                  title: '평소 요리는 어느 정도 하세요?',
                  hint: '고르신 실력에 맞는 난이도부터 보여 드릴게요.',
                  child: _OptionList(
                    choices: OnboardingProfile.cookingSkillChoices,
                    selectedIds: {
                      if (_profile.cookingSkill != null) _profile.cookingSkill!,
                    },
                    onTap: (id) =>
                        _selectSingle(() => _profile.cookingSkill = id),
                  ),
                ),
              ),
            ],
          ),
        );
      case _Step.restrictions:
        return _AskPage(
          title: '못 드시는 재료가 있으신가요?',
          hint: '알레르기는 추천에서 빼고,\n식단에서 빼고 싶은 건 덜 보여 드릴게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OptionList(
                choices: OnboardingProfile.avoidedIngredientChoices,
                selectedIds: _profile.avoidedIngredients.toSet(),
                onTap: _toggleAvoided,
              ),
              if (_profile.avoidedIngredients.contains('other')) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _avoidedOtherController,
                  textInputAction: TextInputAction.done,
                  cursorColor: _OnboardingLook.accent,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: _OnboardingLook.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                  decoration: InputDecoration(
                    hintText: '예: 키위, 새우젓',
                    hintStyle: const TextStyle(
                      fontFamily: 'Pretendard',
                      color: _OnboardingLook.muted,
                      fontWeight: FontWeight.w500,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8F8F8),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _OnboardingLook.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: _OnboardingLook.accent,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
              _Reveal(
                visible: _showDiet,
                child: _FollowUp(
                  title: '식단에서 빼고 싶은 게 있으신가요?',
                  hint: '알레르기가 아니어도 돼요.\n고르신 항목은 추천에서 덜 보여 드릴게요.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _OptionList(
                        choices: OnboardingProfile.dietRestrictionChoices,
                        selectedIds: _profile.dietRestrictions.toSet(),
                        onTap: _toggleDiet,
                      ),
                      if (_profile.dietRestrictions.contains('other')) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _dietOtherController,
                          textInputAction: TextInputAction.done,
                          cursorColor: _OnboardingLook.accent,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: _OnboardingLook.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3,
                          ),
                          decoration: InputDecoration(
                            hintText: '예: 양파, 마늘, 고수',
                            hintStyle: const TextStyle(
                              fontFamily: 'Pretendard',
                              color: _OnboardingLook.muted,
                              fontWeight: FontWeight.w500,
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF8F8F8),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: _OnboardingLook.line,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: _OnboardingLook.accent,
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      case _Step.homeGuide:
        return _HomeGuidePage(guideKey: _guideKey);
      case _Step.bookGuide:
        return _BookGuidePage(guideKey: _guideKey);
      case _Step.habits:
        return _AskPage(
          title: '장은 주로 어디서 보시나요?',
          hint: '고르신 마켓의 상품을 장바구니에서 먼저 보여 드릴게요.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OptionList(
                choices: OnboardingProfile.marketplaceChoices,
                selectedIds: _profile.preferredMarketplaces.toSet(),
                onTap: _toggleMarkets,
              ),
              _Reveal(
                visible: _showShopPriorities,
                child: _FollowUp(
                  title: '장볼 때 어떤 걸 가장\n중요하게 보시나요?',
                  hint: '최대 3개까지 골라 주세요.\n장바구니 상품을 고를 때 이 기준을 먼저 볼게요.',
                  child: _OptionList(
                    choices: OnboardingProfile.shoppingPriorityChoices,
                    selectedIds: _profile.shoppingPriorities.toSet(),
                    onTap: (id) =>
                        _toggle(_profile.shoppingPriorities, id, max: 3),
                  ),
                ),
              ),
            ],
          ),
        );
      case _Step.shopGuide:
        return _ShopGuidePage(guideKey: _guideKey);
      case _Step.nickname:
        return _AskPage(
          title: '요리GO에서 사용할 닉네임을\n정해주세요.',
          hint: '요리 기록이나 커뮤니티에서 사용돼요.',
          child: _NicknameField(
            nameController: _nameController,
            handleController: _handleController,
            onCycle: () => _applySuggestion(overwriteName: true),
            handleValid: _isValidHandle(_handleController.text),
            handleReadOnly: true,
          ),
        );
      case _Step.finalGuide:
        return const _FinalGuidePage();
    }
  }
}

class _CircleBackButton extends StatelessWidget {
  const _CircleBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF4F4F6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 15,
            color: _OnboardingLook.ink,
          ),
        ),
      ),
    );
  }
}

class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: visible
          ? TweenAnimationBuilder<double>(
              key: ValueKey(child.runtimeType),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              builder: (context, value, animatedChild) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 10 * (1 - value)),
                    child: animatedChild,
                  ),
                );
              },
              child: child,
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

class _FollowUpTitle extends StatelessWidget {
  const _FollowUpTitle({required this.text, this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (note == null) return _TitleLine(text: text);
    final lines = text.split('\n');
    final last = lines.last;
    final head =
        lines.length > 1 ? lines.sublist(0, lines.length - 1).join('\n') : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (head != null) _TitleLine(text: head),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            _TitleLine(text: last),
            _ScopeBadge(note!),
          ],
        ),
      ],
    );
  }
}

class _ScopeBadge extends StatelessWidget {
  const _ScopeBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 7, 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F4F6),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          color: _OnboardingLook.muted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.15,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

class _FollowUp extends StatelessWidget {
  const _FollowUp({
    required this.title,
    required this.child,
    this.hint,
    this.note,
  });

  final String title;
  final String? hint;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FollowUpTitle(text: title, note: note),
          if (hint != null) ...[
            const SizedBox(height: 6),
            _TypedText(
              text: hint!,
              style: _OnboardingLook.hintStyle,
              delay: _typingDelayAfter(title),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _CtaButton extends StatelessWidget {
  const _CtaButton({
    required this.label,
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: enabled ? _OnboardingLook.ctaGradient : null,
          color: enabled ? null : _OnboardingLook.ctaDisabled,
          borderRadius: BorderRadius.circular(27),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled && !loading ? onTap : null,
            borderRadius: BorderRadius.circular(27),
            splashColor: Colors.white24,
            highlightColor: Colors.white10,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: enabled
                            ? Colors.white
                            : _OnboardingLook.ctaDisabledText,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleLine extends StatelessWidget {
  const _TitleLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _TypedText(text: text, style: _OnboardingLook.titleStyle);
  }
}

class _NamedQuestionTitle extends StatelessWidget {
  const _NamedQuestionTitle({
    required this.name,
    required this.suffix,
    required this.question,
  });

  final String name;
  final String suffix;
  final String question;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ShimmerName(name: name, style: _OnboardingLook.titleStyle),
            Text(suffix, style: _OnboardingLook.titleStyle),
          ],
        ),
        _TypedText(text: question, style: _OnboardingLook.titleStyle),
      ],
    );
  }
}

class _ShimmerName extends StatefulWidget {
  const _ShimmerName({required this.name, required this.style});

  final String name;
  final TextStyle style;

  @override
  State<_ShimmerName> createState() => _ShimmerNameState();
}

class _ShimmerNameState extends State<_ShimmerName>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
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
              transform: _NameShimmerTransform(progress: _controller.value),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: Text(
        _keepEojeol(widget.name),
        style: widget.style.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _NameShimmerTransform extends GradientTransform {
  const _NameShimmerTransform({required this.progress});

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
  }
}

class _GuideSlide {
  const _GuideSlide({required this.caption, required this.child});

  final String caption;
  final Widget child;
}

class _SaveGuidePage extends StatelessWidget {
  const _SaveGuidePage({required this.guideKey});

  final GlobalKey<_GuideStageState> guideKey;

  @override
  Widget build(BuildContext context) {
    return _GuideStage(
      key: guideKey,
      title: 'SNS에서 마음에 든 레시피를\n요리GO에 바로 저장할 수 있어요.',
      slides: const [
        _GuideSlide(
          caption: 'SNS에서 마음에 드는 레시피를 고르세요.',
          child: _GuideHotspotShot(
            asset: 'assets/images/onboarding_save_shorts.png',
            hotspot: Offset(0.888, 0.765),
            startDelay: Duration(milliseconds: 720),
            iconRadiusFrac: 0.056,
            showCore: false,
          ),
        ),
        _GuideSlide(
          caption: '공유하기에서 요리GO만 고르면 돼요.',
          child: _GuideHotspotShot(
            asset: 'assets/images/onboarding_save_share.png',
            hotspot: Offset(0.388, 0.764),
            zoomHotspot: Offset(0.388, 0.82),
            startDelay: Duration(milliseconds: 220),
            iconRadiusFrac: 0.102,
            showCore: false,
          ),
        ),
        _GuideSlide(
          caption: '재료와 요리 순서가 바로 정리돼요.',
          child: _RecipeReadyShot(),
        ),
      ],
    );
  }
}

class _HomeGuidePage extends StatelessWidget {
  const _HomeGuidePage({required this.guideKey});

  final GlobalKey<_GuideStageState> guideKey;

  @override
  Widget build(BuildContext context) {
    return _GuideStage(
      key: guideKey,
      title: '답해 주신 취향에 맞춰\n레시피를 골라 보여 드릴게요.',
      slides: const [
        _GuideSlide(
          caption: '마음에 드는 레시피는 바로 저장할 수 있어요.',
          child: _GuideAssetShot(
            'assets/images/onboarding_home_feed.png',
          ),
        ),
      ],
    );
  }
}

class _BookGuidePage extends StatelessWidget {
  const _BookGuidePage({required this.guideKey});

  final GlobalKey<_GuideStageState> guideKey;

  @override
  Widget build(BuildContext context) {
    return _GuideStage(
      key: guideKey,
      title: '레시피를 나만의 레시피북에 담고,\n먹을 날까지 정할 수 있어요.',
      slides: const [
        _GuideSlide(
          caption: '레시피북에 모아 두고 꺼내볼 수 있어요.',
          child: _GuideAssetShot(
            'assets/images/onboarding_book_list.png',
          ),
        ),
        _GuideSlide(
          caption: '먹을 날짜를 정해 둘 수 있어요.',
          child: _GuideAssetShot(
            'assets/images/onboarding_book_plan.png',
          ),
        ),
      ],
    );
  }
}

class _ShopGuidePage extends StatelessWidget {
  const _ShopGuidePage({required this.guideKey});

  final GlobalKey<_GuideStageState> guideKey;

  @override
  Widget build(BuildContext context) {
    return _GuideStage(
      key: guideKey,
      title: '장보기 목록에 필요한 재료만\n모았다가 구매할 수 있어요.',
      slides: const [
        _GuideSlide(
          caption: '레시피에서 필요한 재료를 바로 담을 수 있어요.',
          child: _GuideHotspotShot(
            asset: 'assets/images/onboarding_shop_recipe.png',
            hotspot: Offset(0.318, 0.932),
            zoomHotspot: Offset(0.318, 1.06),
            startDelay: Duration(milliseconds: 720),
            iconRadiusFrac: 0.068,
            pillSize: Size(0.415, 0.052),
            zoom: 1.48,
            showCore: false,
          ),
        ),
        _GuideSlide(
          caption: '필요한 재료만 골라 담을 수 있어요.',
          child: _GuideHotspotShot(
            asset: 'assets/images/onboarding_shop_pick.png',
            hotspot: Offset(0.38, 0.38),
            zoomHotspot: Offset(0.38, 0.38),
            startDelay: Duration(milliseconds: 220),
            iconRadiusFrac: 0.034,
            zoom: 1.72,
            pinLeft: 0.058,
            showCore: false,
            ripples: [
              Offset(0.126, 0.346),
              Offset(0.126, 0.418),
              Offset(0.126, 0.621),
            ],
          ),
        ),
        _GuideSlide(
          caption: '장보기 목록에 한 번에 담을 수 있어요.',
          child: _RecipeReadyShot(
            asset: 'assets/images/onboarding_shop_cart.png',
          ),
        ),
      ],
    );
  }
}

class _FinalGuidePage extends StatelessWidget {
  const _FinalGuidePage();

  @override
  Widget build(BuildContext context) {
    return const _GuideStage(
      title: '첫 레시피를 저장하고\n요리를 시작해 볼까요?',
      slides: [
        _GuideSlide(
          caption: '재료와 요리 순서가 바로 정리돼요.',
          child: _FinalOrbitShot(),
        ),
      ],
    );
  }
}

class _FinalOrbitShot extends StatefulWidget {
  const _FinalOrbitShot();

  static const _phone = 'assets/images/onboarding_save_recipe.png';

  static const _icons = [
    _OrbitSpec(
      asset: 'lib/assets/youtube-app-icon-hd.png',
      x: 0.00,
      y: 0.18,
      size: 64,
      phase: 0.0,
      tilt: -0.18,
    ),
    _OrbitSpec(
      asset: 'lib/assets/instagram-app-icon-hd.png',
      x: 0.01,
      y: 0.52,
      size: 58,
      phase: 0.35,
      tilt: 0.16,
    ),
    _OrbitSpec(
      asset: 'lib/assets/tiktok-app-icon-hd.png',
      x: 0.80,
      y: 0.24,
      size: 56,
      phase: 0.6,
      tilt: 0.14,
    ),
    _OrbitSpec(
      asset: 'assets/icons/naver_blog_icon.png',
      x: 0.82,
      y: 0.56,
      size: 42,
      phase: 0.85,
      tilt: -0.12,
    ),
  ];

  @override
  State<_FinalOrbitShot> createState() => _FinalOrbitShotState();
}

class _OrbitSpec {
  const _OrbitSpec({
    required this.asset,
    required this.x,
    required this.y,
    required this.size,
    required this.phase,
    required this.tilt,
  });

  final String asset;
  final double x;
  final double y;
  final double size;
  final double phase;
  final double tilt;
}

class _FinalOrbitShotState extends State<_FinalOrbitShot>
    with TickerProviderStateMixin {
  late final AnimationController _float;
  late final AnimationController _enter;
  Timer? _start;

  @override
  void initState() {
    super.initState();
    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _enter.value = 1;
        return;
      }
      _start = Timer(const Duration(milliseconds: 180), () {
        if (mounted) _enter.forward();
      });
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _float.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return AnimatedBuilder(
          animation: Listenable.merge([_float, _enter]),
          builder: (context, _) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: w * 0.12),
                  child: const _GuideAssetShot(_FinalOrbitShot._phone),
                ),
                for (final spec in _FinalOrbitShot._icons)
                  Positioned(
                    left: w * spec.x,
                    top: h * spec.y +
                        math.sin((_float.value + spec.phase) * math.pi * 2) * 5,
                    child: Opacity(
                      opacity: _enterT(spec),
                      child: Transform.translate(
                        offset: Offset(_enterDx(spec), 0),
                        child: _OrbitBadge(
                          asset: spec.asset,
                          size: spec.size,
                          tilt: spec.tilt,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  double _enterT(_OrbitSpec spec) {
    final local = ((_enter.value - spec.phase * 0.10) / 0.90).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(local);
  }

  double _enterDx(_OrbitSpec spec) {
    final fromLeft = spec.x < 0.5;
    return (fromLeft ? -56.0 : 56.0) * (1 - _enterT(spec));
  }
}

class _OrbitBadge extends StatelessWidget {
  const _OrbitBadge({
    required this.asset,
    required this.size,
    required this.tilt,
  });

  final String asset;
  final double size;
  final double tilt;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: tilt,
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _GuideStage extends StatefulWidget {
  const _GuideStage({
    super.key,
    required this.title,
    required this.slides,
  });

  final String title;
  final List<_GuideSlide> slides;

  @override
  State<_GuideStage> createState() => _GuideStageState();
}

class _GuideStageState extends State<_GuideStage> {
  late final PageController _controller;
  int _page = 0;

  bool get canAdvanceSlide => _page < widget.slides.length - 1;
  bool get canRewindSlide => _page > 0;

  bool advanceSlide() {
    if (!canAdvanceSlide) return false;
    Haptics.medium();
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  bool rewindSlide() {
    if (!canRewindSlide) return false;
    Haptics.selection();
    _controller.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.slides;
    final caption = slides[_page].caption;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Column(
        children: [
          _TypedText(
            text: widget.title,
            style: _OnboardingLook.titleStyle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          _TypedText(
            key: ValueKey(_page),
            text: caption,
            style: _OnboardingLook.hintStyle,
            textAlign: TextAlign.center,
            delay: _page == 0
                ? _typingDelayAfter(widget.title)
                : const Duration(milliseconds: 90),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRect(
              child: PageView.builder(
                controller: _controller,
                physics: slides.length > 1
                    ? const BouncingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: slides.length,
                onPageChanged: (index) {
                  Haptics.selection();
                  setState(() => _page = index);
                },
                itemBuilder: (context, index) {
                  Widget shot = slides[index].child;
                  if (index == 0) {
                    shot = _RiseIn(
                      key: const ValueKey('guide-shot-0'),
                      delay: const Duration(milliseconds: 200),
                      hiddenOffset: const Offset(0, 0.14),
                      duration: const Duration(milliseconds: 520),
                      child: shot,
                    );
                  }
                  return _GuidePageActive(
                    active: index == _page,
                    child: shot,
                  );
                },
              ),
            ),
          ),
          if (slides.length > 1) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? _OnboardingLook.accent
                          : _OnboardingLook.track,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GuideAssetShot extends StatelessWidget {
  const _GuideAssetShot(this.asset);

  final String asset;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: AssetImage(asset),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class _RecipeReadyShot extends StatefulWidget {
  const _RecipeReadyShot({
    this.asset = 'assets/images/onboarding_save_recipe.png',
  });

  final String asset;
  static const _imageSize = Size(354, 728);

  @override
  State<_RecipeReadyShot> createState() => _RecipeReadyShotState();
}

class _RecipeReadyShotState extends State<_RecipeReadyShot>
    with TickerProviderStateMixin {
  late final AnimationController _play;
  late final AnimationController _pop;
  var _active = false;
  List<_BurstSpark> _sparks = const [];
  List<_BurstBloom> _blooms = const [];

  @override
  void initState() {
    super.initState();
    _play = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    );
    _pop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 780),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = _GuidePageActive.of(context);
    if (active == _active) return;
    _active = active;
    if (active) {
      _arm();
    } else {
      _disarm();
    }
  }

  void _arm() {
    _seed();
    _play
      ..stop()
      ..value = 0;
    _pop
      ..stop()
      ..value = 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _play.value = 1;
      _pop.value = 1;
      return;
    }
    Haptics.success();
    _pop.forward();
    _play.forward();
  }

  void _disarm() {
    _play
      ..stop()
      ..value = 0;
    _pop
      ..stop()
      ..value = 0;
  }

  void _seed() {
    final rng = math.Random(11);
    const colors = [
      Color(0xFFFF6900),
      Color(0xFFFF9A3D),
      Color(0xFFFFC078),
      Color(0xFFFFE08A),
      Color(0xFFFFFFFF),
      Color(0xFFFF4D6A),
      Color(0xFFFFD166),
    ];
    const origins = [
      Offset(0.18, 0.22),
      Offset(0.82, 0.22),
      Offset(0.08, 0.42),
      Offset(0.92, 0.42),
      Offset(0.16, 0.68),
      Offset(0.84, 0.68),
      Offset(0.50, 0.16),
      Offset(0.50, 0.78),
    ];
    final sparks = <_BurstSpark>[];
    for (var b = 0; b < origins.length; b++) {
      final origin = origins[b];
      final count = 18 + (b % 3) * 3;
      for (var i = 0; i < count; i++) {
        sparks.add(
          _BurstSpark(
            origin: Offset(
              (origin.dx + (rng.nextDouble() - 0.5) * 0.16).clamp(0.04, 0.96),
              (origin.dy + (rng.nextDouble() - 0.5) * 0.14).clamp(0.08, 0.92),
            ),
            angle: (i / count) * math.pi * 2 + rng.nextDouble() * 0.7,
            speed: 0.32 + rng.nextDouble() * 0.48,
            size: 2.0 + rng.nextDouble() * 4.8,
            color: colors[rng.nextInt(colors.length)],
            kind: rng.nextInt(4),
            spin: (rng.nextDouble() - 0.5) * 10,
            delay: b * 0.05 + rng.nextDouble() * 0.05,
            life: 0.42 + rng.nextDouble() * 0.22,
            gravity: 0.10 + rng.nextDouble() * 0.16,
          ),
        );
      }
    }
    _sparks = sparks;
    _blooms = [
      for (var i = 0; i < origins.length; i++)
        _BurstBloom(
          origin: origins[i],
          delay: i * 0.05,
          color: colors[i % colors.length],
        ),
    ];
  }

  @override
  void dispose() {
    _play.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dest = Alignment.center.inscribe(
          applyBoxFit(
            BoxFit.contain,
            _RecipeReadyShot._imageSize,
            constraints.biggest,
          ).destination,
          Offset.zero & constraints.biggest,
        );
        return AnimatedBuilder(
          animation: Listenable.merge([_play, _pop]),
          builder: (context, _) {
            final scale = (!_active && _pop.value == 0)
                ? 1.0
                : lerpDouble(
                    0.88,
                    1.0,
                    Curves.elasticOut.transform(_pop.value),
                  )!;
            final flash = (!_active || _play.value <= 0)
                ? 0.0
                : 1 -
                    Curves.easeOut.transform(
                      (_play.value / 0.28).clamp(0.0, 1.0),
                    );
            return Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Transform.scale(
                    scale: scale,
                    child: SizedBox(
                      width: dest.width,
                      height: dest.height,
                      child: Image(
                        image: AssetImage(widget.asset),
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
                if (flash > 0)
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: dest.width,
                        height: dest.height,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(36),
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.38 * flash),
                              _OnboardingLook.accent.withValues(alpha: 0.10 * flash),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_play.value > 0 && _play.value < 1)
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _RecipeBurstPainter(
                        t: _play.value,
                        sparks: _sparks,
                        blooms: _blooms,
                        dest: dest,
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _BurstSpark {
  const _BurstSpark({
    required this.origin,
    required this.angle,
    required this.speed,
    required this.size,
    required this.color,
    required this.kind,
    required this.spin,
    required this.delay,
    required this.life,
    required this.gravity,
  });

  final Offset origin;
  final double angle;
  final double speed;
  final double size;
  final Color color;
  final int kind;
  final double spin;
  final double delay;
  final double life;
  final double gravity;
}

class _BurstBloom {
  const _BurstBloom({
    required this.origin,
    required this.delay,
    required this.color,
  });

  final Offset origin;
  final double delay;
  final Color color;
}

class _RecipeBurstPainter extends CustomPainter {
  const _RecipeBurstPainter({
    required this.t,
    required this.sparks,
    required this.blooms,
    required this.dest,
  });

  final double t;
  final List<_BurstSpark> sparks;
  final List<_BurstBloom> blooms;
  final Rect dest;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final windDown = 1 - Curves.easeIn.transform(((t - 0.58) / 0.34).clamp(0.0, 1.0));
    if (windDown <= 0) return;

    for (final bloom in blooms) {
      final local = ((t - bloom.delay) / 0.42).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final p = Curves.easeOut.transform(local);
      final origin = Offset(
        dest.left + dest.width * bloom.origin.dx,
        dest.top + dest.height * bloom.origin.dy,
      );
      canvas.drawCircle(
        origin,
        lerpDouble(10, dest.width * 0.42, p)!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lerpDouble(5, 0.4, p)!
          ..color = bloom.color.withValues(alpha: (1 - p) * 0.55 * windDown),
      );
    }

    for (final spark in sparks) {
      final local = ((t - spark.delay) / spark.life).clamp(0.0, 1.0);
      if (local <= 0 || local >= 1) continue;
      final ease = Curves.easeOutCubic.transform(local);
      final origin = Offset(
        dest.left + dest.width * spark.origin.dx,
        dest.top + dest.height * spark.origin.dy,
      );
      final travel = dest.shortestSide * spark.speed * ease;
      final pos = Offset(
        origin.dx + math.cos(spark.angle) * travel,
        origin.dy +
            math.sin(spark.angle) * travel +
            dest.height * spark.gravity * local * local,
      );
      final fade = Curves.easeIn.transform(1 - local) * windDown;
      final paint = Paint()
        ..color = spark.color.withValues(alpha: fade)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(spark.spin * local);
      switch (spark.kind) {
        case 0:
          canvas.drawCircle(Offset.zero, spark.size, paint);
        case 1:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset.zero,
                width: spark.size * 1.8,
                height: spark.size * 0.7,
              ),
              const Radius.circular(2),
            ),
            paint,
          );
        case 2:
          _drawStar(canvas, spark.size * 1.3, paint);
        default:
          canvas.drawCircle(Offset.zero, spark.size * 0.55, paint);
          canvas.drawLine(
            Offset(-spark.size * 1.6, 0),
            Offset(spark.size * 1.6, 0),
            paint
              ..strokeWidth = 1.4
              ..style = PaintingStyle.stroke,
          );
      }
      canvas.restore();
    }
  }

  void _drawStar(Canvas canvas, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * math.pi / 2;
      final p = Offset(math.cos(a) * r, math.sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      final b = a + math.pi / 4;
      path.lineTo(math.cos(b) * r * 0.38, math.sin(b) * r * 0.38);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_RecipeBurstPainter oldDelegate) {
    return oldDelegate.t != t || oldDelegate.dest != dest;
  }
}

class _GuidePageActive extends InheritedWidget {
  const _GuidePageActive({
    required this.active,
    required super.child,
  });

  final bool active;

  static bool of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_GuidePageActive>()?.active ??
        true;
  }

  @override
  bool updateShouldNotify(_GuidePageActive oldWidget) {
    return oldWidget.active != active;
  }
}

/// 목업의 한 지점을 확대하고, 눌러 보라는 물결을 보여 준다.
class _GuideHotspotShot extends StatefulWidget {
  const _GuideHotspotShot({
    required this.asset,
    required this.hotspot,
    required this.startDelay,
    required this.iconRadiusFrac,
    this.zoomHotspot,
    this.imageSize = const Size(354, 728),
    this.zoom = 1.62,
    this.showCore = true,
    this.pillSize,
    this.ripples,
    this.pinLeft,
  });

  final String asset;
  final Size imageSize;
  final Offset hotspot;
  final Offset? zoomHotspot;
  final Duration startDelay;
  final double iconRadiusFrac;
  final double zoom;
  final bool showCore;
  final Size? pillSize;
  final List<Offset>? ripples;
  final double? pinLeft;

  @override
  State<_GuideHotspotShot> createState() => _GuideHotspotShotState();
}

class _GuideHotspotShotState extends State<_GuideHotspotShot>
    with TickerProviderStateMixin {
  late final AnimationController _zoom;
  late final AnimationController _pulse;
  Timer? _start;
  var _active = false;

  @override
  void initState() {
    super.initState();
    _zoom = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 860),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = _GuidePageActive.of(context);
    if (active == _active) return;
    _active = active;
    if (active) {
      _arm();
    } else {
      _disarm();
    }
  }

  void _arm() {
    _start?.cancel();
    _zoom
      ..stop()
      ..value = 0;
    _pulse
      ..stop()
      ..value = 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _zoom.value = 1;
      return;
    }
    _start = Timer(widget.startDelay, () {
      if (!mounted || !_active) return;
      _zoom.forward();
      _pulse.repeat();
    });
  }

  void _disarm() {
    _start?.cancel();
    _zoom
      ..stop()
      ..value = 0;
    _pulse
      ..stop()
      ..value = 0;
  }

  @override
  void dispose() {
    _start?.cancel();
    _zoom.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dest = Alignment.center.inscribe(
          applyBoxFit(
            BoxFit.contain,
            widget.imageSize,
            constraints.biggest,
          ).destination,
          Offset.zero & constraints.biggest,
        );
        final hotspot = Offset(
          dest.left + dest.width * widget.hotspot.dx,
          dest.top + dest.height * widget.hotspot.dy,
        );
        final zoomAt = widget.zoomHotspot ?? widget.hotspot;
        var zoomX = zoomAt.dx;
        if (widget.pinLeft != null && widget.zoom > 1) {
          final gap = dest.left / dest.width;
          zoomX = (gap + widget.pinLeft! * widget.zoom) / (widget.zoom - 1);
        }
        final zoomPoint = Offset(
          dest.left + dest.width * zoomX,
          dest.top + dest.height * zoomAt.dy,
        );
        final iconR = dest.width * widget.iconRadiusFrac;
        final pill = widget.pillSize == null
            ? null
            : Size(
                dest.width * widget.pillSize!.width,
                dest.height * widget.pillSize!.height,
              );
        final padX = pill == null ? iconR * 2.6 : pill.width / 2 + 26;
        final padY = pill == null ? iconR * 2.6 : pill.height / 2 + 34;
        final zoomAlign = Alignment(
          (zoomPoint.dx / constraints.maxWidth) * 2 - 1,
          (zoomPoint.dy / constraints.maxHeight) * 2 - 1,
        );
        return ClipRect(
          child: AnimatedBuilder(
            animation: Listenable.merge([_zoom, _pulse]),
            builder: (context, _) {
              final zoomT = Curves.easeInOutCubic.transform(_zoom.value);
              final scale = lerpDouble(1.0, widget.zoom, zoomT)!;
              return Transform.scale(
                scale: scale,
                alignment: zoomAlign,
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: dest,
                      child: Image(
                        image: AssetImage(widget.asset),
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                    if (widget.ripples == null)
                      Positioned(
                        left: hotspot.dx - padX,
                        top: hotspot.dy - padY,
                        width: padX * 2,
                        height: padY * 2,
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _ShareRipplePainter(
                              t: _pulse.value,
                              reveal: zoomT,
                              color: _OnboardingLook.accent,
                              iconR: iconR,
                              showCore: widget.showCore,
                              pillSize: pill,
                            ),
                          ),
                        ),
                      )
                    else
                      Positioned.fromRect(
                        rect: dest,
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _MultiCircleRipplePainter(
                              t: _pulse.value,
                              reveal: zoomT,
                              color: _OnboardingLook.accent,
                              iconR: iconR,
                              points: [
                                for (final p in widget.ripples!)
                                  Offset(
                                    dest.width * p.dx,
                                    dest.height * p.dy,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ShareRipplePainter extends CustomPainter {
  const _ShareRipplePainter({
    required this.t,
    required this.reveal,
    required this.color,
    required this.iconR,
    this.showCore = true,
    this.pillSize,
  });

  final double t;
  final double reveal;
  final Color color;
  final double iconR;
  final bool showCore;
  final Size? pillSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final fade = Curves.easeOut.transform(reveal.clamp(0.0, 1.0));
    final breathe = 1 - (2 * t - 1).abs();

    if (pillSize != null) {
      _paintPill(canvas, center, fade, breathe);
      return;
    }

    final coreR = lerpDouble(iconR * 1.08, iconR * 1.32, breathe)!;

    if (showCore) {
      canvas.drawCircle(
        center,
        coreR,
        Paint()..color = Colors.white.withValues(alpha: 0.22 * fade),
      );
    }
    canvas.drawCircle(
      center,
      coreR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (iconR * 0.12).clamp(1.2, 2.2)
        ..color = Colors.white.withValues(alpha: 0.85 * fade),
    );

    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final wave = Curves.easeOut.transform(p);
      canvas.drawCircle(
        center,
        lerpDouble(iconR * 1.18, iconR * 2.55, wave)!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lerpDouble(iconR * 0.20, iconR * 0.04, wave)!
          ..color = Color.lerp(
            Colors.white,
            color,
            0.35 + 0.25 * wave,
          )!.withValues(alpha: (1 - wave) * 0.55 * fade),
      );
    }
  }

  void _paintPill(Canvas canvas, Offset center, double fade, double breathe) {
    final pill = pillSize!;
    final capR = pill.height / 2;
    canvas.drawCircle(
      center,
      lerpDouble(capR * 0.95, capR * 1.12, breathe)!,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = Colors.white.withValues(alpha: 0.28 * fade),
    );
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final wave = Curves.easeOut.transform(p);
      canvas.drawCircle(
        center,
        lerpDouble(capR * 1.08, capR * 2.4, wave)!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lerpDouble(2.1, 0.5, wave)!
          ..color = Color.lerp(
            Colors.white,
            color,
            0.35 + 0.25 * wave,
          )!.withValues(alpha: (1 - wave) * 0.5 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_ShareRipplePainter oldDelegate) {
    return oldDelegate.t != t ||
        oldDelegate.reveal != reveal ||
        oldDelegate.color != color ||
        oldDelegate.iconR != iconR ||
        oldDelegate.showCore != showCore ||
        oldDelegate.pillSize != pillSize;
  }
}

class _MultiCircleRipplePainter extends CustomPainter {
  const _MultiCircleRipplePainter({
    required this.t,
    required this.reveal,
    required this.color,
    required this.iconR,
    required this.points,
  });

  final double t;
  final double reveal;
  final Color color;
  final double iconR;
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    final fade = Curves.easeOut.transform(reveal.clamp(0.0, 1.0));
    for (var i = 0; i < points.length; i++) {
      final localT = (t + i * 0.18) % 1.0;
      final breathe = 1 - (2 * localT - 1).abs();
      final center = points[i];
      final coreR = lerpDouble(iconR * 1.05, iconR * 1.28, breathe)!;
      canvas.drawCircle(
        center,
        coreR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (iconR * 0.14).clamp(1.2, 2.0)
          ..color = Colors.white.withValues(alpha: 0.88 * fade),
      );
      for (var w = 0; w < 3; w++) {
        final p = (localT + w / 3) % 1.0;
        final wave = Curves.easeOut.transform(p);
        canvas.drawCircle(
          center,
          lerpDouble(iconR * 1.15, iconR * 2.45, wave)!,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = lerpDouble(iconR * 0.18, iconR * 0.04, wave)!
            ..color = Color.lerp(
              Colors.white,
              color,
              0.35 + 0.25 * wave,
            )!.withValues(alpha: (1 - wave) * 0.52 * fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MultiCircleRipplePainter oldDelegate) {
    return oldDelegate.t != t ||
        oldDelegate.reveal != reveal ||
        oldDelegate.iconR != iconR ||
        oldDelegate.points != points;
  }
}

class _AskPage extends StatelessWidget {
  const _AskPage({
    required this.title,
    required this.child,
    this.hint,
    this.titleWidget,
  });

  final String title;
  final String? hint;
  final Widget child;
  final Widget? titleWidget;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
      children: [
        titleWidget ?? _TitleLine(text: title),
        if (hint != null) ...[
          const SizedBox(height: 8),
          _TypedText(
            text: hint!,
            style: _OnboardingLook.hintStyle,
            delay: _typingDelayAfter(title),
          ),
        ],
        const SizedBox(height: 28),
        child,
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: _OnboardingLook.labelStyle);
  }
}

class _NicknameField extends StatelessWidget {
  const _NicknameField({
    required this.nameController,
    required this.handleController,
    required this.onCycle,
    required this.handleValid,
    this.handleReadOnly = false,
  });

  final TextEditingController nameController;
  final TextEditingController handleController;
  final VoidCallback onCycle;
  final bool handleValid;
  final bool handleReadOnly;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('닉네임', style: _OnboardingLook.labelStyle),
        const SizedBox(height: 8),
        TextField(
          controller: nameController,
          maxLength: 15,
          textInputAction: TextInputAction.next,
          cursorColor: _OnboardingLook.accent,
          style: _OnboardingLook.inputStyle,
          decoration: InputDecoration(
            counterText: '',
            hintText: '예: 귀여운감자427',
            hintStyle: const TextStyle(
              fontFamily: 'Pretendard',
              color: _OnboardingLook.muted,
              fontWeight: FontWeight.w500,
            ),
            filled: true,
            fillColor: const Color(0xFFF8F8F8),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _OnboardingLook.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _OnboardingLook.accent, width: 1.2),
            ),
            suffixIcon: IconButton(
              icon: const Icon(
                Icons.autorenew_rounded,
                color: AppColors.primary,
                size: 22,
              ),
              onPressed: onCycle,
              tooltip: '다른 닉네임 보기',
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text('아이디', style: _OnboardingLook.labelStyle),
        const SizedBox(height: 8),
        TextField(
          controller: handleController,
          readOnly: handleReadOnly,
          textInputAction: TextInputAction.done,
          cursorColor: _OnboardingLook.accent,
          style: _OnboardingLook.inputStyle,
          decoration: InputDecoration(
            hintText: 'cute_potato427',
            hintStyle: const TextStyle(
              fontFamily: 'Pretendard',
              color: _OnboardingLook.muted,
              fontWeight: FontWeight.w500,
            ),
            prefixText: '@',
            prefixStyle: const TextStyle(
              fontFamily: 'Pretendard',
              color: _OnboardingLook.ink,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            filled: true,
            fillColor: const Color(0xFFF4F4F6),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _OnboardingLook.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _OnboardingLook.accent, width: 1.2),
            ),
            suffixIcon: handleValid
                ? const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 20)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '아이디는 나중에 변경할 수 있습니다',
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: _OnboardingLook.muted,
            fontSize: 12,
            height: 1.45,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

class _OptionList extends StatelessWidget {
  const _OptionList({
    required this.choices,
    required this.selectedIds,
    required this.onTap,
    this.columns,
    this.maxLines = 1,
    this.tiles = false,
  });

  final List<OnboardingChoice> choices;
  final Set<String> selectedIds;
  final ValueChanged<String> onTap;
  final int? columns;
  final int maxLines;
  final bool tiles;

  Widget _chip(OnboardingChoice choice, {required bool expanded, required int index}) {
    return _RiseIn(
      key: ValueKey(choice.id),
      delay: Duration(milliseconds: 180 + index * 42),
      child: _ChoiceChip(
        choice: choice,
        selected: selectedIds.contains(choice.id),
        onTap: () => onTap(choice.id),
        expanded: expanded,
        maxLines: maxLines,
        tile: tiles,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (columns == null || columns! <= 1) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < choices.length; i++)
            _chip(choices[i], expanded: false, index: i),
        ],
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < choices.length; i += columns!) {
      final end = (i + columns!).clamp(0, choices.length);
      final rowChoices = choices.sublist(i, end);
      final lastSpan =
          tiles && end >= choices.length && rowChoices.length < columns!;
      rows.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: end < choices.length ? 8 : 0,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (lastSpan)
                  Expanded(
                    child: _chip(rowChoices.first, expanded: true, index: i),
                  )
                else
                  for (var j = 0; j < columns!; j++) ...[
                    if (j > 0) const SizedBox(width: 8),
                    Expanded(
                      child: j < rowChoices.length
                          ? _chip(rowChoices[j], expanded: true, index: i + j)
                          : const SizedBox.shrink(),
                    ),
                  ],
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _RiseIn extends StatefulWidget {
  const _RiseIn({
    super.key,
    required this.delay,
    required this.child,
    this.active = true,
    this.hiddenOffset = const Offset(0, 0.28),
    this.duration = const Duration(milliseconds: 420),
  });

  final Duration delay;
  final Widget child;
  final bool active;
  final Offset hiddenOffset;
  final Duration duration;

  @override
  State<_RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<_RiseIn> {
  var _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.active) {
      _shown = true;
      return;
    }
    _schedule(widget.delay);
  }

  @override
  void didUpdateWidget(_RiseIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _timer?.cancel();
      setState(() => _shown = false);
      _schedule(widget.delay);
    }
  }

  void _schedule(Duration delay) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() => _shown = true);
        return;
      }
      _timer?.cancel();
      _timer = Timer(delay, () {
        if (mounted) setState(() => _shown = true);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: Duration(milliseconds: widget.duration.inMilliseconds.clamp(0, 400)),
      curve: Curves.easeOutCubic,
      opacity: _shown ? 1 : 0,
      child: AnimatedSlide(
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        offset: _shown ? Offset.zero : widget.hiddenOffset,
        child: widget.child,
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.choice,
    required this.selected,
    required this.onTap,
    this.expanded = false,
    this.maxLines = 1,
    this.tile = false,
  });

  final OnboardingChoice choice;
  final bool selected;
  final VoidCallback onTap;
  final bool expanded;
  final int maxLines;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final caption = choice.caption;
    final label = caption == null || caption.isEmpty
        ? choice.label
        : '${choice.label} · $caption';
    final radius = tile ? 16.0 : 14.0;
    final chip = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            gradient: selected ? _OnboardingLook.borderGradient : null,
            color: selected ? null : Colors.white,
            borderRadius: BorderRadius.circular(radius),
            border: selected ? null : Border.all(color: _OnboardingLook.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          padding: EdgeInsets.all(selected ? 1.5 : 0),
          child: Container(
            width: expanded ? double.infinity : null,
            constraints: tile ? const BoxConstraints(minHeight: 56) : null,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
              horizontal: tile ? 14 : 12,
              vertical: tile ? 12 : 10,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(
                selected ? radius - 1.5 : radius,
              ),
            ),
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (choice.iconAsset != null || choice.emoji.isNotEmpty) ...[
                  _ChipIcon(choice: choice),
                  const SizedBox(width: 8),
                ],
                if (expanded)
                  Flexible(
                    child: Text(
                      _keepEojeol(label),
                      textAlign: TextAlign.center,
                      maxLines: maxLines,
                      overflow: maxLines == 1
                          ? TextOverflow.ellipsis
                          : TextOverflow.visible,
                      style: _OnboardingLook.chipStyle.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  )
                else
                  Text(
                    _keepEojeol(label),
                    style: _OnboardingLook.chipStyle.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (expanded) return chip;
    return IntrinsicWidth(child: chip);
  }
}

class _ChipIcon extends StatelessWidget {
  const _ChipIcon({required this.choice});

  final OnboardingChoice choice;

  @override
  Widget build(BuildContext context) {
    const size = 22.0;
    final asset = choice.iconAsset;
    if (asset != null && asset.isNotEmpty) {
      final iconSize = choice.id == 'naver_blog' ? 16.0 : size;
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(choice.id == 'naver_blog' ? 4 : 6),
            child: Image.asset(
              asset,
              width: iconSize,
              height: iconSize,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          choice.emoji.isEmpty ? '•' : choice.emoji,
          style: const TextStyle(fontSize: 16, height: 1),
        ),
      ),
    );
  }
}
