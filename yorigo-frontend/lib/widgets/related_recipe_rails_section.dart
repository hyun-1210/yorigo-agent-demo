import 'dart:async';

import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/recipe_service.dart';
import '../theme/app_colors.dart';
import '../utils/nav_guard.dart';
import '../utils/recipe_media_aspect.dart';
import '../utils/recipe_signal_snapshot.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import '../utils/related_recipe_rails.dart';
import 'app_network_image.dart';
import 'home_section_chrome.dart';
import 'recipe_card_social_row.dart';
import 'recipe_platform_icon.dart';
import 'recipe_signal_impression.dart';
import 'thumbnail_letterbox_mitigation.dart';

/// 레시피 상세 하단 연관 레일. 홈 TV/트렌드 카드와 같은 세로 썸네일 톤.
class RelatedRecipeRailsSection extends StatelessWidget {
  const RelatedRecipeRailsSection({
    super.key,
    required this.rails,
    required this.loading,
    required this.recipeService,
  });

  final List<RelatedRecipeRail> rails;
  final bool loading;
  final RecipeService recipeService;

  static const double cardWidth = 140;
  static const double cardImageHeight = 175;
  static const double cardCaptionHeight = 68;
  static const double cardRadius = 18;
  static const double cardGap = 12;
  static const double carouselHeight = cardImageHeight + cardCaptionHeight;
  static const double headerToCards = 16;
  static const Color _border = Color(0xFFF3F4F6);
  static const Color _skeleton = Color(0xFFEBECF0);

  @override
  Widget build(BuildContext context) {
    if (!loading && rails.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (loading && rails.isEmpty)
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
        else
          for (var i = 0; i < rails.length; i++) ...[
            if (i > 0) homeSectionRule(),
            _RelatedRecipeRailBlock(
              rail: rails[i],
              recipeService: recipeService,
            ),
          ],
        if (rails.isNotEmpty) homeSectionRule(),
      ],
    );
  }
}

class _RelatedRecipeRailBlock extends StatelessWidget {
  const _RelatedRecipeRailBlock({
    required this.rail,
    required this.recipeService,
  });

  final RelatedRecipeRail rail;
  final RecipeService recipeService;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            rail.title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111111),
              letterSpacing: -0.4,
              height: 1.25,
            ),
          ),
        ),
        if (rail.subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
              rail.subtitle,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF8B95A1),
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
        const SizedBox(height: RelatedRecipeRailsSection.headerToCards),
        SizedBox(
          height: RelatedRecipeRailsSection.carouselHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            physics: const BouncingScrollPhysics(),
            itemCount: rail.recipes.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: RelatedRecipeRailsSection.cardGap),
            itemBuilder: (context, index) {
              final recipe = rail.recipes[index];
              return RecipeSignalImpression(
                screen: 'recipe_detail',
                recipe: recipe,
                sectionId: rail.id,
                position: index,
                child: _RelatedRecipePortraitCard(
                  recipe: recipe,
                  onTap: _onRecipeTap(context, recipe, index),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  VoidCallback _onRecipeTap(
    BuildContext context,
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
          sectionId: rail.id,
          sectionName: rail.title,
          cardIndex: index,
        ),
      );
      unawaited(
        AnalyticsService().logCardEvent(
          'click',
          screen: 'recipe_detail',
          sectionId: rail.id,
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
      final parseResponse = await recipeService.getRecipeById(recipeId);
      if (parseResponse == null || !context.mounted) return;
      Navigator.pushNamed(
        context,
        '/recipe-detail',
        arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
      );
    });
  }
}

class _RelatedRecipePortraitCard extends StatelessWidget {
  const _RelatedRecipePortraitCard({
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
        width: RelatedRecipeRailsSection.cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: RelatedRecipeRailsSection.cardWidth,
              height: RelatedRecipeRailsSection.cardImageHeight,
              decoration: BoxDecoration(
                color: RelatedRecipeRailsSection._border,
                borderRadius: BorderRadius.circular(
                  RelatedRecipeRailsSection.cardRadius,
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
              child: thumbnailUrl.isEmpty
                  ? const ColoredBox(color: RelatedRecipeRailsSection._skeleton)
                  : ThumbnailLetterboxMitigation(
                      platform: platform,
                      imageUrl: thumbnailUrl,
                      sourceUrl: sourceUrl,
                      child: AppNetworkImage(
                        imageUrl: thumbnailUrl,
                        fit: BoxFit.cover,
                        width: RelatedRecipeRailsSection.cardWidth,
                        height: RelatedRecipeRailsSection.cardImageHeight,
                        memCacheWidth:
                            AppNetworkImage.carouselThumbMemCacheWidth,
                        memCacheHeight:
                            AppNetworkImage.carouselThumbMemCacheHeight,
                        brightness: brightness,
                        placeholder: const ColoredBox(
                          color: RelatedRecipeRailsSection._skeleton,
                        ),
                        errorWidget: const ColoredBox(
                          color: RelatedRecipeRailsSection._skeleton,
                        ),
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
            const SizedBox(height: 3),
            RecipeCardSocialRow(recipe: recipe, color: textTertiary),
          ],
        ),
      ),
    );
  }
}
