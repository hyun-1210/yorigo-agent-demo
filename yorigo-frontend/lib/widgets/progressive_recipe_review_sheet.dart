import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../theme/app_colors.dart';
import '../constants/review_experience_options.dart';
import '../services/review_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../services/rewards_service.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/source_creator_utils.dart';
import '../models/recipe_models.dart' as models;
import 'app_network_image.dart';
import 'package:image_picker/image_picker.dart';

/// Opens the progressive "새 탭" review sheet as a true modal (no [Navigator.push]).
Future<bool?> showProgressiveRecipeReviewPopup(
  BuildContext context, {
  required String recipeId,
  required String recipeTitle,
  required String creatorUsername,
  required String platform,
  String? thumbnailUrl,
  required num servings,
  bool fromFridgeCookingComplete = false,
  bool fromCookingFlow = false,
  bool isFreeform = false,
  DateTime? cookedAt,
  void Function(String reviewId)? onReviewCreated,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ProgressiveRecipeReviewSheet(
      recipeId: recipeId,
      recipeTitle: recipeTitle,
      creatorUsername: creatorUsername,
      platform: platform,
      thumbnailUrl: thumbnailUrl,
      servings: servings,
      fromFridgeCookingComplete: fromFridgeCookingComplete,
      fromCookingFlow: fromCookingFlow,
      isFreeform: isFreeform,
      initialCookedAt: cookedAt,
      onReviewCreated: onReviewCreated,
    ),
  );
}

/// Opens the same review sheet in **edit mode**, prefilled from [existingReview].
///
/// Photo editing is intentionally disabled in edit mode (existing photos are
/// preserved as-is). All other fields — rating, comment, difficulty,
/// explanation and benefit labels — can be updated.
Future<bool?> showProgressiveRecipeReviewEditPopup(
  BuildContext context, {
  required String reviewId,
  required Map<String, dynamic> existingReview,
}) {
  final recipeId = (existingReview['recipeId'] as String?) ?? '';
  final recipeTitle = (existingReview['recipeTitle'] as String?) ?? '';
  final creatorUsername = (existingReview['creatorUsername'] as String?) ?? '';
  final platform = (existingReview['platform'] as String?) ?? '';
  final thumbnailUrl = existingReview['thumbnailUrl'] as String?;
  final servings = (existingReview['servings'] as num?)?.toDouble() ?? 1.0;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ProgressiveRecipeReviewSheet(
      recipeId: recipeId,
      recipeTitle: recipeTitle,
      creatorUsername: creatorUsername,
      platform: platform,
      thumbnailUrl: thumbnailUrl,
      servings: servings,
      editReviewId: reviewId,
      existingReview: existingReview,
    ),
  );
}

class ProgressiveRecipeReviewSheet extends StatefulWidget {
  final String recipeId;
  final String recipeTitle;
  final String creatorUsername;
  final String platform;
  final String? thumbnailUrl;
  final num servings;
  /// When true (e.g. from cooking slideshow), pop twice on submit.
  final bool fromCookingFlow;
  /// When true (e.g. from fridge 요리 완료): show "리뷰 안 남기기" above submit in sheet.
  final bool fromFridgeCookingComplete;
  /// When non-null, the sheet runs in **edit mode** and updates the existing
  /// review (instead of creating a new one). Photos are preserved as-is.
  final String? editReviewId;
  /// Existing review document used to prefill fields in edit mode.
  final Map<String, dynamic>? existingReview;
  final bool isFreeform;
  final DateTime? initialCookedAt;
  final void Function(String reviewId)? onReviewCreated;

  const ProgressiveRecipeReviewSheet({
    super.key,
    required this.recipeId,
    required this.recipeTitle,
    required this.creatorUsername,
    required this.platform,
    this.thumbnailUrl,
    required this.servings,
    this.fromCookingFlow = true,
    this.fromFridgeCookingComplete = false,
    this.editReviewId,
    this.existingReview,
    this.isFreeform = false,
    this.initialCookedAt,
    this.onReviewCreated,
  });

  bool get isEditMode => editReviewId != null && editReviewId!.isNotEmpty;
  bool get isFreeformMode => isFreeform || recipeId.trim().isEmpty;

  @override
  State<ProgressiveRecipeReviewSheet> createState() =>
      _ProgressiveRecipeReviewSheetState();
}

