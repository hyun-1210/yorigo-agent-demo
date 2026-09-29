import 'dart:async';

import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/recipe_service.dart';
import '../theme/app_colors.dart';
import '../utils/nav_guard.dart';
import '../utils/recipe_media_aspect.dart';
import '../utils/recipe_pairing.dart';
import '../utils/recipe_signal_snapshot.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/related_recipe_rails.dart';
import 'app_network_image.dart';
import 'home_section_chrome.dart';
import 'recipe_card_social_row.dart';
import 'recipe_platform_icon.dart';
import 'recipe_signal_impression.dart';
import 'thumbnail_letterbox_mitigation.dart';

class RecipePairingSection extends StatefulWidget {
  const RecipePairingSection({
    super.key,
    required this.lanes,
    required this.loading,
    required this.recipeService,
  });

  final List<LoadedPairingLane> lanes;
  final bool loading;
  final RecipeService recipeService;

  @override
  State<RecipePairingSection> createState() => _RecipePairingSectionState();
}

class _RecipePairingSectionState extends State<RecipePairingSection> {
  String? _selectedId;

  LoadedPairingLane? get _selected {
    final lanes = widget.lanes;
    if (lanes.isEmpty) return null;
    final id = _selectedId;
    if (id != null) {
      for (final lane in lanes) {
        if (lane.id == id) return lane;
      }
    }
    return lanes.first;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loading && widget.lanes.isEmpty) {
      return const SizedBox.shrink();
    }

    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            '함께 곁들이면 좋은',
            style: homeSectionTitleStyle(const Color(0xFF111111)),
          ),
        ),
        if (widget.loading && widget.lanes.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (selected != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              itemCount: widget.lanes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final lane = widget.lanes[index];
                final on = lane.id == selected.id;
                return _PairingChip(
                  id: lane.id,
                  label: lane.label,
                  selected: on,
                  onTap: () {
                    if (lane.id == _selectedId ||
                        (_selectedId == null &&
                            lane.id == widget.lanes.first.id)) {
                      return;
                    }
                    setState(() => _selectedId = lane.id);
                    unawaited(
                      AnalyticsService().trackPairingChipSelected(
                        laneId: lane.id,
                        label: lane.label,
                        position: index,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          if (selected.recipes.isNotEmpty)
            SizedBox(
              height: _carouselHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16, right: 16),
                physics: const BouncingScrollPhysics(),
                clipBehavior: Clip.hardEdge,
                itemCount: selected.recipes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final recipe = selected.recipes[index];
                  return RecipeSignalImpression(
                    screen: 'recipe_detail',
                    recipe: recipe,
                    sectionId: 'pairing_${selected.id}',
                    position: index,
                    child: _PairingRecipeCard(
                      recipe: recipe,
                      onTap: _onRecipeTap(context, selected, recipe, index),
                    ),
                  );
                },
              ),
            )
          else
            SizedBox(
              height: _sipCardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16, right: 16),
                physics: const BouncingScrollPhysics(),
                clipBehavior: Clip.hardEdge,
                itemCount: selected.sips.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  return _PairingSipCard(sip: selected.sips[index]);
                },
              ),
            ),
        ],
        homeSectionRule(),
      ],
    );
  }

  VoidCallback _onRecipeTap(
    BuildContext context,
    LoadedPairingLane lane,
    Map<String, dynamic> recipe,
    int index,
  ) {
    return NavGuard.once(() async {
      final recipeId = recipeIdOf(recipe);
      if (recipeId.isEmpty) return;
      final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
      unawaited(
        AnalyticsService().trackRelatedRecipeClicked(
          recipeId: recipeId,
          sectionId: 'pairing_${lane.id}',
          sectionName: lane.label,
          cardIndex: index,
        ),
      );
      unawaited(
        AnalyticsService().logCardEvent(
          'click',
          screen: 'recipe_detail',
          sectionId: 'pairing_${lane.id}',
          cardId: recipeId,
          contentType: 'recipe',
          recipeId: recipeId,
          position: index,
          recipeCuisineType: snapshot.cuisineType,
          recipeTimeCategory: snapshot.timeCategory,
          recipeMenuType: snapshot.menuType,
          recipeMainIngredient: snapshot.mainIngredient,
          recipeMainIngredientSub: snapshot.mainIngredientSub,
          recipeTags: snapshot.tags,
          recipeNutritionRating: snapshot.nutritionRating,
          recipeIngredientCategories: snapshot.ingredientCategories,
          recipeSourcePlatform: snapshot.sourcePlatform,
          recipeServings: snapshot.servings,
        ),
      );
      final parseResponse = await widget.recipeService.getRecipeById(recipeId);
      if (parseResponse == null || !context.mounted) return;
      Navigator.pushNamed(
        context,
        '/recipe-detail',
        arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
      );
    });
  }
}

