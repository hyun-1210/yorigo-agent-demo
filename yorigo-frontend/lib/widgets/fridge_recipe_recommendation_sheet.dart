import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/ingredient_recipe_recommendation_service.dart';
import '../services/background_parsing_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../utils/ingredient_category_unifier.dart';
import '../utils/haptics.dart';
import 'app_toast.dart';
import 'home_style_recipe_card.dart';
import 'ios_liquid_glass_tab_bar.dart';
import 'recipe_bookmark_glyph.dart';

/// 추천 입력용 재료 모델 (냉장고 보관 재료에서 변환).
class RecommendableIngredient {
  const RecommendableIngredient({
    required this.name,
    this.amountLeft,
    this.unit,
  });

  final String name;
  final double? amountLeft;
  final String? unit;
}

/// 냉장고 보관 재료 기반 레시피 추천 시트를 띄웁니다.
Future<void> showFridgeRecipeRecommendationSheet(
  BuildContext context, {
  required List<RecommendableIngredient> ingredients,
  required void Function(String recipeId) onOpenRecipe,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.38),
    builder: (_) => FridgeRecipeRecommendationSheet(
      ingredients: ingredients,
      onOpenRecipe: onOpenRecipe,
    ),
  );
}

class FridgeRecipeRecommendationSheet extends StatefulWidget {
  const FridgeRecipeRecommendationSheet({
    super.key,
    required this.ingredients,
    required this.onOpenRecipe,
  });

  final List<RecommendableIngredient> ingredients;
  final void Function(String recipeId) onOpenRecipe;

  @override
  State<FridgeRecipeRecommendationSheet> createState() =>
      _FridgeRecipeRecommendationSheetState();
}

enum _Stage { select, loading, results, empty, error }

/// 시트를 닫았다가 다시 열어도 한동안 추천 결과가 남아있도록 하는 모듈 캐시.
class _CachedRecommendation {
  _CachedRecommendation({
    required this.selectedNames,
    required this.results,
    required this.savedAt,
  });

  final Set<String> selectedNames;
  final List<_RecResult> results;
  final DateTime savedAt;
}

_CachedRecommendation? _lastRecommendationCache;
const Duration _recommendationCacheTtl = Duration(minutes: 10);

