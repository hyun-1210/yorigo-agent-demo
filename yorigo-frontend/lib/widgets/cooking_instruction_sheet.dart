import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import '../models/recipe_models.dart' as models;
import '../services/analytics_service.dart';
import '../utils/recipe_signal_snapshot.dart';
import 'progressive_recipe_review_sheet.dart';
import 'youtube_player_widget.dart';
import 'instagram_player_widget.dart';
import 'tiktok_player_widget.dart';
import 'inline_video_hero_poster.dart';
import '../utils/youtube_utils.dart';
import '../utils/inline_media_webview.dart';
import '../utils/instagram_utils.dart';
import '../utils/tiktok_utils.dart';
import '../utils/recipe_wait_timer.dart';
import '../utils/recipe_thumbnail_resolver.dart';

class _StepSegment {
  final double startSec;
  final double endSec;
  const _StepSegment(this.startSec, this.endSec);
}

enum _CookTimerPhase { idle, running, paused, done }

class CookingInstructionSheet extends StatefulWidget {
  final models.Recipe recipe;
  final String? recipeId;
  final Map<String, dynamic>? source;

  /// 사용자 로컬 메모 (옵셔널). 길이는 [recipe.steps] 와 동일해야 한다.
  /// null 이거나 길이가 다르면 메모는 무시된다.
  final List<String>? stepMemos;

  /// 레시피 전체 메모 (옵셔널, 빈 문자열이면 표시 안 함).
  final String? recipeMemo;

  const CookingInstructionSheet({
    super.key,
    required this.recipe,
    this.recipeId,
    this.source,
    this.stepMemos,
    this.recipeMemo,
  });

  @override
  State<CookingInstructionSheet> createState() =>
      _CookingInstructionSheetState();
}