class _PairingChip extends StatelessWidget {
  const _PairingChip({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon {
    switch (id) {
      case 'side':
        return Icons.set_meal_outlined;
      case 'drink':
        return Icons.local_cafe_outlined;
      case 'alcohol':
        return Icons.wine_bar_outlined;
      case 'dessert':
        return Icons.icecream_outlined;
      case 'anju':
        return Icons.ramen_dining_outlined;
      default:
        return Icons.restaurant_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1A1A1A);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(11, 0, 13, 0),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 16, color: ink),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ink,
                letterSpacing: -0.2,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const double _cardWidth = 120;
const double _cardImageHeight = 150;
const double _cardCaptionHeight = 68;
const double _cardRadius = 16;
const double _carouselHeight = _cardImageHeight + _cardCaptionHeight;
const double _sipCardWidth = 92;
const double _sipCardHeight = 108;

class _PairingRecipeCard extends StatelessWidget {
  const _PairingRecipeCard({
    required this.recipe,
    required this.onTap,
  });

  final Map<String, dynamic> recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
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
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

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
        width: _cardWidth,
        height: _carouselHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: _cardWidth,
              height: _cardImageHeight,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(_cardRadius),
              ),
              clipBehavior: Clip.antiAlias,
              child: thumbnailUrl.isEmpty
                  ? const ColoredBox(color: Color(0xFFEBECF0))
                  : ThumbnailLetterboxMitigation(
                      platform: platform,
                      imageUrl: thumbnailUrl,
                      sourceUrl: sourceUrl,
                      child: AppNetworkImage(
                        imageUrl: thumbnailUrl,
                        fit: BoxFit.cover,
                        width: _cardWidth,
                        height: _cardImageHeight,
                        memCacheWidth: AppNetworkImage.carouselThumbMemCacheWidth,
                        memCacheHeight:
                            AppNetworkImage.carouselThumbMemCacheHeight,
                        brightness: brightness,
                        placeholder: const ColoredBox(color: Color(0xFFEBECF0)),
                        errorWidget: const ColoredBox(color: Color(0xFFEBECF0)),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: textPrimary,
                letterSpacing: -0.33,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                if (RecipePlatformIcon.assetPathFor(platform) != null) ...[
                  RecipePlatformIcon(
                    platform: platform,
                    size: 16,
                    fallbackColor: textTertiary,
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
                      color: textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            RecipeCardSocialRow(recipe: recipe, color: textTertiary),
          ],
        ),
      ),
    );
  }
}

class _PairingSipCard extends StatelessWidget {
  const _PairingSipCard({required this.sip});

  final PairingSip sip;

  @override
  Widget build(BuildContext context) {
    final visual = _sipVisual(sip.icon);
    return SizedBox(
      width: _sipCardWidth,
      height: _sipCardHeight,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
        decoration: BoxDecoration(
          color: visual.tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: visual.tint.withValues(alpha: 0.18),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(visual.icon, size: 20, color: visual.tint),
            ),
            const SizedBox(height: 8),
            Text(
              sip.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F2937),
                letterSpacing: -0.2,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

({IconData icon, Color tint}) _sipVisual(String key) {
  switch (key) {
    case 'beer':
      return (icon: Icons.sports_bar_rounded, tint: const Color(0xFFD97706));
    case 'soju':
      return (icon: Icons.liquor_rounded, tint: const Color(0xFF4D7C5A));
    case 'wine':
      return (icon: Icons.wine_bar_rounded, tint: const Color(0xFF9F1239));
    case 'makgeolli':
      return (icon: Icons.sports_bar_outlined, tint: const Color(0xFFB45309));
    case 'highball':
      return (icon: Icons.local_bar_rounded, tint: const Color(0xFF0284C7));
    case 'sake':
      return (icon: Icons.local_drink_rounded, tint: const Color(0xFF57534E));
    case 'coffee':
      return (icon: Icons.coffee_rounded, tint: const Color(0xFF92400E));
    case 'tea':
      return (icon: Icons.emoji_food_beverage_rounded, tint: const Color(0xFFB45309));
    case 'cola':
      return (icon: Icons.local_cafe_rounded, tint: const Color(0xFF1F2937));
    case 'cider':
      return (icon: Icons.bubble_chart_rounded, tint: const Color(0xFF0E7490));
    case 'barley':
      return (icon: Icons.eco_rounded, tint: const Color(0xFFA16207));
    case 'milk':
      return (icon: Icons.water_drop_rounded, tint: const Color(0xFF78716C));
    default:
      return (icon: Icons.local_drink_outlined, tint: const Color(0xFF6B7280));
  }
}