class _FridgeRecipeRecommendationSheetState
    extends State<FridgeRecipeRecommendationSheet> {
  static const Color _brand = Color(0xFFFF6422);
  static const Color _ink = Color(0xFF191F28);
  static const Color _sub = Color(0xFF8B95A1);

  _Stage _stage = _Stage.select;
  final Set<int> _selected = {};
  List<_RecResult> _results = const [];
  String _errorMessage = '';
  List<String> _spinNames = const [];
  final ScrollController _scrollController = ScrollController();

  final RecipeService _recipeService = RecipeService();
  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();
  final IngredientRecipeRecommendationService _recommendationService =
      IngredientRecipeRecommendationService();
  final UserService _userService = UserService();

  final Set<String> _bookmarkedIds = {};
  final Set<String> _bookmarkInFlight = {};

  @override
  void initState() {
    super.initState();
    // 최근(10분 이내) 추천 결과가 있으면 복원해, 닫았다 다시 열어도 유지한다.
    final cache = _lastRecommendationCache;
    if (cache != null &&
        cache.results.isNotEmpty &&
        DateTime.now().difference(cache.savedAt) < _recommendationCacheTtl) {
      for (var i = 0; i < widget.ingredients.length; i++) {
        if (cache.selectedNames.contains(widget.ingredients[i].name)) {
          _selected.add(i);
        }
      }
      _results = cache.results;
      _stage = _Stage.results;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshBookmarkStatuses();
      });
    }
    // 그 외 기본값: 아무것도 선택하지 않음 — 유저가 직접 고른다.
  }

  Future<void> _refreshBookmarkStatuses() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _results.isEmpty) return;
    try {
      final saved = await _userService.getSavedRecipes(user.uid);
      if (!mounted) return;
      setState(() {
        for (final result in _results) {
          final id = result.recipeId;
          if (id.isEmpty) continue;
          if (saved.contains(id)) {
            _bookmarkedIds.add(id);
          } else {
            _bookmarkedIds.remove(id);
          }
        }
      });
    } catch (_) {
      // 북마크 상태 조회 실패는 UI에 치명적이지 않으므로 silent fail.
    }
  }

  Future<void> _toggleBookmark(String recipeId) async {
    if (recipeId.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      AppToast.error(context, '북마크하려면 로그인이 필요합니다');
      return;
    }
    if (_bookmarkInFlight.contains(recipeId)) return;

    final wasBookmarked = _bookmarkedIds.contains(recipeId);
    setState(() {
      _bookmarkInFlight.add(recipeId);
      if (wasBookmarked) {
        _bookmarkedIds.remove(recipeId);
      } else {
        _bookmarkedIds.add(recipeId);
      }
    });

    if (wasBookmarked) {
      AppToast.success(context, '북마크에서 제거되었습니다');
    } else {
      AppToast.success(context, '북마크에 추가되었습니다');
    }

    try {
      if (wasBookmarked) {
        await _userService.removeSavedRecipe(user.uid, recipeId);
      } else {
        await _userService.addSavedRecipe(user.uid, recipeId);
      }
      RecipeService.notifyRecipesChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasBookmarked) {
          _bookmarkedIds.add(recipeId);
        } else {
          _bookmarkedIds.remove(recipeId);
        }
      });
      AppToast.error(context, '북마크 처리 중 오류가 발생했어요');
    } finally {
      if (mounted) {
        setState(() => _bookmarkInFlight.remove(recipeId));
      }
    }
  }

  /// 결과 화면에서 "다시 추천받기" 탭 시 확인 팝업 → 재료 선택 화면으로.
  Future<void> _confirmRestart() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 26, 24, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '다시 추천받을까요?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                          color: _ink,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '지금 추천 결과는 사라지고\n재료를 다시 골라 추천받아요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          height: 1.45,
                          letterSpacing: -0.2,
                          color: _sub,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(ctx).pop(false),
                          child: Container(
                            height: 50,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF2F4F6),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Text(
                              '취소',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                                color: Color(0xFF4E5968),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(ctx).pop(true),
                          child: Container(
                            height: 50,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _brand,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Text(
                              '다시 선택',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.2,
                                color: Colors.white,
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
          ),
        );
      },
    );
    if (ok == true && mounted) {
      // 사용자가 직접 다시 추천을 원하므로 캐시도 비운다.
      _lastRecommendationCache = null;
      setState(() {
        _results = const [];
        _selected.clear();
        _stage = _Stage.select;
      });
    }
  }

  Future<void> _runRecommendation() async {
    final picked = <RecommendableIngredient>[
      for (var i = 0; i < widget.ingredients.length; i++)
        if (_selected.contains(i)) widget.ingredients[i],
    ];
    if (picked.isEmpty) return;

    Haptics.medium();
    unawaited(
      AnalyticsService().trackFridgeRecommendationRun(
        ingredientNames: [for (final ing in picked) ing.name],
      ),
    );
    setState(() {
      _spinNames = [for (final ing in picked) ing.name];
      _stage = _Stage.loading;
    });

    // 추첨 드럼이 충분히 돌도록 최소 스핀 시간을 보장한다.
    final spinFloor = Future<void>.delayed(const Duration(milliseconds: 2400));

    try {
      final raw = await _recommendationService.recommend(
        ingredientNames: [for (final ing in picked) ing.name],
        topK: 12,
      );
      final parsed = raw.map(_RecResult.fromLocal).toList();
      await spinFloor;
      if (!mounted) return;
      // 결과를 모듈 캐시에 저장 — 시트를 닫았다 다시 열어도 잠시 유지.
      if (parsed.isNotEmpty) {
        _lastRecommendationCache = _CachedRecommendation(
          selectedNames: {for (final ing in picked) ing.name},
          results: parsed,
          savedAt: DateTime.now(),
        );
      }
      setState(() {
        _results = parsed;
        _stage = parsed.isEmpty ? _Stage.empty : _Stage.results;
      });
      if (parsed.isNotEmpty) {
        _refreshBookmarkStatuses();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _recommendErrorMessage(e);
        _stage = _Stage.error;
      });
    }
  }

  String _recommendErrorMessage(Object error) {
    if (error is IngredientRecipeRecommendationTimeoutException) {
      return error.toString();
    }
    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return '추천 데이터에 접근할 수 없어요. 앱을 업데이트한 뒤 다시 시도해주세요.';
        case 'unavailable':
        case 'deadline-exceeded':
          return '네트워크가 불안정해요. 잠시 후 다시 시도해주세요.';
        default:
          break;
      }
    }
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    if (raw.isEmpty) {
      return '잠시 후 다시 시도해주세요.';
    }
    return raw;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 단계(선택/로딩/결과/빈/에러)와 무관하게 항상 같은 높이로 떠 있도록 고정한다.
    final screenH = MediaQuery.of(context).size.height;
    final sheetHeight = (screenH * 0.9).clamp(480.0, screenH);
    return Container(
      height: sheetHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildGrabber(),
          _buildHeader(),
          Expanded(child: _buildBody(_scrollController)),
        ],
      ),
    );
  }

  Widget _buildGrabber() {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFD1D6DD),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 16, 14),
      child: Row(
        children: [
          Image.asset(
            'assets/images/fridge_recommend_3d.png',
            width: 44,
            height: 44,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '냉장고 요리 추천',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                    letterSpacing: -0.4,
                    color: _ink,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '고른 재료로 만들 수 있는 요리를 찾아드려요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    letterSpacing: -0.2,
                    color: _sub,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF1F4),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 18,
                color: Color(0xFF4E5968),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ScrollController controller) {
    switch (_stage) {
      case _Stage.select:
        return _buildSelectStage(controller);
      case _Stage.loading:
        return _buildLoadingStage(controller);
      case _Stage.results:
        return _buildResultsStage(controller);
      case _Stage.empty:
        return _buildEmptyStage(controller);
      case _Stage.error:
        return _buildErrorStage(controller);
    }
  }

  // ---------------------------------------------------------------------------
  // Stage: select ingredients
  // ---------------------------------------------------------------------------
  Widget _buildSelectStage(ScrollController controller) {
    final selectedCount = _selected.length;
    final allSelected = selectedCount == widget.ingredients.length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: [
              Row(
                children: [
                  const Text(
                    '사용할 재료',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$selectedCount',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      color: _brand,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Haptics.light();
                      setState(() {
                        if (allSelected) {
                          _selected.clear();
                        } else {
                          for (
                            var i = 0;
                            i < widget.ingredients.length;
                            i++
                          ) {
                            _selected.add(i);
                          }
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            allSelected
                                ? Icons.remove_done_rounded
                                : Icons.done_all_rounded,
                            size: 16,
                            color: _brand,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            allSelected ? '전체 해제' : '전체 선택',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                              color: _brand,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                selectedCount == 0
                    ? '만들 요리에 쓸 재료를 골라주세요'
                    : '선택한 재료로 만들 수 있는 요리를 찾아드려요',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                  color: _sub,
                ),
              ),
              const SizedBox(height: 16),
              ..._buildCategorizedIngredientSections(),
            ],
          ),
        ),
        _buildCtaBar(
          label: selectedCount == 0
              ? '재료를 선택해주세요'
              : '$selectedCount개 재료로 레시피 추천',
          enabled: selectedCount > 0,
          onTap: _runRecommendation,
        ),
      ],
    );
  }

  /// 재료를 카테고리별(헤더 + 2열 칩)로 묶어 반환한다. 냉장고 화면과 동일한 직관.
  List<Widget> _buildCategorizedIngredientSections() {
    final byCategory = <String, List<int>>{};
    for (var i = 0; i < widget.ingredients.length; i++) {
      final key = IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: null,
        ingredientName: widget.ingredients[i].name,
      );
      byCategory.putIfAbsent(key, () => []).add(i);
    }

    // groupOrder 순서 우선, 그 외 카테고리는 뒤에 붙인다.
    final orderedKeys = <String>[
      ...IngredientCategoryUnifier.groupOrder.where(byCategory.containsKey),
      ...byCategory.keys.where(
        (k) => !IngredientCategoryUnifier.groupOrder.contains(k),
      ),
    ];

    final widgets = <Widget>[];
    for (final key in orderedKeys) {
      final indices = byCategory[key]!;
      if (indices.isEmpty) continue;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 16));
      widgets.add(_categorySectionHeader(key, indices.length));
      widgets.add(const SizedBox(height: 10));
      widgets.add(
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final itemWidth = (constraints.maxWidth - spacing) / 2;
            return Wrap(
              spacing: spacing,
              runSpacing: 8,
              children: [
                for (final i in indices)
                  SizedBox(width: itemWidth, child: _buildIngredientChip(i)),
              ],
            );
          },
        ),
      );
    }
    return widgets;
  }

  Widget _categorySectionHeader(String key, int count) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Row(
        children: [
          IngredientCategoryUnifier.buildCategoryIcon(key: key, size: 16),
          const SizedBox(width: 6),
          Text(
            IngredientCategoryUnifier.titleFromKey(key),
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
              color: _ink,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: _sub,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIngredientChip(int index) {
    final ing = widget.ingredients[index];
    final selected = _selected.contains(index);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.light();
        setState(() {
          if (selected) {
            _selected.remove(index);
          } else {
            _selected.add(index);
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF1EA) : Colors.white,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? _brand : const Color(0xFFE9EDF2),
            width: 1.4,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              size: 16,
              color: selected ? _brand : const Color(0xFFC4CAD2),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ing.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: selected ? _brand : _ink,
                ),
              ),
            ),
            if (_amountLabel(ing) != null) ...[
              const SizedBox(width: 6),
              Text(
                _amountLabel(ing)!,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: selected ? _brand.withValues(alpha: 0.7) : _sub,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _amountLabel(RecommendableIngredient ing) {
    final amount = ing.amountLeft;
    if (amount == null || amount <= 0) return null;
    final amountText = amount % 1 == 0
        ? amount.toInt().toString()
        : amount.toStringAsFixed(1);
    return '$amountText${ing.unit ?? ''}';
  }

  // ---------------------------------------------------------------------------
  // Stage: loading
  // ---------------------------------------------------------------------------
  Widget _buildLoadingStage(ScrollController controller) {
    return ListView(
      controller: controller,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 44, 20, 24),
      children: [
        Center(child: _ConvergeLoader(names: _spinNames)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Stage: results
  // ---------------------------------------------------------------------------
  Widget _buildResultsStage(ScrollController controller) {
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      itemCount: _results.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Text(
                  '${_results.length}개의 추천',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: _ink,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _confirmRestart,
                  child: Row(
                    children: const [
                      Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: _brand,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '다시 추천받기',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          color: _brand,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final result = _results[index - 1];
        return _RecipeRecommendationCard(
          result: result,
          recipeService: _recipeService,
          backgroundParsingService: _backgroundParsingService,
          isBookmarked: _bookmarkedIds.contains(result.recipeId),
          onBookmark: () => _toggleBookmark(result.recipeId),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Stage: empty / error
  // ---------------------------------------------------------------------------
  Widget _buildEmptyStage(ScrollController controller) {
    return _buildMessageStage(
      controller: controller,
      icon: Icons.search_off_rounded,
      title: '딱 맞는 레시피가 없어요',
      message: '선택한 재료로 만들 수 있는 레시피를\n아직 찾지 못했어요. 재료를 바꿔보세요.',
      actionLabel: '재료 다시 선택',
      onAction: () => setState(() => _stage = _Stage.select),
    );
  }

  Widget _buildErrorStage(ScrollController controller) {
    return _buildMessageStage(
      controller: controller,
      icon: Icons.cloud_off_rounded,
      title: '추천을 불러오지 못했어요',
      message: _errorMessage.isEmpty
          ? '잠시 후 다시 시도해주세요.'
          : _errorMessage,
      actionLabel: '다시 시도',
      onAction: _runRecommendation,
    );
  }

  Widget _buildMessageStage({
    required ScrollController controller,
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
      children: [
        const SizedBox(height: 20),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF1F4),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 30, color: _sub),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: _ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.45,
            letterSpacing: -0.2,
            color: _sub,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 13,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE9EDF2)),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: _ink,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // CTA bar
  // ---------------------------------------------------------------------------
  Widget _buildCtaBar({
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final navInset = IosLiquidGlassTabBar.overlayChromeInset(context);
    final bottomInset = navInset > 0
        ? navInset
        : MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        12 + bottomInset,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFFFF8A4C), Color(0xFFFF5A1F)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: _brand.withValues(alpha: 0.34),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Result model
// =============================================================================
class _RecResult {
  _RecResult({
    required this.recipeId,
    required this.title,
    required this.thumbnailUrl,
    required this.matchPercent,
    required this.reasonSummary,
    required this.matchedNames,
    required this.matchedCount,
    required this.recipeMap,
  });

  final String recipeId;
  final String title;
  final String thumbnailUrl;
  final double matchPercent;
  final String reasonSummary;
  final List<String> matchedNames;
  final int matchedCount;

  /// 실제 레시피 카드 렌더링용 원본 레시피 맵(`recipes` 컬렉션 형태).
  final Map<String, dynamic> recipeMap;

  /// Firestore `ingredient_recipe_index` 기반 로컬 추천 결과.
  factory _RecResult.fromLocal(IngredientRecipeRecommendationResult source) {
    return _RecResult(
      recipeId: source.recipeId,
      title: source.title,
      thumbnailUrl: source.thumbnailUrl,
      matchPercent: source.matchPercent,
      reasonSummary: source.reasonSummary,
      matchedNames: source.matchedNames,
      matchedCount: source.matchedCount,
      recipeMap: source.recipeMap,
    );
  }
}

// =============================================================================
// Recommendation card
// =============================================================================
class _RecipeRecommendationCard extends StatelessWidget {
  const _RecipeRecommendationCard({
    required this.result,
    required this.recipeService,
    required this.backgroundParsingService,
    required this.isBookmarked,
    required this.onBookmark,
  });

  final _RecResult result;
  final RecipeService recipeService;
  final BackgroundParsingService backgroundParsingService;
  final bool isBookmarked;
  final VoidCallback onBookmark;

  static const Color _ink = Color(0xFF191F28);
  static const Color _sub = Color(0xFF8B95A1);
  static const Color _brand = Color(0xFFFF6422);

  @override
  Widget build(BuildContext context) {
    final used = result.matchedNames;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 카드 위쪽: 매치율 + 사용된 재료
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2, bottom: 9),
          child: Row(
            children: [
              _MatchBadge(percent: result.matchPercent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '사용하는 재료',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: _sub,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (used.isEmpty)
                      const Text(
                        '매칭된 재료가 없어요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: _ink,
                        ),
                      )
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        clipBehavior: Clip.none,
                        child: Row(
                          children: [
                            for (final name in used)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: _usedChip(name),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 카드 안쪽: 홈 인기 그룹과 동일하게 우상단 북마크 오버레이.
        Stack(
          clipBehavior: Clip.none,
          children: [
            HomeStyleRecipeCard.fromRecipeMap(
              context,
              result.recipeMap,
              recipeService: recipeService,
              backgroundParsingService: backgroundParsingService,
              forceHideDate: true,
              screenName: 'fridge',
              sectionId: 'fridge_recommendation',
            ),
            Positioned(
              top: -3.5,
              right: 13,
              child: Semantics(
                button: true,
                label: isBookmarked ? '레시피북에서 제거' : '레시피북에 저장',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBookmark,
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    child: RecipeBookmarkGlyph(isBookmarked: isBookmarked),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _usedChip(String label) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: _brand.withValues(alpha: 0.08),
            blurRadius: 5,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_rounded,
            size: 13,
            color: Color(0xFF191F28),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: Color(0xFF191F28),
            ),
          ),
        ],
      ),
    );
  }
}

/// 매치율 배지 (원형 링 + 퍼센트).
class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    final value = (percent / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(44, 44),
            painter: _MatchRingPainter(value),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${percent.round()}',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: -0.5,
                  color: Color(0xFFFF6422),
                ),
              ),
              const Text(
                '%',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  color: Color(0xFFFFA983),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MatchRingPainter extends CustomPainter {
  _MatchRingPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 3;
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFFFE6D8);
    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        colors: [Color(0xFFFF8A4C), Color(0xFFFF5A1F)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    final sweep = 2 * math.pi * value;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MatchRingPainter oldDelegate) =>
      oldDelegate.value != value;
}

// =============================================================================
// 추천 로딩: 재료가 가운데로 모여 합쳐지며 레시피가 만들어지는 애니메이션
// =============================================================================
class _ConvergeLoader extends StatefulWidget {
  const _ConvergeLoader({required this.names});

  final List<String> names;

  @override
  State<_ConvergeLoader> createState() => _ConvergeLoaderState();
}

class _ConvergeLoaderState extends State<_ConvergeLoader>
    with SingleTickerProviderStateMixin {
  static const Color _brand = Color(0xFFFF6422);
  static const Color _ink = Color(0xFF191F28);
  static const Color _sub = Color(0xFF8B95A1);
  static const List<Color> _dotColors = [
    Color(0xFFFF8A65),
    Color(0xFFFFB74D),
    Color(0xFF81C784),
    Color(0xFF4FC3F7),
    Color(0xFF9575CD),
    Color(0xFFF06292),
    Color(0xFF4DB6AC),
    Color(0xFFFFD54F),
  ];

  late final AnimationController _t;

  @override
  void initState() {
    super.initState();
    _t = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.names.isEmpty ? const ['재료'] : widget.names;
    final n = math.min(names.length, 8);
    const box = 210.0;
    const rMax = 90.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: box,
          height: box,
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final t = _t.value;
              final pulse = 1 + 0.07 * math.sin(t * 2 * math.pi * 2);
              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // 글로우
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _brand.withValues(alpha: 0.18),
                          blurRadius: 30,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  // 가운데로 모여드는 재료 칩
                  for (var i = 0; i < n; i++)
                    _convergingChip(names[i], i, n, t, rMax),
                  // 중앙: 배경 없는 3D 물음표
                  Transform.scale(
                    scale: pulse,
                    child: Image.asset(
                      'assets/images/question_3d.png',
                      width: 120,
                      height: 120,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox(
                        width: 120,
                        height: 120,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 26),
        AnimatedBuilder(
          animation: _t,
          builder: (context, _) {
            final dots = (_t.value * 3).floor() + 1;
            return Text(
              '재료를 합쳐 레시피를 만드는 중${'.' * dots}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 16.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.4,
                color: _ink,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          '${widget.names.length}개 재료로 어울리는 요리를 찾는 중',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: _sub,
          ),
        ),
      ],
    );
  }

  /// 바깥에서 중앙으로 빨려들어가며 합쳐지는 재료 칩 1개(반복).
  Widget _convergingChip(String name, int i, int n, double t, double rMax) {
    final frac = (t + i / n) % 1.0;
    // 0도(오른쪽)부터 배치 → 재료 2개일 때 좌/우에서 들어온다.
    final angle = (2 * math.pi * i / n);
    final r = rMax * (1 - Curves.easeIn.transform(frac));
    final dx = math.cos(angle) * r;
    final dy = math.sin(angle) * r;
    final scale = 0.5 + 0.5 * (r / rMax); // 바깥 1.0 → 중앙 0.5
    double opacity;
    if (frac < 0.12) {
      opacity = frac / 0.12; // 등장
    } else if (frac > 0.82) {
      opacity = (1 - frac) / 0.18; // 중앙에서 합쳐지며 사라짐
    } else {
      opacity = 1;
    }
    final color = _dotColors[i % _dotColors.length];
    return Transform.translate(
      offset: Offset(dx, dy),
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

