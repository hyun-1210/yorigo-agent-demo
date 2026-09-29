import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/program_section_keywords.dart';
import '../screens/section_recipes_screen.dart';
import '../services/analytics_service.dart';
import '../services/recipe_service.dart';
import '../services/home_cms_service.dart';
import '../theme/app_colors.dart';
import '../utils/nav_guard.dart';
import '../utils/recipe_media_aspect.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import 'app_network_image.dart';
import 'home_section_chrome.dart';
import 'recipe_card_social_row.dart';
import 'recipe_platform_icon.dart';
import 'recipe_signal_impression.dart';
import 'thumbnail_letterbox_mitigation.dart';

const Color _programBorder = Color(0xFFF3F4F6);
const Color _programSkeleton = Color(0xFFEBECF0);

class ProgramCurationItem {
  const ProgramCurationItem({required this.sectionKey, required this.label});

  final String sectionKey;
  final String label;
}

/// `home_section_index` count > 0 인 프로그램만 남긴다. 입력 순서를 유지한다.
@visibleForTesting
List<ProgramCurationItem> filterProgramsWithIndexCount(
  List<ProgramCurationItem> all,
  Map<String, int> countsByKey,
) {
  return [
    for (final program in all)
      if ((countsByKey[program.sectionKey] ?? 0) > 0) program,
  ];
}

/// 홈 상단 방송 프로그램 큐레이션.
/// 셰프 섹션과 같은 pill 선택 + 가로 캐러셀 패턴.
class ProgramCurationSection extends StatefulWidget {
  const ProgramCurationSection({super.key});

  static const List<ProgramCurationItem> fallbackPrograms = [
    ProgramCurationItem(sectionKey: 'program_pyeonstorang', label: '편스토랑'),
    ProgramCurationItem(sectionKey: 'program_fridge', label: '냉장고를 부탁해'),
    ProgramCurationItem(sectionKey: 'program_best_cooking', label: '최고의 요리비결'),
    ProgramCurationItem(
      sectionKey: 'program_culinary_class_wars',
      label: '흑백요리사',
    ),
    ProgramCurationItem(
      sectionKey: 'program_street_restaurant_fighter',
      label: '스트릿 레스토랑 파이터',
    ),
    ProgramCurationItem(sectionKey: 'program_bake_your_dream', label: '천하제빵'),
    ProgramCurationItem(sectionKey: 'program_altoran', label: '알토란'),
    ProgramCurationItem(
      sectionKey: 'program_sumi_side_dishes',
      label: '수미네 반찬',
    ),
    ProgramCurationItem(sectionKey: 'program_home_food_baek', label: '집밥 백선생'),
    ProgramCurationItem(
      sectionKey: 'program_korean_food_battle',
      label: '한식대첩',
    ),
  ];

  static List<ProgramCurationItem> get programs {
    final cms = HomeCmsService.instance.programsOrFallback;
    if (cms.isEmpty) return fallbackPrograms;
    return [
      for (final s in cms)
        if (s.sectionKey.isNotEmpty)
          ProgramCurationItem(sectionKey: s.sectionKey, label: s.label),
    ];
  }

  @override
  State<ProgramCurationSection> createState() => _ProgramCurationSectionState();
}

class _ProgramCurationSectionState extends State<ProgramCurationSection> {
  static const double _cardWidth = 140;
  static const double _cardImageHeight = 175;
  static const double _cardRadius = 18;
  static const double _cardGap = 12;
  static const int _carouselLimit = 8;

  final RecipeService _recipeService = RecipeService();
  String? _selectedKey;
  List<ProgramCurationItem> _visiblePrograms = const <ProgramCurationItem>[];
  bool _availabilityLoaded = false;
  final Map<String, List<Map<String, dynamic>>> _recipesByKey = {};
  final Set<String> _loadingKeys = <String>{};
  final Set<String> _loadedKeys = <String>{};

