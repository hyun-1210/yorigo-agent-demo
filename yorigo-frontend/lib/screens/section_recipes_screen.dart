// =============================================================================
// SECTION RECIPES SCREEN
// 홈 화면의 각 섹션 헤더 화살표로 들어오는 "섹션 전체 보기" 화면.
// 롱폼(가로) 영상은 16:9, 숏폼(세로) 영상은 9:16 카드로 섞어서 2열 매스너리로 보여준다.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/home_section_keys.dart';
import '../services/analytics_service.dart';
import '../services/home_cms_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../theme/app_colors.dart';
import '../utils/nav_guard.dart';
import '../utils/onboarding_personalization.dart';
import '../utils/recipe_media_aspect.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../widgets/recipe_signal_impression.dart';
import '../widgets/app_network_image.dart';
import '../widgets/recipe_card_social_row.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';

const Color _sectionTextGray = Color(0xFF6A7282);
const Color _sectionBorder = Color(0xFFF3F4F6);
const Color _sectionSkeleton = Color(0xFFEBECF0);

class SectionRecipesScreen extends StatefulWidget {
  const SectionRecipesScreen({
    super.key,
    required this.title,
    this.emoji,
    this.sectionKey,
    this.recipeIds = const <String>[],
    this.initialRecipes = const <Map<String, dynamic>>[],
    this.sourceKeywords = const <String>[],
    this.loadMore,
    this.showTimeBadge = false,
    // 인스타 CDN 만료 시 Storage cropped 우선 (없으면 CDN 폴백).
    this.preferCroppedForInstagram = true,
  });

  final String title;

  /// 제목 옆 이모지 (섹션 헤더와 동일하게).
  final String? emoji;

  /// `home_section_index/{key}` 문서 id. 있으면 화면에서 전체 ID 를 다시 읽어 온다.
  final String? sectionKey;

  /// 인덱스 키가 없는 섹션(셰프·제철)이 미리 넘겨 주는 레시피 ID 목록.
  final List<String> recipeIds;

  /// 홈에서 이미 불러 둔 레시피(첫 화면을 즉시 채우는 용도).
  final List<Map<String, dynamic>> initialRecipes;

  /// 방송 프로그램 등 인덱스 미구축 시 explore 피드 키워드 폴백에 사용.
  final List<String> sourceKeywords;

  /// 인덱스가 없는 섹션(실시간 인기)에서 다음 페이지를 당겨오는 콜백.
  final Future<List<Map<String, dynamic>>> Function()? loadMore;

  final bool showTimeBadge;
  final bool preferCroppedForInstagram;

  @override
  State<SectionRecipesScreen> createState() => _SectionRecipesScreenState();
}

class _SectionRecipesScreenState extends State<SectionRecipesScreen> {
  static const int _initialBatch = 14;
  static const int _appendBatch = 10;
  static const double _gap = 12;
  static const double _horizontalPadding = 20;

  /// 카드 썸네일 아래 제목·작성자 영역의 대략적인 높이. 매스너리 열 배분에만 쓴다.
  static const double _cardMetaHeight = 56;

  final RecipeService _recipeService = RecipeService();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _recipes = <Map<String, dynamic>>[];
  final Set<String> _seenIds = <String>{};
  final List<String> _pendingIds = <String>[];

  bool _bootstrapping = true;
  bool _loading = false;
  bool _exhausted = false;

  /// 일시 네트워크 오류 등. true 면 스크롤/탭으로 재시도 가능하고 영구 exhausted 로 두지 않는다.
  bool _loadFailed = false;

  String get _analyticsSurfaceId => 'section_recipes';