class _ProgressiveRecipeReviewSheetState
    extends State<ProgressiveRecipeReviewSheet> {
  final ReviewService _reviewService = ReviewService();
  final RecipeService _recipeService = RecipeService();
  final UserService _userService = UserService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _manualTitleController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  double _selectedRating = 0;
  /// Up to 3 review photos (gallery); shared across tabs.
  final List<XFile> _pickedReviewImages = [];
  /// Edit mode only: photo URLs already saved on the review.
  /// Combined with [_pickedReviewImages] the total must stay <= 3.
  final List<String> _existingPhotoUrls = [];
  bool _isSubmitting = false;
  final Set<String> _selectedBenefits = {};
  int _selectedDifficultyIndex = -1;
  int _selectedExplanationIndex = -1;
  bool _isPrivate = false;
  final ScrollController _progressiveSheetScrollController = ScrollController();
  final GlobalKey _progressiveSubmitAnchorKey = GlobalKey();
  final GlobalKey _progressiveBenefitSectionKey = GlobalKey();
  final GlobalKey _progressiveBenefitGridEndKey = GlobalKey();
  final GlobalKey _progressiveBottomPaddingKey = GlobalKey();
  final GlobalKey _progressiveManualTitleFieldKey = GlobalKey();
  final GlobalKey _progressiveCommentFieldKey = GlobalKey();
  final FocusNode _manualTitleFocusNode = FocusNode();
  final FocusNode _commentFocusNode = FocusNode();

  /// From [RecipeService.getRecipeById] `source['thumbnail']` when [widget.thumbnailUrl] is empty.
  String? _recipeThumbnailFromFetch;
  final List<String> _reviewTags = [];
  int _reviewTotalMinutes = 15;
  double _reviewCalories = 0;
  int _reviewIngredientsCount = 0;
  String _reviewRecipeName = '';
  String _reviewCreatorDisplayName = '';
  String _reviewCreatorHandle = '';
  String _reviewPlatform = '';
  DateTime? _reviewSavedAtDate;
  late DateTime _reviewCookedAtDate;

  /// Same resolution as home recipe cards: passed-in thumbnail, then Firestore/source thumbnail.
  String? get _effectiveRecipeThumbnailUrl {
    final w = widget.thumbnailUrl?.trim();
    if (w != null && w.isNotEmpty) return w;
    final f = _recipeThumbnailFromFetch?.trim();
    if (f != null && f.isNotEmpty) return f;
    return null;
  }
  // User-provided star assets (gray / orange)
  static const String _starEmptyPath = 'assets/icons/review_star_empty.png';
  static const String _starFilledPath = 'assets/icons/review_star_filled.png';

  @override
  void initState() {
    super.initState();
    _selectedRating = 0;
    _selectedDifficultyIndex = -1;
    _selectedExplanationIndex = -1;
    _selectedBenefits.clear();
    _commentController.clear();
    _pickedReviewImages.clear();
    final seeded = widget.initialCookedAt ?? DateTime.now();
    _reviewCookedAtDate = DateTime(seeded.year, seeded.month, seeded.day);
    _reviewRecipeName = widget.recipeTitle;
    _manualTitleController.text = widget.recipeTitle == '나의 요리'
        ? ''
        : widget.recipeTitle;
    _reviewCreatorHandle = widget.creatorUsername;
    _reviewPlatform = widget.platform;

    // Prefill values when opened in edit mode.
    if (widget.isEditMode) {
      final r = widget.existingReview;
      if (r != null) {
        final rating = (r['rating'] as num?)?.toDouble() ?? 0.0;
        _selectedRating = rating.clamp(0, 5);

        final c = (r['comment'] as String?)?.trim();
        if (c != null && c.isNotEmpty) {
          _commentController.text = c;
        }
        _isPrivate = r['isHidden'] == true ||
            (r['visibility'] as String?)?.trim() == 'private';

        final existingTitle = (r['recipeTitle'] as String?)?.trim();
        if (existingTitle != null && existingTitle.isNotEmpty) {
          _manualTitleController.text = existingTitle;
        }

        final difficulty = (r['difficultyLabel'] as String?)?.trim();
        if (difficulty != null && difficulty.isNotEmpty) {
          final idx = ReviewExperienceOptions.difficultyLabels.indexOf(difficulty);
          if (idx >= 0) _selectedDifficultyIndex = idx;
        }

        final explanation = (r['recipeExplanationLabel'] as String?)?.trim();
        if (explanation != null && explanation.isNotEmpty) {
          final idx = ReviewExperienceOptions.explanationLabels.indexOf(explanation);
          if (idx >= 0) _selectedExplanationIndex = idx;
        }

        final benefits = (r['benefits'] as List?) ?? (r['benefitLabels'] as List?);
        if (benefits != null) {
          for (final b in benefits) {
            final s = b?.toString().trim();
            if (s != null && s.isNotEmpty) _selectedBenefits.add(s);
          }
        }

        final rawPhotos = r['photoUrls'];
        if (rawPhotos is List) {
          for (final u in rawPhotos) {
            final s = u?.toString().trim() ?? '';
            if (s.isNotEmpty) _existingPhotoUrls.add(s);
          }
        }
        if (_existingPhotoUrls.isEmpty) {
          final legacy = (r['photoUrl'] as String?)?.trim() ?? '';
          if (legacy.isNotEmpty) _existingPhotoUrls.add(legacy);
        }

        final existingCooked = r['cookedAt'];
        DateTime? cooked;
        if (existingCooked is Timestamp) {
          cooked = existingCooked.toDate();
        } else if (existingCooked is DateTime) {
          cooked = existingCooked;
        } else if (existingCooked is String) {
          cooked = DateTime.tryParse(existingCooked);
        }
        if (cooked != null) {
          _reviewCookedAtDate = DateTime(
            cooked.year,
            cooked.month,
            cooked.day,
          );
        }
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const AssetImage(_starEmptyPath), context);
      precacheImage(const AssetImage(_starFilledPath), context);
    });
    _manualTitleFocusNode.addListener(() {
      if (_manualTitleFocusNode.hasFocus) {
        _scrollFocusedFieldIntoView(_progressiveManualTitleFieldKey);
      }
    });
    _commentFocusNode.addListener(() {
      if (_commentFocusNode.hasFocus) {
        _scrollFocusedFieldIntoView(_progressiveCommentFieldKey);
      }
    });
    _loadReviewHeaderData();
  }

  @override
  void dispose() {
    _commentController.dispose();
    _manualTitleController.dispose();
    _progressiveSheetScrollController.dispose();
    _manualTitleFocusNode.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  void _scrollFocusedFieldIntoView(GlobalKey key) {
    Future<void>.delayed(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      final context = key.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
    });
  }

  Future<void> _loadReviewHeaderData() async {
    if (widget.isFreeformMode) {
      if (!mounted) return;
      setState(() {
        _reviewRecipeName = _manualTitleController.text.trim().isNotEmpty
            ? _manualTitleController.text.trim()
            : '나의 요리';
        _reviewCreatorDisplayName = '직접 기록';
        _reviewCreatorHandle = '';
        _reviewPlatform = 'manual';
        _reviewTotalMinutes = 0;
        _reviewCalories = 0;
        _reviewIngredientsCount = 0;
      });
      return;
    }
    try {
      final parseResponse = await _recipeService.getRecipeById(widget.recipeId);
      if (parseResponse == null || !mounted) return;

      final source = parseResponse.source;
      final fetchedThumb = (source['thumbnail'] as String?)?.trim();
      final recipe = parseResponse.recipe;
      final nutrition = parseResponse.nutrition;

      // Tags (same filtering rules as recipe detail)
      final tags = _getFigmaTags(source);

      // Stats (same calculations as recipe detail)
      int totalMinutes = 0;
      for (final step in recipe.steps) {
        if (step.estMinutes != null) totalMinutes += step.estMinutes!;
      }
      if (totalMinutes == 0) totalMinutes = 15;

      final calories = nutrition.llmEstimate?.caloriesPerServing ?? 0.0;
      final ingredientsCount = recipe.ingredients.length;

      // Creator
      final platform = source['platform'] as String? ?? widget.platform;
      final uploader = source['uploader'] as String? ?? '';
      final channel = source['channel'] as String? ?? '';
      final creatorDisplayName = channel.isNotEmpty
          ? channel
          : (uploader.isNotEmpty ? uploader.replaceFirst(RegExp(r'^@'), '') : 'Chef');
      // 상세 화면과 동일하게 플랫폼별 @핸들 규칙 통일.
      // (YouTube=uploader_id, Instagram/TikTok=uploader) → 채널명/아이디 중복 표시 방지.
      final creatorHandle = resolveCreatorHandle(
        platform: platform,
        uploader: uploader,
        uploaderId: source['uploader_id'] as String?,
        channel: channel,
        fallback: widget.creatorUsername,
      );

      // Saved date from user doc (savedAt map or savedAt.<recipeId>)
      DateTime? savedAtDate;
      final user = _auth.currentUser;
      if (user != null) {
        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        final userData = userDoc.data();
        if (userData != null) {
          final savedAtRaw = userData['savedAt'];
          if (savedAtRaw is Map) {
            final ts = savedAtRaw[widget.recipeId];
            if (ts is Timestamp) savedAtDate = ts.toDate();
          }
          if (savedAtDate == null) {
            for (final entry in userData.entries) {
              if (!entry.key.startsWith('savedAt.')) continue;
              final id = entry.key.substring('savedAt.'.length);
              if (id != widget.recipeId) continue;
              if (entry.value is Timestamp) savedAtDate = (entry.value as Timestamp).toDate();
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _reviewTags
          ..clear()
          ..addAll(tags);
        _reviewTotalMinutes = totalMinutes;
        _reviewCalories = calories;
        _reviewIngredientsCount = ingredientsCount;
        _reviewRecipeName = recipe.name ?? widget.recipeTitle;
        _reviewPlatform = platform;
        _reviewCreatorDisplayName = creatorDisplayName;
        _reviewCreatorHandle = creatorHandle;
        _reviewSavedAtDate = savedAtDate;
        _recipeThumbnailFromFetch =
            (fetchedThumb != null && fetchedThumb.isNotEmpty) ? fetchedThumb : null;
      });
    } catch (_) {
      // Header uses fallbacks from widget.* when fetch fails.
    }
  }

  List<String> _getFigmaTags(Map<String, dynamic> source) {
    return sanitizeRecipeTagList(source['tags'] as List?);
  }

  String _formatMonthDay(DateTime date) {
    // "02.23" format (no year)
    return DateFormat('MM.dd', 'ko').format(date);
  }

  Future<void> _pickCookedAt([
    void Function(VoidCallback fn)? syncSetState,
  ]) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const orange = Color(0xFFFF6900);
    const ink = Color(0xFF191F28);
    const muted = Color(0xFF8B95A1);
    const disabled = Color(0xFFD1D6DB);
    final picked = await showDatePicker(
      context: context,
      locale: const Locale('ko', 'KR'),
      initialDate: _reviewCookedAtDate.isAfter(today)
          ? today
          : _reviewCookedAtDate,
      firstDate: DateTime(today.year - 3),
      lastDate: today,
      currentDate: today,
      helpText: '요리한 날',
      cancelText: '취소',
      confirmText: '선택',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: orange,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: ink,
              onSurfaceVariant: muted,
            ),
            dialogTheme: const DialogThemeData(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
            ),
            datePickerTheme: DatePickerThemeData(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              headerBackgroundColor: Colors.white,
              headerForegroundColor: ink,
              dividerColor: const Color(0xFFF2F4F6),
              headerHelpStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: muted,
                letterSpacing: -0.2,
              ),
              headerHeadlineStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: ink,
                letterSpacing: -0.5,
              ),
              weekdayStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
              dayStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              yearStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              todayBorder: const BorderSide(color: orange, width: 1.4),
              todayForegroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return Colors.white;
                return orange;
              }),
              todayBackgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return orange;
                return Colors.transparent;
              }),
              dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return orange;
                return Colors.transparent;
              }),
              dayForegroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return Colors.white;
                if (states.contains(WidgetState.disabled)) return disabled;
                return ink;
              }),
              cancelButtonStyle: TextButton.styleFrom(
                foregroundColor: muted,
                textStyle: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              confirmButtonStyle: TextButton.styleFrom(
                foregroundColor: orange,
                textStyle: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    void apply() {
      _reviewCookedAtDate = DateTime(picked.year, picked.month, picked.day);
    }
    if (syncSetState != null) {
      syncSetState(apply);
    } else {
      setState(apply);
    }
  }

  String _cookedAtChipLabel() {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final now = DateTime.now();
    final date = _reviewCookedAtDate;
    final datePart =
        '${date.month}월 ${date.day}일 (${weekdays[date.weekday - 1]})';
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final picked = DateTime(date.year, date.month, date.day);
    if (picked == today) return '오늘 · $datePart';
    if (picked == yesterday) return '어제 · $datePart';
    return datePart;
  }

  Widget _buildCookedAtPicker(
    void Function(VoidCallback fn) syncSetState,
  ) {
    return GestureDetector(
      onTap: () => _pickCookedAt(syncSetState),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
        decoration: _freeformCardDecoration,
        child: Row(
          children: [
            const Text(
              '요리한 날',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFF191F28),
                letterSpacing: -0.38,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Icon(
                    Icons.calendar_today_rounded,
                    size: 15,
                    color: Color(0xFFFF6900),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _cookedAtChipLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF6900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: Color(0xFFB0B8C1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.67, vertical: 3.33),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22369600),
        border: Border.all(width: 0.67, color: const Color(0xFFEFF4F1)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          color: Color(0xFF4B5563),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.5,
          letterSpacing: -0.25,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  void _scrollProgressiveSheetToBenefitsQuestion() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _progressiveBenefitSectionKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: 0.0,
      );
    });
  }

  void _scrollProgressiveSheetToBottomPadding() {
    void run() {
      final ctx = _progressiveBottomPaddingKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: 1.0,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      run();
      Future.delayed(const Duration(milliseconds: 120), run);
      Future.delayed(const Duration(milliseconds: 250), run);
    });
  }

  Future<void> _pickReviewImagesFromGallery() async {
    final used = _existingPhotoUrls.length + _pickedReviewImages.length;
    final remaining = 3 - used;
    if (remaining <= 0) return;
    final picked = await _reviewService.pickImagesFromGallery(
      maxCount: remaining,
      webContext: context,
    );
    if (picked.isEmpty) return;
    if (!mounted) return;
    setState(() {
      for (final x in picked) {
        if (_existingPhotoUrls.length + _pickedReviewImages.length >= 3) break;
        _pickedReviewImages.add(x);
      }
    });
  }

  void _finishSubmitAndMaybeCelebrate({
    required String successMessage,
    String? reviewId,
    bool hasPhoto = false,
  }) {
    final overlayContext = Navigator.of(context, rootNavigator: true).context;
    final createdId = reviewId;
    if (createdId != null &&
        createdId.isNotEmpty &&
        !widget.isEditMode) {
      widget.onReviewCreated?.call(createdId);
    }

    Navigator.of(context).pop(true);
    if (!widget.isEditMode &&
        !widget.fromFridgeCookingComplete &&
        widget.fromCookingFlow) {
      Navigator.of(context).pop();
    }

    unawaited(() async {
      if (reviewId != null && reviewId.isNotEmpty) {
        await RewardsService.instance.claimCookingLogged(
          reviewId: reviewId,
          hasPhoto: hasPhoto,
        );
        return;
      }
      if (!overlayContext.mounted) return;
      showAppSnackBar(
        overlayContext,
        SnackBar(
          content: Text(successMessage),
          backgroundColor: Colors.green,
        ),
      );
    }());
  }

  Future<void> _submitReview() async {
    final resolvedRecipeTitle = widget.isFreeformMode
        ? _manualTitleController.text.trim()
        : widget.recipeTitle;
    if (widget.isFreeformMode && resolvedRecipeTitle.isEmpty) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('요리 이름을 입력해주세요'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_selectedRating == 0) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('별점을 선택해주세요'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Edit mode: update existing review with photo add/remove support.
      if (widget.isEditMode) {
        final diffLabels = ReviewExperienceOptions.difficultyLabels;
        final explLabels = ReviewExperienceOptions.explanationLabels;
        final difficultyLabel = _selectedDifficultyIndex >= 0 &&
                _selectedDifficultyIndex < diffLabels.length
            ? diffLabels[_selectedDifficultyIndex]
            : null;
        final recipeExplanationLabel = _selectedExplanationIndex >= 0 &&
                _selectedExplanationIndex < explLabels.length
            ? explLabels[_selectedExplanationIndex]
            : null;
        final benefitLabels = _selectedBenefits.isEmpty
            ? null
            : List<String>.from(_selectedBenefits);

        // Upload any newly picked images. Use a millisecond-based base index
        // so we don't collide with existing storage paths (e.g. *_0, *_1).
        final List<String> newlyUploadedUrls = [];
        final baseIndex = DateTime.now().millisecondsSinceEpoch;
        for (var i = 0; i < _pickedReviewImages.length; i++) {
          final x = _pickedReviewImages[i];
          String? url;
          if (kIsWeb) {
            final bytes = await x.readAsBytes();
            url = await _reviewService.uploadReviewPhoto(
              reviewId: widget.editReviewId!,
              imageIndex: baseIndex + i,
              imageBytes: bytes,
              mimeType: x.mimeType,
              fileNameHint: x.name,
            );
          } else {
            url = await _reviewService.uploadReviewPhoto(
              reviewId: widget.editReviewId!,
              imageIndex: baseIndex + i,
              imageFile: File(x.path),
              mimeType: x.mimeType,
            );
          }
          if (url != null) newlyUploadedUrls.add(url);
        }

        final mergedPhotoUrls = <String>[
          ..._existingPhotoUrls,
          ...newlyUploadedUrls,
        ];

        await _reviewService.updateReview(
          reviewId: widget.editReviewId!,
          rating: _selectedRating.round().clamp(1, 5),
          recipeTitle: widget.isFreeformMode ? resolvedRecipeTitle : null,
          comment: _commentController.text.trim(),
          difficultyLabel: difficultyLabel,
          recipeExplanationLabel: recipeExplanationLabel,
          benefitLabels: benefitLabels,
          photoUrls: mergedPhotoUrls,
          isHidden: _isPrivate,
          cookedAt: _reviewCookedAtDate,
        );

        if (mounted) {
          _finishSubmitAndMaybeCelebrate(
            successMessage: '리뷰가 수정되었습니다',
          );
        }
        return;
      }

      // Generate review ID first (needed for photo upload path)
      final reviewId = _reviewService.generateReviewId();

      final List<String> uploadedUrls = [];
      for (var i = 0; i < _pickedReviewImages.length; i++) {
        final x = _pickedReviewImages[i];
        String? url;
        if (kIsWeb) {
          final bytes = await x.readAsBytes();
          url = await _reviewService.uploadReviewPhoto(
            reviewId: reviewId,
            imageIndex: i,
            imageBytes: bytes,
            mimeType: x.mimeType,
            fileNameHint: x.name,
          );
        } else {
          url = await _reviewService.uploadReviewPhoto(
            reviewId: reviewId,
            imageIndex: i,
            imageFile: File(x.path),
            mimeType: x.mimeType,
          );
        }
        if (url != null) uploadedUrls.add(url);
      }

      final diffLabels = ReviewExperienceOptions.difficultyLabels;
      final explLabels = ReviewExperienceOptions.explanationLabels;
      final difficultyLabel = _selectedDifficultyIndex >= 0 &&
              _selectedDifficultyIndex < diffLabels.length
          ? diffLabels[_selectedDifficultyIndex]
          : null;
      final recipeExplanationLabel = _selectedExplanationIndex >= 0 &&
              _selectedExplanationIndex < explLabels.length
          ? explLabels[_selectedExplanationIndex]
          : null;
      final benefitLabels = _selectedBenefits.isEmpty
          ? null
          : List<String>.from(_selectedBenefits);

      // Submit review
      await _reviewService.submitReview(
        reviewId: reviewId,
        recipeId: widget.isFreeformMode ? null : widget.recipeId,
        rating: _selectedRating.round().clamp(1, 5),
        photoUrls: uploadedUrls.isEmpty ? null : uploadedUrls,
        comment: _commentController.text.trim().isEmpty
            ? null
            : _commentController.text.trim(),
        servings: widget.servings,
        recipeTitle: resolvedRecipeTitle,
        creatorUsername: widget.isFreeformMode ? '' : widget.creatorUsername,
        platform: widget.isFreeformMode ? 'manual' : widget.platform,
        thumbnailUrl: widget.thumbnailUrl,
        difficultyLabel: difficultyLabel,
        recipeExplanationLabel: recipeExplanationLabel,
        benefitLabels: benefitLabels,
        isHidden: _isPrivate,
        reviewSourceType: widget.isFreeformMode ? 'freeform' : 'recipe',
        cookedAt: _reviewCookedAtDate,
      );

      if (mounted) {
        _finishSubmitAndMaybeCelebrate(
          successMessage: '리뷰가 등록되었습니다',
          reviewId: reviewId,
          hasPhoto: uploadedUrls.isNotEmpty,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text(widget.isEditMode
                ? '리뷰 수정 중 오류가 발생했습니다: $e'
                : '리뷰 등록 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  /// From fridge: secondary confirmation when they tap "리뷰 안 남기기". 리뷰 작성하기 = stay; 그냥 넘어가기 = pop.
  Future<void> _showSkipReviewConfirmDialog(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final dialogBrightness = Theme.of(ctx).brightness;
        final greyBg = dialogBrightness == Brightness.dark
            ? const Color(0xFF505050)
            : const Color(0xFFF2F2F2);
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 32),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '멋진 요리를 다른 사람들과 공유해보세요',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: () => Navigator.of(ctx).pop('review'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          '리뷰 작성하기',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: () => Navigator.of(ctx).pop('skip'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: greyBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '그냥 넘어가기',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.getTextSecondary(dialogBrightness),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (choice == 'skip' && context.mounted) {
      Navigator.of(context).pop(true); // Tell fridge to complete 요리 완료
    }
  }

  Widget _buildPlatformIcon(String platform, Brightness brightness) {
    String? assetPath;

    if (platform.toLowerCase() == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (platform.toLowerCase() == 'instagram' ||
        platform.toLowerCase() == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (platform.toLowerCase() == 'tiktok' ||
        platform.toLowerCase() == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
    }

    if (assetPath != null) {
      return Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        clipBehavior: Clip.antiAliasWithSaveLayer,
        child: Image.asset(
          assetPath,
          width: 24,
          height: 24,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: 24,
              height: 24,
              color: AppColors.getBackgroundTertiary(brightness),
              child: Icon(
                Icons.video_library,
                size: 14,
                color: AppColors.getTextTertiary(brightness),
              ),
            );
          },
        ),
      );
    }

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: AppColors.getBackgroundTertiary(brightness),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.video_library,
        size: 14,
        color: AppColors.getTextTertiary(brightness),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (modalCtx, modalSetState) {
        void syncSetState(VoidCallback fn) {
          fn();
          modalSetState(() {});
        }

        return _progressiveSheet(modalCtx, syncSetState);
      },
    );
  }

  /// Unified keyboard-handling pattern (matches the price/recipe error report
  /// sheets): the whole sheet is lifted above the soft keyboard via
  /// [AnimatedPadding], and the inner scroll view dismisses the keyboard only
  /// when the user actively drags. No custom sheet-height animation, no
  /// `MediaQuery.viewInsets` override — Flutter's built-in caret-on-screen
  /// handles scrolling the focused [TextField] into view.
  Widget _progressiveSheet(
    BuildContext mediaContext,
    void Function(VoidCallback fn) syncSetState,
  ) {
    final viewInsetsBottom = MediaQuery.viewInsetsOf(mediaContext).bottom;
    final mediaHeight = MediaQuery.sizeOf(mediaContext).height;
    const sheetRadius = BorderRadius.vertical(top: Radius.circular(28));
    // Cap the visible sheet to ~92% of the area NOT occupied by the keyboard,
    // so the drag handle never gets clipped above the screen top.
    final maxSheetHeight = (mediaHeight - viewInsetsBottom) * 0.92;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: ClipRRect(
            borderRadius: sheetRadius,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: sheetRadius,
              ),
              child: _buildProgressiveReviewBottomSheet(syncSetState),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressiveReviewBottomSheet(
    void Function(VoidCallback fn) popupSetState,
  ) {
    final brightness = Theme.of(context).brightness;
    final hasRating = _selectedRating > 0;
    final hasDifficulty = _selectedDifficultyIndex >= 0;
    final hasExplanation = _selectedExplanationIndex >= 0;
    final hasBenefits = _selectedBenefits.isNotEmpty;

    return SafeArea(
      top: false,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD1D6DB),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 8),
          // Figma 324:2767 — header: back + centered title, bottom hairline (Pretendard)
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(
                  color: Colors.black.withValues(alpha: 0.03),
                  width: 1,
                ),
              ),
            ),
            child: SizedBox(
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: IconButton(
                        onPressed: () {
                          if (widget.fromFridgeCookingComplete) {
                            Navigator.of(context).pop(false);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        icon: const Icon(
                          Icons.arrow_back,
                          size: 24,
                          color: Color(0xFF191F28),
                        ),
                        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      ),
                    ),
                  ),
                  Text(
                    widget.isEditMode
                        ? '기록 수정하기'
                        : widget.isFreeformMode
                            ? '요리 기록하기'
                            : '요리 후기 남기기',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 24 / 16,
                      letterSpacing: -0.4,
                      color: Color(0xFF191F28),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _progressiveSheetScrollController,
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isFreeformMode) ...[
                    _buildVisibilitySection(popupSetState),
                    const SizedBox(height: 14),
                    _buildCookedAtPicker(popupSetState),
                    const SizedBox(height: 14),
                    _buildFreeformTitleSection(),
                  ] else ...[
                    _buildFigmaPopupTopSummarySection(popupSetState),
                    const SizedBox(height: 8),
                    _buildVisibilitySection(popupSetState),
                    const SizedBox(height: 14),
                    _buildCookedAtPicker(popupSetState),
                  ],
                  const SizedBox(height: 24),
                  const Center(
                    child: Text(
                      '직접 만든 요리, 맛은 어떠셨나요?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF191F28),
                        fontSize: 18,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: _buildTouchStarRatingRow(
                      rating: _selectedRating,
                      onChanged: (value) {
                        popupSetState(() {
                          _selectedRating = value;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      _ratingCaption(_selectedRating),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFF7518),
                        fontSize: 15,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.38,
                      ),
                    ),
                  ),
                  if (hasRating) ...[
                    const SizedBox(height: 32),
                    const Text(
                      '체감 난이도는 어땠나요?',
                      style: TextStyle(
                        color: Color(0xFF191F28),
                        fontSize: 15,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.38,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (int i = 0;
                            i < ReviewExperienceOptions.difficultyLabels.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          _choiceButton(
                            selected: _selectedDifficultyIndex == i,
                            label: ReviewExperienceOptions.difficultyLabels[i],
                            selectedColor: const Color(0xFF191F28),
                            unselectedTextColor: const Color(0xFF4E5968),
                            onTap: () => popupSetState(() {
                              _selectedDifficultyIndex = i;
                            }),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (hasDifficulty) ...[
                    const SizedBox(height: 28),
                    const Text(
                      '설명은 따라하기 충분했나요?',
                      style: TextStyle(
                        color: Color(0xFF191F28),
                        fontSize: 15,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.38,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (int i = 0;
                            i < ReviewExperienceOptions.explanationLabels.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          _choiceButton(
                            selected: _selectedExplanationIndex == i,
                            label: ReviewExperienceOptions.explanationLabels[i],
                            selectedColor: const Color(0xFF191F28),
                            unselectedTextColor: const Color(0xFF4E5968),
                            onTap: () => popupSetState(() {
                              _selectedExplanationIndex = i;
                              _scrollProgressiveSheetToBenefitsQuestion();
                            }),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (hasExplanation) ...[
                    const SizedBox(height: 28),
                    Container(
                      key: _progressiveBenefitSectionKey,
                      child: const Text(
                        '어떤 점이 좋았나요?',
                        style: TextStyle(
                          color: Color(0xFF191F28),
                          fontSize: 15,
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                          letterSpacing: -0.38,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Column(
                      children: List.generate(
                        ReviewExperienceOptions.benefitOptions.length ~/ 2,
                        (row) {
                        final opts = ReviewExperienceOptions.benefitOptions;
                        final left = opts[row * 2];
                        final right = opts[row * 2 + 1];
                        final lastRow =
                            row == ReviewExperienceOptions.benefitOptions.length ~/ 2 - 1;
                        return Padding(
                          padding: EdgeInsets.only(bottom: lastRow ? 0 : 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: _benefitGridButton(
                                  label: left,
                                  selected: _selectedBenefits.contains(left),
                                  onTap: () {
                                    popupSetState(() {
                                      if (_selectedBenefits.contains(left)) {
                                        _selectedBenefits.remove(left);
                                      } else {
                                        _selectedBenefits.add(left);
                                      }
                                      _scrollProgressiveSheetToBottomPadding();
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _benefitGridButton(
                                  label: right,
                                  selected: _selectedBenefits.contains(right),
                                  onTap: () {
                                    popupSetState(() {
                                      if (_selectedBenefits.contains(right)) {
                                        _selectedBenefits.remove(right);
                                      } else {
                                        _selectedBenefits.add(right);
                                      }
                                      _scrollProgressiveSheetToBottomPadding();
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                    SizedBox(key: _progressiveBenefitGridEndKey, height: 1),
                  ],
                  if (hasBenefits) ...[
                    const SizedBox(height: 28),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text(
                          '사진 추가',
                          style: TextStyle(
                            color: Color(0xFF191F28),
                            fontSize: 15,
                            fontFamily: 'Pretendard',
                            fontWeight: FontWeight.w700,
                            height: 1.5,
                            letterSpacing: -0.38,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '(최대 3장)',
                          style: TextStyle(
                            color: Color(0xFF8B95A1),
                            fontSize: 12,
                            fontFamily: 'Pretendard',
                            fontWeight: FontWeight.w400,
                            height: 1.5,
                            letterSpacing: -0.38,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _buildFigmaReviewPhotoRow(),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          widget.isFreeformMode ? '요리 메모' : '상세한 후기',
                          style: const TextStyle(
                            color: Color(0xFF191F28),
                            fontSize: 15,
                            fontFamily: 'Pretendard',
                            fontWeight: FontWeight.w700,
                            height: 1.5,
                            letterSpacing: -0.38,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '(선택)',
                          style: TextStyle(
                            color: Color(0xFF8B95A1),
                            fontSize: 12,
                            fontFamily: 'Pretendard',
                            fontWeight: FontWeight.w400,
                            height: 1.5,
                            letterSpacing: -0.38,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildFigmaReviewCommentInput(),
                    const SizedBox(height: 20),
                    if (widget.fromFridgeCookingComplete) ...[
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: _isSubmitting
                              ? null
                              : () => _showSkipReviewConfirmDialog(context),
                          child: Text(
                            '리뷰 안 남기기',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.getTextSecondary(brightness),
                            ),
                          ),
                        ),
                      ),
                    ],
                    Container(
                      key: _progressiveSubmitAnchorKey,
                      child: _buildSubmitButton(brightness),
                    ),
                    SizedBox(key: _progressiveBottomPaddingKey, height: 32),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration get _freeformCardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.05),
        blurRadius: 12,
        offset: const Offset(0, 4),
        spreadRadius: -6,
      ),
    ],
  );

  Widget _buildFreeformTitleSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: _freeformCardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '어떤 요리를 하셨나요?',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF191F28),
              letterSpacing: -0.38,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: _progressiveManualTitleFieldKey,
            controller: _manualTitleController,
            focusNode: _manualTitleFocusNode,
            textInputAction: TextInputAction.done,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
              letterSpacing: -0.3,
            ),
            decoration: InputDecoration(
              hintText: '예: 김치볶음밥, 오늘의 도시락',
              hintStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF9CA3AF),
              ),
              filled: true,
              fillColor: const Color(0xFFF6F7F9),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 15,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVisibilitySection(void Function(VoidCallback fn) popupSetState) {
    final selectedAlignment =
        _isPrivate ? Alignment.centerRight : Alignment.centerLeft;

    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: selectedAlignment,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                      spreadRadius: -2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _visibilitySegment(
                  selected: !_isPrivate,
                  label: '전체 공개',
                  icon: Icons.groups_rounded,
                  onTap: () => popupSetState(() => _isPrivate = false),
                ),
              ),
              Expanded(
                child: _visibilitySegment(
                  selected: _isPrivate,
                  label: '나만 보기',
                  icon: Icons.lock_outline_rounded,
                  onTap: () => popupSetState(() => _isPrivate = true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _visibilitySegment({
    required bool selected,
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final accent = const Color(0xFFFF6B00);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: Icon(
                icon,
                key: ValueKey('$label-$selected'),
                size: 15,
                color: selected ? accent : const Color(0xFF8B95A1),
              ),
            ),
            const SizedBox(width: 6),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? accent : const Color(0xFF6B7280),
                letterSpacing: -0.3,
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFigmaPopupTopSummarySection(
    void Function(VoidCallback fn) popupSetState,
  ) {
    final brightness = Theme.of(context).brightness;
    final recipeName = _reviewRecipeName.isNotEmpty ? _reviewRecipeName : widget.recipeTitle;
    final t0 = _reviewTags.isNotEmpty ? _reviewTags[0] : '매콤한';
    final t1 = _reviewTags.length > 1 ? _reviewTags[1] : '단짠단짠';
    final t2 = _reviewTags.length > 2 ? _reviewTags[2] : '혼밥용';
    final totalMinutes = _reviewTotalMinutes > 0 ? _reviewTotalMinutes : 15;
    final caloriesInt = _reviewCalories.toInt();
    final caloriesText = '${caloriesInt}kcal';
    final ingredientsText = '재료 $_reviewIngredientsCount개';
    final creatorName = _reviewCreatorDisplayName.isNotEmpty ? _reviewCreatorDisplayName : widget.creatorUsername;
    final creatorHandle = _reviewCreatorHandle.isNotEmpty ? _reviewCreatorHandle : widget.creatorUsername;
    final platform = _reviewPlatform.isNotEmpty ? _reviewPlatform : widget.platform;
    final savedDateLabel = _reviewSavedAtDate != null
        ? '${_formatMonthDay(_reviewSavedAtDate!)} 추가'
        : null;
    final cookedLabel = '${_formatMonthDay(_reviewCookedAtDate)} 요리';

    return SizedBox(
      width: double.infinity,
      height: 166,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 122,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 88,
                  height: 122,
                  padding: const EdgeInsets.all(1),
                  clipBehavior: Clip.antiAlias,
                  decoration: ShapeDecoration(
                    color: Colors.white.withValues(alpha: 0),
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        width: 1,
                        color: Colors.black.withValues(alpha: 0.05),
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    shadows: const [
                      BoxShadow(
                        color: Color(0x0F000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                        spreadRadius: -2,
                      )
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: double.infinity,
                      height: 120,
                      child: _effectiveRecipeThumbnailUrl != null
                          ? AppNetworkImage(
                              imageUrl: _effectiveRecipeThumbnailUrl!,
                              width: double.infinity,
                              height: 120,
                              fit: BoxFit.cover,
                              memCacheWidth: AppNetworkImage.listThumbCacheSize,
                              memCacheHeight: AppNetworkImage.listThumbCacheSize,
                              maxWidthDiskCache: 600,
                              maxHeightDiskCache: 600,
                              brightness: brightness,
                              errorWidget: Container(
                                color: const Color(0xFFF2F4F6),
                                child: Icon(
                                  Icons.restaurant,
                                  size: 36,
                                  color: AppColors.getTextTertiary(brightness),
                                ),
                              ),
                            )
                          : Container(
                              color: const Color(0xFFF2F4F6),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.restaurant,
                                size: 36,
                                color: AppColors.getTextTertiary(brightness),
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    height: 122,
                    padding: const EdgeInsets.symmetric(vertical: 4.375),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 249,
                          height: 21.25,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                top: -1,
                                  child: Text(
                                  recipeName,
                                  style: TextStyle(
                                    color: Color(0xFF191F28),
                                    fontSize: 17,
                                    fontFamily: 'Pretendard',
                                    fontWeight: FontWeight.w700,
                                    height: 1.25,
                                    letterSpacing: -0.43,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 249,
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 0,
                            alignment: WrapAlignment.start,
                            children: [
                              _buildTagPill(t0),
                              _buildTagPill(t1),
                              _buildTagPill(t2),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 249,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FittedBox(
                                alignment: Alignment.centerLeft,
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.people_outline,
                                      size: 11,
                                      color: Color(0xFF6B7684),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      models.formatServingsLabel(widget.servings),
                                      style: TextStyle(
                                        color: Color(0xFF6B7684),
                                        fontSize: 12.50,
                                        fontFamily: 'Pretendard',
                                        fontWeight: FontWeight.w500,
                                        height: 1.50,
                                        letterSpacing: -0.31,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      '|',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w400,
                                        height: 15 / 10,
                                        color: Color(0xFFE5E7EB),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.schedule_rounded,
                                      size: 11,
                                      color: Color(0xFF6B7684),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '$totalMinutes분',
                                      style: TextStyle(
                                        color: Color(0xFF6B7684),
                                        fontSize: 12.50,
                                        fontFamily: 'Pretendard',
                                        fontWeight: FontWeight.w500,
                                        height: 1.50,
                                        letterSpacing: -0.31,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      '|',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w400,
                                        height: 15 / 10,
                                        color: Color(0xFFE5E7EB),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.local_fire_department_rounded,
                                      size: 12,
                                      color: Color(0xFFFF6B00),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      caloriesText,
                                      style: const TextStyle(
                                        color: Color(0xFFFF6B00),
                                        fontSize: 12.50,
                                        fontFamily: 'Pretendard',
                                        fontWeight: FontWeight.w700,
                                        height: 1.50,
                                        letterSpacing: -0.31,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.restaurant_outlined,
                                    size: 11,
                                    color: Color(0xFF6B7684),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    ingredientsText,
                                    style: TextStyle(
                                      color: Color(0xFF6B7684),
                                      fontSize: 12.50,
                                      fontFamily: 'Pretendard',
                                      fontWeight: FontWeight.w500,
                                      height: 1.50,
                                      letterSpacing: -0.31,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 28,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPlatformIcon(platform, brightness),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                creatorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: const TextStyle(
                                  color: Color(0xFF191F28),
                                  fontSize: 12.5,
                                  fontFamily: 'Pretendard',
                                  fontWeight: FontWeight.w700,
                                  height: 1.45,
                                  letterSpacing: -0.28,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              flex: 0,
                              fit: FlexFit.loose,
                              child: Text(
                                creatorHandle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: const TextStyle(
                                  color: Color(0xFF8B95A1),
                                  fontSize: 10.5,
                                  fontFamily: 'Pretendard',
                                  fontWeight: FontWeight.w500,
                                  height: 1.45,
                                  letterSpacing: -0.26,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (savedDateLabel != null) ...[
                      Text(
                        savedDateLabel,
                        style: const TextStyle(
                          color: Color(0xFF8B95A1),
                          fontSize: 10,
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w500,
                          height: 15 / 10,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(width: 4),
                      const SizedBox(
                        width: 3,
                        height: 3,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFFD1D6DB),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    GestureDetector(
                      onTap: () => _pickCookedAt(popupSetState),
                      child: Text(
                        cookedLabel,
                        style: const TextStyle(
                          color: Color(0xFFFF7518),
                          fontSize: 10,
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w500,
                          height: 15 / 10,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _choiceButton({
    required bool selected,
    required String label,
    required Color selectedColor,
    required Color unselectedTextColor,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 44,
          decoration: ShapeDecoration(
            color: selected ? selectedColor : const Color(0xFFF2F4F6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            shadows: selected
                ? const [
                    BoxShadow(
                      color: Color(0x4C191F28),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                      spreadRadius: -4,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? Colors.white : unselectedTextColor,
                fontSize: 14,
                fontFamily: 'Pretendard',
                fontWeight: FontWeight.w600,
                height: 1.5,
                letterSpacing: -0.35,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Thumbnails + grey camera add tile (max 3). Uses [mainAxisSize] so it can scroll horizontally on narrow layouts.
  Widget _buildFigmaReviewPhotoRow({MainAxisSize mainAxisSize = MainAxisSize.min}) {
    final totalCount = _existingPhotoUrls.length + _pickedReviewImages.length;
    final List<Widget> children = [];
    for (int i = 0; i < _existingPhotoUrls.length; i++) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      children.add(_figmaExistingPhotoThumb(i));
    }
    for (int i = 0; i < _pickedReviewImages.length; i++) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      children.add(_figmaPickedPhotoThumb(i));
    }
    if (totalCount < 3) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      children.add(_figmaAddPhotoTile());
    }
    return SizedBox(
      height: 80,
      child: Row(
        mainAxisSize: mainAxisSize,
        children: children,
      ),
    );
  }

  Widget _figmaExistingPhotoThumb(int index) {
    final url = _existingPhotoUrls[index];
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 80,
              height: 80,
              color: const Color(0xFFF2F4F6),
              child: AppNetworkImage(
                imageUrl: url,
                width: 80,
                height: 80,
                fit: BoxFit.cover,
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _existingPhotoUrls.removeAt(index);
                });
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Color(0xCC000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _figmaPickedPhotoThumb(int index) {
    final x = _pickedReviewImages[index];
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 80,
              height: 80,
              color: const Color(0xFFF2F4F6),
              child: _reviewImageFromXFile(x),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _pickedReviewImages.removeAt(index);
                });
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Color(0xCC000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _figmaAddPhotoTile() {
    return GestureDetector(
      onTap: _pickReviewImagesFromGallery,
      child: Container(
        width: 80,
        height: 80,
        decoration: ShapeDecoration(
          color: const Color(0xFFF2F4F6),
          shape: RoundedRectangleBorder(
            side: BorderSide(
              width: 1,
              color: Colors.black.withOpacity(0.03),
            ),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.camera_alt_outlined,
              size: 28,
              color: const Color(0xFF8B95A1),
            ),
            const SizedBox(height: 4),
            Text(
              '${_existingPhotoUrls.length + _pickedReviewImages.length}/3',
              style: const TextStyle(
                color: Color(0xFF8B95A1),
                fontSize: 12,
                fontFamily: 'Pretendard',
                fontWeight: FontWeight.w600,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewImageFromXFile(XFile x) {
    if (kIsWeb) {
      return FutureBuilder<Uint8List>(
        future: x.readAsBytes(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            width: 80,
            height: 80,
          );
        },
      );
    }
    return Image.file(
      File(x.path),
      fit: BoxFit.cover,
      width: 80,
      height: 80,
    );
  }

  Widget _benefitGridButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final bg = selected ? const Color(0xFF191F28) : const Color(0xFFF2F4F6);
    final fg = selected ? Colors.white : const Color(0xFF4E5968);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40.25,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          shadows: selected
              ? const [
                  BoxShadow(
                    color: Color(0x4C191F28),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                    spreadRadius: -4,
                  )
                ]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: fg,
            fontSize: 13.5,
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w600,
            height: 1.5,
            letterSpacing: -0.34,
          ),
        ),
      ),
    );
  }

  Widget _buildTouchStarRatingRow({
    double? rating,
    ValueChanged<double>? onChanged,
  }) {
    const starSize = 44.0;
    const gap = 4.0;
    const count = 5;
    const totalWidth = (starSize * count) + (gap * (count - 1));

    void updateFromX(double dx) {
      final clamped = dx.clamp(0.0, totalWidth);
      final rawStars = clamped / (starSize + gap);
      final inStar = (clamped % (starSize + gap)).clamp(0.0, starSize);
      final rawValue = rawStars.floorToDouble() + (inStar / starSize);
      final stepped = (rawValue * 2).round() / 2;
      final bounded = stepped.clamp(0.0, 5.0);
      if (onChanged != null) {
        onChanged(bounded);
      } else {
        setState(() => _selectedRating = bounded);
      }
    }

    return SizedBox(
      width: totalWidth,
      height: starSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => updateFromX(d.localPosition.dx),
        onHorizontalDragStart: (d) => updateFromX(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => updateFromX(d.localPosition.dx),
        onLongPressStart: (d) => updateFromX(d.localPosition.dx),
        onLongPressMoveUpdate: (d) => updateFromX(d.localPosition.dx),
        child: Row(
          children: List.generate(count, (i) {
            final currentRating = rating ?? _selectedRating;
            final fill = (currentRating - i).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(right: i == count - 1 ? 0 : gap),
              child: SizedBox(
                width: starSize,
                height: starSize,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(_starEmptyPath, fit: BoxFit.contain),
                    ),
                    if (fill > 0)
                      Positioned.fill(
                        child: ClipRect(
                          clipper: _LeftFractionClipper(fill),
                          child: Image.asset(
                            _starFilledPath,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  String _ratingCaption(double rating) {
    if (rating <= 0) return '별점을 선택해주세요';
    final halfSteps = (rating * 2).round().clamp(1, 10);
    switch (halfSteps) {
      case 1:
        return '다시 만들진 않을 것 같아요';
      case 2:
        return '개선이 필요해요';
      case 3:
        return '입맛에 안 맞았어요';
      case 4:
        return '기대에 못 미쳤어요';
      case 5:
        return '조금 아쉬웠어요';
      case 6:
        return '먹을 만했어요';
      case 7:
        return '괜찮은 한 끼였어요';
      case 8:
        return '기대 이상이었어요';
      case 9:
        return '주변에 추천하고 싶어요';
      case 10:
        return '또 해먹고 싶어요!';
      default:
        return '별점을 선택해주세요';
    }
  }



  Widget _buildFigmaReviewCommentInput() {
    final hintText = widget.isFreeformMode
        ? '오늘 요리하면서 느낀 점이나 다음에 참고할 팁을 적어보세요.'
        : '다른 유저들을 위해 나만의 요리 팁이나 솔직한 후기를 남겨주세요.';

    return Container(
      key: _progressiveCommentFieldKey,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: const Color(0xFFF2F4F6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      child: TextField(
        controller: _commentController,
        focusNode: _commentFocusNode,
        maxLength: 500,
        maxLines: 6,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(
            color: Color(0xFF8B95A1),
            fontSize: 14,
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w500,
            height: 1.63,
          ),
          border: InputBorder.none,
          counterText: '',
          isCollapsed: true,
        ),
        style: const TextStyle(
          color: Color(0xFF191F28),
          fontSize: 14,
          fontFamily: 'Pretendard',
          fontWeight: FontWeight.w500,
          height: 1.63,
        ),
      ),
    );
  }

  Widget _buildSubmitButton(Brightness brightness) {
    final isEnabled = _selectedRating > 0 && !_isSubmitting;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: isEnabled ? _submitReview : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.getBorderSecondary(brightness),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _isSubmitting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                widget.isEditMode
                    ? '수정 완료'
                    : widget.isFreeformMode
                        ? '요리 기록하기'
                        : '후기 등록하기',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class _LeftFractionClipper extends CustomClipper<Rect> {
  const _LeftFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) {
    final f = fraction.clamp(0.0, 1.0);
    return Rect.fromLTWH(0, 0, size.width * f, size.height);
  }

  @override
  bool shouldReclip(covariant _LeftFractionClipper oldClipper) {
    return oldClipper.fraction != fraction;
  }
}
