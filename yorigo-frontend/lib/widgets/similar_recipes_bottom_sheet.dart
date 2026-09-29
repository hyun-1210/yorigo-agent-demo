import 'package:flutter/material.dart';

import '../services/background_parsing_service.dart';
import '../services/recipe_service.dart';
import 'home_style_recipe_card.dart';

/// Shown right after a manual recipe (text/screenshots) is saved.
/// Lists up to 3 similar completed recipes whose `canonicalDish` matches the
/// just-saved recipe, and a "don't show again" checkbox that persists the
/// preference via [RecipeService.setSimilarRecipesSheetDismissed].
///
/// Use [SimilarRecipesBottomSheet.show] from a navigator-root context after
/// the parsing flow's post-save hook in [BackgroundParsingService].
class SimilarRecipesBottomSheet {
  SimilarRecipesBottomSheet._();

  /// Display the bottom sheet if [similarRecipes] is non-empty.
  /// Returns immediately (no await needed) — the sheet manages its own lifecycle.
  static Future<void> show(
    BuildContext context, {
    required List<Map<String, dynamic>> similarRecipes,
  }) {
    final visible = similarRecipes.take(3).toList(growable: false);
    if (visible.isEmpty) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      builder: (ctx) => _SimilarRecipesBottomSheetContent(recipes: visible),
    );
  }
}

class _SimilarRecipesBottomSheetContent extends StatefulWidget {
  const _SimilarRecipesBottomSheetContent({required this.recipes});

  final List<Map<String, dynamic>> recipes;

  @override
  State<_SimilarRecipesBottomSheetContent> createState() =>
      _SimilarRecipesBottomSheetContentState();
}

class _SimilarRecipesBottomSheetContentState
    extends State<_SimilarRecipesBottomSheetContent> {
  bool _dontShowAgain = false;
  final RecipeService _recipeService = RecipeService();
  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();

  Future<void> _closeAndPersist() async {
    if (_dontShowAgain) {
      await _recipeService.setSimilarRecipesSheetDismissed(true);
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return DefaultTextStyle(
      style: const TextStyle(fontFamily: 'Pretendard'),
      child: SafeArea(
        top: false,
        child: Container(
          margin: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '비슷한 레시피들이에요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                          height: 1.4,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Color(0xFF9CA3AF)),
                      onPressed: _closeAndPersist,
                      splashRadius: 20,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final recipe in widget.recipes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: HomeStyleRecipeCard.fromRecipeMap(
                            context,
                            recipe,
                            recipeService: _recipeService,
                            backgroundParsingService:
                                _backgroundParsingService,
                            hideAddedDateWhenEmpty: true,
                            forceHideDate: true,
                            screenName: 'recipe_detail',
                            sectionId: 'similar_recipes',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(
                height: 1,
                thickness: 1,
                color: Color(0xFFF1F2F4),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _dontShowAgain = !_dontShowAgain),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: _dontShowAgain,
                            onChanged: (v) =>
                                setState(() => _dontShowAgain = v ?? false),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '앞으로는 띄우지 않기',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF6A7282),
                              height: 1.4,
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
        ),
      ),
    );
  }
}
