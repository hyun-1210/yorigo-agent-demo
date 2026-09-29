import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../l10n/app_localizations.dart';
import '../services/recipe_service.dart';
import '../services/background_parsing_service.dart';
import '../services/guest_parse_quota_service.dart';
import '../services/parse_history_service.dart';
import 'parse_history_screen.dart';
import '../services/user_service.dart';
import '../models/recipe_models.dart' as models;
import '../utils/naver_blog_utils.dart';
import '../main.dart' show appNavigatorKey, mainNavigatorKey;
import '../widgets/ios_liquid_glass_tab_bar.dart';

/// Fixed example videos for onboarding users into the parsing flow.
const List<Map<String, String>> featuredExampleVideos = [
  {
    'url': 'https://youtube.com/shorts/2KoUycJinko?si=9tqlidJ7ygRUUXYV',
    'title': '여러가지 시도해보고 정착한 두부찌개 레시피',
    'creator': '뚜비두밥 맛있는밥',
    'platform': 'youtube',
  },
  {
    'url': 'https://www.instagram.com/reel/DSPYAu0k10M/?igsh=MWhqdmF2eTUwZXhncw==',
    'title': '고기 없이 만들어도 맛있는! 김치볶음밥',
    'creator': '@foozimbab',
    'platform': 'instagram',
  },
  {
    'url': 'https://vt.tiktok.com/ZS9gHj85X/',
    'title': "시장에서 줄서서 먹던 맛! 바지락 칼국수 레시피",
    'creator': '추추의 한끼식사',
    'platform': 'tiktok',
  },
  {
    'url':
        'https://m.blog.naver.com/PostView.naver?blogId=baby0817&logNo=223193223732',
    'title': '된장 꽃게탕 끓이는법 꽃게탕 황금 레시피',
    'creator': '꼬마츄츄',
    'platform': 'naver_blog',
  },
];

// Figma 97-5236: Add recipe (parsing) sheet
const Color _figmaTextPrimary = Color(0xFF111111);
const Color _figmaSubtext = Color(0xFF9CA3AF);
const Color _figmaPlatformLabel = Color(0xFFB4BAC4);
const Color _figmaDivider = Color(0xFFF1F2F4);
const Color _figmaDot = Color(0xFFE2E4E8);

class AddRecipeScreen extends StatefulWidget {
  final String? initialUrl;
  /// When set, sheet opens in progress mode for this recipe (e.g. from home card tap).
  final String? initialParsingRecipeId;
  /// Source URL for retry when showing error for [initialParsingRecipeId].
  final String? initialSourceUrl;
  /// Extra space reserved below the sheet so it can float above the app bottom nav.
  final double bottomOffset;

  /// 공유(Share)로 링크가 들어온 경우처럼, 시트가 열리면 입력된 링크를
  /// 자동으로 분석(분석하기 자동 탭)까지 진행할지 여부.
  final bool autoAnalyze;

  const AddRecipeScreen({
    super.key,
    this.initialUrl,
    this.initialParsingRecipeId,
    this.initialSourceUrl,
    this.bottomOffset = 0,
    this.autoAnalyze = false,
  });

  static double bottomNavOffsetFor(BuildContext context) {
    // 레시피북처럼 탭 셸을 가린 페이지에서는 바닥에 붙인다.
    // 홈 인디케이터 여백은 시트 안쪽에 둔다. 바깥에 두면 카드가 붕 뜬다.
    if (IosLiquidGlassTabBar.coveredByPushedRoute.value) {
      return 0;
    }
    final overlay = IosLiquidGlassTabBar.overlayChromeInset(context);
    if (overlay > 0) return overlay;
    if (IosLiquidGlassTabBar.shouldUse(context) &&
        IosLiquidGlassTabBar.overlayActive.value) {
      return IosLiquidGlassTabBar.hostHeight(context);
    }
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final navBottomSafeGap = bottomInset > 0 ? bottomInset : 6.0;
    // Mirrors MainNavigator's bottom nav height so the sheet sits flush above it.
    return 8 + 56 + 8 + navBottomSafeGap;
  }

  @override
  State<AddRecipeScreen> createState() => _AddRecipeScreenState();
}