class _CookingInstructionSheetState extends State<CookingInstructionSheet>
    with SingleTickerProviderStateMixin {
  int _currentStepIndex = 0;
  final Set<int> _impressedCookingStepIndices = <int>{};
  late final PageController _pageController;
  late final AnimationController _splitAnim;
  static const double _kVideoDefault = 4 / 7;
  static const double _kVideoMin = 0.24;
  static const double _kSheetHandle = 28;
  static const double _kPeekHeader = 48;
  static const double _kPeekNav = 70;
  String? _youtubeVideoId;
  YouTubePlayerHandle? _playerHandle;

  // Instagram/TikTok 인라인 임베드 상태.
  // - Instagram: video element 직접 제어 가능 → handle을 통해 음성 명령
  //   (다시/멈춰/재생)을 영상에도 반영. audio focus guard도 동일 handle에서.
  // - TikTok: cross-origin iframe이라 외부 제어 불가. 음성 명령은 영상 무시
  //   하고 카드만 이동.
  ({String type, String shortcode})? _instagramTarget;
  String? _tiktokVideoUrl;
  InstagramPlayerHandle? _instagramHandle;

  // Step segment playback
  List<_StepSegment?> _stepSegments = [];
  Timer? _segmentPollTimer;
  Timer? _segmentPlayDelayTimer;
  int _segmentPlaybackGen = 0;
  static const double _minSegmentDuration = 2.0;

  // Voice recognition
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  Timer? _voiceWatchdog;

  // Voice onboarding popup (shown every time 요리 시작 flow opens)
  bool _showVoiceOnboarding = false;
  Timer? _onboardingAnimTimer;
  bool _onboardingBtnActive = false;

  Timer? _cookTimer;
  int? _cookTimerTotalSec;
  int _cookTimerLeftSec = 0;
  DateTime? _cookTimerEndsAt;
  _CookTimerPhase _cookTimerPhase = _CookTimerPhase.idle;
  int? _cookTimerPageIndex;
  bool _cookTimerExpanded = false;

  @override
  void initState() {
    super.initState();
    final source = widget.source ?? {};
    final sourceUrl = source['url'] as String? ?? '';
    final platform = (source['platform'] as String? ?? '').toLowerCase();
    if (platform == 'youtube' || isYouTubeUrl(sourceUrl)) {
      final videoId = extractYouTubeVideoId(sourceUrl);
      if (videoId != null) {
        _youtubeVideoId = videoId;
      }
    } else if (platform == 'instagram' ||
        platform == 'instagramweb' ||
        isInstagramUrl(sourceUrl)) {
      final igTarget = extractInstagramShortcode(sourceUrl);
      if (igTarget != null) {
        _instagramTarget = igTarget;
      }
    } else if (platform == 'tiktok' ||
        platform == 'tiktokweb' ||
        isTikTokUrl(sourceUrl)) {
      if (sourceUrl.isNotEmpty) {
        _tiktokVideoUrl = sourceUrl;
      }
    }
    _pageController = PageController();
    _splitAnim = AnimationController(
      vsync: this,
      value: _kVideoDefault,
      lowerBound: _kVideoMin,
      upperBound: 1.0,
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _computeStepSegments();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkVoiceOnboarding();
      _startStepDwell(_currentStepIndex);
      _logCookingStepImpressionOnce(_currentStepIndex);
    });
  }

  DateTime? _stepDwellStartedAt;
  int _stepDwellIndex = 0;

  void _startStepDwell(int index) {
    _stepDwellStartedAt = DateTime.now();
    _stepDwellIndex = index;
  }

  void _flushStepDwell() {
    final started = _stepDwellStartedAt;
    _stepDwellStartedAt = null;
    if (started == null) return;
    final recipeId = widget.recipeId?.trim() ?? '';
    if (recipeId.isEmpty) return;
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    unawaited(
      AnalyticsService().trackCookingStepDwell(
        recipeId: recipeId,
        stepIndex: _stepDwellIndex,
        durationMs: durationMs,
        contentType:
            _stepDwellIndex == 0 ? 'cooking_intro' : 'cooking_step',
      ),
    );
  }

  /// 조리 시작(재료 요약) 화면 + 스텝별 화면 impression을 스텝당 1회만 기록.
  void _logCookingStepImpressionOnce(int stepIndex) {
    if (_impressedCookingStepIndices.contains(stepIndex)) return;
    _impressedCookingStepIndices.add(stepIndex);
    unawaited(
      _logCookingSignal(
        'impression',
        sectionId: 'cooking_step',
        contentType: _isIngredientRoundupPage ? 'cooking_intro' : 'cooking_step',
        cardId: 'step_$stepIndex',
        position: stepIndex,
      ),
    );
  }

  String _cookingVideoPlatform() {
    final source = widget.source ?? const <String, dynamic>{};
    final platform = (source['platform'] as String? ?? '').trim();
    return platform.isEmpty ? 'unknown' : platform;
  }

  void _trackCookingVideoPlay() {
    final recipeId = widget.recipeId?.trim() ?? '';
    if (recipeId.isEmpty) return;
    unawaited(
      AnalyticsService().trackVideoPlay(
        recipeId: recipeId,
        screen: 'cooking_mode',
        platform: _cookingVideoPlatform(),
      ),
    );
  }

  void _trackCookingVideoWatchEnded(int durationMs) {
    final recipeId = widget.recipeId?.trim() ?? '';
    if (recipeId.isEmpty) return;
    unawaited(
      AnalyticsService().trackVideoWatchEnded(
        recipeId: recipeId,
        durationMs: durationMs,
        screen: 'cooking_mode',
        platform: _cookingVideoPlatform(),
      ),
    );
  }

  /// [widget.source]에서 레시피 스냅샷(카테고리/태그/플랫폼 등)을 추출해
  /// 카드 단위 행동 시그널로 기록한다.
  Future<void> _logCookingSignal(
    String eventType, {
    String? sectionId,
    String? contentType,
    String? cardId,
    int? position,
  }) {
    final snapshot = RecipeSignalSnapshot.fromRecipeMap(<String, dynamic>{
      'source': widget.source ?? const <String, dynamic>{},
      'servings': widget.recipe.servings,
    });
    return AnalyticsService().logCardEvent(
      eventType,
      screen: 'cooking_mode',
      sectionId: sectionId,
      cardId: cardId,
      contentType: contentType,
      recipeId: widget.recipeId,
      position: position,
      recipeCuisineType: snapshot.cuisineType,
      recipeTimeCategory: snapshot.timeCategory,
      recipeMenuType: snapshot.menuType,
      recipeMainIngredient: snapshot.mainIngredient,
      recipeMainIngredientSub: snapshot.mainIngredientSub,
      recipeTags: snapshot.tags,
      recipeNutritionRating: snapshot.nutritionRating,
      recipeSourcePlatform: snapshot.sourcePlatform,
      recipeServings: snapshot.servings,
    );
  }

  @override
  void dispose() {
    _flushStepDwell();
    _segmentPollTimer?.cancel();
    _segmentPlayDelayTimer?.cancel();
    _segmentPlaybackGen++;
    _voiceWatchdog?.cancel();
    _onboardingAnimTimer?.cancel();
    if (_isListening) {
      _speech.stop();
      _playerHandle?.setPlaybackGuard(false);
      _instagramHandle?.setPlaybackGuard(false);
    }
    _cookTimer?.cancel();
    _pageController.dispose();
    _splitAnim.dispose();
    super.dispose();
  }

  // ─── Step segment computation ──────────────────────────────────────

  void _computeStepSegments() {
    final steps = widget.recipe.steps;
    _stepSegments = List<_StepSegment?>.filled(steps.length, null);

    for (int i = 0; i < steps.length; i++) {
      final startSec = steps[i].startSec;
      if (startSec == null) continue;

      final start = startSec.toDouble();

      // Find the next step with a DIFFERENT startSec
      double? endSec;
      for (int j = i + 1; j < steps.length; j++) {
        final nextStart = steps[j].startSec;
        if (nextStart != null && nextStart != startSec) {
          endSec = nextStart.toDouble();
          break;
        }
      }

      // Last unique timestamp group: play 15 seconds or to end
      endSec ??= start + 15.0;

      // Enforce minimum duration
      if (endSec - start < _minSegmentDuration) {
        endSec = start + _minSegmentDuration;
      }

      // Extend end by 1.5s to account for slight timestamp inaccuracy
      endSec += 1.5;

      _stepSegments[i] = _StepSegment(start, endSec);
    }
  }

  bool _segmentEnteredRange = false;

  void _applyPlaybackGuardIfListening() {
    _instagramHandle?.setHalted(false);
    if (!_isListening) return;
    _playerHandle?.setPlaybackGuard(true);
    _instagramHandle?.setPlaybackGuard(true);
  }

  /// User paused via native player controls — stay paused, keep position.
  void _pauseWithinSegment() {
    _segmentPollTimer?.cancel();
    _segmentPlayDelayTimer?.cancel();
    _playerHandle?.setPlaybackGuard(false);
    _instagramHandle?.setPlaybackGuard(false);
    _instagramHandle?.setHalted(true);
  }

  /// Stops segment polling and pauses video so voice/UI pause is not overridden.
  void _haltSegmentPlayback() {
    _segmentPollTimer?.cancel();
    _segmentPlayDelayTimer?.cancel();
    _segmentPlaybackGen++;
    _segmentEnteredRange = false;
    _playerHandle?.setPlaybackGuard(false);
    _instagramHandle?.setPlaybackGuard(false);
    _instagramHandle?.setHalted(true);
    _instagramHandle?.pause();
    _playerHandle?.pause();
  }

  /// Replays the current slide's step segment (1s before start → auto-pause at end).
  void _replayCurrentStepSegment() {
    if (_isIngredientRoundupPage) return;
    _playCurrentSegment();
  }

  /// Resumes from the current position; segment polling still stops at step end.
  Future<void> _resumeSegmentPlayback() async {
    final stepIdx = _recipeStepIndex;
    if (stepIdx < 0 || stepIdx >= _stepSegments.length) {
      _applyPlaybackGuardIfListening();
      _instagramHandle?.play();
      _playerHandle?.play();
      return;
    }

    final segment = _stepSegments[stepIdx];
    if (segment == null) {
      _applyPlaybackGuardIfListening();
      _instagramHandle?.play();
      _playerHandle?.play();
      return;
    }

    _segmentPollTimer?.cancel();
    _segmentPlayDelayTimer?.cancel();
    final gen = ++_segmentPlaybackGen;
    _applyPlaybackGuardIfListening();

    double t = 0;
    if (_playerHandle != null) {
      t = await _playerHandle!.getCurrentTime();
      _playerHandle!.play();
    } else if (_instagramHandle != null) {
      t = await _instagramHandle!.getCurrentTime();
      _instagramHandle!.play();
    } else {
      return;
    }

    if (!mounted || gen != _segmentPlaybackGen) return;

    _segmentEnteredRange = t >= segment.startSec - 1.5 && t < segment.endSec;
    _startSegmentPolling(
      startSec: segment.startSec,
      endSec: segment.endSec,
      gen: gen,
    );
  }

  void _playCurrentSegment() {
    final stepIdx = _recipeStepIndex;
    if (stepIdx < 0 || stepIdx >= _stepSegments.length) return;

    final segment = _stepSegments[stepIdx];
    if (segment == null) return;

    _segmentPollTimer?.cancel();
    _segmentPlayDelayTimer?.cancel();
    final gen = ++_segmentPlaybackGen;
    _segmentEnteredRange = false;

    final ytHandle = _playerHandle;
    final igHandle = _instagramHandle;

    final seekTarget = (segment.startSec - 1.0).clamp(0.0, double.infinity);
    _applyPlaybackGuardIfListening();

    if (ytHandle != null) {
      ytHandle.pause();
      ytHandle.seekTo(seekTarget);
      ytHandle.play();
    } else if (igHandle != null) {
      igHandle.seekToAndPlay(seekTarget);
    } else {
      return;
    }

    _segmentPlayDelayTimer = Timer(const Duration(milliseconds: 500), () {
      _segmentPlayDelayTimer = null;
      if (!mounted || gen != _segmentPlaybackGen) return;
      _startSegmentPolling(
        startSec: segment.startSec,
        endSec: segment.endSec,
        gen: gen,
      );
    });
  }

  void _startSegmentPolling({
    required double startSec,
    required double endSec,
    required int gen,
  }) {
    _segmentPollTimer?.cancel();
    _segmentPollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) async {
        if (!mounted || gen != _segmentPlaybackGen) {
          _segmentPollTimer?.cancel();
          return;
        }

        double t;
        VoidCallback? pauseFn;
        if (_playerHandle != null) {
          t = await _playerHandle!.getCurrentTime();
          pauseFn = _playerHandle!.pause;
        } else if (_instagramHandle != null) {
          t = await _instagramHandle!.getCurrentTime();
          pauseFn = _instagramHandle!.pause;
        } else {
          _segmentPollTimer?.cancel();
          return;
        }

        if (!_segmentEnteredRange) {
          if (t >= startSec - 1.5 && t < endSec) {
            _segmentEnteredRange = true;
          }
          return;
        }

        if (t >= endSec) {
          pauseFn();
          _segmentPollTimer?.cancel();
        }
      },
    );
  }

  // ─── Voice recognition ─────────────────────────────────────────────

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _restartListening();
          }
        },
        onError: (error) {
          debugPrint('[Voice] $error');
          // 시뮬레이터/미설치 음성 엔진은 permanent 에러를 반복한다.
          if (error.permanent) {
            _stopVoiceListening(available: false);
            return;
          }
          _restartListening();
        },
      );
    } catch (e) {
      debugPrint('[Voice] init failed: $e');
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  void _stopVoiceListening({bool available = true}) {
    _voiceWatchdog?.cancel();
    _voiceWatchdog = null;
    try {
      _speech.stop();
    } catch (_) {}
    _playerHandle?.setPlaybackGuard(false);
    _instagramHandle?.setPlaybackGuard(false);
    _speechAvailable = available;
    if (!mounted) return;
    if (_isListening || !available) {
      setState(() => _isListening = false);
    }
  }

  void _restartListening() {
    if (!mounted || !_isListening || !_speechAvailable) return;
    if (_speech.isListening) return;
    try {
      unawaited(
        _speech.listen(
          onResult: (result) {
            if (!result.finalResult) return;
            _handleVoiceCommand(result.recognizedWords.trim().toLowerCase());
          },
          localeId: 'ko_KR',
          listenMode: stt.ListenMode.confirmation,
          cancelOnError: false,
          partialResults: true,
          listenFor: const Duration(minutes: 90),
          pauseFor: const Duration(minutes: 90),
        ).then((_) {}, onError: (Object e) {
          debugPrint('[Voice] listen failed: $e');
          _stopVoiceListening(available: false);
        }),
      );
    } catch (e) {
      debugPrint('[Voice] listen failed: $e');
      _stopVoiceListening(available: false);
    }
  }

  void _toggleVoiceListening() {
    if (_isListening) {
      _stopVoiceListening();
    } else {
      setState(() => _isListening = true);
      _playerHandle?.setPlaybackGuard(true);
      _instagramHandle?.setPlaybackGuard(true);
      _restartListening();
      _voiceWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_isListening) return;
        if (!_speech.isListening) _restartListening();
      });
    }
  }

  /// 음성 명령을 처리한다.
  ///
  /// - "다음 / 이전" → 현재 슬라이드(_currentStepIndex) 기준 카드 이동 + 해당 step 구간 재생
  /// - "다시" → 현재 슬라이드 step 구간 처음부터 (1초 전 ~ 구간 끝에서 자동 정지)
  /// - "멈춰" / "정지" → 재생 정지 (구간 폴링 중단, guard 해제로 일시정지 유지)
  /// - "재생" / "시작" → 현재 위치에서 이어 재생 (구간 끝에서 여전히 자동 정지)
  void _handleVoiceCommand(String text) {
    if (text.isEmpty) return;
    debugPrint('[Voice] "$text"');

    if (_handleTimerVoiceCommand(text)) return;

    if (text.contains('다음 단계') || text == '다음') {
      _goToNextStep();
    } else if (text.contains('전 단계') || text == '이전' || text == '전') {
      _goToPreviousStep();
    } else if (text.contains('다시')) {
      _replayCurrentStepSegment();
    } else if (text.contains('멈춰') || text.contains('정지')) {
      _haltSegmentPlayback();
    } else if (text.contains('재생') || text.contains('시작')) {
      unawaited(_resumeSegmentPlayback());
    }
  }

  bool _handleTimerVoiceCommand(String text) {
    final mentionsTimer = text.contains('타이머');
    if (mentionsTimer &&
        (text.contains('초기화') || text.contains('리셋'))) {
      if (_cookTimerActive) _resetCookTimer();
      return true;
    }
    if (mentionsTimer &&
        (text.contains('꺼') || text.contains('끄') || text.contains('닫'))) {
      if (_cookTimerActive) _dismissCookTimer();
      return true;
    }
    if (mentionsTimer &&
        (text.contains('멈춰') ||
            text.contains('정지') ||
            text.contains('일시'))) {
      if (_cookTimerPhase == _CookTimerPhase.running) _pauseCookTimer();
      return true;
    }
    if (mentionsTimer && (text.contains('계속') || text.contains('재개'))) {
      if (_cookTimerPhase == _CookTimerPhase.paused) _resumeCookTimer();
      return true;
    }
    if (mentionsTimer && text.contains('다시')) {
      if (_cookTimerActive) _restartCookTimer();
      return true;
    }
    if (mentionsTimer && (text.contains('시작') || text == '타이머')) {
      if (_cookTimerActive) {
        _setCookTimerExpanded(true);
      } else {
        final suggestion = _currentTimerSuggestion;
        if (suggestion != null) {
          _startCookTimer(suggestion.seconds, _currentStepIndex);
          _setCookTimerExpanded(true);
        }
      }
      return true;
    }
    if (_cookTimerActive && text == '초기화') {
      _resetCookTimer();
      return true;
    }
    if (_cookTimerPhase == _CookTimerPhase.running && text == '일시정지') {
      _pauseCookTimer();
      return true;
    }
    return false;
  }

  // ─── Voice onboarding popup ────────────────────────────────────────

  void _checkVoiceOnboarding() {
    // initState에서 setState하면 디버그에서 빨간 오류 화면이 뜬다.
    _showVoiceOnboarding = true;
    _startOnboardingAnimation();
  }

  void _startOnboardingAnimation() {
    _onboardingBtnActive = false;
    _onboardingAnimTimer = Timer(const Duration(milliseconds: 2500), () {
      _onboardingAnimTimer = null;
      if (!mounted || !_showVoiceOnboarding) return;
      setState(() => _onboardingBtnActive = true);
    });
  }

  Future<void> _onVoiceOnboardingConfirmed() async {
    _onboardingAnimTimer?.cancel();
    _onboardingAnimTimer = null;

    if (mounted) setState(() => _showVoiceOnboarding = false);

    await _initSpeech();
    if (_speechAvailable && mounted) {
      _toggleVoiceListening();
    }
  }

  // ─── Existing getters ──────────────────────────────────────────────

  int get _totalSteps => widget.recipe.steps.length;
  int get _totalPages => _totalSteps + 1;
  bool get _isIngredientRoundupPage => _currentStepIndex == 0;
  int get _recipeStepIndex => _currentStepIndex - 1;
  ({int seconds, String phrase})? get _currentTimerSuggestion {
    if (_currentStepIndex <= 0 || _currentStepIndex > _totalSteps) return null;
    return RecipeWaitTimer.suggestionFor(
      widget.recipe.steps[_currentStepIndex - 1],
    );
  }
  List<models.Ingredient> get _allIngredients {
    final ingredients = widget.recipe.ingredients;
    if (ingredients.isNotEmpty) return ingredients;
    return const <models.Ingredient>[];
  }

  String _formatIngredient(models.Ingredient ingredient) {
    final name = ingredient.item;
    if (ingredient.qty == null ||
        ingredient.unit == null ||
        ingredient.unit!.isEmpty) {
      return name;
    }
    final qty = ingredient.qty!;
    final qtyText = qty % 1 == 0
        ? qty.toInt().toString()
        : qty.toStringAsFixed(1);
    return '$name $qtyText${ingredient.unit!}';
  }

  int _estimateStepMinutes(models.Step step) {
    final instructionLen = step.instruction.trim().length;
    final ingredientCount = step.stepIngredients?.length ?? 0;
    final hasTip = (step.tip?.trim().isNotEmpty ?? false);
    final raw =
        1.0 +
        (instructionLen / 45.0) +
        (ingredientCount * 0.35) +
        (hasTip ? 0.5 : 0.0);
    return raw.round().clamp(1, 30);
  }

  ({int seconds, String phrase})? _timerSuggestionFor(models.Step step) {
    return RecipeWaitTimer.suggestionFor(step);
  }

  String _formatTimerClock(int seconds) => RecipeWaitTimer.formatClock(seconds);

  String _formatTimerLabel(int seconds) => RecipeWaitTimer.formatLabel(seconds);

  bool get _cookTimerActive => _cookTimerPhase != _CookTimerPhase.idle;

  void _publishCookTimerLeft(int left) {
    _cookTimerLeftSec = left;
  }

  void _setCookTimerExpanded(bool expanded) {
    if (_cookTimerExpanded == expanded) return;
    setState(() => _cookTimerExpanded = expanded);
  }

  void _startCookTimer(int seconds, int pageIndex) {
    final safe = seconds.clamp(1, RecipeWaitTimer.maxSeconds);
    _cookTimer?.cancel();
    setState(() {
      _cookTimerTotalSec = safe;
      _cookTimerPageIndex = pageIndex;
      _cookTimerEndsAt = DateTime.now().add(Duration(seconds: safe));
      _cookTimerPhase = _CookTimerPhase.running;
      _publishCookTimerLeft(safe);
    });
    _ensureCookTimerTicker();
  }

  void _pauseCookTimer() {
    if (_cookTimerPhase != _CookTimerPhase.running) return;
    final left = _remainingCookTimerSeconds();
    _cookTimer?.cancel();
    _cookTimer = null;
    setState(() {
      _cookTimerEndsAt = null;
      _cookTimerPhase = _CookTimerPhase.paused;
      _publishCookTimerLeft(left);
    });
  }

  void _resumeCookTimer() {
    if (_cookTimerPhase != _CookTimerPhase.paused || _cookTimerLeftSec <= 0) {
      return;
    }
    setState(() {
      _cookTimerEndsAt =
          DateTime.now().add(Duration(seconds: _cookTimerLeftSec));
      _cookTimerPhase = _CookTimerPhase.running;
      _publishCookTimerLeft(_cookTimerLeftSec);
    });
    _ensureCookTimerTicker();
  }

  void _resetCookTimer() {
    final total = _cookTimerTotalSec;
    if (total == null) return;
    _cookTimer?.cancel();
    _cookTimer = null;
    setState(() {
      _cookTimerEndsAt = null;
      _cookTimerPhase = _CookTimerPhase.paused;
      _publishCookTimerLeft(total);
    });
  }

  void _restartCookTimer() {
    final total = _cookTimerTotalSec;
    final page = _cookTimerPageIndex ?? _currentStepIndex;
    if (total == null) return;
    _startCookTimer(total, page);
  }

  void _dismissCookTimer() {
    _cookTimer?.cancel();
    _cookTimer = null;
    setState(() {
      _cookTimerTotalSec = null;
      _cookTimerLeftSec = 0;
      _cookTimerEndsAt = null;
      _cookTimerPhase = _CookTimerPhase.idle;
      _cookTimerPageIndex = null;
      _cookTimerExpanded = false;
    });
  }

  int _remainingCookTimerSeconds() {
    if (_cookTimerPhase == _CookTimerPhase.done) return 0;
    if (_cookTimerPhase == _CookTimerPhase.paused) return _cookTimerLeftSec;
    final endsAt = _cookTimerEndsAt;
    if (endsAt == null) return _cookTimerLeftSec;
    return endsAt
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, RecipeWaitTimer.maxSeconds);
  }

  void _ensureCookTimerTicker() {
    _cookTimer?.cancel();
    _cookTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      if (_cookTimerPhase != _CookTimerPhase.running) return;
      final left = _remainingCookTimerSeconds();
      if (left <= 0) {
        _cookTimer?.cancel();
        _cookTimer = null;
        setState(() {
          _cookTimerEndsAt = null;
          _cookTimerPhase = _CookTimerPhase.done;
          _publishCookTimerLeft(0);
        });
        HapticFeedback.heavyImpact();
        _setCookTimerExpanded(true);
        return;
      }
      if (left != _cookTimerLeftSec) {
        setState(() => _publishCookTimerLeft(left));
      }
    });
  }

  void _onNavTimerTap() {
    if (!_cookTimerActive && _currentTimerSuggestion == null) return;
    _setCookTimerExpanded(!_cookTimerExpanded);
  }

  Color _progressColorForIndex(int index) {
    final completedCount = _currentStepIndex + 1;
    if (index >= completedCount) return const Color(0xFFE5E7EB);
    if (completedCount <= 1) return const Color(0xFFFF6B00);
    final t = completedCount == 1 ? 1.0 : index / (completedCount - 1);
    return Color.lerp(const Color(0xFFFFB480), const Color(0xFFFF6B00), t)!;
  }

  Future<void> _openVideoLink() async {
    final source = widget.source ?? {};
    final sourceUrl = source['url'] as String? ?? '';
    final platform = source['platform'] as String? ?? '';

    if (sourceUrl.isEmpty) return;

    final lowerPlatform = platform.toLowerCase();
    final isYouTube = lowerPlatform == 'youtube' || isYouTubeUrl(sourceUrl);
    if (isYouTube) {
      final videoId = extractYouTubeVideoId(sourceUrl);
      if (videoId != null) {
        setState(() {
          _youtubeVideoId = videoId;
        });
        return;
      }
    }

    final isInstagram = lowerPlatform == 'instagram' ||
        lowerPlatform == 'instagramweb' ||
        isInstagramUrl(sourceUrl);
    if (isInstagram) {
      final target = extractInstagramShortcode(sourceUrl);
      if (target != null) {
        setState(() {
          _instagramTarget = target;
        });
        return;
      }
    }

    final isTikTok = lowerPlatform == 'tiktok' ||
        lowerPlatform == 'tiktokweb' ||
        isTikTokUrl(sourceUrl);
    if (isTikTok) {
      setState(() {
        _tiktokVideoUrl = sourceUrl;
      });
      return;
    }

    final uri = Uri.tryParse(sourceUrl);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  double _resolveVideoAspectRatio() {
    final source = widget.source ?? {};
    final sourceUrl = source['url'] as String? ?? '';
    final platform = (source['platform'] as String? ?? '').toLowerCase();
    final isYouTube = platform == 'youtube' || isYouTubeUrl(sourceUrl);
    final isInstagram = platform == 'instagram' || platform == 'instagramweb';
    final isTikTok = platform == 'tiktok' || platform == 'tiktokweb';
    final widthRaw = source['width'];
    final heightRaw = source['height'];
    final widthVal = widthRaw is num ? widthRaw.toDouble() : null;
    final heightVal = heightRaw is num ? heightRaw.toDouble() : null;
    final dimsKnown =
        widthVal != null && heightVal != null && widthVal > 0 && heightVal > 0;
    final isLandscapeYouTube = isLandscapeYouTubeSource(source);
    if (isYouTube) {
      if (!isLandscapeYouTube) return 1.0;
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        final width = MediaQuery.sizeOf(context).width;
        return YoutubeEmbedLayout.iosCinemaVisibleAspectRatio(width);
      }
      return 16 / 9;
    }
    if (isInstagram) return dimsKnown && widthVal > heightVal ? 16 / 9 : 1.0;
    if (isTikTok) {
      if (dimsKnown && widthVal > heightVal) return 16 / 9;
      if (Theme.of(context).platform == TargetPlatform.iOS) return 1.0;
      return 4 / 5;
    }
    return 16 / 9;
  }

  Widget _buildVideoSection() {
    final source = widget.source ?? {};
    final sourceUrl = source['url'] as String? ?? '';
    final platform = source['platform'] as String? ?? '';
    var thumbnailUrl = source['thumbnail'] as String? ?? '';
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      final resolved = RecipeThumbnailResolver.resolve({
        'source': source,
        'platform': source['platform'],
        'sourceUrl': source['url'],
        'thumbnailUrl': source['thumbnailUrl'] ?? source['thumbnail'],
        'thumbnailUrlLarge': source['thumbnailUrlLarge'],
        'thumbnailUrlCropped': source['thumbnailUrlCropped'],
      });
      if (resolved.isNotEmpty) {
        thumbnailUrl = resolved;
      } else if (thumbnailUrl.trim().isEmpty) {
        thumbnailUrl = (source['og_image_url'] as String?)?.trim() ?? '';
      }
    }
    final lowerPlatform = platform.toLowerCase();
    final isYouTube = lowerPlatform == 'youtube' || isYouTubeUrl(sourceUrl);
    final isInstagram =
        lowerPlatform == 'instagram' || lowerPlatform == 'instagramweb';
    final isTikTok = lowerPlatform == 'tiktok' || lowerPlatform == 'tiktokweb';

    final videoAspectRatio = _resolveVideoAspectRatio();

    Widget? inlinePlayer;
    if (isYouTube && _youtubeVideoId != null) {
      inlinePlayer = YouTubePlayerWidget(
        key: ValueKey(
          'yt-cook-${_youtubeVideoId!}-${videoAspectRatio > 1.0 ? 'L' : 'Sp'}',
        ),
        videoId: _youtubeVideoId!,
        autoPlay: false,
        showControls: true,
        thumbnailUrl: thumbnailUrl,
        aspectRatio: videoAspectRatio,
        onFirstPlay: _trackCookingVideoPlay,
        onWatchEnded: _trackCookingVideoWatchEnded,
        onDurationKnown: (durationSec) {
          final id = _youtubeVideoId;
          if (!mounted || id == null) return;
          rememberYouTubePlaybackDuration(id, durationSec);
          if (Theme.of(context).platform != TargetPlatform.iOS) return;
          setState(() {});
        },
        onControllerReady: (handle) {
          _playerHandle = handle;
          if (_isListening) handle.setPlaybackGuard(true);
        },
        onUserPausedInPlayer: _pauseWithinSegment,
        onUserPlayedInPlayer: () => unawaited(_resumeSegmentPlayback()),
        onClose: () {
          setState(() {
            _youtubeVideoId = null;
            _playerHandle = null;
          });
        },
      );
    } else if (isInstagram && _instagramTarget != null) {
      inlinePlayer = InstagramPlayerWidget(
        type: _instagramTarget!.type,
        shortcode: _instagramTarget!.shortcode,
        thumbnailUrl: thumbnailUrl,
        aspectRatio: videoAspectRatio,
        onFirstPlay: _trackCookingVideoPlay,
        onWatchEnded: _trackCookingVideoWatchEnded,
        onControllerReady: (handle) {
          _instagramHandle = handle;
          if (_isListening) handle.setPlaybackGuard(true);
        },
        onUserPausedInPlayer: _pauseWithinSegment,
        onUserPlayedInPlayer: () => unawaited(_resumeSegmentPlayback()),
      );
    } else if (isTikTok && _tiktokVideoUrl != null) {
      inlinePlayer = TikTokPlayerWidget(
        videoUrl: _tiktokVideoUrl!,
        thumbnailUrl: thumbnailUrl,
        aspectRatio: videoAspectRatio,
      );
    }

    final player = inlinePlayer ??
        GestureDetector(
          onTap: _openVideoLink,
          child: InlineVideoHeroPoster(
            thumbnailUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : null,
            backgroundColor: Colors.black,
            imageFit: isYouTube ? BoxFit.cover : BoxFit.contain,
            showInstagramTopTapBlock: false,
            imageHttpHeaders: isInstagram
                ? InlineVideoHeroPoster.instagramThumbnailHeaders
                : null,
          ),
        );

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ar = videoAspectRatio <= 0 ? 16 / 9 : videoAspectRatio;
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          if (maxW <= 0 || maxH <= 0) return const SizedBox.shrink();
          final lift = (_videoFraction / _kVideoDefault).clamp(0.0, 1.0);
          var width = maxW * lift;
          var height = width / ar;
          if (height > maxH) {
            height = maxH;
            width = height * ar;
          }
          if (width > maxW) {
            width = maxW;
            height = width / ar;
          }
          return Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRect(child: player),
            ),
          );
        },
      ),
    );
  }

  void _seekToCurrentStep(int pageIndex) {
    final stepIdx = pageIndex - 1;
    if (stepIdx < 0 || stepIdx >= widget.recipe.steps.length) return;
    _playCurrentSegment();
  }

  void _goToNextStep() {
    if (_currentStepIndex < _totalPages - 1) {
      _goToPage(_currentStepIndex + 1);
    } else {
      _showReviewScreen();
    }
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _totalPages) return;
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    _becomeCookingStep(index);
  }

  void _onCookPageChanged(int index) {
    _becomeCookingStep(index);
  }

  void _becomeCookingStep(int index) {
    if (!mounted || _currentStepIndex == index) return;
    _flushStepDwell();
    setState(() => _currentStepIndex = index);
    _startStepDwell(index);
    _logCookingStepImpressionOnce(index);
    _seekToCurrentStep(index);
  }

  void _showReviewScreen() {
    _flushStepDwell();
    final completedRecipeId = widget.recipeId?.trim() ?? '';
    if (completedRecipeId.isNotEmpty) {
      unawaited(
        AnalyticsService().trackCookingCompleted(
          recipeId: completedRecipeId,
          sourceScreen: 'cooking_mode',
          writeGcs: false,
        ),
      );
    }
    if (widget.recipeId == null) {
      Navigator.of(context).pop();
      return;
    }

    final source = widget.source ?? {};
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    final platform = source['platform'] as String? ?? '';

    String creatorUsername = '@ChefAntoine';
    if (uploader.isNotEmpty) {
      creatorUsername = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creatorUsername = channel.startsWith('@') ? channel : '@$channel';
    }

    showProgressiveRecipeReviewPopup(
      context,
      recipeId: widget.recipeId!,
      recipeTitle: widget.recipe.name ?? '레시피',
      creatorUsername: creatorUsername,
      platform: platform,
      thumbnailUrl: source['thumbnail'] as String?,
      servings: widget.recipe.servings ?? 2,
      fromCookingFlow: true,
    );
  }

  void _goToPreviousStep() {
    if (_currentStepIndex > 0) {
      _goToPage(_currentStepIndex - 1);
    }
  }

  // ─── Segment duration label for current step ───────────────────────

  String? _segmentLabelForPage(int pageIndex) {
    final stepIdx = pageIndex - 1;
    if (stepIdx < 0 || stepIdx >= _stepSegments.length) return null;
    final seg = _stepSegments[stepIdx];
    if (seg == null) return null;
    return '${_fmtSec(seg.startSec)} – ${_fmtSec(seg.endSec)}';
  }

  String _memoForPage(int pageIndex) {
    final memos = widget.stepMemos;
    final idx = pageIndex - 1;
    if (memos == null || idx < 0 || idx >= memos.length) return '';
    return memos[idx].trim();
  }

  static String _fmtSec(double s) {
    final total = s.round();
    final m = total ~/ 60;
    final sec = total % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  // ─── Voice onboarding overlay ──────────────────────────────────────

  void _dismissOnboardingWithoutVoice() {
    _onboardingAnimTimer?.cancel();
    _onboardingAnimTimer = null;
    if (mounted) setState(() => _showVoiceOnboarding = false);
  }

  Widget _buildVoiceOnboardingOverlay() {
    // 플랫폼별로 음성 명령 지원 범위가 다르다.
    // - YouTube: 카드 이동 + step별 영상 구간 점프 ("다시"는 step 영상 구간)
    // - Instagram: 카드 이동 + video 직접 제어 ("다시" 현재 step 구간,
    //   "멈춰/재생"으로 pause/play)
    // - TikTok: cross-origin iframe이라 영상 외부 제어 불가 → 카드만 이동
    final source = widget.source ?? {};
    final sourceUrl = source['url'] as String? ?? '';
    final platform = (source['platform'] as String? ?? '').toLowerCase();
    final isYouTube = platform == 'youtube' || isYouTubeUrl(sourceUrl);
    final isInstagram = platform == 'instagram' ||
        platform == 'instagramweb' ||
        isInstagramUrl(sourceUrl);
    final isTikTok = platform == 'tiktok' ||
        platform == 'tiktokweb' ||
        isTikTokUrl(sourceUrl);

    final String subtitle;
    if (isTikTok) {
      // TikTok은 음성으로 영상 제어 불가
      subtitle = '요리 단계를 목소리로 넘겨가며 사용해보세요\n(영상은 직접 조작해 주세요)';
    } else if (isYouTube || isInstagram) {
      subtitle = '영상 플레이어와 요리 단계를 목소리로 제어할 수 있어요';
    } else {
      subtitle = '요리 단계를 목소리로 제어할 수 있어요';
    }

    // 명령어 카드 — 플랫폼별 분기
    final List<({String label, List<String> keywords})> commandRows;
    if (isInstagram) {
      commandRows = const [
        (label: '이전 단계', keywords: ['"이전"', '"전 단계"']),
        (label: '다음 단계', keywords: ['"다음"', '"다음 단계"']),
        (label: '현재 단계 다시 보기', keywords: ['"다시"']),
        (label: '영상 멈춤 / 재생', keywords: ['"멈춰"', '"재생"']),
      ];
    } else if (isTikTok) {
      commandRows = const [
        (label: '이전 단계', keywords: ['"이전"', '"전 단계"']),
        (label: '다음 단계', keywords: ['"다음"', '"다음 단계"']),
      ];
    } else {
      // YouTube 또는 영상 없음 (기존 동작)
      commandRows = const [
        (label: '이전 단계', keywords: ['"이전"', '"전 단계"']),
        (label: '다음 단계', keywords: ['"다음"', '"다음 단계"']),
        (label: '현재 단계 다시 보기', keywords: ['"다시"']),
      ];
    }

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _dismissOnboardingWithoutVoice,
        child: Container(
          color: Colors.black.withValues(alpha: 0.5),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x38000000),
                  blurRadius: 48,
                  offset: Offset(0, 20),
                  spreadRadius: -8,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated 음성 → 듣는 중 button
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _onboardingBtnActive
                        ? const Color(0xFFFF6B00).withValues(alpha: 0.12)
                        : const Color(0xFFF0F1F3),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _onboardingBtnActive
                          ? const Color(0xFFFF6B00)
                          : const Color(0xFFD1D5DB),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Icon(
                          _onboardingBtnActive ? Icons.mic : Icons.mic_none,
                          key: ValueKey(_onboardingBtnActive),
                          color: _onboardingBtnActive
                              ? const Color(0xFFFF6B00)
                              : const Color(0xFF8B95A1),
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          _onboardingBtnActive ? '듣는 중' : '음성',
                          key: ValueKey(
                            _onboardingBtnActive ? 'active' : 'inactive',
                          ),
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _onboardingBtnActive
                                ? const Color(0xFFFF6B00)
                                : const Color(0xFF8B95A1),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Title
                const Text(
                  '음성으로 더 편하게 요리해보세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    letterSpacing: -0.4,
                    color: Color(0xFF111111),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                // Subtitle
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    letterSpacing: -0.3,
                    color: Color(0xFF8B95A1),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                // Command reference card — matches recipe step cards
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFBFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFF0F2F5),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      for (int i = 0; i < commandRows.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 1,
                            thickness: 1,
                            color: Color(0xFFF0F2F5),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                          child: _buildCommandRow(
                            commandRows[i].label,
                            commandRows[i].keywords,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 요리 시작하기 button
                GestureDetector(
                  onTap: _onVoiceOnboardingConfirmed,
                  child: Container(
                    width: double.infinity,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33FF6B00),
                          blurRadius: 7,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '요리 시작하기',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.3875,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommandRow(String label, List<String> keywords) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.25,
              letterSpacing: -0.3,
              color: Color(0xFF6B7280),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Wrap(
          spacing: 6,
          alignment: WrapAlignment.end,
          children: [
            for (final keyword in keywords)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0xFFE5E7EB),
                    width: 1,
                  ),
                ),
                child: Text(
                  keyword,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    letterSpacing: -0.25,
                    color: Color(0xFFEA580C),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildCookHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (_speechAvailable)
              GestureDetector(
                onTap: _toggleVoiceListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _isListening
                        ? const Color(0xFFFF6B00).withValues(alpha: 0.18)
                        : Colors.black.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isListening
                          ? const Color(0xFFFF6B00)
                          : Colors.white.withValues(alpha: 0.28),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isListening ? Icons.mic : Icons.mic_none,
                        color: _isListening
                            ? const Color(0xFFFF6B00)
                            : Colors.white.withValues(alpha: 0.85),
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _isListening ? '듣는 중' : '음성',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _isListening
                              ? const Color(0xFFFF6B00)
                              : Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCookProgress() {
    return Row(
      children: List.generate(_totalPages, (index) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              right: index == _totalPages - 1 ? 0 : 5,
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: 4,
              decoration: BoxDecoration(
                color: _progressColorForIndex(index),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildCookStickyMeta() {
    final page = _currentStepIndex;
    final isPrep = page == 0;
    final segment = isPrep ? null : _segmentLabelForPage(page);
    final minutes = isPrep
        ? null
        : '${_estimateStepMinutes(widget.recipe.steps[page - 1])}분';
    final stepLabel =
        isPrep ? '준비' : 'STEP ${page.toString().padLeft(2, '0')}';

    return ColoredBox(
      color: Colors.white,
      child: SizedBox(
        height: _kPeekHeader,
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _buildCookProgress()),
                  const SizedBox(width: 10),
                  Text(
                    '${page + 1}/$_totalPages',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeOut,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: child,
                      );
                    },
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      );
                    },
                    child: Text(
                      stepLabel,
                      key: ValueKey<String>(stepLabel),
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFFEA580C),
                        letterSpacing: isPrep ? -0.2 : 1.1,
                        height: 1,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (segment != null) ...[
                    GestureDetector(
                      onTap: _playCurrentSegment,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_arrow_rounded,
                            size: 14,
                            color: Color(0xFFC4B8AE),
                          ),
                          Text(
                            segment,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8A827A),
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (minutes != null)
                    Text(
                      minutes,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFB0A89F),
                        height: 1,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCookTimerBar() {
    final canShow = _cookTimerActive || _currentTimerSuggestion != null;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: !canShow || !_cookTimerExpanded
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: Container(
                height: 44,
                padding: const EdgeInsets.fromLTRB(8, 0, 6, 0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFFFFD7B8),
                    width: 0.667,
                  ),
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => _setCookTimerExpanded(false),
                      child: const SizedBox(
                        width: 28,
                        height: 28,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 20,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Expanded(child: _buildCookTimerBarMessage()),
                    const SizedBox(width: 6),
                    ..._buildCookTimerBarActions(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildCookTimerBarMessage() {
    final idle = _cookTimerPhase == _CookTimerPhase.idle;
    final done = _cookTimerPhase == _CookTimerPhase.done;
    final paused = _cookTimerPhase == _CookTimerPhase.paused;
    final pendingSeconds =
        _currentTimerSuggestion?.seconds ?? _cookTimerTotalSec;
    final pendingLabel =
        pendingSeconds == null ? '타이머' : _formatTimerLabel(pendingSeconds);
    final text = idle
        ? '$pendingLabel 타이머를 시작할까요?'
        : (done
            ? '시간이 끝났어요'
            : _formatTimerClock(_cookTimerLeftSec));
    if (paused) {
      return Row(
        children: [
          Text(
            _formatTimerClock(_cookTimerLeftSec),
            maxLines: 1,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFFEA580C),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '일시정지',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9C9389),
                letterSpacing: -0.15,
              ),
            ),
          ),
        ],
      );
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'Pretendard',
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: done || !idle
            ? const Color(0xFFEA580C)
            : const Color(0xFF4B5563),
        letterSpacing: -0.2,
      ),
    );
  }

  List<Widget> _buildCookTimerBarActions() {
    final idle = _cookTimerPhase == _CookTimerPhase.idle;
    final done = _cookTimerPhase == _CookTimerPhase.done;
    final running = _cookTimerPhase == _CookTimerPhase.running;
    if (idle) {
      return [
        _buildTimerChip(
          label: '시작',
          filled: true,
          onTap: () {
            final suggestion = _currentTimerSuggestion;
            if (suggestion == null) return;
            HapticFeedback.selectionClick();
            _startCookTimer(suggestion.seconds, _currentStepIndex);
          },
        ),
      ];
    }
    if (done) {
      return [
        _buildTimerChip(
          label: '다시',
          filled: true,
          onTap: () {
            HapticFeedback.selectionClick();
            _restartCookTimer();
          },
        ),
        const SizedBox(width: 4),
        _buildTimerChip(label: '닫기', onTap: _dismissCookTimer),
      ];
    }
    return [
      _buildTimerChip(
        label: running ? '멈춤' : '계속',
        filled: true,
        onTap: () {
          HapticFeedback.selectionClick();
          if (running) {
            _pauseCookTimer();
          } else {
            _resumeCookTimer();
          }
        },
      ),
      const SizedBox(width: 4),
      _buildTimerChip(
        label: '초기화',
        onTap: () {
          HapticFeedback.selectionClick();
          _resetCookTimer();
        },
      ),
      const SizedBox(width: 4),
      _buildTimerChip(label: '끄기', onTap: _dismissCookTimer),
    ];
  }

  Widget _buildTimerChip({
    required String label,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? const Color(0xFFEA580C) : const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: filled ? Colors.white : const Color(0xFF4B5563),
          ),
        ),
      ),
    );
  }

  Widget _buildNavTimerButton() {
    final active = _cookTimerActive;
    final done = _cookTimerPhase == _CookTimerPhase.done;
    final paused = _cookTimerPhase == _CookTimerPhase.paused;
    return GestureDetector(
      onTap: _onNavTimerTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: active ? 10 : 0),
        constraints: BoxConstraints(minWidth: 52, maxWidth: active ? 96 : 52),
        decoration: BoxDecoration(
          color: done ? const Color(0xFFEA580C) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? const Color(0xFFFFD7B8) : const Color(0xFFE5E8EB),
            width: 0.667,
          ),
        ),
        child: Center(
          child: active
              ? Text(
                  done ? '끝' : _formatTimerClock(_cookTimerLeftSec),
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: done
                        ? Colors.white
                        : (paused
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFFEA580C)),
                    letterSpacing: -0.3,
                    height: 1,
                  ),
                )
              : const Icon(
                  Icons.timer_outlined,
                  size: 22,
                  color: Color(0xFFEA580C),
                ),
        ),
      ),
    );
  }

  Widget _buildCookNavBar({
    bool includeBottomSafeArea = true,
    bool compact = false,
  }) {
    return SafeArea(
      top: false,
      bottom: includeBottomSafeArea,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: Row(
          children: [
            GestureDetector(
              onTap: _currentStepIndex > 0 ? _goToPreviousStep : null,
              child: Opacity(
                opacity: _currentStepIndex > 0 ? 1.0 : 0.3,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFE8E6E3),
                      width: 0.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0A000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.chevron_left_rounded,
                      color: Color(0xFF6B7280),
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (!compact &&
                (_cookTimerActive || _currentTimerSuggestion != null)) ...[
              _buildNavTimerButton(),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: GestureDetector(
                onTap: _goToNextStep,
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B00),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40FF6B00),
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _currentStepIndex < _totalPages - 1
                              ? '다음 단계로'
                              : '완료하기',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontFamily: 'Pretendard',
                            fontWeight: FontWeight.w700,
                            height: 1.5,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          _currentStepIndex < _totalPages - 1
                              ? Icons.chevron_right_rounded
                              : Icons.check_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
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
    );
  }

  double get _videoFraction => _splitAnim.value;

  double _sheetPeekHeight(BuildContext context) {
    return _kSheetHandle +
        _kPeekHeader +
        _kPeekNav +
        MediaQuery.paddingOf(context).bottom;
  }

  double _maxVideoFraction(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return (1.0 - _sheetPeekHeight(context) / h).clamp(_kVideoMin, 1.0);
  }

  void _onSplitDragUpdate(DragUpdateDetails details) {
    _splitAnim.stop();
    final h = MediaQuery.sizeOf(context).height;
    final next = (_videoFraction + details.delta.dy / h)
        .clamp(_kVideoMin, _maxVideoFraction(context));
    _splitAnim.value = next;
  }

  void _onSplitDragEnd(DragEndDetails details) {
    final maxV = _maxVideoFraction(context);
    final v = _videoFraction;
    final vy = details.velocity.pixelsPerSecond.dy;
    final double target;
    if (vy > 720) {
      target = maxV;
    } else if (vy < -720) {
      target = _kVideoMin;
    } else {
      final points = <double>[_kVideoMin, _kVideoDefault, maxV];
      target = points.reduce(
        (a, b) => (a - v).abs() <= (b - v).abs() ? a : b,
      );
    }
    _splitAnim.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildSheetHandle() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onSplitDragUpdate,
      onVerticalDragEnd: _onSplitDragEnd,
      child: const SizedBox(
        height: _kSheetHandle,
        width: double.infinity,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFD1D5DB),
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
            child: SizedBox(width: 36, height: 4),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoStage({double? height}) {
    final media = MediaQuery.of(context);
    return SizedBox(
      height: height ?? media.size.height * _videoFraction,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Positioned.fill(
            child: _buildVideoSection(),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.58),
                    Colors.transparent,
                  ],
                ),
              ),
              child: _buildCookHeader(),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildIngredientChips(List<models.Ingredient> ingredients) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final ingredient in ingredients)
          _buildIngredientChip(ingredient, compact: false),
      ],
    );
  }

  Widget _buildCompactIngredientStrip(List<models.Ingredient> ingredients) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 0.5, color: Color(0xFFE8E2DA)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final ingredient in ingredients)
              _buildIngredientChip(ingredient, compact: true),
          ],
        ),
      ],
    );
  }

  Widget _buildIngredientChip(
    models.Ingredient ingredient, {
    required bool compact,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 3 : 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFE8E6E3),
          width: 0.8,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        _formatIngredient(ingredient),
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: compact ? 11.5 : 13,
          fontWeight: FontWeight.w500,
          color: const Color(0xFF5C564F),
          letterSpacing: -0.15,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _buildCookPage(int pageIndex, Brightness brightness) {
    if (pageIndex == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        clipBehavior: Clip.none,
        children: [
          const Text(
            '재료부터 준비해요',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111111),
              height: 1.25,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '손을 씻고 재료를 꺼내 두면, 다음 단계가 훨씬 수월해요.',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8B95A1),
              height: 1.45,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final ingredient in _allIngredients)
                _buildIngredientChip(ingredient, compact: true),
            ],
          ),
          if ((widget.recipeMemo ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8F2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFD3B5)),
              ),
              child: Text(
                widget.recipeMemo!.trim(),
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF6B7280),
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      );
    }

    final step = widget.recipe.steps[pageIndex - 1];
    final memo = _memoForPage(pageIndex);
    final timerSuggestion = _timerSuggestionFor(step);
    final stepIngredients = (step.stepIngredients ?? [])
        .map(
          (name) => widget.recipe.ingredients.firstWhere(
            (ing) => ing.item == name,
            orElse: () => models.Ingredient(item: name),
          ),
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInstructionWithTimer(
                    step.instruction,
                    timerSuggestion,
                    pageIndex,
                    brightness,
                  ),
                  if ((step.tip ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildPinnedTip((step.tip ?? '').trim()),
                  ],
                  if (memo.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '❋  $memo',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFEA580C),
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (stepIngredients.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _buildCompactIngredientStrip(stepIngredients),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPinnedTip(String tip) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 1.5,
            decoration: BoxDecoration(
              color: const Color(0xFFEA580C),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TIP',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFEA580C),
                    letterSpacing: 1.4,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tip,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF5C564F),
                    height: 1.45,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionWithTimer(
    String instruction,
    ({int seconds, String phrase})? suggestion,
    int pageIndex,
    Brightness brightness, {
    double fontSize = 19.5,
  }) {
    final base = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF2C2A27),
      height: 1.5,
      letterSpacing: -0.25,
    );
    final phrase = suggestion?.phrase;
    final index = phrase == null ? -1 : instruction.indexOf(phrase);
    if (suggestion == null || phrase == null || index < 0) {
      return Text(instruction, style: base);
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: instruction.substring(0, index)),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () {
                if (_cookTimerActive) {
                  _setCookTimerExpanded(true);
                  return;
                }
                HapticFeedback.selectionClick();
                _startCookTimer(suggestion.seconds, pageIndex);
                _setCookTimerExpanded(true);
              },
              child: Text(
                phrase,
                style: base.copyWith(
                  color: const Color(0xFFEA580C),
                  decoration: TextDecoration.underline,
                  decorationColor: const Color(0xFFEA580C),
                  decorationThickness: 1.4,
                ),
              ),
            ),
          ),
          TextSpan(text: instruction.substring(index + phrase.length)),
        ],
      ),
    );
  }

  Widget _buildCookShell(Brightness brightness) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final peek = _sheetPeekHeight(context);
          final maxVideo = (constraints.maxHeight - peek).clamp(0.0, constraints.maxHeight);
          final videoHeight = (constraints.maxHeight * _videoFraction)
              .clamp(0.0, maxVideo)
              .floorToDouble();
          return Column(
            children: [
              SizedBox(
                height: videoHeight,
                width: double.infinity,
                child: _buildVideoStage(height: videoHeight),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: _onSplitDragUpdate,
                          onVerticalDragEnd: _onSplitDragEnd,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildSheetHandle(),
                              _buildCookStickyMeta(),
                            ],
                          ),
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, sheetConstraints) {
                              final h = sheetConstraints.maxHeight;
                              const minBody = 320.0;
                              final childH = h < 1 ? minBody : (h < minBody ? minBody : h);
                              return ClipRect(
                                child: Opacity(
                                  opacity: (h / 88).clamp(0.0, 1.0),
                                  child: OverflowBox(
                                    alignment: Alignment.topCenter,
                                    minHeight: childH,
                                    maxHeight: childH,
                                    child: SizedBox(
                                      height: childH,
                                      width: sheetConstraints.maxWidth,
                                      child: Column(
                                        children: [
                                          _buildCookTimerBar(),
                                          Expanded(
                                            child: PageView.builder(
                                              controller: _pageController,
                                              itemCount: _totalPages,
                                              onPageChanged:
                                                  _onCookPageChanged,
                                              itemBuilder: (context, index) {
                                                return _buildCookPage(
                                                  index,
                                                  brightness,
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        _buildCookNavBar(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_totalPages <= 0) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    return Stack(
      children: [
        _buildCookShell(brightness),
        if (_showVoiceOnboarding) _buildVoiceOnboardingOverlay(),
      ],
    );
  }
}