  String? get _originChipSectionKey {
    final key = widget.sectionKey?.trim();
    if (key != null && key.isNotEmpty) return key;
    final fromTitle = HomeSectionKeys.keyForTitle(widget.title).trim();
    return fromTitle.isEmpty ? null : fromTitle;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _addRecipes(widget.initialRecipes);
    unawaited(_bootstrap());
    unawaited(
      AnalyticsService().trackScreen(
        'section_recipes',
        screenClass: 'SectionRecipesScreen',
      ),
    );
    unawaited(
      AnalyticsService().trackHomeSectionImpression(
        sectionId: _analyticsSurfaceId,
        sectionName: widget.title,
        chipSectionKey: _originChipSectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (UserService.peekOnboardingProfile() == null) {
      await UserService().loadOnboardingProfile();
    }
    var ids = List<String>.from(widget.recipeIds);
    final key = widget.sectionKey;
    final isProgramSection =
        (key != null && key.startsWith('program_')) ||
        widget.sourceKeywords.isNotEmpty;

    if (isProgramSection && key != null && key.isNotEmpty) {
      // home_section_index 만 사용. 비어 있으면 빈 목록(explore 스캔 폴백 없음).
      final programRecipes = await _recipeService.getProgramSectionRecipes(
        sectionKey: key,
        limit: 90,
      );
      if (!mounted) return;
      _addRecipes(programRecipes);
      if (_recipes.isNotEmpty) {
        setState(() => _bootstrapping = false);
        return;
      }
    } else if (key != null && key.isNotEmpty) {
      final fetched = await _recipeService.getHomeSectionRecipeIds(
        sectionKey: key,
        limit: 90,
      );
      if (fetched.isNotEmpty) ids = fetched;
    }
    if (!mounted) return;

    _pendingIds
      ..clear()
      ..addAll(ids.where((id) => id.isNotEmpty && !_seenIds.contains(id)));

    final need = _initialBatch - _recipes.length;
    var fillRounds = 0;
    while (need > 0 &&
        _recipes.length < _initialBatch &&
        fillRounds < 3 &&
        !_exhausted) {
      fillRounds += 1;
      final before = _recipes.length;
      await _loadNext(
        count: (_initialBatch - _recipes.length) < _appendBatch
            ? _appendBatch
            : _initialBatch - _recipes.length,
      );
      if (!mounted) return;
      if (_recipes.length == before) break;
    }
    if (!mounted) return;
    setState(() => _bootstrapping = false);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 700) return;
    unawaited(_loadNext());
  }

  /// 중복을 걸러 추가하고, 실제로 늘어난 개수를 돌려준다.
  int _addRecipes(List<Map<String, dynamic>> incoming) {
    var added = 0;
    for (final recipe in incoming) {
      final id = recipe['id']?.toString() ?? '';
      if (id.isEmpty || _seenIds.contains(id)) continue;
      _seenIds.add(id);
      if (recipeHiddenOnHome(recipe, UserService.peekOnboardingProfile())) {
        continue;
      }
      _recipes.add(recipe);
      added++;
    }
    return added;
  }

  Future<void> _loadNext({int count = _appendBatch}) async {
    if (_loading || _exhausted) return;
    _loading = true;
    _loadFailed = false;
    if (mounted && !_bootstrapping) setState(() {});
    // 실패 시 ID 를 되돌리기 위해 이번에 빼 둔 배치를 기억한다.
    List<String>? reservedIds;
    try {
      if (_pendingIds.isNotEmpty) {
        final take = _pendingIds.take(count).toList(growable: false);
        reservedIds = take;
        _pendingIds.removeRange(0, take.length);
        final fetched = await _recipeService.getExploreRecipesByIds(
          take,
          limit: take.length,
        );
        if (!mounted) return;
        _addRecipes(fetched);
        if (_pendingIds.isEmpty && widget.loadMore == null) _exhausted = true;
      } else if (widget.loadMore != null) {
        final more = await widget.loadMore!();
        if (!mounted) return;
        if (_addRecipes(more) == 0) _exhausted = true;
      } else {
        _exhausted = true;
      }
    } catch (_) {
      // 일시 오류는 영구 종료하지 않고, 빼 둔 ID 를 앞에 되돌린다.
      if (reservedIds != null && reservedIds.isNotEmpty) {
        _pendingIds.insertAll(0, reservedIds);
      }
      _loadFailed = true;
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  void _onRecipeTap(Map<String, dynamic> recipe, int index) {
    final recipeId = recipe['id']?.toString() ?? '';
    if (recipeId.isEmpty) return;
    unawaited(
      AnalyticsService().trackHomeRecipeClicked(
        recipeId: recipeId,
        sectionId: _analyticsSurfaceId,
        sectionName: widget.title,
        cardIndex: index,
        chipSectionKey: _originChipSectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
        sourceScreen: 'section_recipes',
      ),
    );
    unawaited(
      AnalyticsService().logRecipeMapEvent(
        'click',
        screen: 'section_recipes',
        recipe: recipe,
        sectionId: _analyticsSurfaceId,
        position: index,
        chipSectionKey: _originChipSectionKey,
      ),
    );
    NavGuard.once(() async {
      final parseResponse = await _recipeService.getRecipeById(recipeId);
      if (parseResponse == null || !mounted) return;
      Navigator.pushNamed(
        context,
        '/recipe-detail',
        arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
      );
    })();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final background = AppColors.getBackground(brightness);

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(brightness),
            Expanded(
              child: _bootstrapping && _recipes.isEmpty
                  ? _buildSkeleton()
                  : _recipes.isEmpty
                  ? _buildEmpty(brightness)
                  : _buildList(brightness),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Brightness brightness) {
    final textPrimary = AppColors.getTextPrimary(brightness);
    return Container(
      height: 54,
      padding: const EdgeInsets.only(left: 6, right: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _sectionBorder, width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            splashRadius: 22,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 19,
              color: textPrimary,
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 17.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                      color: textPrimary,
                    ),
                  ),
                ),
                if (widget.emoji != null && widget.emoji!.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Text(
                    widget.emoji!,
                    style: const TextStyle(fontSize: 15, height: 1.2),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(Brightness brightness) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth =
            (constraints.maxWidth - _horizontalPadding * 2 - _gap) / 2;
        return CustomScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                _horizontalPadding,
                16,
                _horizontalPadding,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: _buildMasonry(brightness, columnWidth),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 20,
                  bottom: 28,
                ),
                child: Center(
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _sectionTextGray,
                          ),
                        )
                      : _loadFailed
                      ? TextButton(
                          onPressed: () => unawaited(_loadNext()),
                          child: const Text(
                            '불러오지 못했어요 · 다시 시도',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: _sectionTextGray,
                            ),
                          ),
                        )
                      : Text(
                          _exhausted ? '레시피를 모두 확인했어요' : '',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: _sectionTextGray,
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 카드 높이가 제각각이라 2열 매스너리로 쌓는다.
  /// 이미지 비율을 미리 알 수 있으니 열 높이를 누적 계산해 짧은 쪽에 붙인다.
  Widget _buildMasonry(Brightness brightness, double columnWidth) {
    final left = <Widget>[];
    final right = <Widget>[];
    var leftHeight = 0.0;
    var rightHeight = 0.0;

    for (var i = 0; i < _recipes.length; i++) {
      final recipe = _recipes[i];
      final aspect = RecipeMediaAspect.aspectRatioOf(recipe);
      final estimated = columnWidth / aspect + _cardMetaHeight;
      final card = Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: RepaintBoundary(
          child: RecipeSignalImpression(
            screen: 'section_recipes',
            sectionId: _analyticsSurfaceId,
            chipSectionKey: _originChipSectionKey,
            position: i,
            recipe: recipe,
            child: _SectionRecipeCard(
              recipe: recipe,
              brightness: brightness,
              width: columnWidth,
              showTimeBadge: widget.showTimeBadge,
              preferCroppedForInstagram: widget.preferCroppedForInstagram,
              onTap: () => _onRecipeTap(recipe, i),
            ),
          ),
        ),
      );
      if (leftHeight <= rightHeight) {
        left.add(card);
        leftHeight += estimated + 18;
      } else {
        right.add(card);
        rightHeight += estimated + 18;
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: left,
          ),
        ),
        const SizedBox(width: _gap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: right,
          ),
        ),
      ],
    );
  }