class _AddRecipeScreenState extends State<AddRecipeScreen>
    with TickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final RecipeService _recipeService = RecipeService();
  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final FocusNode _urlFocusNode = FocusNode();
  bool _isLoading = false;
  bool _isParsing = false; // Track if we're in the middle of parsing
  String _currentStage = '';
  double _currentProgress = 0.0;
  double _animatedProgress = 0.0; // For smooth animation
  Timer? _progressTimer; // For continuous progress animation

  /// Shown in the parsing URL field (controller may be cleared after submit).
  String _parsingDisplayUrl = '';

  /// Parsing checklist phase derived from shared progress cache:
  /// 0..3 = active step index, 4 = all done (100%).
  int _visualParsePhase = 0;

  late final AnimationController _parsingDotsController;
  late final AnimationController _ringPulseController;
  late final AnimationController _inputGlowController;
  AnimationController? _swipeHintController;
  
  // Firestore subscription for background parsing progress
  StreamSubscription<DocumentSnapshot>? _parsingProgressSubscription;
  /// 로컬(비로그인) 파싱 완료 시 Firestore 없이 반응하기 위한 구독
  StreamSubscription<Map<String, dynamic>>? _completionStreamSubscription;
  /// 현재 이 시트에서 파싱 중인 레시피 ID (완료 스트림 이벤트 매칭용)
  String? _currentParsingRecipeId;
  
  double _displayProgress = 0.0; // Progress shown in UI (전역 시뮬레이션 + 캐시와 동기화)
  VoidCallback? _parsingCacheListener;
  Timer? _dismissTimer; // Timer for debouncing dismissal
  bool _isDismissing = false; // Flag to prevent multiple dismissal attempts
  double? _previousSize; // Previous sheet size for tracking drag direction

  /// When showing error for initialParsingRecipeId (delete/retry in sheet).
  bool _showParseErrorInSheet = false;
  String _parseErrorMessage = '';

  /// 파싱 완료 후 100%까지 부드럽게 차오르는 애니메이션 진행 중이면 true (중복 실행 방지)
  bool _isAnimatingTo100 = false;

  /// 입력 모드: false=링크(기본), true=글/스크린샷
  bool _isManualMode = false;
  bool _isPhotoMode = false;
  final TextEditingController _manualTextController = TextEditingController();
  final FocusNode _manualTextFocusNode = FocusNode();
  final List<Uint8List> _manualImages = <Uint8List>[];
  static const int _kMaxManualImages = 5;

  /// 직전 시트 높이. 더 높은 모드로 전환할 때 cap 이 천천히 커지면
  /// 그 사이 내용이 잠깐 넘쳐 오버플로우가 떠서, 커질 땐 즉시 적용한다.
  double _lastSheetHeight = 0;
  final ImagePicker _imagePicker = ImagePicker();
  Timer? _urlFocusReadyTimer;
  var _allowTapOutsideUnfocus = false;

  @override
  void dispose() {
    _stopChecklistPulse();
    _parsingDotsController.dispose();
    _ringPulseController.dispose();
    _inputGlowController.dispose();
    _swipeHintController?.dispose();
    _urlFocusReadyTimer?.cancel();
    _progressTimer?.cancel();
    _detachParsingCacheListener();
    _dismissTimer?.cancel();
    _parsingProgressSubscription?.cancel();
    _completionStreamSubscription?.cancel();
    _sheetController.removeListener(_handleSheetSizeChange);
    _urlController.removeListener(_onUrlControllerChanged);
    _urlController.dispose();
    _urlFocusNode.dispose();
    _manualTextController.dispose();
    _manualTextFocusNode.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _pickManualImages() async {
    final int remaining = _kMaxManualImages - _manualImages.length;
    if (remaining <= 0) {
      showAppSnackBar(context, 
        SnackBar(content: Text('이미지는 최대 $_kMaxManualImages장까지 첨부할 수 있어요.')),
      );
      return;
    }
    try {
      final picked = await _imagePicker.pickMultiImage(
        imageQuality: 80,
        limit: remaining,
      );
      if (picked.isEmpty || !mounted) return;
      final List<Uint8List> newBytes = [];
      for (final xfile in picked.take(remaining)) {
        final bytes = await xfile.readAsBytes();
        newBytes.add(bytes);
      }
      if (!mounted) return;
      setState(() {
        _manualImages.addAll(newBytes);
      });
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 
        SnackBar(content: Text('이미지를 불러올 수 없어요: $e')),
      );
    }
  }

  void _removeManualImage(int index) {
    if (index < 0 || index >= _manualImages.length) return;
    setState(() {
      _manualImages.removeAt(index);
    });
  }

  void _showParseStartedSnack() {
    final ctx = mainNavigatorKey.currentContext;
    if (ctx == null) return;
    showAppSnackBar(ctx, 
      const SnackBar(
        content: Text('레시피북에서 분석을 시작했어요'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// 네이버 블로그 / 글·사진 파싱은 SSE 로만 진행되므로 분석 중 앱을 닫으면
  /// 연결이 끊겨 분석이 중단될 수 있다. 시트가 닫힌 직후 홈에서 짧게 안내한다.
  void _showStayInAppSnack() {
    final ctx = mainNavigatorKey.currentContext;
    if (ctx == null) return;
    showAppSnackBar(ctx, 
      const SnackBar(
        content: Text('블로그/글,사진은 분석이 끝날 때까지 앱을 나가지 마세요!'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  /// 게스트 무료 분석(성공 1회)을 다 쓴 뒤의 분석 시도를 막는다.
  /// 막힌 경우 로그인 유도 시트를 띄우고 false 를 돌려준다.
  Future<bool> _ensureParseAllowed({String? pendingUrl}) async {
    if (FirebaseAuth.instance.currentUser != null) return true;
    if (await GuestParseQuotaService.instance.canParseAsGuest()) return true;
    await _showGuestParseLoginGate(pendingUrl: pendingUrl);
    return false;
  }

  Future<void> _showGuestParseLoginGate({String? pendingUrl}) async {
    if (!mounted) return;
    final goLogin = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _GuestParseLoginGateSheet(),
    );
    if (goLogin != true) return;
    // 로그인 화면은 네비게이션 스택을 초기화하므로, 이어서 분석할 링크는
    // 화면 상태가 아니라 로컬에 남겨 두고 로그인 후 다시 꺼낸다.
    if (pendingUrl != null && pendingUrl.isNotEmpty) {
      await GuestParseQuotaService.instance.setPendingParseUrl(pendingUrl);
    }
    if (!mounted) return;
    _closePresentedSheet();
    // 시트가 닫힌 다음 프레임에 로그인 화면으로 넘긴다 (내비게이터 잠금 회피).
    Future.microtask(() => appNavigatorKey.currentState?.pushNamed('/login'));
  }

  String _parseHistoryErrorMessage(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  String _parseHistoryErrorType(Object error) {
    final msg = error.toString();
    if (msg.contains('동시에 최대')) return 'concurrent_limit';
    if (msg.contains('이미 저장된')) return 'duplicate';
    return 'client_error';
  }

  Future<void> _markParseHistoryStartFailure(String attemptId, Object error) async {
    if (error is ExistingRecipeException) {
      await ParseHistoryService.instance.remap(attemptId, error.recipeId);
      return;
    }
    await ParseHistoryService.instance.markError(
      id: attemptId,
      error: _parseHistoryErrorMessage(error),
      errorType: _parseHistoryErrorType(error),
    );
  }

  Future<void> _handleManualSubmit() async {
    if (_isLoading || _isParsing) return;
    final text = _manualTextController.text.trim();
    final bool hasText = text.isNotEmpty;
    final bool hasImages = _manualImages.isNotEmpty;
    if (!hasText && !hasImages) {
      showAppSnackBar(context, 
        const SnackBar(content: Text('레시피 글이나 스크린샷을 입력해주세요.')),
      );
      return;
    }

    // 입력을 잃지 않도록 시트는 열어 둔 채로 로그인 유도만 띄운다.
    if (!await _ensureParseAllowed()) return;

    setState(() {
      _isLoading = true;
    });

    // Optimistic parsing card (URL 흐름과 동일한 UX)
    _stopChecklistPulse();
    _detachParsingCacheListener();
    _parsingProgressSubscription?.cancel();
    _parsingProgressSubscription = null;

    final preId = RecipeService.addOptimisticParsingRecipe(sourceUrl: '');
    RecipeService.parsingProgressCache.startProgressSimulation(preId);
    RecipeService.notifyRecipesChanged();

    // 분석 시도를 히스토리에 즉시 남긴다(실패/지연에도 입력이 사라지지 않도록).
    final String manualKind = hasImages ? 'image' : 'text';
    final String manualPreview = hasText
        ? (text.length > 40 ? '${text.substring(0, 40)}…' : text)
        : '스크린샷 분석';
    ParseHistoryService.instance.record(
      id: preId,
      kind: manualKind,
      title: manualPreview,
      manualText: hasText ? text : null,
    );
    if (hasImages) {
      unawaited(ParseHistoryService.instance.saveAttemptImages(
        preId,
        List<Uint8List>.from(_manualImages),
      ));
    }

    setState(() {
      _isParsing = false;
      _isLoading = false;
      _visualParsePhase = 0;
    });
    _closePresentedSheet();
    _showStayInAppSnack();

    final manualFuture = _backgroundParsingService.startContentParsing(
      text: hasText ? text : null,
      images: hasImages ? List<Uint8List>.from(_manualImages) : null,
      preferLang: 'ko',
      preAllocatedRecipeId: preId,
    );
    manualFuture.then((id) {
      if (id.isNotEmpty) {
        ParseHistoryService.instance.remap(preId, id);
      }
    }).catchError((_) {});
    manualFuture.catchError((e) async {
      await _markParseHistoryStartFailure(preId, e);
      final pushContext = mainNavigatorKey.currentContext;
      if (pushContext != null) {
        showAppSnackBar(pushContext, 
          SnackBar(
            content: Text(_parseHistoryErrorMessage(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return '';
    });
  }

  /// 통합 입력 카드 (Drop-zone 스타일)
  /// 링크 · 글 · 스크린샷을 하나의 카드 안에서 전환/입력하고, 같은 카드 우하단에서 바로 분석할 수 있도록 한다.
  Widget _buildUnifiedInputCard() {
    final bool hasImages = _manualImages.isNotEmpty;
    final bool manualHasText = _manualTextController.text.trim().isNotEmpty;
    final bool canSubmitManual = !_isLoading && (manualHasText || hasImages);
    final bool urlHasText = _urlController.text.trim().isNotEmpty;
    final bool canSubmitUrl = !_isLoading && urlHasText;
    final bool canSubmit = _isManualMode ? canSubmitManual : canSubmitUrl;
    final VoidCallback? onAnalyze = _isLoading
        ? null
        : (canSubmit
            ? (_isManualMode ? _handleManualSubmit : _handleSubmit)
            : _showLinkRequiredSnack);

    return AnimatedBuilder(
      animation: _inputGlowController,
      builder: (context, child) {
        return CustomPaint(
          foregroundPainter: _InputCardGlowPainter(
            progress: _inputGlowController.value,
            radius: 18,
          ),
          child: child,
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            width: 1,
            color: const Color(0xFFFF6B00),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF6B00).withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasImages) ...[
              SizedBox(
                height: 64,
                child: Builder(
                  builder: (ctx) {
                    final canAddMore =
                        _manualImages.length < _kMaxManualImages;
                    final itemCount =
                        _manualImages.length + (canAddMore ? 1 : 0);
                    return ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: itemCount,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, i) => i < _manualImages.length
                          ? _buildUnifiedImageThumb(i)
                          : _buildUnifiedAddImageTile(),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: child,
                ),
                child: _isManualMode
                    ? _buildUnifiedManualTextField(photoMode: _isPhotoMode)
                    : _buildUnifiedUrlTextField(),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: 1,
              color: const Color(0xFFF1F2F4),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  // 칩 그룹: Expanded 가 남는 공간을 차지해 분석 버튼을 오른쪽 끝에
                  // 고정시킨다. 공간이 부족할 때만 FittedBox 로 칩이 함께 축소돼
                  // 절대 박스를 넘치지 않는다(평소엔 scale 1.0 → 칩 크기 그대로).
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildModeChip(
                            icon: Icons.link_rounded,
                            label: '링크',
                            active: !_isManualMode,
                            onTap: _isLoading
                                ? null
                                : () {
                                    if (!_isManualMode) return;
                                    setState(() {
                                      _isManualMode = false;
                                      _isPhotoMode = false;
                                    });
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      _urlFocusNode.requestFocus();
                                    });
                                  },
                          ),
                          const SizedBox(width: 6),
                          _buildModeChip(
                            icon: Icons.edit_outlined,
                            label: '글',
                            active: _isManualMode && !_isPhotoMode,
                            onTap: _isLoading
                                ? null
                                : () {
                                    if (_isManualMode && !_isPhotoMode) {
                                      _manualTextFocusNode.requestFocus();
                                      return;
                                    }
                                    setState(() {
                                      _isManualMode = true;
                                      _isPhotoMode = false;
                                    });
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      _manualTextFocusNode.requestFocus();
                                    });
                                  },
                          ),
                          const SizedBox(width: 6),
                          _buildModeChip(
                            icon: Icons.image_outlined,
                            label: hasImages
                                ? '${_manualImages.length}/$_kMaxManualImages'
                                : '스크린샷',
                            active: _isPhotoMode || hasImages,
                            onTap: _isLoading ||
                                    _manualImages.length >= _kMaxManualImages
                                ? null
                                : () {
                                    FocusScope.of(context).unfocus();
                                    setState(() {
                                      _isManualMode = true;
                                      _isPhotoMode = true;
                                    });
                                  },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _buildAnalyzeChipButton(
                    onTap: onAnalyze,
                    label: _isManualMode ? '정리하기' : '분석하기',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _inputModeTagline {
    if (!_isManualMode) return '링크 하나로 레시피 자동 정리';
    if (_isPhotoMode) return '스크린샷으로 레시피 자동 정리';
    return '붙여넣은 글로 레시피 자동 정리';
  }

  /// 공유·딥링크 등 URL이 미리 채워진 진입은 자동 분석만 하면 되므로
  /// URL 입력란에 포커스/키보드를 띄우지 않는다.
  bool get _shouldFocusUrlField {
    if (_isParsing) return false;
    final prefill = widget.initialUrl?.trim();
    if (prefill != null && prefill.isNotEmpty) return false;
    if (widget.autoAnalyze) return false;
    return true;
  }

  Widget _buildUnifiedUrlTextField() {
    return Padding(
      key: const ValueKey('unified-url-field'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(
              Icons.link_rounded,
              size: 17,
              color: Color(0xFFFF6B00),
            ),
          ),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) {
                if (_isLoading) return;
                _urlFocusNode.requestFocus();
              },
              child: TextField(
                controller: _urlController,
                focusNode: _urlFocusNode,
                autofocus: _shouldFocusUrlField,
                onTap: () => _urlFocusNode.requestFocus(),
                onTapOutside: (_) {
                  if (!_allowTapOutsideUnfocus) return;
                  _urlFocusNode.unfocus();
                },
                onChanged: (_) => setState(() {}),
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: '레시피 링크를 붙여넣어 주세요',
                  hintStyle: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF99A1AF),
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.325,
                  ),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                ),
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  color: _figmaTextPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.3,
                  height: 1.35,
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _handleSubmit(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnifiedManualTextField({required bool photoMode}) {
    // 썸네일 행이 떠 있으면(=스크린샷 모드이거나 이미지가 있으면) 입력 필드를
    // 더 작게(2줄) 유지해 시트 높이를 넘지 않게 한다. 순수 글 모드만 3줄.
    final bool compact = photoMode || _manualImages.isNotEmpty;
    final hintText = compact
        ? '레시피 스크린샷을 추가해 주세요. 재료와 조리법이 모두 보여야 분석할 수 있어요.'
        : '레시피 글을 붙여넣어 주세요. 재료와 조리법이 모두 있어야 분석할 수 있어요.';
    return Padding(
      key: const ValueKey('unified-manual-field'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 이미지가 하나라도 추가되면 넓은 "스크린샷 추가" pill 은 숨긴다.
          // 추가 스크린샷은 썸네일 행 끝의 "+" 타일로 넣을 수 있다.
          if (photoMode && _manualImages.isEmpty) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _isLoading ||
                        _manualImages.length >= _kMaxManualImages
                    ? null
                    : _pickManualImages,
                borderRadius: BorderRadius.circular(100),
                child: Container(
                  height: 36,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(
                      color: const Color(0xFFEFF1F4),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                        color: _manualImages.length >= _kMaxManualImages
                            ? const Color(0xFFBFC3C8)
                            : const Color(0xFF111111),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        _manualImages.isEmpty
                            ? '스크린샷 추가'
                            : '스크린샷 ${_manualImages.length}/$_kMaxManualImages',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.8,
                          fontWeight: FontWeight.w800,
                          color: _manualImages.length >= _kMaxManualImages
                              ? const Color(0xFFBFC3C8)
                              : const Color(0xFFFF6B00),
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _manualTextController,
            focusNode: _manualTextFocusNode,
            onTapOutside: (_) => _manualTextFocusNode.unfocus(),
            onChanged: (_) => setState(() {}),
            minLines: compact ? 2 : 3,
            maxLines: compact ? 4 : 7,
            maxLength: 5000,
            buildCounter: (
              _, {
              required int currentLength,
              required bool isFocused,
              required int? maxLength,
            }) => null,
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: const TextStyle(
                fontFamily: 'Pretendard',
                color: Color(0xFF99A1AF),
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                letterSpacing: -0.325,
              ),
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: _figmaTextPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              height: 1.5,
            ),
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
          ),
        ],
      ),
    );
  }

  /// 썸네일 행 끝에 붙는 "+" 추가 타일. 넓은 pill 을 대체해 스크린샷을 더 넣게 한다.
  Widget _buildUnifiedAddImageTile() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isLoading ? null : _pickManualImages,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: const Color(0xFFFAFBFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEFF1F4), width: 1),
          ),
          child: const Icon(
            Icons.add_rounded,
            size: 24,
            color: Color(0xFFFF6B00),
          ),
        ),
      ),
    );
  }

  Widget _buildUnifiedImageThumb(int index) {
    final bytes = _manualImages[index];
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 64,
            height: 64,
            color: const Color(0xFFF1F2F4),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: GestureDetector(
            onTap: () => _removeManualImage(index),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 14,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModeChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback? onTap,
  }) {
    final bool disabled = onTap == null;
    final Color iconColor = disabled
        ? const Color(0xFFBFC3C8)
        : active
            ? const Color(0xFFFF6B00)
            : const Color(0xFF6A7282);
    final Color textColor = disabled
        ? const Color(0xFFBFC3C8)
        : active
            ? const Color(0xFFFF6B00)
            : const Color(0xFF4B5563);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: active
                  ? const Color(0xFFFFE1C7)
                  : const Color(0xFFEFF1F4),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: active ? 0.055 : 0.035),
                blurRadius: active ? 10 : 7,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 통합 카드 우하단에 들어가는 컴팩트 분석 버튼.
  Widget _buildAnalyzeChipButton({
    required VoidCallback? onTap,
    required String label,
  }) {
    final bool enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: enabled ? 1 : 0.4,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00),
              borderRadius: BorderRadius.circular(100),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: const Color(0xFFFF6B00).withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 버튼 크기/라벨은 그대로 두고, 화살표 자리에서 원만 회전.
                  _isLoading
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 13,
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openExampleUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        showAppSnackBar(context, 
          const SnackBar(content: Text('링크를 열 수 없습니다'), backgroundColor: Colors.red),
        );
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(content: Text('링크를 열 수 없습니다'), backgroundColor: Colors.red),
        );
      }
    }
  }

  static String _examplePlatformAssetPath(String platform) {
    switch (platform) {
      case 'youtube': return 'lib/assets/youtube-app-icon-hd.png';
      case 'instagram': return 'lib/assets/instagram-app-icon-hd.png';
      case 'tiktok': return 'lib/assets/tiktok-app-icon-hd.png';
      default: return 'lib/assets/youtube-app-icon-hd.png';
    }
  }

  void _handleSheetSizeChange() {
    // Prevent handling if already dismissing
    if (_isDismissing) return;
    
    final currentSize = _sheetController.size;
    
    // If sheet is being dragged down below 0.75 (75% of screen), dismiss immediately
    // This closes the modal before the sheet shrinks too much, preventing the black barrier from showing
    if (currentSize < 0.75 && currentSize > 0) {
      // Allow dismissal if sheet is actively being dragged down (even during parsing)
      if (!_isLoading && mounted) {
        // Check if sheet is being dragged down (current size < previous size)
        if (_previousSize == null || currentSize < _previousSize!) {
          // Cancel any existing dismiss timer
          _dismissTimer?.cancel();
          // Dismiss immediately to prevent black barrier from showing
          // Use a very short delay to ensure smooth animation
          _dismissTimer = Timer(const Duration(milliseconds: 50), () {
            if (mounted && !_isDismissing && _sheetController.size < 0.75 && !_isLoading) {
              _dismissModal();
            }
          });
        }
      }
    } else {
      // Sheet is above threshold, cancel any pending dismissal
      _dismissTimer?.cancel();
    }
    _previousSize = currentSize;
  }

  void _dismissModal() {
    // Prevent multiple dismissal attempts
    if (_isDismissing || !mounted) return;

    _isDismissing = true;
    _dismissTimer?.cancel();

    // Use Future.microtask to ensure we're not in the middle of a frame
    Future.microtask(() {
      if (!mounted) return;
      _closePresentedSheet();
    });
  }

  bool _isBottomSheetRoute() {
    final route = ModalRoute.of(context);
    return route is PopupRoute;
  }

  void _closePresentedSheet() {
    if (!mounted) return;
    if (_isBottomSheetRoute()) {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      }
      return;
    }
    mainNavigatorKey.currentState?.hideAddRecipeSheet();
  }

  Future<void> _handleExistingRecipe({
    required models.ParseResponse parseResponse,
    String? recipeId,
  }) async {
    // Show progress UI
    setState(() {
      _isParsing = true;
      _currentStage = '완료';
      _currentProgress = 0.0;
      _animatedProgress = 0.0;
      _visualParsePhase = 4;
    });

    // Animate progress bar quickly to 100%
    const animationDuration = Duration(milliseconds: 800);
    const steps = 40;
    final stepDuration = animationDuration ~/ steps;
    final stepIncrement = 100.0 / steps;

    for (int i = 0; i <= steps; i++) {
      await Future.delayed(stepDuration);
      if (!mounted) return;
      setState(() {
        _animatedProgress = (i * stepIncrement).clamp(0.0, 100.0);
        _currentProgress = _animatedProgress;
      });
    }

    // Ensure we're at 100%
    if (mounted) {
      setState(() {
        _animatedProgress = 100.0;
        _currentProgress = 100.0;
      });
      _progressTimer?.cancel();
    }

    // Small delay to show 100% before navigating
    await Future.delayed(const Duration(milliseconds: 300));

    // Navigate to recipe detail screen
    // 모달을 먼저 닫고 상세 화면으로 이동
    if (mounted) {
      final pushContext = mainNavigatorKey.currentContext;
      _closePresentedSheet();
      if (pushContext != null) {
        Future.microtask(() {
          Navigator.pushNamed(
            pushContext,
            '/recipe-detail',
            arguments: recipeId != null
                ? {'parseResponse': parseResponse, 'recipeId': recipeId}
                : parseResponse,
          );
        });
      }
    }

    // Cleanup
    if (mounted) {
      setState(() {
        _isLoading = false;
        _isParsing = false;
      });
    }
  }


  /// Firestore에서 백그라운드 파싱 진행 상황을 실시간으로 구독하여 UI에 반영
  void _subscribeToParsingProgress(String recipeId) {
    _parsingProgressSubscription?.cancel();
    RecipeService.parsingProgressCache.startProgressSimulation(recipeId);

    _parsingProgressSubscription = FirebaseFirestore.instance
        .collection('recipes')
        .doc(recipeId)
        .snapshots(includeMetadataChanges: true)
        .listen((snapshot) {
      if (!mounted || !_isParsing) {
        return;
      }

      if (!snapshot.exists) {
        return;
      }
      
      final data = snapshot.data();
      if (data == null) {
        return;
      }
      
      final status = data['status'] as String?;
      final stage = data['stage'] as String? ?? '분석중...';
      final subStage = data['sub_stage'] as String?;
      final completedRecipeId = snapshot.id;
      
      // 파싱이 완료된 경우
      if (status == 'completed') {
        _parsingProgressSubscription?.cancel();
        _parsingProgressSubscription = null;
        
        if (mounted) {
          if (status == 'completed') {
            // 100%까지 부드럽게 차오른 뒤 디테일로 이동 (캐시 갱신으로 홈/목록 진행도 동기화)
            _animateProgressTo100ThenNavigate(completedRecipeId);
          }
        }
        return;
      }

      if (status == 'error') {
        if (!mounted) return;
        setState(() {
          _isParsing = true;
          _showParseErrorInSheet = false;
          _parseErrorMessage = '';
          _currentStage = '분석중...';
        });
        return;
      }
      
      // 진행 상황 업데이트 (스테이지/체크리스트만 반영, 진행률 %는 ParsingProgressCache 시뮬레이션이 담당)
      if (mounted) {
        final phase = _phaseFromProgress(_displayProgress);
        setState(() {
          _currentStage = subStage != null ? '$stage ($subStage)' : stage;
          _currentProgress = _displayProgress;
          _animatedProgress = _displayProgress;
          _visualParsePhase = phase;
        });
        if (_currentParsingRecipeId != null) {
          RecipeService.parsingProgressCache.update(
            _currentParsingRecipeId!,
            _displayProgress,
            _currentStage,
          );
        }
      }
    });
  }

  void _attachParsingCacheListener() {
    _detachParsingCacheListener();
    _parsingCacheListener = () {
      if (!mounted || !_isParsing || _currentParsingRecipeId == null) return;
      final id = _currentParsingRecipeId!;
      final p = RecipeService.parsingProgressCache.getProgress(id);
      final s = RecipeService.parsingProgressCache.getStage(id);
      final phase = _phaseFromProgress(p);
      setState(() {
        _displayProgress = p;
        _currentProgress = p;
        _animatedProgress = p;
        _visualParsePhase = phase;
        if (s.isNotEmpty) _currentStage = s;
      });
    };
    RecipeService.parsingProgressCache.addListener(_parsingCacheListener!);
  }

  void _detachParsingCacheListener() {
    if (_parsingCacheListener != null) {
      RecipeService.parsingProgressCache.removeListener(_parsingCacheListener!);
      _parsingCacheListener = null;
    }
  }

  /// 파싱 완료 시 현재 진행률에서 100%까지 부드럽게 애니메이션한 뒤 디테일로 이동.
  /// 애니메이션 중 parsingProgressCache를 갱신해 홈/레시피 목록 진행도도 동기화.
  Future<void> _animateProgressTo100ThenNavigate(String recipeId) async {
    if (_isAnimatingTo100 || !mounted) return;
    _isAnimatingTo100 = true;
    _detachParsingCacheListener();
    _parsingProgressSubscription?.cancel();
    _parsingProgressSubscription = null;

    final startProgress = RecipeService.parsingProgressCache
        .getProgress(recipeId)
        .clamp(0.0, 99.0);
    final progressDelta = (100.0 - startProgress).clamp(0.01, 100.0);
    // 짧게: 95→100% ≈ 40ms, 긴 구간도 상한 90ms
    final totalMs = (progressDelta * 1.6).round().clamp(35, 90);
    const steps = 12;
    final stepDuration = Duration(milliseconds: (totalMs / steps).clamp(1, 50).round());

    if (mounted) {
      setState(() {
        _currentStage = '완료';
        _visualParsePhase = 4;
        _stopChecklistPulse();
      });
    }

    for (int i = 1; i <= steps; i++) {
      await Future.delayed(stepDuration);
      if (!mounted || !_isAnimatingTo100) return;
      final t = i / steps;
      final eased = Curves.easeOutCubic.transform(t);
      final progress = (startProgress + progressDelta * eased).clamp(0.0, 100.0);
      setState(() {
        _currentProgress = progress;
        _animatedProgress = progress;
        _displayProgress = progress;
        _visualParsePhase = _phaseFromProgress(progress);
      });
      RecipeService.parsingProgressCache.update(recipeId, progress, '완료');
    }

    if (!mounted) return;
    setState(() {
      _currentProgress = 100.0;
      _animatedProgress = 100.0;
      _displayProgress = 100.0;
      _visualParsePhase = 4;
    });
    RecipeService.parsingProgressCache.update(recipeId, 100.0, '완료');

    await Future.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    RecipeService.parsingProgressCache.remove(recipeId);
    _isAnimatingTo100 = false;
    if (mounted && parseResponse != null) {
      final pushContext = mainNavigatorKey.currentContext;
      _closePresentedSheet();
      if (pushContext != null) {
        Future.microtask(() {
          Navigator.pushNamed(
            pushContext,
            '/recipe-detail',
            arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
          );
        });
      }
    }
    if (mounted) {
      _stopChecklistPulse();
      setState(() {
        _isLoading = false;
        _isParsing = false;
        _visualParsePhase = 0;
      });
    }
  }

  /// Shared progress(%) -> checklist phase mapping.
  /// ParsingProgressCache stage ranges:
  /// - 0..10   영상 확인 중
  /// - 10..25  메타데이터 수집 중
  /// - 25..45  자막/음성 분석 중
  /// - 45..70  재료 추출 중
  /// - 70..90  조리 단계 정리 중
  /// - 90..100 영양 정보 계산 중
  ///
  /// 4단계 체크리스트(링크 확인/영상 읽기/재료 분석/레시피 정리)를 위 흐름에 가깝게 매핑:
  /// - 0..10    step0 (링크 확인 중)
  /// - 10..45   step1 (영상 읽는 중)
  /// - 45..70   step2 (재료 분석 중)
  /// - 70..100  step3 (레시피 정리 중)
  int _phaseFromProgress(double progress) {
    final p = progress.clamp(0.0, 100.0);
    if (p >= 100.0) return 4;
    if (p < 10.0) return 0;
    if (p < 45.0) return 1;
    if (p < 70.0) return 2;
    return 3;
  }

  void _startChecklistPulse() {
    _ringPulseController.repeat(reverse: true);
  }

  void _stopChecklistPulse() {
    _ringPulseController
      ..stop()
      ..reset();
  }

  @override
  void initState() {
    super.initState();
    _parsingDotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _ringPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _inputGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6200),
    )..repeat();
    _swipeHintController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat(reverse: true);

    // Listen to sheet controller to dismiss modal when dragged down
    _sheetController.addListener(_handleSheetSizeChange);
    _urlController.addListener(_onUrlControllerChanged);

    // Pre-decode parsing hero image so the first frame doesn't jank.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        precacheImage(
          const AssetImage('assets/parsing_pan_hero.png'), context,
        );
      }
    });

    // 로컬 파싱 완료 시 Firestore 구독 없이 100% 부드럽게 차오른 뒤 디테일 이동
    _completionStreamSubscription = _backgroundParsingService.onParsingComplete.listen((event) {
      final recipeId = event['recipeId'] as String?;
      if (recipeId == null || recipeId != _currentParsingRecipeId || !mounted || !_isParsing) return;
      final status = event['status'] as String?;
      if (status == 'completed') {
        _animateProgressTo100ThenNavigate(recipeId);
      } else if (status == 'error') {
        setState(() {
          _isParsing = true;
          _showParseErrorInSheet = false;
          _parseErrorMessage = '';
          _currentStage = '분석중...';
        });
      }
    });

    // Open in progress mode for an existing parsing recipe (e.g. from home card tap)
    if (widget.initialParsingRecipeId != null && widget.initialParsingRecipeId!.isNotEmpty) {
      _currentParsingRecipeId = widget.initialParsingRecipeId;
      final cachedProgress = RecipeService.parsingProgressCache.getProgress(_currentParsingRecipeId!);
      final cachedStage = RecipeService.parsingProgressCache.getStage(_currentParsingRecipeId!);
      setState(() {
        _isParsing = true;
        _currentStage = cachedStage;
        _currentProgress = cachedProgress;
        _animatedProgress = cachedProgress;
        _displayProgress = cachedProgress;
        _visualParsePhase = _phaseFromProgress(cachedProgress);
        if (widget.initialSourceUrl != null && widget.initialSourceUrl!.isNotEmpty) {
          _parsingDisplayUrl = widget.initialSourceUrl!;
        }
      });
      _subscribeToParsingProgress(widget.initialParsingRecipeId!);
      _attachParsingCacheListener();
      _startChecklistPulse();
    }
    
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      final sanitized = _sanitizeRecipeUrlInput(widget.initialUrl!);
      if (sanitized.isNotEmpty) {
        _urlController.text = sanitized;
      }
      // 공유로 들어온 링크는 입력 후 '분석하기'까지 자동으로 눌러준다.
      if (widget.autoAnalyze && !_isParsing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isLoading && !_isParsing) {
            _urlFocusNode.unfocus();
            FocusManager.instance.primaryFocus?.unfocus();
            _handleSubmit();
          }
        });
      }
    }

    if (_shouldFocusUrlField) {
      _armUrlFieldFocus();
    }
  }

  void _armUrlFieldFocus() {
    _allowTapOutsideUnfocus = false;
    _urlFocusReadyTimer?.cancel();
    void focusNow() {
      if (!mounted || !_shouldFocusUrlField) return;
      _urlFocusNode.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusNow();
      _urlFocusReadyTimer = Timer(const Duration(milliseconds: 280), () {
        focusNow();
        _allowTapOutsideUnfocus = true;
      });
    });
  }

  void _onUrlControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 공유 텍스트·붙여넣기에서 첫 URL만 추출하고 길이를 제한한다.
  /// (본문 전체가 들어오면 unwrap regex가 UI 스레드를 오래 잡을 수 있음)
  String _sanitizeRecipeUrlInput(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    const maxLen = 2048;
    final match = RegExp(
      r'https?://[^\s\)\]<>"]+',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match != null) {
      var url = match.group(0)!;
      url = url.replaceAll(RegExp(r'[.,;:!?]+$'), '');
      if (url.length > maxLen) url = url.substring(0, maxLen);
      return url;
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed.length > maxLen ? trimmed.substring(0, maxLen) : trimmed;
    }

    final loose = RegExp(
      r'(?:www\.)?(?:youtube\.com|youtu\.be|m\.youtube\.com|'
      r'instagram\.com|instagr\.am|tiktok\.com|'
      r'blog\.naver\.com|m\.blog\.naver\.com|naver\.me)'
      r'[^\s\)\]<>"]*',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (loose != null) {
      var url = 'https://${loose.group(0)!}';
      url = url.replaceAll(RegExp(r'[.,;:!?]+$'), '');
      if (url.length > maxLen) url = url.substring(0, maxLen);
      return url;
    }

    return trimmed.length > maxLen ? trimmed.substring(0, maxLen) : trimmed;
  }

  void _showLinkRequiredSnack() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    showAppSnackBar(context, 
      SnackBar(
        content: Text(l10n?.enterYouTubeUrl ?? '레시피 링크를 입력해주세요'),
      ),
    );
  }

  /// 유튜브/인스타/틱톡/네이버 블로그 URL인지 검사
  bool _isAllowedPlatformUrl(String url) {
    final lower = url.trim().toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('instagram.com') ||
        lower.contains('instagr.am') ||
        lower.contains('tiktok.com') ||
        lower.contains('vt.tiktok.com') ||
        isNaverBlogUrl(url);
  }

  Future<void> _handleSubmit() async {
    if (_isLoading || _isParsing) return;

    final recipeUrl = _sanitizeRecipeUrlInput(_urlController.text);
    if (recipeUrl.isEmpty) {
      _showLinkRequiredSnack();
      return;
    }

    if (!_isAllowedPlatformUrl(recipeUrl)) {
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('유튜브, 인스타그램, 틱톡, 네이버 블로그 링크만 분석할 수 있습니다.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (recipeUrl != _urlController.text) {
      _urlController.text = recipeUrl;
    }

    setState(() {
      _isLoading = true;
    });

    String canonicalUrl;
    try {
      final canonical = _recipeService.buildCanonicalSourceInfo(recipeUrl);
      canonicalUrl = canonical.normalizedUrl;
    } catch (e, st) {
      debugPrint('[AddRecipeScreen] URL normalize failed: $e\n$st');
      if (mounted) {
        setState(() => _isLoading = false);
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('링크를 확인할 수 없어요. URL만 다시 붙여넣어 주세요.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // 네이버 블로그는 본인이 owner 인 메타 doc 이 firestore 에 영구 보존되지만
    // 본문(재료/단계/og 이미지)은 저작권 §30 사적복제 안전구간 유지를 위해
    // 사용자 본인 디바이스 로컬 저장소에만 보관된다. 따라서
    //  - 로컬 본문이 살아 있으면 → YT/IG/TT 와 동일하게 디테일 직행(백엔드 호출 X)
    //  - 로컬 본문이 사라진 경우(북마크 해제·앱 재설치 등) → 선행 룩업을 우회하고
    //    BackgroundParsingService 의 네이버 dedup 분기(naverDedupRecipeId +
    //    skipMetaWrite=true)로 흘려서 같은 recipeId 재사용 + 본문 재추출 +
    //    savedRecipes 재attach 가 일어나게 한다.
    // 네이버 메타 doc 자체에는 본문이 들어 있지 않으므로(_writeNaverMeta) ,
    // getRecipeById 가 합쳐 돌려준 ParseResponse 의 recipe.ingredients 가
    // 비어있는지로 로컬 본문 존재 여부를 판정한다.
    final bool isNaver = isNaverBlogUrl(canonicalUrl);
    if (!isNaver) {
      try {
        String? existingRecipeId = await _recipeService
            .getUserSavedOrOwnedRecipeIdBySourceUrl(canonicalUrl);
        models.ParseResponse? existingParseResponse;

        if (existingRecipeId != null) {
          existingParseResponse = await _recipeService.getRecipeById(existingRecipeId);
        } else {
          final existingRecipeData = await _recipeService.getRecipeBySourceUrl(
            canonicalUrl,
          );
          if (existingRecipeData != null) {
            final foundRecipeId = existingRecipeData['id'] as String?;
            if (foundRecipeId != null && foundRecipeId.isNotEmpty) {
              existingRecipeId = foundRecipeId;
              final currentUser = FirebaseAuth.instance.currentUser;
              if (currentUser != null) {
                await UserService().addSavedRecipe(currentUser.uid, foundRecipeId);
              }
              existingParseResponse = await _recipeService
                  .getParseResponseFromRecipeData(existingRecipeData);
              existingParseResponse ??= await _recipeService.getRecipeById(
                foundRecipeId,
              );
            }
          }
        }

        if (existingRecipeId != null && existingParseResponse != null) {
          if (!mounted) return;
          setState(() {
            _isLoading = false;
          });
          await _handleExistingRecipe(
            parseResponse: existingParseResponse,
            recipeId: existingRecipeId,
          );
          return;
        }
      } catch (e) {
        print('[AddRecipeScreen] Existing recipe lookup failed: $e');
        // Continue to parsing flow when duplicate-check lookup fails.
      }
    } else {
      try {
        final ownedId = await _recipeService
            .getUserSavedOrOwnedRecipeIdBySourceUrl(canonicalUrl);
        if (ownedId != null) {
          final parseResponse = await _recipeService.getRecipeById(ownedId);
          if (parseResponse != null &&
              parseResponse.recipe.ingredients.isNotEmpty) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
            });
            await _handleExistingRecipe(
              parseResponse: parseResponse,
              recipeId: ownedId,
            );
            return;
          }
        }
      } catch (e) {
        print('[AddRecipeScreen] Naver local body lookup failed: $e');
        // Fall through to parsing flow on lookup failure.
      }
    }

    // 이미 저장된 레시피(dedup)는 위에서 처리되므로, 여기서부터가 실제 분석이다.
    // 게스트 무료 1회를 다 썼다면 이 지점에서 로그인으로 유도한다.
    if (!await _ensureParseAllowed(pendingUrl: canonicalUrl)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // Pop immediately and show an optimistic parsing card on the home screen.
    // Create the placeholder card synchronously BEFORE the pop so the home
    // screen already has it when it rebuilds.
    _stopChecklistPulse();
    _detachParsingCacheListener();
    _parsingProgressSubscription?.cancel();
    _parsingProgressSubscription = null;

    final preId = RecipeService.addOptimisticParsingRecipe(
      sourceUrl: canonicalUrl,
    );
    RecipeService.parsingProgressCache.startProgressSimulation(preId);
    RecipeService.notifyRecipesChanged();

    // 분석 시도를 히스토리에 즉시 남긴다(실패/지연에도 링크가 사라지지 않도록).
    ParseHistoryService.instance.record(
      id: preId,
      kind: 'link',
      url: canonicalUrl,
      platform: RecipeService.inferPlatformFromUrl(canonicalUrl),
    );

    setState(() {
      _isParsing = false;
      _isLoading = false;
      _visualParsePhase = 0;
    });
    _closePresentedSheet();
    if (isNaver) {
      _showStayInAppSnack();
    } else {
      _showParseStartedSnack();
    }

    // Everything below runs after the modal is dismissed.
    final urlFuture = _backgroundParsingService.startBackgroundParsing(
      url: canonicalUrl,
      preferLang: 'ko',
      preAllocatedRecipeId: preId,
    );
    urlFuture.then((id) {
      if (id.isNotEmpty) {
        ParseHistoryService.instance.remap(preId, id);
      }
    }).catchError((_) {});
    urlFuture.catchError((e) async {
      if (e is ExistingRecipeException) {
        await ParseHistoryService.instance.remap(preId, e.recipeId);
        final parseResponse = await _recipeService.getRecipeById(e.recipeId);
        final pushContext = mainNavigatorKey.currentContext;
        if (parseResponse != null && pushContext != null) {
          Future.microtask(() {
            Navigator.pushNamed(
              pushContext,
              '/recipe-detail',
              arguments: {'parseResponse': parseResponse, 'recipeId': e.recipeId},
            );
          });
          return e.recipeId;
        }
      } else {
        await _markParseHistoryStartFailure(preId, e);
      }
      final pushContext = mainNavigatorKey.currentContext;
      if (pushContext != null) {
        showAppSnackBar(pushContext, 
          SnackBar(
            content: Text(_parseHistoryErrorMessage(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return '';
    });
  }

  Widget _figmaDotWidget() {
    return Container(
      width: 3,
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: ShapeDecoration(
        color: _figmaDot,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(1.5)),
      ),
    );
  }

  void _openParseHistory() {
    final ctx = mainNavigatorKey.currentContext ?? context;
    Navigator.of(ctx, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const ParseHistoryScreen()),
    );
  }

  /// 분석 실패에 대한 불안을 줄이는 신뢰 마이크로카피. 탭하면 분석 기록으로 이동.
  Widget _buildTrustMicrocopy() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openParseHistory,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.shield_outlined,
            size: 13,
            color: Color(0xFFB6BCC6),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '분석에 실패해도 링크는 안전하게 보관돼요',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                color: Color(0xFFB6BCC6),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '분석 기록',
            style: TextStyle(
              fontFamily: 'Pretendard',
              color: Color(0xFFFF6B00),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              size: 14, color: Color(0xFFFF6B00)),
        ],
      ),
    );
  }

  Widget _supportedPlatformsRow() {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _platformChip('YouTube', 'lib/assets/youtube-app-icon-hd.png'),
            _figmaDotWidget(),
            _platformChip('Instagram', 'lib/assets/instagram-app-icon-hd.png'),
            _figmaDotWidget(),
            _platformChip('TikTok', 'lib/assets/tiktok-app-icon-hd.png'),
            _figmaDotWidget(),
            _platformChip(
              '네이버 블로그',
              'assets/icons/naver_blog_chip.png',
            ),
          ],
        ),
      ),
    );
  }

  Widget _platformChip(String label, String assetPath, {IconData? icon}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: icon != null
              ? Icon(icon, size: 16, color: _figmaPlatformLabel)
              : Image.asset(assetPath, fit: BoxFit.contain),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: _figmaPlatformLabel,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ),
      ],
    );
  }

  /// Example video card — Figma 97-5289. Logo + text; big square rounded export button fills link into parsing field.
  Widget _buildExampleCard({
    required String handle,
    required String title,
    required String assetPath,
    required String exportUrl,
    required VoidCallback onExportTap,
  }) {
    return Container(
      height: 61.25,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(width: 1, color: Color(0xFFF0F1F3)),
          borderRadius: BorderRadius.circular(16),
        ),
        shadows: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 12,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipOval(
            child: SizedBox(
              width: 40,
              height: 40,
              child: Image.asset(assetPath, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  handle,
                  style: const TextStyle(
                    color: Color(0xFFB4BAC4),
                    fontSize: 10.50,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w600,
                    height: 1.50,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF1A1A2E),
                    fontSize: 13,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w700,
                    height: 1.50,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              side: const BorderSide(width: 1, color: Color(0xFFF3F4F6)),
              borderRadius: BorderRadius.circular(33554400),
            ),
            shadowColor: const Color(0x05000000),
            elevation: 2,
            child: InkWell(
              onTap: onExportTap,
              borderRadius: BorderRadius.circular(33554400),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      '영상 분석',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(
                      Icons.arrow_outward_rounded,
                      size: 13,
                      color: Color(0xFF9CA3AF),
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

  static const List<(String, String)> _kFigmaParsingSteps = [
    ('링크 확인 중', 'URL 유효성 검사'),
    ('영상 읽는 중', '자막 & 설명 추출'),
    ('재료 분석 중', 'AI 성분 인식'),
    ('레시피 정리 중', '단계별 구성'),
  ];

  String _parsingUrlForDisplay() {
    final u = _parsingDisplayUrl.trim();
    if (u.isNotEmpty) return u;
    return _urlController.text.trim();
  }

  String _platformKeyForUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('instagram')) return 'instagram';
    if (lower.contains('tiktok')) return 'tiktok';
    return 'youtube';
  }

  Widget _buildParsingThreeDots() {
    return AnimatedBuilder(
      animation: _parsingDotsController,
      builder: (context, child) {
        final t = _parsingDotsController.value * 2 * math.pi;
        return SizedBox(
          width: 18,
          height: 7,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (i) {
              final o = (0.35 + 0.65 * (0.5 + 0.5 * math.sin(t + i * 0.65)))
                  .clamp(0.35, 1.0);
              return Opacity(
                opacity: o,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9F5A),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  double _connectorFillFraction(int index) {
    const phaseStarts = [0.0, 10.0, 45.0, 70.0];
    const phaseEnds = [10.0, 45.0, 70.0, 100.0];
    final nextIndex = index + 1;
    if (nextIndex > 3) return 0.0;
    if (_visualParsePhase > nextIndex) return 1.0;
    if (_visualParsePhase < nextIndex) return 0.0;
    final start = phaseStarts[nextIndex];
    final end = phaseEnds[nextIndex];
    final range = end - start;
    if (range <= 0) return 0.0;
    return ((_animatedProgress - start) / range).clamp(0.0, 1.0);
  }

  Widget _buildFigmaParsingStepRow({
    required int index,
    required bool isDone,
    required bool isActive,
    required bool showConnectorBelow,
    required int activeStepIndex,
    bool isNextDone = false,
    double connectorFill = 0.0,
  }) {
    const orange = Color(0xFFFF6422);
    const green = Color(0xFF22C55E);
    const titleDone = green;
    const titleActive = Color(0xFF111111);
    const titlePending = Color(0xFFC4C9D4);
    const subtitleDone = Color(0xB322C55E); // green 70%
    const subtitleActive = Color(0xFFB4BAC4);

    final title = _kFigmaParsingSteps[index].$1;
    final subtitle = _kFigmaParsingSteps[index].$2;

    // Completed → orange, active → black, future → grey
    final titleColor = isDone ? titleDone : isActive ? titleActive : titlePending;
    final subtitleColor = isDone ? subtitleDone : subtitleActive;

    // Show subtitle only for completed steps and the immediately next step (activeStepIndex).
    // Hide for steps 2+ ahead of the active step.
    final bool showSubtitle = subtitle.isNotEmpty &&
        (isDone || isActive || (activeStepIndex >= 0 && index <= activeStepIndex));

    Widget leadingIcon;
    if (isDone) {
      leadingIcon = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: green,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x4022C55E),
              blurRadius: 8,
              spreadRadius: 0,
              offset: Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.check_rounded, size: 13, color: Colors.white),
      );
    } else if (isActive) {
      final core = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: orange, width: 2),
          borderRadius: BorderRadius.circular(11),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14FF6422),
              blurRadius: 4,
              spreadRadius: 2,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Container(
          width: 10.33,
          height: 10.33,
          decoration: BoxDecoration(
            color: orange,
            borderRadius: BorderRadius.circular(5.16),
          ),
        ),
      );
      leadingIcon = AnimatedBuilder(
        animation: _ringPulseController,
        builder: (context, child) {
          final v = Curves.easeInOut.transform(_ringPulseController.value);
          final w = 1.0 - v;
          return SizedBox(
            width: 22,
            height: 22,
            child: OverflowBox(
              maxWidth: 38,
              maxHeight: 38,
              alignment: Alignment.center,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Transform.scale(
                    scale: 1.0 + 0.28 * v,
                    child: Opacity(
                      opacity: 0.12 + 0.22 * v,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFF6422),
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: 1.0 + 0.18 * w,
                    child: Opacity(
                      opacity: 0.10 + 0.20 * w,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFF9F5A),
                            width: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  child!,
                ],
              ),
            ),
          );
        },
        child: core,
      );
    } else {
      leadingIcon = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: const Color(0xFFD1D5DB),
            borderRadius: BorderRadius.circular(3.5),
          ),
        ),
      );
    }

    final Color connectorBaseColor;
    if (isDone && isNextDone) {
      connectorBaseColor = green;
    } else if (isDone) {
      connectorBaseColor = const Color(0xFFF0F1F3);
    } else {
      connectorBaseColor = const Color(0xFFF0F1F3);
    }

    late final Widget trailing;
    if (isDone) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x1A22C55E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          '완료',
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: green,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            height: 1.5,
          ),
        ),
      );
    } else if (isActive) {
      trailing = Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _buildParsingThreeDots(),
      );
    } else {
      trailing = const SizedBox(width: 18, height: 7);
    }

    final rowHeight = index == 3
        ? (showSubtitle ? 48.0 : 22.0)
        : (showSubtitle ? 54.0 : 36.0);

    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                leadingIcon,
                if (showConnectorBelow && index < 3)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Center(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final totalH = constraints.maxHeight;
                            return TweenAnimationBuilder<double>(
                              tween: Tween<double>(end: connectorFill),
                              duration: const Duration(milliseconds: 800),
                              curve: Curves.easeInOut,
                              builder: (context, animatedFill, _) {
                                final fillH = (animatedFill * totalH).clamp(0.0, totalH);
                                return SizedBox(
                                  width: 2,
                                  height: totalH,
                                  child: Stack(
                                    children: [
                                      Container(
                                        width: 2,
                                        height: totalH,
                                        decoration: BoxDecoration(
                                          color: connectorBaseColor,
                                          borderRadius: BorderRadius.circular(1),
                                        ),
                                      ),
                                      if (animatedFill > 0)
                                        Container(
                                          width: 2,
                                          height: fillH,
                                          decoration: BoxDecoration(
                                            color: green,
                                            borderRadius: BorderRadius.circular(1),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: index == 3
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: titleColor,
                                  fontSize: 14,
                                  fontWeight:
                                      isActive || isDone ? FontWeight.w700 : FontWeight.w500,
                                  height: 1.5,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              if (showSubtitle)
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    color: subtitleColor,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    height: 1.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      trailing,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: titleColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  height: 1.5,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              if (showSubtitle)
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    color: subtitleColor,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    height: 1.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: trailing,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFigmaParsingContent(Brightness brightness) {
    final activeIdx =
        _visualParsePhase < 4 ? _visualParsePhase : -1;
    final headerIdx = activeIdx >= 0 ? activeIdx : 3;
    final headerTitle = _kFigmaParsingSteps[headerIdx].$1;
    final headerSubtitle = _kFigmaParsingSteps[headerIdx].$2;

    final done0 = _visualParsePhase >= 1;
    final done1 = _visualParsePhase >= 2;
    final done2 = _visualParsePhase >= 3;
    final done3 = _visualParsePhase >= 4;

    final urlText = _parsingUrlForDisplay();
    final platformAsset = _examplePlatformAssetPath(_platformKeyForUrl(urlText));

    // Content only — sheet chrome (white, radius, shadow) is the DraggableScrollableSheet container.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 374),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 130,
                height: 130,
                child: Image.asset(
                  'assets/parsing_pan_hero.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                headerTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  color: Color(0xFF111111),
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  height: 1.5,
                  letterSpacing: -0.5,
                ),
              ),
              if (headerSubtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  headerSubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFFB4BAC4),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: ShapeDecoration(
                  color: const Color(0xFFF8F9FA),
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(width: 1, color: Color(0xFFF0F1F3)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: ClipOval(
                        child: Image.asset(
                          platformAsset,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        urlText.isEmpty ? '…' : urlText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Color(0xFFC4C9D4),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  children: [
                    _buildFigmaParsingStepRow(
                      index: 0,
                      isDone: done0,
                      isActive: !done0 && activeIdx == 0,
                      showConnectorBelow: true,
                      activeStepIndex: activeIdx,
                      isNextDone: done1,
                      connectorFill: _connectorFillFraction(0),
                    ),
                    _buildFigmaParsingStepRow(
                      index: 1,
                      isDone: done1,
                      isActive: !done1 && activeIdx == 1,
                      showConnectorBelow: true,
                      activeStepIndex: activeIdx,
                      isNextDone: done2,
                      connectorFill: _connectorFillFraction(1),
                    ),
                    _buildFigmaParsingStepRow(
                      index: 2,
                      isDone: done2,
                      isActive: !done2 && activeIdx == 2,
                      showConnectorBelow: true,
                      activeStepIndex: activeIdx,
                      isNextDone: done3,
                      connectorFill: _connectorFillFraction(2),
                    ),
                    _buildFigmaParsingStepRow(
                      index: 3,
                      isDone: done3,
                      isActive: !done3 && activeIdx == 3,
                      showConnectorBelow: false,
                      activeStepIndex: activeIdx,
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

  Widget _buildRecipeInputFormScroll(Brightness brightness) {
    final keyboardLift = MediaQuery.viewInsetsOf(context).bottom;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final dockOffset = AddRecipeScreen.bottomNavOffsetFor(context);
    final innerBottom = 10.0 +
        ((keyboardLift > 80 || dockOffset > 1) ? 0.0 : bottomSafe);
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 5,
          bottom: innerBottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: SizedBox(
                    width: 72,
                    height: 19,
                    child: Image.asset(
                      'assets/yorigo_korean_logo.png',
                      height: 19,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      isAntiAlias: true,
                      errorBuilder: (_, __, ___) => const Text(
                        '요리GO',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFF6900),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  '|',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFFE5E7EB),
                    fontSize: 18,
                    fontWeight: FontWeight.w200,
                    height: 1.5,
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: SizedBox(
                    width: 184,
                    child: Text(
                      _inputModeTagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFF99A1AF),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.325,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 345),
              child: _buildUnifiedInputCard(),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _isManualMode
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 345),
                        child: _supportedPlatformsRow(),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 345),
              child: _buildTrustMicrocopy(),
            ),
          ],
        ),
      ),
    );
  }

  /// 키보드가 올라온 뒤에도 시트+패딩이 화면을 넘지 않도록, 키보드 제외
  /// 영역(`available`) 기준으로 높이를 잡는다 (profile_feedback_sheet 와 동일 패턴).
  double _computeSheetHeight({
    required double screenHeight,
    required double keyboardHeight,
    required double bottomSafeArea,
  }) {
    if (_isParsing) {
      final available = screenHeight - keyboardHeight;
      if (keyboardHeight > 0) {
        return math.min(screenHeight * 0.85, available * 0.92);
      }
      return screenHeight * 0.85;
    }

    // 썸네일 행은 모드와 무관하게 이미지가 있으면 항상 표시되므로,
    // 글 모드라도 이미지가 있으면 스크린샷 모드와 같은 큰 높이를 써야 한다.
    final bool tallManual =
        _isManualMode && (_isPhotoMode || _manualImages.isNotEmpty);

    final available = screenHeight - keyboardHeight;
    if (keyboardHeight > 0) {
      // 링크·글 모두 available 비율 사용 (전체 화면 64% 등 이중 여백 방지).
      // 링크 모드는 카드 아래 지원 플랫폼 행이 추가로 들어가 글 모드보다 더 높다.
      final ratio = _isManualMode
          ? (tallManual ? 0.58 : 0.46)
          : 0.46;
      final minHeight = _isManualMode ? (tallManual ? 312.0 : 244.0) : 244.0;
      return math.min(available, math.max(available * ratio, minHeight));
    }

    if (_isManualMode) {
      // 썸네일/안내문(최대 4줄)이 있는 상태가 가장 높다. 시트 Column 은
      // mainAxisSize.min 이라 내용보다 크면 자동으로 줄어들어 여백은 안 생긴다.
      return tallManual
          ? math.max(screenHeight * 0.38, 312.0 + bottomSafeArea)
          : math.max(screenHeight * 0.30, 244.0 + bottomSafeArea);
    }
    // 링크 모드: 지원 플랫폼 행(+상단 14px 간격) 만큼 글 모드보다 높이를 더 준다.
    // 시트 Column 은 mainAxisSize.min 이라 내용보다 크면 자동으로 줄어든다.
    return math.max(screenHeight * 0.30, 244.0 + bottomSafeArea);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final bottomSafeArea = mediaQuery.padding.bottom;
    final dockOffset = AddRecipeScreen.bottomNavOffsetFor(context);
    final keyboardLift = keyboardHeight > 80 ? keyboardHeight : 0.0;
    final sheetHeight = _computeSheetHeight(
      screenHeight: screenHeight,
      keyboardHeight: keyboardLift,
      bottomSafeArea: bottomSafeArea,
    );
    // 핸들 영역을 뺀 본문만 상한 — 키보드 시 height 강제(튕김) 없이 overflow 방지.
    const double sheetHandleExtent = 24.0;
    final double formMaxHeight =
        math.max(0.0, sheetHeight - sheetHandleExtent);
    final bool sheetGrowing = sheetHeight > _lastSheetHeight + 0.5;
    _lastSheetHeight = sheetHeight;
    final Duration sheetAnimDuration = sheetGrowing
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 260);
    return DefaultTextStyle(
      style: const TextStyle(fontFamily: 'Pretendard'),
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: keyboardLift > 0 ? keyboardLift : dockOffset,
        ),
        child: AnimatedContainer(
          duration: sheetAnimDuration,
          curve: Curves.easeOutCubic,
          height: _isParsing ? sheetHeight : null,
          constraints: _isParsing
              ? null
              : BoxConstraints(maxHeight: sheetHeight),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: sheetHeight),
                  child: Container(
        decoration: _isParsing
            ? const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 48,
                    offset: Offset(0, -8),
                    spreadRadius: 0,
                  ),
                ],
              )
            : BoxDecoration(
                color: AppColors.getBackground(brightness),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 16,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
        child: Column(
          mainAxisSize:
              _isParsing ? MainAxisSize.max : MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _isParsing
                    ? const Color(0xFFE5E7EB)
                    : AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
                if (_isParsing && _swipeHintController != null)
                  AnimatedBuilder(
                    animation: _swipeHintController!,
                    builder: (context, child) {
                      final t = _swipeHintController!.value;
                      final y = math.sin(t * math.pi) * 4;
                      final opacity = 0.85 + 0.15 * math.sin(t * math.pi);
                      return Transform.translate(
                        offset: Offset(0, y),
                        child: Opacity(opacity: opacity, child: child),
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFFFFE0C2),
                          width: 0.8,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x12FF6422),
                            blurRadius: 12,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFFF0E5),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.arrow_downward_rounded,
                              size: 11,
                              color: Color(0xFFFF7A30),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '스와이프해도 백그라운드에서 분석이 계속 진행돼요',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Color(0xFF9B6840),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_isParsing)
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                      // Show error with delete/retry when parsing failed (opened from card)
                      if (_showParseErrorInSheet) {
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.error_outline_rounded, size: 64, color: Colors.red.shade400),
                              const SizedBox(height: 16),
                              Text(
                                '파싱 중 오류가 발생했습니다',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.getTextPrimary(Theme.of(context).brightness),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _parseErrorMessage,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.getTextSecondary(Theme.of(context).brightness),
                                ),
                              ),
                              const SizedBox(height: 32),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      if (widget.initialParsingRecipeId == null) return;
                                      await _recipeService.deleteRecipe(widget.initialParsingRecipeId!);
                                      if (mounted) _closePresentedSheet();
                                    },
                                    child: const Text('삭제', style: TextStyle(fontFamily: 'Pretendard', color: Colors.red, fontWeight: FontWeight.w600)),
                                  ),
                                  const SizedBox(width: 16),
                                  TextButton(
                                    onPressed: (widget.initialSourceUrl == null || widget.initialSourceUrl!.isEmpty)
                                        ? null
                                        : () async {
                                            if (widget.initialParsingRecipeId == null || widget.initialSourceUrl == null) return;
                                            // Optimistic retry: reuse same recipe ID so card stays and shows parsing (same as first-time add)
                                            await _backgroundParsingService.retryParsing(
                                              recipeId: widget.initialParsingRecipeId!,
                                              url: widget.initialSourceUrl!,
                                              preferLang: 'ko',
                                            );
                                            if (!mounted) return;
                                            setState(() {
                                              _showParseErrorInSheet = false;
                                              _parseErrorMessage = '';
                                              _isParsing = true;
                                              _currentStage = '분석중...';
                                              _currentProgress = 0.0;
                                              _animatedProgress = 0.0;
                                              _displayProgress = 0.0;
                                              if (widget.initialSourceUrl != null &&
                                                  widget.initialSourceUrl!.isNotEmpty) {
                                                _parsingDisplayUrl = widget.initialSourceUrl!;
                                              }
                                            });
                                            _subscribeToParsingProgress(widget.initialParsingRecipeId!);
                                            _startChecklistPulse();
                                          },
                                    child: Text('다시 시도', style: TextStyle(fontFamily: 'Pretendard', color: AppColors.primary, fontWeight: FontWeight.w600)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }
                      // Show inline progress when parsing
                      if (_isParsing) {
                        return Semantics(
                          label:
                              '레시피 분석 중, 단계 ${_visualParsePhase.clamp(0, 4)} / 4, 진행 ${_currentProgress.toStringAsFixed(0)}퍼센트',
                          child: SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            child: _buildFigmaParsingContent(brightness),
                          ),
                        );
                      }

                      return _buildRecipeInputFormScroll(brightness);
                    },
                  ),
                )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: formMaxHeight),
                    child: _buildRecipeInputFormScroll(brightness),
                  ),
              ],
            ),
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

