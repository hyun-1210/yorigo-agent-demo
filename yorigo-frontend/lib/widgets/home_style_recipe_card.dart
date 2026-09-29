import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/analytics_service.dart';
import '../services/background_parsing_service.dart';
import '../services/recipe_service.dart';
import '../utils/nav_guard.dart';
import '../utils/parse_error_type.dart';
import '../utils/recipe_signal_snapshot.dart';
import '../utils/chef_tag_utils.dart';
import '../utils/recipe_tag_filters.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import 'app_network_image.dart';
import 'parsing_animated_dots.dart';
import 'parsing_card_visuals.dart';
import 'parsing_ring_indicator.dart';

/// [HomeStyleRecipeCard] impression 중복 로깅 방지 — 앱 프로세스 생존 기간 동안 유지.
final Set<String> _homeStyleCardImpressionFired = <String>{};

// Mirrors home_screen.dart saved-recipe card styling.
const Color _orange = Color(0xFFFF6B00);
const Color _textDark = Color(0xFF101828);
const Color _textGray2 = Color(0xFF6A7282);
const Color _placeholder = Color(0xFFD1D5DC);
const Color _border = Color(0xFFF3F4F6);

TextStyle _hsTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w500,
  double? height,
  double? letterSpacing,
  required Color color,
}) => TextStyle(
  fontFamily: 'Pretendard',
  fontSize: fontSize,
  fontWeight: fontWeight,
  height: height ?? 1.50,
  letterSpacing: letterSpacing,
  color: color,
);

/// Same horizontal recipe card as [HomeScreen] saved list (parsing / error / completed).
class HomeStyleRecipeCard {
  HomeStyleRecipeCard._();

  static const double cardHeight = 133.33;
  static const double cardImageWidth = 84;
  static const double cardImageHeight = 108;
  static const double cardPadding = 12.67;

  static String formatRecipeSavedDate(Map<String, dynamic> recipe) {
    final createdAt = recipe['createdAt'];
    if (createdAt == null) return '';
    DateTime date;
    if (createdAt is Timestamp) {
      date = createdAt.toDate();
    } else if (createdAt is String) {
      try {
        date = DateTime.parse(createdAt);
      } catch (_) {
        return '';
      }
    } else {
      return '';
    }
    return '${date.month}.${date.day}일';
  }