  final Set<String> _impressedProgramKeys = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadCmsThenBootstrap());
  }

  Future<void> _loadCmsThenBootstrap() async {
    await HomeCmsService.instance.ensureLoaded();
    if (!mounted) return;
    await _bootstrapVisiblePrograms();
  }

  Future<void> _bootstrapVisiblePrograms() async {
    final counts = <String, int>{};
    await Future.wait(
      ProgramCurationSection.programs.map((program) async {
        final ids = await _recipeService.getHomeSectionRecipeIds(
          sectionKey: program.sectionKey,
          limit: 1,
        );
        counts[program.sectionKey] = ids.isEmpty ? 0 : 1;
      }),
    );
    if (!mounted) return;
    final visible = filterProgramsWithIndexCount(
      ProgramCurationSection.programs,
      counts,
    );
    setState(() {
      _visiblePrograms = visible;
      _availabilityLoaded = true;
      _selectedKey = visible.isEmpty ? null : visible.first.sectionKey;
    });
    final selected = _selectedKey;
    if (selected != null) {
      unawaited(_ensureLoaded(selected));
      _impressProgramChip(
        selected,
        visible.first.label,
        visibleRecipeCount: visible.length,
      );
    }
  }

  Future<void> _ensureLoaded(String sectionKey) async {
    if (_loadedKeys.contains(sectionKey) || _loadingKeys.contains(sectionKey)) {
      return;
    }
    _loadingKeys.add(sectionKey);
    if (mounted) setState(() {});
    try {
      final recipes = await _recipeService.getProgramSectionRecipes(
        sectionKey: sectionKey,
        limit: _carouselLimit,
      );
      if (!mounted) return;
      _recipesByKey[sectionKey] = recipes;
      _loadedKeys.add(sectionKey);
    } catch (_) {
      if (!mounted) return;
      _recipesByKey[sectionKey] ??= const <Map<String, dynamic>>[];
      _loadedKeys.add(sectionKey);
    } finally {
      _loadingKeys.remove(sectionKey);
      if (mounted) setState(() {});
    }
  }

  void _selectProgram(ProgramCurationItem program) {
    if (_selectedKey == program.sectionKey) return;
    setState(() => _selectedKey = program.sectionKey);
    final position = _visiblePrograms.indexWhere(
      (p) => p.sectionKey == program.sectionKey,
    );
    unawaited(
      AnalyticsService().trackHomeProgramChipSelected(
        sectionKey: program.sectionKey,
        label: program.label,
        position: position < 0 ? null : position,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
    _impressProgramChip(program.sectionKey, program.label);
    unawaited(_ensureLoaded(program.sectionKey));
  }

  void _impressProgramChip(
    String sectionKey,
    String label, {
    int? visibleRecipeCount,
  }) {
    if (!_impressedProgramKeys.add(sectionKey)) return;
    unawaited(
      AnalyticsService().trackHomeSectionImpression(
        sectionId: 'program_curation',
        sectionName: label,
        visibleRecipeCount: visibleRecipeCount,
        chipSectionKey: sectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
  }

  void _openSeeAll(ProgramCurationItem program) {
    final initial = _recipesByKey[program.sectionKey] ?? const [];
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SectionRecipesScreen(
          title: program.label,
          emoji: '📺',
          sectionKey: program.sectionKey,
          initialRecipes: initial,
          sourceKeywords: ProgramSectionKeywords.forKey(program.sectionKey),
        ),
      ),
    );
  }

  void _onRecipeTap(Map<String, dynamic> recipe, int index) {
    final recipeId = recipe['id']?.toString() ?? '';
    if (recipeId.isEmpty || _selectedKey == null) return;
    final program = _visiblePrograms.firstWhere(
      (p) => p.sectionKey == _selectedKey,
      orElse: () => _visiblePrograms.first,
    );
    unawaited(
      AnalyticsService().trackHomeRecipeClicked(
        recipeId: recipeId,
        sectionId: 'program_curation',
        sectionName: program.label,
        cardIndex: index,
        chipSectionKey: program.sectionKey,
        cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
      ),
    );
    unawaited(
      AnalyticsService().logRecipeMapEvent(
        'click',
        screen: 'home',
        recipe: recipe,
        sectionId: 'program_curation',
        position: index,
        chipSectionKey: program.sectionKey,
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
    // 인덱스에 레시피가 있는 프로그램이 하나도 없으면 섹션 자체를 숨긴다.
    if (_availabilityLoaded && _visiblePrograms.isEmpty) {
      return const SizedBox.shrink();
    }

    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);
    final selectedKey = _selectedKey;
    final recipes = selectedKey == null
        ? const <Map<String, dynamic>>[]
        : (_recipesByKey[selectedKey] ?? const <Map<String, dynamic>>[]);
    final loading = !_availabilityLoaded ||
        (selectedKey != null && _loadingKeys.contains(selectedKey));
    ProgramCurationItem? selectedProgram;
    if (selectedKey != null) {
      for (final program in _visiblePrograms) {
        if (program.sectionKey == selectedKey) {
          selectedProgram = program;
          break;
        }
      }
      selectedProgram ??=
          _visiblePrograms.isEmpty ? null : _visiblePrograms.first;
    }

    // 셰프 섹션과 동일: 구분선 gap(homeSectionRuleGap) 위·아래 + 공통 전체보기.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  'TV에서 본 그 레시피',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: homeSectionTitleStyle(textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              if (selectedProgram != null)
                homeSectionSeeAllArrow(
                  onTap: () => _openSeeAll(selectedProgram!),
                  semanticLabel: '${selectedProgram.label} 전체보기',
                ),
            ],
          ),
        ),
        const SizedBox(height: homeSectionRuleGap),
        if (!_availabilityLoaded)
          const SizedBox(
            height: 34,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 88,
                  height: 28,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _programSkeleton,
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              itemCount: _visiblePrograms.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final program = _visiblePrograms[i];
                final selected = program.sectionKey == _selectedKey;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _selectProgram(program),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF191F28)
                          : const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      program.label,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.25,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: _cardImageHeight + 68,
          child: loading && recipes.isEmpty
              ? ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: 4,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: _cardGap),
                  itemBuilder: (_, __) => const _ProgramShimmerCard(),
                )
              : ListView.separated(
                  key: ValueKey<String>(selectedKey ?? 'none'),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  addAutomaticKeepAlives: false,
                  cacheExtent: 220,
                  physics: const BouncingScrollPhysics(),
                  itemCount: recipes.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: _cardGap),
                  itemBuilder: (context, index) => RecipeSignalImpression(
                    screen: 'home',
                    sectionId: selectedKey,
                    chipSectionKey: selectedKey,
                    position: index,
                    recipe: recipes[index],
                    child: _ProgramRecipeCard(
                      recipe: recipes[index],
                      brightness: brightness,
                      topLeftLabel: selectedProgram?.label,
                      onTap: () => _onRecipeTap(recipes[index], index),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProgramRecipeCard extends StatelessWidget {
  const _ProgramRecipeCard({
    required this.recipe,
    required this.brightness,
    required this.onTap,
    this.topLeftLabel,
  });

  final Map<String, dynamic> recipe;
  final Brightness brightness;
  final VoidCallback onTap;
  final String? topLeftLabel;

  @override
  Widget build(BuildContext context) {
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? const {};
    final source = recipe['source'] as Map<String, dynamic>? ?? const {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    final platform = RecipeMediaAspect.platformOf(recipe);
    final sourceUrl = RecipeMediaAspect.sourceUrlOf(recipe);

    String creator = '@요리';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    }

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: _ProgramCurationSectionState._cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _ProgramCurationSectionState._cardWidth,
              height: _ProgramCurationSectionState._cardImageHeight,
              decoration: BoxDecoration(
                color: _programBorder,
                borderRadius: BorderRadius.circular(
                  _ProgramCurationSectionState._cardRadius,
                ),
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
                        ? const ColoredBox(color: _programSkeleton)
                        : ThumbnailLetterboxMitigation(
                            platform: platform,
                            imageUrl: thumbnailUrl,
                            sourceUrl: sourceUrl,
                            child: AppNetworkImage(
                              imageUrl: thumbnailUrl,
                              mediaSourceUrl: sourceUrl,
                              fit: BoxFit.cover,
                              width: _ProgramCurationSectionState._cardWidth,
                              height:
                                  _ProgramCurationSectionState._cardImageHeight,
                              memCacheWidth:
                                  AppNetworkImage.carouselThumbMemCacheWidth,
                              memCacheHeight:
                                  AppNetworkImage.carouselThumbMemCacheHeight,
                              brightness: brightness,
                              placeholder: const ColoredBox(
                                color: _programSkeleton,
                              ),
                              errorWidget: const ColoredBox(
                                color: _programSkeleton,
                              ),
                            ),
                          ),
                  ),
                  if (topLeftLabel != null && topLeftLabel!.trim().isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
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
                        child: Text(
                          topLeftLabel!,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            height: 15 / 10,
                            letterSpacing: -0.25,
                            color: Color(0xFF111111),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title.length > 12 ? '${title.substring(0, 12)}…' : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.getTextPrimary(brightness),
                letterSpacing: -0.33,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                if (RecipePlatformIcon.assetPathFor(platform) != null) ...[
                  RecipePlatformIcon(
                    platform: platform,
                    size: 16,
                    fallbackColor: AppColors.getTextTertiary(brightness),
                  ),
                  const SizedBox(width: 4),
                ],
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
      ),
    );
  }
}

class _ProgramShimmerCard extends StatelessWidget {
  const _ProgramShimmerCard();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ProgramCurationSectionState._cardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: _ProgramCurationSectionState._cardWidth,
            height: _ProgramCurationSectionState._cardImageHeight,
            decoration: BoxDecoration(
              color: _programSkeleton,
              borderRadius: BorderRadius.circular(
                _ProgramCurationSectionState._cardRadius,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: 108,
            height: 12,
            decoration: BoxDecoration(
              color: _programSkeleton,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ],
      ),
    );
  }
}