class _InputCardGlowPainter extends CustomPainter {
  const _InputCardGlowPainter({
    required this.progress,
    required this.radius,
  });

  final double progress;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1.2),
      Radius.circular(radius),
    );
    final shaderRect = rect.inflate(24);
    final rotation = progress * math.pi * 2;
    final colors = <Color>[
      const Color(0x00FF6B00),
      const Color(0x1FFFBEDE),
      const Color(0xB3FF6B00),
      const Color(0x33FFB26F),
      const Color(0x1FFFBEDE),
      const Color(0xB3FF6B00),
      const Color(0x33FFB26F),
      const Color(0x00FF6B00),
      const Color(0x00FF6B00),
    ];
    final stops = <double>[0.0, 0.16, 0.22, 0.28, 0.66, 0.72, 0.78, 0.88, 1.0];
    final shader = SweepGradient(
      colors: colors,
      stops: stops,
      transform: GradientRotation(rotation),
    ).createShader(shaderRect);

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..shader = shader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawRRect(rrect, glowPaint);

    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..shader = shader;
    canvas.drawRRect(rrect, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant _InputCardGlowPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.radius != radius;
  }
}

class _ParsingPanAnimation extends StatefulWidget {
  const _ParsingPanAnimation({
    required this.currentStep,
    required this.completedSteps,
  });