  static Widget fromRecipeMap(
    BuildContext context,
    Map<String, dynamic> recipe, {
    required RecipeService recipeService,
    required BackgroundParsingService backgroundParsingService,
    VoidCallback? onAfterRecipeMutation,
    bool hideAddedDateWhenEmpty = true,
    bool forceHideDate = false,
    // 행동 시그널 계측용 — screenName이 null이면 계측을 생략(기존 호출부 영향 없음).
    String? screenName,
    String? sectionId,
    int? position,
  }) {
    final recipeId = recipe['id'] as String? ?? '';
    final status = recipe['status'] as String? ?? 'completed';
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final title =
        recipe['title'] as String? ??
        recipeData['title'] as String? ??
        recipeData['name'] as String? ??
        '레시피';
    final thumbnailUrl = RecipeThumbnailResolver.resolve(recipe);
    final source = recipe['source'] as Map<String, dynamic>? ?? {};
    final sourceUrl =
        recipe['sourceUrl'] as String? ?? (source['url'] as String?) ?? '';
    final addedDate = formatRecipeSavedDate(recipe);
    final showDateRow = !forceHideDate && (!hideAddedDateWhenEmpty || addedDate.isNotEmpty);

    if (status == 'parsing') {
      String? creator;
      final uploaderStr = recipe['uploader']?.toString() ?? source['uploader']?.toString() ?? '';
      final channelStr = recipe['channel']?.toString() ?? source['channel']?.toString() ?? '';
      if (uploaderStr.isNotEmpty) {
        creator = uploaderStr.startsWith('@') ? uploaderStr : '@$uploaderStr';
      } else if (channelStr.isNotEmpty) {
        creator = channelStr.startsWith('@') ? channelStr : '@$channelStr';
      }
      var platform = (source['platform'] as String? ?? '').trim();
      if (platform.isEmpty) {
        platform = RecipeService.inferPlatformFromUrl(sourceUrl);
      }
      final parsingTitle = recipeData['title'] as String? ?? '분석 중..';
      final hasRealTitle = parsingTitle != '분석 중..' && parsingTitle.isNotEmpty;
      return _parsingCard(
        context: context,
        title: parsingTitle,
        hasRealTitle: hasRealTitle,
        platform: platform,
        creator: creator ?? '',
        addedDate: addedDate,
        showDate: showDateRow,
      );
    }

    if (status == 'error') {
      final errorMessage = recipe['error'] as String? ?? '파싱 실패';
      final errorType = resolveDisplayedParseErrorType(
        errorType: recipe['errorType'] as String?,
        errorMessage: recipe['error'] as String?,
      );
      final retryCount = recipe['retryCount'] as int? ?? 0;
      return _recipeErrorCard(
        context: context,
        recipeId: recipeId,
        title: recipeData['title'] as String? ?? title,
        errorMessage: errorMessage,
        errorType: errorType,
        retryCount: retryCount,
        sourceUrl: sourceUrl,
        addedDate: addedDate,
        showDate: showDateRow,
        recipeService: recipeService,
        backgroundParsingService: backgroundParsingService,
        onAfterRecipeMutation: onAfterRecipeMutation,
        thumbnailUrl: thumbnailUrl,
      );
    }

    final ingredients = recipeData['ingredients'] as List? ?? [];
    final steps = recipeData['steps'] as List? ?? [];
    int totalMinutes = 0;
    for (var step in steps) {
      if (step is Map && step['est_minutes'] != null) {
        totalMinutes += (step['est_minutes'] as num).toInt();
      }
    }
    if (totalMinutes == 0) totalMinutes = 15;
    final calories =
        recipe['calories'] as num? ?? recipeData['calories'] as num? ?? 0;
    String creator = '@';
    if (source['uploader']?.toString().isNotEmpty == true) {
      final u = source['uploader'].toString();
      creator = u.startsWith('@') ? u : '@$u';
    } else if (source['channel']?.toString().isNotEmpty == true) {
      final c = source['channel'].toString();
      creator = c.startsWith('@') ? c : '@$c';
    } else if (recipe['chefHandle']?.toString().isNotEmpty == true) {
      final h = recipe['chefHandle'].toString();
      creator = h.startsWith('@') ? h : '@$h';
    } else {
      creator = 'Chef';
    }
    final tagsRaw = recipe['tags'] as List? ?? [];
    final tags = filterRecipeTagsForDisplay(tagsRaw);
    if (tags.isEmpty) tags.add('레시피');
    final platform = source['platform'] as String? ?? '';

    final Widget card = _oneRecipeCard(
      context: context,
      title: title,
      tags: tags,
      ingredientsCount: '${ingredients.length}',
      time: '$totalMinutes',
      kcal: '${calories.toInt()}',
      creator: creator,
      platform: platform,
      addedDate: addedDate,
      showDate: showDateRow,
      imageUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : null,
      mediaSourceUrl: source['url'] as String? ??
          recipe['sourceUrl'] as String?,
      onTap: NavGuard.once(() async {
        if (screenName != null && recipeId.isNotEmpty) {
          AnalyticsService().noteRecipeOpenSource(
            recipeId: recipeId,
            screen: screenName,
            sectionId: sectionId,
          );
          final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
          unawaited(
            AnalyticsService().logCardEvent(
              'click',
              screen: screenName,
              sectionId: sectionId,
              cardId: recipeId,
              contentType: 'recipe',
              recipeId: recipeId,
              position: position,
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
        }
        final parseResponse = await recipeService.getRecipeById(recipeId);
        if (parseResponse != null && context.mounted) {
          Navigator.pushNamed(
            context,
            '/recipe-detail',
            arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
          );
        }
      }),
    );

    if (screenName == null || recipeId.isEmpty) {
      return card;
    }
    final String dedupKey =
        '$screenName::${sectionId ?? 'default'}::$recipeId::${position ?? 0}';
    return VisibilityDetector(
      key: Key('home_style_card_impression_$dedupKey'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (_homeStyleCardImpressionFired.contains(dedupKey)) return;
        _homeStyleCardImpressionFired.add(dedupKey);
        final snapshot = RecipeSignalSnapshot.fromRecipeMap(recipe);
        unawaited(
          AnalyticsService().logCardEvent(
            'impression',
            screen: screenName,
            sectionId: sectionId,
            cardId: recipeId,
            contentType: 'recipe',
            recipeId: recipeId,
            position: position,
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
      },
      child: card,
    );
  }

  /// 토스식 "분석 중" 카드.
  ///  - 왼쪽: 아이콘 없이 깔끔한 배경 위에서 계속 도는 주황 링(진행률 무관).
  ///  - 가운데: 영상 제목을 바로 노출 + 4단계 안내가 순차로 전환(지루하지 않게).
  static Widget _parsingCard({
    required BuildContext context,
    required String title,
    required bool hasRealTitle,
    required String platform,
    required String creator,
    required String addedDate,
    required bool showDate,
  }) {
    final headline = hasRealTitle ? title : '레시피를 불러오고 있어요';
    final showFooter =
        (creator.isNotEmpty || platform.isNotEmpty) || (showDate && addedDate.isNotEmpty);
    return Container(
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 왼쪽 이미지 자리: 아이콘 없이 부드러운 주황 톤 배경 + 도는 링.
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: cardImageWidth,
                height: cardImageHeight,
                decoration: const BoxDecoration(color: Colors.white),
                child: const ParsingSpinnerRing(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    headline,
                    style: _hsTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 19.25 / 14,
                      letterSpacing: -0.35,
                      color: _textDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  const ParsingStageCarousel(),
                  const Spacer(),
                  if (showFooter)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: (creator.isNotEmpty || platform.isNotEmpty)
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _platformIcon(platform),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        creator,
                                        style: _hsTextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          height: 16.5 / 11,
                                          color: _textGray2,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (showDate && addedDate.isNotEmpty)
                          Text(
                            addedDate,
                            style: _hsTextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              height: 15 / 10,
                              color: _placeholder,
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
    );
  }

  static Widget _recipeErrorCard({
    required BuildContext context,
    required String recipeId,
    required String title,
    required String errorMessage,
    required String errorType,
    required int retryCount,
    required String sourceUrl,
    required String addedDate,
    required bool showDate,
    required RecipeService recipeService,
    required BackgroundParsingService backgroundParsingService,
    VoidCallback? onAfterRecipeMutation,
    String? thumbnailUrl,
  }) {
    String cardSubtitle;
    bool showRetry;

    switch (errorType) {
      case 'not_cooking':
        cardSubtitle = '레시피 영상이 아니에요';
        showRetry = false;
        break;
      case 'video_too_long':
        cardSubtitle = '영상이 너무 길어요. 15분 이내 영상만 분석할 수 있어요';
        showRetry = false;
        break;
      case 'insufficient_info':
        cardSubtitle = '레시피 정보가 부족해요';
        showRetry = false;
        break;
      case 'network_error':
        cardSubtitle = '네트워크를 확인한 뒤 다시 시도해 주세요';
        showRetry = true;
        break;
      default:
        if (retryCount >= 2) {
          cardSubtitle = '잠시 후 다시 시도해 주세요';
          showRetry = false;
        } else {
          cardSubtitle = '앗, 레시피를 놓쳤어요';
          showRetry = true;
        }
        break;
    }

    return Container(
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: cardImageWidth,
              height: cardImageHeight,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
                  ? AppNetworkImage(
                      imageUrl: thumbnailUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: AppNetworkImage.listThumbCacheSize,
                      errorWidget: Icon(
                        Icons.error_outline_rounded,
                        color: _textGray2,
                        size: 32,
                      ),
                    )
                  : Icon(
                      Icons.error_outline_rounded,
                      color: _textGray2,
                      size: 32,
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
                    style: _hsTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 19.25 / 14,
                      letterSpacing: -0.35,
                      color: _textDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cardSubtitle,
                    style: _hsTextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6B7280),
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      if (showDate)
                        Text(
                          addedDate,
                          style: _hsTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            height: 15 / 10,
                            color: _placeholder,
                          ),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          await recipeService.deleteRecipe(recipeId);
                          onAfterRecipeMutation?.call();
                        },
                        child: Text(
                          '삭제',
                          style: _hsTextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.red,
                          ),
                        ),
                      ),
                      if (showRetry) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: sourceUrl.isEmpty
                              ? null
                              : () async {
                                  await backgroundParsingService.retryParsing(
                                    recipeId: recipeId,
                                    url: sourceUrl,
                                    preferLang: 'ko',
                                  );
                                  if (!context.mounted) return;
                                  onAfterRecipeMutation?.call();
                                },
                          child: Text(
                            '다시 시도',
                            style: _hsTextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _orange,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _oneRecipeCard({
    required BuildContext context,
    required String title,
    required List<String> tags,
    required String ingredientsCount,
    required String time,
    required String kcal,
    required String creator,
    required String platform,
    required String addedDate,
    required bool showDate,
    String? imageUrl,
    String? mediaSourceUrl,
    VoidCallback? onTap,
    double? progress,
    String? parsingSubtitle,
    String? parsingStage,
    bool showMeta = true,
    bool showTags = true,
    bool showCreator = true,
  }) {
    final isParsing = progress != null;
    final content = Container(
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(width: 0.67, color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C000000),
            blurRadius: 16,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: cardImageWidth,
                height: cardImageHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? AppNetworkImage(
                              imageUrl: imageUrl,
                              mediaSourceUrl: mediaSourceUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              memCacheWidth: AppNetworkImage.listThumbCacheSize,
                              memCacheHeight:
                                  AppNetworkImage.listThumbCacheSize,
                              maxWidthDiskCache: 600,
                              maxHeightDiskCache: 600,
                              placeholder: Container(color: _border),
                              errorWidget: Container(
                                color: _border,
                                child: const Icon(
                                  Icons.restaurant,
                                  color: _textGray2,
                                  size: 32,
                                ),
                              ),
                            )
                          : Container(
                              color: _border,
                              child: const Icon(
                                Icons.restaurant,
                                color: _textGray2,
                                size: 32,
                              ),
                            ),
                    ),
                    if (isParsing) ...[
                      Positioned.fill(
                        child: Container(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                      Positioned.fill(
                        child: Center(
                          child: ParsingRingIndicator(
                            progressPercent: progress,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Text(
                    title,
                    style: _hsTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 19.25 / 14,
                      letterSpacing: -0.35,
                      color: _textDark,
                    ),
                    maxLines: parsingSubtitle != null ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (parsingSubtitle != null) ...[
                    // "분석 중" 을 타이틀 아래로 6px 내리기 (기존 2px + 6px).
                    const SizedBox(height: 8),
                    Text(
                      parsingSubtitle,
                      style: _hsTextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: _textDark,
                      ),
                    ),
                    if (parsingStage != null && parsingStage.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Builder(
                        builder: (_) {
                          final stageStyle = _hsTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                            color: const Color(0xFF9CA3AF),
                          );
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(
                                child: Text(
                                  parsingStage,
                                  style: stageStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ParsingAnimatedDots(style: stageStyle),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  if (showTags && tags.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: tags.take(3).map(_tagOutlined).toList(),
                    ),
                  if (showMeta && ingredientsCount.isNotEmpty) ...[
                    const Spacer(),
                    Row(
                      children: [
                        Text(
                          '재료 $ingredientsCount개',
                          style: _hsTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 16.5 / 11,
                            color: _textGray2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '|',
                          style: _hsTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            height: 15 / 10,
                            color: Color(0xFFE5E7EB),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.schedule_rounded,
                          size: 11,
                          color: _textGray2,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$time분',
                          style: _hsTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 16.5 / 11,
                            color: _textGray2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '|',
                          style: _hsTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            height: 15 / 10,
                            color: Color(0xFFE5E7EB),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: 12,
                          color: _orange,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${kcal}kcal',
                          style: _hsTextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            height: 16.5 / 11,
                            color: _orange,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (isParsing) const Spacer(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child:
                            showCreator &&
                                (creator.isNotEmpty || platform.isNotEmpty)
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _platformIcon(platform),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      creator,
                                      style: _hsTextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        height: 16.5 / 11,
                                        color: _textGray2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (showDate)
                        Text(
                          addedDate,
                          style: _hsTextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            height: 15 / 10,
                            color: _placeholder,
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
    );
    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }
    return content;
  }

  static Widget _platformIcon(String platform) {
    String? assetPath;
    final p = platform.toLowerCase();
    if (p == 'youtube') {
      assetPath = 'lib/assets/youtube-app-icon-hd.png';
    } else if (p == 'instagram' || p == 'instagramweb') {
      assetPath = 'lib/assets/instagram-app-icon-hd.png';
    } else if (p == 'tiktok' || p == 'tiktokweb') {
      assetPath = 'lib/assets/tiktok-app-icon-hd.png';
    }
    const iconSize = 23.0;
    if (assetPath != null) {
      // 원형 배경 / 클리핑 없이 로고만 그대로 보여줌.
      return SizedBox(
        width: iconSize,
        height: iconSize,
        child: Image.asset(
          assetPath,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.video_library, size: 13.5, color: _textGray2),
        ),
      );
    }
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Icon(Icons.video_library, size: 13.5, color: _textGray2),
    );
  }

  static const _chefTagGradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [
      Color(0xFFFFC2D4), Color(0xFFFFD6A5), Color(0xFFFDFFB6), Color(0xFFCAFFBF),
      Color(0xFF9BF6FF), Color(0xFFA0C4FF), Color(0xFFBDB2FF), Color(0xFFFFC2D4),
    ],
  );

  static bool _isChefTag(String tag) => isChefDisplayTag(tag);

  static Widget _tagOutlined(String label) {
    final isChef = _isChefTag(label);
    if (isChef) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.33),
        decoration: BoxDecoration(
          gradient: _chefTagGradient,
          borderRadius: BorderRadius.circular(33554400),
          border: Border.all(width: 0.5, color: const Color(0x80FFFFFF)),
          boxShadow: const [
            BoxShadow(color: Color(0x4DA082FF), blurRadius: 6, offset: Offset(0, 1)),
          ],
        ),
        child: Text(
          label,
          style: _hsTextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            height: 15 / 10,
            letterSpacing: -0.25,
            color: const Color(0xFF111111),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.67, vertical: 3.33),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(width: 0.67, color: const Color(0xFFE5E7EB)),
      ),
      child: Text(
        label,
        style: _hsTextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 15 / 10,
          letterSpacing: -0.25,
          color: _textGray2,
        ),
      ),
    );
  }
}