  Widget _buildSkeleton() {
    const ratios = <double>[9 / 16, 16 / 9, 16 / 9, 9 / 16, 4 / 5, 9 / 16];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth =
            (constraints.maxWidth - _horizontalPadding * 2 - _gap) / 2;
        final left = <Widget>[];
        final right = <Widget>[];
        for (var i = 0; i < ratios.length; i++) {
          final tile = Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: columnWidth,
                  height: columnWidth / ratios[i],
                  decoration: BoxDecoration(
                    color: _sectionSkeleton,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: columnWidth * 0.72,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _sectionSkeleton,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          );
          (i.isEven ? left : right).add(tile);
        }
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            _horizontalPadding,
            16,
            _horizontalPadding,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(children: left)),
              const SizedBox(width: _gap),
              Expanded(child: Column(children: right)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmpty(Brightness brightness) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.restaurant_menu_rounded,
              size: 34,
              color: _sectionTextGray,
            ),
            const SizedBox(height: 12),
            Text(
              '아직 이 섹션에 보여드릴 레시피가 없어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                color: AppColors.getTextTertiary(brightness),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 매스너리 셀 하나. 썸네일 비율만 원본 영상 방향에 따라 달라지고,
/// 나머지 타이포/여백은 홈 캐러셀 카드와 동일하게 맞춘다.
class _SectionRecipeCard extends StatelessWidget {
  const _SectionRecipeCard({
    required this.recipe,
    required this.brightness,
    required this.width,
    required this.onTap,
    this.showTimeBadge = false,
    this.preferCroppedForInstagram = true,
  });

  final Map<String, dynamic> recipe;
  final Brightness brightness;
  final double width;
  final VoidCallback onTap;
  final bool showTimeBadge;
  final bool preferCroppedForInstagram;

  @override
  Widget build(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
    final source = recipe['source'] as Map<String, dynamic>? ?? const {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(
      recipe,
      preferCroppedForInstagram: preferCroppedForInstagram,
    );
    final platform = RecipeMediaAspect.platformOf(recipe);
    final sourceUrl = RecipeMediaAspect.sourceUrlOf(recipe);
    final aspect = RecipeMediaAspect.aspectRatioOf(recipe);
    final isLandscape = RecipeMediaAspect.isLandscape(recipe);

    String creator = '@요리';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    }

    var minutes = 0;
    if (showTimeBadge) {
      final steps = recipeData['steps'] as List? ?? const [];
      for (final step in steps) {
        if (step is Map && step['est_minutes'] != null) {
          minutes += (step['est_minutes'] as num).toInt();
        }
      }
    }

    final height = width / aspect;
    Widget image = AppNetworkImage(
      imageUrl: thumbnailUrl,
      mediaSourceUrl: sourceUrl,
      fit: BoxFit.cover,
      width: width,
      height: height,
      memCacheWidth: AppNetworkImage.carouselThumbMemCacheWidth,
      memCacheHeight: AppNetworkImage.carouselThumbMemCacheHeight,
      brightness: brightness,
      placeholder: const ColoredBox(color: _sectionSkeleton),
      errorWidget: const ColoredBox(color: _sectionSkeleton),
    );
    // 가로 슬롯에는 16:9 썸네일이 그대로 들어맞으므로 확대 보정이 필요 없다.
    if (!isLandscape) {
      image = ThumbnailLetterboxMitigation(
        platform: platform,
        imageUrl: thumbnailUrl,
        sourceUrl: sourceUrl,
        child: image,
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: _sectionBorder,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: thumbnailUrl.isEmpty && sourceUrl.isEmpty
                      ? const ColoredBox(color: _sectionSkeleton)
                      : image,
                ),
                if (showTimeBadge && minutes > 0)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _SectionCardBadge(
                      icon: Icons.schedule_rounded,
                      label: '$minutes분',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              height: 1.35,
              letterSpacing: -0.33,
              color: AppColors.getTextPrimary(brightness),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              _sectionPlatformIcon(platform, 14),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  creator,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.getTextTertiary(brightness),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          RecipeCardSocialRow(
            recipe: recipe,
            color: AppColors.getTextTertiary(brightness),
          ),
        ],
      ),
    );
  }
}

class _SectionCardBadge extends StatelessWidget {
  const _SectionCardBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: _sectionTextGray),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 15 / 10,
              letterSpacing: -0.2,
              color: Color(0xFF4A5565),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _sectionPlatformIcon(String platform, double size) {
  String? assetPath;
  final p = platform.toLowerCase();
  if (p.contains('youtube')) {
    assetPath = 'lib/assets/youtube-app-icon-hd.png';
  } else if (p.contains('instagram')) {
    assetPath = 'lib/assets/instagram-app-icon-hd.png';
  } else if (p.contains('tiktok')) {
    assetPath = 'lib/assets/tiktok-app-icon-hd.png';
  } else if (p.contains('naver')) {
    return SizedBox(
      width: size,
      height: size,
      child: Icon(
        Icons.menu_book_rounded,
        size: size * 0.85,
        color: const Color(0xFF03C75A),
      ),
    );
  }
  if (assetPath == null) {
    return SizedBox(
      width: size,
      height: size,
      child: Icon(
        Icons.video_library,
        size: size * 0.85,
        color: _sectionTextGray,
      ),
    );
  }
  return SizedBox(
    width: size,
    height: size,
    child: Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.video_library, size: size * 0.85, color: _sectionTextGray),
    ),
  );
}