  final int currentStep;
  final List<int> completedSteps;

  @override
  State<_ParsingPanAnimation> createState() => _ParsingPanAnimationState();
}

class _ParsingPanAnimationState extends State<_ParsingPanAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop;

  static const _ingredients = <({int step, double cx, double cy, double r})>[
    (step: 0, cx: 64, cy: 76, r: 7.5),
    (step: 1, cx: 84, cy: 87, r: 8.5),
    (step: 2, cx: 65, cy: 91, r: 6.5),
    (step: 3, cx: 87, cy: 70, r: 7.0),
  ];
  static const _steam = <({double x, double delay})>[
    (x: 60, delay: 0.0),
    (x: 73, delay: 0.6),
    (x: 86, delay: 1.15),
  ];
  static const _bubbles = <({double x, double y, double delay})>[
    (x: 58, y: 80, delay: 0.0),
    (x: 76, y: 87, delay: 0.42),
    (x: 68, y: 73, delay: 0.78),
    (x: 84, y: 79, delay: 1.1),
  ];

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  bool get _isActiveStep =>
      widget.currentStep >= 0 &&
      !widget.completedSteps.contains(widget.currentStep);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, child) {
        final t = _loop.value;
        final sec = t * 4.2;
        final shakeSin = math.sin(sec * (2 * math.pi / 0.48));
        final rotDeg = _isActiveStep ? 1.4 * shakeSin : 0.0;
        final shiftX = _isActiveStep ? 0.8 * shakeSin : 0.0;

        return SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [Color(0x12FF6422), Color(0x00FF6422)],
                        stops: [0, 0.7],
                      ),
                    ),
                  ),
                ),
              ),
              ...List.generate(3, (i) {
                final angle = 2 * math.pi * t + (i * 2 * math.pi / 3);
                final dx = 62 * math.cos(angle);
                final dy = 62 * math.sin(angle);
                final phase = (t + i / 3) % 1.0;
                final opacity = (0.6 + 0.4 * (1 - (phase - 0.5).abs() * 2))
                    .clamp(0.0, 1.0);
                return Positioned(
                  left: 80 - 2.5 + dx,
                  top: 80 - 2.5 + dy,
                  child: Opacity(
                    opacity: opacity,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [Color(0xFFFFCC88), Color(0xFFFF6422)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x8CFF6422),
                            blurRadius: 7,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              if (widget.completedSteps.isNotEmpty)
                ..._steam.map((s) {
                  final local = ((sec - s.delay) % 1.9 + 1.9) % 1.9 / 1.9;
                  final opacity = local < 0.1
                      ? 0.0
                      : (1.0 - local).clamp(0.0, 1.0) * 0.75;
                  final y = -32 * local;
                  final x = (s.x == 73 ? 5 : -5) * local;
                  final scaleX = 1 + (1.2 * local);
                  return Positioned(
                    left: s.x + x,
                    top: 38 + y,
                    child: Opacity(
                      opacity: opacity,
                      child: Transform.scale(
                        scaleX: scaleX,
                        scaleY: 1,
                        child: Container(
                          width: 5,
                          height: 13,
                          decoration: BoxDecoration(
                            color: const Color(0x61B4C3DC),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              Transform.translate(
                offset: Offset(shiftX, 0),
                child: Transform.rotate(
                  angle: rotDeg * math.pi / 180,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 114,
                        top: 84,
                        child: Container(
                          width: 40,
                          height: 11,
                          decoration: BoxDecoration(
                            color: const Color(0x66000000),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 112,
                        top: 78,
                        child: Container(
                          width: 40,
                          height: 11,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF606060),
                                Color(0xFF3C3C3C),
                                Color(0xFF222222),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 114,
                        top: 79.5,
                        child: Container(
                          width: 36,
                          height: 3,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: const Color(0x1AFFFFFF),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 117,
                        top: 80.5,
                        child: Container(
                          width: 6.4,
                          height: 6.4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF2A2A2A),
                            border: Border.all(color: const Color(0xFF555555)),
                          ),
                          child: Center(
                            child: Container(
                              width: 2.8,
                              height: 2.8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF666666),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 39,
                        top: 45,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0x4D000000),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 36,
                        top: 40,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(
                              center: Alignment(-0.2, -0.35),
                              radius: 0.9,
                              colors: [Color(0xFF606060), Color(0xFF1C1C1C)],
                            ),
                            border: Border.all(
                              color: const Color(0xFF3C3C3C),
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 43,
                        top: 47,
                        child: Container(
                          width: 66,
                          height: 66,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              center: Alignment(-0.2, -0.35),
                              radius: 0.95,
                              colors: [Color(0xFF2C2C2C), Color(0xFF0D0D0D)],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 57,
                        top: 61,
                        child: Transform.rotate(
                          angle: -20 * math.pi / 180,
                          child: Container(
                            width: 18,
                            height: 11,
                            decoration: const BoxDecoration(
                              color: Color(0x12FFFFFF),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      ..._ingredients.map((ing) {
                        final isDone = widget.completedSteps.contains(ing.step);
                        final isActiveIngredient =
                            widget.currentStep == ing.step && !isDone;
                        if (!isDone && !isActiveIngredient) {
                          return const SizedBox.shrink();
                        }
                        final pulse = isActiveIngredient
                            ? (1 + 0.2 * math.sin(sec * 8)).clamp(0.85, 1.25)
                            : 1.0;
                        final dropProgress = (sec % 0.8 / 0.8).clamp(0.0, 1.0);
                        final y = isDone ? 0.0 : (-8 * (1 - dropProgress));
                        return Positioned(
                          left: ing.cx - ing.r,
                          top: ing.cy - ing.r + y,
                          child: Opacity(
                            opacity: isDone ? 1.0 : dropProgress,
                            child: Transform.scale(
                              scale: pulse,
                              child: Container(
                                width: ing.r * 2,
                                height: ing.r * 2,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    center: const Alignment(-0.35, -0.4),
                                    colors: isDone
                                        ? const [
                                            Color(0xFFFFE090),
                                            Color(0xFFFF8820),
                                          ]
                                        : const [
                                            Color(0xFFFFA060),
                                            Color(0xFFFF4400),
                                          ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: isActiveIngredient
                                          ? const Color(0xA6FF5000)
                                          : const Color(0x66FFAA00),
                                      blurRadius: isActiveIngredient ? 16 : 8,
                                      spreadRadius: isActiveIngredient ? 4 : 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      if (_isActiveStep)
                        ..._bubbles.map((b) {
                          final local = ((sec - b.delay) % 0.95 + 0.95) % 0.95 / 0.95;
                          final y = -18 * local;
                          final scale = 0.4 + 0.6 * (1 - (local - 0.5).abs() * 2);
                          final opacity = local < 0.05
                              ? 0.0
                              : (1 - local).clamp(0.0, 1.0) * 0.9;
                          return Positioned(
                            left: b.x,
                            top: b.y + y,
                            child: Opacity(
                              opacity: opacity,
                              child: Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xBFFFB950),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 게스트 무료 분석을 모두 쓴 뒤 뜨는 로그인 유도 시트.
/// `true` 를 pop 하면 호출부가 로그인 화면으로 보낸다.
class _GuestParseLoginGateSheet extends StatelessWidget {
  const _GuestParseLoginGateSheet();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFF7A32), Color(0xFFFF6317)],
                ),
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                size: 28,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '무료 분석 1회를 모두 사용했어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: Color(0xFF191F28),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '로그인하면 레시피를 계속 분석하고,\n지금까지 분석한 레시피도 레시피북에 안전하게 보관돼요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13.5,
                height: 1.5,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
                color: Color(0xFF8B95A1),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF191F28),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  '로그인하고 계속하기',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                '다음에 하기',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8B95A1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
